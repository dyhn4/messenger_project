// 통합 즐겨찾기의 순수 규칙(쿼리 검사·섞기) — DB 없이 단위 테스트할 수 있게 favorites.js에서 떼어 냈다.

/** 통합 즐겨찾기의 종류 — `GET /api/favorites?type=`. 빼면(또는 'all') 전부 섞어 최근 즐겨찾기순. */
export const FAVORITE_TYPES = ['message', 'file', 'comment', 'poll', 'room', 'member'];
export const FAVORITES_DEFAULT_LIMIT = 30;
export const FAVORITES_MAX_LIMIT = 100;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value) {
  return typeof value === 'string' && UUID_RE.test(value);
}

/**
 * `GET /favorites` 쿼리 검사 — 통과하면 `{ type('all' 또는 FAVORITE_TYPES 중 하나), teamId, before(Date|null), limit }`,
 * 아니면 `{ error }`. limit은 1..100으로 눌러 담고(기본 30), before는 ms 시각(이보다 먼저 담은 것만).
 */
export function parseFavoritesQuery(query) {
  const rawType = typeof query?.type === 'string' && query.type ? query.type : 'all';
  if (rawType !== 'all' && !FAVORITE_TYPES.includes(rawType)) {
    return { error: `type은 ${FAVORITE_TYPES.join('|')} 중 하나여야 합니다.` };
  }
  const teamId = typeof query?.teamId === 'string' ? query.teamId : '';
  if (!isUuid(teamId)) return { error: 'teamId가 필요합니다.' };
  let before = null;
  if (query?.before !== undefined && query.before !== '') {
    const ms = Number(query.before);
    if (!Number.isFinite(ms) || ms <= 0) return { error: 'before는 밀리초 시각이어야 합니다.' };
    before = new Date(ms);
  }
  let limit = FAVORITES_DEFAULT_LIMIT;
  if (query?.limit !== undefined && query.limit !== '') {
    const n = Math.floor(Number(query.limit));
    if (!Number.isFinite(n) || n < 1) return { error: 'limit은 1 이상의 숫자여야 합니다.' };
    limit = Math.min(n, FAVORITES_MAX_LIMIT);
  }
  return { type: rawType, teamId, before, limit };
}

/**
 * 종류별 목록(각각 최근 즐겨찾기순)을 한 줄로 섞어 앞에서 [limit]개만 남긴다. `favoritedAt`(ms)이 없는
 * 항목(대화방)은 여기 오지 않는다. [hasMore]는 섞은 뒤 남은 게 있을 때 true.
 */
export function mergeFavoriteLists(lists, limit) {
  const all = lists.flat().sort((a, b) => b.favoritedAt - a.favoritedAt);
  return { items: all.slice(0, limit), hasMore: all.length > limit };
}
