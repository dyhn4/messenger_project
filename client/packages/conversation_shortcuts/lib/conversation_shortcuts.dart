import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 안드로이드 11+에서 알림이 "대화(conversation)"로 분류되려면(= 프로필 사진이 왼쪽 큰
/// 원으로 오고 앱 아이콘이 그 모서리에 작은 배지로 붙는 레이아웃) MessagingStyle만으로는
/// 부족하고, 알림의 shortcutId와 같은 id를 가진 long-lived 단축키가 실제로 등록돼 있어야 한다.
/// 이 플러그인이 그 단축키를 등록한다.
///
/// 정식 플러그인 패키지로 만든 이유: 앱이 완전히 꺼진 상태에서 FCM으로 알림을 그리는
/// 백그라운드 isolate에는 MainActivity가 없어서 거기서 만든 MethodChannel을 못 쓴다.
/// 반면 pub 플러그인은 백그라운드 FlutterEngine에도 자동 등록되므로 양쪽에서 다 동작한다.
class ConversationShortcuts {
  static const _channel = MethodChannel('teamtalk/conversation_shortcuts');

  /// [id]는 알림의 shortcutId와 같아야 한다(우리는 roomId를 쓴다). [icon]은 정사각형 PNG로,
  /// 안드로이드가 중앙 기준 원형으로 크롭해서 쓴다(어댑티브 아이콘이 아니라 일반 비트맵
  /// 아이콘 — notification_service.dart의 _badgeWithLock 주석 참고).
  ///
  /// 실패해도(구형 안드로이드, 단축키 개수 제한 등) 알림 자체는 정상적으로 떠야 하므로
  /// 예외는 삼킨다 — 이 경우 그냥 기존의 일반 알림 레이아웃으로 보인다.
  static Future<void> push({
    required String id,
    required String label,
    Uint8List? icon,
  }) async {
    try {
      await _channel.invokeMethod<void>('pushConversationShortcut', {
        'id': id,
        'label': label,
        'icon': icon,
      });
    } catch (_) {
      // 무시 — 위 주석 참고.
    }
  }
}
