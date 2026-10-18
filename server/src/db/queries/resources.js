import { and, asc, count, eq, gt, gte, inArray, isNull, lt, lte, ne } from 'drizzle-orm';
import { sql } from 'drizzle-orm';
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
  status: resourceBookings.status,
  seriesId: resourceBookings.seriesId,
  remindedAt: resourceBookings.remindedAt,
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

/** 일정마다 붙은 예약들 — Map(eventId → [예약] — 자원 이름순). */
export async function listBookingsForEvents(eventIds) {
  if (eventIds.length === 0) return new Map();
  const rows = await bookingQuery()
    .where(inArray(resourceBookings.eventId, eventIds))
    .orderBy(asc(resources.sortOrder), asc(resources.name));
  const map = new Map();
  for (const r of rows) {
    if (!map.has(r.eventId)) map.set(r.eventId, []);
    map.get(r.eventId).push(r);
  }
  return map;
}

/**
 * 일정의 예약 맞추기 — 한 트랜잭션에서 관련 자원 행을 모두 잠그고(id 순 — 교착 없게) [plan]의 자원마다 겹침을 본 뒤, [removeIds] 예약을
 * 지우고 [plan]을 넣거나(bookingId 없음) 고친다(bookingId — 시간·제목). 이 일정의 다른 예약과는 겹침을 보지 않는다. 새로 잡는데 자원이
 * 없거나 꺼졌으면 `{ missing: resourceId }`, 겹치면 `{ conflict, resourceId }`, 아니면 `{ rows }`.
 */
export function applyEventBookings({ eventId, plan, removeIds = [] }) {
  return db.transaction(async (tx) => {
    const ids = [...new Set(plan.map((p) => p.resourceId))].sort();
    const locked = ids.length
      ? await tx.select().from(resources).where(inArray(resources.id, ids)).orderBy(asc(resources.id)).for('update')
      : [];
    for (const p of plan) {
      const r = locked.find((x) => x.id === p.resourceId);
      if (!r || (!p.bookingId && !r.enabled)) return { missing: p.resourceId };
      const conditions = [
        eq(resourceBookings.resourceId, p.resourceId),
        lt(resourceBookings.startAt, p.values.endAt),
        gt(resourceBookings.endAt, p.values.startAt),
      ];
      if (eventId) conditions.push(sql`${resourceBookings.eventId} is distinct from ${eventId}`);
      const [conflict] = await tx
        .select()
        .from(resourceBookings)
        .where(and(...conditions))
        .orderBy(asc(resourceBookings.startAt))
        .limit(1);
      if (conflict) return { conflict, resourceId: p.resourceId };
    }
    if (removeIds.length) await tx.delete(resourceBookings).where(inArray(resourceBookings.id, removeIds));
    const rows = [];
    for (const p of plan) {
      if (p.bookingId) {
        const [row] = await tx.update(resourceBookings).set(p.values).where(eq(resourceBookings.id, p.bookingId)).returning();
        rows.push(row);
      } else {
        const scopeKey = locked.find((x) => x.id === p.resourceId).scopeKey;
        const [row] = await tx
          .insert(resourceBookings)
          .values({ ...p.values, resourceId: p.resourceId, scopeKey, eventId })
          .returning();
        rows.push(row);
      }
    }
    return { rows };
  });
}

/**
 * 반복 예약 넣기 — 자원 행을 잠근 채 회차들([occurrences] `[{ startAt, endAt }]`)의 겹침을 보고, [skipConflicts]면 겹치는 회차만 빼고
 * 넣는다(아니면 하나라도 겹치면 아무것도 넣지 않음). `{ missing }` | `{ conflicts: [{ startAt, endAt, with }], rows }`.
 */
export function reserveSeries({ resourceId, occurrences, values, skipConflicts = false }) {
  return db.transaction(async (tx) => {
    const [resource] = await tx.select().from(resources).where(eq(resources.id, resourceId)).for('update');
    if (!resource || !resource.enabled) return { missing: true };
    const first = occurrences[0].startAt;
    const last = occurrences[occurrences.length - 1].endAt;
    const existing = await tx
      .select()
      .from(resourceBookings)
      .where(and(eq(resourceBookings.resourceId, resourceId), lt(resourceBookings.startAt, last), gt(resourceBookings.endAt, first)));
    const conflicts = [];
    const free = [];
    for (const o of occurrences) {
      const hit = existing.find((b) => b.startAt < o.endAt && o.startAt < b.endAt);
      if (hit) conflicts.push({ ...o, with: hit });
      else free.push(o);
    }
    if (conflicts.length && !skipConflicts) return { conflicts, rows: [] };
    if (free.length === 0) return { conflicts, rows: [] };
    const rows = await tx
      .insert(resourceBookings)
      .values(free.map((o) => ({ ...values, resourceId, scopeKey: resource.scopeKey, startAt: o.startAt, endAt: o.endAt })))
      .returning();
    return { conflicts, rows };
  });
}

/** 반복 예약 묶음에서 [fromMs] 이후(그 회차 포함)에 시작하는 예약들. */
export function listSeriesFrom(seriesId, fromMs) {
  return bookingQuery()
    .where(and(eq(resourceBookings.seriesId, seriesId), gte(resourceBookings.startAt, new Date(fromMs))))
    .orderBy(asc(resourceBookings.startAt));
}

export async function deleteBookings(ids) {
  if (ids.length) await db.delete(resourceBookings).where(inArray(resourceBookings.id, ids));
}

/** 승인 기다리는 예약(범위 — 끝나지 않은 것, 시작 순). */
export function listPendingBookings(scopeKey, nowMs) {
  return bookingQuery()
    .where(and(eq(resourceBookings.scopeKey, scopeKey), eq(resourceBookings.status, 'pending'), gt(resourceBookings.endAt, new Date(nowMs))))
    .orderBy(asc(resourceBookings.startAt));
}

/** 예약 상태 바꾸기(승인) — 기다리던 것만. 바뀐 줄 | null. */
export async function confirmBooking(id) {
  const [row] = await db
    .update(resourceBookings)
    .set({ status: 'confirmed' })
    .where(and(eq(resourceBookings.id, id), eq(resourceBookings.status, 'pending')))
    .returning();
  return row ?? null;
}

/** 시작 전 알림 후보 — 지금부터 [aheadMs] 안에 시작하고 아직 안 알린 잡힌 예약(모든 범위). */
export function listBookingsStartingSoon(nowMs, aheadMs) {
  return bookingQuery().where(
    and(
      isNull(resourceBookings.remindedAt),
      eq(resourceBookings.status, 'confirmed'),
      gt(resourceBookings.startAt, new Date(nowMs)),
      lte(resourceBookings.startAt, new Date(nowMs + aheadMs)),
    ),
  );
}

/** 알렸다고 적는다 — 아직 안 알린 것만(여러 서버 작업이 겹쳐도 한 번). true면 이번에 적음. */
export async function claimBookingReminder(id) {
  const rows = await db
    .update(resourceBookings)
    .set({ remindedAt: new Date() })
    .where(and(eq(resourceBookings.id, id), isNull(resourceBookings.remindedAt)))
    .returning({ id: resourceBookings.id });
  return rows.length > 0;
}

/** 태블릿 화면 열쇠로 자원 찾기. */
export async function findResourceByDisplayToken(token) {
  const [row] = await db.select().from(resources).where(eq(resources.displayToken, token)).limit(1);
  return row ?? null;
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

