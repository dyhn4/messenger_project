import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/favorite.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../services/favorites_controller.dart';
import '../services/message_preview.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';
import '../widgets/file_actions.dart';
import '../widgets/poll_card.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'member_profile_dialog.dart';

/// "즐겨찾기" — 내가 즐겨찾기한 메시지·파일·댓글·투표·대화방·멤버를 종류별 탭으로 한눈에 모아 보고, 항목을 누르면 그 자리로
/// 이동한다(메시지·댓글·투표는 그 대화방의 그 메시지로, 파일은 열기, 멤버는 프로필, 대화방은 그 방). 넓은 창(PC)은 대화상자,
/// 좁은 창(모바일)은 전체 화면으로 연다. 메뉴(격자 아이콘)의 "리스트 > 즐겨찾기"에서 들어온다.
Future<void> showFavorites(
  BuildContext context,
  Session session, {
  FavoriteKind? initialKind,
}) {
  final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  if (wide) {
    final height = MediaQuery.sizeOf(context).height;
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 620,
          height: math.min(740, height - 48),
          child: FavoritesScreen(
            session: session,
            asDialog: true,
            initialKind: initialKind,
          ),
        ),
      ),
    );
  }
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => FavoritesScreen(session: session, initialKind: initialKind),
    ),
  );
}

class FavoritesScreen extends StatefulWidget {
  final Session session;
  final bool asDialog;

  /// 처음 열 탭 — null이면 '전체'.
  final FavoriteKind? initialKind;
  const FavoritesScreen({
    super.key,
    required this.session,
    this.asDialog = false,
    this.initialKind,
  });

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  FavoritesController get _favorites => widget.session.favorites;
  final _scroll = ScrollController();
  late FavoriteKind? _kind = widget.initialKind;

  @override
  void initState() {
    super.initState();
    // 열 때마다 새로 받는다 — 다른 곳에서 바뀐 것을 놓치지 않게.
    _favorites.invalidate();
    _favorites.addListener(_onChanged);
    _favorites.load(_kind);
  }

  @override
  void dispose() {
    _favorites.removeListener(_onChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    // 목록이 비워졌으면(다른 기기에서 새로 담음·팀 전환) 지금 탭을 다시 받는다.
    final feed = _favorites.feed(_kind);
    if (!feed.loaded && !feed.loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _favorites.load(_kind);
      });
    }
  }

  void _selectKind(FavoriteKind? kind) {
    if (kind == _kind) return;
    setState(() => _kind = kind);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _favorites.load(kind);
  }

  // ---- 이동 ----

  /// [roomId] 방을 연다 — 넓은 창은 옆 패널의 방을 바꾸고(다른 팀이면 팀 전환까지 requestOpenRoom이 한다), 좁은 창은
  /// 채팅 화면을 위에 얹는다. [messageId]가 있으면 그 메시지로 스크롤·강조한다.
  void _openRoom(String? roomId, {String? messageId}) {
    final room = roomId == null ? null : widget.session.roomById(roomId);
    if (room == null) {
      showAppToast(context, '대화방을 찾을 수 없습니다.');
      return;
    }
    final navigator = Navigator.of(context);
    final narrow = MediaQuery.sizeOf(context).width < wideBreakpoint;
    if (widget.asDialog) navigator.pop();
    if (!narrow) {
      widget.session.requestOpenRoom(room, messageId: messageId);
      return;
    }
    // 좁은 화면도 다른 팀의 방일 수 있어 팀 전환만 requestOpenRoom에 맡기고 화면은 직접 얹는다.
    widget.session.requestOpenRoom(room);
    navigator.push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          session: widget.session,
          room: room,
          highlightMessageId: messageId,
        ),
      ),
    );
  }

  Future<void> _openMember(FavoriteItem item) async {
    final user = item.user;
    if (user == null) return;
    final room = await showDialog<Room>(
      context: context,
      builder: (_) => MemberProfileDialog(session: widget.session, user: user),
    );
    if (room != null && mounted) _openRoom(room.id);
  }

  FileActions _fileActions(FavoriteItem item) => FileActions(
    session: widget.session,
    message: item.message!,
    url: widget.session.resolveUrl(item.fileUrl ?? ''),
    fileName: item.fileName ?? '파일',
  );

  void _open(FavoriteItem item) {
    switch (item.kind) {
      case FavoriteKind.message || FavoriteKind.poll:
        _openRoom(item.roomId, messageId: item.message?.id);
      case FavoriteKind.comment:
        _openRoom(item.roomId, messageId: item.comment?.messageId);
      case FavoriteKind.file:
        _fileActions(item).openOriginal(context);
      case FavoriteKind.room:
        _openRoom(item.roomId);
      case FavoriteKind.member:
        _openMember(item);
    }
  }

  // ---- 해제 ----

  Future<void> _unfavorite(FavoriteItem item) async {
    final session = widget.session;
    try {
      switch (item.kind) {
        case FavoriteKind.message:
          await _favorites.setFavorite(
            FavoriteKind.message,
            item.message!.id,
            false,
          );
        case FavoriteKind.comment:
          await _favorites.setFavorite(
            FavoriteKind.comment,
            item.comment!.id,
            false,
          );
        case FavoriteKind.member:
          await _favorites.setFavorite(
            FavoriteKind.member,
            item.user!.id,
            false,
            teamId: item.teamId,
          );
        case FavoriteKind.poll:
          await session.setPollFavorite(item.message!, false);
          _favorites.removeItem(item);
        case FavoriteKind.room:
          final room = item.roomId == null
              ? null
              : session.roomById(item.roomId!);
          if (room != null && room.favorite) await session.toggleFavorite(room);
          _favorites.removeItem(item);
        case FavoriteKind.file:
          // 파일 즐겨찾기는 켜고 끄는 토글 API라 지금 켜져 있는 것을 끈다(알림은 FileActions가 띄운다).
          final on = await _fileActions(item).toggleFavorite(context);
          if (on == false) _favorites.removeItem(item);
          return;
      }
      if (mounted) showAppToast(context, '즐겨찾기에서 뺐습니다.');
    } catch (e) {
      if (mounted) showAppToast(context, '즐겨찾기를 바꾸지 못했습니다: $e');
    }
  }

  // ---- 그리기 ----

  Widget _tabs(BuildContext context) {
    final tabs = <FavoriteKind?>[null, ...FavoriteKind.values];
    return SizedBox(
      height: 48,
      child: ListView.separated(
        key: const ValueKey('favorites-tabs'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: tabs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final kind = tabs[i];
          return ChoiceChip(
            key: ValueKey('favorites-tab-${kind?.name ?? 'all'}'),
            label: Text(kind?.label ?? '전체'),
            selected: kind == _kind,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => _selectKind(kind),
          );
        },
      ),
    );
  }

  Widget _body(BuildContext context) {
    final feed = _favorites.feed(_kind);
    if (feed.error != null && feed.items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(feed.error!),
            TextButton(
              onPressed: () => _favorites.load(_kind, refresh: true),
              child: const Text('다시 시도'),
            ),
          ],
        ),
      );
    }
    if (!feed.loaded) return const Center(child: CircularProgressIndicator());
    if (feed.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _kind?.emptyHint ??
                '즐겨찾기한 항목이 없습니다.\n메시지·파일·댓글·투표·대화방·멤버를 즐겨찾기에 담아 두세요.',
            key: const ValueKey('favorites-empty'),
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ),
      );
    }
    final footer = feed.hasMore || feed.loading ? 1 : 0;
    return RefreshIndicator(
      onRefresh: () => _favorites.load(_kind, refresh: true),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < 240) _favorites.loadMore(_kind);
          return false;
        },
        child: ListView.separated(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
          itemCount: feed.items.length + footer,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            if (i >= feed.items.length) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: feed.loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton(
                          key: const ValueKey('favorites-more'),
                          onPressed: () => _favorites.loadMore(_kind),
                          child: const Text('더 보기'),
                        ),
                ),
              );
            }
            final item = feed.items[i];
            return KeyedSubtree(
              key: ValueKey('favorite-${item.key}'),
              child: _FavoriteTile(
                session: widget.session,
                item: item,
                onOpen: () => _open(item),
                onOpenRoom: () => _openRoom(
                  item.roomId,
                  messageId: item.message?.id ?? item.comment?.messageId,
                ),
                onUnfavorite: () => _unfavorite(item),
                onPollChanged: () {
                  final poll = item.message?.poll;
                  if (item.message?.deleted == true ||
                      poll == null ||
                      !poll.favorite) {
                    _favorites.removeItem(item);
                  } else {
                    setState(() {});
                  }
                },
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = Column(
      children: [
        _tabs(context),
        const Divider(height: 1),
        Expanded(child: _body(context)),
      ],
    );
    if (widget.asDialog) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
            child: Row(
              children: [
                const Icon(Icons.star, color: Color(0xFFF5A623)),
                const SizedBox(width: 10),
                Text(
                  '즐겨찾기',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
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
    return Scaffold(
      appBar: AppBar(title: const Text('즐겨찾기')),
      body: content,
    );
  }
}

/// 즐겨찾기 목록의 한 줄 — 종류마다 모양이 조금씩 다르다. 오른쪽 별을 누르면 즐겨찾기에서 뺀다.
class _FavoriteTile extends StatelessWidget {
  final Session session;
  final FavoriteItem item;
  final VoidCallback onOpen;
  final VoidCallback onOpenRoom;
  final VoidCallback onUnfavorite;
  final VoidCallback onPollChanged;
  const _FavoriteTile({
    required this.session,
    required this.item,
    required this.onOpen,
    required this.onOpenRoom,
    required this.onUnfavorite,
    required this.onPollChanged,
  });

  Widget _star(BuildContext context) => IconButton(
    key: ValueKey('favorite-unstar-${item.key}'),
    icon: const Icon(Icons.star, color: Colors.amber),
    tooltip: '즐겨찾기 해제',
    visualDensity: VisualDensity.compact,
    onPressed: onUnfavorite,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final box = BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(12),
    );
    if (item.kind == FavoriteKind.poll) return _poll(context, theme, box);

    final (leading, title, body, meta) = _texts(theme);
    return Container(
      decoration: box,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5,
                      ),
                    ),
                    if (body != null && body.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    if (meta != null && meta.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: theme.hintColor,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (item.kind == FavoriteKind.file)
                IconButton(
                  key: ValueKey('favorite-goto-${item.key}'),
                  icon: const Icon(Icons.chat_bubble_outline, size: 20),
                  tooltip: '대화방으로 이동',
                  visualDensity: VisualDensity.compact,
                  onPressed: onOpenRoom,
                ),
              _star(context),
            ],
          ),
        ),
      ),
    );
  }

  /// 사진·파일 메시지는 설명글(캡션)이 있으면 "사진을 보냈습니다 · 설명글"로 — 설명글이 빠지면 같은 "사진을 보냈습니다"
  /// 줄이 여러 개 나란히 있을 때 어느 것인지 알아볼 수 없다.
  String _messageBody(Message m) {
    final preview = formatMessagePreview(
      type: m.type,
      text: m.text,
      fileName: m.fileName,
    );
    final caption = (m.text ?? '').trim();
    final media = m.type == MessageType.image || m.type == MessageType.file;
    return media && caption.isNotEmpty ? '$preview · $caption' : preview;
  }

  /// (앞 아이콘, 제목 줄, 본문, 보조 줄)
  (Widget, String, String?, String?) _texts(ThemeData theme) {
    final room = item.roomName ?? '';
    Widget icon(IconData data, Color color) => Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(data, size: 20, color: color),
    );
    switch (item.kind) {
      case FavoriteKind.message:
        final m = item.message!;
        final body = m.isPost
            ? [
                if ((m.title ?? '').isNotEmpty) m.title!,
                if ((m.text ?? '').isNotEmpty) m.text!,
              ].join(' — ')
            : _messageBody(m);
        return (
          icon(
            m.isPost ? Icons.article_outlined : Icons.chat_bubble_outline,
            const Color(0xFF2F6FDB),
          ),
          '${m.senderName} · $room',
          body,
          formatDateTime(m.createdAt),
        );
      case FavoriteKind.comment:
        final c = item.comment!;
        final body = formatMessagePreview(
          type: c.type,
          text: c.text,
          fileName: c.fileName,
        );
        final origin = [
          if (item.parentSender != null) '${item.parentSender}',
          if ((item.parentText ?? '').isNotEmpty) item.parentText!,
        ].join(': ');
        return (
          icon(Icons.mode_comment_outlined, const Color(0xFF7048E8)),
          '${c.senderName} · $room',
          body,
          origin.isEmpty
              ? formatDateTime(c.createdAt)
              : '${formatDateTime(c.createdAt)} · 원문 $origin',
        );
      case FavoriteKind.file:
        final name = item.fileName ?? '파일';
        final isImage = item.message?.type == MessageType.image;
        return (
          icon(
            isImage
                ? Icons.image_outlined
                : name.toLowerCase().endsWith('.pdf')
                ? Icons.picture_as_pdf_outlined
                : Icons.insert_drive_file_outlined,
            const Color(0xFF1FAE85),
          ),
          name,
          '$room · ${item.message?.senderName ?? ''}',
          item.message == null ? null : formatDateTime(item.message!.createdAt),
        );
      case FavoriteKind.room:
        final type = item.roomType;
        return (
          icon(
            item.isSelf
                ? Icons.bookmark_border
                : item.isSecret
                ? Icons.lock_outline
                : type == 'topic'
                ? Icons.tag
                : type == 'group'
                ? Icons.groups_2_outlined
                : Icons.person_outline,
            const Color(0xFFB86A00),
          ),
          room,
          switch (type) {
            'topic' => '토픽',
            'group' => '그룹채팅',
            _ => item.isSelf ? '나와의 대화' : '1:1 대화',
          },
          null,
        );
      case FavoriteKind.member:
        final user = item.user!;
        return (
          UserAvatar(user: user, resolveUrl: session.resolveUrl, radius: 18),
          user.name,
          user.orgLine,
          null,
        );
      case FavoriteKind.poll:
        throw StateError('투표는 카드로 그린다.');
    }
  }

  /// 투표는 카드째 보여준다 — 그 자리에서 투표도 되고 ⋯ 메뉴에서 즐겨찾기를 풀 수도 있다.
  Widget _poll(BuildContext context, ThemeData theme, BoxDecoration box) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 4, 6, 12),
      decoration: box,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tag, size: 14, color: theme.hintColor),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  item.roomName ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ),
              TextButton(
                key: ValueKey('favorite-goto-${item.key}'),
                onPressed: onOpenRoom,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('대화방으로 이동'),
              ),
              _star(context),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: PollCard(
              session: session,
              message: item.message!,
              maxWidth: 520,
              onChanged: onPollChanged,
            ),
          ),
        ],
      ),
    );
  }
}
