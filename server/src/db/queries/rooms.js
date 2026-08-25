import { and, eq, isNull, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { roomMembers, rooms, users } from '../schema.js';

export function findRoomById(id) {
  return db
    .select()
    .from(rooms)
    .where(eq(rooms.id, id))
    .then((rows) => rows[0] ?? null);
}

export function findDmRoomByKey(dmKey) {
  return db
    .select()
    .from(rooms)
    .where(and(eq(rooms.type, 'dm'), eq(rooms.dmKey, dmKey)))
    .then((rows) => rows[0] ?? null);
}

/** 이 사람이 멤버인 모든 방. */
export function listRoomsForUser(userId) {
  return db
    .select({ room: rooms })
    .from(roomMembers)
    .innerJoin(rooms, eq(roomMembers.roomId, rooms.id))
    .where(eq(roomMembers.userId, userId))
    .then((rows) => rows.map((r) => r.room));
}

/** isPublic이 명시적으로 false가 아니면 공개로 친다(기존 `r.isPublic !== false`와 동일한 규칙). */
const isPublicTopic = or(isNull(rooms.isPublic), eq(rooms.isPublic, true));

/** 새로 가입하는 회원을 자동으로 넣어줄 기존 공개 토픽 전체. */
export function listPublicTopics() {
  return db
    .select()
    .from(rooms)
    .where(and(eq(rooms.type, 'topic'), isPublicTopic));
}

/** 토픽 찾아보기: 공개 토픽 전부 + 비공개 토픽 중 내가 이미 멤버인 것. */
export function listBrowsableTopics(userId) {
  return db
    .select({ room: rooms, joined: sql`(${roomMembers.userId} is not null)`.as('joined') })
    .from(rooms)
    .leftJoin(roomMembers, and(eq(roomMembers.roomId, rooms.id), eq(roomMembers.userId, userId)))
    .where(and(eq(rooms.type, 'topic'), or(isPublicTopic, sql`${roomMembers.userId} is not null`)));
}

export async function insertRoom(fields) {
  const [row] = await db.insert(rooms).values(fields).returning();
  return row;
}

/** 여러 명을 한 번에 멤버로 추가한다(이미 멤버면 조용히 무시 — 초대/공개토픽 자동가입에서 중복 방지). */
export async function addRoomMembers(roomId, userIds) {
  if (userIds.length === 0) return;
  await db
    .insert(roomMembers)
    .values(userIds.map((userId) => ({ roomId, userId })))
    .onConflictDoNothing();
}

export async function removeRoomMember(roomId, userId) {
  await db.delete(roomMembers).where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
}

export async function isRoomMember(roomId, userId) {
  const [row] = await db
    .select({ userId: roomMembers.userId })
    .from(roomMembers)
    .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
  return !!row;
}

/** 방 멤버 id만(소켓 join 등 사용자 정보가 필요 없는 곳에서 가볍게). */
export function listRoomMemberIds(roomId) {
  return db
    .select({ userId: roomMembers.userId })
    .from(roomMembers)
    .where(eq(roomMembers.roomId, roomId))
    .then((rows) => rows.map((r) => r.userId));
}

/** 방 멤버 목록을 실제 사용자 정보(publicUser로 감쌀 원본 행)로. 탈퇴한 사용자는 멤버 목록/
 * 그룹 표시 이름에 더 이상 보일 필요가 없으므로 제외한다(과거 메시지의 발신자 표시는
 * 메시지에 박제된 senderName으로 대체됨 — message_bubble.dart 참고). */
export function listRoomMemberUsers(roomId) {
  return db
    .select({ user: users })
    .from(roomMembers)
    .innerJoin(users, eq(roomMembers.userId, users.id))
    .where(and(eq(roomMembers.roomId, roomId), isNull(users.deletedAt)))
    .then((rows) => rows.map((r) => r.user));
}

/** 방 멤버들의 마지막 읽은 시각 맵({userId: epochMillis}) — 클라이언트의 "안읽음 N" 계산용. */
export async function getRoomLastReadMap(roomId) {
  const rows = await db
    .select({ userId: roomMembers.userId, lastReadAt: roomMembers.lastReadAt })
    .from(roomMembers)
    .where(eq(roomMembers.roomId, roomId));
  const map = {};
  for (const r of rows) {
    map[r.userId] = r.lastReadAt ? new Date(r.lastReadAt).getTime() : 0;
  }
  return map;
}

export async function getMemberLastRead(roomId, userId) {
  const [row] = await db
    .select({ lastReadAt: roomMembers.lastReadAt })
    .from(roomMembers)
    .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
  return row?.lastReadAt ? new Date(row.lastReadAt).getTime() : 0;
}

export async function setMemberLastRead(roomId, userId, whenMs) {
  await db
    .update(roomMembers)
    .set({ lastReadAt: new Date(whenMs) })
    .where(and(eq(roomMembers.roomId, roomId), eq(roomMembers.userId, userId)));
}
