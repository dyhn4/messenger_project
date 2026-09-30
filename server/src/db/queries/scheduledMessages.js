import { and, asc, eq, inArray, lte, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { scheduledMessages } from '../schema.js';

// 사람이 고치거나 지울 수 있는 상태 — 'sending'(서버가 막 보내는 중)은 건드리지 못하게 한다.
const IDLE = ['scheduled', 'failed'];

export function findScheduledMessageById(id) {
  return db
    .select()
    .from(scheduledMessages)
    .where(eq(scheduledMessages.id, id))
    .then((rows) => rows[0] ?? null);
}

/** 내 예약 목록(그 팀) — 발송 실패를 먼저, 그다음 보낼 시각이 이른 순. [roomId]를 주면 그 방 것만. */
export function listScheduledMessages({ userId, teamId, roomId = null }) {
  const conditions = [eq(scheduledMessages.userId, userId), eq(scheduledMessages.teamId, teamId)];
  if (roomId) conditions.push(eq(scheduledMessages.roomId, roomId));
  return db
    .select()
    .from(scheduledMessages)
    .where(and(...conditions))
    .orderBy(
      sql`case when ${scheduledMessages.status} = 'failed' then 0 else 1 end`,
      asc(scheduledMessages.sendAt),
      asc(scheduledMessages.createdAt),
    );
}

/**
 * 개수 제한([max])을 넘지 않을 때만 만든다 — 같은 사람·같은 팀의 생성을 advisory 잠금으로 줄 세워서, 동시에
 * 여러 개를 만들어도 제한을 넘지 않게 한다. 넘으면 null.
 */
export function insertScheduledMessageWithinLimit(fields, max) {
  return db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtext(${`scheduled:${fields.userId}:${fields.teamId}`}))`);
    const [{ n }] = await tx
      .select({ n: sql`count(*)::int` })
      .from(scheduledMessages)
      .where(and(eq(scheduledMessages.userId, fields.userId), eq(scheduledMessages.teamId, fields.teamId)));
    if (Number(n) >= max) return null;
    const [row] = await tx.insert(scheduledMessages).values(fields).returning();
    return row;
  });
}

/**
 * 예약/발송 실패 상태일 때만 고친다(다시 예약됨으로 돌리는 수정 포함). 그사이 서버가 보내기 시작했으면(sending)
 * 아무것도 안 바꾸고 null. [limit]({userId, teamId, max})을 주면(다른 팀 방으로 옮길 때) 옮겨 갈 팀의 개수
 * 제한도 같은 잠금 안에서 본다 — 넘으면 'limit'.
 */
export function updateScheduledMessageIfIdle(id, fields, { limit = null } = {}) {
  return db.transaction(async (tx) => {
    if (limit) {
      await tx.execute(sql`select pg_advisory_xact_lock(hashtext(${`scheduled:${limit.userId}:${limit.teamId}`}))`);
      const [{ n }] = await tx
        .select({ n: sql`count(*)::int` })
        .from(scheduledMessages)
        .where(and(eq(scheduledMessages.userId, limit.userId), eq(scheduledMessages.teamId, limit.teamId)));
      if (Number(n) >= limit.max) return 'limit';
    }
    const [row] = await tx
      .update(scheduledMessages)
      .set({ ...fields, updatedAt: new Date() })
      .where(and(eq(scheduledMessages.id, id), inArray(scheduledMessages.status, IDLE)))
      .returning();
    return row ?? null;
  });
}

/** 예약 취소 — 보내는 중이 아닐 때만. 지웠으면 true. */
export async function deleteScheduledMessageIfIdle(id) {
  const rows = await db
    .delete(scheduledMessages)
    .where(and(eq(scheduledMessages.id, id), inArray(scheduledMessages.status, IDLE)))
    .returning({ id: scheduledMessages.id });
  return rows.length > 0;
}

/** 보낸 뒤 지운다(상태와 무관하게 — 이미 'sending'으로 찜한 행). */
export async function deleteScheduledMessage(id) {
  await db.delete(scheduledMessages).where(eq(scheduledMessages.id, id));
}

/** 이 사람의 예약을 전부 지운다(상태 무관) — 회원 탈퇴 때. 탈퇴한 계정 이름으로는 보낼 수 없어 남겨 둘 이유가 없다. */
export async function deleteScheduledMessagesForUser(userId) {
  await db.delete(scheduledMessages).where(eq(scheduledMessages.userId, userId));
}

/**
 * 보낼 시각이 된 예약을 'sending'으로 바꾸며 가져온다 — FOR UPDATE SKIP LOCKED로 찜하므로 서버가 여러 개
 * 떠 있어도 한 행은 한 번만 가져간다. 보낼 시각 순으로 돌려준다.
 */
export async function claimDueScheduledMessages(limit = 50) {
  const due = db
    .select({ id: scheduledMessages.id })
    .from(scheduledMessages)
    .where(and(eq(scheduledMessages.status, 'scheduled'), lte(scheduledMessages.sendAt, sql`now()`)))
    .orderBy(asc(scheduledMessages.sendAt), asc(scheduledMessages.createdAt))
    .limit(limit)
    .for('update', { skipLocked: true });
  const rows = await db
    .update(scheduledMessages)
    .set({ status: 'sending', updatedAt: new Date() })
    .where(and(inArray(scheduledMessages.id, due), eq(scheduledMessages.status, 'scheduled')))
    .returning();
  return rows.sort(
    (a, b) => new Date(a.sendAt) - new Date(b.sendAt) || new Date(a.createdAt) - new Date(b.createdAt),
  );
}

/** "지금 보내기" — 내 예약이 예약됨/발송 실패 상태일 때만 'sending'으로 찜한다. 못 찜했으면 null. */
export async function claimScheduledMessage(id, userId) {
  const [row] = await db
    .update(scheduledMessages)
    .set({ status: 'sending', updatedAt: new Date() })
    .where(
      and(
        eq(scheduledMessages.id, id),
        eq(scheduledMessages.userId, userId),
        inArray(scheduledMessages.status, IDLE),
      ),
    )
    .returning();
  return row ?? null;
}

/** 발송 실패로 표시한다 — [roomName]을 주면(방이 아직 있으면) 표시용 이름도 최신으로 맞춘다. */
export async function markScheduledMessageFailed(id, reason, roomName) {
  const [row] = await db
    .update(scheduledMessages)
    .set({
      status: 'failed',
      failReason: reason,
      ...(roomName !== undefined ? { roomName } : {}),
      updatedAt: new Date(),
    })
    .where(eq(scheduledMessages.id, id))
    .returning();
  return row ?? null;
}

/** 이 방의 아직 안 보낸 예약들(보관·삭제 때 실패로 돌릴 대상을 고른다). */
export function listScheduledForRoom(roomId, statuses = ['scheduled']) {
  return db
    .select()
    .from(scheduledMessages)
    .where(and(eq(scheduledMessages.roomId, roomId), inArray(scheduledMessages.status, statuses)));
}

/** 아직 예약됨 상태인 것만 골라 한꺼번에 발송 실패로 바꾸고, 바뀐 행을 돌려준다. */
export async function failScheduledMessages(ids, reason) {
  if (ids.length === 0) return [];
  return db
    .update(scheduledMessages)
    .set({ status: 'failed', failReason: reason, updatedAt: new Date() })
    .where(and(inArray(scheduledMessages.id, ids), eq(scheduledMessages.status, 'scheduled')))
    .returning();
}

/** 서버가 보내던 중에 꺼졌던 예약('sending'으로 남은 행) — 보냈는지 알 수 없으니 실패로 돌린다. */
export function failInterruptedScheduledMessages(reason) {
  return db
    .update(scheduledMessages)
    .set({ status: 'failed', failReason: reason, updatedAt: new Date() })
    .where(eq(scheduledMessages.status, 'sending'))
    .returning();
}
