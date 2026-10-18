import 'package:flutter/material.dart';

import '../../models/calendar.dart';
import '../../services/calendar_layout.dart';
import '../../services/calendar_move.dart';
import 'calendar_common.dart';
import 'calendar_drag.dart';
import '../../l10n/tr.dart';

/// 월간 보기 — 일요일 시작 격자. 종일·여러 날 일정은 날짜 칸을 가로지르는 막대로 이어지고, 한 칸에
/// 다 못 넣는 일정은 "+N개"로 접는다. 공휴일은 날짜 숫자를 빨갛게 하고 이름을 옆에 적는다.
///
/// [compact]는 모바일 위쪽 격자용 — 글자와 줄 높이를 줄이고 공휴일 이름은 숫자 색으로만 보인다.
class CalendarMonthView extends StatefulWidget {
  final DateTime month;
  final List<EventOccurrence> events;
  final DateTime today;
  final DateTime? selectedDay;
  final bool compact;

  /// 날짜 칸의 빈 곳을 눌렀다. 데스크톱은 일정 만들기, 모바일은 그 날 선택.
  final ValueChanged<DateTime> onDayTap;
  final ValueChanged<EventOccurrence> onEventTap;

  /// "+N개"를 눌렀다 — 그 날 일정 목록을 보여 준다.
  final ValueChanged<DateTime> onMoreTap;

  /// 일정 막대를 다른 날짜 칸에 끌어다 놓았다 — 새 자리([EventMove])를 알린다. null이면 드래그 이동을 끈다
  /// ([compact] 작은 격자도 끈다). 호출 쪽이 서버 저장과 실패 처리를 맡는다.
  final void Function(EventOccurrence event, EventMove move)? onEventMove;

  const CalendarMonthView({
    super.key,
    required this.month,
    required this.events,
    required this.today,
    required this.onDayTap,
    required this.onEventTap,
    required this.onMoreTap,
    this.onEventMove,
    this.selectedDay,
    this.compact = false,
  });

  @override
  State<CalendarMonthView> createState() => _CalendarMonthViewState();
}

/// 끌고 있는 일정과 놓일 자리 미리보기(고스트)에 쓰는 값.
class _MonthGhost {
  final EventOccurrence event;
  final DateTime first;
  final DateTime last;
  const _MonthGhost(this.event, this.first, this.last);
}

class _CalendarMonthViewState extends State<CalendarMonthView> {
  final _gridKey = GlobalKey();
  EventOccurrence? _dragging;

  /// 잡은 곳이 일정 첫날에서 며칠째인지(여러 날 막대의 중간을 잡고 옮겨도 잡은 날이 포인터 아래로 간다).
  int _grabDays = 0;
  Offset? _pointer;

  EventDragHandle? get _handle => widget.compact || widget.onEventMove == null
      ? null
      : EventDragHandle(
          onStart: _onStart,
          onUpdate: (e, p) => setState(() => _pointer = p),
          onEnd: _onEnd,
        );

  DateTime? _cellAt(Offset? global) {
    if (global == null) return null;
    final box = _gridKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return monthCellDayAt(
      box.size,
      box.globalToLocal(global),
      monthGridWeeks(widget.month),
    );
  }

  void _onStart(EventOccurrence e, Offset down) {
    final cell = _cellAt(down);
    setState(() {
      _dragging = e;
      _pointer = down;
      _grabDays = cell == null
          ? 0
          : daysBetween(e.firstDay, cell).clamp(0, e.dayCount - 1);
    });
  }

  /// 지금 포인터 아래 칸으로 옮겼을 때의 새 자리(안 옮겨지거나 격자 밖이면 null).
  EventMove? _currentMove() {
    final e = _dragging;
    final cell = _cellAt(_pointer);
    if (e == null || cell == null) return null;
    final move = moveEventToDay(e, addDays(cell, -_grabDays));
    return move.isSameAs(e) ? null : move;
  }

  void _onEnd(EventOccurrence e) {
    final move = _currentMove();
    setState(() {
      _dragging = null;
      _pointer = null;
    });
    if (move != null) widget.onEventMove?.call(e, move);
  }

  _MonthGhost? get _ghost {
    final e = _dragging;
    final move = _currentMove();
    if (e == null || move == null) return null;
    final first = move.allDay
        ? allDayFromMs(move.start)
        : dateOnly(DateTime.fromMillisecondsSinceEpoch(move.start));
    return _MonthGhost(e, first, addDays(first, e.dayCount - 1));
  }

  @override
  Widget build(BuildContext context) {
    final weeks = monthGridWeeks(widget.month);
    final theme = Theme.of(context);
    final handle = _handle;
    final ghost = _ghost;
    return Column(
      children: [
        _WeekdayHeader(compact: widget.compact),
        Expanded(
          child: Column(
            key: _gridKey,
            children: [
              for (final week in weeks)
                Expanded(
                  child: _WeekRow(
                    days: week,
                    month: widget.month,
                    events: widget.events,
                    today: widget.today,
                    selectedDay: widget.selectedDay,
                    compact: widget.compact,
                    borderColor: theme.dividerColor,
                    onDayTap: widget.onDayTap,
                    onEventTap: widget.onEventTap,
                    onMoreTap: widget.onMoreTap,
                    dragHandle: handle,
                    ghost: ghost,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _WeekdayHeader extends StatelessWidget {
  final bool compact;
  const _WeekdayHeader({required this.compact});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: compact ? 24 : 30,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < 7; i++)
            Expanded(
              child: Center(
                child: Text(
                  weekdayShortKo(i),
                  style: TextStyle(
                    fontSize: compact ? 11 : 12,
                    fontWeight: FontWeight.w600,
                    color: i == 0
                        ? kSundayColor
                        : i == 6
                        ? kSaturdayColor
                        : theme.hintColor,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _WeekRow extends StatelessWidget {
  final List<DateTime> days;
  final DateTime month;
  final List<EventOccurrence> events;
  final DateTime today;
  final DateTime? selectedDay;
  final bool compact;
  final Color borderColor;
  final ValueChanged<DateTime> onDayTap;
  final ValueChanged<EventOccurrence> onEventTap;
  final ValueChanged<DateTime> onMoreTap;
  final EventDragHandle? dragHandle;
  final _MonthGhost? ghost;

  const _WeekRow({
    required this.days,
    required this.month,
    required this.events,
    required this.today,
    required this.selectedDay,
    required this.compact,
    required this.borderColor,
    required this.onDayTap,
    required this.onEventTap,
    required this.onMoreTap,
    required this.dragHandle,
    required this.ghost,
  });

  @override
  Widget build(BuildContext context) {
    final headerH = compact ? 22.0 : 26.0;
    final rowH = compact ? 15.0 : 21.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellW = constraints.maxWidth / 7;
        final cellH = constraints.maxHeight;
        // 날짜 숫자 아래로 줄이 몇 개 들어가는지 — "+N개"도 한 줄을 쓴다.
        final maxRows = ((cellH - headerH - 2) / rowH).floor().clamp(1, 12);
        final layout = layoutWeek(days, events, maxRows: maxRows);
        return Stack(
          children: [
            Row(
              children: [
                for (var c = 0; c < 7; c++)
                  Expanded(
                    child: _DayCell(
                      day: days[c],
                      month: month,
                      today: today,
                      selected:
                          selectedDay != null && sameDay(selectedDay!, days[c]),
                      compact: compact,
                      borderColor: borderColor,
                      holidayName: holidayNameOn(events, days[c]),
                      isLastColumn: c == 6,
                      onTap: () => onDayTap(days[c]),
                    ),
                  ),
              ],
            ),
            // 모바일 작은 격자(compact)의 막대는 너무 작아 누르기 어려우므로 눌림을 받지 않고 아래 날짜
            // 칸이 받게 한다 — 일정은 아래 "선택한 날" 목록에서 연다.
            for (final seg in layout.segments)
              Positioned(
                left: seg.startCol * cellW,
                width: seg.span * cellW,
                top: headerH + seg.row * rowH,
                height: rowH,
                child: IgnorePointer(
                  ignoring: compact,
                  child: CalendarEventBar(
                    key: ValueKey('cal-bar-${seg.event.key}-${seg.startCol}'),
                    segment: seg,
                    compact: compact,
                    dragHandle: dragHandle,
                    onTap: () => onEventTap(seg.event),
                  ),
                ),
              ),
            for (var c = 0; c < 7; c++)
              if (layout.hiddenCounts[c] > 0)
                Positioned(
                  left: c * cellW,
                  width: cellW,
                  top: headerH + (maxRows - 1) * rowH,
                  height: rowH,
                  child: InkWell(
                    key: ValueKey('cal-more-${_dayKey(days[c])}'),
                    onTap: () => onMoreTap(days[c]),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          tr('+{p0}개', {'p0': layout.hiddenCounts[c]}),
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: compact ? 9 : 11,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            // 끌고 있는 일정이 놓일 날짜 칸 하이라이트와 고스트 — 막대 위젯의 자리를 밀지 않게 맨 끝에 둔다.
            ..._ghostCells(context, cellW, cellH),
            ..._ghostBar(context, cellW, headerH, rowH),
          ],
        );
      },
    );
  }
}

extension on _WeekRow {
  /// 이 주에서 고스트가 덮는 열 범위(없으면 null).
  ({int start, int end})? _ghostCols() {
    final g = ghost;
    if (g == null) return null;
    int? start;
    int? end;
    for (var c = 0; c < 7; c++) {
      final d = days[c];
      if (!d.isBefore(g.first) && !d.isAfter(g.last)) {
        start ??= c;
        end = c;
      }
    }
    return start == null ? null : (start: start, end: end!);
  }

  List<Widget> _ghostCells(BuildContext context, double cellW, double cellH) {
    final cols = _ghostCols();
    if (cols == null) return const [];
    final color = Theme.of(context).colorScheme.primary;
    return [
      Positioned(
        key: ValueKey('cal-drop-${_dayKey(days[cols.start])}'),
        left: cols.start * cellW,
        width: (cols.end - cols.start + 1) * cellW,
        top: 0,
        height: cellH,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              border: Border.all(color: color.withValues(alpha: 0.6)),
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _ghostBar(
    BuildContext context,
    double cellW,
    double headerH,
    double rowH,
  ) {
    final cols = _ghostCols();
    final g = ghost;
    if (cols == null || g == null) return const [];
    final color = calendarColor(g.event.color);
    return [
      Positioned(
        key: ValueKey('cal-ghost-${_dayKey(days[cols.start])}'),
        left: cols.start * cellW,
        width: (cols.end - cols.start + 1) * cellW,
        top: headerH,
        height: rowH,
        child: IgnorePointer(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    eventDisplayTitle(g.event),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 9.5 : 11.5,
                      color: onCalendarColor(color),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ];
  }
}

String _dayKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 날짜 칸 하나(배경·날짜 숫자·공휴일 이름). 일정 막대는 위에 따로 얹힌다.
class _DayCell extends StatelessWidget {
  final DateTime day;
  final DateTime month;
  final DateTime today;
  final bool selected;
  final bool compact;
  final bool isLastColumn;
  final Color borderColor;
  final String? holidayName;
  final VoidCallback onTap;

  const _DayCell({
    required this.day,
    required this.month,
    required this.today,
    required this.selected,
    required this.compact,
    required this.isLastColumn,
    required this.borderColor,
    required this.holidayName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inMonth = day.month == month.month && day.year == month.year;
    final isToday = sameDay(day, today);
    final isHoliday = holidayName != null;
    Color numberColor = day.weekday == DateTime.sunday || isHoliday
        ? kSundayColor
        : day.weekday == DateTime.saturday
        ? kSaturdayColor
        : theme.colorScheme.onSurface;
    if (!inMonth) numberColor = numberColor.withValues(alpha: 0.4);
    final circle = compact ? 18.0 : 22.0;
    return Semantics(
      label: tr('{day.month}월 {day.day}일{p0}', {
        'day.month': day.month,
        'day.day': day.day,
        'p0': isHoliday ? ' $holidayName' : '',
      }),
      button: true,
      child: InkWell(
        key: ValueKey('cal-day-${_dayKey(day)}'),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.08)
                : null,
            border: Border(
              bottom: BorderSide(color: borderColor.withValues(alpha: 0.6)),
              right: isLastColumn
                  ? BorderSide.none
                  : BorderSide(color: borderColor.withValues(alpha: 0.6)),
            ),
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
              child: Row(
                children: [
                  Container(
                    width: circle,
                    height: circle,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isToday ? theme.colorScheme.primary : null,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${day.day}',
                      style: TextStyle(
                        fontSize: compact ? 11 : 12,
                        fontWeight: isToday || selected
                            ? FontWeight.bold
                            : FontWeight.w500,
                        color: isToday
                            ? theme.colorScheme.onPrimary
                            : numberColor,
                      ),
                    ),
                  ),
                  if (isHoliday && !compact) ...[
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        holidayName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: kSundayColor.withValues(
                            alpha: inMonth ? 1 : 0.5,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 일정 한 조각(주간·일간 위쪽 종일 칸도 같이 쓴다). 종일·여러 날 일정은 색으로 채운 막대, 하루짜리 시간 일정은 색 점 + 시각 + 제목.
class CalendarEventBar extends StatelessWidget {
  final BarSegment segment;
  final bool compact;
  final VoidCallback onTap;

  /// 있으면 끌어서 옮길 수 있다(조건은 [EventDragSource]).
  final EventDragHandle? dragHandle;
  const CalendarEventBar({
    super.key,
    required this.segment,
    required this.compact,
    required this.onTap,
    this.dragHandle,
  });

  @override
  Widget build(BuildContext context) {
    return EventDragSource(
      event: segment.event,
      handle: dragHandle,
      builder: _content,
    );
  }

  Widget _content(BuildContext context, MouseCursor? cursor) {
    final e = segment.event;
    final color = calendarColor(e.color);
    final fontSize = compact ? 9.5 : 11.5;
    final title = eventDisplayTitle(e);
    if (e.isBar) {
      final fg = onCalendarColor(color);
      const r = Radius.circular(4);
      return Padding(
        padding: EdgeInsets.only(
          left: segment.continuesBefore ? 0 : 2,
          right: segment.continuesAfter ? 0 : 2,
          top: 1,
          bottom: 1,
        ),
        child: Material(
          color: color,
          borderRadius: BorderRadius.horizontal(
            left: segment.continuesBefore ? Radius.zero : r,
            right: segment.continuesAfter ? Radius.zero : r,
          ),
          child: InkWell(
            mouseCursor: cursor,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: fg, fontSize: fontSize),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      child: InkWell(
        mouseCursor: cursor,
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Row(
            children: [
              Container(
                width: compact ? 5 : 6,
                height: compact ? 5 : 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 3),
              Expanded(
                child: Text(
                  compact ? title : '${_clock(e.startTime)} $title',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: fontSize,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
