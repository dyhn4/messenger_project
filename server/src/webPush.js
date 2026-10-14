import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Router } from 'express';
import webpush from 'web-push';
import { listAppDeviceIds, listWebPushSubscriptionsForUser, setDeviceWebPushSubscription } from './db/queries/devices.js';
import { webPushTargets } from './presence.js';
import { parseWebPushSubscription } from './webPushEndpoint.js';

// 웹 앱(아이폰 등 앱이 없는 기기)용 웹 푸시 — 표준 Web Push(VAPID)라 Firebase 설정이 필요 없다. 앱(탭)을
// 닫아도 알림이 오게 하는 안드로이드 FCM의 웹판이고, push.js가 FCM과 같은 때(소켓이 안 붙어 있을 때)에
// 같이 보낸다. 받는 쪽은 client/web/sw.js. 아이폰은 iOS 16.4 이상에서 홈 화면에 추가한 웹 앱만 받는다.

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const keyPath = path.join(__dirname, '..', '.web-push-vapid.json');

/**
 * VAPID 키쌍 — .env(WEB_PUSH_PUBLIC_KEY/WEB_PUSH_PRIVATE_KEY)가 있으면 그걸, 없으면 .web-push-vapid.json을
 * 쓰고, 그마저 없으면 새로 만들어 저장한다(config.js의 resolveSecret과 같은 방식). 키가 바뀌면 브라우저들의
 * 예전 구독이 전부 무효가 되니(앱이 다음 로그인 때 새로 구독한다) 한 번 만든 파일은 지우지 않는다.
 */
function loadVapidKeys() {
  const { WEB_PUSH_PUBLIC_KEY, WEB_PUSH_PRIVATE_KEY } = process.env;
  if (WEB_PUSH_PUBLIC_KEY && WEB_PUSH_PRIVATE_KEY) {
    return { publicKey: WEB_PUSH_PUBLIC_KEY, privateKey: WEB_PUSH_PRIVATE_KEY };
  }
  if (fs.existsSync(keyPath)) {
    try {
      const keys = JSON.parse(fs.readFileSync(keyPath, 'utf8'));
      if (keys.publicKey && keys.privateKey) return keys;
    } catch {
      console.error('[web-push] .web-push-vapid.json을 읽지 못해 새 키를 만듭니다.');
    }
  }
  const keys = webpush.generateVAPIDKeys();
  fs.writeFileSync(keyPath, JSON.stringify(keys), { mode: 0o600 });
  console.log('[web-push] 웹 푸시 키를 새로 만들어 .web-push-vapid.json에 저장했습니다. 이 파일은 커밋/공유하지 마세요.');
  return keys;
}

const vapidKeys = loadVapidKeys();
// 푸시 서비스(애플·구글·모질라)가 문제 있을 때 연락할 곳 — mailto: 또는 https 주소여야 한다.
const subject = process.env.WEB_PUSH_SUBJECT || 'mailto:webpush@tangotalk.app';
webpush.setVapidDetails(subject, vapidKeys.publicKey, vapidKeys.privateKey);

/** 브라우저가 구독할 때 쓰는 공개키 — 비밀이 아니라 인증 없이 연다(firebase-client-config와 같은 성격). */
export const webPushRouter = Router();
webPushRouter.get('/web-push/public-key', (req, res) => {
  res.json({ publicKey: vapidKeys.publicKey });
});

// 푸시 서비스가 이 시간(ms) 동안 아무 응답이 없으면 끊는다. 정상이면 1초 안에 끝나는데, 시간 제한이 없으면 응답을
// 안 주는 상대 하나가 연결을 계속 붙잡고, push.js는 이 발송을 기다린 뒤에 FCM을 보내므로 그 알림까지 늦어진다.
const SEND_TIMEOUT_MS = 10_000;

/**
 * [userId]의 웹 앱들에 알림 하나를 보낸다. [payload]는 client/web/sw.js가 읽는 모양
 * ({ kind, roomId?, projectId?, title, body }). [ttl]은 초 — 화상회의처럼 늦으면 의미 없는 알림은 짧게.
 * 구독이 사라졌으면(브라우저에서 알림을 끔·앱 삭제 등 — 404/410) 지워서 다음부터 헛발송하지 않는다.
 * 받는 기기 수는 queries/devices.js의 PUSH_DEVICES_PER_USER까지다.
 */
export async function sendWebPushToUser(userId, payload, { ttl = 24 * 60 * 60, urgency = 'high' } = {}) {
  let subscriptions;
  try {
    subscriptions = await listWebPushSubscriptionsForUser(userId);
  } catch (err) {
    // 구독을 못 읽어도(마이그레이션 전 등) 같이 가는 FCM 발송은 막지 않는다.
    console.error('[web-push] 구독 조회 실패:', err?.message ?? err);
    return;
  }
  // 웹 앱 탭이 열려 소켓이 붙어 있는 기기는 소켓으로 알림을 받는다 — 그 기기로는 보내지 않는다(push.js의 FCM과 같다). PC·안드로이드
  // 앱이 접속해 있으면 같은 종류의 브라우저로도 보내지 않는다(presence.js webPushTargets — 같은 기기에서 알림이 두 번 뜨지 않게).
  // PC·안드로이드 브라우저 구독이 있을 때만 앱 기기를 묻는다.
  const appDeviceIds = subscriptions.some((s) => s.kind === 'web-desktop' || s.kind === 'web-android')
    ? await listAppDeviceIds(userId).catch(() => ({}))
    : {};
  subscriptions = webPushTargets(subscriptions, appDeviceIds);
  if (subscriptions.length === 0) return;
  const body = JSON.stringify(payload);
  await Promise.all(
    subscriptions.map(async ({ deviceId, subscription }) => {
      // 등록할 때(devices.js)와 같은 검사를 보내기 직전에 다시 한다 — 주소 검사가 생기기 전에 저장된 구독이나
      // 망가진 값이면 보내지 않고 지운다. 보낼 때도 검사를 통과한 정규화된 endpoint를 쓴다(webPushEndpoint.js).
      const parsed = parseWebPushSubscription(subscription);
      if (parsed.error) {
        console.warn(`[web-push] 허용되지 않는 구독이라 지웁니다: ${parsed.error}${parsed.host ? ` (${parsed.host})` : ''}`);
        await setDeviceWebPushSubscription(deviceId, userId, null).catch(() => {});
        return;
      }
      await webpush
        .sendNotification(parsed.subscription, body, { TTL: ttl, urgency, timeout: SEND_TIMEOUT_MS })
        .catch(async (err) => {
          if (err?.statusCode === 404 || err?.statusCode === 410) {
            await setDeviceWebPushSubscription(deviceId, userId, null).catch(() => {});
            return;
          }
          console.error('[web-push] 발송 실패:', err?.statusCode ?? '', err?.body ?? err?.message ?? err);
        });
    }),
  );
}
