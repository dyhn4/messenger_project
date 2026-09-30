import 'package:flutter/material.dart';

/// 안드로이드 네이티브 토스트처럼 보이는 화면 하단 알림 — 첨부 이미지 참고(둥근 어두운
/// 배경 알약 + 흰 글씨, 화면 아래쪽 중앙, 일정 시간 후 저절로 사라짐). session.dart의
/// toasts 스트림(비밀 대화 거절/양쪽 나가기처럼 "방이 사라지는" 이벤트)뿐 아니라, 초대 링크
/// 복사처럼 다이얼로그 안에서 즉시 피드백을 줄 때도 쓴다.
///
/// [context]가 가리키는 가장 가까운 [Overlay]에 직접 [OverlayEntry]를 꽂는다 — 예전에는
/// SnackBar(ScaffoldMessenger)를 썼는데, ScaffoldMessenger.showSnackBar는 실제로는 그
/// context 위쪽에 있는 **Scaffold**(다이얼로그를 연 원래 화면 쪽) 안에 그려진다. FloatingDialog
/// 같은 Dialog 위젯은 그 자신은 Scaffold가 아니므로, 다이얼로그 안에서 부르면 SnackBar가
/// 다이얼로그 뒤 화면에 그려져 떠 있는 다이얼로그에 완전히 가려 안 보였다(예: 팀 초대 링크
/// 화면의 "링크 복사" 토스트). Overlay는 다이얼로그를 포함해 지금 열려 있는 모든 라우트보다
/// "나중에 삽입"되므로 어디서 불러도 항상 맨 위에 뜬다.
void showAppToast(
  BuildContext context,
  String message, {
  Duration duration = const Duration(milliseconds: 2000),
}) {
  showAppToastOnOverlay(Overlay.of(context), message, duration: duration);
}

/// [showAppToast]와 같지만 [Overlay]를 직접 받는다 — 알림을 띄우기 전에 창이 닫히거나 목록 항목이 없어져
/// (삭제·나가기 직후) 부른 쪽 context가 사라지는 경우, 미리 잡아 둔 Overlay로 결과를 알리려고.
void showAppToastOnOverlay(
  OverlayState overlay,
  String message, {
  Duration duration = const Duration(milliseconds: 2000),
}) {
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _AppToast(
      message: message,
      duration: duration,
      onDone: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _AppToast extends StatefulWidget {
  final String message;
  final Duration duration;
  final VoidCallback onDone;
  const _AppToast({
    required this.message,
    required this.duration,
    required this.onDone,
  });

  @override
  State<_AppToast> createState() => _AppToastState();
}

class _AppToastState extends State<_AppToast> {
  double _opacity = 0;

  @override
  void initState() {
    super.initState();
    // 삽입 직후 바로 1로 두면 애니메이션이 안 먹으므로, 한 프레임 뒤로 미뤄 시작값(0)이
    // 먼저 그려지게 한다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _opacity = 1);
    });
    // 전체 노출 시간(duration)의 마지막 300ms 동안 페이드아웃하고, 그 직후 완전히 치운다.
    final fadeOutDelay = widget.duration - const Duration(milliseconds: 300);
    Future.delayed(fadeOutDelay, () {
      if (mounted) setState(() => _opacity = 0);
    });
    Future.delayed(widget.duration, widget.onDone);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Positioned(
      // 화면 폭에 상관없이 항상 가운데의 좁은 알약으로 보이도록, 양옆 여백을 폭의 비율로
      // 잡는다(고정 margin이면 넓은 PC 화면에서 가로로 길게 늘어져 알약처럼 안 보인다).
      left: width * 0.3,
      right: width * 0.3,
      bottom: 32,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: _opacity,
          duration: const Duration(milliseconds: 200),
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xE6323232),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Text(
                widget.message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
