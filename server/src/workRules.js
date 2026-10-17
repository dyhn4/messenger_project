import { addDaysKey, isWorkday, weekdayOf } from './annualLeave.js';
import { localDateKey, minutesOfDay, parseHm, recordFlags } from './attendanceRules.js';

/**
 * 근로시간 규칙 — 하루 기록을 휴게·연장·야간·휴일 근무로 나누기, 주 52시간(주 40시간 + 연장 12시간 — 근로기준법 제50·53조), 유연근무
 * (사람마다의 근무 형태로 지각·조퇴 따지기), 출근·퇴근 알림을 보낼지. DB 없이 시험할 수 있게 계산만 모았다(groupwareWork.js·groupware.js가
 * 쓴다, test/groupwareWork.test.js). 시각은 서버 PC 기준(attendanceRules.js와 같다).
 *
 * 하루 나누기(실제 출퇴근 기록 기준 — 결재로 받은 연장근무 신청과는 따로 본다):
 *  - 휴게: 일한 시간이 8시간 30분 이상이면 1시간, 4시간 30분 이상이면 30분을 뺀다(제54조 — 4시간마다 30분, 8시간이면 1시간).
 *  - 연장: 근무일에 휴게를 뺀 시간 중 8시간을 넘는 부분.
 *  - 휴일: 주말·공휴일에 일한 시간(휴게를 뺀 것) 전부.
 *  - 야간: 22:00~06:00에 걸친 시간(휴게를 따로 빼지 않는다 — 언제 쉬었는지 기록이 없다).
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

/**
 * 기록 하나 → `{ workedMinutes, breakMinutes, netMinutes, overtimeMinutes, holidayMinutes, nightMinutes }`(퇴근을 안 눌렀으면 모두 0).
 * [holidays]는 공휴일 모음.
 */
export function workBreakdown(record, { holidays = new Set() } = {}) {
  const zero = { workedMinutes: 0, breakMinutes: 0, netMinutes: 0, overtimeMinutes: 0, holidayMinutes: 0, nightMinutes: 0 };
  if (!record?.clockInAt || !record?.clockOutAt) return zero;
  const inAt = new Date(record.clockInAt);
  const outAt = new Date(record.clockOutAt);
  if (!(outAt > inAt)) return zero;
  const worked = Math.round((outAt - inAt) / 60000);
  const brk = breakMinutesFor(worked);
  const net = Math.max(0, worked - brk);
  const workday = isWorkday(record.workDate, holidays);
  return {
    workedMinutes: worked,
    breakMinutes: brk,
    netMinutes: net,
    overtimeMinutes: workday ? Math.max(0, net - DAILY_LIMIT_MINUTES) : 0,
    holidayMinutes: workday ? 0 : net,
    nightMinutes: nightMinutesBetween(inAt, outAt),
  };
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
  const none = { startMinutes: null, endMinutes: null, coreStartMinutes: null, coreEndMinutes: null };
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
export function scheduledFlags(record, hours, { halfType = null, fullLeave = false } = {}) {
  const flags = recordFlags(record, { workStart: hours.workStart, workEnd: hours.workEnd, halfType, fullLeave });
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
