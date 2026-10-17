import 'dart:async';

import 'package:client/models/calendar.dart';
import 'package:client/services/api_client.dart' show ApiException;
import 'package:client/services/calendar_controller.dart';
import 'package:client/services/calendar_move.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_calendar_api.dart';

/// 캘린더 컨트롤러 — 가짜 API로 목록·일정 캐시·숨김·소켓 새로고침을 시험한다.

CalendarController _controller(
  FakeCalendarApi api, {
  Stream<String>? changed,
  bool guest = false,
}) => CalendarController(
  apiProvider: () => api,
  calendarChanged: changed,
  userId: () => 'me',
  isGuest: () => guest,
);

final _sep = DateTime(2026, 9, 1);
final _oct = DateTime(2026, 10, 1);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('팀을 고르면 캘린더 목록을 받고, 내장 캘린더가 구독 묶음 앞에 붙는다', () async {
    final api = FakeCalendarApi(
      subscribed: [
        CalendarInfo(
          id: 'sub',
          kind: 'personal',
          name: '철수',
          color: '#43A047',
          role: 'subscriber',
        ),
      ],
    );
    final c = _controller(api);
    await c.setTeam('t1');

    expect(c.calendarsLoaded, isTrue);
    expect(c.mine.map((e) => e.id), ['cal-me']);
    expect(c.subscribedGroup.map((e) => e.id), [
      'holidays',
      'birthdays',
      'leaves',
      'bookings',
      'sub',
    ]);
    expect(api.callCount('fetchCalendars'), 1);
  });

  test('준회원은 생일 캘린더 항목이 없다', () async {
    final c = _controller(FakeCalendarApi(), guest: true);
    await c.setTeam('t1');
    expect(c.subscribedGroup.map((e) => e.id), ['holidays']);
  });

  test('watch 는 달 단위로 받아 캐시하고 같은 달은 다시 받지 않는다', () async {
    final api = FakeCalendarApi(
      events: [
        timedEvent('e1', DateTime(2026, 9, 30, 10), DateTime(2026, 9, 30, 11)),
      ],
    );
    final c = _controller(api);
    await c.setTeam('t1');
    await c.watch(DateTime(2026, 8, 30), DateTime(2026, 10, 4));
    // 8월·9월·10월 세 덩어리.
    expect(api.callCount('fetchEvents'), 3);
    expect(
      c.eventsBetween(DateTime(2026, 9, 27), DateTime(2026, 10, 4)),
      hasLength(1),
    );

    await c.watch(DateTime(2026, 9, 1), DateTime(2026, 10, 1));
    expect(api.callCount('fetchEvents'), 3, reason: '이미 받은 달은 다시 받지 않는다');
  });

  test('여러 달에 걸친 일정은 덩어리가 겹쳐도 한 번만 나온다', () async {
    final api = FakeCalendarApi(
      events: [
        allDayEvent('trip', DateTime(2026, 9, 29), DateTime(2026, 10, 2)),
      ],
    );
    final c = _controller(api);
    await c.setTeam('t1');
    await c.watch(DateTime(2026, 9, 1), DateTime(2026, 11, 1));
    expect(c.eventsBetween(_sep, DateTime(2026, 11, 1)), hasLength(1));
  });

  test('eventsBetween 은 구간 밖 일정을 거른다', () async {
    final api = FakeCalendarApi(
      events: [
        timedEvent('in', DateTime(2026, 9, 10, 9), DateTime(2026, 9, 10, 10)),
        timedEvent('out', DateTime(2026, 9, 20, 9), DateTime(2026, 9, 20, 10)),
      ],
    );
    final c = _controller(api);
    await c.setTeam('t1');
    await c.watch(_sep, _oct);
    final got = c.eventsBetween(DateTime(2026, 9, 6), DateTime(2026, 9, 13));
    expect(got.map((e) => e.eventId), ['in']);
  });

  group('숨김', () {
    test('일반 캘린더를 숨기면 서버에 저장하고 그 일정이 빠진다', () async {
      final api = FakeCalendarApi(
        mine: [personalCalendar(), sharedCalendar()],
        events: [
          timedEvent('a', DateTime(2026, 9, 10, 9), DateTime(2026, 9, 10, 10)),
          timedEvent(
            'b',
            DateTime(2026, 9, 10, 11),
            DateTime(2026, 9, 10, 12),
            calendarId: 'cal-shared',
          ),
        ],
      );
      final c = _controller(api);
      await c.setTeam('t1');
      await c.watch(_sep, _oct);
      expect(c.eventsBetween(_sep, _oct), hasLength(2));

      await c.setHidden(c.calendarById('cal-shared')!, true);
      expect(
        api.calls,
        contains('updateMySettings cal-shared color=null hidden=true'),
      );
      expect(c.calendarById('cal-shared')!.hidden, isTrue);
      expect(c.eventsBetween(_sep, _oct).map((e) => e.eventId), ['a']);

      await c.setHidden(c.calendarById('cal-shared')!, false);
      expect(c.eventsBetween(_sep, _oct), hasLength(2));
    });

    test('서버가 거절하면 체크박스를 되돌린다', () async {
      final api = FakeCalendarApi(mine: [personalCalendar(), sharedCalendar()]);
      final c = _controller(api);
      await c.setTeam('t1');
      api.failWith = '권한이 없습니다.';
      await expectLater(
        c.setHidden(c.calendarById('cal-shared')!, true),
        throwsA(isA<ApiException>()),
      );
      expect(c.calendarById('cal-shared')!.hidden, isFalse);
    });

    test('내장 캘린더 숨김은 서버가 아니라 로컬(SharedPreferences)에 저장한다', () async {
      final api = FakeCalendarApi(
        events: [holidayEvent(DateTime(2026, 9, 25), '추석')],
      );
      final c = _controller(api);
      await c.setTeam('t1');
      await c.watch(_sep, _oct);
      expect(c.eventsBetween(_sep, _oct), hasLength(1));

      await c.setHidden(CalendarInfo.holidays(), true);
      expect(api.callCount('updateMySettings'), 0);
      expect(c.isHidden('holidays'), isTrue);
      expect(c.eventsBetween(_sep, _oct), isEmpty);
      expect(c.builtinCalendars.first.hidden, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('calendar_hidden_builtin_me'), ['holidays']);

      // 새 컨트롤러(앱을 다시 켠 것)도 저장된 숨김을 읽는다.
      final again = _controller(api);
      await again.setTeam('t1');
      expect(again.isHidden('holidays'), isTrue);
      expect(again.isHidden('birthdays'), isFalse);
    });

    test('목록에 없는 캘린더의 일정(참석자로만 초대됨)은 숨기지 않고 보인다', () async {
      final api = FakeCalendarApi(
        events: [
          timedEvent(
            'invited',
            DateTime(2026, 9, 10, 9),
            DateTime(2026, 9, 10, 10),
            calendarId: 'someone-elses',
            canEdit: false,
            canDelete: false,
          ),
        ],
      );
      final c = _controller(api);
      await c.setTeam('t1');
      await c.watch(_sep, _oct);
      expect(c.eventsBetween(_sep, _oct), hasLength(1));
    });
  });

  test('색 변경은 PATCH /me 로 보내고 일정을 다시 받는다', () async {
    final api = FakeCalendarApi();
    final c = _controller(api);
    await c.setTeam('t1');
    await c.watch(_sep, _oct);
    final before = api.callCount('fetchEvents');

    await c.setColor(c.calendarById('cal-me')!, '#E53935');
    await Future<void>.delayed(Duration.zero);
    expect(c.calendarById('cal-me')!.color, '#E53935');
    expect(
      api.calls,
      contains('updateMySettings cal-me color=#E53935 hidden=null'),
    );
    expect(api.callCount('fetchEvents'), greaterThan(before));
  });

  group('소켓 calendar:changed', () {
    test('보고 있는 팀의 변경이면 목록과 일정을 다시 받는다', () async {
      final api = FakeCalendarApi();
      final changed = StreamController<String>.broadcast();
      final c = _controller(api, changed: changed.stream);
      await c.setTeam('t1');
      await c.watch(_sep, _oct);
      final calendarFetches = api.callCount('fetchCalendars');
      final eventFetches = api.callCount('fetchEvents');

      api.events = [
        timedEvent('new', DateTime(2026, 9, 12, 9), DateTime(2026, 9, 12, 10)),
      ];
      changed.add('t1');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(api.callCount('fetchCalendars'), calendarFetches + 1);
      expect(api.callCount('fetchEvents'), greaterThan(eventFetches));
      expect(c.eventsBetween(_sep, _oct).map((e) => e.eventId), ['new']);
      await changed.close();
    });

    test('다른 팀의 변경은 무시한다', () async {
      final api = FakeCalendarApi();
      final changed = StreamController<String>.broadcast();
      final c = _controller(api, changed: changed.stream);
      await c.setTeam('t1');
      await c.watch(_sep, _oct);
      final fetches = api.callCount('fetchEvents');

      changed.add('t2');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(api.callCount('fetchEvents'), fetches);
      await changed.close();
    });

    test('화면이 닫혀 있으면(unwatch) 받지 않고 캐시만 비운다', () async {
      final api = FakeCalendarApi(
        events: [
          timedEvent('a', DateTime(2026, 9, 12, 9), DateTime(2026, 9, 12, 10)),
        ],
      );
      final changed = StreamController<String>.broadcast();
      final c = _controller(api, changed: changed.stream);
      await c.setTeam('t1');
      await c.watch(_sep, _oct);
      c.unwatch();
      final fetches = api.callCount('fetchEvents');

      changed.add('t1');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(api.callCount('fetchEvents'), fetches);
      expect(c.eventsBetween(_sep, _oct), isEmpty, reason: '옛 캐시는 남기지 않는다');

      // 다시 열면 받는다.
      await c.setTeam('t1');
      await c.watch(_sep, _oct);
      expect(c.eventsBetween(_sep, _oct), hasLength(1));
      await changed.close();
    });
  });

  test('팀을 바꾸면 이전 팀 요청의 늦은 응답을 버린다', () async {
    final api = FakeCalendarApi(
      events: [
        timedEvent('old', DateTime(2026, 9, 12, 9), DateTime(2026, 9, 12, 10)),
      ],
    );
    final gate = Completer<void>();
    api.fetchGate = gate.future;
    final c = _controller(api);
    await c.setTeam('t1');
    final loading = c.watch(_sep, _oct);

    // 응답이 오기 전에 팀 전환 → 데이터를 비운다.
    api.events = [];
    unawaited(c.setTeam('t2'));
    gate.complete();
    await loading;
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(c.teamId, 't2');
    expect(c.eventsBetween(_sep, _oct), isEmpty);
  });

  test('일정 만들기·수정·삭제 뒤에는 일정을 다시 받는다', () async {
    final api = FakeCalendarApi();
    final c = _controller(api);
    await c.setTeam('t1');
    await c.watch(_sep, _oct);

    await c.createEvent(
      'cal-me',
      EventInput(
        title: '점심',
        start: DateTime(2026, 9, 15, 12).millisecondsSinceEpoch,
        end: DateTime(2026, 9, 15, 13).millisecondsSinceEpoch,
      ),
    );
    expect(c.eventsBetween(_sep, _oct).map((e) => e.title), ['점심']);

    final id = api.events.single.eventId!;
    await c.updateEvent(
      id,
      {'title': '늦은 점심'},
      scope: RecurrenceScope.all,
      occurrenceStart: api.events.single.start,
    );
    expect(api.lastEventFields, {'title': '늦은 점심'});
    expect(api.lastScope, RecurrenceScope.all);

    await c.deleteEvent(id);
    expect(c.eventsBetween(_sep, _oct), isEmpty);
  });

  test('캘린더 관리 호출은 성공하면 목록을 다시 받는다', () async {
    final api = FakeCalendarApi();
    final c = _controller(api);
    await c.setTeam('t1');

    await c.createCalendar(name: '디자인', color: '#8E24AA');
    expect(c.mine.map((e) => e.name), ['나', '디자인']);

    await c.leaveCalendar('cal-2');
    expect(c.mine.map((e) => e.name), ['나']);
  });

  test('서버 에러 문구는 error 로 남는다', () async {
    final api = _FailingApi();
    final c = _controller(api);
    await c.setTeam('t1');
    expect(c.error, '팀 멤버가 아닙니다.');
    expect(c.calendarsLoaded, isFalse);
  });

  group('moveEvent (드래그 이동)', () {
    final src = timedEvent(
      'e1',
      DateTime(2026, 9, 10, 9),
      DateTime(2026, 9, 10, 10),
    );

    Future<CalendarController> loaded(FakeCalendarApi api) async {
      final c = _controller(api);
      await c.setTeam('t1');
      await c.watch(_sep, _oct);
      return c;
    }

    test('놓자마자 캐시를 새 자리로 바꾸고 start/end/allDay 만 PATCH 한 뒤 다시 받는다', () async {
      final api = FakeCalendarApi(events: [src]);
      final c = await loaded(api);
      final fetches = api.callCount('fetchEvents');
      final move = moveEventToDay(src, DateTime(2026, 9, 17));
      final done = c.moveEvent(src, move);
      // 낙관적 갱신: 서버 응답을 기다리기 전에 이미 새 자리.
      expect(c.eventsBetween(_sep, _oct).single.start, move.start);
      await done;
      expect(api.lastEventFields, {
        'start': move.start,
        'end': move.end,
        'allDay': false,
      });
      expect(api.lastScope, isNull);
      expect(api.lastOccurrenceStart, isNull);
      expect(api.callCount('fetchEvents'), greaterThan(fetches));
      expect(c.eventsBetween(_sep, _oct).single.start, move.start);
    });

    test('서버가 거절하면 원래 자리로 되돌리고 오류를 다시 던진다', () async {
      final api = FakeCalendarApi(events: [src])..failWith = '권한이 없습니다.';
      final c = await loaded(api);
      final move = moveEventToDay(src, DateTime(2026, 9, 17));
      await expectLater(
        c.moveEvent(src, move),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', '권한이 없습니다.'),
        ),
      );
      expect(c.eventsBetween(_sep, _oct).single.start, src.start);
    });

    test('종일 일정은 UTC 날짜 표현으로 보낸다', () async {
      final trip = allDayEvent(
        'a',
        DateTime(2026, 9, 29),
        DateTime(2026, 9, 30),
      );
      final api = FakeCalendarApi(events: [trip]);
      final c = await loaded(api);
      final move = moveEventToDay(trip, DateTime(2026, 10, 2));
      await c.moveEvent(trip, move);
      expect(api.lastEventFields!['allDay'], isTrue);
      expect(
        api.lastEventFields!['start'],
        DateTime.utc(2026, 10, 2).millisecondsSinceEpoch,
      );
      expect(
        api.lastEventFields!['end'],
        DateTime.utc(2026, 10, 4).millisecondsSinceEpoch,
      );
    });

    test('다른 달로 옮기면 그 달 덩어리에 들어가 바로 보인다', () async {
      final api = FakeCalendarApi(events: [src]);
      final c = _controller(api);
      await c.setTeam('t1');
      await c.watch(DateTime(2026, 8, 30), DateTime(2026, 10, 4));
      final move = moveEventToDay(src, DateTime(2026, 10, 2));
      final done = c.moveEvent(src, move);
      expect(c.eventsBetween(_sep, _oct), isEmpty);
      expect(
        c.eventsBetween(_oct, DateTime(2026, 11, 1)).single.start,
        move.start,
      );
      await done;
    });

    test('반복·권한 없는 일정은 옮길 수 없다(StateError, 서버 호출 없음)', () async {
      final recurring = timedEvent(
        'r',
        DateTime(2026, 9, 10, 9),
        DateTime(2026, 9, 10, 10),
        recurring: true,
        recurrence: const Recurrence(freq: 'daily'),
      );
      final api = FakeCalendarApi(events: [recurring]);
      final c = await loaded(api);
      await expectLater(
        c.moveEvent(recurring, moveEventByDays(recurring, 1)),
        throwsStateError,
      );
      final readOnly = timedEvent(
        'ro',
        DateTime(2026, 9, 10, 9),
        DateTime(2026, 9, 10, 10),
        canEdit: false,
      );
      await expectLater(
        c.moveEvent(readOnly, moveEventByDays(readOnly, 1)),
        throwsStateError,
      );
      expect(api.callCount('updateEvent'), 0);
    });
  });

  test('reset 은 팀과 캐시를 비운다', () async {
    final api = FakeCalendarApi();
    final c = _controller(api);
    await c.setTeam('t1');
    await c.watch(_sep, _oct);
    c.reset();
    expect(c.teamId, isNull);
    expect(c.mine, isEmpty);
    expect(c.eventsBetween(_sep, _oct), isEmpty);
  });
}

class _FailingApi extends FakeCalendarApi {
  @override
  Future<
    ({
      List<CalendarInfo> mine,
      List<CalendarInfo> subscribed,
      List<CalendarInfo> external,
    })
  >
  fetchCalendars(String teamId) async {
    throw const ApiException('팀 멤버가 아닙니다.');
  }
}
