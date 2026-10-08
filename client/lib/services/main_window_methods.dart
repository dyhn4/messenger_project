import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';

/// 메인 창이 서브 창(desktop_multi_window — 캡처 오버레이, 알림 창 …)에게서 받는 메서드 호출을 한 곳에서 나눠 준다.
/// 창 하나에는 메서드 핸들러를 하나만 걸 수 있어서, 기능마다 [WindowController.setWindowMethodHandler]를 따로 부르면
/// 나중에 건 쪽이 앞의 것을 덮어쓰고, 다 쓰고 null로 지우면 다른 기능의 핸들러까지 같이 사라진다. 그래서 핸들러는
/// 여기서 한 번만 걸고, 기능들은 자기 메서드 이름으로 등록·해제한다. Windows 메인 창에서만 쓴다.
typedef MainWindowMethodHandler = Future<dynamic> Function(MethodCall call);

final _handlers = <String, MainWindowMethodHandler>{};
Future<void>? _installing;

/// [method]를 받으면 [handler]를 부른다 — 같은 이름으로 다시 등록하면 바꿔 낀다.
Future<void> registerMainWindowMethod(
  String method,
  MainWindowMethodHandler handler,
) {
  _handlers[method] = handler;
  return _installing ??= () async {
    try {
      final me = await WindowController.fromCurrentEngine();
      await me.setWindowMethodHandler((call) async {
        final h = _handlers[call.method];
        return h == null ? null : await h(call);
      });
    } catch (_) {
      _installing = null; // 다음 등록 때 다시 시도한다.
      rethrow;
    }
  }();
}

/// [method] 등록을 푼다 — [handler]를 주면 그 핸들러가 아직 등록돼 있을 때만(그 사이 다른 쪽이 바꿔 꼈으면 두고).
void unregisterMainWindowMethod(
  String method, [
  MainWindowMethodHandler? handler,
]) {
  if (handler == null || identical(_handlers[method], handler)) {
    _handlers.remove(method);
  }
}
