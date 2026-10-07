// 서버 운영자 부트스트랩(첫 계정만 운영자)·마지막 운영자 보호(db/queries/users.js) 단위 테스트 — `node --test test/*.test.js`.
// DB에 붙지 않는다: db.transaction을 가짜 트랜잭션으로 바꿔 "무엇을 잠그고 무엇을 바꾸는지"만 보고, 나머지 db 메서드는
// 부르면 바로 실패하게 막아 둔다(접속 주소도 .env보다 먼저 닿지 않는 값으로 정해 둔다).
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { PgDialect } from 'drizzle-orm/pg-core';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { insertRegisteredUser, updateUserUnlessLastServerAdmin } = await import('../src/db/queries/users.js');

const dialect = new PgDialect();

/**
 * 이번 테스트 동안 db.transaction을 가짜 tx로 바꾼다 — [admins]는 잠근 활성 운영자 행, [existing]은 이미 있는 계정 행.
 * tx가 받은 일을 순서대로 [log]에 남긴다.
 */
function fakeTransaction(t, { admins = [], existing = [] } = {}) {
  const log = [];
  const tx = {
    execute: async (query) => {
      log.push({ op: 'execute', sql: dialect.sqlToQuery(query).sql });
      return { rows: [] };
    },
    select: () => ({
      from: () => ({
        where: (cond) => ({
          for: async (mode) => {
            log.push({ op: 'lockAdmins', mode, where: dialect.sqlToQuery(cond).sql });
            return admins;
          },
        }),
        limit: async (n) => {
          log.push({ op: 'checkExisting', n });
          return existing;
        },
      }),
    }),
    update: () => ({
      set: (patch) => ({
        where: () => ({
          returning: async () => {
            log.push({ op: 'update', patch });
            return [{ id: 'target', ...patch }];
          },
        }),
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

const FIELDS = { username: 'newbie', role: 'guest', isServerAdmin: false };
const FIRST = { role: 'admin', isServerAdmin: true };

test('insertRegisteredUser: 계정이 하나도 없는 서버의 첫 가입만 관리자 + 서버 운영자가 된다', async (t) => {
  const log = fakeTransaction(t, { existing: [] });
  const { user, firstAccount } = await insertRegisteredUser(FIELDS, FIRST);
  assert.equal(firstAccount, true);
  assert.equal(user.role, 'admin');
  assert.equal(user.isServerAdmin, true);
  // 확인보다 잠금이 먼저다 — 빈 서버에 동시에 들어온 가입 둘이 둘 다 "첫 계정"으로 보지 않게.
  assert.deepEqual(log.map((e) => e.op), ['execute', 'checkExisting', 'insert']);
  assert.match(log[0].sql, /pg_advisory_xact_lock/);
});

test('insertRegisteredUser: 계정이 하나라도 있으면(운영자가 없어도) 준회원으로 시작한다', async (t) => {
  // 예전 규칙("운영자가 한 명도 없으면")이면 마지막 운영자가 빠진 서버에서 이 가입자가 운영자가 됐다.
  const log = fakeTransaction(t, { existing: [{ id: 'old-user' }] });
  const { user, firstAccount } = await insertRegisteredUser(FIELDS, FIRST);
  assert.equal(firstAccount, false);
  assert.equal(user.role, 'guest');
  assert.equal(user.isServerAdmin, false);
  assert.deepEqual(log.at(-1), { op: 'insert', values: FIELDS });
});

test('updateUserUnlessLastServerAdmin: 활성 운영자는 탈퇴·정지되지 않은 운영자이고, 그 행들을 잠그고 센다', async (t) => {
  const log = fakeTransaction(t, { admins: [{ id: 'a' }, { id: 'b' }] });
  await updateUserUnlessLastServerAdmin('a', { isServerAdmin: false });
  const lock = log[0];
  assert.equal(lock.op, 'lockAdmins');
  assert.equal(lock.mode, 'update');
  assert.match(lock.where, /"is_server_admin" = \$1/);
  assert.match(lock.where, /"deleted_at" is null/);
  assert.match(lock.where, /"suspended_at" is null/);
});

test('updateUserUnlessLastServerAdmin: 마지막 활성 운영자의 탈퇴·정지·해제는 적용하지 않는다', async (t) => {
  for (const patch of [{ deletedAt: new Date() }, { suspendedAt: new Date() }, { isServerAdmin: false }]) {
    const log = fakeTransaction(t, { admins: [{ id: 'a' }] });
    assert.equal(await updateUserUnlessLastServerAdmin('a', patch), null);
    assert.ok(!log.some((e) => e.op === 'update'), '바꾸지 않아야 한다');
  }
});

test('updateUserUnlessLastServerAdmin: 다른 활성 운영자가 남거나, 대상이 운영자가 아니면 그대로 적용한다', async (t) => {
  let log = fakeTransaction(t, { admins: [{ id: 'a' }, { id: 'b' }] });
  assert.equal((await updateUserUnlessLastServerAdmin('a', { isServerAdmin: false })).isServerAdmin, false);
  assert.deepEqual(log.at(-1), { op: 'update', patch: { isServerAdmin: false } });

  // 일반 회원의 탈퇴는 운영자 수와 상관없다.
  log = fakeTransaction(t, { admins: [{ id: 'a' }] });
  assert.ok(await updateUserUnlessLastServerAdmin('member-1', { deletedAt: new Date() }));
  assert.equal(log.at(-1).op, 'update');

  // 활성 운영자가 이미 없는(예전에 마지막 운영자가 탈퇴한) 서버에서도 다른 회원 처리는 막히지 않는다.
  log = fakeTransaction(t, { admins: [] });
  assert.ok(await updateUserUnlessLastServerAdmin('member-2', { suspendedAt: new Date() }));
  assert.equal(log.at(-1).op, 'update');
});
