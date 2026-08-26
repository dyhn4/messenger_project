import 'package:flutter/material.dart';

/// 말풍선/댓글 줄 호버 시 뜨는 흰 상자 툴바(잔디 스타일). MessageBubble과 댓글 카드의
/// _CommentEntryLine이 공유해서 쓴다.
class HoverToolbar extends StatelessWidget {
  final List<Widget> children;
  const HoverToolbar({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.3),
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// HoverToolbar 안에 들어가는 아이콘 버튼 하나. [menuItems]를 주면 눌렀을 때 팝업 메뉴가 뜨고,
/// 안 주면 [onPressed]를 그대로 호출하는 일반 버튼이 된다. [visible]이 false면(예: 내 메시지가
/// 아니라서 더보기가 의미 없을 때) 버튼은 숨기되 같은 크기의 빈 자리는 그대로 남겨서, 내 것과
/// 상대방 것의 툴바가 항상 같은 크기로 보이게 한다.
class HoverToolbarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final List<PopupMenuEntry<void>>? menuItems;
  final bool visible;
  const HoverToolbarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.menuItems,
    this.visible = true,
  });

  static const _dimension = 30.0;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox(width: _dimension, height: _dimension);

    // PopupMenuButton의 constraints는 버튼 자체가 아니라 펼쳐지는 메뉴의 크기라서, 버튼
    // 크기는 SizedBox로 직접 강제해야 한다 — 안 그러면 Material 기본 최소 탭 영역(48x48)으로
    // 커져서 옆의 IconButton(32x32)과 크기가 안 맞고 툴바 전체 높이도 예상보다 커진다.
    final button = menuItems != null
        ? PopupMenuButton<void>(
            icon: Icon(icon, size: 18),
            tooltip: tooltip,
            padding: EdgeInsets.zero,
            itemBuilder: (context) => menuItems!,
          )
        : IconButton(
            icon: Icon(icon, size: 18),
            tooltip: tooltip,
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            onPressed: onPressed,
          );
    return SizedBox(width: _dimension, height: _dimension, child: button);
  }
}
