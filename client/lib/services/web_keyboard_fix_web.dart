import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

// 웹 빌드에서 키보드를 닫은 뒤 줄어든 채 묶인 화면 높이를 되돌린다(web_keyboard_fix.dart). 네이티브 빌드는
// web_keyboard_fix_stub.dart.

bool _enabled = false;
Timer? _check;

void enableWebKeyboardFix() {
  if (_enabled) return;
  final viewport = web.window.visualViewport;
  if (viewport == null) return;
  _enabled = true;
  viewport.addEventListener(
    'resize',
    ((web.Event event) {
      // 아래 _recoverIfStuck이 엔진에 보내는 가짜 resize는 건너뛴다.
      if (!event.isTrusted) return;
      // 엔진도 같은 이벤트로 화면 크기를 다시 계산하는데 그 처리가 이 리스너보다 늦게 끝난다 — 조금 기다렸다 본다.
      _check?.cancel();
      _check = Timer(const Duration(milliseconds: 150), _recoverIfStuck);
    }).toJS,
  );
}

void _recoverIfStuck() {
  final view = WidgetsBinding.instance.platformDispatcher.implicitView;
  final viewport = web.window.visualViewport;
  if (view == null || viewport == null) return;
  // 묶인 상태에서는 엔진이 기억한 화면 높이가 지금 보이는 높이보다 작아 키보드 인셋이 음수가 된다(정상이면 0 이상).
  if (view.viewInsets.bottom >= 0) return;
  // 입력 중인 동안은 엔진이 화면 높이를 바꾸지 않으니 포커스를 놓아 입력을 끝낸 뒤(입력 연결이 닫히는 데 한 박자
  // 걸린다), 브라우저 크기가 바뀐 것처럼 알려서 지금 보이는 높이로 다시 재게 한다.
  FocusManager.instance.primaryFocus?.unfocus();
  Timer(const Duration(milliseconds: 100), () {
    viewport.dispatchEvent(web.Event('resize'));
  });
}
