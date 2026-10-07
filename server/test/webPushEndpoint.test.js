// 웹 푸시 구독 검사(webPushEndpoint.js) 단위 테스트 — `node --test test/*.test.js` (DB·서버·네트워크 없이 돈다).
// 서버가 구독의 endpoint로 직접 POST를 보내므로, 브라우저 푸시 서비스가 아닌 주소(사내망·IP·다른 포트 등)는 받지 않는다.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { test } from 'node:test';
import { parse as legacyParse } from 'node:url';
import webpush from 'web-push';
import { normalizeWebPushEndpoint, parseWebPushSubscription } from '../src/webPushEndpoint.js';

// web-push가 쓰는 옛 url.parse의 경고 — 아래에서 일부러 같은 함수로 확인하므로 출력만 끈다.
process.noDeprecation = true;

const CHROME = 'https://fcm.googleapis.com/fcm/send/dXk4abcDEF:APA91bHPRgkF3JUikC4ENAHEeMrd41Zxv3hVZjC9KtT8OvPVGJ-hQMRKRrZuJAEcl7B3';
const CHROME_WP = 'https://fcm.googleapis.com/wp/dXk4abcDEF:APA91bHPRgkF3JUikC4ENAHEeMrd41Zxv3hVZjC9KtT8';
const FIREFOX = 'https://updates.push.services.mozilla.com/wpush/v2/gAAAAABl_abc-DEF123ghiJKL456mnoPQR789';
const SAFARI = 'https://web.push.apple.com/QGuQyavXutnMH2hhb7Fs1bUMkV-jBcKx5W6Wf0aXg7FSE3fq0WCw-7eQ2XkVfrXcTmjm4C8';
const EDGE = 'https://wns2-par02p.notify.windows.com/w/?token=BQYAAAB%2bAbCdEf%2fGh%3d';

function keys() {
  const ecdh = crypto.createECDH('prime256v1');
  return {
    p256dh: ecdh.generateKeys().toString('base64url'), // 65바이트(비압축 P-256 공개키) — 브라우저가 주는 모양
    auth: crypto.randomBytes(16).toString('base64url'),
  };
}

test('브라우저들이 실제로 쓰는 푸시 서비스 주소는 그대로 받는다', () => {
  for (const endpoint of [CHROME, CHROME_WP, FIREFOX, SAFARI, EDGE, 'https://api.push.apple.com/3/device/abc']) {
    assert.equal(normalizeWebPushEndpoint(endpoint), endpoint, endpoint);
  }
});

test('대문자·기본 포트(:443)는 정규화한 주소로 돌려준다', () => {
  assert.equal(normalizeWebPushEndpoint('HTTPS://FCM.GOOGLEAPIS.COM:443/fcm/send/abc'), 'https://fcm.googleapis.com/fcm/send/abc');
  assert.equal(normalizeWebPushEndpoint('https://WEB.push.apple.com/x'), 'https://web.push.apple.com/x');
});

test('https가 아니거나 다른 포트·아이디/비밀번호가 붙은 주소는 막는다', () => {
  for (const endpoint of [
    'http://fcm.googleapis.com/fcm/send/abc',
    'wss://fcm.googleapis.com/fcm/send/abc',
    'ftp://fcm.googleapis.com/fcm/send/abc',
    'https://fcm.googleapis.com:8443/fcm/send/abc',
    'https://fcm.googleapis.com:80/fcm/send/abc',
    'https://web.push.apple.com:5432/x',
    'https://user:pw@fcm.googleapis.com/fcm/send/abc',
    'https://user@fcm.googleapis.com/fcm/send/abc',
    'https://fcm.googleapis.com@evil.example/fcm/send/abc',
    'https://fcm.googleapis.com:443@127.0.0.1/',
  ]) {
    assert.equal(normalizeWebPushEndpoint(endpoint), null, endpoint);
  }
});

test('IP를 직접 적은 주소(사내망·루프백·메타데이터·10진/16진 표기·IPv6)는 막는다', () => {
  for (const endpoint of [
    'https://127.0.0.1/x',
    'https://10.0.0.1/x',
    'https://192.168.0.1/x',
    'https://169.254.169.254/latest/meta-data',
    'https://8.8.8.8/x',
    'https://2130706433/x', // 127.0.0.1
    'https://0x7f000001/x', // 127.0.0.1
    'https://[::1]/x',
    'https://[::ffff:127.0.0.1]/x',
  ]) {
    assert.equal(normalizeWebPushEndpoint(endpoint), null, endpoint);
  }
});

test('허용 목록에 없는 호스트·비슷하게 꾸민 호스트는 막는다', () => {
  for (const endpoint of [
    'https://localhost/x',
    'https://example.com/x',
    'https://fcm.googleapis.com.evil.example/x',
    'https://evilfcm.googleapis.com/x',
    'https://www.googleapis.com/x',
    'https://fcm.googleapis.co/x',
    'https://fcm.googleapis.com./x', // 끝에 점
    'https://updates.push.services.mozilla.com.evil.example/x',
    'https://push.apple.com/x', // 하위 도메인이 있어야 한다
    'https://evilpush.apple.com/x',
    'https://push.apple.com.evil.example/x',
    'https://notify.windows.com/x',
    'https://evilnotify.windows.com/x',
    'https://wns2-par02p.notify.windows.com.evil.example/w/',
    'https://evil.example#@fcm.googleapis.com/',
    'https://evil.example?@fcm.googleapis.com/',
    'https://evil.example\\@fcm.googleapis.com/',
  ]) {
    assert.equal(normalizeWebPushEndpoint(endpoint), null, endpoint);
  }
});

test('호스트 이름에 점 사이가 빈 곳이 있으면(맨 앞·중간·끝의 점) 하위 도메인으로 치지 않는다', () => {
  for (const endpoint of [
    'https://.push.apple.com/x', // 점 앞이 비었는데 ".push.apple.com"으로 끝난다
    'https://..push.apple.com/x',
    'https://a..push.apple.com/x',
    'https://%2Epush.apple.com/x', // new URL이 %2E를 점으로 풀어 ".push.apple.com"이 된다
    'https://。push.apple.com/x', // 전각 마침표(。)도 점이 된다
    'https://.notify.windows.com/x',
    'https://wns2-par02p..notify.windows.com/w/',
    'https://.fcm.googleapis.com/x',
    'https://fcm..googleapis.com/x',
    'https://web.push.apple.com./x',
  ]) {
    assert.equal(normalizeWebPushEndpoint(endpoint), null, endpoint);
  }
  // 빈 곳 없이 풀리는 표기는 정규화한 이름으로 검사·저장한다(a。push → a.push).
  assert.equal(normalizeWebPushEndpoint('https://a。push.apple.com/x'), 'https://a.push.apple.com/x');
});

test('문자열이 아니거나 비었거나 너무 길거나 주소가 아니면 null', () => {
  for (const endpoint of [undefined, null, 123, {}, [], '', 'not a url', 'javascript:alert(1)', 'file:///etc/passwd']) {
    assert.equal(normalizeWebPushEndpoint(endpoint), null, String(endpoint));
  }
  assert.equal(normalizeWebPushEndpoint(`https://fcm.googleapis.com/fcm/send/${'a'.repeat(5000)}`), null);
  // 원래 문자열은 짧아도 정규화(퍼센트 인코딩)로 길어지면 막는다.
  assert.equal(normalizeWebPushEndpoint(`https://fcm.googleapis.com/fcm/send/${'<'.repeat(2000)}`), null);
  assert.ok(normalizeWebPushEndpoint(`https://fcm.googleapis.com/fcm/send/${'a'.repeat(3000)}`));
});

test('정규화한 주소는 web-push가 쓰는 옛 url.parse로 읽어도 같은 호스트다(두 파서 차이로 우회 못 함)', () => {
  const tricky = [
    'https://fcm.googleapis.com\\@evil.example/', // 새 파서: 역슬래시부터 경로 / 옛 파서(원래 문자열): 다르게 읽힐 수 있음
    'https://fcm.googleapis.com\t/fcm/send/a', // 탭은 새 파서가 지운다
    'https://fcm.googleapis.com\n.evil.example/x',
    ' https://web.push.apple.com/x ',
    'https://fcm.googleapis.com/fcm/send/a b<c>"d`e{f}',
    'https://wns2-par02p.notify.windows.com/w/?token=a\'b"c',
    CHROME,
    EDGE,
  ];
  for (const endpoint of tricky) {
    const normalized = normalizeWebPushEndpoint(endpoint);
    if (normalized === null) continue;
    const host = new URL(normalized).hostname;
    assert.equal(legacyParse(normalized).hostname, host, endpoint);
    assert.equal(legacyParse(normalized).port, null, endpoint);
    assert.equal(normalizeWebPushEndpoint(normalized), normalized, endpoint); // 다시 넣어도 같다
  }
  assert.equal(normalizeWebPushEndpoint('https://fcm.googleapis.com\\@evil.example/'), 'https://fcm.googleapis.com/@evil.example/');
  assert.equal(normalizeWebPushEndpoint('https://fcm.googleapis.com\t/fcm/send/a'), 'https://fcm.googleapis.com/fcm/send/a');
  assert.equal(normalizeWebPushEndpoint('https://fcm.googleapis.com\n.evil.example/x'), null);
});

test('parseWebPushSubscription: 검사한 endpoint와 키만 남긴다', () => {
  const k = keys();
  const result = parseWebPushSubscription({ endpoint: 'HTTPS://FCM.googleapis.com/fcm/send/abc', expirationTime: null, keys: { ...k, extra: 'x' } });
  assert.deepEqual(result, { subscription: { endpoint: 'https://fcm.googleapis.com/fcm/send/abc', keys: k } });
  // 저장 모양이 항상 같아야(키 순서까지) 같은 구독을 문자열로 비교해 겹친 행을 정리할 수 있다(queries/devices.js).
  assert.equal(JSON.stringify(result.subscription), JSON.stringify({ endpoint: 'https://fcm.googleapis.com/fcm/send/abc', keys: { p256dh: k.p256dh, auth: k.auth } }));
});

test('parseWebPushSubscription: 객체가 아니거나 endpoint가 허용 목록 밖이면 거절(호스트는 로그용으로)', () => {
  const k = keys();
  for (const value of [undefined, null, 'x', 1, [], [CHROME]]) {
    assert.ok(parseWebPushSubscription(value).error, String(value));
  }
  const internal = parseWebPushSubscription({ endpoint: 'https://192.168.0.10:8443/admin', keys: k });
  assert.ok(internal.error);
  assert.equal(internal.subscription, undefined);
  assert.equal(internal.host, '192.168.0.10:8443');
  assert.equal(parseWebPushSubscription({ endpoint: 'not a url', keys: k }).host, null);
  assert.equal(parseWebPushSubscription({ keys: k }).host, null);
});

test('parseWebPushSubscription: 키는 web-push가 암호화할 수 있는 길이·모양이어야 한다', () => {
  const k = keys();
  const bad = [
    {},
    { p256dh: k.p256dh },
    { auth: k.auth },
    { p256dh: 1, auth: k.auth },
    { p256dh: crypto.randomBytes(64).toString('base64url'), auth: k.auth }, // 65바이트가 아님
    { p256dh: crypto.randomBytes(33).toString('base64url'), auth: k.auth }, // 압축 공개키 — web-push가 못 쓴다
    { p256dh: k.p256dh, auth: crypto.randomBytes(15).toString('base64url') }, // 16바이트 미만
    { p256dh: k.p256dh, auth: crypto.randomBytes(80).toString('base64url') }, // 너무 김
    { p256dh: `${k.p256dh}!`, auth: k.auth }, // base64 글자가 아님
    { p256dh: k.p256dh, auth: `${k.auth} ` },
    { p256dh: k.p256dh, auth: 'A'.repeat(200) },
  ];
  for (const badKeys of bad) {
    assert.ok(parseWebPushSubscription({ endpoint: CHROME, keys: badKeys }).error, JSON.stringify(badKeys));
  }
  assert.ok(parseWebPushSubscription({ endpoint: CHROME, keys: 'x' }).error);
  // 패딩·표준 base64 글자가 섞여도 web-push가 그대로 읽으므로 받는다.
  const raw = crypto.createECDH('prime256v1').generateKeys();
  const padded = { p256dh: raw.toString('base64'), auth: crypto.randomBytes(16).toString('base64') };
  assert.ok(parseWebPushSubscription({ endpoint: CHROME, keys: padded }).subscription);
});

test('검사를 통과한 구독은 web-push가 그대로 요청을 만들고, 시간 제한·VAPID 대상도 그 호스트다', () => {
  const vapid = webpush.generateVAPIDKeys();
  for (const endpoint of [CHROME, FIREFOX, SAFARI, EDGE, 'https://fcm.googleapis.com\\@evil.example/']) {
    const { subscription } = parseWebPushSubscription({ endpoint, keys: keys() });
    const details = webpush.generateRequestDetails(subscription, JSON.stringify({ title: 't', body: 'b' }), {
      TTL: 60,
      urgency: 'high',
      timeout: 10_000,
      vapidDetails: { subject: 'mailto:test@example.com', publicKey: vapid.publicKey, privateKey: vapid.privateKey },
    });
    assert.equal(details.endpoint, subscription.endpoint);
    assert.equal(details.timeout, 10_000);
    // VAPID 토큰의 aud는 web-push가 endpoint에서 읽은 출처(옛 url.parse) — 검사한 호스트와 같아야 한다.
    const jwt = /t=([^,\s]+)/.exec(details.headers.Authorization)[1];
    const { aud } = JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString('utf8'));
    assert.equal(aud, new URL(subscription.endpoint).origin, endpoint);
  }
});
