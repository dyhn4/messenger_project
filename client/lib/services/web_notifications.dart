// 웹 빌드의 알림·웹 푸시(서비스 워커 web/sw.js) — 네이티브에서는 전부 아무것도 안 하는 빈 구현이다.
export 'web_notifications_stub.dart'
    if (dart.library.js_interop) 'web_notifications_web.dart';
