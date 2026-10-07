import { videoTierFor } from './callQuality.js';

/**
 * 지금 진행 중인 통화 — roomId -> { startedBy, startedAt, hostId, participants: Map<userId, Set<socketId>>, ... }.
 *
 * 미디어는 LiveKit이 알아서 처리하므로 여기 상태는 오직 **신호(누가 통화를 걸었고 지금 누가
 * 들어와 있는지, 누가 진행자인지, 지금 화질 단계)**를 위한 것이다. 서버 메모리에만 두는 이유: 통화는
 * 서버가 살아있는 동안만 의미가 있고 DB에 남길 이유가 없다. 통화 기록(부재중 등)은 끝날 때 메시지로
 * 남긴다(socket.js). Node 서버만 재시작되면 LiveKit 연결은 그대로라, 앱들이 참여를 다시 알려 통화를
 * 되살린다(callAccess.js admitCallJoin — [restored]).
 *
 * 사람마다 그 통화에 들어와 있는 소켓을 둔다(userId -> socketId 집합). LiveKit은 같은 사람(identity =
 * 사용자 id)이 한 방에 한 연결만 갖게 해서 미디어가 실제로 붙은 기기는 늘 하나다 — 새로 참여를 알린
 * 소켓이 그 사람의 예전 소켓을 대신해서(joinCall) 집합에는 소켓이 하나만 든다. 그래서 예전 소켓의
 * 나가기·끊김 정리(CALL_DISCONNECT_GRACE_MS 뒤)는 그 소켓이 아직 그 자리에 있을 때만 그 사람을 뺀다.
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
    // 서버가 잃었던 통화를 참가자의 LiveKit 연결로 되살린 것(재시작 뒤 등) — 처음 시작할 때 이미 울렸으니 앱은 이 통화로
    // 다시 울리지 않는다(client session.dart). 보통 통화는 이 칸이 없다.
    ...(call.restored && { restored: true }),
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

/**
 * 통화 참가(이미 진행 중이면 합류, 아니면 이 사람이 시작한 것 — 시작한 사람이 진행자). 바뀐 상태를 돌려준다.
 *
 * 이미 들어와 있던 사람이면 이 소켓이 그 사람의 예전 소켓(들)을 대신한다 — 다른 기기로 옮겨 참여했으면 LiveKit이 예전
 * 기기의 연결을 이미 끊었고(같은 identity는 한 연결만), 재연결한 소켓이면 예전 소켓은 죽은 것이다. 예전엔 예전 소켓이
 * 그대로 남아, 옮겨 간 기기에서 나가도 그 사람이 통화에 남은 것처럼 보이고(진행자·참가자 목록) 통화가 끝나지 않았다.
 * 참가 순서(진행자를 넘길 때 보는 순서)는 처음 들어온 자리 그대로다(Map은 키를 다시 넣어도 자리가 안 바뀐다).
 *
 * [restored]는 서버가 잃었던 통화를 되살리는 참가(callAccess.js admitCallJoin)일 때 — 새로 만드는 통화에만 붙는다.
 */
export function joinCall(roomId, userId, socketId, { restored = false } = {}) {
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
      // 이 통화를 거절한 사람 — 거절은 한 통화에 한 번만 알린다(markCallDeclined).
      declinedBy: new Set(),
      lastTier: null,
      restored,
    };
    activeCalls.set(roomId, call);
  }
  call.participants.set(userId, new Set([socketId]));
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
  return settleAfterLeave(roomId, call);
}

/** 누가 빠진 뒤의 정리 — 진행자를 다시 정하거나, 아무도 안 남았으면 통화를 끝내고 요약을 붙인다(leaveCall 참고). */
function settleAfterLeave(roomId, call) {
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
      // 되살린 통화(카드 없이 이어 간 것) — 끝날 때 남길 기록이 다르다(callCards.js postCallLeft).
      ...(call.restored && { restored: true }),
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
 * [userId]를 통화에서 통째로 뺀다(그 사람의 모든 소켓) — 방에서 내보내졌거나 계정이 정지되는 등 통화에 있을 자격을 잃었을
 * 때(callAccess.js endUserCallAccess). 기기 하나가 나가는 leaveCall과 달리 다른 기기로 들어와 있어도 같이 빠진다. 진행자
 * 넘기기·통화 끝내기는 보통 나가기와 같다. [roomIds]를 주면 그 방들의 통화에서만, 생략하면 들어가 있는 모든 통화에서.
 * 바뀐 방마다 leaveCall과 같은 모양의 상태(끝났으면 [ended] 포함)를 돌려준다 — 들어가 있지 않던 통화는 빠진다.
 */
export function removeUserFromCalls(userId, { roomIds } = {}) {
  const only = roomIds ? new Set(roomIds) : null;
  const changed = [];
  for (const [roomId, call] of [...activeCalls]) {
    if (only && !only.has(roomId)) continue;
    if (!call.participants.delete(userId)) continue;
    changed.push(settleAfterLeave(roomId, call));
  }
  return changed;
}

/** [userId]가 지금 이 방의 통화에 들어와 있는지(기기 하나라도). */
export function isInCall(roomId, userId) {
  return activeCalls.get(roomId)?.participants.has(userId) ?? false;
}

/** 이 소켓이 [userId]의 자리로 이 방 통화에 들어와 있는지 — 다른 기기의 참여가 이 소켓을 대신했으면 false(joinCall). */
export function isSocketInCall(roomId, userId, socketId) {
  return activeCalls.get(roomId)?.participants.get(userId)?.has(socketId) ?? false;
}

/**
 * 진행 중인 통화를 [userId]가 거절했다고 적는다 — 이 통화에서 처음 거절한 것이면 true. 이미 거절했거나(같은 계정의 다른
 * 기기에서 또 거절, 또는 call:decline을 되풀이해 보냄), 통화가 없거나, 이미 통화에 들어와 있으면 false — 그때는 건 사람에게
 * 다시 알리지도, 카드에 다시 쌓지도 않는다(socket.js call:decline).
 */
export function markCallDeclined(roomId, userId) {
  const call = activeCalls.get(roomId);
  if (!call || call.participants.has(userId) || call.declinedBy.has(userId)) return false;
  call.declinedBy.add(userId);
  return true;
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
