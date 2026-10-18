import { addDaysKey, isDateKey, isWorkday, weekdayOf } from './annualLeave.js';
import { localDateKey, minutesOfDay, parseHm, recordFlags } from './attendanceRules.js';

/**
 * 근로시간 규칙 — 하루 기록을 휴게·연장·야간·휴일 근무로 나누기, 주 52시간(주 40시간 + 연장 12시간 — 근로기준법 제50·53조), 유연근무
 * (사람마다의 근무 형태로 지각·조퇴 따지기), 출근·퇴근 알림을 보낼지. DB 없이 시험할 수 있게 계산만 모았다(groupwareWork.js·groupware.js가
 * 쓴다, test/groupwareWork.test.js). 시각은 서버 PC 기준(attendanceRules.js와 같다).
 *
 * 하루 나누기(실제 출퇴근 기록 기준 — 결재로 받은 연장근무 신청과는 따로 본다):
 *  - 휴게: 휴게 시작·끝을 직접 누른 날은 누른 시간(출근~퇴근 안에서 닫힌 것)을 빼고, 법정 휴게보다 짧으면 모자란 분을 알린다
 *    (breakShortMinutes). 누르지 않은 날은 일한 시간이 8시간 30분 이상이면 1시간, 4시간 30분 이상이면 30분을 뺀다(제54조 — 4시간마다
 *    30분, 8시간이면 1시간).
 *  - 연장: 근무일에 휴게를 뺀 시간 중 8시간을 넘는 부분.
 *  - 휴일: 주말·공휴일에 일한 시간(휴게를 뺀 것) 전부.
 *  - 야간: 22:00~06:00에 걸친 시간(누른 휴게가 그 안에 들면 뺀다 — 누르지 않은 날은 언제 쉬었는지 몰라 빼지 않는다).
 */

export const DAILY_LIMIT_MINUTES = 8 * 60;
export const WEEKLY_BASE_MINUTES = 40 * 60;
export const WEEKLY_LIMIT_MINUTES = 52 * 60;
/** 주 52시간에 가까워졌다고 알리는 선(48시간). */
export const WEEKLY_WARN_MINUTES = 48 * 60;
export const NIGHT_START = 22 * 60;
export const NIGHT_END = 6 * 60;

/** 일한 시간(분)의 법정 휴게(분). */
export function breakMinutesFor(workedMinutes) {
  if (workedMinutes >= 8 * 60 + 30) return 60;
  if (workedMinutes >= 4 * 60 + 30) return 30;
  return 0;
}

/** [start]~[end](Date) 가운데 22:00~06:00에 든 분. */
export function nightMinutesBetween(start, end) {
  let total = 0;
  const s = new Date(start).getTime();
  const e = new Date(end).getTime();
  if (!(e > s)) return 0;
  // 출근한 날 전날 밤부터 퇴근한 날 밤까지 날마다 22:00~다음 날 06:00 구간과 겹치는 만큼.
  const first = new Date(s);
  for (let day = new Date(first.getFullYear(), first.getMonth(), first.getDate() - 1); day.getTime() <= e; ) {
    const nightStart = new Date(day.getFullYear(), day.getMonth(), day.getDate(), 22, 0).getTime();
    const nightEnd = new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1, 6, 0).getTime();
    const overlap = Math.min(e, nightEnd) - Math.max(s, nightStart);
    if (overlap > 0) total += overlap;
    day = new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1);
  }
  return Math.round(total / 60000);
}

/** 하루에 누를 수 있는 휴게 수. */
export const BREAKS_MAX = 10;

/** 누른 휴게들([breaks] `[{ startAt, endAt }]`) 중 [inAt]~[outAt] 안에서 닫힌 구간들(겹치는 부분만, Date). */
function closedBreaks(breaks, inAt, outAt) {
  const out = [];
  for (const b of Array.isArray(breaks) ? breaks : []) {
    if (!b?.startAt || !b?.endAt) continue;
    const s = Math.max(new Date(b.startAt).getTime(), inAt.getTime());
    const e = Math.min(new Date(b.endAt).getTime(), outAt.getTime());
    if (e > s) out.push([new Date(s), new Date(e)]);
  }
  return out;
}

/**
 * 기록 하나 → `{ workedMinutes, breakMinutes, netMinutes, overtimeMinutes, holidayMinutes, nightMinutes, breakRecorded, breakShortMinutes }`
 * (퇴근을 안 눌렀으면 모두 0). [holidays]는 공휴일 모음. 휴게를 누른 날([record.breaks])은 누른 시간을 뺀다.
 */
export function workBreakdown(record, { holidays = new Set() } = {}) {
  const zero = {
    workedMinutes: 0,
    breakMinutes: 0,
    netMinutes: 0,
    overtimeMinutes: 0,
    holidayMinutes: 0,
    nightMinutes: 0,
    breakRecorded: false,
    breakShortMinutes: 0,
  };
  if (!record?.clockInAt || !record?.clockOutAt) return zero;
  const inAt = new Date(record.clockInAt);
  const outAt = new Date(record.clockOutAt);
  if (!(outAt > inAt)) return zero;
  const worked = Math.round((outAt - inAt) / 60000);
  const statutory = breakMinutesFor(worked);
  const pressed = closedBreaks(record.breaks, inAt, outAt);
  const pressedMinutes = Math.round(pressed.reduce((sum, [s, e]) => sum + (e - s), 0) / 60000);
  const brk = pressed.length ? Math.min(worked, pressedMinutes) : statutory;
  const net = Math.max(0, worked - brk);
  const workday = isWorkday(record.workDate, holidays);
  const nightBreak = pressed.reduce((sum, [s, e]) => sum + nightMinutesBetween(s, e), 0);
  return {
    workedMinutes: worked,
    breakMinutes: brk,
    netMinutes: net,
    overtimeMinutes: workday ? Math.max(0, net - DAILY_LIMIT_MINUTES) : 0,
    holidayMinutes: workday ? 0 : net,
    nightMinutes: Math.max(0, nightMinutesBetween(inAt, outAt) - nightBreak),
    breakRecorded: pressed.length > 0,
    breakShortMinutes: pressed.length ? Math.max(0, statutory - brk) : 0,
  };
}

/**
 * 휴게 누르기 — [action] 'start' | 'end', [record]는 그날(또는 밤을 넘긴 어제) 기록. 출근했고 퇴근 전이어야 하고, 시작은 열린 휴게가 없을 때·
 * 하루 [BREAKS_MAX]번까지, 끝은 열린 휴게가 있을 때. `{ breaks }`(저장할 목록 — ISO 시각) | `{ error, status }`.
 */
export function applyBreakAction(record, action, now = new Date()) {
  if (!record?.clockInAt) return { error: '출근을 먼저 누르세요.', status: 409 };
  if (record.clockOutAt) return { error: '이미 퇴근을 눌렀습니다.', status: 409 };
  const list = (Array.isArray(record.breaks) ? record.breaks : []).map((b) => ({ startAt: b.startAt, endAt: b.endAt ?? null }));
  const open = list.find((b) => !b.endAt);
  const at = new Date(now).toISOString();
  if (action === 'start') {
    if (open) return { error: '이미 휴게 중입니다.', status: 409 };
    if (list.length >= BREAKS_MAX) return { error: `휴게는 하루 ${BREAKS_MAX}번까지 누를 수 있습니다.`, status: 409 };
    return { breaks: [...list, { startAt: at, endAt: null }] };
  }
  if (action === 'end') {
    if (!open) return { error: '휴게 중이 아닙니다.', status: 409 };
    return { breaks: list.map((b) => (b === open ? { ...b, endAt: at } : b)) };
  }
  return { error: '알 수 없는 동작입니다.', status: 400 };
}

/** 퇴근할 때 열린 휴게는 퇴근 시각으로 닫는다. */
export function closeOpenBreaks(breaks, at) {
  const iso = new Date(at).toISOString();
  return (Array.isArray(breaks) ? breaks : []).map((b) => (b.endAt ? b : { ...b, endAt: iso }));
}

/** 그 날이 든 주의 월요일('YYYY-MM-DD'). */
export function weekStartOf(dateKey) {
  const wd = weekdayOf(dateKey); // 0 = 일
  return addDaysKey(dateKey, wd === 0 ? -6 : 1 - wd);
}

/**
 * 한 주(월~일) 근로시간 — [records]는 그 주 기록(다른 날 것이 섞여도 거른다). 주 52시간은 휴일 근무까지 더한 실근로(휴게 뺀) 시간으로
 * 본다(2018년 개정 — 1주 = 휴일 포함 7일). `{ weekStart, weekEnd, netMinutes, overtimeMinutes(주 40시간 넘은 것 — 하루 8시간 넘은 것과
 * 큰 쪽), holidayMinutes, nightMinutes, status('ok' | 'warn' — 48시간 이상 | 'over' — 52시간 넘음) }`.
 */
export function weeklySummary(records, weekStart, { holidays = new Set() } = {}) {
  const weekEnd = addDaysKey(weekStart, 6);
  let net = 0;
  let dailyOver = 0;
  let holiday = 0;
  let night = 0;
  for (const r of records) {
    if (!r?.workDate || r.workDate < weekStart || r.workDate > weekEnd) continue;
    const b = workBreakdown(r, { holidays });
    net += b.netMinutes;
    dailyOver += b.overtimeMinutes;
    holiday += b.holidayMinutes;
    night += b.nightMinutes;
  }
  const weeklyOver = Math.max(0, net - holiday - WEEKLY_BASE_MINUTES);
  return {
    weekStart,
    weekEnd,
    netMinutes: net,
    overtimeMinutes: Math.max(dailyOver, weeklyOver),
    holidayMinutes: holiday,
    nightMinutes: night,
    status: net > WEEKLY_LIMIT_MINUTES ? 'over' : net >= WEEKLY_WARN_MINUTES ? 'warn' : 'ok',
  };
}

/** [monthKey] 달에 걸친 주들의 월요일(그 달 1일이 든 주부터 말일이 든 주까지). */
export function weeksOfMonth(days) {
  if (!days.length) return [];
  const out = [];
  for (let w = weekStartOf(days[0]); w <= days[days.length - 1]; w = addDaysKey(w, 7)) out.push(w);
  return out;
}

// ── 유연근무 ──

export const WORK_MODES = Object.freeze(['staggered', 'core', 'free']);
export const WORK_MODE_LABEL = Object.freeze({ staggered: '시차출퇴근', core: '선택근무', free: '자율 출퇴근' });

/**
 * 근무 형태 입력 `{ mode, start?, end?, coreStart?, coreEnd? }`('HH:MM') 검사 → 저장할 값
 * `{ mode, startMinutes, endMinutes, coreStartMinutes, coreEndMinutes }` | `{ error }`. 시차출퇴근은 시작<끝(하루 안), 선택근무는 핵심
 * 시간대 시작<끝, 자율은 시각 없이.
 */
export function parseSchedule(input) {
  const mode = input?.mode;
  if (!WORK_MODES.includes(mode)) return { error: '근무 형태를 고르세요(시차출퇴근·선택근무·자율 출퇴근).' };
  const period = parsePeriod(input, mode);
  if (period.error) return period;
  const none = { startMinutes: null, endMinutes: null, coreStartMinutes: null, coreEndMinutes: null, ...period.period };
  if (mode === 'free') return { schedule: { mode, ...none } };
  if (mode === 'staggered') {
    const start = parseHm(input?.start);
    const end = parseHm(input?.end);
    if (start === null || end === null || start >= end) return { error: '출근·퇴근 시각을 HH:MM으로, 출근이 퇴근보다 앞이게 넣으세요.' };
    return { schedule: { mode, ...none, startMinutes: start, endMinutes: end } };
  }
  const coreStart = parseHm(input?.coreStart);
  const coreEnd = parseHm(input?.coreEnd);
  if (coreStart === null || coreEnd === null || coreStart >= coreEnd) return { error: '핵심 시간대를 HH:MM으로, 시작이 끝보다 앞이게 넣으세요.' };
  return { schedule: { mode, ...none, coreStartMinutes: coreStart, coreEndMinutes: coreEnd } };
}

/** 탄력적 근로시간제의 단위 기간·선택근무의 정산 기간(workPolicy.js). */
export const PERIOD_TYPES = Object.freeze(['flex2w', 'flex3m', 'select']);
export const PERIOD_TYPE_LABEL = Object.freeze({ flex2w: '탄력 2주', flex3m: '탄력 3개월', select: '선택근무 정산' });

/**
 * 근무 형태의 기간 입력 `{ periodType?, periodStart?, periodMonths? }` → `{ period: { periodType, periodStart, periodMonths } }` | `{ error }`.
 * 없으면 모두 null(주 단위 — 주 52시간). 선택근무 정산은 선택근무·자율 출퇴근에만, 1개월 또는 3개월(신상품·연구개발).
 */
function parsePeriod(input, mode) {
  const type = input?.periodType ?? null;
  if (type === null || type === '') return { period: { periodType: null, periodStart: null, periodMonths: null } };
  if (!PERIOD_TYPES.includes(type)) return { error: '근로시간 기간 종류를 확인하세요(탄력 2주·탄력 3개월·선택근무 정산).' };
  if (type === 'select' && mode !== 'core' && mode !== 'free') {
    return { error: '선택근무 정산 기간은 선택근무·자율 출퇴근에만 정할 수 있습니다.' };
  }
  if (!isDateKey(input?.periodStart)) return { error: '기간이 시작하는 날을 정하세요.' };
  const months = type === 'select' ? Number(input?.periodMonths ?? 1) : type === 'flex3m' ? 3 : null;
  if (type === 'select' && months !== 1 && months !== 3) return { error: '선택근무 정산 기간은 1개월 또는 3개월입니다.' };
  return { period: { periodType: type, periodStart: input.periodStart, periodMonths: months } };
}

/**
 * 그 사람의 지각·조퇴 기준 — 근무 형태가 없으면 범위의 근무 시간. `{ workStart, workEnd, checkLate, checkEarly }`(선택근무는 핵심 시간대가
 * 기준, 자율은 안 따짐). 출근 알림의 "근무 시작"도 이것(자율은 범위의 근무 시작).
 */
export function effectiveHours(schedule, { workStart, workEnd }) {
  if (!schedule) return { workStart, workEnd, checkLate: true, checkEarly: true };
  if (schedule.mode === 'staggered') return { workStart: schedule.startMinutes, workEnd: schedule.endMinutes, checkLate: true, checkEarly: true };
  if (schedule.mode === 'core') {
    return { workStart: schedule.coreStartMinutes, workEnd: schedule.coreEndMinutes, checkLate: true, checkEarly: true };
  }
  return { workStart, workEnd, checkLate: false, checkEarly: false };
}

/** 근무 형태를 반영한 기록 표시(attendanceRules.js recordFlags + 자율이면 지각·조퇴 없음). */
export function scheduledFlags(record, hours, { halfType = null, fullLeave = false, hourRange = null } = {}) {
  const flags = recordFlags(record, { workStart: hours.workStart, workEnd: hours.workEnd, halfType, fullLeave, hourRange });
  return { ...flags, late: hours.checkLate && flags.late, earlyLeave: hours.checkEarly && flags.earlyLeave };
}

// ── 출근·퇴근 알림 ──

/** 출근 알림을 보낼 시간대 — 근무 시작 + [delay]분부터 3시간 동안(그 뒤로는 늦었다고 알리지 않는다). */
export const REMINDER_WINDOW_MINUTES = 180;
/** 퇴근 알림 — 근무 끝 1시간 뒤부터 3시간. */
export const CLOCK_OUT_REMINDER_AFTER = 60;

/**
 * 지금 이 사람에게 출근·퇴근 알림을 보낼지 — `'in' | 'out' | null`. [today]가 근무일이 아니거나, 휴가(하루)·출장인 날이거나, 이미 보냈으면
 * ([sent] — 'in'·'out' 모음) 보내지 않는다. 출근 알림은 출근 기록이 없을 때, 퇴근 알림은 출근은 했는데 퇴근을 안 눌렀을 때.
 */
export function reminderDue({ now, record, hours, delay, holidays = new Set(), offToday = false, sent = new Set(), clockIn = true, clockOut = true }) {
  const today = localDateKey(now);
  if (!isWorkday(today, holidays) || offToday) return null;
  const minute = minutesOfDay(now);
  if (clockIn && !record?.clockInAt && !sent.has('in')) {
    const from = hours.workStart + delay;
    if (minute >= from && minute < from + REMINDER_WINDOW_MINUTES) return 'in';
  }
  if (clockOut && record?.clockInAt && !record.clockOutAt && !sent.has('out') && record.workDate === today) {
    const from = hours.workEnd + CLOCK_OUT_REMINDER_AFTER;
    if (minute >= from && minute < from + REMINDER_WINDOW_MINUTES) return 'out';
  }
  return null;
}

/** 출근 형태 — 'office' | 'field'(외근 — 장소를 적어야) | 'remote'(재택). */
export const CLOCK_IN_MODES = Object.freeze(['office', 'field', 'remote']);
export const CLOCK_IN_MODE_LABEL = Object.freeze({ office: '사무실', field: '외근', remote: '재택' });

/** 출근 입력 `{ mode?, note? }` → `{ mode, note }` | `{ error }`. */
export function parseClockIn(body) {
  const mode = body?.mode ?? 'office';
  if (!CLOCK_IN_MODES.includes(mode)) return { error: '출근 형태를 확인하세요.' };
  const note = typeof body?.note === 'string' ? body.note.trim().slice(0, 200) || null : null;
  if (mode === 'field' && !note) return { error: '외근 장소(어디서 일하는지)를 적으세요.' };
  return { mode, note };
}

/** 한 달(또는 아무 기간) 기록의 합 — `{ netMinutes, actualOvertimeMinutes, nightMinutes, holidayWorkMinutes }`. */
export function monthBreakdown(records, { holidays = new Set() } = {}) {
  const sum = { netMinutes: 0, actualOvertimeMinutes: 0, nightMinutes: 0, holidayWorkMinutes: 0 };
  for (const r of records) {
    const b = workBreakdown(r, { holidays });
    sum.netMinutes += b.netMinutes;
    sum.actualOvertimeMinutes += b.overtimeMinutes;
    sum.nightMinutes += b.nightMinutes;
    sum.holidayWorkMinutes += b.holidayMinutes;
  }
  return sum;
}
