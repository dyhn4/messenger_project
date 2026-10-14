import { and, asc, eq, inArray } from 'drizzle-orm';
import { db } from '../client.js';
import { messageReactions } from '../schema.js';

/** 메시지들의 공감 행 — 누른 순서대로(먼저 누른 사람이 앞). */
export async function listReactionsForMessages(messageIds) {
  if (messageIds.length === 0) return [];
  return db
    .select({ messageId: messageReactions.messageId, userId: messageReactions.userId, emoji: messageReactions.emoji })
    .from(messageReactions)
    .where(inArray(messageReactions.messageId, messageIds))
    .orderBy(asc(messageReactions.createdAt));
}

/** 내 공감을 [emoji]로 — 이미 다른 것을 눌렀으면 바꾼다(바꾸면 맨 뒤로 간다 — 새로 누른 것으로 친다). */
export async function setReaction(messageId, userId, emoji) {
  await db
    .insert(messageReactions)
    .values({ messageId, userId, emoji })
    .onConflictDoUpdate({
      target: [messageReactions.messageId, messageReactions.userId],
      set: { emoji, createdAt: new Date() },
    });
}

/** 내 공감을 뺀다. */
export async function removeReaction(messageId, userId) {
  await db.delete(messageReactions).where(and(eq(messageReactions.messageId, messageId), eq(messageReactions.userId, userId)));
}
