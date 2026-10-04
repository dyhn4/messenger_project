// 투표 목록(GET /api/polls) 순수 규칙 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { compareByCursor, formatCursor, parseCursor } from '../src/pageCursor.js';
import {
  DEADLINE_CLOSED_BASE,
  POLL_LIST_DEFAULT_LIMIT,
  POLL_LIST_MAX_LIMIT,
  compareByDeadline,
  parsePollListQuery,
  pollDeadlineKey,
  pollEndMs,
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
  assert.equal(ok.sort, 'created');
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

test('parsePollListQuery: sort는 created|deadline(기본 created, 빈 문자열은 안 준 것과 같다)', () => {
  assert.equal(parsePollListQuery({ teamId: TEAM, sort: 'deadline' }).sort, 'deadline');
  assert.equal(parsePollListQuery({ teamId: TEAM, sort: 'created' }).sort, 'created');
  assert.equal(parsePollListQuery({ teamId: TEAM, sort: '' }).sort, 'created');
  assert.ok(parsePollListQuery({ teamId: TEAM, sort: 'title' }).error);
  // 기한 순 커서도 "<키>:<id>" — 마감된 쪽 키(1e14 근처)도 그대로 읽힌다.
  const key = DEADLINE_CLOSED_BASE - 1700000000000;
  assert.deepEqual(parsePollListQuery({ teamId: TEAM, sort: 'deadline', before: `${key}:${USER}` }).cursor, {
    ms: key,
    id: USER,
  });
});

test('pollEndMs · pollDeadlineKey: 진행 중은 마감 시각, 마감됨은 기준값 - 끝난 시각(일찍 마감이면 마감한 시각)', () => {
  const now = 1_700_000_000_000;
  const open = { closedAt: null, closesAt: new Date(now + 5000) };
  const expired = { closedAt: null, closesAt: new Date(now - 5000) };
  const early = { closedAt: new Date(now - 100), closesAt: new Date(now + 9000) };
  assert.equal(pollEndMs(open), now + 5000);
  assert.equal(pollEndMs(early), now - 100);
  assert.equal(pollDeadlineKey(open, now), now + 5000);
  assert.equal(pollDeadlineKey(expired, now), DEADLINE_CLOSED_BASE - (now - 5000));
  assert.equal(pollDeadlineKey(early, now), DEADLINE_CLOSED_BASE - (now - 100));
  // 진행 중인 어떤 투표(2100년 마감)라도 마감된 투표보다 앞이다.
  const far = { closedAt: null, closesAt: new Date(Date.UTC(2100, 0, 1)) };
  assert.ok(pollDeadlineKey(far, now) < pollDeadlineKey(early, now));
  assert.ok(Number.isSafeInteger(DEADLINE_CLOSED_BASE));
});

test('기한 순: 진행 중(마감 가까운 순) → 마감됨(최근에 끝난 순), 같은 키는 id 순', () => {
  const now = 1_000_000;
  const p = (id, closesAt, closedAt = null) => ({ id, closesAt: new Date(closesAt), closedAt: closedAt && new Date(closedAt) });
  const polls = [
    p('a', now + 300),
    p('b', now - 50), // 마감(최근)
    p('c', now + 100),
    p('d', now - 900), // 마감(오래전)
    p('e', now + 9000, now - 10), // 일찍 마감(가장 최근)
    p('f', now + 100), // c와 같은 마감 시각 → id 순
  ];
  const sorted = [...polls].sort(compareByDeadline(now)).map((x) => x.id);
  assert.deepEqual(sorted, ['c', 'f', 'a', 'e', 'b', 'd']);
});

test('기한 순 쪽 나누기: "키:id" 커서로 이어 받으면 빠지거나 겹치는 것 없이 전부 나온다', () => {
  const now = 5_000_000;
  const all = [];
  for (let i = 0; i < 23; i++) {
    const id = `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`;
    // 같은 마감 시각이 여럿(i % 4), 절반은 마감됨.
    const closesAt = i % 2 === 0 ? now + 1000 * (i % 4) + 1 : now - 1000 * (i % 4) - 1;
    all.push({ id, closesAt: new Date(closesAt), closedAt: null });
  }
  const expected = [...all].sort(compareByDeadline(now)).map((x) => x.id);
  // SQL의 커서 조건과 같은 규칙: 키가 크거나, 같으면 id가 크다.
  const pageAfter = (cursor, limit) =>
    [...all]
      .sort(compareByDeadline(now))
      .filter((x) => {
        if (!cursor) return true;
        const k = pollDeadlineKey(x, now);
        return k > cursor.ms || (k === cursor.ms && x.id > cursor.id);
      })
      .slice(0, limit);
  const seen = [];
  let cursor = null;
  for (let guard = 0; guard < 10; guard++) {
    const page = pageAfter(cursor, 5);
    seen.push(...page.map((x) => x.id));
    if (page.length < 5) break;
    const last = page[page.length - 1];
    cursor = parseCursor(formatCursor(pollDeadlineKey(last, now), last.id));
  }
  assert.deepEqual(seen, expected);
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
