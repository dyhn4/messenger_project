import 'package:flutter/material.dart';

import 'compact_menu.dart';

/// 툴바 한 줄의 높이(버튼 지름 + 위아래 테두리) — 마지막 메시지 아래에 툴바가 뜰 자리를
/// 미리 비워둘 때 쓴다(chat_panel.dart, message_thread_screen.dart 참고).
const kHoverToolbarHeight = HoverToolbarButton.dimension + 2;

/// 말풍선/댓글 줄 호버 시 뜨는 흰 상자 툴바(잔디 스타일). MessageBubble과 댓글 카드의
/// _CommentEntryLine이 공유해서 쓴다.
class HoverToolbar extends StatelessWidget {
  final List<Widget> children;
  const HoverToolbar({super.key, required this.children});

  /// 버튼 [buttonCount]개짜리 툴바가 차지하는 가로 폭 — 호버하기 전에도 같은 크기의 빈
  /// 자리를 미리 비워둬서, 툴바가 나타날 때 옆의 말풍선 폭이 안 바뀌게 할 때 쓴다.
  static double widthFor(int buttonCount) =>
      buttonCount * HoverToolbarButton.dimension + 6; // 좌우 패딩 2+2 + 테두리 1+1.

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

/// 호버 툴바를 말풍선 "아래에 떠 있게" 보여주기 위한 앵커. 이 위젯 자체는 크기가 0이라
/// 레이아웃에 전혀 영향을 주지 않고(=아래 메시지들이 안 밀림), 툴바는 Overlay에 그려져서
/// 아래쪽 내용 위에 팝업처럼 겹쳐 뜬다. 말풍선 바로 아래(왼쪽 정렬)에 두고 쓴다.
///
/// 구현 주의사항 두 가지 — 예전에 이 "겹쳐 뜨는 툴바"를 시도했다가 실패했던 원인들이다.
///  * 위치를 `CompositedTransformFollower`로 잡으면 안 된다. 그러면 툴바 안쪽이 전부
///    `RenderFollowerLayer` 아래에 놓이는데, 그 레이어는 페인트 시점에야 변환이 정해져서
///    "레이아웃 중에 좌표를 알아야 하는" 자식이 있으면 터진다. 툴바 버튼들의 `Tooltip`이
///    바로 그런 자식이라(내부적으로 OverlayPortal을 씀), 버튼에 마우스를 올리는 순간
///    'The paint transform cannot be reliably computed because of RenderFollowerLayer(s)'
///    + 'debugNeedsLayout' 단언으로 화면이 빨개졌다. 대신 SDK가 권하는
///    [OverlayPortal.overlayChildLayoutBuilder]로 앵커의 좌표를 레이아웃 중에 직접 받아
///    평범한 [Positioned]로 놓는다 — FollowerLayer 자체가 없어진다.
///  * [OverlayPortalController]의 show/hide는 "위젯 트리를 다시 빌드하는 중에는 호출하지
///    말라"고 SDK 주석에 적혀 있다. 그래서 이 위젯은 visible 같은 prop을 받지 않고, 부모가
///    호버 콜백(=빌드 밖)에서 컨트롤러로 직접 여닫도록 [controller]를 받는다.
class FloatingHoverToolbar extends StatelessWidget {
  final OverlayPortalController controller;

  /// 실제 툴바 내용. 툴바 위로 마우스가 올라가도 계속 보이게 하려면(=부모의 호버 상태를
  /// 유지하려면) 이 안에서 MouseRegion으로 감싸서 부모에 알려야 한다.
  final WidgetBuilder toolbarBuilder;

  /// 앵커(말풍선 왼쪽 아래) 기준으로 툴바를 얼마나 옮겨 그릴지.
  final Offset offset;

  const FloatingHoverToolbar({
    super.key,
    required this.controller,
    required this.toolbarBuilder,
    this.offset = const Offset(0, 2),
  });

  @override
  Widget build(BuildContext context) {
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: controller,
      overlayChildBuilder: (context, info) {
        // 0크기 앵커의 좌상단을 Overlay 좌표로 옮긴 값 = 말풍선 왼쪽 아래.
        final origin = MatrixUtils.transformPoint(
          info.childPaintTransform,
          Offset.zero,
        );
        return Positioned(
          left: origin.dx + offset.dx,
          top: origin.dy + offset.dy,
          child: toolbarBuilder(context),
        );
      },
      child: const SizedBox.shrink(),
    );
  }
}

/// 툴바 "더보기" 메뉴의 항목 한 줄 — 채팅 목록 우클릭 메뉴([CompactMenu])와 같은 모양(작은
/// 글씨, 좁은 줄 간격, 작고 흐린 아이콘)이다. 메시지·댓글·이미지 썸네일의 더보기 메뉴가 모두
/// 이걸 써서 같아진다. 메뉴 자체의 모양(흰 바탕·둥근 모서리·최소 폭)은 [hoverMenuStyle].
Widget hoverMenuItem({
  required IconData icon,
  required String label,
  required VoidCallback onPressed,
  Color? color,
}) => MenuItemButton(
  leadingIcon: Builder(
    builder: (context) =>
        Icon(icon, size: 16, color: color ?? Theme.of(context).hintColor),
  ),
  onPressed: onPressed,
  style: const ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(0, CompactMenu.itemHeight)),
    padding: WidgetStatePropertyAll(CompactMenu.itemPadding),
    textStyle: WidgetStatePropertyAll(CompactMenu.textStyle),
  ),
  child: Text(
    label,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: color == null ? null : TextStyle(color: color),
  ),
);

/// 더보기 메뉴의 구분선(예: 공용 항목과 수정/삭제 사이) — 우클릭 메뉴의 구분선과 같은 높이.
Widget hoverMenuDivider() => const Divider(height: 9);

/// 더보기 메뉴(MenuAnchor)의 바탕·모서리·여백·최소 폭을 우클릭 메뉴([CompactMenu])와 맞춘다.
MenuStyle hoverMenuStyle(BuildContext context) => MenuStyle(
  backgroundColor: WidgetStatePropertyAll(CompactMenu.color(context)),
  shape: WidgetStatePropertyAll(CompactMenu.shape as OutlinedBorder),
  padding: const WidgetStatePropertyAll(CompactMenu.menuPadding),
  minimumSize: WidgetStatePropertyAll(
    Size(CompactMenu.constraints.minWidth, 0),
  ),
);

/// HoverToolbar 안에 들어가는 아이콘 버튼 하나. [menuChildren]을 주면 눌렀을 때 메뉴가 뜨고
/// ([hoverMenuItem]으로 만든 항목들), 안 주면 [onPressed]를 그대로 호출하는 일반 버튼이 된다.
/// [visible]이 false면(예: 내 메시지가 아니라서 더보기가 의미 없을 때) 버튼은 숨기되 같은
/// 크기의 빈 자리는 그대로 남겨서, 내 것과 상대방 것의 툴바가 항상 같은 크기로 보이게 한다.
class HoverToolbarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;

  /// 아이콘 색 — 켜진 상태를 보여줄 때만 준다(예: 즐겨찾기한 파일의 노란 별).
  final Color? color;
  final VoidCallback? onPressed;
  final List<Widget>? menuChildren;
  final bool visible;

  /// 진행 중이면 아이콘 대신 작은 진행 표시를 그리고 누를 수 없게 한다(예: 다운로드 중).
  final bool busy;

  /// 메뉴가 열리고 닫힐 때 알려준다 — 메뉴가 떠 있는 동안에는 툴바를 계속 보여줘야 해서
  /// (마우스가 메뉴로 넘어가면 툴바에서 벗어난 것으로 잡히기 때문에) 부모가 이걸로 붙잡아 둔다.
  final ValueChanged<bool>? onMenuOpenChanged;

  const HoverToolbarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.color,
    this.onPressed,
    this.menuChildren,
    this.visible = true,
    this.busy = false,
    this.onMenuOpenChanged,
  });

  static const dimension = 30.0;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox(width: dimension, height: dimension);

    // 버튼 크기는 SizedBox로 직접 강제한다 — 안 그러면 Material 기본 최소 탭 영역(48x48)으로
    // 커져서 툴바 전체 높이도 예상보다 커진다.
    final iconWidget = busy
        ? const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(icon, size: 18, color: color);
    final items = menuChildren;
    final button = items != null
        // 팝업메뉴(PopupMenuButton) 대신 MenuAnchor를 쓴다 — 여는 애니메이션이 없어 바로
        // 뜨고, 항목 모양도 이미지 썸네일의 더보기 메뉴와 같아진다.
        ? MenuAnchor(
            style: hoverMenuStyle(context),
            menuChildren: items,
            onOpen: () => onMenuOpenChanged?.call(true),
            onClose: () => onMenuOpenChanged?.call(false),
            builder: (context, controller, _) => IconButton(
              icon: iconWidget,
              tooltip: tooltip,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
            ),
          )
        : IconButton(
            icon: iconWidget,
            tooltip: tooltip,
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            onPressed: busy ? null : onPressed,
          );
    return SizedBox(width: dimension, height: dimension, child: button);
  }
}
