// 영수증 읽기 규칙 — 서비스 응답 맞추기(CLOVA·모델 JSON), 지출 분류 짐작, 카드 사용 건과 맞춰 보기, 읽기 흐름(서비스는 가짜로).
// `node --test test/*.test.js`(DB·바깥 서비스 없이 돈다).
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import sharp from 'sharp';
import {
  extractJson,
  guessExpenseCategory,
  isEmptyReceipt,
  matchReceiptToTransactions,
  normalizeClovaReceipt,
  normalizeDate,
  normalizeReceipt,
  normalizeTime,
  RECEIPT_SCHEMA,
  receiptInputKind,
  receiptMismatches,
} from '../src/receiptOcrRules.js';
// receiptOcr.js는 저장(receipt_scans)을 위해 DB 모듈을 불러온다 — 닿지 않는 주소로 두고, 저장은 가짜로 바꿔 끼운다. 업로드 폴더도 임시 폴더로.
process.env.DATABASE_URL ??= 'postgres://test:test@127.0.0.1:1/unused';
process.env.UPLOADS_DIR = await fs.mkdtemp(path.join(os.tmpdir(), 'receipt-ocr-'));
const { uploadsDir } = await import('../src/upload.js');
const { readReceipt, ReceiptOcrError, setReceiptOcrDepsForTest } = await import('../src/receiptOcr.js');

test('맞춘 모양 — 날짜·시각·금액·카드·승인번호를 고르고 이상한 값은 버린다', () => {
  const r = normalizeReceipt({
    merchant: '  스타벅스   강남점 ',
    bizNo: '220-81-62517',
    date: '26.10.18',
    time: '13시 05분',
    total: '5,600',
    vat: 509,
    cardLast4: '5310-****-****-1234',
    approvalNo: ' 3001 2345 ',
    items: [{ name: '아메리카노', qty: 1, amount: '4,500' }, { name: '' }],
  });
  assert.deepEqual(r, {
    merchant: '스타벅스 강남점',
    bizNo: '220-81-62517',
    date: '2026-10-18',
    time: '13:05',
    total: 5600,
    vat: 509,
    cardLast4: '1234',
    approvalNo: '30012345',
    items: [{ name: '아메리카노', qty: 1, amount: 4500 }],
  });
  assert.equal(normalizeDate('2026-02-30'), null);
  assert.equal(normalizeTime('25:00'), null);
  assert.equal(normalizeReceipt({ total: 0 }).total, null);
  assert.equal(isEmptyReceipt(normalizeReceipt({})), true);
});

test('모델 응답에서 JSON 꺼내기', () => {
  assert.deepEqual(extractJson('여기 있습니다:\n```json\n{"total": 1}\n```'), { total: 1 });
  assert.deepEqual(extractJson('{"a":{"b":2}} 끝'), { a: { b: 2 } });
  assert.equal(extractJson('없음'), null);
  // 구조화 출력 스키마 — 모든 칸이 required.
  assert.deepEqual([...RECEIPT_SCHEMA.required].sort(), Object.keys(RECEIPT_SCHEMA.properties).sort());
});

test('CLOVA OCR 영수증 응답 — formatted 값, 승인번호 text, 합계가 없으면 신용카드 금액', () => {
  const json = {
    images: [
      {
        inferResult: 'SUCCESS',
        receipt: {
          result: {
            storeInfo: { name: { text: '(주)이마트', formatted: { value: '이마트' } }, subName: { text: '성수점' }, bizNum: { text: '206-86-50913' } },
            paymentInfo: {
              date: { text: '2026/10/18', formatted: { year: '2026', month: '10', day: '18' } },
              time: { text: '14:22:10', formatted: { hour: '14', minute: '22', second: '10' } },
              cardInfo: { number: { text: '9410-****-****-55**' }, company: { text: '삼성' } },
              confirmNum: { text: '12345678' },
            },
            subResults: [{ items: [{ name: { text: '우유' }, count: { text: '2' }, price: { price: { text: '5,980', formatted: { value: '5980' } } } }] }],
            totalPrice: { creditCardPrice: { text: '23,450', formatted: { value: '23450' } } },
          },
        },
      },
    ],
  };
  const r = normalizeClovaReceipt(json);
  assert.equal(r.merchant, '이마트 성수점');
  assert.equal(r.date, '2026-10-18');
  assert.equal(r.time, '14:22');
  assert.equal(r.total, 23450);
  assert.equal(r.approvalNo, '12345678');
  assert.deepEqual(r.items, [{ name: '우유', qty: 2, amount: 5980 }]);
  assert.equal(r.bizNo, '206-86-50913');
  assert.equal(isEmptyReceipt(normalizeClovaReceipt({ images: [{ inferResult: 'FAILURE' }] })), true);
});

test('지출 분류 짐작 — 범위의 분류 이름에 맞춰', () => {
  const cats = ['교통비', '식대', '비품', '소모품', '출장비', '교육비', '접대비', '기타'];
  assert.equal(guessExpenseCategory({ merchant: '카카오T 택시' }, cats), '교통비');
  assert.equal(guessExpenseCategory({ merchant: '메가커피 역삼점' }, cats), '식대');
  assert.equal(guessExpenseCategory({ merchant: '교보문고' }, cats), '교육비');
  assert.equal(guessExpenseCategory({ merchant: '다이소' }, cats), '소모품');
  assert.equal(guessExpenseCategory({ merchant: '알 수 없음' }, cats), null);
  // 분류 이름이 달라도 말이 들어 있으면.
  assert.equal(guessExpenseCategory({ merchant: 'GS칼텍스' }, ['차량유지비', '기타']), '차량유지비');
  assert.equal(guessExpenseCategory({ merchant: '택시' }, ['기타']), null);
});

test('사용 건과 맞춰 보기 — 승인번호 > 금액·날짜·카드·가맹점, 금액이 다르면 후보 아님', () => {
  const receipt = normalizeReceipt({ merchant: '스타벅스 강남', date: '2026-10-18', total: 5600, cardLast4: '1234', approvalNo: '0030012345' });
  const txs = [
    { id: 'a', usedAt: '2026-10-18T03:00:00Z', merchant: '스타벅스 강남점', amount: 5600, approvalNo: '30012345', cardLast4: '1234' },
    { id: 'b', usedAt: '2026-10-18T05:00:00Z', merchant: '이디야', amount: 5600, approvalNo: null, cardLast4: '9999' },
    { id: 'c', usedAt: '2026-10-18T05:00:00Z', merchant: '스타벅스', amount: 5700, approvalNo: null, cardLast4: '1234' },
    { id: 'd', usedAt: '2026-10-25T05:00:00Z', merchant: '스타벅스', amount: 5600, approvalNo: null, cardLast4: '1234' },
  ];
  const m = matchReceiptToTransactions(receipt, txs);
  assert.deepEqual(
    m.map((x) => x.id),
    ['a', 'b'],
  );
  assert.ok(m[0].reasons.includes('approvalNo'));
  assert.deepEqual(receiptMismatches(receipt, { usedAt: '2026-10-18T03:00:00Z', amount: 5700, cardLast4: '9999' }), ['amount', 'card']);
  // 날짜는 하루 차이까지 봐준다(자정 넘긴 영수증).
  assert.deepEqual(receiptMismatches(receipt, { usedAt: '2026-10-18T16:00:00Z', amount: 5600 }), []);
  assert.deepEqual(receiptMismatches(receipt, { usedAt: '2026-10-25T03:00:00Z', amount: 5600 }), ['date']);
});

test('읽을 수 있는 파일 형식', () => {
  assert.equal(receiptInputKind('image/jpeg', 'a.jpg'), 'image');
  assert.equal(receiptInputKind(null, '영수증.PNG'), 'image');
  assert.equal(receiptInputKind('application/pdf', 'x'), 'pdf');
  assert.equal(receiptInputKind('image/heic', 'x.heic'), 'heic');
  assert.equal(receiptInputKind('text/plain', 'a.txt'), null);
});

test('읽기 흐름 — 사진을 줄여 서비스로, 결과를 저장해 두고 다시 읽지 않는다, 꺼져 있으면 503', async (t) => {
  const name = `receipt-test-${Date.now()}.png`;
  const file = path.join(uploadsDir, name);
  await sharp({ create: { width: 3000, height: 1000, channels: 3, background: '#ffffff' } }).png().toFile(file);
  t.after(() => fs.rm(file, { force: true }));
  const saved = new Map();
  const calls = [];
  setReceiptOcrDepsForTest({
    engine: () => 'claude',
    read: async (input) => {
      calls.push(input);
      return normalizeReceipt({ merchant: 'GS25', total: '3,000', date: '2026-10-18' });
    },
    findScan: async (n) => saved.get(n) ?? null,
    saveScan: async (row) => saved.set(row.fileName, row),
  });
  t.after(() => setReceiptOcrDepsForTest());
  const first = await readReceipt({ fileUrl: `/uploads/${name}`, mimeType: 'image/png', fileName: name, userId: 'u' });
  assert.equal(first.cached, false);
  assert.equal(first.receipt.total, 3000);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].mediaType, 'image/jpeg');
  const meta = await sharp(calls[0].data).metadata();
  assert.equal(meta.width, 2000);
  const again = await readReceipt({ fileUrl: `/uploads/${name}`, mimeType: 'image/png', fileName: name, userId: 'u' });
  assert.equal(again.cached, true);
  assert.equal(calls.length, 1);
  await assert.rejects(readReceipt({ fileUrl: '/files/abc', userId: 'u' }), (e) => e instanceof ReceiptOcrError && e.status === 404);
  await assert.rejects(
    readReceipt({ fileUrl: '/uploads/x.heic', mimeType: 'image/heic', fileName: 'x.heic', userId: 'u' }),
    (e) => e instanceof ReceiptOcrError && e.status === 400 && /HEIC/.test(e.message),
  );
  setReceiptOcrDepsForTest({ engine: () => null });
  await assert.rejects(readReceipt({ fileUrl: `/uploads/${name}`, userId: 'u' }), (e) => e.status === 503);
});
