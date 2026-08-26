import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/app_user.dart';
import '../models/comment.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../services/session.dart';
import 'attachment_widgets.dart';
import 'avatar_utils.dart';
import 'hover_toolbar.dart';

final _timeFormat = DateFormat('a h:mm');
final _dateTimeFormat = DateFormat('yyyy/MM/dd a h:mm');

/// 원본 메시지에 달린, 끊기지 않고 연달아 온 댓글 한 묶음(run)을 채팅 타임라인에 그려 넣는 항목
/// (chat_panel.dart가 MessageType.comment 항목 중 "런의 첫 댓글"에서만 하나씩 그린다 — 같은
/// 런의 나머지 댓글은 이 카드 안의 목록에 흡수되어 별도 항목으로는 안 그려진다. 런은 "이 원본
/// 메시지에 대한 댓글이 사이에 다른 채팅 없이 연달아 온 구간"이라, 채팅방 마지막 항목이 이 카드인
/// 동안 계속 댓글을 주고받으면 새 댓글이 그때마다 이 카드 안에 이어 붙고(런 확장), 중간에 일반
/// 채팅이 한 번 끼면 그다음 댓글부터는 새 카드가 새로 시작된다 — chat_panel.dart의
/// isFirstCommentInRun 판정 참고).
/// 왼쪽엔 작은 댓글 아이콘, 가운데엔 원본 메시지를 인용한 카드(+ "N개 댓글 모두 보기"), 그 아래
/// 이 런에 속한 댓글들이 발신자별 배경색(내 댓글=파랑, 상대=회색 — MessageBubble과 같은 색 규칙)
/// 줄로 하나씩 이어 붙는다. 시간은 MessageBubble처럼 그 색상 말풍선 오른쪽 바깥(일반 텍스트, 배경
/// 없음)에 둔다. "N개 댓글"의 N은 [parentMessage].comments.length(그 원본 메시지에 달린 전체
/// 댓글 수, 이 런에 있는 것만이 아니라)를 그대로 쓴다.
class MessageCommentsCard extends StatelessWidget {
  final Session session;
  final Message parentMessage;
  final List<Comment> comments;
  final Room room;
  final String? currentUserId;
  final String Function(String relative) resolveUrl;
  final VoidCallback onTap;
  final Future<void> Function(String commentId, String text)? onEditComment;
  final Future<void> Function(String commentId)? onDeleteComment;

  const MessageCommentsCard({
    super.key,
    required this.session,
    required this.parentMessage,
    required this.comments,
    required this.room,
    required this.currentUserId,
    required this.resolveUrl,
    required this.onTap,
    this.onEditComment,
    this.onDeleteComment,
  });

  AppUser? _memberOf(String? userId) {
    for (final m in room.members) {
      if (m.id == userId) return m;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final originalSender = _memberOf(parentMessage.senderId);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.mode_comment_outlined,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              // Expanded 하나만 쓰면 카드가 항상 남는 폭을 전부 채워서, 창을 넓게 하면 카드도
              // 한없이 넓어진다. LayoutBuilder로 실제 남는 폭을 재서 min(700, 남는 폭)만큼만
              // SizedBox로 못박아 두면, 좁을 땐 기존처럼 꽉 채우고 넓을 땐 700px에서 멈춘다.
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth > 700
                        ? 700.0
                        : constraints.maxWidth;
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: width,
                        child: _buildCard(context, originalSender),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCard(BuildContext context, AppUser? originalSender) {
    return Material(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  AvatarView(
                    username: originalSender?.name ?? parentMessage.senderName,
                    avatarType: originalSender?.avatarType ?? 'initial',
                    avatarEmoji: originalSender?.avatarEmoji,
                    avatarColor: originalSender?.avatarColor,
                    avatarUrl: originalSender?.avatarUrl,
                    resolveUrl: resolveUrl,
                    radius: 12,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    originalSender?.name ?? parentMessage.senderName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _timeFormat.format(parentMessage.createdAt),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ),
              if (parentMessage.deleted)
                Text(
                  '삭제된 메시지입니다',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: Theme.of(context).hintColor,
                  ),
                )
              else if (parentMessage.type == MessageType.text &&
                  (parentMessage.text?.isNotEmpty ?? false)) ...[
                const SizedBox(height: 4),
                Text(
                  parentMessage.text!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${parentMessage.comments.length}개 댓글 모두 보기',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.arrow_forward,
                    size: 12,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ),
              // 이 런에 속한 댓글들 — 카드 테두리(Material) 밖으로 나가지 않고 이 안에서 계속
              // 이어 붙어야 "새 채팅이 온 것"이 아니라 "이 카드 안에 댓글이 쌓이는 것"으로 보인다.
              // 채팅과 동일하게, 같은 사람이 연달아 단 댓글은 첫 댓글에만 프로필 사진을 보여준다.
              for (var i = 0; i < comments.length; i++)
                CommentEntryLine(
                  session: session,
                  comment: comments[i],
                  sender: _memberOf(comments[i].senderId),
                  isMine:
                      currentUserId != null &&
                      comments[i].senderId == currentUserId,
                  resolveUrl: resolveUrl,
                  onEdit: onEditComment,
                  onDelete: onDeleteComment,
                  showAvatar:
                      i == 0 ||
                      comments[i - 1].senderId != comments[i].senderId,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 댓글 하나를 나타내는 줄. 두 군데서 같이 쓴다:
/// - 채팅 카드 안(fullWidth: false, 기본값): 말풍선이 내용 길이만큼만 차지(Flexible)하고, 시간은
///   그 옆(오른쪽 바깥)에 일반 텍스트로 붙는다. 호버 시 뜨는 더보기 툴바도 그 옆 남는 공간에 들어간다.
/// - 댓글 스레드 패널(message_thread_screen.dart, fullWidth: true): 말풍선이 패널 가로폭을
///   가득 채우고(Expanded), 이름 아래에 전체 날짜+시간을 보여준다. 이 경우엔 말풍선이 이미 폭을
///   다 쓰므로, 호버 툴바 자리를 오른쪽에 고정 너비로 항상 비워둬서(호버 여부와 무관하게 폭이
///   안 바뀌게) 나타날 때 말풍선이 밀리지 않게 한다.
/// 발신자가 나면 파란(primaryContainer), 남이면 회색(surfaceContainerHighest) 배경으로
/// MessageBubble과 같은 색 규칙을 써서 누구 댓글인지 한눈에 구분되게 한다. 내 댓글 위에 마우스를
/// 올리면(호버) MessageBubble과 같은 흰 상자 툴바(더보기 → 수정/삭제)가 뜬다.
class CommentEntryLine extends StatefulWidget {
  final Session session;
  final Comment comment;
  final AppUser? sender;
  final bool isMine;
  final String Function(String relative) resolveUrl;
  final Future<void> Function(String commentId, String text)? onEdit;
  final Future<void> Function(String commentId)? onDelete;
  final bool fullWidth;

  /// 같은 사람이 연달아 단 댓글 중 첫 댓글이 아니면 false — 채팅에서 연속 발신자의 아바타/이름을
  /// 첫 메시지에만 보여주는 것과 동일한 규칙(호출부에서 이전 댓글의 senderId와 비교해서 넘긴다).
  /// 아바타와 이름을 같이 가린다(시간은 그대로 보여준다 — 채팅도 시간은 매 메시지마다 보여줌).
  final bool showAvatar;

  const CommentEntryLine({
    super.key,
    required this.session,
    required this.comment,
    required this.sender,
    required this.isMine,
    required this.resolveUrl,
    this.onEdit,
    this.onDelete,
    this.fullWidth = false,
    this.showAvatar = true,
  });

  @override
  State<CommentEntryLine> createState() => _CommentEntryLineState();
}

class _CommentEntryLineState extends State<CommentEntryLine> {
  static const _toolbarSlotWidth = 40.0;

  bool _hovering = false;
  bool _editing = false;
  bool _savingEdit = false;
  final _editController = TextEditingController();

  @override
  void dispose() {
    _editController.dispose();
    super.dispose();
  }

  void _startEdit() {
    setState(() {
      _editing = true;
      _editController.text = widget.comment.text ?? '';
    });
  }

  void _cancelEdit() => setState(() => _editing = false);

  Future<void> _saveEdit() async {
    final text = _editController.text.trim();
    if (text.isEmpty) return;
    setState(() => _savingEdit = true);
    try {
      await widget.onEdit!(widget.comment.id, text);
      if (mounted) setState(() => _editing = false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('수정 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _savingEdit = false);
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('댓글 삭제'),
        content: const Text('이 댓글을 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('삭제', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await widget.onDelete!(widget.comment.id);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('삭제 실패: $e')));
    }
  }

  Widget _buildBubbleContent(BuildContext context) {
    final comment = widget.comment;
    final sender = widget.sender;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 채팅과 동일하게, 같은 사람이 연달아 단 댓글은 첫 댓글에만 이름(과 아바타)을 보여준다.
        if (widget.showAvatar)
          Text(
            sender?.name ?? comment.senderName,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
        if (widget.fullWidth)
          Text(
            _dateTimeFormat.format(comment.createdAt),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).hintColor,
            ),
          ),
        if (comment.deleted)
          Text(
            '삭제된 댓글입니다',
            style: TextStyle(
              fontStyle: FontStyle.italic,
              color: Theme.of(context).hintColor,
            ),
          )
        else if (_editing)
          _buildEditor(context)
        else ...[
          // 첨부(이미지/파일)에 캡션이 같이 달려 있으면 그 위에 먼저 보여준다(MessageBubble과 동일).
          if (comment.type != MessageType.text &&
              (comment.text?.isNotEmpty ?? false)) ...[
            Text(comment.text!, style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
          ],
          if (comment.type == MessageType.text)
            Text(comment.text ?? '', style: const TextStyle(fontSize: 13))
          else
            _buildAttachment(context),
          if (comment.editedAt != null)
            Text(
              '(수정됨)',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
        ],
      ],
    );
  }

  /// 이미지/파일 댓글의 첨부 내용. MessageBubble의 이미지/파일 렌더링과 같은 위젯을 재사용한다.
  Widget _buildAttachment(BuildContext context) {
    final comment = widget.comment;
    switch (comment.type) {
      case MessageType.image:
        return DownloadableImage(
          session: widget.session,
          url: widget.resolveUrl(comment.fileUrl ?? ''),
          fileName: comment.fileName ?? 'image.png',
        );
      case MessageType.file:
        return DownloadableFile(
          session: widget.session,
          url: widget.resolveUrl(comment.fileUrl ?? ''),
          fileName: comment.fileName ?? '파일',
        );
      case MessageType.text:
      case MessageType.system:
      case MessageType.comment:
        return const SizedBox.shrink();
    }
  }

  Widget _buildToolbar(BuildContext context) {
    return HoverToolbar(
      children: [
        HoverToolbarButton(
          icon: Icons.more_vert,
          tooltip: '더보기',
          menuItems: [
            // 메시지 수정과 동일하게, 텍스트 댓글만 수정할 수 있다(서버도 동일하게 막음).
            if (widget.comment.type == MessageType.text &&
                widget.onEdit != null)
              PopupMenuItem<void>(
                onTap: _startEdit,
                child: const Row(
                  children: [Icon(Icons.edit), SizedBox(width: 8), Text('수정')],
                ),
              ),
            if (widget.onDelete != null)
              PopupMenuItem<void>(
                onTap: () => _confirmDelete(context),
                child: const Row(
                  children: [
                    Icon(Icons.delete, color: Colors.redAccent),
                    SizedBox(width: 8),
                    Text('삭제', style: TextStyle(color: Colors.redAccent)),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final comment = widget.comment;
    final sender = widget.sender;
    final showToolbar =
        widget.isMine &&
        !comment.deleted &&
        !_editing &&
        (widget.onEdit != null || widget.onDelete != null);

    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: widget.isMine
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: _buildBubbleContent(context),
    );

    // 같은 사람이 연달아 단 댓글은 첫 댓글에만 아바타를 보여준다(showAvatar: false면 같은
    // 지름의 빈 자리만 남겨서 말풍선 들여쓰기는 그대로 유지).
    final avatarRadius = widget.fullWidth ? 16.0 : 12.0;
    final avatar = widget.showAvatar
        ? AvatarView(
            username: sender?.name ?? comment.senderName,
            avatarType: sender?.avatarType ?? 'initial',
            avatarEmoji: sender?.avatarEmoji,
            avatarColor: sender?.avatarColor,
            avatarUrl: sender?.avatarUrl,
            resolveUrl: widget.resolveUrl,
            radius: avatarRadius,
          )
        : SizedBox(width: avatarRadius * 2, height: avatarRadius * 2);

    final Widget row;
    if (widget.fullWidth) {
      // 말풍선이 이미 Expanded로 폭을 다 쓰므로, 호버 툴바 자리를 항상 고정폭으로 비워둬야
      // (호버 여부와 무관하게) 나타날 때 말풍선 폭이 안 바뀌어서 글자가 안 움직인다.
      row = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          avatar,
          const SizedBox(width: 8),
          Expanded(child: bubble),
          const SizedBox(width: 4),
          SizedBox(
            width: _toolbarSlotWidth,
            child: (_hovering && showToolbar) ? _buildToolbar(context) : null,
          ),
        ],
      );
    } else {
      row = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          avatar,
          const SizedBox(width: 6),
          // Expanded(꽉 채움) 대신 Flexible(내용만큼만)을 써서, 말풍선이 카드 가로폭을 전부
          // 채우지 않고 내용 길이만큼만 차지하게 한다.
          Flexible(child: bubble),
          const SizedBox(width: 6),
          Text(
            _timeFormat.format(comment.createdAt),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).hintColor,
            ),
          ),
          const SizedBox(width: 6),
          // fullWidth와 동일하게, 호버 여부와 무관하게 툴바 자리를 항상 고정폭으로 비워둔다 —
          // Flexible만으로는 말풍선 내용이 길어서 이미 가용 폭을 거의 다 쓰고 있을 때 툴바가
          // 뜨면서 그만큼 다시 밀릴 수 있는데, 자리를 아예 고정해두면 그 경우에도 안 밀린다.
          SizedBox(
            width: _toolbarSlotWidth,
            child: (_hovering && showToolbar) ? _buildToolbar(context) : null,
          ),
        ],
      );
    }

    return Padding(
      padding: EdgeInsets.only(top: widget.fullWidth ? 10 : 6),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: row,
      ),
    );
  }

  Widget _buildEditor(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _editController,
          autofocus: true,
          maxLines: null,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _saveEdit(),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _savingEdit ? null : _cancelEdit,
              child: const Text('취소'),
            ),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: _savingEdit ? null : _saveEdit,
              child: _savingEdit
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('저장'),
            ),
          ],
        ),
      ],
    );
  }
}
