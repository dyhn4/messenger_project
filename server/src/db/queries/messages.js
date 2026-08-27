import { and, desc, eq, gt, gte, isNotNull, lte, ne, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { roomMembers, rooms, messages } from '../schema.js';

export async function insertMessage(fields) {
  const [row] = await db.insert(messages).values(fields).returning();
  return row;
}

export function findMessageById(id) {
  return db
    .select()
    .from(messages)
    .where(eq(messages.id, id))
    .then((rows) => rows[0] ?? null);
}

/** 방 목록 정렬용 "최근 활동" 계산에 쓴다(rooms.js의 toRoomDto 참고) — 이 방의 가장 최근
 * 메시지 시각. 메시지가 하나도 없으면 null(그러면 room.createdAt으로 대체됨). */
export async function getLastMessageAt(roomId) {
  const [row] = await db
    .select({ createdAt: messages.createdAt })
    .from(messages)
    .where(eq(messages.roomId, roomId))
    .orderBy(desc(messages.createdAt))
    .limit(1);
  return row?.createdAt ?? null;
}

export async function updateMessageText(id, text) {
  const [row] = await db.update(messages).set({ text, editedAt: new Date() }).where(eq(messages.id, id)).returning();
  return row;
}

/** 소프트 삭제 — 행은 남기고(댓글 스레드가 계속 참조) 내용만 비운다. */
export async function softDeleteMessage(id) {
  const [row] = await db
    .update(messages)
    .set({ deletedAt: new Date(), text: null, fileUrl: null, fileName: null, fileSize: null, mimeType: null })
    .where(eq(messages.id, id))
    .returning();
  return row;
}

/** 방의 최근 메시지 limit개를 시간순(오래된 것부터)으로. */
export async function listMessagesByRoom(roomId, limit) {
  const rows = await db
    .select()
    .from(messages)
    .where(eq(messages.roomId, roomId))
    .orderBy(desc(messages.createdAt))
    .limit(limit);
  return rows.reverse();
}

/** toRoomDto의 unreadCount: 이 방에서 나(requesterId)를 뺀 사람이 보낸, 시스템 메시지가 아닌,
 * 내가 마지막으로 읽은 시각(sinceMs) 이후의 메시지 수. */
export async function countUnreadForUser(roomId, requesterId, sinceMs) {
  const [row] = await db
    .select({ count: sql`count(*)`.mapWith(Number) })
    .from(messages)
    .where(
      and(
        eq(messages.roomId, roomId),
        ne(messages.senderId, requesterId),
        ne(messages.type, 'system'),
        gt(messages.createdAt, new Date(sinceMs)),
      ),
    );
  return row?.count ?? 0;
}

/** 보존기간 만료 파기(retention.js) — 그 사람이 보낸 메시지를 전부 지우고 지운 개수를 돌려준다. */
export async function deleteMessagesBySender(userId) {
  const deleted = await db.delete(messages).where(eq(messages.senderId, userId)).returning({ id: messages.id });
  return deleted.length;
}

/** 회원 탈퇴 시 과거 메시지의 작성자 표시도 다시 쓴다. */
export async function renameSenderMessages(userId, newName) {
  await db.update(messages).set({ senderName: newName }).where(eq(messages.senderId, userId));
}

/**
 * 통합 검색. requesterId가 속한 방으로만 좁히는 건 room_members와의 join으로 강제한다(클라이언트가
 * roomId를 임의로 보내도 내 방이 아니면 절대 안 걸림 — 예전 myRoomIds.has(...) 필터와 동일한 보장).
 */
export async function searchMessages({ requesterId, roomId, senderId, since, until, q, limit }) {
  const conditions = [
    eq(roomMembers.userId, requesterId),
    or(sql`lower(${messages.text}) like ${`%${q}%`}`, sql`lower(${messages.fileName}) like ${`%${q}%`}`),
  ];
  if (roomId) conditions.push(eq(messages.roomId, roomId));
  if (senderId) conditions.push(eq(messages.senderId, senderId));
  if (since) conditions.push(gte(messages.createdAt, new Date(since)));
  if (until) conditions.push(lte(messages.createdAt, new Date(until)));

  const rows = await db
    .select({ message: messages })
    .from(messages)
    .innerJoin(roomMembers, eq(roomMembers.roomId, messages.roomId))
    .innerJoin(rooms, eq(rooms.id, messages.roomId))
    .where(and(eq(rooms.isSecret, false), ...conditions))
    .orderBy(desc(messages.createdAt))
    .limit(limit);
  return rows.map((r) => r.message);
}

/** 비밀 대화 자동 삭제(secretExpiry.js): 상대방이 읽어서 expiresAt이 잡힌 뒤 그 시각이
 * 지난 메시지. 최초 1회만 읽음 처리되도록 readAt이 아직 없을 때만 세팅한다. */
export async function markMessageRead(id, expiresAt) {
  const [row] = await db
    .update(messages)
    .set({ readAt: new Date(), expiresAt: expiresAt ? new Date(expiresAt) : null })
    .where(and(eq(messages.id, id), sql`${messages.readAt} is null`))
    .returning();
  return row ?? null;
}

export function findExpiredSecretMessages() {
  return db
    .select()
    .from(messages)
    .where(and(isNotNull(messages.expiresAt), lte(messages.expiresAt, new Date())));
}

/** 자동 삭제 타이머 만료 — 소프트 삭제가 아니라 행 자체를 완전히 없앤다(댓글도 FK cascade로
 * 함께 삭제됨 — 부모 없는 댓글 스레드가 남는 것보다 자연스러운 선택). */
export async function hardDeleteMessage(id) {
  const [row] = await db.delete(messages).where(eq(messages.id, id)).returning();
  return row ?? null;
}
