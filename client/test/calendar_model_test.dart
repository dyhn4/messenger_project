import 'dart:convert';

import 'package:client/models/calendar.dart';
import 'package:client/screens/calendar/calendar_common.dart';
import 'package:flutter_test/flutter_test.dart';

/// 캘린더 모델 — 서버 규약 JSON을 읽는 규칙(특히 종일 일정의 UTC 날짜), 반복 요약 문구, 요청 본문.

Map<String, dynamic> _occurrenceJson({
  int? start,
  int? end,
  bool allDay = false,
  Map<String, dynamic>? recurrence,
  bool restricted = false,
}) => {
  'key': 'e1:${start ?? 0}',
  'eventId': 'e1',
  'calendarId': 'c1',
  'source': 'event',
  'title': '회의',
  'description': '설명',
  'location': '3층',
  'start': start ?? DateTime(2026, 9, 30, 10).millisecondsSinceEpoch,
  'end': end ?? DateTime(2026, 9, 30, 11).millisecondsSinceEpoch,
  'allDay': allDay,
  'visibility': 'public',
  'restricted': restricted,
  'recurring': recurrence != null,
  'recurrence': recurrence,
  'creatorId': 'u1',
  'creatorName': '김철수',
  'attendees': [
    {'userId': 'u2', 'name': '이영희'},
  ],
  'color': '#43A047',
  'canEdit': true,
  'canDelete': false,
};

void main() {
  group('EventOccurrence.fromJson', () {
    test('시간 일정은 보통의 순간(epoch ms)으로 읽는다', () {
      final e = EventOccurrence.fromJson(_occurrenceJson());
      expect(e.allDay, isFalse);
      expect(e.startTime, DateTime(2026, 9, 30, 10));
      expect(e.endTime, DateTime(2026, 9, 30, 11));
      expect(e.firstDay, DateTime(2026, 9, 30));
      expect(e.lastDay, DateTime(2026, 9, 30));
      expect(e.isMultiDay, isFalse);
      expect(e.isBar, isFalse);
      expect(e.attendees.single.name, '이영희');
      expect(e.creatorName, '김철수');
      expect(e.color, '#43A047');
      expect(e.canEdit, isTrue);
      expect(e.canDelete, isFalse);
    });

    test('종일 일정은 UTC 자정의 y/m/d로만 읽는다(끝은 마지막 날 다음 날, 배타)', () {
      // 2026-05-05 하루짜리 종일: start=5/5 UTC 자정, end=5/6 UTC 자정.
      final e = EventOccurrence.fromJson(
        _occurrenceJson(
          start: DateTime.utc(2026, 5, 5).millisecondsSinceEpoch,
          end: DateTime.utc(2026, 5, 6).millisecondsSinceEpoch,
          allDay: true,
        ),
      );
      expect(e.firstDay, DateTime(2026, 5, 5));
      expect(e.lastDay, DateTime(2026, 5, 5));
      expect(e.dayCount, 1);
      expect(e.isBar, isTrue, reason: '종일은 하루짜리여도 막대로 그린다');
    });

    test('여러 날 종일 일정의 마지막 날은 end - 1일', () {
      final e = EventOccurrence.fromJson(
        _occurrenceJson(
          start: DateTime.utc(2026, 9, 29).millisecondsSinceEpoch,
          end: DateTime.utc(2026, 10, 2).millisecondsSinceEpoch,
          allDay: true,
        ),
      );
      expect(e.firstDay, DateTime(2026, 9, 29));
      expect(e.lastDay, DateTime(2026, 10, 1));
      expect(e.dayCount, 3);
      expect(e.isMultiDay, isTrue);
      expect(e.coversDay(DateTime(2026, 9, 30)), isTrue);
      expect(e.coversDay(DateTime(2026, 10, 1)), isTrue);
      expect(e.coversDay(DateTime(2026, 10, 2)), isFalse);
      expect(e.coversDay(DateTime(2026, 9, 28)), isFalse);
    });

    test('allDayToMs / allDayFromMs 는 서로 되돌린다', () {
      final day = DateTime(2026, 12, 31);
      expect(
        allDayToMs(day),
        DateTime.utc(2026, 12, 31).millisecondsSinceEpoch,
      );
      expect(allDayFromMs(allDayToMs(day)), day);
    });

    test('자정 정각에 끝나는 시간 일정은 다음 날에 걸치지 않는다', () {
      final e = EventOccurrence.fromJson(
        _occurrenceJson(
          start: DateTime(2026, 9, 30, 22).millisecondsSinceEpoch,
          end: DateTime(2026, 10, 1).millisecondsSinceEpoch,
        ),
      );
      expect(e.lastDay, DateTime(2026, 9, 30));
      expect(e.isMultiDay, isFalse);
    });

    test('자정을 넘기는 시간 일정은 여러 날(막대)이다', () {
      final e = EventOccurrence.fromJson(
        _occurrenceJson(
          start: DateTime(2026, 9, 30, 22).millisecondsSinceEpoch,
          end: DateTime(2026, 10, 1, 2).millisecondsSinceEpoch,
        ),
      );
      expect(e.lastDay, DateTime(2026, 10, 1));
      expect(e.isMultiDay, isTrue);
      expect(e.isBar, isTrue);
    });

    test('공휴일·생일 source 와 비공개 표시', () {
      final holiday = EventOccurrence.fromJson({
        'key': 'holiday:2026-05-05',
        'eventId': null,
        'calendarId': 'holidays',
        'source': 'holiday',
        'title': '어린이날',
        'start': DateTime.utc(2026, 5, 5).millisecondsSinceEpoch,
        'end': DateTime.utc(2026, 5, 6).millisecondsSinceEpoch,
        'allDay': true,
        'color': '#E53935',
      });
      expect(holiday.isHoliday, isTrue);
      expect(holiday.isUserEvent, isFalse);
      expect(holiday.eventId, isNull);
      expect(holiday.firstDay, DateTime(2026, 5, 5));

      final secret = EventOccurrence.fromJson(
        _occurrenceJson(restricted: true)..['title'] = '비공개 일정',
      );
      expect(secret.restricted, isTrue);
      expect(eventDisplayTitle(secret), '비공개 일정');
    });
  });

  group('Recurrence', () {
    test('fromJson / toJson (until 은 YYYY-MM-DD, weekly 만 byWeekday)', () {
      final r = Recurrence.fromJson({
        'freq': 'weekly',
        'interval': 2,
        'byWeekday': [3, 1],
        'until': '2026-12-31',
      });
      expect(r.freq, 'weekly');
      expect(r.interval, 2);
      expect(r.until, DateTime(2026, 12, 31));
      expect(r.count, isNull);
      expect(
        jsonEncode(r.toJson()),
        jsonEncode({
          'freq': 'weekly',
          'interval': 2,
          'byWeekday': [1, 3],
          'until': '2026-12-31',
        }),
      );

      const daily = Recurrence(freq: 'daily', byWeekday: [1]);
      expect(daily.toJson().containsKey('byWeekday'), isFalse);
      expect(const Recurrence(freq: 'daily', count: 10).toJson()['count'], 10);
    });

    test('요약 문구', () {
      expect(
        const Recurrence(freq: 'weekly', byWeekday: [1, 3]).summary(),
        '매주 월·수요일 반복',
      );
      expect(const Recurrence(freq: 'daily').summary(), '매일 반복');
      expect(const Recurrence(freq: 'daily', interval: 3).summary(), '3일마다 반복');
      expect(
        const Recurrence(
          freq: 'weekly',
          interval: 2,
          byWeekday: [0, 6],
        ).summary(),
        '2주마다 일·토요일 반복',
      );
      expect(const Recurrence(freq: 'monthly').summary(), '매월 반복');
      expect(
        const Recurrence(
          freq: 'monthly',
        ).summary(startDay: DateTime(2026, 9, 15)),
        '매월 15일 반복',
      );
      expect(
        const Recurrence(
          freq: 'yearly',
        ).summary(startDay: DateTime(2026, 3, 1)),
        '매년 3월 1일 반복',
      );
      expect(
        Recurrence(freq: 'daily', until: DateTime(2026, 12, 31)).summary(),
        '매일 반복 (2026년 12월 31일까지)',
      );
      expect(
        const Recurrence(freq: 'daily', count: 10).summary(),
        '매일 반복 (10회)',
      );
    });

    test('byWeekday 가 비면 시작 요일로 요약한다(서버 규약: 비면 시작 요일)', () {
      // 2026-09-30 은 수요일.
      expect(
        const Recurrence(
          freq: 'weekly',
        ).summary(startDay: DateTime(2026, 9, 30)),
        '매주 수요일 반복',
      );
      expect(const Recurrence(freq: 'weekly').summary(), '매주 반복');
    });

    // 서버는 시간 일정의 반복 요일을 한국(Asia/Seoul) 달력으로 읽는다. 한국이 아닌 기기에서 같은 순간이 다른 요일이 되면
    // 옮기지 않았을 때 서버가 시작일을 엉뚱한 요일로 밀어 버린다(실서버로 확인: UTC-8 일요일 20:00 매주 → 6일 밀림).
    group('반복 요일의 한국 달력 변환(kstWeekdayShift)', () {
      // 2026-11-09 04:00Z = 한국 월요일 13:00 = UTC-8 일요일(11/8) 20:00.
      final start = DateTime.utc(2026, 11, 9, 4).millisecondsSinceEpoch;
      const utcMinus8 = Duration(hours: -8);

      test('기기가 UTC-8이면 한국 날짜가 하루 뒤라 +1, 한국이면 0', () {
        expect(kstWeekdayShift(start, localOffset: utcMinus8), 1);
        expect(kstWeekdayShift(start, localOffset: const Duration(hours: 9)), 0);
        // 기기가 한국보다 훨씬 동쪽(UTC+14)이면 한국 날짜가 하루 앞(11/8 21:00 KST = UTC+14 11/9 02:00).
        expect(
          kstWeekdayShift(
            DateTime.utc(2026, 11, 8, 12).millisecondsSinceEpoch,
            localOffset: const Duration(hours: 14),
          ),
          -1,
        );
      });

      test('보낼 때 더하고 받을 때 뺀다(일요일=0 → 월요일=1, 토요일 6 → 일요일 0)', () {
        const local = Recurrence(freq: 'weekly', byWeekday: [0, 3, 6]);
        expect(local.toJson(weekdayShift: 1)['byWeekday'], [0, 1, 4]);
        final back = Recurrence.fromJson({
          'freq': 'weekly',
          'byWeekday': [0, 1, 4],
        }, weekdayShift: -1);
        expect(back.byWeekday, [6, 0, 3]);
      });

      test('EventInput 은 시간 일정만 옮기고 종일은 그대로 보낸다', () {
        // 이 테스트 기기의 시간대와 무관하게, 오프셋 0(shift 0)인 경우와 결과가 같은지만 본다.
        final input = EventInput(
          title: 't',
          start: start,
          end: start + 3600000,
          recurrence: const Recurrence(freq: 'weekly', byWeekday: [1]),
        );
        final shift = kstWeekdayShift(start);
        expect(
          (input.toJson()['recurrence'] as Map)['byWeekday'],
          [(1 + shift) % 7],
        );
        final allDay = EventInput(
          title: 't',
          start: allDayToMs(DateTime(2026, 11, 9)),
          end: allDayToMs(DateTime(2026, 11, 10)),
          allDay: true,
          recurrence: const Recurrence(freq: 'weekly', byWeekday: [1]),
        );
        expect((allDay.toJson()['recurrence'] as Map)['byWeekday'], [1]);
      });
    });
  });

  group('CalendarInfo / 요청 본문', () {
    test('캘린더 DTO 를 읽는다', () {
      final c = CalendarInfo.fromJson({
        'id': 'c1',
        'teamId': 't1',
        'kind': 'shared',
        'name': '디자인팀',
        'color': '#8E24AA',
        'defaultColor': '#3949AB',
        'isPublic': true,
        'ownerId': 'u1',
        'ownerName': '김철수',
        'role': 'write',
        'hidden': true,
        'canCreateEvents': true,
        'canDelete': false,
        'canEditSettings': false,
      });
      expect(c.kind, 'shared');
      expect(c.color, '#8E24AA');
      expect(c.defaultColor, '#3949AB');
      expect(c.hidden, isTrue);
      expect(c.canCreateEvents, isTrue);
      expect(c.isBuiltin, isFalse);
      expect(c.isSharedMember, isTrue);
      expect(c.isSubscriber, isFalse);
    });

    test('내장 구독 캘린더는 고정 id·색', () {
      final h = CalendarInfo.holidays();
      final b = CalendarInfo.birthdays(hidden: true);
      expect(h.id, 'holidays');
      expect(h.color, '#E53935');
      expect(h.isBuiltin, isTrue);
      expect(b.id, 'birthdays');
      expect(b.color, '#F06292');
      expect(b.hidden, isTrue);
      expect(h.isSubscriber, isFalse, reason: '내장은 구독 취소 대상이 아니다');
    });

    test('EventInput 본문: 종일은 UTC 자정, 색은 고른 때만', () {
      final input = EventInput(
        title: '워크숍',
        start: allDayToMs(DateTime(2026, 10, 1)),
        end: allDayToMs(DateTime(2026, 10, 3)),
        allDay: true,
        visibility: 'private',
        attendeeIds: const ['u2'],
        recurrence: const Recurrence(freq: 'yearly'),
      );
      final json = input.toJson();
      expect(json['start'], DateTime.utc(2026, 10, 1).millisecondsSinceEpoch);
      expect(json['end'], DateTime.utc(2026, 10, 3).millisecondsSinceEpoch);
      expect(json['allDay'], isTrue);
      expect(json['visibility'], 'private');
      expect(json['attendeeIds'], ['u2']);
      expect(json['recurrence'], {'freq': 'yearly', 'interval': 1});
      expect(json.containsKey('color'), isFalse);
      expect(
        const EventInput(
          title: 'a',
          start: 1,
          end: 2,
          color: '#E53935',
        ).toJson()['color'],
        '#E53935',
      );
    });

    test('RecurrenceScope 는 서버 scope 문자열', () {
      expect(RecurrenceScope.thisOnly.wire, 'this');
      expect(RecurrenceScope.following.wire, 'following');
      expect(RecurrenceScope.all.wire, 'all');
    });
  });

  group('기간 문구', () {
    test('종일 / 여러 날 / 시간 일정', () {
      final allDay = EventOccurrence.fromJson(
        _occurrenceJson(
          start: DateTime.utc(2026, 9, 30).millisecondsSinceEpoch,
          end: DateTime.utc(2026, 10, 1).millisecondsSinceEpoch,
          allDay: true,
        ),
      );
      expect(formatEventPeriod(allDay), '9월 30일 (수) · 종일');

      final multi = EventOccurrence.fromJson(
        _occurrenceJson(
          start: DateTime.utc(2026, 9, 30).millisecondsSinceEpoch,
          end: DateTime.utc(2026, 10, 3).millisecondsSinceEpoch,
          allDay: true,
        ),
      );
      expect(formatEventPeriod(multi), '9월 30일 (수) – 10월 2일 (금) · 종일');

      final timed = EventOccurrence.fromJson(_occurrenceJson());
      expect(formatEventPeriod(timed), '9월 30일 (수) 오전 10:00 – 오전 11:00');
    });

    test('보기별 제목', () {
      final d = DateTime(2026, 9, 30);
      expect(formatViewTitle(CalendarViewMode.month, d), '2026년 9월');
      expect(formatViewTitle(CalendarViewMode.list, d), '2026년 9월');
      expect(formatViewTitle(CalendarViewMode.day, d), '2026년 9월 30일 (수)');
      // 9/30(수)가 든 주는 9/27(일) ~ 10/3(토).
      expect(
        formatViewTitle(CalendarViewMode.week, d),
        '2026년 9월 27일 – 10월 3일',
      );
    });
  });
}
