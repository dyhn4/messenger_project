import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../services/app_platform.dart';

/// 카카오톡 PC처럼 ESC로 창을 최소화한다(Windows — 메인 창과 프로젝트 창).
///
/// ESC는 원래 대화상자·팝업 메뉴·멘션 목록·편집 창 닫기 등에 먼저 쓰인다. 키 입력은 포커스된 위젯에서 바깥쪽
/// 으로 올라오므로, 안쪽에서 ESC를 쓰는 위젯(멘션 목록·메뉴·달력 등)이 먼저 받고 안 쓴 ESC만 Navigator 바깥의
/// 여기까지 온다. 그리고 위에 뜬 화면(대화상자·팝업·전체 화면 페이지)이 하나라도 있으면 최소화하지 않고 그냥
/// 넘긴다 — 대화상자는 그 뒤에 있는 앱 기본 단축키(ESC → 닫기)가 닫고, 닫히지 않는 대화상자도 있다.
///
/// (Actions로 [DismissIntent]를 받는 방식은 안 된다 — 맨 아래 페이지 라우트가 꺼진 DismissAction을 늘 갖고 있어서
/// 단축키가 그 꺼진 처리기에서 멈추고 Navigator 바깥까지 오지 않는다.)
///
/// MaterialApp.builder에서 Navigator([child])를 감싼다. 아무 위젯에도 포커스가 없으면 키가 아예 안 닿아서,
/// 포커스가 없을 때 받을 자리([Focus.autofocus])를 겸한다.
class EscToMinimize extends StatelessWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  /// 테스트가 Windows 밖에서도 켜고, 실제 창 대신 [onMinimize]로 확인하는 자리.
  final bool? enabled;
  final VoidCallback? onMinimize;

  const EscToMinimize({
    super.key,
    required this.navigatorKey,
    required this.child,
    this.enabled,
    this.onMinimize,
  });

  @override
  Widget build(BuildContext context) {
    if (!(enabled ?? AppPlatform.isWindows)) return child;
    return Focus(
      autofocus: true,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        // 위에 뜬 화면이 있으면 그 화면 몫(대화상자 닫기 등) — 손대지 않는다.
        if (navigatorKey.currentState?.canPop() ?? true) {
          return KeyEventResult.ignored;
        }
        (onMinimize ?? () => windowManager.minimize())();
        return KeyEventResult.handled;
      },
      child: child,
    );
  }
}
