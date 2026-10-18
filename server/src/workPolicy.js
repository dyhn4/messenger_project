import { addDaysKey, addMonthsKey, isDateKey } from './annualLeave.js';
import { WEEKLY_BASE_MINUTES, WEEKLY_LIMIT_MINUTES, WEEKLY_WARN_MINUTES, weekStartOf, workBreakdown } from './workRules.js';

/**
 * 근로시간 정책(순수 규칙) — 주 52시간을 넘기 전에 막거나 결재를 받게 하기, 탄력적 근로시간제(2주·3개월 단위 평균 — 근로기준법 제51조)와
 * 선택적 근로시간제의 정산 기간(제52조), 가산 수당(제56조 — 연장·야간·휴일). DB는 groupware.js·groupwareWork.js. `node --test`로 시험한다
 * (test/workFollowup.test.js).
 */

// ── 주 52시간 지키기 ──

/**
 * 범위의 주 52시간 지키기 방식 — 'warn'(알리기만 — 예전), 'approval'(48시간을 넘긴 주에는 그날 승인된 연장·휴일근무 결재가 있어야 출근을
 * 누를 수 있고, 52시간을 넘기게 되는 연장근무 신청은 받지 않음), 'block'(52시간을 채운 주에는 출근을 누를 수 없고, 넘기게 되는 연장근무
 * 신청도 받지 않음).
 */
export const OVERTIME_GUARDS = Object.freeze(['warn', 'approval', 'block']);
export const OVERTIME_GUARD_LABEL = Object.freeze({ warn: '알리기만', approval: '결재를 받게', block: '막기' });

/**
 * 탄력적 근로시간제·선택근무의 주당 상한(연장 포함). 탄력 2주는 한 주 48시간 + 연장 12시간, 3개월은 52시간 + 12시간. 선택근무는 주 상한이
 * 없다(정산 기간 평균으로 본다 — null).
 */
export const PERIOD_WEEKLY_MAX = Object.freeze({ flex2w: 60 * 60, flex3m: 64 * 60, select: null });

/** 이 사람의 한 주 상한(분 — 없으면 null). 근무 형태가 없거나 기간이 없으면 주 52시간. */
export const weeklyLimitFor = (schedule) =>
  schedule?.periodType ? (PERIOD_WEEKLY_MAX[schedule.periodType] ?? null) : WEEKLY_LIMIT_MINUTES;

/** 상한 몇 분 전부터 "결재를 받게"가 출근을 막는지 — 주 52시간이면 48시간에서(4시간 전). */
const WARN_GAP = WEEKLY_LIMIT_MINUTES - WEEKLY_WARN_MINUTES;

/**
 * 출근을 누를 때 — 이번 주 지금까지 일한 시간([weekNetMinutes], 휴게 뺀 실근로)과 이 사람의 주 상한([limitMinutes] — null이면 보지 않음)으로.
 * 'block'·'approval'은 상한에 이른 주에 막고, 'approval'은 상한 4시간 전부터 그날 승인된 연장·휴일근무 결재([hasApprovedOvertime])가
 * 없으면 막는다. 막으면 `{ error }`, 아니면 null.
 */
export function clockInGuard({ guard = 'warn', weekNetMinutes, limitMinutes, hasApprovedOvertime = false }) {
  if (guard === 'warn' || limitMinutes == null) return null;
  const hours = Math.round(limitMinutes / 60);
  if (weekNetMinutes >= limitMinutes) {
    return { error: `이번 주 근로시간이 ${hours}시간에 이르러 더 일할 수 없습니다. 관리자에게 문의하세요.` };
  }
  if (guard === 'approval' && weekNetMinutes >= limitMinutes - WARN_GAP && !hasApprovedOvertime) {
    return {
      error: `이번 주 근로시간이 ${Math.round((limitMinutes - WARN_GAP) / 60)}시간을 넘었습니다. 오늘 일하려면 연장근무(또는 휴일근무) 결재를 먼저 받으세요.`,
    };
  }
  return null;
}

/**
 * 연장근무 신청을 받을지 — [workDate]의 주에 대해 `max(40시간, 지금까지 일한 시간) + 앞으로 할 연장근무(승인·결재 중 — 오늘 이후)
 * + 이 신청`이 주 상한을 넘으면 'approval'·'block'은 막는다. 지난 날(이미 일한 날)의 신청은 막지 않는다(기록이 이미 시간에 들어 있다).
 * `{ error, projectedMinutes }` | `{ projectedMinutes }`.
 */
export function overtimeRequestGuard({ guard = 'warn', workDate, today, weekNetMinutes, futureCommittedMinutes = 0, requestMinutes, limitMinutes }) {
  const projectedMinutes = Math.max(WEEKLY_BASE_MINUTES, weekNetMinutes) + futureCommittedMinutes + requestMinutes;
  if (guard === 'warn' || limitMinutes == null || workDate < today) return { projectedMinutes };
  if (projectedMinutes > limitMinutes) {
    const h = (m) => Math.round((m / 60) * 10) / 10;
    return {
      projectedMinutes,
      error: `이 연장근무를 더하면 그 주 근로시간이 약 ${h(projectedMinutes)}시간으로 ${h(limitMinutes)}시간을 넘습니다. 날을 나누거나 관리자와 상의하세요.`,
    };
  }
  return { projectedMinutes };
}

// ── 탄력적 근로시간제·선택근무 정산 기간 ──

const daysBetween = (a, b) => Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86_400_000);

/**
 * [dateKey]가 든 이 사람의 기간 — `{ type, start, end(다음 기간 시작 — 그날은 안 듦), days, standardMinutes(주 40시간 × 주 수),
 * overtimeCapMinutes(연장 한도 — 주 12시간 × 주 수), weeklyMaxMinutes }`. 기간은 [schedule.periodStart]부터 탄력 2주는 14일, 탄력 3개월은
 * 3개월, 선택근무는 [periodMonths]개월씩 이어진다(그 전 날짜는 거꾸로). 기간이 없으면 null.
 */
export function workPeriodOf(schedule, dateKey) {
  const type = schedule?.periodType;
  const anchor = schedule?.periodStart;
  if (!type || !isDateKey(anchor) || !isDateKey(dateKey)) return null;
  let start;
  let end;
  if (type === 'flex2w') {
    const idx = Math.floor(daysBetween(anchor, dateKey) / 14);
    start = addDaysKey(anchor, idx * 14);
    end = addDaysKey(start, 14);
  } else {
    const step = type === 'flex3m' ? 3 : (schedule.periodMonths ?? 1);
    let k = 0;
    // 앞뒤로 걸어 [dateKey]가 든 칸을 찾는다(기간 시작 기준 — 몇 년이면 수십 번).
    while (addMonthsKey(anchor, k * step) > dateKey) k -= 1;
    while (addMonthsKey(anchor, (k + 1) * step) <= dateKey) k += 1;
    start = addMonthsKey(anchor, k * step);
    end = addMonthsKey(anchor, (k + 1) * step);
  }
  const days = daysBetween(start, end);
  return {
    type,
    start,
    end,
    days,
    standardMinutes: Math.round((WEEKLY_BASE_MINUTES * days) / 7),
    overtimeCapMinutes: Math.round((12 * 60 * days) / 7),
    weeklyMaxMinutes: PERIOD_WEEKLY_MAX[type] ?? null,
  };
}

/**
 * 기간 한 칸의 근로시간 — [records]는 그 기간 기록(밖의 것은 거름). `{ ...period, netMinutes, overtimeMinutes(기준 시간을 넘은 것),
 * weeks: [{ weekStart, netMinutes, over }], status }`. status는 'over'(연장 한도를 넘었거나 주 상한을 넘은 주가 있음) | 'warn'(연장이 한도의
 * 80% 이상) | 'ok'. 주는 월요일 시작이고 기간 밖의 날은 세지 않는다.
 */
export function periodSummary(records, period, { holidays = new Set() } = {}) {
  let net = 0;
  const weeks = new Map();
  for (const r of records) {
    if (!r?.workDate || r.workDate < period.start || r.workDate >= period.end) continue;
    const b = workBreakdown(r, { holidays });
    net += b.netMinutes;
    const w = weekStartOf(r.workDate);
    weeks.set(w, (weeks.get(w) ?? 0) + b.netMinutes);
  }
  const weekRows = [...weeks.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([weekStart, netMinutes]) => ({ weekStart, netMinutes, over: period.weeklyMaxMinutes != null && netMinutes > period.weeklyMaxMinutes }));
  const overtime = Math.max(0, net - period.standardMinutes);
  const status =
    overtime > period.overtimeCapMinutes || weekRows.some((w) => w.over) ? 'over' : overtime >= period.overtimeCapMinutes * 0.8 ? 'warn' : 'ok';
  return { ...period, netMinutes: net, overtimeMinutes: overtime, weeks: weekRows, status };
}

/** [from]~[to](둘 다 포함)과 겹치는 기간들(그 사람의 기간 — 앞에서부터). */
export function periodsOverlapping(schedule, from, to) {
  const out = [];
  let p = workPeriodOf(schedule, from);
  while (p && p.start <= to) {
    out.push(p);
    p = workPeriodOf(schedule, p.end);
  }
  return out;
}

// ── 가산 수당 ──

/**
 * 가산율(%) — 연장 50, 야간 50(가산분만), 휴일 8시간까지 50, 8시간 넘는 부분 100(근로기준법 제56조). [smallBusiness](상시 5명 미만)이면
 * 가산하지 않는다(제11조 — 일한 시간의 통상임금만).
 */
export const LEGAL_PAY_RATES = Object.freeze({ overtime: 50, night: 50, holiday: 50, holidayOver: 100 });
export const DEFAULT_PAY_RATES = Object.freeze({ ...LEGAL_PAY_RATES, smallBusiness: false });
export const PAY_RATE_MAX = 300;
export const HOURLY_WAGE_MAX = 1_000_000;

/** 저장해 둔 가산율(없으면 법정). */
export const payRatesOf = (stored) => ({ ...DEFAULT_PAY_RATES, ...(stored && typeof stored === 'object' ? stored : {}) });

/**
 * 가산율 입력 `{ overtime?, night?, holiday?, holidayOver?, smallBusiness? }` → `{ rates }` | `{ error }`. 5명 이상 사업장이면 법정보다 낮게
 * 정할 수 없다(회사가 더 주는 것은 된다).
 */
export function parsePayRates(input, previous = null) {
  const rates = payRatesOf(previous);
  for (const key of ['overtime', 'night', 'holiday', 'holidayOver']) {
    if (input?.[key] === undefined) continue;
    const n = Number(input[key]);
    if (!Number.isInteger(n) || n < 0 || n > PAY_RATE_MAX) return { error: `가산율은 0~${PAY_RATE_MAX}% 사이 정수로 넣으세요.` };
    rates[key] = n;
  }
  if (input?.smallBusiness !== undefined) {
    if (typeof input.smallBusiness !== 'boolean') return { error: '5명 미만 사업장인지를 참/거짓으로 보내세요.' };
    rates.smallBusiness = input.smallBusiness;
  }
  if (!rates.smallBusiness) {
    for (const [key, min] of Object.entries(LEGAL_PAY_RATES)) {
      if (rates[key] < min) return { error: `상시 5명 이상 사업장은 법정 가산율(${min}%)보다 낮게 정할 수 없습니다.` };
    }
  }
  return { rates };
}

/** 통상시급 입력 → `{ wage }`(null이면 지움) | `{ error }`. */
export function parseHourlyWage(input) {
  if (input === null || input === '' || input === undefined) return { wage: null };
  const n = Number(typeof input === 'string' ? input.replace(/,/g, '') : input);
  if (!Number.isInteger(n) || n <= 0 || n > HOURLY_WAGE_MAX) return { error: '통상시급을 원 단위 숫자로 넣으세요.' };
  return { wage: n };
}

/**
 * 한 달(또는 아무 기간) 가산 수당(참고용) — [records]의 날마다 근로시간 나누기(workRules.js workBreakdown)와 통상시급 [wage]·가산율
 * [rates]로. 연장은 (1 + 연장 가산율), 휴일은 하루 8시간까지 (1 + 휴일 가산율)·넘는 부분 (1 + 휴일 8시간 초과 가산율), 야간은 가산율만
 * (일한 시간의 통상임금은 다른 칸에 이미 든다). [overtimeMinutes]를 주면(탄력·선택근무 — 정산 기간이 끝난 달에 기간의 연장) 날마다의 연장
 * 대신 쓴다. 원 단위 반올림. `{ wage, overtimeMinutes, nightMinutes, holidayMinutes, holidayOverMinutes, overtimePay, nightPay, holidayPay, totalPay }`.
 */
export function allowanceOf({ records, wage, rates = DEFAULT_PAY_RATES, holidays = new Set(), overtimeMinutes = null }) {
  const r = payRatesOf(rates);
  const premium = (key) => (r.smallBusiness ? 0 : r[key]);
  let overtime = 0;
  let night = 0;
  let holiday = 0;
  let holidayOver = 0;
  for (const rec of records) {
    const b = workBreakdown(rec, { holidays });
    overtime += b.overtimeMinutes;
    night += b.nightMinutes;
    holiday += Math.min(8 * 60, b.holidayMinutes);
    holidayOver += Math.max(0, b.holidayMinutes - 8 * 60);
  }
  if (overtimeMinutes !== null) overtime = overtimeMinutes;
  const pay = (minutes, percent) => Math.round(((wage * minutes) / 60) * (percent / 100));
  const overtimePay = pay(overtime, 100 + premium('overtime'));
  const nightPay = pay(night, premium('night'));
  const holidayPay = pay(holiday, 100 + premium('holiday')) + pay(holidayOver, 100 + premium('holidayOver'));
  return {
    wage,
    overtimeMinutes: overtime,
    nightMinutes: night,
    holidayMinutes: holiday,
    holidayOverMinutes: holidayOver,
    overtimePay,
    nightPay,
    holidayPay,
    totalPay: overtimePay + nightPay + holidayPay,
  };
}
