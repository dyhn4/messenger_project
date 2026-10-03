import 'package:flutter/material.dart';

import '../models/my_post.dart';
import '../models/room.dart';
import '../services/panel_lists_api.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';
import '../widgets/home_shell_scope.dart';
import '../widgets/panel_filters.dart';
import '../widgets/side_panel_header.dart';

/// "내가 쓴 글" 패널 — 내가 직접 보낸 메시지·게시글과 내가 단 댓글을 키워드 없이 시간순으로 모아 보고, 누르면 원본 대화의
/// 그 메시지로 이동한다. 파일·즐겨찾기 패널과 같은 틀이다 — 위에서부터 헤더(`내가 쓴 글` + 닫기), 필터 줄(참여 대화방 /
/// 기간 — 글쓴이는 늘 나라 멤버 필터는 없다), 탭(전체 | 메시지 | 댓글)과 정렬, `"N"개가 로딩되었습니다.` 줄, 목록(무한 스크롤).
/// 텍스트 없이 파일·이미지만 보낸 메시지는 여기 없고(파일 패널에서 본다), 내가 나간 방·비밀 대화의 글도 없다.
/// PC는 오른쪽 패널, 모바일은 전체 화면으로 열린다(side_panels.dart의 'myposts'). 메뉴의 "리스트 > 내가 쓴 글"에서 들어온다.
///
/// 방·기간·탭·정렬은 전부 서버가 건다(`GET /api/my-posts`, panel_lists_api.dart) — 바꿀 때마다 처음부터 다시 받는다.
class MyPostsScreen extends StatefulWidget {
  final Session session;
  final VoidCallback? onClose;

  /// 글을 눌렀을 때 — 안 주면 [openRoomFromPanel](PC는 가운데 채팅이 바뀌고 다른 팀이면 팀 전환까지, 모바일은 채팅 화면이 얹힌다).
  /// 댓글이면 [messageId]는 그 댓글이 달린 원본 메시지다.
  final void Function(Room room, String messageId)? onOpenRoom;

  const MyPostsScreen({
    super.key,
    required this.session,
    this.onClose,
    this.onOpenRoom,
  });

  @override
  State<MyPostsScreen> createState() => _MyPostsScreenState();
}

class _MyPostsScreenState extends State<MyPostsScreen> {
  static const _pageSize = 30;

  final _items = <MyPost>[];
  final _scroll = ScrollController();

  String? _roomId; // null = 참여 대화방(전체)
  MyPostKind _kind = MyPostKind.all;
  PanelPeriod _period = const PanelPeriod();
  bool _newestFirst = true;

  bool _loaded = false;
  bool _loading = false;
  bool _hasMore = false;
  String? _nextBefore;
  String? _error;

  /// 필터가 바뀌거나 새로 받을 때마다 올라간다 — 그 전에 나간 요청의 늦은 응답을 버리려고.
  int _epoch = 0;
  String? _teamId;
  late final _sessionListener = _onSessionChanged;

  Session get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _teamId = _session.currentTeam?.id;
    _session.addListener(_sessionListener);
    _reload();
  }

  @override
  void dispose() {
    _session.removeListener(_sessionListener);
    _scroll.dispose();
    super.dispose();
  }

  /// 팀을 바꾸면 방 필터가 이전 팀 기준이라 풀고 새 팀의 글을 받는다.
  void _onSessionChanged() {
    final team = _session.currentTeam?.id;
    if (team == _teamId) return;
    _teamId = team;
    setState(() => _roomId = null);
    _reload();
  }

  // ---- 받기 ----

  Future<MyPostsPage> _fetch({String? before}) => _session.api!.fetchMyPosts(
    teamId: _teamId!,
    roomId: _roomId,
    kind: _kind,
    since: _period.since(),
    until: _period.until,
    newestFirst: _newestFirst,
    before: before,
    limit: _pageSize,
  );

  Future<void> _reload() async {
    if (_session.api == null || _teamId == null) return;
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _fetch();
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _hasMore = page.hasMore;
        _nextBefore = page.nextBefore;
        _loaded = true;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (e) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _error = '$e';
        _loaded = true;
      });
    } finally {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_loaded || !_hasMore || _nextBefore == null) return;
    final epoch = _epoch;
    setState(() => _loading = true);
    try {
      final page = await _fetch(before: _nextBefore);
      if (!mounted || epoch != _epoch) return;
      setState(() {
        final have = {for (final i in _items) i.key};
        _items.addAll(page.items.where((i) => !have.contains(i.key)));
        _hasMore = page.hasMore;
        _nextBefore = page.nextBefore;
      });
    } catch (e) {
      if (!mounted || epoch != _epoch) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
    }
  }

  // ---- 동작 ----

  void _open(MyPost post) {
    final room = _session.roomById(post.roomId);
    if (room == null) {
      showAppToast(context, '대화방을 찾을 수 없습니다.');
      return;
    }
    final open = widget.onOpenRoom;
    if (open != null) {
      open(room, post.messageId);
    } else {
      openRoomFromPanel(context, _session, room, messageId: post.messageId);
    }
  }

  // ---- 그리기 ----

  Widget _tabs() {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        key: const ValueKey('my-posts-tabs'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: MyPostKind.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final kind = MyPostKind.values[i];
          return ChoiceChip(
            key: ValueKey('my-posts-tab-${kind.name}'),
            label: Text(kind.label),
            selected: kind == _kind,
            visualDensity: VisualDensity.compact,
            onSelected: (_) {
              if (kind == _kind) return;
              setState(() => _kind = kind);
              _reload();
            },
          );
        },
      ),
    );
  }

  Widget _countLine(BuildContext context) => PanelResultLine(
    summary: Text(
      '"${_items.length}"개가 로딩되었습니다.',
      key: const ValueKey('panel-loaded-count'),
      style: Theme.of(context).textTheme.labelLarge,
    ),
    rangeText: _period.rangeText,
  );

  Widget _row(BuildContext context, MyPost post) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final hasTitle = post.isPost;
    final body = (post.text ?? '').trim();
    return InkWell(
      key: ValueKey('my-post-${post.key}'),
      onTap: () => _open(post),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    post.roomName ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatPostDateTime(post.createdAt),
                  style: TextStyle(fontSize: 11.5, color: hint),
                ),
                if (post.editedAt != null)
                  Text(
                    ' · 편집됨',
                    key: ValueKey('my-post-edited-${post.key}'),
                    style: TextStyle(fontSize: 11.5, color: hint),
                  ),
              ],
            ),
            const SizedBox(height: 3),
            if (hasTitle)
              Text(
                post.title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                ),
              ),
            if (body.isNotEmpty)
              Text(
                body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5, height: 1.35),
              ),
            if (post.isComment && (post.parent ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  '댓글 · 원본: ${post.parent}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              )
            else if (post.isComment)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text('댓글', style: TextStyle(fontSize: 12, color: hint)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, key: const ValueKey('my-posts-error')),
            TextButton(onPressed: _reload, child: const Text('다시 시도')),
          ],
        ),
      );
    }
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '작성한 글이 없습니다.',
            key: const ValueKey('my-posts-empty'),
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ),
      );
    }
    final footer = _hasMore || _loading ? 1 : 0;
    return RefreshIndicator(
      onRefresh: _reload,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < 320) _loadMore();
          return false;
        },
        child: ListView.separated(
          key: const ValueKey('my-posts-list'),
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 16),
          itemCount: _items.length + footer,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            if (i >= _items.length) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton(
                          key: const ValueKey('my-posts-more'),
                          onPressed: _loadMore,
                          child: const Text('더 보기'),
                        ),
                ),
              );
            }
            return _row(context, _items[i]);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SidePanelHeader(title: '내가 쓴 글', onClose: widget.onClose),
          const Divider(height: 1),
          PanelFilterBar(
            searchHint: '',
            showSearch: false,
            showMember: false,
            onQueryChanged: (_) {},
            session: _session,
            roomId: _roomId,
            onRoomChanged: (id) {
              setState(() => _roomId = id);
              _reload();
            },
            members: const [],
            senderId: null,
            onSenderChanged: (_) {},
            period: _period,
            onPeriodChanged: (v) {
              setState(() => _period = v);
              _reload();
            },
            leading: _tabs(),
            leadingExpands: true,
            newestFirst: _newestFirst,
            onSortChanged: (v) {
              setState(() => _newestFirst = v);
              _reload();
            },
          ),
          const SizedBox(height: 4),
          _countLine(context),
          const Divider(height: 1),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }
}
