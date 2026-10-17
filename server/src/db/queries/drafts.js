import { and, eq, gte, lt } from 'drizzle-orm';
import { db } from '../client.js';
import { chatDrafts, roomMembers, rooms } from '../schema.js';

/** 내 임시 저장 글 — 지금 멤버이고 비밀 대화가 아닌 방의 것, [since] 뒤에 고친 것만(지운 것 — 빈 글 — 도 포함). */
export function listMyDrafts(userId, since) {
  return db
    .select({
      roomId: chatDrafts.roomId,
      text: chatDrafts.text,
      textFormat: chatDrafts.textFormat,
      mentions: chatDrafts.mentions,
      updatedAt: chatDrafts.updatedAt,
    })
    .from(chatDrafts)
    .innerJoin(roomMembers, and(eq(roomMembers.roomId, chatDrafts.roomId), eq(roomMembers.userId, chatDrafts.userId)))
    .innerJoin(rooms, eq(rooms.id, chatDrafts.roomId))
    .where(and(eq(chatDrafts.userId, userId), eq(rooms.isSecret, false), gte(chatDrafts.updatedAt, since)));
}

/** 넣거나 바꾸기 — 저장한 시각(서버 시계)을 돌려준다. */
export async function upsertDraft(userId, roomId, values) {
  const now = new Date();
  const [row] = await db
    .insert(chatDrafts)
    .values({ userId, roomId, ...values, updatedAt: now })
    .onConflictDoUpdate({ target: [chatDrafts.userId, chatDrafts.roomId], set: { ...values, updatedAt: now } })
    .returning({ updatedAt: chatDrafts.updatedAt });
  return row.updatedAt;
}

/** 오래된 임시 저장 정리(30일 — drafts.js). 지운 수. */
export async function deleteDraftsBefore(cutoff) {
  const rows = await db.delete(chatDrafts).where(lt(chatDrafts.updatedAt, cutoff)).returning({ roomId: chatDrafts.roomId });
  return rows.length;
}
