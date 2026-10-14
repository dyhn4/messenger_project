// 네이티브 빌드용 — 브라우저가 없으니 연결 종류를 알 수 없다(network_type.dart가 kIsWeb일 때만 본다).
// 웹 구현은 network_type_web.dart.

bool get webConnectionIsCellular => false;
