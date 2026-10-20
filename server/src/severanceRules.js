/**
 * 퇴직금·퇴직소득세(payrollReports.js)의 순수 규칙 — DB 없이 `node --test`로 시험한다(test/payrollReports.test.js).
 *
 * 퇴직금(근로자퇴직급여 보장법 제8조) = 1일 평균임금 × 30일 × (재직일수 ÷ 365). 계속근로기간 1년 이상(4주 평균 주 15시간 이상)이어야 받는다.
 * 평균임금(근로기준법 제2조 제1항 제6호) = 산정 사유가 생긴 날(퇴직일 — 마지막 근무일 다음 날) 이전 3개월 동안 받은 임금 총액 ÷ 그 기간의 총일수.
 * 3개월 밖에 받은 상여금은 연간 상여금 × 3/12, 연차수당은 퇴직 전전년도 발생·전년도 미사용분 × 3/12을 더하는 것이 관행이다(행정해석).
 * 평균임금이 통상임금보다 적으면 통상임금을 평균임금으로 한다(같은 조 제2항) — 1일 통상임금 = 통상시급 × 8시간.
 * 기간 안의 급여는 보낸 명세서의 지급 총액을 귀속 월의 날짜로 나눠(그 달 중 기간에 든 날만큼) 더한다 — 담당자가 고쳐 넣을 수 있다.
 *
 * 퇴직소득세(소득세법 제48조·제55조 — 2023년 이후 퇴직):
 *  근속연수(1년 미만은 1년) → 근속연수공제(5년 이하 100만 원 × 연수, 10년 이하 500만 + 200만 × (연수 − 5), 20년 이하 1,500만 + 250만 × (연수 − 10),
 *  그 넘게 4,000만 + 300만 × (연수 − 20)) → 환산급여 = (퇴직소득 − 근속연수공제) × 12 ÷ 근속연수 → 환산급여공제(800만 원 이하 전액,
 *  7,000만 이하 800만 + 초과 60%, 1억 이하 4,520만 + 55%, 3억 이하 6,170만 + 45%, 그 넘게 1억 5,170만 + 35%) → 과세표준 × 기본세율 =
 *  환산산출세액 → × 근속연수 ÷ 12 = 산출세액(10원 미만 버림). 지방소득세는 그 10%. 퇴직연금(IRP) 이전·과세이연·임원 한도는 다루지 않는다.
 */
import { basicTax, floor10 } from './incomeTaxRules.js';

const isDateKey = (v) => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) && !Number.isNaN(Date.parse(`${v}T00:00:00Z`));
const dayMs = 86_400_000;
const dayNo = (key) => Math.round(Date.parse(`${key}T00:00:00Z`) / dayMs);
const keyOf = (n) => new Date(n * dayMs).toISOString().slice(0, 10);
export const addDays = (key, n) => keyOf(dayNo(key) + n);

/** 'YYYY-MM-DD' + [months]개월(달 끝을 넘으면 그 달 끝). */
export function addMonths(key, months) {
  const [y, m, d] = key.split('-').map(Number);
  const total = y * 12 + (m - 1) + months;
  const ny = Math.floor(total / 12);
  const nm = (total % 12) + 1;
  const last = new Date(Date.UTC(ny, nm, 0)).getUTCDate();
  return `${ny}-${String(nm).padStart(2, '0')}-${String(Math.min(d, last)).padStart(2, '0')}`;
}

/** 재직일수 — 입사일부터 마지막 근무일까지(둘 다 넣어). */
export const serviceDays = (hireDate, lastDay) => dayNo(lastDay) - dayNo(hireDate) + 1;

/** 퇴직소득세의 근속연수 — 입사일부터 퇴직일(마지막 근무일 다음 날) 전까지의 해, 1년 미만 끝은 1년. 최소 1. */
export function serviceYears(hireDate, lastDay) {
  const end = addDays(lastDay, 1);
  let years = 0;
  while (addMonths(hireDate, (years + 1) * 12) <= end) years += 1;
  return Math.max(1, addMonths(hireDate, years * 12) < end ? years + 1 : years);
}

/** 평균임금 산정 기간 — 퇴직일(마지막 근무일 다음 날) 전 3개월 `{ from, to(마지막 근무일), days }`. */
export function averageWagePeriod(lastDay) {
  const end = addDays(lastDay, 1);
  const from = addMonths(end, -3);
  return { from, to: lastDay, days: dayNo(end) - dayNo(from) };
}

/**
 * 기간 안의 임금 — [months]는 `[{ payMonth('YYYY-MM'), gross }]`(보낸 명세서의 귀속 월 합계). 달마다 기간에 든 날의 비율만큼 더한다.
 * `[{ payMonth, gross, days, monthDays, amount }]`.
 */
export function wagesInPeriod(months, period) {
  const out = [];
  for (const m of months ?? []) {
    if (!/^\d{4}-\d{2}$/.test(m.payMonth ?? '')) continue;
    const first = `${m.payMonth}-01`;
    const last = addDays(addMonths(first, 1), -1);
    const from = first > period.from ? first : period.from;
    const to = last < period.to ? last : period.to;
    const days = dayNo(to) - dayNo(from) + 1;
    if (days <= 0) continue;
    const monthDays = dayNo(last) - dayNo(first) + 1;
    out.push({ payMonth: m.payMonth, gross: m.gross, days, monthDays, amount: Math.floor((m.gross * days) / monthDays) });
  }
  return out;
}

/** 근속연수공제(2023년 이후). */
export function serviceYearsDeduction(years) {
  if (years <= 5) return 1_000_000 * years;
  if (years <= 10) return 5_000_000 + 2_000_000 * (years - 5);
  if (years <= 20) return 15_000_000 + 2_500_000 * (years - 10);
  return 40_000_000 + 3_000_000 * (years - 20);
}

/** 환산급여공제. */
export function convertedPayDeduction(pay) {
  if (pay <= 8_000_000) return pay;
  if (pay <= 70_000_000) return 8_000_000 + (pay - 8_000_000) * 0.6;
  if (pay <= 100_000_000) return 45_200_000 + (pay - 70_000_000) * 0.55;
  if (pay <= 300_000_000) return 61_700_000 + (pay - 100_000_000) * 0.45;
  return 151_700_000 + (pay - 300_000_000) * 0.35;
}

/** 퇴직소득세 — 퇴직급여 [amount]원, 근속연수 [years]. `{ serviceDeduction, convertedPay, convertedDeduction, taxBase, convertedTax, incomeTax, localTax }`. */
export function retirementIncomeTax(amount, years) {
  const y = Math.max(1, Math.floor(years));
  const income = Math.max(0, Math.floor(amount));
  const serviceDeduction = Math.min(income, serviceYearsDeduction(y));
  const convertedPay = Math.floor(((income - serviceDeduction) * 12) / y);
  const convertedDeduction = Math.floor(convertedPayDeduction(convertedPay));
  const taxBase = Math.max(0, convertedPay - convertedDeduction);
  const convertedTax = Math.floor(basicTax(taxBase));
  const incomeTax = floor10((convertedTax * y) / 12);
  return { serviceDeduction, convertedPay, convertedDeduction, taxBase, convertedTax, incomeTax, localTax: floor10(incomeTax * 0.1) };
}

const amountOf = (v) => {
  if (v === undefined || v === null || v === '') return 0;
  const n = Number(typeof v === 'string' ? v.replace(/[,\s원]/g, '') : v);
  return Number.isFinite(n) && n >= 0 && n <= 10_000_000_000 ? Math.round(n) : null;
};

/**
 * 퇴직금 계산 입력 `{ hireDate, lastDay, annualBonus?, leavePay?, wages?(3개월 임금 총액 — 비우면 명세서로), hourlyWage?, wageMonths? }` →
 * 결과 | `{ error }`. [wageMonths]는 보낸 명세서의 귀속 월 합계(서버가 넣는다).
 */
export function calculateSeverance(input) {
  const { hireDate, lastDay } = input ?? {};
  if (!isDateKey(hireDate)) return { error: '입사일을 확인하세요(관리 탭에서 정하거나 직접 넣으세요).' };
  if (!isDateKey(lastDay)) return { error: '마지막 근무일을 확인하세요.' };
  if (lastDay < hireDate) return { error: '마지막 근무일이 입사일보다 앞입니다.' };
  const annualBonus = amountOf(input.annualBonus);
  const leavePay = amountOf(input.leavePay);
  const manualWages = input.wages === undefined || input.wages === null || input.wages === '' ? null : amountOf(input.wages);
  const hourlyWage = amountOf(input.hourlyWage);
  if (annualBonus === null || leavePay === null || hourlyWage === null || (input.wages !== undefined && input.wages !== null && input.wages !== '' && manualWages === null)) {
    return { error: '금액을 원 단위 숫자로 넣으세요.' };
  }
  const days = serviceDays(hireDate, lastDay);
  const period = averageWagePeriod(lastDay);
  const breakdown = wagesInPeriod(input.wageMonths ?? [], period);
  const wages = manualWages ?? breakdown.reduce((s, b) => s + b.amount, 0);
  const bonusAdd = Math.floor((annualBonus * 3) / 12);
  const leaveAdd = Math.floor((leavePay * 3) / 12);
  const averageDaily = (wages + bonusAdd + leaveAdd) / period.days;
  const ordinaryDaily = hourlyWage * 8;
  const dailyWage = Math.max(averageDaily, ordinaryDaily);
  const eligible = days >= 365;
  const amount = eligible ? Math.floor((dailyWage * 30 * days) / 365) : 0;
  const years = serviceYears(hireDate, lastDay);
  const tax = retirementIncomeTax(amount, years);
  return {
    hireDate,
    lastDay,
    retireDate: addDays(lastDay, 1),
    serviceDays: days,
    serviceYears: years,
    eligible,
    period,
    wageBreakdown: manualWages === null ? breakdown : [],
    wages,
    annualBonus,
    bonusAdd,
    leavePay,
    leaveAdd,
    averageDailyWage: Math.floor(averageDaily * 100) / 100,
    ordinaryDailyWage: ordinaryDaily,
    usedOrdinary: ordinaryDaily > averageDaily,
    dailyWage: Math.floor(dailyWage * 100) / 100,
    amount,
    ...tax,
    net: amount - tax.incomeTax - tax.localTax,
  };
}

const WON = '원';
const won = (n) => Math.floor(n).toLocaleString('ko-KR') + WON;

/** 퇴직금 명세서의 항목(급여 대장으로 만들 때) — 지급 퇴직금(계산 방법), 공제 퇴직소득세·지방소득세. */
export function severancePayslipData(result) {
  return {
    earnings: [{ name: '퇴직금', amount: result.amount, basis: `1일 평균임금 ${won(result.dailyWage)} × 30일 × ${result.serviceDays}일 ÷ 365` }],
    deductions: [
      { name: '퇴직소득세', amount: result.incomeTax, basis: `근속 ${result.serviceYears}년` },
      { name: '지방소득세', amount: result.localTax },
    ],
    work: null,
    memo: `재직 ${result.hireDate} ~ ${result.lastDay} (${result.serviceDays}일), 평균임금 산정 ${result.period.from} ~ ${result.period.to} (${result.period.days}일)`,
  };
}
