import assert from 'node:assert/strict';
import test from 'node:test';
import { yearEndEstimate } from '../src/incomeTaxRules.js';
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
