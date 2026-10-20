/**
 * 연말정산 공제 자료(소득·세액공제 신고서 — 홈택스 간소화 자료의 합계를 사람이 옮겨 적은 것)의 순수 규칙 — 입력 읽기와, 그 자료로 넣는
 * 소득공제·세액공제 계산. 연말정산 어림(incomeTaxRules.js yearEndEstimate)이 쓴다. DB 없이 `node --test`로 시험한다(test/yearEndClaims.test.js).
 *
 * 금액은 모두 그해(귀속 연도) 합계·원 단위 정수다. 간소화 PDF를 직접 읽지는 않는다(국세청 모듈이 있어야 함) — 근로자·담당자가 간소화 자료의
 * 항목별 합계를 넣는다. 법 값은 2025년 귀속(2026년 초 정산) 기준이고, 귀속 연도마다 달라지는 것(고향사랑기부금 한도·결혼세액공제 기간)만 연도로
 * 가른다. 해마다 세법 개정으로 바뀌므로 참고용 어림이다 — 실제 정산은 세무 프로그램·홈택스 편리한 연말정산으로 한다.
 *
 *  - 인적공제 추가공제(소득세법 제51조): 경로우대(70세 이상) 1명 100만, 장애인 1명 200만, 부녀자 50만(근로소득금액 3,000만 원 이하), 한부모 100만
 *    (부녀자와 겹치면 한부모만).
 *  - 신용카드 등 소득공제(조세특례제한법 제126조의2): 최저사용금액(총급여 25%)을 신용카드 → 체크카드·현금영수증·도서공연 등 → 전통시장·대중교통
 *    순으로 빼고, 남은 금액에 15%·30%·30%·40%·40%. 기본한도 300만(총급여 7,000만 원 넘으면 250만), 추가한도(전통시장·대중교통·도서공연 등의 공제분
 *    안에서) 300만(넘으면 200만 — 도서공연 등은 빠짐). 총급여 7,000만 원 넘는 사람의 도서공연·체육시설 사용분은 신용카드 사용분으로 본다.
 *  - 주택자금(제52조 ④⑤, 조특법 제87조): 주택임차차입금 원리금 상환액 40%, 주택청약종합저축 납입액(연 300만 원까지 — 총급여 7,000만 원 이하) 40%,
 *    둘을 합해 400만 원 한도. 장기주택저당차입금 이자는 고른 한도(600·800·1,800·2,000만 원 — 상환 방식·기간)까지, 앞의 둘과 합해서도 그 한도.
 *  - 연금계좌 세액공제(제59조의3): 연금저축 600만 원 + 퇴직연금 합쳐 900만 원까지, 총급여 5,500만 원 이하 15% · 넘으면 12%.
 *  - 보장성보험료(제59조의4 ①): 일반 100만 원까지 12%, 장애인전용 100만 원까지 15%.
 *  - 의료비(제59조의4 ②): 총급여 3%를 넘는 금액 — 그 밖의 가족 의료비에서 먼저 빼고, 모자라면 본인 등(본인·65세 이상·장애인·6세 이하·
 *    건강보험 산정특례자) → 미숙아·선천성이상아 → 난임 시술비 순으로 뺀다. 그 밖의 가족 의료비는 700만 원까지. 15%(미숙아 등 20%, 난임 30%).
 *  - 교육비(제59조의4 ③): 15% — 본인(대학원 포함)·장애인 특수교육비는 한도 없음, 취학 전·초중고 1명 300만, 대학생 1명 900만.
 *  - 기부금(제59조의4 ④, 조특법 제76조·제58조): 정치자금·고향사랑기부금은 10만 원까지 100/110, 넘는 금액은 15%(정치자금 3,000만 원 넘으면 25%).
 *    고향사랑기부금은 2,000만 원(2024년 귀속까지 500만)까지. 특례기부금은 근로소득금액까지, 일반기부금은 (근로소득금액 − 특례) × 30%(종교 단체
 *    기부금이 있으면 × 10% + min(× 20%, 종교 단체 외)) 까지. 특례·일반을 합해 1,000만 원까지 15%, 넘는 금액 30%.
 *  - 월세 세액공제(조특법 제95조의2): 총급여 8,000만 원 이하, 연 1,000만 원까지 — 5,500만 원 이하 17%, 넘으면 15%.
 *  - 결혼세액공제(제59조의2 — 2024~2026년 혼인신고, 생애 한 번) 50만 원. 출산·입양 세액공제: 첫째 30만·둘째 50만·셋째 이상 70만 원.
 *  - 그 밖의 소득공제·세액공제는 직접 넣는다(우리사주·벤처투자·소비 증가분·주택자금차입금이자 세액공제·외국납부 등 — 여기서 계산하지 않음).
 *  - 표준세액공제(13만 원)를 고르면 건강·고용보험료와 주택임차·저당 이자 공제, 보험·의료·교육·특례·일반기부금·월세 세액공제를 쓰지 못한다
 *    (신용카드·주택청약·연금계좌·정치자금·고향사랑·결혼·출산은 함께 쓴다) — 어림은 둘 중 세금이 적은 쪽을 고른다.
 */

/** 금액 칸 하나의 상한(100억 원). */
const AMOUNT_MAX = 10_000_000_000;
/** 교육비 줄 수 상한. */
export const EDUCATION_ROWS_MAX = 20;
/** 교육비 종류 — 본인, 취학 전 아동, 초·중·고, 대학생, 장애인 특수교육비. */
export const EDUCATION_KINDS = Object.freeze(['self', 'preschool', 'school', 'college', 'disabled']);
/** 장기주택저당차입금 이자 공제 한도(원) — 상환 방식·기간에 따라 고른다. */
export const MORTGAGE_LIMITS = Object.freeze([6_000_000, 8_000_000, 18_000_000, 20_000_000]);

/** 칸 이름 — 앱이 같은 이름으로 보낸다(client models/groupware_finance_tools.dart YearEndClaim). */
const GROUPS = Object.freeze({
  card: ['credit', 'debitCash', 'culture', 'sports', 'market', 'transit'],
  insurance: ['general', 'disabled'],
  medical: ['general', 'special', 'premature', 'infertility'],
  donation: ['political', 'hometown', 'special', 'general', 'religious'],
  pension: ['savings', 'retirement'],
  housing: ['rentLoan', 'subscription', 'mortgage'],
  births: ['first', 'second', 'third'],
  extraPersonal: ['elderly', 'disabled'],
});
const COUNT_FIELDS = new Set(['births', 'extraPersonal']);

const amount = (v) => {
  if (v === undefined || v === null || v === '') return 0;
  const n = Number(typeof v === 'string' ? v.replace(/[,\s원]/g, '') : v);
  return Number.isInteger(n) && n >= 0 && n <= AMOUNT_MAX ? n : undefined;
};
const count = (v) => {
  if (v === undefined || v === null || v === '') return 0;
  const n = Number(v);
  return Number.isInteger(n) && n >= 0 && n <= 20 ? n : undefined;
};

/**
 * 공제 자료 입력 → `{ claim }` | `{ error }`. 비어 있는 칸은 0으로 두고, 모두 0이면 `{ claim: null }`(지운다).
 * `{ card: {credit, debitCash, culture, sports, market, transit}, insurance: {general, disabled}, medical: {general, special, premature,
 *    infertility}, education: [{ kind, amount }], donation: {political, hometown, special, general, religious}, pension: {savings, retirement},
 *    housing: {rentLoan, subscription, mortgage, mortgageLimit}, monthlyRent, marriage, births: {first, second, third},
 *    extraPersonal: {elderly, disabled, woman, singleParent}, otherDeduction, otherCredit, memo }`.
 */
export function parseYearEndClaim(input) {
  if (input === null || input === undefined) return { claim: null };
  if (typeof input !== 'object' || Array.isArray(input)) return { error: '공제 자료를 확인하세요.' };
  const out = {};
  let any = false;
  for (const [group, fields] of Object.entries(GROUPS)) {
    const src = input[group] ?? {};
    if (typeof src !== 'object' || Array.isArray(src)) return { error: '공제 자료를 확인하세요.' };
    const g = {};
    for (const f of fields) {
      const v = COUNT_FIELDS.has(group) ? count(src[f]) : amount(src[f]);
      if (v === undefined) return { error: COUNT_FIELDS.has(group) ? '사람 수는 0~20명입니다.' : '금액은 0원 이상의 원 단위 정수로 넣으세요.' };
      g[f] = v;
      if (v) any = true;
    }
    out[group] = g;
  }
  // 저당차입금 이자 한도 — 비우면 가장 흔한 1,800만 원(고정금리 또는 비거치식 15년 이상).
  const limit = input.housing?.mortgageLimit === undefined || input.housing?.mortgageLimit === null || input.housing?.mortgageLimit === '' ? 18_000_000 : Number(input.housing.mortgageLimit);
  if (!MORTGAGE_LIMITS.includes(limit)) return { error: '장기주택저당차입금 이자 공제 한도를 고르세요.' };
  out.housing.mortgageLimit = limit;
  out.extraPersonal.woman = input.extraPersonal?.woman === true;
  out.extraPersonal.singleParent = input.extraPersonal?.singleParent === true;
  if (out.extraPersonal.woman || out.extraPersonal.singleParent) any = true;
  const rows = input.education ?? [];
  if (!Array.isArray(rows)) return { error: '교육비를 확인하세요.' };
  if (rows.length > EDUCATION_ROWS_MAX) return { error: `교육비는 ${EDUCATION_ROWS_MAX}줄까지입니다.` };
  out.education = [];
  for (const r of rows) {
    if (!EDUCATION_KINDS.includes(r?.kind)) return { error: '교육비 종류를 고르세요.' };
    const a = amount(r.amount);
    if (a === undefined) return { error: '금액은 0원 이상의 원 단위 정수로 넣으세요.' };
    if (a) {
      out.education.push({ kind: r.kind, amount: a });
      any = true;
    }
  }
  for (const key of ['monthlyRent', 'otherDeduction', 'otherCredit']) {
    const v = amount(input[key]);
    if (v === undefined) return { error: '금액은 0원 이상의 원 단위 정수로 넣으세요.' };
    out[key] = v;
    if (v) any = true;
  }
  out.marriage = input.marriage === true;
  if (out.marriage) any = true;
  const memo = typeof input.memo === 'string' ? input.memo.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '').trim() : '';
  if ([...memo].length > 500) return { error: '메모는 500자까지입니다.' };
  if (memo) {
    out.memo = memo;
    any = true;
  }
  return { claim: any ? out : null };
}

const rate = (x, r) => Math.floor(x * r + 1e-7);
const min = Math.min;
const max = Math.max;

/** 신용카드 등 소득공제 — 총급여 [g], 사용액 [card]. `{ deduction, raw, minimum, basicLimit, extraLimit }`. */
export function cardDeduction(g, card) {
  const c = card ?? {};
  const low = g <= 70_000_000;
  // 7,000만 원 넘는 사람의 도서공연·체육시설 사용분은 신용카드 사용분으로(어느 결제 수단인지 몰라 낮은 쪽으로 본다).
  const buckets = [
    { amount: (c.credit ?? 0) + (low ? 0 : (c.culture ?? 0) + (c.sports ?? 0)), rate: 0.15, extra: false },
    { amount: c.debitCash ?? 0, rate: 0.3, extra: false },
    { amount: low ? (c.culture ?? 0) + (c.sports ?? 0) : 0, rate: 0.3, extra: true },
    { amount: c.market ?? 0, rate: 0.4, extra: true },
    { amount: c.transit ?? 0, rate: 0.4, extra: true },
  ];
  const minimum = rate(g, 0.25);
  let left = minimum;
  let raw = 0;
  let special = 0;
  for (const b of buckets) {
    const take = min(left, b.amount);
    left -= take;
    const d = rate(b.amount - take, b.rate);
    raw += d;
    if (b.extra) special += d;
  }
  const basicLimit = low ? 3_000_000 : 2_500_000;
  const extraLimit = low ? 3_000_000 : 2_000_000;
  const deduction = min(raw, basicLimit) + min(max(0, raw - basicLimit), extraLimit, special);
  return { deduction, raw, minimum, basicLimit, extraLimit };
}

/** 주택자금 공제 — `{ rentLoan(특별소득공제), subscription(그 밖의 소득공제), mortgage(특별소득공제) }`. */
export function housingDeduction(g, housing) {
  const h = housing ?? {};
  const rentLoan = min(rate(h.rentLoan ?? 0, 0.4), 4_000_000);
  // 주택청약종합저축은 총급여 7,000만 원 이하(무주택 세대주)만, 납입 300만 원까지.
  const subscription = g <= 70_000_000 ? min(rate(min(h.subscription ?? 0, 3_000_000), 0.4), 4_000_000 - rentLoan) : 0;
  const limit = h.mortgageLimit ?? 18_000_000;
  const mortgage = h.mortgage ? max(0, min(h.mortgage, limit - rentLoan - subscription)) : 0;
  return { rentLoan, subscription, mortgage };
}

/** 의료비 세액공제 — 총급여 [g]. */
export function medicalCredit(g, medical) {
  const m = medical ?? {};
  let short = rate(g, 0.03);
  const parts = [m.general ?? 0, m.special ?? 0, m.premature ?? 0, m.infertility ?? 0];
  const after = parts.map((v) => {
    const take = min(short, v);
    short -= take;
    return v - take;
  });
  after[0] = min(after[0], 7_000_000);
  return rate(after[0] + after[1], 0.15) + rate(after[2], 0.2) + rate(after[3], 0.3);
}

/** 교육비 세액공제. */
export function educationCredit(rows) {
  const caps = { self: Infinity, disabled: Infinity, preschool: 3_000_000, school: 3_000_000, college: 9_000_000 };
  let base = 0;
  for (const r of rows ?? []) base += min(r.amount ?? 0, caps[r.kind] ?? 0);
  return rate(base, 0.15);
}

/** 10만 원까지 100/110, 넘는 금액은 [over]. */
const smallDonation = (a) => Math.floor((min(a, 100_000) * 100) / 110);

/**
 * 기부금 세액공제 — 근로소득금액 [earnedIncome], 귀속 [year]. `{ political, hometown, itemized }` — itemized(특례·일반)는 표준세액공제와
 * 함께 못 쓴다.
 */
export function donationCredit(earnedIncome, donation, year) {
  const d = donation ?? {};
  const political = min(d.political ?? 0, earnedIncome);
  const politicalCredit = smallDonation(political) + rate(max(0, min(political, 30_000_000) - 100_000), 0.15) + rate(max(0, political - 30_000_000), 0.25);
  const hometownMax = year >= 2025 ? 20_000_000 : 5_000_000;
  const hometown = min(d.hometown ?? 0, hometownMax, max(0, earnedIncome - political));
  const hometownCredit = smallDonation(hometown) + rate(max(0, hometown - 100_000), 0.15);
  const base = max(0, earnedIncome - political - hometown);
  const special = min(d.special ?? 0, base);
  const rest = base - special;
  const religious = d.religious ?? 0;
  const nonReligious = d.general ?? 0;
  const general = religious
    ? min(nonReligious + religious, rate(rest, 0.1) + min(rate(rest, 0.2), nonReligious))
    : min(nonReligious, rate(rest, 0.3));
  const total = special + general;
  const itemized = rate(min(total, 10_000_000), 0.15) + rate(max(0, total - 10_000_000), 0.3);
  return { political: politicalCredit, hometown: hometownCredit, itemized };
}

/** 연금계좌 세액공제. */
export function pensionAccountCredit(g, pension) {
  const p = pension ?? {};
  const base = min(min(p.savings ?? 0, 6_000_000) + (p.retirement ?? 0), 9_000_000);
  return rate(base, g <= 55_000_000 ? 0.15 : 0.12);
}

/** 보장성보험료 세액공제. */
export const insuranceCredit = (ins) => rate(min(ins?.general ?? 0, 1_000_000), 0.12) + rate(min(ins?.disabled ?? 0, 1_000_000), 0.15);

/** 월세 세액공제 — 총급여 8,000만 원 이하. */
export const monthlyRentCredit = (g, rent) => (g <= 80_000_000 ? rate(min(rent ?? 0, 10_000_000), g <= 55_000_000 ? 0.17 : 0.15) : 0);

/** 출산·입양 세액공제 — 그해 태어난(입양한) 자녀의 순서별 수. */
export const birthCredit = (b) => (b?.first ?? 0) * 300_000 + (b?.second ?? 0) * 500_000 + (b?.third ?? 0) * 700_000;

/** 인적공제 추가공제 — 근로소득금액 [earnedIncome]. */
export function extraPersonalDeduction(earnedIncome, extra) {
  const e = extra ?? {};
  const woman = !e.singleParent && e.woman && earnedIncome <= 30_000_000 ? 500_000 : 0;
  return (e.elderly ?? 0) * 1_000_000 + (e.disabled ?? 0) * 2_000_000 + woman + (e.singleParent ? 1_000_000 : 0);
}

/**
 * 공제 자료로 넣는 공제들 — 총급여 [g], 근로소득금액 [earnedIncome], 귀속 [year]. 표준세액공제와 함께 쓸 수 있는지에 따라 나눈다:
 * `{ deductions: { extraPersonal, card, subscription, other, rentLoan, mortgage }, credits: { pensionAccount, political, hometown, marriage,
 *    births, other, insurance, medical, education, donation, monthlyRent }, itemizedDeductions, itemizedCredits, commonDeductions, commonCredits }`.
 * itemized*는 특별소득공제·특별세액공제·월세(표준세액공제를 고르면 빠짐), common*은 늘 넣는다.
 */
export function claimAllowances(g, earnedIncome, claim, year) {
  const c = claim ?? {};
  const housing = housingDeduction(g, c.housing);
  const donation = donationCredit(earnedIncome, c.donation, year);
  const deductions = {
    extraPersonal: extraPersonalDeduction(earnedIncome, c.extraPersonal),
    card: cardDeduction(g, c.card).deduction,
    subscription: housing.subscription,
    other: c.otherDeduction ?? 0,
    rentLoan: housing.rentLoan,
    mortgage: housing.mortgage,
  };
  const credits = {
    pensionAccount: pensionAccountCredit(g, c.pension),
    political: donation.political,
    hometown: donation.hometown,
    marriage: c.marriage && year >= 2024 && year <= 2026 ? 500_000 : 0,
    births: birthCredit(c.births),
    other: c.otherCredit ?? 0,
    insurance: insuranceCredit(c.insurance),
    medical: medicalCredit(g, c.medical),
    education: educationCredit(c.education),
    donation: donation.itemized,
    monthlyRent: monthlyRentCredit(g, c.monthlyRent),
  };
  return {
    deductions,
    credits,
    commonDeductions: deductions.extraPersonal + deductions.card + deductions.subscription + deductions.other,
    itemizedDeductions: deductions.rentLoan + deductions.mortgage,
    commonCredits: credits.pensionAccount + credits.political + credits.hometown + credits.marriage + credits.births + credits.other,
    itemizedCredits: credits.insurance + credits.medical + credits.education + credits.donation + credits.monthlyRent,
  };
}
