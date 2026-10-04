import { videoTierFor } from './callQuality.js';

/**
 * 지금 진행 중인 통화 — roomId -> { startedBy, startedAt, hostId, participants: Map<userId, Set<socketId>>, ... }.
 *
 * 미디어는 LiveKit이 알아서 처리하므로 여기 상태는 오직 **신호(누가 통화를 걸었고 지금 누가
 * 들어와 있는지, 누가 진행자인지, 지금 화질 단계)**를 위한 것이다. 서버 메모리에만 두는 이유: 통화는
 * 서버가 살아있는 동안만 의미가 있고(재시작되면 LiveKit 연결도 끊긴다) DB에 남길 이유가 없다. 통화
 * 기록(부재중 등)은 끝날 때 메시지로 남긴다(socket.js).
 *
 * 한 사용자가 여러 기기로 접속할 수 있어서 userId -> socketId 집합으로 센다 — 폰에서 나가도
 * PC에서 아직 통화 중이면 참가자 목록에서 빠지면 안 되기 때문이다.
 *
 * DB·LiveKit을 모르는 순수 상태라 단위 테스트가 그대로 돌린다(test/callQuality.test.js).
 */
const activeCalls = new Map();

/** 서버 전체에서 지금 통화 중인 사람 수(방마다 센 합 — 두 방에 동시에 있으면 두 번 센다). */
function serverParticipantCount() {
  let total = 0;
  for (const call of activeCalls.values()) total += call.participants.size;
  return total;
}

function tierOf(call) {
  return videoTierFor(call.participants.size, serverParticipantCount());
}

function toState(roomId) {
  const call = activeCalls.get(roomId);
  if (!call) {
    return {
      roomId,
      active: false,
      startedBy: null,
      startedAt: null,
      hostId: null,
      videoTier: null,
      participantIds: [],
    };
  }
  return {
    roomId,
    active: true,
    startedBy: call.startedBy,
    startedAt: call.startedAt,
    // 진행자 — 참가자 패널에서 다른 사람의 마이크를 켜고 끌 수 있다(canControlMic).
    hostId: call.hostId,
    // 영상 화질 단계(callQuality.js) — 클라이언트가 이 단계에 맞춰 보내는 해상도를 낮춘다.
    videoTier: tierOf(call),
    participantIds: [...call.participants.keys()],
  };
}

export function callStateFor(roomId) {
  return toState(roomId);
}

/**
 * 지금 통화가 진행 중인 방들의 상태 — 소켓이 막 붙었을 때(앱을 켰을 때) 한 번 내려준다.
 * call:state는 "바뀌는 순간"에만 브로드캐스트되므로, 이게 없으면 통화가 이미 진행 중인 방에
 * 나중에 들어온 사람은 그 통화를 아예 모른다(참여 버튼이 안 뜬다).
 */
export function activeCallStatesFor(roomIds) {
  return roomIds.filter((id) => activeCalls.has(id)).map(toState);
}

/** 통화 참가(이미 진행 중이면 합류, 아니면 이 사람이 시작한 것 — 시작한 사람이 진행자). 바뀐 상태를 돌려준다. */
export function joinCall(roomId, userId, socketId) {
  let call = activeCalls.get(roomId);
  if (!call) {
    call = {
      startedBy: userId,
      startedAt: Date.now(),
      hostId: userId,
      participants: new Map(),
      // 통화가 끝난 뒤 "몇 명이 참여했는지"를 남기려면, **지금** 남아있는 사람이 아니라
      // 한 번이라도 들어왔던 사람을 세야 한다(먼저 나간 사람도 참여자다).
      everJoined: new Set(),
      lastTier: null,
    };
    activeCalls.set(roomId, call);
  }
  const sockets = call.participants.get(userId) ?? new Set();
  sockets.add(socketId);
  call.participants.set(userId, sockets);
  call.everJoined.add(userId);
  const state = toState(roomId);
  call.lastTier = state.videoTier;
  return state;
}

/**
 * 통화에서 나가기. 진행자가 나가면 남은 사람 중 가장 먼저 들어온 사람이 진행자가 된다. 마지막 참가자가
 * 나가면 통화 자체가 끝난다.
 *
 * 통화가 끝난 경우 [state.ended]에 요약(시작 시각·길이·참여자 수)을 같이 담아 돌려준다 —
 * 호출부(socket.js)가 그걸로 대화에 "화상회의 · 12분 · 3명 참여" 같은 기록을 남긴다.
 */
export function leaveCall(roomId, userId, socketId) {
  const call = activeCalls.get(roomId);
  if (!call) return toState(roomId);
  const sockets = call.participants.get(userId);
  if (sockets) {
    sockets.delete(socketId);
    if (sockets.size === 0) call.participants.delete(userId);
  }
  if (call.participants.size > 0) {
    // Map은 넣은 순서를 지키므로 첫 키 = 지금 남은 사람 중 가장 먼저 들어온 사람.
    if (!call.participants.has(call.hostId)) call.hostId = call.participants.keys().next().value;
    const state = toState(roomId);
    call.lastTier = state.videoTier;
    return state;
  }

  activeCalls.delete(roomId);
  return {
    ...toState(roomId),
    ended: {
      startedBy: call.startedBy,
      durationMs: Date.now() - call.startedAt,
      // 건 사람만 들어왔다 나갔으면 아무도 안 받은 것 = 부재중.
      participantIds: [...call.everJoined],
      answered: call.everJoined.size > 1,
    },
  };
}

/** 소켓이 끊겼을 때(앱 종료/네트워크 끊김) 그 소켓이 들어가 있던 모든 통화에서 빼낸다. */
export function leaveAllCallsForSocket(userId, socketId) {
  const changed = [];
  for (const [roomId, call] of activeCalls) {
    if (call.participants.get(userId)?.has(socketId)) {
      changed.push(leaveCall(roomId, userId, socketId));
    }
  }
  return changed;
}

/**
 * 서버 전체 참가자 수가 바뀌어 화질 단계가 달라진 통화들의 새 상태 — 다른 방에 사람이 들고 나도 이 방의
 * 단계가 바뀔 수 있어서, 참가·퇴장 뒤마다 불러 바뀐 방에만 call:state를 다시 보낸다(socket.js).
 */
export function refreshVideoTiers() {
  const changed = [];
  for (const [roomId, call] of activeCalls) {
    const tier = tierOf(call);
    if (tier === call.lastTier) continue;
    call.lastTier = tier;
    changed.push(toState(roomId));
  }
  return changed;
}

/** [requesterId]가 이 통화의 진행자이고 [targetId]가 지금 통화에 있는지 — 진행자의 마이크 켜기/끄기 요청 검사. */
export function canControlMic(roomId, requesterId, targetId) {
  const call = activeCalls.get(roomId);
  if (!call) return false;
  return call.hostId === requesterId && call.participants.has(targetId);
}
