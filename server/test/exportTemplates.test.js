import assert from 'node:assert/strict';
import test from 'node:test';
import {
  BUILTIN_TEMPLATES,
  findTemplate,
  formatDate,
  normalizeRrn,
  parseTemplate,
  parseTemplates,
  renderTemplate,
  toCsv,
} from '../src/exportTemplateRules.js';
import { insuranceRecords, transferRecords } from '../src/payrollReportRules.js';

test('양식 읽기 — 종류·이름·열·고정 값 검사', () => {
  const ok = parseTemplate(
    {
      kind: 'transfer',
      name: ' 신한 기업뱅킹 ',
      header: false,
      dateFormat: 'compact',
      fileType: 'csv',
      columns: [
        { field: 'bankCode', header: '입금은행' },
        { field: 'account', header: '계좌' },
        { field: 'amount', header: '금액' },
        { field: 'fixed', header: '구분', value: '급여' },
      ],
    },
    { newId: () => 'abcd1234' },
  );
  assert.equal(ok.template.id, 'abcd1234');
  assert.equal(ok.template.name, '신한 기업뱅킹');
  assert.equal(ok.template.header, false);
  assert.equal(ok.template.columns[3].value, '급여');
  assert.match(parseTemplate({ kind: 'x', name: 'a', columns: [{ field: 'name' }] }).error, /종류/);
  assert.match(parseTemplate({ kind: 'transfer', name: '', columns: [{ field: 'amount' }] }).error, /이름/);
  assert.match(parseTemplate({ kind: 'transfer', name: 'a', columns: [] }).error, /열/);
  // 이체 양식에는 주민등록번호 칸이 없다.
  assert.match(parseTemplate({ kind: 'transfer', name: 'a', columns: [{ field: 'rrn' }] }).error, /칸/);
  assert.match(parseTemplate({ kind: 'acquire', name: 'a', dateFormat: 'x', columns: [{ field: 'rrn' }] }).error, /날짜/);
  assert.match(parseTemplates([{ kind: 'lose', name: 'A', columns: [{ field: 'name' }] }, { kind: 'lose', name: 'A', columns: [{ field: 'name' }] }]).error, /둘/);
  // 이름이 같아도 종류가 다르면 된다.
  assert.equal(parseTemplates([{ kind: 'lose', name: 'A', columns: [{ field: 'name' }] }, { kind: 'acquire', name: 'A', columns: [{ field: 'name' }] }]).templates.length, 2);
});

test('양식 찾기 — 없으면 기본, 모르는 id는 null', () => {
  const saved = [{ id: 'x1y2', kind: 'transfer', name: '은행', columns: [] }];
  assert.equal(findTemplate('transfer', null, saved).id, 'builtin-transfer');
  assert.equal(findTemplate('transfer', 'x1y2', saved).name, '은행');
  assert.equal(findTemplate('acquire', 'x1y2', saved), null);
  assert.equal(findTemplate('lose', 'builtin-lose').builtin, true);
  assert.equal(BUILTIN_TEMPLATES.length, 3);
});

test('주민등록번호·날짜 모양', () => {
  assert.equal(normalizeRrn('900101-1234567'), '9001011234567');
  assert.equal(normalizeRrn('9001011234567'), '9001011234567');
  assert.equal(normalizeRrn('901301-1234567'), null);
  assert.equal(normalizeRrn('900100-1234567'), null);
  assert.equal(normalizeRrn('12345'), null);
  assert.equal(formatDate('2026-03-02', 'compact'), '20260302');
  assert.equal(formatDate('2026-03-02', 'dot'), '2026.03.02');
  assert.equal(formatDate('2026-03-02', 'dash'), '2026-03-02');
});

test('양식대로 표 만들기 — 은행 양식(머리 없음·고정 값)·EDI 양식(주민등록번호·마지막 근무일)·CSV', () => {
  const { records } = transferRecords([{ userId: 'a', userName: '가', employeeNo: 'E1', net: 3_000_000 }], { a: { bankCode: '004', number: '012345678901' } }, { senderText: '탱고' });
  const bank = parseTemplate({
    kind: 'transfer',
    name: '국민',
    header: false,
    columns: [{ field: 'bankCode' }, { field: 'account' }, { field: 'amount' }, { field: 'holder' }, { field: 'receiverText' }, { field: 'blank' }, { field: 'fixed', value: '01' }],
  }).template;
  const t = renderTemplate(bank, records);
  assert.equal(t.header, null);
  assert.deepEqual(t.rows[0], ['004', '012345678901', 3_000_000, '가', '탱고', '', '01']);
  assert.deepEqual(t.numeric, [2]);
  assert.deepEqual(t.text, [0, 1, 6]);

  const edi = parseTemplate({
    kind: 'lose',
    name: 'EDI 상실',
    dateFormat: 'compact',
    rrnDash: false,
    columns: [
      { field: 'rrn', header: '주민번호' },
      { field: 'name', header: '성명' },
      { field: 'eventDate', header: '상실일' },
      { field: 'lastWorkDay', header: '마지막근무일' },
      { field: 'reasonCode', header: '사유' },
      { field: 'yearPay', header: '보수총액' },
      { field: 'pensionCode', header: '연금 상실부호' },
    ],
  }).template;
  const rows = insuranceRecords('lose', [{ name: '나', rrn: '9001011234567', eventDate: '2026-03-01', reasonCode: '11', yearPay: 6_000_000, data: { pensionCode: '3' } }]);
  const e = renderTemplate(edi, rows);
  assert.deepEqual(e.header, ['주민번호', '성명', '상실일', '마지막근무일', '사유', '보수총액', '연금 상실부호']);
  assert.deepEqual(e.rows[0], ['9001011234567', '나', '20260301', '20260228', '11', 6_000_000, '3']);
  // 기본 양식은 주민등록번호에 '-'를 넣고, 번호가 없으면 빈칸.
  const dashed = renderTemplate(findTemplate('acquire', null), insuranceRecords('acquire', [{ name: '다', rrn: '9001011234567', eventDate: '2026-03-02', data: {} }]));
  assert.equal(dashed.rows[0][2], '900101-1234567');
  assert.equal(renderTemplate(findTemplate('acquire', null), insuranceRecords('acquire', [{ name: '라', eventDate: '2026-03-02', data: {} }])).rows[0][2], '');

  const csv = toCsv({ header: ['이름', '메모'], rows: [['가', 'a,"b"'], ['나', 1]] });
  assert.equal(csv, '﻿이름,메모\r\n가,"a,""b"""\r\n나,1\r\n');
});
