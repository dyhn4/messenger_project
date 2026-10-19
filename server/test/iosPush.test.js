// 아이폰 앱 푸시(APNs) — 기기 종류에 맞춘 FCM 메시지(fcmMessage.js)와 뒤로 간 아이폰 기기로도 보내기(presence.js) 단위 테스트.
// `node --test test/*.test.js` — DB·Firebase 없이 돈다. 만든 메시지는 firebase-admin이 보내기 전에 하는 검사(validateMessage)에
// 그대로 넣어 본다 — 키 이름(threadId → thread-id 등)이 틀리면 실제 발송 때 서버 로그에만 남고 알림이 안 간다.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { APNS_TEXT_MAX, clipAlertText, fcmMessageFor } from '../src/fcmMessage.js';
import { isDeviceConnected, markConnected, markDisconnected, pushesToDevice, setDeviceBackground } from '../src/presence.js';

const here = path.dirname(fileURLToPath(import.meta.url));
// 패키지 exports에 없는 내부 파일이라 경로로 직접 읽는다(firebase-admin이 send() 안에서 부르는 그 검사).
const { validateMessage } = createRequire(import.meta.url)(
  path.join(here, '..', 'node_modules', 'firebase-admin', 'lib', 'messaging', 'messaging-internal.js'),
);

const content = {
  android: { data: { kind: 'message', roomId: 'r1', title: '김철수', body: '안녕' }, android: { priority: 'high' } },
  ios: { title: '🔒 김철수 [1:1]', body: '새 메시지가 있습니다', threadId: 'r1', data: { kind: 'message', roomId: 'r1' } },
};

test('안드로이드·종류를 모르는 예전 기기는 지금까지의 data 메시지 그대로', () => {
  for (const kind of ['android', null, undefined, 'windows']) {
    const message = fcmMessageFor({ fcmToken: 'tok', kind }, content);
    assert.deepEqual(message, { token: 'tok', ...content.android });
    validateMessage(structuredClone(message));
  }
});

test('아이폰은 OS가 그릴 알림(alert) + 누를 때 쓸 data만 — 소리, 방마다 한 묶음', () => {
  const message = fcmMessageFor({ fcmToken: 'tok', kind: 'ios' }, content);
  assert.equal(message.token, 'tok');
  assert.deepEqual(message.data, { kind: 'message', roomId: 'r1' });
  assert.equal(message.android, undefined);
  assert.deepEqual(message.apns.headers, { 'apns-push-type': 'alert', 'apns-priority': '10' });
  const { aps } = message.apns.payload;
  assert.deepEqual(aps.alert, { title: '🔒 김철수 [1:1]', body: '새 메시지가 있습니다' });
  assert.equal(aps.sound, 'default');
  const checked = structuredClone(message);
  validateMessage(checked);
  // firebase-admin이 APNs 이름으로 바꿔 보낸다.
  assert.equal(checked.apns.payload.aps['thread-id'], 'r1');
});

test('아이폰 통화 알림은 지나면 버린다(apns-expiration = 지금 + ttl)', () => {
  const before = Math.floor(Date.now() / 1000);
  const message = fcmMessageFor(
    { fcmToken: 'tok', kind: 'ios' },
    { android: {}, ios: { title: '김철수', body: '화상회의 요청', data: { kind: 'call', roomId: 'r1' }, ttlSeconds: 45 } },
  );
  const expiration = Number(message.apns.headers['apns-expiration']);
  assert.ok(expiration >= before + 45 && expiration <= before + 47, String(expiration));
  assert.equal(message.apns.payload.aps.threadId, undefined); // 묶지 않을 때는 키를 아예 안 넣는다.
  validateMessage(structuredClone(message));
});

test('긴 미리보기는 잘라 싣는다 — APNs 4KB 제한, 이모지를 반으로 가르지 않는다', () => {
  assert.equal(clipAlertText('짧은 글'), '짧은 글');
  assert.equal(clipAlertText(null), '');
  const long = '가'.repeat(APNS_TEXT_MAX + 50);
  const clipped = clipAlertText(long);
  assert.equal(Array.from(clipped).length, APNS_TEXT_MAX);
  assert.ok(clipped.endsWith('…'));
  const emoji = '😀'.repeat(APNS_TEXT_MAX + 1);
  assert.ok(!/[\uD800-\uDBFF]…$/.test(clipAlertText(emoji))); // 앞 반쪽만 남은 서로게이트가 없다.
  const message = fcmMessageFor({ fcmToken: 'tok', kind: 'ios' }, { android: {}, ios: { title: long, body: long, data: {} } });
  assert.equal(Array.from(message.apns.payload.aps.alert.body).length, APNS_TEXT_MAX);
});

let seq = 0;
const fresh = () => `ios-${process.pid}-${++seq}`;

test('뒤로 간 아이폰 기기는 소켓이 붙어 있어도 푸시를 보내고, 돌아오면 다시 소켓으로', () => {
  const user = fresh();
  const phone = fresh();
  assert.equal(pushesToDevice(phone), true); // 안 붙어 있다
  markConnected(user, { deviceId: phone });
  assert.equal(pushesToDevice(phone), false);
  setDeviceBackground(phone, true);
  assert.equal(isDeviceConnected(phone), true); // "로그인한 기기"의 사용 중 표시는 그대로
  assert.equal(pushesToDevice(phone), true);
  setDeviceBackground(phone, false);
  assert.equal(pushesToDevice(phone), false);
  markDisconnected(user, phone);
});

test('뒤로 간 표시는 기기의 마지막 소켓이 끊기면 지운다 — 다시 붙으면 앞에 있는 것으로 시작', () => {
  const user = fresh();
  const phone = fresh();
  markConnected(user, { deviceId: phone });
  markConnected(user, { deviceId: phone }); // 재연결 겹침
  setDeviceBackground(phone, true);
  markDisconnected(user, phone);
  assert.equal(pushesToDevice(phone), true); // 아직 소켓 하나가 남았지만 뒤에 있다
  markDisconnected(user, phone);
  markConnected(user, { deviceId: phone });
  assert.equal(pushesToDevice(phone), false);
  markDisconnected(user, phone);
});

test('붙어 있지 않은 기기의 "뒤로 감"은 남기지 않는다(늦게 온 신호)', () => {
  const user = fresh();
  const phone = fresh();
  setDeviceBackground(phone, true);
  markConnected(user, { deviceId: phone });
  assert.equal(pushesToDevice(phone), false);
  setDeviceBackground(null, true); // 기기를 모르는 소켓은 무시
  markDisconnected(user, phone);
});

test('socket.js가 인증된 기기의 app:background만 받아 presence에 넘긴다', () => {
  const src = fs.readFileSync(path.join(here, '..', 'src', 'socket.js'), 'utf8');
  const at = src.indexOf("socket.on('app:background'");
  assert.ok(at > 0);
  const handler = src.slice(at, src.indexOf('});', at));
  assert.match(handler, /if \(!socket\.data\.deviceId \|\| typeof payload\?\.background !== 'boolean'\) return;/);
  assert.match(handler, /setDeviceBackground\(socket\.data\.deviceId, payload\.background\)/);
});

test('push.js는 모든 FCM 발송을 기기 종류에 맞춰(fcmMessageFor) 보내고, 뒤로 간 아이폰도 대상에 넣는다', () => {
  const src = fs.readFileSync(path.join(here, '..', 'src', 'push.js'), 'utf8');
  assert.equal((src.match(/messaging\.send\(/g) ?? []).length, 1);
  assert.match(src, /messaging\.send\(fcmMessageFor\(device, content\)\)/);
  assert.match(src, /filter\(\(\{ deviceId \}\) => pushesToDevice\(deviceId\)\)/);
  // 아이폰 앱이 Firebase를 켤 값(GoogleService-Info.plist)도 내준다.
  assert.match(src, /iosApiKey: settings\.fcmIosApiKey \?\? null/);
  assert.match(src, /iosAppId: settings\.fcmIosAppId \?\? null/);
});
