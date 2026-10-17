// 앱을 켜 둔 기기에서 웹 앱 탭을 닫으면 앱 알림과 브라우저(웹 푸시) 알림이 둘 다 뜨던 문제 — PC(PC 앱 + 크롬)와 안드로이드(안드로이드
// 앱 + 모바일 크롬). `node --test test/*.test.js`. presence.js는 메모리 상태뿐이라 직접 돌리고, webPush.js·devices.js 연결은 소스
// 글로 확인한다(import하면 DB에 붙는다).
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { mock, test } from 'node:test';
import { markConnected, markDisconnected, webPushTargets } from '../src/presence.js';

// devices.js는 DB 모듈을 불러온다 — 닿지 않는 주소를 정해 두고 DB 메서드는 부르면 실패하게 막는다(deviceFields.test.js와 같다).
process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/unused';
const { db } = await import('../src/db/client.js');
for (const method of ['select', 'insert', 'update', 'delete', 'execute', 'transaction']) {
  mock.method(db, method, () => {
    throw new Error(`이 테스트는 DB를 쓰면 안 된다(db.${method})`);
  });
}
const { parseDeviceKind, parseDeviceRegistration } = await import('../src/devices.js');

let seq = 0;
const fresh = () => `wpd-${process.pid}-${++seq}`;
const sub = (kind) => ({ deviceId: fresh(), kind, subscription: {} });

test('PC 앱이 접속해 있으면 PC 브라우저로는 웹 푸시를 보내지 않고, 다른 브라우저·종류 모르는 기기로는 보낸다', () => {
  const user = fresh();
  const pcApp = fresh();
  const chrome = sub('web-desktop');
  const androidChrome = sub('web-android');
  const iphone = sub('web-mobile');
  const legacy = sub(null);
  const all = [chrome, androidChrome, iphone, legacy];
  const apps = { windows: [pcApp], android: [] };

  // PC 앱이 꺼져 있으면 모두 받는다(크롬이 그 PC의 유일한 알림 통로).
  assert.deepEqual(webPushTargets(all, apps), all);

  markConnected(user, { deviceId: pcApp });
  try {
    assert.deepEqual(webPushTargets(all, apps), [androidChrome, iphone, legacy]);
    // PC 앱 기기를 모르면(예전 앱으로 등록) 지금처럼 보낸다.
    assert.deepEqual(webPushTargets(all, {}), all);
  } finally {
    markDisconnected(user, pcApp);
  }
  assert.deepEqual(webPushTargets(all, apps), all);
});

test('안드로이드 앱이 접속해 있으면 안드로이드 브라우저로는 웹 푸시를 보내지 않고, 아이폰·PC 브라우저로는 보낸다', () => {
  const user = fresh();
  const phoneApp = fresh();
  const chrome = sub('web-desktop');
  const androidChrome = sub('web-android');
  const iphone = sub('web-mobile');
  const all = [chrome, androidChrome, iphone];
  const apps = { windows: [], android: [phoneApp] };

  assert.deepEqual(webPushTargets(all, apps), all, '안드로이드 앱이 꺼져 있으면 모바일 크롬도 받는다');
  markConnected(user, { deviceId: phoneApp });
  try {
    assert.deepEqual(webPushTargets(all, apps), [chrome, iphone]);
  } finally {
    markDisconnected(user, phoneApp);
  }
});

test('웹 앱 탭이 열려 소켓이 붙은 기기는 종류와 상관없이 웹 푸시를 받지 않는다(예전과 같다)', () => {
  const user = fresh();
  const iphone = sub('web-mobile');
  markConnected(user, { deviceId: iphone.deviceId });
  try {
    assert.deepEqual(webPushTargets([iphone], {}), []);
  } finally {
    markDisconnected(user, iphone.deviceId);
  }
});

test('기기 등록: 아는 종류만 받고 모르는 값은 null(예전 앱과 같게)', () => {
  for (const kind of ['windows', 'android', 'ios', 'web-desktop', 'web-android', 'web-mobile']) {
    assert.equal(parseDeviceKind(kind), kind);
  }
  assert.equal(parseDeviceKind('linux'), null);
  assert.equal(parseDeviceKind(undefined), null);
  assert.equal(parseDeviceKind(3), null);
  const base = { deviceId: 'dev-1', identityPublicKey: 'a'.repeat(44), signingPublicKey: 'b'.repeat(44) };
  assert.equal(parseDeviceRegistration({ ...base, kind: 'web-android' }).fields.kind, 'web-android');
  assert.equal(parseDeviceRegistration(base).fields.kind, null);
});

test('연결: 웹 푸시는 PC·안드로이드 브라우저 구독이 있을 때만 앱 기기를 묻고 webPushTargets로 거르며, 다시 등록할 때 종류를 지우지 않는다', () => {
  const webPush = fs.readFileSync(new URL('../src/webPush.js', import.meta.url), 'utf8');
  assert.match(webPush, /subscriptions\.some\(\(s\) => s\.kind === 'web-desktop' \|\| s\.kind === 'web-android'\)/);
  assert.match(webPush, /subscriptions = webPushTargets\(subscriptions, appDeviceIds\);/);
  const queries = fs.readFileSync(new URL('../src/db/queries/devices.js', import.meta.url), 'utf8');
  assert.match(queries, /\.\.\.\(kind \? \{ kind \} : \{\}\)/);
  assert.match(queries, /inArray\(devices\.kind, \['windows', 'android'\]\)/);
});
