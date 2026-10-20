/**
 * 근로소득 세금 계산(급여 — payroll.js·payrollReports.js)의 순수 규칙 — 매달 원천징수할 소득세(근로소득 간이세액표), 연말정산 어림(참고용),
 * 종합소득 기본세율. DB 없이 `node --test`로 시험한다(test/incomeTax.test.js — 간이세액표의 칸 값과 맞춰 본다).
 *
 * ── 근로소득 간이세액표(소득세법 시행령 [별표 2], 2026. 2. 27. 개정 — 2026. 3. 1. 이후 지급분) ──
 * 표의 칸은 월급여액(비과세·학자금 뺀 금액) 구간 × 공제대상가족 수(본인 포함 1~11명)이고, 별표 주석대로 근로소득공제·기본공제·특별소득공제 등
 * 일부·연금보험료공제·근로소득세액공제와 기본세율을 반영해 계산한 금액이다. 여기서는 표를 통째로 싣지 않고 그 계산을 그대로 다시 한다:
 *  - 구간: 770천~1,500천 원은 5천 원, ~3,000천 원은 1만 원, ~10,000천 원은 2만 원 폭(이상~미만). 구간의 가운데 값 × 12가 연간 총급여.
 *  - 특별소득공제 등(별표 주석 1)은 가족 수(1명·2명·3명 이상)와 총급여 구간마다의 식, 3명 이상은 4천만 원 넘는 금액의 4%를 더한다.
 *  - 표에 들어 있는 국민연금(4.5%, 기준소득월액 상한 449만 원 — 천 원 미만 버림)과 근로소득세액공제(산출세액 50만 원 기준 55%·30%, 한도
 *    66만·63만·50만 원)는 지금 법과 다른 **표를 만들 때의 값**이다 — 지금 값으로 바꾸면 표와 달라진다(연말정산 어림은 지금 법을 쓴다).
 *  - 칸 값은 월 결정세액(연 결정세액 ÷ 12)의 10원 미만을 버리고, 1,000원 미만은 0(소득세법 제86조 소액부징수).
 *  - 10,000천 원 초과는 별표 끝의 식(10,000천 원 칸 + 초과 금액 × 98% × 35% … 45%), 11명 초과는 주석 4(11명 − (10명 − 11명) × 초과 인원).
 *  - 8세 이상 20세 이하 자녀(공제대상가족에 들어간 자녀)는 주석 3대로 칸 값에서 뺀다 — 2026. 3. 1. 지급분부터 1명 20,830원, 2명 45,830원,
 *    3명 이상 45,830원 + 2명 넘는 1명마다 33,330원(그 전 지급분은 12,500원·29,160원·25,000원). 빼서 0보다 적으면 0.
 *  - 근로자가 원천징수세액을 80%·120%로 신청하면(시행령 제194조) 자녀를 뺀 금액에 그 비율을 곱하고 10원 미만을 버린다.
 *  - 지방소득세(개인지방소득세 특별징수) = 소득세 × 10%, 10원 미만 버림.
 * 이 계산은 별표의 647구간 × 11명(7,117칸) 모두와 맞는다(시험에서 확인). 금액은 원 단위 정수.
 */

/** 가족 수 입력 상한(본인 포함). */
export const TAX_FAMILY_MAX = 20;
/** 원천징수 비율(%) — 시행령 제194조. */
export const WITHHOLDING_RATIOS = Object.freeze([80, 100, 120]);

// 실수 곱셈으로 10원 배수에 꼭 떨어지는 칸이 9.9999…로 깎이지 않게 아주 작은 값을 더한 뒤 버린다.
const EPS = 1e-7;
export const floor10 = (x) => Math.floor(x / 10 + EPS) * 10;

/** 근로소득공제(소득세법 제47조) — 총급여 [g]원. 2,000만 원 한도. */
export function earnedIncomeDeduction(g) {
  let d;
  if (g <= 5_000_000) d = g * 0.7;
  else if (g <= 15_000_000) d = 3_500_000 + (g - 5_000_000) * 0.4;
  else if (g <= 45_000_000) d = 7_500_000 + (g - 15_000_000) * 0.15;
  else if (g <= 100_000_000) d = 12_000_000 + (g - 45_000_000) * 0.05;
  else d = 14_750_000 + (g - 100_000_000) * 0.02;
  return Math.min(d, 20_000_000);
}

/** 종합소득 기본세율(소득세법 제55조 — 2023년 이후) — 과세표준 [t]원의 산출세액. */
export function basicTax(t) {
  if (t <= 0) return 0;
  const brackets = [
    [14_000_000, 0, 0.06, 0],
    [50_000_000, 840_000, 0.15, 14_000_000],
    [88_000_000, 6_240_000, 0.24, 50_000_000],
    [150_000_000, 15_360_000, 0.35, 88_000_000],
    [300_000_000, 37_060_000, 0.38, 150_000_000],
    [500_000_000, 94_060_000, 0.4, 300_000_000],
    [1_000_000_000, 174_060_000, 0.42, 500_000_000],
    [Infinity, 384_060_000, 0.45, 1_000_000_000],
  ];
  for (const [upTo, base, rate, from] of brackets) if (t <= upTo) return base + (t - from) * rate;
  return 0;
}

/** 간이세액표의 특별소득공제 등(별표 주석 1) — 총급여 [g], 가족 [n]명. */
function tableSpecialDeduction(g, n) {
  const [a, r] = n === 1 ? [3_100_000, [0.04, 0.04, 0.015, 0.005]] : n === 2 ? [3_600_000, [0.04, 0.04, 0.02, 0.01]] : [5_000_000, [0.07, 0.07, 0.05, 0.03]];
  let s;
  if (g <= 30_000_000) s = a + g * r[0];
  else if (g <= 45_000_000) s = a + g * r[1] - (g - 30_000_000) * 0.05;
  else if (g <= 70_000_000) s = a + g * r[2];
  else s = a + g * r[3];
  if (n >= 3 && g > 40_000_000) s += (g - 40_000_000) * 0.04;
  return s;
}

/** 간이세액표 칸 하나 — 구간 가운데 월급여 [mid]원, 가족 [n]명(1~11). */
function tableCell(mid, n) {
  const g = mid * 12;
  const pensionBase = Math.min(4_490_000, Math.max(290_000, Math.floor(mid / 1000) * 1000));
  const pension = Math.floor((pensionBase * 0.045) / 10 + EPS) * 10 * 12;
  const base = Math.max(g - earnedIncomeDeduction(g) - 1_500_000 * n - pension - tableSpecialDeduction(g, n), 0);
  const tax = basicTax(base);
  const credit = tax <= 500_000 ? tax * 0.55 : 275_000 + (tax - 500_000) * 0.3;
  const limit = g <= 55_000_000 ? 660_000 : g <= 70_000_000 ? Math.max(630_000, 660_000 - (g - 55_000_000) / 2) : Math.max(500_000, 630_000 - (g - 70_000_000) / 2);
  const monthly = floor10(Math.max(tax - Math.min(credit, limit), 0) / 12);
  return monthly < 1000 ? 0 : monthly;
}

/** 월급여 [w]원이 든 간이세액표 구간 `{ lo, hi }`(천 원 — 이상~미만). 770천 원 미만은 null, 10,000천 원 이상은 `{ lo: 10000, hi: null }`. */
export function tableBracket(w) {
  const k = Math.floor(w / 1000);
  if (k < 770) return null;
  if (k >= 10_000) return { lo: 10_000, hi: null };
  const [start, width] = k < 1500 ? [770, 5] : k < 3000 ? [1500, 10] : [3000, 20];
  const lo = start + Math.floor((k - start) / width) * width;
  return { lo, hi: lo + width };
}

/** 간이세액표의 "해당란 세액" — 월급여 [w]원(비과세 뺀), 공제대상가족 [n]명(본인 포함). 자녀·비율은 반영하지 않은 값. */
export function simplifiedTableTax(w, n) {
  const family = Math.max(1, Math.floor(n));
  if (family > 11) {
    const t11 = simplifiedTableTax(w, 11);
    const t10 = simplifiedTableTax(w, 10);
    return Math.max(0, t11 - (t10 - t11) * (family - 11));
  }
  const bracket = tableBracket(w);
  if (!bracket) return 0;
  if (bracket.hi !== null) return tableCell(((bracket.lo + bracket.hi) / 2) * 1000, family);
  const t10 = tableCell(10_000_000, family);
  if (w <= 10_000_000) return t10;
  let add;
  if (w <= 14_000_000) add = (w - 10_000_000) * 0.98 * 0.35 + 25_000;
  else if (w <= 28_000_000) add = 1_397_000 + (w - 14_000_000) * 0.98 * 0.38;
  else if (w <= 30_000_000) add = 6_610_600 + (w - 28_000_000) * 0.98 * 0.4;
  else if (w <= 45_000_000) add = 7_394_600 + (w - 30_000_000) * 0.4;
  else if (w <= 87_000_000) add = 13_394_600 + (w - 45_000_000) * 0.42;
  else add = 31_034_600 + (w - 87_000_000) * 0.45;
  return floor10(t10 + add);
}

/** 8세 이상 20세 이하 자녀 [k]명의 공제(별표 주석 3) — 지급일 [payDate](YYYY-MM-DD)가 2026-03-01 전이면 예전 금액. */
export function childTaxDeduction(k, payDate = null) {
  const kids = Math.max(0, Math.floor(k ?? 0));
  if (!kids) return 0;
  const old = typeof payDate === 'string' && payDate < '2026-03-01';
  const [one, two, more] = old ? [12_500, 29_160, 25_000] : [20_830, 45_830, 33_330];
  return kids === 1 ? one : two + (kids - 2) * more;
}

/**
 * 사람마다의 원천징수 정보(급여 설정) — `{ dependents(공제대상가족 — 본인 포함), children(그중 8~20세 자녀), ratio(80|100|120), auto }`.
 * auto: false면 소득세를 계산하지 않는다(직접 넣는 사람 — 일용직·외국인 단일세율 등). 비우면 본인 1명·100%(신고서를 내지 않은 사람).
 */
export function parseTaxProfile(input) {
  if (input === null || input === undefined) return { profile: null };
  if (typeof input !== 'object') return { error: '원천징수 정보를 확인하세요.' };
  const dependents = input.dependents === undefined || input.dependents === null || input.dependents === '' ? 1 : Number(input.dependents);
  if (!Number.isInteger(dependents) || dependents < 1 || dependents > TAX_FAMILY_MAX) {
    return { error: `공제대상가족 수는 본인을 넣어 1~${TAX_FAMILY_MAX}명입니다.` };
  }
  const children = input.children === undefined || input.children === null || input.children === '' ? 0 : Number(input.children);
  if (!Number.isInteger(children) || children < 0 || children >= dependents) {
    return { error: '8~20세 자녀 수는 공제대상가족 수보다 적어야 합니다(본인 포함이므로).' };
  }
  const ratio = input.ratio === undefined || input.ratio === null || input.ratio === '' ? 100 : Number(input.ratio);
  if (!WITHHOLDING_RATIOS.includes(ratio)) return { error: '원천징수 비율은 80%·100%·120% 중 하나입니다.' };
  const profile = { dependents, children, ratio, ...(input.auto === false && { auto: false }) };
  // 기본값(본인 1명·자녀 없음·100%·자동)이면 저장하지 않는다.
  return { profile: dependents === 1 && children === 0 && ratio === 100 && input.auto !== false ? null : profile };
}

/** 원천징수 정보 표 `{ userId: profile }` → 저장할 값 | `{ error }`. [current]에 덮는다(null·빈 값은 지운다). */
export function parseTaxProfiles(input, current = {}) {
  if (input === undefined) return { taxProfiles: undefined };
  if (!input || typeof input !== 'object' || Array.isArray(input)) return { error: '원천징수 정보를 확인하세요.' };
  const out = { ...(current ?? {}) };
  for (const [userId, raw] of Object.entries(input)) {
    const p = parseTaxProfile(raw);
    if (p.error) return p;
    if (p.profile) out[userId] = p.profile;
    else delete out[userId];
  }
  return { taxProfiles: out };
}

const WON = '원';
const won = (n) => Math.round(n).toLocaleString('ko-KR') + WON;

/**
 * 한 달 원천징수 — 과세 대상 월급여 [taxable]원(지급 총액 − 비과세)과 원천징수 정보 [profile], 지급일 [payDate]로
 * `{ incomeTax, localTax, tableTax, childDeduction, basis }`. basis는 명세서의 "계산 방법" 칸에 넣는 글.
 */
export function monthlyWithholding(taxable, profile = null, { payDate = null, localRate = 10 } = {}) {
  const w = Math.max(0, Math.floor(taxable ?? 0));
  const dependents = profile?.dependents ?? 1;
  const children = profile?.children ?? 0;
  const ratio = profile?.ratio ?? 100;
  const tableTax = simplifiedTableTax(w, dependents);
  const childDeduction = Math.min(tableTax, childTaxDeduction(children, payDate));
  let incomeTax = floor10((Math.max(0, tableTax - childTaxDeduction(children, payDate)) * ratio) / 100);
  if (incomeTax < 1000) incomeTax = 0;
  const localTax = floor10((incomeTax * localRate) / 100);
  const parts = [`간이세액표 ${won(w)}`, `가족 ${dependents}명`];
  if (children) parts.push(`8~20세 자녀 ${children}명`);
  if (ratio !== 100) parts.push(`${ratio}%`);
  return { incomeTax, localTax, tableTax, childDeduction, basis: parts.join(' · ') };
}

// ── 연말정산 어림(참고용 — 지금 법) ──

/** 근로소득세액공제(소득세법 제59조 — 지금 법) — 산출세액 [tax], 총급여 [g]. */
export function earnedIncomeTaxCredit(tax, g) {
  const credit = tax <= 1_300_000 ? tax * 0.55 : 715_000 + (tax - 1_300_000) * 0.3;
  let limit;
  if (g <= 33_000_000) limit = 740_000;
  else if (g <= 70_000_000) limit = Math.max(660_000, 740_000 - (g - 33_000_000) * 0.008);
  else if (g <= 120_000_000) limit = Math.max(500_000, 660_000 - (g - 70_000_000) / 2);
  else limit = Math.max(200_000, 500_000 - (g - 120_000_000) / 2);
  return Math.floor(Math.min(credit, limit));
}

/** 자녀세액공제(소득세법 제59조의2 — 2025년 귀속부터) — 8세 이상 자녀 [k]명: 1명 25만, 2명 55만, 3명 이상 55만 + 1명마다 40만 원. */
export function childTaxCredit(k) {
  const kids = Math.max(0, Math.floor(k ?? 0));
  if (!kids) return 0;
  return kids === 1 ? 250_000 : 550_000 + (kids - 2) * 400_000;
}

/**
 * 연말정산 어림(참고용) — 한 해 동안 보낸 명세서의 합계로 결정세액을 어림한다. [year]는 `{ taxable(총급여 — 비과세 뺀), pension(국민연금
 * 낸 것), insurance(건강·장기요양·고용보험 낸 것), withheldIncomeTax, withheldLocalTax }`, [profile]은 원천징수 정보(가족·자녀).
 * 근로소득공제 → 기본공제(150만 원 × 가족) → 연금보험료공제 → 특별소득공제(보험료) 또는 표준세액공제(13만 원) 중 세금이 적은 쪽 → 기본세율 →
 * 근로소득세액공제·자녀세액공제. 의료비·교육비·기부금·신용카드·주택자금·연금저축 같은 공제는 간소화 자료가 있어야 해서 넣지 않는다.
 * `{ grossIncome, earnedDeduction, earnedIncome, personal, pension, insurance, useStandard, taxBase, computedTax, earnedCredit, childCredit,
 *    standardCredit, decidedTax, decidedLocalTax, withheldIncomeTax, withheldLocalTax, diffIncomeTax, diffLocalTax }` — diff가 양수면 더 낼
 * 세금(추징), 음수면 돌려받을 세금(환급). 10원 미만은 버린다.
 */
export function yearEndEstimate(year, profile = null) {
  const g = Math.max(0, Math.floor(year?.taxable ?? 0));
  const dependents = profile?.dependents ?? 1;
  const children = profile?.children ?? 0;
  const earnedDeduction = Math.floor(earnedIncomeDeduction(g));
  const earnedIncome = Math.max(0, g - earnedDeduction);
  const personal = 1_500_000 * dependents;
  const pension = Math.max(0, Math.floor(year?.pension ?? 0));
  const insurance = Math.max(0, Math.floor(year?.insurance ?? 0));
  const decide = (withInsurance) => {
    const taxBase = Math.max(0, earnedIncome - personal - pension - (withInsurance ? insurance : 0));
    const computedTax = Math.floor(basicTax(taxBase));
    const earnedCredit = Math.min(computedTax, earnedIncomeTaxCredit(computedTax, g));
    const childCredit = Math.min(computedTax - earnedCredit, childTaxCredit(children));
    const standardCredit = withInsurance ? 0 : Math.min(computedTax - earnedCredit - childCredit, 130_000);
    const decidedTax = floor10(Math.max(0, computedTax - earnedCredit - childCredit - standardCredit));
    return { taxBase, computedTax, earnedCredit, childCredit, standardCredit, decidedTax };
  };
  const withIns = decide(true);
  const standard = decide(false);
  const useStandard = standard.decidedTax < withIns.decidedTax;
  const best = useStandard ? standard : withIns;
  const decidedLocalTax = floor10(best.decidedTax * 0.1);
  const withheldIncomeTax = Math.floor(year?.withheldIncomeTax ?? 0);
  const withheldLocalTax = Math.floor(year?.withheldLocalTax ?? 0);
  // 차감징수세액도 10원 미만은 버린다(환급은 음수 — 버린 쪽으로).
  const trunc10 = (n) => (n >= 0 ? floor10(n) : -floor10(-n));
  return {
    grossIncome: g,
    earnedDeduction,
    earnedIncome,
    personal,
    pension,
    insurance: useStandard ? 0 : insurance,
    useStandard,
    ...best,
    decidedLocalTax,
    withheldIncomeTax,
    withheldLocalTax,
    diffIncomeTax: trunc10(best.decidedTax - withheldIncomeTax),
    diffLocalTax: trunc10(decidedLocalTax - withheldLocalTax),
  };
}
