import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import 'web_safe_area_stub.dart'
    if (dart.library.js_interop) 'web_safe_area_web.dart'
    as impl;

/// 웹 앱이 아이폰의 상태바(시계·배터리 줄)·홈 막대 자리를 피하게 한다.
///
/// Flutter 웹은 기기의 안전 영역(노치·상태바·홈 막대)을 MediaQuery.padding으로 알려 주지 않아(늘 0) SafeArea·앱 바가
/// 아무 여백도 두지 않는다. 그래서 아이폰 홈 화면 웹 앱에서 화면이 상태바 밑까지 올라가, iOS가 상태바 뒤에 거는 흐림이
/// 앱 바의 글자까지 덮었다. [enableWebSafeArea]가 페이지를 안전 영역까지 펼치고(viewport-fit=cover — Flutter가 뜨면서
/// 자기 viewport 설정으로 바꿔 빠졌었다) CSS `env(safe-area-inset-*)` 값을 읽어 두면, [WebSafeArea]가 그 값을
/// MediaQuery.padding에 얹는다 — 네이티브 앱처럼 앱 바 배경은 상태바 뒤까지 깔리고 글자는 그 아래에 놓인다.
/// 웹이 아니거나 안전 영역이 없는 기기(PC·안드로이드 브라우저 등)에서는 아무것도 바꾸지 않는다.
void enableWebSafeArea() {
  if (kIsWeb) impl.enableWebSafeArea();
}

/// [child] 아래의 MediaQuery.padding·viewPadding에 웹 페이지의 안전 영역을 더한다(웹이 아니면 그대로).
class WebSafeArea extends StatelessWidget {
  final Widget child;
  const WebSafeArea({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return child;
    return ValueListenableBuilder<EdgeInsets>(
      valueListenable: impl.webSafeAreaInsets,
      builder: (context, insets, child) {
        if (insets == EdgeInsets.zero) return child!;
        final mq = MediaQuery.of(context);
        final view = EdgeInsets.fromLTRB(
          math.max(mq.viewPadding.left, insets.left),
          math.max(mq.viewPadding.top, insets.top),
          math.max(mq.viewPadding.right, insets.right),
          math.max(mq.viewPadding.bottom, insets.bottom),
        );
        return MediaQuery(
          data: mq.copyWith(
            viewPadding: view,
            // 네이티브와 같이 — 키보드가 올라와 있으면 그만큼 아래 여백(홈 막대 자리)은 빠진다.
            padding: EdgeInsets.fromLTRB(
              view.left,
              view.top,
              view.right,
              math.max(0, view.bottom - mq.viewInsets.bottom),
            ),
          ),
          child: child!,
        );
      },
      child: child,
    );
  }
}
