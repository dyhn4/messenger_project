// 투표 목록(`GET /api/polls`)의 순수 규칙 — 쿼리 검사. DB·서버 없이 단위 테스트한다(test/pollList.test.js).
// 저장소 조회는 db/queries/polls.js의 listPollPanelRows, 요청 처리는 polls.js.
import { isUuid, parseCursor, parseLimit, parseTimeBound } from './pageCursor.js';

export const POLL_STATUSES = ['all', 'open', 'closed'];
export const POLL_PARTICIPATION = ['all', 'yes', 'no'];
export const POLL_SORTS = ['created', 'deadline'];
export const POLL_LIST_DEFAULT_LIMIT = 20;
export const POLL_LIST_MAX_LIMIT = 50;

/**
 * 기한 순(`sort=deadline`) 정렬 키에서 마감된 투표 쪽의 기준값 — 마감된 투표의 키는 `이 값 - 끝난 시각(ms)`이라 진행 중인
 * 투표의 키(마감 시각 ms, 서기 2100년 전이면 4.2e12 아래)보다 늘 크고, 끝난 시각이 최근일수록 작다. 2^53 아래라 JS 숫자로도 정확하다.
 */
export const DEADLINE_CLOSED_BASE = 100_000_000_000_000; // 1e14

/**
 * 쿼리 검사 — 통과하면
 * `{ teamId, roomId|null, status, creatorId|null, participated, since|null, until|null, sort, order, cursor|null, limit }`,
 * 아니면 `{ error }`. status는 all|open|closed(기본 all), participated는 all|yes|no(기본 all), order는 desc|asc(기본 desc),
 * since/until은 투표를 만든 시각(밀리초) — 안 주면 기간 제한 없음(전체 기간), limit은 1..50(기본 20).
 * sort는 created(기본 — 만든 시각, order 방향) | deadline(기한 순 — [pollDeadlineKey] 오름차순, order는 무시).
 * before 커서는 두 정렬 모두 "<정렬 키>:<pollId>" — created면 키가 만든 시각(ms), deadline이면 [pollDeadlineKey]다.
 */
export function parsePollListQuery(query) {
  const q = query ?? {};
  const teamId = typeof q.teamId === 'string' ? q.teamId : '';
  if (!isUuid(teamId)) return { error: 'teamId가 필요합니다.' };

  const status = typeof q.status === 'string' && q.status ? q.status : 'all';
  if (!POLL_STATUSES.includes(status)) return { error: `status는 ${POLL_STATUSES.join('|')} 중 하나여야 합니다.` };
  const participated = typeof q.participated === 'string' && q.participated ? q.participated : 'all';
  if (!POLL_PARTICIPATION.includes(participated)) {
    return { error: `participated는 ${POLL_PARTICIPATION.join('|')} 중 하나여야 합니다.` };
  }
  if (q.order !== undefined && q.order !== '' && q.order !== 'asc' && q.order !== 'desc') {
    return { error: 'order는 asc|desc 중 하나여야 합니다.' };
  }
  const order = q.order === 'asc' ? 'asc' : 'desc';
  const sort = typeof q.sort === 'string' && q.sort ? q.sort : 'created';
  if (!POLL_SORTS.includes(sort)) return { error: `sort는 ${POLL_SORTS.join('|')} 중 하나여야 합니다.` };

  let roomId = null;
  if (q.roomId !== undefined && q.roomId !== '') {
    if (typeof q.roomId !== 'string') return { error: 'roomId가 올바르지 않습니다.' };
    roomId = q.roomId;
  }
  let creatorId = null;
  if (q.creatorId !== undefined && q.creatorId !== '') {
    if (!isUuid(q.creatorId)) return { error: 'creatorId가 올바르지 않습니다.' };
    creatorId = q.creatorId;
  }

  const since = parseTimeBound(q.since);
  if (since === undefined) return { error: 'since는 밀리초 시각이어야 합니다.' };
  const until = parseTimeBound(q.until);
  if (until === undefined) return { error: 'until은 밀리초 시각이어야 합니다.' };

  const cursor = parseCursor(q.before);
  if (cursor?.error) return { error: cursor.error };
  const limit = parseLimit(q.limit, { fallback: POLL_LIST_DEFAULT_LIMIT, max: POLL_LIST_MAX_LIMIT });
  if (limit === null) return { error: 'limit은 1 이상의 숫자여야 합니다.' };

  return { teamId, roomId, status, creatorId, participated, since, until, sort, order, cursor, limit };
}

/** 마감 여부 — 일찍 마감했거나 마감 시각이 [now]까지 지났으면 마감(polls.js의 isPollClosed와 같은 기준). */
export function pollIsClosedAt(poll, now = Date.now()) {
  return !!poll.closedAt || new Date(poll.closesAt).getTime() <= now;
}

/** 투표가 실제로 끝나는(끝난) 시각(ms) — 일찍 마감했으면 마감한 시각, 아니면 마감 시각(둘 중 이른 쪽). 밀리초로 자른다. */
export function pollEndMs(poll) {
  const closes = new Date(poll.closesAt).getTime();
  const closed = poll.closedAt ? new Date(poll.closedAt).getTime() : closes;
  return Math.trunc(Math.min(closed, closes));
}

/**
 * 기한 순 정렬 키(작을수록 앞) — 진행 중인 투표가 먼저 마감이 가까운 순(키 = 마감 시각 ms)으로 오고, 그 뒤에 마감된 투표가
 * 최근에 끝난 순(키 = [DEADLINE_CLOSED_BASE] - 끝난 시각 ms)으로 온다. 같은 키는 pollId 오름차순. SQL(db/queries/polls.js의
 * listPollPanelRows)도 같은 식이다. 진행 중/마감 구분이 [now]에 달려 있어서, 쪽을 넘기는 사이 마감된 투표는 마감 쪽에서 한 번
 * 더 보일 수 있다(클라이언트가 메시지 id로 겹친 것을 거른다) — 빠지는 투표는 없다.
 */
export function pollDeadlineKey(poll, now = Date.now()) {
  const end = pollEndMs(poll);
  return pollIsClosedAt(poll, now) ? DEADLINE_CLOSED_BASE - end : end;
}

/** 기한 순 비교 함수 — `{ id, closesAt, closedAt }`들을 [pollDeadlineKey] → id 순으로. */
export function compareByDeadline(now = Date.now()) {
  return (a, b) => {
    const ka = pollDeadlineKey(a, now);
    const kb = pollDeadlineKey(b, now);
    if (ka !== kb) return ka - kb;
    if (a.id === b.id) return 0;
    return a.id < b.id ? -1 : 1;
  };
}

/**
 * 목록 필터를 한 투표에 적용해 본 결과 — SQL 조건과 같은 규칙이라, 규칙을 바꿀 때 단위 테스트로 맞춰 본다.
 * [poll]은 `{ createdAt, closedAt, closesAt, creatorId, roomId }`, [votedByMe]는 내가 투표했는지.
 */
export function pollMatchesFilter(poll, q, { votedByMe = false, now = Date.now() } = {}) {
  if (q.roomId && poll.roomId !== q.roomId) return false;
  if (q.creatorId && poll.creatorId !== q.creatorId) return false;
  const closed = pollIsClosedAt(poll, now);
  if (q.status === 'open' && closed) return false;
  if (q.status === 'closed' && !closed) return false;
  if (q.participated === 'yes' && !votedByMe) return false;
  if (q.participated === 'no' && votedByMe) return false;
  const created = new Date(poll.createdAt).getTime();
  if (q.since && created < q.since.getTime()) return false;
  if (q.until && created > q.until.getTime()) return false;
  return true;
}
