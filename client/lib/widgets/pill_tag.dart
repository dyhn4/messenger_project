import 'package:flutter/material.dart';

/// 보드 뷰 "고정된 게시글"의 "고정" 표시(board_view.dart의 PinnedPostTag)와 같은 강조색 — 밝은 테마는 진한
/// 주황, 어두운 테마는 밝은 주황(board_view.dart BoardColors.pin과 같은 값).
Color pillTagAccent(ThemeData theme) => theme.brightness == Brightness.dark
    ? const Color(0xFFFFB74D)
    : const Color(0xFFE8590C);

/// 작은 알약 모양 표시 — 아이콘 하나 + 짧은 글(11px 굵게), 같은 색을 10%로 깐 둥근 바탕. 보드 뷰의 "고정"
/// 표시와 같은 모양이고, 토픽 채팅 위 공지바의 "공지" 표시(announcement_banner.dart)가 쓴다.
class PillTag extends StatelessWidget {
  final IconData icon;
  final String label;

  /// 없으면 [pillTagAccent](보드 뷰 "고정"과 같은 주황).
  final Color? color;
  final String? tooltip;

  const PillTag({
    super.key,
    required this.icon,
    required this.label,
    this.color,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? pillTagAccent(Theme.of(context));
    final pill = Container(
      padding: const EdgeInsets.fromLTRB(5, 1, 7, 1),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: c),
          const SizedBox(width: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: c,
            ),
          ),
        ],
      ),
    );
    final message = tooltip;
    return message == null ? pill : Tooltip(message: message, child: pill);
  }
}
