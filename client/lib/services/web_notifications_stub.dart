// 네이티브 빌드용 — 웹 알림·웹 푸시가 없다(알림은 flutter_local_notifications, 푸시는 FCM이 맡는다).
// 웹 구현은 web_notifications_web.dart.

bool get webNotificationsSupported => false;

bool get webPushSupported => false;

String get webNotificationPermission => 'unsupported';

bool get isStandaloneDisplay => false;

Future<void> initWebNotifications(
  void Function(String payload) onClick,
) async {}

String? takeLaunchNotificationPayload() => null;

Future<String> requestWebNotificationPermission() async => 'unsupported';

Future<void> showWebNotification({
  required String title,
  required String body,
  required String tag,
  required String payload,
}) async {}

Future<void> closeWebNotifications(String tag) async {}

Future<Map<String, dynamic>?> subscribeWebPush(String vapidPublicKey) async =>
    null;

Future<void> unsubscribeWebPush() async {}
