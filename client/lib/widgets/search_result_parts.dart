import 'package:flutter/material.dart';

/// 검색 패널과 내가 쓴 글 패널이 같이 쓰는 조각 — 종류 탭, 팀 이름 칩, 게시글·댓글 표시, 검색어 형광펜.

/// 종류 탭 하나 — 고른 탭은 굵은 글씨 + 밑줄. [menuBuilder]를 주면 글자 오른쪽에 꺽쇠가 붙고,
/// 꺽쇠를 누르면 그 메뉴가 열린다(글자를 누르면 탭만 고른다).
class PanelTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget Function(Widget chevron)? menuBuilder;
  const PanelTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.menuBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected ? theme.colorScheme.onSurface : theme.hintColor;
    final text = InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.only(
          left: 6,
          right: menuBuilder == null ? 6 : 0,
          top: 10,
          bottom: 10,
        ),
        child: Text(
          label,
          // 줄 높이·기준선을 글꼴과 상관없이 고정한다 — "할 일"처럼 띄어쓰기가 든 글자는 띄어쓰기만 기본 글꼴(한글은
          // 대체 글꼴)로 그려져 줄 기준선이 내려가, 옆 탭보다 글자가 살짝 아래로 처졌다.
          strutStyle: const StrutStyle(
            fontSize: 14,
            height: 1.35,
            forceStrutHeight: true,
          ),
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: color,
          ),
        ),
      ),
    );
    final builder = menuBuilder;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            width: 2,
            color: selected ? theme.colorScheme.onSurface : Colors.transparent,
          ),
        ),
      ),
      child: builder == null
          ? text
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                text,
                builder(
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 10, 8, 10),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 18,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// 모든 팀에서 찾은 결과가 어느 팀 것인지 알려 주는 작은 칩.
class TeamNameChip extends StatelessWidget {
  final String name;
  const TeamNameChip({super.key, required this.name});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// 결과 줄 내용 앞의 작은 종류 표시(`게시글`·`댓글`) — 옅은 강조색 바탕에 강조색 글씨.
class ResultKindBadge extends StatelessWidget {
  final String label;
  const ResultKindBadge(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: primary,
        ),
      ),
    );
  }
}

/// [text] 안의 [query]를 형광펜으로 칠한 것처럼 보여준다(대소문자 무시).
Widget highlightedText(
  BuildContext context,
  String text,
  String query, {
  int? maxLines,
  TextStyle? style,
}) {
  final overflow = maxLines == null ? null : TextOverflow.ellipsis;
  if (query.isEmpty) {
    return Text(text, maxLines: maxLines, overflow: overflow, style: style);
  }
  final lowerText = text.toLowerCase();
  final lowerQuery = query.toLowerCase();
  final spans = <TextSpan>[];
  var start = 0;
  while (true) {
    final idx = lowerText.indexOf(lowerQuery, start);
    if (idx < 0) {
      spans.add(TextSpan(text: text.substring(start)));
      break;
    }
    if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
    spans.add(
      TextSpan(
        text: text.substring(idx, idx + query.length),
        style: const TextStyle(
          backgroundColor: Color(0xFFFFF59D),
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    start = idx + query.length;
  }
  return RichText(
    maxLines: maxLines,
    overflow: overflow ?? TextOverflow.clip,
    text: TextSpan(
      style: DefaultTextStyle.of(context).style.merge(style),
      children: spans,
    ),
  );
}
