import { and, desc, eq, inArray, isNotNull, isNull, ne, notExists, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { messages, postReads, roomMembers, users } from '../schema.js';

/** 방의 지금 멤버 이름 — 탈퇴한 사람은 뺀다(읽음 확인). */
export async function listRoomMemberNames(roomId) {
  const rows = await db
    .select({ id: users.id, name: users.name, username: users.username })
    .from(roomMembers)
    .innerJoin(users, eq(users.id, roomMembers.userId))
    .where(and(eq(roomMembers.roomId, roomId), isNull(users.deletedAt)));
  return rows.map((r) => ({ id: r.id, name: r.name ?? r.username }));
}

export function listPostReads(messageId) {
  return db.select({ userId: postReads.userId, readAt: postReads.readAt }).from(postReads).where(eq(postReads.messageId, messageId));
}

/** 읽음 기록 — 처음 연 시각만 남긴다. 새로 찍었으면 true. */
export async function markPostRead(messageId, userId) {
  const rows = await db.insert(postReads).values({ messageId, userId }).onConflictDoNothing().returning({ userId: postReads.userId });
  return rows.length > 0;
}

/** [messageIds] 중 [userId]가 읽은 것. */
export async function readPostIdsOf(userId, messageIds) {
  if (messageIds.length === 0) return new Set();
  const rows = await db
    .select({ messageId: postReads.messageId })
    .from(postReads)
    .where(and(eq(postReads.userId, userId), inArray(postReads.messageId, messageIds)));
  return new Set(rows.map((r) => r.messageId));
}

export async function setPostMustRead(messageId, on) {
  const [row] = await db
    .update(messages)
    .set({ mustReadAt: on ? new Date() : null })
    .where(eq(messages.id, messageId))
    .returning();
  return row;
}

/** 방의 필독 게시글 중 [userId]가 아직 안 읽은 것(쓴 사람 것은 뺌) — 최근 필독 지정순. */
export function listUnreadMustRead(roomId, userId) {
  return db
    .select({ id: messages.id, title: messages.title, createdAt: messages.createdAt, mustReadAt: messages.mustReadAt })
    .from(messages)
    .where(
      and(
        eq(messages.roomId, roomId),
        eq(messages.type, 'post'),
        isNull(messages.deletedAt),
        isNotNull(messages.mustReadAt),
        or(isNull(messages.senderId), ne(messages.senderId, userId)),
        notExists(
          db
            .select({ one: sql`1` })
            .from(postReads)
            .where(and(eq(postReads.messageId, messages.id), eq(postReads.userId, userId))),
        ),
      ),
    )
    .orderBy(desc(messages.mustReadAt))
    .limit(100);
}
