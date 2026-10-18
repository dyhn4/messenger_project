import 'dart:async';

import 'package:flutter/material.dart';

import '../models/my_post.dart';
import '../models/room.dart';
import '../services/panel_lists_api.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';
import '../widgets/filter_dropdown.dart';
import '../widgets/home_shell_scope.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/panel_filters.dart';
import '../widgets/search_result_parts.dart';
import '../widgets/side_panel_header.dart';
import '../l10n/tr.dart';

/// 탭 줄에 범위 단추(현재 팀 ⌄)까지 한 줄로 두려면 필요한 최소 폭 — 이보다 좁으면 단추를 `"N"개가 로딩되었습니다.` 줄
/// 오른쪽으로 옮긴다(검색 패널과 같은 방식). 3개 탭 + 범위 단추 + 정렬 단추가 가로 스크롤 없이 들어가는 폭.
const _scopeInlineMinWidth = 300.0;

/// "내가 쓴 글" 패널 — 내가 직접 보낸 메시지·게시글과 내가 단 댓글을 시간순으로 모아 보고, 누르면 원본 대화의 그 메시지로
/// 이동한다. 검색 패널과 같은 틀이다 — 위에서부터 헤더(`내가 쓴 글` + 닫기), 검색칸(비우면 전부), 필터 줄(참여 대화방 / 기간 —
/// 글쓴이는 늘 나라 멤버 필터는 없다), 탭 줄(`전체 | 메시지 | 댓글`, 오른쪽에 범위 단추(팀이 둘 이상일 때)와 정렬),
/// `"N"개가 로딩되었습니다.` 줄, 목록(검색 결과와 같은 줄 모양, 무한 스크롤).
/// 텍스트 없이 파일·이미지만 보낸 메시지는 여기 없고(파일 패널에서 본다), 내가 나간 방·비밀 대화의 글도 없다.
/// PC는 오른쪽 패널, 모바일은 전체 화면으로 열린다(side_panels.dart의 'myposts'). 메뉴의 "리스트 > 내가 쓴 글"에서 들어온다.
///
/// 검색어·방·기간·종류·범위·정렬은 전부 서버가 건다(`GET /api/my-posts`, panel_lists_api.dart) — 바꿀 때마다 처음부터 다시 받는다.
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
  final _query = TextEditingController();

  /// 검색칸은 입력을 멈추고 잠깐 뒤(또는 엔터)에 찾는다 — 검색 패널과 같은 디바운스.
  Timer? _debounce;

  /// 지금 목록을 받은 검색어(앞뒤 공백 뗀 것) — 결과 줄의 형광펜과 빈 상태 문구가 이걸 본다.
  String _sentQuery = '';

  String? _roomId; // null = 참여 대화방(전체)
  MyPostKind _kind = MyPostKind.all;
  PanelPeriod _period = const PanelPeriod();
  bool _newestFirst = true;

  // 범위 — 패널을 열 때마다 "현재 팀"으로 시작한다. 가입한 팀이 하나뿐이면 단추 자체가 없다(검색 패널과 같다).
  // [_scopeTeamId]는 범위 메뉴에서 이름으로 고른 특정 팀(null이면 _allTeams에 따라 현재 팀 / 모든 팀).
  bool _allTeams = false;
  String? _scopeTeamId;

  /// 지금 목록을 "모든 팀"으로 받았는지 — 맞으면 줄마다 팀 이름 칩.
  bool _resultAllTeams = false;

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
    _debounce?.cancel();
    _query.dispose();
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

  // ---- 범위 ----

  /// 가입한 팀이 둘 이상일 때만 범위 단추가 있다.
  bool get _hasScopeChoice => _session.teams.length > 1;

  /// 범위 메뉴에서 이름으로 고른 팀 — 단추가 없거나, 그 사이 그 팀을 나갔으면 null(현재 팀 / 모든 팀).
  String? get _pickedTeamId {
    final id = _scopeTeamId;
    if (id == null || !_hasScopeChoice) return null;
    return _session.teams.any((t) => t.id == id) ? id : null;
  }

  /// 지금 "모든 팀"으로 받는 중인지(단추가 없으면 늘 현재 팀).
  bool get _allTeamsActive =>
      _allTeams && _hasScopeChoice && _pickedTeamId == null;

  void _selectScope(bool allTeams) {
    if (_allTeams == allTeams && _scopeTeamId == null) return;
    final hadTeam = _pickedTeamId;
    setState(() {
      _allTeams = allTeams;
      _scopeTeamId = null;
    });
    _onFilterTeamChanged(hadTeam);
    _reload();
  }

  /// 범위 메뉴에서 특정 팀을 골랐을 때 — 그 팀 하나에서만 받는다.
  void _selectTeam(String teamId) {
    if (_scopeTeamId == teamId) return;
    final hadTeam = _pickedTeamId;
    setState(() {
      _scopeTeamId = teamId;
      _allTeams = false;
    });
    _onFilterTeamChanged(hadTeam);
    _reload();
  }

  /// 참여 대화방 필터의 후보는 고른 팀(없으면 지금 팀)의 방이다 — 그 팀이 바뀌면 다른 팀 방을 골라 둔 방 필터는 푼다.
  void _onFilterTeamChanged(String? before) {
    final after = _pickedTeamId;
    if (before == after) return;
    final teamId = after ?? _teamId;
    final room = _roomId == null ? null : _session.roomById(_roomId!);
    if (room != null && room.teamId != teamId) {
      setState(() => _roomId = null);
    }
  }

  // ---- 검색칸 ----

  /// 입력할 때마다 — 지우기(X) 단추 표시를 갱신하고, 잠깐(350ms) 멈추면 찾는다.
  void _onQueryChanged(String _) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _searchNow);
  }

  /// 엔터를 누르거나 지우기(X)를 눌렀을 때, 디바운스가 끝났을 때 — 검색어가 바뀌었을 때만 다시 받는다.
  void _searchNow() {
    _debounce?.cancel();
    if (_query.text.trim() == _sentQuery) return;
    _reload();
  }

  // ---- 받기 ----

  Future<MyPostsPage> _fetch(String query, bool allTeams, {String? before}) =>
      _session.api!.fetchMyPosts(
        teamId: _pickedTeamId ?? _teamId!,
        allTeams: allTeams,
        query: query,
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
    final query = _query.text.trim();
    final allTeams = _allTeamsActive;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _fetch(query, allTeams);
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _hasMore = page.hasMore;
        _nextBefore = page.nextBefore;
        _sentQuery = query;
        _resultAllTeams = allTeams;
        _loaded = true;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (e) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _error = '$e';
        _sentQuery = query;
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
      // 이어 받기는 첫 쪽과 같은 조건이어야 한다 — 그 사이 검색칸에 입력 중이어도 받은 검색어·범위로.
      final page = await _fetch(
        _sentQuery,
        _resultAllTeams,
        before: _nextBefore,
      );
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

  void _selectKind(MyPostKind kind) {
    if (kind == _kind) return;
    setState(() => _kind = kind);
    _reload();
  }

  void _open(MyPost post) {
    final room = _session.roomById(post.roomId);
    if (room == null) {
      showAppToast(context, tr('대화방을 찾을 수 없습니다.'));
      return;
    }
    final open = widget.onOpenRoom;
    if (open != null) {
      open(room, post.messageId);
    } else {
      openRoomFromPanel(context, _session, room, messageId: post.messageId);
    }
  }

  /// 줄의 방 이름 — 목록에 있는 방이면 사이드바와 같은 이름(나에게만 바꾼 이름·나와의 대화 포함), 없으면 서버가 준 이름.
  String _roomNameOf(MyPost post) {
    final room = _session.roomById(post.roomId);
    if (room == null) return post.roomName ?? '';
    return room.displayName(_session.userId ?? '');
  }

  // ---- 그리기 ----

  Widget _controls() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const ValueKey('my-posts-search-field'),
          controller: _query,
          decoration: InputDecoration(
            hintText: tr('내가 쓴 글 검색'),
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _query.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: tr('지우기'),
                    onPressed: () {
                      _query.clear();
                      setState(() {});
                      _searchNow();
                    },
                  ),
            border: const OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.search,
          onChanged: _onQueryChanged,
          onSubmitted: (_) => _searchNow(),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: RoomFilterButton(
                session: _session,
                selectedRoomId: _roomId,
                teamId: _pickedTeamId,
                expand: true,
                onSelected: (id) {
                  setState(() => _roomId = id);
                  _reload();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: PeriodFilterButton(
                period: _period,
                onChanged: (v) {
                  setState(() => _period = v);
                  _reload();
                },
              ),
            ),
          ],
        ),
      ],
    ),
  );

  /// `전체 | 메시지 | 댓글` 탭과 맨 오른쪽 정렬 단추. [scope]는 정렬 단추 왼쪽에 둘 범위 단추(자리가 모자라거나 팀이 하나면 null).
  Widget _typeBar(Widget? scope) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final kind in MyPostKind.values)
                  PanelTab(
                    key: ValueKey('my-posts-tab-${kind.name}'),
                    label: kind.label,
                    selected: _kind == kind,
                    onTap: () => _selectKind(kind),
                  ),
              ],
            ),
          ),
        ),
        ?scope,
        PanelSortButton(
          newestFirst: _newestFirst,
          onChanged: (v) {
            setState(() => _newestFirst = v);
            _reload();
          },
        ),
      ],
    ),
  );

  Widget _countLine(BuildContext context, Widget? scope) => PanelResultLine(
    summary: Text(
      tr('"{_items.length}"개가 로딩되었습니다.', {'_items.length': _items.length}),
      key: const ValueKey('panel-loaded-count'),
      style: Theme.of(context).textTheme.labelLarge,
    ),
    rangeText: _period.rangeText,
    trailing: scope,
  );

  Widget _body(BuildContext context) {
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, key: const ValueKey('my-posts-error')),
            TextButton(onPressed: _reload, child: Text(tr('다시 시도'))),
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
            _sentQuery.isEmpty ? tr('작성한 글이 없습니다.') : tr('검색 결과가 없습니다.'),
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
        child: MutedScrollbar(
          controller: _scroll,
          child: ListView.separated(
            key: const ValueKey('my-posts-list'),
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 16),
            itemCount: _items.length + footer,
            // 오른쪽 끝에 겹치는 스크롤바 아래로 선이 파고들지 않도록 그만큼 짧게 그린다(검색 결과와 같다).
            separatorBuilder: (_, _) => const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Divider(height: 1),
            ),
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
                            child: Text(tr('더 보기')),
                          ),
                  ),
                );
              }
              final post = _items[i];
              return _MyPostRow(
                post: post,
                roomName: _roomNameOf(post),
                myName: _session.name ?? '',
                query: _sentQuery,
                showTeam: _resultAllTeams,
                onTap: () => _open(post),
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 범위 단추(현재 팀 ⌄)는 탭 줄의 정렬 단추 왼쪽에 둔다. 폭이 모자라면(휴대폰) 로딩 줄 오른쪽으로.
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final scope = _hasScopeChoice
            ? PanelScopeButton(
                allTeams: _allTeamsActive,
                onChanged: _selectScope,
                // 가입한 팀 전부(현재 팀 포함) — 이름으로 골라 그 팀 하나만 본다.
                teams: [
                  for (final t in _session.teams) (id: t.id, name: t.name),
                ],
                teamId: _pickedTeamId,
                onTeamSelected: _selectTeam,
              )
            : null;
        final inline =
            scope != null && constraints.maxWidth - 32 >= _scopeInlineMinWidth;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _controls(),
            const SizedBox(height: 4),
            _typeBar(inline ? scope : null),
            _countLine(
              context,
              inline || scope == null
                  ? null
                  : Align(alignment: Alignment.centerRight, child: scope),
            ),
            const Divider(height: 1),
            Expanded(child: _body(context)),
          ],
        );
      },
    );
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SidePanelHeader(title: tr('내가 쓴 글'), onClose: widget.onClose),
          const Divider(height: 1),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// 내가 쓴 글 한 줄 — 검색 결과 줄(search_screen.dart)과 같은 모양: 방 이름(강조색, 모든 팀이면 팀 칩) + (아바타 + 내 이름 ·
/// 시각 · 편집됨) + 내용. 게시글은 `게시글` 표시와 굵은 제목 한 줄 아래 본문, 댓글은 `댓글` 표시와 원본 한 줄 아래 댓글 본문,
/// 일반 메시지는 본문만(두 줄까지). 검색어는 형광펜으로 칠한다.
class _MyPostRow extends StatelessWidget {
  final MyPost post;
  final String roomName;
  final String myName;
  final String query;
  final bool showTeam;
  final VoidCallback onTap;
  const _MyPostRow({
    required this.post,
    required this.roomName,
    required this.myName,
    required this.query,
    required this.showTeam,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final metaStyle = theme.textTheme.labelSmall?.copyWith(color: hint);
    final body = (post.text ?? '').trim();
    final teamName = post.teamName ?? '';
    return InkWell(
      key: ValueKey('my-post-${post.key}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    roomName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (showTeam && teamName.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  TeamNameChip(
                    key: ValueKey('my-post-team-${post.key}'),
                    name: teamName,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 14,
                  child: Text(myName.isNotEmpty ? myName[0] : '?'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              myName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            formatPostDateTime(post.createdAt),
                            style: metaStyle,
                          ),
                          // 좁은 폭에서는 이름과 함께 말줄임으로 줄어든다(시각은 늘 다 보인다).
                          if (post.editedAt != null)
                            Flexible(
                              child: Text(
                                tr(' · 편집됨'),
                                key: ValueKey('my-post-edited-${post.key}'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: metaStyle,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      if (post.isPost)
                        _headline(
                          context,
                          ResultKindBadge(tr('게시글')),
                          highlightedText(
                            context,
                            post.title!,
                            query,
                            maxLines: 1,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        )
                      else if (post.isComment)
                        _headline(
                          context,
                          ResultKindBadge(tr('댓글')),
                          Text(
                            (post.parent ?? '').isEmpty
                                ? tr('원본 메시지')
                                : tr('원본: {post.parent}', {
                                    'post.parent': post.parent,
                                  }),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: hint),
                          ),
                        ),
                      if (body.isNotEmpty) ...[
                        if (post.isPost || post.isComment)
                          const SizedBox(height: 2),
                        highlightedText(context, body, query, maxLines: 2),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 내용 첫 줄 — 왼쪽 종류 표시(`게시글`·`댓글`)와 오른쪽 한 줄(제목·원본).
  Widget _headline(BuildContext context, Widget badge, Widget text) => Row(
    children: [
      badge,
      const SizedBox(width: 6),
      Expanded(child: text),
    ],
  );
}
