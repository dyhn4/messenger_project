// 네이티브 빌드용 — 브라우저가 없으니 부르지 않는다(device_kind.dart가 kIsWeb일 때만 본다). 웹 구현은 device_kind_web.dart.

bool get webHasTouchScreen => false;
