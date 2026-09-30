import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/calendar.dart';
import '../../services/calendar_layout.dart';
import '../../services/time_format.dart';
import 'calendar_common.dart';
import 'calendar_month_view.dart' show CalendarEventBar;

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

  const CalendarTimeGrid({
    super.key,
    required this.days,
    required this.events,
    required this.today,
    required this.onEventTap,
    required this.onSlotTap,
    required this.onMoreTap,
    this.onDayHeaderTap,
  });

  @override
  State<CalendarTimeGrid> createState() => _CalendarTimeGridState();
}

const _hourHeight = 52.0;
const _gutterWidth = 54.0;
const _stripRowHeight = 21.0;
const _stripMaxRows = 4;

class _CalendarTimeGridState extends State<CalendarTimeGrid> {
  late final ScrollController _scroll;

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
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = widget.days;
    return Column(
      children: [
        _buildHeader(theme),
        _buildStrip(theme),
        Divider(height: 1, color: theme.dividerColor),
        Expanded(
          child: SingleChildScrollView(
            controller: _scroll,
            child: SizedBox(
              height: 24 * _hourHeight,
              child: Stack(
                children: [
                  _buildHourLines(theme),
                  Row(
                    children: [
                      const SizedBox(width: _gutterWidth),
                      for (var i = 0; i < days.length; i++)
                        Expanded(child: _buildDayColumn(theme, days[i], i)),
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

  Widget _buildStrip(ThemeData theme) {
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
                            '+${layout.hiddenCounts[c]}개',
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

  Widget _buildDayColumn(ThemeData theme, DateTime day, int index) {
    final placements = layoutTimedDay(day, widget.events);
    final isToday = sameDay(day, widget.today);
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
                    onTap: () => widget.onEventTap(p.event),
                  ),
                ),
              if (isToday) _nowLine(theme),
            ],
          ),
        );
      },
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
  if (hour == 12) return '오후 12시';
  return hour < 12 ? '오전 $hour시' : '오후 ${hour - 12}시';
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
  const _TimedBlock({super.key, required this.placement, required this.onTap});

  @override
  Widget build(BuildContext context) {
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
