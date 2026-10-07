// 정지·탈퇴한 계정에 푸시를 보내지 않는 기기 조회(db/queries/devices.js listFcmTokensForUser·listWebPushSubscriptionsForUser)와
// 탈퇴 때 푸시 토큰·웹 푸시 구독 지우기(clearPushTargetsForUser) 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다).
// 모든 푸시(push.js·webPush.js)가 이 두 조회로 받을 기기를 고르므로, 여기서 계정 상태를 보는지만 지키면 된다. drizzle의 실제 쿼리
// 빌더에 SQL을 받아 적는 가짜 pg 클라이언트를 붙여 모양을 본다(접속 주소도 닿지 않는 값으로 정해 둔다).
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { drizzle } from 'drizzle-orm/node-postgres';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { PUSH_DEVICES_PER_USER, clearPushTargetsForUser, listFcmTokensForUser, listWebPushSubscriptionsForUser } = await import(
  '../src/db/queries/devices.js'
);

const USER = '11111111-1111-4111-8111-111111111111';

/** 이 테스트 동안 db.[methods]를 SQL만 받아 적는 drizzle로 돌린다 — select 결과는 [rows](pg rowMode 'array' 모양). */
function recordQueries(t, { rows = [], methods = ['select'] } = {}) {
  const queries = [];
  const fake = drizzle({
    client: {
      async query(config, values = []) {
        queries.push({ text: typeof config === 'string' ? config : config.text, values });
        return { rows, rowCount: rows.length };
      },
    },
  });
  for (const method of methods) t.mock.method(db, method, (...args) => fake[method](...args));
  return queries;
}

// 기기 행을 계정(users)과 이어서, 정지·탈퇴하지 않은 계정의 기기만 고른다.
const ACCOUNT_JOIN = 'inner join "users" on "users"."id" = "devices"."user_id"';
const ACCOUNT_ACTIVE = '("users"."suspended_at" is null and "users"."deleted_at" is null)';

test('listFcmTokensForUser: 정지·탈퇴한 계정이면 아무 기기도 고르지 않는다(최근 기기 상한은 그대로)', async (t) => {
  const queries = recordQueries(t, {
    rows: [
      ['phone', 'token-1'],
      ['old-phone', ''], // 빈 토큰은 보내지 않는다.
    ],
  });
  assert.deepEqual(await listFcmTokensForUser(USER), [{ deviceId: 'phone', fcmToken: 'token-1' }]);
  assert.equal(queries.length, 1);
  const [{ text, values }] = queries;
  assert.ok(text.startsWith(`select "devices"."id", "devices"."fcm_token" from "devices" ${ACCOUNT_JOIN} where (`), text);
  assert.ok(
    text.includes(
      `"devices"."user_id" = $1 and "devices"."revoked_at" is null and "devices"."fcm_token" is not null and ${ACCOUNT_ACTIVE}`,
    ),
    text,
  );
  assert.match(text, /order by "devices"\."last_seen_at" desc nulls last, "devices"\."created_at" desc limit \$2$/);
  assert.deepEqual(values, [USER, PUSH_DEVICES_PER_USER]);
  assert.equal(PUSH_DEVICES_PER_USER, 10);
});

test('listWebPushSubscriptionsForUser: 같은 계정 상태 조건으로 고르고, 망가진 구독은 null로 넘긴다', async (t) => {
  const subscription = { endpoint: 'https://fcm.googleapis.com/fcm/send/abc', keys: { p256dh: 'p', auth: 'a' } };
  const queries = recordQueries(t, {
    rows: [
      ['browser', JSON.stringify(subscription)],
      ['broken', '{not json'],
    ],
  });
  assert.deepEqual(await listWebPushSubscriptionsForUser(USER), [
    { deviceId: 'browser', subscription },
    { deviceId: 'broken', subscription: null }, // webPush.js가 보내기 전에 지운다.
  ]);
  assert.equal(queries.length, 1);
  const [{ text, values }] = queries;
  assert.ok(
    text.startsWith(`select "devices"."id", "devices"."web_push_subscription" from "devices" ${ACCOUNT_JOIN} where (`),
    text,
  );
  assert.ok(
    text.includes(
      `"devices"."user_id" = $1 and "devices"."revoked_at" is null and "devices"."web_push_subscription" is not null and ${ACCOUNT_ACTIVE}`,
    ),
    text,
  );
  assert.match(text, /limit \$2$/);
  assert.deepEqual(values, [USER, PUSH_DEVICES_PER_USER]);
});

test('clearPushTargetsForUser: 그 사람의 모든 기기(폐기된 기기 포함)에서 푸시 토큰·웹 푸시 구독을 지운다', async (t) => {
  const queries = recordQueries(t, { methods: ['update'] });
  await clearPushTargetsForUser(USER);
  assert.deepEqual(queries, [
    {
      text: 'update "devices" set "fcm_token" = $1, "web_push_subscription" = $2 where "devices"."user_id" = $3',
      values: [null, null, USER],
    },
  ]);
});
