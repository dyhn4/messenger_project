import 'package:flutter/material.dart' show ThemeMode;

/// PC 알림 창(notification_popup.dart)의 모양 — 앱 테마와, 환경설정 > 메신저 설정 > "메시지 내용 미리보기"
/// 아래에서 사람마다 고르는 카드 가로·세로(논리 픽셀 — 화면 배율을 곱해 그린다)와 한꺼번에 쌓이는 최대 개수.
/// 값은 AppSettings가 저장하고, 범위·간격·기본값은 여기 한 곳에 둔다(설정 화면 스텝퍼와 저장할 때의 보정이 같이 쓴다).
class NotificationPopupStyle {
  final ThemeMode themeMode;
  final int width;
  final int height;
  final int maxCards;

  const NotificationPopupStyle({
    this.themeMode = ThemeMode.light,
    this.width = defaultWidth,
    this.height = defaultHeight,
    this.maxCards = defaultMaxCards,
  });

  static const minWidth = 150;
  static const maxWidth = 480;
  static const widthStep = 10;
  static const defaultWidth = 270;

  static const minHeight = 40;
  static const maxHeight = 80;
  static const heightStep = 5;
  static const defaultHeight = 50;

  static const minCards = 1;
  static const maxCardsLimit = 5;
  static const defaultMaxCards = 3;

  /// 범위 밖이면 끝으로 붙이고, 간격에 안 맞으면 가까운 칸으로(예전에 저장된 값이나 손으로 고친 값도 안전하게).
  static int snapWidth(int v) => _snap(v, minWidth, maxWidth, widthStep);
  static int snapHeight(int v) => _snap(v, minHeight, maxHeight, heightStep);
  static int snapMaxCards(int v) => v.clamp(minCards, maxCardsLimit);

  static int _snap(int v, int min, int max, int step) =>
      (min + ((v.clamp(min, max) - min) / step).round() * step).clamp(min, max);
}
