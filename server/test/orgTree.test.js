// 조직도 규칙 — 부서 이름, 트리가 꼬이지 않는지(자기 아래로 옮기기·깊이), 상위자(따로 정한 사람 → 부서장 → 위 부서 부서장)와 상위자
// 사슬(결재선 추천), 서로가 서로의 상위자가 되지 않게, 누가 보고 고치는지. `node --test test/*.test.js`(DB 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { suggestApprovalLine } from '../src/approvalRules.js';
import {
  ancestorsOf,
  canEditOrgTree,
  canViewOrgTree,
  checkDepartmentParent,
  checkManager,
  DEPARTMENT_DEPTH_MAX,
  departmentPath,
  descendantsOf,
  directManagerOf,
  managerChain,
  orgScopeKey,
  parseDepartmentName,
  sortDepartments,
} from '../src/orgTreeRules.js';

// 대표실(ceo) ─ 영업본부(sales, 본부장 kim) ─ 영업1팀(s1, 팀장 lee) / 영업2팀(s2, 팀장 없음)
//            └ 개발본부(dev, 본부장 park)
const departments = [
  { id: 'ceo', parentId: null, name: '대표실', headId: 'boss' },
  { id: 'sales', parentId: 'ceo', name: '영업본부', headId: 'kim' },
  { id: 's1', parentId: 'sales', name: '영업1팀', headId: 'lee' },
  { id: 's2', parentId: 'sales', name: '영업2팀', headId: null },
  { id: 'dev', parentId: 'ceo', name: '개발본부', headId: 'park' },
];
const member = (departmentId, managerId = null) => ({ departmentId, managerId });
const members = new Map([
  ['boss', member('ceo')],
  ['kim', member('sales')],
  ['lee', member('s1')],
  ['hong', member('s1')],
  ['choi', member('s2')],
  ['park', member('dev')],
  ['jung', member('dev', 'lee')], // 따로 정한 상위자(다른 부서 사람)
  ['nobody', member(null)],
]);
const org = { members, departments };

test('범위 키·부서 이름', () => {
  assert.equal(orgScopeKey({ orgScope: 'account' }, 't1'), 'server');
  assert.equal(orgScopeKey({ orgScope: 'team' }, 't1'), 't1');
  assert.equal(orgScopeKey({ orgScope: 'team' }, null), null);
  assert.deepEqual(parseDepartmentName('  영업1팀 '), { name: '영업1팀' });
  assert.ok(parseDepartmentName('').error);
  assert.ok(parseDepartmentName('가'.repeat(31)).error);
  assert.deepEqual(parseDepartmentName('a\u0007b'), { name: 'ab' });
});

test('트리 읽기 — 위 부서·아래 부서·경로·순서', () => {
  assert.deepEqual(ancestorsOf(departments, 's1'), ['sales', 'ceo']);
  assert.deepEqual(descendantsOf(departments, 'sales').sort(), ['s1', 's2']);
  assert.deepEqual(departmentPath(departments, 's1'), ['대표실', '영업본부', '영업1팀']);
  assert.deepEqual(departmentPath(departments, 'none'), []);
  // 꼬인 트리(서로가 위 부서)여도 멈춘다.
  const loop = [
    { id: 'a', parentId: 'b', name: 'A' },
    { id: 'b', parentId: 'a', name: 'B' },
  ];
  assert.deepEqual(ancestorsOf(loop, 'a'), ['b']);
  assert.deepEqual(
    sortDepartments([
      { name: '나', sortOrder: 1 },
      { name: '다', sortOrder: 0 },
      { name: '가', sortOrder: 1 },
    ]).map((d) => d.name),
    ['다', '가', '나'],
  );
});

test('부서 옮기기 — 자기 자신·자기 아래로는 안 되고, 깊이 상한', () => {
  assert.deepEqual(checkDepartmentParent(departments, 's1', 'dev'), { ok: true });
  assert.deepEqual(checkDepartmentParent(departments, 'sales', null), { ok: true }, '맨 위로');
  assert.ok(checkDepartmentParent(departments, 'sales', 'sales').error);
  assert.ok(checkDepartmentParent(departments, 'sales', 's1').error, '자기 아래로');
  assert.ok(checkDepartmentParent(departments, null, 'missing').error);
  assert.deepEqual(checkDepartmentParent(departments, null, 's1'), { ok: true }, '새 부서');
  // 깊이 — 맨 위부터 한 줄로 DEPARTMENT_DEPTH_MAX단계를 쌓으면 그 아래로는 못 만든다.
  const chain = Array.from({ length: DEPARTMENT_DEPTH_MAX }, (_, i) => ({ id: `d${i}`, parentId: i ? `d${i - 1}` : null, name: `${i}` }));
  assert.ok(checkDepartmentParent(chain, null, `d${DEPARTMENT_DEPTH_MAX - 1}`).error);
  assert.deepEqual(checkDepartmentParent(chain, null, `d${DEPARTMENT_DEPTH_MAX - 2}`), { ok: true });
  // 하위 부서가 딸린 부서를 옮길 때는 그 아래 깊이까지 센다.
  const withExtra = [...chain, { id: 'x', parentId: null, name: 'x' }, { id: 'x2', parentId: 'x', name: 'x2' }];
  assert.ok(checkDepartmentParent(withExtra, 'x', `d${DEPARTMENT_DEPTH_MAX - 2}`).error);
});

test('바로 위 상위자 — 따로 정한 사람 → 부서장 → (본인이 부서장이면) 위 부서 부서장', () => {
  assert.equal(directManagerOf('hong', org), 'lee', '팀원은 팀장');
  assert.equal(directManagerOf('lee', org), 'kim', '팀장은 본부장');
  assert.equal(directManagerOf('choi', org), 'kim', '팀장이 빈 팀은 위 부서의 부서장');
  assert.equal(directManagerOf('kim', org), 'boss');
  assert.equal(directManagerOf('boss', org), null, '맨 위');
  assert.equal(directManagerOf('jung', org), 'lee', '따로 정한 상위자가 먼저');
  assert.equal(directManagerOf('nobody', org), null, '부서 없음');
  assert.equal(directManagerOf('ghost', org), null);
});

test('상위자 사슬 — 가까운 사람부터, 고를 수 없는 사람은 건너뛰고, 최대 수·돌고 도는 사슬', () => {
  assert.deepEqual(managerChain('hong', org), ['lee', 'kim', 'boss']);
  assert.deepEqual(managerChain('hong', { ...org, max: 2 }), ['lee', 'kim']);
  assert.deepEqual(managerChain('hong', { ...org, isEligible: (id) => id !== 'kim' }), ['lee', 'boss'], '본부장이 정지됐으면 대표로');
  assert.deepEqual(managerChain('boss', org), []);
  const loopMembers = new Map([
    ['a', member(null, 'b')],
    ['b', member(null, 'a')],
  ]);
  assert.deepEqual(managerChain('a', { members: loopMembers, departments: [] }), ['b']);
});

test('상위자 정하기 — 자기 자신·서로가 서로의 상위자는 안 됨', () => {
  assert.deepEqual(checkManager('hong', 'park', org), { ok: true });
  assert.deepEqual(checkManager('hong', null, org), { ok: true }, '비우면 부서장으로');
  assert.ok(checkManager('hong', 'hong', org).error);
  assert.ok(checkManager('lee', 'hong', org).error, 'hong의 상위자가 lee인데 lee의 상위자를 hong으로');
  assert.ok(checkManager('kim', 'jung', org).error, 'jung → lee → kim 사슬');
  assert.ok(checkManager('hong', 'ghost', org).error);
});

test('결재선 추천 — 상위자 사슬이 있으면 그것, 없으면 저장한 결재선', () => {
  const saved = [{ id: 'l1', approverIds: ['x'], ccIds: ['y'], createdAt: '2026-01-01' }];
  assert.deepEqual(suggestApprovalLine({ savedLines: saved, managerChain: managerChain('hong', org) }), {
    approverIds: ['lee', 'kim', 'boss'],
    ccIds: [],
    source: 'org',
  });
  assert.equal(suggestApprovalLine({ savedLines: saved, managerChain: [] }).source, 'saved');
  assert.equal(suggestApprovalLine({ savedLines: [], managerChain: [] }), null);
});

test('누가 보고 고치는지', () => {
  assert.equal(canViewOrgTree({ scope: 'server', role: 'member' }), true);
  assert.equal(canViewOrgTree({ scope: 'server', role: 'guest' }), false, '회사 조직도는 준회원 제외');
  assert.equal(canViewOrgTree({ scope: 'team', role: 'guest', isTeamMember: true }), true);
  assert.equal(canViewOrgTree({ scope: 'team', role: 'member', isTeamMember: false }), false);
  assert.equal(canViewOrgTree({ scope: 'team', role: 'admin' }), true);
  assert.equal(canEditOrgTree({ scope: 'server', role: 'member', isOwner: true }), false, '회사 조직도는 팀 소유자도 못 고침');
  assert.equal(canEditOrgTree({ scope: 'server', role: 'admin' }), true);
  assert.equal(canEditOrgTree({ scope: 'team', role: 'member', isOwner: true }), true);
  assert.equal(canEditOrgTree({ scope: 'team', role: 'member' }), false);
  assert.equal(canEditOrgTree({ scope: 'team', role: 'member', isServerAdmin: true }), true);
});
