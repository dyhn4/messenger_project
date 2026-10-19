// 법인카드 규칙 — 카드 등록 검사, 카드사 이용내역(엑셀·CSV·HTML 엑셀) 읽기, 중복 키, 승인 취소 짝짓기, 청구 확인, 연동 입력.
// `node --test test/*.test.js`(DB 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  canClaimTx,
  checkClaim,
  decodeText,
  duplicateCard,
  isCardFeedToken,
  last4Of,
  mapStatementHeader,
  normalizeBizNo,
  pairCancellations,
  parseCardInput,
  parseCsv,
  parseFeedTransaction,
  parseStatementRows,
  parseTxAmount,
  parseUsedAt,
  seoulDateKey,
  statementFileKind,
  txDedupeKey,
  txStatus,
} from '../src/cardRules.js';
import { htmlTableRows } from '../src/sheetRows.js';

test('카드 입력 — 끝 4자리·사용자·한도, 같은 끝 4자리', () => {
  const ok = parseCardInput({ name: ' 영업팀 카드 ', issuer: '신한', last4: '12-34', holderIds: ['a', 'a'], monthlyLimit: '3,000,000' });
  assert.deepEqual(ok.card, { name: '영업팀 카드', issuer: '신한', last4: '1234', holderIds: ['a'], monthlyLimit: 3000000, memo: null });
  assert.match(parseCardInput({ name: 'x', last4: '123' }).error, /4자리/);
  assert.match(parseCardInput({ name: 'x', last4: '1234', holderIds: ['z'] }, { isCandidate: () => false }).error, /정회원/);
  assert.equal(parseCardInput({ name: 'x', last4: '1234', issuer: '없는카드' }).card.issuer, '기타');
  const cards = [{ id: 'c1', issuer: '신한', last4: '1234', name: 'A' }];
  assert.equal(duplicateCard(cards, { issuer: '신한', last4: '1234' })?.id, 'c1');
  assert.equal(duplicateCard(cards, { issuer: '삼성', last4: '1234' }), null);
  assert.equal(duplicateCard(cards, { issuer: '신한', last4: '1234' }, 'c1'), null);
});

test('날짜·시각 읽기 — 여러 모양, 한국 시각, 없는 날', () => {
  const d = parseUsedAt('2026.10.18 12:30');
  assert.equal(d.toISOString(), '2026-10-18T03:30:00.000Z');
  assert.equal(seoulDateKey(d), '2026-10-18');
  assert.equal(parseUsedAt('20261018', '0915').toISOString(), '2026-10-18T00:15:00.000Z');
  assert.equal(parseUsedAt('26/10/18').toISOString(), '2026-10-17T15:00:00.000Z');
  assert.equal(parseUsedAt('2026년 10월 18일').toISOString(), '2026-10-17T15:00:00.000Z');
  // 엑셀의 날짜 셀(exceljs는 UTC로 준다) — 그 글자 그대로 한국 시각.
  assert.equal(parseUsedAt(new Date(Date.UTC(2026, 9, 18, 23, 50))).toISOString(), '2026-10-18T14:50:00.000Z');
  // 엑셀 일련번호 + 시간 분수.
  assert.equal(seoulDateKey(parseUsedAt(46313, 0.5)), '2026-10-18');
  assert.equal(parseUsedAt('2026-02-30'), null);
  assert.equal(parseUsedAt('가나다'), null);
});

test('금액·끝 4자리·사업자번호', () => {
  assert.equal(parseTxAmount('12,300원'), 12300);
  assert.equal(parseTxAmount('-12,300'), -12300);
  assert.equal(parseTxAmount('(12,300)'), -12300);
  assert.equal(parseTxAmount('△5,000'), -5000);
  assert.equal(parseTxAmount(''), null);
  assert.equal(last4Of('1234-****-****-5678'), '5678');
  assert.equal(last4Of('****5678'), '5678');
  assert.equal(last4Of('본인 5678'), '5678');
  assert.equal(last4Of('***'), null);
  assert.equal(normalizeBizNo('1234567890'), '123-45-67890');
  assert.equal(normalizeBizNo('123'), null);
});

test('머리 줄 — 카드사마다 다른 열 이름', () => {
  const h = mapStatementHeader(['이용일자', '이용시간', '이용카드', '이용가맹점', '이용금액', '승인번호', '취소여부']);
  assert.deepEqual(h, { date: 0, time: 1, merchant: 3, amount: 4, approvalNo: 5, card: 2, status: 6, bizNo: -1 });
  // 승인금액이 청구금액보다 먼저.
  const h2 = mapStatementHeader(['승인일시', '가맹점명', '청구금액', '승인금액', '카드번호']);
  assert.equal(h2.amount, 3);
  assert.equal(mapStatementHeader(['이름', '금액']), null);
  // "이용금액(원)"처럼 덧붙은 이름.
  assert.equal(mapStatementHeader(['거래일', '가맹점', '이용금액(원)']).amount, 2);
});

test('이용내역 읽기 — 머리 위의 안내 줄, 합계 줄, 취소, 카드 고르기, 오류 줄', () => {
  const cards = [
    { id: 'c1', last4: '5678', holderIds: ['u1'] },
    { id: 'c2', last4: '1111', holderIds: [] },
  ];
  const rows = [
    ['신한카드 이용내역 (2026.10.01 ~ 2026.10.31)'],
    [],
    ['이용일자', '이용카드', '이용가맹점', '이용금액', '승인번호', '취소여부'],
    ['2026.10.02 12:10', '본인 5678', '스타벅스 강남점', '5,600', '30012345', ''],
    ['2026.10.03', '본인 5678', '스타벅스 강남점', '5,600', '30012345', '취소'],
    ['2026.10.04', '9999', '모르는카드', '1,000', '', ''],
    ['날짜없음', '5678', '어딘가', '1,000', '', ''],
    ['합계', '', '', '12,200', '', ''],
  ];
  const r = parseStatementRows(rows, { cardOf: (l) => cards.find((c) => c.last4 === l) ?? null });
  assert.equal(r.rows.length, 2);
  assert.equal(r.rows[0].cardId, 'c1');
  assert.equal(r.rows[0].amount, 5600);
  assert.equal(r.rows[1].amount, -5600);
  assert.equal(r.rows[0].usedOn, '2026-10-02');
  assert.equal(r.rows[0].line, 4);
  assert.deepEqual(
    r.errors.map((e) => e.line),
    [6, 7],
  );
  // 카드를 정하면 카드 열이 없어도 된다.
  const fixed = parseStatementRows([['거래일', '가맹점', '금액'], ['2026-10-05', 'GS25', 3000]], { fixedCard: cards[1] });
  assert.equal(fixed.rows[0].cardId, 'c2');
  assert.match(parseStatementRows([['거래일', '가맹점', '금액']], {}).error, /카드 번호 열/);
  assert.match(parseStatementRows([['아무', '것']], {}).error, /머리 줄/);
});

test('CSV·EUC-KR·HTML 엑셀', () => {
  assert.deepEqual(parseCsv('﻿날짜,가맹점,금액\r\n2026-10-01,"A, B","1,000"\n"x ""y""",,\n'), [
    ['날짜', '가맹점', '금액'],
    ['2026-10-01', 'A, B', '1,000'],
    ['x "y"', '', ''],
  ]);
  assert.deepEqual(parseCsv('a\tb\n1\t2'), [
    ['a', 'b'],
    ['1', '2'],
  ]);
  // "가맹점"을 EUC-KR로.
  const euc = Buffer.from([0xb0, 0xa1, 0xb8, 0xcd, 0xc1, 0xa1]);
  assert.equal(decodeText(euc), '가맹점');
  assert.equal(statementFileKind(Buffer.from('PK\u0003\u0004')), 'xlsx');
  assert.equal(statementFileKind(Buffer.from([0xd0, 0xcf, 0x11, 0xe0, 0, 0, 0, 0])), 'xls');
  assert.equal(statementFileKind(Buffer.from('<html><table><tr><td>a</td></tr></table>')), 'html');
  assert.equal(statementFileKind(Buffer.from('a,b\n1,2')), 'csv');
  assert.deepEqual(htmlTableRows('<table><tr><th>이용일자</th><th>금액</th></tr><tr><td> 2026-10-01 </td><td>1,000&nbsp;</td></tr><tr><td></td></tr></table>'), [
    ['이용일자', '금액'],
    ['2026-10-01', '1,000'],
  ]);
});

test('중복 키 — 승인번호가 있으면 승인번호·금액, 없으면 시각·금액·가맹점', () => {
  assert.equal(txDedupeKey({ approvalNo: ' 300 123 ', amount: 5600 }), 'a:300123:5600');
  assert.equal(txDedupeKey({ approvalNo: '300123', amount: -5600 }), 'a:300123:-5600');
  const t = txDedupeKey({ approvalNo: null, usedAt: new Date('2026-10-02T03:10:30Z'), amount: 1000, merchant: 'G S 25' });
  assert.equal(t, 't:2026-10-02T03:10:1000:gs25');
});

test('승인 취소 짝짓기 — 승인번호, 없으면 같은 가맹점 30일 안, 청구한 건은 건드리지 않음', () => {
  const txs = [
    { id: 'a', cardId: 'c', amount: 5600, approvalNo: '1', merchant: '스타벅스', usedAt: '2026-10-02T03:00:00Z' },
    { id: 'b', cardId: 'c', amount: -5600, approvalNo: '1', merchant: '스타벅스', usedAt: '2026-10-03T03:00:00Z' },
    { id: 'c', cardId: 'c', amount: 3000, approvalNo: null, merchant: 'GS25', usedAt: '2026-10-01T03:00:00Z' },
    { id: 'd', cardId: 'c', amount: -3000, approvalNo: null, merchant: 'GS 25', usedAt: '2026-10-20T03:00:00Z' },
    { id: 'e', cardId: 'c', amount: 9000, approvalNo: '9', merchant: 'X', usedAt: '2026-10-01T03:00:00Z', expenseDocId: 'doc', expenseStatus: 'pending' },
    { id: 'f', cardId: 'c', amount: -9000, approvalNo: '9', merchant: 'X', usedAt: '2026-10-05T03:00:00Z' },
  ];
  assert.deepEqual(pairCancellations(txs), [
    ['b', 'a'],
    ['d', 'c'],
  ]);
});

test('상태와 청구할 수 있는 사람', () => {
  assert.equal(txStatus({ excludedAt: new Date() }), 'excluded');
  assert.equal(txStatus({ expenseDocId: 'd', expenseStatus: 'pending' }), 'claiming');
  assert.equal(txStatus({ expenseDocId: 'd', expenseStatus: 'approved' }), 'settled');
  assert.equal(txStatus({ expenseDocId: 'd', expenseStatus: 'rejected' }), 'open');
  assert.equal(txStatus({}), 'open');
  const card = { holderIds: ['u1', 'u2'] };
  assert.equal(canClaimTx({ userId: null }, card, 'u2'), true);
  assert.equal(canClaimTx({ userId: 'u1' }, card, 'u2'), false);
  assert.equal(canClaimTx({ userId: null }, card, 'u3'), false);
});

test('청구 확인 — 내 것·미정산·승인 건·합계', () => {
  const cardsById = new Map([['c', { id: 'c', name: '영업 카드', issuer: '신한', last4: '5678', holderIds: ['u1'] }]]);
  const base = { scopeKey: 's', cardId: 'c', userId: 'u1', merchant: 'A', usedAt: '2026-10-02T03:00:00Z', receipts: [] };
  const txs = [
    { ...base, id: 't1', amount: 5000 },
    { ...base, id: 't2', amount: 7000, usedAt: '2026-10-01T03:00:00Z' },
    { ...base, id: 't3', amount: -1000 },
    { ...base, id: 't4', amount: 1000, expenseDocId: 'd', expenseStatus: 'approved' },
    { ...base, id: 't5', amount: 1000, userId: 'u9' },
  ];
  const ok = checkClaim({ ids: ['t1', 't2'], txs, cardsById, userId: 'u1', scopeKey: 's', amount: 12000 });
  assert.equal(ok.total, 12000);
  assert.deepEqual(
    ok.snapshot.map((s) => s.id),
    ['t2', 't1'],
  );
  assert.equal(ok.snapshot[0].last4, '5678');
  assert.match(checkClaim({ ids: ['t1'], txs, cardsById, userId: 'u1', scopeKey: 's', amount: 4000 }).error, /합계/);
  assert.match(checkClaim({ ids: ['t3'], txs, cardsById, userId: 'u1', scopeKey: 's' }).error, /취소/);
  assert.equal(checkClaim({ ids: ['t4'], txs, cardsById, userId: 'u1', scopeKey: 's' }).status, 409);
  // 같은 카드를 함께 쓰는 사람이 먼저 가져간 건은 409, 카드를 쓰지 않는 사람에게는 있는지도 알리지 않는다(404).
  assert.equal(checkClaim({ ids: ['t5'], txs, cardsById, userId: 'u1', scopeKey: 's' }).status, 409);
  const other = checkClaim({ ids: ['t1'], txs, cardsById, userId: 'u7', scopeKey: 's' });
  assert.equal(other.status, 404);
  assert.doesNotMatch(other.error, /A/);
  assert.equal(checkClaim({ ids: ['t1'], txs, cardsById, userId: 'u1', scopeKey: 'other' }).status, 404);
  assert.match(checkClaim({ ids: ['t1', 't1'], txs, cardsById, userId: 'u1', scopeKey: 's' }).error, /두 번/);
  assert.match(checkClaim({ ids: [], txs, cardsById, userId: 'u1', scopeKey: 's' }).error, /고르세요/);
});

test('연동 입력 — ISO 시각·취소 표시·카드 지정', () => {
  const r = parseFeedTransaction({ cardLast4: '5678', usedAt: '2026-10-18T12:30:00+09:00', merchant: '택시', amount: 15000, canceled: true, approvalNo: '12 34' });
  assert.equal(r.tx.amount, -15000);
  assert.equal(r.tx.usedOn, '2026-10-18');
  assert.equal(r.tx.approvalNo, '1234');
  assert.equal(r.tx.last4, '5678');
  assert.equal(parseFeedTransaction({ cardLast4: '5678', date: '2026-10-18', time: '09:00', amount: '1,000' }).tx.usedAt.toISOString(), '2026-10-18T00:00:00.000Z');
  assert.match(parseFeedTransaction({ usedAt: '2026-10-18T12:30:00Z', amount: 1 }).error, /cardLast4/);
  assert.match(parseFeedTransaction({ cardLast4: '5678', usedAt: 'x', amount: 1 }).error, /usedAt/);
  assert.match(parseFeedTransaction({ cardLast4: '5678', usedAt: '2026-10-18T00:00:00Z', amount: 0 }).error, /amount/);
  assert.equal(isCardFeedToken(`ttc_${'a'.repeat(43)}`), true);
  assert.equal(isCardFeedToken('ttk_x'), false);
});
