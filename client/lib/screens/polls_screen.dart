import 'dart:async';

import 'package:flutter/material.dart';

import '../models/message.dart';
import '../models/poll.dart';
import '../models/poll_list.dart';
import '../models/room.dart';
import '../services/panel_lists_api.dart';
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/compact_menu.dart';
import '../widgets/filter_dropdown.dart';
import '../widgets/home_shell_scope.dart';
import '../widgets/hover_toolbar.dart' show hoverMenuStyle;
import '../widgets/panel_create_button.dart';
import '../widgets/poll_card.dart';
import '../widgets/side_panel_header.dart';
import 'poll_create_dialog.dart';

/// "투표" 패널 — 이 팀에서 내가 멤버인 방(비밀 대화 제외)의 투표를 한곳에 모아 보고, 그 자리에서 바로 투표한다.
/// 할 일 패널(todos_panel.dart)과 같은 틀이다 — 위에서부터 헤더(`투표` + 닫기), 가로 전체 옅은 회색 `+ 투표 만들기`,
/// 필터 줄(참여한 대화방 · 참여 여부 — 전체 / 참여함 / 참여 안 함), 작은 글씨 줄(왼쪽 `마감된 투표 제외` 스위치, 오른쪽
/// 정렬 — 생성 순 / 기한 순), 그 아래 옅은 회색 바탕에 `N개의 투표`(서버가 센 전체 개수)와 흰 둥근 카드 목록(무한
/// 스크롤)이다. 기간 제한은 없다(만든 지 오래된 투표도 다 나온다). 카드는 위 줄(대화방 이름 · "방으로 이동")과 채팅의
/// [PollCard]를 그대로 담아 그 자리에서 투표한다. "방으로 이동"을 누르면 그 방의 그 투표로 간다.
///
/// 정렬 — 생성 순은 최근에 만든 것부터, 기한 순은 진행 중인 투표를 마감이 가까운 것부터 보이고 그 뒤에 마감된 투표를
/// 최근에 끝난 것부터 보인다(`마감된 투표 제외`를 켜면 진행 중인 것만). 펼침 메뉴(참여 여부·정렬)는 메시지 예약 패널의
/// 정렬과 같은 [MenuAnchor]라 애니메이션 없이 바로 뜬다.
/// PC는 오른쪽 패널, 모바일은 전체 화면으로 열린다(side_panels.dart의 'polls'). 메뉴(격자 아이콘)의 "생성 > 투표"에서 들어온다.
///
/// 필터·정렬은 전부 서버가 건다(`GET /api/polls`, panel_lists_api.dart) — 필터를 바꿀 때마다 처음부터 다시 받는다. 열려 있는
/// 동안 소켓으로 투표가 바뀌면(`session.pollEvents`) 목록의 해당 카드를 고치고, 새 투표가 올라오면 맨 위에 끼우지 않고
/// "새 투표가 있습니다 · 새로고침" 줄만 띄운다(내가 만든 투표는 바로 다시 받는다).
class PollsScreen extends StatefulWidget {
  final Session session;
  final VoidCallback? onClose;

  /// "방으로 이동" — 안 주면 [openRoomFromPanel](PC는 가운데 채팅이 바뀌고 모바일은 채팅 화면이 얹힌다).
  final void Function(Room room, String messageId)? onOpenRoom;

  const PollsScreen({
    super.key,
    required this.session,
    this.onClose,
    this.onOpenRoom,
  });

  @override
  State<PollsScreen> createState() => _PollsScreenState();
}

class _PollsScreenState extends State<PollsScreen> {
  static const _pageSize = 20;

  final _items = <PollListItem>[];
  final _scroll = ScrollController();

  String? _roomId; // null = 참여한 대화방(전체)
  PollParticipationFilter _participated = PollParticipationFilter.all;

  /// `마감된 투표 제외` — 켜면 진행 중인 투표만(서버 status=open).
  bool _excludeClosed = false;
  PollSort _sort = PollSort.created;

  bool _loaded = false;
  bool _loading = false;
  bool _hasMore = false;
  int _total = 0;
  String? _nextBefore;
  String? _error;
  bool _newPollNotice = false;

  /// 필터가 바뀌거나 새로 받을 때마다 올라간다 — 그 전에 나간 요청의 늦은 응답을 버리려고.
  int _epoch = 0;
  String? _teamId;
  late final _sessionListener = _onSessionChanged;
  final _subs = <StreamSubscription<dynamic>>[];

  Session get _session => widget.session;

  bool get _filtered =>
      _roomId != null ||
      _excludeClosed ||
      _participated != PollParticipationFilter.all;

  @override
  void initState() {
    super.initState();
    _teamId = _session.currentTeam?.id;
    _session.addListener(_sessionListener);
    _subs
      ..add(_session.pollEvents.updated.listen(_onPollUpdated))
      ..add(_session.pollEvents.created.listen(_onPollCreated));
    _reload();
  }

  @override
  void dispose() {
    _session.removeListener(_sessionListener);
    for (final s in _subs) {
      s.cancel();
    }
    _scroll.dispose();
    super.dispose();
  }

  /// 팀을 바꾸면 방 필터가 이전 팀 기준이라 풀고 새 팀의 목록을 받는다.
  void _onSessionChanged() {
    final team = _session.currentTeam?.id;
    if (team == _teamId) return;
    _teamId = team;
    setState(() => _roomId = null);
    _reload();
  }

  // ---- 받기 ----

  /// 기간은 보내지 않는다 — 서버는 since/until이 없으면 전체 기간에서 찾는다.
  Future<PollListPage> _fetch({String? before}) => _session.api!.fetchPollList(
    teamId: _teamId!,
    roomId: _roomId,
    status: _excludeClosed ? PollStatusFilter.open : PollStatusFilter.all,
    participated: _participated,
    sort: _sort,
    before: before,
    limit: _pageSize,
  );

  /// 처음부터 다시 받는다 — 필터·정렬을 바꿨을 때, 새로고침, 팀 전환.
  Future<void> _reload() async {
    if (_session.api == null || _teamId == null) return;
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _error = null;
      _newPollNotice = false;
    });
    try {
      final page = await _fetch();
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _hasMore = page.hasMore;
        _total = page.total;
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
        final have = {for (final i in _items) i.message.id};
        _items.addAll(page.items.where((i) => !have.contains(i.message.id)));
        _hasMore = page.hasMore;
        _total = page.total;
        _nextBefore = page.nextBefore;
      });
    } catch (e) {
      if (!mounted || epoch != _epoch) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
    }
  }

  // ---- 소켓 ----

  /// 누가 투표했거나 마감됐다 — 목록에 있는 카드의 투표를 받는 쪽 규칙([Poll.applyUpdate])대로 고친다.
  void _onPollUpdated(PollUpdatedEvent event) {
    final index = _items.indexWhere(
      (i) =>
          i.message.id == event.messageId || i.message.poll?.id == event.pollId,
    );
    if (index < 0 || !mounted) return;
    final message = _items[index].message;
    setState(() {
      message.poll = Poll.applyUpdate(
        message.poll,
        event.poll,
        actorId: event.actorId,
        actorOptionIds: event.actorOptionIds,
        myUserId: _session.userId,
      );
    });
  }

  /// 새 투표가 올라왔다 — 내가 만든 것이면 바로 다시 받고, 남이 만든 것이면 알림줄만 띄운다(보던 자리가 밀리지 않게).
  void _onPollCreated(Message m) {
    if (!mounted || _session.roomById(m.roomId) == null) return;
    if (_roomId != null && _roomId != m.roomId) return;
    if (m.senderId != null && m.senderId == _session.userId) {
      _reload();
      return;
    }
    if (!_newPollNotice) setState(() => _newPollNotice = true);
  }

  // ---- 동작 ----

  Future<void> _create() async {
    final created = await showPollCreator(context, session: _session);
    if (!mounted || !created) return;
    showAppToast(context, '투표를 만들었습니다.');
    _reload();
  }

  void _openRoom(PollListItem item) {
    final room = _session.roomById(item.roomId);
    if (room == null) {
      showAppToast(context, '대화방을 찾을 수 없습니다.');
      return;
    }
    final open = widget.onOpenRoom;
    if (open != null) {
      open(room, item.message.id);
    } else {
      openRoomFromPanel(context, _session, room, messageId: item.message.id);
    }
  }

  void _onCardChanged(PollListItem item) {
    if (item.message.deleted) {
      setState(() {
        _items.remove(item);
        if (_total > 0) _total--;
      });
    } else {
      setState(() {});
    }
  }

  void _onRoomSelected(String? roomId) {
    setState(() => _roomId = roomId);
    _reload();
  }

  void _setParticipated(PollParticipationFilter v) {
    if (v == _participated) return;
    setState(() => _participated = v);
    _reload();
  }

  void _setExcludeClosed(bool v) {
    if (v == _excludeClosed) return;
    setState(() => _excludeClosed = v);
    _reload();
  }

  void _setSort(PollSort v) {
    if (v == _sort) return;
    setState(() => _sort = v);
    _reload();
  }

  // ---- 그리기 ----

  /// 목록 아래쪽 옅은 회색 바탕 — 그 위에 [_cardColor] 카드가 떠 보인다(할 일 패널과 같은 색).
  static Color _listBackground(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? theme.colorScheme.surfaceContainerLow
        : theme.colorScheme.surfaceContainer;
  }

  /// 투표 카드 바탕 — 밝은 테마는 패널 바탕(surface)과 같은 흰색.
  static Color _cardColor(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? theme.colorScheme.surfaceContainerHigh
        : theme.colorScheme.surface;
  }

  /// 가로 전체 `+ 투표 만들기` — 할 일 패널의 `+ 할 일 생성`과 같은 옅은 회색 둥근 단추.
  Widget _createButton(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: PanelCreateButton(
        key: const ValueKey('polls-create'),
        label: '투표 만들기',
        onPressed: _create,
      ),
    );
  }

  /// 대화방 필터에서 방을 고르지 않았을 때의 글자(할 일 패널과 같다).
  static const _allRoomsLabel = '참여한 대화방';

  /// 참여 여부 단추 글자 — 펼침 목록은 `전체 / 참여함 / 참여 안 함`이고, 전체일 때 단추만 무엇의 전체인지 보인다.
  String get _participationLabel => _participated == PollParticipationFilter.all
      ? '참여 여부'
      : _participated.label;

  /// 필터 줄 — 참여한 대화방, 그 오른쪽 참여 여부. 할 일 패널의 `참여한 대화방` · `나의 할 일`처럼 두 단추를 같은 폭으로
  /// 나누고, 넘치는 글자는 말줄임표로 줄인다.
  Widget _filterBar() {
    final room = RoomFilterButton(
      session: _session,
      selectedRoomId: _roomId,
      expand: true,
      allLabel: _allRoomsLabel,
      allOptionLabel: _allRoomsLabel,
      onSelected: _onRoomSelected,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        children: [
          Expanded(child: room),
          const SizedBox(width: 8),
          Expanded(child: _participationButton()),
        ],
      ),
    );
  }

  /// 작은 메뉴 항목 — 메시지 예약 패널의 정렬 메뉴와 같은 모양(작은 글씨·좁은 줄 간격·고른 것에 체크).
  Widget _menuItem({
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onPressed,
  }) {
    return MenuItemButton(
      key: key,
      onPressed: onPressed,
      style: const ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(140, CompactMenu.itemHeight)),
        padding: WidgetStatePropertyAll(CompactMenu.itemPadding),
        textStyle: WidgetStatePropertyAll(CompactMenu.textStyle),
      ),
      trailingIcon: selected
          ? const Icon(Icons.check, size: 16)
          : const SizedBox(width: 16),
      child: Text(label),
    );
  }

  /// 참여 여부 드롭다운(전체 / 참여함 / 참여 안 함) — 단추는 옆 대화방 단추([FilterDropdownButton])와 같은 테두리 단추,
  /// 펼침 메뉴는 메시지 예약 패널의 정렬과 같은 [MenuAnchor](바로 뜬다).
  Widget _participationButton() {
    return MenuAnchor(
      style: hoverMenuStyle(context),
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        for (final p in PollParticipationFilter.values)
          _menuItem(
            key: ValueKey('polls-participated-${p.name}'),
            label: p.label,
            selected: p == _participated,
            onPressed: () => _setParticipated(p),
          ),
      ],
      builder: (context, controller, _) => Semantics(
        expanded: controller.isOpen,
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const ValueKey('polls-participated'),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            // FilterDropdownButton과 같은 모양 — 아이콘 앞 여백 10, 내용은 왼쪽에 붙인다.
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsetsDirectional.fromSTEB(10, 0, 0, 0),
              alignment: Alignment.centerLeft,
            ),
            icon: Icon(
              controller.isOpen ? Icons.arrow_drop_up : Icons.arrow_drop_down,
            ),
            label: Text(
              _participationLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }

  /// 작은 글씨 줄 — 왼쪽 `마감된 투표 제외` 스위치(스위치 · 글자 — 글자를 눌러도 켜고 끈다, 할 일 패널의 `완료된 할 일
  /// 제외`와 같다), 오른쪽 끝 정렬.
  Widget _optionBar(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              // 글자와 스위치를 한 마디(켜짐/꺼짐)로 읽게 합친다.
              child: MergeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 작은 스위치 — 누르는 자리 여백을 빼야 모바일·PC에서 같은 크기로 줄어든다.
                    SizedBox(
                      height: 24,
                      child: FittedBox(
                        child: Switch(
                          key: const ValueKey('polls-exclude-closed'),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          value: _excludeClosed,
                          onChanged: _setExcludeClosed,
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Flexible(
                      child: InkWell(
                        key: const ValueKey('polls-exclude-closed-label'),
                        onTap: () => _setExcludeClosed(!_excludeClosed),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 6,
                          ),
                          child: Text(
                            '마감된 투표 제외',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _sortButton(context),
        ],
      ),
    );
  }

  /// 정렬(생성 순 / 기한 순) 단추 — 메시지 예약 패널의 정렬과 같은 작은 회색 글자와 [MenuAnchor] 메뉴.
  Widget _sortButton(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return MenuAnchor(
      style: hoverMenuStyle(context),
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        for (final s in PollSort.values)
          _menuItem(
            key: ValueKey('polls-sort-${s.name}'),
            label: s.label,
            selected: s == _sort,
            onPressed: () => _setSort(s),
          ),
      ],
      builder: (context, controller, _) => Semantics(
        expanded: controller.isOpen,
        child: Tooltip(
          message: '정렬',
          child: InkWell(
            key: const ValueKey('polls-sort'),
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.swap_vert, size: 16, color: hint),
                  const SizedBox(width: 2),
                  Text(
                    _sort.label,
                    style: theme.textTheme.labelMedium?.copyWith(color: hint),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _newPollLine(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      child: InkWell(
        key: const ValueKey('polls-new-notice'),
        onTap: _reload,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            children: [
              Icon(Icons.fiber_new, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '새 투표가 있습니다 · 새로고침',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              Icon(Icons.refresh, size: 18, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }

  /// `N개의 투표` — 지금 필터에 맞는 전체 개수(다음 쪽을 아직 안 받았어도 다 센다), 숫자는 굵게. 처음 받기 전에는 개수를
  /// 모르므로 같은 높이의 빈 줄만 둔다.
  Widget _countLine(BuildContext context) {
    final theme = Theme.of(context);
    const bold = TextStyle(fontWeight: FontWeight.w700);
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurface,
    );
    final Widget line;
    if (_loaded) {
      line = Text.rich(
        key: const ValueKey('panel-loaded-count'),
        TextSpan(
          children: [
            TextSpan(text: '$_total', style: bold),
            const TextSpan(text: '개의 투표'),
          ],
        ),
        style: style,
      );
    } else {
      line = ExcludeSemantics(
        child: Text.rich(
          key: const ValueKey('panel-count-pending'),
          const TextSpan(
            children: [
              TextSpan(text: ' ', style: bold),
              TextSpan(text: ' '),
            ],
          ),
          style: style,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: line,
    );
  }

  /// 투표 카드 — 흰 둥근 카드에 위 줄(대화방 종류 아이콘 + 이름, 오른쪽 "방으로 이동")과 채팅과 같은 [PollCard].
  Widget _card(BuildContext context, PollListItem item) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final room = _session.roomById(item.roomId);
    final roomName =
        room?.displayName(_session.userId ?? '') ?? item.roomName ?? '';
    return Material(
      key: ValueKey('polls-item-${item.message.id}'),
      color: _cardColor(context),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  iconForRoomType(room?.type ?? RoomType.topic),
                  size: 13,
                  color: hint,
                ),
                const SizedBox(width: 3),
                Expanded(
                  child: Text(
                    roomName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                ),
                TextButton(
                  key: ValueKey('polls-goto-${item.message.id}'),
                  onPressed: () => _openRoom(item),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    textStyle: theme.textTheme.labelMedium,
                  ),
                  child: const Text('방으로 이동'),
                ),
              ],
            ),
            // "방으로 이동"은 누르는 자리 여백만큼 오른쪽에 붙고, 구분선·투표 카드는 좌우 16으로 맞춘다.
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Divider(
                height: 1,
                color: theme.colorScheme.outlineVariant,
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: PollCard(
                session: _session,
                message: item.message,
                maxWidth: 520,
                onChanged: () => _onCardChanged(item),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 빈 목록 — 할 일 패널처럼 아이콘 · 문구 · 작은 안내.
  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.how_to_vote_outlined, size: 40, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(
              _filtered ? '조건에 맞는 투표가 없습니다.' : '등록된 투표가 없습니다.',
              key: const ValueKey('polls-empty'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 4),
            Text(
              _filtered ? '필터를 바꿔 보세요.' : '"투표 만들기"로 대화방에 첫 투표를 만들어 보세요.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _error!,
                key: const ValueKey('polls-error'),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _reload, child: const Text('다시 시도')),
          ],
        ),
      );
    }
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) return _empty(context);
    final footer = _hasMore || _loading ? 1 : 0;
    return RefreshIndicator(
      onRefresh: _reload,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < 320) _loadMore();
          return false;
        },
        child: ListView.separated(
          key: const ValueKey('polls-list'),
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          itemCount: _items.length + footer,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
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
                          key: const ValueKey('polls-more'),
                          onPressed: _loadMore,
                          child: const Text('더 보기'),
                        ),
                ),
              );
            }
            return _card(context, _items[i]);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SidePanelHeader(title: '투표', onClose: widget.onClose),
          const Divider(height: 1),
          _createButton(context),
          _filterBar(),
          _optionBar(context),
          if (_newPollNotice) _newPollLine(context),
          Expanded(
            child: ColoredBox(
              color: _listBackground(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _countLine(context),
                  Expanded(child: _body(context)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
