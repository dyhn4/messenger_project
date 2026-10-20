import { setMemberLastRead } from './db/queries/rooms.js';
import { markRoomNotificationsRead } from './notifications.js';

/**
 * [userId]가 방([roomId])을 지금까지 읽었다 — 마지막 읽은 시각을 남기고 방에 `room:read`로 알린 뒤(다른 멤버의 안 읽은 수·내 다른 기기),
 * 이 방의 멘션·보드 알림(그 시각 이전 것)도 읽은 것으로 한다(다른 기기에는 notification:sync). 멤버인지는 부르는 쪽이 본다 —
 * 소켓의 `room:read`(socket.js)와 알림에서 바로 답장(pushReply.js — 답장했으면 읽은 것)이 같이 쓴다.
 */
export async function markRoomRead(io, roomId, userId) {
  const lastReadAt = Date.now();
  await setMemberLastRead(roomId, userId, lastReadAt);
  io.to(roomId).emit('room:read', { roomId, userId, lastReadAt });
  await markRoomNotificationsRead(io, userId, roomId, lastReadAt).catch((err) =>
    console.error('[notifications] 자동 읽음 실패:', err?.message ?? err),
  );
  return lastReadAt;
}
