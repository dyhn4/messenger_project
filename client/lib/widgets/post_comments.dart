import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../services/edit_policy.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import 'app_toast.dart';
import 'avatar_utils.dart';
import 'compact_menu.dart';
import '../l10n/tr.dart';

/// 공지·할 일 상세가 같이 쓰는 단순 댓글(의견만 남기는 댓글 — 고치고 지울 수는 있다) 조각 — `댓글 N` 제목, 댓글 한 줄
/// (⋯ 수정하기 · 삭제하기), 맨 아래 고정된 입력칸. 메시지 댓글(comment_input_bar.dart)과 달리 첨부·멘션이 없다.

/// 입력칸 왼쪽 😀 단추가 띄우는 빠른 이모지.
const _quickEmojis = [
  '😀',
  '😂',
  '😍',
  '😊',
  '😉',
  '😢',
  '😭',
  '😡',
  '👍',
  '👎',
  '👏',
  '🙏',
  '🎉',
  '❤️',
  '🔥',
  '✨',
  '💯',
  '👀',
  '🤔',
  '😅',
];

/// `댓글 N` — 개수가 있으면 강조색. [textKey]는 글자(Text) 자체에 붙는다(테스트가 글자를 읽는다).
class PostCommentCount extends StatelessWidget {
  final int count;
  final Key? textKey;
  const PostCommentCount(this.count, {super.key, this.textKey});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text.rich(
      key: textKey,
      TextSpan(
        children: [
          TextSpan(
            text: tr('댓글 '),
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          TextSpan(
            text: '$count',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: count > 0 ? theme.colorScheme.primary : theme.hintColor,
            ),
          ),
        ],
      ),
      style: const TextStyle(fontSize: 14),
    );
  }
}

/// 댓글 목록 — 받는 중이면 도는 표시, 없으면 `아직 댓글이 없습니다.`, 있으면 한 줄씩([PostCommentTile]).
/// [itemPadding]은 줄마다 둘레 여백(공지 카드 안과 할 일 상세의 여백이 다르다).
class PostCommentList<T> extends StatelessWidget {
  final List<T>? comments;
  final Widget Function(T comment) itemBuilder;
  final EdgeInsets itemPadding;
  final EdgeInsets emptyPadding;

  const PostCommentList({
    super.key,
    required this.comments,
    required this.itemBuilder,
    this.itemPadding = const EdgeInsets.fromLTRB(0, 8, 8, 10),
    this.emptyPadding = const EdgeInsets.fromLTRB(0, 8, 8, 14),
  });

  @override
  Widget build(BuildContext context) {
    final list = comments;
    if (list == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (list.isEmpty) {
      return Padding(
        padding: emptyPadding,
        child: Text(
          tr('아직 댓글이 없습니다.'),
          style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final c in list)
          Padding(padding: itemPadding, child: itemBuilder(c)),
      ],
    );
  }
}

/// 공지·할 일 댓글을 지금 사용자가 고치거나 지울 수 있는지 — 서버(moderation.js의 isSimpleComment)와 같은 규칙: 팀에서
/// 메시지 수정/삭제를 꺼 두면 아무도 못 하고, 수정은 작성자만, 삭제는 작성자와 관리자(그 방을 관리할 수 있는 사람·팀
/// 관리자). 시간 제한은 없다. 최종 판단은 서버가 한다(여기서 통과해도 403이면 토스트).
({bool edit, bool delete}) simpleCommentPermissions(
  Session session,
  Room? room,
  String? authorId,
) {
  if (!isEditDeleteAllowed(session)) return (edit: false, delete: false);
  final mine = authorId != null && authorId == session.userId;
  final manager =
      (room?.canManage(session) ?? false) || session.canModerateContent;
  return (edit: mine, delete: mine || manager);
}

enum _CommentAction { edit, delete }

/// 댓글 한 줄 — 아바타, 이름, `yyyy/MM/dd AM h:mm`(고쳤으면 `(수정됨)`), 본문. [avatarUser]는 그 방 멤버에서 찾은 작성자
/// (나갔으면 null — 이름 첫 글자로 그린다).
///
/// [onEdit]·[onDelete]가 있으면 이름 줄 오른쪽에 ⋯(수정하기 · 삭제하기)를 둔다. 수정하기는 본문 자리에서 바로 고치고
/// (취소 · 저장), 삭제하기는 한 번 묻고 지운다. 둘 다 실패하면 던지면 된다 — 토스트로 알리고 고치던 글은 그대로 둔다.
/// 메뉴와 삭제 확인은 창 전체(루트 Navigator)에 [menuRouteSettings]를 붙여 띄운다(할 일 패널이 지워질 때 같이 닫으려고).
class PostCommentTile extends StatefulWidget {
  final String commentId;
  final AppUser? avatarUser;
  final String authorName;
  final DateTime createdAt;
  final DateTime? editedAt;
  final String text;
  final String Function(String) resolveUrl;
  final Future<void> Function(String text)? onEdit;
  final Future<void> Function()? onDelete;
  final RouteSettings? menuRouteSettings;

  const PostCommentTile({
    super.key,
    required this.commentId,
    required this.avatarUser,
    required this.authorName,
    required this.createdAt,
    this.editedAt,
    required this.text,
    required this.resolveUrl,
    this.onEdit,
    this.onDelete,
    this.menuRouteSettings,
  });

  @override
  State<PostCommentTile> createState() => _PostCommentTileState();
}

class _PostCommentTileState extends State<PostCommentTile> {
  /// 고치는 중이면 그 입력칸(아니면 null).
  TextEditingController? _editing;
  bool _busy = false;

  @override
  void dispose() {
    _editing?.dispose();
    super.dispose();
  }

  void _startEdit() {
    setState(() {
      _editing?.dispose();
      _editing = TextEditingController(text: widget.text)
        ..selection = TextSelection.collapsed(offset: widget.text.length);
    });
    // 맨 아래 댓글이면 취소·저장 단추가 화면 밖에 걸린다 — 다 보이게 끌어 올린다. 애니메이션 없이 바로 옮긴다(입력칸이
    // 포커스를 받으며 커서를 보이게 하는 스크롤이 애니메이션을 끊어 중간에 멈춘다).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  void _cancelEdit() {
    setState(() {
      _editing?.dispose();
      _editing = null;
    });
  }

  Future<void> _saveEdit() async {
    final controller = _editing;
    final onEdit = widget.onEdit;
    if (controller == null || onEdit == null || _busy) return;
    final text = controller.text.trim();
    if (text.isEmpty) {
      showAppToast(context, tr('댓글 내용을 입력하세요.'));
      return;
    }
    if (text == widget.text) return _cancelEdit();
    setState(() => _busy = true);
    try {
      await onEdit(text);
      if (mounted) _cancelEdit();
    } catch (e) {
      if (mounted) showAppToast(context, tr('댓글을 수정하지 못했습니다: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final onDelete = widget.onDelete;
    if (onDelete == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      routeSettings: widget.menuRouteSettings,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('댓글 삭제')),
        content: Text(tr('이 댓글을 삭제할까요? 되돌릴 수 없습니다.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('취소')),
          ),
          TextButton(
            key: const ValueKey('post-comment-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('삭제'), style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await onDelete();
    } catch (e) {
      if (mounted) showAppToast(context, tr('댓글을 삭제하지 못했습니다: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final user = widget.avatarUser;
    final editing = _editing;
    final time = formatPostDateTime(widget.createdAt);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AvatarView(
          username: widget.authorName,
          avatarType: user?.avatarType ?? 'initial',
          avatarEmoji: user?.avatarEmoji,
          avatarColor: user?.avatarColor,
          avatarUrl: user?.avatarUrl,
          resolveUrl: widget.resolveUrl,
          radius: 16,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.authorName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          widget.editedAt != null
                              ? tr('{time} (수정됨)', {'time': time})
                              : time,
                          style: TextStyle(fontSize: 12, color: hint),
                        ),
                      ],
                    ),
                  ),
                  if (editing == null) _moreButton(context),
                ],
              ),
              const SizedBox(height: 6),
              if (editing == null)
                Text(
                  widget.text,
                  style: const TextStyle(fontSize: 14, height: 1.5),
                )
              else
                _editor(context, editing),
            ],
          ),
        ),
      ],
    );
  }

  /// ⋯ — 할 수 있는 게 없으면 그리지 않는다.
  Widget _moreButton(BuildContext context) {
    final canEdit = widget.onEdit != null;
    final canDelete = widget.onDelete != null;
    if (!canEdit && !canDelete) return const SizedBox.shrink();
    return PopupMenuButton<_CommentAction>(
      key: ValueKey('post-comment-more-${widget.commentId}'),
      tooltip: tr('더보기'),
      enabled: !_busy,
      padding: EdgeInsets.zero,
      iconSize: 18,
      icon: Icon(
        Icons.more_horiz,
        size: 18,
        color: Theme.of(context).hintColor,
      ),
      style: IconButton.styleFrom(
        fixedSize: const Size.square(28),
        minimumSize: const Size.square(28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      useRootNavigator: true,
      routeSettings: widget.menuRouteSettings,
      position: PopupMenuPosition.under,
      color: CompactMenu.color(context),
      shape: CompactMenu.shape,
      menuPadding: CompactMenu.menuPadding,
      constraints: CompactMenu.constraints,
      onSelected: (action) => switch (action) {
        _CommentAction.edit => _startEdit(),
        _CommentAction.delete => _delete(),
      },
      itemBuilder: (context) => [
        if (canEdit)
          CompactMenu.item(
            context,
            icon: Icons.edit_outlined,
            label: tr('수정하기'),
            value: _CommentAction.edit,
          ),
        if (canEdit && canDelete) CompactMenu.divider,
        if (canDelete)
          CompactMenu.item(
            context,
            icon: Icons.delete_outline,
            label: tr('삭제하기'),
            color: Colors.redAccent,
            value: _CommentAction.delete,
          ),
      ],
    );
  }

  /// 본문 자리에서 고치기 — 입력칸과 취소 · 저장.
  Widget _editor(BuildContext context, TextEditingController controller) {
    final theme = Theme.of(context);
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: theme.dividerColor),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('post-comment-edit-input'),
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: 6,
          enabled: !_busy,
          style: const TextStyle(fontSize: 14, height: 1.5),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            border: outline,
            enabledBorder: outline,
            focusedBorder: outline.copyWith(
              borderSide: BorderSide(
                color: theme.colorScheme.primary,
                width: 1.5,
              ),
            ),
          ),
          onSubmitted: (_) => _saveEdit(),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              key: const ValueKey('post-comment-edit-cancel'),
              onPressed: _busy ? null : _cancelEdit,
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: Text(tr('취소')),
            ),
            const SizedBox(width: 4),
            FilledButton(
              key: const ValueKey('post-comment-edit-save'),
              onPressed: _busy ? null : _saveEdit,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              child: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(tr('저장')),
            ),
          ],
        ),
      ],
    );
  }
}

/// 맨 아래 고정된 댓글 입력칸 — 둥근 테두리, "댓글을 입력하세요....", 왼쪽 😀(빠른 이모지), 오른쪽 보내기(보내는 중이면
/// 도는 표시). Enter로도 보낸다.
class PostCommentInput extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSubmit;
  final Key? inputKey;
  final Key? sendKey;

  const PostCommentInput({
    super.key,
    required this.controller,
    required this.sending,
    required this.onSubmit,
    this.inputKey,
    this.sendKey,
  });

  void _insertEmoji(String emoji) {
    final sel = controller.selection;
    final text = controller.text;
    if (!sel.isValid) {
      controller.text = text + emoji;
      return;
    }
    final newText = text.replaceRange(sel.start, sel.end, emoji);
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: sel.start + emoji.length),
    );
  }

  void _showEmojiPicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final emoji in _quickEmojis)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    _insertEmoji(emoji);
                    Navigator.of(sheetContext).pop();
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(emoji, style: const TextStyle(fontSize: 26)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: theme.dividerColor),
    );
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: TextField(
            key: inputKey,
            controller: controller,
            minLines: 1,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: tr('댓글을 입력하세요....'),
              hintStyle: TextStyle(color: theme.hintColor),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              border: outline,
              enabledBorder: outline,
              focusedBorder: outline.copyWith(
                borderSide: BorderSide(
                  color: theme.colorScheme.primary,
                  width: 1.5,
                ),
              ),
              prefixIcon: IconButton(
                icon: const Icon(Icons.emoji_emotions_outlined, size: 20),
                onPressed: () => _showEmojiPicker(context),
                tooltip: tr('이모티콘'),
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 44),
              suffixIcon: sending
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      key: sendKey,
                      icon: Icon(
                        Icons.send_rounded,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                      tooltip: tr('댓글 등록'),
                      onPressed: onSubmit,
                    ),
              suffixIconConstraints: const BoxConstraints(minWidth: 44),
            ),
            onSubmitted: (_) => onSubmit(),
          ),
        ),
      ),
    );
  }
}
