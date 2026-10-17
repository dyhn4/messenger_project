import { Router } from 'express';
import { addDaysKey } from './annualLeave.js';
import { localDateKey } from './attendanceRules.js';
import { AUDIT, recordAudit } from './audit.js';
import {
  claimAttendanceReminder,
  deleteWorkSchedule,
  findGroupwareOptions,
  findLeavePromotion,
  insertLeavePromotion,
  listApprovedLeaves,
  listApprovedTrips,
  listAttendanceInRange,
  listAttendanceRemindersOn,
  listGroupwareMembers,
  listLeavePromotions,
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
import { optionsView, parseExpenseCategories, parseLeaveTypesInput, REMINDER_DELAY_MAX } from './groupwareOptions.js';
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

  /** 범위 설정 바꾸기(관리자) `{ leaveTypes?, expenseCategories?, clockInReminder?, clockOutReminder?, reminderDelayMinutes? }`. */
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
        const [members, records] = await Promise.all([
          listGroupwareMembers({ scope: ctx.scope, teamId: ctx.teamId }),
          listAttendanceInRange({ scopeKey: ctx.scopeKey, from: weekStart, to: addDaysKey(weekStart, 6) }),
        ]);
        const rows = members
          .filter((m) => !m.suspendedAt)
          .map((m) => ({
            userId: m.id,
            name: m.name,
            ...weeklySummary(
              records.filter((r) => r.userId === m.id),
              weekStart,
              { holidays: HOLIDAY_DATES },
            ),
          }))
          .sort((a, b) => b.netMinutes - a.netMinutes);
        res.json({ weekStart, weekEnd: addDaysKey(weekStart, 6), members: rows });
      },
      { managerOnly: true },
    ),
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
          const schedule = promotionSchedule(m.hireDate, today);
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
          const schedule = m?.hireDate ? promotionSchedule(m.hireDate, today) : null;
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
            `쓰지 않은 연차 ${remaining / 2}일 — ${row.deadline}까지 쓸 날을 정해 내 주세요(연차 기간 ${schedule.expiry} 만료).`,
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
        const schedule = m?.hireDate ? promotionSchedule(m.hireDate, today) : null;
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
      ...leaves.filter((l) => !['half_am', 'half_pm'].includes(l.payload?.leaveType)).map((l) => l.authorId),
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
