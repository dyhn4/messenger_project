// 웹 푸시 구독(브라우저의 PushSubscription) 검사 — 서버는 알림을 보낼 때 구독의 endpoint 주소로 직접 POST를
// 보낸다(webPush.js). 예전엔 https://로 시작하기만 하면 받아서, 로그인한 누구나 서버를 시켜 사내망(공유기 관리
// 화면·DB·LiveKit 등)이나 아무 호스트·포트로 요청을 보내게 할 수 있었다(SSRF). 그래서 브라우저들이 실제로 쓰는
// 푸시 서비스 주소만 받는다. DB·네트워크를 안 건드리는 순수 규칙이라 단위 테스트(test/webPushEndpoint.test.js)로
// 그대로 검증한다.
import net from 'node:net';

/** 이름이 정확히 같아야 하는 푸시 서비스. */
const PUSH_SERVICE_HOSTS = new Set([
  'fcm.googleapis.com', // 크롬·안드로이드 브라우저·삼성 인터넷·오페라 등 크로뮴 계열
  'updates.push.services.mozilla.com', // 파이어폭스
  'web.push.apple.com', // 사파리(맥)·아이폰/아이패드 홈 화면 웹 앱
]);

/** 이 도메인의 하위 도메인이면 되는 푸시 서비스 — 서버마다 이름이 달라서 도메인으로 본다. */
const PUSH_SERVICE_DOMAINS = [
  '.push.apple.com', // 애플 안내가 "*.push.apple.com을 허용하라"고 한다.
  '.notify.windows.com', // 윈도우의 엣지(WNS) — wns2-xxx.notify.windows.com 등
];

// 실제 endpoint는 수백 자, 구독 키는 100자 안쪽이다 — 넉넉히 잡되 큰 값을 쌓아 두지 못하게 막는다.
const ENDPOINT_MAX_LENGTH = 4096;
const KEY_MAX_LENGTH = 128;
// base64url(브라우저가 주는 모양). 패딩·표준 base64 글자도 받는다 — web-push가 둘 다 그대로 읽는다.
const KEY_RE = /^[A-Za-z0-9_\-+/]+={0,2}$/;

/**
 * 웹 푸시 endpoint가 허용된 브라우저 푸시 서비스 주소면 정규화한 주소(new URL().href)를, 아니면 null —
 * 허용 목록은 여기 한 곳에만 둔다. https·기본 포트(443)만 받고, 아이디·비밀번호(user:pw@)나 IP를 직접 적은
 * 주소, 점 사이가 빈 호스트(".push.apple.com")는 안 받으며, 호스트는 PUSH_SERVICE_HOSTS이거나
 * PUSH_SERVICE_DOMAINS의 하위 도메인이어야 한다.
 * 새 브라우저가 다른 푸시 서비스를 쓰게 되면 여기에 더한다(막히면 devices.js가 그 호스트를 로그에 남긴다).
 *
 * 원래 문자열 대신 정규화한 주소를 저장·사용하는 건 web-push가 옛 url.parse로 주소를 다시 읽기 때문이다 —
 * 역슬래시·탭 등을 섞어 두 파서가 호스트를 다르게 읽는 주소로 이 검사를 피해 갈 여지를 없앤다.
 */
export function normalizeWebPushEndpoint(endpoint) {
  if (typeof endpoint !== 'string' || endpoint.length === 0 || endpoint.length > ENDPOINT_MAX_LENGTH) return null;
  let url;
  try {
    url = new URL(endpoint);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:') return null;
  // new URL은 기본 포트(:443)를 빈 문자열로 둔다 — 다른 포트로 같은 호스트의 다른 서비스를 찌르지 못하게.
  if (url.port !== '') return null;
  if (url.username !== '' || url.password !== '') return null;
  const host = url.hostname; // 소문자·퓨니코드로 정규화돼 있다.
  // IP를 직접 적은 주소(IPv6는 [ ]로 감싸여 나온다) — 아래 목록에도 안 걸리지만 의도를 분명히 해 둔다.
  if (host.startsWith('[') || net.isIP(host) !== 0) return null;
  // 점 사이(맨 앞·끝 포함)가 빈 이름(".push.apple.com", "a..push.apple.com", 끝의 점) — new URL은 그대로 받아 주고
  // (%2E·전각 마침표 "。"도 점이 된다) 아래 접미사 비교는 맨 앞 점 앞이 비어 있어도 통과시켜서, 실제 푸시 서비스가 아닌
  // 이름이 하위 도메인처럼 들어왔다. 정상적인 푸시 서비스 주소에는 빈 레이블이 없다.
  if (host.split('.').includes('')) return null;
  if (!PUSH_SERVICE_HOSTS.has(host) && !PUSH_SERVICE_DOMAINS.some((domain) => host.endsWith(domain))) return null;
  // 정규화하면서 퍼센트 인코딩으로 길어질 수 있어(< → %3C) 저장할 주소로 한 번 더 잰다.
  return url.href.length <= ENDPOINT_MAX_LENGTH ? url.href : null;
}

function isKey(value, minBytes, maxBytes) {
  if (typeof value !== 'string' || value.length > KEY_MAX_LENGTH || !KEY_RE.test(value)) return false;
  const bytes = Buffer.from(value, 'base64url').length;
  return bytes >= minBytes && bytes <= maxBytes;
}

/** 로그용 — 거절한 endpoint의 호스트만(주소 전체에는 구독 비밀값이 들어 있어 남기지 않는다). */
function hostForLog(endpoint) {
  if (typeof endpoint !== 'string' || endpoint.length > ENDPOINT_MAX_LENGTH) return null;
  try {
    return new URL(endpoint).host || null;
  } catch {
    return null;
  }
}

/**
 * 브라우저 PushSubscription(toJSON 모양)을 검사해 저장·발송할 모양 `{ subscription: { endpoint, keys: { p256dh, auth } } }`로
 * 돌려준다 — endpoint는 정규화한 것이고 그 밖의 필드(expirationTime 등)는 버린다. 안 되면 `{ error }`(endpoint가 허용 목록
 * 밖이면 원인을 찾을 수 있게 `host`도). 키는 web-push가 암호화할 때 요구하는 길이(p256dh는 P-256 공개키 65바이트, auth는
 * 16바이트 이상)를 미리 본다 — 안 그러면 저장은 되고 보낼 때마다 실패한다. 보낼 때(webPush.js)도 저장된 값을 이걸로 다시
 * 본다(이 검사가 생기기 전에 저장된 것까지 거르려고).
 */
export function parseWebPushSubscription(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return { error: 'subscription은 endpoint와 keys(p256dh, auth)가 있는 객체 또는 null이어야 합니다.' };
  }
  const endpoint = normalizeWebPushEndpoint(value.endpoint);
  if (!endpoint) {
    return { error: '브라우저 푸시 서비스의 주소가 아닙니다.', host: hostForLog(value.endpoint) };
  }
  const p256dh = value.keys?.p256dh;
  const auth = value.keys?.auth;
  if (!isKey(p256dh, 65, 65) || !isKey(auth, 16, 64)) {
    return { error: '구독 키(p256dh, auth)가 올바르지 않습니다.' };
  }
  return { subscription: { endpoint, keys: { p256dh, auth } } };
}
