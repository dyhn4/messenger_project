import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

// 웹 빌드의 알림·웹 푸시 — 브라우저의 Notification/Push API를 우리 서비스 워커(web/sw.js)로 쓴다.
// 알림은 페이지가 아니라 서비스 워커가 띄워야 아이폰(홈 화면 앱)에서도 뜨고, 알림을 눌렀을 때 서비스
// 워커가 열린 창을 찾아 [onWebNotificationClick]으로 알려 준다(창이 없으면 ?notification=으로 새로 연다).
// 네이티브 빌드는 web_notifications_stub.dart.

bool get _hasNotification => globalContext.has('Notification');
bool get _hasServiceWorker => web.window.navigator.has('serviceWorker');
bool get _hasPushManager => globalContext.has('PushManager');

/// 이 브라우저가 알림을 띄울 수 있는지(서비스 워커 + Notification). 아이폰 Safari는 홈 화면에
/// 추가해서 연 웹 앱에서만 true다.
bool get webNotificationsSupported => _hasNotification && _hasServiceWorker;

/// 웹 푸시(앱을 닫아도 오는 알림)까지 되는지.
bool get webPushSupported => webNotificationsSupported && _hasPushManager;

/// 'granted' | 'denied' | 'default' — 알림을 못 쓰는 브라우저면 'unsupported'.
String get webNotificationPermission =>
    _hasNotification ? web.Notification.permission : 'unsupported';

/// 홈 화면에 추가해서(또는 PC에서 "앱 설치"로) 독립 창으로 열었는지.
bool get isStandaloneDisplay {
  if (web.window.matchMedia('(display-mode: standalone)').matches) return true;
  // 아이폰 Safari는 display-mode 대신 비표준 navigator.standalone을 쓴다.
  final standalone = web.window.navigator.getProperty<JSAny?>(
    'standalone'.toJS,
  );
  return standalone != null && standalone.dartify() == true;
}

Future<web.ServiceWorkerRegistration>? _registration;

/// 서비스 워커를 등록하고 준비될 때까지 기다린다(여러 번 불러도 한 번만 등록한다).
Future<web.ServiceWorkerRegistration> _ready() => _registration ??= () async {
  final container = web.window.navigator.serviceWorker;
  await container.register('sw.js'.toJS).toDart;
  return container.ready.toDart;
}();

/// 앱 시작 시 한 번 — 서비스 워커를 미리 등록해 두고, 알림 클릭을 [onClick]으로 받는다.
Future<void> initWebNotifications(void Function(String payload) onClick) async {
  if (!_hasServiceWorker) return;
  web.window.navigator.serviceWorker.addEventListener(
    'message',
    ((web.MessageEvent event) {
      final data = event.data.dartify();
      if (data is Map && data['type'] == 'notification-click') {
        final payload = data['payload'];
        if (payload is String && payload.isNotEmpty) onClick(payload);
      }
    }).toJS,
  );
  try {
    await _ready();
  } catch (_) {
    // 등록이 안 되는 환경(사설 인증서 등) — 알림만 못 쓸 뿐 앱은 그대로 돈다.
  }
}

/// 알림을 눌러 앱이 새로 열렸으면(서비스 워커가 ?notification=을 붙여 연다) 그 payload — 한 번
/// 꺼내면 주소창에서도 지워서 새로고침해도 다시 열리지 않게 한다.
String? takeLaunchNotificationPayload() {
  final uri = Uri.base;
  final payload = uri.queryParameters['notification'];
  if (payload == null || payload.isEmpty) return null;
  final rest = Map<String, String>.of(uri.queryParameters)
    ..remove('notification');
  final clean = uri.replace(queryParameters: rest.isEmpty ? null : rest);
  web.window.history.replaceState(
    null,
    '',
    clean.toString().replaceFirst(RegExp(r'\?$'), ''),
  );
  return payload;
}

/// 알림 권한을 묻는다 — 아이폰은 사용자가 단추를 누른 그 순간에만 물을 수 있어서, 단추의
/// onPressed에서 바로 불러야 한다.
Future<String> requestWebNotificationPermission() async {
  if (!_hasNotification) return 'unsupported';
  final result = await web.Notification.requestPermission().toDart;
  return result.toDart;
}

/// 알림 하나를 띄운다. 같은 [tag]의 알림은 새 것으로 바뀐다(방 하나에 하나). [payload]는 눌렀을 때
/// 돌려받는 값(방 id 등 — 네이티브 알림 payload와 같은 규칙).
Future<void> showWebNotification({
  required String title,
  required String body,
  required String tag,
  required String payload,
}) async {
  if (webNotificationPermission != 'granted') return;
  final registration = await _ready();
  await registration
      .showNotification(
        title,
        web.NotificationOptions(
          body: body,
          tag: tag,
          icon: 'icons/Icon-192.png',
          badge: 'icons/Icon-192.png',
          data: {'payload': payload}.jsify(),
        ),
      )
      .toDart;
}

/// [tag] 알림을 지운다(그 방을 열었을 때 등).
Future<void> closeWebNotifications(String tag) async {
  if (!webNotificationsSupported) return;
  final registration = await _ready();
  final shown = await registration
      .getNotifications(web.GetNotificationOptions(tag: tag))
      .toDart;
  for (final n in shown.toDart) {
    n.close();
  }
}

@JS('JSON.stringify')
external JSString _stringify(JSAny? value);

/// 웹 푸시를 구독하고 서버에 보낼 구독 정보(endpoint·keys)를 돌려준다. 권한이 없으면 null —
/// 권한은 [requestWebNotificationPermission]으로 먼저 받아 둬야 한다. 이미 구독돼 있으면 그대로 쓴다.
Future<Map<String, dynamic>?> subscribeWebPush(String vapidPublicKey) async {
  if (!webPushSupported || webNotificationPermission != 'granted') return null;
  final registration = await _ready();
  final manager = registration.pushManager;
  final key = _base64UrlDecode(vapidPublicKey);
  var subscription = await manager.getSubscription().toDart;
  if (subscription != null && !_sameKey(subscription, key)) {
    // 서버의 VAPID 키가 바뀌었으면(서버 재설치 등) 예전 구독으로는 못 받는다 — 새로 구독한다.
    await subscription.unsubscribe().toDart;
    subscription = null;
  }
  subscription ??= await manager
      .subscribe(
        web.PushSubscriptionOptionsInit(
          userVisibleOnly: true,
          applicationServerKey: key.toJS,
        ),
      )
      .toDart;
  return jsonDecode(_stringify(subscription).toDart) as Map<String, dynamic>;
}

/// 웹 푸시 구독을 끊는다(로그아웃 등).
Future<void> unsubscribeWebPush() async {
  if (!webPushSupported) return;
  final registration = await _ready();
  final subscription = await registration.pushManager.getSubscription().toDart;
  await subscription?.unsubscribe().toDart;
}

bool _sameKey(web.PushSubscription subscription, Uint8List key) {
  final current = subscription.options.applicationServerKey;
  if (current == null) return false;
  final bytes = current.toDart.asUint8List();
  if (bytes.length != key.length) return false;
  for (var i = 0; i < key.length; i++) {
    if (bytes[i] != key[i]) return false;
  }
  return true;
}

Uint8List _base64UrlDecode(String value) =>
    base64Url.decode(base64Url.normalize(value));
