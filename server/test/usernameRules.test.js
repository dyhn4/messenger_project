// 아이디 규칙(authGuard.js parseNewUsername·pickUsernameMatch)과 대소문자를 무시한 아이디 조회(db/queries/users.js) 단위 테스트 —
// `node --test test/*.test.js` (DB·서버 없이 돈다: db 메서드는 부르면 바로 실패하게 막아 두고, 쿼리 모양을 볼 때만 SQL을 받아
// 적는 가짜로 바꾼다. 접속 주소도 닿지 않는 값으로 정해 둔다 — 이 파일은 .env를 읽는 모듈을 불러오지 않는다).
//
// 지키려는 것: 새 아이디는 영문·숫자·. _ - 4~20자만, 대소문자만 다른 기존 아이디('Admin' ↔ 'admin')·앞뒤 공백('admin ')·모양만
// 비슷한 다른 글자(키릴 문자 а)로 다른 사람인 척하지 못한다. 그 전에 가입한 계정은 로그인·비밀번호 찾기·운영자 복구 스크립트가
// 같은 규칙으로 찾는다 — 글자까지 같은 계정이 먼저, 없으면 대소문자만 다른 계정이 하나일 때만(둘 이상이면 고르지 않는다).
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { PgDialect } from 'drizzle-orm/pg-core';
import { drizzle } from 'drizzle-orm/node-postgres';
import { USERNAME_PATTERN, USERNAME_RULE_ERROR, parseNewUsername, pickUsernameMatch } from '../src/authGuard.js';
import { decideGrant, parseArgs } from '../scripts/grant-server-admin.mjs';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { insertRegisteredUser, isUsernameTakenIgnoringCase, listUsersByUsernameIgnoringCase } = await import(
  '../src/db/queries/users.js'
);

test('parseNewUsername: 앞뒤 공백을 떼고 영문·숫자·. _ - 4~20자만 받는다(대소문자는 그대로)', () => {
  assert.deepEqual(parseNewUsername('hong.gil-dong_1'), { username: 'hong.gil-dong_1' });
  assert.deepEqual(parseNewUsername('  hong123 '), { username: 'hong123' });
  assert.deepEqual(parseNewUsername('Hong123'), { username: 'Hong123' });
  assert.deepEqual(parseNewUsername('abcd'), { username: 'abcd' });
  assert.deepEqual(parseNewUsername('a'.repeat(20)), { username: 'a'.repeat(20) });
  // 'admin '처럼 끝에 공백을 붙여 다른 아이디로 만들 수 없다 — 떼고 나면 'admin'이다(겹치는지는 가입 때 따로 본다).
  assert.deepEqual(parseNewUsername('admin '), { username: 'admin' });
  assert.deepEqual(parseNewUsername('\tadmin\n'), { username: 'admin' });
  for (const bad of [
    'abc',
    '   abc   ',
    'a'.repeat(21),
    '',
    '   ',
    '홍길동123',
    'ad min',
    'аdmin', // 첫 글자가 키릴 문자 а
    'ａｄｍｉｎ', // 전각 영문
    'admin@corp',
    'admin​', // 보이지 않는 글자
    'ad\nmin',
    'kim/../x',
    undefined,
    null,
    1234,
    ['admin'],
    { username: 'admin' },
  ]) {
    assert.deepEqual(parseNewUsername(bad), { error: USERNAME_RULE_ERROR }, JSON.stringify(bad));
  }
  assert.match(USERNAME_RULE_ERROR, /영문·숫자와 \. _ - 만/);
  assert.match(USERNAME_RULE_ERROR, /4~20자/);
  // 앱(login_screen.dart kSignupUsernamePattern)과 같은 규칙.
  assert.equal(USERNAME_PATTERN.source, '^[A-Za-z0-9._-]{4,20}$');
});

const acct = (id, username, more = {}) => ({ id, username, ...more });

test('pickUsernameMatch: 글자까지 같은 계정이 먼저, 없으면 대소문자만 다른 계정이 하나일 때만', () => {
  const kim = acct('k1', 'kim');
  const Kim = acct('k2', 'Kim');
  const KIM = acct('k3', 'KIM');
  assert.equal(pickUsernameMatch([Kim, kim, KIM], 'kim').user, kim);
  assert.equal(pickUsernameMatch([Kim, kim, KIM], 'Kim').user, Kim);
  assert.equal(pickUsernameMatch([Kim], 'kIM').user, Kim);
  assert.equal(pickUsernameMatch([Kim], '  KIM ').user, Kim); // 앱처럼 앞뒤 공백은 뗀다
  assert.deepEqual(pickUsernameMatch([KIM, Kim], 'kIm'), { user: null, ambiguous: true });
  assert.deepEqual(pickUsernameMatch([], 'kim'), { user: null, ambiguous: false });
  assert.deepEqual(pickUsernameMatch([kim], '   '), { user: null, ambiguous: false });
  assert.deepEqual(pickUsernameMatch([kim], undefined), { user: null, ambiguous: false });
  // 규칙 전에 가입한 한글 아이디도 글자 그대로 넣으면 찾는다.
  const korean = acct('h1', '홍길동');
  assert.equal(pickUsernameMatch([korean], '홍길동').user, korean);
  // 대소문자를 무시하고 같지 않은 계정은 DB가 잘못 줘도 고르지 않는다.
  assert.equal(pickUsernameMatch([acct('x', 'kimx')], 'kim').user, null);
});

test('운영자 복구 스크립트(grant-server-admin.mjs)도 같은 계정을 고른다 — 앞뒤 공백도 똑같이 뗀다', () => {
  const kim = acct('k1', 'kim', { name: '김', isServerAdmin: false });
  const Kim = acct('k2', 'Kim', { name: '김2', isServerAdmin: false });
  const KIM = acct('k3', 'KIM', { name: '김3', isServerAdmin: false });
  const cases = [
    ['kim', [Kim, kim, KIM]],
    ['Kim', [Kim, kim, KIM]],
    ['kIm', [Kim]],
    ['kIm', [KIM, Kim]],
    ['nobody', []],
  ];
  for (const [input, candidates] of cases) {
    const login = pickUsernameMatch(candidates, input);
    const grant = decideGrant({ username: input, admins: [], candidates });
    assert.equal(grant.ok ? grant.user : null, login.user, `${input} / ${candidates.map((c) => c.username)}`);
    assert.equal(grant.reason === 'ambiguous', login.ambiguous, input);
  }
  assert.deepEqual(parseArgs(['  kim ']), { username: 'kim' });
  assert.match(parseArgs(['   ']).error, /사용법/);
});

/** 이 테스트 동안 db.select를 SQL만 받아 적는 drizzle로 돌린다 — select 결과는 [rows](pg rowMode 'array' 모양). */
function recordQueries(t, rows = []) {
  const queries = [];
  const fake = drizzle({
    client: {
      async query(config, values = []) {
        queries.push({ text: typeof config === 'string' ? config : config.text, values });
        return { rows, rowCount: rows.length };
      },
    },
  });
  t.mock.method(db, 'select', (...args) => fake.select(...args));
  return queries;
}

test('대소문자를 무시한 조회: lower(username) = lower(값) — 쓸 수 없는 아이디인지는 한 줄만 본다', async (t) => {
  const queries = recordQueries(t);
  assert.deepEqual(await listUsersByUsernameIgnoringCase('Kim'), []);
  assert.equal(await isUsernameTakenIgnoringCase('Kim'), false);
  assert.match(queries[0].text, /from "users" where lower\("users"\."username"\) = lower\(\$1\)$/);
  assert.deepEqual(queries[0].values, ['Kim']);
  assert.match(queries[1].text, /^select "id" from "users" where lower\("users"\."username"\) = lower\(\$1\) limit \$2$/);
  assert.deepEqual(queries[1].values, ['Kim', 1]);
});

test('isUsernameTakenIgnoringCase: 한 줄이라도 있으면 쓸 수 없다', async (t) => {
  recordQueries(t, [['u-1']]);
  assert.equal(await isUsernameTakenIgnoringCase('kim'), true);
});

/**
 * db.transaction을 가짜 tx로 바꾼다 — [existing]은 이미 있는 계정 행(첫 계정인지 보는 조회), [sameName]은 대소문자를 무시하고
 * 같은 아이디 확인이 받는 행. tx가 받은 일을 순서대로 [log]에 남긴다.
 */
function fakeTransaction(t, { existing = [{ id: 'old' }], sameName = [] } = {}) {
  const dialect = new PgDialect();
  const log = [];
  const tx = {
    execute: async (query) => {
      const sql = dialect.sqlToQuery(query);
      log.push({ op: 'execute', sql: sql.sql, params: sql.params });
      return { rows: /lower\(/.test(sql.sql) ? sameName : [] };
    },
    select: () => ({
      from: () => ({
        limit: async () => {
          log.push({ op: 'checkExisting' });
          return existing;
        },
      }),
    }),
    insert: () => ({
      values: (values) => ({
        returning: async () => {
          log.push({ op: 'insert', values });
          return [{ id: 'new-user', ...values }];
        },
      }),
    }),
  };
  t.mock.method(db, 'transaction', async (fn) => fn(tx));
  return log;
}

test('insertRegisteredUser: 가입끼리 줄 세운 잠금 안에서 대소문자만 다른 같은 아이디를 다시 보고, 있으면 넣지 않는다', async (t) => {
  const log = fakeTransaction(t, { sameName: [{ '?column?': 1 }] });
  const result = await insertRegisteredUser({ username: 'Kim', role: 'guest' }, { role: 'admin', isServerAdmin: true });
  assert.deepEqual(result, { user: null, firstAccount: false, usernameTaken: true });
  assert.deepEqual(log.map((e) => e.op), ['execute', 'checkExisting', 'execute']);
  assert.match(log[0].sql, /pg_advisory_xact_lock/); // 잠금이 먼저
  assert.match(log[2].sql, /select 1 from "users" where lower\("users"\."username"\) = lower\(\$1\) limit 1/);
  assert.deepEqual(log[2].params, ['Kim']);
});

test('insertRegisteredUser: 겹치는 아이디가 없으면 그대로 넣고, 빈 서버의 첫 가입은 겹칠 계정이 없어 보지 않는다', async (t) => {
  let log = fakeTransaction(t);
  const second = await insertRegisteredUser({ username: 'lee', role: 'guest' }, { role: 'admin', isServerAdmin: true });
  assert.equal(second.user.username, 'lee');
  assert.equal(second.usernameTaken, undefined);
  assert.deepEqual(log.map((e) => e.op), ['execute', 'checkExisting', 'execute', 'insert']);

  log = fakeTransaction(t, { existing: [] });
  const first = await insertRegisteredUser({ username: 'boss', role: 'guest' }, { role: 'admin', isServerAdmin: true });
  assert.equal(first.firstAccount, true);
  assert.deepEqual(log.map((e) => e.op), ['execute', 'checkExisting', 'insert']);
});
