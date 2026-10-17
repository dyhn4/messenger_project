// "다른 기기 접속 중에도 푸시"(notification_settings.pushWhileOnline) — `node --test test/*.test.js`. DB 없이 돈다:
// presence.js는 메모리 상태뿐이고, push.js·webPush.js·socket.js 등은 import하면 DB·Firebase에 붙어서 소스 글만 확인한다.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import {
  isDeviceConnected,
  isOnline,
  markConnected,
  markDisconnected,
  setPushWhileOnline,
  skipsPush,
} from '../src/presence.js';

let seq = 0;
const fresh = () => `pwo-${process.pid}-${++seq}`;

test('기기별로 연결을 센다 — 같은 기기의 소켓이 둘이면 둘 다 끊겨야 끊긴 것', () => {
  const user = fresh();
  const pc = fresh();
  const phone = fresh();
  assert.equal(isDeviceConnected(pc), false);
  markConnected(user, { deviceId: pc });
  markConnected(user, { deviceId: pc }); // 재연결이 잠깐 겹친 경우
  assert.equal(isDeviceConnected(pc), true);
  assert.equal(isDeviceConnected(phone), false); // 휴대폰은 안 붙어 있다 → 그 기기로는 푸시가 간다
  markDisconnected(user, pc);
  assert.equal(isDeviceConnected(pc), true);
  markDisconnected(user, pc);
  assert.equal(isDeviceConnected(pc), false);
  assert.equal(isOnline(user), false);
});

test('기기를 모르는 연결은 사람 단위로만 센다', () => {
  const user = fresh();
  assert.equal(markConnected(user), true);
  assert.equal(isOnline(user), true);
  assert.equal(markDisconnected(user), true);
  assert.equal(isOnline(user), false);
});

test('켬(기본): 접속 중이어도 사람을 빼지 않는다 — 접속해 있지 않은 기기로 간다', () => {
  const user = fresh();
  assert.equal(skipsPush(user), false); // 접속 안 함 → 늘 보낸다
  markConnected(user, { deviceId: fresh(), pushWhileOnline: true });
  assert.equal(skipsPush(user), false);
  markDisconnected(user);
});

test('설정을 모르면(접속할 때 못 읽음) 기본값(켬)으로 본다', () => {
  const user = fresh();
  markConnected(user, { deviceId: fresh() });
  assert.equal(skipsPush(user), false);
  markDisconnected(user);
});

test('끔: 어느 기기로든 접속해 있으면 아예 빼고(예전 동작), 다 끊기면 다시 보낸다', () => {
  const user = fresh();
  const pc = fresh();
  markConnected(user, { deviceId: pc, pushWhileOnline: false });
  assert.equal(skipsPush(user), true);
  markDisconnected(user, pc);
  assert.equal(skipsPush(user), false);
});

test('접속 중에 바꾸면 바로 따르고, 접속 안 한 사람의 값은 들고 있지 않는다(다음 접속 때 읽는다)', () => {
  const user = fresh();
  setPushWhileOnline(user, false); // 접속 전 — 무시
  markConnected(user, { deviceId: fresh() });
  assert.equal(skipsPush(user), false);
  setPushWhileOnline(user, false);
  assert.equal(skipsPush(user), true);
  setPushWhileOnline(user, true);
  assert.equal(skipsPush(user), false);
  markDisconnected(user);

  // 마지막 연결이 끊기면 값을 지운다 — 다시 붙을 때 DB 값을 새로 읽는다.
  const other = fresh();
  markConnected(other, { pushWhileOnline: false });
  markDisconnected(other);
  markConnected(other);
  assert.equal(skipsPush(other), false);
  markDisconnected(other);
});

// ─────────────────────────────── 연결 (소스 확인) ───────────────────────────────

const read = (name) => fs.readFileSync(new URL(`../src/${name}`, import.meta.url), 'utf8');

test('push.js: 사람 단위로는 skipsPush로만 빼고, FCM 토큰은 접속해 있지 않은 기기 것만 보낸다', () => {
  const push = read('push.js');
  assert.equal(/\bisOnline\b/.test(push), false, '사람 단위 isOnline으로 거르는 곳이 남으면 안 된다');
  const listCalls = push.match(/listFcmTokensForUser\(/g) ?? [];
  assert.equal(listCalls.length, 1, 'FCM 토큰은 pushableFcmTokens 한 곳에서만 읽는다');
  assert.match(push, /async function pushableFcmTokens\(userId\) \{\s*return \(await listFcmTokensForUser\(userId\)\)\.filter\(\(\{ deviceId \}\) => !isDeviceConnected\(deviceId\)\);/);
  assert.equal((push.match(/await pushableFcmTokens\(/g) ?? []).length, 6); // 채팅·프로젝트·결재·메일·통화·비밀 대화
  assert.equal((push.match(/skipsPush\(/g) ?? []).length, 6);
});

test('webPush.js: 소켓이 붙어 있는 기기(열린 웹 앱 탭)로는 웹 푸시를 보내지 않는다', () => {
  // 붙어 있는 기기를 빼는 규칙은 presence.js의 webPushTargets로 옮겼다(test/webPushDesktopDuplicate.test.js가 직접 돌려 본다).
  assert.match(read('webPush.js'), /subscriptions = webPushTargets\(subscriptions, appDeviceIds\);/);
});

test('멘션·할 일 푸시도 같은 규칙(skipsPush)', () => {
  assert.match(read('notifications.js'), /isOnline: skipsPush,/);
  const todos = read('todos.js');
  assert.equal(/\bisOnline\b/.test(todos), false);
  assert.equal((todos.match(/filter\(\(id\) => skipsPush\(id\)\)/g) ?? []).length, 2);
});

test('socket.js: 인증된 기기와 설정을 접속·끊김에 넘긴다', () => {
  const socket = read('socket.js');
  assert.match(socket, /markConnected\(socket\.data\.userId, \{\s*deviceId: socket\.data\.deviceId \?\? null,\s*pushWhileOnline: socket\.data\.pushWhileOnline,/);
  assert.match(socket, /markDisconnected\(socket\.data\.userId, socket\.data\.deviceId \?\? null\)/);
  assert.match(socket, /socket\.data\.pushWhileOnline = await getNotificationSettingsMap/);
});

test('notifications.js: 설정 저장은 참/거짓만 받고, 접속 중이면 바로 반영한다', () => {
  const route = read('notifications.js');
  const patch = route.slice(route.indexOf("router.patch('/notification-settings'"));
  assert.match(patch, /typeof body\.pushWhileOnline !== 'boolean'/);
  assert.match(patch, /setPushWhileOnline\(req\.user\.sub, saved\.pushWhileOnline\)/);
});
