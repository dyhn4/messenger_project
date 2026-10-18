import 'package:flutter/material.dart';

import '../../models/calendar.dart';
import '../../services/calendar_layout.dart';
import '../../widgets/muted_scrollbar.dart';
import 'calendar_common.dart';
import '../../l10n/tr.dart';

/// 일정 한 줄 — 왼쪽 색 띠, 시간(종일/시작 시각), 제목, 장소·캘린더 이름. 목록 보기·모바일의 "선택한 날"
/// 목록·"+N개" 대화상자가 같이 쓴다.
class CalendarEventTile extends StatelessWidget {
  final EventOccurrence event;

  /// 여러 날 일정이 그 날짜에서 어떻게 보일지 정하는 기준 날짜("계속"으로 표시).
  final DateTime? onDay;

  /// 이름을 보여 줄 캘린더(없으면 생략).
  final String? calendarName;
  final VoidCallback onTap;

  const CalendarEventTile({
    super.key,
    required this.event,
    required this.onTap,
    this.onDay,
    this.calendarName,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = calendarColor(event.color);
    final name = (calendarName ?? '').isEmpty ? null : calendarName;
    final sub = [
      ?name,
      if ((event.location ?? '').isNotEmpty) event.location!,
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 64,
              child: Text(
                formatEventTimeShort(event, onDay: onDay),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ),
            Container(
              width: 4,
              height: 34,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (event.restricted)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(
                            Icons.lock_outline,
                            size: 14,
                            color: theme.hintColor,
                          ),
                        ),
                      Expanded(
                        child: Text(
                          eventDisplayTitle(event),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (sub.isNotEmpty)
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 그 날의 공휴일 이름을 붙인 날짜 머리글 — "9월 30일 (수)  추석".
class CalendarDayHeader extends StatelessWidget {
  final DateTime day;
  final String? holidayName;
  final bool isToday;
  const CalendarDayHeader({
    super.key,
    required this.day,
    this.holidayName,
    this.isToday = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final red = day.weekday == DateTime.sunday || holidayName != null;
    final color = red
        ? kSundayColor
        : day.weekday == DateTime.saturday
        ? kSaturdayColor
        : theme.colorScheme.onSurface;
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Text(
            formatDayLabel(day),
            style: theme.textTheme.labelLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (isToday) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                tr('오늘'),
                style: TextStyle(
                  fontSize: 10,
                  color: theme.colorScheme.onPrimary,
                ),
              ),
            ),
          ],
          if (holidayName != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                holidayName!,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: kSundayColor),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 하루의 일정 목록(모바일 월간 아래 "선택한 날", 데스크톱 "+N개" 대화상자). 공휴일 이름을 맨 위에 적는다.
class CalendarDayEventList extends StatelessWidget {
  final DateTime day;
  final List<EventOccurrence> events;
  final String Function(EventOccurrence) calendarNameOf;
  final ValueChanged<EventOccurrence> onEventTap;
  final ScrollController? controller;

  /// 맨 위에 공휴일 이름 줄을 둘지 — 날짜 머리글이 이미 공휴일을 보여 주는 화면은 끈다.
  final bool showHoliday;

  const CalendarDayEventList({
    super.key,
    required this.day,
    required this.events,
    required this.calendarNameOf,
    required this.onEventTap,
    this.controller,
    this.showHoliday = true,
  });

  @override
  Widget build(BuildContext context) {
    final holiday = showHoliday ? holidayNameOn(events, day) : null;
    final list = [
      for (final e in eventsOnDay(events, day))
        if (!e.isHoliday) e,
    ];
    final theme = Theme.of(context);
    return ListView(
      controller: controller,
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        if (holiday != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                const Icon(Icons.flag_outlined, size: 16, color: kSundayColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    holiday,
                    style: const TextStyle(
                      color: kSundayColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text(
                tr('일정이 없습니다.'),
                style: TextStyle(color: theme.hintColor),
              ),
            ),
          ),
        for (final e in list)
          CalendarEventTile(
            key: ValueKey('cal-tile-${e.key}'),
            event: e,
            onDay: day,
            calendarName: calendarNameOf(e),
            onTap: () => onEventTap(e),
          ),
      ],
    );
  }
}

/// 월간 칸의 "+N개"를 눌렀을 때 그 날 일정을 모아 보여 주는 대화상자(데스크톱).
Future<void> showDayEventsDialog(
  BuildContext context, {
  required DateTime day,
  required List<EventOccurrence> events,
  required String Function(EventOccurrence) calendarNameOf,
  required ValueChanged<EventOccurrence> onEventTap,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      formatDayLabel(day),
                      style: Theme.of(dialogContext).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(dialogContext).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: CalendarDayEventList(
                day: day,
                events: events,
                calendarNameOf: calendarNameOf,
                onEventTap: (e) {
                  Navigator.of(dialogContext).pop();
                  onEventTap(e);
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 목록 보기 — 선택한 기간([from, to))의 일정을 날짜별로 나열한다. 일정이 없는 날은 건너뛴다.
class CalendarListView extends StatefulWidget {
  final DateTime from;
  final DateTime to;
  final DateTime today;
  final List<EventOccurrence> events;
  final String Function(EventOccurrence) calendarNameOf;
  final ValueChanged<EventOccurrence> onEventTap;

  const CalendarListView({
    super.key,
    required this.from,
    required this.to,
    required this.today,
    required this.events,
    required this.calendarNameOf,
    required this.onEventTap,
  });

  @override
  State<CalendarListView> createState() => _CalendarListViewState();
}

class _CalendarListViewState extends State<CalendarListView> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final grouped = groupEventsByDay(widget.events, widget.from, widget.to);
    final theme = Theme.of(context);
    if (grouped.isEmpty) {
      return Center(
        child: Text(
          tr('이 기간에 일정이 없습니다.'),
          style: TextStyle(color: theme.hintColor),
        ),
      );
    }
    final days = grouped.keys.toList();
    return MutedScrollbar(
      controller: _scroll,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: 88),
        itemCount: days.length,
        itemBuilder: (context, i) {
          final day = days[i];
          final items = grouped[day]!;
          final holiday = holidayNameOn(items, day);
          final userItems = [
            for (final e in items)
              if (!e.isHoliday) e,
          ];
          return Column(
            key: ValueKey('cal-list-day-${day.month}-${day.day}'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CalendarDayHeader(
                day: day,
                holidayName: holiday,
                isToday: sameDay(day, widget.today),
              ),
              for (final e in userItems)
                CalendarEventTile(
                  key: ValueKey('cal-tile-${e.key}-${day.day}'),
                  event: e,
                  onDay: day,
                  calendarName: widget.calendarNameOf(e),
                  onTap: () => widget.onEventTap(e),
                ),
            ],
          );
        },
      ),
    );
  }
}
