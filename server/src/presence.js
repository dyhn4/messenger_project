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
