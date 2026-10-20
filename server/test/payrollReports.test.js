import assert from 'node:assert/strict';
import test from 'node:test';
import {
  bankOf,
  deductionBucket,
  insuranceRecords,
  parseBankAccount,
  parseBankAccounts,
  parseInsuranceReport,
  reportDeadline,
  suggestInsuranceReports,
  transferRecords,
  yearTotals,
} from '../src/payrollReportRules.js';
import { findTemplate, renderTemplate } from '../src/exportTemplateRules.js';
import {
  addMonths,
  averageWagePeriod,
  calculateSeverance,
  convertedPayDeduction,
  retirementIncomeTax,
  serviceDays,
  serviceYears,
  serviceYearsDeduction,
  severancePayslipData,
  wagesInPeriod,
} from '../src/severanceRules.js';

test('퇴직금 기간 — 재직일수·근속연수(1년 미만은 1년)·평균임금 3개월', () => {
  assert.equal(serviceDays('2023-01-01', '2025-12-31'), 1096);
  assert.equal(serviceYears('2023-01-01', '2025-12-31'), 3);
  assert.equal(serviceYears('2023-01-01', '2026-01-15'), 4);
  assert.equal(serviceYears('2026-01-01', '2026-03-31'), 1);
  assert.equal(addMonths('2026-01-31', 1), '2026-02-28');
  // 마지막 근무일 2026-10-31 → 퇴직일 11-01, 그 전 3개월 = 8-01 ~ 10-31 (92일).
  assert.deepEqual(averageWagePeriod('2026-10-31'), { from: '2026-08-01', to: '2026-10-31', days: 92 });
  // 중간에 그만두면 앞 달은 날짜만큼만.
  const period = averageWagePeriod('2026-10-15');
  assert.deepEqual(period, { from: '2026-07-16', to: '2026-10-15', days: 92 });
  const w = wagesInPeriod(
    [
      { payMonth: '2026-07', gross: 3_100_000 },
      { payMonth: '2026-08', gross: 3_100_000 },
      { payMonth: '2026-10', gross: 3_100_000 },
      { payMonth: '2026-05', gross: 9_999_999 },
    ],
    period,
  );
  assert.deepEqual(
    w.map((x) => [x.payMonth, x.days, x.amount]),
    [
      ['2026-07', 16, 1_600_000],
      ['2026-08', 31, 3_100_000],
      ['2026-10', 15, 1_500_000],
    ],
  );
});

test('퇴직소득세 — 근속연수공제·환산급여·환산급여공제·기본세율 × 근속연수 ÷ 12', () => {
  assert.equal(serviceYearsDeduction(3), 3_000_000);
  assert.equal(serviceYearsDeduction(10), 15_000_000);
  assert.equal(serviceYearsDeduction(25), 55_000_000);
  assert.equal(convertedPayDeduction(5_000_000), 5_000_000);
  assert.equal(convertedPayDeduction(42_000_000), 8_000_000 + 34_000_000 * 0.6);
  // 퇴직금 5천만 원, 10년: 환산급여 4,200만, 공제 2,840만, 과세표준 1,360만 → 816,000 × 10/12 = 680,000원.
  const t = retirementIncomeTax(50_000_000, 10);
  assert.equal(t.convertedPay, 42_000_000);
  assert.equal(t.taxBase, 13_600_000);
  assert.equal(t.incomeTax, 680_000);
  assert.equal(t.localTax, 68_000);
  // 공제가 퇴직금보다 크면 세금 0.
  assert.equal(retirementIncomeTax(2_000_000, 5).incomeTax, 0);
});

test('퇴직금 계산 — 평균임금(3개월 + 상여·연차 3/12), 통상임금이 크면 통상임금, 1년 미만은 0', () => {
  const r = calculateSeverance({
    hireDate: '2021-11-01',
    lastDay: '2026-10-31',
    wages: 9_300_000,
    annualBonus: 4_000_000,
    leavePay: 1_200_000,
  });
  assert.equal(r.serviceDays, 1826);
  assert.equal(r.eligible, true);
  assert.equal(r.bonusAdd, 1_000_000);
  assert.equal(r.leaveAdd, 300_000);
  const daily = (9_300_000 + 1_000_000 + 300_000) / 92;
  assert.equal(r.amount, Math.floor((daily * 30 * 1826) / 365));
  assert.equal(r.serviceYears, 5);
  assert.equal(r.net, r.amount - r.incomeTax - r.localTax);
  // 통상시급 × 8이 더 크면 그걸로.
  const ord = calculateSeverance({ hireDate: '2021-11-01', lastDay: '2026-10-31', wages: 1_000_000, hourlyWage: 20_000 });
  assert.equal(ord.usedOrdinary, true);
  assert.equal(ord.dailyWage, 160_000);
  // 1년 미만.
  const short = calculateSeverance({ hireDate: '2026-01-01', lastDay: '2026-10-31', wages: 9_000_000 });
  assert.equal(short.eligible, false);
  assert.equal(short.amount, 0);
  // 명세서로 — 지급 퇴직금, 공제 퇴직소득세·지방소득세.
  const data = severancePayslipData(r);
  assert.equal(data.earnings[0].name, '퇴직금');
  assert.deepEqual(
    data.deductions.map((d) => d.name),
    ['퇴직소득세', '지방소득세'],
  );
  assert.match(calculateSeverance({ hireDate: null, lastDay: '2026-10-31' }).error, /입사일/);
  assert.match(calculateSeverance({ hireDate: '2026-11-01', lastDay: '2026-10-31' }).error, /앞/);
});

test('급여 계좌 — 은행 이름·코드, 계좌번호 숫자 8~16자리', () => {
  assert.equal(bankOf('신한')?.code, '088');
  assert.equal(bankOf('국민은행')?.code, '004');
  assert.equal(bankOf('90')?.code, '090');
  assert.equal(bankOf('카카오뱅크')?.code, '090');
  assert.equal(bankOf('은행'), null);
  assert.equal(bankOf(''), null);
  assert.deepEqual(parseBankAccount({ bank: '088', number: '110-123-456789', holder: '홍길동' }), {
    account: { bankCode: '088', number: '110123456789', holder: '홍길동' },
  });
  assert.match(parseBankAccount({ bank: '088', number: '123' }).error, /8~16/);
  assert.match(parseBankAccount({ bank: '없는은행', number: '12345678' }).error, /은행/);
  assert.deepEqual(parseBankAccount({ bank: '', number: '' }), { account: null });
  const merged = parseBankAccounts({ a: { bank: '004', number: '12345678901' }, b: null }, { b: { bankCode: '088', number: '1' } });
  assert.deepEqual(Object.keys(merged.bankAccounts), ['a']);
});

test('급여 이체 줄 — 계좌 없는 사람·실수령 0원 이하는 빠진 사람으로', () => {
  const r = transferRecords(
    [
      { userId: 'a', userName: '가', employeeNo: 'E1', net: 3_000_000 },
      { userId: 'b', userName: '나', net: 2_500_000 },
      { userId: 'c', userName: '다', net: 0 },
    ],
    { a: { bankCode: '088', number: '110123456789' }, c: { bankCode: '004', number: '12345678' } },
    { senderText: '탱고상사주식회사입니다', myText: '급여' },
  );
  assert.equal(r.total, 3_000_000);
  assert.deepEqual(renderTemplate(findTemplate('transfer', null), r.records).rows[0], ['088', '신한은행', '110123456789', '가', 3_000_000, '탱고상사주식회사입니', '급여 가', '가', 'E1']);
  assert.deepEqual(
    r.missing.map((m) => [m.userName, m.reason]),
    [
      ['나', '급여 계좌 없음'],
      ['다', '실수령액이 0원 이하'],
    ],
  );
});

test('4대보험 신고 — 기한(다음 달 15일)·검사·자료 열·입사일로 제안', () => {
  assert.equal(reportDeadline('2026-10-20'), '2026-11-15');
  assert.equal(reportDeadline('2026-12-31'), '2027-01-15');
  const ok = parseInsuranceReport({ kind: 'lose', eventDate: '2026-11-01', reasonCode: '11', memo: ' 자진 퇴사 ' });
  assert.deepEqual(ok, { report: { kind: 'lose', eventDate: '2026-11-01', reasonCode: '11' }, data: { memo: '자진 퇴사' } });
  assert.match(parseInsuranceReport({ kind: 'x', eventDate: '2026-11-01' }).error, /취득·상실/);
  assert.match(parseInsuranceReport({ kind: 'lose', eventDate: '2026-11-01', reasonCode: '99' }).error, /사유/);
  assert.match(parseInsuranceReport({ kind: 'acquire', eventDate: '2026-11-01', weeklyHours: 80 }).error, /소정근로시간/);
  const acquire = renderTemplate(findTemplate('acquire', null), insuranceRecords('acquire', [{ name: '가', employeeNo: 'E1', eventDate: '2026-10-05', data: { monthlyPay: 3_000_000, weeklyHours: 40 } }]));
  assert.equal(acquire.header[0], '성명');
  assert.deepEqual(acquire.rows[0].slice(0, 6), ['가', 'E1', '', '2026-10-05', 3_000_000, 40]);
  assert.equal(acquire.rows[0][14], '2026-11-15');
  assert.deepEqual(acquire.rows[0].slice(7, 11), ['Y', 'Y', 'Y', 'Y']);
  const lose = renderTemplate(findTemplate('lose', null), insuranceRecords('lose', [{ name: '나', eventDate: '2026-11-01', reasonCode: '31', yearPay: 30_000_000, yearMonths: 10, data: {} }]));
  assert.deepEqual(lose.rows[0].slice(3, 8), ['2026-11-01', '31', '정년', 30_000_000, 10]);
  const s = suggestInsuranceReports(
    [
      { id: 'a', name: '가', hireDate: '2026-10-01' },
      { id: 'b', name: '나', hireDate: '2026-10-02' },
      { id: 'c', name: '다', hireDate: '2025-01-01' },
      { id: 'd', name: '라', hireDate: '2026-12-01' },
    ],
    [{ kind: 'acquire', userId: 'b' }],
    '2026-10-20',
  );
  assert.deepEqual(
    s.map((x) => x.userId),
    ['a'],
  );
});

test('한 해 집계 — 공제 항목을 4대보험·소득세·정산분으로 나눠 더한다', () => {
  assert.equal(deductionBucket('연말정산 소득세'), 'settlement');
  assert.equal(deductionBucket('장기요양보험'), 'longTermCare');
  assert.equal(deductionBucket('지방소득세'), 'localTax');
  assert.equal(deductionBucket('사우회비'), 'other');
  const t = yearTotals([
    {
      payMonth: '2026-01',
      data: {
        earnings: [
          { name: '기본급', amount: 3_000_000 },
          { name: '식대', amount: 200_000, taxFree: true },
        ],
        deductions: [
          { name: '국민연금', amount: 142_500 },
          { name: '소득세', amount: 74_350 },
          { name: '지방소득세', amount: 7_430 },
        ],
      },
    },
    { payMonth: '2026-01', data: { earnings: [{ name: '상여', amount: 1_000_000 }], deductions: [{ name: '연말정산 소득세', amount: -50_000 }] } },
    { payMonth: '2026-02', data: { earnings: [{ name: '기본급', amount: 3_000_000 }], deductions: [] } },
  ]);
  assert.equal(t.months, 2);
  assert.equal(t.gross, 7_200_000);
  assert.equal(t.taxable, 7_000_000);
  assert.equal(t.pension, 142_500);
  assert.equal(t.incomeTax, 74_350);
  assert.equal(t.settlement, -50_000);
});
