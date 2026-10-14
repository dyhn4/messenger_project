import { and, asc, count, eq, gt, inArray, isNull, lt, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import { calendarFeeds, externalCalendarEvents, externalCalendars } from '../schema.js';

// ── 외부 캘린더 구독(가져오기) ──

export function listExternalCalendars(userId, teamId) {
  return db
    .select()
    .from(externalCalendars)
    .where(and(eq(externalCalendars.userId, userId), eq(externalCalendars.teamId, teamId)))
    .orderBy(asc(externalCalendars.createdAt));
}

export async function countExternalCalendars(userId, teamId) {
  const [row] = await db
    .select({ n: count() })
    .from(externalCalendars)
    .where(and(eq(externalCalendars.userId, userId), eq(externalCalendars.teamId, teamId)));
  return Number(row?.n ?? 0);
}

export async function insertExternalCalendar(values) {
  const [row] = await db.insert(externalCalendars).values(values).returning();
  return row;
}

export async function findExternalCalendar(id) {
  const [row] = await db.select().from(externalCalendars).where(eq(externalCalendars.id, id));
  return row ?? null;
}

export async function updateExternalCalendar(id, patch) {
  const [row] = await db.update(externalCalendars).set(patch).where(eq(externalCalendars.id, id)).returning();
  return row ?? null;
}

export async function deleteExternalCalendar(id) {
  const rows = await db.delete(externalCalendars).where(eq(externalCalendars.id, id)).returning({ id: externalCalendars.id });
  return rows.length > 0;
}

/** 다시 받을 때가 된 구독 — 한 번도 안 받았거나 [before]보다 전에 받은 것, 오래된 것부터. */
export function listDueExternalCalendars(before, limit) {
  return db
    .select()
    .from(externalCalendars)
    .where(or(isNull(externalCalendars.lastFetchedAt), lt(externalCalendars.lastFetchedAt, before)))
    .orderBy(sql`${externalCalendars.lastFetchedAt} asc nulls first`)
    .limit(limit);
}

/** 받은 회차로 통째로 바꾼다(지난 것은 지우고 새로 넣는다) — 구독 행의 상태도 같은 트랜잭션에서 바꾼다. */
export async function replaceExternalEvents(calendarId, occurrences, patch) {
  return db.transaction(async (tx) => {
    await tx.delete(externalCalendarEvents).where(eq(externalCalendarEvents.externalCalendarId, calendarId));
    for (let i = 0; i < occurrences.length; i += 500) {
      await tx.insert(externalCalendarEvents).values(
        occurrences.slice(i, i + 500).map((o) => ({
          externalCalendarId: calendarId,
          uid: o.uid,
          title: o.title,
          description: o.description,
          location: o.location,
          startAt: new Date(o.start),
          endAt: new Date(o.end),
          allDay: o.allDay,
        })),
      );
    }
    const [row] = await tx.update(externalCalendars).set(patch).where(eq(externalCalendars.id, calendarId)).returning();
    return row ?? null;
  });
}

/** [calendarIds]의 회차 중 [fromMs - slackMs, toMs + slackMs)와 겹치는 것(종일 회차의 날짜 맞춤은 호출부가 다시 거른다). */
export function listExternalEventsForWindow(calendarIds, fromMs, toMs, slackMs, limit) {
  if (calendarIds.length === 0) return [];
  return db
    .select()
    .from(externalCalendarEvents)
    .where(
      and(
        inArray(externalCalendarEvents.externalCalendarId, calendarIds),
        lt(externalCalendarEvents.startAt, new Date(toMs + slackMs)),
        gt(externalCalendarEvents.endAt, new Date(fromMs - slackMs)),
      ),
    )
    .orderBy(asc(externalCalendarEvents.startAt))
    .limit(limit);
}

// ── 내 일정 내보내기(ICS 구독 주소) ──

export async function findCalendarFeed(userId, teamId) {
  const [row] = await db
    .select()
    .from(calendarFeeds)
    .where(and(eq(calendarFeeds.userId, userId), eq(calendarFeeds.teamId, teamId)));
  return row ?? null;
}

export async function findCalendarFeedByHash(tokenHash) {
  const [row] = await db.select().from(calendarFeeds).where(eq(calendarFeeds.tokenHash, tokenHash));
  return row ?? null;
}

/** 새 토큰으로 만들거나 바꾼다 — 예전 주소는 바로 끊긴다. */
export async function upsertCalendarFeed({ userId, teamId, tokenHash, tokenEnc }) {
  const [row] = await db
    .insert(calendarFeeds)
    .values({ userId, teamId, tokenHash, tokenEnc })
    .onConflictDoUpdate({
      target: [calendarFeeds.userId, calendarFeeds.teamId],
      set: { tokenHash, tokenEnc, createdAt: new Date(), lastAccessAt: null },
    })
    .returning();
  return row;
}

export async function deleteCalendarFeed(userId, teamId) {
  const rows = await db
    .delete(calendarFeeds)
    .where(and(eq(calendarFeeds.userId, userId), eq(calendarFeeds.teamId, teamId)))
    .returning({ id: calendarFeeds.id });
  return rows.length > 0;
}

export async function touchCalendarFeed(id, at) {
  await db.update(calendarFeeds).set({ lastAccessAt: at }).where(eq(calendarFeeds.id, id));
}
