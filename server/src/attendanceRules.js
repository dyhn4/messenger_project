import { addDaysKey, dateKeyOf, isDateKey, isWorkday, parseDateKey } from './annualLeave.js';

/**
 * 출퇴근 기록의 규칙 — DB 없이 시험할 수 있게 계산만 모았다(groupware.js가 쓴다). 날짜·시각은 서버 PC의 시각으로 본다(사무실과
 * 같은 시간대에 둔 서버라는 전제 — 멘션 요약 메일의 9시와 같다).
 */

/** 기본 근무 시간(하루 중 분). */
export const DEFAULT_WORK_START = 9 * 60;
export const DEFAULT_WORK_END = 18 * 60;

/** 전날 출근한 기록을 다음 날 퇴근으로 닫아 줄 수 있는 시간 — 야간 근무. 그보다 오래 열려 있으면 근태 수정으로 고친다. */
export const OVERNIGHT_CLOSE_MS = 20 * 60 * 60 * 1000;

/** [date]의 서버 PC 기준 날짜 'YYYY-MM-DD'. */
export function localDateKey(date) {
  const d = new Date(date);
  return dateKeyOf(d.getFullYear(), d.getMonth() + 1, d.getDate());
}

/** [date]의 하루 중 분(서버 PC 기준). */
export function minutesOfDay(date) {
  const d = new Date(date);
  return d.getHours() * 60 + d.getMinutes();
}

/** 'HH:MM'(00:00~23:59) → 하루 중 분, 아니면 null. */
export function parseHm(value) {
  if (typeof value !== 'string') return null;
  const match = /^(\d{2}):(\d{2})$/.exec(value);
  if (!match) return null;
  const [h, m] = [Number(match[1]), Number(match[2])];
  return h < 24 && m < 60 ? h * 60 + m : null;
}

/** 하루 중 분 → 'HH:MM'. */
export function hmText(minutes) {
  return `${String(Math.floor(minutes / 60)).padStart(2, '0')}:${String(minutes % 60).padStart(2, '0')}`;
}

/** [dateKey]의 [minutes]분(서버 PC 기준 시각). */
export function dateAtMinutes(dateKey, minutes) {
  const { y, m, d } = parseDateKey(dateKey);
  return new Date(y, m - 1, d, Math.floor(minutes / 60), minutes % 60);
}

/** 근무 시간 { start, end }가 쓸 만한지(시작 < 끝). */
export function validWorkHours(start, end) {
  return Number.isInteger(start) && Number.isInteger(end) && start >= 0 && end <= 24 * 60 && start < end;
}

/**
 * 퇴근을 누를 기록 — 오늘 기록, 없으면 전날 출근하고 아직 안 닫힌 기록(출근한 지 [OVERNIGHT_CLOSE_MS] 안). [records]는 이 사람의 최근
 * 기록들. 없으면 null.
 */
export function clockOutTarget(records, now = new Date()) {
  const today = localDateKey(now);
  const todayRecord = records.find((r) => r.workDate === today);
  if (todayRecord) return todayRecord;
  const yesterday = addDaysKey(today, -1);
  const open = records.find((r) => r.workDate === yesterday && r.clockInAt && !r.clockOutAt);
  if (open && new Date(now).getTime() - new Date(open.clockInAt).getTime() <= OVERNIGHT_CLOSE_MS) return open;
  return null;
}

/**
 * 한 기록의 표시 — 지각(근무 시작 뒤 출근), 조퇴(근무 끝 전 퇴근), 일한 분(퇴근을 안 눌렀으면 null). 휴가로 쉬는 날([leaveHalfDays]가
 * 2)은 지각·조퇴를 따지지 않고, 반차(1)면 오전 반차는 지각을, 오후 반차는 조퇴를 따지지 않는다([halfType]).
 */
export function recordFlags(record, { workStart = DEFAULT_WORK_START, workEnd = DEFAULT_WORK_END, halfType = null, fullLeave = false } = {}) {
  const inAt = record?.clockInAt ? new Date(record.clockInAt) : null;
  const outAt = record?.clockOutAt ? new Date(record.clockOutAt) : null;
  const sameDay = (at) => at && localDateKey(at) === record.workDate;
  const late = !fullLeave && halfType !== 'half_am' && !!inAt && sameDay(inAt) && minutesOfDay(inAt) > workStart;
  // 다음 날 새벽에 퇴근했으면(야간) 조퇴가 아니다.
  const earlyLeave = !fullLeave && halfType !== 'half_pm' && !!outAt && sameDay(outAt) && minutesOfDay(outAt) < workEnd;
  const workedMinutes = inAt && outAt && outAt > inAt ? Math.round((outAt - inAt) / 60000) : null;
  return { late, earlyLeave, workedMinutes, missingClockOut: !!inAt && !outAt };
}

/** 'YYYY-MM' → 그 달의 날짜들, 아니면 null. */
export function monthDays(monthKey) {
  if (typeof monthKey !== 'string' || !/^\d{4}-\d{2}$/.test(monthKey)) return null;
  const first = `${monthKey}-01`;
  if (!isDateKey(first)) return null;
  const days = [];
  for (let key = first; key.startsWith(monthKey); key = addDaysKey(key, 1)) days.push(key);
  return days;
}

/**
 * 한 사람의 한 달 근태 요약. [records]는 그 달 기록, [leaveByDate]는 날짜 → { halfDays, halfType }(승인된 휴가), [today]보다 뒤의 날은
 * 결근으로 세지 않는다. `{ daysWorked, workedMinutes, late, earlyLeave, missingClockOut, absent, leaveHalfDays }`.
 */
export function summarizeMonth({ monthKey, records, leaveByDate = new Map(), holidays = new Set(), workStart, workEnd, today }) {
  const days = monthDays(monthKey) ?? [];
  const byDate = new Map(records.map((r) => [r.workDate, r]));
  const summary = { daysWorked: 0, workedMinutes: 0, late: 0, earlyLeave: 0, missingClockOut: 0, absent: 0, leaveHalfDays: 0 };
  for (const day of days) {
    const leave = leaveByDate.get(day);
    if (leave) summary.leaveHalfDays += leave.halfDays;
    const record = byDate.get(day);
    if (record?.clockInAt) {
      summary.daysWorked += 1;
      const flags = recordFlags(record, { workStart, workEnd, halfType: leave?.halfType ?? null, fullLeave: leave?.halfDays === 2 });
      if (flags.late) summary.late += 1;
      if (flags.earlyLeave) summary.earlyLeave += 1;
      if (flags.missingClockOut && day < today) summary.missingClockOut += 1;
      if (flags.workedMinutes) summary.workedMinutes += flags.workedMinutes;
    } else if (day < today && isWorkday(day, holidays) && !leave) {
      summary.absent += 1;
    }
  }
  return summary;
}
