// TangoTalk 웹 앱의 서비스 워커 — 알림과 웹 푸시만 맡는다(오프라인 캐시는 하지 않는다).
//
// - 앱이 켜져 있을 때의 알림: 앱(Dart)이 registration.showNotification으로 띄운다
//   (lib/services/web_notifications_web.dart).
// - 앱을 닫았을 때의 알림: 서버가 웹 푸시로 보내면(server/src/webPush.js) 여기 'push'가 받아 띄운다.
//   아이폰은 홈 화면에 추가한 웹 앱에서만 받는다.
// - 알림을 누르면 열린 창이 있으면 그 창을 앞으로 가져와 payload를 알리고, 없으면 새 창으로 연다.
//
// payload는 네이티브 앱 알림과 같은 규칙이다: 방 id, 'call:<방 id>'(화상회의), 'project:<프로젝트 id>', 'approval:<문서 id>:<팀 id>'(결재).

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

function payloadOf(data) {
  if (data.kind === 'call') return `call:${data.roomId}`;
  if (data.kind === 'project') return `project:${data.projectId}`;
  // 결재 알림 — NotificationService.approvalPayload와 같은 모양(회사 전체 범위면 팀 id가 빈 글자).
  if (data.kind === 'groupware') return `approval:${data.documentId ?? ''}:${data.teamId ?? ''}`;
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
  const tag = data.kind === 'call' || data.kind === 'project' || data.kind === 'groupware' ? payload : data.roomId || 'tangotalk';
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
