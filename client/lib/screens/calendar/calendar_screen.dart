import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/calendar.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/calendar_controller.dart';
import '../../services/calendar_layout.dart';
import '../../services/calendar_move.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/date_picker_popup.dart';
import '../../widgets/home_shell_scope.dart';
import '../home_screen.dart' show wideBreakpoint;
import 'calendar_common.dart';
import 'calendar_event_widgets.dart';
import 'calendar_list_panel.dart';
import 'calendar_month_view.dart';
import 'calendar_search_view.dart';
import 'calendar_time_grid.dart';
import 'event_detail.dart';
import 'event_editor.dart';
import 'management/calendar_management.dart';
import '../../l10n/tr.dart';

/// 모바일에서 캘린더를 전체 화면으로 연다(방 목록 위쪽 캘린더 버튼).
Future<void> openCalendarScreen(BuildContext context, Session session) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => CalendarScreen(session: session)),
  );
}

/// 캘린더 화면. 보기 4가지(월간·주간·일간·목록), 오늘·이전·다음·날짜 선택, 캘린더 목록(체크박스로
/// 숨기기), 일정 만들기/상세로 이어진다.
///
/// 넓은 창은 왼쪽에 캘린더 목록, 오른쪽에 툴바+본문이다([embedded]면 데스크톱 홈 안에 끼워 넣는 모양이라
/// 자체 앱바가 없다). 좁은 창(모바일)은 월간 격자 아래에 선택한 날의 일정 목록을 보여 주고, 캘린더
/// 목록은 오른쪽 서랍이다. 지금 보고 있는 팀(session.currentTeam)을 따른다.
class CalendarScreen extends StatefulWidget {
  final Session session;

  /// 테스트에서 가짜 API를 끼운 컨트롤러를 넘긴다. 기본은 세션의 것.
  final CalendarController? controller;

  /// 관리 대화상자 훅. 기본은 [CalendarManagementHooks.current], 그것도 없으면 세션에 연결한 기본 관리 훅.
  final CalendarManagementHooks? hooks;
  final bool embedded;

  /// 테스트용 "지금".
  final DateTime? now;

  const CalendarScreen({
    super.key,
    required this.session,
    this.controller,
    this.hooks,
    this.embedded = false,
    this.now,
  });

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late final CalendarController _c =
      widget.controller ?? widget.session.calendar;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  // PC 검색창: 결과 패널을 검색창 아래에 붙이고(LayerLink), 바깥을 누르면 닫는다.
  final _searchLink = LayerLink();
  final _searchGroup = Object();
  bool _searchOpen = false;

  CalendarViewMode _mode = CalendarViewMode.month;
  late DateTime _focused;

  /// 모바일 월간에서 눌러 고른 날(아래 목록의 날짜).
  late DateTime _selected;
  String? _teamId;

  DateTime get _today => dateOnly(widget.now ?? DateTime.now());
  late final CalendarManagementHooks _defaultHooks =
      buildCalendarManagementHooks(widget.session);
  CalendarManagementHooks get _hooks =>
      widget.hooks ?? CalendarManagementHooks.current ?? _defaultHooks;

  @override
  void initState() {
    super.initState();
    _focused = _today;
    _selected = _today;
    widget.session.addListener(_syncTeam);
    _teamId = widget.session.currentTeam?.id;
    _watch();
    _c.setTeam(_teamId);
  }

  @override
  void dispose() {
    widget.session.removeListener(_syncTeam);
    _c.unwatch();
    super.dispose();
  }

  /// 팀을 바꾸면(전환 팝업) 그 팀의 캘린더로 갈아탄다.
  void _syncTeam() {
    final id = widget.session.currentTeam?.id;
    if (id == _teamId) return;
    _teamId = id;
    _c.setTeam(id);
  }

  /// 지금 보기가 그리는 날짜 범위 [from, to).
  ({DateTime from, DateTime to}) get _range {
    switch (_mode) {
      case CalendarViewMode.month:
        return monthGridRange(_focused);
      case CalendarViewMode.week:
        final start = weekStartOf(_focused);
        return (from: start, to: addDays(start, 7));
      case CalendarViewMode.day:
        return (from: _focused, to: addDays(_focused, 1));
      case CalendarViewMode.list:
        final first = monthStartOf(_focused);
        return (from: first, to: DateTime(first.year, first.month + 1, 1));
    }
  }

  void _watch() => _c.watch(_range.from, _range.to);

  void _setState(VoidCallback fn) {
    setState(fn);
    _watch();
  }

  void _goToday() => _setState(() {
    _focused = _today;
    _selected = _today;
  });

  void _shift(int dir) => _setState(() {
    switch (_mode) {
      case CalendarViewMode.month:
      case CalendarViewMode.list:
        final lastDay = DateTime(
          _focused.year,
          _focused.month + dir + 1,
          0,
        ).day;
        _focused = DateTime(
          _focused.year,
          _focused.month + dir,
          _focused.day > lastDay ? lastDay : _focused.day,
        );
      case CalendarViewMode.week:
        _focused = addDays(_focused, 7 * dir);
      case CalendarViewMode.day:
        _focused = addDays(_focused, dir);
    }
    _selected = _focused;
  });

  Future<void> _pickDate() async {
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Center(
          child: DatePickerPopup(
            initialMonth: _focused,
            selectedDate: _focused,
            onClose: () => Navigator.of(dialogContext).pop(),
            onDateSelected: (d) => Navigator.of(dialogContext).pop(d),
          ),
        ),
      ),
    );
    if (picked == null) return;
    _setState(() {
      _focused = dateOnly(picked);
      _selected = _focused;
    });
  }

  Future<void> _createOn(DateTime start) =>
      showEventEditor(context, widget.session, _c, initialStart: start);

  void _openEvent(EventOccurrence e) => showEventDetail(
    context,
    session: widget.session,
    controller: _c,
    event: e,
  );

  String _calendarName(EventOccurrence e) =>
      _c.calendarById(e.calendarId)?.name ?? '';

  /// 일정을 끌어다 놓았다 — 서버에 저장하고(컨트롤러가 낙관적으로 화면을 바꾼다) 실패하면 원위치 + 토스트.
  Future<void> _moveEvent(EventOccurrence event, EventMove move) async {
    try {
      await _c.moveEvent(event, move);
    } catch (e) {
      if (!mounted) return;
      showAppToast(
        context,
        e is ApiException ? trServer(e.message) : tr('일정을 옮기지 못했습니다.'),
      );
    }
  }

  // ---- 검색 ----

  /// 검색 결과의 일정 상세 — 설명 같은 전체 내용을 위해 서버에서 다시 읽고, 못 읽으면 결과의 요약으로 연다.
  Future<void> _openSearchItem(CalendarSearchItem item) async {
    var event = item.toOccurrence();
    try {
      event = await _c.fetchEvent(item.eventId);
    } catch (_) {
      // 결과에 담긴 요약으로 연다.
    }
    if (!mounted) return;
    _openEvent(event);
  }

  /// "이동" — 현재 보기를 유지한 채 그 일정이 등록된 날짜로 캘린더를 옮긴다.
  void _jumpToDay(DateTime day) {
    _setState(() {
      _focused = dateOnly(day);
      _selected = _focused;
    });
  }

  void _moveToSearchItem(CalendarSearchItem item) {
    setState(() => _searchOpen = false);
    _jumpToDay(item.firstDay);
  }

  Future<void> _openSearchScreen() async {
    final day = await Navigator.of(context).push<DateTime>(
      MaterialPageRoute(
        builder: (_) =>
            CalendarSearchScreen(controller: _c, onOpen: _openSearchItem),
      ),
    );
    _c.search.clear();
    if (day != null && mounted) _jumpToDay(day);
  }

  Widget _buildSearchField() {
    return CompositedTransformTarget(
      link: _searchLink,
      child: TapRegion(
        groupId: _searchGroup,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                setState(() => _searchOpen = false),
          },
          child: CalendarSearchField(
            controller: _c.search,
            width: 200,
            onActivate: () {
              if (!_searchOpen) setState(() => _searchOpen = true);
            },
          ),
        ),
      ),
    );
  }

  /// 검색창 아래에 뜨는 결과 패널(검색어가 있고 열려 있을 때만).
  Widget _buildSearchPanel(BuildContext context) {
    return Positioned(
      left: 0,
      top: 0,
      child: ListenableBuilder(
        listenable: _c.search,
        builder: (context, _) => _searchOpen && _c.search.hasQuery
            ? _searchPanelBody(context)
            : const SizedBox.shrink(),
      ),
    );
  }

  Widget _searchPanelBody(BuildContext context) {
    return CompositedTransformFollower(
      link: _searchLink,
      targetAnchor: Alignment.bottomRight,
      followerAnchor: Alignment.topRight,
      offset: const Offset(0, 4),
      child: TapRegion(
        groupId: _searchGroup,
        onTapOutside: (_) => setState(() => _searchOpen = false),
        child: Material(
          key: const ValueKey('cal-search-panel'),
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440, maxHeight: 460),
            child: SizedBox(
              width: 440,
              child: CalendarSearchResults(
                controller: _c.search,
                onOpen: _openSearchItem,
                onMove: _moveToSearchItem,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showMore(DateTime day) {
    showDayEventsDialog(
      context,
      day: day,
      events: _c.eventsBetween(day, addDays(day, 1)),
      calendarNameOf: _calendarName,
      onEventTap: _openEvent,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = widget.embedded || constraints.maxWidth >= wideBreakpoint;
        return ListenableBuilder(
          listenable: _c,
          builder: (context, _) =>
              wide ? _buildWide(context) : _buildNarrow(context),
        );
      },
    );
  }

  // ---- 넓은 창 ----

  Widget _buildWide(BuildContext context) {
    final theme = Theme.of(context);
    final content = Row(
      children: [
        SizedBox(
          width: 236,
          child: CalendarListPanel(controller: _c, hooks: _hooks),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                children: [
                  _buildToolbar(context),
                  const Divider(height: 1),
                  _statusBar(context),
                  Expanded(child: _buildView(context, wide: true)),
                ],
              ),
              _buildSearchPanel(context),
            ],
          ),
        ),
      ],
    );
    if (widget.embedded) {
      return Material(color: theme.colorScheme.surface, child: content);
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr('캘린더'))),
      body: content,
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      // Wrap이 폭을 꽉 채워야 spaceBetween이 먹는다(안 그러면 두 묶음이 가운데로 모인다).
      child: SizedBox(
        width: double.infinity,
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  key: const ValueKey('cal-today'),
                  onPressed: _goToday,
                  child: Text(tr('오늘')),
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: const ValueKey('cal-prev'),
                  tooltip: tr('이전'),
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => _shift(-1),
                ),
                IconButton(
                  key: const ValueKey('cal-next'),
                  tooltip: tr('다음'),
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => _shift(1),
                ),
                InkWell(
                  key: const ValueKey('cal-title'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: _pickDate,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          formatViewTitle(_mode, _focused),
                          style: theme.textTheme.titleMedium,
                        ),
                        const Icon(Icons.arrow_drop_down),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            _buildSearchField(),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _modeSelector(),
                const SizedBox(width: 12),
                FilledButton.icon(
                  key: const ValueKey('cal-create'),
                  onPressed: () => _createOn(_focused),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(tr('일정 만들기')),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  key: const ValueKey('cal-close'),
                  onPressed: _close,
                  child: Text(tr('닫기')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// `닫기` — PC 홈에 끼워 넣은 캘린더는 홈 셸의 캘린더를 접어 채팅 화면으로 돌아가고, 따로 띄운 화면이면 닫는다.
  void _close() {
    final shell = widget.embedded ? HomeShellScope.maybeOf(context) : null;
    if (shell != null) {
      shell.toggleCalendar();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Widget _modeSelector() {
    return SegmentedButton<CalendarViewMode>(
      key: const ValueKey('cal-modes'),
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
      ),
      segments: [
        for (final m in CalendarViewMode.values)
          ButtonSegment(value: m, label: Text(m.label)),
      ],
      selected: {_mode},
      onSelectionChanged: (s) => _setState(() => _mode = s.first),
    );
  }

  /// 불러오는 중 막대와 오류 안내.
  Widget _statusBar(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        if (_c.loadingEvents)
          const SizedBox(height: 2, child: LinearProgressIndicator())
        else
          const SizedBox(height: 2),
        if (_c.error != null && _c.calendarsLoaded)
          Container(
            width: double.infinity,
            color: theme.colorScheme.errorContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _c.error!,
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
                TextButton(onPressed: _c.refresh, child: Text(tr('다시 시도'))),
              ],
            ),
          ),
      ],
    );
  }

  // ---- 좁은 창(모바일) ----

  Widget _buildNarrow(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(tr('캘린더')),
        actions: [
          IconButton(
            key: const ValueKey('cal-search-open'),
            tooltip: tr('일정 검색'),
            icon: const Icon(Icons.search),
            onPressed: _openSearchScreen,
          ),
          IconButton(
            key: const ValueKey('cal-today'),
            tooltip: tr('오늘'),
            icon: const Icon(Icons.today),
            onPressed: _goToday,
          ),
          IconButton(
            key: const ValueKey('cal-open-list'),
            tooltip: tr('캘린더 목록'),
            icon: const Icon(Icons.layers_outlined),
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
          ),
        ],
      ),
      endDrawer: Drawer(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(tr('캘린더'), style: theme.textTheme.titleMedium),
              ),
              Expanded(
                child: CalendarListPanel(controller: _c, hooks: _hooks),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        key: const ValueKey('cal-create'),
        tooltip: tr('일정 만들기'),
        onPressed: () =>
            _createOn(_mode == CalendarViewMode.month ? _selected : _focused),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Row(
            children: [
              IconButton(
                key: const ValueKey('cal-prev'),
                tooltip: tr('이전'),
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _shift(-1),
              ),
              Expanded(
                child: InkWell(
                  key: const ValueKey('cal-title'),
                  onTap: _pickDate,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            formatViewTitle(_mode, _focused),
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        const Icon(Icons.arrow_drop_down),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('cal-next'),
                tooltip: tr('다음'),
                icon: const Icon(Icons.chevron_right),
                onPressed: () => _shift(1),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox(width: double.infinity, child: _modeSelector()),
          ),
          _statusBar(context),
          Expanded(child: _buildView(context, wide: false)),
        ],
      ),
    );
  }

  // ---- 본문(보기별) ----

  Widget _buildView(BuildContext context, {required bool wide}) {
    final range = _range;
    final events = _c.eventsBetween(range.from, range.to);
    switch (_mode) {
      case CalendarViewMode.month:
        if (wide) {
          return CalendarMonthView(
            key: const ValueKey('cal-month'),
            month: _focused,
            events: events,
            today: _today,
            onDayTap: _createOn,
            onEventTap: _openEvent,
            onMoreTap: _showMore,
            onEventMove: _moveEvent,
          );
        }
        return _buildNarrowMonth(context, events);
      case CalendarViewMode.week:
        return CalendarTimeGrid(
          key: const ValueKey('cal-week'),
          days: weekDays(_focused),
          events: events,
          today: _today,
          onEventTap: _openEvent,
          onSlotTap: _createOn,
          onMoreTap: _showMore,
          onEventMove: _moveEvent,
          onDayHeaderTap: (d) => _setState(() {
            _focused = d;
            _mode = CalendarViewMode.day;
          }),
        );
      case CalendarViewMode.day:
        return CalendarTimeGrid(
          key: const ValueKey('cal-day'),
          days: [_focused],
          events: events,
          today: _today,
          onEventTap: _openEvent,
          onSlotTap: _createOn,
          onMoreTap: _showMore,
          onEventMove: _moveEvent,
        );
      case CalendarViewMode.list:
        return CalendarListView(
          key: const ValueKey('cal-list'),
          from: range.from,
          to: range.to,
          today: _today,
          events: events,
          calendarNameOf: _calendarName,
          onEventTap: _openEvent,
        );
    }
  }

  /// 모바일 월간: 위에 작은 격자, 아래에 고른 날의 일정 목록.
  Widget _buildNarrowMonth(BuildContext context, List<EventOccurrence> events) {
    final weeks = monthGridWeeks(_focused).length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final gridHeight = (24.0 + weeks * 58).clamp(
          0.0,
          constraints.maxHeight * 0.6,
        );
        return Column(
          children: [
            SizedBox(
              height: gridHeight,
              child: CalendarMonthView(
                key: const ValueKey('cal-month'),
                month: _focused,
                events: events,
                today: _today,
                selectedDay: _selected,
                compact: true,
                onDayTap: (d) => _setState(() {
                  _selected = d;
                  if (d.month != _focused.month || d.year != _focused.year) {
                    _focused = d;
                  }
                }),
                onEventTap: (e) => _openEvent(e),
                onMoreTap: (d) => _setState(() => _selected = d),
              ),
            ),
            const Divider(height: 1),
            CalendarDayHeader(
              day: _selected,
              holidayName: holidayNameOn(events, _selected),
              isToday: sameDay(_selected, _today),
            ),
            Expanded(
              child: CalendarDayEventList(
                key: ValueKey(
                  'cal-daylist-${_selected.month}-${_selected.day}',
                ),
                day: _selected,
                events: events,
                showHoliday: false,
                calendarNameOf: _calendarName,
                onEventTap: _openEvent,
              ),
            ),
          ],
        );
      },
    );
  }
}
