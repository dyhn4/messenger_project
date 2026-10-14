import { and, asc, count, eq, isNull, lte, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { messageReminders, messages } from '../schema.js';

export async function insertReminder({ userId, messageId, roomId, remindAt }) {
  const [row] = await db.insert(messageReminders).values({ userId, messageId, roomId, remindAt }).returning();
  return row;
}

/** 아직 울리지 않은 내 리마인더 수 — 한 사람이 끝없이 쌓지 못하게(reminderRules.js REMINDER_MAX_PENDING). */
export async function countPendingReminders(userId) {
  const [row] = await db
    .select({ n: count() })
    .from(messageReminders)
    .where(and(eq(messageReminders.userId, userId), isNull(messageReminders.firedAt)));
  return Number(row?.n ?? 0);
}

/** 아직 울리지 않은 내 리마인더 — 울릴 시각 순, 원본 메시지와 함께(목록 화면의 미리보기). */
export function listPendingReminders(userId) {
  return db
    .select({ reminder: messageReminders, message: messages })
    .from(messageReminders)
    .innerJoin(messages, eq(messages.id, messageReminders.messageId))
    .where(and(eq(messageReminders.userId, userId), isNull(messageReminders.firedAt)))
    .orderBy(asc(messageReminders.remindAt));
}

/** 내 리마인더를 지운다(울리기 전 취소) — 지웠으면 true. */
export async function deleteReminder(id, userId) {
  const rows = await db
    .delete(messageReminders)
    .where(and(eq(messageReminders.id, id), eq(messageReminders.userId, userId), isNull(messageReminders.firedAt)))
    .returning({ id: messageReminders.id });
  return rows.length > 0;
}

/**
 * 울릴 때가 된 리마인더를 [limit]개까지 "울림"으로 찍고 돌려준다 — 찍는 것과 고르는 것을 한 문장으로 해서, 같은 리마인더를 두 번
 * 울리지 않는다(작업이 겹쳐도 먼저 찍은 쪽만 받는다).
 */
export function claimDueReminders(now, limit = 100) {
  return db
    .update(messageReminders)
    .set({ firedAt: now })
    .where(
      sql`${messageReminders.id} in (
        select ${messageReminders.id} from ${messageReminders}
        where ${messageReminders.firedAt} is null and ${messageReminders.remindAt} <= ${now}
        order by ${messageReminders.remindAt}
        limit ${limit}
        for update skip locked
      )`,
    )
    .returning();
}

/** 울린 지 오래된 리마인더 행을 지운다(목록에는 안 나오고 쌓이기만 하므로). */
export async function deleteFiredRemindersBefore(cutoff) {
  const rows = await db
    .delete(messageReminders)
    .where(lte(messageReminders.firedAt, cutoff))
    .returning({ id: messageReminders.id });
  return rows.length;
}
