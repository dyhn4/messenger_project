import 'package:flutter/material.dart';

/// 채팅 목록 우클릭 메뉴(desktop_home_screen.dart의 _showContextMenu)와 같은 모양의 간결한
/// 팝업 메뉴 — 작은 글씨, 좁은 줄 간격, 항목 묶음 사이 구분선. 사이드바 "토픽 추가"(+)와
/// 우측 상단 "설정"(삼선) 메뉴도 이 모양을 쓴다.
class CompactMenu {
  CompactMenu._();

  static const double itemHeight = 32;
  static const EdgeInsets itemPadding = EdgeInsets.symmetric(horizontal: 16);
  static const TextStyle textStyle = TextStyle(fontSize: 13);
  static const EdgeInsets menuPadding = EdgeInsets.symmetric(vertical: 6);
  static const BoxConstraints constraints = BoxConstraints(
    minWidth: 180,
    maxWidth: 280,
  );
  static final ShapeBorder shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(8),
  );
  static const PopupMenuDivider divider = PopupMenuDivider(height: 9);

  /// 밝은 테마는 흰 바탕, 어두운 테마는 앱 공통 팝업 색(main.dart popupMenuTheme).
  static Color? color(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light ? Colors.white : null;

  /// 아이콘(선택) + 글자 한 줄 항목. 아이콘은 우클릭 메뉴의 "폴더로 이동" 하위 메뉴처럼
  /// 작고 흐리게 그린다.
  static PopupMenuItem<T> item<T>(
    BuildContext context, {
    required String label,
    IconData? icon,
    VoidCallback? onTap,
    T? value,
    Color? color,
  }) => PopupMenuItem<T>(
    value: value,
    onTap: onTap,
    height: itemHeight,
    padding: itemPadding,
    child: Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: color ?? Theme.of(context).hintColor),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: color == null ? textStyle : textStyle.copyWith(color: color),
          ),
        ),
      ],
    ),
  );
}
