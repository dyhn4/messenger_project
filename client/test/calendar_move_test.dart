import 'package:client/models/calendar.dart';
import 'package:client/services/calendar_layout.dart';
import 'package:client/services/calendar_move.dart';
import 'package:flutter/painting.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_calendar_api.dart';

/// 일정 드래그 이동의 순수 계산 시험 — 여러 날 일정, 종일/시간 일정, 월말·연말, 시간대 경계, 10분 스냅, 드래그 가능 조건.

int _ms(int y, int m, int d, [int h = 0, int min = 0]) =>
    DateTime(y, m, d, h, min).millisecondsSinceEpoch;

void main() {
  group('드래그 가능 조건', () {
    final base = timedEvent(
      'e',
      DateTime(2026, 9, 10, 9),
      DateTime(2026, 9, 10, 10),
    );

    test('내가 수정할 수 있는 반복 아닌 사용자 일정만', () {
      expect(canDragEvent(base), isTrue);
      expect(
        canDragEvent(
          allDayEvent('a', DateTime(2026, 9, 3), DateTime(2026, 9, 3)),
        ),
        isTrue,
      );
    });

    test('반복 일정·권한 없는 일정·제한된(비공개) 일정·공휴일·생일은 안 된다', () {
      final recurring = timedEvent(
        'r',
        DateTime(2026, 9, 10, 9),
        DateTime(2026, 9, 10, 10),
        recurring: true,
        recurrence: const Recurrence(freq: 'weekly'),
      );
      expect(canDragEvent(recurring), isFalse);
      expect(isDragBlockedByRecurrence(recurring), isTrue);
      final readOnly = timedEvent(
        'ro',
        DateTime(2026, 9, 10, 9),
        DateTime(2026, 9, 10, 10),
        canEdit: false,
      );
      expect(canDragEvent(readOnly), isFalse);
      expect(isDragBlockedByRecurrence(readOnly), isFalse);
      final restricted = timedEvent(
        's',
        DateTime(2026, 9, 10, 9),
        DateTime(2026, 9, 10, 10),
        restricted: true,
      );
      expect(canDragEvent(restricted), isFalse);
      expect(canDragEvent(holidayEvent(DateTime(2026, 10, 3), '개천절')), isFalse);
      final birthday = EventOccurrence(
        key: 'birthday:u:2026-09-10',
        calendarId: kBirthdaysCalendarId,
        source: 'birthday',
        title: '김철수 님의 생일',
        start: allDayToMs(DateTime(2026, 9, 10)),
        end: allDayToMs(DateTime(2026, 9, 11)),
        allDay: true,
        canEdit: true,
      );
      expect(canDragEvent(birthday), isFalse);
    });
  });

  group('날짜 계산', () {
    test('daysBetween: 월·연 경계와 음수', () {
      expect(daysBetween(DateTime(2026, 9, 30), DateTime(2026, 10, 1)), 1);
      expect(daysBetween(DateTime(2026, 12, 31), DateTime(2027, 1, 1)), 1);
      expect(daysBetween(DateTime(2026, 9, 10), DateTime(2026, 9, 3)), -7);
      expect(daysBetween(DateTime(2028, 2, 28), DateTime(2028, 3, 1)), 2);
    });

    test('시간 일정: 날짜만 옮기고 시각·길이는 그대로', () {
      final e = timedEvent(
        'e',
        DateTime(2026, 9, 10, 9, 30),
        DateTime(2026, 9, 10, 11),
      );
      final m = moveEventToDay(e, DateTime(2026, 9, 17));
      expect(m.allDay, isFalse);
      expect(m.start, _ms(2026, 9, 17, 9, 30));
      expect(m.end, _ms(2026, 9, 17, 11));
      expect(m.isSameAs(e), isFalse);
      expect(moveEventToDay(e, DateTime(2026, 9, 10)).isSameAs(e), isTrue);
    });

    test('월말을 넘기면 다음 달로', () {
      final e = timedEvent(
        'e',
        DateTime(2026, 9, 30, 23, 30),
        DateTime(2026, 10, 1, 0, 30),
      );
      final m = moveEventByDays(e, 1);
      expect(m.start, _ms(2026, 10, 1, 23, 30));
      expect(m.end, _ms(2026, 10, 2, 0, 30));
      // 윤년 2월 말.
      final leap = timedEvent(
        'l',
        DateTime(2028, 2, 28, 10),
        DateTime(2028, 2, 28, 11),
      );
      expect(moveEventByDays(leap, 1).start, _ms(2028, 2, 29, 10));
      expect(moveEventByDays(leap, 2).start, _ms(2028, 3, 1, 10));
    });

    test('여러 날 일정은 시작을 옮긴 일수만큼 전체가 간다', () {
      final trip = allDayEvent(
        't',
        DateTime(2026, 9, 29),
        DateTime(2026, 10, 1),
      );
      expect(trip.dayCount, 3);
      final m = moveEventToDay(trip, DateTime(2026, 10, 5));
      expect(m.allDay, isTrue);
      expect(allDayFromMs(m.start), DateTime(2026, 10, 5));
      // 끝은 마지막 날(10/7) 다음 날 자정(배타).
      expect(allDayFromMs(m.end), DateTime(2026, 10, 8));
      expect(m.end - m.start, trip.end - trip.start);
      // 앞으로도 옮긴다.
      final back = moveEventByDays(trip, -10);
      expect(allDayFromMs(back.start), DateTime(2026, 9, 19));
      expect(allDayFromMs(back.end), DateTime(2026, 9, 22));
    });

    test('여러 날 시간 일정도 시각을 유지한 채 통째로 간다', () {
      final e = timedEvent(
        'e',
        DateTime(2026, 9, 10, 22),
        DateTime(2026, 9, 12, 8),
      );
      expect(e.isMultiDay, isTrue);
      final m = moveEventByDays(e, 3);
      expect(m.start, _ms(2026, 9, 13, 22));
      expect(m.end, _ms(2026, 9, 15, 8));
    });

    test('종일 일정은 UTC 날짜로만 움직인다 — 기기 시간대와 무관한 하루 단위', () {
      final e = allDayEvent('a', DateTime(2026, 9, 30), DateTime(2026, 9, 30));
      expect(e.start, DateTime.utc(2026, 9, 30).millisecondsSinceEpoch);
      final m = moveEventByDays(e, 1);
      expect(m.start, DateTime.utc(2026, 10, 1).millisecondsSinceEpoch);
      expect(m.end, DateTime.utc(2026, 10, 2).millisecondsSinceEpoch);
      expect(m.start % 86400000, 0);
      expect(m.end % 86400000, 0);
      // 서버로 보내는 모양.
      expect(m.toFields(), {'start': m.start, 'end': m.end, 'allDay': true});
    });

    test('applyTo: 옮긴 복사본은 키도 새 시작 시각을 따른다', () {
      final e = timedEvent(
        'e',
        DateTime(2026, 9, 10, 9),
        DateTime(2026, 9, 10, 10),
      );
      final m = moveEventByDays(e, 2);
      final moved = m.applyTo(e);
      expect(moved.start, m.start);
      expect(moved.key, 'e:${m.start}');
      expect(moved.title, e.title);
      expect(moved.firstDay, DateTime(2026, 9, 12));
    });
  });

  group('시간표 이동(10분 스냅·길이 유지)', () {
    final e = timedEvent(
      'e',
      DateTime(2026, 9, 10, 9),
      DateTime(2026, 9, 10, 10, 30),
    );

    test('snapMinutes: 가장 가까운 10분', () {
      expect(snapMinutes(0), 0);
      expect(snapMinutes(4), 0);
      expect(snapMinutes(5), 10);
      expect(snapMinutes(14 * 60 + 33), 14 * 60 + 30);
      expect(snapMinutes(14 * 60 + 37), 14 * 60 + 40);
    });

    test('다른 날·다른 시각으로 옮기면 10분에 맞추고 길이(90분)는 그대로', () {
      final m = moveTimedEventTo(e, DateTime(2026, 9, 12), 14 * 60 + 7);
      expect(m.start, _ms(2026, 9, 12, 14, 10));
      expect(m.end - m.start, 90 * 60000);
      expect(m.allDay, isFalse);
    });

    test('하루를 넘기지 않게 아래·위 끝에서 멈춘다', () {
      final late = moveTimedEventTo(e, DateTime(2026, 9, 10), 23 * 60 + 50);
      // 90분 일정은 22:30에 시작해야 24:00에 끝난다.
      expect(late.start, _ms(2026, 9, 10, 22, 30));
      expect(late.end, _ms(2026, 9, 11));
      final early = moveTimedEventTo(e, DateTime(2026, 9, 10), -45);
      expect(early.start, _ms(2026, 9, 10, 0, 0));
    });

    test('자정 직전 시각: 다음 달 1일로 옮겨도 그 날 안에 머문다', () {
      final night = timedEvent(
        'n',
        DateTime(2026, 9, 30, 23, 0),
        DateTime(2026, 9, 30, 23, 30),
      );
      final m = moveTimedEventTo(night, DateTime(2026, 10, 1), 23 * 60);
      expect(m.start, _ms(2026, 10, 1, 23));
      expect(m.end, _ms(2026, 10, 1, 23, 30));
      expect(DateTime.fromMillisecondsSinceEpoch(m.end).day, 1);
    });

    test('minutesIntoDay: 시작이 그날 몇 분인지', () {
      expect(minutesIntoDay(e), 9 * 60);
    });
  });

  group('월간 격자 칸 찾기', () {
    final weeks = monthGridWeeks(DateTime(2026, 9, 1));
    const size = Size(700, 600);

    test('좌표 → 날짜 칸', () {
      // 9월 격자는 8/30(일)부터 5줄(라이브: 9/1이 화요일).
      expect(weeks.length, 5);
      expect(monthCellDayAt(size, const Offset(1, 1), weeks), weeks[0][0]);
      expect(monthCellDayAt(size, const Offset(699, 599), weeks), weeks[4][6]);
      // 7칸·5줄 = 칸 폭 100, 줄 높이 120.
      expect(monthCellDayAt(size, const Offset(250, 130), weeks), weeks[1][2]);
    });

    test('영역 밖이면 null', () {
      expect(monthCellDayAt(size, const Offset(-1, 10), weeks), isNull);
      expect(monthCellDayAt(size, const Offset(10, 600), weeks), isNull);
      expect(monthCellDayAt(size, const Offset(700, 10), weeks), isNull);
    });
  });
}
