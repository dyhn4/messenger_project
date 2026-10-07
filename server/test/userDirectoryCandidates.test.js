// 팀 설정 "팀원 추가" 후보(teams.js GET /teams/:id/member-candidates, userDirectory.js) 단위 테스트 — `node --test test/*.test.js`
// (DB·서버 없이 돈다). 라우트 처리 함수를 가짜 요청으로 직접 부르고, drizzle의 실제 쿼리 빌더에 아주 작은 가짜 표(계정·팀·팀 멤버)를
// 답하는 pg 클라이언트를 붙인다(접속 주소도 닿지 않는 값으로 정해 둔다).
//
// 지키려는 것: 관리자 등급이 아닌 팀 소유자 — 기본 설정에서는 정회원 누구나 팀을 만들어 소유자가 된다 — 가 이 목록으로 서버 전체
// 회원 명단(아이디 포함)을 받아 가지 못하는 것. 팀을 같이 쓰는 사람만 받고, 팀 밖 사람은 아이디를 정확히 알 때만 한 명씩 찾는다.
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { getTableColumns } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/node-postgres';
import { RateLimiter } from '../src/authGuard.js';
import {
  MEMBER_LOOKUP_RATE,
  memberCandidateScope,
  parseCandidateUsername,
  seesWholeDirectory,
} from '../src/userDirectory.js';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'selectDistinct', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { users: usersTable, teams: teamsTable } = await import('../src/db/schema.js');
const { createTeamsRouter } = await import('../src/teams.js');

const USER_COLUMNS = Object.keys(getTableColumns(usersTable));
const TEAM_COLUMNS = Object.keys(getTableColumns(teamsTable));
/** 행 하나를 pg가 rowMode 'array'로 돌려주는 모양(스키마 열 순서)으로. */
const asRow = (columns, fields) => columns.map((key) => fields[key] ?? null);

const CREATED = '2026-10-01T00:00:00.000Z';
const account = (id, fields = {}) => ({
  id,
  username: `${id}-login`,
  name: id,
  role: 'member',
  isServerAdmin: false,
  avatarType: 'initial',
  tokenVersion: 0,
  createdAt: CREATED,
  suspendedAt: null,
  deletedAt: null,
  ...fields,
});

/**
 * 가짜 서버 — 'own'은 팀 t1을 만든 정회원(소유자)이고 t2에서 'kim'·'sus'(정지)·'gone'(탈퇴)과 함께 있다. 'lee'는 'own'과 겹치는 팀이
 * 없고, 'newbie'는 가입만 해서 어느 팀에도 없다. 'adm'은 계정 등급 관리자(t1 멤버 아님), 'srv'는 정회원 등급의 서버 운영자로 t4의
 * 소유자다. 'rl'은 횟수 제한만 따로 보려고 둔 t5의 소유자다.
 */
const ACCOUNTS = [
  account('own'),
  account('mem'),
  account('kim', { name: '김철수' }),
  account('sus', { name: '정지된 사람', suspendedAt: CREATED }),
  account('gone', { name: '탈퇴한 사용자', deletedAt: CREATED }),
  account('lee', { name: '이영희' }),
  account('newbie', { name: '신입', role: 'guest' }),
  account('adm', { name: '관리자', role: 'admin' }),
  account('srv', { name: '운영자', isServerAdmin: true }),
  account('rl', { name: '소유자2' }),
];
const TEAMS = ['t1', 't2', 't3', 't4', 't5'].map((id) => ({ id, name: id, createdAt: CREATED }));
const MEMBERSHIPS = [
  { teamId: 't1', userId: 'own', role: 'owner' },
  { teamId: 't1', userId: 'mem', role: 'member' },
  { teamId: 't2', userId: 'own', role: 'member' },
  { teamId: 't2', userId: 'kim', role: 'member' },
  { teamId: 't2', userId: 'sus', role: 'member' },
  { teamId: 't2', userId: 'gone', role: 'member' },
  { teamId: 't3', userId: 'lee', role: 'owner' },
  { teamId: 't3', userId: 'adm', role: 'member' },
  { teamId: 't4', userId: 'srv', role: 'owner' },
  { teamId: 't5', userId: 'rl', role: 'owner' },
];

/**
 * 이 테스트 동안 db.select·db.selectDistinct를 위 가짜 표로 답하는 drizzle로 돌린다 — 이 라우트가 내는 쿼리 모양만 알아듣고,
 * 모르는 쿼리는 실패시킨다. 받은 SQL은 돌려주는 목록에 쌓인다.
 */
function fakeServer(t) {
  const queries = [];
  const fake = drizzle({
    client: {
      async query(config, values = []) {
        const text = typeof config === 'string' ? config : config.text;
        queries.push({ text, values });
        if (/ from "teams" where "teams"\."id" = \$1$/.test(text)) {
          return { rows: TEAMS.filter((x) => x.id === values[0]).map((x) => asRow(TEAM_COLUMNS, x)) };
        }
        if (
          text ===
          'select "role" from "team_members" where ("team_members"."team_id" = $1 and "team_members"."user_id" = $2)'
        ) {
          return {
            rows: MEMBERSHIPS.filter((x) => x.teamId === values[0] && x.userId === values[1]).map((x) => [x.role]),
          };
        }
        if (text === 'select "user_id" from "team_members" where "team_members"."team_id" = $1') {
          return { rows: MEMBERSHIPS.filter((x) => x.teamId === values[0]).map((x) => [x.userId]) };
        }
        if (
          text ===
          'select distinct "user_id" from "team_members" where "team_members"."team_id" in ' +
            '(select "team_id" from "team_members" where "team_members"."user_id" = $1)'
        ) {
          const mine = new Set(MEMBERSHIPS.filter((x) => x.userId === values[0]).map((x) => x.teamId));
          const ids = new Set(MEMBERSHIPS.filter((x) => mine.has(x.teamId)).map((x) => x.userId));
          return { rows: [...ids].map((id) => [id]) };
        }
        const rowsOf = (list) => ({ rows: list.map((u) => asRow(USER_COLUMNS, u)) });
        if (/ from "users" where "users"\."id" = \$1$/.test(text)) return rowsOf(ACCOUNTS.filter((u) => u.id === values[0]));
        if (/ from "users" where "users"\."username" = \$1$/.test(text)) {
          return rowsOf(ACCOUNTS.filter((u) => u.username === values[0]));
        }
        if (/ from "users" where "users"\."deleted_at" is null$/.test(text)) {
          return rowsOf(ACCOUNTS.filter((u) => !u.deletedAt));
        }
        if (/ from "users" where \("users"\."id" in \([$\d, ]+\) and "users"\."deleted_at" is null\)$/.test(text)) {
          return rowsOf(ACCOUNTS.filter((u) => values.includes(u.id) && !u.deletedAt));
        }
        throw new Error(`테스트가 모르는 쿼리: ${text}`);
      },
    },
  });
  t.mock.method(db, 'select', (...args) => fake.select(...args));
  t.mock.method(db, 'selectDistinct', (...args) => fake.selectDistinct(...args));
  return queries;
}

/** 서버 전체 회원을 읽는 쿼리(listActiveUsers)였는지. */
const isWholeDirectoryQuery = (q) => / from "users" where "users"\."deleted_at" is null$/.test(q.text);
const isUsernameQuery = (q) => / from "users" where "users"\."username" = \$1$/.test(q.text);

const router = createTeamsRouter({ to: () => ({ emit() {} }) });
const handler = router.stack.find((l) => l.route?.path === '/teams/:id/member-candidates' && l.route.methods.get)
  .route.stack[0].handle;

/** GET /teams/:teamId/member-candidates를 [userId]가 [query]로 부른 결과 — { status, body, headers }. */
async function candidates(userId, teamId, query = {}) {
  const out = { status: 200, body: null, headers: {} };
  const res = {
    status(code) {
      out.status = code;
      return res;
    },
    json(body) {
      out.body = body;
      return res;
    },
    set(name, value) {
      out.headers[name] = value;
      return res;
    },
  };
  await handler({ params: { id: teamId }, query, user: { sub: userId } }, res);
  return out;
}
const ids = (body) => body.users.map((u) => u.id).sort();

test('memberCandidateScope: 서버 전체는 계정 등급 관리자·서버 운영자만 — 팀 소유자라는 것만으로는 아니다', () => {
  assert.equal(memberCandidateScope(account('a', { role: 'admin' })), 'all');
  assert.equal(memberCandidateScope(account('s', { role: 'guest', isServerAdmin: true })), 'all');
  assert.equal(memberCandidateScope(account('m')), 'coTeam');
  assert.equal(memberCandidateScope(account('g', { role: 'guest' })), 'coTeam');
  assert.equal(memberCandidateScope(account('x', { role: 'owner' })), 'coTeam'); // 팀 역할은 계정 등급이 아니다.
  assert.equal(memberCandidateScope(null), 'coTeam');
  // 회원 목록(GET /users)과 같은 기준이다.
  for (const u of ACCOUNTS) assert.equal(memberCandidateScope(u) === 'all', seesWholeDirectory(u), u.id);
});

test('parseCandidateUsername: 앞뒤 공백만 떼고, 가입 규칙(4~20자) 밖이거나 문자열이 아니면 null', () => {
  assert.equal(parseCandidateUsername('hong123'), 'hong123');
  assert.equal(parseCandidateUsername('  hong123 '), 'hong123');
  assert.equal(parseCandidateUsername('Hong123'), 'Hong123'); // 대소문자는 그대로(로그인처럼 정확히 같은 아이디만).
  assert.equal(parseCandidateUsername('abcd'), 'abcd');
  assert.equal(parseCandidateUsername('a'.repeat(20)), 'a'.repeat(20));
  for (const bad of ['abc', '   abc   ', '', '   ', 'a'.repeat(21), undefined, null, 1234, ['hong123'], { a: 1 }]) {
    assert.equal(parseCandidateUsername(bad), null, JSON.stringify(bad));
  }
});

test('MEMBER_LOOKUP_RATE: 10분에 30번까지 — 31번째부터 막힌다', () => {
  let now = 0;
  const limiter = new RateLimiter({ ...MEMBER_LOOKUP_RATE, now: () => now });
  for (let i = 0; i < 30; i += 1) assert.equal(limiter.hit('me'), 0, `${i + 1}번째`);
  assert.ok(limiter.hit('me') > 0);
  assert.equal(limiter.hit('someone-else'), 0); // 사람 단위다.
  now = MEMBER_LOOKUP_RATE.windowMs;
  assert.equal(limiter.hit('me'), 0); // 창이 지나면 다시 센다.
});

test('관리자 등급이 아닌 소유자는 팀을 같이 쓰는 사람만 받는다 — 서버 전체 회원을 읽지도 않는다', async (t) => {
  const queries = fakeServer(t);
  const { status, body } = await candidates('own', 't1');
  assert.equal(status, 200);
  assert.equal(body.scope, 'coTeam');
  // t2에서 같이 있는 kim만 — 정지(sus)·탈퇴(gone)한 계정, 이미 팀원인 사람(own·mem), 겹치는 팀이 없는 lee·newbie·adm·srv는 없다.
  assert.deepEqual(ids(body), ['kim']);
  assert.deepEqual(Object.keys(body.users[0]).sort(), [
    'avatarColor',
    'avatarEmoji',
    'avatarType',
    'avatarUrl',
    'id',
    'name',
    'role',
    'username',
  ]);
  assert.equal(queries.some(isWholeDirectoryQuery), false);
});

test('계정 등급 관리자와 서버 운영자는 서버 전체 후보를 받는다', async (t) => {
  fakeServer(t);
  // 관리자는 t1 멤버가 아니어도 그 팀을 관리할 수 있다(permissions.js canManageTeam) — 자기 자신도 후보다.
  const admin = await candidates('adm', 't1');
  assert.equal(admin.status, 200);
  assert.equal(admin.body.scope, 'all');
  assert.deepEqual(ids(admin.body), ['adm', 'kim', 'lee', 'newbie', 'rl', 'srv']);
  // 서버 운영자는 계정 등급이 정회원이어도 회원 목록처럼 전체를 본다(자기가 소유자인 팀에서).
  const server = await candidates('srv', 't4');
  assert.equal(server.body.scope, 'all');
  assert.deepEqual(ids(server.body), ['adm', 'kim', 'lee', 'mem', 'newbie', 'own', 'rl']);
});

test('그 팀을 관리할 수 없으면 403, 없는 팀이면 404 — 아이디로 찾기도 마찬가지', async (t) => {
  const queries = fakeServer(t);
  assert.deepEqual(await candidates('mem', 't1'), {
    status: 403,
    body: { error: '멤버를 추가할 권한이 없습니다.' },
    headers: {},
  });
  assert.equal((await candidates('newbie', 't1', { username: 'kim-login' })).status, 403);
  // 서버 운영자라도 계정 등급이 관리자가 아니면 남의 팀은 관리하지 못한다(팀원 추가 POST와 같은 권한).
  assert.equal((await candidates('srv', 't1')).status, 403);
  assert.equal((await candidates('own', 'no-such-team')).status, 404);
  assert.equal(queries.some(isUsernameQuery), false);
});

test('아이디로 찾기: 아이디가 정확히 같고 넣을 수 있는 사람만 — 팀 밖 사람도 찾는다', async (t) => {
  fakeServer(t);
  const found = await candidates('own', 't1', { username: 'newbie-login' });
  assert.equal(found.status, 200);
  assert.equal(found.body.scope, 'username');
  assert.deepEqual(ids(found.body), ['newbie']);
  assert.equal(found.body.users[0].username, 'newbie-login');
  assert.equal(found.body.users[0].role, 'guest');
  assert.deepEqual(ids((await candidates('own', 't1', { username: '  lee-login ' })).body), ['lee']);

  // 못 찾은 것과 찾았지만 넣을 수 없는 것을 똑같이 빈 목록으로 답한다(정지·탈퇴 여부를 알려 주지 않는다).
  for (const username of ['NEWBIE-LOGIN', 'newbie-logi', 'sus-login', 'gone-login', 'mem-login', 'own-login', 'nobody']) {
    const { status, body } = await candidates('own', 't1', { username });
    assert.equal(status, 200, username);
    assert.deepEqual(body, { scope: 'username', users: [] }, username);
  }
});

test('아이디로 찾기: 가입 규칙에 안 맞는 값은 DB에 묻지 않고 400', async (t) => {
  const queries = fakeServer(t);
  for (const username of ['abc', '   ', '', 'a'.repeat(21), ['kim-login', 'lee-login'], { $ne: '' }]) {
    const { status, body } = await candidates('own', 't1', { username });
    assert.equal(status, 400, JSON.stringify(username));
    assert.deepEqual(body, { error: '찾을 아이디를 정확히 입력하세요(4~20자).' });
  }
  assert.equal(queries.some(isUsernameQuery), false);
});

test('아이디로 찾기 횟수 제한: 관리자 등급이 아니면 10분에 30번 — 넘으면 DB에 묻지 않고 429(Retry-After)', async (t) => {
  const queries = fakeServer(t);
  for (let i = 0; i < MEMBER_LOOKUP_RATE.max; i += 1) {
    assert.equal((await candidates('rl', 't5', { username: `guess${i}` })).status, 200, `${i + 1}번째`);
  }
  const before = queries.filter(isUsernameQuery).length;
  const blocked = await candidates('rl', 't5', { username: 'newbie-login' });
  assert.equal(blocked.status, 429);
  assert.deepEqual(blocked.body, { error: '아이디로 찾기가 너무 많습니다. 10분 후 다시 시도하세요.' });
  assert.ok(Number(blocked.headers['Retry-After']) > 0);
  assert.equal(queries.filter(isUsernameQuery).length, before);
  // 막힌 동안에도 팀을 같이 쓰는 사람 목록은 그대로 받는다(세는 것은 아이디로 찾기뿐이다).
  assert.equal((await candidates('rl', 't5')).status, 200);
  // 잘못된 입력(400)은 세지 않고 막지도 않는다 — 그 전에 걸러진다.
  assert.equal((await candidates('rl', 't5', { username: 'abc' })).status, 400);

  // 서버 전체를 보는 관리자는 세지 않는다(이미 전부 보인다).
  for (let i = 0; i < MEMBER_LOOKUP_RATE.max + 5; i += 1) {
    assert.equal((await candidates('adm', 't1', { username: `guess${i}` })).status, 200, `관리자 ${i + 1}번째`);
  }
});
