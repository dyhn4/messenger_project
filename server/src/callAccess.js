import { minutesText, RateLimiter } from './authGuard.js';
import { callStateFor, isInCall, joinCall, refreshVideoTiers, removeUserFromCalls } from './callState.js';
import { SELF_ROOM_DENIAL, topicWriteDenial } from './permissions.js';

/**
 * 화상회의에 "누가 들어와 있을 수 있는지" — 들어올 때의 규칙(토큰 발급 calls.js와 소켓 call:join socket.js가 같이 쓴다)과,
 * 자격을 잃은 사람을 진행 중인 통화에서 내보내기(endUserCallAccess) · 내보낸 뒤 남은 토큰으로 다시 붙는 연결 막기.
 *
 * 미디어는 클라이언트와 LiveKit이 직접 주고받아서, 방 멤버인지는 LiveKit 토큰을 줄 때 한 번만 본다(calls.js). 그래서 방에서
 * 내보내지거나 계정이 정지된 사람의 이미 붙은 미디어는 여기서 LiveKit에 내보내라고 하지 않으면 그 사람이 스스로 나갈 때까지
 * 계속 오가고, 소켓 call:join은 토큰 없이도 보낼 수 있어서 같은 규칙을 다시 걸어야 한다.
 *
 * DB를 직접 읽지 않는다 — 실제 LiveKit 클라이언트와 화상회의 카드(DB)는 내보낼 때만 불러온다(endUserCallAccess). 그래서
 * 규칙과 내보내기의 상태 변화를 단위 테스트가 가짜 LiveKit으로 그대로 돌린다(test/callGates.test.js, test/callAccess.test.js).
 */

const MIN = 60 * 1000;

// ── 들어올 때의 규칙 ─────────────────────────────────────────────────────

export const SECRET_ROOM_CALL_DENIAL = '비밀 대화에서는 아직 화상회의를 쓸 수 없습니다.';

/**
 * 이 방에서 화상회의를 아예 쓸 수 없으면 그 문구(쓸 수 있으면 null). 비밀 대화(E2EE)는 서버가 내용을 볼 수 없어야 하는데
 * SFU는 미디어를 풀어서 중계하는 구성요소라 그 약속이 깨지고(LiveKit의 E2EE로 나중에 열 수 있다), 나와의 대화는 회의할
 * 상대가 없다. 예전엔 토큰 발급만 막고 call:join은 막지 않아서, 비밀 대화에 평문 카드가 남고 isSecret 없이 전화 푸시가 갔다.
 */
export function callRoomDenial(room) {
  if (room.isSecret) return SECRET_ROOM_CALL_DENIAL;
  if (room.isSelf) return SELF_ROOM_DENIAL;
  return null;
}

/** 읽기 전용·보관된 토픽인지 — 여기서만 통화 시작에 토픽 관리 권한이 필요해서, 이때만 권한(DB)을 조회한다. */
export function isRestrictedTopic(room) {
  return room.type === 'topic' && !!(room.readOnly || room.archivedAt);
}

/**
 * 통화를 **시작**할 때(진행 중인 통화가 없을 때)의 거절 문구(괜찮으면 null) — 읽기 전용·보관된 토픽은 글쓰기와 같이 토픽을
 * 관리할 수 있는 사람만(permissions.js topicWriteDenial과 같은 판단). 통화를 시작하면 대화에 카드가 올라가고 방 전원에게
 * 전화가 울려서, 글을 못 쓰는 사람이 이걸로 공지 토픽 전체를 울리면 안 된다. 이미 진행 중인 통화(관리자가 연 회의)에
 * 합류하는 건 막지 않는다 — 공지 토픽의 전체 회의에 멤버가 들어오는 게 자연스럽고, 합류는 누구도 울리지 않는다.
 */
export function callStartDenial({ room, canManage }) {
  if (!topicWriteDenial({ room, canManage })) return null;
  return room.archivedAt
    ? '보관된 토픽에서는 토픽 관리자만 화상회의를 시작할 수 있습니다.'
    : '읽기 전용 토픽에서는 토픽 관리자만 화상회의를 시작할 수 있습니다.';
}

// ── 참가 토큰 발급 기록 ─────────────────────────────────────────────────
//
// call:join은 LiveKit에 연결한 뒤에 보내는 신호라, 토큰을 받은 적도 없이(미디어 연결 없이) call:join/call:leave만 되풀이해
// 카드와 전화를 계속 만들 수 있었다. 그래서 call:join은 ①방금(토큰 유효 시간 안에) 이 방 토큰을 받았거나 ②이미 이 방
// 통화에 들어와 있거나(다른 기기, 잠깐 끊겼다 다시 알림) ③실제로 이 방 LiveKit에 연결돼 있을 때만 받는다(admitCallJoin).
// ③은 소켓이 끊김 유예(CALL_DISCONNECT_GRACE_MS)보다 오래 끊겼다가, 또는 서버가 재시작된 뒤에 몇 시간 지난 통화에
// 참여를 다시 알리는 경우다(client session.dart _reannounceCall) — 그때는 토큰이 오래됐고 메모리 기록도 없다.

/**
 * LiveKit 참가 토큰의 유효 시간 — calls.js가 이 값으로 발급한다(입장권이라 짧게, 통화 중 만료돼도 연결은 그대로다 — 붙어
 * 있는 동안은 LiveKit이 새 토큰을 내려 준다). 더 줄이지 않은 건, LiveKit이 연결 직후에 새 토큰을 바로 주지 않으면 통화
 * 초반의 재연결(와이파이↔LTE 전환 등)이 만료된 처음 토큰으로 시도되다 실패하기 때문이다 — 그 대신 자격을 잃은 사람의
 * 남은 토큰은 만료될 때까지 따로 지켜본다(아래 "다시 붙는 연결 막기").
 */
export const CALL_TOKEN_TTL_MS = 10 * MIN;

/**
 * `${userId}:${roomId}` → { at: 마지막으로 그 방 토큰을 준 시각, used: 그 토큰으로 이미 참여했는지 }. 서버 메모리에만
 * 둔다(재시작하면 ③으로 확인한다). 참여한 뒤에도 시각은 남겨 둔다 — 자격을 잃은 뒤 다시 얻었는지 볼 때 쓴다(tokenIssuedAfter).
 */
const issuedTokens = new Map();

const pairKey = (userId, roomId) => `${userId}:${roomId}`;

/** 토큰을 발급했다(calls.js). */
export function recordCallToken(userId, roomId, now = Date.now()) {
  issuedTokens.set(pairKey(userId, roomId), { at: now, used: false });
}

/** 이 사람에게 이 방 토큰을 유효 시간 안에 줬고 아직 그 토큰으로 참여하지 않았는지. */
export function hasCallToken(userId, roomId, now = Date.now()) {
  const issued = issuedTokens.get(pairKey(userId, roomId));
  return !!issued && !issued.used && now - issued.at <= CALL_TOKEN_TTL_MS;
}

/** 토큰으로 통화에 들어왔다 — 한 번 받은 토큰으로 call:join을 되풀이하지 못하게 쓴 것으로 표시한다(다시 들어올 땐 앱이 새로 받는다). */
export function consumeCallToken(userId, roomId) {
  const issued = issuedTokens.get(pairKey(userId, roomId));
  if (issued) issued.used = true;
}

/** [since] 뒤에 이 사람에게 이 방 토큰을 새로 줬는지 — 토큰 발급은 방 멤버·계정을 그때 확인하므로, 자격을 다시 얻었다는 뜻이다. */
export function tokenIssuedAfter(userId, roomId, since) {
  const issued = issuedTokens.get(pairKey(userId, roomId));
  return !!issued && issued.at > since;
}

/** 자격을 잃은 사람의 발급 기록을 지운다 — [roomIds]를 주면 그 방들만, 생략하면 모든 방(id는 콜론 없는 UUID다). */
function forgetCallTokens(userId, roomIds) {
  if (roomIds) {
    for (const roomId of roomIds) issuedTokens.delete(pairKey(userId, roomId));
    return;
  }
  const prefix = `${userId}:`;
  for (const key of issuedTokens.keys()) if (key.startsWith(prefix)) issuedTokens.delete(key);
}

/** 없어진 방(토픽 삭제)의 발급 기록을 모두 지운다. */
function forgetRoomCallTokens(roomId) {
  const suffix = `:${roomId}`;
  for (const key of issuedTokens.keys()) if (key.endsWith(suffix)) issuedTokens.delete(key);
}

// ── 통화 시작 횟수 제한 ─────────────────────────────────────────────────
//
// 통화를 시작할 때마다 대화에 카드가 올라가고 방 전원(앱이 꺼진 사람은 푸시, 켜진 사람은 수신 창)에게 전화가 울린다.
// 시작·끊기를 되풀이해 방 전체를 계속 울리지 못하게, 실제로 통화를 시작한 횟수를 사람·방마다, 그리고 사람마다 센다.
// 안 받는 상대에게 몇 번 다시 거는 정도(10분에 같은 방 5번, 여러 방 합쳐 20번)는 걸리지 않는다. 합류와, 서버가 잃었던
// 통화를 되살리는 것(아무도 울리지 않는다)은 세지 않는다.

export const CALL_START_WINDOW_MS = 10 * MIN;
export const CALL_START_MAX_PER_ROOM = 5;
export const CALL_START_MAX_PER_USER = 20;

/** 세지 않고 "지금 한 번 더 세면 막히는지"도 볼 수 있는 RateLimiter — 토큰 발급은 미리 보기만 하고, 세는 건 call:join이다. */
class PeekableRateLimiter extends RateLimiter {
  /** 지금 한 번 더 오면 막힐 때 남은 ms(아니면 0). 세지 않는다. */
  waitFor(key) {
    const e = this.entries.get(key);
    const t = this.now();
    return e && e.resetAt > t && e.count >= this.max ? e.resetAt - t : 0;
  }
}

/** 통화 시작 제한 한 벌 — 서버는 아래 기본 하나를 쓰고, 테스트는 가짜 시계로 따로 만든다. */
export function createCallStartLimiter({
  now = () => Date.now(),
  windowMs = CALL_START_WINDOW_MS,
  maxPerRoom = CALL_START_MAX_PER_ROOM,
  maxPerUser = CALL_START_MAX_PER_USER,
} = {}) {
  const perRoom = new PeekableRateLimiter({ max: maxPerRoom, windowMs, now });
  const perUser = new PeekableRateLimiter({ max: maxPerUser, windowMs, now });
  const waitFor = (userId, roomId) => Math.max(perRoom.waitFor(pairKey(userId, roomId)), perUser.waitFor(userId));
  return {
    /** 지금 이 방에서 통화를 시작하면 막히는지 — 남은 ms(아니면 0). 세지 않는다(토큰 발급이 미리 알려 줄 때). */
    waitFor,
    /** 통화를 시작한다 — 막히면 남은 ms를 돌려주고 세지 않는다, 아니면 한 번 세고 0. */
    hit(userId, roomId) {
      const wait = waitFor(userId, roomId);
      if (wait > 0) return wait;
      perRoom.hit(pairKey(userId, roomId));
      perUser.hit(userId);
      return 0;
    },
    prune() {
      perRoom.prune();
      perUser.prune();
    },
  };
}

const callStarts = createCallStartLimiter();

/** 지금 [roomId]에서 통화를 시작하면 막히는지(남은 ms, 아니면 0) — 세지 않는다(토큰 발급 calls.js). 세는 건 admitCallJoin. */
export function callStartWait(userId, roomId) {
  return callStarts.waitFor(userId, roomId);
}

/** 막혔을 때 앱에 보여 줄 문구 — 토큰 발급의 429(authGuard.js tooMany)와 같은 말. */
export function callStartLimitText(ms) {
  return `화상회의 시도가 너무 많습니다. ${minutesText(ms)} 후 다시 시도하세요.`;
}

// ── LiveKit 확인까지 가는 call:join 횟수 제한 ───────────────────────────
//
// 토큰도 통화 상태도 없는 call:join은 방·멤버·계정을 DB로 보고 LiveKit에도 물어본다(최대 5초 — calls.js). 정상 앱이 여기까지
// 오는 건 소켓이 오래 끊겼다 붙었거나 서버가 재시작된 뒤 참여를 다시 알릴 때뿐이라 1분에 한두 번도 안 된다. 미디어 연결은
// 그대로 둔 채 call:leave/call:join만 되풀이하거나(그때마다 카드에 나감·참여가 붙고 방 전체에 상태가 나간다), 아무 방에나
// call:join을 쏟아부어 DB 조회와 LiveKit 요청을 계속 일으키지 못하게 사람마다 센다.

export const CALL_JOIN_PROOF_MAX_PER_MIN = 10;

const joinProofs = new RateLimiter({ max: CALL_JOIN_PROOF_MAX_PER_MIN, windowMs: MIN });

/**
 * 이 call:join이 LiveKit 확인까지 가야 하는 시도(이 방 통화에 없고 쓸 수 있는 토큰도 없음)면 한 번 세고, 너무 잦으면 남은
 * ms(아니면 0) — socket.js가 DB를 보기 전에 부른다. 이미 통화에 있는 사람의 다시 알림과 방금 토큰을 받은 참여는 세지 않는다.
 */
export function callJoinProofWait(userId, roomId, { limiter = joinProofs, now = Date.now() } = {}) {
  if (isInCall(roomId, userId) || hasCallToken(userId, roomId, now)) return 0;
  return limiter.hit(userId);
}

/** LiveKit 확인까지 가는 call:join이 너무 잦을 때 앱에 보여 줄 문구. */
export function callJoinProofLimitText(ms) {
  return `화상회의 참여 시도가 너무 많습니다. ${minutesText(ms)} 후 다시 시도하세요.`;
}

setInterval(() => {
  callStarts.prune();
  joinProofs.prune();
  const t = Date.now();
  for (const [key, issued] of issuedTokens) if (t - issued.at > CALL_TOKEN_TTL_MS) issuedTokens.delete(key);
}, CALL_TOKEN_TTL_MS).unref();

// ── call:join 받아들이기 ────────────────────────────────────────────────

export const CALL_JOIN_UNVERIFIED = '화상회의 연결을 확인하지 못했습니다. 다시 참여해 주세요.';

/**
 * 소켓 call:join을 받아들일지 정하고, 받아들이면 통화 상태에 넣는다(callState.js joinCall) — socket.js가 방 멤버·계정·토픽
 * 관리 권한([canManage] — 읽기 전용·보관 토픽일 때만 조회, 아니면 true)을 DB로 본 뒤 부른다. 순서:
 *   1) 화상회의를 쓸 수 없는 방(비밀 대화·나와의 대화)이면 거절.
 *   2) 참가 자격 — 이미 이 통화에 들어와 있거나(다른 기기, 잠깐 끊겼다 다시 알림), 방금 이 방 토큰을 받았거나, 실제로 이 방
 *      LiveKit에 연결돼 있거나([livekitHas] — 끊김 유예보다 오래 끊겼다 다시 알림, 서버 재시작 뒤). 앞의 둘은 메모리만 보고,
 *      둘 다 아닐 때만 LiveKit에 묻는다.
 *   3) 진행 중인 통화가 없을 때:
 *      - 방금 받은 토큰으로 왔으면 통화 **시작**이다 — 읽기 전용·보관 토픽은 토픽 관리자만, 너무 자주는 안 된다(세는 것도 여기).
 *      - LiveKit 연결로만 확인됐으면 서버가 잃었던 통화를 **되살리는** 것이다 — 서버가 재시작됐거나, 혼자 남아 있던 사람의
 *        소켓이 끊김 유예보다 오래 끊겨 통화가 끝난 것으로 정리됐을 뿐 회의는 LiveKit에서 그대로 이어지고 있다. 그 연결은
 *        처음 들어올 때 이미 규칙을 통과했으니 시작 규칙(읽기 전용 토픽의 멤버 거절·횟수)을 다시 걸지 않는다 — 걸면 관리자가
 *        연 공지 토픽 회의가 서버 재시작 한 번에 멤버들 쪽에서 모두 끊긴다. 대신 아무도 울리지 않는다: 새 카드도 전화
 *        푸시도 없고(socket.js), 상태에 restored가 붙어 앱도 울리지 않는다(callState.js).
 *   4) 토큰이 있었으면 쓴 것으로 표시한다(같은 토큰으로 call:join을 되풀이하지 못하게 — 다시 들어올 땐 앱이 새로 받는다).
 * 3)부터 통화 상태에 넣기까지는 await 없이 한 번에 한다 — 사이에 다른 참가·퇴장이 끼어 "시작인지"가 바뀌지 않게.
 * 결과: 받아들이면 { ok: true, state, wasIn, restored }(wasIn — 이미 들어와 있던 사람이 참여를 다시 알린 것, restored —
 * 이 참여로 통화를 되살린 것), 아니면 { ok: false, error }.
 */
export async function admitCallJoin({
  room,
  userId,
  socketId,
  canManage,
  livekitHas,
  limiter = callStarts,
  now = () => Date.now(),
}) {
  const roomDenial = callRoomDenial(room);
  if (roomDenial) return { ok: false, error: roomDenial };
  const inCall = isInCall(room.id, userId);
  const viaToken = !inCall && hasCallToken(userId, room.id, now());
  if (!inCall && !viaToken && !(await livekitHas(room.id, userId))) {
    return { ok: false, error: CALL_JOIN_UNVERIFIED };
  }

  // LiveKit에 묻는 동안(await) 통화가 끝났거나 누가 시작했을 수 있어서 지금 상태를 다시 본다.
  const before = callStateFor(room.id);
  const wasIn = before.participantIds.includes(userId);
  const restored = !before.active && !viaToken;
  if (!before.active && viaToken) {
    const startDenial = callStartDenial({ room, canManage });
    if (startDenial) return { ok: false, error: startDenial };
    const wait = limiter.hit(userId, room.id);
    if (wait > 0) return { ok: false, error: callStartLimitText(wait) };
  }
  consumeCallToken(userId, room.id);
  return { ok: true, wasIn, restored, state: joinCall(room.id, userId, socketId, { restored }) };
}

// ── 자격을 잃은 사람 내보내기 ───────────────────────────────────────────

/** LiveKit API가 "그런 방/참가자 없음"으로 답했는지 — 내보낼 사람이 이미 없는 것이라 실패가 아니다. */
export function isLivekitNotFound(err) {
  return err?.status === 404 || err?.code === 'not_found';
}

/**
 * 서버 전체 통화 참가자 수가 바뀌어 화질 단계가 달라진 **다른** 통화들에 새 상태를 다시 알린다(callQuality.js) — 참가·
 * 퇴장한 그 방은 호출부가 이미 알렸다.
 */
export function emitVideoTierChanges(io) {
  for (const state of refreshVideoTiers()) io.to(state.roomId).emit('call:state', state);
}

/**
 * LiveKit 토큰 무효화 기준 시각(초) — 이 시각 전에 받은 토큰(nbf가 더 이른 것)으로는 그 방에 다시 못 들어온다. 비워 두면
 * LiveKit이 "지금+1분"을 쓰는데, 그러면 그 1분 안에 다시 초대·로그인해 새로 받은 토큰까지 막힌다. 토큰을 서명하는 것도
 * 이 서버 시계라(calls.js — nbf = 발급 시각) 같은 시계로 1초 뒤를 준다.
 */
function revokeTokensBefore(nowMs) {
  return BigInt(Math.floor(nowMs / 1000) + 1);
}

// ── 자격을 잃은 뒤 남은 토큰으로 다시 붙는 연결 막기 ─────────────────────
//
// 내보낼 때(removeFromCallsWith) 그때 LiveKit에 붙어 있던 연결은 끊고 그 전에 받은 토큰을 무효로 하지만(revokeTokenTs —
// LiveKit은 이 값을 참가자를 내보낼 때만 쓴다), 토큰만 받아 두고 아직 붙지 않았던 사람은 LiveKit이 모르는 참가자라 무효가
// 남지 않는다. 그 토큰은 받은 뒤 CALL_TOKEN_TTL_MS 동안 유효해서, 앱을 고쳐 call:join 없이 LiveKit에 바로 붙으면 서버가 다시
// 보지 않는 한 회의를 끝까지 듣는다(토픽이 지워졌어도 LiveKit은 들어올 때 방을 새로 만든다). 그래서 내보낸 뒤 그 토큰들이
// 모두 만료될 때까지 잠깐마다 열린 회의방을 보고, 그 사람이 다시 붙어 있으면 또 내보내고(그 시각까지의 토큰도 무효로),
// 지워진 방이 다시 열렸으면 방째 닫는다. 내보낼 때 LiveKit이 잠깐 응답하지 않아 못 끊은 연결도 이렇게 다시 끊긴다. 그 사이
// 자격을 다시 얻어(다시 초대됨·정지 해제) 새 토큰을 받은 사람은 건드리지 않는다(tokenIssuedAfter — 토큰 발급이 그때
// 멤버·계정을 확인했다).

/** 다시 붙는 연결을 얼마나 자주 보는지 — 남은 토큰으로 붙어도 이만큼 안에 끊긴다. */
export const CALL_REVOKE_SWEEP_MS = 5_000;

/** 얼마 동안 지켜보는지 — 자격을 잃기 전에 받은 토큰이 모두 만료될 때까지(+ LiveKit과의 시계 차이 여유). */
export const CALL_REVOKE_WINDOW_MS = CALL_TOKEN_TTL_MS + 30_000;

/**
 * 지켜볼 목록 한 벌 — 서버는 아래 기본 하나를 쓰고(endUserCallAccess가 넣고 타이머가 훑는다), 테스트는 따로 만들어 가짜
 * LiveKit으로 [sweep]을 직접 부른다.
 */
export function createCallRevocations({ windowMs = CALL_REVOKE_WINDOW_MS } = {}) {
  /** { userId, rooms: Set|null(모든 방), exempt: Set(자격을 다시 얻은 방), since, until } 또는 { roomId, since, until }. */
  let watches = [];

  /** 열린 LiveKit 방 하나를 본다 — 지워진 방이면 닫고, 아니면 지켜보는 사람 중 다시 붙은 사람을 내보낸다. */
  async function sweepRoom(livekit, room, revokeTokenTs) {
    const name = room.name;
    if (watches.some((w) => w.roomId === name)) {
      await livekit.deleteRoom(name).then(
        () => console.warn('[call] 지워진 방의 화상회의가 다시 열려 닫았습니다:', name),
        (err) => {
          if (!isLivekitNotFound(err)) console.error('[call] LiveKit 방 닫기 실패:', name, err?.message ?? err);
        },
      );
      return;
    }
    if (room.numParticipants === 0) return;
    const targets = watches.filter((w) => w.userId && (!w.rooms || w.rooms.has(name)) && !w.exempt.has(name));
    if (targets.length === 0) return;

    let participants;
    try {
      participants = await livekit.listParticipants(name);
    } catch (err) {
      if (!isLivekitNotFound(err)) console.error('[call] LiveKit 참가자 목록 조회 실패:', name, err?.message ?? err);
      return;
    }
    const present = new Set(participants.map((p) => p.identity));
    const remove = new Set();
    for (const w of targets) {
      if (!present.has(w.userId) || remove.has(w.userId)) continue;
      // 그 뒤에 이 방 토큰을 새로 받았으면 자격을 다시 얻은 것 — 이 감시로는 이 방을 더 보지 않는다.
      if (tokenIssuedAfter(w.userId, name, w.since)) {
        w.exempt.add(name);
        continue;
      }
      remove.add(w.userId);
    }
    await Promise.all(
      [...remove].map((userId) =>
        livekit.removeParticipant(name, userId, { revokeTokenTs }).then(
          () => console.warn('[call] 통화 자격을 잃은 사람이 회의에 다시(또는 아직) 붙어 있어 내보냈습니다:', name, userId),
          (err) => {
            if (!isLivekitNotFound(err)) {
              console.error('[call] LiveKit에서 참가자 내보내기 실패:', name, userId, err?.message ?? err);
            }
          },
        ),
      ),
    );
  }

  return {
    /** 아직 지켜보는 항목 수(만료된 것은 다음 [sweep]에서 빠진다). */
    get size() {
      return watches.length;
    },
    /** [userId]가 [now]에 [roomIds](생략하면 모든 방)의 통화 자격을 잃었다. */
    watchUser(userId, roomIds, now) {
      watches.push({ userId, rooms: roomIds ? new Set(roomIds) : null, exempt: new Set(), since: now, until: now + windowMs });
    },
    /** [roomId] 방이 [now]에 없어졌다(토픽 삭제). */
    watchRoom(roomId, now) {
      watches.push({ roomId, since: now, until: now + windowMs });
    },
    /**
     * 한 번 훑는다 — 만료된 항목을 빼고, 열린 LiveKit 방들을 본다. [livekit]이 없으면(화상회의가 설정 안 된 서버) 지켜볼
     * 것도 없다. LiveKit 방 목록을 못 받으면 던진다(다음 차례에 다시 본다) — 방 하나의 실패는 남기고 나머지는 계속한다.
     */
    async sweep(livekit, now) {
      watches = livekit ? watches.filter((w) => w.until > now) : [];
      if (watches.length === 0) return;
      const rooms = await livekit.listRooms();
      const revokeTokenTs = revokeTokensBefore(now);
      await Promise.all(rooms.map((room) => sweepRoom(livekit, room, revokeTokenTs)));
    },
  };
}

const callRevocations = createCallRevocations();
let sweepTimer = null;
let sweeping = false;

/** 지켜볼 것이 생겼다 — 타이머가 없으면 띄운다(다 만료되면 스스로 멈춘다). */
function startRevocationSweep() {
  if (sweepTimer) return;
  sweepTimer = setInterval(() => void runRevocationSweep(), CALL_REVOKE_SWEEP_MS);
  sweepTimer.unref();
}

async function runRevocationSweep() {
  if (sweeping) return; // LiveKit이 느려 앞 차례가 아직 안 끝났으면 건너뛴다.
  sweeping = true;
  try {
    const { livekitRoomService } = await import('./calls.js');
    await callRevocations.sweep(livekitRoomService(), Date.now());
  } catch (err) {
    console.error('[call] 통화 자격을 잃은 사람의 연결 확인 실패(다음 차례에 다시 봅니다):', err?.message ?? err);
  } finally {
    sweeping = false;
    if (callRevocations.size === 0 && sweepTimer) {
      clearInterval(sweepTimer);
      sweepTimer = null;
    }
  }
}

/** 서버가 쓰는 지켜볼 목록 — 넣을 때 타이머도 띄운다. */
const liveRevocations = {
  watchUser(userId, roomIds, now) {
    callRevocations.watchUser(userId, roomIds, now);
    startRevocationSweep();
  },
  watchRoom(roomId, now) {
    callRevocations.watchRoom(roomId, now);
    startRevocationSweep();
  },
};

/**
 * endUserCallAccess의 본체 — 실제 LiveKit 클라이언트([livekit] — RoomServiceClient 또는 같은 모양의 가짜, 화상회의가 설정 안
 * 된 서버면 null), 카드 정리([afterLeave] — callCards.js postCallLeft), 지켜볼 목록([revocations] — createCallRevocations
 * 모양)을 받는다. 순서:
 *   1) 메모리 상태(callState.js)에서 그 사람을 모든 기기째 빼고 바뀐 상태를 방에 알린다 — LiveKit이 꺼져 있거나 늦어도
 *      참가자 목록·진행자(마이크 제어 권한)는 바로 맞는다. 진행자였으면 보통 나가기처럼 남은 사람 중 먼저 들어온 사람에게.
 *      아직 안 쓴 토큰 발급 기록도 지운다.
 *   2) LiveKit에서 내보낸다 — 우리 상태에 없어도(call:join 없이 미디어만 붙었거나, 끊김 유예 뒤 상태에서 빠졌어도) 연결돼
 *      있을 수 있어서, 지금 열린 LiveKit 방(범위 안)에서 모두 뺀다. 실패하면 남기고 계속한다. 그리고 남은 토큰이 만료될
 *      때까지 다시 붙는지 지켜본다(위 "다시 붙는 연결 막기").
 *   3) 화상회의 카드에 보통 나가기처럼 "나감"을 붙이고, 그걸로 통화가 끝났으면 카드를 닫는다.
 * 바뀐 통화 상태들을 돌려준다.
 */
export async function removeFromCallsWith({ livekit, afterLeave, revocations, now = () => Date.now() }, io, userId, { roomIds } = {}) {
  if (Array.isArray(roomIds) && roomIds.length === 0) return [];
  const at = now();
  const only = roomIds ? new Set(roomIds) : null;

  forgetCallTokens(userId, roomIds);
  const states = removeUserFromCalls(userId, { roomIds });
  for (const state of states) io.to(state.roomId).emit('call:state', state);
  if (states.length > 0) emitVideoTierChanges(io);

  if (livekit) {
    revocations?.watchUser(userId, roomIds, at);
    const targets = new Set(states.map((s) => s.roomId));
    try {
      // 이름을 주면 그중 열린 방만, 안 주면(빈 배열이 아니라 undefined) 열린 방 전부를 돌려준다.
      for (const r of await livekit.listRooms(roomIds)) {
        if ((!only || only.has(r.name)) && r.numParticipants !== 0) targets.add(r.name);
      }
    } catch (err) {
      console.error('[call] LiveKit 방 목록 조회 실패(우리 통화 상태에 있던 방에서만 내보냅니다):', err?.message ?? err);
    }
    const revokeTokenTs = revokeTokensBefore(at);
    await Promise.all(
      [...targets].map((roomName) =>
        livekit.removeParticipant(roomName, userId, { revokeTokenTs }).catch((err) => {
          if (!isLivekitNotFound(err)) {
            console.error('[call] LiveKit에서 참가자 내보내기 실패:', roomName, userId, err?.message ?? err);
          }
        }),
      ),
    );
  }

  for (const state of states) {
    await Promise.resolve(afterLeave(io, state, userId, true)).catch((err) =>
      console.error('[call] 통화 기록 남기기 실패:', err?.message ?? err),
    );
  }
  return states;
}

/**
 * 방이 통째로 없어질 때(토픽 삭제) 그 방 통화를 끝낸다 — 모두를 메모리 상태에서 빼고, LiveKit 방째 닫고(call:join 없이 붙은
 * 연결까지 끊긴다), 카드를 닫는다(메모리의 진행 중 카드를 치운다 — 메시지는 방과 함께 지워진다). 남은 토큰으로 방이 다시
 * 열리면 닫도록 지켜본다.
 */
export async function endRoomCallWith({ livekit, afterLeave, revocations, now = () => Date.now() }, io, roomId) {
  forgetRoomCallTokens(roomId);
  let last = null;
  for (const userId of callStateFor(roomId).participantIds) {
    for (const state of removeUserFromCalls(userId, { roomIds: [roomId] })) last = { userId, state };
  }
  if (last) {
    io.to(roomId).emit('call:state', last.state);
    emitVideoTierChanges(io);
  }
  if (livekit) {
    revocations?.watchRoom(roomId, now());
    await livekit.deleteRoom(roomId).catch((err) => {
      if (!isLivekitNotFound(err)) console.error('[call] LiveKit 방 닫기 실패:', roomId, err?.message ?? err);
    });
  }
  if (last) {
    await Promise.resolve(afterLeave(io, last.state, last.userId, true)).catch((err) =>
      console.error('[call] 통화 기록 남기기 실패:', err?.message ?? err),
    );
  }
}

/** 실제 LiveKit 클라이언트와 카드 정리 — 둘 다 DB·설정을 읽는 모듈이라 쓸 때 불러온다(이 파일을 테스트가 그대로 읽게). */
async function liveDeps() {
  const [{ livekitRoomService }, { postCallLeft }] = await Promise.all([import('./calls.js'), import('./callCards.js')]);
  return { livekit: livekitRoomService(), afterLeave: postCallLeft, revocations: liveRevocations };
}

/**
 * 통화 접근을 잃은 사람을 진행 중인 화상회의에서 내보낸다 — 방에서 내보내기·팀에서 빼기·방 나가기·계정 정지·탈퇴·전체
 * 로그아웃처럼 그 사람이 더는 그 방(들)의 통화를 들을 자격이 없어졌을 때 부른다(removeFromCallsWith 참고 — 메모리 상태,
 * LiveKit, 카드 순, 그 뒤 남은 토큰이 만료될 때까지 다시 붙는지 지켜본다). 앱은 LiveKit이 끊어 주면(participantRemoved)
 * 통화 화면을 닫고 안내한다.
 *
 * [roomIds]를 주면 그 방들의 통화에서만, 생략하면 그 사람이 들어가 있는 모든 통화에서 뺀다.
 * 실패해도 던지지 않는다(호출부의 본래 일 — 정지·탈퇴 등 — 을 막지 않게).
 */
export async function endUserCallAccess(io, userId, { roomIds } = {}) {
  try {
    await removeFromCallsWith(await liveDeps(), io, userId, { roomIds });
  } catch (err) {
    console.error('[call] 통화에서 내보내기 실패:', userId, err?.message ?? err);
  }
}

/** 방이 없어져 모두가 통화 자격을 잃었을 때(토픽 삭제 — 팀 삭제도 방마다 같다). 던지지 않는다. */
export async function endRoomCallAccess(io, roomId) {
  try {
    await endRoomCallWith(await liveDeps(), io, roomId);
  } catch (err) {
    console.error('[call] 방 통화 끝내기 실패:', roomId, err?.message ?? err);
  }
}
