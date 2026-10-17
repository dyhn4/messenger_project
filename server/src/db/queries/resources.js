import { and, asc, count, eq, gt, inArray, isNull, lt, ne } from 'drizzle-orm';
import { db } from '../client.js';
import { calendarEvents, resourceBookings, resources } from '../schema.js';

// ── 자원 ────────────────────────────────────────────────────────────────

export function listResources(scopeKey) {
  return db
    .select()
    .from(resources)
    .where(eq(resources.scopeKey, scopeKey))
    .orderBy(asc(resources.sortOrder), asc(resources.name));
}

export async function findResource(id) {
  const [row] = await db.select().from(resources).where(eq(resources.id, id));
  return row ?? null;
}

export async function countResources(scopeKey) {
  const [row] = await db.select({ n: count() }).from(resources).where(eq(resources.scopeKey, scopeKey));
  return Number(row?.n ?? 0);
}

/** 넣기 — 같은 범위에 같은 이름이 있으면 null. */
export async function insertResource(values) {
  const [row] = await db.insert(resources).values(values).onConflictDoNothing().returning();
  return row ?? null;
}

/** 고치기 — 같은 이름이 이미 있으면(unique) 'duplicate'. */
export async function updateResource(id, patch) {
  try {
    const [row] = await db.update(resources).set(patch).where(eq(resources.id, id)).returning();
    return row ?? null;
  } catch (err) {
    if (err?.code === '23505' || err?.cause?.code === '23505') return 'duplicate';
    throw err;
  }
}

export async function deleteResource(id) {
  await db.delete(resources).where(eq(resources.id, id));
}

// ── 예약 ────────────────────────────────────────────────────────────────

/** 예약 줄 + 자원 이름·종류 + 붙은 일정의 제목·공개 범위·만든 사람(일정 예약이면). */
const bookingColumns = {
  id: resourceBookings.id,
  scopeKey: resourceBookings.scopeKey,
  resourceId: resourceBookings.resourceId,
  resourceName: resources.name,
  resourceKind: resources.kind,
  userId: resourceBookings.userId,
  userName: resourceBookings.userName,
  teamId: resourceBookings.teamId,
  title: resourceBookings.title,
  startAt: resourceBookings.startAt,
  endAt: resourceBookings.endAt,
  eventId: resourceBookings.eventId,
  eventTitle: calendarEvents.title,
  eventVisibility: calendarEvents.visibility,
  eventCreatorId: calendarEvents.creatorId,
  createdAt: resourceBookings.createdAt,
};

const bookingQuery = () =>
  db
    .select(bookingColumns)
    .from(resourceBookings)
    .innerJoin(resources, eq(resources.id, resourceBookings.resourceId))
    .leftJoin(calendarEvents, eq(calendarEvents.id, resourceBookings.eventId));

/** [fromMs, toMs)와 겹치는 범위의 예약들(자원 하나로 좁히려면 [resourceId]) — 시작 순. */
export function listBookingsInRange({ scopeKey, fromMs, toMs, resourceId = null }) {
  const conditions = [
    eq(resourceBookings.scopeKey, scopeKey),
    lt(resourceBookings.startAt, new Date(toMs)),
    gt(resourceBookings.endAt, new Date(fromMs)),
  ];
  if (resourceId) conditions.push(eq(resourceBookings.resourceId, resourceId));
  return bookingQuery()
    .where(and(...conditions))
    .orderBy(asc(resourceBookings.startAt));
}

/** 내가 잡은, 아직 끝나지 않은 예약들(가까운 것부터 [limit]개). */
export function listUpcomingBookingsOf({ scopeKey, userId, nowMs, limit = 50 }) {
  return bookingQuery()
    .where(and(eq(resourceBookings.scopeKey, scopeKey), eq(resourceBookings.userId, userId), gt(resourceBookings.endAt, new Date(nowMs))))
    .orderBy(asc(resourceBookings.startAt))
    .limit(limit);
}

/** 캘린더 내장 "회의실 예약" — [teamId]에서 [userId]가 그룹웨어에서 바로 잡은(일정에 안 붙은) 예약 중 [fromMs, toMs)와 겹치는 것. */
export function listStandaloneBookingsForCalendar({ scopeKey, userId, fromMs, toMs }) {
  return bookingQuery().where(
    and(
      eq(resourceBookings.scopeKey, scopeKey),
      eq(resourceBookings.userId, userId),
      isNull(resourceBookings.eventId),
      lt(resourceBookings.startAt, new Date(toMs)),
      gt(resourceBookings.endAt, new Date(fromMs)),
    ),
  );
}

export async function findBooking(id) {
  const [row] = await bookingQuery().where(eq(resourceBookings.id, id));
  return row ?? null;
}

/** 일정마다 붙은 예약 — Map(eventId → 예약). */
export async function listBookingsForEvents(eventIds) {
  if (eventIds.length === 0) return new Map();
  const rows = await bookingQuery().where(inArray(resourceBookings.eventId, eventIds));
  return new Map(rows.map((r) => [r.eventId, r]));
}

export async function countUpcomingBookingsOf({ scopeKey, userId, nowMs }) {
  const [row] = await db
    .select({ n: count() })
    .from(resourceBookings)
    .where(and(eq(resourceBookings.scopeKey, scopeKey), eq(resourceBookings.userId, userId), gt(resourceBookings.endAt, new Date(nowMs))));
  return Number(row?.n ?? 0);
}

/**
 * 예약 넣기·옮기기 — 자원 행을 잠근 채(FOR UPDATE — 같은 자원의 예약을 한 줄로 세움) 겹치는 예약이 있는지 보고, 없으면 [values]를 넣는다
 * ([bookingId]를 주면 그 예약을 고친다 — 자기 자신과는 겹침을 보지 않음). 자원이 없거나 꺼졌으면 `{ missing }`, 겹치면 `{ conflict }`(겹친
 * 예약 줄), 아니면 `{ row }`.
 */
export function reserveResource({ resourceId, values, bookingId = null }) {
  return db.transaction(async (tx) => {
    const [resource] = await tx.select().from(resources).where(eq(resources.id, resourceId)).for('update');
    if (!resource || !resource.enabled) return { missing: true };
    const conditions = [
      eq(resourceBookings.resourceId, resourceId),
      lt(resourceBookings.startAt, values.endAt),
      gt(resourceBookings.endAt, values.startAt),
    ];
    if (bookingId) conditions.push(ne(resourceBookings.id, bookingId));
    const [conflict] = await tx
      .select()
      .from(resourceBookings)
      .where(and(...conditions))
      .orderBy(asc(resourceBookings.startAt))
      .limit(1);
    if (conflict) return { conflict };
    if (bookingId) {
      const [row] = await tx
        .update(resourceBookings)
        .set({ ...values, resourceId })
        .where(eq(resourceBookings.id, bookingId))
        .returning();
      return { row };
    }
    const [row] = await tx
      .insert(resourceBookings)
      .values({ ...values, resourceId, scopeKey: resource.scopeKey })
      .returning();
    return { row };
  });
}

/** 일정 예약의 시간만 옮기기(자원은 그대로) — reserveResource와 같은 잠금·겹침 검사. 꺼진 자원이어도 이미 잡힌 예약은 옮길 수 있다. */
export function moveBooking({ booking, startAt, endAt }) {
  return db.transaction(async (tx) => {
    await tx.select({ id: resources.id }).from(resources).where(eq(resources.id, booking.resourceId)).for('update');
    const [conflict] = await tx
      .select()
      .from(resourceBookings)
      .where(
        and(
          eq(resourceBookings.resourceId, booking.resourceId),
          ne(resourceBookings.id, booking.id),
          lt(resourceBookings.startAt, endAt),
          gt(resourceBookings.endAt, startAt),
        ),
      )
      .limit(1);
    if (conflict) return { conflict };
    const [row] = await tx.update(resourceBookings).set({ startAt, endAt }).where(eq(resourceBookings.id, booking.id)).returning();
    return { row };
  });
}

export async function deleteBooking(id) {
  await db.delete(resourceBookings).where(eq(resourceBookings.id, id));
}

/** 자원을 지우기 전에 — 앞으로의 예약을 잡은 사람들(알림용). */
export async function listUpcomingBookersOf(resourceId, nowMs) {
  const rows = await db
    .selectDistinct({ userId: resourceBookings.userId })
    .from(resourceBookings)
    .where(and(eq(resourceBookings.resourceId, resourceId), gt(resourceBookings.endAt, new Date(nowMs))));
  return rows.map((r) => r.userId).filter(Boolean);
}

