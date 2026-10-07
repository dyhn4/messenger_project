// 지금 소켓으로 연결되어 있는 사용자(온라인) 추적. 같은 사람이 여러 기기(PC+폰)로 동시에
// 붙어있을 수 있어서 단순 Set이 아니라 연결 개수를 센다 — 기기 하나만 닫아도 다른 기기가
// 아직 붙어있으면 여전히 온라인으로 남아야 한다.
const connectionCounts = new Map(); // userId -> 활성 소켓 개수

/** 소켓이 연결됐을 때 호출. 반환값이 true면 방금 오프라인→온라인으로 막 바뀐 것(첫 연결). */
export function markConnected(userId) {
  const next = (connectionCounts.get(userId) ?? 0) + 1;
  connectionCounts.set(userId, next);
  return next === 1;
}

/** 소켓이 끊겼을 때 호출. 반환값이 true면 방금 온라인→오프라인으로 막 바뀐 것(마지막 연결이 끊김). */
export function markDisconnected(userId) {
  const current = connectionCounts.get(userId) ?? 0;
  const next = Math.max(0, current - 1);
  if (next === 0) {
    connectionCounts.delete(userId);
  } else {
    connectionCounts.set(userId, next);
  }
  return next === 0;
}

export function isOnline(userId) {
  return connectionCounts.has(userId);
}

/**
 * [userId]의 접속 상태가 바뀌었음을 그 사람과 팀을 같이 쓰는 사람들(user:<id> 방)에게만 알린다(presence:update). 예전엔
 * io.emit으로 서버에 붙은 모든 소켓에 모든 사람의 접속·해제를 흘려서, 팀이 없는 준회원도 서버 전체 회원의 접속 여부를 볼
 * 수 있었다. 범위는 회원 목록(GET /api/users)과 같다 — [listCoTeamMemberIds]로 db/queries/teams.js의 같은 이름 함수를
 * 받는다(이 파일이 DB를 몰라 테스트가 가짜를 넣는다).
 *
 * 받는 사람을 찾는 조회가 끝난 시점의 **지금** 상태를 보낸다(바뀐 순간의 값이 아니라) — 붙자마자 끊겨 두 조회가 끝나는
 * 순서가 뒤바뀌어도 마지막에 도착하는 알림이 실제 상태와 같다. 부르는 건 지금처럼 진짜 온라인↔오프라인 전환 때뿐이다
 * (markConnected/markDisconnected가 true일 때 — socket.js).
 */
export async function broadcastPresence(io, userId, listCoTeamMemberIds) {
  const ids = await listCoTeamMemberIds(userId);
  // 빈 목록으로 io.to([])를 부르면 socket.io는 "방 조건 없음 = 모두에게"로 보낸다 — 팀이 없으면 알릴 사람도 없다.
  if (ids.length === 0) return;
  io.to(ids.map((id) => `user:${id}`)).emit('presence:update', { userId, online: isOnline(userId) });
}
