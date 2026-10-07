// 기기 등록·푸시 토큰 칸 검사(devices.js) 단위 테스트 — `node --test test/*.test.js` (DB·서버 없이 돈다: db 메서드는 부르면 바로
// 실패하게 막아 두고, 등록이 실제로 넣는 값을 볼 때만 SQL을 받아 적는 가짜로 바꾼다. 접속 주소도 닿지 않는 값으로 정해 둔다 —
// 이 파일은 .env를 읽는 모듈을 불러오지 않는다).
//
// 지키려는 것: 로그인한 누구나 부르는 경로라, 문자열이 아니거나 아주 큰 값(기기 id·이름·공개키·FCM 토큰)을 쌓아 두지 못한다.
// 앱이 실제로 보내는 값(uuid 기기 id, 44자 base64 공개키, 'windows' 같은 이름, 200자 안팎의 FCM 토큰)은 그대로 받는다.
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { getTableColumns } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/node-postgres';

process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { devices } = await import('../src/db/schema.js');
const { DEVICE_NAME_MAX_LENGTH, createDevicesRouter, isDeviceId, parseDeviceName, parseDeviceRegistration, parseFcmToken } =
  await import('../src/devices.js');

const DEVICE_ID = '3f1c2b9a-7d4e-4c1a-9b2f-1e2d3c4b5a69';
const KEY_A = Buffer.alloc(32, 7).toString('base64'); // 44자 — 앱이 보내는 X25519 공개키 모양
const KEY_B = Buffer.alloc(32, 9).toString('base64');
const FCM = `dXyZ0123_-abc:APA91b${'Q'.repeat(140)}`;

test('parseDeviceRegistration: 앱이 보내는 값은 그대로 받는다', () => {
  assert.equal(KEY_A.length, 44);
  assert.deepEqual(
    parseDeviceRegistration({ deviceId: DEVICE_ID, name: 'windows', identityPublicKey: KEY_A, signingPublicKey: KEY_B }),
    { fields: { id: DEVICE_ID, name: 'windows', identityPublicKey: KEY_A, signingPublicKey: KEY_B } },
  );
  // 이름이 없거나 문자열이 아니면 이름 없이 등록한다(등록 자체는 막지 않는다). 모르는 칸은 저장하지 않는다.
  const noName = parseDeviceRegistration({
    deviceId: DEVICE_ID,
    identityPublicKey: KEY_A,
    signingPublicKey: KEY_B,
    platform: 'x'.repeat(50_000),
    model: { huge: true },
    appVersion: 1,
  });
  assert.deepEqual(noName.fields, { id: DEVICE_ID, name: null, identityPublicKey: KEY_A, signingPublicKey: KEY_B });
  assert.equal(parseDeviceRegistration({ deviceId: DEVICE_ID, name: 42, identityPublicKey: KEY_A, signingPublicKey: KEY_B }).fields.name, null);
  // URL 안전 base64·패딩 없는 키도 받는다.
  const urlSafe = KEY_A.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  assert.ok(parseDeviceRegistration({ deviceId: 'dev_1.a:b', identityPublicKey: urlSafe, signingPublicKey: KEY_B }).fields);
});

test('parseDeviceRegistration: 빠졌거나, 문자열이 아니거나, 모양·길이가 틀린 기기 id·공개키는 받지 않는다', () => {
  const ok = { deviceId: DEVICE_ID, identityPublicKey: KEY_A, signingPublicKey: KEY_B };
  assert.equal(parseDeviceRegistration({}).error, 'deviceId, identityPublicKey, signingPublicKey가 필요합니다.');
  assert.equal(parseDeviceRegistration(null).error, 'deviceId, identityPublicKey, signingPublicKey가 필요합니다.');
  for (const deviceId of ['', 'a/b', '../x', 'a b', 'a?b', 'x'.repeat(129), 12345, ['a'], { id: 'a' }, '기기']) {
    assert.equal(parseDeviceRegistration({ ...ok, deviceId }).error, 'deviceId가 올바르지 않습니다.', JSON.stringify(deviceId));
  }
  for (const key of ['', 'not base64!', 'A'.repeat(129), `${KEY_A}===`, 7, [KEY_A], { k: KEY_A }]) {
    assert.match(parseDeviceRegistration({ ...ok, identityPublicKey: key }).error, /공개키/, JSON.stringify(key));
    assert.match(parseDeviceRegistration({ ...ok, signingPublicKey: key }).error, /공개키/, JSON.stringify(key));
  }
  assert.equal(isDeviceId('x'.repeat(128)), true);
  assert.equal(isDeviceId('x'.repeat(129)), false);
});

test('parseDeviceName: 보여 주기만 하는 값이라 막지 않고 다듬는다 — 제어·방향 글자 빼고, 100자까지(이모지를 자르지 않는다)', () => {
  assert.equal(parseDeviceName('android'), 'android');
  assert.equal(parseDeviceName('  Galaxy S24\n'), 'Galaxy S24');
  assert.equal(parseDeviceName('내‮ PC\u0007'), '내 PC');
  assert.equal(parseDeviceName('a'.repeat(5000)).length, DEVICE_NAME_MAX_LENGTH);
  const emoji = parseDeviceName('😀'.repeat(150));
  assert.equal(Array.from(emoji).length, DEVICE_NAME_MAX_LENGTH);
  assert.ok(Array.from(emoji).every((ch) => ch === '😀'));
  for (const empty of ['', '   ', '‮​', null, undefined, 3, ['pc']]) assert.equal(parseDeviceName(empty), null, JSON.stringify(empty));
});

test('parseFcmToken: null·빈 값은 지우기, 공백·제어 문자 없는 4096자까지의 문자열만', () => {
  assert.deepEqual(parseFcmToken(null), { token: null });
  assert.deepEqual(parseFcmToken(''), { token: null });
  assert.deepEqual(parseFcmToken(FCM), { token: FCM });
  assert.deepEqual(parseFcmToken('x'.repeat(4096)), { token: 'x'.repeat(4096) });
  for (const bad of ['x'.repeat(4097), 'abc def', 'abc\n', '토큰', 'abc\u0000']) {
    assert.deepEqual(parseFcmToken(bad), { error: 'token이 올바르지 않습니다.' }, JSON.stringify(bad).slice(0, 40));
  }
  for (const bad of [undefined, 12, ['x'], { t: 'x' }]) {
    assert.deepEqual(parseFcmToken(bad), { error: 'token은 문자열 또는 null이어야 합니다.' }, String(bad));
  }
});

const router = createDevicesRouter();
const handlerOf = (method, path) => router.stack.find((l) => l.route?.path === path && l.route.methods[method]).route.stack[0].handle;

/** [method] [path] 처리 함수를 가짜 요청으로 부른 결과 — { status, body }. */
async function call(method, path, { params = {}, body = {} } = {}) {
  const out = { status: 200, body: null };
  const res = {
    status(code) {
      out.status = code;
      return res;
    },
    json(b) {
      out.body = b;
      return res;
    },
  };
  await handlerOf(method, path)({ params, body, user: { sub: '11111111-1111-4111-8111-111111111111' } }, res);
  return out;
}

test('라우트: 틀린 값은 DB에 닿기 전에 400/404 — 모양이 틀린 기기 id는 그런 기기가 없는 것과 같다', async () => {
  // db 메서드는 부르면 실패하게 막혀 있다 — 아래가 모두 그 전에 끝나야 한다.
  assert.equal((await call('post', '/devices', { body: { deviceId: 'a/b', identityPublicKey: KEY_A, signingPublicKey: KEY_B } })).status, 400);
  assert.equal((await call('post', '/devices', { body: { deviceId: DEVICE_ID, identityPublicKey: 'x'.repeat(50_000), signingPublicKey: KEY_B } })).status, 400);
  assert.equal((await call('patch', '/devices/:deviceId/fcm-token', { params: { deviceId: DEVICE_ID }, body: { token: 'x'.repeat(50_000) } })).status, 400);
  assert.equal((await call('patch', '/devices/:deviceId/fcm-token', { params: { deviceId: DEVICE_ID }, body: { token: 7 } })).status, 400);
  const notFound = { error: '기기를 찾을 수 없습니다.' };
  const longId = 'x'.repeat(5000);
  assert.deepEqual(await call('patch', '/devices/:deviceId/fcm-token', { params: { deviceId: longId }, body: { token: FCM } }), { status: 404, body: notFound });
  assert.deepEqual(await call('patch', '/devices/:deviceId/web-push', { params: { deviceId: longId }, body: { subscription: null } }), { status: 404, body: notFound });
  assert.deepEqual(await call('get', '/devices/:deviceId/public-key', { params: { deviceId: longId } }), { status: 404, body: notFound });
  assert.deepEqual(await call('delete', '/devices/:deviceId', { params: { deviceId: longId } }), { status: 404, body: notFound });
});

test('라우트: 등록은 다듬은 이름으로 넣는다 — 아주 긴 이름도 100자만 저장된다', async (t) => {
  const DEVICE_COLUMNS = Object.keys(getTableColumns(devices));
  const queries = [];
  const fake = drizzle({
    client: {
      async query(config, values = []) {
        queries.push({ text: typeof config === 'string' ? config : config.text, values });
        const row = {
          id: DEVICE_ID,
          userId: '11111111-1111-4111-8111-111111111111',
          name: values[2],
          identityPublicKey: KEY_A,
          signingPublicKey: KEY_B,
          createdAt: new Date('2026-10-01T00:00:00Z'),
          lastSeenAt: new Date('2026-10-01T00:00:00Z'),
        };
        return { rows: [DEVICE_COLUMNS.map((k) => row[k] ?? null)], rowCount: 1 };
      },
    },
  });
  t.mock.method(db, 'insert', (...args) => fake.insert(...args));
  const res = await call('post', '/devices', {
    body: { deviceId: DEVICE_ID, name: `PC${'가'.repeat(5000)}`, identityPublicKey: KEY_A, signingPublicKey: KEY_B },
  });
  assert.equal(res.status, 201);
  assert.equal(queries.length, 1);
  assert.match(queries[0].text, /^insert into "devices"/);
  const stored = queries[0].values.filter((v) => typeof v === 'string' && v.startsWith('PC'));
  assert.ok(stored.length >= 1);
  for (const name of stored) assert.equal(name.length, DEVICE_NAME_MAX_LENGTH);
  assert.ok(!queries[0].values.some((v) => typeof v === 'string' && v.length > 200));
  assert.equal(res.body.id, DEVICE_ID);
});
