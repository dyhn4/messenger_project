import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../models/announcement.dart';
import '../models/app_user.dart';
import '../models/room.dart';
import '../services/chat_socket.dart' show AnnouncementRemovedEvent;
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/announcement_image.dart';
import '../widgets/app_toast.dart';
import '../widgets/avatar_utils.dart';
import '../widgets/board_view.dart'
    show BoardColors, PinnedPostTag, boardCardDecoration;
import 'announcement_editor_dialog.dart';
import 'home_screen.dart' show wideBreakpoint;

/// 공지 "상세보기" — 배너·공지 목록·알림 센터에서 연다. 잔디의 게시글 상세처럼 카드 하나에 작성자 아바타·이름·
/// `2026/10/01 AM 3:44`, 오른쪽 위 ⋯(작성자만: 수정하기·공지 내리기·삭제하기 …), 본문, 사진(있으면), 구분선,
/// `댓글 N`과 댓글 목록을 담고, 맨 아래에 고정된 댓글 입력칸이 있다. PC는 대화상자, 모바일은 전체 화면이다.
Future<void> showAnnouncementDetailScreen(
  BuildContext context,
  Session session,
  Room room,
  Announcement announcement,
) {
  final isWide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  if (isWide) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 520,
          height: 680,
          child: AnnouncementDetailScreen(
            session: session,
            room: room,
            announcement: announcement,
          ),
        ),
      ),
    );
  }
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('공지')),
        body: AnnouncementDetailScreen(
          session: session,
          room: room,
          announcement: announcement,
        ),
      ),
    ),
  );
}

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

enum _MoreAction { share, edit, unpin, delete }

class AnnouncementDetailScreen extends StatefulWidget {
  final Session session;
  final Room room;
  final Announcement announcement;
  const AnnouncementDetailScreen({
    super.key,
    required this.session,
    required this.room,
    required this.announcement,
  });

  @override
  State<AnnouncementDetailScreen> createState() =>
      _AnnouncementDetailScreenState();
}

class _AnnouncementDetailScreenState extends State<AnnouncementDetailScreen> {
  late Announcement _announcement;
  List<AnnouncementComment>? _comments;
  String? _error;
  final _commentController = TextEditingController();
  bool _sending = false;

  StreamSubscription<AnnouncementComment>? _commentSub;
  StreamSubscription<Announcement>? _updatedSub;
  StreamSubscription<AnnouncementRemovedEvent>? _unpinnedSub;
  StreamSubscription<AnnouncementRemovedEvent>? _deletedSub;

  bool get _canManage => widget.session.canManageAnnouncement(_announcement);

  @override
  void initState() {
    super.initState();
    _announcement = widget.announcement;
    _load();
    // 상세를 실제로 열었다는 뜻 — 알림 센터의 "안 읽은 공지" 표시를 지운다(배너에서 바로 열 때도 같다).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.session.markAnnouncementsRead(widget.room);
    });
    _commentSub = widget.session.chatSocket.announcementComments.listen((c) {
      if (c.announcementId != _announcement.id || !mounted) return;
      setState(() {
        final comments = _comments;
        if (comments == null || comments.any((e) => e.id == c.id)) return;
        _comments = [...comments, c];
        _announcement.commentCount += 1;
      });
    });
    _updatedSub = widget.session.chatSocket.announcementUpdated.listen((a) {
      if (a.id != _announcement.id || !mounted) return;
      setState(() {
        _announcement.text = a.text;
        _announcement.editedAt = a.editedAt;
      });
    });
    _unpinnedSub = widget.session.chatSocket.announcementUnpinned.listen((e) {
      if (e.id != _announcement.id || !mounted) return;
      setState(() => _announcement.pinned = false);
    });
    // 보고 있는 공지가 (작성자의 다른 기기 등에서) 지워지면 닫는다.
    _deletedSub = widget.session.chatSocket.announcementDeleted.listen((e) {
      if (e.id != _announcement.id || !mounted) return;
      _close();
    });
  }

  @override
  void dispose() {
    _commentSub?.cancel();
    _updatedSub?.cancel();
    _unpinnedSub?.cancel();
    _deletedSub?.cancel();
    _commentController.dispose();
    super.dispose();
  }

  bool _closed = false;

  /// 상세를 닫는다 — 삭제 응답과 소켓 알림이 둘 다 오니 한 번만(두 번 닫으면 뒤 화면까지 닫힌다).
  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  Future<void> _load() async {
    try {
      final comments = await widget.session.api!.fetchAnnouncementComments(
        widget.room.id,
        _announcement.id,
      );
      if (mounted) setState(() => _comments = comments);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _postComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _commentController.clear();
    try {
      final created = await widget.session.api!.postAnnouncementComment(
        widget.room.id,
        _announcement.id,
        text,
      );
      if (!mounted) return;
      setState(() {
        final comments = _comments ?? [];
        if (comments.any((e) => e.id == created.id)) return;
        _comments = [...comments, created];
        _announcement.commentCount += 1;
      });
    } catch (e) {
      if (mounted) showAppToast(context, '댓글을 등록하지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _insertEmoji(String emoji) {
    final sel = _commentController.selection;
    final text = _commentController.text;
    if (!sel.isValid) {
      _commentController.text = text + emoji;
      return;
    }
    final newText = text.replaceRange(sel.start, sel.end, emoji);
    _commentController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: sel.start + emoji.length),
    );
  }

  void _showEmojiPicker() {
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

  AppUser? _memberOf(String? userId) {
    if (userId == null) return null;
    for (final m in widget.room.members) {
      if (m.id == userId) return m;
    }
    return null;
  }

  Future<void> _shareToRoom() async {
    try {
      await widget.session.chatSocket.send(
        roomId: widget.room.id,
        type: 'text',
        quotedSenderName: _announcement.authorName,
        quotedPreview: _announcement.previewText,
      );
      if (mounted) showAppToast(context, '현재 채팅방에 공유했습니다.');
    } catch (e) {
      if (mounted) showAppToast(context, '공유하지 못했습니다: $e');
    }
  }

  Future<void> _unpin() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('공지 내리기'),
        content: const Text('이 공지를 채팅방 상단에서 내릴까요? 목록에는 그대로 남습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('내리기'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.session.api!.unpinAnnouncement(
        widget.room.id,
        _announcement.id,
      );
      if (mounted) setState(() => _announcement.pinned = false);
    } catch (e) {
      if (mounted) showAppToast(context, '공지를 내리지 못했습니다: $e');
    }
  }

  /// 수정 — 공지 쓰기와 같은 틀의 창(announcement_editor_dialog.dart)에서 글을 고친다.
  Future<void> _edit() async {
    await showAnnouncementEditor(
      context,
      session: widget.session,
      room: widget.room,
      announcement: _announcement,
      onSubmit: (draft) async {
        final updated = await widget.session.api!.updateAnnouncement(
          widget.room.id,
          _announcement.id,
          draft.text,
        );
        if (mounted) {
          setState(() {
            _announcement.text = updated.text;
            _announcement.editedAt = updated.editedAt;
          });
        }
      },
    );
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('공지 삭제'),
        content: const Text('이 공지를 삭제할까요? 댓글도 함께 삭제되며 되돌릴 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('삭제', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.session.api!.deleteAnnouncement(
        widget.room.id,
        _announcement.id,
      );
      if (mounted) _close();
    } catch (e) {
      if (mounted) showAppToast(context, '삭제하지 못했습니다: $e');
    }
  }

  void _onMore(_MoreAction action) {
    switch (action) {
      case _MoreAction.share:
        _shareToRoom();
      case _MoreAction.edit:
        _edit();
      case _MoreAction.unpin:
        _unpin();
      case _MoreAction.delete:
        _delete();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 좁은 화면은 showAnnouncementDetailScreen이 이미 Scaffold+AppBar를 씌워서 push하므로 그대로 쓰고,
    // 넓은 화면(Dialog)에서는 헤더+닫기 버튼을 직접 그린다.
    final isWide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
    final colors = BoardColors.of(Theme.of(context));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isWide) _buildDialogHeader(context),
        Expanded(
          child: ColoredBox(
            color: colors.background,
            child: _buildBody(context, colors),
          ),
        ),
        _buildCommentInput(context),
      ],
    );
  }

  Widget _buildDialogHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text('공지', style: Theme.of(context).textTheme.titleLarge),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: '닫기',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, BoardColors colors) {
    if (_error != null) return Center(child: Text(_error!));
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final comments = _comments;
    final count = comments?.length ?? _announcement.commentCount;
    final hasText = _announcement.text.trim().isNotEmpty;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        DecoratedBox(
          key: const ValueKey('announcement-detail-card'),
          decoration: boardCardDecoration(colors),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildAuthorRow(
                  context,
                  avatarUser: _memberOf(_announcement.authorId),
                  authorName: _announcement.authorName,
                  time: _announcement.createdAt,
                  edited: _announcement.editedAt != null,
                  avatarRadius: 20,
                  trailing: [
                    if (_announcement.pinned) ...[
                      const PinnedPostTag(),
                      const SizedBox(width: 2),
                    ],
                    if (_canManage) _buildMoreMenu(),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (hasText) ...[
                        const SizedBox(height: 14),
                        // Windows(마우스)에서는 끌어서 바로 고를 수 있게(게시글 상세와 같은 규칙).
                        Platform.isWindows
                            ? SelectableText(
                                _announcement.text,
                                key: const ValueKey('announcement-detail-text'),
                                style: const TextStyle(
                                  fontSize: 15,
                                  height: 1.6,
                                ),
                              )
                            : Text(
                                _announcement.text,
                                key: const ValueKey('announcement-detail-text'),
                                style: const TextStyle(
                                  fontSize: 15,
                                  height: 1.6,
                                ),
                              ),
                      ],
                      if (_announcement.hasImage) ...[
                        const SizedBox(height: 14),
                        _buildImageCard(context),
                      ],
                      const SizedBox(height: 14),
                    ],
                  ),
                ),
                Divider(height: 1, color: colors.border),
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 12, 8, 4),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        const TextSpan(
                          text: '댓글 ',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(
                          text: '$count',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: count > 0 ? theme.colorScheme.primary : hint,
                          ),
                        ),
                      ],
                    ),
                    key: const ValueKey('announcement-comment-count'),
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                if (comments == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (comments.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 8, 8, 14),
                    child: Text(
                      '아직 댓글이 없습니다.',
                      style: TextStyle(fontSize: 13, color: hint),
                    ),
                  )
                else
                  for (final c in comments)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 8, 8, 10),
                      child: _buildComment(context, c),
                    ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMoreMenu() {
    return PopupMenuButton<_MoreAction>(
      key: const ValueKey('announcement-detail-more'),
      icon: const Icon(Icons.more_horiz),
      tooltip: '더보기',
      padding: EdgeInsets.zero,
      onSelected: _onMore,
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: _MoreAction.edit,
          child: Row(
            children: [
              Icon(Icons.edit_outlined),
              SizedBox(width: 8),
              Text('수정하기'),
            ],
          ),
        ),
        if (_announcement.pinned)
          const PopupMenuItem(
            value: _MoreAction.unpin,
            child: Row(
              children: [
                Icon(Icons.push_pin_outlined),
                SizedBox(width: 8),
                Text('공지 내리기'),
              ],
            ),
          ),
        const PopupMenuItem(
          value: _MoreAction.share,
          child: Row(
            children: [
              Icon(Icons.forward_outlined),
              SizedBox(width: 8),
              Text('현재 채팅방에 공유하기'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: _MoreAction.delete,
          child: Row(
            children: [
              Icon(Icons.delete_outline, color: Colors.redAccent),
              SizedBox(width: 8),
              Text('삭제하기', style: TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
      ],
    );
  }

  /// 사진 공지의 사진 — 잔디의 첨부 카드처럼 옅은 바탕의 둥근 카드 안에(누르면 기존 이미지 뷰어).
  Widget _buildImageCard(BuildContext context) {
    final theme = Theme.of(context);
    final name = _announcement.imageName;
    return Container(
      key: const ValueKey('announcement-detail-image-card'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnnouncementImage(
            session: widget.session,
            announcement: _announcement,
            maxHeight: 280,
            maxWidth: 400,
          ),
          if (name != null && name.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
          ],
        ],
      ),
    );
  }

  /// 작성자 줄 — 아바타 + 이름 + `yyyy/MM/dd AM h:mm`(수정됨), 오른쪽에 [trailing](고정 표시·⋯).
  Widget _buildAuthorRow(
    BuildContext context, {
    required AppUser? avatarUser,
    required String authorName,
    required DateTime time,
    required bool edited,
    required double avatarRadius,
    List<Widget> trailing = const [],
  }) {
    final hint = Theme.of(context).hintColor;
    return Row(
      children: [
        AvatarView(
          username: authorName,
          avatarType: avatarUser?.avatarType ?? 'initial',
          avatarEmoji: avatarUser?.avatarEmoji,
          avatarColor: avatarUser?.avatarColor,
          avatarUrl: avatarUser?.avatarUrl,
          resolveUrl: widget.session.resolveUrl,
          radius: avatarRadius,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                authorName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              Text(
                edited
                    ? '${formatPostDateTime(time)} (수정됨)'
                    : formatPostDateTime(time),
                style: TextStyle(fontSize: 12, color: hint),
              ),
            ],
          ),
        ),
        ...trailing,
      ],
    );
  }

  Widget _buildComment(BuildContext context, AnnouncementComment c) {
    final hint = Theme.of(context).hintColor;
    final user = _memberOf(c.authorId);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AvatarView(
          username: c.authorName,
          avatarType: user?.avatarType ?? 'initial',
          avatarEmoji: user?.avatarEmoji,
          avatarColor: user?.avatarColor,
          avatarUrl: user?.avatarUrl,
          resolveUrl: widget.session.resolveUrl,
          radius: 16,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                c.authorName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              Text(
                formatPostDateTime(c.createdAt),
                style: TextStyle(fontSize: 12, color: hint),
              ),
              const SizedBox(height: 6),
              Text(c.text, style: const TextStyle(fontSize: 14, height: 1.5)),
            ],
          ),
        ),
      ],
    );
  }

  /// 맨 아래 고정된 댓글 입력칸 — 둥근 테두리, "댓글을 입력하세요....".
  Widget _buildCommentInput(BuildContext context) {
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
            key: const ValueKey('announcement-comment-input'),
            controller: _commentController,
            minLines: 1,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: '댓글을 입력하세요....',
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
                onPressed: _showEmojiPicker,
                tooltip: '이모티콘',
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 44),
              suffixIcon: _sending
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      key: const ValueKey('announcement-comment-send'),
                      icon: Icon(
                        Icons.send_rounded,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                      tooltip: '댓글 등록',
                      onPressed: _postComment,
                    ),
              suffixIconConstraints: const BoxConstraints(minWidth: 44),
            ),
            onSubmitted: (_) => _postComment(),
          ),
        ),
      ),
    );
  }
}
