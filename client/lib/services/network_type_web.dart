import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

// 웹 빌드에서 지금 연결이 휴대폰 데이터인지 본다 — Network Information API(navigator.connection).
// package:web의 NetworkInformation에는 `type`이 없어서 속성을 직접 읽는다. 네이티브 빌드는
// network_type_stub.dart.

/// navigator.connection.type이 'cellular'인지. 이 API는 안드로이드 크롬 계열에만 있고(PC 크롬은
/// `type`을 주지 않는다), 아이폰 Safari·파이어폭스에는 없어서 그때는 false다.
bool get webConnectionIsCellular {
  try {
    final navigator = web.window.navigator;
    if (!navigator.has('connection')) return false;
    final connection = navigator.getProperty<JSObject?>('connection'.toJS);
    final type = connection?.getProperty<JSAny?>('type'.toJS);
    return type.dartify() == 'cellular';
  } catch (_) {
    return false;
  }
}
