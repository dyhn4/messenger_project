import 'package:flutter/material.dart';

import 'compact_menu.dart';
import 'hover_toolbar.dart' show hoverMenuDivider, hoverMenuStyle;

/// [CompactMenuAnchor] 메뉴의 한 줄 — 값 하나([CompactMenuOption]) 또는 구분선([CompactMenuDivider]).
sealed class CompactMenuEntry<T> {
  const CompactMenuEntry();
}

/// 고를 수 있는 값 하나 — 글자와 (있으면) 왼쪽의 작고 흐린 아이콘. 지금 값이면 오른쪽에 체크가 붙는다.
class CompactMenuOption<T> extends CompactMenuEntry<T> {
  final T value;
  final String label;
  final IconData? icon;

  /// 항목 키(테스트가 항목을 찾는 데 쓴다).
  final Key? key;
  const CompactMenuOption({
    required this.value,
    required this.label,
    this.icon,
    this.key,
  });
}

/// 항목 묶음 사이 구분선(우클릭 메뉴의 구분선과 같은 높이).
class CompactMenuDivider<T> extends CompactMenuEntry<T> {
  const CompactMenuDivider();
}

/// 값 하나를 고르는 작은 드롭다운 — 메시지 예약 패널의 정렬 메뉴와 같은 MenuAnchor 메뉴(설정·더보기 메뉴 모양
/// [hoverMenuStyle], 32 높이 13px 항목, 지금 값에 체크). 팝업 라우트가 아니라 여는 애니메이션 없이 바로 뜨고, 바깥을
/// 누르면 닫힌다. 메뉴는 가장 가까운 Overlay에 뜬다(PC 할 일 패널 안 화면이면 패널 안).
///
/// [builder]가 그리는 단추는 각자 모양 그대로 두고, 받은 `toggle`로 메뉴를 열고 닫는다(`open`이면 열려 있다).
class CompactMenuAnchor<T> extends StatelessWidget {
  final List<CompactMenuEntry<T>> entries;

  /// 체크를 붙일 지금 값.
  final T? selected;
  final ValueChanged<T> onSelected;
  final Widget Function(BuildContext context, bool open, VoidCallback toggle)
  builder;

  /// 항목 최소 폭. 메뉴 자체 최소 폭은 [menuMinWidth](없으면 설정 메뉴와 같은 180).
  final double itemMinWidth;
  final double? menuMinWidth;

  /// 메뉴 최대 폭 — 넘는 글자는 말줄임(긴 팀 이름 등).
  final double? maxWidth;

  /// 단추와 메뉴 사이 간격(아래쪽으로).
  final double gap;

  /// true면 메뉴 오른쪽 끝을 단추 오른쪽 끝에 맞춰 왼쪽으로 편다(줄 오른쪽 끝 단추 — 정렬 등). 아니면 왼쪽 끝에 맞춰
  /// 오른쪽으로. 어느 쪽이든 자리가 모자라면 Overlay 안으로 밀려 들어온다.
  final bool alignEnd;

  /// true면 바깥을 눌러 닫을 때 그 누름이 아래(채팅 등)로 가지 않는다.
  final bool consumeOutsideTap;
  final MenuController? controller;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;

  const CompactMenuAnchor({
    super.key,
    required this.entries,
    required this.selected,
    required this.onSelected,
    required this.builder,
    this.itemMinWidth = 140,
    this.menuMinWidth,
    this.maxWidth,
    this.gap = 4,
    this.alignEnd = false,
    this.consumeOutsideTap = false,
    this.controller,
    this.onOpen,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    // 메뉴 자리 잡기는 "단추의 시작 쪽 끝에 메뉴 시작 쪽을 맞춘다" — 끝 쪽에 맞추려면 방향을 뒤집어 자리를 잡고, 안의
    // 내용(단추·항목)은 원래 방향으로 그린다.
    final flipped = alignEnd
        ? (direction == TextDirection.ltr
              ? TextDirection.rtl
              : TextDirection.ltr)
        : direction;
    Widget keep(Widget child) => alignEnd
        ? Directionality(textDirection: direction, child: child)
        : child;

    var style = hoverMenuStyle(context);
    if (menuMinWidth != null || maxWidth != null) {
      style = style.copyWith(
        minimumSize: menuMinWidth == null
            ? null
            : WidgetStatePropertyAll(Size(menuMinWidth!, 0)),
        maximumSize: maxWidth == null
            ? null
            : WidgetStatePropertyAll(Size(maxWidth!, double.infinity)),
      );
    }
    final hint = Theme.of(context).hintColor;
    // 휴대폰에서도 PC와 같은 32 높이(터치 영역을 48로 키우지 않는다 — 예전 팝업 메뉴 항목과 같다).
    final itemStyle = ButtonStyle(
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      minimumSize: WidgetStatePropertyAll(
        Size(itemMinWidth, CompactMenu.itemHeight),
      ),
      padding: const WidgetStatePropertyAll(CompactMenu.itemPadding),
      textStyle: const WidgetStatePropertyAll(CompactMenu.textStyle),
    );
    return Directionality(
      textDirection: flipped,
      child: MenuAnchor(
        controller: controller,
        style: style,
        alignmentOffset: Offset(0, gap),
        consumeOutsideTap: consumeOutsideTap,
        // 최대 폭을 정했으면 메뉴가 그 폭 안에 들어오게(긴 글자는 말줄임) — 기본(true)은 내용 폭대로 그리고 넘치면 잘라 낸다.
        crossAxisUnconstrained: maxWidth == null,
        onOpen: onOpen,
        onClose: onClose,
        menuChildren: [
          for (final e in entries)
            switch (e) {
              CompactMenuDivider<T>() => keep(hoverMenuDivider()),
              CompactMenuOption<T>() => keep(
                MenuItemButton(
                  key: e.key,
                  onPressed: () => onSelected(e.value),
                  style: itemStyle,
                  leadingIcon: e.icon == null
                      ? null
                      : Icon(e.icon, size: 16, color: hint),
                  trailingIcon: e.value == selected
                      ? const Icon(Icons.check, size: 16)
                      : const SizedBox(width: 16),
                  child: Text(
                    e.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            },
        ],
        builder: (_, controller, _) => keep(
          Builder(
            builder: (context) => builder(
              context,
              controller.isOpen,
              () => controller.isOpen ? controller.close() : controller.open(),
            ),
          ),
        ),
      ),
    );
  }
}
