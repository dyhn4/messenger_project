import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_platform.dart';

/// Windows 앱의 비밀번호 칸에서 한글 입력기(IME)를 끈다. 일반 Windows 프로그램의 비밀번호 칸은 입력기가
/// 저절로 꺼지지만 Flutter의 칸(obscureText)은 그렇지 않아서, 한글 상태로 치면 자모가 조합 중인 채로
/// 들어가 비밀번호가 제대로 입력되지 않았다. 안드로이드 키보드와 웹 브라우저는 비밀번호 칸에서 스스로
/// 영문으로 바꾸므로 Windows만 다룬다.
///
/// 칸마다 감싸지 않고 포커스가 바뀔 때마다 지금 포커스가 비밀번호 칸(obscureText인 EditableText)인지 본다 —
/// 로그인·잠금 해제·비밀번호 변경 등 어느 칸이든, 앞으로 생길 칸도 따로 손대지 않아도 된다. 칸을 벗어나면
/// 입력기를 다시 붙여 사용자가 쓰던 한/영 상태로 돌아간다(windows/runner/flutter_window.cpp의 SetLatinOnly).
abstract final class PasswordIme {
  static const _channel = MethodChannel('tangotalk/ime');
  static bool _latinOnly = false;

  /// 메인 창에서 한 번 부른다(main.dart). 따로 뜨는 "프로젝트" 창(별도 엔진)에는 이 채널이 없다.
  static void install() {
    if (!AppPlatform.isWindows) return;
    FocusManager.instance.addListener(_update);
  }

  static void _update() {
    final latinOnly = isPasswordField(FocusManager.instance.primaryFocus);
    if (latinOnly == _latinOnly) return;
    _latinOnly = latinOnly;
    _channel.invokeMethod<void>('setLatinOnly', latinOnly).catchError((_) {});
  }

  /// [node]가 비밀번호 칸(obscureText인 EditableText)의 포커스인지. 포커스 노드는 EditableText 안쪽의 Focus에
  /// 붙어 있어서 그 위의 EditableText를 찾는다(Flutter 버전에 따라 EditableText 자신에 붙을 수도 있어 둘 다 본다).
  @visibleForTesting
  static bool isPasswordField(FocusNode? node) {
    final context = node?.context;
    if (context == null || !context.mounted) return false;
    final widget = context.widget;
    final editable = widget is EditableText
        ? widget
        : context.findAncestorWidgetOfExactType<EditableText>();
    return editable?.obscureText ?? false;
  }
}
