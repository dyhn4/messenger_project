import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../screens/project/project_window.dart' show broadcastLockChange;
import 'session.dart';

/// 환경설정 > 시스템 설정 > "자동 잠금" — PC가 절전 모드에 들어가거나 화면이 꺼지면 메신저를
/// 잠근다. 잠긴 동안은 앱 전체를 가리는 잠금 화면(widgets/app_lock_overlay.dart)이 떠서 로그인
/// 비밀번호를 넣어야 풀린다. 잠긴 상태는 저장해 두므로(AppSettings.appLocked) 트레이에서 다시
/// 열거나 앱을 껐다 켜도 잠긴 채로 뜬다. 따로 떠 있는 "프로젝트" 창도 같이 가린다.
class AppLock {
  AppLock._();

  /// windows/runner/flutter_window.cpp가 절전("suspend")·화면 꺼짐("displayOff")을 알리는 채널.
  static const _power = MethodChannel('tangotalk/power');

  /// 메인 창에서 한 번 부른다(main.dart).
  static void install(Session session) {
    if (!Platform.isWindows) return;
    _power.setMethodCallHandler((call) async {
      if (call.method != 'suspend' && call.method != 'displayOff') return;
      if (!session.settings.autoLockOnSleep) return;
      if (session.stage != AuthStage.ready) return; // 로그인 전에는 잠글 게 없다.
      await lock(session);
    });
  }

  static Future<void> lock(Session session) async {
    await session.settings.setAppLocked(true);
    unawaited(broadcastLockChange(true));
  }

  static Future<void> unlock(Session session) async {
    await session.settings.setAppLocked(false);
    unawaited(broadcastLockChange(false));
  }
}
