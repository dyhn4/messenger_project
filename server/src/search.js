import { Router } from 'express';
import { searchMessages } from './db/queries/messages.js';
import { findRoomById } from './db/queries/rooms.js';
import { isTeamMember } from './db/queries/teams.js';
import { parseFileKind } from './fileKinds.js';
// 결과의 방 이름은 클라이언트 Room.displayName()과 같은 규칙(나와의 대화 포함) — 예약 메시지 목록과 한 벌로 쓴다.
import { roomDisplayName } from './rooms.js';

export const searchRouter = Router();

/**
 * 내가 속한 모든 방을 가로지르는 통합 검색. 메시지 텍스트와 파일명, 보드 뷰 게시글 제목을 대상으로 합니다.
 * roomId/senderId/since/until로 결과 범위를 좁힐 수 있습니다(전부 선택적). "내가 속한 방"
 * 범위는 searchMessages가 room_members 조인으로 강제한다 — roomId를 임의로 보내도 내 방이
 * 아니면 결과에 안 걸린다.
 *
 * 검색 패널의 탭·정렬도 여기서 받는다(전부 선택적 — 안 보내면 예전 동작 그대로):
 *   type=message|poll|file(기본 전체), fileKind=image|pdf|…|other(type=file일 때, fileKinds.js),
 *   order=desc|asc(기본 최신 순), withTotal=1이면 배열 대신 { items, total }을 돌려준다 —
 *   total은 limit에 잘리기 전의 전체 건수라 패널의 "결과 N건"이 정확하다.
 */
searchRouter.get('/search', async (req, res) => {
  const q = String(req.query.q ?? '').trim().toLowerCase();
  if (!q) return res.json(['1', 'true'].includes(req.query.withTotal) ? { items: [], total: 0 } : []);
  const { roomId, senderId, since, until, teamId } = req.query;
  const type = ['message', 'poll', 'file'].includes(req.query.type) ? req.query.type : 'all';
  const order = req.query.order === 'asc' ? 'asc' : 'desc';
  const withTotal = req.query.withTotal === '1' || req.query.withTotal === 'true';
  const limit = Math.min(Number(req.query.limit) || 200, 500);
  // 검색은 지금 보고 있는 팀 안에서만 한다 — 다른 팀 대화가 섞여 나오면 안 된다.
  if (!teamId) return res.status(400).json({ error: 'teamId가 필요합니다.' });
  if (!(await isTeamMember(teamId, req.user.sub))) {
    return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
  }

  const found = await searchMessages({
    requesterId: req.user.sub,
    teamId,
    roomId: roomId || null,
    senderId: senderId || null,
    since: since ? Number(since) : null,
    until: until ? Number(until) : null,
    q,
    limit,
    type,
    fileKind: type === 'file' ? parseFileKind(req.query.fileKind) : null,
    order,
    withTotal,
  });
  const rows = withTotal ? found.rows : found;

  const roomNameById = new Map();
  for (const m of rows) {
    if (roomNameById.has(m.roomId)) continue;
    const room = await findRoomById(m.roomId);
    roomNameById.set(m.roomId, room ? await roomDisplayName(room, req.user.sub) : null);
  }

  const items = rows.map((m) => ({
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
  }));
  res.json(withTotal ? { items, total: found.total } : items);
});
