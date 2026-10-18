import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/room.dart';
import '../models/todo.dart';
import '../services/session.dart';
import '../services/todo_controller.dart';
import 'filter_dropdown.dart' show iconForRoomType;
import 'todo_menu.dart' show TodoCardActions;
import 'todo_widgets.dart' show TodoPageHeader, TodoViewMode;
import 'todos_panel.dart' show TodoCard, todoCardColor, todoListBackgroundColor;
import '../l10n/tr.dart';

final _weekdayHeaders = [
  tr('일'),
  tr('월'),
  tr('화'),
  tr('수'),
  tr('목'),
  tr('금'),
  tr('토'),
];

/// 달력 한 칸의 높이 — 날짜 원(30)과 그 아래 할 일 점(4)에 위아래 여백.
const _cellHeight = 44.0;

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

bool _inMonth(DateTime day, DateTime month) =>
    day.year == month.year && day.month == month.month;

/// 할 일 일정 화면(잔디 "할 일 일정") — 할 일 패널([TodosPanel]) 머리의 `할 일 일정` 칩으로 여는 별도 화면이다. PC 할 일
/// 패널 안([TodoViewMode.panel])이면 머리 `← 할 일 … ✕`(←는 이 화면만 닫고, ✕는 [onClosePanel]로 패널 전체를 닫는다),
/// 그 밖(모바일)은 전체 화면(앱바 `할 일 일정`, 뒤로 가기로 닫는다). 본문은 [TodoCalendarView]이고, 이 화면이 닫히면
/// 패널이 컨트롤러의 달력 받기를 멈춘다.
class TodoCalendarPage extends StatelessWidget {
  final Session session;
  final TodoController controller;
  final ValueChanged<Todo> onOpen;

  /// 카드 ⋯ 메뉴의 손잡이(목록 카드와 같다) — 없으면 ⋯가 없다.
  final TodoCardActions? actions;
  final TodoViewMode mode;
  final VoidCallback? onClosePanel;

  const TodoCalendarPage({
    super.key,
    required this.session,
    required this.controller,
    required this.onOpen,
    this.actions,
    this.mode = TodoViewMode.page,
    this.onClosePanel,
  });

  @override
  Widget build(BuildContext context) {
    final view = TodoCalendarView(
      session: session,
      controller: controller,
      onOpen: onOpen,
      actions: actions,
    );
    if (mode != TodoViewMode.panel) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('할 일 일정'))),
        body: SafeArea(top: false, child: view),
      );
    }
    // 바탕을 칠해 밀려 들어오는 동안 아래 목록이 비치지 않게 한다.
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TodoPageHeader(
            onBack: () => Navigator.of(context).maybePop(),
            onClose: onClosePanel,
          ),
          const Divider(height: 1),
          Expanded(child: view),
        ],
      ),
    );
  }
}

/// 할 일 일정 본문 — 위에서부터 월 이동 줄(« 이전 해 · ‹ 이전 달 · `2026/10` · 다음 달 › · 다음 해 », 오른쪽 `오늘`), 일~토
/// 머리(차분한 회색), 6주 42칸 달력(할 일이 걸친 날은 숫자 아래 작은 점, 고른 날은 채운 원, 오늘은 옅은 테두리, 이웃 달
/// 날짜는 흐리게), 그 아래 옅은 회색 바탕에 `N개의 할 일이 있습니다.`와 고른 날의 할 일을 대화방별로 묶은 카드다(머리는
/// 방 아이콘·이름·개수·접기/펼치기, 안에는 목록과 같은 카드, 묶음 순서는 받은 목록에 처음 나온 순). 달력과 묶음이 한
/// 번에 스크롤된다.
///
/// 받기와 필터는 [TodoController]의 달력 상태(calendarMonth·calendarItems)를 그대로 쓴다 — 목록 화면에서 고른 보기·
/// 대화방·담당 멤버·완료 제외가 그대로 걸리고, 이 화면에는 필터가 없다. 달을 옮기면 [TodoController.loadCalendar]로 그
/// 달을 받는다. 고른 날은 처음엔 오늘이고, 달을 옮기면 그 달 안이면 그대로, 아니면 그 달 1일이 된다. 카드를 누르면
/// [onOpen](패널이 상세를 연다), 카드 오른쪽 위 ⋯는 목록 카드와 같은 메뉴([actions]).
class TodoCalendarView extends StatefulWidget {
  final Session session;
  final TodoController controller;
  final ValueChanged<Todo> onOpen;

  /// 카드 ⋯ 메뉴의 손잡이 — 없으면 ⋯가 없다.
  final TodoCardActions? actions;

  const TodoCalendarView({
    super.key,
    required this.session,
    required this.controller,
    required this.onOpen,
    this.actions,
  });

  @override
  State<TodoCalendarView> createState() => _TodoCalendarViewState();
}

class _TodoCalendarViewState extends State<TodoCalendarView> {
  /// 고른 날(0시).
  late DateTime _selected;

  /// 마지막으로 그린 달 — 다른 곳에서 달을 옮겼는지 알아본다.
  DateTime? _shownMonth;

  /// 칸마다의 개수 — 받은 목록과 칸 범위가 같으면 다시 세지 않는다.
  List<int> _counts = const [];
  List<Todo>? _countedItems;
  DateTime? _countedFrom;

  /// 접어 둔 대화방 묶음(방 id) — 날짜·달을 옮겨도 그대로 둔다.
  final _collapsed = <String>{};

  TodoController get _c => widget.controller;

  /// 보고 있는 달(1일) — 컨트롤러가 아직 달을 안 들고 있으면 이번 달.
  DateTime get _month {
    final month = _c.calendarMonth;
    if (month != null) return month;
    final now = DateTime.now();
    return DateTime(now.year, now.month);
  }

  @override
  void initState() {
    super.initState();
    final today = _dayOnly(DateTime.now());
    final month = _month;
    _shownMonth = month;
    _selected = _inMonth(today, month) ? today : month;
    _c.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(TodoCalendarView old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {
      // 이 화면 밖에서 달을 옮겼으면 그 달에 맞춰 고른 날을 고친다.
      final month = _c.calendarMonth;
      if (month != null && month != _shownMonth) {
        _shownMonth = month;
        if (!_inMonth(_selected, month)) _selected = month;
      }
    });
  }

  // ---- 달 옮기기 ----

  void _goTo(DateTime month, {DateTime? select}) {
    final target = DateTime(month.year, month.month);
    setState(() {
      _shownMonth = target;
      _selected = select ?? (_inMonth(_selected, target) ? _selected : target);
    });
    _c.loadCalendar(target);
  }

  /// [delta]달만큼 옮긴다(«·»는 12달).
  void _moveMonth(int delta) {
    final month = _month;
    _goTo(DateTime(month.year, month.month + delta));
  }

  /// "오늘" — 오늘이 있는 달로 옮기고 오늘을 고른다(이미 그 달이면 고르기만).
  void _goToday() {
    final today = _dayOnly(DateTime.now());
    final month = DateTime(today.year, today.month);
    if (month == _c.calendarMonth) {
      setState(() => _selected = today);
    } else {
      _goTo(month, select: today);
    }
  }

  void _toggleRoom(String roomId) => setState(() {
    if (!_collapsed.remove(roomId)) _collapsed.add(roomId);
  });

  // ---- 세기 ----

  /// 42칸마다 그날에 기간이 걸친 할 일 수 — [todoCoversDate]와 같은 기준(시작일 ?? 종료일 ~ 종료일 ?? 시작일)을 칸 범위로
  /// 잘라 한 번에 센다(칸마다 목록 전체를 훑지 않게).
  static List<int> _countDays(List<Todo> items, DateTime from) {
    final counts = List.filled(42, 0);
    // 날짜 차이는 UTC로 — 일광 절약 시간이 있는 곳에서도 하루가 23·25시간이 되지 않게.
    final origin = DateTime.utc(from.year, from.month, from.day);
    int indexOf(DateTime d) =>
        DateTime.utc(d.year, d.month, d.day).difference(origin).inDays;
    for (final t in items) {
      final start = t.start ?? t.due;
      final end = t.due ?? t.start;
      if (start == null || end == null) continue;
      final last = math.min(41, indexOf(end));
      for (var i = math.max(0, indexOf(start)); i <= last; i++) {
        counts[i]++;
      }
    }
    return counts;
  }

  // ---- 화면 ----

  @override
  Widget build(BuildContext context) {
    final month = _month;
    final (from, _) = todoCalendarRange(month);
    final items = _c.calendarItems;
    if (!identical(items, _countedItems) || from != _countedFrom) {
      _counts = _countDays(items, from);
      _countedItems = items;
      _countedFrom = from;
    }
    final loaded = _c.calendarLoaded;
    // 고른 날의 할 일을 대화방별로 — 방 순서는 받은 목록에 처음 나온 순.
    final groups = <String, List<Todo>>{};
    if (loaded) {
      for (final t in items) {
        if (todoCoversDate(t, _selected)) (groups[t.roomId] ??= []).add(t);
      }
    }
    final entries = groups.entries.toList();
    final dayCount = entries.fold(0, (n, e) => n + e.value.length);
    return ColoredBox(
      color: todoListBackgroundColor(context),
      child: CustomScrollView(
        key: const ValueKey('todo-calendar'),
        slivers: [
          SliverToBoxAdapter(
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: _calendar(context, month, from),
            ),
          ),
          SliverToBoxAdapter(
            child: _dayLine(context, loaded ? dayCount : null),
          ),
          if (!loaded)
            SliverToBoxAdapter(child: _status(context))
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverList.separated(
                itemCount: entries.length,
                separatorBuilder: (context, i) => const SizedBox(height: 10),
                itemBuilder: (context, i) =>
                    _group(context, entries[i].key, entries[i].value),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ],
      ),
    );
  }

  /// 월 이동 줄 + 요일 머리 + 6주 칸.
  Widget _calendar(BuildContext context, DateTime month, DateTime from) {
    final theme = Theme.of(context);
    final today = _dayOnly(DateTime.now());
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _arrow(
                context,
                'todo-cal-prev-year',
                Icons.keyboard_double_arrow_left,
                tr('이전 해'),
                -12,
              ),
              _bar(context),
              _arrow(
                context,
                'todo-cal-prev',
                Icons.chevron_left,
                tr('이전 달'),
                -1,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  '${month.year}/${month.month.toString().padLeft(2, '0')}',
                  key: const ValueKey('todo-cal-month'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _arrow(
                context,
                'todo-cal-next',
                Icons.chevron_right,
                tr('다음 달'),
                1,
              ),
              _bar(context),
              _arrow(
                context,
                'todo-cal-next-year',
                Icons.keyboard_double_arrow_right,
                tr('다음 해'),
                12,
              ),
              const Spacer(),
              OutlinedButton(
                key: const ValueKey('todo-cal-today'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.onSurfaceVariant,
                  side: BorderSide(color: theme.colorScheme.outlineVariant),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(0, 26),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 12),
                ),
                onPressed: _goToday,
                child: Text(tr('오늘')),
              ),
              const SizedBox(width: 4),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final label in _weekdayHeaders)
                Expanded(
                  child: Center(
                    child: Text(
                      label,
                      style: TextStyle(fontSize: 12, color: theme.hintColor),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          for (var row = 0; row < 6; row++)
            Row(
              children: [
                for (var col = 0; col < 7; col++)
                  _dayCell(
                    context,
                    from,
                    row * 7 + col,
                    month: month,
                    today: today,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// 월 이동 단추(작은 회색 꺽쇠).
  Widget _arrow(
    BuildContext context,
    String key,
    IconData icon,
    String tooltip,
    int delta,
  ) => Tooltip(
    message: tooltip,
    child: InkWell(
      key: ValueKey(key),
      onTap: () => _moveMonth(delta),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 18, color: Theme.of(context).hintColor),
      ),
    ),
  );

  /// 해 이동과 달 이동 사이의 가는 세로줄.
  Widget _bar(BuildContext context) => Container(
    width: 1,
    height: 12,
    margin: const EdgeInsets.symmetric(horizontal: 3),
    color: Theme.of(context).colorScheme.outlineVariant,
  );

  /// [from]부터 [index]번째 날짜 칸 — 두 자리 숫자(이웃 달은 흐리게), 고른 날은 채운 원, 오늘은 옅은 테두리 원, 그날에
  /// 걸친 할 일이 있으면 숫자 아래 작은 점.
  Widget _dayCell(
    BuildContext context,
    DateTime from,
    int index, {
    required DateTime month,
    required DateTime today,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final day = DateTime(from.year, from.month, from.day + index);
    final count = _counts[index];
    final inMonth = _inMonth(day, month);
    final selected = day == _selected;
    final isToday = day == today;
    final ymd = todoDateWire(day);
    void select() => setState(() => _selected = day);
    return Expanded(
      // 칸 하나를 "10월 3일, 할 일 2개" 한 마디로 읽게 한다(안쪽 숫자·점은 따로 읽지 않는다).
      child: Semantics(
        container: true,
        button: true,
        selected: selected,
        label: tr('{day.month}월 {day.day}일, 할 일 {count}개', {
          'day.month': day.month,
          'day.day': day.day,
          'count': count,
        }),
        onTap: select,
        excludeSemantics: true,
        child: InkWell(
          key: ValueKey('todo-cal-day-$ymd'),
          onTap: select,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: _cellHeight,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  key: selected ? const ValueKey('todo-cal-selected') : null,
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: selected
                      ? BoxDecoration(
                          shape: BoxShape.circle,
                          color: scheme.primary,
                        )
                      : isToday
                      ? BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: scheme.primary.withValues(alpha: 0.45),
                          ),
                        )
                      : null,
                  child: Text(
                    day.day.toString().padLeft(2, '0'),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected
                          ? FontWeight.w700
                          : isToday
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: selected
                          ? scheme.onPrimary
                          : inMonth
                          ? scheme.onSurface
                          : theme.disabledColor,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                SizedBox(
                  height: 4,
                  child: count == 0
                      ? null
                      : Container(
                          key: ValueKey('todo-cal-dot-$ymd'),
                          width: 4,
                          height: 4,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: inMonth
                                ? scheme.outline
                                : scheme.outlineVariant,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 달력 아래 줄 — 고른 날의 할 일 수(`3개의 할 일이 있습니다.` / `할 일이 없습니다.`, [count]가 null이면 아직 모른다).
  Widget _dayLine(BuildContext context, int? count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: count == null
          ? null
          : Text(
              count == 0
                  ? tr('할 일이 없습니다.')
                  : tr('{count}개의 할 일이 있습니다.', {'count': count}),
              key: const ValueKey('todo-cal-day-count'),
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
    );
  }

  /// 아직 못 받았을 때 — 받는 중이면 돌아가는 표시, 실패했으면 문구와 다시 시도.
  Widget _status(BuildContext context) {
    final error = _c.calendarError;
    if (error == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: CircularProgressIndicator(key: ValueKey('todo-cal-loading')),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            error,
            key: const ValueKey('todo-cal-error'),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const ValueKey('todo-cal-retry'),
            onPressed: () => _c.loadCalendar(_month),
            child: Text(tr('다시 시도')),
          ),
        ],
      ),
    );
  }

  /// 대화방 하나의 묶음 카드 — 머리(누르면 접고 편다) 아래 그 방의 할 일 카드들(대화방 이름은 머리에 있어 뺀다).
  Widget _group(BuildContext context, String roomId, List<Todo> todos) {
    final collapsed = _collapsed.contains(roomId);
    final divider = Divider(
      height: 1,
      color: Theme.of(context).colorScheme.outlineVariant,
    );
    return Material(
      color: todoCardColor(context),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _roomHeader(context, todos.first, todos.length, collapsed),
          if (!collapsed)
            for (final t in todos) ...[
              divider,
              TodoCard(
                key: ValueKey('todo-${t.id}'),
                session: widget.session,
                controller: _c,
                todo: t,
                onTap: () => widget.onOpen(t),
                actions: widget.actions,
                showRoom: false,
                framed: false,
              ),
            ],
        ],
      ),
    );
  }

  /// 묶음 머리 — 방 종류 아이콘, 이름(내 목록에 없으면 서버가 준 이름), 그날 그 방의 할 일 수, 오른쪽 접기(^)/펴기(v).
  Widget _roomHeader(
    BuildContext context,
    Todo first,
    int count,
    bool collapsed,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final session = widget.session;
    final room = session.roomById(first.roomId);
    final name =
        room?.displayName(session.userId ?? '') ?? first.roomName ?? '';
    return Semantics(
      container: true,
      button: true,
      expanded: !collapsed,
      child: InkWell(
        key: ValueKey('todo-cal-room-${first.roomId}'),
        onTap: () => _toggleRoom(first.roomId),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(
            children: [
              Icon(
                iconForRoomType(room?.type ?? RoomType.topic),
                size: 16,
                color: theme.hintColor,
              ),
              const SizedBox(width: 6),
              // 이름이 길면 이름만 줄이고 개수는 이름 바로 뒤에 둔다.
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: theme.hintColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.surfaceContainerHighest,
                ),
                child: Icon(
                  collapsed
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_up,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
