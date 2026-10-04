import 'package:flutter/material.dart';

/// 패널 맨 위의 가로 전체 `+ 만들기` 단추 — 옅은 회색 바탕의 둥근 단추(투표 패널의 `+ 투표 만들기`, 북마크의
/// `+ 북마크 추가`, 앨범의 `+ 앨범 생성`). 할 일 패널의 `+ 할 일 생성`과 같은 모양이다.
class PanelCreateButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const PanelCreateButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return FilledButton.icon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: scheme.surfaceContainerHighest,
        foregroundColor: scheme.onSurface,
        minimumSize: const Size.fromHeight(44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: theme.textTheme.labelLarge?.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      icon: const Icon(Icons.add, size: 20),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}
