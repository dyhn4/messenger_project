// 결재 양식 후속 — 칸 설명·key 유지(순서 바꾸기), 사람·표 칸, 양식의 기본 결재선·참조자, 구매·출장의 정산 연결.
// `node --test test/*.test.js`(DB 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { buildFormPayload, mergeForms, parseFieldValue, parseFormDefinition } from '../src/approvalForms.js';
import { applyFormDefaults, parseFormDefaults } from '../src/approvalFormDefaults.js';
import { documentAmountOf } from '../src/approvalLineRules.js';
import { canSettle, checkSettlement, settleBudgetOf, settlementDiff, settlementOf } from '../src/settlementRules.js';

const people = new Map([
  ['u1', { id: 'u1', name: '김팀장' }],
  ['u2', { id: 'u2', name: '박본부장' }],
  ['u3', { id: 'u3', name: '이재무' }],
]);
const personOf = (id) => people.get(id) ?? null;

test('양식 정의 — 보낸 key는 그대로(순서를 바꿔도), 새 칸만 가장 큰 번호 다음으로, 칸 설명', () => {
  const first = parseFormDefinition({
    name: '교육 신청',
    fields: [
      { label: '교육명', type: 'text', help: '  과정 이름을   그대로 ' },
      { label: '비용', type: 'money' },
    ],
  });
  assert.deepEqual(
    first.form.fields.map((f) => f.key),
    ['f1', 'f2'],
  );
  assert.equal(first.form.fields[0].help, '과정 이름을 그대로');
  assert.equal('help' in first.form.fields[1], false);
  // 순서를 바꾸고 새 칸을 맨 앞에 — 예전 칸은 key를 지키고 새 칸은 f3.
  const edited = parseFormDefinition({
    name: '교육 신청',
    fields: [{ label: '기관', type: 'text' }, { key: 'f2', label: '비용', type: 'money' }, { key: 'f1', label: '교육명', type: 'text' }],
  });
  assert.deepEqual(
    edited.form.fields.map((f) => [f.key, f.label]),
    [
      ['f3', '기관'],
      ['f2', '비용'],
      ['f1', '교육명'],
    ],
  );
  // 같은 key를 두 번 보내면 뒤의 것은 새 번호.
  const dup = parseFormDefinition({ name: 'x', fields: [{ key: 'f1', label: 'a', type: 'text' }, { key: 'f1', label: 'b', type: 'text' }] });
  assert.deepEqual(
    dup.form.fields.map((f) => f.key),
    ['f1', 'f2'],
  );
  assert.match(parseFormDefinition({ name: 'x', fields: [{ label: 'a', type: 'text', help: '가'.repeat(101) }] }).error, /100자/);
});

test('양식 정의 — 사람 칸(여러 명)과 표 칸(열 이름·종류)', () => {
  const parsed = parseFormDefinition({
    name: '외부 행사',
    fields: [
      { label: '참석자', type: 'person', multiple: true },
      { label: '담당', type: 'person' },
      {
        label: '경비 내역',
        type: 'table',
        columns: [
          { label: '항목', type: 'text' },
          { label: '날짜', type: 'date' },
          { label: '금액', type: 'money' },
          { label: '비고', type: 'nonsense' },
        ],
      },
    ],
  });
  assert.equal(parsed.form.fields[0].multiple, true);
  assert.equal(parsed.form.fields[1].multiple, false);
  assert.deepEqual(
    parsed.form.fields[2].columns.map((c) => c.type),
    ['text', 'date', 'money', 'text'],
  );
  assert.match(parseFormDefinition({ name: 'x', fields: [{ label: '표', type: 'table', columns: [] }] }).error, /열을 하나 이상/);
  assert.match(
    parseFormDefinition({ name: 'x', fields: [{ label: '표', type: 'table', columns: [{ label: 'a' }, { label: 'a' }] }] }).error,
    /같은 이름의 열/,
  );
  assert.match(
    parseFormDefinition({ name: 'x', fields: [{ label: '표', type: 'table', columns: Array.from({ length: 9 }, (_, i) => ({ label: `c${i}` })) }] })
      .error,
    /8개까지/,
  );
});

test('사람 칸 값 — 고를 수 있는 사람만, 한 사람 칸에 둘은 안 됨, 그때의 이름으로 적는다', () => {
  const one = { key: 'k', label: '담당', type: 'person', required: true, multiple: false };
  const many = { ...one, label: '참석자', multiple: true };
  assert.deepEqual(parseFieldValue(one, 'u1', { personOf }).value, [{ id: 'u1', name: '김팀장' }]);
  assert.deepEqual(parseFieldValue(many, ['u1', 'u2', 'u1'], { personOf }).value.map((p) => p.id), ['u1', 'u2']);
  assert.match(parseFieldValue(one, ['u1', 'u2'], { personOf }).error, /한 사람만/);
  assert.match(parseFieldValue(many, ['u1', 'zz'], { personOf }).error, /고를 수 없는 사람/);
  assert.match(parseFieldValue(one, [], { personOf }).error, /넣으세요/);
  assert.equal(parseFieldValue({ ...many, required: false }, [], { personOf }).value, null);
  // 사람 확인 함수가 없으면 받지 않는다.
  assert.match(parseFieldValue(one, 'u1').error, /고를 수 없는 사람/);
});

test('표 칸 값 — 열 종류대로 검사, 빈 줄 건너뜀, 숫자·금액 열의 합계', () => {
  const field = {
    key: 'k',
    label: '경비',
    type: 'table',
    required: true,
    columns: [
      { label: '항목', type: 'text' },
      { label: '날짜', type: 'date' },
      { label: '수량', type: 'number' },
      { label: '금액', type: 'money' },
    ],
  };
  const parsed = parseFieldValue(field, [
    ['택시', '2026-10-01', '2', '12,000'],
    ['', '', '', ''],
    { 항목: '식대', 금액: 30000 },
  ]);
  assert.deepEqual(parsed.value.rows, [
    ['택시', '2026-10-01', 2, 12000],
    ['식대', null, null, 30000],
  ]);
  assert.deepEqual(parsed.value.totals, [null, null, 2, 42000]);
  assert.match(parseFieldValue(field, [['a', '10/1', '', '']]).error, /1번째 줄의 "날짜" 날짜/);
  assert.match(parseFieldValue(field, [['a', '', '', '-5']]).error, /원 단위 금액/);
  assert.match(parseFieldValue(field, [['', '', '', '']]).error, /한 줄 이상/);
  assert.match(parseFieldValue(field, Array.from({ length: 51 }, () => ['x'])).error, /50줄/);
});

test('양식 payload — 사람·표 칸의 정의(여러 명·열)를 문서에 같이 적고, 금액 열 합계는 결재선 규칙의 문서 금액에 들어간다', () => {
  const template = {
    id: 't1',
    name: '외부 행사',
    fields: parseFormDefinition({
      name: '외부 행사',
      fields: [
        { label: '참석자', type: 'person', multiple: true, help: '같이 가는 사람' },
        { label: '경비', type: 'table', columns: [{ label: '항목' }, { label: '금액', type: 'money' }] },
        { label: '예비비', type: 'money' },
      ],
    }).form.fields,
  };
  const { payload } = buildFormPayload({
    kind: 'form',
    template,
    values: { f1: ['u1', 'u3'], f2: [['버스', '200000'], ['식대', '150000']], f3: '50000' },
    today: '2026-10-18',
    personOf,
  });
  assert.deepEqual(payload.fields[0], { key: 'f1', label: '참석자', type: 'person', multiple: true });
  assert.deepEqual(payload.fields[1].columns, [
    { label: '항목', type: 'text' },
    { label: '금액', type: 'money' },
  ]);
  assert.deepEqual(payload.values.f1.map((p) => p.name), ['김팀장', '이재무']);
  assert.equal(documentAmountOf('form', payload), 400000);
});

test('양식 목록 — 기본 양식의 기록 줄과 관리자가 만든 양식에서 기본 결재선·참조자를 읽는다', () => {
  const forms = mergeForms([
    { builtinKey: 'trip', enabled: true, sortOrder: 1, defaultLine: [{ userId: 'u1', role: 'approve' }], defaultCcIds: ['u3'] },
    { id: 'c1', name: '교육', fields: [], enabled: true, sortOrder: 100 },
  ]);
  const trip = forms.find((f) => f.id === 'builtin:trip');
  assert.deepEqual(trip.defaultLine, [{ userId: 'u1', role: 'approve' }]);
  assert.deepEqual(trip.defaultCcIds, ['u3']);
  const custom = forms.find((f) => f.id === 'c1');
  assert.equal(custom.defaultLine, null);
  assert.deepEqual(custom.defaultCcIds, []);
  assert.equal(forms.find((f) => f.id === 'builtin:draft').defaultLine, null);
});

test('기본 결재선 입력 — 결재선과 같은 규칙(같은 사람·겹치는 참조자·전결 둘·고를 수 없는 사람), 빈 결재선은 null', () => {
  const isCandidate = (id) => people.has(id);
  const ok = parseFormDefaults(
    { defaultLine: [{ userId: 'u1' }, { userId: 'u2', role: 'final' }], defaultCcIds: ['u3', 'u3'] },
    { isCandidate },
  );
  assert.deepEqual(ok.defaults, {
    defaultLine: [
      { userId: 'u1', role: 'approve' },
      { userId: 'u2', role: 'final' },
    ],
    defaultCcIds: ['u3'],
  });
  assert.deepEqual(parseFormDefaults({ defaultLine: [], defaultCcIds: [] }, { isCandidate }).defaults, { defaultLine: null, defaultCcIds: [] });
  assert.match(parseFormDefaults({ defaultLine: ['u1', 'u1'] }, { isCandidate }).error, /두 번/);
  assert.match(parseFormDefaults({ defaultLine: ['u1'], defaultCcIds: ['u1'] }, { isCandidate }).error, /함께/);
  assert.match(
    parseFormDefaults({ defaultLine: [{ userId: 'u1', role: 'final' }, { userId: 'u2', role: 'final' }] }, { isCandidate }).error,
    /전결은 한 명/,
  );
  assert.match(parseFormDefaults({ defaultLine: ['zz'] }, { isCandidate }).error, /고를 수 없는/);
  assert.match(parseFormDefaults({ defaultLine: [{ userId: 'u1', role: 'boss' }] }, { isCandidate }).error, /역할/);
});

test('기본 결재선 입히기 — 기본 결재선이 규칙·상위자보다 먼저, 참조자만 있으면 더하기, 올리는 사람·고를 수 없는 사람은 뺌', () => {
  const isCandidate = (id) => people.has(id);
  const fromRule = { approverIds: ['u1'], ccIds: [], source: 'rule' };
  const form = { id: 'builtin:purchase', name: '구매 요청', defaultLine: [{ userId: 'u2', role: 'agree' }, { userId: 'u3', role: 'approve' }], defaultCcIds: ['u1'] };
  assert.deepEqual(applyFormDefaults({ form, authorId: 'me', suggested: fromRule, isCandidate }), {
    approverIds: ['u2', 'u3'],
    ccIds: ['u1'],
    source: 'form',
    roles: { u2: 'agree' },
    form: { id: 'builtin:purchase', name: '구매 요청' },
  });
  // 올리는 사람이 기본 결재선의 유일한 사람이면 규칙·상위자 그대로(참조자만 더함).
  const onlyMe = { id: 'c1', name: '교육', defaultLine: [{ userId: 'u2', role: 'approve' }], defaultCcIds: ['u3'] };
  assert.deepEqual(applyFormDefaults({ form: onlyMe, authorId: 'u2', suggested: fromRule, isCandidate }), {
    approverIds: ['u1'],
    ccIds: ['u3'],
    source: 'rule',
    form: { id: 'c1', name: '교육' },
  });
  // 참조자가 결재자와 겹치면 뺀다.
  const ccOnly = { id: 'c2', name: '보고', defaultLine: null, defaultCcIds: ['u1', 'u3', 'gone'] };
  assert.deepEqual(applyFormDefaults({ form: ccOnly, authorId: 'me', suggested: fromRule, isCandidate }).ccIds, ['u3']);
  // 기본값이 없으면 그대로.
  assert.equal(applyFormDefaults({ form: { id: 'c3', name: 'x', defaultLine: null, defaultCcIds: [] }, authorId: 'me', suggested: fromRule, isCandidate }), fromRule);
  assert.equal(applyFormDefaults({ form: null, authorId: 'me', suggested: null, isCandidate }), null);
});

test('정산 — 올린 사람의 승인된 구매·출장만, 살아 있는 정산이 있으면 막고, 예산을 적는다', () => {
  const purchase = {
    id: 'p1',
    scopeKey: 'server',
    authorId: 'me',
    kind: 'purchase',
    status: 'approved',
    title: '구매 요청 — 노트북',
    docNumber: '구매-2026-0003',
    payload: { total: 1_200_000, values: { items: { total: 1_200_000 } } },
  };
  assert.deepEqual(checkSettlement({ source: purchase, userId: 'me', scopeKey: 'server' }).settles, {
    id: 'p1',
    kind: 'purchase',
    title: '구매 요청 — 노트북',
    docNumber: '구매-2026-0003',
    budget: 1_200_000,
  });
  assert.equal(checkSettlement({ source: purchase, userId: 'other', scopeKey: 'server' }).status, 404);
  assert.equal(checkSettlement({ source: purchase, userId: 'me', scopeKey: 'team-a' }).status, 404);
  assert.equal(checkSettlement({ source: { ...purchase, status: 'pending' }, userId: 'me', scopeKey: 'server' }).status, 409);
  assert.match(checkSettlement({ source: { ...purchase, kind: 'draft' }, userId: 'me', scopeKey: 'server' }).error, /구매 요청·출장/);
  assert.match(
    checkSettlement({ source: purchase, userId: 'me', scopeKey: 'server', settlements: [{ status: 'pending', title: '지출 결재 — 비품' }] }).error,
    /이미 정산/,
  );
  // 반려된 정산은 다시 올릴 수 있다.
  assert.ok(checkSettlement({ source: purchase, userId: 'me', scopeKey: 'server', settlements: [{ status: 'rejected', title: 'x' }] }).settles);
  assert.equal(settleBudgetOf({ kind: 'trip', payload: { values: { cost: null } } }), null);
  assert.equal(settleBudgetOf({ kind: 'trip', payload: { values: { cost: 300000 } } }), 300000);
});

test('정산 상태 — 승인된 것, 없으면 결재 중, 없으면 최근 것; 정산하기는 올린 사람만·살아 있는 정산이 없을 때', () => {
  const s = (id, status, at, amount = 1000) => ({ id, docNumber: null, title: id, status, amount, createdAt: new Date(at) });
  assert.equal(settlementOf([]), null);
  assert.equal(settlementOf([s('a', 'rejected', '2026-10-01'), s('b', 'pending', '2026-09-01')]).id, 'b');
  assert.equal(settlementOf([s('a', 'pending', '2026-10-01'), s('b', 'approved', '2026-09-01')]).id, 'b');
  assert.equal(settlementOf([s('a', 'rejected', '2026-10-01'), s('b', 'withdrawn', '2026-10-05')]).id, 'b');
  const doc = { kind: 'trip', status: 'approved', authorId: 'me' };
  assert.equal(canSettle(doc, 'me', []), true);
  assert.equal(canSettle(doc, 'me', [s('a', 'rejected', '2026-10-01')]), true);
  assert.equal(canSettle(doc, 'me', [s('a', 'approved', '2026-10-01')]), false);
  assert.equal(canSettle(doc, 'other', []), false);
  assert.equal(canSettle({ ...doc, kind: 'draft' }, 'me', []), false);
  assert.equal(settlementDiff(1_200_000, 1_150_000), -50_000);
  assert.equal(settlementDiff(null, 1000), null);
});
