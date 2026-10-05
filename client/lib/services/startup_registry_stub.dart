// 웹 빌드용 — 레지스트리가 없으니 "시작 시 자동 실행"은 늘 꺼진 것으로 본다(startup_registry.dart 참고).

String? readStartupPath() => null;

void writeStartupPath(String exePath) {}

void deleteStartupPath() {}
