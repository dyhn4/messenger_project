import { Router } from 'express';
import { searchMessages } from './db/queries/messages.js';
import { findRoomById, listRoomMemberUsers } from './db/queries/rooms.js';
import { isTeamMember } from './db/queries/teams.js';

export const searchRouter = Router();

/**
 * 클라이언트 Room.displayName()과 동일한 규칙: 이름이 있으면 그대로, DM은 상대방 이름,
 * 이름 없는 그룹은 나를 뺀 나머지 멤버 이름을 이름순으로 나열.
 */
async function displayNameFor(room, myUserId) {
  if (room.name) return room.name;
  const members = await listRoomMemberUsers(room.id);
  const nameOf = (id) => members.find((u) => u.id === id)?.name;
  if (room.type === 'dm') {
    const other = members.find((m) => m.id !== myUserId);
    return other ? (nameOf(other.id) ?? '(알 수 없음)') : '(알 수 없음)';
  }
  const names = members
    .filter((m) => m.id !== myUserId)
    .map((m) => m.name)
    .filter(Boolean)
    .sort();
  return names.length > 0 ? names.join(', ') : '(알 수 없음)';
}

/**
 * 내가 속한 모든 방을 가로지르는 통합 검색. 메시지 텍스트와 파일명, 보드 뷰 게시글 제목을 대상으로 합니다.
 * roomId/senderId/since/until로 결과 범위를 좁힐 수 있습니다(전부 선택적). "내가 속한 방"
 * 범위는 searchMessages가 room_members 조인으로 강제한다 — roomId를 임의로 보내도 내 방이
 * 아니면 결과에 안 걸린다.
 */
searchRouter.get('/search', async (req, res) => {
  const q = String(req.query.q ?? '').trim().toLowerCase();
  if (!q) return res.json([]);
  const { roomId, senderId, since, until, teamId } = req.query;
  const limit = Math.min(Number(req.query.limit) || 200, 500);
  // 검색은 지금 보고 있는 팀 안에서만 한다 — 다른 팀 대화가 섞여 나오면 안 된다.
  if (!teamId) return res.status(400).json({ error: 'teamId가 필요합니다.' });
  if (!(await isTeamMember(teamId, req.user.sub))) {
    return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
  }

  const rows = await searchMessages({
    requesterId: req.user.sub,
    teamId,
    roomId: roomId || null,
    senderId: senderId || null,
    since: since ? Number(since) : null,
    until: until ? Number(until) : null,
    q,
    limit,
  });

  const roomNameById = new Map();
  for (const m of rows) {
    if (roomNameById.has(m.roomId)) continue;
    const room = await findRoomById(m.roomId);
    roomNameById.set(m.roomId, room ? await displayNameFor(room, req.user.sub) : null);
  }

  res.json(
    rows.map((m) => ({
      id: m.id,
      roomId: m.roomId,
      roomName: roomNameById.get(m.roomId) ?? null,
      senderId: m.senderId,
      senderName: m.senderName,
      type: m.type,
      title: m.title ?? null, // 게시글('post')이면 제목 — 결과 목록에 본문 대신 제목을 보여줄 수 있게.
      text: m.text,
      fileName: m.fileName,
      createdAt: new Date(m.createdAt).getTime(),
    })),
  );
});
