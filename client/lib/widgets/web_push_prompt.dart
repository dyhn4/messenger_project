import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_platform.dart';
import '../services/session.dart';
import '../services/web_notifications.dart';
import 'app_toast.dart';

/// 웹 앱에서 알림을 켜자고 권하는 알약(화면 위 가운데) — 앱 화면이 아니면(로그인 전 등) 안 보인다.
/// - 아이폰 Safari 탭: 웹 푸시는 홈 화면에 추가한 앱에서만 되니 그 방법을 안내한다.
/// - 그 밖에 아직 묻지 않은 브라우저: [알림 켜기]를 누르면 권한을 묻는다(아이폰은 누름으로만 물을 수 있다).
/// 닫으면 이 브라우저에서는 다시 띄우지 않는다(환경설정 > 알림에서 언제든 켤 수 있다).
///
/// main.dart의 MaterialApp.builder에서 Navigator와 형제로 붙는다(UpdateBanner와 같은 자리) — 그래서
/// Tooltip을 쓰면 안 되고, 대화상자는 [navigatorKey]의 context로 연다.
class WebPushPrompt extends StatefulWidget {
  final Session session;
  final GlobalKey<NavigatorState> navigatorKey;
  const WebPushPrompt({
    super.key,
    required this.session,
    required this.navigatorKey,
  });

  @override
  State<WebPushPrompt> createState() => _WebPushPromptState();
}

const _kDismissedKey = 'web_push_prompt_dismissed';

class _WebPushPromptState extends State<WebPushPrompt> {
  bool _dismissed = true; // 저장값을 읽기 전엔 띄우지 않는다.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) return;
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() => _dismissed = prefs.getBool(_kDismissedKey) ?? false);
      }
    });
  }

  Future<void> _dismiss() async {
    setState(() => _dismissed = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDismissedKey, true);
  }

  Future<void> _enable() async {
    setState(() => _busy = true);
    final result = await widget.session.enableWebNotifications();
    if (!mounted) return;
    setState(() => _busy = false);
    // 허용했든 거절했든 더는 물어볼 게 없다(거절은 브라우저 설정에서만 되돌릴 수 있다).
    if (result != 'default') await _dismiss();
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb || _dismissed) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        if (widget.session.stage != AuthStage.ready) {
          return const SizedBox.shrink();
        }
        final needsHomeScreen = AppPlatform.isWebOnIOS && !isStandaloneDisplay;
        final canAsk =
            webNotificationsSupported && webNotificationPermission == 'default';
        if (!needsHomeScreen && !canAsk) return const SizedBox.shrink();
        final colors = Theme.of(context).colorScheme;
        return SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Material(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(24),
                elevation: 3,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.notifications_active_outlined,
                        size: 18,
                        color: colors.onPrimaryContainer,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          needsHomeScreen
                              ? '홈 화면에 추가하면 알림을 받을 수 있습니다.'
                              : '알림을 켜면 새 메시지를 놓치지 않습니다.',
                          style: TextStyle(
                            color: colors.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : needsHomeScreen
                            ? () => showAddToHomeScreenGuide(
                                widget.navigatorKey.currentContext ?? context,
                              )
                            : _enable,
                        child: Text(needsHomeScreen ? '방법 보기' : '알림 켜기'),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.close,
                          size: 16,
                          color: colors.onPrimaryContainer,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        onPressed: _dismiss,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 아이폰 Safari에서 홈 화면에 추가하는 방법 — 웹 푸시는 그렇게 추가한 앱에서만 받는다(iOS 16.4 이상).
Future<void> showAddToHomeScreenGuide(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('홈 화면에 추가하기'),
      content: const Text(
        '아이폰은 홈 화면에 추가한 앱에서만 알림을 받을 수 있습니다(iOS 16.4 이상).\n\n'
        '1. Safari 아래쪽의 공유 단추(네모에서 화살표가 나온 모양)를 누릅니다.\n'
        '2. "홈 화면에 추가"를 누릅니다.\n'
        '3. 홈 화면에 생긴 TangoTalk 아이콘으로 열고, 로그인한 뒤 "알림 켜기"를 누릅니다.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('확인'),
        ),
      ],
    ),
  );
}

/// 환경설정의 "알림" 항목(웹 전용) — 지금 상태와, 켤 수 있으면 [알림 켜기] 단추.
class WebNotificationSetting extends StatefulWidget {
  final Session session;
  const WebNotificationSetting({super.key, required this.session});

  @override
  State<WebNotificationSetting> createState() => _WebNotificationSettingState();
}

class _WebNotificationSettingState extends State<WebNotificationSetting> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final needsHomeScreen = AppPlatform.isWebOnIOS && !isStandaloneDisplay;
    final permission = webNotificationPermission;
    final String status;
    Widget? action;
    if (needsHomeScreen) {
      status = '아이폰은 홈 화면에 추가한 앱에서만 알림을 받을 수 있습니다.';
      action = OutlinedButton(
        onPressed: () => showAddToHomeScreenGuide(context),
        child: const Text('방법 보기'),
      );
    } else if (!webNotificationsSupported) {
      status = '이 브라우저는 알림을 지원하지 않습니다.';
    } else if (permission == 'granted') {
      final push = webPushSupported && widget.session.webPushEnabled;
      status = push
          ? '켜져 있습니다. 앱을 닫아도 새 메시지 알림이 옵니다.'
          : '켜져 있습니다. 앱이 열려 있는 동안 새 메시지 알림이 옵니다.';
      // 앱을 닫아도 오는 알림(이 브라우저의 웹 푸시) 켜고 끄기 — 같은 기기에서 PC 앱·휴대폰 앱으로도 알림을 받으면 두 번 뜨니
      // 끌 수 있게 한다(그 앱이 켜져 있는 동안은 서버가 알아서 막지만, 앱을 껐을 때나 다른 기기 브라우저는 여기서 고른다).
      if (webPushSupported) {
        action = SwitchListTile(
          key: const ValueKey('web-push-switch'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('앱을 닫아도 알림 받기(푸시)'),
          subtitle: const Text(
            '끄면 이 브라우저는 웹 앱이 열려 있는 동안에만 알림을 받습니다. 같은 기기에서 앱으로 알림을 받고 있다면 꺼 두세요.',
          ),
          value: widget.session.webPushEnabled,
          onChanged: _busy
              ? null
              : (on) async {
                  setState(() => _busy = true);
                  try {
                    await widget.session.setWebPushEnabled(on);
                  } catch (e) {
                    if (context.mounted) {
                      showAppToast(context, '알림 설정을 바꾸지 못했습니다: $e');
                    }
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
        );
      }
    } else if (permission == 'denied') {
      status = '브라우저에서 알림이 차단되어 있습니다. 주소창의 사이트 설정에서 알림을 허용하세요.';
    } else {
      status = '꺼져 있습니다.';
      action = FilledButton.tonal(
        onPressed: _busy
            ? null
            : () async {
                setState(() => _busy = true);
                await widget.session.enableWebNotifications();
                if (mounted) setState(() => _busy = false);
              },
        child: const Text('알림 켜기'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(status, style: TextStyle(fontSize: 13, color: hint)),
        if (action != null) ...[const SizedBox(height: 8), action],
      ],
    );
  }
}
