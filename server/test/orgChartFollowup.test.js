// 조직도 후속 — 결재선 규칙(고르기·채우기·문서 금액·입력 검사), 겸직 검사, 부서 경로·DN의 OU 경로, 끌어다 놓기 순서, 엑셀 내보내기·
// 가져오기(할 일 정하기 — exceljs로 실제 파일을 만들어 다시 읽기까지). `node --test test/*.test.js`(DB·네트워크 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import ExcelJS from 'exceljs';
import { applyLineRule, documentAmountOf, parseLineRule, pickLineRule } from '../src/approvalLineRules.js';
import {
  buildOrgExport,
  checkConcurrent,
  CONCURRENT_MAX,
  departmentByPath,
  DEPT_COLUMNS,
  dnParts,
  formatDepartmentPath,
  importSummary,
  MEMBER_COLUMNS,
  ouPathOf,
  parseDepartmentPath,
  planOrgImport,
  reorderSiblings,
} from '../src/orgTreeRules.js';

const U = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;

test('결재선 규칙 고르기 — 양식 지정 > 같은 종류 > any, 같은 칸이면 금액 기준이 문서 금액 이하인 것 중 가장 큰 것', () => {
  const rules = [
    { id: 'any', kind: 'any', minAmount: null },
    { id: 'leave', kind: 'leave', minAmount: null },
    { id: 'exp', kind: 'expense', minAmount: null },
    { id: 'exp100', kind: 'expense', minAmount: 1_000_000 },
    { id: 'exp1000', kind: 'expense', minAmount: 10_000_000 },
    { id: 'formAny', kind: 'form', templateId: null, minAmount: null },
    { id: 'formT1', kind: 'form', templateId: 't1', minAmount: null },
  ];
  assert.equal(pickLineRule(rules, { kind: 'leave' }).id, 'leave');
  assert.equal(pickLineRule(rules, { kind: 'expense', amount: 50_000 }).id, 'exp');
  assert.equal(pickLineRule(rules, { kind: 'expense', amount: 1_000_000 }).id, 'exp100', '경계 포함');
  assert.equal(pickLineRule(rules, { kind: 'expense', amount: 30_000_000 }).id, 'exp1000');
  assert.equal(pickLineRule(rules, { kind: 'expense' }).id, 'exp', '금액을 모르면 금액 기준 규칙은 안 고른다');
  assert.equal(pickLineRule(rules, { kind: 'attendance' }).id, 'any');
  assert.equal(pickLineRule(rules, { kind: 'form', templateId: 't1' }).id, 'formT1');
  assert.equal(pickLineRule(rules, { kind: 'form', templateId: 't2' }).id, 'formAny', '다른 양식을 정한 규칙은 안 고른다');
  assert.equal(pickLineRule([{ id: 'x', kind: 'expense', minAmount: 5 }], { kind: 'expense', amount: 1 }), null);
  assert.equal(pickLineRule([], { kind: 'leave' }), null);
});

test('결재선 채우기 — 상위자 n명, 직책 이상까지(없으면 사슬 전부), 늘 붙일 결재자·참조자는 겹치지 않게', () => {
  const chain = ['lead', 'director', 'vp', 'ceo'];
  const rank = { 대리: 2, 팀장: 4, 본부장: 6, 대표: 7 };
  const positions = { lead: '팀장', director: '팀장', vp: '본부장', ceo: '대표' };
  const opts = { chain, authorId: 'me', rankOf: (id) => rank[positions[id]] ?? null, rankOfLabel: (l) => rank[l] ?? null };
  assert.deepEqual(applyLineRule({ mode: 'levels', levels: 1 }, opts), { approverIds: ['lead'], ccIds: [] });
  assert.deepEqual(applyLineRule({ mode: 'levels', levels: 0 }, opts).approverIds, []);
  assert.deepEqual(applyLineRule({ mode: 'position', positionLabel: '본부장' }, opts).approverIds, ['lead', 'director', 'vp']);
  assert.deepEqual(applyLineRule({ mode: 'position', positionLabel: '팀장' }, opts).approverIds, ['lead']);
  assert.deepEqual(applyLineRule({ mode: 'position', positionLabel: '회장' }, opts).approverIds, chain, '모르는 직책이면 사슬 전부');
  assert.deepEqual(
    applyLineRule({ mode: 'levels', levels: 1, extraApproverIds: ['finance', 'lead', 'me'], ccIds: ['hr', 'finance', 'me'] }, opts),
    { approverIds: ['lead', 'finance'], ccIds: ['hr'] },
  );
});

test('문서 금액 — 지출·기안 예산·출장 경비·구매 합계·양식의 금액·품목 칸', () => {
  assert.equal(documentAmountOf('expense', { amount: 1200 }), 1200);
  assert.equal(documentAmountOf('draft', { values: { budget: 500 } }), 500);
  assert.equal(documentAmountOf('draft', { values: { budget: null } }), null);
  assert.equal(documentAmountOf('trip', { values: { cost: 300 } }), 300);
  assert.equal(documentAmountOf('purchase', { values: { items: { total: 9000 } } }), 9000);
  const form = {
    fields: [
      { key: 'f1', type: 'money' },
      { key: 'f2', type: 'items' },
      { key: 'f3', type: 'text' },
    ],
    values: { f1: 100, f2: { total: 50 }, f3: '1000' },
  };
  assert.equal(documentAmountOf('form', form), 150);
  assert.equal(documentAmountOf('form', { fields: [{ key: 'f1', type: 'text' }], values: { f1: 'x' } }), null);
  assert.equal(documentAmountOf('leave', { amount: 5 }), null);
});

test('결재선 규칙 입력 검사', () => {
  const ok = parseLineRule(
    { kind: 'expense', minAmount: '1000000', mode: 'position', positionLabel: '본부장', extraApproverIds: [U(1)], ccIds: [U(2)] },
    { positionLabels: ['팀장', '본부장'] },
  );
  assert.deepEqual(ok.fields, {
    kind: 'expense',
    templateId: null,
    minAmount: 1_000_000,
    mode: 'position',
    levels: null,
    positionLabel: '본부장',
    extraApproverIds: [U(1)],
    ccIds: [U(2)],
  });
  assert.equal(parseLineRule({ kind: 'leave', mode: 'levels', levels: 1 }).fields.levels, 1);
  assert.ok(parseLineRule({ kind: 'nope', mode: 'levels', levels: 1 }).error);
  assert.ok(parseLineRule({ kind: 'leave', mode: 'levels', levels: 11 }).error);
  assert.ok(parseLineRule({ kind: 'leave', mode: 'position', positionLabel: '회장' }, { positionLabels: ['팀장'] }).error);
  assert.ok(parseLineRule({ kind: 'leave', templateId: U(3), mode: 'levels', levels: 1 }).error, '양식은 form 종류에서만');
  assert.ok(parseLineRule({ kind: 'leave', mode: 'levels', levels: 1, minAmount: -1 }).error);
  assert.ok(parseLineRule({ kind: 'leave', mode: 'levels', levels: 1, ccIds: [U(1)], extraApproverIds: [U(1)] }).error, '결재자이자 참조자');
  assert.ok(parseLineRule({ kind: 'leave', mode: 'levels', levels: 1, ccIds: [U(1)] }, { isCandidate: () => false }).error);
});

const depts = [
  { id: 'hq', parentId: null, name: '영업본부', sortOrder: 0, headId: 'u-vp' },
  { id: 't1', parentId: 'hq', name: '1팀', sortOrder: 0, headId: 'u-lead' },
  { id: 't2', parentId: 'hq', name: '2팀', sortOrder: 1, headId: null },
  { id: 'dev', parentId: null, name: '개발실', sortOrder: 1, headId: null },
];
const members = new Map([
  ['u-vp', { id: 'u-vp', username: 'vp', name: '본부장님', departmentId: 'hq', managerId: null, position: '본부장' }],
  ['u-lead', { id: 'u-lead', username: 'lead', name: '팀장님', departmentId: 't1', managerId: null, position: '팀장' }],
  ['u-kim', { id: 'u-kim', username: 'kim', name: '김사원', departmentId: 't1', managerId: null, position: '사원' }],
  ['u-off', { id: 'u-off', username: 'off', name: '정지됨', departmentId: 't2', managerId: null, suspendedAt: new Date() }],
]);

test('겸직 검사 — 이 범위의 부서, 주 부서와 다르게, 겹치지 않게, 5개까지', () => {
  const kim = members.get('u-kim');
  assert.deepEqual(checkConcurrent({ departments: depts, member: kim, departmentId: 'dev' }), { ok: true });
  assert.ok(checkConcurrent({ departments: depts, member: kim, departmentId: 't1' }).error, '주 부서');
  assert.ok(checkConcurrent({ departments: depts, member: kim, departmentId: 'dev', current: ['dev'] }).error);
  assert.ok(checkConcurrent({ departments: depts, member: kim, departmentId: 'x' }).error);
  assert.ok(checkConcurrent({ departments: depts, member: kim, departmentId: 'dev', current: Array(CONCURRENT_MAX).fill('y') }).error);
});

test('부서 경로·DN — 경로 글자 읽기, DN 나누기(이스케이프), OU 경로(시작 위치 아래만)', () => {
  assert.deepEqual(parseDepartmentPath(' 영업본부 > 1팀 '), ['영업본부', '1팀']);
  assert.deepEqual(parseDepartmentPath('영업본부/1팀'), ['영업본부', '1팀']);
  assert.deepEqual(parseDepartmentPath('영업본부 › 1팀 >'), ['영업본부', '1팀']);
  assert.equal(formatDepartmentPath(['a', 'b']), 'a > b');
  assert.equal(departmentByPath(depts, ['영업본부', '2팀']).id, 't2');
  assert.equal(departmentByPath(depts, ['2팀']), null, '맨 위가 아님');
  assert.deepEqual(dnParts('CN=김\\, 철수,OU=1팀,DC=c'), [
    ['cn', '김, 철수'],
    ['ou', '1팀'],
    ['dc', 'c'],
  ]);
  const dn = 'CN=김철수,OU=1팀,OU=영업본부,OU=Users,DC=company,DC=local';
  assert.deepEqual(ouPathOf(dn, 'OU=Users,DC=company,DC=local'), ['영업본부', '1팀']);
  assert.deepEqual(ouPathOf(dn, 'ou=users, dc=COMPANY, dc=local'), ['영업본부', '1팀'], '대소문자·공백');
  assert.deepEqual(ouPathOf(dn), ['Users', '영업본부', '1팀']);
  assert.equal(ouPathOf(dn, 'OU=Other,DC=company,DC=local'), null, '시작 위치 밖');
  assert.deepEqual(ouPathOf('CN=a,DC=c,DC=l', 'DC=c,DC=l'), []);
});

test('끌어다 놓기 순서 — 그 자리에 넣고 나머지는 밀린다', () => {
  assert.deepEqual(reorderSiblings(depts, 't2', 'hq', 0), ['t2', 't1']);
  assert.deepEqual(reorderSiblings(depts, 'dev', 'hq', 1), ['t1', 'dev', 't2']);
  assert.deepEqual(reorderSiblings(depts, 'dev', 'hq', 99), ['t1', 't2', 'dev']);
  assert.deepEqual(reorderSiblings(depts, 't1', null, null), ['hq', 'dev', 't1']);
});

test('엑셀 — 내보낸 파일을 그대로 다시 읽으면 바꿀 것이 경로·사람 그대로이고, 고친 칸만 바뀐다', async () => {
  const concurrent = new Map([['u-kim', ['dev']]]);
  const rows = buildOrgExport({ departments: depts, members, concurrent });
  assert.deepEqual(rows.departments, [
    ['영업본부', 'vp', 0],
    ['영업본부 > 1팀', 'lead', 0],
    ['영업본부 > 2팀', '', 1],
    ['개발실', '', 1],
  ]);
  assert.deepEqual(
    rows.members.map((r) => r[0]),
    ['kim', 'vp', 'lead'].sort((a, b) => members.get(`u-${a}`).name.localeCompare(members.get(`u-${b}`).name, 'ko')),
    '정지된 사람은 빼고 이름 순',
  );
  assert.deepEqual(rows.members.find((r) => r[0] === 'kim'), ['kim', '김사원', '영업본부 > 1팀', '사원', '', '개발실']);

  // 실제 xlsx로 쓰고 읽기.
  const wb = new ExcelJS.Workbook();
  const put = (name, cols, data) => {
    const ws = wb.addWorksheet(name);
    ws.addRow(cols);
    for (const r of data) ws.addRow(r);
  };
  const edited = rows.members.map((r) => (r[0] === 'kim' ? ['kim', '김사원', '개발실 > 플랫폼팀', '대리', 'lead', '-'] : r));
  put('부서', DEPT_COLUMNS, rows.departments);
  put('구성원', MEMBER_COLUMNS, edited);
  const buf = await wb.xlsx.writeBuffer();
  const back = new ExcelJS.Workbook();
  await back.xlsx.load(buf);
  const read = (name) => {
    const out = [];
    back.getWorksheet(name).eachRow({ includeEmpty: false }, (row, n) => {
      if (n > 1) out.push(row.values.slice(1));
    });
    return out;
  };
  const { plan, errors } = planOrgImport({
    departments: depts,
    members,
    deptRows: read('부서'),
    memberRows: read('구성원'),
    positionLabels: ['사원', '대리', '팀장', '본부장'],
  });
  assert.deepEqual(errors, []);
  assert.deepEqual(plan.createPaths, [['개발실', '플랫폼팀']], '없는 부서만 만든다');
  const kim = plan.members.find((m) => m.userId === 'u-kim');
  assert.deepEqual(kim, { userId: 'u-kim', departmentPath: '개발실 > 플랫폼팀', position: '대리', managerId: 'u-lead', concurrentPaths: [] });
  // 부서장은 내보낸 두 부서(영업본부·1팀)의 것을 그대로 다시 적는다(같은 값이라 바뀌는 것은 없다).
  assert.deepEqual(importSummary(plan), { createDepartments: 1, headChanges: 2, orderChanges: 4, memberChanges: 3 });
});

test('엑셀 가져오기 오류 — 없는 아이디·직책·자기 자신 상위자·두 번 나온 사람·잘못된 순서', () => {
  const { errors } = planOrgImport({
    departments: depts,
    members,
    deptRows: [
      ['영업본부', 'ghost', ''],
      ['영업본부 > 3팀', '', 'x'],
    ],
    memberRows: [
      ['nobody', '', '', '', '', ''],
      ['kim', '', '', '회장', 'kim', ''],
      ['lead', '', '', '', '', ''],
      ['LEAD', '', '', '', '', ''],
    ],
    positionLabels: ['사원'],
  });
  const messages = errors.map((e) => `${e.sheet}:${e.row}:${e.message}`);
  assert.ok(messages.some((m) => m.startsWith('부서:2:') && m.includes('ghost')));
  assert.ok(messages.some((m) => m.startsWith('부서:3:') && m.includes('순서')));
  assert.ok(messages.some((m) => m.startsWith('구성원:2:') && m.includes('nobody')));
  assert.ok(messages.some((m) => m.startsWith('구성원:3:') && m.includes('직책')));
  assert.ok(messages.some((m) => m.startsWith('구성원:3:') && m.includes('자기 자신')));
  assert.ok(messages.some((m) => m.startsWith('구성원:5:') && m.includes('두 번')), '아이디는 대소문자를 가리지 않는다');
});
