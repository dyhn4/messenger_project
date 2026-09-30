import 'package:client/models/calendar.dart';
import 'package:client/services/calendar_layout.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_calendar_api.dart';

/// 월간 격자 계산, 여러 날 일정 막대 배치, "+N개" 접기, 시간표의 겹침 배치 — 위젯 없는 순수 계산.

void main() {
  group('월간 격자', () {
    test('2026년 9월은 8/30(일) 부터 10/3(토) 까지 5주', () {
      final weeks = monthGridWeeks(DateTime(2026, 9, 15));
      expect(weeks, hasLength(5));
      expect(weeks.first.first, DateTime(2026, 8, 30));
      expect(weeks.first.first.weekday, DateTime.sunday);
      expect(weeks.last.last, DateTime(2026, 10, 3));
      expect(weeks.every((w) => w.length == 7), isTrue);
    });

    test('1일이 일요일이고 28일까지인 달(2026년 2월)은 4주', () {
      final weeks = monthGridWeeks(DateTime(2026, 2, 10));
      expect(weeks, hasLength(4));
      expect(weeks.first.first, DateTime(2026, 2, 1));
      expect(weeks.last.last, DateTime(2026, 2, 28));
    });

    test('6주가 필요한 달(2026년 5월: 1일이 금요일)', () {
      final weeks = monthGridWeeks(DateTime(2026, 5, 1));
      expect(weeks, hasLength(6));
      expect(weeks.first.first, DateTime(2026, 4, 26));
      expect(weeks.last.last, DateTime(2026, 6, 6));
    });

    test('조회 범위는 [첫 칸, 마지막 칸 다음 날)', () {
      final range = monthGridRange(DateTime(2026, 9, 1));
      expect(range.from, DateTime(2026, 8, 30));
      expect(range.to, DateTime(2026, 10, 4));
    });

    test('weekStartOf 는 일요일, weekDays 는 7일', () {
      expect(weekStartOf(DateTime(2026, 9, 30, 15)), DateTime(2026, 9, 27));
      expect(weekStartOf(DateTime(2026, 9, 27)), DateTime(2026, 9, 27));
      expect(weekDays(DateTime(2026, 9, 30)).map((d) => d.day), [
        27,
        28,
        29,
        30,
        1,
        2,
        3,
      ]);
    });

    test('addDays 는 달·해를 넘는다', () {
      expect(addDays(DateTime(2026, 12, 31), 1), DateTime(2027, 1, 1));
      expect(addDays(DateTime(2026, 3, 1), -1), DateTime(2026, 2, 28));
    });
  });

  group('layoutWeek', () {
    // 2026-09-27(일) ~ 10-03(토)
    final week = weekDays(DateTime(2026, 9, 30));

    test('여러 날 종일 일정은 한 줄에 가로로 이어진다', () {
      final e = allDayEvent('a', DateTime(2026, 9, 29), DateTime(2026, 10, 1));
      final layout = layoutWeek(week, [e], maxRows: 4);
      expect(layout.segments, hasLength(1));
      final s = layout.segments.single;
      expect(s.startCol, 2);
      expect(s.endCol, 4);
      expect(s.row, 0);
      expect(s.span, 3);
      expect(s.continuesBefore, isFalse);
      expect(s.continuesAfter, isFalse);
    });

    test('주 경계를 넘는 일정은 이어짐 표시가 붙는다', () {
      final e = allDayEvent('a', DateTime(2026, 9, 24), DateTime(2026, 9, 29));
      final layout = layoutWeek(week, [e], maxRows: 4);
      final s = layout.segments.single;
      expect(s.startCol, 0);
      expect(s.endCol, 2);
      expect(s.continuesBefore, isTrue);
      expect(s.continuesAfter, isFalse);

      final e2 = allDayEvent('b', DateTime(2026, 10, 2), DateTime(2026, 10, 8));
      final s2 = layoutWeek(week, [e2], maxRows: 4).segments.single;
      expect(s2.startCol, 5);
      expect(s2.endCol, 6);
      expect(s2.continuesAfter, isTrue);
    });

    test('겹치는 일정은 다른 줄로, 안 겹치면 같은 줄을 나눠 쓴다', () {
      final a = allDayEvent('a', DateTime(2026, 9, 28), DateTime(2026, 9, 30));
      final b = allDayEvent('b', DateTime(2026, 9, 29), DateTime(2026, 10, 1));
      final c = allDayEvent('c', DateTime(2026, 10, 2), DateTime(2026, 10, 3));
      final layout = layoutWeek(week, [a, b, c], maxRows: 4);
      int rowOf(String id) =>
          layout.segments.firstWhere((s) => s.event.eventId == id).row;
      expect(rowOf('a'), 0);
      expect(rowOf('b'), 1);
      expect(rowOf('c'), 0, reason: 'c 는 a 와 열이 겹치지 않아 첫 줄을 다시 쓴다');
      expect(layout.rowCount, 2);
    });

    test('종일 막대가 시간 일정보다 위 줄을 먼저 차지한다', () {
      final timed = timedEvent(
        't',
        DateTime(2026, 9, 29, 9),
        DateTime(2026, 9, 29, 10),
      );
      final bar = allDayEvent(
        'a',
        DateTime(2026, 9, 29),
        DateTime(2026, 9, 29),
      );
      final layout = layoutWeek(week, [timed, bar], maxRows: 4);
      expect(layout.segments.firstWhere((s) => s.event.eventId == 'a').row, 0);
      expect(layout.segments.firstWhere((s) => s.event.eventId == 't').row, 1);
    });

    test('한 날 일정이 한도를 넘으면 마지막 줄을 "+N개"에 내준다', () {
      // 9/29 에 시간 일정 4개, maxRows 3 → 보이는 줄 2개, 접힌 2개.
      final events = [
        for (var i = 0; i < 4; i++)
          timedEvent(
            't$i',
            DateTime(2026, 9, 29, 9 + i),
            DateTime(2026, 9, 29, 10 + i),
          ),
      ];
      final layout = layoutWeek(week, events, maxRows: 3);
      expect(layout.segments, hasLength(2));
      expect(layout.hiddenCounts[2], 2);
      expect(layout.hiddenCounts.where((n) => n > 0), hasLength(1));
    });

    test('정확히 한도만큼이면 접지 않는다', () {
      final events = [
        for (var i = 0; i < 3; i++)
          timedEvent(
            't$i',
            DateTime(2026, 9, 29, 9 + i),
            DateTime(2026, 9, 29, 10 + i),
          ),
      ];
      final layout = layoutWeek(week, events, maxRows: 3);
      expect(layout.segments, hasLength(3));
      expect(layout.hiddenCounts.every((n) => n == 0), isTrue);
    });

    test('여러 날 막대가 접히는 날에서는 끊어진 조각이 된다', () {
      // 9/29~10/1 막대 + 9/30 에만 시간 일정 2개. maxRows 2 → 9/30 은 1줄만 보인다.
      final bar = allDayEvent(
        'bar',
        DateTime(2026, 9, 29),
        DateTime(2026, 10, 1),
      );
      final t1 = timedEvent(
        't1',
        DateTime(2026, 9, 30, 9),
        DateTime(2026, 9, 30, 10),
      );
      final t2 = timedEvent(
        't2',
        DateTime(2026, 9, 30, 11),
        DateTime(2026, 9, 30, 12),
      );
      final layout = layoutWeek(week, [bar, t1, t2], maxRows: 2);
      // 9/30(열 3): bar(row0), t1(row1), t2(row2) → 한도 1줄만 보이고 2개 접힘.
      expect(layout.hiddenCounts[3], 2);
      final barSegs = layout.segments.where((s) => s.event.eventId == 'bar');
      expect(barSegs, hasLength(1), reason: '막대는 row0 이라 접히지 않는다');
      expect(layout.segments.where((s) => s.event.eventId == 't1'), isEmpty);
    });

    test('공휴일은 막대에 넣지 않는다', () {
      final h = holidayEvent(DateTime(2026, 9, 29), '추석');
      final layout = layoutWeek(week, [h], maxRows: 3);
      expect(layout.segments, isEmpty);
      expect(holidayNameOn([h], DateTime(2026, 9, 29)), '추석');
      expect(holidayNameOn([h], DateTime(2026, 9, 30)), isNull);
    });

    test('주 밖의 일정은 무시한다', () {
      final e = allDayEvent(
        'a',
        DateTime(2026, 10, 10),
        DateTime(2026, 10, 11),
      );
      expect(layoutWeek(week, [e], maxRows: 3).segments, isEmpty);
    });
  });

  group('layoutTimedDay', () {
    final day = DateTime(2026, 9, 30);

    test('시각에 맞춰 분 단위로 놓는다', () {
      final e = timedEvent(
        'a',
        DateTime(2026, 9, 30, 9, 30),
        DateTime(2026, 9, 30, 11),
      );
      final p = layoutTimedDay(day, [e]).single;
      expect(p.startMinutes, 9 * 60 + 30);
      expect(p.endMinutes, 11 * 60);
      expect(p.column, 0);
      expect(p.columnCount, 1);
    });

    test('겹치는 일정은 열을 나눠 나란히 선다', () {
      final a = timedEvent(
        'a',
        DateTime(2026, 9, 30, 9),
        DateTime(2026, 9, 30, 11),
      );
      final b = timedEvent(
        'b',
        DateTime(2026, 9, 30, 10),
        DateTime(2026, 9, 30, 12),
      );
      final c = timedEvent(
        'c',
        DateTime(2026, 9, 30, 13),
        DateTime(2026, 9, 30, 14),
      );
      final ps = layoutTimedDay(day, [a, b, c]);
      TimedPlacement of(String id) =>
          ps.firstWhere((p) => p.event.eventId == id);
      expect(of('a').columnCount, 2);
      expect(of('b').columnCount, 2);
      expect({of('a').column, of('b').column}, {0, 1});
      expect(of('c').columnCount, 1, reason: '겹치지 않는 일정은 혼자 한 열을 다 쓴다');
    });

    test('너무 짧은 일정도 눌러 볼 수 있게 최소 높이를 준다', () {
      final e = timedEvent(
        'a',
        DateTime(2026, 9, 30, 9),
        DateTime(2026, 9, 30, 9, 5),
      );
      final p = layoutTimedDay(day, [e]).single;
      expect(p.endMinutes - p.startMinutes, kMinTimedMinutes);
    });

    test('종일·여러 날 일정은 시간표에 넣지 않는다', () {
      final bar = allDayEvent(
        'a',
        DateTime(2026, 9, 30),
        DateTime(2026, 9, 30),
      );
      final multi = timedEvent(
        'm',
        DateTime(2026, 9, 30, 22),
        DateTime(2026, 10, 1, 2),
      );
      expect(layoutTimedDay(day, [bar, multi]), isEmpty);
    });
  });

  group('기타 계산', () {
    test('groupEventsByDay: 일정이 있는 날만, 여러 날 일정은 걸친 날마다', () {
      final multi = allDayEvent(
        'm',
        DateTime(2026, 9, 29),
        DateTime(2026, 9, 30),
      );
      final t = timedEvent(
        't',
        DateTime(2026, 10, 2, 9),
        DateTime(2026, 10, 2, 10),
      );
      final grouped = groupEventsByDay(
        [multi, t],
        DateTime(2026, 9, 1),
        DateTime(2026, 10, 1),
      );
      expect(grouped.keys.map((d) => d.day), [29, 30]);
      expect(grouped[DateTime(2026, 9, 30)]!.single.eventId, 'm');
    });

    test('하루 안에서는 종일이 먼저, 그다음 시각순', () {
      final late = timedEvent(
        'late',
        DateTime(2026, 9, 30, 15),
        DateTime(2026, 9, 30, 16),
      );
      final early = timedEvent(
        'early',
        DateTime(2026, 9, 30, 8),
        DateTime(2026, 9, 30, 9),
      );
      final allDay = allDayEvent(
        'all',
        DateTime(2026, 9, 30),
        DateTime(2026, 9, 30),
      );
      final list = eventsOnDay([late, early, allDay], DateTime(2026, 9, 30));
      expect(list.map((e) => e.eventId), ['all', 'early', 'late']);
    });

    test('시각을 10분 단위로 내리고 올린다', () {
      expect(
        floorToMinutes(DateTime(2026, 9, 30, 9, 47)),
        DateTime(2026, 9, 30, 9, 40),
      );
      expect(
        ceilToMinutes(DateTime(2026, 9, 30, 9, 41)),
        DateTime(2026, 9, 30, 9, 50),
      );
      expect(
        ceilToMinutes(DateTime(2026, 9, 30, 9, 40)),
        DateTime(2026, 9, 30, 9, 40),
      );
      expect(
        ceilToMinutes(DateTime(2026, 9, 30, 23, 55)),
        DateTime(2026, 10, 1, 0, 0),
      );
    });
  });
}
