import { Router } from 'express';
import { db } from './db.js';

export const searchRouter = Router();

/**
 * 클라이언트 Room.displayName()과 동일한 규칙: 이름이 있으면 그대로, DM은 상대방 아이디,
 * 이름 없는 그룹은 멤버 아이디를 이름순으로 나열.
 */
function displayNameFor(room, myUserId) {
  if (room.name) return room.name;
  const usernames = (id) => db.data.users.find((u) => u.id === id)?.username;
  if (room.type === 'dm') {
    const other = room.memberIds.find((id) => id !== myUserId);
    return other ? usernames(other) ?? '(알 수 없음)' : '(알 수 없음)';
  }
  return room.memberIds.map(usernames).filter(Boolean).sort().join(', ');
}

/**
 * 내가 속한 모든 방을 가로지르는 통합 검색. 메시지 텍스트와 파일명을 대상으로 합니다.
 * roomId/senderId/since/until로 결과 범위를 좁힐 수 있습니다(전부 선택적).
 */
searchRouter.get('/search', (req, res) => {
  const q = String(req.query.q ?? '').trim().toLowerCase();
  if (!q) return res.json([]);
  const { roomId, senderId, since, until } = req.query;

  const limit = Math.min(Number(req.query.limit) || 200, 500);
  const myRoomIds = new Set(
    db.data.rooms.filter((r) => r.memberIds.includes(req.user.sub)).map((r) => r.id),
  );
  const roomNameById = new Map(
    db.data.rooms.map((r) => [r.id, displayNameFor(r, req.user.sub)]),
  );

  const results = db.data.messages
    .filter((m) => myRoomIds.has(m.roomId))
    .filter((m) => !roomId || m.roomId === roomId)
    .filter((m) => !senderId || m.senderId === senderId)
    .filter((m) => !since || m.createdAt >= Number(since))
    .filter((m) => !until || m.createdAt <= Number(until))
    .filter((m) => m.text?.toLowerCase().includes(q) || m.fileName?.toLowerCase().includes(q))
    .sort((a, b) => b.createdAt - a.createdAt)
    .slice(0, limit)
    .map((m) => ({
      id: m.id,
      roomId: m.roomId,
      roomName: roomNameById.get(m.roomId) ?? null,
      senderId: m.senderId,
      senderName: m.senderName,
      type: m.type,
      text: m.text,
      fileName: m.fileName,
      createdAt: m.createdAt,
    }));

  res.json(results);
});
