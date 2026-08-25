import 'package:flutter/material.dart';

/// 회색 트랙+막대 스크롤바(마우스를 올리면 살짝 진해짐). 검색 결과/멤버 목록 등 긴 목록에서
/// 공통으로 쓴다.
class MutedScrollbar extends StatelessWidget {
  final ScrollController controller;
  final Widget child;
  const MutedScrollbar({super.key, required this.controller, required this.child});

  @override
  Widget build(BuildContext context) {
    return ScrollbarTheme(
      data: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(10),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? Colors.grey.withValues(alpha: 0.75)
              : Colors.grey.withValues(alpha: 0.6),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? Colors.grey.withValues(alpha: 0.45)
              : Colors.grey.withValues(alpha: 0.28),
        ),
        trackBorderColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      child: Scrollbar(
        controller: controller,
        thumbVisibility: true,
        trackVisibility: true,
        child: child,
      ),
    );
  }
}
