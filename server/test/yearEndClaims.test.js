import assert from 'node:assert/strict';
import test from 'node:test';
import { childTaxCredit, yearEndEstimate } from '../src/incomeTaxRules.js';
import {
  birthCredit,
  cardDeduction,
  claimAllowances,
  donationCredit,
  educationCredit,
  extraPersonalDeduction,
  housingDeduction,
  medicalCredit,
  monthlyRentCredit,
  parseYearEndClaim,
  pensionAccountCredit,
  taxLaw,
} from '../src/yearEndClaimRules.js';

test('공제 자료 읽기 — 빈 칸은 0, 모두 비면 null, 잘못된 값은 거절', () => {
  assert.deepEqual(parseYearEndClaim(null), { claim: null });
  assert.deepEqual(parseYearEndClaim({ card: { credit: '' } }), { claim: null });
  const ok = parseYearEndClaim({ card: { credit: '1,000,000' }, education: [{ kind: 'school', amount: 0 }, { kind: 'self', amount: 500 }], marriage: true, memo: ' 메모 ' });
  assert.equal(ok.claim.card.credit, 1_000_000);
  assert.equal(ok.claim.card.debitCash, 0);
  assert.deepEqual(ok.claim.education, [{ kind: 'self', amount: 500 }]);
  assert.equal(ok.claim.marriage, true);
  assert.equal(ok.claim.memo, '메모');
  assert.equal(ok.claim.housing.mortgageLimit, 18_000_000);
  assert.match(parseYearEndClaim({ card: { credit: -1 } }).error, /금액/);
  assert.match(parseYearEndClaim({ card: { credit: 1.5 } }).error, /금액/);
  assert.match(parseYearEndClaim({ education: [{ kind: 'x', amount: 1 }] }).error, /교육비/);
  assert.match(parseYearEndClaim({ housing: { mortgage: 1, mortgageLimit: 5 } }).error, /한도/);
  assert.match(parseYearEndClaim({ births: { first: 30 } }).error, /사람 수/);
  assert.match(parseYearEndClaim({ memo: 'x'.repeat(501) }).error, /500자/);
});

test('신용카드 등 소득공제 — 최저사용금액·공제율·기본·추가 한도', () => {
  // 총급여 5,000만: 최저 1,250만은 신용카드에서 — (750만 × 15%) + 500만 × 30% + 100만 × 40% + 50만 × 40% = 322.5만 → 300만 + 추가 22.5만.
  const a = cardDeduction(50_000_000, { credit: 20_000_000, debitCash: 5_000_000, market: 1_000_000, transit: 500_000 });
  assert.equal(a.minimum, 12_500_000);
  assert.equal(a.raw, 3_225_000);
  assert.equal(a.deduction, 3_225_000);
  // 추가한도는 전통시장·대중교통·도서공연 공제분 안에서만: 총급여 3,000만 — 기본 300만 + min(230만, 300만, 80만).
  assert.equal(cardDeduction(30_000_000, { credit: 7_500_000, debitCash: 15_000_000, market: 2_000_000 }).deduction, 3_800_000);
  // 7,000만 넘으면 도서공연 사용분은 신용카드로(15%), 기본한도 250만.
  assert.equal(cardDeduction(80_000_000, { credit: 30_000_000, culture: 1_000_000 }).deduction, 1_650_000);
  assert.equal(cardDeduction(80_000_000, { debitCash: 40_000_000 }).deduction, 2_500_000);
  // 최저사용금액을 넘지 못하면 0.
  assert.equal(cardDeduction(50_000_000, { credit: 10_000_000 }).deduction, 0);
});

test('주택자금·의료비·교육비·기부금·연금계좌·월세·출산·추가공제', () => {
  assert.deepEqual(housingDeduction(50_000_000, { rentLoan: 12_000_000, subscription: 3_000_000, mortgage: 10_000_000, mortgageLimit: 18_000_000 }), {
    rentLoan: 4_000_000,
    subscription: 0,
    mortgage: 10_000_000,
  });
  assert.deepEqual(housingDeduction(50_000_000, { subscription: 5_000_000 }), { rentLoan: 0, subscription: 1_200_000, mortgage: 0 });
  // 총급여 7,000만 넘으면 주택청약 공제 없음.
  assert.equal(housingDeduction(80_000_000, { subscription: 3_000_000 }).subscription, 0);
  assert.equal(housingDeduction(50_000_000, { mortgage: 30_000_000, mortgageLimit: 6_000_000 }).mortgage, 6_000_000);

  // 3%(120만) — 그 밖의 가족 100만을 다 쓰고 모자란 20만을 본인 등에서. 280만 × 15% + 난임 100만 × 30%.
  assert.equal(medicalCredit(40_000_000, { general: 1_000_000, special: 3_000_000, infertility: 1_000_000 }), 720_000);
  // 그 밖의 가족은 700만까지.
  assert.equal(medicalCredit(10_000_000, { general: 10_300_000 }), 1_050_000);
  assert.equal(medicalCredit(40_000_000, { premature: 2_200_000 }), 200_000);

  assert.equal(
    educationCredit([
      { kind: 'self', amount: 5_000_000 },
      { kind: 'school', amount: 4_000_000 },
      { kind: 'college', amount: 10_000_000 },
    ]),
    2_550_000,
  );

  // 정치자금 20만: 10만 × 100/110 + 10만 × 15%. 고향사랑 10만. 일반 200만 × 15%.
  assert.deepEqual(donationCredit(30_000_000, { political: 200_000, hometown: 100_000, general: 2_000_000 }, 2025), {
    political: 105_909,
    hometown: 90_909,
    itemized: 300_000,
  });
  // 종교 단체 기부금이 있으면 한도 = 소득 × 10% + min(× 20%, 종교 외) — 200만 + 100만.
  assert.equal(donationCredit(20_000_000, { religious: 3_000_000, general: 1_000_000 }, 2025).itemized, 450_000);
  // 1,000만 넘는 금액은 30%.
  assert.equal(donationCredit(100_000_000, { special: 12_000_000 }, 2025).itemized, 2_100_000);
  // 고향사랑 한도 — 2025년 귀속부터 2,000만(그 전 500만).
  assert.equal(donationCredit(100_000_000, { hometown: 10_000_000 }, 2024).hometown, 90_909 + 735_000);
  assert.equal(donationCredit(100_000_000, { hometown: 10_000_000 }, 2025).hometown, 90_909 + 1_485_000);

  assert.equal(pensionAccountCredit(50_000_000, { savings: 7_000_000, retirement: 3_000_000 }), 1_350_000);
  assert.equal(pensionAccountCredit(60_000_000, { savings: 7_000_000, retirement: 3_000_000 }), 1_080_000);
  assert.equal(monthlyRentCredit(50_000_000, 12_000_000), 1_700_000);
  assert.equal(monthlyRentCredit(70_000_000, 6_000_000), 900_000);
  assert.equal(monthlyRentCredit(90_000_000, 6_000_000), 0);
  assert.equal(birthCredit({ first: 1, third: 1 }), 1_000_000);
  assert.equal(extraPersonalDeduction(20_000_000, { elderly: 1, disabled: 1, woman: true }), 3_500_000);
  // 한부모와 부녀자는 한부모만, 근로소득금액 3,000만 넘으면 부녀자 없음.
  assert.equal(extraPersonalDeduction(20_000_000, { woman: true, singleParent: true }), 1_000_000);
  assert.equal(extraPersonalDeduction(40_000_000, { woman: true }), 0);
});

test('결혼세액공제는 2024~2026년 귀속만, 표준세액공제와 함께 쓰는 것과 아닌 것', () => {
  const claim = parseYearEndClaim({ marriage: true, insurance: { general: 1_000_000 }, pension: { savings: 1_000_000 } }).claim;
  const a = claimAllowances(50_000_000, 37_750_000, claim, 2025);
  assert.equal(a.credits.marriage, 500_000);
  assert.equal(a.commonCredits, 500_000 + 150_000);
  assert.equal(a.itemizedCredits, 120_000);
  assert.equal(claimAllowances(50_000_000, 37_750_000, claim, 2027).credits.marriage, 0);
});

test('연말정산 어림 — 공제 자료가 없으면 예전 계산 그대로, 있으면 공제를 더하고 유리한 쪽을 고른다', () => {
  const year = { taxable: 50_000_000, pension: 2_250_000, insurance: 1_800_000, withheldIncomeTax: 2_000_000, withheldLocalTax: 200_000 };
  const base = yearEndEstimate(year, { dependents: 2 });
  assert.equal(base.claim, undefined);
  assert.equal(base.claimCredit, 0);
  assert.equal(yearEndEstimate(year, { dependents: 2 }, { claim: null }).decidedTax, base.decidedTax);

  // 신용카드 공제로 과세표준이 줄고, 연금계좌 세액공제(300만 × 15%)가 빠진다.
  const claim = parseYearEndClaim({ card: { credit: 20_000_000, debitCash: 5_000_000 }, pension: { savings: 3_000_000 } }).claim;
  const est = yearEndEstimate(year, { dependents: 2 }, { claim, taxYear: 2025 });
  assert.equal(est.claim.deductions.card, 2_625_000);
  assert.equal(est.taxBase, base.taxBase - 2_625_000);
  assert.equal(est.claim.credits.pensionAccount, 450_000);
  assert.ok(est.decidedTax < base.decidedTax);
  assert.equal(est.diffIncomeTax, est.decidedTax - 2_000_000 - ((est.decidedTax - 2_000_000) % 10));

  // 특별세액공제가 표준세액공제(13만)보다 적으면 표준을 고르고, 그때 의료비 공제는 0으로 보인다.
  const small = parseYearEndClaim({ medical: { general: 1_600_000 } }).claim;
  const s = yearEndEstimate({ taxable: 50_000_000, pension: 0, insurance: 0, withheldIncomeTax: 0 }, null, { claim: small, taxYear: 2025 });
  assert.equal(s.useStandard, true);
  assert.equal(s.standardCredit, 130_000);
  assert.equal(s.claim.credits.medical, 0);

  // 세액공제는 산출세액을 넘지 못한다.
  const big = parseYearEndClaim({ otherCredit: 100_000_000 }).claim;
  assert.equal(yearEndEstimate(year, null, { claim: big }).decidedTax, 0);
});

test('귀속 연도마다의 법 — 줄이 없는 해는 가까운 해를 빌리고 assumed로 알린다', () => {
  assert.deepEqual([taxLaw(2025).year, taxLaw(2025).assumed], [2025, false]);
  assert.deepEqual([taxLaw(2027).year, taxLaw(2027).assumed], [2026, true]);
  assert.deepEqual([taxLaw(2023).year, taxLaw(2023).assumed], [2024, true]);
  assert.equal(taxLaw(null).year, 2025);
  // 자녀세액공제 — 2024년 귀속 15만·35만·30만, 2025년부터 25만·55만·40만.
  assert.equal(childTaxCredit(1, 2024), 150_000);
  assert.equal(childTaxCredit(3, 2024), 650_000);
  assert.equal(childTaxCredit(2, 2025), 550_000);
  assert.equal(childTaxCredit(3, 2026), 950_000);
});

test('공제 자료 읽기 — 카드 한도 자녀등 수·지난해 사용액·종합한도 밖 소득공제', () => {
  const ok = parseYearEndClaim({ cardChildren: 2, cardPrevious: '15,000,000', otherDeductionExempt: 1_000 }).claim;
  assert.equal(ok.cardChildren, 2);
  assert.equal(ok.cardPrevious, 15_000_000);
  assert.equal(ok.otherDeductionExempt, 1_000);
  // 이 칸들만 있어도 자료로 남는다.
  assert.notEqual(parseYearEndClaim({ cardChildren: 1 }).claim, null);
  assert.match(parseYearEndClaim({ cardChildren: 21 }).error, /사람 수/);
  assert.match(parseYearEndClaim({ cardPrevious: -1 }).error, /금액/);
});

test('신용카드 등 — 2026년 귀속부터 자녀등 수로 기본한도가 늘어난다(2명까지)', () => {
  const card = { credit: 20_000_000, debitCash: 15_000_000 }; // 공제 전 금액 562.5만
  assert.equal(cardDeduction(50_000_000, card, { year: 2025, children: 2 }).deduction, 3_000_000);
  assert.equal(cardDeduction(50_000_000, card, { year: 2026, children: 1 }).deduction, 3_500_000);
  assert.equal(cardDeduction(50_000_000, card, { year: 2026, children: 2 }).deduction, 4_000_000);
  assert.equal(cardDeduction(50_000_000, card, { year: 2026, children: 3 }).basicLimit, 4_000_000);
  // 총급여 7,000만 원 넘으면 1명마다 25만 원.
  const high = { credit: 40_000_000, debitCash: 20_000_000 };
  assert.equal(cardDeduction(80_000_000, high, { year: 2026, children: 1 }).deduction, 2_750_000);
  assert.equal(cardDeduction(80_000_000, high, { year: 2026, children: 2 }).deduction, 3_000_000);
});

test('신용카드 등 — 2024년 귀속 소비 증가분(지난해 × 105% 넘는 금액의 10%, 추가한도 100만)', () => {
  const card = { credit: 20_000_000, debitCash: 5_000_000, market: 1_000_000 }; // 합계 2,600만, 공제 전 302.5만(전통시장 40만)
  const a = cardDeduction(50_000_000, card, { year: 2024, previous: 5_000_000 });
  assert.equal(a.growth, 2_075_000); // (2,600만 − 525만) × 10%
  // 기본 300만 + min(넘는 210만, 전통시장 40만 + 증가분 100만(한도)) = 440만.
  assert.equal(a.deduction, 4_400_000);
  assert.equal(cardDeduction(50_000_000, card, { year: 2024, previous: 15_000_000 }).deduction, 4_050_000);
  // 2025년 귀속에는 없고, 지난해를 안 넣었거나 최저사용금액을 못 넘으면 셈하지 않는다.
  assert.equal(cardDeduction(50_000_000, card, { year: 2025, previous: 5_000_000 }).deduction, 3_025_000);
  assert.equal(cardDeduction(50_000_000, card, { year: 2024 }).deduction, 3_025_000);
  assert.equal(cardDeduction(50_000_000, { credit: 10_000_000 }, { year: 2024, previous: 1_000_000 }).deduction, 0);
  // 공제 자료로도 같은 값.
  const claim = parseYearEndClaim({ card, cardPrevious: 5_000_000 }).claim;
  assert.equal(claimAllowances(50_000_000, 37_750_000, claim, 2024).deductions.card, 4_400_000);
});

test('고향사랑기부금 — 2026년 귀속부터 10만 원 넘고 20만 원까지 40%', () => {
  assert.equal(donationCredit(100_000_000, { hometown: 300_000 }, 2025).hometown, 90_909 + 30_000);
  assert.equal(donationCredit(100_000_000, { hometown: 300_000 }, 2026).hometown, 90_909 + 40_000 + 15_000);
  assert.equal(donationCredit(100_000_000, { hometown: 150_000 }, 2026).hometown, 90_909 + 20_000);
});

test('소득공제 종합한도 2,500만 원 — 주택자금·청약·카드·그 밖의 소득공제(한도 안)', () => {
  // 총급여 1억: 카드 250만(한도), 저당 이자 2,000만, 그 밖(한도 안) 500만 → 2,750만 중 250만을 뺀다. 한도 밖 100만은 그대로.
  const claim = parseYearEndClaim({
    card: { credit: 60_000_000 },
    housing: { mortgage: 20_000_000, mortgageLimit: 20_000_000 },
    otherDeduction: 5_000_000,
    otherDeductionExempt: 1_000_000,
  }).claim;
  const year = { taxable: 100_000_000, pension: 0, insurance: 0, withheldIncomeTax: 0 };
  const est = yearEndEstimate(year, null, { claim, taxYear: 2025 });
  assert.equal(est.useStandard, false);
  assert.equal(est.limitExcess, 2_500_000);
  assert.equal(est.claim.deductions.otherExempt, 1_000_000);
  // 근로소득금액 8,525만 − (기본 150만 + 카드 250만 + 그 밖 500만 + 한도 밖 100만 + 저당 2,000만 − 넘는 250만).
  assert.equal(est.taxBase, 85_250_000 - 27_500_000);
  assert.deepEqual(est.law, { year: 2025, assumed: false });
  // 한도 안이면 빼지 않는다.
  const small = parseYearEndClaim({ card: { credit: 60_000_000 }, otherDeduction: 5_000_000 }).claim;
  assert.equal(yearEndEstimate(year, null, { claim: small, taxYear: 2025 }).limitExcess, 0);
  // 공제 자료가 없어도 법의 해는 알린다.
  assert.deepEqual(yearEndEstimate(year, null, { taxYear: 2028 }).law, { year: 2026, assumed: true });
});
