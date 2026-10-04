// 앨범의 순수 규칙(입력 검사·권한 판단) — DB 없이 단위 테스트할 수 있게 albums.js에서 떼어 냈다.

import { canManageTeam, graphemeLength } from './permissions.js';

// 앨범 입력 제한 — 클라이언트 입력창(maxLength)과 같은 단위(글자 = 이모지 한 덩어리 1자)로 센다.
export const ALBUM_TITLE_MAX = 50;
export const ALBUM_DESCRIPTION_MAX = 300;
/** 한 번의 항목 추가(POST /albums/:id/items)로 올릴 수 있는 최대 개수 — 앨범의 총 개수에는 제한이 없다. */
export const ALBUM_ITEMS_PER_REQUEST_MAX = 100;
/** 앨범 항목을 대화방에 공유할 때 한 번에 보낼 수 있는 최대 개수. */
export const ALBUM_SHARE_MAX = 10;
/** 한 번에 지울 수 있는 항목 수(요청 크기 방어 — 화면은 한 번에 100개씩만 올리지만 선택은 더 많을 수 있다). */
export const ALBUM_DELETE_MAX = 500;
export const ALBUM_LIST_DEFAULT_LIMIT = 30;
export const ALBUM_LIST_MAX_LIMIT = 100;
export const ALBUM_ITEMS_DEFAULT_LIMIT = 60;
export const ALBUM_ITEMS_MAX_LIMIT = 200;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const UPLOAD_PATH_RE = /^\/uploads\/[^/\\]+$/;

export function isUuid(value) {
  return typeof value === 'string' && UUID_RE.test(value);
}

/** 앨범 제목·설명 — `partial`이면(수정) 주어진 키만 검사한다. 통과하면 `{ title?, description? }`, 아니면 `{ error }`. */
export function parseAlbumFields(body, { partial = false } = {}) {
  const out = {};
  if (!partial || body?.title !== undefined) {
    const title = typeof body?.title === 'string' ? body.title.trim() : '';
    if (!title) return { error: '앨범 제목을 입력하세요.' };
    if (graphemeLength(title) > ALBUM_TITLE_MAX) return { error: `앨범 제목은 ${ALBUM_TITLE_MAX}자 이내로 입력하세요.` };
    out.title = title;
  }
  if (!partial || body?.description !== undefined) {
    let description = null;
    if (body?.description !== undefined && body?.description !== null) {
      if (typeof body.description !== 'string') return { error: '앨범 설명이 올바르지 않습니다.' };
      description = body.description.trim() || null;
      if (description && graphemeLength(description) > ALBUM_DESCRIPTION_MAX) {
        return { error: `앨범 설명은 ${ALBUM_DESCRIPTION_MAX}자 이내로 입력하세요.` };
      }
    }
    out.description = description;
  }
  return out;
}

/** mimeType으로 항목 종류를 정한다 — image/*(GIF 포함)는 'image', video/*는 'video', 그 밖은 null(앨범에 못 넣는다). */
export function albumKindOfMime(mimeType) {
  if (typeof mimeType !== 'string') return null;
  const mime = mimeType.trim().toLowerCase();
  if (mime.startsWith('image/')) return 'image';
  if (mime.startsWith('video/')) return 'video';
  return null;
}

function optionalInt(value, { min = 0 } = {}) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return null;
  const n = Math.round(value);
  return n >= min && n <= 2147483647 ? n : null;
}

/**
 * 항목 일괄 추가 본문 검사 — 통과하면 `{ items }`(DB에 넣을 모양: kind/fileUrl/fileName/fileSize/mimeType/
 * thumbnailUrl/width/height/durationMs), 아니면 `{ error }`. [resolveUrl]은 서명된 `/files/<토큰>`을 원본
 * `/uploads/<파일>`로 되돌리는 함수(upload.js의 resolveRawUrl) — 순수 규칙으로 두려고 밖에서 받는다.
 * kind는 클라이언트 값을 믿지 않고 mimeType으로 정한다(이미지/영상만, 아니면 400).
 */
export function parseAlbumItems(body, resolveUrl) {
  if (!Array.isArray(body?.items) || body.items.length === 0) return { error: '추가할 파일을 선택하세요.' };
  if (body.items.length > ALBUM_ITEMS_PER_REQUEST_MAX) {
    return { error: `한 번에 ${ALBUM_ITEMS_PER_REQUEST_MAX}개까지 올릴 수 있습니다.` };
  }
  const items = [];
  for (const raw of body.items) {
    if (!raw || typeof raw !== 'object') return { error: '파일 정보가 올바르지 않습니다.' };
    const kind = albumKindOfMime(raw.mimeType);
    if (!kind) return { error: '앨범에는 이미지와 영상만 올릴 수 있습니다.' };
    const fileUrl = typeof raw.fileUrl === 'string' ? resolveUrl(raw.fileUrl) : null;
    if (!fileUrl || !UPLOAD_PATH_RE.test(fileUrl)) return { error: '업로드한 파일 경로가 올바르지 않거나 만료되었습니다.' };
    let thumbnailUrl = typeof raw.thumbnailUrl === 'string' ? resolveUrl(raw.thumbnailUrl) : null;
    if (thumbnailUrl && !UPLOAD_PATH_RE.test(thumbnailUrl)) thumbnailUrl = null;
    const fileName = typeof raw.fileName === 'string' && raw.fileName.trim() ? raw.fileName.trim().slice(0, 255) : null;
    items.push({
      kind,
      fileUrl,
      fileName,
      fileSize: optionalInt(raw.fileSize),
      mimeType: raw.mimeType.trim().toLowerCase().slice(0, 100),
      thumbnailUrl,
      width: optionalInt(raw.width, { min: 1 }),
      height: optionalInt(raw.height, { min: 1 }),
      durationMs: kind === 'video' ? optionalInt(raw.durationMs) : null,
    });
  }
  return { items };
}

/** itemIds 배열 검사(삭제·공유 공통) — 중복은 합치고 UUID가 아닌 값이 있으면 400. `{ ids }` 또는 `{ error }`. */
export function parseItemIds(value, { min = 1, max, overLimitMessage = null }) {
  if (!Array.isArray(value) || value.some((id) => !isUuid(id))) return { error: 'itemIds는 항목 id 배열이어야 합니다.' };
  const ids = [...new Set(value.map((id) => id.toLowerCase()))];
  if (ids.length < min) return { error: '항목을 선택하세요.' };
  if (ids.length > max) return { error: overLimitMessage ?? `한 번에 ${max}개까지 선택할 수 있습니다.` };
  return { ids };
}

/** `GET /albums` 쿼리 검사 — `{ teamId, roomId|null, before(Date|null), limit }` 또는 `{ error }`. */
export function parseAlbumListQuery(query) {
  const teamId = typeof query?.teamId === 'string' ? query.teamId : '';
  if (!isUuid(teamId)) return { error: 'teamId가 필요합니다.' };
  const roomId = typeof query?.roomId === 'string' && query.roomId ? query.roomId : null;
  return { teamId, roomId, ...parseCursor(query, ALBUM_LIST_DEFAULT_LIMIT, ALBUM_LIST_MAX_LIMIT) };
}

/** `GET /albums/:id/items` 쿼리 검사 — `{ before(Date|null), limit }` 또는 `{ error }`. */
export function parseItemsQuery(query) {
  return parseCursor(query, ALBUM_ITEMS_DEFAULT_LIMIT, ALBUM_ITEMS_MAX_LIMIT);
}

function parseCursor(query, defaultLimit, maxLimit) {
  let before = null;
  if (query?.before !== undefined && query.before !== '') {
    const ms = Number(query.before);
    if (!Number.isFinite(ms) || ms <= 0) return { error: 'before는 밀리초 시각이어야 합니다.' };
    before = new Date(ms);
  }
  let limit = defaultLimit;
  if (query?.limit !== undefined && query.limit !== '') {
    const n = Math.floor(Number(query.limit));
    if (!Number.isFinite(n) || n < 1) return { error: 'limit은 1 이상의 숫자여야 합니다.' };
    limit = Math.min(n, maxLimit);
  }
  return { before, limit };
}

// ── 권한 ────────────────────────────────────────────────────────────────
// [access]는 access.js의 topicAccess(room, userId) 결과 — { isMember(팀), role, isOwner, canManage(토픽 관리자) }.

/** 팀 관리자(소유자·관리자 등급) — 팀에서 빠진 사람은 해당 없음. */
export function isAlbumTeamAdmin(access) {
  return !!access?.isMember && canManageTeam(access);
}

/** 제목·설명·대표 이미지 수정 — 만든 사람·방 관리자(토픽 관리자)·팀 관리자. */
export function canEditAlbum({ album, userId, access }) {
  return album.creatorId === userId || !!access?.canManage || isAlbumTeamAdmin(access);
}

/** 앨범 삭제 — 만든 사람·팀 관리자. */
export function canDeleteAlbum({ album, userId, access }) {
  return album.creatorId === userId || isAlbumTeamAdmin(access);
}

/** 항목 삭제 — 올린 사람·앨범 만든 사람·팀 관리자. */
export function canDeleteAlbumItem({ album, item, userId, access }) {
  return item.uploaderId === userId || album.creatorId === userId || isAlbumTeamAdmin(access);
}

/** 지울 항목들을 권한 있는 것과 없는 것으로 나눈다 — `{ allowed, skipped }`. */
export function partitionDeletableItems({ album, items, userId, access }) {
  const allowed = [];
  const skipped = [];
  for (const item of items) {
    (canDeleteAlbumItem({ album, item, userId, access }) ? allowed : skipped).push(item);
  }
  return { allowed, skipped };
}

/** 앨범을 만들거나 항목을 올릴 수 있는 방인지 — 비밀 대화는 서버가 파일 내용을 못 보므로 제외, 그 밖은 허용. 거절 문구 또는 null. */
export function albumRoomDenial(room) {
  if (room?.isSecret) return '비밀 대화에서는 앨범을 쓸 수 없습니다.';
  return null;
}

/** 읽기 전용·보관된 토픽에는 관리자만 앨범을 만들고 올린다 — 거절 문구 또는 null. */
export function albumWriteDenial({ room, canManage }) {
  if (room?.type !== 'topic' || canManage) return null;
  if (room.archivedAt) return '보관된 토픽에서는 토픽 관리자만 앨범을 쓸 수 있습니다.';
  if (room.readOnly) return '읽기 전용 토픽에서는 토픽 관리자만 앨범을 쓸 수 있습니다.';
  return null;
}

/** 공유 대상 방 — 챗 뷰 토픽·그룹·1:1·나와의 대화만(보드 뷰 토픽·비밀 대화 제외). 거절 문구 또는 null. */
export function albumShareTargetDenial(room) {
  if (room?.isSecret) return '비밀 대화로는 앨범을 공유할 수 없습니다.';
  if (room?.type === 'topic' && room.viewMode === 'board') return '보드 뷰 토픽에는 앨범을 공유할 수 없습니다.';
  return null;
}

/** 공유 메시지에 실을 첨부 한 칸 — 이미지는 'image', 영상은 'file'(채팅 말풍선이 영상을 파일 첨부로 다룬다). */
export function toShareAttachment(item) {
  return {
    kind: item.kind === 'image' ? 'image' : 'file',
    fileUrl: item.fileUrl,
    fileName: item.fileName,
    fileSize: item.fileSize,
    mimeType: item.mimeType,
    thumbnailUrl: item.thumbnailUrl,
  };
}

/** 항목 몇 개를 한 메시지로 보낼 때의 type — 전부 이미지면 'image', 하나라도 영상이면 'file'. */
export function shareMessageType(items) {
  return items.every((i) => i.kind === 'image') ? 'image' : 'file';
}

/** 대표 이미지 후보인지 — 이미지이거나 썸네일이 있는 영상. */
export function canBeCover(item) {
  return item.kind === 'image' || !!item.thumbnailUrl;
}

// ── 앨범 공유(앨범 카드 메시지) ──────────────────────────────────────────
// 앨범 하나를 통째로 대화방에 알리는 글 메시지 — 사람이 쓴 메시지(필수) 아래에 "{팀}에서 공유된 앨범입니다."와
// 앨범 카드가 붙는다. 메시지는 일반 글(type 'text')이라 검색·미리보기·수정·멘션을 그대로 쓰고, 카드는
// messages.album_id(앨범이 지워지면 null)·album_share({ title, teamName } 스냅샷)로 그린다.

/** 공유 메시지 최대 길이(예약 메시지와 같은 5,000자 — 글자 = 이모지 한 덩어리 1자). */
export const ALBUM_SHARE_TEXT_MAX = 5000;

function shiftRanges(raw, lead, length) {
  if (!Array.isArray(raw)) return null;
  if (lead === 0) return raw;
  return raw.map((r) =>
    r && Number.isInteger(r.s) && Number.isInteger(r.e)
      ? { ...r, s: Math.max(0, r.s - lead), e: Math.min(length, r.e - lead) }
      : r,
  );
}

/**
 * 앨범 공유 메시지 본문 — 필수, 앞뒤 공백을 빼고 5,000자까지. 뗀 앞 공백만큼 서식·멘션 구간도 당긴다(구간은 본문의
 * UTF-16 위치 기준 — 정리는 sendUserMessage가 textFormat.js·notificationRules.js로 한다).
 * 통과하면 `{ text, textFormat, mentions }`, 아니면 `{ error }`.
 */
export function parseAlbumShareMessage(body) {
  const raw = body?.text;
  if (typeof raw !== 'string' || !raw.trim()) return { error: '메시지를 입력하세요.' };
  const lead = raw.length - raw.trimStart().length;
  const text = raw.trim();
  if (graphemeLength(text) > ALBUM_SHARE_TEXT_MAX) {
    return { error: `메시지는 ${ALBUM_SHARE_TEXT_MAX.toLocaleString('en-US')}자 이내로 입력하세요.` };
  }
  return {
    text,
    textFormat: shiftRanges(body?.textFormat, lead, text.length),
    mentions: shiftRanges(body?.mentions, lead, text.length),
  };
}

/** 메시지에 실어 둘 앨범 스냅샷 — 카드의 제목과 "{팀 이름}에서 공유된 앨범입니다." 문구에 쓴다. */
export function albumShareSnapshot(album, teamName) {
  return { title: album.title, teamName: typeof teamName === 'string' && teamName ? teamName : null };
}

/**
 * 메시지 DTO의 `sharedAlbum` — 앨범 공유 메시지가 아니거나 지운 메시지면 null. 앨범이 지워졌으면 id가 null이다
 * (카드는 "삭제된 앨범"으로 보인다).
 */
export function toSharedAlbumDto(m) {
  const snap = m?.albumShare;
  if (!snap || typeof snap !== 'object' || m.deletedAt) return null;
  return {
    id: m.albumId ?? null,
    title: typeof snap.title === 'string' ? snap.title : '',
    teamName: typeof snap.teamName === 'string' ? snap.teamName : null,
  };
}

/** 앨범 상세의 내 권한 — 그 방 멤버가 아니라 공유 메시지로만 보는 사람([viaShare])은 보기·내려받기만 된다. */
export function albumPerms({ album, userId, access, viaShare = false }) {
  if (viaShare) {
    return { canEdit: false, canDelete: false, canDeleteAnyItem: false, canShare: false, viewOnly: true };
  }
  return {
    canEdit: canEditAlbum({ album, userId, access }),
    canDelete: canDeleteAlbum({ album, userId, access }),
    // 항목을 지우는 쪽 "전부 가능" 여부 — 앨범 만든 사람·팀 관리자(그 밖에는 항목마다 canDelete를 본다).
    canDeleteAnyItem: canDeleteAlbumItem({ album, item: { uploaderId: null }, userId, access }),
    canShare: true,
    viewOnly: false,
  };
}
