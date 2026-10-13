/**
 * 멘션·알림 센터의 **순수 규칙** — DB도 소켓도 만지지 않는다. 그래서 `node --test`로 그대로 시험할 수 있고
 * (server/test/notifications.test.js), 실제로 행을 넣고 푸시를 보내는 notifications.js는 여기서 "누구에게 / 무슨
 * 종류로 / 푸시를 보낼지"만 받아 쓴다.
 *
 * 멘션: messages.mentions · message_comments.mentions · scheduled_messages.mentions에 이 모양으로 저장된다.
 *   [ { type: 'user', userId, s, e } | { type: 'all', s, e } ]   — s/e는 본문(text)의 UTF-16 위치 구간(e는 포함 안 함).
 */

export const MENTION_MAX = 50; // 한 글에 담을 수 있는 멘션 수
export const PREVIEW_MAX = 120; // 알림 미리보기 길이
export const BOARD_LEVELS = ['all', 'important', 'new'];
// 보드 알림 기본은 'important'(새 글 + 내가 쓴 글에 달린 댓글) — 글 수정·남의 글 댓글까지 받고 싶은 사람은 알림 설정에서
// '전체'로 바꾼다. 큰 토픽에서 수정·댓글마다 멤버 전원에게 알림 행이 생기는 걸 기본으로 두지 않으려는 선택이다.
export const DEFAULT_NOTIFICATION_SETTINGS = Object.freeze({ mentionAll: true, boardLevel: 'important', pushWhileOnline: true });

export const MENTION_KINDS = ['mention', 'mention_all'];
export const BOARD_KINDS = ['board_post', 'board_edit', 'board_comment'];

/**
 * 알림 목록·읽음 처리·안 읽음 수가 쓰는 묶음 이름. `mention`은 개인 멘션과 @all을 함께, `mention_personal`은 개인 멘션
 * (DB kind `mention`)만, `mention_all`은 @all(DB kind `mention_all`)만이다 — 알림 센터 멘션 탭의 드롭다운 필터가 쓴다.
 */
export const NOTIFICATION_GROUPS = ['mention', 'mention_personal', 'mention_all', 'board'];

/** 안 읽음 수 한 벌 — `mention`은 `mentionPersonal + mentionAll`의 합이다(옛 클라이언트가 읽는 키는 그대로 둔다). */
export function unreadCountsOf({ mentionPersonal = 0, mentionAll = 0, board = 0 } = {}) {
  return { mention: mentionPersonal + mentionAll, board, mentionPersonal, mentionAll };
}

/**
 * 멘션을 쓸 수 있는 방 — 토픽·그룹만. 1:1은 상대가 한 명뿐이라 멘션 없이도 모든 메시지가 그 사람에게 가고(오히려
 * 개인 멘션이 방 알림 끔 설정을 건너뛰는 알림이 된다), 나와의 대화는 부를 사람이 없으며, 비밀 대화는 서버가 본문을
 * 몰라 멘션을 지원하지 않는다.
 */
export function canMention(room) {
  return !!room && !room.isSecret && !room.isSelf && (room.type === 'topic' || room.type === 'group');
}

/** `@all`(방 전체 멘션)을 쓸 수 있는 방 — 지금은 멘션을 쓸 수 있는 방과 같다(토픽·그룹). */
export function canMentionAll(room) {
  return canMention(room);
}

/**
 * 클라이언트가 보낸 멘션을 저장할 모양으로 정리한다 — 잘못된 항목은 에러 없이 그 항목만 버린다.
 *  - 토픽·그룹이 아닌 방(1:1·나와의 대화·비밀 대화)에서는 전부 버린다([canMention]).
 *  - user: 방 멤버([memberIdSet])여야 하고 보낸 사람 본인은 뺀다. 같은 사람은 본문에서 먼저 나온 하나만.
 *  - all: 토픽·그룹에서만, 한 글에 하나.
 *  - 구간은 0 ≤ s < e ≤ text.length 여야 한다. 서로 겹치는 구간은 앞선 것만 남긴다(같은 글자를 두 번 강조할 수 없다).
 *  - 최대 [MENTION_MAX]개. 본문 위치 순으로 돌려준다.
 * [shift]는 서버가 본문 앞 공백을 잘라낸 글자 수 — 서식 구간과 마찬가지로 그만큼 앞으로 당겨 맞춘다.
 */
export function sanitizeMentions(rawMentions, text, { room, senderId, memberIdSet, shift = 0 } = {}) {
  if (!Array.isArray(rawMentions) || rawMentions.length === 0) return [];
  if (typeof text !== 'string' || text.length === 0 || !canMention(room)) return [];
  const allowAll = canMentionAll(room);
  const candidates = [];
  for (const m of rawMentions.slice(0, MENTION_MAX * 4)) {
    if (!m || typeof m !== 'object') continue;
    if (!Number.isInteger(m.s) || !Number.isInteger(m.e)) continue;
    const s = m.s - shift;
    const e = m.e - shift;
    if (s < 0 || e <= s || e > text.length) continue;
    if (m.type === 'user') {
      if (typeof m.userId !== 'string' || m.userId === senderId) continue;
      if (!memberIdSet || !memberIdSet.has(m.userId)) continue;
      candidates.push({ type: 'user', userId: m.userId, s, e });
    } else if (m.type === 'all') {
      if (!allowAll) continue;
      candidates.push({ type: 'all', s, e });
    }
  }
  candidates.sort((a, b) => a.s - b.s || a.e - b.e);
  const out = [];
  const seenUsers = new Set();
  let hasAll = false;
  let lastEnd = 0;
  for (const c of candidates) {
    if (out.length >= MENTION_MAX) break;
    if (c.s < lastEnd) continue; // 앞 멘션과 겹침
    if (c.type === 'user') {
      if (seenUsers.has(c.userId)) continue;
      seenUsers.add(c.userId);
    } else {
      if (hasAll) continue;
      hasAll = true;
    }
    out.push(c);
    lastEnd = c.e;
  }
  return out;
}

/** 저장된 멘션(jsonb)을 DTO용 배열로 — 없거나 모양이 이상하면 []. */
export function mentionsOrEmpty(value) {
  return Array.isArray(value) ? value : [];
}

/** 저장할 값 — 비었으면 null(행을 가볍게). */
export function mentionsToStore(list) {
  return Array.isArray(list) && list.length > 0 ? list : null;
}

/** 멘션 목록에서 개인 멘션 대상 userId 집합과 @all 여부. */
export function mentionTargets(mentions) {
  const list = mentionsOrEmpty(mentions);
  return {
    userIds: [...new Set(list.filter((m) => m?.type === 'user' && typeof m.userId === 'string').map((m) => m.userId))],
    all: list.some((m) => m?.type === 'all'),
  };
}

/**
 * 수정 전후 멘션을 비교한다 — 새로 생긴 것에만 알림을 보내고(이미 있던 사람에게 다시 알리지 않는다), 사라진 것은 알림
 * 기록을 지운다. 구간만 바뀐(같은 사람을 다른 자리에서 다시 멘션한) 경우는 "그대로"로 본다.
 */
export function diffMentions(before, after) {
  const prev = mentionTargets(before);
  const next = mentionTargets(after);
  const prevSet = new Set(prev.userIds);
  const nextSet = new Set(next.userIds);
  return {
    addedUserIds: next.userIds.filter((id) => !prevSet.has(id)),
    removedUserIds: prev.userIds.filter((id) => !nextSet.has(id)),
    addedAll: next.all && !prev.all,
    removedAll: prev.all && !next.all,
  };
}

/** 알림 미리보기 — 공백·줄바꿈을 한 칸으로 줄이고 앞 120자(글자 단위)만. */
export function previewOf(text) {
  if (typeof text !== 'string') return '';
  const flat = text.replace(/\s+/g, ' ').trim();
  const chars = Array.from(flat);
  return chars.length > PREVIEW_MAX ? chars.slice(0, PREVIEW_MAX).join('') : flat;
}

/** 푸시 본문 — 멘션은 "{이름}님이 회원님을 멘션했습니다: 미리보기" / @all은 "…모두를 멘션했습니다: …". */
export function notificationPushBody(kind, actorName, preview) {
  const name = actorName || '알 수 없음';
  switch (kind) {
    case 'mention':
      return `${name}님이 회원님을 멘션했습니다: ${preview}`;
    case 'mention_all':
      return `${name}님이 모두를 멘션했습니다: ${preview}`;
    case 'board_edit':
      return `${name}님이 게시글을 수정했습니다: ${preview}`;
    default:
      return preview;
  }
}

/** 알림 제목 끝에 붙는 방 꼬리표(push.js의 '·댓글', '·공지'와 같은 자리). */
export function pushTagSuffix(kind) {
  if (kind === 'mention' || kind === 'mention_all') return '멘션';
  if (kind === 'board_edit') return '게시글 수정';
  return null;
}

/**
 * 알림 기록 대상 중 **푸시를 보낼 사람**을 고른다. 기록은 [recipientIds] 전원에게 남기고 푸시만 여기서 거른다.
 *  - 개인 멘션(mention): 방 알림을 꺼 둔 사람에게도 간다(뮤트 무시).
 *  - @all(mention_all): 방 뮤트를 존중하고, 사용자 설정 mentionAll=false면 푸시만 생략(기록은 남는다).
 *  - 게시글 수정(board_edit): 뮤트한 사람은 기록만.
 *  - board_post·board_comment: 글·댓글 자체의 일반 채팅 푸시(push.js notifyOfflineMembers)가 이미 간다 — 두 번 울리지 않는다.
 * [isOnline]이 참인 사람은 뺀다(소켓이 붙어 있으면 notification:new·message:new로 실시간으로 받는다) — 실제로는
 * presence.js의 skipsPush를 넘긴다: "다른 기기 접속 중에도 푸시"를 끈 사람만 접속 중일 때 빠지고, 켠 사람은 남아서
 * 접속해 있지 않은 기기로만 간다(기기별로 거르는 건 push.js).
 * [settingsOf]는 userId → { mentionAll } (없으면 기본값).
 */
export function pushTargetsFor({ kind, recipientIds, mutedIds = new Set(), settingsOf = () => null, isOnline = () => false }) {
  return recipientIds.filter((id) => {
    if (isOnline(id)) return false;
    switch (kind) {
      case 'mention':
        return true;
      case 'mention_all':
        return !mutedIds.has(id) && (settingsOf(id)?.mentionAll ?? DEFAULT_NOTIFICATION_SETTINGS.mentionAll) !== false;
      case 'board_edit':
        return !mutedIds.has(id);
      default:
        return false;
    }
  });
}

/**
 * 보드 알림 수신자 — 보드 뷰 토픽의 멤버에서 행위자를 뺀 사람 중 각자의 boardLevel에 맞는 사람.
 *   event 'post'   — 새 게시글: 모든 수준이 받는다.
 *   event 'edit'   — 게시글 수정: 'all'만.
 *   event 'comment'— 게시글의 댓글: 'all'은 모든 멤버, 'important'는 그 게시글 작성자([postAuthorId])만, 'new'는 아무도.
 * [excludeIds]는 같은 글로 이미 멘션 알림을 받는 사람(같은 글에 알림이 두 번 가지 않게).
 * [levelOf]는 userId → 'all'|'important'|'new' (없으면 기본 'important').
 */
export function boardRecipientsFor({ event, memberIds, actorId, postAuthorId = null, levelOf = () => null, excludeIds = [] }) {
  const exclude = new Set(excludeIds);
  const out = [];
  for (const id of new Set(memberIds)) {
    if (id === actorId || exclude.has(id)) continue;
    const level = levelOf(id) ?? DEFAULT_NOTIFICATION_SETTINGS.boardLevel;
    if (event === 'post') out.push(id);
    else if (event === 'edit') {
      if (level === 'all') out.push(id);
    } else if (event === 'comment') {
      if (level === 'all' || (level === 'important' && id === postAuthorId)) out.push(id);
    }
  }
  return out;
}

/** 방 이름을 글로 — 클라이언트 Room.displayName()/rooms.js roomDisplayName과 같은 규칙인데, 멤버를 미리 받아 둔 채
 * 받는 사람마다 계산한다(@all 한 번에 수십 명이면 사람마다 DB를 다시 읽지 않도록). 검색 패널의 대화방 이름
 * (roomSearchRules.js)도 이걸 쓴다. */
export function roomNameForViewer(room, members, viewerId) {
  if (room.isSelf) return '나와의 대화';
  if (room.name) return room.name;
  if (room.type === 'dm') {
    const other = members.find((m) => m.id !== viewerId);
    if (other) return other.name ?? '(알 수 없음)';
    // 상대가 빠진 1:1 대화(비밀 대화 혼자 나가기·팀에서 제외 — db/queries/rooms.js removeMemberFromRoom)는 남겨 둔
    // 이름으로 — rooms.js roomDisplayName과 같다. 알림 기록은 1:1 대화에 생기지 않으므로(멘션은 토픽·그룹, 보드 알림은
    // 보드 토픽) 이 줄이 실제로 쓰이는 곳은 검색 패널이다 — 방 목록과 같은 이름으로 보이고 그 이름으로 찾힌다.
    return room.secretDepartedMemberName ? `${room.secretDepartedMemberName} (나갔음)` : '(알 수 없음)';
  }
  const names = members
    .filter((m) => m.id !== viewerId)
    .map((m) => m.name)
    .filter(Boolean)
    .sort();
  return names.length > 0 ? names.join(', ') : '(알 수 없음)';
}
