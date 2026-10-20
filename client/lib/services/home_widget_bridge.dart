import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../models/room.dart';
import 'app_platform.dart';
import 'session.dart';
import '../l10n/tr.dart';

/// 홈 화면 위젯 "안 읽은 대화"(안드로이드 — UnreadWidgetProvider.kt)에 줄 내용 — 안 읽은 메시지 합계와 안 읽은 방 세 개.
/// 알림을 끈(muted) 방은 빼고, 비밀 대화는 이름 대신 "비밀 대화"로, 앱 잠금을 켰으면 방 이름 없이 합계만, 로그아웃했으면 안내만
/// 보이게 한다(홈 화면은 누구나 본다). `{ total, rooms: [{ id, name, unread }], locked, loggedOut }`.
Map<String, dynamic> homeWidgetState({
  required bool signedIn,
  required bool locked,
  required String myUserId,
  required List<Room> rooms,
}) {
  if (!signedIn) return {'loggedOut': true, 'total': 0, 'rooms': const []};
  final unread = [
    for (final r in rooms)
      if (r.unreadCount > 0 && !r.muted) r,
  ]..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
  final total = unread.fold<int>(0, (sum, r) => sum + r.unreadCount);
  return {
    'total': total,
    'locked': locked,
    'rooms': locked
        ? const []
        : [
            for (final r in unread.take(3))
              {
                'id': r.id,
                'name': r.isSecret ? tr('비밀 대화') : r.displayName(myUserId),
                'unread': r.unreadCount,
              },
          ],
  };
}

/// 세션이 바뀔 때마다(잠깐 모아서) 위젯 내용을 다시 만들어, 달라졌을 때만 안드로이드로 넘긴다(채널 tangotalk/widget). 앱이 꺼져 있는 동안
/// 온 푸시는 안드로이드가 위젯 숫자만 직접 올리므로(PushWidgetReceiver.kt — 어림), 앱이 앞으로 돌아오면 같은 내용이어도 한 번 다시 넘겨
/// 정확한 값으로 덮는다.
class HomeWidgetBridge with WidgetsBindingObserver {
  HomeWidgetBridge(this.session, {MethodChannel? channel, bool? enabled})
    : _channel = channel ?? const MethodChannel('tangotalk/widget'),
      _enabled = enabled ?? AppPlatform.isAndroid;

  final Session session;
  final MethodChannel _channel;
  final bool _enabled;
  Timer? _timer;
  String? _lastJson;

  void start() {
    if (!_enabled) return;
    session.addListener(_schedule);
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _lastJson = null;
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 800), () => unawaited(push()));
  }

  /// 지금 내용을 넘긴다(같으면 넘기지 않는다).
  Future<void> push() async {
    final state = homeWidgetState(
      signedIn: session.stage == AuthStage.ready && session.token != null,
      locked: session.settings.appLocked,
      myUserId: session.userId ?? '',
      rooms: session.rooms,
    );
    final json = jsonEncode(state);
    if (json == _lastJson) return;
    _lastJson = json;
    try {
      await _channel.invokeMethod('update', {'json': json});
    } on MissingPluginException {
      // 예전 앱 껍데기 — 무시.
    } on PlatformException {
      // 무시.
    }
  }

  void stop() {
    _timer?.cancel();
    session.removeListener(_schedule);
    if (_enabled) WidgetsBinding.instance.removeObserver(this);
  }
}
