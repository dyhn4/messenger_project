import 'dart:io' as io show Platform;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// dart:io의 `Platform` 대신 쓴다 — 웹 빌드에서는 `Platform.isWindows`처럼 건드리기만 해도
/// 예외가 나서, 웹이면 어느 OS도 아닌 것(전부 false)으로 본다. 웹인지 볼 때는 `kIsWeb`.
///
/// `defaultTargetPlatform`은 웹에서 브라우저가 도는 OS(아이폰 Safari면 iOS)를 돌려줘서 이 용도로는
/// 못 쓴다 — 웹 앱이 Windows 창 관리나 안드로이드 푸시 같은 네이티브 기능을 부르게 된다.
abstract final class AppPlatform {
  static bool get isWindows => !kIsWeb && io.Platform.isWindows;
  static bool get isAndroid => !kIsWeb && io.Platform.isAndroid;
  static bool get isIOS => !kIsWeb && io.Platform.isIOS;
  static bool get isMacOS => !kIsWeb && io.Platform.isMacOS;
  static bool get isLinux => !kIsWeb && io.Platform.isLinux;

  static String get pathSeparator => kIsWeb ? '/' : io.Platform.pathSeparator;

  static Map<String, String> get environment =>
      kIsWeb ? const {} : io.Platform.environment;

  static String get resolvedExecutable =>
      kIsWeb ? '' : io.Platform.resolvedExecutable;

  static String get operatingSystem =>
      kIsWeb ? 'web' : io.Platform.operatingSystem;

  /// 아이폰·아이패드의 브라우저(또는 홈 화면에 추가한 웹 앱)에서 도는 웹 빌드인지 — 화면 공유가 없고,
  /// 웹 푸시는 홈 화면에 추가해야만 되는 등 그 브라우저만의 제약을 안내할 때 쓴다. 아이패드 Safari는
  /// 기본이 데스크톱 모드라 Mac으로 보여서 여기 안 걸릴 수 있다.
  static bool get isWebOnIOS =>
      kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
}
