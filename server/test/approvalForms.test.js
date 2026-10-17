// 결재 양식 규칙 — 칸 종류별 값 검사, 기본 양식(일반 기안서·출장·구매·연장근무)의 payload와 자동 제목, 관리자가 만드는 양식 정의 검사,
// 기본 양식 켜고 끄기를 입힌 목록. `node --test test/*.test.js`(DB 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  BUILTIN_FORMS,
  buildFormPayload,
  builtinKindOfId,
  defaultFormTitle,
  FORM_FIELDS_MAX,
  mergeForms,
  parseFieldValue,
  parseFormDefinition,
  parseFormValues,
} from '../src/approvalForms.js';
import { APPROVAL_KINDS, approvalLabelOf, approvalNotificationOf, defaultApprovalTitle } from '../src/approvalRules.js';
import { summarizeMonth } from '../src/attendanceRules.js';

const f = (type, extra = {}) => ({ key: 'k', label: '칸', type, required: false, ...extra });

test('칸 종류별 값 — 글·숫자·금액·날짜', () => {
  assert.deepEqual(parseFieldValue(f('text'), '  한   줄  '), { value: '한 줄' });
  assert.deepEqual(parseFieldValue(f('text'), ''), { value: null });
  assert.ok(parseFieldValue(f('text', { required: true }), ' ').error);
  assert.ok(parseFieldValue(f('text'), 'a'.repeat(201)).error);
  assert.deepEqual(parseFieldValue(f('textarea'), '줄1\n줄2'), { value: '줄1\n줄2' });
  assert.deepEqual(parseFieldValue(f('number'), '1,234.567'), { value: 1234.57 });
  assert.ok(parseFieldValue(f('number'), 'abc').error);
  assert.deepEqual(parseFieldValue(f('money'), '1,500,000'), { value: 1500000 });
  assert.ok(parseFieldValue(f('money'), '-1').error);
  assert.ok(parseFieldValue(f('money'), '1.5').error);
  assert.deepEqual(parseFieldValue(f('date'), '2026-10-20'), { value: '2026-10-20' });
  assert.ok(parseFieldValue(f('date'), '2026-13-01').error);
});

test('칸 종류별 값 — 기간·시간대(밤샘)·고르기', () => {
  assert.deepEqual(parseFieldValue(f('dateRange'), { start: '2026-10-20', end: '2026-10-22' }), {
    value: { start: '2026-10-20', end: '2026-10-22' },
  });
  assert.deepEqual(parseFieldValue(f('dateRange'), { start: '2026-10-20' }), { value: { start: '2026-10-20', end: '2026-10-20' } });
  assert.ok(parseFieldValue(f('dateRange'), { start: '2026-10-22', end: '2026-10-20' }).error);
  assert.ok(parseFieldValue(f('dateRange'), { start: '2026-01-01', end: '2027-06-01' }).error, '366일 넘음');
  assert.deepEqual(parseFieldValue(f('dateRange'), { start: '', end: '' }), { value: null }, '둘 다 비면 빈 칸');
  assert.ok(parseFieldValue(f('dateRange', { required: true }), { start: null, end: null }).error);
  assert.deepEqual(parseFieldValue(f('timeRange'), { start: '18:00', end: '21:30' }), {
    value: { start: '18:00', end: '21:30', minutes: 210, overnight: false },
  });
  assert.equal(parseFieldValue(f('timeRange'), { start: '22:00', end: '02:00' }).value.minutes, 240, '다음 날로 넘어감');
  assert.ok(parseFieldValue(f('timeRange'), { start: '09:00', end: '09:00' }).error);
  assert.ok(parseFieldValue(f('timeRange'), { start: '9:00', end: '10:00' }).error);
  const sel = f('select', { options: ['가', '나'] });
  assert.deepEqual(parseFieldValue(sel, '나'), { value: '나' });
  assert.ok(parseFieldValue(sel, '다').error);
});

test('품목 표 — 줄마다 금액, 합계, 빈 줄은 건너뜀', () => {
  const items = f('items', { required: true });
  const parsed = parseFieldValue(items, [
    { name: '모니터', qty: '2', unitPrice: '300,000' },
    { name: '', qty: '' },
    { name: '키보드', qty: 3, unitPrice: 50000 },
  ]);
  assert.deepEqual(parsed.value, {
    rows: [
      { name: '모니터', qty: 2, unitPrice: 300000, amount: 600000 },
      { name: '키보드', qty: 3, unitPrice: 50000, amount: 150000 },
    ],
    total: 750000,
  });
  assert.ok(parseFieldValue(items, []).error, '필수인데 비었음');
  assert.ok(parseFieldValue(items, undefined).error);
  assert.ok(parseFieldValue(items, [{ name: '', qty: 1 }]).error, '품명 없음');
  assert.ok(parseFieldValue(items, [{ name: '펜', qty: 0, unitPrice: 1 }]).error);
  assert.ok(parseFieldValue(items, [{ name: '펜', qty: 1.5, unitPrice: 1 }]).error);
  assert.ok(parseFieldValue(items, Array.from({ length: 51 }, () => ({ name: 'x', qty: 1, unitPrice: 1 }))).error);
});

test('기본 양식 — 출장(기간·일수), 구매(합계), 연장근무(분·날짜 범위), 기안', () => {
  const today = '2026-10-17';
  const trip = buildFormPayload({
    kind: 'trip',
    template: { name: '출장 신청', fields: BUILTIN_FORMS.trip.fields },
    values: { destination: '부산 지사', period: { start: '2026-10-20', end: '2026-10-22' }, purpose: '고객 미팅', transport: '항공' },
    today,
  }).payload;
  assert.equal(trip.startDate, '2026-10-20');
  assert.equal(trip.endDate, '2026-10-22');
  assert.equal(trip.days, 3);
  assert.equal(trip.values.companions, null);
  assert.equal(trip.templateId, null);
  assert.equal(trip.fields.length, BUILTIN_FORMS.trip.fields.length);
  assert.equal(defaultFormTitle('trip', trip), '출장 신청 — 부산 지사 (10/20~10/22)');
  assert.ok(
    buildFormPayload({ kind: 'trip', template: { name: '출장', fields: BUILTIN_FORMS.trip.fields }, values: { destination: '부산' }, today }).error,
    '기간·목적이 빠짐',
  );

  const purchase = buildFormPayload({
    kind: 'purchase',
    template: { name: '구매 요청', fields: BUILTIN_FORMS.purchase.fields },
    values: { items: [{ name: '노트북', qty: 1, unitPrice: 1800000 }, { name: '마우스', qty: 2, unitPrice: 30000 }], reason: '신규 입사자' },
    today,
  }).payload;
  assert.equal(purchase.total, 1860000);
  assert.equal(purchase.itemCount, 2);
  assert.equal(defaultFormTitle('purchase', purchase), '구매 요청 — 노트북 외 1건 (1,860,000원)');

  const overtime = buildFormPayload({
    kind: 'overtime',
    template: { name: '연장근무 신청', fields: BUILTIN_FORMS.overtime.fields },
    values: { workDate: '2026-10-17', time: { start: '19:00', end: '22:00' }, overtimeType: '연장근무', reason: '배포' },
    today,
  }).payload;
  assert.equal(overtime.minutes, 180);
  assert.equal(overtime.workDate, '2026-10-17');
  assert.equal(defaultFormTitle('overtime', overtime), '연장근무 신청 (10/17 19:00~22:00)');
  for (const workDate of ['2026-09-01', '2027-01-01']) {
    assert.ok(
      buildFormPayload({
        kind: 'overtime',
        template: { name: 'x', fields: BUILTIN_FORMS.overtime.fields },
        values: { workDate, time: { start: '19:00', end: '22:00' }, overtimeType: '연장근무', reason: 'r' },
        today,
      }).error,
      workDate,
    );
  }

  const draft = buildFormPayload({
    kind: 'draft',
    template: { name: '일반 기안서', fields: BUILTIN_FORMS.draft.fields },
    values: { content: '사내 워크숍 개최 건\n장소: 양평', budget: '2,000,000' },
    today,
  }).payload;
  assert.equal(draft.values.budget, 2000000);
  assert.equal(defaultFormTitle('draft', draft), '기안 — 사내 워크숍 개최 건');
  assert.equal(defaultApprovalTitle('draft', draft), '기안 — 사내 워크숍 개최 건', 'approvalRules가 양식 제목으로 넘긴다');
});

test('관리자가 만드는 양식 정의 — 이름·칸(키는 새로 매김)·고르기 거리', () => {
  const parsed = parseFormDefinition({
    name: ' 교육 신청 ',
    description: '외부 교육',
    allowAttachments: true,
    fields: [
      { key: 'zzz', label: '교육명', type: 'text', required: true },
      { label: '기간', type: 'dateRange' },
      { label: '구분', type: 'select', options: ['온라인', '오프라인', '온라인', ' '] },
    ],
  });
  assert.deepEqual(parsed.form, {
    name: '교육 신청',
    description: '외부 교육',
    allowAttachments: true,
    fields: [
      { key: 'f1', label: '교육명', type: 'text', required: true },
      { key: 'f2', label: '기간', type: 'dateRange', required: false },
      { key: 'f3', label: '구분', type: 'select', required: false, options: ['온라인', '오프라인'] },
    ],
  });
  assert.ok(parseFormDefinition({ name: '', fields: [{ label: 'a', type: 'text' }] }).error);
  assert.ok(parseFormDefinition({ name: 'x', fields: [] }).error);
  assert.ok(parseFormDefinition({ name: 'x', fields: [{ label: 'a', type: 'nope' }] }).error);
  assert.ok(parseFormDefinition({ name: 'x', fields: [{ label: 'a', type: 'text' }, { label: 'a', type: 'date' }] }).error, '같은 칸 이름');
  assert.ok(parseFormDefinition({ name: 'x', fields: [{ label: 'a', type: 'select', options: ['하나'] }] }).error, '고를 거리 둘 이상');
  assert.ok(
    parseFormDefinition({ name: 'x', fields: Array.from({ length: FORM_FIELDS_MAX + 1 }, (_, i) => ({ label: `c${i}`, type: 'text' })) }).error,
  );
  // 만든 양식으로 값 검사.
  const values = parseFormValues(parsed.form.fields, { f1: '보안 교육', f3: '온라인' });
  assert.deepEqual(values, { values: { f1: '보안 교육', f2: null, f3: '온라인' } });
  assert.ok(parseFormValues(parsed.form.fields, { f3: '온라인' }).error, '필수 칸');
});

test('양식 목록 — 기본 양식에 켜고 끈 기록을 입히고, 만든 양식은 뒤에', () => {
  const rows = [
    { builtinKey: 'purchase', enabled: false, sortOrder: 2 },
    { id: 'u1', builtinKey: null, name: '교육 신청', fields: [{ key: 'f1', label: 'a', type: 'text' }], enabled: true, sortOrder: 100 },
  ];
  const forms = mergeForms(rows);
  assert.deepEqual(
    forms.map((x) => [x.id, x.enabled]),
    [
      ['builtin:draft', true],
      ['builtin:trip', true],
      ['builtin:purchase', false],
      ['builtin:overtime', true],
      ['u1', true],
    ],
  );
  assert.equal(forms[4].kind, 'form');
  assert.equal(builtinKindOfId('builtin:trip'), 'trip');
  assert.equal(builtinKindOfId('builtin:nope'), null);
  assert.equal(builtinKindOfId('u1'), null);
});

test('결재 종류·이름·알림 — 양식 종류가 들어가고, 만든 양식은 양식 이름으로 알린다', () => {
  for (const kind of ['draft', 'trip', 'purchase', 'overtime', 'form']) assert.ok(APPROVAL_KINDS.includes(kind));
  const doc = { kind: 'form', title: '보안 교육', authorName: '김철수', payload: { templateName: '교육 신청' } };
  assert.equal(approvalLabelOf(doc), '교육 신청');
  assert.equal(approvalNotificationOf('approved', doc).title, '교육 신청 결재 승인');
  assert.equal(approvalLabelOf({ kind: 'trip', payload: {} }), '출장');
});

test('월 근태 — 승인된 출장 날은 결근이 아니고, 연장근무 분을 합친다', () => {
  const summary = summarizeMonth({
    monthKey: '2026-10',
    records: [],
    tripDates: new Set(['2026-10-07', '2026-10-08']),
    overtimeByDate: new Map([['2026-10-02', 180], ['2026-10-07', 60]]),
    holidays: new Set(['2026-10-05', '2026-10-09']),
    workStart: 540,
    workEnd: 1080,
    today: '2026-10-09',
  });
  // 10/1·2(목·금)·6(화) 결근, 10/5 공휴일, 10/7·8 출장, 10/9 오늘.
  assert.equal(summary.absent, 3);
  assert.equal(summary.tripDays, 2);
  assert.equal(summary.overtimeMinutes, 240);
});
