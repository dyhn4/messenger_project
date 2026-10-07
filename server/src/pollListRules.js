// 투표의 순수 규칙 — 투표 목록(`GET /api/polls`) 쿼리 검사·정렬 키, 그리고 투표 DTO(toPollDto)와 소켓 `poll:updated`
// 모양(누가 무엇을 골랐는지가 방 전체에 새지 않게). DB·서버 없이 단위 테스트한다(test/pollList.test.js,
// test/pollAnonymousBroadcast.test.js). 저장소 조회는 db/queries/polls.js(목록은 listPollPanelRows), 요청 처리는 polls.js.
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

/** 마감 여부 — 일찍 마감했거나 마감 시각이 [now]까지 지났으면 마감(polls.js의 isPollClosed가 이 함수를 그대로 쓴다). */
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

// ---- 투표 DTO와 소켓 poll:updated — polls.js(조회·라우트)가 쓰고, 여기서는 DB 없이 모양만 정한다. ----

/**
 * 메시지 DTO에 붙는 `poll` 객체 — 행([poll])·보기([options])·표([votes], 이 투표의 전부)를 받아 조립한다.
 * 익명이면 누가 골랐는지(voters)는 키 자체를 내리지 않고 개수만 낸다. myOptionIds는 [viewerId]가 고른 보기,
 * viewerId가 null이면(소켓 브로드캐스트처럼 모두에게 같은 DTO) 빈 배열이다.
 */
export function toPollDto(poll, options, votes, { viewerId = null, favorite = false } = {}) {
  const votesByOption = new Map();
  for (const v of votes) {
    const list = votesByOption.get(v.optionId) ?? [];
    list.push(v);
    votesByOption.set(v.optionId, list);
  }
  return {
    id: poll.id,
    title: poll.title,
    description: poll.description ?? null,
    anonymous: !!poll.anonymous,
    multiple: !!poll.multiple,
    closesAt: new Date(poll.closesAt).getTime(),
    closedAt: poll.closedAt ? new Date(poll.closedAt).getTime() : null,
    closed: pollIsClosedAt(poll),
    creatorId: poll.creatorId ?? null,
    voterCount: new Set(votes.map((v) => v.userId)).size,
    options: options.map((o) => {
      const optionVotes = votesByOption.get(o.id) ?? [];
      return {
        id: o.id,
        text: o.text,
        voteCount: optionVotes.length,
        ...(poll.anonymous
          ? {}
          : { voters: optionVotes.map((v) => ({ userId: v.userId, name: v.name ?? v.username ?? '알 수 없음' })) }),
      };
    }),
    myOptionIds: viewerId ? votes.filter((v) => v.userId === viewerId).map((v) => v.optionId) : [],
    favorite: !!favorite,
  };
}

/**
 * 방 전체에 보내는 `poll:updated` — [poll]은 viewerId 없이 만든 중립 DTO(집계만, 익명이면 voters 키도 없음)이고,
 * "누가 무엇을 골랐는지"(actorId·actorOptionIds)는 늘 null이다. 앱(Poll.applyUpdate)은 actorId가 자기일 때만 그 값을
 * 쓰므로 다른 사람에게는 필요 없는 값이고, 익명 투표에서는 실으면 익명이 깨진다(S18 — 소켓 프레임만 보면 다 보였다).
 * 기명 투표도 똑같이 비운다 — 누가 골랐는지는 같은 DTO의 voters에 이미 있어서(REST와 같은 규칙) 따로 실을 까닭이 없다.
 * 마감 알림도 이 모양이다.
 */
export function pollRoomUpdate({ roomId, messageId, pollId, poll }) {
  return { roomId, messageId, pollId, poll, actorId: null, actorOptionIds: null };
}

/**
 * 투표하기(재투표·취소 포함) 뒤의 `poll:updated`를 두 벌로 나눠 보낸다 — 같은 집계(중립 DTO [poll])를 싣되 받는 곳이 다르다.
 *  - 방 전체(투표한 사람의 기기는 뺀다): [pollRoomUpdate] — 누가 투표했는지 없이 집계만.
 *  - 투표한 사람의 기기들(`user:<voterId>`): 여기에만 actorId(본인)·actorOptionIds(고른 보기, 취소면 빈 배열)를 더한다 —
 *    다른 기기(PC·폰·웹)도 "내 선택"을 맞추게. 이벤트 이름·모양이 예전 방 알림과 같아서 옛 앱도 그대로 알아듣는다.
 * 투표한 사람의 소켓은 연결하자마자 user 룸에 들어가므로(socket.js) 한 소켓은 둘 중 하나만 받는다. 둘 다 받더라도
 * poll은 그때의 절대값(표 수를 더하는 값이 아니다)이라 표가 두 번 세어지지 않는다. 보낸 두 벌을 돌려준다(테스트용).
 */
export function emitPollVoteUpdate(io, { roomId, messageId, pollId, poll, voterId, optionIds }) {
  const room = pollRoomUpdate({ roomId, messageId, pollId, poll });
  const voter = { ...room, actorId: voterId, actorOptionIds: [...optionIds] };
  io.to(roomId).except(`user:${voterId}`).emit('poll:updated', room);
  io.to(`user:${voterId}`).emit('poll:updated', voter);
  return { room, voter };
}
