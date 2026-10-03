import 'dart:ui' show Offset, Size;

import '../models/calendar.dart';

// 캘린더 화면의 순수 계산 — 위젯 없이 테스트할 수 있도록 격자 계산·일정 배치를 따로 뺐다.
// 모든 날짜는 "시각 없는 날짜(dateOnly)"이고 한 주는 일요일에 시작한다.

/// [d]가 속한 주의 일요일.
DateTime weekStartOf(DateTime d) {
  final day = dateOnly(d);
  return addDays(day, -(day.weekday % 7));
}

/// [month](아무 날이나)가 속한 달의 첫날.
DateTime monthStartOf(DateTime month) => DateTime(month.year, month.month, 1);

/// 월간 격자의 주(일요일 시작) 목록 — 그 달의 첫날이 든 주부터 마지막 날이 든 주까지(4~6줄).
List<List<DateTime>> monthGridWeeks(DateTime month) {
  final first = monthStartOf(month);
  final last = DateTime(month.year, month.month + 1, 0);
  final weeks = <List<DateTime>>[];
  var cursor = weekStartOf(first);
  while (!cursor.isAfter(last)) {
    weeks.add([for (var i = 0; i < 7; i++) addDays(cursor, i)]);
    cursor = addDays(cursor, 7);
  }
  return weeks;
}

/// 월간 격자가 그리는 날짜 범위 [from, to) — 일정 조회 구간을 정할 때 쓴다.
({DateTime from, DateTime to}) monthGridRange(DateTime month) {
  final weeks = monthGridWeeks(month);
  return (from: weeks.first.first, to: addDays(weeks.last.last, 1));
}

/// 한 주(7일)의 날짜들.
List<DateTime> weekDays(DateTime anyDayInWeek) {
  final start = weekStartOf(anyDayInWeek);
  return [for (var i = 0; i < 7; i++) addDays(start, i)];
}

/// [day]에 걸친 일정을 화면에 보일 순서로 — 종일·여러 날 일정이 먼저, 그다음 시작 시각순.
List<EventOccurrence> eventsOnDay(List<EventOccurrence> events, DateTime day) {
  final d = dateOnly(day);
  final list = [
    for (final e in events)
      if (e.coversDay(d)) e,
  ];
  list.sort(compareForDay);
  return list;
}

/// 같은 날 안에서의 표시 순서 — 막대(종일·여러 날)가 먼저, 그다음 시작 시각, 제목.
int compareForDay(EventOccurrence a, EventOccurrence b) {
  if (a.isBar != b.isBar) return a.isBar ? -1 : 1;
  final byStart = a.start.compareTo(b.start);
  if (byStart != 0) return byStart;
  return a.title.compareTo(b.title);
}

/// 월간(한 주 한 줄)에서 일정 하나가 차지하는 가로 조각.
class BarSegment {
  final EventOccurrence event;

  /// 이 주에서 차지하는 열(0=일 … 6=토), 양 끝 포함.
  final int startCol;
  final int endCol;

  /// 위에서 몇 번째 줄인지(0부터).
  final int row;

  /// 이 조각의 왼쪽/오른쪽이 이 주 밖(또는 잘린 칸)으로 이어지는지 — 막대 끝 모양을 정한다.
  final bool continuesBefore;
  final bool continuesAfter;

  const BarSegment({
    required this.event,
    required this.startCol,
    required this.endCol,
    required this.row,
    required this.continuesBefore,
    required this.continuesAfter,
  });

  int get span => endCol - startCol + 1;
}

/// [layoutWeek]의 결과.
class WeekLayout {
  final List<BarSegment> segments;

  /// 열마다 "+N개"로 접힌 일정 개수(0이면 접힌 게 없다).
  final List<int> hiddenCounts;

  /// 쓰인 줄 수(접힌 줄 제외) — 주간 뷰의 종일 칸 높이를 정할 때 쓴다.
  final int rowCount;

  const WeekLayout({
    required this.segments,
    required this.hiddenCounts,
    required this.rowCount,
  });
}

/// 한 주([days] 7일)에 일정을 줄로 배치한다. 종일·여러 날 일정은 가로로 이어지는 막대가 되고, 한 날짜만
/// 차지하는 시간 일정도 같은 줄 체계에 한 칸짜리로 들어간다(그래야 두 종류가 서로 겹치지 않는다).
/// 공휴일은 날짜 칸에 이름으로 따로 보여 주므로 여기서는 뺀다.
///
/// 한 칸의 높이에는 [maxRows]줄까지만 들어간다. 그날 일정이 그보다 많으면 마지막 줄을 "+N개"에 내주고
/// (그래서 보이는 줄은 maxRows-1) 넘친 일정 수를 [WeekLayout.hiddenCounts]에 센다. 여러 날 막대가 어느
/// 날에서만 접히면 그 막대는 보이는 날들끼리 끊어진 조각으로 나뉜다.
WeekLayout layoutWeek(
  List<DateTime> days,
  List<EventOccurrence> events, {
  required int maxRows,
}) {
  assert(days.length == 7);
  final firstDay = dateOnly(days.first);
  final lastDay = dateOnly(days.last);

  final items = <_Item>[];
  for (final e in events) {
    if (e.isHoliday) continue;
    if (e.lastDay.isBefore(firstDay) || e.firstDay.isAfter(lastDay)) continue;
    final startCol = e.firstDay.isBefore(firstDay)
        ? 0
        : e.firstDay.difference(firstDay).inDays.clamp(0, 6);
    final endCol = e.lastDay.isAfter(lastDay)
        ? 6
        : e.lastDay.difference(firstDay).inDays.clamp(0, 6);
    items.add(
      _Item(
        e,
        startCol,
        endCol,
        e.firstDay.isBefore(firstDay),
        e.lastDay.isAfter(lastDay),
      ),
    );
  }

  // 막대(종일·여러 날)가 위쪽 줄을 먼저 차지한다. 그 안에서는 왼쪽부터, 같은 시작이면 긴 것부터.
  items.sort((a, b) {
    if (a.event.isBar != b.event.isBar) return a.event.isBar ? -1 : 1;
    final byCol = a.startCol.compareTo(b.startCol);
    if (byCol != 0) return byCol;
    final bySpan = (b.endCol - b.startCol).compareTo(a.endCol - a.startCol);
    if (bySpan != 0) return bySpan;
    final byStart = a.event.start.compareTo(b.event.start);
    if (byStart != 0) return byStart;
    return a.event.title.compareTo(b.event.title);
  });

  // 줄마다 어느 열이 이미 찼는지.
  final rows = <List<bool>>[];
  for (final item in items) {
    var r = 0;
    while (true) {
      if (r == rows.length) rows.add(List.filled(7, false));
      var free = true;
      for (var c = item.startCol; c <= item.endCol; c++) {
        if (rows[r][c]) {
          free = false;
          break;
        }
      }
      if (free) break;
      r++;
    }
    for (var c = item.startCol; c <= item.endCol; c++) {
      rows[r][c] = true;
    }
    item.row = r;
  }

  // 열마다 보이는 줄 수 한도 — 어느 일정이라도 maxRows 밖이면 마지막 줄을 "+N개"에 내준다.
  final limits = List<int>.filled(7, maxRows);
  final hidden = List<int>.filled(7, 0);
  for (var c = 0; c < 7; c++) {
    final covering = [
      for (final i in items)
        if (i.startCol <= c && c <= i.endCol) i,
    ];
    if (covering.any((i) => i.row >= maxRows)) {
      limits[c] = maxRows - 1 < 0 ? 0 : maxRows - 1;
      hidden[c] = covering.where((i) => i.row >= limits[c]).length;
    }
  }

  final segments = <BarSegment>[];
  var used = 0;
  for (final item in items) {
    int? runStart;
    for (var c = item.startCol; c <= item.endCol + 1; c++) {
      final visible = c <= item.endCol && item.row < limits[c];
      if (visible && runStart == null) runStart = c;
      if (!visible && runStart != null) {
        final runEnd = c - 1;
        segments.add(
          BarSegment(
            event: item.event,
            startCol: runStart,
            endCol: runEnd,
            row: item.row,
            continuesBefore: runStart > item.startCol || item.continuesBefore,
            continuesAfter: runEnd < item.endCol || item.continuesAfter,
          ),
        );
        if (item.row + 1 > used) used = item.row + 1;
        runStart = null;
      }
    }
  }

  return WeekLayout(segments: segments, hiddenCounts: hidden, rowCount: used);
}

class _Item {
  final EventOccurrence event;
  final int startCol;
  final int endCol;
  final bool continuesBefore;
  final bool continuesAfter;
  int row = 0;
  _Item(
    this.event,
    this.startCol,
    this.endCol,
    this.continuesBefore,
    this.continuesAfter,
  );
}

/// 주간·일간 시간표에서 시간 일정 하나의 자리.
class TimedPlacement {
  final EventOccurrence event;

  /// 그날 0시부터의 분(0~1440). 화면에 그리는 끝은 너무 짧은 일정도 눌러 볼 수 있게 늘려 둔 값이다.
  final int startMinutes;
  final int endMinutes;

  /// 겹치는 일정끼리 나란히 세울 때의 몇 번째 열 / 전체 열 수.
  final int column;
  final int columnCount;

  const TimedPlacement({
    required this.event,
    required this.startMinutes,
    required this.endMinutes,
    required this.column,
    required this.columnCount,
  });
}

/// 시간표에서 눌러 볼 수 있는 일정의 최소 높이(분).
const kMinTimedMinutes = 30;

/// 한 날짜의 시간 일정(종일·여러 날 일정 제외)을 시간표 위에 놓는다. 서로 시간이 겹치는 일정은 같은
/// 묶음에서 열을 나눠 나란히 서게 한다.
List<TimedPlacement> layoutTimedDay(
  DateTime day,
  List<EventOccurrence> events,
) {
  final d = dateOnly(day);
  final dayStartMs = d.millisecondsSinceEpoch;
  final nextDayMs = addDays(d, 1).millisecondsSinceEpoch;
  final entries = <(EventOccurrence, int, int)>[];
  for (final e in events) {
    if (e.isBar || e.allDay) continue;
    if (!e.coversDay(d)) continue;
    final startMin =
        ((e.start.clamp(dayStartMs, nextDayMs) - dayStartMs) / 60000).floor();
    var endMin = ((e.end.clamp(dayStartMs, nextDayMs) - dayStartMs) / 60000)
        .ceil();
    if (endMin < startMin + kMinTimedMinutes) {
      endMin = startMin + kMinTimedMinutes;
    }
    if (endMin > 1440) endMin = 1440;
    entries.add((e, startMin, endMin));
  }
  entries.sort((a, b) {
    final byStart = a.$2.compareTo(b.$2);
    if (byStart != 0) return byStart;
    return b.$3.compareTo(a.$3);
  });

  final result = <TimedPlacement>[];
  var i = 0;
  while (i < entries.length) {
    // 시간이 이어서 겹치는 일정들을 한 묶음으로.
    var clusterEnd = entries[i].$3;
    var j = i + 1;
    while (j < entries.length && entries[j].$2 < clusterEnd) {
      if (entries[j].$3 > clusterEnd) clusterEnd = entries[j].$3;
      j++;
    }
    final colEnds = <int>[];
    final assigned = <(EventOccurrence, int, int, int)>[];
    for (var k = i; k < j; k++) {
      final (e, s, en) = entries[k];
      var col = colEnds.indexWhere((end) => end <= s);
      if (col < 0) {
        colEnds.add(en);
        col = colEnds.length - 1;
      } else {
        colEnds[col] = en;
      }
      assigned.add((e, s, en, col));
    }
    for (final (e, s, en, col) in assigned) {
      result.add(
        TimedPlacement(
          event: e,
          startMinutes: s,
          endMinutes: en,
          column: col,
          columnCount: colEnds.length,
        ),
      );
    }
    i = j;
  }
  return result;
}

/// [events] 중 [from]~[to)(날짜, to는 배타)에 걸친 것을 날짜별로 묶는다(목록 보기). 여러 날 일정은 걸친
/// 날마다 나온다. 일정이 없는 날은 키가 없다.
Map<DateTime, List<EventOccurrence>> groupEventsByDay(
  List<EventOccurrence> events,
  DateTime from,
  DateTime to,
) {
  final result = <DateTime, List<EventOccurrence>>{};
  for (var d = dateOnly(from); d.isBefore(to); d = addDays(d, 1)) {
    final list = eventsOnDay(events, d);
    if (list.isNotEmpty) result[d] = list;
  }
  return result;
}

/// 공휴일 이름 — [day]가 공휴일이면 그 이름(여러 개면 " · "로 이어서), 아니면 null.
String? holidayNameOn(List<EventOccurrence> events, DateTime day) {
  final names = [
    for (final e in events)
      if (e.isHoliday && e.coversDay(day)) e.title,
  ];
  return names.isEmpty ? null : names.join(' · ');
}

/// 시각을 [minutes]분 단위로 내린다(일정 시간은 10분 단위로만 고르게 한다).
DateTime floorToMinutes(DateTime t, [int minutes = 10]) =>
    DateTime(t.year, t.month, t.day, t.hour, t.minute - t.minute % minutes);

/// [t] 이후의 첫 [minutes]분 단위 시각(이미 딱 맞으면 그대로).
DateTime ceilToMinutes(DateTime t, [int minutes = 10]) {
  final floored = floorToMinutes(t, minutes);
  final exact =
      floored.hour == t.hour &&
      floored.minute == t.minute &&
      t.second == 0 &&
      t.millisecond == 0;
  return exact ? floored : floored.add(Duration(minutes: minutes));
}

/// 월간 격자(주 [weeks])에서 [local](격자 영역 안 좌표, [size]는 영역 크기)이 가리키는 날짜 칸 — 영역 밖이면 null.
DateTime? monthCellDayAt(Size size, Offset local, List<List<DateTime>> weeks) {
  if (weeks.isEmpty || size.isEmpty) return null;
  if (local.dx < 0 ||
      local.dy < 0 ||
      local.dx >= size.width ||
      local.dy >= size.height) {
    return null;
  }
  final row = (local.dy / (size.height / weeks.length)).floor().clamp(
    0,
    weeks.length - 1,
  );
  final col = (local.dx / (size.width / 7)).floor().clamp(0, 6);
  return weeks[row][col];
}
