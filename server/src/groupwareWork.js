import { Router } from 'express';
import { addDaysKey, carryOverHalfDays, LEAVE_BASES, leaveAmountText } from './annualLeave.js';
import { localDateKey } from './attendanceRules.js';
import { AUDIT, recordAudit } from './audit.js';
import {
  claimAttendanceReminder,
  deleteWorkSchedule,
  findGroupwareOptions,
  findLeavePromotion,
  insertLeavePromotion,
  insertLeaveAdjustment,
  listLeaveAdjustments,
  listApprovedLeaves,
  listApprovedTrips,
  listAttendanceInRange,
  listAttendanceRemindersOn,
  listGroupwareMembers,
  listLeavePromotions,
  listPendingLeavesOf,
  listRecentAttendanceUsers,
  listReminderScopes,
  listWorkSchedules,
  updateLeavePromotion,
  upsertGroupwareOptions,
  upsertWorkSchedule,
} from './db/queries/groupware.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { findTeamById, listTeamMemberIds } from './db/queries/teams.js';
import { isUuid } from './favoritesRules.js';
import { balanceFor, fail, groupwareContext, scheduleDto } from './groupware.js';
import { CARRY_OVER_MAX_DAYS, optionsView, parseExpenseCategories, parseLeaveTypesInput, REMINDER_DELAY_MAX } from './groupwareOptions.js';
import { OVERTIME_GUARDS, parsePayRates, periodsOverlapping, periodSummary, weeklyLimitFor } from './workPolicy.js';
import { parseOfficeLocation } from './workLocation.js';
import { BOOKING_REMINDER_MAX } from './resourcePolicy.js';
import { HOLIDAYS } from './holidays.js';
import { parseLeaveDates, PLAN_RESPONSE_DAYS, PROMOTION_MESSAGE_MAX, promotionSchedule, promotionStage } from './leavePromotion.js';
import { notifyGroupwarePush } from './push.js';
import { effectiveHours, parseSchedule, reminderDue, weekStartOf, weeklySummary } from './workRules.js';

/**
 * 그룹웨어 근태·휴가 관리 — 범위 설정(휴가 종류·지출 분류·출근 알림 — groupwareOptions.js), 유연근무(사람마다의 근무 형태 — workRules.js),
 * 주 52시간(주마다 구성원 근로시간), 연차 사용 촉진(근로기준법 제61조 — leavePromotion.js), 출근·퇴근 알림 작업. 결재·출퇴근 자체는
 * groupware.js.
 */

const HOLIDAY_DATES = new Set(HOLIDAYS.map((h) => h.date));
const ms = (v) => (v ? new Date(v).getTime() : null);
/** 범위의 연차 기준(입사일·회계연도) — promotionSchedule·leavePeriodFor에 넘긴다. */
const basisOf = (ctx) => ({ basis: ctx.options?.leaveBasis ?? 'hire', fiscalStartMonth: ctx.options?.fiscalStartMonth ?? 1 });

const promotionDto = (p) => ({
  id: p.id,
  userId: p.userId,
  stage: p.stage,
  periodStart: p.periodStart,
  periodEnd: p.periodEnd,
  expiry: addDaysKey(p.periodEnd, -1),
  remainingHalfDays: p.remainingHalfDays,
  deadline: p.deadline,
  message: p.message ?? null,
  designatedDates: p.designatedDates ?? null,
  planDates: p.planDates ?? null,
  plannedAt: ms(p.plannedAt),
  sentByName: p.sentByName ?? null,
  sentAt: ms(p.sentAt),
  readAt: ms(p.readAt),
});

/** 아직 계획이 안 잡힌 남은 연차(반일) — 결재 중인 것도 쓸 것으로 본다. */
const unplannedHalfDays = (balance) => Math.max(0, (balance.remainingHalfDays ?? 0) - (balance.pendingHalfDays ?? 0));

export function createGroupwareWorkRouter(io) {
  const router = Router();

  const withContext =
    (handler, { managerOnly = false } = {}) =>
    async (req, res) => {
      const ctx = await groupwareContext(req.user.sub, req.query.teamId ?? req.body?.teamId);
      if (ctx.error) return fail(res, ctx);
      if (managerOnly && !ctx.isManager) return fail(res, { error: '결재·근태 관리자만 할 수 있습니다.', status: 403 });
      return handler(req, res, ctx);
    };

  /** 범위 사람들에게 그룹웨어 화면이 다시 받게(groupware:changed). */
  async function broadcast(ctx, payload) {
    const data = { ...payload, scopeKey: ctx.scopeKey };
    if (ctx.scope === 'team') {
      for (const id of await listTeamMemberIds(ctx.teamId)) io.to(`user:${id}`).emit('groupware:changed', data);
    } else {
      io.emit('groupware:changed', data);
    }
  }

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

  /** 받은 사람에게 알린다 — 푸시(접속해 있지 않은 기기)와 소켓. */
  function notify(ctx, userId, title, body) {
    io.to(`user:${userId}`).emit('groupware:changed', { promotion: true, scopeKey: ctx.scopeKey });
    notifyGroupwarePush({ userId, title, body, documentId: '', teamId: ctx.teamId }).catch((err) =>
      console.error('[groupware] 연차 촉진 알림 실패:', err?.message ?? err),
    );
  }

  // ── 범위 설정 ──

  router.get(
    '/groupware/options',
    withContext(async (req, res, ctx) => res.json(ctx.options)),
  );

  /**
   * 범위 설정 바꾸기(관리자) `{ leaveTypes?, expenseCategories?, clockInReminder?, clockOutReminder?, reminderDelayMinutes?, overtimeGuard?,
   * leaveBasis?, fiscalStartMonth?, carryOverMaxDays?, payRates?, officeLocation?, requireFieldLocation? }`.
   */
  router.patch(
    '/groupware/options',
    withContext(
      async (req, res, ctx) => {
        const body = req.body ?? {};
        const patch = {};
        const details = [];
        if ('leaveTypes' in body) {
          const parsed = parseLeaveTypesInput(body.leaveTypes, { previous: (await findGroupwareOptions(ctx.scopeKey))?.leaveTypes ?? null });
          if (parsed.error) return fail(res, parsed);
          patch.leaveTypes = parsed.stored;
          details.push('휴가 종류');
        }
        if ('expenseCategories' in body) {
          const parsed = parseExpenseCategories(body.expenseCategories);
          if (parsed.error) return fail(res, parsed);
          patch.expenseCategories = parsed.categories;
          details.push('지출 분류');
        }
        for (const key of ['clockInReminder', 'clockOutReminder']) {
          if (key in body) {
            if (typeof body[key] !== 'boolean') return fail(res, { error: '알림 설정을 확인하세요.' });
            patch[key] = body[key];
            details.push(`${key === 'clockInReminder' ? '출근' : '퇴근'} 알림 ${body[key] ? '켜기' : '끄기'}`);
          }
        }
        if ('reminderDelayMinutes' in body) {
          const n = Number(body.reminderDelayMinutes);
          if (!Number.isInteger(n) || n < 0 || n > REMINDER_DELAY_MAX) return fail(res, { error: `출근 알림은 근무 시작 0~${REMINDER_DELAY_MAX}분 뒤로 정하세요.` });
          patch.reminderDelayMinutes = n;
          details.push(`출근 알림 ${n}분 뒤`);
        }
        // 주 52시간 지키기(workPolicy.js).
        if ('overtimeGuard' in body) {
          if (!OVERTIME_GUARDS.includes(body.overtimeGuard)) return fail(res, { error: '주 52시간 지키기 방식을 고르세요(알리기만·결재를 받게·막기).' });
          patch.overtimeGuard = body.overtimeGuard;
          // 문장 전체로(앱이 통째로 번역한다).
          details.push({ warn: '주 52시간 알리기만', approval: '주 52시간 결재를 받게', block: '주 52시간 막기' }[body.overtimeGuard]);
        }
        // 연차 기준 — 입사일·회계연도(annualLeave.js). 바꾸면 이번 기간·조정·촉진 일정이 새 기준으로 다시 계산된다.
        if ('leaveBasis' in body) {
          if (!LEAVE_BASES.includes(body.leaveBasis)) return fail(res, { error: '연차 기준을 고르세요(입사일·회계연도).' });
          patch.leaveBasis = body.leaveBasis;
          details.push(body.leaveBasis === 'fiscal' ? '연차 기준 회계연도' : '연차 기준 입사일');
        }
        if ('fiscalStartMonth' in body) {
          const n = Number(body.fiscalStartMonth);
          if (!Number.isInteger(n) || n < 1 || n > 12) return fail(res, { error: '회계연도가 시작하는 달을 1~12로 정하세요.' });
          patch.fiscalStartMonth = n;
          details.push(`회계연도 ${n}월 시작`);
        }
        if ('carryOverMaxDays' in body) {
          const n = Number(body.carryOverMaxDays);
          if (!Number.isInteger(n) || n < 0 || n > CARRY_OVER_MAX_DAYS) return fail(res, { error: `연차 이월은 0~${CARRY_OVER_MAX_DAYS}일로 정하세요(0이면 하지 않음).` });
          patch.carryOverMaxDays = n;
          details.push(n ? `연차 이월 ${n}일까지` : '연차 이월 끄기');
        }
        if ('payRates' in body) {
          const parsed = parsePayRates(body.payRates, (await findGroupwareOptions(ctx.scopeKey))?.payRates ?? null);
          if (parsed.error) return fail(res, parsed);
          patch.payRates = parsed.rates;
          details.push('가산율');
        }
        // 사무실 위치·외근 위치 필수(workLocation.js).
        if ('officeLocation' in body) {
          const parsed = parseOfficeLocation(body.officeLocation);
          if (parsed.error) return fail(res, parsed);
          patch.officeLocation = parsed.office;
          details.push(parsed.office ? `사무실 위치(반경 ${parsed.office.radius}m)` : '사무실 위치 지움');
        }
        if ('requireFieldLocation' in body) {
          if (typeof body.requireFieldLocation !== 'boolean') return fail(res, { error: '외근 위치 필수를 참/거짓으로 보내세요.' });
          patch.requireFieldLocation = body.requireFieldLocation;
          details.push(body.requireFieldLocation ? '외근 위치 필수' : '외근 위치 선택');
        }
        // 회의실·자원 예약 시작 전 알림(분 — 0이면 끔).
        if ('bookingReminderMinutes' in body) {
          const n = Number(body.bookingReminderMinutes);
          if (!Number.isInteger(n) || n < 0 || n > BOOKING_REMINDER_MAX) return fail(res, { error: `예약 알림은 0~${BOOKING_REMINDER_MAX}분 전으로 정하세요(0이면 끔).` });
          patch.bookingReminderMinutes = n;
          details.push(n ? `예약 알림 ${n}분 전` : '예약 알림 끄기');
        }
        if (Object.keys(patch).length === 0) return fail(res, { error: '바꿀 내용이 없습니다.' });
        const row = await upsertGroupwareOptions(ctx.scopeKey, patch);
        audit(ctx, `그룹웨어 설정 — ${details.join(', ')}`);
        await broadcast(ctx, { options: true });
        res.json(optionsView(row));
      },
      { managerOnly: true },
    ),
  );

  // ── 유연근무 ──

  /** 구성원별 근무 형태(관리자) — 정하지 않은 사람은 schedule null(범위의 근무 시간). */
  router.get(
    '/groupware/schedules',
    withContext(
      async (req, res, ctx) => {
        const [members, schedules] = await Promise.all([
          listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId }),
          listWorkSchedules(ctx.scopeKey),
        ]);
        const byUser = new Map(schedules.map((s) => [s.userId, s]));
        res.json(
          members
            .filter((m) => !m.suspendedAt)
            .map((m) => ({ userId: m.id, name: m.name, schedule: scheduleDto(byUser.get(m.id) ?? null) }))
            .sort((a, b) => a.name.localeCompare(b.name, 'ko')),
        );
      },
      { managerOnly: true },
    ),
  );

  /** 근무 형태 정하기(관리자) `{ mode: 'staggered'|'core'|'free', start?, end?, coreStart?, coreEnd? }`('HH:MM'). */
  router.put(
    '/groupware/schedules/:userId',
    withContext(
      async (req, res, ctx) => {
        const members = await listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId });
        const member = members.find((m) => m.id === req.params.userId);
        if (!member) return fail(res, { error: '이 범위의 구성원이 아닙니다.', status: 404 });
        const parsed = parseSchedule(req.body);
        if (parsed.error) return fail(res, parsed);
        const row = await upsertWorkSchedule(ctx.scopeKey, member.id, parsed.schedule);
        audit(ctx, `${member.name} 근무 형태 — ${scheduleDto(row).label}`);
        io.to(`user:${member.id}`).emit('groupware:changed', { schedule: true, scopeKey: ctx.scopeKey });
        res.json({ userId: member.id, name: member.name, schedule: scheduleDto(row) });
      },
      { managerOnly: true },
    ),
  );

  router.delete(
    '/groupware/schedules/:userId',
    withContext(
      async (req, res, ctx) => {
        if (!isUuid(req.params.userId)) return fail(res, { error: '구성원을 찾을 수 없습니다.', status: 404 });
        await deleteWorkSchedule(ctx.scopeKey, req.params.userId);
        audit(ctx, '근무 형태 되돌림(범위의 근무 시간)');
        io.to(`user:${req.params.userId}`).emit('groupware:changed', { schedule: true, scopeKey: ctx.scopeKey });
        res.json({ ok: true });
      },
      { managerOnly: true },
    ),
  );

  // ── 주 52시간 ──

  /** 한 주(그 날이 든 월~일) 구성원별 근로시간(관리자) `?week=YYYY-MM-DD` — 많이 일한 사람부터. */
  router.get(
    '/groupware/attendance/weekly',
    withContext(
      async (req, res, ctx) => {
        const day = typeof req.query.week === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(req.query.week) ? req.query.week : localDateKey(new Date());
        const weekStart = weekStartOf(day);
        const [members, records, schedules] = await Promise.all([
          listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId }),
          listAttendanceInRange({ scopeKey: ctx.scopeKey, from: weekStart, to: addDaysKey(weekStart, 6) }),
          listWorkSchedules(ctx.scopeKey),
        ]);
        const scheduleOf = new Map(schedules.map((s) => [s.userId, s]));
        const rows = [];
        for (const m of members.filter((x) => !x.suspendedAt)) {
          const schedule = scheduleOf.get(m.id) ?? null;
          const week = weeklySummary(
            records.filter((r) => r.userId === m.id),
            weekStart,
            { holidays: HOLIDAY_DATES },
          );
          // 탄력·선택근무 — 주 상한이 다르고(선택근무는 없음) 그 주가 든 기간의 근로시간을 함께.
          const limit = weeklyLimitFor(schedule);
          let period = null;
          if (schedule?.periodType) {
            const [p] = periodsOverlapping(schedule, weekStart, weekStart);
            if (p) {
              const periodRecords = await listAttendanceInRange({ scopeKey: ctx.scopeKey, from: p.start, to: addDaysKey(p.end, -1), userId: m.id });
              period = periodSummary(periodRecords, p, { holidays: HOLIDAY_DATES });
            }
          }
          const status = limit == null ? (period?.status ?? 'ok') : week.netMinutes > limit ? 'over' : week.netMinutes >= limit - 4 * 60 ? 'warn' : 'ok';
          rows.push({ userId: m.id, name: m.name, ...week, status, weeklyLimitMinutes: limit, periodType: schedule?.periodType ?? null, period });
        }
        rows.sort((a, b) => b.netMinutes - a.netMinutes);
        res.json({ weekStart, weekEnd: addDaysKey(weekStart, 6), overtimeGuard: ctx.options.overtimeGuard, members: rows });
      },
      { managerOnly: true },
    ),
  );

  // ── 휴가 달력 ──

  /**
   * 한 달 휴가 달력 `?month=YYYY-MM`(기본 이번 달) — 승인된 휴가·출장(범위 사람 모두)과 내가 올려 결재 중인 휴가, 공휴일.
   * 휴가 이름은 신청할 때의 이름(payload.leaveLabel), 없으면 지금 범위의 휴가 종류 이름.
   */
  router.get(
    '/groupware/leave/month',
    withContext(async (req, res, ctx) => {
      const month = typeof req.query.month === 'string' && /^\d{4}-(0[1-9]|1[0-2])$/.test(req.query.month) ? req.query.month : localDateKey(new Date()).slice(0, 7);
      const from = `${month}-01`;
      const to = addDaysKey(addDaysKey(from, 31).slice(0, 7) + '-01', -1);
      const [approved, pending, trips] = await Promise.all([
        listApprovedLeaves({ scopeKey: ctx.scopeKey, from, to }),
        listPendingLeavesOf({ scopeKey: ctx.scopeKey, authorId: ctx.user.id, from, to }),
        listApprovedTrips({ scopeKey: ctx.scopeKey, from, to }),
      ]);
      const labelOf = (p) => p?.leaveLabel ?? ctx.options.leaveTypes.find((t) => t.key === p?.leaveType)?.label ?? '휴가';
      const leaveRow = (l, status) => ({
        documentId: l.id,
        userId: l.authorId,
        name: l.authorName,
        leaveType: l.payload?.leaveType ?? null,
        label: labelOf(l.payload),
        startDate: l.payload?.startDate,
        endDate: l.payload?.endDate,
        halfDays: l.payload?.halfDays ?? null,
        status,
        mine: l.authorId === ctx.user.id,
      });
      const byStart = (a, b) => a.startDate.localeCompare(b.startDate) || a.name.localeCompare(b.name, 'ko');
      res.json({
        month,
        from,
        to,
        holidays: HOLIDAYS.filter((h) => h.date >= from && h.date <= to),
        leaves: [...approved.map((l) => leaveRow(l, 'approved')), ...pending.map((l) => leaveRow(l, 'pending'))]
          .filter((l) => l.startDate && l.endDate)
          .sort(byStart),
        trips: trips
          .map((t) => ({
            documentId: t.id,
            userId: t.authorId,
            name: t.authorName,
            destination: t.payload?.destination ?? null,
            startDate: t.payload?.startDate,
            endDate: t.payload?.endDate,
          }))
          .filter((t) => t.startDate && t.endDate)
          .sort(byStart),
      });
    }),
  );

  // ── 연차 사용 촉진(근로기준법 제61조) ──

  /** 구성원별 촉진 현황(관리자) — 입사일이 있는 사람마다 이번 연차 기간 일정·남은 연차·지금 해야 할 일·보낸 통지. */
  router.get(
    '/groupware/leave/promotions',
    withContext(
      async (req, res, ctx) => {
        const today = localDateKey(new Date());
        const members = (await listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId })).filter((m) => !m.suspendedAt && m.hireDate);
        const notices = await listLeavePromotions(ctx.scopeKey);
        const rows = [];
        for (const m of members) {
          const schedule = promotionSchedule(m.hireDate, today, basisOf(ctx));
          if (!schedule) continue;
          const balance = await balanceFor(ctx, m.id);
          const mine = notices.filter((n) => n.userId === m.id && n.periodStart === schedule.periodStart);
          const remaining = unplannedHalfDays(balance);
          rows.push({
            userId: m.id,
            name: m.name,
            hireDate: m.hireDate,
            ...schedule,
            remainingHalfDays: remaining,
            stage: promotionStage({ schedule, today, remainingHalfDays: remaining, notices: mine }),
            notices: mine.map(promotionDto),
          });
        }
        const order = { first: 0, second: 1, awaiting: 2, missed: 3, upcoming: 4, done: 5, none: 6 };
        rows.sort((a, b) => order[a.stage] - order[b.stage] || a.expiry.localeCompare(b.expiry));
        res.json({ today, members: rows });
      },
      { managerOnly: true },
    ),
  );

  /**
   * 1차 촉진 보내기(관리자) `{ userIds, message? }` — 남은 연차를 알리고 10일 안에 쓸 날을 정해 내라고 요구한다. 이 연차 기간에 이미 1차를
   * 보냈거나 남은 연차가 없는 사람은 건너뛴다. `{ sent: [통지], skipped: [{ userId, reason }] }`.
   */
  router.post(
    '/groupware/leave/promotions',
    withContext(
      async (req, res, ctx) => {
        const userIds = Array.isArray(req.body?.userIds) ? req.body.userIds.filter(isUuid) : [];
        if (userIds.length === 0) return fail(res, { error: '보낼 사람을 고르세요.' });
        const message = typeof req.body?.message === 'string' ? req.body.message.trim().slice(0, PROMOTION_MESSAGE_MAX) || null : null;
        const today = localDateKey(new Date());
        const members = new Map((await listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId })).map((m) => [m.id, m]));
        const sent = [];
        const skipped = [];
        for (const userId of [...new Set(userIds)]) {
          const m = members.get(userId);
          const schedule = m?.hireDate ? promotionSchedule(m.hireDate, today, basisOf(ctx)) : null;
          if (!schedule) {
            skipped.push({ userId, reason: '입사일이 없습니다.' });
            continue;
          }
          const existing = await listLeavePromotions(ctx.scopeKey, { userId, periodStart: schedule.periodStart });
          if (existing.some((n) => n.stage === 1)) {
            skipped.push({ userId, reason: '이 연차 기간에 이미 1차 촉진을 보냈습니다.' });
            continue;
          }
          const remaining = unplannedHalfDays(await balanceFor(ctx, userId));
          if (remaining <= 0) {
            skipped.push({ userId, reason: '남은 연차가 없습니다.' });
            continue;
          }
          const deadline = addDaysKey(today, PLAN_RESPONSE_DAYS);
          const row = await insertLeavePromotion({
            scopeKey: ctx.scopeKey,
            userId,
            periodStart: schedule.periodStart,
            periodEnd: schedule.periodEnd,
            stage: 1,
            remainingHalfDays: remaining,
            deadline: deadline < schedule.expiry ? deadline : schedule.expiry,
            message,
            sentById: ctx.user.id,
            sentByName: ctx.user.name ?? ctx.user.username,
          });
          sent.push(promotionDto(row));
          notify(
            ctx,
            userId,
            '연차 사용 촉진 안내',
            `쓰지 않은 연차 ${leaveAmountText(remaining)} — ${row.deadline}까지 쓸 날을 정해 내 주세요(연차 기간 ${schedule.expiry} 만료).`,
          );
        }
        if (sent.length) audit(ctx, `연차 사용 촉진 1차 — ${sent.length}명`);
        res.status(sent.length ? 201 : 200).json({ sent, skipped });
      },
      { managerOnly: true },
    ),
  );

  /** 2차 촉진(관리자) `{ userId, dates, message? }` — 1차 뒤 쓸 날을 내지 않은 사람에게 회사가 정한 날을 알린다. */
  router.post(
    '/groupware/leave/promotions/second',
    withContext(
      async (req, res, ctx) => {
        const userId = req.body?.userId;
        const today = localDateKey(new Date());
        const m = isUuid(userId) ? (await listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId })).find((x) => x.id === userId) : null;
        const schedule = m?.hireDate ? promotionSchedule(m.hireDate, today, basisOf(ctx)) : null;
        if (!schedule) return fail(res, { error: '입사일이 있는 구성원을 고르세요.', status: 404 });
        const notices = await listLeavePromotions(ctx.scopeKey, { userId, periodStart: schedule.periodStart });
        const first = notices.find((n) => n.stage === 1);
        if (!first) return fail(res, { error: '1차 촉진을 먼저 보내세요.', status: 409 });
        if (Array.isArray(first.planDates) && first.planDates.length) return fail(res, { error: '이미 쓸 날을 냈습니다.', status: 409 });
        if (notices.some((n) => n.stage === 2)) return fail(res, { error: '이미 2차 촉진을 보냈습니다.', status: 409 });
        if (today <= first.deadline) return fail(res, { error: `${first.deadline}까지는 받은 사람이 쓸 날을 낼 수 있습니다.`, status: 409 });
        const remaining = unplannedHalfDays(await balanceFor(ctx, userId));
        const dates = parseLeaveDates(req.body?.dates, { from: addDaysKey(today, 1), expiry: schedule.expiry, maxDays: Math.floor(remaining / 2) });
        if (dates.error) return fail(res, dates);
        const message = typeof req.body?.message === 'string' ? req.body.message.trim().slice(0, PROMOTION_MESSAGE_MAX) || null : null;
        const row = await insertLeavePromotion({
          scopeKey: ctx.scopeKey,
          userId,
          periodStart: schedule.periodStart,
          periodEnd: schedule.periodEnd,
          stage: 2,
          remainingHalfDays: remaining,
          deadline: schedule.expiry,
          message,
          designatedDates: dates.dates,
          sentById: ctx.user.id,
          sentByName: ctx.user.name ?? ctx.user.username,
        });
        audit(ctx, `연차 사용 촉진 2차 — ${m.name} ${dates.dates.length}일 지정`);
        notify(ctx, userId, '연차 사용 시기 지정 통보', `회사가 연차 쓸 날을 정했습니다: ${dates.dates.join(', ')}`);
        res.status(201).json(promotionDto(row));
      },
      { managerOnly: true },
    ),
  );

  // ── 연차 이월 ──

  /**
   * 연차 이월(관리자) `{ userIds?, dryRun? }` — 범위의 이월 상한(일)까지, 지난 연차 기간 끝에 남은 연차를 이번 기간의 조정(kind 'carry')으로
   * 넣는다. 기간마다 한 번(이미 넣었으면 건너뜀). [userIds]를 안 주면 입사일이 있는 모두. [dryRun]이면 넣지 않고 넣을 양만 보여 준다.
   * `{ capDays, applied: [{ userId, name, halfDays, from, to }], skipped: [{ userId, name, reason }] }`.
   */
  router.post(
    '/groupware/leave/carry-over',
    withContext(
      async (req, res, ctx) => {
        const capDays = ctx.options.carryOverMaxDays ?? 0;
        if (capDays <= 0) return fail(res, { error: '연차 이월이 꺼져 있습니다. 먼저 이월할 수 있는 일수를 정하세요.' });
        const dryRun = req.body?.dryRun === true;
        const pick = Array.isArray(req.body?.userIds) ? new Set(req.body.userIds.filter(isUuid)) : null;
        const today = localDateKey(new Date());
        const members = (await listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId })).filter(
          (m) => !m.suspendedAt && m.hireDate && (!pick || pick.has(m.id)),
        );
        const applied = [];
        const skipped = [];
        for (const m of members) {
          const now = await balanceFor(ctx, m.id);
          if (!now.period) {
            skipped.push({ userId: m.id, name: m.name, reason: '입사일이 없거나 아직 입사 전입니다.' });
            continue;
          }
          const lastDay = addDaysKey(now.period.start, -1);
          if (lastDay < m.hireDate) {
            skipped.push({ userId: m.id, name: m.name, reason: '지난 연차 기간이 없습니다(첫 기간).' });
            continue;
          }
          const existing = await listLeaveAdjustments({ scopeKey: ctx.scopeKey, userId: m.id, periodStart: now.period.start });
          if (existing.some((a) => a.kind === 'carry')) {
            skipped.push({ userId: m.id, name: m.name, reason: '이번 기간에 이미 이월했습니다.' });
            continue;
          }
          // 지난 기간 마지막 날 기준의 남은 연차(결재 중이던 것은 빼지 않는다 — 승인된 것만 쓴 것으로).
          const prev = await balanceFor(ctx, m.id, { today: lastDay });
          const halfDays = carryOverHalfDays(prev.remainingHalfDays, capDays);
          if (halfDays <= 0) {
            skipped.push({ userId: m.id, name: m.name, reason: '지난 기간에 남은 연차가 없습니다.' });
            continue;
          }
          const from = prev.period?.start ?? null;
          if (!dryRun) {
            await insertLeaveAdjustment({
              scopeKey: ctx.scopeKey,
              userId: m.id,
              periodStart: now.period.start,
              halfDays,
              kind: 'carry',
              reason: `이월 — ${from}~${lastDay}에 남은 ${leaveAmountText(prev.remainingHalfDays)} 중 ${leaveAmountText(halfDays)}`,
              createdByName: ctx.user.name ?? ctx.user.username,
            });
          }
          applied.push({ userId: m.id, name: m.name, halfDays, from, to: lastDay });
        }
        if (!dryRun && applied.length) {
          audit(ctx, `연차 이월 — ${applied.length}명`);
          await broadcast(ctx, { leave: true });
        }
        res.json({ capDays, dryRun, applied, skipped, today });
      },
      { managerOnly: true },
    ),
  );

  /** 내가 받은 촉진 통지(최근 것부터). */
  router.get(
    '/groupware/leave/promotions/mine',
    withContext(async (req, res, ctx) => {
      res.json((await listLeavePromotions(ctx.scopeKey, { userId: ctx.user.id })).map(promotionDto));
    }),
  );

  /** 받은 통지를 읽음(확인) — 처음 읽은 시각만 남긴다. */
  router.post('/groupware/leave/promotions/:id/read', async (req, res) => {
    const row = isUuid(req.params.id) ? await findLeavePromotion(req.params.id) : null;
    if (!row || row.userId !== req.user.sub) return fail(res, { error: '통지를 찾을 수 없습니다.', status: 404 });
    const updated = row.readAt ? row : await updateLeavePromotion(row.id, { readAt: new Date() });
    res.json(promotionDto(updated));
  });

  /** 1차 통지에 쓸 날 내기 `{ dates }` — 마감 안에, 한 번만. 보낸 관리자에게 알린다. */
  router.post('/groupware/leave/promotions/:id/plan', async (req, res) => {
    const row = isUuid(req.params.id) ? await findLeavePromotion(req.params.id) : null;
    if (!row || row.userId !== req.user.sub) return fail(res, { error: '통지를 찾을 수 없습니다.', status: 404 });
    if (row.stage !== 1) return fail(res, { error: '1차 촉진 통지에만 쓸 날을 냅니다.', status: 409 });
    if (Array.isArray(row.planDates) && row.planDates.length) return fail(res, { error: '이미 쓸 날을 냈습니다.', status: 409 });
    const today = localDateKey(new Date());
    if (today > row.deadline) return fail(res, { error: `낼 수 있는 기한(${row.deadline})이 지났습니다.`, status: 409 });
    const dates = parseLeaveDates(req.body?.dates, {
      from: today,
      expiry: addDaysKey(row.periodEnd, -1),
      maxDays: Math.floor(row.remainingHalfDays / 2),
    });
    if (dates.error) return fail(res, dates);
    const updated = await updateLeavePromotion(row.id, { planDates: dates.dates, plannedAt: new Date(), readAt: row.readAt ?? new Date() });
    if (row.sentById) io.to(`user:${row.sentById}`).emit('groupware:changed', { promotion: true, scopeKey: row.scopeKey });
    res.json(promotionDto(updated));
  });

  return router;
}

// ── 출근·퇴근 알림 작업 ──

/**
 * 출근·퇴근 알림 한 바퀴 — 알림을 켠 범위마다, 최근 30일 안에 출퇴근을 쓴 사람 중 오늘 근무일인데(휴가·출장이 아닌) 근무 시작 + 정한 분이
 * 지나도 출근을 안 눌렀거나(출근 알림), 근무 끝 1시간 뒤에도 퇴근을 안 눌렀으면(퇴근 알림) 하루에 한 번씩 알린다. 보낸 수.
 */
export async function runAttendanceReminders(io, now = new Date()) {
  const today = localDateKey(now);
  const settings = await getServerSettings();
  let count = 0;
  for (const opt of await listReminderScopes()) {
    const scopeKey = opt.scopeKey;
    const teamId = scopeKey === 'server' ? null : scopeKey;
    const team = teamId ? await findTeamById(teamId) : null;
    if (teamId && !team) continue;
    const workStart = team ? (team.workStartMinutes ?? settings.workStartMinutes) : settings.workStartMinutes;
    const workEnd = team ? (team.workEndMinutes ?? settings.workEndMinutes) : settings.workEndMinutes;
    const [members, recentUsers, records, leaves, trips, sent, schedules] = await Promise.all([
      listGroupwareMembers({ scope: teamId ? 'team' : 'server', teamId }),
      listRecentAttendanceUsers(scopeKey, addDaysKey(today, -30)),
      listAttendanceInRange({ scopeKey, from: addDaysKey(today, -1), to: today }),
      listApprovedLeaves({ scopeKey, from: today, to: today }),
      listApprovedTrips({ scopeKey, from: today, to: today }),
      listAttendanceRemindersOn(scopeKey, today),
      listWorkSchedules(scopeKey),
    ]);
    const active = new Set(recentUsers);
    const scheduleOf = new Map(schedules.map((s) => [s.userId, s]));
    // 하루 휴가(반차는 아님)·출장인 사람.
    const off = new Set([
      ...leaves.filter((l) => !['half_am', 'half_pm'].includes(l.payload?.leaveType) && !l.payload?.hours).map((l) => l.authorId),
      ...trips.map((t) => t.authorId),
    ]);
    for (const m of members) {
      if (m.suspendedAt || m.deletedAt || !active.has(m.id)) continue;
      const hours = effectiveHours(scheduleOf.get(m.id) ?? null, { workStart, workEnd });
      const record = records.find((r) => r.userId === m.id && r.workDate === today) ?? null;
      const due = reminderDue({
        now,
        record,
        hours,
        delay: opt.reminderDelayMinutes ?? 10,
        holidays: HOLIDAY_DATES,
        offToday: off.has(m.id),
        sent: new Set(sent.filter((s) => s.userId === m.id).map((s) => s.kind)),
        clockIn: opt.clockInReminder,
        clockOut: opt.clockOutReminder,
      });
      if (!due || !(await claimAttendanceReminder({ scopeKey, userId: m.id, workDate: today, kind: due }))) continue;
      const title = due === 'in' ? '출근 기록을 잊으셨나요?' : '퇴근 기록을 잊으셨나요?';
      const body = due === 'in' ? '아직 출근을 누르지 않았습니다. 그룹웨어 → 출퇴근에서 눌러 주세요.' : '아직 퇴근을 누르지 않았습니다.';
      io.to(`user:${m.id}`).emit('attendance:reminder', { kind: due, title, body, scopeKey, teamId });
      notifyGroupwarePush({ userId: m.id, title, body, documentId: '', teamId }).catch((err) =>
        console.error('[groupware] 출근 알림 실패:', err?.message ?? err),
      );
      count += 1;
    }
  }
  return count;
}

/** 5분마다 출근·퇴근 알림(서버를 켜고 1분 뒤 처음). */
export function startAttendanceReminderJob(io, { intervalMs = 5 * 60 * 1000 } = {}) {
  const run = () => runAttendanceReminders(io).catch((err) => console.error('[groupware] 출근 알림 작업 실패:', err?.message ?? err));
  setTimeout(run, 60_000).unref?.();
  const timer = setInterval(run, intervalMs);
  timer.unref?.();
  return timer;
}
