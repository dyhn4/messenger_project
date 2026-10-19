import { and, desc, eq, inArray, isNotNull, isNull, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { callRecordings, messages } from '../schema.js';

/** 녹화 한 번을 시작했다고 적는다(callRecording.js) — 만든 줄. */
export async function insertCallRecording(values) {
  const [row] = await db.insert(callRecordings).values(values).returning();
  return row;
}

export function findCallRecording(id) {
  return db
    .select()
    .from(callRecordings)
    .where(eq(callRecordings.id, id))
    .then((rows) => rows[0] ?? null);
}

/** 녹화 줄을 고친다 — 고친 줄(없으면 null). */
export async function updateCallRecording(id, values) {
  const [row] = await db
    .update(callRecordings)
    .set({ ...values, updatedAt: new Date() })
    .where(eq(callRecordings.id, id))
    .returning();
  return row ?? null;
}

/**
 * [from] 상태일 때만 [values]로 고친다 — 고쳤으면 그 줄, 그사이 다른 쪽이 먼저 바꿨으면 null(멈추기를 두 번 누름·통화 종료와 멈추기가
 * 겹침 — 마무리를 한 번만 하게).
 */
export async function transitionCallRecording(id, from, values) {
  const [row] = await db
    .update(callRecordings)
    .set({ ...values, updatedAt: new Date() })
    .where(and(eq(callRecordings.id, id), eq(callRecordings.status, from)))
    .returning();
  return row ?? null;
}

/** 회의록 단계를 [from] 중 하나일 때만 [values]로 — 다시 만들기를 두 번 눌러도 한 번만 돈다. */
export async function transitionCallMinutes(id, from, values) {
  const [row] = await db
    .update(callRecordings)
    .set({ ...values, updatedAt: new Date() })
    .where(and(eq(callRecordings.id, id), inArray(callRecordings.minutesStatus, from)))
    .returning();
  return row ?? null;
}

/** 지금 녹화 중인 이 방의 줄(통화마다 한 번에 하나) — 없으면 null. */
export function findRecordingInRoom(roomId) {
  return db
    .select()
    .from(callRecordings)
    .where(and(eq(callRecordings.roomId, roomId), eq(callRecordings.status, 'recording')))
    .orderBy(desc(callRecordings.startedAt))
    .limit(1)
    .then((rows) => rows[0] ?? null);
}

/** 서버가 켜질 때 이어서 마무리할 줄들 — 녹화 중·마무리 중이었거나 회의록을 만들던 중. */
export function listUnfinishedCallRecordings() {
  return db
    .select()
    .from(callRecordings)
    .where(
      sql`${callRecordings.status} in ('recording', 'processing') or ${callRecordings.minutesStatus} in ('pending', 'transcribing', 'summarizing')`,
    );
}

/** 한 화상회의 카드에 딸린 녹화들(시작 순) — 카드에 싣는 요약을 다시 만들 때. */
export function listRecordingsForCallMessage(callMessageId) {
  return db
    .select()
    .from(callRecordings)
    .where(eq(callRecordings.callMessageId, callMessageId))
    .orderBy(callRecordings.startedAt);
}

/**
 * 이 방에서 가장 최근의 화상회의 카드 — 서버가 재시작돼 카드 없이 되살린 통화에서 녹화할 때 그 회의의 처음 카드에 붙인다(그 카드는
 * 서버가 켜질 때 종료로 닫혔지만 같은 회의다). 없으면 null.
 */
export function findLatestCallCardMessage(roomId) {
  return db
    .select({ id: messages.id })
    .from(messages)
    .where(and(eq(messages.roomId, roomId), isNotNull(messages.callCard), isNull(messages.deletedAt)))
    .orderBy(desc(messages.createdAt))
    .limit(1)
    .then((rows) => rows[0]?.id ?? null);
}
