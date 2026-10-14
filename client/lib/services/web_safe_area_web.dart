import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:web/web.dart' as web;

// 웹 빌드에서 페이지의 안전 영역(CSS env(safe-area-inset-*))을 읽는다(web_safe_area.dart). 네이티브 빌드는 web_safe_area_stub.dart.

final ValueNotifier<EdgeInsets> _insets = ValueNotifier(EdgeInsets.zero);
ValueListenable<EdgeInsets> get webSafeAreaInsets => _insets;

web.HTMLElement? _probe;

void enableWebSafeArea() {
  if (_probe != null) return;
  try {
    _coverViewport();
    // 안전 영역만큼 padding을 가진 보이지 않는 칸 — 계산된 padding이 곧 env(safe-area-inset-*) 값(px)이다.
    final probe = web.document.createElement('div') as web.HTMLElement;
    probe.style.cssText =
        'position:fixed;top:0;left:0;width:0;height:0;visibility:hidden;'
        'pointer-events:none;'
        'padding:env(safe-area-inset-top,0px) env(safe-area-inset-right,0px) '
        'env(safe-area-inset-bottom,0px) env(safe-area-inset-left,0px);';
    web.document.body?.append(probe);
    _probe = probe;
    _read();
    // 화면 회전·창 크기 변화 때 다시 읽는다. viewport 설정을 바꾼 직후에는 값이 늦게 반영될 수 있어 조금 뒤에도 몇 번.
    final onChange = ((web.Event _) => _read()).toJS;
    web.window.addEventListener('resize', onChange);
    web.window.addEventListener('orientationchange', onChange);
    for (final ms in const [100, 500, 1500]) {
      Timer(Duration(milliseconds: ms), _read);
    }
  } catch (_) {
    // 못 읽으면 예전처럼 여백 없이 둔다.
  }
}

/// Flutter 웹은 뜨면서 index.html의 viewport 설정을 자기 것으로 바꿔 viewport-fit=cover가 빠진다 — 다시 붙여야
/// 아이폰이 env(safe-area-inset-*)에 실제 값을 준다.
void _coverViewport() {
  final metas = web.document.querySelectorAll('meta[name="viewport"]');
  for (var i = 0; i < metas.length; i++) {
    final meta = metas.item(i) as web.HTMLMetaElement;
    if (!meta.content.contains('viewport-fit')) {
      meta.content = '${meta.content}, viewport-fit=cover';
    }
  }
}

double _px(String value) => double.tryParse(value.replaceAll('px', '')) ?? 0;

void _read() {
  final probe = _probe;
  if (probe == null) return;
  try {
    final style = web.window.getComputedStyle(probe);
    final next = EdgeInsets.fromLTRB(
      _px(style.paddingLeft),
      _px(style.paddingTop),
      _px(style.paddingRight),
      _px(style.paddingBottom),
    );
    if (next != _insets.value) _insets.value = next;
  } catch (_) {}
}
