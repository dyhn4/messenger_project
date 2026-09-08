import 'package:flutter/material.dart';

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

  static const dimension = 30.0;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox(width: dimension, height: dimension);

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
    return SizedBox(width: dimension, height: dimension, child: button);
  }
}
