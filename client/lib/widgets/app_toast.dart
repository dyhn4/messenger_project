import 'package:flutter/material.dart';

/// 안드로이드 네이티브 토스트처럼 보이는 화면 하단 알림 — 첨부 이미지 참고(둥근 어두운
/// 배경 알약 + 흰 글씨, 화면 아래쪽 중앙, 일정 시간 후 저절로 사라짐). session.dart의
/// toasts 스트림(비밀 대화 거절/양쪽 나가기처럼 "방이 사라지는" 이벤트)을 보여줄 때 쓴다.
///
/// SnackBar를 쓰되 floating + 둥근 모양 + 좁은 너비로 꾸며서 액션 버튼 없는 토스트처럼
/// 보이게 한다.
///
/// [context]는 반드시 실제로 화면에 마운트된(라우트/화면 자신의) context여야 한다 —
/// MaterialApp의 navigatorKey.currentContext(Navigator 위젯 자체의 context)를 쓰면
/// ScaffoldMessenger.of가 예외 없이 성공한 것처럼 보여도 실제 화면에는 그려지지 않는다
/// (home_screen.dart가 자기 자신의 context로 구독하는 이유).
void showAppToast(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  final width = MediaQuery.sizeOf(context).width;
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
      backgroundColor: const Color(0xE6323232),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      duration: const Duration(milliseconds: 2000),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      // 화면 폭에 상관없이 항상 가운데의 좁은 알약으로 보이도록, 양옆 여백을 폭의 비율로
      // 잡는다(고정 margin이면 넓은 PC 화면에서 가로로 길게 늘어져 알약처럼 안 보인다).
      margin: EdgeInsets.only(
        left: width * 0.3,
        right: width * 0.3,
        bottom: 32,
      ),
    ),
  );
}
