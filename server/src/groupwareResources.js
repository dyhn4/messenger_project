import crypto from 'node:crypto';
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
  applyEventBookings,
  reserveSeries,
  listSeriesFrom,
  deleteBookings,
  listPendingBookings,
  confirmBooking,
  listBookingsStartingSoon,
  claimBookingReminder,
} from './db/queries/resources.js';
import { findGroupwareOptions, listGroupwareMembers } from './db/queries/groupware.js';
import { canManageGroupware } from './groupwareScope.js';
import {
  BOOKING_REMINDER_DEFAULT,
  checkBookingPolicy,
  EVENT_RESOURCES_MAX,
  initialBookingStatus,
  isApproverOf,
  parseResourcePolicy,
  remindersDue,
  resourceStats,
  seriesOccurrences,
  suggestResources,
} from './resourcePolicy.js';
import { listTeamMemberIds } from './db/queries/teams.js';
import { isUuid } from './favoritesRules.js';
import { approverCandidates, fail, groupwareContext } from './groupware.js';
import { effectiveGroupwareScope, groupwareScopeKey } from './groupwareScope.js';
import { notifyGroupwarePush } from './push.js';
import {
  BOOKING_QUERY_MAX_MS,
  BOOKINGS_PER_USER_MAX,
  RESOURCE_KIND_LABEL,
  RESOURCES_MAX,
  bookingDto,
  conflictText,
  eventResourceDto,
  kstText,
  parseBookingTimes,
  parseBookingTitle,
  parseResourceInput,
} from './resourceRules.js';

/**
 * 그룹웨어 회의실·자원 예약 — 자원(관리자가 만듦)과 예약(겹치지 않게 — resourceRules.js). 캘린더 일정에 자원을 붙이는 쪽(calendars.js)이
 * 쓰는 도우미도 여기 둔다: prepareEventResource·attachEventBooking·moveEventBooking·broadcastResources(일정 DTO의 자원 칸은 resourceRules.js eventResourceDto).
 */

/** 자원 → 화면 모양. 태블릿 화면 주소는 관리자에게만([isManager]). */
export const resourceDto = (r, { isManager = false } = {}) => ({
  id: r.id,
  kind: r.kind,
  kindLabel: RESOURCE_KIND_LABEL[r.kind] ?? '자원',
  name: r.name,
  location: r.location ?? null,
  capacity: r.capacity ?? null,
  description: r.description ?? null,
  enabled: r.enabled,
  sortOrder: r.sortOrder,
  // 예약 규칙(resourcePolicy.js).
  requiresApproval: !!r.requiresApproval,
  approverIds: r.approverIds ?? [],
  allowedUserIds: r.allowedUserIds ?? [],
  availableDays: r.availableDays ?? null,
  availableFrom: r.availableFrom ?? null,
  availableTo: r.availableTo ?? null,
  maxMinutes: r.maxMinutes ?? null,
  displayQuickBook: !!r.displayQuickBook,
  ...(isManager ? { displayPath: r.displayToken ? `/room-display/${r.displayToken}` : null } : {}),
});

/** 이 범위에서 승인할 사람 — 자원에 정한 사람, 없으면 그룹웨어 관리자들. */
async function approversOf(resource, scopeKey) {
  if (Array.isArray(resource.approverIds) && resource.approverIds.length) return resource.approverIds;
  const scope = scopeKey === 'server' ? 'server' : 'team';
  const members = await listGroupwareMembers({ scope, teamId: scope === 'team' ? scopeKey : null });
  return members.filter((m) => !m.suspendedAt && canManageGroupware({ scope, role: m.role, isOwner: m.isOwner })).map((m) => m.id);
}

/** 승인 요청을 알린다(승인할 사람에게 — 잡은 사람은 빼고). */
async function notifyApprovalRequest(io, resource, booking) {
  const targets = (await approversOf(resource, booking.scopeKey)).filter((id) => id !== booking.userId);
  for (const userId of targets) {
    io.to(`user:${userId}`).emit('groupware:changed', { resources: true, pending: true, scopeKey: booking.scopeKey });
    notifyGroupwarePush({
      userId,
      title: '회의실·자원 예약 승인 요청',
      body: `${booking.userName} — ${resource.name} ${kstText(new Date(booking.startAt).getTime())}`,
      documentId: '',
      teamId: booking.teamId ?? null,
    }).catch((err) => console.error('[groupware] 승인 요청 알림 실패:', err?.message ?? err));
  }
}

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

/**
 * 일정의 자원들 맞추기(일정 하나에 여러 자원 — 회의실 + 장비, [EVENT_RESOURCES_MAX]개까지). [resourceIds]가 undefined면 지금 붙은 자원 그대로
 * 시간만 옮기고, 목록이면 그대로 맞춘다(빠진 것은 지우고 새것은 잡음). 자원마다 예약 규칙(resourcePolicy.js checkBookingPolicy)을 보고, 승인이
 * 필요한 자원은 '승인 기다림'으로 잡아 승인할 사람에게 알린다. 겹치면 아무것도 바꾸지 않는다(한 트랜잭션). [existing]은 지금 붙은 예약들.
 * `{ scopes: [바뀐 범위], rows }` | `{ error, status }`.
 */
export async function syncEventResources({ io, eventId, title, resourceIds, existing = [], range, user, teamId, role }) {
  const desired = resourceIds === undefined ? existing.map((b) => b.resourceId) : [...new Set(resourceIds)];
  if (desired.length > EVENT_RESOURCES_MAX) return { error: `일정 하나에 회의실·자원은 ${EVENT_RESOURCES_MAX}개까지 붙일 수 있습니다.`, status: 400 };
  if (!desired.every(isUuid)) return { error: '회의실·자원을 확인하세요.', status: 400 };
  const removeIds = existing.filter((b) => !desired.includes(b.resourceId)).map((b) => b.id);
  if (desired.length === 0) {
    if (!removeIds.length) return { scopes: [], rows: [] };
    await deleteBookings(removeIds);
    return { scopes: [...new Set(existing.map((b) => b.scopeKey))], rows: [] };
  }
  const times = parseBookingTimes(range.startMs, range.endMs);
  if (times.error) return { error: `회의실·자원 — ${times.error}`, status: 400 };
  if (role === 'guest' && desired.some((id) => !existing.some((b) => b.resourceId === id))) {
    return { error: '준회원은 회의실·자원을 예약할 수 없습니다.', status: 403 };
  }
  const scopeKey = await resourceScopeKeyForTeam(teamId);
  const gw = await groupwareContext(user.id, teamId).catch(() => null);
  const isManager = !!gw && !gw.error && gw.isManager;
  const startAt = new Date(times.startMs);
  const endAt = new Date(times.endMs);
  const plan = [];
  const resourcesById = new Map();
  for (const id of desired) {
    const resource = await findResource(id);
    if (!resource || resource.scopeKey !== scopeKey) return { error: '회의실·자원을 찾을 수 없습니다.', status: 404 };
    resourcesById.set(id, resource);
    const ex = existing.find((b) => b.resourceId === id);
    if (!ex && !resource.enabled) return { error: `${resource.name} — 지금은 예약할 수 없는 자원입니다.`, status: 409 };
    const policy = checkBookingPolicy(resource, { userId: user.id, startMs: times.startMs, endMs: times.endMs, privileged: isManager });
    if (policy) return { error: policy.error, status: 403 };
    if (ex) {
      if (ex.startAt.getTime() !== times.startMs || ex.endAt.getTime() !== times.endMs) plan.push({ resourceId: id, bookingId: ex.id, values: { startAt, endAt } });
      continue;
    }
    plan.push({
      resourceId: id,
      bookingId: null,
      values: {
        userId: user.id,
        userName: user.name ?? user.username,
        teamId,
        title,
        startAt,
        endAt,
        status: initialBookingStatus(resource, { userId: user.id, isManager }),
      },
    });
  }
  if (!plan.length && !removeIds.length) return { scopes: [], rows: [] };
  const result = await applyEventBookings({ eventId, plan, removeIds });
  if (result.missing) return { error: `${resourcesById.get(result.missing)?.name ?? '자원'} — 지금은 예약할 수 없는 자원입니다.`, status: 409 };
  if (result.conflict) return { error: `${resourcesById.get(result.resourceId)?.name ?? '자원'} — ${conflictText({ ...result.conflict, userName: result.conflict.userName })}`, status: 409 };
  for (const row of result.rows) {
    if (row.status === 'pending' && plan.some((p) => !p.bookingId && p.resourceId === row.resourceId)) {
      await notifyApprovalRequest(io, resourcesById.get(row.resourceId), row);
    }
  }
  return { scopes: [scopeKey], rows: result.rows };
}

/** 일정 DTO의 자원 칸들 — `resource`(첫 자원 — 예전 앱)와 `resources`(모두). */
export const eventResourcesDto = (bookings) => {
  const list = (bookings ?? []).map(eventResourceDto);
  return { resource: list[0] ?? null, resources: list };
};

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
          ...resourceDto(r, { isManager: ctx.isManager }),
          ...(busyByResource ? { busy: busyByResource.get(r.id) ?? null } : {}),
          // 내가 이 자원을 예약할 수 있는지(예약할 수 있는 사람 — 관리자는 늘), 승인이 필요한지.
          canBook: ctx.isManager || !(r.allowedUserIds ?? []).length || (r.allowedUserIds ?? []).includes(ctx.user.id),
          needsApproval: r.requiresApproval && !isApproverOf(r, { userId: ctx.user.id, isManager: ctx.isManager }),
        })),
      );
    }),
  );

  /**
   * 회의실 추천 `?start=&end=(ms)&attendees=&kind=`(기본 회의실) — 그 시간에 비어 있고 내가 예약할 수 있고 수용 인원이 참석자 수 이상인 자원,
   * 남는 자리가 적은 것부터(resourcePolicy.js suggestResources). `eventId`를 주면 그 일정에 붙은 예약은 비어 있는 것으로 본다.
   */
  router.get(
    '/groupware/resources/suggest',
    withContext(async (req, res, ctx) => {
      const start = Number(req.query.start);
      const end = Number(req.query.end);
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || end <= start || end - start > BOOKING_QUERY_MAX_MS) {
        return fail(res, { error: '시간(start·end ms)을 확인하세요.' });
      }
      const attendees = Math.max(0, Math.min(1000, Number.parseInt(req.query.attendees, 10) || 0));
      const kind = ['room', 'equipment', 'vehicle'].includes(req.query.kind) ? req.query.kind : 'room';
      const skipEvent = isUuid(req.query.eventId) ? req.query.eventId : null;
      const [all, busy] = await Promise.all([
        listResources(ctx.scopeKey),
        listBookingsInRange({ scopeKey: ctx.scopeKey, fromMs: start, toMs: end }),
      ]);
      const list = suggestResources({
        resources: all,
        busy: busy.filter((b) => !skipEvent || b.eventId !== skipEvent),
        startMs: start,
        endMs: end,
        attendees,
        kind,
        userId: ctx.user.id,
        privileged: ctx.isManager,
      });
      res.json(list.map((s) => ({ ...resourceDto(s.resource), spare: s.spare, needsApproval: s.needsApproval })));
    }),
  );

  /**
   * 사용 통계(관리자) `?from=&to=`(ms, 기본 지난 30일, 366일까지) — 자원마다 건수·쓴 시간·이용률·쓴 사람 수·많이 쓴 사람·요일별
   * (resourcePolicy.js resourceStats).
   */
  router.get(
    '/groupware/resources/stats',
    withContext(
      async (req, res, ctx) => {
        const now = Date.now();
        const to = Number.isSafeInteger(Number(req.query.to)) && req.query.to ? Number(req.query.to) : now;
        const from = Number.isSafeInteger(Number(req.query.from)) && req.query.from ? Number(req.query.from) : to - 30 * 86_400_000;
        if (to <= from || to - from > 366 * 86_400_000) return fail(res, { error: '기간은 366일 안으로 고르세요.' });
        const [all, bookings] = await Promise.all([
          listResources(ctx.scopeKey),
          listBookingsInRange({ scopeKey: ctx.scopeKey, fromMs: from, toMs: to }),
        ]);
        res.json({ from, to, resources: resourceStats({ resources: all, bookings, fromMs: from, toMs: to }) });
      },
      { managerOnly: true },
    ),
  );

  router.post(
    '/groupware/resources',
    withContext(
      async (req, res, ctx) => {
        const parsed = parseResourceInput(req.body);
        if (parsed.error) return fail(res, parsed);
        const policy = await parsedPolicy(ctx, req.body, {});
        if (policy.error) return fail(res, policy);
        if ((await countResources(ctx.scopeKey)) >= RESOURCES_MAX) return fail(res, { error: `자원은 ${RESOURCES_MAX}개까지 둘 수 있습니다.` });
        const row = await insertResource({ ...parsed.values, ...policy.values, scopeKey: ctx.scopeKey });
        if (!row) return fail(res, { error: '같은 이름의 자원이 있습니다.', status: 409 });
        audit(ctx, `자원 추가 — ${RESOURCE_KIND_LABEL[row.kind]} ${row.name}`);
        await changed(ctx);
        res.status(201).json(resourceDto(row, { isManager: true }));
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
        // 기본 칸과 예약 규칙 칸 — 둘 중 하나만 보내도 된다.
        const policy = await parsedPolicy(ctx, req.body, resource);
        if (policy.error) return fail(res, policy);
        const hasPolicy = Object.keys(policy.values).length > 0;
        const parsed = parseResourceInput(req.body, { partial: true });
        if (parsed.error && !(hasPolicy && parsed.error === '바꿀 내용이 없습니다.')) return fail(res, parsed);
        const row = await updateResource(resource.id, { ...(parsed.values ?? {}), ...policy.values });
        if (row === 'duplicate') return fail(res, { error: '같은 이름의 자원이 있습니다.', status: 409 });
        const what = [
          parsed.values.name && parsed.values.name !== resource.name ? `이름 ${resource.name} → ${parsed.values.name}` : null,
          parsed.values.enabled === false && resource.enabled ? '끔' : null,
          parsed.values.enabled === true && !resource.enabled ? '켬' : null,
        ].filter(Boolean);
        audit(ctx, `자원 ${row.name} 고침${what.length ? ` — ${what.join(', ')}` : ''}`);
        await changed(ctx);
        res.json(resourceDto(row, { isManager: true }));
      },
      { managerOnly: true },
    ),
  );

  /** 예약 규칙 입력 검사(승인할 사람·예약할 수 있는 사람은 이 범위의 결재자 후보 중에서). */
  async function parsedPolicy(ctx, body, current) {
    const candidates = await approverCandidates(ctx);
    return parseResourcePolicy(body, { isCandidate: (id) => candidates.has(id), current });
  }

  /**
   * 회의실 앞 태블릿 화면 켜기(관리자) — 주소의 열쇠를 새로 만든다(이미 있으면 바꿔 예전 주소는 못 씀). `{ displayPath }`. 끄기는 DELETE.
   */
  router.post(
    '/groupware/resources/:id/display',
    withContext(
      async (req, res, ctx) => {
        const resource = await loadResource(req, res, ctx);
        if (!resource) return;
        const token = crypto.randomBytes(18).toString('base64url');
        const row = await updateResource(resource.id, { displayToken: token });
        audit(ctx, `${resource.displayToken ? '태블릿 화면 주소 바꿈' : '태블릿 화면 켬'} — ${resource.name}`);
        res.json(resourceDto(row, { isManager: true }));
      },
      { managerOnly: true },
    ),
  );

  router.delete(
    '/groupware/resources/:id/display',
    withContext(
      async (req, res, ctx) => {
        const resource = await loadResource(req, res, ctx);
        if (!resource) return;
        const row = await updateResource(resource.id, { displayToken: null });
        audit(ctx, `태블릿 화면 끔 — ${resource.name}`);
        res.json(resourceDto(row, { isManager: true }));
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

  /** 승인 기다리는 예약 — 그룹웨어 관리자는 범위 전부, 아니면 내가 승인할 사람으로 정해진 자원의 것. */
  router.get(
    '/groupware/bookings/pending',
    withContext(async (req, res, ctx) => {
      const [rows, all] = await Promise.all([listPendingBookings(ctx.scopeKey, Date.now()), listResources(ctx.scopeKey)]);
      const byId = new Map(all.map((r) => [r.id, r]));
      res.json(
        rows
          .filter((b) => byId.has(b.resourceId) && isApproverOf(byId.get(b.resourceId), { userId: ctx.user.id, isManager: ctx.isManager }))
          .map((b) => bookingDto(b, { viewerId: ctx.user.id, isManager: true })),
      );
    }),
  );

  /** 승인·거절(그 자원의 승인할 사람이나 그룹웨어 관리자) — 거절은 `{ reason? }`, 예약을 지우고 잡은 사람에게 알린다. 반복 예약이면 [series]로 이후 모두. */
  for (const action of ['approve', 'reject']) {
    router.post(
      `/groupware/bookings/:id/${action}`,
      withContext(async (req, res, ctx) => {
        const booking = isUuid(req.params.id) ? await findBooking(req.params.id) : null;
        if (!booking || booking.scopeKey !== ctx.scopeKey) return fail(res, { error: '예약을 찾을 수 없습니다.', status: 404 });
        const resource = await findResource(booking.resourceId);
        if (!resource || !isApproverOf(resource, { userId: ctx.user.id, isManager: ctx.isManager })) {
          return fail(res, { error: '이 자원의 예약을 승인할 수 없습니다.', status: 403 });
        }
        if (booking.status !== 'pending') return fail(res, { error: '승인을 기다리는 예약이 아닙니다.', status: 409 });
        const targets =
          req.body?.series === true && booking.seriesId
            ? (await listSeriesFrom(booking.seriesId, booking.startAt.getTime())).filter((b) => b.status === 'pending')
            : [booking];
        const reason = typeof req.body?.reason === 'string' ? req.body.reason.trim().slice(0, 200) : '';
        if (action === 'approve') for (const b of targets) await confirmBooking(b.id);
        else await deleteBookings(targets.map((b) => b.id));
        audit(ctx, `${action === 'approve' ? '예약 승인' : '예약 거절'} — ${resource.name} ${kstText(booking.startAt.getTime())} ${booking.userName}${targets.length > 1 ? ` 외 ${targets.length - 1}회` : ''}`);
        await changed(ctx, booking);
        if (booking.userId && booking.userId !== ctx.user.id) {
          notifyGroupwarePush({
            userId: booking.userId,
            title: action === 'approve' ? '회의실·자원 예약 승인' : '회의실·자원 예약 거절',
            body:
              action === 'approve'
                ? `${resource.name} ${kstText(booking.startAt.getTime())} 예약이 승인되었습니다.`
                : `${resource.name} ${kstText(booking.startAt.getTime())} 예약이 거절되었습니다.${reason ? ` (${reason})` : ''}`,
            documentId: '',
            teamId: booking.teamId ?? null,
          }).catch((err) => console.error('[groupware] 예약 승인 알림 실패:', err?.message ?? err));
        }
        if (booking.eventId && booking.teamId) {
          io.to(`user:${booking.eventCreatorId ?? booking.userId}`).emit('calendar:changed', { teamId: booking.teamId, calendarId: null });
        }
        res.json({ ok: true, count: targets.length });
      }),
    );
  }

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
      // 반복(매주·2주마다 같은 시간 — repeatWeeks 회차, resourcePolicy.js).
      const series = seriesOccurrences({ startMs: times.startMs, endMs: times.endMs, repeatWeeks: req.body?.repeatWeeks ?? 1, everyWeeks: req.body?.everyWeeks ?? 1 });
      if (series.error) return fail(res, series);
      // 자원의 예약 규칙 — 회차마다(요일·시간대는 같으니 첫 회차로 충분하지만 여러 날 예약도 있어 모두 본다).
      for (const o of series.occurrences) {
        const policy = checkBookingPolicy(resource, { userId: ctx.user.id, startMs: o.startMs, endMs: o.endMs, privileged: ctx.isManager });
        if (policy) return fail(res, { error: policy.error, status: 403 });
      }
      const upcoming = await countUpcomingBookingsOf({ scopeKey: ctx.scopeKey, userId: ctx.user.id, nowMs: Date.now() });
      if (upcoming + series.occurrences.length > BOOKINGS_PER_USER_MAX) {
        return fail(res, { error: `앞으로의 예약은 ${BOOKINGS_PER_USER_MAX}건까지 잡아 둘 수 있습니다.`, status: 429 });
      }
      const status = initialBookingStatus(resource, { userId: ctx.user.id, isManager: ctx.isManager });
      const values = {
        userId: ctx.user.id,
        userName: ctx.user.name ?? ctx.user.username,
        // 회사 전체 범위면 ctx.teamId가 없다 — 앱이 지금 보는 팀(캘린더의 내장 "회의실 예약"을 새로 받게 알릴 팀).
        teamId: ctx.teamId ?? (isUuid(req.body?.teamId) ? req.body.teamId : null),
        title: title.title,
        eventId: null,
        status,
      };
      let rows;
      let skipped = [];
      if (series.occurrences.length === 1) {
        const result = await reserveResource({
          resourceId: resource.id,
          values: { ...values, startAt: new Date(times.startMs), endAt: new Date(times.endMs) },
        });
        if (result.missing) return fail(res, { error: '지금은 예약할 수 없는 자원입니다.', status: 409 });
        if (result.conflict) return fail(res, { error: conflictText(result.conflict), status: 409 });
        rows = [result.row];
      } else {
        const result = await reserveSeries({
          resourceId: resource.id,
          occurrences: series.occurrences.map((o) => ({ startAt: new Date(o.startMs), endAt: new Date(o.endMs) })),
          values: { ...values, seriesId: crypto.randomUUID() },
          skipConflicts: req.body?.skipConflicts === true,
        });
        if (result.missing) return fail(res, { error: '지금은 예약할 수 없는 자원입니다.', status: 409 });
        if (!result.rows.length) {
          const first = result.conflicts[0];
          return fail(res, {
            error: `반복 ${series.occurrences.length}회 중 ${result.conflicts.length}회가 겹칩니다 — ${conflictText(first.with)}. 겹치는 회차를 빼고 잡으려면 "겹치는 날 빼고"를 고르세요.`,
            status: 409,
          });
        }
        rows = result.rows;
        skipped = result.conflicts.map((c) => ({ start: c.startAt.getTime(), end: c.endAt.getTime(), conflict: conflictText(c.with) }));
      }
      await changed(ctx, rows[0]);
      if (status === 'pending') await notifyApprovalRequest(io, resource, rows[0]);
      const first = bookingDto(await findBooking(rows[0].id), { viewerId: ctx.user.id, isManager: ctx.isManager });
      // 예전 앱은 예약 하나를 받는다 — 반복 예약이면 첫 회차에 회차 수·건너뛴 회차를 붙인다.
      res.status(201).json({ ...first, created: rows.length, skipped });
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
      // 반복 예약 — ?series=1이면 이 회차와 그 뒤 회차 모두.
      if (req.query.series === '1' && booking.seriesId) {
        const rest = (await listSeriesFrom(booking.seriesId, booking.startAt.getTime())).filter((b) => b.userId === booking.userId);
        await deleteBookings(rest.map((b) => b.id));
      } else {
        await deleteBooking(booking.id);
      }
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

// ── 예약 시작 전 알림 ──

/**
 * 시작 전 알림 한 바퀴 — 앞으로 2시간 안에 시작하는 잡힌 예약 중 아직 안 알린 것을, 그 범위의 알림 분(groupware_options.booking_reminder_minutes —
 * 0이면 끔) 안에 들면 잡은 사람에게 알린다(푸시와 소켓 'resource:reminder' — 한 번만). 보낸 수.
 */
export async function runBookingReminders(io, now = Date.now()) {
  const candidates = await listBookingsStartingSoon(now, 2 * 60 * 60_000);
  if (!candidates.length) return 0;
  const leads = new Map();
  for (const scopeKey of new Set(candidates.map((b) => b.scopeKey))) {
    leads.set(scopeKey, (await findGroupwareOptions(scopeKey))?.bookingReminderMinutes ?? BOOKING_REMINDER_DEFAULT);
  }
  let count = 0;
  for (const b of remindersDue(candidates, { now, leadOf: (k) => leads.get(k) ?? 0 })) {
    if (!(await claimBookingReminder(b.id))) continue;
    const minutes = Math.max(1, Math.round((b.startAt.getTime() - now) / 60_000));
    const title = `${b.resourceName} 예약 ${minutes}분 전`;
    const body = `${kstText(b.startAt.getTime())} — ${b.eventId ? (b.eventTitle ?? b.title) : b.title}`;
    io.to(`user:${b.userId}`).emit('resource:reminder', { bookingId: b.id, resourceName: b.resourceName, start: b.startAt.getTime(), title, body, scopeKey: b.scopeKey, teamId: b.teamId ?? null });
    notifyGroupwarePush({ userId: b.userId, title, body, documentId: '', teamId: b.teamId ?? null }).catch((err) =>
      console.error('[groupware] 예약 알림 실패:', err?.message ?? err),
    );
    count += 1;
  }
  return count;
}

/** 1분마다 예약 시작 전 알림(서버를 켜고 1분 뒤 처음). */
export function startBookingReminderJob(io, { intervalMs = 60_000 } = {}) {
  const run = () => runBookingReminders(io).catch((err) => console.error('[groupware] 예약 알림 작업 실패:', err?.message ?? err));
  setTimeout(run, 60_000).unref?.();
  const timer = setInterval(run, intervalMs);
  timer.unref?.();
  return timer;
}
