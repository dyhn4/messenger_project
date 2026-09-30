import 'package:flutter/material.dart';

import '../../models/calendar.dart';
import '../../services/calendar_layout.dart';
import 'calendar_common.dart';

/// 월간 보기 — 일요일 시작 격자. 종일·여러 날 일정은 날짜 칸을 가로지르는 막대로 이어지고, 한 칸에
/// 다 못 넣는 일정은 "+N개"로 접는다. 공휴일은 날짜 숫자를 빨갛게 하고 이름을 옆에 적는다.
///
/// [compact]는 모바일 위쪽 격자용 — 글자와 줄 높이를 줄이고 공휴일 이름은 숫자 색으로만 보인다.
class CalendarMonthView extends StatelessWidget {
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

  const CalendarMonthView({
    super.key,
    required this.month,
    required this.events,
    required this.today,
    required this.onDayTap,
    required this.onEventTap,
    required this.onMoreTap,
    this.selectedDay,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final weeks = monthGridWeeks(month);
    final theme = Theme.of(context);
    return Column(
      children: [
        _WeekdayHeader(compact: compact),
        Expanded(
          child: Column(
            children: [
              for (final week in weeks)
                Expanded(
                  child: _WeekRow(
                    days: week,
                    month: month,
                    events: events,
                    today: today,
                    selectedDay: selectedDay,
                    compact: compact,
                    borderColor: theme.dividerColor,
                    onDayTap: onDayTap,
                    onEventTap: onEventTap,
                    onMoreTap: onMoreTap,
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
                          '+${layout.hiddenCounts[c]}개',
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
          ],
        );
      },
    );
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
      label: '${day.month}월 ${day.day}일${isHoliday ? ' $holidayName' : ''}',
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
  const CalendarEventBar({
    super.key,
    required this.segment,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
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
