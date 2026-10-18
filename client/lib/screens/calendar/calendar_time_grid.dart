import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/calendar.dart';
import '../../services/calendar_layout.dart';
import '../../services/calendar_move.dart';
import '../../services/time_format.dart';
import 'calendar_common.dart';
import 'calendar_drag.dart';
import 'calendar_month_view.dart' show CalendarEventBar;
import '../../l10n/tr.dart';

/// 주간(7일)·일간(1일) 시간표. 위쪽에 종일·여러 날 일정 칸, 아래에 0~24시 시간표가 있고 시간 일정은
/// 시각에 맞춰 세로로 놓인다. 서로 시간이 겹치는 일정은 나란히 선다.
class CalendarTimeGrid extends StatefulWidget {
  /// 1일(일간) 또는 7일(주간, 일요일 시작).
  final List<DateTime> days;
  final List<EventOccurrence> events;
  final DateTime today;
  final ValueChanged<EventOccurrence> onEventTap;

  /// 시간표의 빈 곳을 눌렀다 — 누른 자리의 날짜+시각(30분 단위).
  final ValueChanged<DateTime> onSlotTap;

  /// 종일 칸의 "+N개"나 날짜 머리글을 눌렀다.
  final ValueChanged<DateTime>? onDayHeaderTap;
  final ValueChanged<DateTime> onMoreTap;

  /// 일정을 다른 날/시간대로 끌어다 놓았다 — 새 자리([EventMove])를 알린다. 시간 블록은 10분 단위로 맞추고 길이를
  /// 유지하며, 종일·여러 날 막대는 날짜만 옮긴다. null이면 드래그 이동을 끈다. 저장과 실패 처리는 호출 쪽이 맡는다.
  final void Function(EventOccurrence event, EventMove move)? onEventMove;

  const CalendarTimeGrid({
    super.key,
    required this.days,
    required this.events,
    required this.today,
    required this.onEventTap,
    required this.onSlotTap,
    required this.onMoreTap,
    this.onDayHeaderTap,
    this.onEventMove,
  });

  @override
  State<CalendarTimeGrid> createState() => _CalendarTimeGridState();
}

const _hourHeight = 52.0;
const _gutterWidth = 54.0;
const _stripRowHeight = 21.0;
const _stripMaxRows = 4;

/// 끄는 동안 놓일 자리 미리보기 — 어느 일정이 어디로 가는지, 그리고 시간표 안(분 단위)인지 날짜만 옮기는지.
class _Ghost {
  final EventOccurrence event;
  final EventMove move;
  final bool timed;
  const _Ghost(this.event, this.move, {required this.timed});

  /// 옮긴 뒤의 첫날/마지막 날.
  DateTime get first => move.allDay
      ? allDayFromMs(move.start)
      : dateOnly(DateTime.fromMillisecondsSinceEpoch(move.start));
  DateTime get last => addDays(first, event.dayCount - 1);
}

/// 포인터가 가리키는 자리 — 날짜 칸([day]), 시간표 안이면 그 위치의 분([minutes]).
typedef _Hit = ({DateTime day, int? minutes});

class _CalendarTimeGridState extends State<CalendarTimeGrid> {
  late final ScrollController _scroll;
  final _viewportKey = GlobalKey();
  final _gridKey = GlobalKey();
  final _stripKey = GlobalKey();

  // 드래그 상태.
  EventOccurrence? _dragging;
  int _grabDays = 0;
  int _grabMinutes = 0;
  Offset? _downPos;
  Offset? _pointer;
  Timer? _autoScroll;
  int _autoDir = 0;

  @override
  void initState() {
    super.initState();
    // 오늘이 보이는 범위면 지금 시각 한 시간 전부터, 아니면 오전 8시부터 보여 준다.
    final now = DateTime.now();
    final showsToday = widget.days.any((d) => sameDay(d, now));
    final startHour = showsToday ? math.max(0, now.hour - 1) : 8;
    _scroll = ScrollController(initialScrollOffset: startHour * _hourHeight);
  }

  @override
  void dispose() {
    _autoScroll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  // ---- 드래그 이동 ----

  EventDragHandle? get _handle => widget.onEventMove == null
      ? null
      : EventDragHandle(
          onStart: _onDragStart,
          onUpdate: _onDragUpdate,
          onEnd: _onDragEnd,
        );

  RenderBox? _boxOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize ? box : null;
  }

  /// [global]이 시간표 영역 → 종일 칸 순으로 어느 날짜 칸(과 분)에 있는지. 둘 다 아니면 null.
  _Hit? _hitAt(Offset? global) {
    if (global == null) return null;
    final days = widget.days;
    final viewport = _boxOf(_viewportKey);
    final grid = _boxOf(_gridKey);
    if (viewport != null && grid != null) {
      final vp = viewport.localToGlobal(Offset.zero) & viewport.size;
      if (vp.contains(global)) {
        final local = grid.globalToLocal(global);
        final colW = (grid.size.width - _gutterWidth) / days.length;
        if (local.dx >= _gutterWidth && colW > 0) {
          final col = ((local.dx - _gutterWidth) / colW).floor().clamp(
            0,
            days.length - 1,
          );
          final minutes = (local.dy / _hourHeight * 60).floor().clamp(0, 1439);
          return (day: days[col], minutes: minutes);
        }
        return null;
      }
    }
    final strip = _boxOf(_stripKey);
    if (strip != null) {
      final local = strip.globalToLocal(global);
      final colW = (strip.size.width - _gutterWidth) / days.length;
      if (local.dx >= _gutterWidth &&
          local.dx < strip.size.width &&
          local.dy >= 0 &&
          local.dy < strip.size.height &&
          colW > 0) {
        final col = ((local.dx - _gutterWidth) / colW).floor().clamp(
          0,
          days.length - 1,
        );
        return (day: days[col], minutes: null);
      }
    }
    return null;
  }

  void _onDragStart(EventOccurrence e, Offset down) {
    final hit = _hitAt(down);
    setState(() {
      _dragging = e;
      _downPos = down;
      _pointer = down;
      _grabDays = hit == null || !e.isBar
          ? 0
          : daysBetween(e.firstDay, hit.day).clamp(0, e.dayCount - 1);
      _grabMinutes = hit?.minutes == null || e.isBar || e.allDay
          ? 0
          : (hit!.minutes! - minutesIntoDay(e)).clamp(
              0,
              ((e.end - e.start) / 60000).ceil(),
            );
    });
  }

  void _onDragUpdate(EventOccurrence e, Offset position) {
    setState(() => _pointer = position);
    _updateAutoScroll(position);
  }

  /// 시간표 위·아래 가장자리에 포인터를 대고 있으면 그쪽으로 스크롤한다(하루 24시간이 한 화면에 안 들어오므로).
  void _updateAutoScroll(Offset position) {
    final viewport = _boxOf(_viewportKey);
    var dir = 0;
    if (viewport != null) {
      final vp = viewport.localToGlobal(Offset.zero) & viewport.size;
      if (position.dx >= vp.left && position.dx <= vp.right) {
        if (position.dy >= vp.top && position.dy < vp.top + 36) dir = -1;
        if (position.dy <= vp.bottom && position.dy > vp.bottom - 36) dir = 1;
      }
    }
    _autoDir = dir;
    if (dir == 0) {
      _autoScroll?.cancel();
      _autoScroll = null;
    } else {
      _autoScroll ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
        if (!mounted || _autoDir == 0 || !_scroll.hasClients) return;
        final pos = _scroll.position;
        final next = (pos.pixels + _autoDir * 6).clamp(
          pos.minScrollExtent,
          pos.maxScrollExtent,
        );
        if (next != pos.pixels) {
          _scroll.jumpTo(next);
          setState(() {});
        }
      });
    }
  }

  /// 지금 포인터 자리로 옮겼을 때의 새 자리. 안 옮겨지거나 놓을 수 없는 곳이면 null.
  _Ghost? _currentGhost() {
    final e = _dragging;
    final hit = _hitAt(_pointer);
    if (e == null || hit == null) return null;
    final bool timed;
    final EventMove move;
    if (!e.isBar && !e.allDay && hit.minutes != null) {
      timed = true;
      move = moveTimedEventTo(e, hit.day, hit.minutes! - _grabMinutes);
    } else {
      timed = false;
      move = moveEventToDay(e, addDays(hit.day, e.isBar ? -_grabDays : 0));
    }
    return move.isSameAs(e) ? null : _Ghost(e, move, timed: timed);
  }

  void _onDragEnd(EventOccurrence e) {
    // 클릭하다 살짝 움직인 정도(몇 픽셀)는 옮김으로 치지 않는다.
    final moved =
        _downPos != null &&
        _pointer != null &&
        (_pointer! - _downPos!).distance >= 4;
    final ghost = moved ? _currentGhost() : null;
    _autoScroll?.cancel();
    _autoScroll = null;
    _autoDir = 0;
    setState(() {
      _dragging = null;
      _pointer = null;
      _downPos = null;
    });
    if (ghost != null) widget.onEventMove?.call(e, ghost.move);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = widget.days;
    final ghost = _dragging == null ? null : _currentGhost();
    return Column(
      children: [
        _buildHeader(theme),
        _buildStrip(theme, ghost),
        Divider(height: 1, color: theme.dividerColor),
        Expanded(
          child: SingleChildScrollView(
            key: _viewportKey,
            controller: _scroll,
            child: SizedBox(
              key: _gridKey,
              height: 24 * _hourHeight,
              child: Stack(
                children: [
                  _buildHourLines(theme),
                  Row(
                    children: [
                      const SizedBox(width: _gutterWidth),
                      for (var i = 0; i < days.length; i++)
                        Expanded(
                          child: _buildDayColumn(theme, days[i], i, ghost),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Row(
      children: [
        const SizedBox(width: _gutterWidth),
        for (final day in widget.days)
          Expanded(
            child: _DayHeaderCell(
              day: day,
              today: widget.today,
              holidayName: holidayNameOn(widget.events, day),
              onTap: widget.onDayHeaderTap == null
                  ? null
                  : () => widget.onDayHeaderTap!(day),
            ),
          ),
      ],
    );
  }

  Widget _buildStrip(ThemeData theme, _Ghost? ghost) {
    final days = widget.days;
    final padded = days.length == 7
        ? days
        : [for (var i = 0; i < 7; i++) addDays(days.first, i)];
    final bars = [
      for (final e in widget.events)
        if (e.isBar && !e.isHoliday) e,
    ];
    final layout = layoutWeek(padded, bars, maxRows: _stripMaxRows);
    final anyHidden = layout.hiddenCounts.take(days.length).any((n) => n > 0);
    final rows = math.max(layout.rowCount, anyHidden ? _stripMaxRows : 0);
    if (rows == 0) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final colW = (constraints.maxWidth - _gutterWidth) / days.length;
        return Container(
          key: _stripKey,
          height: rows * _stripRowHeight + 4,
          padding: const EdgeInsets.only(top: 2),
          child: Stack(
            children: [
              for (final seg in layout.segments)
                if (seg.startCol < days.length)
                  Positioned(
                    left: _gutterWidth + seg.startCol * colW,
                    width:
                        math.min(seg.span, days.length - seg.startCol) * colW,
                    top: seg.row * _stripRowHeight,
                    height: _stripRowHeight,
                    child: CalendarEventBar(
                      key: ValueKey(
                        'cal-strip-${seg.event.key}-${seg.startCol}',
                      ),
                      segment: seg,
                      compact: false,
                      dragHandle: _handle,
                      onTap: () => widget.onEventTap(seg.event),
                    ),
                  ),
              for (var c = 0; c < days.length; c++)
                if (layout.hiddenCounts[c] > 0)
                  Positioned(
                    left: _gutterWidth + c * colW,
                    width: colW,
                    top: (_stripMaxRows - 1) * _stripRowHeight,
                    height: _stripRowHeight,
                    child: InkWell(
                      onTap: () => widget.onMoreTap(days[c]),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            tr('+{p0}개', {'p0': layout.hiddenCounts[c]}),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              // 끄는 동안 날짜만 옮기는 일정의 도착 열 하이라이트 — 막대 위젯의 자리를 밀지 않게 맨 끝에 둔다.
              if (ghost != null && !ghost.timed)
                for (var c = 0; c < days.length; c++)
                  if (_ghostCovers(ghost, days[c]))
                    Positioned(
                      left: _gutterWidth + c * colW,
                      width: colW,
                      top: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: ColoredBox(color: dragHighlightColor(context)),
                      ),
                    ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHourLines(ThemeData theme) {
    return Column(
      children: [
        for (var h = 0; h < 24; h++)
          SizedBox(
            height: _hourHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: _gutterWidth,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Align(
                      alignment: Alignment.topRight,
                      child: Transform.translate(
                        offset: const Offset(0, -7),
                        child: Text(
                          h == 0 ? '' : _hourLabel(h),
                          style: TextStyle(
                            fontSize: 10,
                            color: theme.hintColor,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(
                          color: theme.dividerColor.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 고스트가 [day]를 덮는지 — 시간 블록이면 도착한 그 날, 날짜만 옮기는 막대면 새 기간 전체.
  bool _ghostCovers(_Ghost ghost, DateTime day) {
    if (ghost.timed) return sameDay(ghost.first, day);
    return !day.isBefore(ghost.first) && !day.isAfter(ghost.last);
  }

  Widget _buildDayColumn(
    ThemeData theme,
    DateTime day,
    int index,
    _Ghost? ghost,
  ) {
    final placements = layoutTimedDay(day, widget.events);
    final isToday = sameDay(day, widget.today);
    final handle = _handle;
    return LayoutBuilder(
      builder: (context, constraints) {
        final colW = constraints.maxWidth;
        return DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.6),
              ),
            ),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  key: ValueKey('cal-slot-${day.month}-${day.day}'),
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) {
                    final minutes =
                        ((details.localPosition.dy / _hourHeight) * 60)
                            .floor()
                            .clamp(0, 1439);
                    widget.onSlotTap(
                      DateTime(
                        day.year,
                        day.month,
                        day.day,
                        minutes ~/ 60,
                        minutes % 60 - minutes % 60 % 30,
                      ),
                    );
                  },
                ),
              ),
              for (final p in placements)
                Positioned(
                  left: colW * p.column / p.columnCount,
                  width: colW / p.columnCount - 2,
                  top: p.startMinutes / 60 * _hourHeight,
                  height: math.max(
                    18,
                    (p.endMinutes - p.startMinutes) / 60 * _hourHeight - 1,
                  ),
                  child: _TimedBlock(
                    key: ValueKey('cal-block-${p.event.key}'),
                    placement: p,
                    dragHandle: handle,
                    onTap: () => widget.onEventTap(p.event),
                  ),
                ),
              // 끄는 동안의 도착 열 하이라이트와 고스트 — 일정 블록 위젯의 자리를 밀지 않게 블록들 뒤에 둔다.
              if (ghost != null && _ghostCovers(ghost, day))
                Positioned.fill(
                  key: ValueKey('cal-drop-${day.month}-${day.day}'),
                  child: IgnorePointer(
                    child: ColoredBox(color: dragHighlightColor(context)),
                  ),
                ),
              if (ghost != null && ghost.timed && sameDay(ghost.first, day))
                _ghostBlock(ghost, colW),
              if (isToday) _nowLine(theme),
            ],
          ),
        );
      },
    );
  }

  /// 놓일 자리를 보여 주는 반투명 블록(시간 범위 글자 포함).
  Widget _ghostBlock(_Ghost ghost, double colW) {
    final e = ghost.event;
    final start = DateTime.fromMillisecondsSinceEpoch(ghost.move.start);
    final end = DateTime.fromMillisecondsSinceEpoch(ghost.move.end);
    final color = calendarColor(e.color);
    final startMin = start.hour * 60 + start.minute;
    final durationMin = ((ghost.move.end - ghost.move.start) / 60000).ceil();
    return Positioned(
      key: ValueKey('cal-ghost-${e.key}'),
      left: 0,
      width: colW - 2,
      top: startMin / 60 * _hourHeight,
      height: math.max(18, durationMin / 60 * _hourHeight - 1),
      child: IgnorePointer(
        child: Padding(
          padding: const EdgeInsets.only(left: 1),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.5),
              border: Border.all(color: color),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              child: Text(
                '${formatScheduleClock(start)} – ${formatScheduleClock(end)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: onCalendarColor(color),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _nowLine(ThemeData theme) {
    final now = DateTime.now();
    final top = (now.hour * 60 + now.minute) / 60 * _hourHeight;
    return Positioned(
      left: 0,
      right: 0,
      top: top,
      child: IgnorePointer(
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
              ),
            ),
            Expanded(child: Container(height: 1.5, color: Colors.red)),
          ],
        ),
      ),
    );
  }
}

/// "오전 9시" / "오후 1시" 시간표 눈금.
String _hourLabel(int hour) {
  if (hour == 12) return tr('오후 12시');
  return hour < 12
      ? tr('오전 {hour}시', {'hour': hour})
      : tr('오후 {p0}시', {'p0': hour - 12});
}

class _DayHeaderCell extends StatelessWidget {
  final DateTime day;
  final DateTime today;
  final String? holidayName;
  final VoidCallback? onTap;
  const _DayHeaderCell({
    required this.day,
    required this.today,
    required this.holidayName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isToday = sameDay(day, today);
    final red = day.weekday == DateTime.sunday || holidayName != null;
    final color = red
        ? kSundayColor
        : day.weekday == DateTime.saturday
        ? kSaturdayColor
        : theme.colorScheme.onSurface;
    return InkWell(
      key: ValueKey('cal-head-${day.month}-${day.day}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              weekdayShortKo(weekdayIndex(day)),
              style: TextStyle(fontSize: 11, color: color),
            ),
            const SizedBox(height: 2),
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isToday ? theme.colorScheme.primary : null,
                shape: BoxShape.circle,
              ),
              child: Text(
                '${day.day}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: isToday ? theme.colorScheme.onPrimary : color,
                ),
              ),
            ),
            if (holidayName != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  holidayName!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 9, color: kSundayColor),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TimedBlock extends StatelessWidget {
  final TimedPlacement placement;
  final VoidCallback onTap;
  final EventDragHandle? dragHandle;
  const _TimedBlock({
    super.key,
    required this.placement,
    required this.onTap,
    this.dragHandle,
  });

  @override
  Widget build(BuildContext context) {
    return EventDragSource(
      event: placement.event,
      handle: dragHandle,
      builder: _content,
    );
  }

  Widget _content(BuildContext context, MouseCursor? cursor) {
    final e = placement.event;
    final color = calendarColor(e.color);
    final fg = onCalendarColor(color);
    final tall = placement.endMinutes - placement.startMinutes >= 45;
    return Padding(
      padding: const EdgeInsets.only(left: 1),
      child: Material(
        color: color.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          mouseCursor: cursor,
          borderRadius: BorderRadius.circular(5),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  eventDisplayTitle(e),
                  maxLines: tall ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
                if (tall)
                  Text(
                    '${formatScheduleClock(e.startTime)} – ${formatScheduleClock(e.endTime)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: fg.withValues(alpha: 0.85),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
