import { and, eq, inArray, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { messageComments, messages, roomMembers, rooms, teamMembers, teams, users } from '../schema.js';

/**
 * 검색 패널 "대화방" 탭 — [userId]가 멤버인 방(공개이지만 가입 안 한 토픽은 room_members에 없어 자연히 빠진다)만,
 * 비밀 대화(E2EE)는 뺀다. 방이 속한 팀에 내가 아직 멤버여야 하고(team_members 조인), [teamId]를 주면 그 팀만.
 * 보관된 토픽은 포함한다. 한 행: { room, customName(나에게만 바꾼 이름), teamName }.
 */
export function listMemberRoomsForSearch(userId, teamId = null) {
  const conditions = [eq(roomMembers.userId, userId), eq(rooms.isSecret, false)];
  if (teamId) conditions.push(eq(rooms.teamId, teamId));
  return db
    .select({ room: rooms, customName: roomMembers.customName, teamName: teams.name })
    .from(roomMembers)
    .innerJoin(rooms, eq(roomMembers.roomId, rooms.id))
    .innerJoin(teams, eq(teams.id, rooms.teamId))
    .innerJoin(teamMembers, and(eq(teamMembers.teamId, rooms.teamId), eq(teamMembers.userId, userId)))
    .where(and(...conditions));
}

/** roomId → [{ id, name }] — 이름이 필요한 방들의 멤버(표시 이름을 만들 때). 탈퇴한 사용자도 그 이름 그대로 들어간다. */
export async function listMembersByRoom(roomIds) {
  const map = new Map();
  if (roomIds.length === 0) return map;
  const rows = await db
    .select({ roomId: roomMembers.roomId, id: users.id, name: users.name })
    .from(roomMembers)
    .innerJoin(users, eq(roomMembers.userId, users.id))
    .where(inArray(roomMembers.roomId, roomIds));
  for (const r of rows) {
    if (!map.has(r.roomId)) map.set(r.roomId, []);
    map.get(r.roomId).push({ id: r.id, name: r.name });
  }
  return map;
}

/** roomId → 멤버 수. */
export async function countMembersByRoom(roomIds) {
  const map = new Map();
  if (roomIds.length === 0) return map;
  const rows = await db
    .select({ roomId: roomMembers.roomId, n: sql`count(*)::int` })
    .from(roomMembers)
    .where(inArray(roomMembers.roomId, roomIds))
    .groupBy(roomMembers.roomId);
  for (const r of rows) map.set(r.roomId, r.n);
  return map;
}

/** roomId → 마지막 활동 시각(ms) — 방 목록(rooms.js toRoomDto)과 같은 기준: 방 만든 때·마지막 메시지·마지막 댓글 중 가장 늦은 것. */
export async function lastActivityByRoom(roomRows) {
  const map = new Map(roomRows.map((r) => [r.id, new Date(r.createdAt).getTime()]));
  const ids = roomRows.map((r) => r.id);
  if (ids.length === 0) return map;
  const [msgRows, commentRows] = await Promise.all([
    db
      .select({ roomId: messages.roomId, at: sql`max(${messages.createdAt})` })
      .from(messages)
      .where(inArray(messages.roomId, ids))
      .groupBy(messages.roomId),
    db
      .select({ roomId: messageComments.roomId, at: sql`max(${messageComments.createdAt})` })
      .from(messageComments)
      .where(inArray(messageComments.roomId, ids))
      .groupBy(messageComments.roomId),
  ]);
  for (const r of [...msgRows, ...commentRows]) {
    const at = r.at ? new Date(r.at).getTime() : 0;
    if (at > (map.get(r.roomId) ?? 0)) map.set(r.roomId, at);
  }
  return map;
}
