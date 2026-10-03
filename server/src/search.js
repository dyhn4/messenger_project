import { Router } from 'express';
import { searchMessages } from './db/queries/messages.js';
import { findRoomById } from './db/queries/rooms.js';
import { countMembersByRoom, lastActivityByRoom, listMemberRoomsForSearch, listMembersByRoom } from './db/queries/roomSearch.js';
import { isTeamMember } from './db/queries/teams.js';
import { matchRoomsByName, parseRoomSearchQuery, sortRoomsByActivity } from './roomSearchRules.js';
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
 *   scope=all이면 teamId 없이 내가 속한 모든 팀에서 찾고("모든 팀"), 결과 항목에 teamId·teamName이 붙는다.
 *   안 보내면(기본 team) 지금까지처럼 teamId 한 팀 안에서만 — teamId가 필수다.
 */
searchRouter.get('/search', async (req, res) => {
  const q = String(req.query.q ?? '').trim().toLowerCase();
  if (!q) return res.json(['1', 'true'].includes(req.query.withTotal) ? { items: [], total: 0 } : []);
  const { roomId, senderId, since, until, teamId } = req.query;
  const type = ['message', 'poll', 'file'].includes(req.query.type) ? req.query.type : 'all';
  const order = req.query.order === 'asc' ? 'asc' : 'desc';
  const withTotal = req.query.withTotal === '1' || req.query.withTotal === 'true';
  const limit = Math.min(Number(req.query.limit) || 200, 500);
  // 기본은 지금 보고 있는 팀 안에서만 — 다른 팀 대화가 섞여 나오면 안 된다. 모든 팀(scope=all)은 내 팀 멤버십을
  // searchMessages가 team_members로 직접 확인한다.
  const allTeams = req.query.scope === 'all';
  if (!allTeams) {
    if (!teamId) return res.status(400).json({ error: 'teamId가 필요합니다.' });
    if (!(await isTeamMember(teamId, req.user.sub))) {
      return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    }
  }

  const found = await searchMessages({
    requesterId: req.user.sub,
    teamId: allTeams ? null : teamId,
    allTeams,
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
    ...(allTeams ? { teamId: m.roomTeamId, teamName: m.roomTeamName } : {}),
  }));
  res.json(withTotal ? { items, total: found.total } : items);
});

/**
 * 검색 패널 "대화방" 탭 — 내가 멤버인 토픽·그룹채팅·채팅(1:1)·나와의 대화를 **이름**으로 찾는다(메시지 검색과 별개).
 * 공개여도 가입하지 않은 토픽은 안 나오고(room_members 기준), 보관된 토픽은 나오며(archived), 비밀 대화(E2EE)는 뺀다.
 * 이름은 화면에 보이는 그대로(1:1은 상대 이름, 이름 없는 그룹은 멤버 이름들, 나에게만 바꾼 이름, 나와의 대화)이고
 * 이름 없는 그룹은 멤버 이름으로도 찾힌다. q는 글자 그대로 부분 일치(%·_ 와일드카드 아님).
 *   scope=team(기본, teamId 필수)|all(내가 속한 모든 팀), order=desc|asc(마지막 활동순, 기본 최신 순), limit(기본 200, 최대 500).
 * 응답 { items, total } — total은 limit에 잘리기 전의 건수. 항목: roomId, teamId, teamName, type(topic|group|dm),
 * name, memberCount, archived, lastActivityAt(ms), isSelf, isPublic.
 */
searchRouter.get('/search/rooms', async (req, res) => {
  const parsed = parseRoomSearchQuery(req.query);
  if (parsed.error) return res.status(400).json({ error: parsed.error });
  const { q, scope, teamId, order, limit } = parsed;
  if (!q) return res.json({ items: [], total: 0 });
  const me = req.user.sub;
  if (scope === 'team' && !(await isTeamMember(teamId, me))) {
    return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
  }

  const rows = await listMemberRoomsForSearch(me, scope === 'team' ? teamId : null);
  // 표시 이름에 멤버 이름이 필요한 방(이름 없는 1:1·그룹, 나와의 대화 제외)만 멤버를 읽는다.
  const needMembers = rows.filter((r) => !r.room.isSelf && !r.room.name).map((r) => r.room.id);
  const matched = matchRoomsByName(rows, await listMembersByRoom(needMembers), q, me);
  const activity = await lastActivityByRoom(matched.map((r) => r.room));
  const sorted = sortRoomsByActivity(
    matched.map((r) => ({ ...r, lastActivityAt: activity.get(r.room.id) ?? 0 })),
    order,
  );
  const page = sorted.slice(0, limit);
  const counts = await countMembersByRoom(page.map((r) => r.room.id));
  res.json({
    items: page.map((r) => ({
      roomId: r.room.id,
      teamId: r.room.teamId,
      teamName: r.teamName,
      type: r.room.type,
      name: r.name,
      memberCount: counts.get(r.room.id) ?? 0,
      archived: !!r.room.archivedAt,
      lastActivityAt: r.lastActivityAt,
      isSelf: !!r.room.isSelf,
      isPublic: r.room.isPublic !== false,
    })),
    total: sorted.length,
  });
});
