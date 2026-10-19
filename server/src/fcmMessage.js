// FCM 한 통을 받는 기기 종류에 맞춰 만든다(push.js가 기기마다 부른다). 안드로이드는 data만 받아 앱이 직접 알림을 그리지만
// (client main.dart의 백그라운드 isolate — 자물쇠 배지·대화 레이아웃), 아이폰(devices.kind 'ios')은 뒤로 간 앱을 iOS가 멈춰
// 두어 앱이 그릴 수 없다 — OS가 바로 그리는 알림(APNs alert)으로 보내고, 누를 때 앱이 열 곳만 data에 싣는다(client main.dart
// _onFcmOpened). DB를 모르는 순수 함수라 테스트가 직접 부른다.

/** APNs는 알림 하나가 4KB까지라 긴 메시지 미리보기를 그대로 실으면 통째로 거절된다 — 알림 글은 이만큼(글자)에서 자른다. */
export const APNS_TEXT_MAX = 200;

/** [text]를 [max]글자로 자른다(넘치면 끝에 …). 이모지·한글 조합을 반으로 가르지 않게 코드 포인트로 센다. */
export function clipAlertText(text, max = APNS_TEXT_MAX) {
  const s = String(text ?? '');
  const chars = Array.from(s);
  return chars.length <= max ? s : `${chars.slice(0, max - 1).join('')}…`;
}

/**
 * [device]({ fcmToken, kind })에 보낼 FCM 메시지.
 * - [android]: 지금까지 보내던 모양 그대로({ data, notification?, android }) — 아이폰이 아닌 기기(안드로이드·종류를 모르는 예전 기기).
 * - [ios]: { title, body, data, threadId?, ttlSeconds? } — data는 누를 때 쓸 것만(FCM data 값은 글자만 된다), [threadId]가
 *   같은 알림은 알림 센터에서 한 묶음(방마다)이 되고, [ttlSeconds]가 지나면 꺼져 있던 기기가 켜져도 보내지 않는다(지나간 전화).
 */
export function fcmMessageFor(device, { android, ios }) {
  if (device.kind !== 'ios') return { token: device.fcmToken, ...android };
  const headers = { 'apns-push-type': 'alert', 'apns-priority': '10' };
  if (ios.ttlSeconds) headers['apns-expiration'] = String(Math.floor(Date.now() / 1000) + ios.ttlSeconds);
  return {
    token: device.fcmToken,
    data: ios.data,
    apns: {
      headers,
      payload: {
        aps: {
          alert: { title: clipAlertText(ios.title), body: clipAlertText(ios.body) },
          sound: 'default',
          ...(ios.threadId ? { threadId: ios.threadId } : {}),
        },
      },
    },
  };
}
