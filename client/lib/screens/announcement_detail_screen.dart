import 'dart:async';

import 'package:flutter/material.dart';

import '../models/announcement.dart';
import '../models/app_user.dart';
import '../models/room.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/announcement_image.dart';
import '../widgets/app_toast.dart';
import '../widgets/avatar_utils.dart';
import 'home_screen.dart' show wideBreakpoint;

/// 공지 "상세보기" — 공지 목록에서 항목을 누르면 연다. 작성자 프로필/이름/시간 + 전체 내용 +
/// 댓글 목록 + 댓글 입력칸을 보여주고, 작성 본인이면 오른쪽 위 삼점 버튼으로 현재 채팅방에
/// 공유하기/공지 내리기/수정하기/삭제하기를 할 수 있다(session.canManageAnnouncement).
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
        child: SizedBox(
          width: 480,
          height: 640,
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
        body: SafeArea(
          child: AnnouncementDetailScreen(
            session: session,
            room: room,
            announcement: announcement,
          ),
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

  bool get _canManage => widget.session.canManageAnnouncement(_announcement);

  @override
  void initState() {
    super.initState();
    _announcement = widget.announcement;
    _load();
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
  }

  @override
  void dispose() {
    _commentSub?.cancel();
    _updatedSub?.cancel();
    _commentController.dispose();
    super.dispose();
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

  AppUser? _authorUser() {
    for (final m in widget.room.members) {
      if (m.id == _announcement.authorId) return m;
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

  Future<void> _edit() async {
    final textController = TextEditingController(text: _announcement.text);
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('공지 수정'),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: textController,
            autofocus: true,
            maxLines: 6,
            minLines: 3,
            maxLength: 2000,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(textController.text.trim()),
            child: const Text('완료'),
          ),
        ],
      ),
    );
    // 사진 공지는 글 없이 사진만 둘 수 있다(서버도 같은 규칙).
    if (text == null || (text.isEmpty && !_announcement.hasImage) || !mounted) {
      return;
    }
    try {
      final updated = await widget.session.api!.updateAnnouncement(
        widget.room.id,
        _announcement.id,
        text,
      );
      if (mounted) {
        setState(() {
          _announcement.text = updated.text;
          _announcement.editedAt = updated.editedAt;
        });
      }
    } catch (e) {
      if (mounted) showAppToast(context, '수정하지 못했습니다: $e');
    }
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
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showAppToast(context, '삭제하지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        const Divider(height: 1),
        Expanded(child: _buildBody(context)),
        const Divider(height: 1),
        _buildCommentInput(context),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Text(
              '상세보기',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('글목록'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final comments = _comments;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildPost(
          context,
          avatarUser: _authorUser(),
          authorName: _announcement.authorName,
          time: _announcement.createdAt,
          edited: _announcement.editedAt != null,
          text: _announcement.text,
          extra: _announcement.hasImage
              ? AnnouncementImage(
                  session: widget.session,
                  announcement: _announcement,
                  maxHeight: 280,
                  maxWidth: 400,
                )
              : null,
          trailing: _canManage
              ? PopupMenuButton<void>(
                  icon: const Icon(Icons.more_vert),
                  itemBuilder: (menuContext) => [
                    PopupMenuItem<void>(
                      onTap: _shareToRoom,
                      child: const Row(
                        children: [
                          Icon(Icons.forward_outlined),
                          SizedBox(width: 8),
                          Text('현재 채팅방에 공유하기'),
                        ],
                      ),
                    ),
                    PopupMenuItem<void>(
                      onTap: _unpin,
                      child: const Row(
                        children: [
                          Icon(Icons.push_pin_outlined),
                          SizedBox(width: 8),
                          Text('공지 내리기'),
                        ],
                      ),
                    ),
                    PopupMenuItem<void>(
                      onTap: _edit,
                      child: const Row(
                        children: [
                          Icon(Icons.edit_outlined),
                          SizedBox(width: 8),
                          Text('수정하기'),
                        ],
                      ),
                    ),
                    PopupMenuItem<void>(
                      onTap: _delete,
                      child: const Row(
                        children: [
                          Icon(Icons.delete_outline, color: Colors.redAccent),
                          SizedBox(width: 8),
                          Text(
                            '삭제하기',
                            style: TextStyle(color: Colors.redAccent),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              : null,
        ),
        const SizedBox(height: 8),
        if (comments == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          const Divider(height: 24),
          for (final c in comments) ...[
            _buildPost(
              context,
              avatarUser: _memberOf(c.authorId),
              authorName: c.authorName,
              time: c.createdAt,
              edited: false,
              text: c.text,
              trailing: null,
            ),
            const SizedBox(height: 16),
          ],
        ],
      ],
    );
  }

  AppUser? _memberOf(String? userId) {
    for (final m in widget.room.members) {
      if (m.id == userId) return m;
    }
    return null;
  }

  Widget _buildPost(
    BuildContext context, {
    required AppUser? avatarUser,
    required String authorName,
    required DateTime time,
    required bool edited,
    required String text,
    required Widget? trailing,
    // 글 아래에 붙일 것(사진 공지의 사진).
    Widget? extra,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AvatarView(
          username: authorName,
          avatarType: avatarUser?.avatarType ?? 'initial',
          avatarEmoji: avatarUser?.avatarEmoji,
          avatarColor: avatarUser?.avatarColor,
          avatarUrl: avatarUser?.avatarUrl,
          resolveUrl: widget.session.resolveUrl,
          radius: 18,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      authorName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  ?trailing,
                ],
              ),
              Text(
                edited
                    ? '${formatRelativeTime(time)} · 수정됨'
                    : formatRelativeTime(time),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).hintColor,
                ),
              ),
              const SizedBox(height: 6),
              if (text.isNotEmpty) Text(text),
              if (extra != null) ...[
                if (text.isNotEmpty) const SizedBox(height: 8),
                extra,
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCommentInput(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.emoji_emotions_outlined),
              onPressed: _showEmojiPicker,
              tooltip: '이모티콘',
            ),
            Expanded(
              child: TextField(
                controller: _commentController,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: '댓글을 남겨보세요.',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
                onSubmitted: (_) => _postComment(),
              ),
            ),
            const SizedBox(width: 8),
            _sending
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : TextButton(onPressed: _postComment, child: const Text('등록')),
          ],
        ),
      ),
    );
  }
}
