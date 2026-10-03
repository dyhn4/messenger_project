import 'package:flutter/material.dart';

/// 파일 삭제(업로드한 본인·팀 관리자)로 지워진 첨부 자리에 그리는 흐린 카드 — "삭제된 파일입니다".
/// 메시지와 그 댓글은 그대로 남고 파일만 사라진 것이라, 말풍선은 이 카드로 그 자리를 보여 준다
/// (사진·파일·여러 장 묶음 모두). [compact]면 사진 격자의 한 칸처럼 글자 없이 아이콘과 짧은 문구만 둔다.
class DeletedFileCard extends StatelessWidget {
  /// 지워진 파일의 이름(서버가 남겨 준다). 있으면 작게 곁들인다.
  final String? fileName;

  /// 사진이었는지 — 아이콘만 다르다.
  final bool isImage;
  final double? width;
  final double? height;

  /// 격자 칸 안(좁은 칸)에서 쓰는 모양.
  final bool compact;

  const DeletedFileCard({
    super.key,
    this.fileName,
    this.isImage = false,
    this.width,
    this.height,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final icon = Icon(
      isImage ? Icons.hide_image_outlined : Icons.insert_drive_file_outlined,
      size: compact ? 22 : 24,
      color: hint.withValues(alpha: 0.7),
    );
    final label = Text(
      '삭제된 파일입니다',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: hint,
        fontStyle: FontStyle.italic,
      ),
    );
    final name = (fileName ?? '').isEmpty
        ? null
        : Text(
            fileName!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: hint.withValues(alpha: 0.7),
              decoration: TextDecoration.lineThrough,
            ),
          );
    return Opacity(
      opacity: 0.75,
      child: Container(
        key: const ValueKey('deleted-file-card'),
        width: width,
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.6,
          ),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: hint.withValues(alpha: 0.25)),
        ),
        child: compact
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [icon, const SizedBox(height: 4), label],
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  icon,
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [label, ?name],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
