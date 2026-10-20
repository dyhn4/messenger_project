import assert from 'node:assert/strict';
import test from 'node:test';
import {
  accountsOf,
  cardVoucherLines,
  expenseVoucherLines,
  numberVouchers,
  parseAccountMap,
  parseRetention,
  payrollVoucherLines,
  receiptKeepUntil,
  taxDocVoucherLines,
  voucherSheet,
  voucherTotals,
} from '../src/accountingRules.js';
import { parseCardInput } from '../src/cardRules.js';
import { decodeCodefBody } from '../src/codef.js';
import {
  codefCardRow,
  codefFieldReport,
  codefFields,
  codefList,
  codefOrgOf,
  codefTaxDocRow,
  parseTaxDocRows,
  taxDocDedupeKey,
} from '../src/taxDocRules.js';

const accounts = accountsOf(null);

test('계정 설정 — 기본에 덮고, 코드·이름 검사', () => {
  assert.deepEqual(accounts.categories.식대, { code: '811', name: '복리후생비' });
  const parsed = parseAccountMap({ categories: { 식대: { code: '826', name: '도서인쇄비' } }, payment: { code: '101', name: '현금' } });
  const merged = accountsOf(parsed.accountMap);
  assert.deepEqual(merged.categories.식대, { code: '826', name: '도서인쇄비' });
  assert.deepEqual(merged.categories.교통비, { code: '812', name: '여비교통비' });
  assert.deepEqual(merged.payment, { code: '101', name: '현금' });
  assert.match(parseAccountMap({ salary: { code: '8 02', name: '급여' } }).error, /계정 코드/);
  assert.match(parseAccountMap({ salary: { code: '802', name: '' } }).error, /계정과목/);
});

test('법인카드 전표 — 차변 분류 계정 / 대변 미지급금(카드사), 취소는 반대로', () => {
  const lines = cardVoucherLines(
    [
      { id: 't2', usedOn: '2026-10-05', merchant: '택시', amount: 15_000, category: '교통비', issuer: '신한', last4: '1234', userName: '가' },
      { id: 't1', usedOn: '2026-10-02', merchant: '식당', amount: 48_000, category: '식대', issuer: '신한', last4: '1234', memo: '팀 점심' },
      { id: 't3', usedOn: '2026-10-05', merchant: '택시', amount: -15_000, category: '교통비', issuer: '신한', last4: '1234' },
      { id: 't4', usedOn: '2026-10-06', merchant: '모름', amount: 1_000, category: '없는 분류', issuer: '신한', last4: '1234' },
    ],
    accounts,
  );
  assert.equal(lines.length, 8);
  assert.deepEqual([lines[0].date, lines[0].side, lines[0].account.name, lines[0].amount], ['2026-10-02', 'debit', '복리후생비', 48_000]);
  assert.deepEqual([lines[1].side, lines[1].account.name, lines[1].partner], ['credit', '미지급금', '신한카드 1234']);
  assert.equal(lines[1].memo, '식당 / 팀 점심');
  // 취소 건 — 차변 미지급금, 대변 여비교통비.
  assert.deepEqual([lines[4].side, lines[4].account.name, lines[5].side, lines[5].account.name], ['credit', '여비교통비', 'debit', '미지급금']);
  assert.equal(lines[6].account.name, '잡비');
  assert.equal(voucherTotals(lines).balanced, true);
  // 전표 번호 — 날짜마다 1부터, 거래마다 하나.
  assert.deepEqual(
    numberVouchers(lines).map((l) => `${l.date}#${l.voucherNo}`),
    ['2026-10-02#1', '2026-10-02#1', '2026-10-05#1', '2026-10-05#1', '2026-10-05#2', '2026-10-05#2', '2026-10-06#1', '2026-10-06#1'],
  );
});

test('지출 결재·증빙·급여 전표', () => {
  const exp = expenseVoucherLines(
    [
      { id: 'd1', docNumber: '지출-2026-0003', title: '출장 숙박', authorName: '가', payload: { amount: 120_000, category: '출장비', spentOn: '2026-10-11' } },
      { id: 'd2', title: '카드 청구', authorName: '나', payload: { amount: 50_000, category: '식대', spentOn: '2026-10-12', cardTransactions: [{}] } },
    ],
    accounts,
  );
  assert.equal(exp.length, 2);
  assert.deepEqual([exp[0].account.name, exp[1].account.name, exp[1].partner], ['여비교통비', '미지급금', '가']);
  const tax = taxDocVoucherLines([{ id: 'x', issuedOn: '2026-10-03', kind: 'tax_invoice', supplierName: '사무용품', supplierBizNo: '123-45-67890', totalAmount: 110_000, category: '소모품' }], accounts);
  assert.deepEqual([tax[0].account.name, tax[1].partner, tax[1].bizNo], ['소모품비', '사무용품', '123-45-67890']);
  const pay = payrollVoucherLines(
    { id: 'r', payDate: '2026-10-25', title: '10월 급여' },
    [
      { data: { earnings: [{ name: '기본급', amount: 3_000_000 }], deductions: [{ name: '국민연금', amount: 142_500 }, { name: '소득세', amount: 74_350 }] } },
      { data: { earnings: [{ name: '기본급', amount: 2_000_000 }], deductions: [{ name: '국민연금', amount: 95_000 }] } },
    ],
    accounts,
  );
  assert.deepEqual(
    pay.map((l) => [l.side, l.account.name, l.amount]),
    [
      ['debit', '직원급여', 5_000_000],
      ['credit', '예수금', 237_500],
      ['credit', '예수금', 74_350],
      ['credit', '보통예금', 5_000_000 - 311_850],
    ],
  );
  assert.equal(voucherTotals(pay).balanced, true);
});

test('전표 엑셀 모양 — 일반(차변·대변 열)과 더존(구분 3·4, 월·일)', () => {
  const lines = cardVoucherLines([{ id: 't', usedOn: '2026-10-02', merchant: '식당', amount: 48_000, category: '식대', issuer: '신한', last4: '1234' }], accounts);
  const generic = voucherSheet(lines, 'generic');
  assert.deepEqual(generic.rows[0], ['2026-10-02', 1, '차변', '811', '복리후생비', '식당', '', '식당', 48_000, null]);
  assert.deepEqual(generic.rows[1].slice(8), [null, 48_000]);
  const dz = voucherSheet(lines, 'douzone');
  assert.deepEqual(dz.rows[0].slice(0, 6), [10, 2, 1, 3, '811', '복리후생비']);
  assert.equal(dz.rows[1][3], 4);
});

test('영수증 보관 기한 — 쓴 해의 다음 해 법정신고기한부터 N년', () => {
  assert.equal(receiptKeepUntil('2026-10-05', { years: 5 }), '2032-03-31');
  assert.equal(receiptKeepUntil('2026-10-05', { years: 5, filing: 'individual' }), '2032-05-31');
  assert.equal(receiptKeepUntil('2026-01-01', { years: 10 }), '2037-03-31');
  assert.equal(receiptKeepUntil('2026-10-05', { years: 0 }), null);
  assert.deepEqual(parseRetention({ retentionYears: 7, filing: 'individual', purge: true }), {
    patch: { receiptRetentionYears: 7, receiptFiling: 'individual', receiptPurge: true },
  });
  assert.match(parseRetention({ retentionYears: 3 }).error, /보관 기간/);
});

test('홈택스 현금영수증 엑셀 — 제목 줄 아래 머리 줄, 취소는 음수', () => {
  const rows = [
    ['현금영수증 매입내역 조회'],
    ['조회기간', '2026-10-01 ~ 2026-10-31'],
    [],
    ['매입일시', '가맹점명', '가맹점 사업자등록번호', '승인번호', '거래구분', '공급가액', '부가세', '봉사료', '총금액'],
    ['2026-10-03 12:30:00', '문구점', '1234567890', 'A1234', '승인', '10,000', '1,000', '0', '11,000'],
    ['2026-10-04 09:00:00', '문구점', '1234567890', 'A1234', '취소', '10,000', '1,000', '0', '11,000'],
    ['합계', '', '', '', '', '20,000', '2,000', '0', '22,000'],
    ['날짜아님', '문구점', '', '', '승인', '1', '0', '0', '1'],
  ];
  const r = parseTaxDocRows(rows);
  assert.equal(r.kind, 'cash_receipt');
  assert.equal(r.rows.length, 2);
  assert.deepEqual(
    [r.rows[0].issuedOn, r.rows[0].supplierName, r.rows[0].supplierBizNo, r.rows[0].supplyAmount, r.rows[0].taxAmount, r.rows[0].totalAmount],
    ['2026-10-03', '문구점', '123-45-67890', 10_000, 1_000, 11_000],
  );
  assert.equal(r.rows[1].totalAmount, -11_000);
  assert.equal(r.errors.length, 1);
  // 승인·취소는 같은 승인번호여도 다른 증빙.
  assert.notEqual(taxDocDedupeKey({ ...r.rows[0], total: r.rows[0].totalAmount }), taxDocDedupeKey({ ...r.rows[1], total: r.rows[1].totalAmount }));
});

test('홈택스 전자세금계산서 엑셀 — 공급받는자 열이 있으면 세금계산서', () => {
  const rows = [
    ['작성일자', '승인번호', '공급자사업자등록번호', '상호', '공급받는자사업자등록번호', '공급받는자상호', '합계금액', '공급가액', '세액', '품목명'],
    ['20261015', '20261015-41000000-1234abcd', '111-22-33333', '(주)공급', '444-55-66666', '(주)우리', '330000', '300000', '30000', '토너'],
  ];
  const r = parseTaxDocRows(rows);
  assert.equal(r.kind, 'tax_invoice');
  assert.deepEqual(
    [r.rows[0].issuedOn, r.rows[0].supplierName, r.rows[0].buyerBizNo, r.rows[0].totalAmount, r.rows[0].itemName],
    ['2026-10-15', '(주)공급', '444-55-66666', 330_000, '토너'],
  );
  assert.match(parseTaxDocRows([['아무', '열']]).error, /머리 줄/);
});

test('CODEF — 응답 풀기, 카드 승인내역·홈택스 줄 맞추기, 기관 코드', () => {
  const body = encodeURIComponent(JSON.stringify({ result: { code: 'CF-00000', message: '성공' }, data: { resList: [{ a: 1 }] } }));
  assert.deepEqual(decodeCodefBody(body).data, { resList: [{ a: 1 }] });
  assert.deepEqual(codefList({ resList: [{ a: 1 }] }), [{ a: 1 }]);
  assert.deepEqual(codefList([{ b: 2 }]), [{ b: 2 }]);
  const row = codefCardRow({
    resUsedDate: '20261018',
    resUsedTime: '123045',
    resCardNo: '1234********5678',
    resMemberStoreName: '커피 가게',
    resUsedAmount: '4,500',
    resApprovalNo: '00012345',
    resCancelYN: '0',
    resMemberStoreCorpNo: '1234567890',
  });
  assert.equal(row.tx.last4, '5678');
  assert.equal(row.tx.usedOn, '2026-10-18');
  assert.equal(row.tx.usedAt.toISOString(), '2026-10-18T03:30:45.000Z');
  assert.equal(row.tx.amount, 4_500);
  assert.equal(row.tx.merchantBizNo, '123-45-67890');
  assert.equal(codefCardRow({ resUsedDate: '20261018', resUsedAmount: '4500', resCancelYN: '1', resCancelAmount: '4500' }).tx.amount, -4_500);
  assert.equal(codefCardRow({ resUsedDate: '20261018', resUsedAmount: '4500', resCancelYN: '3' }).skip, true);
  assert.match(codefCardRow({ resUsedAmount: '1' }).error, /날짜/);
  const doc = codefTaxDocRow({ resIssueDate: '20261005', resSupplierCompanyName: '공급', resSupplyValue: '100000', resTaxAmt: '10000' }, { kind: 'tax_invoice' });
  assert.equal(doc.doc.totalAmount, 110_000);
  assert.equal(codefOrgOf({ issuer: '신한' }), '0306');
  assert.equal(codefOrgOf({ issuer: 'IBK기업' }), null);
  assert.equal(codefOrgOf({ issuer: 'IBK기업', codefOrganization: '0305' }), '0305');
  assert.equal(parseCardInput({ codefOrganization: '03x6' }, { partial: true }).error !== undefined, true);
  assert.deepEqual(parseCardInput({ codefOrganization: '' }, { partial: true }), { card: { codefOrganization: null } });
});

test('CODEF 칸 이름 — .env로 더한 이름을 먼저 보고, 연동 점검은 값 없이 칸 이름과 읽은 이름만', () => {
  const fields = codefFields('card', { amount: 'resApprovalAmt', merchant: ['resStoreNm', 'bad name'], nope: 'x' });
  assert.deepEqual(fields.amount.slice(0, 2), ['resApprovalAmt', 'resUsedAmount']);
  assert.deepEqual(fields.merchant.slice(0, 2), ['resStoreNm', 'resMemberStoreName']);
  assert.equal(fields.nope, undefined);
  const raw = { resUsedDate: '20261018', resApprovalAmt: '12,000', resStoreNm: '가게', resCardNo: '1234-****-****-5678' };
  assert.match(codefCardRow(raw).error, /금액/);
  const row = codefCardRow(raw, fields);
  assert.equal(row.tx.amount, 12_000);
  assert.equal(row.tx.merchant, '가게');
  const report = codefFieldReport([raw, { resUsedDate: '20261019' }], 'card', fields);
  assert.deepEqual(report.keys, ['resApprovalAmt', 'resCardNo', 'resStoreNm', 'resUsedDate']);
  assert.deepEqual(report.fields.amount.matched, { resApprovalAmt: 1 });
  assert.equal(report.fields.amount.missing, 1);
  assert.equal(report.fields.amount.required, true);
  assert.equal(report.fields.approvalNo.required, false);
  assert.ok(!JSON.stringify(report).includes('가게'));
  const doc = codefTaxDocRow({ resDate: '20261005', resSumAmount: '5000' }, { kind: 'cash_receipt', fields: codefFields('taxDoc', { total: 'resSumAmount' }) });
  assert.equal(doc.doc.totalAmount, 5_000);
});
