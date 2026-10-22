import { and, asc, eq, gt, isNotNull, lte, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { dmHistoryFloors, messageRemovals, messages, roomMembers, rooms } from '../schema.js';

/** [at] 다음부터(같은 시각이면 [afterId]보다 큰 id부터) — 커서는 (시각, id) 순서라 같은 시각에 여럿 바뀌어도 건너뛰지 않는다. */
function afterCursor(atColumn, idColumn, at, afterId) {
  return afterId ? or(gt(atColumn, at), and(eq(atColumn, at), gt(idColumn, afterId))) : gt(atColumn, at);
}

/**
 * [userId]가 멤버인 평문 방에서 보낸 뒤에 바뀐 메시지 — (바뀐 시각, id) 순으로 커서([since]·[afterId]) 다음부터 [until]까지 [limit]개.
 * DM "진짜 나가기" 이력(dm_history_floors)보다 오래된 메시지는 이 사람에게 없는 것이라 뺀다(rooms.js의 목록과 같은 규칙).
 */
export async function listChangedMessagesForUser(userId, { since, afterId = null, until, limit }) {
  const rows = await db
    .select({ message: messages })
    .from(messages)
    .innerJoin(roomMembers, and(eq(roomMembers.roomId, messages.roomId), eq(roomMembers.userId, userId)))
    .innerJoin(rooms, and(eq(rooms.id, messages.roomId), eq(rooms.isSecret, false)))
    .leftJoin(dmHistoryFloors, and(eq(dmHistoryFloors.roomId, messages.roomId), eq(dmHistoryFloors.userId, userId)))
    .where(
      and(
        isNotNull(messages.changedAt),
        lte(messages.changedAt, until),
        afterCursor(messages.changedAt, messages.id, since, afterId),
        sql`(${dmHistoryFloors.hiddenBeforeAt} is null or ${messages.createdAt} >= ${dmHistoryFloors.hiddenBeforeAt})`,
      ),
    )
    .orderBy(asc(messages.changedAt), asc(messages.id))
    .limit(limit);
  return rows.map((r) => r.message);
}

/** [userId]가 멤버인 방에서 완전히 지운 메시지의 흔적 — [listChangedMessagesForUser]와 같은 커서·순서. */
export function listRemovalsForUser(userId, { since, afterId = null, until, limit }) {
  return db
    .select({ id: messageRemovals.messageId, roomId: messageRemovals.roomId, removedAt: messageRemovals.removedAt })
    .from(messageRemovals)
    .innerJoin(roomMembers, and(eq(roomMembers.roomId, messageRemovals.roomId), eq(roomMembers.userId, userId)))
    .where(
      and(
        lte(messageRemovals.removedAt, until),
        afterCursor(messageRemovals.removedAt, messageRemovals.messageId, since, afterId),
      ),
    )
    .orderBy(asc(messageRemovals.removedAt), asc(messageRemovals.messageId))
    .limit(limit);
}
