import 'dart:async';

import 'package:flutter/material.dart';

import '../models/room.dart';
import '../screens/schedule_message_dialog.dart';
import '../services/api_client.dart' show ApiException;
import '../services/session.dart';
import '../services/time_format.dart';
import 'app_toast.dart';
import 'compact_menu.dart';
import 'filter_dropdown.dart';
import 'home_shell_scope.dart';
import 'hover_toolbar.dart'
    show hoverMenuDivider, hoverMenuItem, hoverMenuStyle;

/// 예약 목록의 상태 필터 — 보내는 중(잠깐)인 예약은 '예약됨'에 든다.
enum ScheduledStatusFilter {
  all('모든 예약'),
  scheduled('예약됨'),
  failed('발송 실패');

  final String label;
  const ScheduledStatusFilter(this.label);

  bool accepts(ScheduledMessage m) => switch (this) {
    ScheduledStatusFilter.all => true,
    ScheduledStatusFilter.scheduled => !m.isFailed,
    ScheduledStatusFilter.failed => m.isFailed,
  };
}

/// 예약 목록의 정렬 — 어느 쪽이든 발송 실패가 먼저다(고쳐야 할 것이 위에 보이게).
enum ScheduledSort {
  /// 보낼 시각이 이른 순(서버 GET·Session 목록과 같은 순서).
  sendAt('발송 시간 순'),

  /// 최근에 만든 순.
  created('생성 순');

  final String label;
  const ScheduledSort(this.label);
}

/// [all]에서 [roomId](null이면 모든 방)·[status]에 맞는 예약만 [sort] 순서로.
List<ScheduledMessage> filterScheduledMessages(
  Iterable<ScheduledMessage> all, {
  String? roomId,
  ScheduledStatusFilter status = ScheduledStatusFilter.all,
  ScheduledSort sort = ScheduledSort.sendAt,
}) {
  final list = [
    for (final m in all)
      if ((roomId == null || m.roomId == roomId) && status.accepts(m)) m,
  ];
  switch (sort) {
    case ScheduledSort.sendAt:
      list.sort(compareScheduledMessages);
    case ScheduledSort.created:
      list.sort((a, b) {
        if (a.isFailed != b.isFailed) return a.isFailed ? -1 : 1;
        final byCreated = b.createdAt.compareTo(a.createdAt);
        return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
      });
  }
  return list;
}

/// 메시지 예약 패널(side_panels.dart의 'scheduled') — [메뉴] > 생성 > 메시지 예약. 할 일 패널과 같은 짜임이다: 위에서부터
/// 머리(`메시지 예약`, 오른쪽 끝 ✕), 가로 전체 `+ 메시지 예약`(만들기 창 — PC는 대화상자, 모바일은 전체 화면), 필터 줄
/// (참여한 대화방 · 모든 예약 / 예약됨 / 발송 실패), 정렬(발송 시간 순 / 생성 순)과 오른쪽 `예약 N/30`, 그 아래 옅은 회색
/// 바탕에 `N개의 예약 메시지`와 카드 목록. 카드를 누르면 수정 창이 열리고, ⋯로 수정·지금 보내기·예약 취소(발송 실패면
/// 수정·삭제)를 한다.
///
/// 목록은 Session.scheduledMessages(지금 팀의 내 예약)를 그대로 보여 준다 — 열 때 서버에서 새로 받고, 그 뒤로는 Session이
/// 소켓 scheduled:changed / sent / failed로 맞춰 둔 목록이 그 자리에서 바뀐다(보내진 예약은 사라지고, 못 보낸 예약은
/// 사유와 함께 '발송 실패'). 팀을 바꾸면 필터를 풀고 새 팀 목록을 받는다.
class ScheduledPanel extends StatefulWidget {
  final Session session;
  final VoidCallback? onClose;

  const ScheduledPanel({super.key, required this.session, this.onClose});

  @override
  State<ScheduledPanel> createState() => _ScheduledPanelState();
}

class _ScheduledPanelState extends State<ScheduledPanel> {
  final _scroll = ScrollController();
  String? _roomId;
  ScheduledStatusFilter _status = ScheduledStatusFilter.all;
  ScheduledSort _sort = ScheduledSort.sendAt;
  bool _loading = true;
  Object? _loadError;
  late String? _teamId = widget.session.currentTeam?.id;

  Session get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
    // 열 때마다 서버에서 새로 받는다(다른 기기에서 바꿨거나 알림을 놓쳤을 수 있다).
    unawaited(_fetch());
  }

  @override
  void didUpdateWidget(covariant ScheduledPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      oldWidget.session.removeListener(_onSessionChanged);
      widget.session.addListener(_onSessionChanged);
      // 다른 세션(다시 로그인)이면 처음 연 것처럼 필터를 풀고 새로 받는다.
      _teamId = widget.session.currentTeam?.id;
      _roomId = null;
      _loading = true;
      _loadError = null;
      unawaited(_fetch());
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    _scroll.dispose();
    super.dispose();
  }

  /// 예약 목록·방 이름이 바뀌면 다시 그린다. 팀이 바뀌면 그 팀의 대화방 필터는 의미가 없으니 풀고 새로 받는다.
  void _onSessionChanged() {
    if (!mounted) return;
    final teamId = _session.currentTeam?.id;
    if (teamId != _teamId) {
      _teamId = teamId;
      setState(() {
        _roomId = null;
        _loading = true;
        _loadError = null;
      });
      unawaited(_fetch());
      return;
    }
    setState(() {});
  }

  void _retry() {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    unawaited(_fetch());
  }

  Future<void> _fetch() async {
    try {
      await _session.loadScheduledMessages();
    } catch (e) {
      if (!mounted) return;
      // 이미 받아 둔 목록이 있으면 그대로 보여주고 알리기만 한다.
      if (_session.scheduledMessagesLoaded) {
        showAppToast(context, '예약 목록을 새로 받지 못했습니다: $e');
      } else {
        setState(() => _loadError = e);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _atLimit =>
      _session.scheduledMessages.length >= scheduledMessageMaxCount;

  // ---- 동작 ----

  /// `+ 메시지 예약` — 대화방 칸은 필터로 고른 방, 아니면 지금 연 방(PC)으로 미리 골라 둔다(예약할 수 있는 방일 때만).
  Future<void> _create() async {
    final shell = HomeShellScope.maybeOf(context);
    Room? pick(String? id) {
      if (id == null) return null;
      final room = _session.roomById(id);
      return room != null && canScheduleIn(_session, room) ? room : null;
    }

    final room =
        pick(_roomId) ?? pick(shell?.panelRoom?.id ?? shell?.currentRoomId);
    await showScheduleMessageEditor(context, _session, room: room);
  }

  Future<void> _edit(ScheduledMessage m) async {
    await showScheduleMessageEditor(context, _session, editing: m);
  }

  Future<bool> _confirm({
    required String title,
    required String content,
    required String action,
    bool destructive = false,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('닫기'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              action,
              style: destructive
                  ? const TextStyle(color: Colors.redAccent)
                  : null,
            ),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// 묻는 사이 목록에서 사라졌는지 — 예약 시각이 되어 보내졌거나 다른 기기에서 취소했으면 더 할 일이 없다.
  bool _gone(ScheduledMessage m) =>
      _session.scheduledMessagesLoaded &&
      _session.scheduledMessageById(m.id) == null;

  Future<void> _sendNow(ScheduledMessage m) async {
    final room = _session.scheduledRoomName(m);
    final ok = await _confirm(
      title: '지금 보내기',
      content: "예약 시간을 기다리지 않고 '$room'에 지금 바로 보낼까요?",
      action: '보내기',
    );
    if (!ok || !mounted || _gone(m)) return;
    try {
      // 보내지면 루트 화면이 "예약 메시지를 보냈습니다" 토스트를 띄운다(여기서는 따로 알리지 않는다).
      await _session.sendScheduledMessageNow(m.id);
    } catch (e) {
      if (mounted) {
        showAppToast(
          context,
          e is ApiException ? e.message : '보내지 못했습니다: $e',
          duration: const Duration(seconds: 3),
        );
      }
    }
  }

  Future<void> _cancel(ScheduledMessage m) async {
    final failed = m.isFailed;
    final ok = await _confirm(
      title: failed ? '예약 메시지 삭제' : '예약 취소',
      content: failed
          ? '보내지 못한 예약 메시지를 삭제할까요?'
          : '${formatScheduleTime(m.sendAt)}에 보낼 예약을 취소할까요? 취소한 예약은 되돌릴 수 없습니다.',
      action: failed ? '삭제' : '예약 취소',
      destructive: true,
    );
    if (!ok || !mounted || _gone(m)) return;
    try {
      await _session.cancelScheduledMessage(m.id);
      if (mounted) {
        showAppToast(context, failed ? '예약 메시지를 삭제했습니다.' : '예약을 취소했습니다.');
      }
    } catch (e) {
      if (mounted) {
        showAppToast(context, e is ApiException ? e.message : '취소하지 못했습니다: $e');
      }
    }
  }

  // ---- 화면 ----

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context),
          const Divider(height: 1),
          _createButton(context),
          _filterBar(),
          _optionBar(context),
          Expanded(
            child: ColoredBox(
              color: scheduledListBackgroundColor(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _countLine(context),
                  Expanded(child: _content(context)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 머리 — 다른 패널 머리(SidePanelHeader)와 같은 높이.
  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '메시지 예약',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          IconButton(
            key: const ValueKey('scheduled-panel-close'),
            icon: const Icon(Icons.close),
            tooltip: '닫기',
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  /// 가로 전체 `+ 메시지 예약` — 옅은 회색 둥근 단추(할 일 생성과 같은 모양). 30건이 차면 막고 까닭을 띄운다.
  Widget _createButton(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final button = FilledButton.icon(
      key: const ValueKey('scheduled-panel-create'),
      onPressed: _atLimit ? null : _create,
      style: FilledButton.styleFrom(
        backgroundColor: scheme.surfaceContainerHighest,
        foregroundColor: scheme.onSurface,
        minimumSize: const Size.fromHeight(44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: theme.textTheme.labelLarge?.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      icon: const Icon(Icons.add, size: 20),
      label: const Text('메시지 예약', maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: _atLimit
          ? Tooltip(
              message: '예약 메시지는 최대 $scheduledMessageMaxCount건까지 만들 수 있습니다.',
              child: button,
            )
          : button,
    );
  }

  /// 대화방 필터에서 방을 고르지 않았을 때의 글자(할 일 패널과 같다).
  static const _allRoomsLabel = '참여한 대화방';

  /// 상태 드롭다운 펼침 패널 폭.
  static const _statusPanelWidth = 180.0;

  /// 필터 줄 — 참여한 대화방, 상태(모든 예약 / 예약됨 / 발송 실패).
  Widget _filterBar() {
    final room = RoomFilterButton(
      key: const ValueKey('scheduled-panel-room'),
      session: _session,
      selectedRoomId: _roomId,
      expand: true,
      allLabel: _allRoomsLabel,
      allOptionLabel: _allRoomsLabel,
      onSelected: (id) => setState(() => _roomId = id),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        children: [
          Expanded(child: room),
          const SizedBox(width: 8),
          Expanded(child: _statusButton()),
        ],
      ),
    );
  }

  Widget _statusButton() {
    // 펼침 목록의 각 줄 오른쪽에 지금 고른 대화방 기준 개수를 작게 붙인다.
    int count(ScheduledStatusFilter s) => filterScheduledMessages(
      _session.scheduledMessages,
      roomId: _roomId,
      status: s,
    ).length;
    return FilterDropdownButton(
      key: const ValueKey('scheduled-panel-status'),
      label: _status.label,
      expand: true,
      alignEnd: true,
      panelWidth: _statusPanelWidth,
      panelBuilder: (close) => FilterPanelShell(
        width: _statusPanelWidth,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          children: [
            for (final s in ScheduledStatusFilter.values)
              Builder(
                builder: (context) {
                  final theme = Theme.of(context);
                  final n = _session.scheduledMessagesLoaded ? count(s) : null;
                  return ListTile(
                    key: ValueKey('scheduled-status-${s.name}'),
                    dense: true,
                    title: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: s.label),
                          if (n != null)
                            TextSpan(
                              text: '  $n',
                              style: TextStyle(
                                color:
                                    s == ScheduledStatusFilter.failed && n > 0
                                    ? theme.colorScheme.error
                                    : theme.hintColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                    ),
                    trailing: s == _status
                        ? const Icon(Icons.check, size: 18)
                        : null,
                    onTap: () {
                      setState(() => _status = s);
                      close();
                    },
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 왼쪽 정렬 단추, 오른쪽 `예약 N/30`(한 사람이 한 팀에 둘 수 있는 예약 수).
  Widget _optionBar(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final used = _session.scheduledMessages.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 16, 6),
      child: Row(
        children: [
          _sortButton(context),
          const Spacer(),
          if (_session.scheduledMessagesLoaded)
            Tooltip(
              message: '예약 메시지는 최대 $scheduledMessageMaxCount건까지 만들 수 있습니다.',
              child: Text.rich(
                key: const ValueKey('scheduled-panel-quota'),
                TextSpan(
                  children: [
                    const TextSpan(text: '예약 '),
                    TextSpan(
                      text: '$used',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _atLimit
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    TextSpan(text: '/$scheduledMessageMaxCount'),
                  ],
                ),
                style: theme.textTheme.labelMedium?.copyWith(color: hint),
              ),
            ),
        ],
      ),
    );
  }

  /// 정렬(발송 시간 순 / 생성 순) 단추 — 할 일 패널의 정렬과 같은 작은 회색 글자.
  Widget _sortButton(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return MenuAnchor(
      style: hoverMenuStyle(context),
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        for (final s in ScheduledSort.values)
          MenuItemButton(
            key: ValueKey('scheduled-sort-${s.name}'),
            onPressed: () => setState(() => _sort = s),
            style: const ButtonStyle(
              minimumSize: WidgetStatePropertyAll(
                Size(140, CompactMenu.itemHeight),
              ),
              padding: WidgetStatePropertyAll(CompactMenu.itemPadding),
              textStyle: WidgetStatePropertyAll(CompactMenu.textStyle),
            ),
            trailingIcon: s == _sort
                ? const Icon(Icons.check, size: 16)
                : const SizedBox(width: 16),
            child: Text(s.label),
          ),
      ],
      builder: (context, controller, _) => Semantics(
        expanded: controller.isOpen,
        child: Tooltip(
          message: '정렬',
          child: InkWell(
            key: const ValueKey('scheduled-panel-sort'),
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

  List<ScheduledMessage> get _visible => filterScheduledMessages(
    _session.scheduledMessages,
    roomId: _roomId,
    status: _status,
    sort: _sort,
  );

  /// `N개의 예약 메시지` — 지금 필터에 맞는 개수(숫자는 굵게). 받기 전에는 같은 높이의 빈 줄.
  Widget _countLine(BuildContext context) {
    final theme = Theme.of(context);
    const bold = TextStyle(fontWeight: FontWeight.w700);
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurface,
    );
    final Widget line;
    if (_session.scheduledMessagesLoaded) {
      line = Text.rich(
        key: const ValueKey('scheduled-panel-count'),
        TextSpan(
          children: [
            TextSpan(text: '${_visible.length}', style: bold),
            const TextSpan(text: '개의 예약 메시지'),
          ],
        ),
        style: style,
      );
    } else {
      line = ExcludeSemantics(
        child: Text.rich(
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

  Widget _content(BuildContext context) {
    if (!_session.scheduledMessagesLoaded) {
      if (_loadError != null && !_loading) return _error(context);
      return const Center(child: CircularProgressIndicator());
    }
    final items = _visible;
    if (items.isEmpty) return _empty(context);
    return ListView.separated(
      key: const ValueKey('scheduled-panel-list'),
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      itemCount: items.length,
      separatorBuilder: (context, i) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final m = items[i];
        return ScheduledMessageCard(
          key: ValueKey('scheduled-panel-card-${m.id}'),
          session: _session,
          message: m,
          onEdit: () => _edit(m),
          onSendNow: () => _sendNow(m),
          onCancel: () => _cancel(m),
        );
      },
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _roomId != null;
    final text = switch (_status) {
      ScheduledStatusFilter.failed => '발송에 실패한 예약 메시지가 없어요.',
      _ when filtered => '이 대화방에 예약된 메시지가 없어요.',
      _ => '예약된 메시지가 없어요.',
    };
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.schedule_send_outlined,
              size: 40,
              color: theme.hintColor,
            ),
            const SizedBox(height: 12),
            Text(
              text,
              key: const ValueKey('scheduled-panel-empty'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 4),
            Text(
              '"메시지 예약"으로 원하는 시간에 보낼 메시지를 미리 써 두세요.\n'
              '15분 단위로 최대 $scheduledMaxDaysAhead일 뒤까지 예약할 수 있어요.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _error(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 40, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(
              '예약 목록을 불러오지 못했습니다.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 4),
            Text(
              '연결 상태를 확인한 뒤 다시 시도해 주세요.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              key: const ValueKey('scheduled-panel-retry'),
              onPressed: _retry,
              child: const Text('다시 시도'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 예약 목록 아래쪽의 옅은 회색 바탕 — 그 위에 [scheduledCardColor] 카드가 떠 보인다(할 일 패널과 같은 색).
Color scheduledListBackgroundColor(BuildContext context) {
  final theme = Theme.of(context);
  return theme.brightness == Brightness.dark
      ? theme.colorScheme.surfaceContainerLow
      : theme.colorScheme.surfaceContainer;
}

/// 예약 카드 바탕 — 밝은 테마는 패널 바탕(surface)과 같은 흰색.
Color scheduledCardColor(BuildContext context) {
  final theme = Theme.of(context);
  return theme.brightness == Brightness.dark
      ? theme.colorScheme.surfaceContainerHigh
      : theme.colorScheme.surface;
}

/// 예약 한 건 카드 — 첫 줄 `발송 예정 : 10월 5일 (월) 오전 9:00`(발송 실패면 `발송 예정 :` 대신 빨간 `발송 실패` 표)과
/// 오른쪽 끝 ⋯(보내는 중이면 작은 진행 표시), 대화방(종류 아이콘 + 이름)·첨부 수 한 줄(작게), 두 줄 미리보기(게시글이면 `게시글` 표 + 제목),
/// 발송 실패면 그 아래 사유. 누르면 [onEdit](보내는 중이면 막는다).
class ScheduledMessageCard extends StatelessWidget {
  final Session session;
  final ScheduledMessage message;
  final VoidCallback onEdit;
  final VoidCallback onSendNow;
  final VoidCallback onCancel;

  const ScheduledMessageCard({
    super.key,
    required this.session,
    required this.message,
    required this.onEdit,
    required this.onSendNow,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final m = message;
    final failed = m.isFailed;
    return Material(
      color: scheduledCardColor(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: failed
            ? BorderSide(color: scheme.error.withValues(alpha: 0.45))
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: m.isSending ? null : onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 6, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _topLine(context),
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _roomLine(context),
                    const SizedBox(height: 8),
                    _preview(context),
                    if (failed) ...[
                      const SizedBox(height: 8),
                      _failReason(context),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// `발송 예정 : 시각`(발송 실패면 `[발송 실패] 시각`) + ⋯(보내는 중이면 진행 표시).
  Widget _topLine(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final m = message;
    final failed = m.isFailed;
    return Row(
      children: [
        // 좁은 폭(휴대폰 360)에서 해를 넘긴 긴 날짜("2027년 1월 4일 (월) 오전 9:00")면 시각부터 줄인다.
        Expanded(
          child: Row(
            children: [
              // 발송 실패는 `발송 예정 :` 자리에 빨간 표를 둔다(좁은 폭에서도 시각이 다 보이게).
              if (failed) ...[
                _Badge(
                  key: ValueKey('scheduled-panel-failed-${m.id}'),
                  label: '발송 실패',
                  color: scheme.error,
                ),
                const SizedBox(width: 8),
              ] else
                Text(
                  '발송 예정 : ',
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              Flexible(
                child: Text(
                  formatScheduleTime(m.sendAt),
                  key: ValueKey('scheduled-panel-time-${m.id}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: failed ? theme.hintColor : scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (m.isSending)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 10, 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 6),
                Text(
                  '보내는 중',
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ],
            ),
          )
        else
          _MoreButton(
            message: m,
            onEdit: onEdit,
            onSendNow: onSendNow,
            onCancel: onCancel,
          ),
      ],
    );
  }

  /// 작은 회색 한 줄 — 대화방(종류 아이콘 + 지금 이름) · 📎 첨부 수.
  Widget _roomLine(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final style = TextStyle(fontSize: 12.5, color: hint);
    final m = message;
    final roomId = m.roomId;
    final room = roomId == null ? null : session.roomById(roomId);
    final icon = room == null
        ? Icons.speaker_notes_off_outlined
        : room.isBoard
        ? Icons.dashboard_outlined
        : iconForRoomType(room.type);
    final attachments = m.attachments.length;
    return Row(
      children: [
        Icon(icon, size: 14, color: hint),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            session.scheduledRoomName(m),
            key: ValueKey('scheduled-panel-room-${m.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        if (attachments > 0) ...[
          Text(' · ', style: style),
          Icon(Icons.attach_file, size: 14, color: hint),
          Text(
            '$attachments',
            key: ValueKey('scheduled-panel-clips-${m.id}'),
            style: style,
          ),
        ],
      ],
    );
  }

  /// 두 줄 미리보기 — 게시글 예약은 `게시글` 표 + 제목, 그 밖엔 메시지(줄바꿈은 한 칸으로).
  Widget _preview(BuildContext context) {
    final theme = Theme.of(context);
    final m = message;
    final text = m.preview.trim().replaceAll(RegExp(r'\s*\n\s*'), ' ');
    return Text.rich(
      TextSpan(
        children: [
          if (m.isPost)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _Badge(label: '게시글', color: theme.colorScheme.primary),
              ),
            ),
          TextSpan(
            text: text,
            style: m.isPost
                ? const TextStyle(fontWeight: FontWeight.w700)
                : null,
          ),
        ],
      ),
      key: ValueKey('scheduled-panel-preview-${m.id}'),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 14,
        height: 1.45,
        color: theme.colorScheme.onSurface,
      ),
    );
  }

  Widget _failReason(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(Icons.error_outline, size: 15, color: error),
        ),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            message.failReason ?? '보내지 못했습니다.',
            key: ValueKey('scheduled-panel-reason-${message.id}'),
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: error,
            ),
          ),
        ),
      ],
    );
  }
}

/// 작은 둥근 표(`발송 실패`·`게시글`).
class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// 카드의 ⋯ — 예약됨: 수정 / 지금 보내기 / 예약 취소. 발송 실패: 수정(고쳐서 다시 예약) / 삭제.
class _MoreButton extends StatelessWidget {
  final ScheduledMessage message;
  final VoidCallback onEdit;
  final VoidCallback onSendNow;
  final VoidCallback onCancel;
  const _MoreButton({
    required this.message,
    required this.onEdit,
    required this.onSendNow,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final failed = message.isFailed;
    return MenuAnchor(
      style: hoverMenuStyle(context),
      menuChildren: [
        hoverMenuItem(
          icon: Icons.edit_outlined,
          label: failed ? '수정해서 다시 예약' : '수정',
          onPressed: onEdit,
        ),
        if (!failed)
          hoverMenuItem(
            icon: Icons.send_outlined,
            label: '지금 보내기',
            onPressed: onSendNow,
          ),
        hoverMenuDivider(),
        hoverMenuItem(
          icon: failed ? Icons.delete_outline : Icons.event_busy_outlined,
          label: failed ? '삭제' : '예약 취소',
          color: Colors.redAccent,
          onPressed: onCancel,
        ),
      ],
      builder: (context, controller, _) => IconButton(
        key: ValueKey('scheduled-panel-more-${message.id}'),
        icon: const Icon(Icons.more_horiz, size: 20),
        tooltip: '더보기',
        visualDensity: VisualDensity.compact,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}
