// 투표 목록(GET /api/polls) 순수 규칙 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { compareByCursor, formatCursor, parseCursor } from '../src/pageCursor.js';
import {
  POLL_LIST_DEFAULT_LIMIT,
  POLL_LIST_MAX_LIMIT,
  parsePollListQuery,
  pollIsClosedAt,
  pollMatchesFilter,
} from '../src/pollListRules.js';

const TEAM = '11111111-1111-4111-8111-111111111111';
const USER = '22222222-2222-4222-8222-222222222222';

test('parsePollListQuery: teamId는 UUID여야 하고, 나머지는 기본값이 있다', () => {
  const ok = parsePollListQuery({ teamId: TEAM });
  assert.equal(ok.status, 'all');
  assert.equal(ok.participated, 'all');
  assert.equal(ok.order, 'desc');
  assert.equal(ok.limit, POLL_LIST_DEFAULT_LIMIT);
  assert.equal(ok.roomId, null);
  assert.equal(ok.creatorId, null);
  assert.equal(ok.since, null);
  assert.equal(ok.until, null);
  assert.equal(ok.cursor, null);
  assert.ok(parsePollListQuery({}).error);
  assert.ok(parsePollListQuery({ teamId: 'nope' }).error);
});

test('parsePollListQuery: status·participated·order는 정해진 값만', () => {
  for (const status of ['all', 'open', 'closed']) {
    assert.equal(parsePollListQuery({ teamId: TEAM, status }).status, status);
  }
  for (const participated of ['all', 'yes', 'no']) {
    assert.equal(parsePollListQuery({ teamId: TEAM, participated }).participated, participated);
  }
  assert.equal(parsePollListQuery({ teamId: TEAM, order: 'asc' }).order, 'asc');
  assert.ok(parsePollListQuery({ teamId: TEAM, status: 'bogus' }).error);
  assert.ok(parsePollListQuery({ teamId: TEAM, participated: 'maybe' }).error);
  assert.ok(parsePollListQuery({ teamId: TEAM, order: 'sideways' }).error);
});

test('parsePollListQuery: creatorId는 UUID, roomId는 문자열, 빈 문자열은 안 준 것과 같다', () => {
  assert.equal(parsePollListQuery({ teamId: TEAM, creatorId: USER }).creatorId, USER);
  assert.ok(parsePollListQuery({ teamId: TEAM, creatorId: 'x' }).error);
  assert.equal(parsePollListQuery({ teamId: TEAM, roomId: 'room-1' }).roomId, 'room-1');
  const blank = parsePollListQuery({ teamId: TEAM, roomId: '', creatorId: '', status: '', since: '', limit: '' });
  assert.equal(blank.roomId, null);
  assert.equal(blank.creatorId, null);
  assert.equal(blank.since, null);
  assert.equal(blank.status, 'all');
});

test('parsePollListQuery: since/until은 ms 시각 → Date, limit은 1..50으로 눌러 담는다', () => {
  const q = parsePollListQuery({ teamId: TEAM, since: '1700000000000', until: '1800000000000', limit: '9999' });
  assert.equal(q.since.getTime(), 1700000000000);
  assert.equal(q.until.getTime(), 1800000000000);
  assert.equal(q.limit, POLL_LIST_MAX_LIMIT);
  assert.equal(parsePollListQuery({ teamId: TEAM, limit: '7' }).limit, 7);
  assert.ok(parsePollListQuery({ teamId: TEAM, since: 'abc' }).error);
  assert.ok(parsePollListQuery({ teamId: TEAM, until: '-1' }).error);
  assert.ok(parsePollListQuery({ teamId: TEAM, limit: '0' }).error);
  assert.ok(parsePollListQuery({ teamId: TEAM, limit: 'x' }).error);
});

test('parsePollListQuery: before 커서는 "ms:id" 또는 ms만', () => {
  const withId = parsePollListQuery({ teamId: TEAM, before: `1700000000000:${USER}` });
  assert.deepEqual(withId.cursor, { ms: 1700000000000, id: USER });
  assert.deepEqual(parsePollListQuery({ teamId: TEAM, before: '1700000000000' }).cursor, { ms: 1700000000000, id: null });
  assert.ok(parsePollListQuery({ teamId: TEAM, before: 'abc' }).error);
  assert.ok(parsePollListQuery({ teamId: TEAM, before: '1700000000000:not-a-uuid' }).error);
  assert.ok(parsePollListQuery({ teamId: TEAM, before: `1:${USER}:extra` }).error);
});

test('pollIsClosedAt: 일찍 마감했거나 마감 시각이 지났으면 마감', () => {
  const now = 1_000_000;
  assert.equal(pollIsClosedAt({ closedAt: null, closesAt: new Date(now + 1) }, now), false);
  assert.equal(pollIsClosedAt({ closedAt: null, closesAt: new Date(now) }, now), true); // 정각은 마감
  assert.equal(pollIsClosedAt({ closedAt: null, closesAt: new Date(now - 1) }, now), true);
  assert.equal(pollIsClosedAt({ closedAt: new Date(now - 5), closesAt: new Date(now + 9999) }, now), true);
});

test('pollMatchesFilter: 상태·참여·작성자·방·기간을 모두 만족해야 한다', () => {
  const now = 10_000;
  const open = { roomId: 'r1', creatorId: USER, createdAt: new Date(5000), closedAt: null, closesAt: new Date(20_000) };
  const closedEarly = { ...open, closedAt: new Date(6000) };
  const expired = { ...open, closesAt: new Date(9000) };
  const f = (extra) => ({ ...parsePollListQuery({ teamId: TEAM }), ...extra });

  assert.equal(pollMatchesFilter(open, f({}), { now }), true);
  assert.equal(pollMatchesFilter(open, f({ status: 'open' }), { now }), true);
  assert.equal(pollMatchesFilter(open, f({ status: 'closed' }), { now }), false);
  assert.equal(pollMatchesFilter(closedEarly, f({ status: 'closed' }), { now }), true);
  assert.equal(pollMatchesFilter(expired, f({ status: 'closed' }), { now }), true);
  assert.equal(pollMatchesFilter(expired, f({ status: 'open' }), { now }), false);

  assert.equal(pollMatchesFilter(open, f({ participated: 'yes' }), { now, votedByMe: true }), true);
  assert.equal(pollMatchesFilter(open, f({ participated: 'yes' }), { now, votedByMe: false }), false);
  assert.equal(pollMatchesFilter(open, f({ participated: 'no' }), { now, votedByMe: false }), true);
  assert.equal(pollMatchesFilter(open, f({ participated: 'no' }), { now, votedByMe: true }), false);

  assert.equal(pollMatchesFilter(open, f({ roomId: 'r2' }), { now }), false);
  assert.equal(pollMatchesFilter(open, f({ creatorId: '33333333-3333-4333-8333-333333333333' }), { now }), false);
  assert.equal(pollMatchesFilter(open, f({ creatorId: USER, roomId: 'r1' }), { now }), true);

  // 기간은 투표를 만든 시각(5000) 기준 — 양 끝 포함.
  assert.equal(pollMatchesFilter(open, f({ since: new Date(5000) }), { now }), true);
  assert.equal(pollMatchesFilter(open, f({ since: new Date(5001) }), { now }), false);
  assert.equal(pollMatchesFilter(open, f({ until: new Date(5000) }), { now }), true);
  assert.equal(pollMatchesFilter(open, f({ until: new Date(4999) }), { now }), false);
});

test('커서: formatCursor ↔ parseCursor 왕복, 정렬 비교는 (시각, id) 순', () => {
  assert.equal(formatCursor(1700000000123.9, USER), `1700000000123:${USER}`);
  assert.deepEqual(parseCursor(formatCursor(1700000000123, USER)), { ms: 1700000000123, id: USER });
  assert.equal(parseCursor(''), null);
  assert.equal(parseCursor(undefined), null);

  const a = { createdAt: 100, id: 'a' };
  const b = { createdAt: 100, id: 'b' };
  const c = { createdAt: 200, id: 'a' };
  assert.deepEqual([a, c, b].sort(compareByCursor('desc')), [c, b, a]);
  assert.deepEqual([c, b, a].sort(compareByCursor('asc')), [a, b, c]);
});
