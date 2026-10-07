// 서버 운영자 복구 스크립트(scripts/grant-server-admin.mjs) 단위 테스트 — `node --test test/*.test.js`.
// DB·.env를 건드리지 않는다: 누구를 지정할지(decideGrant)와 문구는 순수 함수로, 한 트랜잭션 안의 잠금·변경 순서는 받은
// 쿼리를 적어 두는 가짜 client로 본다. 스크립트를 직접 실행해 보는 것은 인자가 틀린 경우뿐이다(.env를 읽기 전에 끝난다).
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  EXIT_ERROR,
  auditEntryFor,
  decideGrant,
  describeDbError,
  envErrorMessage,
  grantServerAdmin,
  isActiveServerAdmin,
  parseArgs,
  refusalLines,
  successLines,
} from '../scripts/grant-server-admin.mjs';

const SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'scripts', 'grant-server-admin.mjs');

const account = (over = {}) => ({
  id: 'u-kim',
  username: 'kim',
  name: '김철수',
  isServerAdmin: false,
  deletedAt: null,
  suspendedAt: null,
  ...over,
});
const LONG_AGO = new Date('2025-01-01T00:00:00Z');

test('isActiveServerAdmin: 탈퇴·정지되지 않은 운영자만(verify-admin.mjs와 같은 기준)', () => {
  assert.equal(isActiveServerAdmin(account({ isServerAdmin: true })), true);
  assert.equal(isActiveServerAdmin(account({ isServerAdmin: true, deletedAt: LONG_AGO })), false);
  assert.equal(isActiveServerAdmin(account({ isServerAdmin: true, suspendedAt: LONG_AGO })), false);
  assert.equal(isActiveServerAdmin(account()), false);
});

test('decideGrant: 활성 운영자가 한 명이라도 있으면 아무도 지정하지 않는다', () => {
  const admins = [account({ id: 'a2', username: 'park', isServerAdmin: true }), account({ id: 'a1', username: 'choi', isServerAdmin: true })];
  const decision = decideGrant({ username: 'kim', admins, candidates: [account()] });
  assert.deepEqual(decision, { ok: false, reason: 'active-admin', activeAdmins: ['choi', 'park'] });
  assert.match(refusalLines(decision, 'kim').join('\n'), /관리자 콘솔/);
});

test('decideGrant: 탈퇴·정지된 운영자만 남은 서버는 운영자가 없는 서버다', () => {
  const admins = [
    account({ id: 'w', username: 'oldboss', isServerAdmin: true, deletedAt: LONG_AGO }), // 예전 규칙 때 마지막 운영자가 탈퇴
    account({ id: 's', username: 'lee', isServerAdmin: true, suspendedAt: LONG_AGO }),
  ];
  const decision = decideGrant({ username: 'kim', admins, candidates: [account()] });
  assert.equal(decision.ok, true);
  assert.equal(decision.user.id, 'u-kim');
  // 정지된 운영자 본인을 고르면 정지만 풀면 된다.
  const self = decideGrant({ username: 'lee', admins, candidates: [admins[1]] });
  assert.equal(self.ok, true);
  assert.equal(self.user.id, 's');
});

test('decideGrant: 아이디는 글자까지 같은 계정이 먼저, 없으면 대소문자만 다른 계정 하나만', () => {
  const kim = account({ id: 'k1', username: 'kim' });
  const Kim = account({ id: 'k2', username: 'Kim' });
  const KIM = account({ id: 'k3', username: 'KIM' });
  // 글자까지 같은 계정이 있으면 대소문자만 다른 계정이 더 있어도 그 계정.
  assert.equal(decideGrant({ username: 'kim', admins: [], candidates: [Kim, kim, KIM] }).user.id, 'k1');
  assert.equal(decideGrant({ username: 'Kim', admins: [], candidates: [Kim, kim, KIM] }).user.id, 'k2');
  // 없으면 대소문자만 다른 계정이 하나일 때만.
  assert.equal(decideGrant({ username: 'kIm', admins: [], candidates: [Kim] }).user.id, 'k2');
  const ambiguous = decideGrant({ username: 'kIm', admins: [], candidates: [KIM, Kim] });
  assert.deepEqual(ambiguous, { ok: false, reason: 'ambiguous', usernames: ['KIM', 'Kim'] });
  assert.match(refusalLines(ambiguous, 'kIm').join('\n'), /KIM, Kim/);
  assert.deepEqual(decideGrant({ username: 'nobody', admins: [], candidates: [] }), { ok: false, reason: 'not-found' });
});

test('decideGrant: 탈퇴한 계정은 지정하지 않고, 대소문자만 다른 다른 사람으로 넘어가지도 않는다', () => {
  const withdrawn = account({ id: 'k1', username: 'kim', name: '탈퇴한 사용자', deletedAt: LONG_AGO });
  const other = account({ id: 'k2', username: 'Kim' });
  const decision = decideGrant({ username: 'kim', admins: [], candidates: [withdrawn, other] });
  assert.equal(decision.ok, false);
  assert.equal(decision.reason, 'withdrawn');
  assert.equal(decision.user.id, 'k1');
  assert.match(refusalLines(decision, 'kim')[0], /^'kim'은\(는\) 탈퇴한 계정/);
  // 대소문자만 다른 유일한 계정이 탈퇴한 계정이어도 마찬가지.
  assert.equal(decideGrant({ username: 'KIM', admins: [], candidates: [withdrawn] }).reason, 'withdrawn');
});

test('decideGrant: 정지된 일반 계정도 지정할 수 있다(정지도 함께 푼다)', () => {
  const decision = decideGrant({ username: 'kim', admins: [], candidates: [account({ suspendedAt: LONG_AGO })] });
  assert.equal(decision.ok, true);
  assert.match(successLines(decision.user, { audited: true })[0], /서버 운영자로 지정했습니다\(정지돼 있던 것도 풀었습니다\)/);
});

test('successLines / auditEntryFor: 바뀐 것에 맞는 문구와 관리자 콘솔과 같은 감사 로그 종류', () => {
  assert.deepEqual(successLines(account(), { audited: true }), [
    "'kim'(김철수) 계정을 서버 운영자로 지정했습니다.",
    '그 계정으로 로그인하면 관리자 콘솔을 쓸 수 있습니다 — 이미 로그인해 있다면 앱을 다시 시작하세요.',
  ]);
  assert.match(successLines(account({ isServerAdmin: true, suspendedAt: LONG_AGO }), { audited: true })[0], /정지를 풀었습니다 — 이미 서버 운영자였으므로/);
  assert.match(successLines(account({ name: 'kim' }), { audited: true })[0], /^'kim' 계정을/);
  assert.match(successLines(account(), { audited: false }).at(-1), /감사 로그는 남기지 못했습니다/);

  assert.equal(auditEntryFor(account()).action, 'user.serverAdmin');
  assert.match(auditEntryFor(account()).detail, /^서버 운영자로 지정\(/);
  assert.match(auditEntryFor(account({ suspendedAt: LONG_AGO })).detail, /^서버 운영자로 지정·정지 해제\(/);
  assert.equal(auditEntryFor(account({ isServerAdmin: true, suspendedAt: LONG_AGO })).action, 'user.unsuspend');
});

test('parseArgs: 아이디 하나만 받는다', () => {
  assert.deepEqual(parseArgs(['kim']), { username: 'kim' });
  assert.deepEqual(parseArgs(['김 철수']), { username: '김 철수' });
  for (const bad of [[], [''], ['kim', 'lee'], ['--help'], ['-h'], ['/?']]) {
    assert.match(parseArgs(bad).error, /사용법/, JSON.stringify(bad));
  }
});

/**
 * 받은 쿼리를 차례로 적고, 운영자·대상 계정 조회에는 정해 둔 행을 돌려주는 가짜 pg client. [failOn]이 든 쿼리에서는
 * [error]를 던진다(그 쿼리도 적어 둔다).
 */
function fakeClient({ admins = [], candidates = [], updateCount = 1, failOn = null, error = new Error('boom') } = {}) {
  const log = [];
  return {
    log,
    sql: () => log.map((q) => q.sql),
    async query(text, params = []) {
      const sql = text.replace(/\s+/g, ' ').trim();
      log.push({ sql, params });
      if (failOn && sql.includes(failOn)) throw error;
      if (sql.includes('FROM users WHERE is_server_admin = true')) return { rows: admins, rowCount: admins.length };
      if (sql.includes('FROM users WHERE lower(username)')) return { rows: candidates, rowCount: candidates.length };
      if (sql.startsWith('UPDATE users')) return { rows: [], rowCount: updateCount };
      return { rows: [], rowCount: 0 };
    },
  };
}

test('grantServerAdmin: 한 트랜잭션에서 잠그고 확인한 뒤 운영자 표시·정지만 바꾸고 감사 로그를 남긴다', async () => {
  const client = fakeClient({
    admins: [account({ id: 'w', username: 'oldboss', isServerAdmin: true, deletedAt: LONG_AGO })],
    candidates: [account({ suspendedAt: LONG_AGO })],
  });
  const result = await grantServerAdmin(client, 'kim');
  assert.equal(result.ok, true);
  assert.equal(result.audited, true);
  const sql = client.sql();
  assert.equal(sql[0], 'BEGIN');
  assert.equal(sql[1], "SET LOCAL lock_timeout = '15s'");
  // 두 실행이 서로 다른 계정을 함께 지정하지 못하게 — 활성 운영자가 없으면 행 잠금으로는 잠글 것이 없다.
  assert.equal(sql[2], "SELECT pg_advisory_xact_lock(hashtext('users:grant-server-admin'))");
  assert.match(sql[3], /FROM users WHERE is_server_admin = true ORDER BY id FOR UPDATE$/);
  assert.match(sql[4], /FROM users WHERE lower\(username\) = lower\(\$1::text\) ORDER BY id FOR UPDATE$/);
  assert.deepEqual(client.log[4].params, ['kim']);
  // 바꾸는 것은 운영자 표시와 정지뿐 — 등급·토큰 버전은 건드리지 않는다.
  assert.equal(sql[5], 'UPDATE users SET is_server_admin = true, suspended_at = NULL WHERE id = $1 AND deleted_at IS NULL');
  assert.deepEqual(client.log[5].params, ['u-kim']);
  assert.doesNotMatch(sql[5], /token_version|role/);
  assert.equal(sql[6], 'SAVEPOINT grant_audit');
  assert.match(sql[7], /^INSERT INTO audit_logs \(actor_name, action, target_type, target_id, target_label, detail\)/);
  assert.deepEqual(client.log[7].params.slice(1, 4), ['user.serverAdmin', 'u-kim', '김철수']);
  assert.equal(sql[8], 'RELEASE SAVEPOINT grant_audit');
  assert.equal(sql[9], 'COMMIT');
  assert.equal(sql.length, 10);
});

test('grantServerAdmin: 거절이면 아무것도 바꾸지 않고 롤백한다', async () => {
  const cases = [
    ['활성 운영자가 있음', { admins: [account({ id: 'a', username: 'park', isServerAdmin: true })], candidates: [account()] }, 'active-admin'],
    ['계정 없음', { candidates: [] }, 'not-found'],
    ['탈퇴한 계정', { candidates: [account({ deletedAt: LONG_AGO })] }, 'withdrawn'],
  ];
  for (const [name, rows, reason] of cases) {
    const client = fakeClient(rows);
    const result = await grantServerAdmin(client, 'kim');
    assert.equal(result.reason, reason, name);
    const sql = client.sql();
    assert.equal(sql.at(-1), 'ROLLBACK', name);
    assert.ok(!sql.some((q) => q.startsWith('UPDATE') || q.startsWith('INSERT') || q === 'COMMIT'), name);
  }
});

test('grantServerAdmin: 도중에 DB 오류가 나면 롤백하고 오류를 그대로 던진다', async () => {
  const lockTimeout = Object.assign(new Error('canceling statement due to lock timeout'), { code: '55P03', severity: 'ERROR' });
  const client = fakeClient({ candidates: [account()], failOn: 'FOR UPDATE', error: lockTimeout });
  await assert.rejects(grantServerAdmin(client, 'kim'), (err) => err === lockTimeout);
  const sql = client.sql();
  assert.equal(sql.at(-1), 'ROLLBACK');
  assert.ok(!sql.some((q) => q.startsWith('UPDATE') || q === 'COMMIT'));
  assert.match(describeDbError(lockTimeout), /잠시 뒤 다시 실행하세요 \(55P03\)/);

  // 바꾼 행이 없으면(그럴 일은 없어야 하지만) 지정했다고 하지 않는다.
  const none = fakeClient({ candidates: [account()], updateCount: 0 });
  await assert.rejects(grantServerAdmin(none, 'kim'), /대상 계정을 바꾸지 못했습니다/);
  assert.equal(none.sql().at(-1), 'ROLLBACK');
  assert.ok(!none.sql().includes('COMMIT'));
});

test('grantServerAdmin: 감사 로그를 못 남겨도 그 한 줄만 되돌리고 지정은 커밋한다', async () => {
  const client = fakeClient({ candidates: [account()], failOn: 'INSERT INTO audit_logs' });
  const result = await grantServerAdmin(client, 'kim');
  assert.equal(result.ok, true);
  assert.equal(result.audited, false);
  const sql = client.sql();
  assert.deepEqual(sql.slice(-3), ['INSERT INTO audit_logs (actor_name, action, target_type, target_id, target_label, detail) VALUES ($1, $2, \'user\', $3, $4, $5)', 'ROLLBACK TO SAVEPOINT grant_audit', 'COMMIT']);
  assert.ok(sql.some((q) => q.startsWith('UPDATE users')));
});

test('describeDbError: 접속 단계 오류의 문구(접속 주소·비밀번호가 섞일 수 있다)는 보이지 않는다', () => {
  const secret = 'postgres://tango:S3cret!@127.0.0.1:5432/messenger';
  const leaky = [
    Object.assign(new Error(`connect ECONNREFUSED ${secret}`), { code: 'ECONNREFUSED' }),
    Object.assign(new Error(`getaddrinfo ENOTFOUND ${secret}`), { code: 'ENOTFOUND' }),
    Object.assign(new TypeError(`Invalid URL ${secret}`), { code: 'ERR_INVALID_URL' }),
    Object.assign(new Error(`weird ${secret}`), { code: 'ESOMETHING' }),
    new Error(`Invalid sslmode: ${secret}`), // pg 접속 설정 오류는 code 없이 값을 싣는다
  ];
  for (const err of leaky) {
    const text = describeDbError(err);
    assert.doesNotMatch(text, /S3cret|tango|5432|postgres:/, text);
  }
  assert.match(describeDbError(leaky[0]), /PostgreSQL 서비스가 실행 중인지 확인하세요 \(ECONNREFUSED\)/);
  assert.equal(describeDbError(leaky[4]), 'DB 오류');
  assert.match(describeDbError(new Error('timeout expired')), /응답하지 않아/);
  // PostgreSQL 서버가 돌려준 오류는 접속 정보가 없어 문구를 보인다.
  const serverError = Object.assign(new Error('column "is_server_admin" does not exist'), { code: '42703', severity: 'ERROR' });
  assert.equal(describeDbError(serverError), 'DB 오류 (42703): column "is_server_admin" does not exist');
  assert.match(describeDbError(Object.assign(new Error('password authentication failed for user "tango"'), { code: '28P01', severity: 'FATAL' })), /DB 비밀번호가 맞지 않습니다/);
});

test('envErrorMessage: .env를 못 읽은 까닭에 맞춰 안내한다', () => {
  assert.match(envErrorMessage(Object.assign(new Error('x'), { code: 'EPERM' }), 'C:\\x\\.env'), /관리자 권한으로 실행하세요/);
  assert.match(envErrorMessage(Object.assign(new Error('x'), { code: 'EACCES' }), 'C:\\x\\.env'), /관리자 권한으로 실행하세요/);
  assert.match(envErrorMessage(Object.assign(new Error('x'), { code: 'ENOENT' }), 'C:\\x\\.env'), /\.env 파일이 없습니다\(C:\\x\\\.env\)/);
  assert.equal(envErrorMessage(undefined, 'C:\\x\\.env'), '.env에 DATABASE_URL이 없습니다.');
});

test('직접 실행하면 인자부터 본다 — 아이디가 없거나 여럿이면 .env를 읽기 전에 사용법과 함께 exit 2', () => {
  // 혹시 인자 검사를 지나치더라도 실제 DB에 닿지 않게 접속 주소를 닿지 않는 값으로 둔다(dotenv는 있는 값을 덮지 않는다).
  const env = { ...process.env, DATABASE_URL: 'postgres://test:test@127.0.0.1:1/unused' };
  for (const args of [[], ['kim', 'lee']]) {
    const run = spawnSync(process.execPath, [SCRIPT, ...args], { encoding: 'utf8', env, timeout: 30_000 });
    assert.equal(run.status, EXIT_ERROR, JSON.stringify(args));
    assert.match(run.stderr, /사용법: node scripts\/grant-server-admin\.mjs <아이디>/);
    assert.equal(run.stdout, '');
  }
});
