// 급여명세서 규칙 — 항목 검사·합계, 4대보험 공제 어림, 근태 채우기, 엑셀 급여대장 가져오기·내보내기. `node --test test/*.test.js`(DB 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  applyAttendance,
  applyInsurance,
  blankPayslipData,
  canManagePayroll,
  classifyHeader,
  insuranceDeductions,
  mergePayslipData,
  parseAmount,
  parseCorrectionReason,
  parseEmployeeNos,
  parseInsurance,
  parseItems,
  parsePayslipData,
  parseRunInput,
  parseStaffIds,
  payrollSheetColumns,
  payslipNotice,
  payslipTotals,
  planPayrollImport,
} from '../src/payrollRules.js';

test('금액 — 쉼표·원·회계식 음수', () => {
  assert.equal(parseAmount('1,234,000원'), 1234000);
  assert.equal(parseAmount('(12,300)'), -12300);
  assert.equal(parseAmount('-500'), -500);
  assert.equal(parseAmount(12.6), 13);
  assert.equal(parseAmount('abc'), null);
});

test('항목 — 빈 이름은 버리고, 같은 이름·너무 큰 금액은 거절, 비과세는 지급만', () => {
  const ok = parseItems(
    [
      { name: ' 기본급 ', amount: '3,000,000', basis: '월급' },
      { name: '', amount: 5 },
      { name: '식대', amount: 200000, taxFree: true },
    ],
    { label: '지급', allowTaxFree: true },
  );
  assert.deepEqual(ok.items, [
    { name: '기본급', amount: 3000000, basis: '월급' },
    { name: '식대', amount: 200000, taxFree: true },
  ]);
  assert.match(parseItems([{ name: 'a', amount: 1 }, { name: 'a', amount: 2 }], { label: '지급' }).error, /두 번/);
  assert.match(parseItems([{ name: 'a', amount: 2_000_000_000 }], { label: '지급' }).error, /금액/);
  assert.deepEqual(parseItems([{ name: '소득세', amount: 1, taxFree: true }], { label: '공제' }).items, [{ name: '소득세', amount: 1 }]);
});

test('합계 — 지급·과세 대상·공제·실수령', () => {
  const t = payslipTotals({
    earnings: [
      { name: '기본급', amount: 3000000 },
      { name: '식대', amount: 200000, taxFree: true },
    ],
    deductions: [{ name: '국민연금', amount: 142500 }],
  });
  assert.deepEqual(t, { gross: 3200000, taxable: 3000000, taxFree: 200000, deductionTotal: 142500, net: 3057500 });
});

test('4대보험 어림 — 2026년 기본 요율, 10원 미만 버림, 국민연금 상·하한', () => {
  const d = insuranceDeductions(3_000_000);
  assert.equal(d.pension, 142500); // 3,000,000 × 4.75%
  assert.equal(d.health, 107850); // 3,000,000 × 3.595%
  assert.equal(d.longTermCare, 14170); // 107,850 × 13.14% = 14,171.49 → 14,170
  assert.equal(d.employment, 27000); // 0.9%
  // 상한 659만 원(2026.7~2027.6).
  assert.equal(insuranceDeductions(10_000_000).pension, Math.floor((6_590_000 * 4.75) / 100 / 10) * 10);
  // 하한 41만 원.
  assert.equal(insuranceDeductions(300_000).pension, 19470);
  // 천 원 미만 버림 뒤 곱한다.
  assert.equal(insuranceDeductions(3_000_999).pension, 142500);
  assert.deepEqual(insuranceDeductions(0), { pension: 0, health: 0, longTermCare: 0, employment: 0 });
  // 바꾼 요율.
  assert.equal(insuranceDeductions(1_000_000, { employment: 1 }).employment, 10000);
});

test('공제 채우기 — 비과세는 빼고, 소득세가 있으면 지방소득세 10%', () => {
  const data = applyInsurance(
    {
      earnings: [
        { name: '기본급', amount: 3000000 },
        { name: '식대', amount: 200000, taxFree: true },
      ],
      deductions: [{ name: '소득세', amount: 74350 }, { name: '지방소득세', amount: 0 }],
    },
    null,
  );
  const of = (n) => data.deductions.find((i) => i.name === n)?.amount;
  assert.equal(of('국민연금'), 142500);
  assert.equal(of('소득세'), 74350);
  assert.equal(of('지방소득세'), 7430);
  assert.equal(of('고용보험'), 27000);
});

test('요율 설정 — 범위·상하한 순서', () => {
  assert.deepEqual(parseInsurance({ pension: '4.75', employment: 0.9 }).insurance, { pension: 4.75, employment: 0.9 });
  assert.match(parseInsurance({ health: 101 }).error, /0~100/);
  assert.match(parseInsurance({ pensionMin: 7_000_000 }).error, /하한/);
});

test('근태 채우기 — 근무 시간 요약과 통상시급 있는 사람의 수당·계산 방법', () => {
  const data = applyAttendance(blankPayslipData(null), {
    summary: { daysWorked: 21, netMinutes: 10080, actualOvertimeMinutes: 600, nightMinutes: 120, holidayWorkMinutes: 0 },
    allowance: {
      wage: 12000,
      overtimeMinutes: 600,
      nightMinutes: 120,
      holidayMinutes: 0,
      holidayOverMinutes: 0,
      overtimePay: 180000,
      nightPay: 12000,
      holidayPay: 0,
    },
    rates: { overtime: 50, night: 50, holiday: 50, holidayOver: 100, smallBusiness: false },
  });
  assert.deepEqual(data.work, { workDays: 21, workMinutes: 10080, overtimeMinutes: 600, nightMinutes: 120, holidayMinutes: 0 });
  const ot = data.earnings.find((i) => i.name === '연장근로수당');
  assert.equal(ot.amount, 180000);
  assert.equal(ot.basis, '10시간 × 12,000원 × 1.5');
  assert.equal(data.earnings.find((i) => i.name === '야간근로수당').basis, '2시간 × 12,000원 × 0.5');
  assert.equal(data.earnings.find((i) => i.name === '휴일근로수당').basis, undefined);
  // 통상시급이 없으면 시간만.
  const hoursOnly = applyAttendance(blankPayslipData(null), { summary: { daysWorked: 3, netMinutes: 1440 }, allowance: null, rates: {} });
  assert.equal(hoursOnly.work.workDays, 3);
  assert.equal(hoursOnly.earnings.find((i) => i.name === '연장근로수당').amount, 0);
});

test('명세서 입력·대장 머리·정정 사유', () => {
  const d = parsePayslipData({ earnings: [{ name: '기본급', amount: 1 }], work: { workDays: 20, overtimeMinutes: '90' }, memo: '  안녕 ' });
  assert.deepEqual(d.data, { earnings: [{ name: '기본급', amount: 1 }], deductions: [], work: { workDays: 20, overtimeMinutes: 90 }, memo: '안녕' });
  const run = parseRunInput({ payMonth: '2026-10', payDate: '2026-10-25' });
  assert.equal(run.run.title, '2026년 10월 급여');
  assert.match(parseRunInput({ payMonth: '2026-13', payDate: '2026-10-25' }).error, /달/);
  assert.deepEqual(parseRunInput({ note: '안내' }, { partial: true }).run, { note: '안내' });
  assert.match(parseCorrectionReason('  ').error, /사유/);
});

test('담당자·사번 — 정회원만, 빈 사번은 지움, 관리자 또는 담당자', () => {
  assert.deepEqual(parseStaffIds(['a', 'a'], () => true).staffIds, ['a']);
  assert.match(parseStaffIds(['x'], () => false).error, /정회원/);
  assert.deepEqual(parseEmployeeNos({ u1: ' 2026-01 ', u2: '' }, { u2: 'old', u3: 'k' }).employeeNos, { u1: '2026-01', u3: 'k' });
  assert.equal(canManagePayroll({ isManager: false, userId: 'u', staffIds: ['u'] }), true);
  assert.equal(canManagePayroll({ isManager: false, userId: 'u', staffIds: [] }), false);
});

test('엑셀 머리 — 공제 표시·흔한 공제 이름·비과세·계산 방법', () => {
  assert.deepEqual(classifyHeader('[공제] 사우회비'), { kind: 'deduction', name: '사우회비' });
  assert.deepEqual(classifyHeader('국민연금'), { kind: 'deduction', name: '국민연금' });
  assert.deepEqual(classifyHeader('식대 (비과세)'), { kind: 'earning', name: '식대', taxFree: true });
  assert.deepEqual(classifyHeader('지급: 성과급'), { kind: 'earning', name: '성과급' });
  assert.deepEqual(classifyHeader('[계산] 연장근로수당'), { kind: 'basis', name: '연장근로수당' });
  assert.deepEqual(classifyHeader('사번'), { kind: 'fixed', key: 'employeeNo' });
  assert.equal(classifyHeader(''), null);
});

test('급여대장 가져오기 — 아이디·사번·이름으로 사람 찾기, 빈 칸 건너뜀, 합계 줄, 못 찾은 줄', () => {
  const people = [
    { id: 'u1', username: 'kim', name: '김철수', employeeNo: 'E01' },
    { id: 'u2', username: 'lee', name: '이영희', employeeNo: null },
    { id: 'u3', username: 'park1', name: '박민수', employeeNo: null },
    { id: 'u4', username: 'park2', name: '박민수', employeeNo: null },
  ];
  const rows = [
    ['아이디', '사번', '이름', '근무일수', '연장시간', '기본급', '식대 (비과세)', '[계산] 기본급', '[공제] 국민연금', '소득세', '메모'],
    ['KIM', '', '', 21, 10.5, '3,000,000', 200000, '월급', 142500, 74350, '수고하셨습니다'],
    ['', '', '이영희', '', '', 2500000, '', '', 118750, '', ''],
    ['', '', '박민수', '', '', 1, '', '', '', '', ''],
    ['', '', '합계', '', '', 5500001, '', '', '', '', ''],
    ['', 'E01', '', '', '', 1, '', '', '', '', ''],
  ];
  const r = planPayrollImport(rows, people);
  assert.deepEqual(r.columns, { earnings: ['기본급', '식대'], deductions: ['국민연금', '소득세'] });
  assert.equal(r.plan.length, 2);
  const kim = r.plan.find((p) => p.userId === 'u1');
  assert.deepEqual(kim.data.earnings, [
    { name: '기본급', amount: 3000000, basis: '월급' },
    { name: '식대', amount: 200000, taxFree: true },
  ]);
  assert.deepEqual(kim.data.deductions, [
    { name: '국민연금', amount: 142500 },
    { name: '소득세', amount: 74350 },
  ]);
  assert.deepEqual(kim.data.work, { workDays: 21, overtimeMinutes: 630 });
  assert.equal(kim.data.memo, '수고하셨습니다');
  assert.deepEqual(r.plan.find((p) => p.userId === 'u2').data.earnings, [{ name: '기본급', amount: 2500000 }]);
  // 같은 이름이 둘인 박민수는 못 찾음, 사번 E01은 김철수와 겹쳐 오류.
  assert.deepEqual(r.unmatched, [{ row: 4, label: '박민수' }]);
  assert.equal(r.errors.length, 1);
  assert.match(r.errors[0].message, /두 줄/);
  assert.match(planPayrollImport([['금액']], people).errors[0].message, /아이디/);
});

test('가져온 값 덧쓰기 — 파일에 있는 항목만 바꾸고 나머지는 그대로', () => {
  const merged = mergePayslipData(
    {
      earnings: [
        { name: '기본급', amount: 1 },
        { name: '식대', amount: 200000, taxFree: true },
      ],
      deductions: [{ name: '국민연금', amount: 5 }],
      work: { workDays: 20 },
      memo: '예전',
    },
    { earnings: [{ name: '기본급', amount: 3000000 }, { name: '성과급', amount: 10 }], deductions: [], work: { overtimeMinutes: 60 }, memo: null },
  );
  assert.deepEqual(merged.earnings, [
    { name: '기본급', amount: 3000000 },
    { name: '식대', amount: 200000, taxFree: true },
    { name: '성과급', amount: 10 },
  ]);
  assert.deepEqual(merged.deductions, [{ name: '국민연금', amount: 5 }]);
  assert.deepEqual(merged.work, { workDays: 20, overtimeMinutes: 60 });
  assert.equal(merged.memo, '예전');
});

test('내보낸 급여대장은 그대로 다시 가져와진다', () => {
  const slips = [
    {
      username: 'kim',
      employeeNo: 'E01',
      name: '김철수',
      department: '영업',
      position: '대리',
      data: {
        earnings: [
          { name: '기본급', amount: 3000000 },
          { name: '식대', amount: 200000, taxFree: true },
          { name: '연장근로수당', amount: 180000, basis: '10시간 × 12,000원 × 1.5' },
        ],
        deductions: [{ name: '사우회비', amount: 10000 }],
        work: { workDays: 21, overtimeMinutes: 600 },
        memo: null,
      },
      viewedAt: null,
    },
  ];
  const cols = payrollSheetColumns(slips);
  const header = cols.map((c) => c.header);
  assert.ok(header.includes('[공제] 사우회비'));
  assert.ok(header.includes('식대 (비과세)'));
  assert.ok(header.includes('[계산] 연장근로수당'));
  const rows = [header, cols.map((c) => c.value(slips[0]))];
  const r = planPayrollImport(rows, [{ id: 'u1', username: 'kim', name: '김철수', employeeNo: 'E01' }]);
  assert.deepEqual(r.errors, []);
  assert.deepEqual(r.plan[0].data.earnings, slips[0].data.earnings);
  assert.deepEqual(r.plan[0].data.deductions, slips[0].data.deductions);
  assert.deepEqual(r.plan[0].data.work, { workDays: 21, overtimeMinutes: 600 });
});

test('알림 글에는 금액이 없다', () => {
  const n = payslipNotice({ title: '2026년 10월 급여' });
  assert.doesNotMatch(n.body, /\d원/);
  assert.match(payslipNotice({ title: 'x' }, { corrected: true }).title, /정정/);
});
