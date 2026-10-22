// TangoTalk 웹 앱의 서비스 워커 — 알림·웹 푸시와, 서버가 꺼져 있어도 웹 앱을 열 수 있게 앱 파일을 보관하는 일을 맡는다.
//
// - 앱이 켜져 있을 때의 알림: 앱(Dart)이 registration.showNotification으로 띄운다
//   (lib/services/web_notifications_web.dart).
// - 앱을 닫았을 때의 알림: 서버가 웹 푸시로 보내면(server/src/webPush.js) 여기 'push'가 받아 띄운다.
//   아이폰은 홈 화면에 추가한 웹 앱에서만 받는다.
// - 알림을 누르면 열린 창이 있으면 그 창을 앞으로 가져와 payload를 알리고, 없으면 새 창으로 연다.
// - 앱 파일 보관: 웹 앱은 서버가 내려 주므로 예전엔 서버가 꺼져 있으면 새로 열 수 없었다(대화는 IndexedDB에 있어도). 앱 파일
//   (첫 페이지·main.dart.js·flutter*.js·assets/·canvaskit/·icons/ 등 — [isAppFile])을 받을 때마다 보관해 두고, 서버에 닿지 않으면
//   보관해 둔 것으로 연다. 늘 서버 것을 먼저 받아(새 판이 바로 보이게) 실패하거나 [NETWORK_WAIT_MS] 넘게 답이 없을 때만 보관한
//   것을 쓴다. API·업로드 파일·다른 서버 페이지는 건드리지 않는다. 처음 열 때는 서비스 워커가 아직 페이지를 맡기 전이라 그때
//   받은 파일을 놓치므로, 첫 화면이 뜬 뒤 페이지가 받은 파일 목록을 넘겨 준다('keep-app-files' — web/flutter_bootstrap.js).
//
// payload는 네이티브 앱 알림과 같은 규칙이다: 방 id, 'call:<방 id>'(화상회의), 'project:<프로젝트 id>', 'approval:<문서 id>:<팀 id>'(결재),
// 'mail:'(새 메일).

const APP_CACHE = 'tangotalk-app-v1';
const NETWORK_WAIT_MS = 4000;

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) =>
  event.waitUntil(
    (async () => {
      // 예전 판의 보관함은 치운다(보관 방식을 바꿀 때 APP_CACHE 이름을 올린다).
      for (const key of await caches.keys()) {
        if (key.startsWith('tangotalk-app-') && key !== APP_CACHE) await caches.delete(key);
      }
      await self.clients.claim();
    })(),
  ),
);

/** 서비스 워커 범위 안의 경로(앞 '/' 없이) — 범위 밖이거나 다른 서버면 null. */
function scopedPath(url) {
  const scope = new URL(self.registration.scope);
  if (url.origin !== scope.origin || !url.pathname.startsWith(scope.pathname)) return null;
  return url.pathname.slice(scope.pathname.length);
}

/** 첫 페이지(index.html) — 알림으로 연 ?notification= 등 물음표 뒤는 달라도 같은 페이지다. */
const isAppPage = (path) => path === '' || path === 'index.html';

/** 웹 앱 빌드가 내놓는 파일만(서버의 API·업로드·다른 페이지는 같은 주소에 있어도 아님). */
function isAppFile(path) {
  if (path === null) return false;
  if (isAppPage(path)) return true;
  if (/^(assets|canvaskit|icons)\//.test(path)) return true;
  return /^(main\.dart\.[^/]+|flutter\.js|flutter_bootstrap\.js|manifest\.json|favicon\.png|version\.json)$/.test(path);
}

/** 보관 열쇠 — 첫 페이지는 범위 주소 하나로, 나머지는 물음표 뒤를 뗀 주소로. */
function cacheKeyOf(url) {
  const path = scopedPath(url);
  if (path !== null && isAppPage(path)) return self.registration.scope;
  return url.origin + url.pathname;
}

async function keep(key, response) {
  if (!response || !response.ok || response.type !== 'basic') return;
  try {
    const cache = await caches.open(APP_CACHE);
    await cache.put(key, response);
  } catch (_) {
    // 저장 공간이 모자라면 넘어간다 — 다음에 서버에서 다시 받는다.
  }
}

/** 서버 것을 먼저 — 받으면 보관해 두고, 실패하거나 너무 늦으면 보관해 둔 것(없으면 서버 답을 끝까지 기다린다). 앞에 둔 프록시가
 * 서버 대신 5xx로 답해도(서버가 꺼짐) 보관해 둔 것으로. */
async function networkFirst(request) {
  const key = cacheKeyOf(new URL(request.url));
  const network = fetch(request).then((response) => {
    keep(key, response.clone());
    return response;
  });
  const cached = await caches.match(key).catch(() => undefined);
  if (!cached) return network;
  let timer;
  const late = new Promise((resolve) => {
    timer = setTimeout(() => resolve(cached), NETWORK_WAIT_MS);
  });
  try {
    const response = await Promise.race([network, late]);
    return response.status >= 500 ? cached : response;
  } catch (_) {
    return cached;
  } finally {
    clearTimeout(timer);
  }
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const path = scopedPath(new URL(request.url));
  if (!isAppFile(path)) return;
  // 다른 서버 페이지로 가는 이동(/guide, /pair/… 등)은 위에서 걸러진다 — 첫 페이지로의 이동과 앱 파일만 맡는다.
  if (request.mode === 'navigate' && !isAppPage(path)) return;
  event.respondWith(networkFirst(request));
});

// 페이지가 이번에 받은 파일 목록 — 처음 열 때(서비스 워커가 맡기 전) 받은 앱 파일도 보관한다. 대개 브라우저 캐시에서 바로 온다.
self.addEventListener('message', (event) => {
  const data = event.data;
  if (!data || data.type !== 'keep-app-files' || !Array.isArray(data.urls)) return;
  event.waitUntil(
    (async () => {
      const cache = await caches.open(APP_CACHE);
      const seen = new Set();
      for (const raw of data.urls) {
        let url;
        try {
          url = new URL(raw, self.registration.scope);
        } catch (_) {
          continue;
        }
        if (!isAppFile(scopedPath(url))) continue;
        const key = cacheKeyOf(url);
        if (seen.has(key)) continue;
        seen.add(key);
        if (await cache.match(key)) continue; // 이미 있으면(맡은 뒤 받은 것) 그대로.
        try {
          await keep(key, await fetch(key, { credentials: 'same-origin' }));
        } catch (_) {
          // 지금 못 받으면 넘어간다 — 다음에 열 때 맡아서 받는다.
        }
      }
    })(),
  );
});

function payloadOf(data) {
  if (data.kind === 'call') return `call:${data.roomId}`;
  if (data.kind === 'project') return `project:${data.projectId}`;
  // 결재 알림 — NotificationService.approvalPayload와 같은 모양(회사 전체 범위면 팀 id가 빈 글자).
  if (data.kind === 'groupware') return `approval:${data.documentId ?? ''}:${data.teamId ?? ''}`;
  // 새 메일 — NotificationService.mailPayload.
  if (data.kind === 'mail') return 'mail:';
  return data.roomId ?? '';
}

self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (_) {
    data = { title: 'TangoTalk', body: event.data ? event.data.text() : '' };
  }
  const payload = payloadOf(data);
  // 같은 방 알림은 하나로 바뀌게(앱이 띄우는 알림과 같은 tag).
  const tag = data.kind === 'call' || data.kind === 'project' || data.kind === 'groupware' || data.kind === 'mail' ? payload : data.roomId || 'tangotalk';
  event.waitUntil(
    self.registration.showNotification(data.title || 'TangoTalk', {
      body: data.body || '',
      tag,
      renotify: true,
      icon: 'icons/Icon-192.png',
      badge: 'icons/Icon-192.png',
      // 화상회의는 사용자가 볼 때까지 남겨 둔다.
      requireInteraction: data.kind === 'call',
      data: { payload },
    }),
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const payload = event.notification.data?.payload ?? '';
  event.waitUntil(
    (async () => {
      const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      const target = windows.find((c) => c.focused) ?? windows[0];
      if (target) {
        await target.focus();
        if (payload) target.postMessage({ type: 'notification-click', payload });
        return;
      }
      const url = new URL('./', self.registration.scope);
      if (payload) url.searchParams.set('notification', payload);
      await self.clients.openWindow(url.href);
    })(),
  );
});
