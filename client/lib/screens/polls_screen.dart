import 'dart:async';

import 'package:flutter/material.dart';

import '../models/message.dart';
import '../models/poll.dart';
import '../models/poll_list.dart';
import '../models/room.dart';
import '../services/panel_lists_api.dart';
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/home_shell_scope.dart';
import '../widgets/panel_filters.dart';
import '../widgets/poll_card.dart';
import '../widgets/side_panel_header.dart';
import 'poll_create_dialog.dart';

/// "투표" 패널 — 이 팀에서 내가 멤버인 방(비밀 대화 제외)의 투표를 한곳에 모아 보고, 그 자리에서 바로 투표한다.
/// 파일·즐겨찾기 패널과 같은 틀이다 — 위에서부터 헤더(`투표` + 닫기), `+ 투표 만들기` 단추, 필터 줄(참여 대화방 / 작성자 /
/// 기간), 상태 칩(전체 | 진행 중 | 마감)과 정렬, 참여 여부 칩(전체 | 참여함 | 참여 안 함), `"N"개가 로딩되었습니다.` 줄,
/// 투표 카드 목록(무한 스크롤). 카드는 채팅의 [PollCard]를 그대로 쓰고, 카드 위 줄의 "방으로 이동"을 누르면 그 방의 그 투표로 간다.
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

  String? _roomId; // null = 참여 대화방(전체)
  String? _creatorId; // null = 모든 멤버
  PollStatusFilter _status = PollStatusFilter.all;
  PollParticipationFilter _participated = PollParticipationFilter.all;
  PanelPeriod _period = const PanelPeriod();
  bool _newestFirst = true;

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
      _creatorId != null ||
      _status != PollStatusFilter.all ||
      _participated != PollParticipationFilter.all ||
      _period.preset != PeriodPreset.year;

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

  /// 팀을 바꾸면 방·작성자 필터가 이전 팀 기준이라 풀고 새 팀의 목록을 받는다.
  void _onSessionChanged() {
    final team = _session.currentTeam?.id;
    if (team == _teamId) return;
    _teamId = team;
    setState(() {
      _roomId = null;
      _creatorId = null;
    });
    _reload();
  }

  // ---- 받기 ----

  Future<PollListPage> _fetch({String? before}) => _session.api!.fetchPollList(
    teamId: _teamId!,
    roomId: _roomId,
    status: _status,
    creatorId: _creatorId,
    participated: _participated,
    since: _period.since(),
    until: _period.until,
    newestFirst: _newestFirst,
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
    setState(() {
      _roomId = roomId;
      _creatorId = null; // 이전 방 멤버 기준으로 골랐던 작성자는 새 범위에 안 맞을 수 있다.
    });
    _reload();
  }

  // ---- 그리기 ----

  Widget _chips<T>({
    required Key listKey,
    required String prefix,
    required List<T> values,
    required T selected,
    required String Function(T) label,
    required ValueChanged<T> onSelected,
  }) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        key: listKey,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final v = values[i];
          return ChoiceChip(
            key: ValueKey('$prefix-${(v as Enum).name}'),
            label: Text(label(v)),
            selected: v == selected,
            // 칩이 두 줄이라 폭 360에서도 한 줄에 다 들어가게 선택 표시(체크)는 칠한 바탕으로만 한다.
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => onSelected(v),
          );
        },
      ),
    );
  }

  Widget _participationRow(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          Text('참여 여부', style: TextStyle(fontSize: 12.5, color: hint)),
          const SizedBox(width: 8),
          Expanded(
            child: _chips<PollParticipationFilter>(
              listKey: const ValueKey('polls-participated'),
              prefix: 'polls-participated',
              values: PollParticipationFilter.values,
              selected: _participated,
              label: (v) => v.label,
              onSelected: (v) {
                setState(() => _participated = v);
                _reload();
              },
            ),
          ),
        ],
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

  Widget _countLine(BuildContext context) => PanelResultLine(
    summary: Text(
      '"$_total"개가 로딩되었습니다.',
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

  Widget _card(BuildContext context, PollListItem item) {
    final theme = Theme.of(context);
    return Container(
      key: ValueKey('polls-item-${item.message.id}'),
      padding: const EdgeInsets.fromLTRB(14, 4, 6, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
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
                key: ValueKey('polls-goto-${item.message.id}'),
                onPressed: () => _openRoom(item),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('방으로 이동'),
              ),
            ],
          ),
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
    );
  }

  Widget _body(BuildContext context) {
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, key: const ValueKey('polls-error')),
            TextButton(onPressed: _reload, child: const Text('다시 시도')),
          ],
        ),
      );
    }
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return _message(
        context,
        _filtered
            ? '조건에 맞는 투표가 없습니다.'
            : '등록된 투표가 없습니다.\n위의 "투표 만들기"로 첫 투표를 만들어 보세요.',
        const ValueKey('polls-empty'),
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
          key: const ValueKey('polls-list'),
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
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
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SidePanelHeader(title: '투표', onClose: widget.onClose),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: FilledButton.icon(
              key: const ValueKey('polls-create'),
              onPressed: _create,
              icon: const Icon(Icons.add, size: 20),
              label: const Text('투표 만들기'),
            ),
          ),
          PanelFilterBar(
            searchHint: '',
            showSearch: false,
            onQueryChanged: (_) {},
            session: _session,
            roomId: _roomId,
            onRoomChanged: _onRoomSelected,
            members: memberChoicesFor(_session, _roomId),
            senderId: _creatorId,
            onSenderChanged: (v) {
              setState(() => _creatorId = v);
              _reload();
            },
            period: _period,
            onPeriodChanged: (v) {
              setState(() => _period = v);
              _reload();
            },
            leading: _chips<PollStatusFilter>(
              listKey: const ValueKey('polls-status'),
              prefix: 'polls-status',
              values: PollStatusFilter.values,
              selected: _status,
              label: (v) => v.label,
              onSelected: (v) {
                setState(() => _status = v);
                _reload();
              },
            ),
            leadingExpands: true,
            newestFirst: _newestFirst,
            onSortChanged: (v) {
              setState(() => _newestFirst = v);
              _reload();
            },
          ),
          _participationRow(context),
          if (_newPollNotice) _newPollLine(context),
          _countLine(context),
          const Divider(height: 1),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }
}
