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
import '../widgets/home_shell_scope.dart';
import '../widgets/panel_filters.dart';
import '../widgets/poll_card.dart';
import '../widgets/side_panel_header.dart';
import '../widgets/user_avatar.dart';
import 'member_profile_dialog.dart';
import '../l10n/tr.dart';

/// "즐겨찾기" 패널 — 내가 즐겨찾기한 메시지·파일·댓글·투표·대화방·멤버를 한곳에 모아 보고, 항목을 누르면 그 자리로
/// 이동한다(메시지·댓글·투표는 그 대화방의 그 메시지로, 파일은 열기, 멤버는 프로필, 대화방은 그 방). 파일 패널과 같은
/// 틀이다 — 위에서부터 검색칸, 필터 줄(참여 대화방 / 모든 멤버 / 기간), 그 아래 줄(왼쪽 끝 종류 드롭다운 — 전체 / 메시지 /
/// 파일 / 댓글 / 투표 / 대화방 / 멤버 — 과 오른쪽 끝 정렬), `"N"개가 로딩되었습니다.` 줄, 목록. PC는 오른쪽 패널, 모바일은
/// 전체 화면으로 열린다(side_panels.dart의 'favorites'). 메뉴(격자 아이콘)의 "리스트 > 즐겨찾기"에서 들어온다.
///
/// 필터는 서버를 거치지 않고 **이미 불러온 목록**(favorites_controller.dart, 한 번에 30개씩 "더 보기")을 클라이언트에서
/// 거른다. 항목이 가진 정보로만 걸 수 있다(자세한 규칙은 [FavoriteFilter]).
class FavoritesScreen extends StatefulWidget {
  final Session session;
  final VoidCallback? onClose;

  /// 처음 고를 종류 — null이면 '전체'.
  final FavoriteKind? initialKind;
  const FavoritesScreen({
    super.key,
    required this.session,
    this.onClose,
    this.initialKind,
  });

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

/// 즐겨찾기 항목이 필터에 들어맞는지 — 화면 상태와 떼어 둔 순수 클래스라 테스트가 직접 쓴다. 항목이 가진 정보로만 건다:
///  - 대화방: 메시지·파일·댓글·투표·대화방 항목이 방 id를 가진다. 멤버 항목은 방이 없어 영향받지 않는다.
///  - 멤버(보낸 사람): 메시지·파일·댓글·투표는 보낸 사람, 멤버 항목은 즐겨찾기한 그 사람이다. 대화방 항목은 영향받지 않는다.
///  - 기간: 즐겨찾기에 **담은 시각**(favoritedAt) 기준이다 — 서버가 주는 순서(최신순)와 같은 축이다. 담은 시각이 없는
///    대화방 항목은 영향받지 않는다.
///  - 검색: 본문·제목·파일명·보낸 사람·대화방 이름·투표 제목/항목·멤버 이름/조직에서 찾는다.
@visibleForTesting
class FavoriteFilter {
  final String query;
  final String? roomId;
  final String? senderId;
  final PanelPeriod period;

  /// 테스트용 "지금".
  final DateTime? now;
  const FavoriteFilter({
    this.query = '',
    this.roomId,
    this.senderId,
    this.period = const PanelPeriod(),
    this.now,
  });

  bool matches(FavoriteItem item) {
    if (roomId != null && item.roomId != null && item.roomId != roomId) {
      return false;
    }
    final who = senderOf(item);
    if (senderId != null && who != null && who != senderId) return false;
    final at = item.favoritedAt;
    if (at != null) {
      final since = period.since(now);
      if (since != null && at.isBefore(since)) return false;
      final until = period.until;
      if (until != null && at.isAfter(until)) return false;
    }
    final q = query.trim().toLowerCase();
    if (q.isNotEmpty && !searchText(item).contains(q)) return false;
    return true;
  }

  /// 메시지·파일·댓글·투표는 보낸 사람, 멤버는 그 사람. 대화방은 null.
  static String? senderOf(FavoriteItem item) => switch (item.kind) {
    FavoriteKind.message ||
    FavoriteKind.poll ||
    FavoriteKind.file => item.message?.senderId,
    FavoriteKind.comment => item.comment?.senderId,
    FavoriteKind.member => item.user?.id,
    FavoriteKind.room => null,
  };

  static String searchText(FavoriteItem item) {
    final m = item.message;
    final c = item.comment;
    final parts = <String?>[
      item.roomName,
      item.fileName,
      m?.text,
      m?.title,
      m?.senderName,
      c?.text,
      c?.senderName,
      item.parentText,
      item.parentSender,
      m?.poll?.title,
      ...?m?.poll?.options.map((o) => o.text),
      item.user?.name,
      item.user?.orgLine,
    ];
    return parts.whereType<String>().join(' ').toLowerCase();
  }
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  FavoritesController get _favorites => widget.session.favorites;
  final _scroll = ScrollController();
  late FavoriteKind? _kind = widget.initialKind;

  String _query = '';
  String? _roomId; // null = 참여 대화방(전체)
  String? _senderId; // null = 모든 멤버
  PanelPeriod _period = const PanelPeriod();
  bool _newestFirst = true;

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
    // 목록이 비워졌으면(다른 기기에서 새로 담음·팀 전환) 지금 종류를 다시 받는다.
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

  /// [roomId] 방을 연다 — PC는 가운데 채팅이 바뀌고(다른 팀이면 팀 전환까지), 모바일은 채팅 화면을 위에 얹는다.
  /// [messageId]가 있으면 그 메시지로 스크롤·강조한다.
  void _openRoom(String? roomId, {String? messageId}) {
    final room = roomId == null ? null : widget.session.roomById(roomId);
    if (room == null) {
      showAppToast(context, tr('대화방을 찾을 수 없습니다.'));
      return;
    }
    openRoomFromPanel(context, widget.session, room, messageId: messageId);
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
    fileName: item.fileName ?? tr('파일'),
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
      if (mounted) showAppToast(context, tr('즐겨찾기에서 뺐습니다.'));
    } catch (e) {
      if (mounted) showAppToast(context, tr('즐겨찾기를 바꾸지 못했습니다: {e}', {'e': e}));
    }
  }

  // ---- 거르기 · 정렬 ----

  /// 대화방 필터가 바뀌면 보낸 사람 필터(이전 방 멤버 기준으로 골랐던 값)가 새 범위에 안 맞을 수 있어 같이 초기화한다.
  void _onRoomSelected(String? roomId) => setState(() {
    _roomId = roomId;
    _senderId = null;
  });

  /// 지금 종류의 불러온 목록에서 필터를 통과한 것을 정렬해 돌려준다.
  List<FavoriteItem> _visibleItems(List<FavoriteItem> items) {
    final filter = FavoriteFilter(
      query: _query,
      roomId: _roomId,
      senderId: _senderId,
      period: _period,
    );
    final indexed = [
      for (final (i, item) in items.indexed)
        if (filter.matches(item)) (i, item),
    ];
    // 담은 시각 순. 담은 시각이 없는 항목(대화방)은 최신순에서 맨 앞, 과거순에서 맨 뒤. 같으면 서버가 준 순서.
    indexed.sort((a, b) {
      final x = a.$2.favoritedAt;
      final y = b.$2.favoritedAt;
      if (x == null || y == null) {
        if (x == y) return a.$1.compareTo(b.$1);
        return (x == null) == _newestFirst ? -1 : 1;
      }
      final byTime = _newestFirst ? y.compareTo(x) : x.compareTo(y);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
    return [for (final (_, item) in indexed) item];
  }

  // ---- 그리기 ----

  /// 정렬 단추 줄 왼쪽 끝의 종류 드롭다운(전체 / 메시지 / 파일 / 댓글 / 투표 / 대화방 / 멤버).
  Widget _kindButton() => PanelKindButton<FavoriteKind?>(
    key: const ValueKey('favorites-kind'),
    values: const [null, ...FavoriteKind.values],
    selected: _kind,
    labelOf: (kind) => kind?.label ?? tr('전체'),
    itemKey: (kind) => ValueKey('favorites-tab-${kind?.name ?? 'all'}'),
    onChanged: _selectKind,
  );

  /// "N개가 로딩되었습니다." 줄 — 비어 있어도 보이고, 직접 설정한 기간은 그 오른쪽에 보인다.
  Widget _countLine(BuildContext context, int count) => PanelResultLine(
    summary: Text(
      tr('"{count}"개가 로딩되었습니다.', {'count': count}),
      key: const ValueKey('panel-loaded-count'),
      style: Theme.of(context).textTheme.labelLarge,
    ),
    rangeText: _period.rangeText,
  );

  Widget _message(BuildContext context, String text, Key key) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        key: key,
        textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).hintColor),
      ),
    ),
  );

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
              child: Text(tr('다시 시도')),
            ),
          ],
        ),
      );
    }
    if (!feed.loaded) return const Center(child: CircularProgressIndicator());
    if (feed.items.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _countLine(context, 0),
          const Divider(height: 1),
          Expanded(
            child: _message(
              context,
              _kind?.emptyHint ??
                  tr('즐겨찾기한 항목이 없습니다.\n메시지·파일·댓글·투표·대화방·멤버를 즐겨찾기에 담아 두세요.'),
              const ValueKey('favorites-empty'),
            ),
          ),
        ],
      );
    }
    final items = _visibleItems(feed.items);
    final footer = feed.hasMore || feed.loading ? 1 : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _countLine(context, items.length),
        const Divider(height: 1),
        Expanded(
          child: items.isEmpty && footer == 0
              ? _message(
                  context,
                  tr('조건에 맞는 즐겨찾기가 없습니다.'),
                  const ValueKey('favorites-no-match'),
                )
              : RefreshIndicator(
                  onRefresh: () => _favorites.load(_kind, refresh: true),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.extentAfter < 240) {
                        _favorites.loadMore(_kind);
                      }
                      return false;
                    },
                    child: ListView.separated(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                      itemCount: items.length + footer,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        if (i >= items.length) return _footer(feed);
                        final item = items[i];
                        return KeyedSubtree(
                          key: ValueKey('favorite-${item.key}'),
                          child: _FavoriteTile(
                            session: widget.session,
                            item: item,
                            onOpen: () => _open(item),
                            onOpenRoom: () => _openRoom(
                              item.roomId,
                              messageId:
                                  item.message?.id ?? item.comment?.messageId,
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
                ),
        ),
      ],
    );
  }

  /// 목록 맨 아래 — 받는 중이면 돌리는 표시, 더 있으면 "더 보기".
  Widget _footer(FavoriteFeed feed) => Padding(
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
              child: Text(tr('더 보기')),
            ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final kind = _kind;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SidePanelHeader(title: tr('즐겨찾기'), onClose: widget.onClose),
          const Divider(height: 1),
          PanelFilterBar(
            searchHint: tr('즐겨찾기 검색'),
            onQueryChanged: (q) => setState(() => _query = q),
            session: widget.session,
            roomId: _roomId,
            onRoomChanged: _onRoomSelected,
            members: memberChoicesFor(widget.session, _roomId),
            senderId: _senderId,
            onSenderChanged: (v) => setState(() => _senderId = v),
            period: _period,
            onPeriodChanged: (v) => setState(() => _period = v),
            // 항목에 그 정보가 없는 종류에서는 필터를 막는다([FavoriteFilter] 설명 참고).
            roomEnabled: kind != FavoriteKind.member,
            memberEnabled: kind != FavoriteKind.room,
            periodEnabled: kind != FavoriteKind.room,
            leading: _kindButton(),
            newestFirst: _newestFirst,
            onSortChanged: (v) => setState(() => _newestFirst = v),
          ),
          const SizedBox(height: 4),
          Expanded(child: _body(context)),
        ],
      ),
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
    tooltip: tr('즐겨찾기 해제'),
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
                  tooltip: tr('대화방으로 이동'),
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
              : tr('{p0} · 원문 {origin}', {
                  'p0': formatDateTime(c.createdAt),
                  'origin': origin,
                }),
        );
      case FavoriteKind.file:
        final name = item.fileName ?? tr('파일');
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
            'topic' => tr('토픽'),
            'group' => tr('그룹채팅'),
            _ => item.isSelf ? tr('나와의 대화') : tr('1:1 대화'),
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
        throw StateError(tr('투표는 카드로 그린다.'));
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
                child: Text(tr('대화방으로 이동')),
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
