/**
 * 휴가 일수와 법정 연차 — DB 없이 시험할 수 있게 계산만 모았다(groupware.js가 쓴다). 날짜는 늘 'YYYY-MM-DD' 글자로 다룬다(시간대가
 * 끼어들 자리가 없게 — 휴가·입사일은 "그 날짜"다). 휴가 양은 반일 단위 정수(halfDays — 하루 = 2, 반차 = 1)로 센다.
 *
 * 법정 연차(근로기준법 제60조, 입사일 기준):
 *  - 입사 1년 미만: 1개월 개근할 때마다 1일, 최대 11일(그 1년 안에 쓴다 — 1년이 되면 새 연차 기간이 시작된다).
 *  - 1년 이상: 15일. 3년 이상은 최초 1년을 넘는 근속 2년마다 1일씩 더해 최대 25일 — 15 + ⌊(근속연수 - 1) / 2⌋.
 *  - 출근율 80% 미만인 해의 감액, 이월, 회사가 더 주는 휴가는 계산하지 않는다 — 관리자가 연차 조정(leave_adjustments)으로 맞춘다.
 *  - 연차 기간은 입사일 기념일마다 바뀐다(회계연도 기준 방식은 쓰지 않는다).
 */

const DATE_KEY = /^(\d{4})-(\d{2})-(\d{2})$/;

/** 'YYYY-MM-DD'가 실제로 있는 날짜면 { y, m, d }, 아니면 null. */
export function parseDateKey(value) {
  if (typeof value !== 'string') return null;
  const match = DATE_KEY.exec(value);
  if (!match) return null;
  const [y, m, d] = [Number(match[1]), Number(match[2]), Number(match[3])];
  const probe = new Date(Date.UTC(y, m - 1, d));
  if (probe.getUTCFullYear() !== y || probe.getUTCMonth() !== m - 1 || probe.getUTCDate() !== d) return null;
  if (y < 1900 || y > 2200) return null;
  return { y, m, d };
}

export const isDateKey = (value) => parseDateKey(value) !== null;

const pad = (n) => String(n).padStart(2, '0');

/** { y, m, d } → 'YYYY-MM-DD'. */
export function dateKeyOf(y, m, d) {
  return `${y}-${pad(m)}-${pad(d)}`;
}

/** [key]에서 [days]일 뒤(음수면 앞). */
export function addDaysKey(key, days) {
  const { y, m, d } = parseDateKey(key);
  const date = new Date(Date.UTC(y, m - 1, d + days));
  return dateKeyOf(date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate());
}

/** [key]에서 [months]개월 뒤 — 그 달에 같은 날이 없으면 그 달 마지막 날(1월 31일 + 1개월 = 2월 28·29일). */
export function addMonthsKey(key, months) {
  const { y, m, d } = parseDateKey(key);
  const total = y * 12 + (m - 1) + months;
  const ny = Math.floor(total / 12);
  const nm = (total % 12) + 1;
  const last = new Date(Date.UTC(ny, nm, 0)).getUTCDate();
  return dateKeyOf(ny, nm, Math.min(d, last));
}

/** 요일(0 = 일 … 6 = 토). */
export function weekdayOf(key) {
  const { y, m, d } = parseDateKey(key);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}

/** 근무일인지 — 토·일요일과 [holidays](공휴일 'YYYY-MM-DD' 모음 — holidays.js)가 아닌 날. */
export function isWorkday(key, holidays = new Set()) {
  const wd = weekdayOf(key);
  return wd !== 0 && wd !== 6 && !holidays.has(key);
}

/** [start]~[end](둘 다 포함) 사이 근무일 수. */
export function workdaysBetween(start, end, holidays = new Set()) {
  let count = 0;
  for (let key = start; key <= end; key = addDaysKey(key, 1)) {
    if (isWorkday(key, holidays)) count += 1;
  }
  return count;
}

/**
 * 휴가 종류. deducts는 연차에서 빼는지, half는 반차(하루 중 반 — 시작일과 끝일이 같아야 한다). 병가·경조사·공가·기타는 연차에서
 * 빼지 않는다(회사 규정에 따라 유급·무급은 다르지만 기록과 결재만 남긴다).
 */
export const LEAVE_TYPES = Object.freeze([
  { key: 'annual', label: '연차', deducts: true, half: false },
  { key: 'half_am', label: '오전 반차', deducts: true, half: true },
  { key: 'half_pm', label: '오후 반차', deducts: true, half: true },
  { key: 'sick', label: '병가', deducts: false, half: false },
  { key: 'family', label: '경조사', deducts: false, half: false },
  { key: 'official', label: '공가', deducts: false, half: false },
  { key: 'other', label: '기타 휴가', deducts: false, half: false },
]);

export const leaveTypeOf = (key) => LEAVE_TYPES.find((t) => t.key === key) ?? null;

/** 한 번에 신청할 수 있는 가장 긴 기간(달력 날짜 수). */
export const LEAVE_MAX_SPAN_DAYS = 60;

/**
 * 휴가 신청 { leaveType, startDate, endDate }의 양 — 통과하면 `{ halfDays, workdays }`, 아니면 `{ error }`. 근무일만 센다(주말·공휴일은
 * 빼고). 반차는 근무일 하루의 반.
 */
export function leaveRequestAmount({ leaveType, startDate, endDate }, holidays = new Set()) {
  const type = leaveTypeOf(leaveType);
  if (!type) return { error: '휴가 종류를 고르세요.' };
  if (!isDateKey(startDate) || !isDateKey(endDate)) return { error: '휴가 날짜를 확인하세요.' };
  if (endDate < startDate) return { error: '끝나는 날이 시작하는 날보다 앞입니다.' };
  if (type.half) {
    if (startDate !== endDate) return { error: '반차는 하루만 고를 수 있습니다.' };
    if (!isWorkday(startDate, holidays)) return { error: '반차는 근무일에만 쓸 수 있습니다.' };
    return { halfDays: 1, workdays: 1 };
  }
  if (addDaysKey(startDate, LEAVE_MAX_SPAN_DAYS - 1) < endDate) {
    return { error: `휴가는 한 번에 ${LEAVE_MAX_SPAN_DAYS}일까지 신청할 수 있습니다. 나눠서 신청하세요.` };
  }
  const workdays = workdaysBetween(startDate, endDate, holidays);
  if (workdays === 0) return { error: '고른 기간에 근무일이 없습니다(주말·공휴일만 있음).' };
  return { halfDays: workdays * 2, workdays };
}

/** [from]부터 [to]까지 다 채운 개월 수(1월 15일 → 2월 15일이 1개월). */
export function completedMonths(from, to) {
  if (to < from) return 0;
  let months = 0;
  while (addMonthsKey(from, months + 1) <= to) months += 1;
  return months;
}

/**
 * 오늘이 속한 연차 기간 — 입사일 기념일마다 바뀐다. `{ year, start, end }`(year는 근속 연수 — 0이면 입사 첫해, end는 다음 기간의
 * 시작일이라 그날은 들지 않는다). 입사일이 없거나 오늘보다 뒤면 null.
 */
export function leavePeriod(hireDate, today) {
  if (!isDateKey(hireDate) || !isDateKey(today) || hireDate > today) return null;
  const years = Math.floor(completedMonths(hireDate, today) / 12);
  return { year: years, start: addMonthsKey(hireDate, years * 12), end: addMonthsKey(hireDate, (years + 1) * 12) };
}

/** 법정 연차 최대(일). */
export const ANNUAL_LEAVE_CAP_DAYS = 25;
/** 입사 첫해 월차 최대(일). */
export const FIRST_YEAR_CAP_DAYS = 11;

/** 근속 [years]년(1 이상)인 해의 법정 연차 일수 — 15 + ⌊(근속연수 - 1) / 2⌋, 최대 25. */
export function annualLeaveDays(years) {
  if (years < 1) return 0;
  return Math.min(ANNUAL_LEAVE_CAP_DAYS, 15 + Math.floor((years - 1) / 2));
}

/**
 * 오늘 기준으로 이번 연차 기간에 생긴 법정 연차(반일 단위). 입사 첫해는 지금까지 채운 개월 수(최대 11일), 그 뒤는 근속 연수에 따른
 * 일수. 입사일이 없으면 null(계산할 수 없음).
 */
export function statutoryHalfDays(hireDate, today) {
  const period = leavePeriod(hireDate, today);
  if (!period) return null;
  if (period.year === 0) return Math.min(FIRST_YEAR_CAP_DAYS, completedMonths(hireDate, today)) * 2;
  return annualLeaveDays(period.year) * 2;
}

/**
 * 연차 현황 — [usedHalfDays]는 이 기간에 승인된 연차, [pendingHalfDays]는 결재 중인 연차, [adjustmentHalfDays]는 관리자 조정 합.
 * 입사일이 없으면 granted·remaining이 null(얼마나 남았는지 모른다 — 신청은 막지 않는다).
 */
export function leaveBalance({ hireDate, today, usedHalfDays = 0, pendingHalfDays = 0, adjustmentHalfDays = 0 }) {
  const period = leavePeriod(hireDate, today);
  const statutory = statutoryHalfDays(hireDate, today);
  const granted = statutory === null ? null : statutory + adjustmentHalfDays;
  return {
    period,
    statutoryHalfDays: statutory,
    adjustmentHalfDays,
    grantedHalfDays: granted,
    usedHalfDays,
    pendingHalfDays,
    remainingHalfDays: granted === null ? null : granted - usedHalfDays,
  };
}

/**
 * 연차에서 빼는 휴가를 새로 신청할 수 있는지 — 남은 연차(결재 중인 것까지 뺀)가 신청한 양보다 적으면 문구. 입사일이 없어 모르면 null
 * (막지 않는다).
 */
export function leaveShortage(balance, requestedHalfDays) {
  if (balance.remainingHalfDays === null) return null;
  const available = balance.remainingHalfDays - balance.pendingHalfDays;
  if (requestedHalfDays <= available) return null;
  return `남은 연차(${halfDaysText(Math.max(0, available))})보다 많이 신청했습니다. 관리자에게 연차 조정을 요청하거나 다른 휴가 종류를 고르세요.`;
}

/** 반일 단위 → "3일" / "2.5일". */
export function halfDaysText(halfDays) {
  return `${halfDays % 2 === 0 ? halfDays / 2 : (halfDays / 2).toFixed(1)}일`;
}
