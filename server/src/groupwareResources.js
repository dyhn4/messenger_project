import { Router } from 'express';
import { AUDIT, recordAudit } from './audit.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import {
  countResources,
  countUpcomingBookingsOf,
  deleteBooking,
  deleteResource,
  findBooking,
  findResource,
  insertResource,
  listBookingsInRange,
  listResources,
  listUpcomingBookersOf,
  listUpcomingBookingsOf,
  moveBooking,
  reserveResource,
  updateResource,
} from './db/queries/resources.js';
import { listTeamMemberIds } from './db/queries/teams.js';
import { isUuid } from './favoritesRules.js';
import { fail, groupwareContext } from './groupware.js';
import { effectiveGroupwareScope, groupwareScopeKey } from './groupwareScope.js';
import { notifyGroupwarePush } from './push.js';
import {
  BOOKING_QUERY_MAX_MS,
  BOOKINGS_PER_USER_MAX,
  RESOURCE_KIND_LABEL,
  RESOURCES_MAX,
  bookingDto,
  conflictText,
  kstText,
  parseBookingTimes,
  parseBookingTitle,
  parseResourceInput,
} from './resourceRules.js';

/**
 * 그룹웨어 회의실·자원 예약 — 자원(관리자가 만듦)과 예약(겹치지 않게 — resourceRules.js). 캘린더 일정에 자원을 붙이는 쪽(calendars.js)이
 * 쓰는 도우미도 여기 둔다: prepareEventResource·attachEventBooking·moveEventBooking·broadcastResources(일정 DTO의 자원 칸은 resourceRules.js eventResourceDto).
 */

export const resourceDto = (r) => ({
  id: r.id,
  kind: r.kind,
  kindLabel: RESOURCE_KIND_LABEL[r.kind] ?? '자원',
  name: r.name,
  location: r.location ?? null,
  capacity: r.capacity ?? null,
  description: r.description ?? null,
  enabled: r.enabled,
  sortOrder: r.sortOrder,
});

/** [teamId] 팀에서 쓰는 그룹웨어 범위 키(캘린더 쪽에서 — 그룹웨어 context 없이). */
export async function resourceScopeKeyForTeam(teamId) {
  return groupwareScopeKey(effectiveGroupwareScope(await getServerSettings()), teamId);
}

/** 범위 사람들의 그룹웨어 화면이 예약 현황을 다시 받게(groupware:changed `{ resources: true }`). */
export async function broadcastResources(io, scopeKey) {
  const data = { resources: true, scopeKey };
  if (scopeKey === 'server') {
    io.emit('groupware:changed', data);
    return;
  }
  for (const id of await listTeamMemberIds(scopeKey)) io.to(`user:${id}`).emit('groupware:changed', data);
}

/**
 * 캘린더 일정에 붙일 자원 검사 — [teamId] 팀의 그룹웨어 범위에 있고 켜진 자원이어야 하고, 준회원은 잡을 수 없다. `{ resource }` | `{ error, status }`.
 */
export async function prepareEventResource({ teamId, resourceId, role }) {
  if (!isUuid(resourceId)) return { error: '회의실·자원을 확인하세요.', status: 400 };
  if (role === 'guest') return { error: '준회원은 회의실·자원을 예약할 수 없습니다.', status: 403 };
  const resource = await findResource(resourceId);
  if (!resource || resource.scopeKey !== (await resourceScopeKeyForTeam(teamId))) {
    return { error: '회의실·자원을 찾을 수 없습니다.', status: 404 };
  }
  if (!resource.enabled) return { error: '지금은 예약할 수 없는 자원입니다.', status: 409 };
  return { resource };
}

/**
 * 일정에 자원 붙이기(새로 잡거나, [existing] 예약을 다른 자원·시간으로 옮김) — `{ row }` | `{ error, status }`. [range]는 eventBookingRange 값.
 * 지난 시간·7일 넘는 일정은 막는다(parseBookingTimes).
 */
export async function attachEventBooking({ eventId, title, resource, range, user, teamId, existing = null }) {
  const times = parseBookingTimes(range.startMs, range.endMs);
  if (times.error) return { error: `회의실·자원 — ${times.error}`, status: 400 };
  const result = await reserveResource({
    resourceId: resource.id,
    bookingId: existing?.id ?? null,
    values: {
      userId: user.id,
      userName: user.name ?? user.username,
      teamId,
      title,
      startAt: new Date(times.startMs),
      endAt: new Date(times.endMs),
      eventId,
    },
  });
  if (result.missing) return { error: '지금은 예약할 수 없는 자원입니다.', status: 409 };
  if (result.conflict) return { error: `${resource.name} — ${conflictText(result.conflict)}`, status: 409 };
  return { row: result.row };
}

/** 일정 시간이 바뀌어 붙은 예약을 옮긴다 — `{ row }` | `{ error, status }`. */
export async function moveEventBooking({ booking, range }) {
  const times = parseBookingTimes(range.startMs, range.endMs);
  if (times.error) return { error: `${booking.resourceName} 예약 — ${times.error} 회의실을 빼고 옮기세요.`, status: 400 };
  const result = await moveBooking({ booking, startAt: new Date(times.startMs), endAt: new Date(times.endMs) });
  if (result.conflict) return { error: `${booking.resourceName} — ${conflictText(result.conflict)}`, status: 409 };
  return { row: result.row };
}

export function createGroupwareResourcesRouter(io) {
  const router = Router();

  const withContext =
    (handler, { managerOnly = false } = {}) =>
    async (req, res) => {
      const ctx = await groupwareContext(req.user.sub, req.query.teamId ?? req.body?.teamId);
      if (ctx.error) return fail(res, ctx);
      if (managerOnly && !ctx.isManager) return fail(res, { error: '결재·근태 관리자만 할 수 있습니다.', status: 403 });
      return handler(req, res, ctx);
    };

  function audit(ctx, detail) {
    recordAudit({
      actorId: ctx.user.id,
      actorName: ctx.user.name ?? ctx.user.username,
      action: AUDIT.groupwareSettings,
      teamId: ctx.teamId,
      teamName: ctx.team?.name ?? null,
      detail,
    });
  }

  /** 예약이 바뀌면 — 범위의 그룹웨어 화면, 일정에 붙었거나 캘린더 내장 "회의실 예약"에 보이는 사람의 캘린더. */
  async function changed(ctx, booking = null) {
    await broadcastResources(io, ctx.scopeKey);
    if (booking?.userId && booking.teamId) {
      io.to(`user:${booking.userId}`).emit('calendar:changed', { teamId: booking.teamId, calendarId: 'bookings' });
    }
  }

  /** 범위 안의 자원(아니면 404로 응답하고 null). */
  async function loadResource(req, res, ctx) {
    const resource = isUuid(req.params.id) ? await findResource(req.params.id) : null;
    if (!resource || resource.scopeKey !== ctx.scopeKey) {
      fail(res, { error: '회의실·자원을 찾을 수 없습니다.', status: 404 });
      return null;
    }
    return resource;
  }

  // ── 자원 ──

  /**
   * 자원 목록 — 관리자가 아니면 켜진 것만. `?from=&to=`(ms)를 주면 자원마다 그 시간에 잡힌 예약(`busy` — 첫 겹침, 없으면 null)을 붙인다
   * (`eventId`를 주면 그 일정에 붙은 예약은 빼고 — 일정 편집 창이 고르는 중).
   */
  router.get(
    '/groupware/resources',
    withContext(async (req, res, ctx) => {
      const rows = (await listResources(ctx.scopeKey)).filter((r) => ctx.isManager || r.enabled);
      const from = Number(req.query.from);
      const to = Number(req.query.to);
      let busyByResource = null;
      if (Number.isSafeInteger(from) && Number.isSafeInteger(to) && to > from && to - from <= BOOKING_QUERY_MAX_MS) {
        const skipEvent = isUuid(req.query.eventId) ? req.query.eventId : null;
        busyByResource = new Map();
        for (const b of await listBookingsInRange({ scopeKey: ctx.scopeKey, fromMs: from, toMs: to })) {
          if (skipEvent && b.eventId === skipEvent) continue;
          if (!busyByResource.has(b.resourceId)) busyByResource.set(b.resourceId, bookingDto(b, { viewerId: ctx.user.id }));
        }
      }
      res.json(
        rows.map((r) => ({
          ...resourceDto(r),
          ...(busyByResource ? { busy: busyByResource.get(r.id) ?? null } : {}),
        })),
      );
    }),
  );

  router.post(
    '/groupware/resources',
    withContext(
      async (req, res, ctx) => {
        const parsed = parseResourceInput(req.body);
        if (parsed.error) return fail(res, parsed);
        if ((await countResources(ctx.scopeKey)) >= RESOURCES_MAX) return fail(res, { error: `자원은 ${RESOURCES_MAX}개까지 둘 수 있습니다.` });
        const row = await insertResource({ ...parsed.values, scopeKey: ctx.scopeKey });
        if (!row) return fail(res, { error: '같은 이름의 자원이 있습니다.', status: 409 });
        audit(ctx, `자원 추가 — ${RESOURCE_KIND_LABEL[row.kind]} ${row.name}`);
        await changed(ctx);
        res.status(201).json(resourceDto(row));
      },
      { managerOnly: true },
    ),
  );

  router.patch(
    '/groupware/resources/:id',
    withContext(
      async (req, res, ctx) => {
        const resource = await loadResource(req, res, ctx);
        if (!resource) return;
        const parsed = parseResourceInput(req.body, { partial: true });
        if (parsed.error) return fail(res, parsed);
        const row = await updateResource(resource.id, parsed.values);
        if (row === 'duplicate') return fail(res, { error: '같은 이름의 자원이 있습니다.', status: 409 });
        const what = [
          parsed.values.name && parsed.values.name !== resource.name ? `이름 ${resource.name} → ${parsed.values.name}` : null,
          parsed.values.enabled === false && resource.enabled ? '끔' : null,
          parsed.values.enabled === true && !resource.enabled ? '켬' : null,
        ].filter(Boolean);
        audit(ctx, `자원 ${row.name} 고침${what.length ? ` — ${what.join(', ')}` : ''}`);
        await changed(ctx);
        res.json(resourceDto(row));
      },
      { managerOnly: true },
    ),
  );

  /** 지우기 — 그 자원의 예약도 지운다(일정은 남고 회의실만 빠짐). 앞으로의 예약을 잡은 사람에게 알린다. */
  router.delete(
    '/groupware/resources/:id',
    withContext(
      async (req, res, ctx) => {
        const resource = await loadResource(req, res, ctx);
        if (!resource) return;
        const bookers = await listUpcomingBookersOf(resource.id, Date.now());
        await deleteResource(resource.id);
        audit(ctx, `자원 지움 — ${resource.name}${bookers.length ? ` (앞으로의 예약 ${bookers.length}명)` : ''}`);
        await changed(ctx);
        for (const userId of bookers) {
          if (userId === ctx.user.id) continue;
          io.to(`user:${userId}`).emit('calendar:changed', { teamId: ctx.teamId, calendarId: 'bookings' });
          notifyGroupwarePush({
            userId,
            title: '회의실·자원 예약 취소',
            body: `${resource.name}이(가) 없어져 잡아 둔 예약이 취소되었습니다.`,
            documentId: '',
            teamId: ctx.teamId,
          }).catch((err) => console.error('[groupware] 예약 취소 알림 실패:', err?.message ?? err));
        }
        res.json({ ok: true });
      },
      { managerOnly: true },
    ),
  );

  // ── 예약 ──

  /** 예약 현황 `?from=&to=`(ms, 31일 안) — 범위의 모든 자원. */
  router.get(
    '/groupware/bookings',
    withContext(async (req, res, ctx) => {
      const from = Number(req.query.from);
      const to = Number(req.query.to);
      if (!Number.isSafeInteger(from) || !Number.isSafeInteger(to) || to <= from) return fail(res, { error: 'from, to(ms)를 보내세요.' });
      if (to - from > BOOKING_QUERY_MAX_MS) return fail(res, { error: '조회 구간은 31일까지입니다.' });
      const rows = await listBookingsInRange({ scopeKey: ctx.scopeKey, fromMs: from, toMs: to });
      res.json(rows.map((b) => bookingDto(b, { viewerId: ctx.user.id, isManager: ctx.isManager })));
    }),
  );

  /** 내가 잡은 앞으로의 예약. */
  router.get(
    '/groupware/bookings/mine',
    withContext(async (req, res, ctx) => {
      const rows = await listUpcomingBookingsOf({ scopeKey: ctx.scopeKey, userId: ctx.user.id, nowMs: Date.now() });
      res.json(rows.map((b) => bookingDto(b, { viewerId: ctx.user.id, isManager: ctx.isManager })));
    }),
  );

  /** 예약하기 `{ resourceId, title?, start, end }`(ms) — 겹치면 409(겹친 예약을 알려 줌). */
  router.post(
    '/groupware/bookings',
    withContext(async (req, res, ctx) => {
      if (ctx.user.role === 'guest') return fail(res, { error: '준회원은 회의실·자원을 예약할 수 없습니다.', status: 403 });
      const resource = isUuid(req.body?.resourceId) ? await findResource(req.body.resourceId) : null;
      if (!resource || resource.scopeKey !== ctx.scopeKey) return fail(res, { error: '회의실·자원을 찾을 수 없습니다.', status: 404 });
      if (!resource.enabled) return fail(res, { error: '지금은 예약할 수 없는 자원입니다.', status: 409 });
      const times = parseBookingTimes(req.body?.start, req.body?.end);
      if (times.error) return fail(res, times);
      const title = parseBookingTitle(req.body?.title, resource.name);
      if (title.error) return fail(res, title);
      if ((await countUpcomingBookingsOf({ scopeKey: ctx.scopeKey, userId: ctx.user.id, nowMs: Date.now() })) >= BOOKINGS_PER_USER_MAX) {
        return fail(res, { error: `앞으로의 예약은 ${BOOKINGS_PER_USER_MAX}건까지 잡아 둘 수 있습니다.`, status: 429 });
      }
      const result = await reserveResource({
        resourceId: resource.id,
        values: {
          userId: ctx.user.id,
          userName: ctx.user.name ?? ctx.user.username,
          // 회사 전체 범위면 ctx.teamId가 없다 — 앱이 지금 보는 팀(캘린더의 내장 "회의실 예약"을 새로 받게 알릴 팀).
          teamId: ctx.teamId ?? (isUuid(req.body?.teamId) ? req.body.teamId : null),
          title: title.title,
          startAt: new Date(times.startMs),
          endAt: new Date(times.endMs),
          eventId: null,
        },
      });
      if (result.missing) return fail(res, { error: '지금은 예약할 수 없는 자원입니다.', status: 409 });
      if (result.conflict) return fail(res, { error: conflictText(result.conflict), status: 409 });
      await changed(ctx, result.row);
      res.status(201).json(bookingDto(await findBooking(result.row.id), { viewerId: ctx.user.id, isManager: ctx.isManager }));
    }),
  );

  /** 예약 취소 — 잡은 사람이나 관리자(남의 예약이면 잡은 사람에게 알림). 일정에 붙은 예약이면 일정은 남고 회의실만 빠진다. */
  router.delete(
    '/groupware/bookings/:id',
    withContext(async (req, res, ctx) => {
      const booking = isUuid(req.params.id) ? await findBooking(req.params.id) : null;
      if (!booking || booking.scopeKey !== ctx.scopeKey) return fail(res, { error: '예약을 찾을 수 없습니다.', status: 404 });
      const mine = booking.userId === ctx.user.id;
      if (!mine && !ctx.isManager) return fail(res, { error: '잡은 사람이나 관리자만 취소할 수 있습니다.', status: 403 });
      await deleteBooking(booking.id);
      await changed(ctx, booking);
      if (booking.eventId && booking.teamId) {
        io.to(`user:${booking.eventCreatorId ?? booking.userId}`).emit('calendar:changed', { teamId: booking.teamId, calendarId: null });
      }
      if (!mine && booking.userId) {
        audit(ctx, `예약 취소 — ${booking.resourceName} ${kstText(booking.startAt.getTime())} ${booking.userName}`);
        notifyGroupwarePush({
          userId: booking.userId,
          title: '회의실·자원 예약 취소',
          body: `관리자가 ${booking.resourceName} ${kstText(booking.startAt.getTime())} 예약을 취소했습니다.`,
          documentId: '',
          teamId: ctx.teamId,
        }).catch((err) => console.error('[groupware] 예약 취소 알림 실패:', err?.message ?? err));
      }
      res.json({ ok: true });
    }),
  );

  return router;
}
