// 근태 후속 — 휴게 누르기, 주 52시간 지키기(결재를 받게·막기), 탄력적 근로시간제·선택근무 정산 기간, 가산 수당, 출퇴근 위치(GPS),
// 시간 단위 연차(반반차), 회계연도 기준 연차·연차 이월. `node --test test/*.test.js`(DB 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  carryOverHalfDays,
  fiscalPeriodOf,
  leaveAmountText,
  leaveBalance,
  leavePeriodFor,
  leaveRequestAmount,
  statutoryHalfDaysFor,
} from '../src/annualLeave.js';
import { defaultApprovalTitle, parseLeavePayload } from '../src/approvalRules.js';
import { dateAtMinutes, recordFlags } from '../src/attendanceRules.js';
import { mergeLeaveTypes } from '../src/groupwareOptions.js';
import { promotionSchedule } from '../src/leavePromotion.js';
import { checkClockLocation, distanceMeters, parseLocation, parseOfficeLocation } from '../src/workLocation.js';
import {
  allowanceOf,
  clockInGuard,
  overtimeRequestGuard,
  parsePayRates,
  periodsOverlapping,
  periodSummary,
  weeklyLimitFor,
  workPeriodOf,
} from '../src/workPolicy.js';
import { applyBreakAction, closeOpenBreaks, parseSchedule, workBreakdown } from '../src/workRules.js';

const at = (day, hm) => dateAtMinutes(day, Number(hm.slice(0, 2)) * 60 + Number(hm.slice(3, 5)));
const rec = (day, inHm, outHm, extra = {}) => ({ workDate: day, clockInAt: at(day, inHm), clockOutAt: outHm ? at(day, outHm) : null, ...extra });

test('휴게 누르기 — 누른 시간을 빼고, 법정보다 짧으면 모자란 분, 야간에 든 휴게는 야간에서 뺀다', () => {
  const day = '2026-10-14'; // 수요일
  // 09:00~18:00, 12:00~12:40 휴게 → 실근로 8시간 20분, 법정 60분보다 20분 모자람.
  const r = rec(day, '09:00', '18:00', { breaks: [{ startAt: at(day, '12:00'), endAt: at(day, '12:40') }] });
  const b = workBreakdown(r);
  assert.equal(b.breakMinutes, 40);
  assert.equal(b.netMinutes, 500);
  assert.equal(b.overtimeMinutes, 20);
  assert.equal(b.breakRecorded, true);
  assert.equal(b.breakShortMinutes, 20);
  // 출근 전·퇴근 뒤로 걸친 휴게는 그 안만, 열린 휴게는 세지 않는다.
  const edge = rec(day, '09:00', '18:00', {
    breaks: [
      { startAt: at(day, '08:30'), endAt: at(day, '09:30') },
      { startAt: at(day, '17:00'), endAt: null },
    ],
  });
  assert.equal(workBreakdown(edge).breakMinutes, 30);
  // 야간 근무 중 휴게(23:00~23:30)는 야간 시간에서 뺀다.
  const night = rec(day, '18:00', '23:59', { breaks: [{ startAt: at(day, '23:00'), endAt: at(day, '23:30') }] });
  assert.equal(workBreakdown(night).nightMinutes, 119 - 30);
  // 누르지 않은 날은 예전처럼 법정 휴게.
  assert.equal(workBreakdown(rec(day, '09:00', '18:00')).breakMinutes, 60);
});

test('휴게 시작·끝 — 출근 뒤 퇴근 전, 열린 휴게는 하나, 하루 10번까지, 퇴근하면 닫힘', () => {
  const now = new Date('2026-10-14T03:00:00Z');
  const open = { clockInAt: new Date('2026-10-14T00:00:00Z'), clockOutAt: null, breaks: [] };
  const started = applyBreakAction(open, 'start', now);
  assert.equal(started.breaks.length, 1);
  assert.equal(started.breaks[0].endAt, null);
  assert.equal(applyBreakAction({ ...open, breaks: started.breaks }, 'start', now).status, 409);
  const ended = applyBreakAction({ ...open, breaks: started.breaks }, 'end', new Date('2026-10-14T03:30:00Z'));
  assert.equal(ended.breaks[0].endAt, '2026-10-14T03:30:00.000Z');
  assert.match(applyBreakAction(open, 'end', now).error, /휴게 중이 아닙니다/);
  assert.match(applyBreakAction({ clockInAt: null }, 'start', now).error, /출근을 먼저/);
  assert.match(applyBreakAction({ ...open, clockOutAt: now }, 'start', now).error, /퇴근/);
  const ten = Array.from({ length: 10 }, () => ({ startAt: '2026-10-14T01:00:00Z', endAt: '2026-10-14T01:05:00Z' }));
  assert.match(applyBreakAction({ ...open, breaks: ten }, 'start', now).error, /10번/);
  assert.deepEqual(closeOpenBreaks([{ startAt: 'a', endAt: null }, { startAt: 'b', endAt: 'c' }], now), [
    { startAt: 'a', endAt: now.toISOString() },
    { startAt: 'b', endAt: 'c' },
  ]);
});

test('주 52시간 지키기 — 출근 막기(52시간)·결재를 받게(48시간 넘으면 승인된 연장근무가 있어야), 연장근무 신청 막기', () => {
  const h = (n) => n * 60;
  assert.equal(clockInGuard({ guard: 'warn', weekNetMinutes: h(60), limitMinutes: h(52) }), null);
  assert.match(clockInGuard({ guard: 'block', weekNetMinutes: h(52), limitMinutes: h(52) }).error, /52시간/);
  assert.equal(clockInGuard({ guard: 'block', weekNetMinutes: h(50), limitMinutes: h(52) }), null);
  assert.match(clockInGuard({ guard: 'approval', weekNetMinutes: h(49), limitMinutes: h(52) }).error, /결재를 먼저/);
  assert.equal(clockInGuard({ guard: 'approval', weekNetMinutes: h(49), limitMinutes: h(52), hasApprovedOvertime: true }), null);
  assert.ok(clockInGuard({ guard: 'approval', weekNetMinutes: h(52), limitMinutes: h(52), hasApprovedOvertime: true }).error);
  // 선택근무(주 상한 없음)는 보지 않는다.
  assert.equal(clockInGuard({ guard: 'block', weekNetMinutes: h(70), limitMinutes: null }), null);

  const base = { guard: 'block', workDate: '2026-10-16', today: '2026-10-14', limitMinutes: h(52) };
  // 지금까지 30시간이라도 주 40시간을 기본으로 본다 — 40 + 앞으로 할 연장 6 + 이번 8 = 54 > 52.
  assert.match(overtimeRequestGuard({ ...base, weekNetMinutes: h(30), futureCommittedMinutes: h(6), requestMinutes: h(8) }).error, /54시간/);
  assert.equal(overtimeRequestGuard({ ...base, weekNetMinutes: h(30), requestMinutes: h(8) }).error, undefined);
  assert.equal(overtimeRequestGuard({ ...base, weekNetMinutes: h(44), requestMinutes: h(8) }).projectedMinutes, h(52));
  // 지난 날의 신청·알리기만은 막지 않는다.
  assert.equal(overtimeRequestGuard({ ...base, workDate: '2026-10-13', weekNetMinutes: h(60), requestMinutes: h(4) }).error, undefined);
  assert.equal(overtimeRequestGuard({ ...base, guard: 'warn', weekNetMinutes: h(60), requestMinutes: h(4) }).error, undefined);
  // 사람마다의 주 상한.
  assert.equal(weeklyLimitFor(null), h(52));
  assert.equal(weeklyLimitFor({ periodType: 'flex2w' }), h(60));
  assert.equal(weeklyLimitFor({ periodType: 'flex3m' }), h(64));
  assert.equal(weeklyLimitFor({ periodType: 'select' }), null);
});

test('근무 형태의 기간 — 탄력 2주·3개월, 선택근무 정산은 선택근무·자율에만(1·3개월)', () => {
  const flex = parseSchedule({ mode: 'staggered', start: '09:00', end: '18:00', periodType: 'flex2w', periodStart: '2026-10-05' });
  assert.deepEqual(
    [flex.schedule.periodType, flex.schedule.periodStart, flex.schedule.periodMonths],
    ['flex2w', '2026-10-05', null],
  );
  assert.equal(parseSchedule({ mode: 'free', periodType: 'flex3m', periodStart: '2026-10-01' }).schedule.periodMonths, 3);
  assert.equal(parseSchedule({ mode: 'core', coreStart: '10:00', coreEnd: '15:00', periodType: 'select', periodStart: '2026-10-01', periodMonths: 3 }).schedule.periodMonths, 3);
  assert.match(parseSchedule({ mode: 'staggered', start: '09:00', end: '18:00', periodType: 'select', periodStart: '2026-10-01' }).error, /선택근무·자율/);
  assert.match(parseSchedule({ mode: 'free', periodType: 'select', periodStart: '2026-10-01', periodMonths: 2 }).error, /1개월 또는 3개월/);
  assert.match(parseSchedule({ mode: 'free', periodType: 'flex2w' }).error, /시작하는 날/);
  assert.match(parseSchedule({ mode: 'free', periodType: 'weekly', periodStart: '2026-10-01' }).error, /기간 종류/);
});

test('정산 기간 — 기간 찾기(앞뒤로), 기준 시간·연장·주 상한, 겹치는 기간들', () => {
  const s2 = { periodType: 'flex2w', periodStart: '2026-10-05' };
  assert.deepEqual([workPeriodOf(s2, '2026-10-18').start, workPeriodOf(s2, '2026-10-18').end], ['2026-10-05', '2026-10-19']);
  assert.deepEqual([workPeriodOf(s2, '2026-10-19').start, workPeriodOf(s2, '2026-10-04').start], ['2026-10-19', '2026-09-21']);
  const p = workPeriodOf(s2, '2026-10-10');
  assert.equal(p.standardMinutes, 80 * 60);
  assert.equal(p.overtimeCapMinutes, 24 * 60);
  const s3 = { periodType: 'select', periodStart: '2026-01-15', periodMonths: 1 };
  assert.deepEqual([workPeriodOf(s3, '2026-10-18').start, workPeriodOf(s3, '2026-10-18').end], ['2026-10-15', '2026-11-15']);
  assert.equal(workPeriodOf(s3, '2025-12-20').start, '2025-12-15');
  assert.equal(workPeriodOf(null, '2026-10-18'), null);

  // 2주 기간: 첫 주 5일 × 11시간(휴게 1시간 → 10시간) = 50시간, 둘째 주 5일 × 7시간(→ 6.5시간) = 32.5시간.
  const records = [];
  for (const d of ['2026-10-05', '2026-10-06', '2026-10-07', '2026-10-08', '2026-10-09']) records.push(rec(d, '08:00', '19:00'));
  for (const d of ['2026-10-12', '2026-10-13', '2026-10-14', '2026-10-15', '2026-10-16']) records.push(rec(d, '09:00', '16:00'));
  records.push(rec('2026-10-20', '09:00', '18:00')); // 기간 밖
  const sum = periodSummary(records, p);
  assert.equal(sum.netMinutes, 50 * 60 + 32.5 * 60);
  assert.equal(sum.overtimeMinutes, 2.5 * 60);
  assert.deepEqual(
    sum.weeks.map((w) => [w.weekStart, w.netMinutes, w.over]),
    [
      ['2026-10-05', 50 * 60, false],
      ['2026-10-12', 32.5 * 60, false],
    ],
  );
  assert.equal(sum.status, 'ok');
  // 한 주가 60시간을 넘으면 over.
  const heavy = periodSummary([...records, rec('2026-10-10', '06:00', '18:00')], p);
  assert.equal(heavy.weeks[0].over, true);
  assert.equal(heavy.status, 'over');
  assert.deepEqual(
    periodsOverlapping(s2, '2026-10-01', '2026-10-31').map((x) => x.start),
    ['2026-09-21', '2026-10-05', '2026-10-19'],
  );
});

test('가산 수당 — 연장 1.5배, 야간 가산 0.5배, 휴일 8시간까지 1.5배·넘으면 2배, 5명 미만은 가산 없음', () => {
  const wage = 10_000;
  // 수요일 09:00~23:00 → 연장 5시간, 야간 1시간. 토요일 08:00~19:00 → 휴일 10시간(휴게 1시간) = 8 + 2.
  const records = [rec('2026-10-14', '09:00', '23:00'), rec('2026-10-17', '08:00', '19:00')];
  const a = allowanceOf({ records, wage });
  assert.deepEqual(
    [a.overtimeMinutes, a.nightMinutes, a.holidayMinutes, a.holidayOverMinutes],
    [300, 60, 480, 120],
  );
  assert.equal(a.overtimePay, 75_000);
  assert.equal(a.nightPay, 5_000);
  assert.equal(a.holidayPay, 120_000 + 40_000);
  assert.equal(a.totalPay, 240_000);
  const small = allowanceOf({ records, wage, rates: { smallBusiness: true } });
  assert.deepEqual([small.overtimePay, small.nightPay, small.holidayPay], [50_000, 0, 100_000]);
  // 탄력·선택근무 — 정산 기간의 연장을 대신 쓴다.
  assert.equal(allowanceOf({ records, wage, overtimeMinutes: 120 }).overtimePay, 30_000);

  assert.deepEqual(parsePayRates({ overtime: 60 }).rates, { overtime: 60, night: 50, holiday: 50, holidayOver: 100, smallBusiness: false });
  assert.match(parsePayRates({ overtime: 30 }).error, /법정 가산율/);
  assert.equal(parsePayRates({ overtime: 0, smallBusiness: true }).rates.overtime, 0);
  assert.match(parsePayRates({ night: 1.5 }).error, /정수/);
});

test('출퇴근 위치 — 좌표 검사·사무실 반경·외근 위치 필수', () => {
  assert.deepEqual(parseLocation({ lat: 37.5665123456, lng: '126.978', accuracy: 12.4 }).location, { lat: 37.566512, lng: 126.978, accuracy: 12 });
  assert.equal(parseLocation(null).location, null);
  assert.match(parseLocation({ lat: 91, lng: 0 }).error, /위치를 확인/);
  assert.match(parseLocation({ lat: 37, lng: 127, accuracy: 9000 }).error, /흐립니다/);
  assert.deepEqual(parseOfficeLocation({ lat: 37.5665, lng: 126.978, radius: 300 }).office, { lat: 37.5665, lng: 126.978, radius: 300 });
  assert.match(parseOfficeLocation({ lat: 37.5665, lng: 126.978, radius: 10 }).error, /반경/);
  assert.equal(parseOfficeLocation(null).office, null);
  // 서울시청 ↔ 광화문(약 900m).
  const office = { lat: 37.5665, lng: 126.978, radius: 300 };
  const far = { lat: 37.5759, lng: 126.9768, accuracy: 20 };
  const d = distanceMeters(office, far);
  assert.ok(d > 950 && d < 1150, `거리 ${d}`);
  assert.deepEqual(checkClockLocation({ mode: 'office', location: far, office }), { distance: d, outside: true });
  assert.equal(checkClockLocation({ mode: 'office', location: { lat: 37.5667, lng: 126.978, accuracy: 10 }, office }).outside, false);
  assert.equal(checkClockLocation({ mode: 'field', location: far, office }).outside, false);
  assert.match(checkClockLocation({ mode: 'field', location: null, requireField: true }).error, /위치를 함께/);
  assert.deepEqual(checkClockLocation({ mode: 'office', location: null, requireField: true }), { distance: null, outside: false });
});

test('시간 단위 연차 — 반반차 2시간·시간 연차 1~7시간, 반일 0.25 단위, 지각·조퇴 기준이 옮겨진다', () => {
  const day = '2026-10-14';
  assert.deepEqual(leaveRequestAmount({ leaveType: 'quarter', startDate: day, endDate: day, startTime: '09:00' }), {
    halfDays: 0.5,
    workdays: 1,
    hours: 2,
    startMinutes: 540,
    endMinutes: 660,
  });
  assert.equal(leaveRequestAmount({ leaveType: 'hourly', startDate: day, endDate: day, startTime: '15:00', hours: 3 }).halfDays, 0.75);
  assert.match(leaveRequestAmount({ leaveType: 'hourly', startDate: day, endDate: day, startTime: '15:00', hours: 8 }).error, /1~7시간/);
  assert.match(leaveRequestAmount({ leaveType: 'hourly', startDate: day, endDate: '2026-10-15', startTime: '15:00', hours: 2 }).error, /하루만/);
  assert.match(leaveRequestAmount({ leaveType: 'quarter', startDate: '2026-10-17', endDate: '2026-10-17', startTime: '09:00' }).error, /근무일/);
  assert.match(leaveRequestAmount({ leaveType: 'quarter', startDate: day, endDate: day, startTime: '9시' }).error, /HH:MM/);
  assert.match(leaveRequestAmount({ leaveType: 'hourly', startDate: day, endDate: day, startTime: '22:00', hours: 3 }).error, /그날 안/);

  const parsed = parseLeavePayload({ leaveType: 'quarter', startDate: day, startTime: '09:00' });
  assert.deepEqual(
    [parsed.payload.halfDays, parsed.payload.hours, parsed.payload.startTime, parsed.payload.endTime],
    [0.5, 2, '09:00', '11:00'],
  );
  assert.equal(defaultApprovalTitle('leave', parsed.payload), '반반차 신청 (10/14 09:00~11:00, 2시간)');
  // 오전 2시간을 쓰면 11:00까지 출근해도 지각이 아니고, 오후 2시간이면 16:00 퇴근이 조퇴가 아니다.
  const r = rec(day, '10:50', '16:00');
  assert.equal(recordFlags(r, { hourRange: { start: 540, end: 660 } }).late, false);
  assert.equal(recordFlags(r, { hourRange: { start: 540, end: 660 } }).earlyLeave, true);
  assert.equal(recordFlags(r, { hourRange: { start: 960, end: 1080 } }).earlyLeave, false);
  assert.equal(recordFlags(r).late, true);

  assert.equal(leaveAmountText(3), '1.5일');
  assert.equal(leaveAmountText(0.5), '2시간');
  assert.equal(leaveAmountText(4.75), '2일 3시간');
  assert.equal(leaveAmountText(-0.25), '-1시간');
  const types = mergeLeaveTypes(null);
  assert.deepEqual(
    types.filter((t) => t.hourly).map((t) => [t.key, t.fixedHours]),
    [
      ['quarter', 2],
      ['hourly', null],
    ],
  );
});

test('회계연도 기준 연차 — 입사한 해는 월 1일, 다음 해는 일한 날 비율의 15일 + 남은 월차, 그 뒤 15·16일 …', () => {
  assert.deepEqual(fiscalPeriodOf('2026-10-18', 1), { start: '2026-01-01', end: '2027-01-01' });
  assert.deepEqual(fiscalPeriodOf('2026-02-10', 3), { start: '2025-03-01', end: '2026-03-01' });
  const opts = { basis: 'fiscal', fiscalStartMonth: 1, hireDate: '2025-07-01' };
  // 입사한 해 — 2025-10-15에 3개월 → 3일.
  assert.deepEqual(leavePeriodFor({ ...opts, today: '2025-10-15' }), { year: 0, start: '2025-01-01', end: '2026-01-01' });
  assert.equal(statutoryHalfDaysFor({ ...opts, today: '2025-10-15' }), 6);
  // 다음 해 2026-03-10 — 15 × 184/365 = 7.56일 → 반일 올림 16 + 1년이 될 때까지 이 해에 채운 달(1·2월 2개월 → 2026-03-01까지 8개월, 앞 해 6개월) 2일.
  assert.equal(statutoryHalfDaysFor({ ...opts, today: '2026-03-10' }), 16 + 4);
  // 1년이 지난 뒤(2026-10) — 월차는 11개월까지(앞 해 6개월 + 이 해 5개월).
  assert.equal(statutoryHalfDaysFor({ ...opts, today: '2026-10-18' }), 16 + 10);
  assert.equal(statutoryHalfDaysFor({ ...opts, today: '2027-05-01' }), 30);
  assert.equal(statutoryHalfDaysFor({ ...opts, today: '2028-05-01' }), 32);
  // 입사일 기준은 그대로.
  assert.equal(statutoryHalfDaysFor({ hireDate: '2025-07-01', today: '2026-10-18' }), 30);
  const balance = leaveBalance({ ...opts, today: '2027-05-01', usedHalfDays: 3, adjustmentHalfDays: 2.5 });
  assert.deepEqual([balance.period.start, balance.grantedHalfDays, balance.remainingHalfDays], ['2027-01-01', 32.5, 29.5]);
  // 촉진 일정도 회계연도 끝 기준.
  assert.equal(promotionSchedule('2025-07-01', '2027-05-01', { basis: 'fiscal', fiscalStartMonth: 1 }).expiry, '2027-12-31');
  assert.equal(promotionSchedule('2025-07-01', '2027-05-01').expiry, '2027-06-30');
});

test('연차 이월 — 남은 연차를 상한까지, 끄면 0, 모자라면 0', () => {
  assert.equal(carryOverHalfDays(7.5, 5), 7.5);
  assert.equal(carryOverHalfDays(20, 5), 10);
  assert.equal(carryOverHalfDays(20, 0), 0);
  assert.equal(carryOverHalfDays(-3, 5), 0);
  assert.equal(carryOverHalfDays(null, 5), 0);
});
