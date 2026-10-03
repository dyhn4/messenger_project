// 북마크의 순수 규칙 — DB·서버 없이 단위 테스트한다(test/bookmarks.test.js). 저장은 db/queries/bookmarks.js,
// 요청 처리는 bookmarks.js. 잔디의 북마크와 같다: 팀 북마크/개인 북마크, 수정·삭제는 만든 사람과 관리자만,
// 순서 변경은 팀 북마크는 관리자만(개인 북마크는 본인).

export const BOOKMARK_KINDS = ['team', 'personal'];
export const BOOKMARK_TITLE_MAX = 50;
export const BOOKMARK_URL_MAX = 2000;
/** 한 팀·한 종류(개인은 한 사람)당 북마크 수 상한 — 터무니없이 많이 쌓이는 걸 막는다. */
export const BOOKMARK_MAX_PER_KIND = 200;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUuid = (v) => typeof v === 'string' && UUID_RE.test(v);

/** http/https 주소만 — 그 외(javascript:, file: 등)와 파싱 안 되는 값은 null. 앞뒤 공백은 자른다. */
export function normalizeHttpUrl(raw, max = BOOKMARK_URL_MAX) {
  if (typeof raw !== 'string') return null;
  const value = raw.trim();
  if (!value || value.length > max) return null;
  try {
    const u = new URL(value);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
    if (!u.hostname) return null;
  } catch {
    return null;
  }
  return value;
}

/**
 * 만들기/고치기 본문 검사. [partial]이면(PATCH) 보낸 필드만 검사하고 `fields`에도 보낸 것만 담는다.
 * imageUrl은 null/빈 문자열이면 이미지 없음, 문자열이면 http(s) 주소이거나 우리 서버 업로드 경로(/uploads/…)여야 한다
 * — [toUpload]는 서명된 /files/… 링크를 원본 업로드 경로로 되돌리는 함수(upload.js toStoredUploadUrl)다.
 * 돌려주는 값: `{ ok: true, fields }` 또는 `{ ok: false, error }`.
 */
export function parseBookmarkBody(body, { partial = false, toUpload = () => null } = {}) {
  const fields = {};
  const b = body ?? {};
  if (!partial || b.title !== undefined) {
    const title = typeof b.title === 'string' ? b.title.trim() : '';
    if (!title) return { ok: false, error: '북마크 제목을 입력하세요.' };
    if ([...title].length > BOOKMARK_TITLE_MAX) {
      return { ok: false, error: `북마크 제목은 ${BOOKMARK_TITLE_MAX}자 이내로 입력하세요.` };
    }
    fields.title = title;
  }
  if (!partial || b.url !== undefined) {
    const url = normalizeHttpUrl(b.url);
    if (!url) return { ok: false, error: '북마크 주소는 http:// 또는 https://로 시작하는 올바른 주소여야 합니다(2000자 이내).' };
    fields.url = url;
  }
  if (b.imageUrl !== undefined) {
    if (b.imageUrl === null || b.imageUrl === '') {
      fields.imageUrl = null;
    } else {
      const image = typeof b.imageUrl === 'string' ? (toUpload(b.imageUrl) ?? normalizeHttpUrl(b.imageUrl)) : null;
      if (!image) return { ok: false, error: '이미지 주소가 올바르지 않습니다.' };
      fields.imageUrl = image;
    }
  } else if (!partial) {
    fields.imageUrl = null;
  }
  return { ok: true, fields };
}

/** 이 사람이 이 북마크를 보고 있을 때 쓸 권한. [canManage]는 팀 관리자 여부. */
export function bookmarkPermissions({ bookmark, requesterId, canManage }) {
  if (bookmark.kind === 'personal') {
    // 개인 북마크는 본인 것만 보이므로 관리자라도 남의 것을 고치지 못한다.
    const mine = bookmark.ownerId === requesterId;
    return { canEdit: mine, canReorder: mine };
  }
  return {
    canEdit: bookmark.creatorId === requesterId || canManage === true,
    canReorder: canManage === true,
  };
}

/** 팀 북마크를 만들 수 있는지 — 정회원 이상(준회원은 보기만). 개인 북마크는 팀 멤버면 누구나. */
export function canCreateBookmark({ kind, role, isMember }) {
  if (!isMember) return false;
  if (kind === 'personal') return true;
  return role === 'member' || role === 'admin';
}

/** 순서 변경 요청의 ids가 그 종류의 현재 전체 id 집합과 정확히 같은지(중복·누락·모르는 id 없음). */
export function reorderIdsMatch(ids, currentIds) {
  if (!Array.isArray(ids) || ids.some((id) => typeof id !== 'string')) return false;
  if (ids.length !== currentIds.length) return false;
  const want = new Set(currentIds);
  const got = new Set(ids);
  return got.size === ids.length && ids.every((id) => want.has(id));
}
