// 통합 즐겨찾기 순수 규칙 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  FAVORITES_DEFAULT_LIMIT,
  FAVORITES_MAX_LIMIT,
  mergeFavoriteLists,
  parseFavoritesQuery,
} from '../src/favoritesRules.js';

const TEAM = '11111111-1111-4111-8111-111111111111';

test('parseFavoritesQuery: type을 안 주면 all, teamId는 UUID여야 한다', () => {
  const ok = parseFavoritesQuery({ teamId: TEAM });
  assert.equal(ok.type, 'all');
  assert.equal(ok.limit, FAVORITES_DEFAULT_LIMIT);
  assert.equal(ok.before, null);
  assert.ok(parseFavoritesQuery({}).error);
  assert.ok(parseFavoritesQuery({ teamId: 'nope' }).error);
});

test('parseFavoritesQuery: type은 정해진 값만, limit은 1..100으로 눌러 담는다', () => {
  for (const type of ['message', 'file', 'comment', 'poll', 'room', 'member', 'all']) {
    assert.equal(parseFavoritesQuery({ teamId: TEAM, type }).type, type);
  }
  assert.ok(parseFavoritesQuery({ teamId: TEAM, type: 'bogus' }).error);
  assert.equal(parseFavoritesQuery({ teamId: TEAM, limit: '5000' }).limit, FAVORITES_MAX_LIMIT);
  assert.equal(parseFavoritesQuery({ teamId: TEAM, limit: '7' }).limit, 7);
  assert.ok(parseFavoritesQuery({ teamId: TEAM, limit: '0' }).error);
  assert.ok(parseFavoritesQuery({ teamId: TEAM, limit: 'x' }).error);
});

test('parseFavoritesQuery: before는 ms 시각 → Date', () => {
  const q = parseFavoritesQuery({ teamId: TEAM, before: '1700000000000' });
  assert.equal(q.before.getTime(), 1700000000000);
  assert.ok(parseFavoritesQuery({ teamId: TEAM, before: 'abc' }).error);
  assert.ok(parseFavoritesQuery({ teamId: TEAM, before: '-5' }).error);
});

test('mergeFavoriteLists: 종류를 섞어 최근 즐겨찾기순으로 limit개만, 남으면 hasMore', () => {
  const m = (t) => ({ type: 'message', favoritedAt: t });
  const c = (t) => ({ type: 'comment', favoritedAt: t });
  const out = mergeFavoriteLists([[m(50), m(10)], [c(40), c(30)], []], 3);
  assert.deepEqual(out.items.map((i) => i.favoritedAt), [50, 40, 30]);
  assert.equal(out.hasMore, true);
  const all = mergeFavoriteLists([[m(5)], [c(4)]], 3);
  assert.equal(all.items.length, 2);
  assert.equal(all.hasMore, false);
});
