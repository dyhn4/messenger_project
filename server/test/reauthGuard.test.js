// 로그인한 사람의 비밀번호 재확인(authGuard.js runReauthAttempt — users.js checkCurrentPassword: 화면 잠금 해제·이메일 변경·
// 비밀번호 변경·탈퇴) 단위 테스트 — `node --test test/reauthGuard.test.js` (DB·서버 없이 돈다). 예전엔 막혔는지만 보고 bcrypt를
// 기다린 뒤에야 틀린 것을 세서, 훔친 AccessToken으로 요청을 한꺼번에 N개 보내면 15분에 10번 제한인데도 N번을 맞춰 볼 수 있었다.
// 확인을 시작할 때 "확인 중"으로 걸어 두는지(로그인·비밀번호 찾기와 같은 방식 — beginAttempts), 끝나면(오류로 끝나도) 놓는지 본다.
// 라우트 쪽은 users.js의 실제 처리 함수를 가짜 요청으로 부르고, 계정 조회는 drizzle에 계정 한 줄을 답하는 가짜 pg 클라이언트로
// 돌린다(접속 주소도 닿지 않는 값으로 정해 둔다 — test/avatarUpdateResign.test.js와 같은 방식).
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import bcrypt from 'bcryptjs';
import { getTableColumns } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/node-postgres';
import { FailureLimiter, limits, runReauthAttempt } from '../src/authGuard.js';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { users } = await import('../src/db/schema.js');
const { createUsersRouter } = await import('../src/users.js');

const MIN = 60 * 1000;
const BUSY_ERROR = '비밀번호 확인 시도가 너무 많습니다. 5초 후 다시 시도하세요.';
const BLOCKED_ERROR = '비밀번호 확인 시도가 너무 많습니다. 15분 후 다시 시도하세요.';

function clock(start = 0) {
  let t = start;
  return { now: () => t, advance: (ms) => (t += ms) };
}

/** 손으로 끝내는 비밀번호 확인 — 불린 비밀번호를 calls에 남기고, settle(true/false)를 부를 때까지 결과를 내지 않는다. */
function heldCheck() {
  const calls = [];
  let open;
  const gate = new Promise((resolve) => (open = resolve));
  return {
    calls,
    check: async (plain) => {
      calls.push(plain);
      return gate;
    },
    settle: (value) => open(value),
  };
}

test('한꺼번에 50개를 보내도 비밀번호는 10번만 맞춰 본다 — 나머지는 확인을 시작하기 전에 429(5초 뒤)', async () => {
  const c = clock(1_000_000);
  const limiter = new FailureLimiter({ max: 10, windowMs: 15 * MIN, blockMs: 15 * MIN, now: c.now });
  const guard = { reauthUser: limiter };
  const { calls, check, settle } = heldCheck();
  const running = Array.from({ length: 50 }, (_, i) =>
    runReauthAttempt({ key: 'u1', password: `guess-${i}`, checkPassword: check, guard }),
  );
  // 확인을 시작하는 데까지는 await가 없다 — 아직 아무 결과도 안 났는데 이미 10개에서 멈췄다(예전엔 50개 모두 들어갔다).
  assert.equal(calls.length, 10);
  assert.deepEqual(calls, Array.from({ length: 10 }, (_, i) => `guess-${i}`));
  assert.equal(limiter.pending.get('u1'), 10);
  settle(false);
  const results = await Promise.all(running);
  const busy = results.filter((r) => r.wait);
  assert.equal(busy.length, 40);
  for (const r of busy) assert.deepEqual(r, { wait: 5000, error: BUSY_ERROR });
  assert.equal(results.filter((r) => r.ok === false).length, 10);
  assert.equal(limiter.pending.size, 0, '끝난 확인은 모두 놓았다');
  // 10번 다 틀렸으니 막혔다 — 이제는 맞는 비밀번호여도 맞춰 보지 않는다(예전과 같다).
  const after = await runReauthAttempt({
    key: 'u1',
    password: 'right',
    checkPassword: async () => assert.fail('막혀 있는데 비밀번호를 맞춰 봤다'),
    guard,
  });
  assert.deepEqual(after, { wait: 15 * MIN, error: BLOCKED_ERROR });
  // 다른 계정은 따로 센다.
  assert.deepEqual(await runReauthAttempt({ key: 'u2', password: 'pw', checkPassword: async () => true, guard }), { ok: true });
});

test('틀리면 창 안에서 쌓이고 맞으면 지운다 — 막힌 계정이 다른 계정을 막지 않는다', async () => {
  const c = clock();
  const limiter = new FailureLimiter({ max: 3, windowMs: 1000, blockMs: 5000, now: c.now });
  const guard = { reauthUser: limiter };
  const wrong = async () => false;
  const right = async () => true;
  assert.deepEqual(await runReauthAttempt({ key: 'a', password: 'x', checkPassword: wrong, guard }), { ok: false });
  assert.deepEqual(await runReauthAttempt({ key: 'a', password: 'y', checkPassword: wrong, guard }), { ok: false });
  assert.equal(limiter.failures('a'), 2);
  assert.deepEqual(await runReauthAttempt({ key: 'a', password: 'ok', checkPassword: right, guard }), { ok: true });
  assert.equal(limiter.failures('a'), 0, '맞으면 틀린 기록을 지운다');
  for (let i = 0; i < 3; i += 1) await runReauthAttempt({ key: 'b', password: 'x', checkPassword: wrong, guard });
  assert.equal(limiter.blockedFor('b'), 5000);
  assert.deepEqual(await runReauthAttempt({ key: 'a', password: 'ok', checkPassword: right, guard }), { ok: true });
  // 차단이 끝나면 다시 맞춰 볼 수 있다.
  c.advance(5000);
  assert.deepEqual(await runReauthAttempt({ key: 'b', password: 'ok', checkPassword: right, guard }), { ok: true });
});

test('비밀번호가 비었으면 맞춰 보지 않고 틀린 것으로 센다 — 문자열이 아니면 문자열로 바꿔 맞춰 본다', async () => {
  const limiter = new FailureLimiter({ max: 10, windowMs: 1000, blockMs: 5000 });
  const guard = { reauthUser: limiter };
  for (const empty of [undefined, null, '']) {
    const r = await runReauthAttempt({
      key: 'e',
      password: empty,
      checkPassword: async () => assert.fail('빈 비밀번호를 맞춰 봤다'),
      guard,
    });
    assert.deepEqual(r, { ok: false }, String(empty));
  }
  assert.equal(limiter.failures('e'), 3);
  assert.equal(limiter.pending.size, 0);
  const seen = [];
  await runReauthAttempt({
    key: 'n',
    password: 12345678,
    checkPassword: async (plain) => {
      seen.push(plain);
      return false;
    },
    guard,
  });
  assert.deepEqual(seen, ['12345678']);
});

test('확인이 오류로 끝나도 "확인 중"을 놓는다 — 실패로는 세지 않고 오류는 그대로 던진다', async () => {
  const limiter = new FailureLimiter({ max: 1, windowMs: 1000, blockMs: 5000 });
  const guard = { reauthUser: limiter };
  await assert.rejects(
    runReauthAttempt({
      key: 'k',
      password: 'pw',
      checkPassword: async () => {
        throw new Error('bcrypt 오류');
      },
      guard,
    }),
    /bcrypt 오류/,
  );
  assert.equal(limiter.pending.size, 0);
  assert.equal(limiter.failures('k'), 0);
  // 한 번만 받는 칸인데도 바로 다시 확인할 수 있다 — 놓지 않았다면 칸이 꽉 찬 채로 남아 본인도 다시 확인하지 못한다.
  assert.deepEqual(await runReauthAttempt({ key: 'k', password: 'pw', checkPassword: async () => true, guard }), { ok: true });
});

// ── users.js 라우트(checkCurrentPassword) ─────────────────────────────

const PASSWORD = 'Correct-Horse-7';
const HASH = bcrypt.hashSync(PASSWORD, 4); // 테스트라 가장 싼 cost — 실제 서버는 10.
const columnKeys = new Map(Object.entries(getTableColumns(users)).map(([key, column]) => [column.name, key]));

/** 계정 하나 — users 표의 칸 이름(JS) 그대로. */
function account(id) {
  return {
    id,
    username: `user-${id.slice(0, 4)}`,
    name: '테스트',
    passwordHash: HASH,
    tokenVersion: 0,
    avatarType: 'initial',
    role: 'member',
    isServerAdmin: false,
  };
}

/** 이 테스트 동안 db.select가 [accounts]만 아는 가짜 drizzle로 돈다 — 계정 한 건 조회(findUserById)만 답한다. */
function fakeAccounts(t, accounts) {
  const fake = drizzle({
    client: {
      async query(config, values = []) {
        const text = typeof config === 'string' ? config : config.text;
        const select = /^select (.+) from "users" where "users"\."id" = \$1$/.exec(text.trim());
        if (!select) throw new Error(`테스트가 모르는 쿼리: ${text}`);
        const row = accounts.find((a) => a.id === values[0]);
        // 쿼리가 고른 칸 순서대로(drizzle은 행을 배열로 받는다).
        const names = select[1].split(', ').map((c) => c.replace(/"/g, ''));
        return { rows: row ? [names.map((name) => row[columnKeys.get(name)] ?? null)] : [] };
      },
    },
  });
  t.mock.method(db, 'select', (...args) => fake.select(...args));
}

const router = createUsersRouter({ in: () => ({ disconnectSockets() {} }) });
function handlerOf(method, path) {
  const layer = router.stack.find((l) => l.route?.path === path && l.route.methods[method]);
  assert.ok(layer, `${method.toUpperCase()} ${path} 라우트가 없다`);
  return layer.route.stack.at(-1).handle;
}

/** [method] [path] 처리 함수를 [userId]가 [body]로 부른 결과 — { status, body, headers }. */
async function call(method, path, userId, body) {
  const out = { status: 200, body: null, headers: {} };
  const res = {
    set(k, v) {
      out.headers[k] = v;
      return res;
    },
    status(code) {
      out.status = code;
      return res;
    },
    json(payload) {
      out.body = payload;
      return res;
    },
  };
  await handlerOf(method, path)({ body, user: { sub: userId }, params: {} }, res);
  return out;
}

test('라우트: 비밀번호 확인·이메일 변경·비밀번호 변경·탈퇴를 섞어 한꺼번에 보내도 한 계정은 10번만 맞춰 본다', async (t) => {
  const id = 'aaaaaaaa-0000-4000-8000-000000000001';
  fakeAccounts(t, [account(id)]);
  const compare = t.mock.method(bcrypt, 'compare');
  const requests = [];
  for (let i = 0; i < 6; i += 1) {
    requests.push(call('post', '/users/me/verify-password', id, { password: `wrong-${i}` }));
    requests.push(call('patch', '/users/me', id, { email: 'new@example.com', currentPassword: `wrong-${i}` }));
    requests.push(call('post', '/users/me/change-password', id, { currentPassword: `wrong-${i}`, newPassword: 'Zebra-Moon-482' }));
    requests.push(call('post', '/users/me/withdraw', id, { password: `wrong-${i}` }));
  }
  const results = await Promise.all(requests);
  // 틀린 비밀번호는 403 — 401이면 앱이 토큰을 새로 받아 같은 요청을 다시 보내 한 번 틀린 것이 두 번으로 세어진다(users.js).
  const wrong = results.filter((r) => r.status === 403);
  const busy = results.filter((r) => r.status === 429);
  assert.equal(wrong.length, 10, '네 경로가 한 계정의 칸을 함께 쓴다');
  assert.equal(busy.length, 14);
  assert.equal(compare.mock.callCount(), 10, 'bcrypt는 10번만 돌았다');
  for (const r of wrong) assert.match(r.body.error, /^(현재 )?비밀번호가 올바르지 않습니다\.$/);
  for (const r of busy) {
    assert.ok([BUSY_ERROR, BLOCKED_ERROR].includes(r.body.error), r.body.error);
    assert.ok(Number(r.headers['Retry-After']) >= 1);
  }
  assert.equal(limits.reauthUser.pending.size, 0, '끝난 확인은 모두 놓았다');
  // 10번 틀려 막혔다 — 맞는 비밀번호도 15분 동안은 받지 않는다(예전 문구 그대로).
  const blocked = await call('post', '/users/me/verify-password', id, { password: PASSWORD });
  assert.equal(blocked.status, 429);
  assert.equal(blocked.body.error, BLOCKED_ERROR);
  assert.equal(blocked.headers['Retry-After'], String(15 * 60));
});

test('라우트: 맞는 비밀번호는 통과하고 틀린 기록을 지운다, 응답 문구는 예전 그대로(상태는 401이 아니라 403)', async (t) => {
  const id = 'aaaaaaaa-0000-4000-8000-000000000002';
  fakeAccounts(t, [account(id)]);
  const wrong = await call('post', '/users/me/verify-password', id, { password: 'nope' });
  assert.deepEqual([wrong.status, wrong.body], [403, { error: '비밀번호가 올바르지 않습니다.' }]);
  const missing = await call('post', '/users/me/verify-password', id, {});
  assert.deepEqual([missing.status, missing.body], [403, { error: '비밀번호가 올바르지 않습니다.' }]);
  assert.equal(limits.reauthUser.failures(id), 2);
  const ok = await call('post', '/users/me/verify-password', id, { password: PASSWORD });
  assert.deepEqual([ok.status, ok.body], [200, { ok: true }]);
  assert.equal(limits.reauthUser.failures(id), 0);
  assert.equal(limits.reauthUser.pending.size, 0);
  // 새 비밀번호가 규칙에 안 맞으면 현재 비밀번호를 맞춰 보기 전에 거절한다(틀린 횟수에 세지 않는다 — 예전과 같다).
  const weak = await call('post', '/users/me/change-password', id, { currentPassword: 'nope', newPassword: 'short' });
  assert.equal(weak.status, 400);
  assert.equal(limits.reauthUser.failures(id), 0);
});

test('라우트: 이메일 변경은 비밀번호를 맞혀도 200자를 넘거나 문자열이 아닌 값을 받지 않는다(가입과 같은 상한)', async (t) => {
  // 본문 상한을 올리면서(bodyLimit.js) 길이를 안 보던 이 칸에 아주 긴 값을 저장할 수 있게 되지 않게.
  const id = 'aaaaaaaa-0000-4000-8000-000000000003';
  fakeAccounts(t, [account(id)]);
  for (const email of [`${'a'.repeat(189)}@example.com`, `${'a'.repeat(400_000)}@example.com`, ['a@b.c'], 12345]) {
    const r = await call('patch', '/users/me', id, { email, currentPassword: PASSWORD });
    assert.deepEqual([r.status, r.body], [400, { error: '이메일 형식이 올바르지 않습니다.' }], String(email).slice(0, 12));
  }
  assert.equal(limits.reauthUser.failures(id), 0, '비밀번호는 맞았다');
});
