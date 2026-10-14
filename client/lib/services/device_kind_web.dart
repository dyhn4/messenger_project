import 'package:web/web.dart' as web;

// 웹 빌드에서 터치 화면인지 — 데스크톱 모드로 Mac처럼 보이는 아이패드를 휴대폰·태블릿으로 가르는 데 쓴다(device_kind.dart).
// 터치 노트북도 여기에 걸리지만, 그쪽을 휴대폰으로 잘못 보는 편(PC 앱과 알림이 두 번 뜰 수 있음)이 아이패드 알림을 아예 놓치는
// 것보다 낫다. 네이티브 빌드는 device_kind_stub.dart.

bool get webHasTouchScreen {
  try {
    return web.window.navigator.maxTouchPoints > 1;
  } catch (_) {
    return false;
  }
}
