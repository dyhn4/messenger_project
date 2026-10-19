/**
 * 급여명세서(payroll.js)의 순수 규칙 — 지급·공제 항목 검사, 합계, 4대보험 공제 어림(참고용), 엑셀 급여대장 가져오기·내보내기의 열.
 * DB 없이 `node --test`로 시험한다(test/payroll.test.js).
 *
 * 근로기준법 제48조 제2항·시행령 제27조의2 — 임금을 줄 때 임금명세서를 서면(전자 문서 포함)으로 주어야 하고, 명세서에는 ① 성명·생년월일·
 * 사원번호 등 근로자를 특정할 정보 ② 임금 지급일 ③ 임금 총액 ④ 기본급·각종 수당·상여금·성과금 등 구성 항목별 금액 ⑤ 출근일수·시간 등에
 * 따라 달라지는 항목의 계산 방법(연장·야간·휴일근로의 시간 수 포함) ⑥ 공제 항목별 금액과 총액이 들어가야 한다. 그래서 항목마다 "계산 방법"
 * 칸과 근무 시간 요약(work)을 두고, 사람을 특정하는 값으로 이름·사번·부서·직책을 적는다.
 *
 * 금액은 원 단위 정수다. 명세서 내용(항목·금액·메모)은 DB에 암호화해 둔다(payroll.js — crypto.js encryptField).
 */

export const PAYROLL_ITEMS_MAX = 30;
export const PAYROLL_ITEM_NAME_MAX = 30;
export const PAYROLL_BASIS_MAX = 100;
export const PAYROLL_MEMO_MAX = 1000;
export const PAYROLL_NOTE_MAX = 1000;
export const PAYROLL_TITLE_MAX = 60;
export const PAYROLL_REASON_MAX = 200;
export const PAYROLL_STAFF_MAX = 20;
export const EMPLOYEE_NO_MAX = 30;
/** 항목 하나의 금액 상한(±10억 원 — 소급분 환수 같은 음수도 받는다). */
export const PAYROLL_AMOUNT_MAX = 1_000_000_000;
/** 한 급여 대장의 사람 수 상한. */
export const PAYROLL_SLIPS_MAX = 2000;

/** 새 급여 대장의 기본 항목(관리자가 바꾼다) — 식대는 월 20만 원까지 비과세(소득세법 시행령 제17조의2)라 비과세로 둔다. */
export const DEFAULT_EARNING_ITEMS = Object.freeze([
  { name: '기본급' },
  { name: '식대', taxFree: true },
  { name: '연장근로수당' },
  { name: '야간근로수당' },
  { name: '휴일근로수당' },
]);
export const DEFAULT_DEDUCTION_ITEMS = Object.freeze([
  { name: '국민연금' },
  { name: '건강보험' },
  { name: '장기요양보험' },
  { name: '고용보험' },
  { name: '소득세' },
  { name: '지방소득세' },
]);

/** 근태에서 채우는 수당 항목 이름(workPolicy.js allowanceOf의 연장·야간·휴일). */
export const ALLOWANCE_ITEMS = Object.freeze({ overtime: '연장근로수당', night: '야간근로수당', holiday: '휴일근로수당' });

/** 4대보험 공제 어림에서 채우는 항목 이름. */
export const INSURANCE_ITEMS = Object.freeze({
  pension: '국민연금',
  health: '건강보험',
  longTermCare: '장기요양보험',
  employment: '고용보험',
  incomeTax: '소득세',
  localTax: '지방소득세',
});

/**
 * 4대보험 근로자 부담 요율(%) 기본값 — 2026년. 국민연금 9.5%(근로자 4.75%, 2026년부터 해마다 0.5%p 올라 2033년 13%), 건강보험 7.19%
 * (근로자 3.595%), 장기요양 소득의 0.9448%(= 건강보험료 × 0.9448 / 7.19 ≈ 13.14%), 고용보험 실업급여 1.8%(근로자 0.9%). 국민연금 기준소득월액
 * 상·하한은 해마다 7월에 바뀐다(2025.7~2026.6: 637만 원·40만 원). 요율은 고시로 바뀌므로 관리자가 고친다(급여 설정).
 */
export const DEFAULT_INSURANCE = Object.freeze({
  pension: 4.75,
  health: 3.595,
  // 장기요양보험료 = 건강보험료 × 이 비율(%).
  longTermCare: 13.14,
  employment: 0.9,
  pensionMin: 400_000,
  pensionMax: 6_370_000,
  // 지방소득세 = 소득세 × 이 비율(%).
  localTax: 10,
});

const DEDUCTION_NAME_HINTS = [
  '국민연금',
  '건강보험',
  '장기요양',
  '고용보험',
  '소득세',
  '지방소득세',
  '주민세',
  '공제',
  '가불',
  '상환',
  '환수',
  '연말정산',
  '사우회비',
  '조합비',
];

const cleanText = (v, max) =>
  typeof v === 'string' ? v.replace(/[\u0000-\u001f\u007f‪-‮⁦-⁩]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max) : '';

/** 'YYYY-MM'인지. */
export const isMonthKey = (v) => typeof v === 'string' && /^\d{4}-(0[1-9]|1[0-2])$/.test(v);

/** 금액 하나 — 정수(쉼표 글자도 받는다)로, 아니면 null. */
export function parseAmount(v) {
  if (typeof v === 'number') return Number.isFinite(v) ? Math.round(v) : null;
  if (typeof v !== 'string') return null;
  let s = v.replace(/[,\s원₩]/g, '');
  let negative = false;
  // 회계식 음수 "(12,300)".
  if (/^\(.*\)$/.test(s)) {
    negative = true;
    s = s.slice(1, -1);
  }
  if (!/^[-+]?\d+(\.\d+)?$/.test(s)) return null;
  const n = Math.round(Number(s));
  return negative ? -n : n;
}

/**
 * 항목 목록 하나(지급 또는 공제) → `{ items: [{ name, amount, basis?, taxFree? }] }` | `{ error }`. 이름이 빈 줄은 버리고, 같은 이름이 두 번
 * 나오면 오류(엑셀 가져오기·자동 채우기가 이름으로 찾는다). [allowTaxFree]면 비과세 표시를 받는다(지급 항목).
 */
export function parseItems(input, { label, allowTaxFree = false } = {}) {
  if (input === undefined || input === null) return { items: [] };
  if (!Array.isArray(input)) return { error: `${label} 항목을 확인하세요.` };
  const items = [];
  const seen = new Set();
  for (const raw of input) {
    const name = cleanText(raw?.name, PAYROLL_ITEM_NAME_MAX + 1);
    if (!name) continue;
    if ([...name].length > PAYROLL_ITEM_NAME_MAX) return { error: `항목 이름은 ${PAYROLL_ITEM_NAME_MAX}자까지입니다.` };
    if (seen.has(name)) return { error: `${label} 항목 '${name}'이(가) 두 번 있습니다.` };
    seen.add(name);
    const amount = raw?.amount === undefined || raw?.amount === null || raw?.amount === '' ? 0 : parseAmount(raw.amount);
    if (amount === null || Math.abs(amount) > PAYROLL_AMOUNT_MAX) return { error: `'${name}'의 금액을 원 단위 숫자로 넣으세요.` };
    const basis = cleanText(raw?.basis, PAYROLL_BASIS_MAX);
    items.push({ name, amount, ...(basis && { basis }), ...(allowTaxFree && raw?.taxFree === true && { taxFree: true }) });
    if (items.length > PAYROLL_ITEMS_MAX) return { error: `${label} 항목은 ${PAYROLL_ITEMS_MAX}개까지입니다.` };
  }
  return { items };
}

const minutesOf = (v) => {
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 && n <= 31 * 24 * 60 ? Math.round(n) : null;
};

/** 근무 시간 요약 `{ workDays, workMinutes, overtimeMinutes, nightMinutes, holidayMinutes }`(모두 선택) → 저장할 값(없으면 null). */
export function parseWorkSummary(input) {
  if (!input || typeof input !== 'object') return null;
  const out = {};
  const days = Number(input.workDays);
  if (Number.isInteger(days) && days >= 0 && days <= 31) out.workDays = days;
  for (const key of ['workMinutes', 'overtimeMinutes', 'nightMinutes', 'holidayMinutes']) {
    const m = minutesOf(input[key]);
    if (m !== null && input[key] !== undefined && input[key] !== null && input[key] !== '') out[key] = m;
  }
  return Object.keys(out).length ? out : null;
}

/** 명세서 내용 → `{ data: { earnings, deductions, work, memo } }` | `{ error }`. */
export function parsePayslipData(body) {
  const earnings = parseItems(body?.earnings, { label: '지급', allowTaxFree: true });
  if (earnings.error) return earnings;
  const deductions = parseItems(body?.deductions, { label: '공제' });
  if (deductions.error) return deductions;
  const memo = cleanText(body?.memo, PAYROLL_MEMO_MAX + 1);
  if ([...memo].length > PAYROLL_MEMO_MAX) return { error: `메모는 ${PAYROLL_MEMO_MAX}자까지입니다.` };
  return {
    data: {
      earnings: earnings.items,
      deductions: deductions.items,
      work: parseWorkSummary(body?.work),
      memo: memo || null,
    },
  };
}

/** 합계 — 지급 총액·과세 대상(비과세 뺀)·공제 총액·실수령액. */
export function payslipTotals(data) {
  const earnings = data?.earnings ?? [];
  const deductions = data?.deductions ?? [];
  const gross = earnings.reduce((s, i) => s + (i.amount ?? 0), 0);
  const taxFree = earnings.filter((i) => i.taxFree).reduce((s, i) => s + (i.amount ?? 0), 0);
  const deductionTotal = deductions.reduce((s, i) => s + (i.amount ?? 0), 0);
  return { gross, taxable: gross - taxFree, taxFree, deductionTotal, net: gross - deductionTotal };
}

/** 빈 명세서 — 항목 틀(이름만, 금액 0). */
export function blankPayslipData(template) {
  const t = template ?? {};
  return {
    earnings: (t.earnings ?? DEFAULT_EARNING_ITEMS).map((i) => ({ name: i.name, amount: 0, ...(i.taxFree && { taxFree: true }) })),
    deductions: (t.deductions ?? DEFAULT_DEDUCTION_ITEMS).map((i) => ({ name: i.name, amount: 0 })),
    work: null,
    memo: null,
  };
}

/** 지난 명세서의 항목·금액을 그대로 이어받은 새 명세서(근무 시간·메모는 비운다 — 달마다 다르다). */
export function carriedPayslipData(previous) {
  return {
    earnings: (previous?.earnings ?? []).map((i) => ({ ...i })),
    deductions: (previous?.deductions ?? []).map((i) => ({ ...i })),
    work: null,
    memo: null,
  };
}

/** 항목 틀(급여 설정) → `{ template: { earnings: [{ name, taxFree? }], deductions: [{ name }] } }` | `{ error }`. */
export function parseItemTemplate(input) {
  if (input === undefined || input === null) return { template: null };
  const earnings = parseItems(input.earnings, { label: '지급', allowTaxFree: true });
  if (earnings.error) return earnings;
  const deductions = parseItems(input.deductions, { label: '공제' });
  if (deductions.error) return deductions;
  return {
    template: {
      earnings: earnings.items.map(({ name, taxFree }) => ({ name, ...(taxFree && { taxFree: true }) })),
      deductions: deductions.items.map(({ name }) => ({ name })),
    },
  };
}

/** 4대보험 요율 설정 → 저장할 값 `{ insurance }` | `{ error }`. 비우면 기본값. */
export function parseInsurance(input) {
  if (input === undefined || input === null) return { insurance: null };
  if (typeof input !== 'object') return { error: '요율을 확인하세요.' };
  const out = {};
  for (const key of ['pension', 'health', 'longTermCare', 'employment', 'localTax']) {
    if (input[key] === undefined || input[key] === null || input[key] === '') continue;
    const n = Number(input[key]);
    if (!Number.isFinite(n) || n < 0 || n > 100) return { error: '요율은 0~100(%) 사이 숫자로 넣으세요.' };
    out[key] = Math.round(n * 10000) / 10000;
  }
  for (const key of ['pensionMin', 'pensionMax']) {
    if (input[key] === undefined || input[key] === null || input[key] === '') continue;
    const n = parseAmount(input[key]);
    if (n === null || n < 0 || n > 100_000_000) return { error: '국민연금 기준소득월액 상·하한을 원 단위로 넣으세요.' };
    out[key] = n;
  }
  const merged = { ...DEFAULT_INSURANCE, ...out };
  if (merged.pensionMin > merged.pensionMax) return { error: '국민연금 하한이 상한보다 큽니다.' };
  return { insurance: out };
}

export const insuranceOf = (stored) => ({ ...DEFAULT_INSURANCE, ...(stored ?? {}) });

const floor10 = (n) => Math.floor(n / 10) * 10;

/**
 * 4대보험 근로자 부담분 어림(참고용) — 과세 대상 급여([taxable], 원)로. 국민연금은 기준소득월액(천 원 미만 버림, 상·하한)에, 건강·고용보험은
 * 보수월액에 요율을 곱하고 10원 미만은 버린다. 장기요양은 건강보험료 × 비율. 소득세(간이세액표 — 부양가족 수에 따라 다름)는 계산하지 않는다.
 * `{ pension, health, longTermCare, employment }`.
 */
export function insuranceDeductions(taxable, stored) {
  const r = insuranceOf(stored);
  const pay = Math.max(0, Math.floor(taxable));
  if (pay === 0) return { pension: 0, health: 0, longTermCare: 0, employment: 0 };
  const pensionBase = Math.min(r.pensionMax, Math.max(r.pensionMin, Math.floor(pay / 1000) * 1000));
  const health = floor10((pay * r.health) / 100);
  return {
    pension: floor10((pensionBase * r.pension) / 100),
    health,
    longTermCare: floor10((health * r.longTermCare) / 100),
    employment: floor10((pay * r.employment) / 100),
  };
}

/** 항목 목록에서 [name]의 금액을 [amount]로 — 없으면 덧붙인다(계산 방법은 [basis]가 있으면 바꾼다). 새 목록. */
export function setItem(items, name, amount, basis = undefined) {
  const list = (items ?? []).map((i) => ({ ...i }));
  const found = list.find((i) => i.name === name);
  if (found) {
    found.amount = amount;
    if (basis !== undefined) {
      if (basis) found.basis = basis;
      else delete found.basis;
    }
    return list;
  }
  list.push({ name, amount, ...(basis && { basis }) });
  return list;
}

/** 4대보험 공제를 명세서에 채운다(지방소득세는 소득세가 있으면 그 비율로). 새 data. */
export function applyInsurance(data, stored) {
  const totals = payslipTotals(data);
  const r = insuranceOf(stored);
  const ded = insuranceDeductions(totals.taxable, stored);
  let deductions = data.deductions ?? [];
  deductions = setItem(deductions, INSURANCE_ITEMS.pension, ded.pension);
  deductions = setItem(deductions, INSURANCE_ITEMS.health, ded.health);
  deductions = setItem(deductions, INSURANCE_ITEMS.longTermCare, ded.longTermCare);
  deductions = setItem(deductions, INSURANCE_ITEMS.employment, ded.employment);
  const incomeTax = deductions.find((i) => i.name === INSURANCE_ITEMS.incomeTax)?.amount ?? 0;
  if (incomeTax > 0 || deductions.some((i) => i.name === INSURANCE_ITEMS.localTax)) {
    deductions = setItem(deductions, INSURANCE_ITEMS.localTax, floor10((Math.max(0, incomeTax) * r.localTax) / 100));
  }
  return { ...data, deductions };
}

const hoursText = (minutes) => {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m ? `${h}시간 ${m}분` : `${h}시간`;
};
// 계산 방법 글의 금액("12,000원") — 템플릿 글로 두면 앱의 서버 글 번역(trServer)이 '…원'으로 끝나는 모든 글에 걸리므로 이어 붙인다.
const WON = '원';
const won = (n) => Math.round(n).toLocaleString('ko-KR') + WON;

/**
 * 근태(한 달 요약·가산 수당 — groupware.js attendanceMonthSummaries)를 명세서에 채운다 — 근무 시간 요약(work)을 바꾸고, 통상시급이 있는 사람은
 * 연장·야간·휴일근로수당 금액과 계산 방법을 넣는다(통상시급 × 시간 × 배율 — 근로기준법 제56조). [rates]는 가산율(%)이다. 새 data.
 */
export function applyAttendance(data, { summary, allowance, rates }) {
  // 한 달 요약(attendanceRules.js summarizeMonth + workRules.js monthBreakdown) — 실근로·실제 연장·야간·휴일. 탄력·선택근무의 연장은
  // 가산 수당 쪽(정산 기간이 끝난 달에 기간의 연장)을 따른다.
  const work = {
    workDays: summary?.daysWorked,
    workMinutes: summary?.netMinutes,
    overtimeMinutes: allowance?.overtimeMinutes ?? summary?.actualOvertimeMinutes,
    nightMinutes: allowance?.nightMinutes ?? summary?.nightMinutes,
    holidayMinutes:
      allowance !== null && allowance !== undefined
        ? (allowance.holidayMinutes ?? 0) + (allowance.holidayOverMinutes ?? 0)
        : summary?.holidayWorkMinutes,
  };
  const next = { ...data, work: parseWorkSummary(work) };
  if (!allowance) return next;
  const wage = allowance.wage;
  const pct = (key, base) => (rates?.smallBusiness ? base : base + (rates?.[key] ?? 0));
  let earnings = next.earnings ?? [];
  const overtimeRate = pct('overtime', 100);
  earnings = setItem(
    earnings,
    ALLOWANCE_ITEMS.overtime,
    allowance.overtimePay,
    allowance.overtimeMinutes ? `${hoursText(allowance.overtimeMinutes)} × ${won(wage)} × ${overtimeRate / 100}` : '',
  );
  const nightRate = pct('night', 0);
  earnings = setItem(
    earnings,
    ALLOWANCE_ITEMS.night,
    allowance.nightPay,
    allowance.nightMinutes && nightRate ? `${hoursText(allowance.nightMinutes)} × ${won(wage)} × ${nightRate / 100}` : '',
  );
  const holidayParts = [];
  if (allowance.holidayMinutes) holidayParts.push(`${hoursText(allowance.holidayMinutes)} × ${won(wage)} × ${pct('holiday', 100) / 100}`);
  if (allowance.holidayOverMinutes) holidayParts.push(`${hoursText(allowance.holidayOverMinutes)} × ${won(wage)} × ${pct('holidayOver', 100) / 100}`);
  earnings = setItem(earnings, ALLOWANCE_ITEMS.holiday, allowance.holidayPay, holidayParts.join(' + '));
  return { ...next, earnings };
}

// ── 급여 설정 ──

/** 급여 담당자 목록 → `{ staffIds }` | `{ error }` — [isCandidate](id)인 사람만(범위의 정회원 이상). */
export function parseStaffIds(input, isCandidate) {
  if (input === undefined) return { staffIds: undefined };
  if (!Array.isArray(input)) return { error: '급여 담당자를 확인하세요.' };
  const ids = [...new Set(input.filter((id) => typeof id === 'string'))];
  if (ids.length > PAYROLL_STAFF_MAX) return { error: `급여 담당자는 ${PAYROLL_STAFF_MAX}명까지입니다.` };
  if (ids.some((id) => !isCandidate(id))) return { error: '급여 담당자는 이 범위의 정회원 이상만 정할 수 있습니다.' };
  return { staffIds: ids };
}

/** 사번 표 `{ userId: '사번' }` → 저장할 값 | `{ error }`. 빈 값은 지운다. */
export function parseEmployeeNos(input, current = {}) {
  if (input === undefined) return { employeeNos: undefined };
  if (!input || typeof input !== 'object' || Array.isArray(input)) return { error: '사번을 확인하세요.' };
  const out = { ...(current ?? {}) };
  for (const [userId, raw] of Object.entries(input)) {
    const value = cleanText(raw ?? '', EMPLOYEE_NO_MAX + 1);
    if ([...value].length > EMPLOYEE_NO_MAX) return { error: `사번은 ${EMPLOYEE_NO_MAX}자까지입니다.` };
    if (value) out[userId] = value;
    else delete out[userId];
  }
  return { employeeNos: out };
}

/** 급여를 다룰 수 있는지 — 그룹웨어 관리자, 또는 관리자가 정한 급여 담당자. */
export const canManagePayroll = ({ isManager, userId, staffIds = [] }) => isManager === true || (staffIds ?? []).includes(userId);

/** 급여 대장 머리 `{ title, payMonth, payDate, note }` → `{ run }` | `{ error }`. [partial]이면 보낸 칸만. */
export function parseRunInput(body, { partial = false } = {}) {
  const out = {};
  if (!partial || body?.payMonth !== undefined) {
    if (!isMonthKey(body?.payMonth)) return { error: '급여 달을 고르세요(YYYY-MM).' };
    out.payMonth = body.payMonth;
  }
  if (!partial || body?.payDate !== undefined) {
    if (typeof body?.payDate !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(body.payDate) || Number.isNaN(Date.parse(`${body.payDate}T00:00:00Z`))) {
      return { error: '지급일을 확인하세요.' };
    }
    out.payDate = body.payDate;
  }
  if (!partial || body?.title !== undefined) {
    const title = cleanText(body?.title ?? '', PAYROLL_TITLE_MAX + 1);
    if ([...title].length > PAYROLL_TITLE_MAX) return { error: `제목은 ${PAYROLL_TITLE_MAX}자까지입니다.` };
    out.title = title || (out.payMonth ? defaultRunTitle(out.payMonth) : null);
    if (!out.title) delete out.title;
  }
  if (!partial || body?.note !== undefined) {
    const note = cleanText(body?.note ?? '', PAYROLL_NOTE_MAX + 1);
    if ([...note].length > PAYROLL_NOTE_MAX) return { error: `안내 글은 ${PAYROLL_NOTE_MAX}자까지입니다.` };
    out.note = note || null;
  }
  return { run: out };
}

export const defaultRunTitle = (payMonth) => `${Number(payMonth.slice(0, 4))}년 ${Number(payMonth.slice(5, 7))}월 급여`;

/** 정정 사유 — 게시한 명세서를 고칠 때 꼭. */
export function parseCorrectionReason(v) {
  const reason = cleanText(v ?? '', PAYROLL_REASON_MAX + 1);
  if (!reason) return { error: '이미 보낸 명세서입니다. 정정 사유를 쓰세요.' };
  if ([...reason].length > PAYROLL_REASON_MAX) return { error: `사유는 ${PAYROLL_REASON_MAX}자까지입니다.` };
  return { reason };
}

// ── 엑셀 급여대장 ──

/** 급여대장 시트의 고정 열(항목이 아님). */
export const SHEET_FIXED = Object.freeze({
  username: '아이디',
  employeeNo: '사번',
  name: '이름',
  department: '부서',
  position: '직책',
  workDays: '근무일수',
  workHours: '근로시간',
  overtimeHours: '연장시간',
  nightHours: '야간시간',
  holidayHours: '휴일시간',
  gross: '지급 합계',
  deductionTotal: '공제 합계',
  net: '실수령액',
  memo: '메모',
  viewed: '확인',
});
const FIXED_HEADERS = new Set(Object.values(SHEET_FIXED));
export const DEDUCTION_PREFIX = '[공제] ';
export const TAX_FREE_SUFFIX = ' (비과세)';
export const BASIS_PREFIX = '[계산] ';

/** 엑셀 머리 글자 하나 → `{ kind: 'fixed', key } | { kind: 'earning'|'deduction', name, taxFree? } | { kind: 'basis', name } | null`. */
export function classifyHeader(raw) {
  const text = cleanText(typeof raw === 'string' ? raw : raw === null || raw === undefined ? '' : String(raw), 60);
  if (!text) return null;
  for (const [key, label] of Object.entries(SHEET_FIXED)) if (text === label) return { kind: 'fixed', key };
  const prefixed = /^\[\s*(공제|지급|계산)\s*\]\s*(.+)$/.exec(text) ?? /^(공제|지급|계산)\s*[:：]\s*(.+)$/.exec(text);
  let kind = null;
  let name = text;
  if (prefixed) {
    kind = prefixed[1] === '공제' ? 'deduction' : prefixed[1] === '계산' ? 'basis' : 'earning';
    name = prefixed[2].trim();
  }
  let taxFree = false;
  const tf = /^(.+?)\s*\(\s*비과세\s*\)$/.exec(name);
  if (tf) {
    name = tf[1].trim();
    taxFree = true;
  }
  name = name.slice(0, PAYROLL_ITEM_NAME_MAX);
  if (!name) return null;
  if (kind === 'basis') return { kind, name };
  if (!kind) kind = DEDUCTION_NAME_HINTS.some((h) => name.includes(h)) ? 'deduction' : 'earning';
  return { kind, name, ...(kind === 'earning' && taxFree && { taxFree: true }) };
}

const cellText = (v) => {
  if (v === null || v === undefined) return '';
  if (typeof v === 'object') {
    if (v instanceof Date) return v.toISOString().slice(0, 10);
    if (Array.isArray(v.richText)) return v.richText.map((r) => r.text ?? '').join('');
    if ('result' in v) return cellText(v.result);
    if ('text' in v) return String(v.text);
    return '';
  }
  return String(v).trim();
};
const cellAmount = (v) => {
  if (v && typeof v === 'object' && !(v instanceof Date) && 'result' in v) return cellAmount(v.result);
  if (v === null || v === undefined || v === '') return null;
  return parseAmount(typeof v === 'number' ? v : cellText(v));
};
const cellHoursToMinutes = (v) => {
  const n = cellAmount(v) === null ? null : Number(String(cellText(v)).replace(/,/g, ''));
  return n === null || !Number.isFinite(n) || n < 0 ? null : Math.round(n * 60);
};

/**
 * 급여대장 엑셀 가져오기 계획(순수) — [rows]는 첫 줄이 머리인 시트의 값 목록(줄마다 열 순서), [people]은 이 대장에 넣을 수 있는 사람
 * `[{ id, username, name, employeeNo }]`. 사람은 아이디 → 사번 → 이름(이름은 하나뿐일 때만) 순서로 찾는다.
 * 항목 열: "[공제] 이름"·"공제: 이름"은 공제, "[지급] …"·그 밖은 지급(국민연금·소득세 같은 흔한 공제 이름은 그냥 써도 공제), "(비과세)"가
 * 붙으면 비과세 지급, "[계산] 항목"은 그 항목의 계산 방법. 빈 칸은 그 항목을 넣지 않는다.
 * `{ plan: [{ userId, data }], unmatched: [{ row, label }], errors: [{ row, message }], columns: { earnings, deductions } }`.
 */
export function planPayrollImport(rows, people) {
  const errors = [];
  const [header = [], ...body] = rows ?? [];
  const columns = header.map(classifyHeader);
  const fixed = new Map();
  columns.forEach((c, i) => {
    if (c?.kind === 'fixed' && !fixed.has(c.key)) fixed.set(c.key, i);
  });
  if (!fixed.has('username') && !fixed.has('employeeNo') && !fixed.has('name')) {
    return { plan: [], unmatched: [], errors: [{ row: 1, message: "첫 줄에 '아이디'·'사번'·'이름' 중 하나의 열이 있어야 합니다." }], columns: { earnings: [], deductions: [] } };
  }
  const earningCols = [];
  const deductionCols = [];
  const basisCols = new Map();
  const seen = new Set();
  columns.forEach((c, i) => {
    if (!c || c.kind === 'fixed') return;
    if (c.kind === 'basis') {
      basisCols.set(c.name, i);
      return;
    }
    const key = `${c.kind}:${c.name}`;
    if (seen.has(key)) {
      errors.push({ row: 1, message: `'${c.name}' 열이 두 번 있습니다.` });
      return;
    }
    seen.add(key);
    (c.kind === 'deduction' ? deductionCols : earningCols).push({ ...c, index: i });
  });
  if (earningCols.length > PAYROLL_ITEMS_MAX || deductionCols.length > PAYROLL_ITEMS_MAX) {
    errors.push({ row: 1, message: `지급·공제 항목은 각각 ${PAYROLL_ITEMS_MAX}개까지입니다.` });
  }
  const byUsername = new Map(people.map((p) => [String(p.username ?? '').toLowerCase(), p]));
  const byEmployeeNo = new Map(people.filter((p) => p.employeeNo).map((p) => [String(p.employeeNo), p]));
  const nameCount = new Map();
  for (const p of people) nameCount.set(p.name, (nameCount.get(p.name) ?? 0) + 1);
  const byName = new Map(people.filter((p) => nameCount.get(p.name) === 1).map((p) => [p.name, p]));

  const plan = [];
  const unmatched = [];
  const taken = new Set();
  body.forEach((row, idx) => {
    const rowNo = idx + 2;
    const get = (key) => (fixed.has(key) ? cellText(row[fixed.get(key)]) : '');
    const username = get('username');
    const employeeNo = get('employeeNo');
    const name = get('name');
    if (!username && !employeeNo && !name) return;
    // 합계 줄은 건너뛴다.
    if (/^(합\s*계|소\s*계|총\s*계)$/.test(name || username)) return;
    const person =
      (username && byUsername.get(username.toLowerCase())) || (employeeNo && byEmployeeNo.get(employeeNo)) || (name && byName.get(name)) || null;
    if (!person) {
      unmatched.push({ row: rowNo, label: name || username || employeeNo });
      return;
    }
    if (taken.has(person.id)) {
      errors.push({ row: rowNo, message: `${person.name}님이 두 줄에 있습니다.` });
      return;
    }
    taken.add(person.id);
    const items = (cols) => {
      const out = [];
      for (const c of cols) {
        const raw = row[c.index];
        if (raw === null || raw === undefined || cellText(raw) === '') continue;
        const amount = cellAmount(raw);
        if (amount === null || Math.abs(amount) > PAYROLL_AMOUNT_MAX) {
          errors.push({ row: rowNo, message: `'${c.name}' 금액을 읽지 못했습니다: ${cellText(raw)}` });
          continue;
        }
        const basis = basisCols.has(c.name) ? cleanText(cellText(row[basisCols.get(c.name)]), PAYROLL_BASIS_MAX) : '';
        out.push({ name: c.name, amount, ...(basis && { basis }), ...(c.taxFree && { taxFree: true }) });
      }
      return out;
    };
    const work = {};
    if (fixed.has('workDays')) {
      const d = cellAmount(row[fixed.get('workDays')]);
      if (d !== null) work.workDays = d;
    }
    for (const [key, col] of [
      ['workMinutes', 'workHours'],
      ['overtimeMinutes', 'overtimeHours'],
      ['nightMinutes', 'nightHours'],
      ['holidayMinutes', 'holidayHours'],
    ]) {
      if (!fixed.has(col)) continue;
      const m = cellHoursToMinutes(row[fixed.get(col)]);
      if (m !== null && cellText(row[fixed.get(col)]) !== '') work[key] = m;
    }
    const memo = cleanText(get('memo'), PAYROLL_MEMO_MAX) || null;
    plan.push({
      userId: person.id,
      employeeNo: employeeNo || null,
      data: { earnings: items(earningCols), deductions: items(deductionCols), work: parseWorkSummary(work), memo },
    });
  });
  return {
    plan,
    unmatched,
    errors,
    columns: { earnings: earningCols.map((c) => c.name), deductions: deductionCols.map((c) => c.name) },
  };
}

/**
 * 급여대장 시트의 열(내보내기 — 가져오기와 같은 모양) — 명세서들에 나온 항목을 처음 나온 순서대로. `[{ header, value(slip) }]`.
 * [slips]는 `[{ username, employeeNo, name, department, position, data, viewedAt }]`.
 */
export function payrollSheetColumns(slips) {
  const earnings = [];
  const deductions = [];
  const taxFree = new Set();
  const withBasis = new Set();
  for (const s of slips) {
    for (const i of s.data?.earnings ?? []) {
      if (!earnings.includes(i.name)) earnings.push(i.name);
      if (i.taxFree) taxFree.add(i.name);
      if (i.basis) withBasis.add(`e:${i.name}`);
    }
    for (const i of s.data?.deductions ?? []) {
      if (!deductions.includes(i.name)) deductions.push(i.name);
      if (i.basis) withBasis.add(`d:${i.name}`);
    }
  }
  const amountOf = (list, name) => list?.find((i) => i.name === name)?.amount ?? null;
  const basisOf = (list, name) => list?.find((i) => i.name === name)?.basis ?? '';
  const hours = (m) => (m === null || m === undefined ? null : Math.round((m / 60) * 100) / 100);
  const cols = [
    { header: SHEET_FIXED.username, value: (s) => s.username ?? '' },
    { header: SHEET_FIXED.employeeNo, value: (s) => s.employeeNo ?? '' },
    { header: SHEET_FIXED.name, value: (s) => s.name ?? '' },
    { header: SHEET_FIXED.department, value: (s) => s.department ?? '' },
    { header: SHEET_FIXED.position, value: (s) => s.position ?? '' },
    { header: SHEET_FIXED.workDays, value: (s) => s.data?.work?.workDays ?? null },
    { header: SHEET_FIXED.workHours, value: (s) => hours(s.data?.work?.workMinutes) },
    { header: SHEET_FIXED.overtimeHours, value: (s) => hours(s.data?.work?.overtimeMinutes) },
    { header: SHEET_FIXED.nightHours, value: (s) => hours(s.data?.work?.nightMinutes) },
    { header: SHEET_FIXED.holidayHours, value: (s) => hours(s.data?.work?.holidayMinutes) },
  ];
  for (const name of earnings) {
    cols.push({ header: `${name}${taxFree.has(name) ? TAX_FREE_SUFFIX : ''}`, amount: true, value: (s) => amountOf(s.data?.earnings, name) });
    if (withBasis.has(`e:${name}`)) cols.push({ header: `${BASIS_PREFIX}${name}`, value: (s) => basisOf(s.data?.earnings, name) });
  }
  for (const name of deductions) {
    cols.push({ header: `${DEDUCTION_PREFIX}${name}`, amount: true, value: (s) => amountOf(s.data?.deductions, name) });
    if (withBasis.has(`d:${name}`)) cols.push({ header: `${BASIS_PREFIX}${name}`, value: (s) => basisOf(s.data?.deductions, name) });
  }
  cols.push(
    { header: SHEET_FIXED.gross, amount: true, value: (s) => payslipTotals(s.data).gross },
    { header: SHEET_FIXED.deductionTotal, amount: true, value: (s) => payslipTotals(s.data).deductionTotal },
    { header: SHEET_FIXED.net, amount: true, value: (s) => payslipTotals(s.data).net },
    { header: SHEET_FIXED.memo, value: (s) => s.data?.memo ?? '' },
    { header: SHEET_FIXED.viewed, value: (s) => (s.viewedAt ? new Date(s.viewedAt).toISOString().slice(0, 16).replace('T', ' ') : '') },
  );
  return cols;
}

/**
 * 가져온 줄([imported] — planPayrollImport의 data, 빈 칸은 빠져 있다)을 지금 명세서([existing])에 덧쓴다 — 파일에 값이 있는 항목만 바꾸고(없던
 * 항목은 덧붙임, 비과세·계산 방법도 파일대로), 파일에 없는 항목·빈 칸은 그대로 둔다. 근무 시간·메모도 파일에 값이 있을 때만. 새 data.
 */
export function mergePayslipData(existing, imported) {
  const merge = (list, incoming) => {
    const out = (list ?? []).map((i) => ({ ...i }));
    for (const item of incoming ?? []) {
      const at = out.findIndex((i) => i.name === item.name);
      if (at >= 0) out[at] = { ...item };
      else out.push({ ...item });
    }
    return out;
  };
  return {
    earnings: merge(existing?.earnings, imported?.earnings),
    deductions: merge(existing?.deductions, imported?.deductions),
    work: imported?.work ? { ...(existing?.work ?? {}), ...imported.work } : (existing?.work ?? null),
    memo: imported?.memo ?? existing?.memo ?? null,
  };
}

/** 회사 이름(명세서 머리) → `{ companyName }` | `{ error }`. 비우면 null(팀 이름). */
export function parseCompanyName(v) {
  if (v === undefined) return { companyName: undefined };
  const name = cleanText(v ?? '', 61);
  if ([...name].length > 60) return { error: '회사 이름은 60자까지입니다.' };
  return { companyName: name || null };
}

/** 머리 글자가 가져오기에서 항목이 아닌 고정 열인지(시험용). */
export const isFixedHeader = (h) => FIXED_HEADERS.has(h);

/** 명세서를 받는 사람에게 보낼 알림 글(잠금 화면에 보이므로 금액은 넣지 않는다). */
export function payslipNotice(run, { corrected = false } = {}) {
  return corrected
    ? { title: '급여명세서 정정', body: `${run.title} 명세서가 정정되었습니다. 그룹웨어 → 급여에서 확인하세요.` }
    : { title: '급여명세서', body: `${run.title} 명세서가 도착했습니다. 그룹웨어 → 급여에서 확인하세요.` };
}
