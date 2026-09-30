import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/message.dart';
import '../services/session.dart';

/// 사진·파일 메시지 "수정" 모드의 첨부 목록 — 잔디처럼 잘못 붙인 첨부를 **지우기만** 한다(더하지는 못 한다).
/// 첨부마다 오른쪽 위 X 버튼이 있고, 누르면 그 첨부가 "삭제 예정"(흐리게)으로 바뀐다 — 실제로 지워지는 건 [저장]을
/// 누른 뒤이고, 저장 전에는 같은 버튼(되돌리기)으로 취소할 수 있다. [removedIds]는 부모가 들고 있다.
class EditAttachmentStrip extends StatelessWidget {
  final Session session;
  final List<MessageAttachment> attachments;
  final Set<String> removedIds;
  final void Function(String attachmentId) onToggle;

  const EditAttachmentStrip({
    super.key,
    required this.session,
    required this.attachments,
    required this.removedIds,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final a in attachments)
          a.isImage
              ? _ImageTile(
                  session: session,
                  attachment: a,
                  removed: removedIds.contains(a.id),
                  onToggle: () => onToggle(a.id),
                )
              : _FileTile(
                  attachment: a,
                  removed: removedIds.contains(a.id),
                  onToggle: () => onToggle(a.id),
                ),
      ],
    );
  }
}

/// 첨부 오른쪽 위에 얹는 X(삭제)/되돌리기 버튼.
class _RemoveButton extends StatelessWidget {
  final Key buttonKey;
  final bool removed;
  final VoidCallback onPressed;
  const _RemoveButton({
    required this.buttonKey,
    required this.removed,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: removed ? '삭제 취소' : '첨부 삭제',
      child: Material(
        color: Colors.black.withValues(alpha: 0.65),
        shape: const CircleBorder(),
        child: InkWell(
          key: buttonKey,
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Icon(
              removed ? Icons.undo : Icons.close,
              size: 14,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _ImageTile extends StatelessWidget {
  final Session session;
  final MessageAttachment attachment;
  final bool removed;
  final VoidCallback onToggle;
  const _ImageTile({
    required this.session,
    required this.attachment,
    required this.removed,
    required this.onToggle,
  });

  static const double size = 80;

  @override
  Widget build(BuildContext context) {
    final url = session.resolveUrl(
      attachment.thumbnailUrl ?? attachment.fileUrl,
    );
    final placeholder = Container(
      width: size,
      height: size,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: const Icon(Icons.image_outlined),
    );
    return SizedBox(
      key: ValueKey('edit-attachment-${attachment.id}'),
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Opacity(
              opacity: removed ? 0.3 : 1,
              child: CachedNetworkImage(
                imageUrl: url,
                width: size,
                height: size,
                fit: BoxFit.cover,
                placeholder: (context, _) => placeholder,
                errorWidget: (context, _, error) => placeholder,
              ),
            ),
          ),
          if (removed)
            const Center(
              child: Text(
                '삭제 예정',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
          Positioned(
            top: 3,
            right: 3,
            child: _RemoveButton(
              buttonKey: ValueKey('remove-attachment-${attachment.id}'),
              removed: removed,
              onPressed: onToggle,
            ),
          ),
        ],
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  final MessageAttachment attachment;
  final bool removed;
  final VoidCallback onToggle;
  const _FileTile({
    required this.attachment,
    required this.removed,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: ValueKey('edit-attachment-${attachment.id}'),
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.insert_drive_file_outlined,
            size: 18,
            color: theme.hintColor,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              attachment.fileName ?? '파일',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                decoration: removed ? TextDecoration.lineThrough : null,
                color: removed ? theme.hintColor : null,
              ),
            ),
          ),
          const SizedBox(width: 6),
          _RemoveButton(
            buttonKey: ValueKey('remove-attachment-${attachment.id}'),
            removed: removed,
            onPressed: onToggle,
          ),
        ],
      ),
    );
  }
}
