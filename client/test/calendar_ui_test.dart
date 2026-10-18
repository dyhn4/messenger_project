import 'dart:convert';

import 'package:client/models/calendar.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/calendar/calendar_common.dart';
import 'package:client/screens/calendar/calendar_list_panel.dart';
import 'package:client/screens/calendar/calendar_month_view.dart';
import 'package:client/screens/calendar/calendar_screen.dart';
import 'package:client/screens/calendar/event_detail.dart';
import 'package:client/screens/calendar/event_editor.dart';
import 'package:client/screens/calendar/recurrence_scope_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/calendar_controller.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_calendar_api.dart';

/// 캘린더 화면 위젯 시험 — 월간 셀 표시, 캘린더 목록, 일정 폼 검증, 반복 범위 선택, 상세, 화면 전체 흐름.

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

final _now = DateTime(2026, 9, 30, 10, 15);

Session _session({AccountRole role = AccountRole.member, http.Client? client}) {
  final session = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: client,
  );
  session.userId = 'me';
  session.name = '나';
  session.accountRole = role;
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  return session;
}

/// 팀 멤버 목록을 돌려주는 가짜 서버(참석자 검색).
http.Client _membersClient() => MockClient((request) async {
  if (request.url.path == '/api/teams/t1/members') {
    return http.Response.bytes(
      utf8.encode(
        jsonEncode([
          {'id': 'me', 'username': 'me', 'name': '나', 'role': 'member'},
          {'id': 'u2', 'username': 'u2', 'name': '김철수', 'role': 'member'},
          {'id': 'u3', 'username': 'u3', 'name': '이영희', 'role': 'member'},
        ]),
      ),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
  return http.Response.bytes(utf8.encode('[]'), 200);
});

CalendarController _controller(FakeCalendarApi api) =>
    CalendarController(apiProvider: () => api, userId: () => 'me');

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 화면을 띄우고 첫 조회가 끝날 때까지 돌린다.
Future<CalendarController> _pumpScreen(
  WidgetTester tester,
  FakeCalendarApi api, {
  Size size = const Size(1280, 900),
  Session? session,
}) async {
  _size(tester, size);
  final controller = _controller(api);
  await tester.pumpWidget(
    MaterialApp(
      home: CalendarScreen(
        session: session ?? _session(),
        controller: controller,
        now: _now,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

/// 토스트가 사라질 때까지(타이머가 남지 않게) 시간을 흘린다.
Future<void> _drainToasts(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 3));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('월간 셀', () {
    final holiday = holidayEvent(DateTime(2026, 9, 25), '추석연휴');
    final workshop = allDayEvent(
      'w',
      DateTime(2026, 9, 29),
      DateTime(2026, 10, 1),
    );
    final secret = timedEvent(
      's',
      DateTime(2026, 9, 10, 9),
      DateTime(2026, 9, 10, 10),
      title: '비공개 일정',
      restricted: true,
      canEdit: false,
      canDelete: false,
    );
    final crowded = [
      for (var i = 0; i < 5; i++)
        timedEvent(
          'c$i',
          DateTime(2026, 9, 30, 8 + i),
          DateTime(2026, 9, 30, 9 + i),
          title: '회의$i',
        ),
    ];

    Future<
      ({List<DateTime> days, List<EventOccurrence> opened, List<DateTime> more})
    >
    pump(WidgetTester tester) async {
      _size(tester, const Size(1000, 700));
      final days = <DateTime>[];
      final opened = <EventOccurrence>[];
      final more = <DateTime>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1000,
              height: 600,
              child: CalendarMonthView(
                month: DateTime(2026, 9, 1),
                today: DateTime(2026, 9, 30),
                events: [holiday, workshop, secret, ...crowded],
                onDayTap: days.add,
                onEventTap: opened.add,
                onMoreTap: more.add,
              ),
            ),
          ),
        ),
      );
      return (days: days, opened: opened, more: more);
    }

    testWidgets('공휴일은 숫자가 빨갛고 이름이 붙는다', (tester) async {
      await pump(tester);
      expect(find.text('추석연휴'), findsOneWidget);
      Color numberColor(String cell, String text) => tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(ValueKey('cal-day-$cell')),
              matching: find.text(text),
            ),
          )
          .style!
          .color!;
      // 9/25 는 금요일이지만 공휴일이라 빨갛다.
      expect(numberColor('2026-09-25', '25'), kSundayColor);
      // 일요일 빨강 / 토요일 파랑 / 평일 일반.
      expect(numberColor('2026-09-27', '27'), kSundayColor);
      expect(numberColor('2026-09-26', '26'), kSaturdayColor);
      expect(numberColor('2026-09-10', '10'), isNot(kSundayColor));
      expect(numberColor('2026-09-10', '10'), isNot(kSaturdayColor));
    });

    testWidgets('여러 날 종일 일정은 한 개의 가로 막대로 이어진다', (tester) async {
      final r = await pump(tester);
      final bar = find.byKey(ValueKey('cal-bar-${workshop.key}-2'));
      expect(bar, findsOneWidget);
      expect(find.text('워크숍'), findsOneWidget);
      // 3일에 걸치므로 셀 폭의 약 3배(1000/7*3).
      expect(tester.getSize(bar).width, closeTo(1000 / 7 * 3, 1));
      await tester.tap(bar);
      expect(r.opened.single.eventId, 'w');
    });

    testWidgets('비공개 일정은 "비공개 일정"으로 보인다', (tester) async {
      await pump(tester);
      expect(find.textContaining('비공개 일정'), findsOneWidget);
    });

    testWidgets('일정이 많으면 "+N개"로 접고, 누르면 그 날을 알린다', (tester) async {
      final r = await pump(tester);
      // 9/30 은 워크숍 막대 + 시간 일정 5개 = 6개, 한 칸에 4줄 → 3줄만 보이고 3개가 접힌다.
      final more = find.byKey(const ValueKey('cal-more-2026-09-30'));
      expect(more, findsOneWidget);
      expect(
        find.descendant(of: more, matching: find.text('+3개')),
        findsOneWidget,
      );
      expect(find.textContaining('회의4'), findsNothing);
      await tester.tap(more);
      expect(r.more.single, DateTime(2026, 9, 30));
    });

    testWidgets('빈 날짜 칸을 누르면 그 날짜를 알린다', (tester) async {
      final r = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('cal-day-2026-09-15')));
      expect(r.days.single, DateTime(2026, 9, 15));
    });
  });

  group('캘린더 목록', () {
    Future<(FakeCalendarApi, CalendarController)> pumpPanel(
      WidgetTester tester, {
      List<CalendarInfo>? mine,
      List<CalendarInfo>? subscribed,
      CalendarManagementHooks hooks = const CalendarManagementHooks(),
    }) async {
      _size(tester, const Size(600, 900));
      final api = FakeCalendarApi(mine: mine, subscribed: subscribed);
      final controller = _controller(api);
      await controller.setTeam('t1');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: CalendarListPanel(controller: controller, hooks: hooks),
            ),
          ),
        ),
      );
      await tester.pump();
      return (api, controller);
    }

    testWidgets('나의 캘린더 / 구독 캘린더 두 묶음과 내장 캘린더', (tester) async {
      await pumpPanel(
        tester,
        mine: [personalCalendar(), sharedCalendar()],
        subscribed: [
          CalendarInfo(
            id: 'sub',
            kind: 'personal',
            name: '철수의 캘린더',
            color: '#43A047',
            role: 'subscriber',
          ),
        ],
      );
      expect(find.text('나의 캘린더'), findsOneWidget);
      expect(find.text('구독 캘린더'), findsOneWidget);
      expect(find.text('나'), findsOneWidget);
      expect(find.text('디자인팀'), findsOneWidget);
      expect(find.text('국가 공휴일'), findsOneWidget);
      expect(find.text('멤버 생일'), findsOneWidget);
      expect(find.text('철수의 캘린더'), findsOneWidget);
      // 체크박스는 보이는 캘린더가 체크된 상태.
      expect(
        tester
            .widget<Checkbox>(find.byKey(const ValueKey('cal-check-cal-me')))
            .value,
        isTrue,
      );
    });

    testWidgets('체크박스를 끄면 서버에 숨김을 저장한다', (tester) async {
      final (api, controller) = await pumpPanel(
        tester,
        mine: [personalCalendar(), sharedCalendar()],
      );
      await tester.tap(find.byKey(const ValueKey('cal-check-cal-shared')));
      await tester.pump();
      await tester.pump();
      expect(
        api.calls,
        contains('updateMySettings cal-shared color=null hidden=true'),
      );
      expect(controller.calendarById('cal-shared')!.hidden, isTrue);
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('cal-check-cal-shared')),
            )
            .value,
        isFalse,
      );
    });

    testWidgets('내장 캘린더 체크박스는 서버를 부르지 않는다', (tester) async {
      final (api, controller) = await pumpPanel(tester);
      await tester.tap(find.byKey(const ValueKey('cal-check-holidays')));
      await tester.pump();
      await tester.pump();
      expect(api.callCount('updateMySettings'), 0);
      expect(controller.isHidden('holidays'), isTrue);
    });

    testWidgets('색 변경: 팔레트에서 고르면 PATCH /me color', (tester) async {
      final (api, controller) = await pumpPanel(tester);
      await tester.tap(find.byKey(const ValueKey('cal-menu-cal-me')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('색 변경'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cal-color-#E53935')));
      await tester.pumpAndSettle();
      expect(
        api.calls,
        contains('updateMySettings cal-me color=#E53935 hidden=null'),
      );
      expect(controller.calendarById('cal-me')!.color, '#E53935');
    });

    testWidgets('메뉴 항목은 역할에 따라 다르다', (tester) async {
      await pumpPanel(
        tester,
        mine: [
          personalCalendar(),
          sharedCalendar(
            id: 'owned',
            name: '내가 만든',
            role: 'admin',
            canDelete: true,
          ),
          sharedCalendar(id: 'member', name: '속한 캘린더', role: 'write'),
        ],
        subscribed: [
          CalendarInfo(
            id: 'sub',
            kind: 'personal',
            name: '구독중',
            color: '#43A047',
            role: 'subscriber',
          ),
        ],
      );
      Future<List<String>> menuOf(String id) async {
        await tester.tap(find.byKey(ValueKey('cal-menu-$id')));
        await tester.pumpAndSettle();
        final items = [
          for (final label in ['색 변경', '캘린더 설정', '구독 취소', '나에게만 삭제', '삭제'])
            if (find.text(label).evaluate().isNotEmpty) label,
        ];
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        return items;
      }

      expect(await menuOf('cal-me'), ['색 변경', '캘린더 설정']);
      expect(await menuOf('owned'), ['색 변경', '캘린더 설정', '삭제']);
      expect(await menuOf('member'), ['색 변경', '캘린더 설정', '나에게만 삭제']);
      expect(await menuOf('sub'), ['색 변경', '캘린더 설정', '구독 취소']);
      // 내장 캘린더는 ⋯ 메뉴가 없다(숨기기만 가능).
      expect(find.byKey(const ValueKey('cal-menu-holidays')), findsNothing);
    });

    testWidgets('훅이 없으면 토스트로 안내하고, 있으면 훅을 부른다', (tester) async {
      await pumpPanel(tester);
      await tester.tap(find.byKey(const ValueKey('cal-add-mine')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('새 캘린더 만들기 기능은 아직 연결되지 않았습니다.'), findsOneWidget);
      await _drainToasts(tester);

      await tester.tap(find.byKey(const ValueKey('cal-menu-cal-me')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('캘린더 설정'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('캘린더 설정 기능은 아직 연결되지 않았습니다.'), findsOneWidget);
      await _drainToasts(tester);
    });

    testWidgets('준회원에게는 두 "+" 버튼이 없다', (tester) async {
      _size(tester, const Size(600, 900));
      final controller = CalendarController(
        apiProvider: () => FakeCalendarApi(),
        isGuest: () => true,
      );
      await controller.setTeam('t1');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: CalendarListPanel(
                controller: controller,
                hooks: const CalendarManagementHooks(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('cal-add-mine')), findsNothing);
      expect(find.byKey(const ValueKey('cal-add-subscribed')), findsNothing);
      expect(find.text('멤버 생일'), findsNothing);
      expect(find.text('국가 공휴일'), findsOneWidget);
    });

    testWidgets('연결된 훅에는 컨트롤러와 캘린더가 넘어간다', (tester) async {
      final calls = <String>[];
      await pumpPanel(
        tester,
        mine: [
          personalCalendar(),
          sharedCalendar(id: 'owned', role: 'admin', canDelete: true),
        ],
        hooks: CalendarManagementHooks(
          onCreateCalendar: (context, controller) async => calls.add('create'),
          onSearchSubscribe: (context, controller) async => calls.add('search'),
          onOpenSettings: (context, controller, calendar) async =>
              calls.add('settings ${calendar.id}'),
          onDelete: (context, controller, calendar) async =>
              calls.add('delete ${calendar.id}'),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('cal-add-mine')));
      await tester.tap(find.byKey(const ValueKey('cal-add-subscribed')));
      await tester.tap(find.byKey(const ValueKey('cal-menu-owned')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('캘린더 설정'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cal-menu-owned')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('삭제'));
      await tester.pumpAndSettle();
      expect(calls, ['create', 'search', 'settings owned', 'delete owned']);
    });
  });

  group('반복 범위 선택 대화상자', () {
    Future<RecurrenceScope?> open(
      WidgetTester tester,
      Future<void> Function() interact,
    ) async {
      RecurrenceScope? result;
      var done = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showRecurrenceScopeDialog(
                    context,
                    title: '반복 일정 수정',
                    confirmLabel: '수정',
                  );
                  done = true;
                },
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      await interact();
      await tester.pumpAndSettle();
      expect(done, isTrue);
      return result;
    }

    testWidgets('세 가지 선택지, 기본은 "이 일정만"', (tester) async {
      final scope = await open(tester, () async {
        expect(find.text('이 일정만'), findsOneWidget);
        expect(find.text('이 일정 및 이후 일정'), findsOneWidget);
        expect(find.text('모든 일정'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('scope-confirm')));
      });
      expect(scope, RecurrenceScope.thisOnly);
    });

    testWidgets('이후 일정 / 모든 일정을 고르면 그 범위를 돌려준다', (tester) async {
      expect(
        await open(tester, () async {
          await tester.tap(find.text('이 일정 및 이후 일정'));
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('scope-confirm')));
        }),
        RecurrenceScope.following,
      );
    });

    testWidgets('모든 일정', (tester) async {
      expect(
        await open(tester, () async {
          await tester.tap(find.text('모든 일정'));
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('scope-confirm')));
        }),
        RecurrenceScope.all,
      );
    });

    testWidgets('취소하면 null', (tester) async {
      expect(
        await open(tester, () async => tester.tap(find.text('취소'))),
        isNull,
      );
    });
  });

  group('일정 폼', () {
    Future<(FakeCalendarApi, CalendarController)> openEditor(
      WidgetTester tester, {
      FakeCalendarApi? api,
      Session? session,
      EventOccurrence? editing,
      RecurrenceScope? scope,
      DateTime? initialStart,
      Size size = const Size(1280, 900),
    }) async {
      _size(tester, size);
      final fake =
          api ?? FakeCalendarApi(mine: [personalCalendar(), sharedCalendar()]);
      final controller = _controller(fake);
      await controller.setTeam('t1');
      final s = session ?? _session();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showEventEditor(
                  context,
                  s,
                  controller,
                  editing: editing,
                  scope: scope,
                  initialStart: initialStart ?? DateTime(2026, 10, 5),
                ),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      return (fake, controller);
    }

    Future<void> save(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('event-save')));
      await tester.pumpAndSettle();
    }

    testWidgets('제목이 비면 저장되지 않고 안내한다', (tester) async {
      final (api, _) = await openEditor(tester);
      await save(tester);
      expect(find.text('제목을 입력하세요.'), findsOneWidget);
      expect(api.callCount('createEvent'), 0);
    });

    testWidgets('제목 50자 제한', (tester) async {
      await openEditor(tester);
      await tester.enterText(
        find.byKey(const ValueKey('event-title')),
        '가' * 60,
      );
      await tester.pump();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('event-title')),
      );
      expect(field.maxLength, kEventTitleMax);
      expect(field.controller!.text.length, kEventTitleMax);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('event-location')))
            .maxLength,
        50,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('event-description')))
            .maxLength,
        500,
      );
    });

    testWidgets('누른 날짜가 기본값이고 저장하면 시간 일정으로 만든다', (tester) async {
      final (api, _) = await openEditor(tester);
      // 10월 5일 오전 9시 ~ 10시가 기본.
      expect(find.text('10월 5일 (월)'), findsNWidgets(2));
      await tester.enterText(
        find.byKey(const ValueKey('event-title')),
        '주간 회의',
      );
      await tester.enterText(
        find.byKey(const ValueKey('event-location')),
        '3층',
      );
      await save(tester);

      final input = api.lastCreateInput!;
      expect(input.title, '주간 회의');
      expect(input.location, '3층');
      expect(input.allDay, isFalse);
      expect(input.start, DateTime(2026, 10, 5, 9).millisecondsSinceEpoch);
      expect(input.end, DateTime(2026, 10, 5, 10).millisecondsSinceEpoch);
      expect(input.visibility, 'public');
      expect(input.recurrence, isNull);
      expect(input.color, isNull, reason: '색을 안 골랐으면 보내지 않는다');
      expect(api.calls, contains('createEvent cal-me'));
      await _drainToasts(tester);
    });

    testWidgets('종일을 켜면 시각 칸이 사라지고 UTC 자정 날짜로 보낸다', (tester) async {
      final (api, _) = await openEditor(tester);
      expect(find.byKey(const ValueKey('event-start-time')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('event-allday')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('event-start-time')), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('event-title')), '워크숍');
      await save(tester);
      final input = api.lastCreateInput!;
      expect(input.allDay, isTrue);
      expect(input.start, DateTime.utc(2026, 10, 5).millisecondsSinceEpoch);
      // 하루짜리 종일: 끝은 다음 날 UTC 자정(배타).
      expect(input.end, DateTime.utc(2026, 10, 6).millisecondsSinceEpoch);
      await _drainToasts(tester);
    });

    testWidgets('종료 시각은 시작 시각 이하를 고를 수 없다', (tester) async {
      await openEditor(tester);
      await tester.tap(find.byKey(const ValueKey('event-end-time')));
      await tester.pumpAndSettle();
      // 시작이 오전 9:00 이라 종료 목록의 "오전 9:00" 은 눌러도 반응하지 않는다(비활성).
      final all = tester
          .widgetList<DropdownMenuItem<int>>(find.byType(DropdownMenuItem<int>))
          .toList();
      // 시작 칸의 9:00 은 고를 수 있지만 종료 칸의 9:00 은 비활성이다.
      expect(all.where((i) => i.value == 9 * 60 && !i.enabled), isNotEmpty);
      expect(all.where((i) => i.value == 10 * 60 && !i.enabled), isEmpty);
    });

    testWidgets('시작을 옮기면 종료가 같은 길이로 따라온다', (tester) async {
      final (api, _) = await openEditor(tester);
      await tester.tap(find.byKey(const ValueKey('event-start-time')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('오전 8:30').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('event-title')),
        '조금 늦은 회의',
      );
      await save(tester);
      expect(
        api.lastCreateInput!.start,
        DateTime(2026, 10, 5, 8, 30).millisecondsSinceEpoch,
      );
      expect(
        api.lastCreateInput!.end,
        DateTime(2026, 10, 5, 9, 30).millisecondsSinceEpoch,
      );
      await _drainToasts(tester);
    });

    testWidgets('반복: 매주를 고르면 요일 칩이 나오고 시작 요일이 선택돼 있다', (tester) async {
      final (api, _) = await openEditor(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('event-repeat')));
      await tester.tap(find.byKey(const ValueKey('event-repeat')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('매주').last);
      await tester.pumpAndSettle();
      // 10월 5일은 월요일(1).
      expect(
        tester
            .widget<FilterChip>(find.byKey(const ValueKey('event-weekday-1')))
            .selected,
        isTrue,
      );
      expect(find.text('매주 월요일 반복'), findsOneWidget);

      // 수요일도 추가.
      await tester.tap(find.byKey(const ValueKey('event-weekday-3')));
      await tester.pumpAndSettle();
      expect(find.text('매주 월·수요일 반복'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('event-title')), '스탠드업');
      await save(tester);
      final r = api.lastCreateInput!.recurrence!;
      expect(r.freq, 'weekly');
      expect(r.byWeekday, unorderedEquals([1, 3]));
      expect(r.interval, 1);
      await _drainToasts(tester);
    });

    testWidgets('반복: 매주에서 요일을 모두 끄면 저장할 수 없다', (tester) async {
      final (api, _) = await openEditor(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('event-repeat')));
      await tester.tap(find.byKey(const ValueKey('event-repeat')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('매주').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-weekday-1')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('event-title')), '스탠드업');
      await save(tester);
      expect(find.text('반복할 요일을 하나 이상 고르세요.'), findsOneWidget);
      expect(api.callCount('createEvent'), 0);
    });

    testWidgets('반복: 사용자 정의 간격·횟수를 검증한다', (tester) async {
      final (api, _) = await openEditor(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('event-repeat')));
      await tester.tap(find.byKey(const ValueKey('event-repeat')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('사용자 정의').last);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('event-title')),
        '격주 회고',
      );
      await tester.enterText(
        find.byKey(const ValueKey('event-interval')),
        '100',
      );
      await save(tester);
      expect(find.text('반복 간격은 1~99 사이의 숫자여야 합니다.'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('event-interval')), '2');
      await tester.ensureVisible(
        find.byKey(const ValueKey('event-repeat-end')),
      );
      await tester.tap(find.byKey(const ValueKey('event-repeat-end')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('횟수').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('event-count')), '501');
      await save(tester);
      expect(find.text('반복 횟수는 1~500 사이의 숫자여야 합니다.'), findsOneWidget);
      expect(api.callCount('createEvent'), 0);

      await tester.enterText(find.byKey(const ValueKey('event-count')), '8');
      await save(tester);
      final r = api.lastCreateInput!.recurrence!;
      expect(r.freq, 'daily');
      expect(r.interval, 2);
      expect(r.count, 8);
      expect(r.until, isNull, reason: 'until 과 count 는 동시에 보내지 않는다');
      await _drainToasts(tester);
    });

    testWidgets('공개 설정: 비공개를 고르면 visibility private', (tester) async {
      final (api, _) = await openEditor(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('event-visibility')),
      );
      await tester.tap(find.text('비공개'));
      await tester.pumpAndSettle();
      expect(find.text('비공개 일정은 초대된 사람만 자세한 내용을 볼 수 있습니다.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('event-title')), '면담');
      await save(tester);
      expect(api.lastCreateInput!.visibility, 'private');
      await _drainToasts(tester);
    });

    testWidgets('캘린더 선택 목록에는 쓰기 가능한 캘린더만 나온다', (tester) async {
      final api = FakeCalendarApi(
        mine: [
          personalCalendar(),
          sharedCalendar(id: 'w', name: '쓰기 가능', role: 'write'),
          sharedCalendar(id: 'r', name: '읽기 전용', role: 'read'),
        ],
      );
      final (_, controller) = await openEditor(tester, api: api);
      expect(controller.writableCalendars.map((c) => c.id), ['cal-me', 'w']);
      await tester.tap(find.byKey(const ValueKey('event-calendar')));
      await tester.pumpAndSettle();
      expect(find.text('쓰기 가능'), findsWidgets);
      expect(find.text('읽기 전용'), findsNothing);
    });

    testWidgets('서버 에러 메시지를 폼에 보여주고 닫지 않는다', (tester) async {
      final (api, _) = await openEditor(tester);
      api.failWith = '캘린더에 일정을 만들 권한이 없습니다.';
      await tester.enterText(find.byKey(const ValueKey('event-title')), '회의');
      await save(tester);
      expect(find.text('캘린더에 일정을 만들 권한이 없습니다.'), findsOneWidget);
      expect(find.byKey(const ValueKey('event-title')), findsOneWidget);
    });

    testWidgets('참석자: 이름 검색으로 추가하고 칩으로 보인다', (tester) async {
      final session = _session(client: _membersClient());
      final (api, _) = await openEditor(tester, session: session);
      await tester.ensureVisible(
        find.byKey(const ValueKey('event-attendee-search')),
      );
      await tester.tap(find.byKey(const ValueKey('event-attendee-search')));
      await tester.enterText(
        find.byKey(const ValueKey('event-attendee-search')),
        '철수',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-suggest-u2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('event-attendee-u2')), findsOneWidget);
      // 나 자신은 제안에 없다.
      await tester.enterText(
        find.byKey(const ValueKey('event-attendee-search')),
        '나',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('event-suggest-me')), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('event-title')),
        '워크숍 준비',
      );
      await save(tester);
      expect(api.lastCreateInput!.attendeeIds, ['u2']);
      await _drainToasts(tester);
    });

    testWidgets('준회원 요청자는 참석자 항목이 숨겨진다', (tester) async {
      await openEditor(tester, session: _session(role: AccountRole.guest));
      expect(find.byKey(const ValueKey('event-attendee-search')), findsNothing);
      expect(find.byKey(const ValueKey('event-attendee-org')), findsNothing);
    });

    testWidgets('모바일(좁은 창)에서는 전체 화면으로 열린다', (tester) async {
      final (api, _) = await openEditor(tester, size: const Size(400, 800));
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('일정 만들기'), findsWidgets);
      await tester.enterText(find.byKey(const ValueKey('event-title')), '병원');
      await save(tester);
      expect(api.lastCreateInput!.title, '병원');
      await _drainToasts(tester);
    });

    group('수정', () {
      final recurringEvent = timedEvent(
        'rec',
        DateTime(2026, 10, 5, 9),
        DateTime(2026, 10, 5, 10),
        title: '스탠드업',
        recurring: true,
        recurrence: const Recurrence(freq: 'weekly', byWeekday: [1]),
      );

      Future<FakeCalendarApi> editWith(
        WidgetTester tester,
        RecurrenceScope scope,
        Future<void> Function() change,
      ) async {
        final api = FakeCalendarApi(
          mine: [personalCalendar(), sharedCalendar()],
          events: [recurringEvent],
        );
        await openEditor(
          tester,
          api: api,
          editing: recurringEvent,
          scope: scope,
        );
        await change();
        await save(tester);
        return api;
      }

      testWidgets('기존 값이 채워져 있다', (tester) async {
        await openEditor(
          tester,
          editing: recurringEvent,
          scope: RecurrenceScope.all,
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('event-title')))
              .controller!
              .text,
          '스탠드업',
        );
        expect(find.text('일정 수정'), findsOneWidget);
        expect(find.text('매주 월요일 반복'), findsOneWidget);
      });

      testWidgets('scope=all: 제목만 바꾸면 바뀐 필드만 scope/occurrenceStart 와 함께 보낸다', (
        tester,
      ) async {
        final api = await editWith(tester, RecurrenceScope.all, () async {
          await tester.enterText(
            find.byKey(const ValueKey('event-title')),
            '스탠드업 (변경)',
          );
        });
        expect(api.lastEventFields, {'title': '스탠드업 (변경)'});
        expect(api.lastScope, RecurrenceScope.all);
        expect(api.lastOccurrenceStart, recurringEvent.start);
        await _drainToasts(tester);
      });

      testWidgets('scope=this: 반복 설정이 숨겨지고 이 회차의 시간을 함께 보낸다', (tester) async {
        final api = await editWith(tester, RecurrenceScope.thisOnly, () async {
          expect(find.byKey(const ValueKey('event-repeat')), findsNothing);
          await tester.enterText(
            find.byKey(const ValueKey('event-title')),
            '오늘만 다른 제목',
          );
        });
        expect(api.lastScope, RecurrenceScope.thisOnly);
        expect(api.lastEventFields!['title'], '오늘만 다른 제목');
        expect(api.lastEventFields!['start'], recurringEvent.start);
        expect(api.lastEventFields!['end'], recurringEvent.end);
        expect(api.lastEventFields!.containsKey('recurrence'), isFalse);
        await _drainToasts(tester);
      });

      testWidgets('scope=following: 이 회차부터 새 마스터가 되도록 시간을 함께 보낸다', (
        tester,
      ) async {
        final api = await editWith(tester, RecurrenceScope.following, () async {
          await tester.enterText(
            find.byKey(const ValueKey('event-location')),
            '4층',
          );
        });
        expect(api.lastScope, RecurrenceScope.following);
        expect(api.lastEventFields!['location'], '4층');
        expect(api.lastEventFields!['start'], recurringEvent.start);
        await _drainToasts(tester);
      });

      testWidgets('색만 바꾸면 scope 없이 color 만 보낸다(내 개인 설정)', (tester) async {
        final api = await editWith(tester, RecurrenceScope.thisOnly, () async {
          await tester.ensureVisible(
            find.byKey(const ValueKey('cal-color-#E53935')),
          );
          await tester.tap(find.byKey(const ValueKey('cal-color-#E53935')));
          await tester.pump();
        });
        expect(api.lastEventFields, {'color': '#E53935'});
        expect(api.lastScope, isNull);
        await _drainToasts(tester);
      });

      testWidgets('아무 것도 안 바꾸고 저장하면 서버를 부르지 않는다', (tester) async {
        final api = await editWith(tester, RecurrenceScope.all, () async {});
        expect(api.callCount('updateEvent'), 0);
        await _drainToasts(tester);
      });

      testWidgets('scope=all: 시간을 옮기면 start/end/allDay 를 보낸다', (tester) async {
        final api = await editWith(tester, RecurrenceScope.all, () async {
          await tester.tap(find.byKey(const ValueKey('event-start-time')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('오전 8:30').last);
          await tester.pumpAndSettle();
        });
        expect(
          api.lastEventFields!['start'],
          DateTime(2026, 10, 5, 8, 30).millisecondsSinceEpoch,
        );
        expect(
          api.lastEventFields!['end'],
          DateTime(2026, 10, 5, 9, 30).millisecondsSinceEpoch,
        );
        expect(api.lastEventFields!['allDay'], isFalse);
        await _drainToasts(tester);
      });
    });
  });

  group('일정 상세', () {
    Future<(FakeCalendarApi, CalendarController)> openDetail(
      WidgetTester tester,
      EventOccurrence event, {
      Size size = const Size(1280, 900),
      List<CalendarInfo>? mine,
    }) async {
      _size(tester, size);
      final api = FakeCalendarApi(
        mine: mine ?? [personalCalendar(), sharedCalendar()],
        events: [event],
      );
      final controller = _controller(api);
      await controller.setTeam('t1');
      final session = _session();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showEventDetail(
                  context,
                  session: session,
                  controller: controller,
                  event: event,
                ),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      return (api, controller);
    }

    testWidgets('제목·캘린더·기간·반복 요약·장소·설명·참석자·공개·만든 사람을 보여준다', (tester) async {
      final event = timedEvent(
        'e',
        DateTime(2026, 10, 5, 9),
        DateTime(2026, 10, 5, 10, 30),
        title: '스탠드업',
        calendarId: 'cal-shared',
        recurring: true,
        recurrence: const Recurrence(freq: 'weekly', byWeekday: [1, 3]),
        location: '3층 회의실',
        description: '오늘 할 일 공유',
        attendees: const [Attendee(userId: 'u2', name: '김철수')],
        visibility: 'private',
      );
      await openDetail(tester, event);
      expect(find.text('스탠드업'), findsOneWidget);
      expect(find.text('디자인팀'), findsOneWidget);
      expect(find.text('10월 5일 (월) 오전 9:00 – 오전 10:30'), findsOneWidget);
      expect(find.text('매주 월·수요일 반복'), findsOneWidget);
      expect(find.text('3층 회의실'), findsOneWidget);
      expect(find.text('오늘 할 일 공유'), findsOneWidget);
      expect(find.text('김철수'), findsOneWidget);
      expect(find.textContaining('비공개'), findsOneWidget);
      expect(find.text('만든 사람: 나'), findsOneWidget);
      expect(find.byKey(const ValueKey('event-edit')), findsOneWidget);
      expect(find.byKey(const ValueKey('event-delete')), findsOneWidget);
    });

    testWidgets('canEdit/canDelete 가 아니면 수정·삭제 아이콘이 없다', (tester) async {
      final event = timedEvent(
        'e',
        DateTime(2026, 10, 5, 9),
        DateTime(2026, 10, 5, 10),
        canEdit: false,
        canDelete: false,
      );
      await openDetail(tester, event);
      expect(find.byKey(const ValueKey('event-edit')), findsNothing);
      expect(find.byKey(const ValueKey('event-delete')), findsNothing);
    });

    testWidgets('비공개(restricted) 일정은 세부를 보이지 않는다', (tester) async {
      final event = timedEvent(
        'e',
        DateTime(2026, 10, 5, 9),
        DateTime(2026, 10, 5, 10),
        title: '비공개 일정',
        restricted: true,
        canEdit: false,
        canDelete: false,
        location: '비밀 장소',
      );
      await openDetail(tester, event);
      expect(find.text('비공개 일정'), findsWidgets);
      expect(find.text('비밀 장소'), findsNothing);
      expect(find.textContaining('초대된 사람만'), findsOneWidget);
    });

    testWidgets('공휴일 상세는 이름과 날짜만', (tester) async {
      await openDetail(tester, holidayEvent(DateTime(2026, 10, 9), '한글날'));
      expect(find.text('한글날'), findsOneWidget);
      expect(find.text('국가 공휴일'), findsOneWidget);
      expect(find.text('10월 9일 (금)'), findsOneWidget);
      expect(find.byKey(const ValueKey('event-edit')), findsNothing);
    });

    testWidgets('종일·여러 날 기간 표기', (tester) async {
      await openDetail(
        tester,
        allDayEvent('e', DateTime(2026, 10, 5), DateTime(2026, 10, 7)),
      );
      expect(find.text('10월 5일 (월) – 10월 7일 (수) · 종일'), findsOneWidget);
    });

    testWidgets('반복이 아닌 일정 삭제는 확인 후 scope 없이 지운다', (tester) async {
      final event = timedEvent(
        'e',
        DateTime(2026, 10, 5, 9),
        DateTime(2026, 10, 5, 10),
      );
      final (api, _) = await openDetail(tester, event);
      await tester.tap(find.byKey(const ValueKey('event-delete')));
      await tester.pumpAndSettle();
      expect(find.text('일정을 삭제할까요?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('event-delete-confirm')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('deleteEvent e null'));
      expect(api.lastOccurrenceStart, isNull);
      expect(find.text('일정을 삭제했습니다.'), findsOneWidget);
      await _drainToasts(tester);
    });

    testWidgets('반복 일정 삭제는 범위를 묻고 scope 와 occurrenceStart 를 보낸다', (
      tester,
    ) async {
      final event = timedEvent(
        'rec',
        DateTime(2026, 10, 12, 9),
        DateTime(2026, 10, 12, 10),
        recurring: true,
        recurrence: const Recurrence(freq: 'weekly', byWeekday: [1]),
      );
      final (api, _) = await openDetail(tester, event);
      await tester.tap(find.byKey(const ValueKey('event-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('이 일정 및 이후 일정'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('scope-confirm')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('deleteEvent rec following'));
      expect(api.lastScope, RecurrenceScope.following);
      expect(api.lastOccurrenceStart, event.start);
      await _drainToasts(tester);
    });

    testWidgets('반복 일정 수정은 범위를 묻고 편집기를 연다', (tester) async {
      final event = timedEvent(
        'rec',
        DateTime(2026, 10, 12, 9),
        DateTime(2026, 10, 12, 10),
        recurring: true,
        recurrence: const Recurrence(freq: 'daily'),
      );
      await openDetail(tester, event);
      await tester.tap(find.byKey(const ValueKey('event-edit')));
      await tester.pumpAndSettle();
      expect(find.text('반복 일정 수정'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('scope-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('일정 수정'), findsOneWidget);
      // "이 일정만"을 골랐으므로 반복 설정은 숨겨진다.
      expect(find.byKey(const ValueKey('event-repeat')), findsNothing);
    });

    testWidgets('모바일에서는 아래에서 올라오는 시트로 열린다', (tester) async {
      final event = timedEvent(
        'e',
        DateTime(2026, 10, 5, 9),
        DateTime(2026, 10, 5, 10),
      );
      await openDetail(tester, event, size: const Size(400, 800));
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('회의'), findsOneWidget);
    });
  });

  group('화면 전체', () {
    FakeCalendarApi api0() => FakeCalendarApi(
      mine: [personalCalendar(), sharedCalendar()],
      events: [
        timedEvent(
          'm',
          DateTime(2026, 9, 30, 10),
          DateTime(2026, 9, 30, 11),
          title: '오늘 회의',
        ),
        allDayEvent(
          'trip',
          DateTime(2026, 9, 29),
          DateTime(2026, 10, 1),
          title: '제주 출장',
        ),
        holidayEvent(DateTime(2026, 10, 3), '개천절'),
        timedEvent(
          'sh',
          DateTime(2026, 9, 15, 14),
          DateTime(2026, 9, 15, 15),
          title: '디자인 리뷰',
          calendarId: 'cal-shared',
          color: '#8E24AA',
        ),
      ],
    );

    testWidgets('월간: 제목·일정·공휴일이 보이고 이전/다음/오늘로 이동한다', (tester) async {
      await _pumpScreen(tester, api0());
      expect(find.text('2026년 9월'), findsWidgets);
      expect(find.textContaining('오늘 회의'), findsOneWidget);
      expect(find.text('제주 출장'), findsOneWidget);
      expect(find.textContaining('디자인 리뷰'), findsOneWidget);
      expect(find.text('개천절'), findsOneWidget);
      // 캘린더 목록 두 묶음이 왼쪽에 있다.
      expect(find.text('나의 캘린더'), findsOneWidget);
      expect(find.text('구독 캘린더'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('cal-next')));
      await tester.pumpAndSettle();
      expect(find.text('2026년 10월'), findsWidgets);
      // 10월 격자에는 9월 중순 일정이 없다(9/27 이후 앞쪽 며칠만 이어서 보인다).
      expect(find.textContaining('디자인 리뷰'), findsNothing);
      expect(find.text('개천절'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cal-today')));
      await tester.pumpAndSettle();
      expect(find.text('2026년 9월'), findsWidgets);
      expect(find.textContaining('디자인 리뷰'), findsOneWidget);
    });

    testWidgets('캘린더 체크를 끄면 그 캘린더 일정이 사라진다', (tester) async {
      await _pumpScreen(tester, api0());
      expect(find.textContaining('디자인 리뷰'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cal-check-cal-shared')));
      await tester.pumpAndSettle();
      expect(find.textContaining('디자인 리뷰'), findsNothing);
      expect(find.textContaining('오늘 회의'), findsOneWidget);
    });

    testWidgets('공휴일 캘린더 체크를 끄면 공휴일 이름이 사라진다', (tester) async {
      await _pumpScreen(tester, api0());
      expect(find.text('개천절'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cal-check-holidays')));
      await tester.pumpAndSettle();
      expect(find.text('개천절'), findsNothing);
    });

    testWidgets('보기 전환: 주간 → 일간 → 목록', (tester) async {
      await _pumpScreen(tester, api0());
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('cal-modes')),
          matching: find.text('주간'),
        ),
      );
      await tester.pumpAndSettle();
      // 7일 전부(일요일 시작): 27 28 29 30 1 2 3 머리글.
      expect(find.text('2026년 9월 27일 – 10월 3일'), findsWidgets);
      for (final key in [
        '9-27',
        '9-28',
        '9-29',
        '9-30',
        '10-1',
        '10-2',
        '10-3',
      ]) {
        expect(
          find.byKey(ValueKey('cal-head-$key')),
          findsOneWidget,
          reason: key,
        );
      }
      expect(find.text('오늘 회의'), findsOneWidget);
      expect(find.text('제주 출장'), findsOneWidget, reason: '종일 일정은 위쪽 종일 칸에');

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('cal-modes')),
          matching: find.text('일간'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2026년 9월 30일 (수)'), findsWidgets);
      expect(find.text('오늘 회의'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('cal-modes')),
          matching: find.text('목록'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('9월 30일 (수)'), findsOneWidget);
      expect(find.text('9월 15일 (화)'), findsOneWidget);
      expect(find.text('오늘 회의'), findsOneWidget);
      expect(find.text('디자인 리뷰'), findsOneWidget);
    });

    testWidgets('일정 만들기 오른쪽의 닫기 — 따로 띄운 캘린더 화면을 닫는다', (tester) async {
      final api = api0();
      _size(tester, const Size(1280, 900));
      final controller = _controller(api);
      final session = _session();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CalendarScreen(
                        session: session,
                        controller: controller,
                        now: _now,
                      ),
                    ),
                  ),
                  child: const Text('열기'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      final create = tester.getRect(find.byKey(const ValueKey('cal-create')));
      final close = tester.getRect(find.byKey(const ValueKey('cal-close')));
      expect(close.left, greaterThan(create.right));
      expect(close.center.dy, closeTo(create.center.dy, 1));
      await tester.tap(find.byKey(const ValueKey('cal-close')));
      await tester.pumpAndSettle();
      expect(find.byType(CalendarScreen), findsNothing);
      expect(find.text('열기'), findsOneWidget);
    });

    testWidgets('일정 만들기 버튼은 편집기를 열고, 저장하면 목록에 나타난다', (tester) async {
      final api = api0();
      await _pumpScreen(tester, api);
      await tester.tap(find.byKey(const ValueKey('cal-create')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('event-title')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('event-title')), '새 일정');
      await tester.tap(find.byKey(const ValueKey('event-save')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('createEvent cal-me'));
      expect(find.textContaining('새 일정'), findsOneWidget);
      await _drainToasts(tester);
    });

    testWidgets('빈 날짜 칸을 누르면 그 날짜로 일정 만들기가 열린다', (tester) async {
      await _pumpScreen(tester, api0());
      await tester.tap(find.byKey(const ValueKey('cal-day-2026-09-20')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('event-title')), findsOneWidget);
      expect(find.text('9월 20일 (일)'), findsNWidgets(2));
    });

    testWidgets('일정을 누르면 상세가 열린다', (tester) async {
      await _pumpScreen(tester, api0());
      await tester.tap(find.textContaining('오늘 회의'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('event-detail-title')), findsOneWidget);
      expect(find.byKey(const ValueKey('event-edit')), findsOneWidget);
    });

    testWidgets('일정이 많은 날의 "+N개"는 그 날 목록 대화상자를 연다', (tester) async {
      final api = FakeCalendarApi(
        events: [
          for (var i = 0; i < 8; i++)
            timedEvent(
              'x$i',
              DateTime(2026, 9, 16, 8 + i),
              DateTime(2026, 9, 16, 9 + i),
              title: '일정$i',
            ),
        ],
      );
      await _pumpScreen(tester, api, size: const Size(1280, 700));
      final more = find.byKey(const ValueKey('cal-more-2026-09-16'));
      expect(more, findsOneWidget);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.text('9월 16일 (수)'), findsOneWidget);
      // 대화상자에는 8개가 다 있다.
      for (var i = 0; i < 8; i++) {
        expect(find.text('일정$i'), findsWidgets);
      }
    });

    testWidgets('팀을 바꾸면 그 팀의 캘린더를 다시 받는다', (tester) async {
      final api = api0();
      final session = _session();
      session.teams.add(Team(id: 't2', name: '다른팀', createdAt: DateTime(2026)));
      await _pumpScreen(tester, api, session: session);
      expect(api.calls.where((c) => c == 'fetchCalendars t1'), hasLength(1));
      session.enterTeam(session.teams.last);
      await tester.pumpAndSettle();
      expect(api.calls, contains('fetchCalendars t2'));
    });

    group('모바일(좁은 창)', () {
      testWidgets('월간 격자 아래에 선택한 날의 일정 목록이 나온다', (tester) async {
        await _pumpScreen(tester, api0(), size: const Size(400, 800));
        // 오늘(9/30)이 선택돼 있고, 그 날 일정이 목록에 있다.
        expect(find.text('오늘 회의'), findsWidgets);
        expect(find.text('9월 30일 (수)'), findsOneWidget);

        // 9/15 를 누르면 그 날 일정으로 바뀐다.
        await tester.tap(find.byKey(const ValueKey('cal-day-2026-09-15')));
        await tester.pumpAndSettle();
        expect(find.text('9월 15일 (화)'), findsOneWidget);
        expect(find.text('디자인 리뷰'), findsWidgets);
      });

      testWidgets('일정 생성 + 버튼이 선택한 날짜로 편집기를 연다', (tester) async {
        await _pumpScreen(tester, api0(), size: const Size(400, 800));
        await tester.tap(find.byKey(const ValueKey('cal-day-2026-09-15')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('cal-create')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('event-title')), findsOneWidget);
        expect(find.text('9월 15일 (화)'), findsNWidgets(2));
      });

      testWidgets('4가지 보기 전환과 캘린더 목록 서랍', (tester) async {
        await _pumpScreen(tester, api0(), size: const Size(400, 800));
        for (final label in ['주간', '일간', '목록', '월간']) {
          await tester.tap(
            find.descendant(
              of: find.byKey(const ValueKey('cal-modes')),
              matching: find.text(label),
            ),
          );
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const ValueKey('cal-open-list')));
        await tester.pumpAndSettle();
        expect(find.text('나의 캘린더'), findsOneWidget);
        expect(find.text('구독 캘린더'), findsOneWidget);
        expect(find.text('국가 공휴일'), findsOneWidget);
      });
    });
  });
}
