// 목록 쪽 나누기(무한 스크롤)용 커서의 순수 규칙 — 투표 목록(pollListRules.js)·내가 쓴 글(myPostsRules.js)이 같이 쓴다.
// 커서는 "<createdAt 밀리초>:<id>" 문자열이다. 같은 밀리초에 만든 글이 여럿이어도 id로 순서를 가려 빠지거나 겹치지 않는다
// (DB 쪽은 created_at을 밀리초로 잘라 같은 방식으로 비교·정렬한다 — db/queries 참고).

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value) {
  return typeof value === 'string' && UUID_RE.test(value);
}

export function formatCursor(ms, id) {
  return `${Math.trunc(ms)}:${id}`;
}

/**
 * 커서 문자열 → `{ ms, id }`. 비어 있으면 null(첫 쪽), 형식이 틀리면 `{ error }`. id 없이 밀리초만 와도(`1700000000000`)
 * 받는다 — 그때 id는 null이라 그 시각 "바로 앞/뒤"부터 이어진다.
 */
export function parseCursor(raw) {
  if (raw === undefined || raw === null || raw === '') return null;
  if (typeof raw !== 'string') return { error: 'before가 올바르지 않습니다.' };
  const [msPart, idPart, ...rest] = raw.split(':');
  const ms = Number(msPart);
  if (rest.length > 0 || !Number.isFinite(ms) || ms <= 0) return { error: 'before가 올바르지 않습니다.' };
  if (idPart !== undefined && !isUuid(idPart)) return { error: 'before가 올바르지 않습니다.' };
  return { ms: Math.trunc(ms), id: idPart ?? null };
}

/** `limit` 쿼리 → 1..[max]로 눌러 담은 정수. 비었으면 [fallback], 숫자가 아니거나 1 미만이면 null. */
export function parseLimit(raw, { fallback, max }) {
  if (raw === undefined || raw === null || raw === '') return fallback;
  const n = Math.floor(Number(raw));
  if (!Number.isFinite(n) || n < 1) return null;
  return Math.min(n, max);
}

/** `since`/`until`(밀리초) → Date. 비었으면 null, 숫자가 아니면 undefined(오류). */
export function parseTimeBound(raw) {
  if (raw === undefined || raw === null || raw === '') return null;
  const ms = Number(raw);
  if (!Number.isFinite(ms) || ms <= 0) return undefined;
  return new Date(ms);
}

/** 두 항목이 (시각, id) 순서에서 [order] 방향으로 앞서는지의 비교 함수 — 목록 섞기에 쓴다. */
export function compareByCursor(order) {
  const dir = order === 'asc' ? 1 : -1;
  return (a, b) => {
    if (a.createdAt !== b.createdAt) return (a.createdAt - b.createdAt) * dir;
    if (a.id === b.id) return 0;
    return (a.id < b.id ? -1 : 1) * dir;
  };
}
