// 근태·휴가 관리 규칙 — 휴가 종류·지출 분류 설정, 하루 근로 나누기(휴게·연장·야간·휴일), 주 52시간, 유연근무(근무 형태로 지각·조퇴),
// 출근·퇴근 알림, 출근 형태(외근·재택), 연차 사용 촉진 일정(근로기준법 제61조). `node --test test/*.test.js`(DB 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseLeavePayload } from '../src/approvalRules.js';
import { dateAtMinutes } from '../src/attendanceRules.js';
import { expenseCategoriesOf, mergeLeaveTypes, optionsView, parseExpenseCategories, parseLeaveTypesInput } from '../src/groupwareOptions.js';
import { parseLeaveDates, promotionSchedule, promotionStage } from '../src/leavePromotion.js';
import {
  breakMinutesFor,
  effectiveHours,
  monthBreakdown,
  nightMinutesBetween,
  parseClockIn,
  parseSchedule,
  reminderDue,
  scheduledFlags,
  weekStartOf,
  weeklySummary,
  weeksOfMonth,
  workBreakdown,
} from '../src/workRules.js';

const rec = (date, inHm, outHm, { nextDayOut = false } = {}) => {
  const [ih, im] = inHm.split(':').map(Number);
  const [oh, om] = outHm.split(':').map(Number);
  const outDate = nextDayOut ? new Date(dateAtMinutes(date, 0).getTime() + 86_400_000) : dateAtMinutes(date, 0);
  return {
    workDate: date,
    clockInAt: dateAtMinutes(date, ih * 60 + im),
    clockOutAt: new Date(outDate.getFullYear(), outDate.getMonth(), outDate.getDate(), oh, om),
  };
};

test('휴가 종류 — 기본 종류 이름·끄기, 더한 종류, 빠진 종류는 꺼진 채 남김, 연차는 못 끔', () => {
  const base = mergeLeaveTypes(null);
  // 기본 7가지 + 시간 단위 연차(반반차·시간 연차).
  assert.equal(base.length, 9);
  assert.ok(base.every((t) => t.enabled && t.builtin));
  let key = 0;
  const parsed = parseLeaveTypesInput(
    [
      { key: 'annual', label: '연차휴가' },
      { key: 'sick', label: '병가', enabled: false },
      { label: '리프레시 휴가', deducts: false },
      { label: '생일 반나절', deducts: true, enabled: true },
    ],
    { newKey: () => `c_k${(key += 1)}` },
  );
  assert.equal(parsed.error, undefined);
  const merged = mergeLeaveTypes(parsed.stored);
  assert.equal(merged.find((t) => t.key === 'annual').label, '연차휴가');
  assert.equal(merged.find((t) => t.key === 'sick').enabled, false);
  assert.equal(merged.find((t) => t.key === 'half_am').enabled, false, '목록에서 빠진 기본 종류는 꺼진다');
  assert.deepEqual(
    merged.filter((t) => !t.builtin).map((t) => [t.key, t.label, t.deducts, t.half]),
    [
      ['c_k1', '리프레시 휴가', false, false],
      ['c_k2', '생일 반나절', true, false],
    ],
  );
  // 다시 저장할 때 더한 종류를 빼면 꺼진 채 남는다(예전 신청의 이름).
  const again = mergeLeaveTypes(parseLeaveTypesInput([{ key: 'annual', label: '연차' }], { previous: parsed.stored }).stored);
  assert.equal(again.find((t) => t.key === 'c_k1').enabled, false);
  assert.equal(again.find((t) => t.key === 'c_k1').label, '리프레시 휴가');
  assert.match(parseLeaveTypesInput([{ key: 'annual', label: '연차', enabled: false }]).error, /연차는 끌 수/);
  assert.match(parseLeaveTypesInput([{ key: 'sick', label: '병가' }]).error, /연차는 지울 수/);
  assert.match(parseLeaveTypesInput([{ key: 'annual', label: '연차' }, { label: '연차' }]).error, /같은 이름/);
  assert.match(parseLeaveTypesInput([{ key: 'annual', label: '' }]).error, /이름/);
});

test('휴가 신청 — 범위의 켜진 종류만, 이름·차감 여부를 문서에 적는다', () => {
  const types = mergeLeaveTypes([
    { key: 'c_ref', label: '리프레시', deducts: false, custom: true },
    { key: 'sick', label: '병가', enabled: false },
  ]);
  const ok = parseLeavePayload({ leaveType: 'c_ref', startDate: '2026-10-19', endDate: '2026-10-20' }, new Set(), types);
  assert.deepEqual(ok.payload, { leaveType: 'c_ref', leaveLabel: '리프레시', deducts: false, startDate: '2026-10-19', endDate: '2026-10-20', halfDays: 4 });
  assert.ok(parseLeavePayload({ leaveType: 'sick', startDate: '2026-10-19' }, new Set(), types).error, '꺼진 종류');
  assert.equal(parseLeavePayload({ leaveType: 'annual', startDate: '2026-10-19' }, new Set(), types).payload.deducts, true);
});

test('지출 분류', () => {
  assert.deepEqual(parseExpenseCategories([' 교통비 ', '식대', '', '도서']), { categories: ['교통비', '식대', '도서'] });
  assert.ok(parseExpenseCategories([]).error);
  assert.ok(parseExpenseCategories(['a', 'a']).error);
  assert.ok(parseExpenseCategories(['가'.repeat(21)]).error);
  assert.equal(expenseCategoriesOf(null).length, 7, '기본');
  assert.deepEqual(optionsView(null).clockInReminder, false);
});

test('하루 나누기 — 휴게(4시간 30분·8시간 30분), 연장(8시간 넘음), 휴일(주말·공휴일), 야간(22~06시)', () => {
  assert.equal(breakMinutesFor(4 * 60 + 29), 0);
  assert.equal(breakMinutesFor(4 * 60 + 30), 30);
  assert.equal(breakMinutesFor(9 * 60), 60);
  // 수요일 09:00~18:00 = 9시간, 휴게 1시간 → 실근로 8시간, 연장 없음.
  assert.deepEqual(workBreakdown(rec('2026-10-14', '09:00', '18:00')), {
    workedMinutes: 540, breakMinutes: 60, netMinutes: 480, overtimeMinutes: 0, holidayMinutes: 0, nightMinutes: 0,
    breakRecorded: false, breakShortMinutes: 0,
  });
  // 09:00~23:00 = 14시간 → 실근로 13시간, 연장 5시간, 야간 1시간.
  const late = workBreakdown(rec('2026-10-14', '09:00', '23:00'));
  assert.equal(late.netMinutes, 780);
  assert.equal(late.overtimeMinutes, 300);
  assert.equal(late.nightMinutes, 60);
  // 토요일 10:00~15:00 — 휴일 근무(휴게 30분).
  assert.deepEqual(
    [workBreakdown(rec('2026-10-17', '10:00', '15:00')).holidayMinutes, workBreakdown(rec('2026-10-17', '10:00', '15:00')).overtimeMinutes],
    [270, 0],
  );
  // 공휴일.
  assert.equal(workBreakdown(rec('2026-10-14', '09:00', '13:00'), { holidays: new Set(['2026-10-14']) }).holidayMinutes, 240);
  // 밤샘 21:00~다음 날 03:00 — 야간 5시간.
  assert.equal(nightMinutesBetween(dateAtMinutes('2026-10-14', 21 * 60), dateAtMinutes('2026-10-15', 3 * 60)), 300);
  // 새벽 05:00~07:00 — 야간 1시간.
  assert.equal(nightMinutesBetween(dateAtMinutes('2026-10-14', 5 * 60), dateAtMinutes('2026-10-14', 7 * 60)), 60);
  assert.equal(workBreakdown({ workDate: '2026-10-14', clockInAt: new Date() }).netMinutes, 0, '퇴근 전');
  const sum = monthBreakdown([rec('2026-10-14', '09:00', '23:00'), rec('2026-10-17', '10:00', '15:00')]);
  assert.deepEqual(sum, { netMinutes: 1050, actualOvertimeMinutes: 300, nightMinutes: 60, holidayWorkMinutes: 270 });
});

test('주 52시간 — 월~일, 휴일 근무 포함, 48시간부터 주의, 52시간 넘으면 넘음', () => {
  assert.equal(weekStartOf('2026-10-14'), '2026-10-12', '수 → 월');
  assert.equal(weekStartOf('2026-10-18'), '2026-10-12', '일 → 그 주 월');
  assert.equal(weekStartOf('2026-10-12'), '2026-10-12');
  const days = ['2026-10-12', '2026-10-13', '2026-10-14', '2026-10-15', '2026-10-16'];
  const normal = weeklySummary(days.map((d) => rec(d, '09:00', '18:00')), '2026-10-12');
  assert.deepEqual([normal.netMinutes, normal.overtimeMinutes, normal.status], [2400, 0, 'ok']);
  const heavy = weeklySummary([...days.map((d) => rec(d, '08:00', '19:00')), rec('2026-10-17', '09:00', '15:00')], '2026-10-12');
  // 평일 11시간 - 1시간 = 10시간 × 5 = 50시간, 토요일 6시간 - 30분 = 5.5시간 → 55.5시간.
  assert.equal(heavy.netMinutes, 50 * 60 + 330);
  assert.equal(heavy.holidayMinutes, 330);
  assert.equal(heavy.overtimeMinutes, 600, '하루 8시간 넘은 2시간 × 5');
  assert.equal(heavy.status, 'over');
  const warn = weeklySummary(days.map((d) => rec(d, '08:00', '18:40')), '2026-10-12');
  assert.equal(warn.status, 'warn');
  assert.equal(weeklySummary([rec('2026-10-19', '09:00', '18:00')], '2026-10-12').netMinutes, 0, '다른 주 기록은 거른다');
  const oct = Array.from({ length: 31 }, (_, i) => `2026-10-${String(i + 1).padStart(2, '0')}`);
  assert.deepEqual(weeksOfMonth(oct), ['2026-09-28', '2026-10-05', '2026-10-12', '2026-10-19', '2026-10-26']);
});

test('유연근무 — 시차출퇴근·선택근무(핵심 시간)·자율, 지각·조퇴 기준', () => {
  assert.deepEqual(parseSchedule({ mode: 'staggered', start: '07:00', end: '16:00' }).schedule, {
    mode: 'staggered', startMinutes: 420, endMinutes: 960, coreStartMinutes: null, coreEndMinutes: null,
    periodType: null, periodStart: null, periodMonths: null,
  });
  assert.ok(parseSchedule({ mode: 'staggered', start: '16:00', end: '07:00' }).error);
  assert.equal(parseSchedule({ mode: 'core', coreStart: '10:00', coreEnd: '15:00' }).schedule.coreStartMinutes, 600);
  assert.ok(parseSchedule({ mode: 'core' }).error);
  assert.equal(parseSchedule({ mode: 'free' }).schedule.mode, 'free');
  assert.ok(parseSchedule({ mode: 'night' }).error);
  const scope = { workStart: 540, workEnd: 1080 };
  const r = rec('2026-10-14', '09:30', '17:00');
  assert.deepEqual(effectiveHours(null, scope), { workStart: 540, workEnd: 1080, checkLate: true, checkEarly: true });
  const def = scheduledFlags(r, effectiveHours(null, scope));
  assert.deepEqual([def.late, def.earlyLeave], [true, true]);
  const staggered = scheduledFlags(r, effectiveHours({ mode: 'staggered', startMinutes: 600, endMinutes: 1020 }, scope));
  assert.deepEqual([staggered.late, staggered.earlyLeave], [false, false], '10시~17시 근무');
  const core = scheduledFlags(r, effectiveHours({ mode: 'core', coreStartMinutes: 600, coreEndMinutes: 960 }, scope));
  assert.deepEqual([core.late, core.earlyLeave], [false, false], '핵심 시간 10~16시 안');
  const free = scheduledFlags(rec('2026-10-14', '13:00', '15:00'), effectiveHours({ mode: 'free' }, scope));
  assert.deepEqual([free.late, free.earlyLeave], [false, false]);
});

test('출근·퇴근 알림 — 근무 시작 + 분 지나서 출근 없음, 근무 끝 1시간 뒤 퇴근 없음, 쉬는 날·보낸 뒤는 없음', () => {
  const hours = { workStart: 540, workEnd: 1080 };
  const at = (hm) => dateAtMinutes('2026-10-14', Number(hm.slice(0, 2)) * 60 + Number(hm.slice(3)));
  const base = { hours, delay: 10, record: null };
  assert.equal(reminderDue({ ...base, now: at('09:05') }), null, '아직 이르다');
  assert.equal(reminderDue({ ...base, now: at('09:10') }), 'in');
  assert.equal(reminderDue({ ...base, now: at('12:11') }), null, '3시간이 지나면 안 보낸다');
  assert.equal(reminderDue({ ...base, now: at('09:30'), sent: new Set(['in']) }), null);
  assert.equal(reminderDue({ ...base, now: at('09:30'), offToday: true }), null, '휴가·출장');
  assert.equal(reminderDue({ ...base, now: dateAtMinutes('2026-10-17', 600) }), null, '토요일');
  assert.equal(reminderDue({ ...base, now: at('09:30'), clockIn: false }), null, '출근 알림 끔');
  const working = { workDate: '2026-10-14', clockInAt: at('09:00'), clockOutAt: null };
  assert.equal(reminderDue({ ...base, record: working, now: at('18:30') }), null);
  assert.equal(reminderDue({ ...base, record: working, now: at('19:00') }), 'out');
  assert.equal(reminderDue({ ...base, record: { ...working, clockOutAt: at('18:00') }, now: at('19:00') }), null);
  assert.equal(reminderDue({ ...base, record: working, now: at('19:00'), clockOut: false }), null);
});

test('출근 형태 — 외근은 장소가 있어야', () => {
  assert.deepEqual(parseClockIn({}), { mode: 'office', note: null });
  assert.deepEqual(parseClockIn({ mode: 'remote' }), { mode: 'remote', note: null });
  assert.ok(parseClockIn({ mode: 'field' }).error);
  assert.deepEqual(parseClockIn({ mode: 'field', note: ' 고객사(판교) ' }), { mode: 'field', note: '고객사(판교)' });
  assert.ok(parseClockIn({ mode: 'moon' }).error);
});

test('연차 촉진 일정 — 1년 이상은 만료 6개월 전 10일·2개월 전, 첫해는 3개월 전·1개월 전', () => {
  // 2020-05-10 입사 → 2026-05-10 ~ 2027-05-09 기간.
  const s = promotionSchedule('2020-05-10', '2026-10-17');
  assert.deepEqual(s, {
    periodStart: '2026-05-10',
    periodEnd: '2027-05-10',
    expiry: '2027-05-09',
    firstYear: false,
    firstStart: '2026-11-09',
    firstEnd: '2026-11-18',
    secondDeadline: '2027-03-09',
  });
  const first = promotionSchedule('2026-03-02', '2026-10-17');
  assert.equal(first.firstYear, true);
  assert.equal(first.expiry, '2027-03-01');
  assert.equal(first.firstStart, '2026-12-01');
  assert.equal(first.secondDeadline, '2027-02-01');
  assert.equal(promotionSchedule(null, '2026-10-17'), null);
});

test('연차 촉진 단계 — 이르다·1차·기다림·2차·끝남·놓침·없음', () => {
  const s = promotionSchedule('2020-05-10', '2026-10-17');
  const st = (today, notices = [], remaining = 10) => promotionStage({ schedule: s, today, remainingHalfDays: remaining, notices });
  assert.equal(st('2026-10-17'), 'upcoming');
  assert.equal(st('2026-11-10'), 'first');
  assert.equal(st('2026-11-10', [], 0), 'none', '남은 연차 없음');
  assert.equal(st('2026-11-25'), 'missed', '1차 기간을 놓침');
  const sent = { stage: 1, deadline: '2026-11-20', planDates: null };
  assert.equal(st('2026-11-15', [sent]), 'awaiting');
  assert.equal(st('2026-11-21', [sent]), 'second');
  assert.equal(st('2027-03-10', [sent]), 'missed', '2차 마감도 지남');
  assert.equal(st('2026-11-21', [{ ...sent, planDates: ['2027-01-05'] }]), 'done');
  assert.equal(st('2026-11-21', [sent, { stage: 2 }]), 'done');
});

test('쓸 날 고르기 — 기간 안·겹침 없이·남은 일수까지', () => {
  const opts = { from: '2026-11-20', expiry: '2027-05-09', maxDays: 3 };
  assert.deepEqual(parseLeaveDates(['2027-01-06', '2027-01-05'], opts), { dates: ['2027-01-05', '2027-01-06'] });
  assert.ok(parseLeaveDates([], opts).error);
  assert.ok(parseLeaveDates(['2027-01-05', '2027-01-05'], opts).error);
  assert.ok(parseLeaveDates(['2026-11-01'], opts).error, '기간 밖');
  assert.ok(parseLeaveDates(['2027-01-05', '2027-01-06', '2027-01-07', '2027-01-08'], opts).error, '남은 일수보다 많음');
  assert.ok(parseLeaveDates(['2027-02-30'], opts).error);
});
