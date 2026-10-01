import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/announcement.dart';
import '../models/room.dart';
import '../services/chat_socket.dart' show AnnouncementRemovedEvent;
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/avatar_utils.dart';
import '../widgets/board_view.dart'
    show BoardColors, PinnedPostTag, boardCardDecoration;
import 'announcement_detail_screen.dart';
import 'announcement_editor_dialog.dart';
import 'home_screen.dart' show wideBreakpoint;

/// 토픽방 "공지" — 카카오톡과 같은 개념. 누구나 볼 수 있고(방 멤버라면), 토픽을 만들 수
/// 있는 사람만 새로 쓸 수 있다(session.canCreateAnnouncementIn). pinned인 글(방마다 최대
/// 1개)이 채팅방 상단 배너에 고정된다 — 새 글을 쓰면 자동으로 그 글로 바뀌고, "공지 내리기"로
/// 직접 내릴 수도 있다(announcement_detail_screen.dart).
///
/// [unreadCount]가 0보다 크면(알림 센터에서 안 읽은 공지 때문에 열었을 때) 목록 위쪽의(=가장
/// 최근의) 다른 사람이 쓴 공지 그만큼에 "안 읽음" 표시를 붙여서 어느 게 새 공지인지 알 수 있게 한다.
Future<void> showAnnouncementListScreen(
  BuildContext context,
  Session session,
  Room room, {
  int unreadCount = 0,
}) {
  final isWide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  if (isWide) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SizedBox(
          width: 480,
          height: 640,
          child: AnnouncementListScreen(
            session: session,
            room: room,
            unreadCount: unreadCount,
          ),
        ),
      ),
    );
  }
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('공지')),
        body: AnnouncementListScreen(
          session: session,
          room: room,
          unreadCount: unreadCount,
        ),
      ),
    ),
  );
}

class AnnouncementListScreen extends StatefulWidget {
  final Session session;
  final Room room;
  final int unreadCount;
  const AnnouncementListScreen({
    super.key,
    required this.session,
    required this.room,
    this.unreadCount = 0,
  });

  @override
  State<AnnouncementListScreen> createState() => _AnnouncementListScreenState();
}

class _AnnouncementListScreenState extends State<AnnouncementListScreen> {
  List<Announcement>? _items;
  String? _error;
  StreamSubscription<Announcement>? _newSub;
  StreamSubscription<Announcement>? _updatedSub;
  StreamSubscription<AnnouncementRemovedEvent>? _deletedSub;
  StreamSubscription<AnnouncementRemovedEvent>? _unpinnedSub;

  /// "안 읽음" 표시가 붙은 공지 id — 처음 목록이 그려질 때 한 번만 정하고, 상세를 열어본 공지는
  /// 여기서 빼서 표시를 지운다(build에서 매번 다시 계산하면 열어본 것도 다시 붙는다).
  Set<String>? _unreadIds;

  bool get _canWrite => widget.session.canCreateAnnouncementIn(widget.room);

  @override
  void initState() {
    super.initState();
    _load();
    // 이 목록을 실제로 열었다는 뜻 — 알림 센터의 "안 읽은 공지" 표시를 여기서 지운다
    // (session.dart의 markAnnouncementsRead 참고. 배너만 보고 안 열었으면 안읽음 그대로).
    widget.session.markAnnouncementsRead(widget.room);
    // 이 화면을 열어둔 채로 누군가 공지를 쓰거나/고치거나/내리거나/지우면, 새로고침 없이 그
    // 자리에서 바로 반영한다 — 채팅방 배너와 같은 실시간성.
    _newSub = widget.session.chatSocket.announcements.listen((a) {
      if (a.roomId != widget.room.id || !mounted) return;
      setState(() {
        final items = _items;
        if (items == null || items.any((e) => e.id == a.id)) return;
        _items = [a, ...items];
      });
    });
    _updatedSub = widget.session.chatSocket.announcementUpdated.listen((a) {
      if (a.roomId != widget.room.id || !mounted) return;
      setState(() {
        final items = _items;
        if (items == null) return;
        final i = items.indexWhere((e) => e.id == a.id);
        if (i == -1) return;
        items[i].text = a.text;
        items[i].editedAt = a.editedAt;
      });
    });
    _deletedSub = widget.session.chatSocket.announcementDeleted.listen((e) {
      if (e.roomId != widget.room.id || !mounted) return;
      setState(() {
        _items = _items?.where((a) => a.id != e.id).toList();
      });
    });
    _unpinnedSub = widget.session.chatSocket.announcementUnpinned.listen((e) {
      if (e.roomId != widget.room.id || !mounted) return;
      setState(() {
        final i = _items?.indexWhere((a) => a.id == e.id) ?? -1;
        if (i != -1) _items![i].pinned = false;
      });
    });
  }

  @override
  void dispose() {
    _newSub?.cancel();
    _updatedSub?.cancel();
    _deletedSub?.cancel();
    _unpinnedSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await widget.session.api!.fetchAnnouncements(
        widget.room.id,
      );
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 글쓰기 — 게시글 작성창과 같은 틀의 공지 쓰기 창(announcement_editor_dialog.dart). 등록 실패는 창 안에서
  /// 토스트로 알리고 쓰던 글을 남겨 둔다.
  Future<void> _write() async {
    await showAnnouncementEditor(
      context,
      session: widget.session,
      room: widget.room,
      onSubmit: (draft) async {
        final autoUnpinAfter = draft.autoUnpinAfter;
        final Announcement created;
        try {
          created = await widget.session.api!.createAnnouncement(
            widget.room.id,
            draft.text,
            autoUnpinAt: autoUnpinAfter == null
                ? null
                : DateTime.now().add(autoUnpinAfter),
          );
        } catch (e) {
          throw '공지를 등록하지 못했습니다: $e';
        }
        if (!mounted) return;
        // 소켓 echo(위 _newSub)와 중복되지 않도록 id로 한 번 더 확인한다.
        setState(() {
          final items = _items ?? [];
          if (items.any((e) => e.id == created.id)) return;
          _items = [created, ...items];
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = BoardColors.of(Theme.of(context));
    final content = ColoredBox(
      color: colors.background,
      child: _buildContent(context, colors),
    );
    // 좁은 화면은 showAnnouncementListScreen이 이미 Scaffold+AppBar를 씌워서 push하므로
    // 그대로 쓰고, 넓은 화면(Dialog)에서는 헤더+닫기 버튼을 직접 그린다.
    final isWide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
    if (!isWide) return content;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '공지',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: '닫기',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Expanded(child: content),
      ],
    );
  }

  Widget _buildContent(BuildContext context, BoardColors colors) {
    if (_error != null) return Center(child: Text(_error!));
    final items = _items;
    if (items == null) return const Center(child: CircularProgressIndicator());

    // 최신순 목록에서 내가 안 쓴 공지 앞에서부터 unreadCount개가 안 읽은 공지다(안 읽은 건
    // 항상 마지막으로 연 시각 이후 = 가장 최근 것들이기 때문).
    final unreadIds = _unreadIds ??= () {
      final ids = <String>{};
      for (final a in items) {
        if (ids.length >= widget.unreadCount) break;
        if (a.authorId != widget.session.userId) ids.add(a.id);
      }
      return ids;
    }();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 보드의 "고정된 게시글 N" 머리줄처럼 — 아이콘 + "공지 N", 오른쪽에 글쓰기(권한 있는 사람만).
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 16, 4),
          child: Row(
            children: [
              Icon(Icons.campaign_outlined, size: 18, color: colors.pin),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '공지 ${items.length}',
                  key: const ValueKey('announcement-list-header'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_canWrite)
                FilledButton.icon(
                  key: const ValueKey('announcement-write'),
                  onPressed: _write,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('글쓰기'),
                ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('등록된 공지가 없습니다.'))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => _AnnouncementTile(
                    key: ValueKey('announcement-tile-${items[i].id}'),
                    session: widget.session,
                    room: widget.room,
                    announcement: items[i],
                    unread: unreadIds.contains(items[i].id),
                    onTap: () async {
                      // 상세를 열어본 공지는 "안 읽음" 표시를 지운다.
                      setState(() => unreadIds.remove(items[i].id));
                      await showAnnouncementDetailScreen(
                        context,
                        widget.session,
                        widget.room,
                        items[i],
                      );
                      // 상세에서 고치거나 댓글을 달았다면(같은 객체를 고친다) 카드도 새로 그린다.
                      if (mounted) setState(() {});
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

/// 공지 목록의 카드 — 보드의 "고정된 게시글" 카드(작은 카드 + 굵은 글 줄 + `작성자 · 시각` + 댓글 수)와 같은 모양.
/// 공지는 제목이 없어서 본문 앞부분(3줄 말줄임)을 굵은 글 줄 자리에 두고, 앞에 작성자 아바타, 오른쪽에 사진
/// 공지의 작은 썸네일·댓글 수를 둔다. 지금 채팅방에 고정된 공지에는 "고정" 표시, 안 읽은 공지에는 "안 읽음".
class _AnnouncementTile extends StatelessWidget {
  final Session session;
  final Room room;
  final Announcement announcement;
  final VoidCallback onTap;
  final bool unread;
  const _AnnouncementTile({
    super.key,
    required this.session,
    required this.room,
    required this.announcement,
    required this.onTap,
    this.unread = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = BoardColors.of(theme);
    final primary = theme.colorScheme.primary;
    final hint = theme.hintColor;
    final author = room.members
        .where((m) => m.id == announcement.authorId)
        .firstOrNull;
    final hasText = announcement.text.trim().isNotEmpty;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: boardCardDecoration(
        colors,
        border: unread ? primary : null,
        borderWidth: unread ? 1.5 : 1,
        color: unread
            ? Color.alphaBlend(primary.withValues(alpha: 0.06), colors.card)
            : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AvatarView(
                  username: announcement.authorName,
                  avatarType: author?.avatarType ?? 'initial',
                  avatarEmoji: author?.avatarEmoji,
                  avatarColor: author?.avatarColor,
                  avatarUrl: author?.avatarUrl,
                  resolveUrl: session.resolveUrl,
                  radius: 17,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (unread || announcement.pinned)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (unread)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.redAccent,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Text(
                                    '안 읽음',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              if (announcement.pinned) const PinnedPostTag(),
                            ],
                          ),
                        ),
                      // 사진만 있는 공지는 "[사진]".
                      Text(
                        hasText ? announcement.text : announcement.previewText,
                        key: const ValueKey('announcement-tile-text'),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${announcement.authorName} · '
                        '${formatPostDateTime(announcement.createdAt)}',
                        key: const ValueKey('announcement-tile-meta'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: hint),
                      ),
                    ],
                  ),
                ),
                // 오른쪽 — 사진 공지의 작은 썸네일, 그 아래(또는 혼자) 댓글 수. 아래 줄(작성자·시각)이 잘리지 않게
                // 한 칸에 모았다.
                if (announcement.hasImage || announcement.commentCount > 0) ...[
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (announcement.hasImage)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: CachedNetworkImage(
                            key: const ValueKey('announcement-tile-thumb'),
                            imageUrl: session.resolveUrl(
                              announcement.imageThumbnailUrl ??
                                  announcement.imageUrl ??
                                  '',
                            ),
                            width: 44,
                            height: 44,
                            fit: BoxFit.cover,
                            placeholder: (_, _) => Container(
                              width: 44,
                              height: 44,
                              color: theme.colorScheme.surfaceContainerHighest,
                            ),
                            errorWidget: (_, _, _) => Container(
                              width: 44,
                              height: 44,
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: Icon(Icons.image_outlined, color: hint),
                            ),
                          ),
                        ),
                      if (announcement.hasImage &&
                          announcement.commentCount > 0)
                        const SizedBox(height: 6),
                      if (announcement.commentCount > 0)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.mode_comment_outlined,
                              size: 14,
                              color: hint,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '${announcement.commentCount}',
                              style: TextStyle(fontSize: 12, color: hint),
                            ),
                          ],
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
