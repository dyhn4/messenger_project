import 'package:flutter/painting.dart' show Color;
import 'package:web/web.dart' as web;

// 웹 빌드에서 페이지 바탕색·theme-color를 앱 바탕색에 맞춘다(web_page_color.dart). 네이티브 빌드는 web_page_color_stub.dart.

String? _applied;

void syncWebPageColor(Color color) {
  final argb = color.toARGB32();
  final css = '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  // 테마 전환 애니메이션 동안에는 프레임마다 불리므로, 바뀌었을 때만 DOM을 건드린다.
  if (css == _applied) return;
  _applied = css;
  try {
    (web.document.documentElement as web.HTMLElement?)?.style.backgroundColor =
        css;
    web.document.body?.style.backgroundColor = css;
    final metas = web.document.querySelectorAll('meta[name="theme-color"]');
    if (metas.length == 0) {
      final meta = web.document.createElement('meta') as web.HTMLMetaElement
        ..name = 'theme-color'
        ..content = css;
      web.document.head?.append(meta);
    } else {
      for (var i = 0; i < metas.length; i++) {
        (metas.item(i) as web.HTMLMetaElement).content = css;
      }
    }
  } catch (_) {
    // 페이지 색은 꾸밈일 뿐이라 실패해도 앱은 그대로 둔다.
  }
}
