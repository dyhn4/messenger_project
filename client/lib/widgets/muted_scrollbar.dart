import 'package:flutter/material.dart';

/// 회색 트랙+막대 스크롤바 테마(마우스를 올리면 살짝 진해짐) — 채팅방 스크롤바
/// (indexed_scrollbar.dart)와 같은 두께(10px)로 맞췄다. [MutedScrollbar]와, TextField처럼
/// 직접 Scrollbar를 못 떼어내는 곳에서 [ScrollbarTheme]으로 감싸 재사용한다(chat_input_bar.dart
/// 참고 — EditableText는 여러 줄일 때 조상 ScrollConfiguration과 무관하게 항상 자체 스크롤바를
/// 강제로 붙이므로, 그 자동 스크롤바를 이 테마로 꾸미는 것 외엔 막을 방법이 없다).
final mutedScrollbarThemeData = ScrollbarThemeData(
  thickness: const WidgetStatePropertyAll(10),
  // 기본값(약간의 여백)을 두면 트랙이 위아래 끝까지 안 닿아 보인다 — 채팅방 스크롤바처럼
  // 끝까지 꽉 차게 그린다.
  mainAxisMargin: 0,
  crossAxisMargin: 0,
  thumbVisibility: const WidgetStatePropertyAll(true),
  trackVisibility: const WidgetStatePropertyAll(true),
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
);

/// 위 테마를 직접 [Scrollbar]로 그려서 붙이는 버전 — 검색 결과/멤버 목록 등 긴 목록에서 쓴다.
/// [controller]는 생략할 수 있다(안드로이드 미니보기의 각 탭처럼 그 화면에 스크롤 가능한
/// 목록이 하나뿐이면, Scrollbar가 별도 컨트롤러 없이도 그 목록에 알아서 붙는다).
class MutedScrollbar extends StatelessWidget {
  final ScrollController? controller;
  final Widget child;
  const MutedScrollbar({super.key, this.controller, required this.child});

  @override
  Widget build(BuildContext context) {
    return ScrollbarTheme(
      data: mutedScrollbarThemeData,
      child: Scrollbar(
        controller: controller,
        thumbVisibility: true,
        trackVisibility: true,
        child: child,
      ),
    );
  }
}
