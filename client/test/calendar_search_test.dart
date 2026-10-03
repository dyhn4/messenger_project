import 'dart:async';

import 'package:client/models/calendar.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/calendar/calendar_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/calendar_controller.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_calendar_api.dart';

/// 일정 제목 검색 시험 — 컨트롤러(디바운스·이어 받기·숨긴 캘린더·오류·늦은 응답)와 화면(PC 검색창+결과 패널, 모바일
/// 전체 화면 검색, "이동" 버튼, 항목을 누르면 상세).

class _Quiet extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

final _now = DateTime(2026, 9, 30, 10, 15);

Session _session() {
  final s = Session(notifications: _Quiet(), settings: AppSettings());
  s.serverUrl = 'https://test.local';
  s.api = ApiClient(baseUrl: 'https://test.local', token: 't');
  s.userId = 'me';
  s.name = '나';
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  s.teams.add(team);
  s.currentTeam = team;
  return s;
}

CalendarSearchItem _item(
  String id,
  String title,
  DateTime start, {
  DateTime? end,
  bool allDay = false,
  bool recurring = false,
  List<Attendee> attendees = const [],
  String calendarId = 'cal-me',
  String calendarName = '나',
}) {
  final e = end ?? start.add(const Duration(hours: 1));
  return CalendarSearchItem(
    eventId: id,
    calendarId: calendarId,
    calendarName: calendarName,
    color: '#1E88E5',
    title: title,
    start: allDay ? allDayToMs(start) : start.millisecondsSinceEpoch,
    end: allDay
        ? allDayToMs(DateTime(e.year, e.month, e.day + 1))
        : e.millisecondsSinceEpoch,
    allDay: allDay,
    recurring: recurring,
    recurrence: recurring
        ? const Recurrence(freq: 'weekly', byWeekday: [1])
        : null,
    attendees: attendees,
    creatorName: '나',
    canEdit: true,
  );
}

CalendarController _controller(FakeCalendarApi api) =>
    CalendarController(apiProvider: () => api, userId: () => 'me');

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

const _debounce = Duration(milliseconds: 300);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('CalendarSearchController', () {
    CalendarController make(FakeCalendarApi api) {
      final c = _controller(api);
      c.teamId = 't1';
      return c;
    }

    testWidgets('입력을 멈추고 300ms 뒤에 한 번만 검색한다', (tester) async {
      final api = FakeCalendarApi()
        ..searchableEvents = [_item('a', '주간 회의', DateTime(2026, 10, 5, 10))];
      final c = make(api);
      c.search.setQuery('주');
      await tester.pump(const Duration(milliseconds: 200));
      c.search.setQuery('주간');
      await tester.pump(const Duration(milliseconds: 299));
      expect(api.callCount('searchEvents'), 0);
      await tester.pump(const Duration(milliseconds: 2));
      await tester.pump();
      expect(api.callCount('searchEvents'), 1);
      expect(api.lastEventSearchQuery, '주간');
      expect(c.search.visibleItems.map((i) => i.eventId), ['a']);
      expect(c.search.searched, isTrue);
    });

    testWidgets('비우면 곧바로 결과를 지우고 검색하지 않는다', (tester) async {
      final api = FakeCalendarApi()
        ..searchableEvents = [_item('a', '회의', DateTime(2026, 10, 5, 10))];
      final c = make(api);
      c.search.setQuery('회의');
      await tester.pump(_debounce);
      await tester.pump();
      expect(c.search.visibleItems, hasLength(1));
      c.search.setQuery('  ');
      expect(c.search.visibleItems, isEmpty);
      expect(c.search.hasQuery, isFalse);
      await tester.pump(_debounce);
      expect(api.callCount('searchEvents'), 1);
    });

    testWidgets('최신순으로 받고 "더 보기"로 이어 받으며 중복은 걸러낸다', (tester) async {
      final api = FakeCalendarApi()
        ..searchPageSize = 2
        ..searchableEvents = [
          for (var i = 1; i <= 5; i++)
            _item('e$i', '회의 $i', DateTime(2026, 10, i, 10)),
        ];
      final c = make(api);
      c.search.setQuery('회의');
      await tester.pump(_debounce);
      await tester.pump();
      expect(c.search.visibleItems.map((i) => i.eventId), ['e5', 'e4']);
      expect(c.search.hasMore, isTrue);
      await c.search.loadMore();
      expect(c.search.visibleItems.map((i) => i.eventId), [
        'e5',
        'e4',
        'e3',
        'e2',
      ]);
      await c.search.loadMore();
      expect(c.search.visibleItems.map((i) => i.eventId).last, 'e1');
      expect(c.search.hasMore, isFalse);
    });

    testWidgets('숨긴 캘린더의 결과는 클라이언트가 뺀다', (tester) async {
      final api =
          FakeCalendarApi(
              mine: [personalCalendar(), sharedCalendar(hidden: true)],
            )
            ..searchableEvents = [
              _item('a', '회의 A', DateTime(2026, 10, 5, 10)),
              _item(
                'b',
                '회의 B',
                DateTime(2026, 10, 6, 10),
                calendarId: 'cal-shared',
                calendarName: '디자인팀',
              ),
            ];
      final c = make(api);
      await c.loadCalendars();
      c.search.setQuery('회의');
      await tester.pump(_debounce);
      await tester.pump();
      expect(c.search.visibleItems.map((i) => i.eventId), ['a']);
    });

    testWidgets('실패하면 서버 문구를 담고, 늦게 온 이전 검색 응답은 버린다', (tester) async {
      final api = FakeCalendarApi()..failWith = '검색어를 입력하세요.';
      final c = make(api);
      c.search.setQuery('회의');
      await tester.pump(_debounce);
      await tester.pump();
      expect(c.search.error, '검색어를 입력하세요.');
      expect(c.search.visibleItems, isEmpty);

      // 늦은 응답: 첫 검색이 끝나기 전에 다른 검색어로 다시 검색.
      final gate = Completer<void>();
      final slow = _SlowApi(gate.future)
        ..searchableEvents = [
          _item('old', '옛 회의', DateTime(2026, 10, 1, 10)),
          _item('new', '새 일정', DateTime(2026, 10, 2, 10)),
        ];
      final c2 = make(slow);
      c2.search.setQuery('회의');
      await tester.pump(_debounce);
      c2.search.setQuery('새');
      gate.complete();
      await tester.pump(_debounce);
      await tester.pump();
      await tester.pump();
      expect(c2.search.visibleItems.map((i) => i.eventId), ['new']);
    });

    testWidgets('일정이 바뀌면(새로고침) 검색 중인 검색어로 다시 받는다', (tester) async {
      final api = FakeCalendarApi()
        ..searchableEvents = [_item('a', '회의', DateTime(2026, 10, 5, 10))];
      final c = make(api);
      c.watch(DateTime(2026, 9, 27), DateTime(2026, 11, 7));
      c.search.setQuery('회의');
      await tester.pump(_debounce);
      await tester.pump();
      expect(api.callCount('searchEvents'), 1);
      await c.refresh();
      expect(api.callCount('searchEvents'), 2);
    });
  });

  group('PC 검색창', () {
    final items = [
      _item(
        'trip',
        '제주 워크숍',
        DateTime(2027, 2, 14),
        end: DateTime(2027, 2, 16),
        allDay: true,
        attendees: const [
          Attendee(userId: 'u2', name: '김철수'),
          Attendee(userId: 'u3', name: '이영희'),
          Attendee(userId: 'u4', name: '박민수'),
        ],
        calendarName: '디자인팀',
        calendarId: 'cal-shared',
      ),
      _item(
        'weekly',
        '주간 회의',
        DateTime(2026, 10, 5, 10),
        recurring: true,
        attendees: const [Attendee(userId: 'u2', name: '김철수')],
      ),
      _item('solo', '회의 준비', DateTime(2026, 8, 3, 14)),
    ];

    FakeCalendarApi api0() => FakeCalendarApi(
      mine: [personalCalendar(), sharedCalendar()],
      events: [
        timedEvent(
          'solo',
          DateTime(2026, 8, 3, 14),
          DateTime(2026, 8, 3, 15),
          title: '회의 준비',
          description: '자료 챙기기',
        ),
      ],
    )..searchableEvents = items;

    Future<void> pumpScreen(WidgetTester tester, FakeCalendarApi api) async {
      _size(tester, const Size(1280, 900));
      await tester.pumpWidget(
        MaterialApp(
          home: CalendarScreen(
            session: _session(),
            controller: _controller(api),
            now: _now,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> type(WidgetTester tester, String text) async {
      await tester.tap(find.byKey(const ValueKey('cal-search-field')));
      await tester.enterText(
        find.byKey(const ValueKey('cal-search-field')),
        text,
      );
      await tester.pump(_debounce);
      await tester.pumpAndSettle();
    }

    testWidgets('상단 툴바에 검색창이 있다', (tester) async {
      await pumpScreen(tester, api0());
      expect(find.byKey(const ValueKey('cal-search-field')), findsOneWidget);
      expect(find.text('일정 제목 검색'), findsOneWidget);
      // 입력 전에는 패널이 없다.
      expect(find.byKey(const ValueKey('cal-search-panel')), findsNothing);
    });

    testWidgets('입력하면 결과가 나온다: 제목·기간·캘린더·반복·참석자 표시', (tester) async {
      final api = api0();
      await pumpScreen(tester, api);
      await type(tester, '회의');
      expect(api.lastEventSearchQuery, '회의');
      expect(find.byKey(const ValueKey('cal-search-panel')), findsOneWidget);
      final weekly = find.byKey(const ValueKey('cal-search-item-weekly'));
      expect(weekly, findsOneWidget);
      expect(
        find.descendant(of: weekly, matching: find.text('주간 회의')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: weekly, matching: find.text('반복')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: weekly, matching: find.text('참석자 김철수')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: weekly, matching: find.text('나')),
        findsOneWidget,
      );
      // 반복이 아니고 참석자가 없는 일정에는 반복·참석자 표시가 없다.
      final solo = find.byKey(const ValueKey('cal-search-item-solo'));
      expect(
        find.descendant(of: solo, matching: find.text('반복')),
        findsNothing,
      );
      expect(
        find.descendant(of: solo, matching: find.textContaining('참석자')),
        findsNothing,
      );
      // 제목에 없는 '워크숍'은 '회의' 검색에 걸리지 않는다(제목 기준).
      expect(find.byKey(const ValueKey('cal-search-item-trip')), findsNothing);
      // 시간 범위.
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('cal-search-period-solo')))
            .data,
        contains('8월 3일'),
      );
    });

    testWidgets('종일 여러 날 일정은 날짜만, 참석자가 셋 이상이면 인원수', (tester) async {
      await pumpScreen(tester, api0());
      await type(tester, '워크숍');
      final trip = find.byKey(const ValueKey('cal-search-item-trip'));
      expect(trip, findsOneWidget);
      expect(
        find.descendant(of: trip, matching: find.text('참석자 3명')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: trip, matching: find.text('디자인팀')),
        findsOneWidget,
      );
      final period = tester
          .widget<Text>(find.byKey(const ValueKey('cal-search-period-trip')))
          .data!;
      expect(period, contains('2월 14일'));
      expect(period, contains('2월 16일'));
      expect(period, contains('종일'));
      expect(period, isNot(contains('오전')));
      expect(period, isNot(contains('오후')));
    });

    testWidgets('"이동"은 현재 보기를 유지한 채 그 일정의 날짜로 옮긴다(상세는 열지 않는다)', (tester) async {
      await pumpScreen(tester, api0());
      // 주간 보기로 바꾼 뒤 검색해도 보기는 그대로 주간.
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('cal-modes')),
          matching: find.text('주간'),
        ),
      );
      await tester.pumpAndSettle();
      await type(tester, '워크숍');
      await tester.tap(find.byKey(const ValueKey('cal-search-move-trip')));
      await tester.pumpAndSettle();
      // 2027-02-14(일)가 속한 주 — 일요일 시작이라 2/14 ~ 2/20.
      expect(find.text('2027년 2월 14일 – 20일'), findsWidgets);
      expect(find.byKey(const ValueKey('cal-week')), findsOneWidget);
      expect(find.byKey(const ValueKey('event-detail-title')), findsNothing);
      // 패널은 닫힌다.
      expect(find.byKey(const ValueKey('cal-search-panel')), findsNothing);
    });

    testWidgets('월간에서 "이동"하면 그 달로 간다', (tester) async {
      await pumpScreen(tester, api0());
      await type(tester, '워크숍');
      await tester.tap(find.byKey(const ValueKey('cal-search-move-trip')));
      await tester.pumpAndSettle();
      expect(find.text('2027년 2월'), findsWidgets);
      expect(find.byKey(const ValueKey('cal-month')), findsOneWidget);
    });

    testWidgets('항목을 누르면 일정 상세가 열린다', (tester) async {
      await pumpScreen(tester, api0());
      await type(tester, '준비');
      await tester.tap(find.byKey(const ValueKey('cal-search-item-solo')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('event-detail-title')), findsOneWidget);
      expect(find.text('회의 준비'), findsWidgets);
      expect(find.text('자료 챙기기'), findsOneWidget);
    });

    testWidgets('결과가 없으면 안내, 오류면 문구와 다시 시도', (tester) async {
      final api = api0();
      await pumpScreen(tester, api);
      await type(tester, '없는제목');
      expect(find.text('검색 결과가 없습니다.'), findsOneWidget);

      api.failWith = '서버가 응답하지 않습니다.';
      await type(tester, '회의');
      expect(find.text('서버가 응답하지 않습니다.'), findsOneWidget);
      api.failWith = null;
      await tester.tap(find.byKey(const ValueKey('cal-search-retry')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('cal-search-item-weekly')),
        findsOneWidget,
      );
    });

    testWidgets('불러오는 동안 진행 표시', (tester) async {
      final gate = Completer<void>();
      final api = _SlowApi(gate.future)..searchableEvents = items;
      await pumpScreen(tester, api);
      await tester.tap(find.byKey(const ValueKey('cal-search-field')));
      await tester.enterText(
        find.byKey(const ValueKey('cal-search-field')),
        '회의',
      );
      await tester.pump(_debounce);
      await tester.pump();
      expect(find.byKey(const ValueKey('cal-search-loading')), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cal-search-loading')), findsNothing);
    });

    testWidgets('Esc나 바깥을 누르면 패널이 닫히고, 칸을 다시 누르면 열린다', (tester) async {
      await pumpScreen(tester, api0());
      await type(tester, '회의');
      expect(find.byKey(const ValueKey('cal-search-panel')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cal-search-panel')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('cal-search-field')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cal-search-panel')), findsOneWidget);
      await tester.tapAt(const Offset(600, 500));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cal-search-panel')), findsNothing);
    });

    testWidgets('지우기(x)를 누르면 입력과 결과가 비워진다', (tester) async {
      await pumpScreen(tester, api0());
      await type(tester, '회의');
      await tester.tap(find.byKey(const ValueKey('cal-search-clear')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('cal-search-field')))
            .controller!
            .text,
        '',
      );
      expect(
        find.byKey(const ValueKey('cal-search-item-weekly')),
        findsNothing,
      );
    });

    testWidgets('숨긴 캘린더의 결과는 나오지 않는다', (tester) async {
      final api = api0();
      api.mine = [personalCalendar(), sharedCalendar(hidden: true)];
      await pumpScreen(tester, api);
      await type(tester, '워크숍');
      expect(find.byKey(const ValueKey('cal-search-item-trip')), findsNothing);
      expect(find.text('검색 결과가 없습니다.'), findsOneWidget);
    });
  });

  group('모바일 검색 화면(폭 360)', () {
    final items = [
      _item(
        'trip',
        '아주 긴 제목을 가진 제주 가족 여행 일정입니다 두 줄을 넘어가는 경우',
        DateTime(2027, 2, 14),
        end: DateTime(2027, 2, 16),
        allDay: true,
        recurring: true,
        attendees: const [
          Attendee(userId: 'u2', name: '김철수'),
          Attendee(userId: 'u3', name: '이영희'),
        ],
        calendarName: '아주 긴 이름의 공유 캘린더 이름',
        calendarId: 'cal-shared',
      ),
    ];

    Future<FakeCalendarApi> pumpNarrow(WidgetTester tester) async {
      _size(tester, const Size(360, 780));
      final api = FakeCalendarApi(mine: [personalCalendar(), sharedCalendar()])
        ..searchableEvents = items;
      await tester.pumpWidget(
        MaterialApp(
          home: CalendarScreen(
            session: _session(),
            controller: _controller(api),
            now: _now,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return api;
    }

    testWidgets('앱바 돋보기 → 전체 화면 검색, 입력하면 결과, 이동하면 닫히고 날짜로 간다', (tester) async {
      final api = await pumpNarrow(tester);
      expect(find.byKey(const ValueKey('cal-search-field')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('cal-search-open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cal-search-field')), findsOneWidget);
      expect(find.textContaining('일정 제목의 일부를 입력하세요'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('cal-search-field')),
        '여행',
      );
      await tester.pump(_debounce);
      await tester.pumpAndSettle();
      expect(api.lastEventSearchQuery, '여행');
      expect(
        find.byKey(const ValueKey('cal-search-item-trip')),
        findsOneWidget,
      );
      expect(find.text('반복'), findsOneWidget);
      expect(find.text('참석자 김철수, 이영희'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('cal-search-move-trip')));
      await tester.pumpAndSettle();
      // 검색 화면이 닫히고 월간이 2027년 2월로.
      expect(find.byKey(const ValueKey('cal-search-field')), findsNothing);
      expect(find.text('2027년 2월'), findsWidgets);
    });

    testWidgets('결과 항목을 누르면 검색 화면 위에 상세 시트가 열린다', (tester) async {
      final api = await pumpNarrow(tester);
      api.events = [
        allDayEvent(
          'trip',
          DateTime(2027, 2, 14),
          DateTime(2027, 2, 15),
          title: '가족 여행',
        ),
      ];
      await tester.tap(find.byKey(const ValueKey('cal-search-open')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('cal-search-field')),
        '여행',
      );
      await tester.pump(_debounce);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cal-search-item-trip')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('event-detail-title')), findsOneWidget);
      // 상세를 닫으면 검색 결과가 그대로 있다.
      await tester.tap(find.byTooltip('닫기'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('cal-search-item-trip')),
        findsOneWidget,
      );
    });
  });
}

/// 검색 응답을 [gate]가 열릴 때까지 붙잡아 두는 가짜 API.
class _SlowApi extends FakeCalendarApi {
  final Future<void> gate;
  _SlowApi(this.gate);

  @override
  Future<CalendarSearchPage> searchEvents(
    String teamId,
    String q, {
    String? before,
    int limit = 50,
  }) async {
    final page = await super.searchEvents(
      teamId,
      q,
      before: before,
      limit: limit,
    );
    await gate;
    return page;
  }
}
