import { and, asc, eq, gt, inArray, isNotNull, isNull, lt, ne, or, sql } from 'drizzle-orm';
import { db } from '../client.js';
import {
  calendarEventAttendees,
  calendarEventColors,
  calendarEvents,
  calendarMembers,
  calendars,
  teamMembers,
  users,
} from '../schema.js';

// ── 캘린더 ──────────────────────────────────────────────────────────────

export function findCalendarById(id) {
  return db
    .select()
    .from(calendars)
    .where(eq(calendars.id, id))
    .then((rows) => rows[0] ?? null);
}

export function findCalendarsByIds(ids) {
  if (ids.length === 0) return Promise.resolve([]);
  return db.select().from(calendars).where(inArray(calendars.id, ids));
}

/**
 * 사람·팀마다 하나뿐인 기본 캘린더를 (없으면) 만들고 돌려준다. unique index(calendars_personal_owner_idx)가
 * 있어서 두 요청이 동시에 처음 열어도 한쪽은 onConflictDoNothing으로 조용히 물러나고, 둘 다 재조회로 같은 행을 본다.
 */
export async function ensurePersonalCalendar(teamId, ownerId, { name, color }) {
  await db
    .insert(calendars)
    .values({ teamId, kind: 'personal', name, color, ownerId, isPublic: true })
    .onConflictDoNothing();
  const [row] = await db
    .select()
    .from(calendars)
    .where(and(eq(calendars.teamId, teamId), eq(calendars.kind, 'personal'), eq(calendars.ownerId, ownerId)));
  return row;
}

/** 팀 캘린더(팀마다 하나) — ensurePersonalCalendar와 같은 방식(calendars_team_kind_idx). */
export async function ensureTeamCalendar(teamId, { name, color }) {
  await db.insert(calendars).values({ teamId, kind: 'team', name, color, ownerId: null, isPublic: true }).onConflictDoNothing();
  const [row] = await db
    .select()
    .from(calendars)
    .where(and(eq(calendars.teamId, teamId), eq(calendars.kind, 'team')));
  return row;
}

/** 새 공유 캘린더 + 만든 사람의 관리자(admin) 멤버 행을 한 트랜잭션으로. */
export function insertSharedCalendar({ teamId, name, color, isPublic, ownerId }) {
  return db.transaction(async (tx) => {
    const [row] = await tx
      .insert(calendars)
      .values({ teamId, kind: 'shared', name, color, isPublic, ownerId })
      .returning();
    const [member] = await tx.insert(calendarMembers).values({ calendarId: row.id, userId: ownerId, role: 'admin' }).returning();
    return { calendar: row, member };
  });
}

export async function updateCalendar(id, patch) {
  const [row] = await db.update(calendars).set(patch).where(eq(calendars.id, id)).returning();
  return row;
}

export async function deleteCalendar(id) {
  await db.delete(calendars).where(eq(calendars.id, id));
}

/**
 * 이 사람이 (팀 안에서) 볼 수 있을 만한 캘린더 후보와 내 멤버 행 — 팀 캘린더 + 내 기본 캘린더 + 내 행이 있는 것
 * (멤버·구독). 진짜 볼 수 있는지는 calendarAccess가 판정한다(비공개로 바뀐 구독, 팀 밖으로 나간 옛 소유자 등).
 * 팀 안의 모든 사람의 기본 캘린더를 끌어오지 않도록 여기서 좁힌다.
 */
export function listCalendarCandidates(teamId, userId) {
  return db
    .select({ calendar: calendars, member: calendarMembers })
    .from(calendars)
    .leftJoin(calendarMembers, and(eq(calendarMembers.calendarId, calendars.id), eq(calendarMembers.userId, userId)))
    .where(
      and(
        eq(calendars.teamId, teamId),
        or(eq(calendars.kind, 'team'), eq(calendars.ownerId, userId), isNotNull(calendarMembers.userId)),
      ),
    )
    .orderBy(asc(calendars.createdAt))
    .then((rows) => rows.map((r) => ({ calendar: r.calendar, member: r.member?.userId ? r.member : null })));
}

/** id → 이름(사람 이름 표시용). */
export function listUserNames(ids) {
  if (ids.length === 0) return Promise.resolve(new Map());
  return db
    .select({ id: users.id, name: users.name, username: users.username })
    .from(users)
    .where(inArray(users.id, ids))
    .then((rows) => new Map(rows.map((r) => [r.id, r.name ?? r.username])));
}

/** 이 팀의 팀 멤버 id 집합 — 팀 밖으로 나간 사람의 기본 캘린더를 구독 목록에서 빼는 데 쓴다. */
export function listTeamMemberIdSet(teamId) {
  return db
    .select({ userId: teamMembers.userId })
    .from(teamMembers)
    .where(eq(teamMembers.teamId, teamId))
    .then((rows) => new Set(rows.map((r) => r.userId)));
}

/** 팀 멤버 중 준회원이 아닌 사람 id — 팀 캘린더가 바뀌었을 때 알릴 사람들. */
export function listTeamNonGuestMemberIds(teamId) {
  return db
    .select({ userId: teamMembers.userId })
    .from(teamMembers)
    .innerJoin(users, eq(users.id, teamMembers.userId))
    .where(and(eq(teamMembers.teamId, teamId), ne(users.role, 'guest'), isNull(users.deletedAt)))
    .then((rows) => rows.map((r) => r.userId));
}

// ── 멤버·구독 ───────────────────────────────────────────────────────────

export function findCalendarMember(calendarId, userId) {
  return db
    .select()
    .from(calendarMembers)
    .where(and(eq(calendarMembers.calendarId, calendarId), eq(calendarMembers.userId, userId)))
    .then((rows) => rows[0] ?? null);
}

/** 여러 캘린더에 대한 내 멤버 행 — calendarId → 행. */
export function listMemberRowsForUser(userId, calendarIds) {
  if (calendarIds.length === 0) return Promise.resolve(new Map());
  return db
    .select()
    .from(calendarMembers)
    .where(and(eq(calendarMembers.userId, userId), inArray(calendarMembers.calendarId, calendarIds)))
    .then((rows) => new Map(rows.map((r) => [r.calendarId, r])));
}

/** 내 개인 설정(색·숨김)을 저장한다 — 행이 없으면 [roleIfNew]로 만든다(팀 캘린더·기본 캘린더는 권한이 계산값이라 행이 없을 수 있다). */
export async function upsertMemberPreferences(calendarId, userId, patch, roleIfNew) {
  const [row] = await db
    .insert(calendarMembers)
    .values({ calendarId, userId, role: roleIfNew, ...patch })
    .onConflictDoUpdate({ target: [calendarMembers.calendarId, calendarMembers.userId], set: patch })
    .returning();
  return row;
}

/** 구독 행을 만든다(이미 멤버·구독이면 그대로 둔다). */
export async function insertSubscriber(calendarId, userId) {
  await db.insert(calendarMembers).values({ calendarId, userId, role: 'subscriber' }).onConflictDoNothing();
}

/** 멤버 행 추가(구독자였다면 멤버로 올린다). 이미 admin/write/read 멤버면 null. */
export async function addMemberRow(calendarId, userId, role) {
  const existing = await findCalendarMember(calendarId, userId);
  if (existing && existing.role !== 'subscriber') return null;
  if (existing) {
    const [row] = await db
      .update(calendarMembers)
      .set({ role })
      .where(and(eq(calendarMembers.calendarId, calendarId), eq(calendarMembers.userId, userId)))
      .returning();
    return row;
  }
  const [row] = await db
    .insert(calendarMembers)
    .values({ calendarId, userId, role })
    .onConflictDoNothing()
    .returning();
  return row ?? null;
}

export async function setMemberRole(calendarId, userId, role) {
  const [row] = await db
    .update(calendarMembers)
    .set({ role })
    .where(and(eq(calendarMembers.calendarId, calendarId), eq(calendarMembers.userId, userId)))
    .returning();
  return row ?? null;
}

export async function deleteMemberRow(calendarId, userId) {
  const rows = await db
    .delete(calendarMembers)
    .where(and(eq(calendarMembers.calendarId, calendarId), eq(calendarMembers.userId, userId)))
    .returning({ userId: calendarMembers.userId });
  return rows.length > 0;
}

/** 멤버(admin/write/read) 목록 — 구독자는 뺀다. 소유자·관리자 먼저, 그다음 이름순. */
export function listMembersWithUsers(calendarId) {
  return db
    .select({ userId: calendarMembers.userId, role: calendarMembers.role, name: users.name, username: users.username, createdAt: calendarMembers.createdAt })
    .from(calendarMembers)
    .innerJoin(users, eq(users.id, calendarMembers.userId))
    .where(and(eq(calendarMembers.calendarId, calendarId), ne(calendarMembers.role, 'subscriber')))
    .orderBy(asc(calendarMembers.createdAt));
}

/** 캘린더에 딸린 모든 사람 id(멤버 + 구독자) — 변경 알림 대상. */
export function listCalendarPeopleIds(calendarId) {
  return db
    .select({ userId: calendarMembers.userId })
    .from(calendarMembers)
    .where(eq(calendarMembers.calendarId, calendarId))
    .then((rows) => rows.map((r) => r.userId));
}

/** 캘린더 안 모든 일정의 참석자 id — 캘린더를 지울 때 그 사람들에게도 알리려고 미리 모은다. */
export function listAttendeeIdsOfCalendar(calendarId) {
  return db
    .selectDistinct({ userId: calendarEventAttendees.userId })
    .from(calendarEventAttendees)
    .innerJoin(calendarEvents, eq(calendarEvents.id, calendarEventAttendees.eventId))
    .where(eq(calendarEvents.calendarId, calendarId))
    .then((rows) => rows.map((r) => r.userId));
}

/**
 * 구독 검색 — 이 팀의 공개 기본 캘린더(이름·소유자 이름)와 공개 공유 캘린더(이름). 내 기본 캘린더와 내가 이미 멤버인
 * 것은 뺀다. 소유자가 팀에서 나간 기본 캘린더도 뺀다. subscribed=내가 구독 중인지.
 */
export async function searchSubscribableCalendars(teamId, userId, q, limit = 50) {
  const like = q ? `%${q.replace(/[\\%_]/g, (c) => `\\${c}`)}%` : null;
  const rows = await db
    .select({
      calendar: calendars,
      ownerName: users.name,
      ownerUsername: users.username,
      memberRole: calendarMembers.role,
    })
    .from(calendars)
    .leftJoin(users, eq(users.id, calendars.ownerId))
    .leftJoin(calendarMembers, and(eq(calendarMembers.calendarId, calendars.id), eq(calendarMembers.userId, userId)))
    .where(
      and(
        eq(calendars.teamId, teamId),
        eq(calendars.isPublic, true),
        inArray(calendars.kind, ['personal', 'shared']),
        // 내 기본 캘린더는 이미 "내 캘린더"이므로 뺀다. owner가 null(탈퇴로 set null)인 shared는 남긴다.
        or(isNull(calendars.ownerId), ne(calendars.ownerId, userId)),
        or(isNull(calendarMembers.role), eq(calendarMembers.role, 'subscriber')),
        // 팀을 나간 사람의 기본 캘린더, 탈퇴한 사람의 기본 캘린더는 뺀다.
        or(
          eq(calendars.kind, 'shared'),
          and(
            isNull(users.deletedAt),
            inArray(
              calendars.ownerId,
              db.select({ id: teamMembers.userId }).from(teamMembers).where(eq(teamMembers.teamId, teamId)),
            ),
          ),
        ),
        like
          ? or(
              sql`${calendars.name} ilike ${like}`,
              and(eq(calendars.kind, 'personal'), sql`${users.name} ilike ${like}`),
            )
          : undefined,
      ),
    )
    .orderBy(asc(calendars.kind), asc(calendars.name))
    .limit(limit);
  return rows;
}

// ── 일정 ────────────────────────────────────────────────────────────────

export function findEventById(id) {
  return db
    .select()
    .from(calendarEvents)
    .where(eq(calendarEvents.id, id))
    .then((rows) => rows[0] ?? null);
}

/** 일정 + 참석자 + (있으면) 만든 사람의 개인 색을 한 트랜잭션으로 만든다. */
export function insertEvent(values, { attendeeIds = [], colors = [] } = {}) {
  return db.transaction(async (tx) => {
    const [row] = await tx.insert(calendarEvents).values(values).returning();
    if (attendeeIds.length > 0) {
      await tx.insert(calendarEventAttendees).values(attendeeIds.map((userId) => ({ eventId: row.id, userId })));
    }
    if (colors.length > 0) {
      await tx.insert(calendarEventColors).values(colors.map(({ userId, color }) => ({ eventId: row.id, userId, color })));
    }
    return row;
  });
}

/** 일정 행을 고치고, [attendeeIds]가 주어지면 참석자를 통째로 바꾼다. */
export function updateEvent(id, patch, { attendeeIds } = {}) {
  return db.transaction(async (tx) => {
    const [row] = await tx
      .update(calendarEvents)
      .set({ ...patch, updatedAt: new Date() })
      .where(eq(calendarEvents.id, id))
      .returning();
    if (attendeeIds) {
      await tx.delete(calendarEventAttendees).where(eq(calendarEventAttendees.eventId, id));
      if (attendeeIds.length > 0) {
        await tx.insert(calendarEventAttendees).values(attendeeIds.map((userId) => ({ eventId: id, userId })));
      }
    }
    return row;
  });
}

export async function deleteEvent(id) {
  await db.delete(calendarEvents).where(eq(calendarEvents.id, id));
}

/**
 * "이 일정만"·"이 일정부터" 편집: 원본 시리즈를 고치고 새 일정을 만드는 것을 한 트랜잭션으로 묶는다.
 * [master]는 원본에 적용할 변경(recurrence·exdates), [created]는 새 일정 값. 새 일정은 원본의 참석자와 모든
 * 사람의 개인 색을 물려받는다(참석자를 [attendeeIds]로 바꿨다면 그 목록).
 */
export function splitEvent(masterId, masterPatch, created, { attendeeIds } = {}) {
  return db.transaction(async (tx) => {
    await tx
      .update(calendarEvents)
      .set({ ...masterPatch, updatedAt: new Date() })
      .where(eq(calendarEvents.id, masterId));
    const [row] = await tx.insert(calendarEvents).values(created).returning();
    const attendees = attendeeIds
      ? attendeeIds
      : await tx
          .select({ userId: calendarEventAttendees.userId })
          .from(calendarEventAttendees)
          .where(eq(calendarEventAttendees.eventId, masterId))
          .then((rs) => rs.map((r) => r.userId));
    if (attendees.length > 0) {
      await tx.insert(calendarEventAttendees).values(attendees.map((userId) => ({ eventId: row.id, userId })));
    }
    const colors = await tx.select().from(calendarEventColors).where(eq(calendarEventColors.eventId, masterId));
    if (colors.length > 0) {
      await tx.insert(calendarEventColors).values(colors.map((c) => ({ eventId: row.id, userId: c.userId, color: c.color })));
    }
    return row;
  });
}

/**
 * 조회 구간에 걸칠 수 있는 일정 — [calendarIds]에 속한 것 + 내가 참석자로 초대된 것(그 팀 안에서만).
 * 반복 일정은 시작이 구간 끝 전이기만 하면 후보다(회차 펼치기가 정확히 가른다). 종일 일정은 날짜를 한국 날짜로
 * 해석해 겹침을 재므로(calendars.js) UTC 자정 표현과 최대 9시간 어긋난다 — 후보를 그만큼 넉넉히 가져온다.
 */
export function listEventsForWindow({ teamId, calendarIds, attendeeUserId, fromMs, toMs, slackMs }) {
  const from = new Date(fromMs - slackMs);
  const to = new Date(toMs + slackMs);
  const attendeeEventIds = db
    .select({ id: calendarEventAttendees.eventId })
    .from(calendarEventAttendees)
    .where(eq(calendarEventAttendees.userId, attendeeUserId));
  return db
    .select({ event: calendarEvents, creatorName: users.name, creatorUsername: users.username })
    .from(calendarEvents)
    .innerJoin(calendars, eq(calendars.id, calendarEvents.calendarId))
    .leftJoin(users, eq(users.id, calendarEvents.creatorId))
    .where(
      and(
        eq(calendars.teamId, teamId),
        calendarIds.length > 0
          ? or(inArray(calendarEvents.calendarId, calendarIds), inArray(calendarEvents.id, attendeeEventIds))
          : inArray(calendarEvents.id, attendeeEventIds),
        lt(calendarEvents.startAt, to),
        or(isNotNull(calendarEvents.recurrence), gt(calendarEvents.endAt, from)),
      ),
    )
    .then((rows) =>
      rows.map((r) => ({ ...r.event, creatorName: r.creatorName ?? r.creatorUsername ?? null })),
    );
}

export function findEventWithCreatorName(id) {
  return db
    .select({ event: calendarEvents, creatorName: users.name, creatorUsername: users.username })
    .from(calendarEvents)
    .leftJoin(users, eq(users.id, calendarEvents.creatorId))
    .where(eq(calendarEvents.id, id))
    .then((rows) => (rows[0] ? { ...rows[0].event, creatorName: rows[0].creatorName ?? rows[0].creatorUsername ?? null } : null));
}

/** 일정들의 참석자 — eventId → [{ userId, name }]. */
export async function listAttendeesForEvents(eventIds) {
  const map = new Map();
  if (eventIds.length === 0) return map;
  const rows = await db
    .select({ eventId: calendarEventAttendees.eventId, userId: calendarEventAttendees.userId, name: users.name, username: users.username })
    .from(calendarEventAttendees)
    .innerJoin(users, eq(users.id, calendarEventAttendees.userId))
    .where(inArray(calendarEventAttendees.eventId, eventIds))
    .orderBy(asc(users.name));
  for (const r of rows) {
    if (!map.has(r.eventId)) map.set(r.eventId, []);
    map.get(r.eventId).push({ userId: r.userId, name: r.name ?? r.username });
  }
  return map;
}

/** 내가 일정에 고른 색 — eventId → '#RRGGBB'. */
export function listEventColorsForUser(eventIds, userId) {
  if (eventIds.length === 0) return Promise.resolve(new Map());
  return db
    .select()
    .from(calendarEventColors)
    .where(and(eq(calendarEventColors.userId, userId), inArray(calendarEventColors.eventId, eventIds)))
    .then((rows) => new Map(rows.map((r) => [r.eventId, r.color])));
}

export async function setEventColor(eventId, userId, color) {
  await db
    .insert(calendarEventColors)
    .values({ eventId, userId, color })
    .onConflictDoUpdate({ target: [calendarEventColors.eventId, calendarEventColors.userId], set: { color } });
}

/** 참석자로 초대할 수 있는 사람인지 걸러낸다 — 이 팀 멤버이고 탈퇴·정지하지 않은 사람 id만 돌려준다. */
export function filterInvitableUserIds(teamId, userIds) {
  if (userIds.length === 0) return Promise.resolve([]);
  return db
    .select({ id: users.id })
    .from(teamMembers)
    .innerJoin(users, eq(users.id, teamMembers.userId))
    .where(
      and(
        eq(teamMembers.teamId, teamId),
        inArray(teamMembers.userId, userIds),
        isNull(users.deletedAt),
        isNull(users.suspendedAt),
      ),
    )
    .then((rows) => rows.map((r) => r.id));
}

/** 생일이 있는 팀 멤버(탈퇴한 사람 제외) — 생일 캘린더용. */
export function listTeamBirthdays(teamId) {
  return db
    .select({ id: users.id, name: users.name, username: users.username, birthday: users.birthday })
    .from(teamMembers)
    .innerJoin(users, eq(users.id, teamMembers.userId))
    .where(and(eq(teamMembers.teamId, teamId), isNotNull(users.birthday), isNull(users.deletedAt)));
}
