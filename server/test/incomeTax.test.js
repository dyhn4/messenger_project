import assert from 'node:assert/strict';
import test from 'node:test';
import {
  basicTax,
  childTaxCredit,
  childTaxDeduction,
  earnedIncomeDeduction,
  earnedIncomeTaxCredit,
  monthlyWithholding,
  parseTaxProfile,
  parseTaxProfiles,
  simplifiedTableTax,
  tableBracket,
  yearEndEstimate,
} from '../src/incomeTaxRules.js';
import { applyInsurance } from '../src/payrollRules.js';

// 칸 값은 소득세법 시행령 [별표 2] 근로소득 간이세액표(2026. 2. 27. 개정)의 해당 구간·가족 수 칸.
test('간이세액표 — 별표 칸 값과 같다(구간 가운데 값으로 계산)', () => {
  const cells = [
    [2_000_000, [19_520, 14_750, 6_600, 3_220]],
    [3_000_000, [74_350, 56_850, 31_940, 26_690]],
    [3_500_000, [127_220, 102_220, 62_460, 49_340, 37_630, 32_380]],
    [4_000_000, [195_960, 167_950, 109_590, 91_670]],
    [5_000_000, [335_470, 306_710, 237_850, 219_100]],
    [7_000_000, [732_700, 684_290, 557_350, 527_350]],
    [9_000_000, [1_191_180, 1_140_360]],
    [1_500_000, [8_920, 4_420]],
  ];
  for (const [w, values] of cells) values.forEach((v, i) => assert.equal(simplifiedTableTax(w, i + 1), v, `${w}원 ${i + 1}명`));
  // 같은 구간 안이면 같은 칸(이상~미만).
  assert.equal(simplifiedTableTax(3_519_999, 1), 127_220);
  assert.equal(simplifiedTableTax(3_520_000, 1) !== 127_220, true);
  // 11명 칸.
  assert.equal(simplifiedTableTax(3_000_000, 11), 0);
  assert.equal(simplifiedTableTax(5_000_000, 11), 87_850);
  // 첫 세금 칸(1명은 1,060천 원부터 — 1,000원 미만 소액부징수).
  assert.equal(simplifiedTableTax(1_060_000, 1), 1_040);
  assert.equal(simplifiedTableTax(1_059_999, 1), 0);
  assert.equal(simplifiedTableTax(1_160_000, 1), 2_440);
  assert.equal(simplifiedTableTax(700_000, 1), 0);
  // 10,000천 원 칸과 그 넘는 식.
  assert.deepEqual(
    Array.from({ length: 11 }, (_, i) => simplifiedTableTax(10_000_000, i + 1)),
    [1_507_400, 1_431_570, 1_200_840, 1_170_840, 1_140_840, 1_110_840, 1_080_840, 1_050_840, 1_020_840, 990_840, 960_840],
  );
  assert.equal(simplifiedTableTax(12_000_000, 1), 2_218_400);
  assert.equal(simplifiedTableTax(15_000_000, 4), 2_940_240);
  assert.equal(simplifiedTableTax(20_000_000, 2), 5_062_970);
  assert.equal(simplifiedTableTax(29_000_000, 1), 8_510_000);
  assert.equal(simplifiedTableTax(40_000_000, 3), 12_595_440);
  assert.equal(simplifiedTableTax(50_000_000, 1), 17_002_000);
  assert.equal(simplifiedTableTax(100_000_000, 1), 38_392_000);
  assert.equal(simplifiedTableTax(10_123_456, 1), 1_574_740);
  // 11명 넘으면 주석 4(11명 − (10명 − 11명) × 초과 인원).
  assert.equal(simplifiedTableTax(5_000_000, 12), 69_100);
  assert.equal(simplifiedTableTax(5_000_000, 13), 50_350);
});

test('간이세액표 구간 — 5천·1만·2만 원 폭', () => {
  assert.equal(tableBracket(769_999), null);
  assert.deepEqual(tableBracket(1_062_000), { lo: 1060, hi: 1065 });
  assert.deepEqual(tableBracket(2_005_000), { lo: 2000, hi: 2010 });
  assert.deepEqual(tableBracket(3_515_000), { lo: 3500, hi: 3520 });
  assert.deepEqual(tableBracket(10_000_000), { lo: 10000, hi: null });
});

test('8~20세 자녀 공제 — 2026. 3. 1. 지급분부터 새 금액', () => {
  assert.equal(childTaxDeduction(0), 0);
  assert.equal(childTaxDeduction(1), 20_830);
  assert.equal(childTaxDeduction(2), 45_830);
  assert.equal(childTaxDeduction(3), 79_160);
  assert.equal(childTaxDeduction(4), 112_490);
  assert.equal(childTaxDeduction(1, '2026-02-25'), 12_500);
  assert.equal(childTaxDeduction(3, '2026-02-25'), 54_160);
  assert.equal(childTaxDeduction(2, '2026-03-01'), 45_830);
});

test('한 달 원천징수 — 자녀 빼고 비율 곱하고 10원 미만 버림, 지방소득세 10%', () => {
  const a = monthlyWithholding(3_500_000, { dependents: 4, children: 2, ratio: 100 }, { payDate: '2026-10-25' });
  assert.equal(a.incomeTax, 3_510);
  assert.equal(a.localTax, 350);
  assert.match(a.basis, /가족 4명/);
  // 빼서 0보다 적으면 0.
  assert.equal(monthlyWithholding(2_500_000, { dependents: 3, children: 1 }).incomeTax, 0);
  assert.equal(monthlyWithholding(5_000_000, { dependents: 4, children: 3 }).incomeTax, 139_940);
  assert.equal(monthlyWithholding(5_000_000, { dependents: 4, children: 3 }).localTax, 13_990);
  // 80%·120%.
  assert.equal(monthlyWithholding(3_000_000, { dependents: 1, ratio: 80 }).incomeTax, 59_480);
  assert.equal(monthlyWithholding(3_000_000, { dependents: 1, ratio: 120 }).incomeTax, 89_220);
  assert.equal(monthlyWithholding(2_000_000, { dependents: 1, ratio: 80 }).incomeTax, 15_610);
  // 정보가 없으면 본인 1명·100%.
  assert.equal(monthlyWithholding(3_000_000, null).incomeTax, 74_350);
  assert.equal(monthlyWithholding(3_000_000, null).localTax, 7_430);
});

test('원천징수 정보 검사 — 가족 1~20명, 자녀는 가족보다 적게, 비율 80·100·120', () => {
  assert.deepEqual(parseTaxProfile({ dependents: 3, children: 1, ratio: 120 }), { profile: { dependents: 3, children: 1, ratio: 120 } });
  // 기본값이면 저장하지 않는다.
  assert.deepEqual(parseTaxProfile({ dependents: 1, children: 0, ratio: 100 }), { profile: null });
  assert.deepEqual(parseTaxProfile({ auto: false }), { profile: { dependents: 1, children: 0, ratio: 100, auto: false } });
  assert.match(parseTaxProfile({ dependents: 0 }).error, /1~20/);
  assert.match(parseTaxProfile({ dependents: 2, children: 2 }).error, /자녀/);
  assert.match(parseTaxProfile({ ratio: 90 }).error, /80%/);
  const merged = parseTaxProfiles({ a: { dependents: 2 }, b: null }, { b: { dependents: 3, children: 0, ratio: 100 } });
  assert.deepEqual(merged.taxProfiles, { a: { dependents: 2, children: 0, ratio: 100 } });
});

test('공제 계산에 소득세 넣기 — 과세 대상으로 간이세액표, 지방소득세는 그 10%', () => {
  const data = {
    earnings: [
      { name: '기본급', amount: 3_300_000 },
      { name: '식대', amount: 200_000, taxFree: true },
    ],
    deductions: [{ name: '소득세', amount: 0 }],
  };
  const next = applyInsurance(data, null, { withholding: { profile: { dependents: 3, children: 1, ratio: 100 }, payDate: '2026-10-25' } });
  const tax = next.deductions.find((d) => d.name === '소득세');
  // 3,300,000원(3,300~3,320 구간) 3명 칸에서 자녀 1명 20,830원을 뺀다.
  assert.equal(tax.amount, simplifiedTableTax(3_300_000, 3) - 20_830);
  assert.match(tax.basis, /간이세액표/);
  assert.equal(next.deductions.find((d) => d.name === '지방소득세').amount, Math.floor(tax.amount / 100) * 10);
  // 자동 계산을 끈 사람은 소득세를 그대로 둔다.
  const manual = applyInsurance({ ...data, deductions: [{ name: '소득세', amount: 12_340 }] }, null, { withholding: { profile: { auto: false } } });
  assert.equal(manual.deductions.find((d) => d.name === '소득세').amount, 12_340);
  // withholding 없이는 예전처럼 소득세를 계산하지 않는다.
  assert.equal(applyInsurance(data, null).deductions.find((d) => d.name === '소득세').amount, 0);
});

test('세율·공제 — 기본세율, 근로소득공제, 근로소득세액공제(지금 법), 자녀세액공제', () => {
  assert.equal(basicTax(14_000_000), 840_000);
  assert.equal(basicTax(50_000_000), 6_240_000);
  assert.equal(basicTax(100_000_000), 15_360_000 + 12_000_000 * 0.35);
  assert.equal(earnedIncomeDeduction(40_000_000), 7_500_000 + 25_000_000 * 0.15);
  assert.equal(earnedIncomeDeduction(500_000_000), 20_000_000);
  assert.equal(earnedIncomeTaxCredit(1_000_000, 30_000_000), 550_000);
  assert.equal(earnedIncomeTaxCredit(2_000_000, 30_000_000), 740_000);
  // 한도 74만 − (총급여 − 3,300만) × 0.8%, 66만 원 아래로는 내려가지 않는다.
  assert.equal(earnedIncomeTaxCredit(2_000_000, 40_000_000), 740_000 - 7_000_000 * 0.008);
  assert.equal(earnedIncomeTaxCredit(2_000_000, 50_000_000), 660_000);
  assert.equal(childTaxCredit(1), 250_000);
  assert.equal(childTaxCredit(3), 950_000);
});

test('연말정산 어림 — 결정세액과 기납부세액의 차이(추징·환급)', () => {
  const est = yearEndEstimate(
    { taxable: 40_000_000, pension: 1_800_000, insurance: 1_700_000, withheldIncomeTax: 900_000, withheldLocalTax: 90_000 },
    { dependents: 2, children: 0 },
  );
  // 근로소득금액 = 4,000만 − 1,125만 = 2,875만, 과세표준 = 2,875만 − 300만 − 180만 − 170만 = 2,225만.
  assert.equal(est.earnedIncome, 28_750_000);
  assert.equal(est.taxBase, 22_250_000);
  assert.equal(est.computedTax, 840_000 + 8_250_000 * 0.15);
  assert.equal(est.useStandard, false);
  // 근로소득세액공제 = min(715,000 + 777,500 × 30%, 한도 max(66만, 74만 − 700만 × 0.8%)) = 684,000원.
  assert.equal(est.earnedCredit, 684_000);
  assert.equal(est.decidedTax, 1_393_500);
  assert.equal(est.diffIncomeTax, est.decidedTax - 900_000);
  assert.equal(est.decidedLocalTax, Math.floor(est.decidedTax / 100) * 10);
  // 보험료가 적으면 표준세액공제(13만 원)가 나을 수 있다.
  const small = yearEndEstimate({ taxable: 40_000_000, pension: 0, insurance: 10_000, withheldIncomeTax: 0 }, null);
  assert.equal(small.useStandard, true);
  assert.equal(small.standardCredit, 130_000);
  // 세금이 없으면 결정세액 0, 기납부는 모두 환급.
  const zero = yearEndEstimate({ taxable: 10_000_000, withheldIncomeTax: 5_000 }, { dependents: 3 });
  assert.equal(zero.decidedTax, 0);
  assert.equal(zero.diffIncomeTax, -5_000);
});
