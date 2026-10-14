import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;

import 'app_platform.dart';
import 'device_kind_stub.dart'
    if (dart.library.js_interop) 'device_kind_web.dart';

/// 서버에 기기를 등록할 때 알려 주는 기기 종류(server/src/devices.js DEVICE_KINDS) — 'windows'(PC 앱) | 'android' |
/// 'web-desktop'(PC 브라우저의 웹 앱) | 'web-android'(안드로이드 기기의 브라우저) | 'web-mobile'(아이폰·아이패드 등 그 밖의
/// 휴대폰·태블릿 브라우저). 모르면 null.
///
/// 서버는 PC 앱이 접속해 있는 동안 PC 브라우저로, 안드로이드 앱이 접속해 있는 동안 안드로이드 브라우저로는 웹 푸시를 보내지
/// 않는다 — 앱을 켜 둔 기기에서 웹 앱 탭을 닫으면 브라우저가 웹 푸시를 받아, 앱 알림과 브라우저 알림이 둘 다 떴다
/// (server/src/presence.js webPushTargets). 그래서 아이폰·아이패드를 PC나 안드로이드 브라우저로 잘못 알리면 그 기기의 알림이
/// 사라진다 — 애매하면 'web-mobile'로 본다.
String? deviceKind() {
  final override = debugDeviceKindOverride;
  if (override != null) return override;
  if (AppPlatform.isWindows) return 'windows';
  if (AppPlatform.isAndroid) return 'android';
  if (!kIsWeb) return null;
  if (defaultTargetPlatform == TargetPlatform.android) return 'web-android';
  // 아이패드 사파리는 기본이 데스크톱 모드라 Mac으로 보인다 — 터치 화면인 Mac은 없으니 터치 지점으로 가른다.
  return defaultTargetPlatform == TargetPlatform.iOS || webHasTouchScreen
      ? 'web-mobile'
      : 'web-desktop';
}

/// 시험이 기기 종류를 정해 두는 자리 — null이면 실제로 알아본다.
@visibleForTesting
String? debugDeviceKindOverride;
