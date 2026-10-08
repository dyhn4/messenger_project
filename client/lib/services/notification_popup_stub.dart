import 'package:desktop_multi_window/desktop_multi_window.dart';

import 'notification_popup_style.dart';

// 웹 빌드용 — 알림 창은 Win32로 띄우는 Windows 전용 기능이다(notification_popup.dart 참고). 공개 API 모양만 맞춘다.

const kNotificationPopupWindowType = 'notify';

void setNotificationPopupTapHandler(void Function(String payload) onTap) {}

Future<bool> showNotificationPopup({
  required String key,
  required String title,
  required String body,
  required String payload,
  String? imagePath,
  NotificationPopupStyle style = const NotificationPopupStyle(),
  bool force = false,
  bool sound = true,
}) async => false;

Future<void> cancelNotificationPopup(String key) async {}

Future<void> runNotificationPopupWindow(
  WindowController controller,
  Map<String, dynamic> args,
) async {}
