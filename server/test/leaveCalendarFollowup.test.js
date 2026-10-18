// 휴가 달력 후속 — 부서로 거르기(아래 부서·겸직 포함, 부서 없음)와 부서 고르기 목록(트리 순서). `node --test test/*.test.js`(DB 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { departmentMemberIds, departmentOptions } from '../src/orgTreeRules.js';

const departments = [
  { id: 'sales', name: '영업본부', parentId: null, sortOrder: 1 },
  { id: 'team1', name: '1팀', parentId: 'sales', sortOrder: 1 },
  { id: 'team2', name: '2팀', parentId: 'sales', sortOrder: 2 },
  { id: 'dev', name: '개발본부', parentId: null, sortOrder: 2 },
  { id: 'orphan', name: '떨어진 부서', parentId: 'gone', sortOrder: 0 },
];
const members = new Map([
  ['a', { id: 'a', departmentId: 'sales' }],
  ['b', { id: 'b', departmentId: 'team1' }],
  ['c', { id: 'c', departmentId: 'team2' }],
  ['d', { id: 'd', departmentId: 'dev' }],
  ['e', { id: 'e', departmentId: null }],
  ['f', { id: 'f', departmentId: null }],
]);
const concurrent = [{ userId: 'd', departmentId: 'team1' }, { userId: 'f', departmentId: 'dev' }];

test('부서로 거르기 — 아래 부서와 겸직까지, 부서 없음은 겸직도 없는 사람', () => {
  const ids = (departmentId) => [...departmentMemberIds({ departmentId, departments, members, concurrent })].sort();
  assert.deepEqual(ids('sales'), ['a', 'b', 'c', 'd']);
  assert.deepEqual(ids('team1'), ['b', 'd']);
  assert.deepEqual(ids('dev'), ['d', 'f']);
  assert.deepEqual(ids('none'), ['e']);
  assert.deepEqual(ids('team2'), ['c']);
});

test('부서 고르기 목록 — 위 부서 다음에 그 아래(순서대로), 깊이, 떨어진 부서도 빠뜨리지 않음', () => {
  assert.deepEqual(
    departmentOptions(departments).map((d) => [d.id, d.depth]),
    [
      ['sales', 1],
      ['team1', 2],
      ['team2', 2],
      ['dev', 1],
      ['orphan', 1],
    ],
  );
  assert.deepEqual(departmentOptions([]), []);
});
