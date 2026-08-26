import { asc, eq, inArray } from 'drizzle-orm';
import { db } from '../client.js';
import { messageComments } from '../schema.js';

export async function insertComment(fields) {
  const [row] = await db.insert(messageComments).values(fields).returning();
  return row;
}

/** 여러 메시지의 댓글을 한 번에(생성 순) 가져온다 — 호출부에서 messageId별로 묶는다. */
export function listCommentsForMessages(messageIds) {
  if (messageIds.length === 0) return Promise.resolve([]);
  return db
    .select()
    .from(messageComments)
    .where(inArray(messageComments.messageId, messageIds))
    .orderBy(asc(messageComments.createdAt));
}

export function findCommentById(id) {
  return db
    .select()
    .from(messageComments)
    .where(eq(messageComments.id, id))
    .then((rows) => rows[0] ?? null);
}

export async function updateCommentText(id, text) {
  const [row] = await db
    .update(messageComments)
    .set({ text, editedAt: new Date() })
    .where(eq(messageComments.id, id))
    .returning();
  return row;
}

/** 소프트 삭제 — 행은 남기고(원본 메시지처럼 참조가 필요하진 않지만 동일 패턴 유지) deletedAt만
 * 찍는다. text는 지우지 않고 남겨두되, toCommentDto가 deletedAt이 찍힌 건 null로 가린다. */
export async function softDeleteComment(id) {
  const [row] = await db
    .update(messageComments)
    .set({ deletedAt: new Date() })
    .where(eq(messageComments.id, id))
    .returning();
  return row;
}
