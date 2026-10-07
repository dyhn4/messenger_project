import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { drizzle } from 'drizzle-orm/node-postgres';

// 기기 등록(upsertDevice)이 같은 기기 id의 키를 바꾸지 못하는지 — 상대 앱들이 이 기기의 서명 키를 처음 본 값으로 고정해 두므로
// (비밀 대화 키 고정), 같은 id에 다른 키를 올릴 수 있으면 로그인을 훔친 사람이 그 기기와의 비밀 대화를 모두 멈출 수 있다. 앱은 키를
// 잃으면 새 기기 id를 만들고, 거절(409)을 받아도 새 id로 다시 등록한다. DB 없이 drizzle이 만드는 SQL만 본다.

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { upsertDevice } = await import('../src/db/queries/devices.js');

test('같은 기기 id를 다시 등록할 때는 같은 사람이고 두 키가 모두 같을 때만 고친다(on conflict ... where)', async (t) => {
  const queries = [];
  const fake = drizzle({
    client: {
      async query(config, values = []) {
        queries.push({ text: typeof config === 'string' ? config : config.text, values });
        return { rows: [], rowCount: 0 }; // 조건이 맞지 않아 고치지 않은 경우 — 행이 돌아오지 않는다.
      },
    },
  });
  t.mock.method(db, 'insert', (...args) => fake.insert(...args));

  const row = await upsertDevice({
    id: 'device-1',
    userId: '11111111-1111-4111-8111-111111111111',
    name: 'Windows',
    identityPublicKey: 'ID-KEY',
    signingPublicKey: 'SIGN-KEY',
  });
  assert.equal(row, null, '고칠 수 없으면 null — 라우트가 409로 답하고 앱은 새 기기 id로 다시 등록한다');
  assert.equal(queries.length, 1);
  const { text, values } = queries[0];
  const where = text.slice(text.toLowerCase().lastIndexOf(' where '));
  assert.match(where, /"user_id" = \$\d+/);
  assert.match(where, /"identity_public_key" = \$\d+/);
  assert.match(where, /"signing_public_key" = \$\d+/);
  // 조건 자리에 실제로 이번 요청의 사용자·키가 들어간다.
  const placeholders = [...where.matchAll(/\$(\d+)/g)].map((m) => values[Number(m[1]) - 1]);
  assert.ok(placeholders.includes('11111111-1111-4111-8111-111111111111'));
  assert.ok(placeholders.includes('ID-KEY'));
  assert.ok(placeholders.includes('SIGN-KEY'));
});
