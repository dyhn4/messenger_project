import 'dart:convert';

import 'package:client/models/calendar.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/calendar/calendar_common.dart';
import 'package:client/screens/calendar/calendar_list_panel.dart';
import 'package:client/screens/calendar/calendar_screen.dart';
import 'package:client/screens/calendar/management/calendar_create.dart';
import 'package:client/screens/calendar/management/calendar_management.dart';
import 'package:client/screens/calendar/management/calendar_settings.dart';
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

/// 캘린더 관리 화면 시험 — 새 캘린더 폼 검증, 설정(관리자/일반 멤버/소유자/팀), 멤버 추가·권한·내보내기,
/// 구독 검색·구독, 나에게만 삭제·삭제 확인, 훅 연결(더는 "연결되지 않았습니다"가 안 뜬다).

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

final _now = DateTime(2026, 9, 30, 10, 15);

/// 팀 멤버(GET /api/teams/t1/members) — 준회원 '박준회'가 하나 들어 있다.
http.Client _teamClient() => MockClient((request) async {
  if (request.url.path == '/api/teams/t1/members') {
    return http.Response.bytes(
      utf8.encode(
        jsonEncode([
          {'id': 'me', 'username': 'me', 'name': '나', 'role': 'member'},
          {'id': 'u2', 'username': 'u2', 'name': '김철수', 'role': 'member'},
          {'id': 'u3', 'username': 'u3', 'name': '이영희', 'role': 'member'},
          {'id': 'g1', 'username': 'g1', 'name': '박준회', 'role': 'guest'},
        ]),
      ),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
  return http.Response.bytes(utf8.encode('[]'), 200);
});

Session _session({AccountRole role = AccountRole.member}) {
  final session = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: _teamClient(),
  );
  session.userId = 'me';
  session.name = '나';
  session.accountRole = role;
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  return session;
}

CalendarController _controller(FakeCalendarApi api, {bool guest = false}) =>
    CalendarController(
      apiProvider: () => api,
      userId: () => 'me',
      isGuest: () => guest,
    );

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 토스트가 사라질 때까지(타이머가 남지 않게) 시간을 흘린다.
Future<void> _drainToasts(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 3));

/// 화면 전체(CalendarScreen, 훅은 기본값)를 띄운다 — 실제 앱과 같은 연결.
Future<CalendarController> _pumpScreen(
  WidgetTester tester,
  FakeCalendarApi api, {
  Size size = const Size(1280, 900),
  Session? session,
  bool guest = false,
}) async {
  _size(tester, size);
  final controller = _controller(api, guest: guest);
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

Finder _text(String s) => find.text(s);

const _notConnected = '아직 연결되지 않았습니다';

/// 설정 본문을 곧바로 띄운다.
Future<CalendarController> _pumpSettings(
  WidgetTester tester,
  FakeCalendarApi api,
  CalendarInfo calendar, {
  Size size = const Size(700, 1400),
  Session? session,
}) async {
  _size(tester, size);
  final controller = _controller(api);
  await controller.setTeam('t1');
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: CalendarSettingsView(
            session: session ?? _session(),
            controller: controller,
            calendar: controller.calendarById(calendar.id) ?? calendar,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

CalendarInfo _ownedShared({String id = 'owned', String name = '내가 만든'}) =>
    CalendarInfo(
      id: id,
      teamId: 't1',
      kind: 'shared',
      name: name,
      color: '#8E24AA',
      isPublic: true,
      ownerId: 'me',
      ownerName: '나',
      role: 'admin',
      canCreateEvents: true,
      canDelete: true,
      canEditSettings: true,
    );

FakeCalendarApi _apiWithOwned() {
  final api = FakeCalendarApi(mine: [personalCalendar(), _ownedShared()]);
  api.userNames.addAll({'u2': '김철수', 'u3': '이영희', 'g1': '박준회'});
  api.guestUserIds.add('g1');
  api.members['owned'] = [
    CalendarMember(userId: 'me', name: '나', role: 'admin', isOwner: true),
    CalendarMember(userId: 'u2', name: '김철수', role: 'write'),
  ];
  return api;
}

/// 드롭다운을 열고 [label] 항목을 고른다(선택된 값도 같은 글자라 마지막 것을 누른다).
Future<void> _pickDropdown(
  WidgetTester tester,
  Finder dropdown,
  String label,
) async {
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('이름 검사', () {
    test('1~30자만 통과한다', () {
      expect(validateCalendarName(''), isNotNull);
      expect(validateCalendarName('   '), isNotNull);
      expect(validateCalendarName('가'), isNull);
      expect(validateCalendarName('가' * 30), isNull);
      expect(validateCalendarName('가' * 31), contains('30자'));
      // 앞뒤 공백은 세지 않는다.
      expect(validateCalendarName('  ${'a' * 30}  '), isNull);
      // 이모지는 한 글자로 센다(서버도 글자 단위).
      expect(validateCalendarName('😀' * 30), isNull);
      expect(validateCalendarName('😀' * 31), isNotNull);
    });
  });

  group('새 캘린더 만들기', () {
    Future<(FakeCalendarApi, CalendarController)> pumpForm(
      WidgetTester tester, {
      List<CalendarInfo>? mine,
    }) async {
      _size(tester, const Size(700, 900));
      final api = FakeCalendarApi(mine: mine);
      final controller = _controller(api);
      await controller.setTeam('t1');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CalendarCreateForm(controller: controller)),
        ),
      );
      await tester.pump();
      return (api, controller);
    }

    FilledButton submit(WidgetTester tester) => tester.widget<FilledButton>(
      find.byKey(const ValueKey('cal-create-submit')),
    );

    testWidgets('이름이 비어 있으면 만들 수 없고, 쓰면 만들기가 켜진다', (tester) async {
      final (api, _) = await pumpForm(tester);
      expect(submit(tester).onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('cal-create-name')),
        '   ',
      );
      await tester.pump();
      expect(submit(tester).onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('cal-create-name')),
        '디자인팀',
      );
      await tester.pump();
      expect(submit(tester).onPressed, isNotNull);
      expect(api.callCount('createCalendar'), 0);
    });

    testWidgets('입력 칸은 30자까지만 받는다', (tester) async {
      await pumpForm(tester);
      await tester.enterText(
        find.byKey(const ValueKey('cal-create-name')),
        '가' * 40,
      );
      await tester.pump();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('cal-create-name')),
      );
      expect(field.controller!.text.characters.length, 30);
    });

    testWidgets('색은 기본으로 안 쓰는 색이 골라져 있고 바꿀 수 있다', (tester) async {
      // 기본 캘린더가 파랑(#1E88E5)이 아니라 팔레트 첫 색을 쓰고 있으면 그다음 색이 기본.
      final (api, controller) = await pumpForm(
        tester,
        mine: [personalCalendar(color: calendarPalette.first)],
      );
      await tester.enterText(
        find.byKey(const ValueKey('cal-create-name')),
        '영업 일정',
      );
      await tester.tap(find.byKey(const ValueKey('cal-color-#8E24AA')));
      await tester.pump();
      // 고른 색에 체크 표시가 붙는다.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('cal-color-#8E24AA')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('cal-create-submit')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('createCalendar 영업 일정'));
      expect(api.lastCreateColor, '#8E24AA');
      expect(controller.mine.map((c) => c.name), contains('영업 일정'));
    });

    testWidgets('이름 앞뒤 공백은 잘라서 보낸다', (tester) async {
      final (api, _) = await pumpForm(tester);
      await tester.enterText(
        find.byKey(const ValueKey('cal-create-name')),
        '  스터디  ',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('cal-create-submit')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('createCalendar 스터디'));
    });

    testWidgets('서버 오류는 폼 안에 그대로 보이고 창은 열려 있다', (tester) async {
      final (api, _) = await pumpForm(tester);
      api.failWith = '준회원은 새 캘린더를 만들 수 없습니다.';
      await tester.enterText(
        find.byKey(const ValueKey('cal-create-name')),
        '스터디',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('cal-create-submit')));
      await tester.pumpAndSettle();
      expect(_text('준회원은 새 캘린더를 만들 수 없습니다.'), findsOneWidget);
      expect(find.byKey(const ValueKey('cal-create-submit')), findsOneWidget);
    });
  });

  group('훅 연결 (CalendarScreen 기본값)', () {
    testWidgets('+ 버튼: 새 캘린더 → 만들면 그 캘린더의 설정이 열린다', (tester) async {
      final api = FakeCalendarApi();
      await _pumpScreen(tester, api);
      await tester.tap(find.byKey(const ValueKey('cal-add-mine')));
      await tester.pumpAndSettle();
      expect(_text('새 캘린더 만들기'), findsOneWidget);
      expect(find.textContaining(_notConnected), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('cal-create-name')),
        '프로젝트',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('cal-create-submit')));
      await tester.pumpAndSettle();
      // 목록에 나타나고, 이어서 설정 창이 열린다(멤버 추가를 바로 할 수 있게).
      expect(api.calls, contains('createCalendar 프로젝트'));
      expect(_text('캘린더 설정'), findsOneWidget);
      expect(find.byKey(const ValueKey('cal-settings-name')), findsOneWidget);
      expect(_text('프로젝트'), findsWidgets);
      // 소유자 한 명이 멤버로 보인다.
      expect(
        find.byKey(const ValueKey('cal-member-owner-badge')),
        findsOneWidget,
      );
    });

    testWidgets('+ 버튼: 구독 캘린더 찾기가 열린다', (tester) async {
      final api = FakeCalendarApi();
      await _pumpScreen(tester, api);
      await tester.tap(find.byKey(const ValueKey('cal-add-subscribed')));
      await tester.pumpAndSettle();
      expect(_text('구독할 캘린더 찾기'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cal-subscribe-search')),
        findsOneWidget,
      );
      expect(find.textContaining(_notConnected), findsNothing);
    });

    testWidgets('⋯ 메뉴의 설정·나에게만 삭제·구독 취소·삭제 모두 연결돼 있다', (tester) async {
      final api = _apiWithOwned();
      api.mine = [
        ...api.mine,
        sharedCalendar(id: 'member', name: '속한 캘린더', role: 'write'),
      ];
      api.subscribed = [
        CalendarInfo(
          id: 'sub',
          kind: 'personal',
          name: '철수의 캘린더',
          color: '#43A047',
          ownerName: '김철수',
          role: 'subscriber',
        ),
      ];
      await _pumpScreen(tester, api);

      Future<void> open(String id, String item) async {
        await tester.tap(find.byKey(ValueKey('cal-menu-$id')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(item));
        await tester.pumpAndSettle();
      }

      // 설정
      await open('owned', '캘린더 설정');
      expect(find.byKey(const ValueKey('cal-settings-name')), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      // 삭제 — 확인 창(취소하면 아무 일도 안 한다)
      await open('owned', '삭제');
      expect(find.textContaining('모든 일정도 함께 삭제'), findsOneWidget);
      await tester.tap(_text('취소'));
      await tester.pumpAndSettle();
      expect(api.callCount('deleteCalendar'), 0);
      // 나에게만 삭제
      await open('member', '나에게만 삭제');
      expect(find.textContaining('내 목록에서만 삭제'), findsOneWidget);
      await tester.tap(_text('취소'));
      await tester.pumpAndSettle();
      // 구독 취소
      await open('sub', '구독 취소');
      expect(find.textContaining('구독을 취소할까요'), findsOneWidget);
      await tester.tap(_text('취소'));
      await tester.pumpAndSettle();

      expect(find.textContaining(_notConnected), findsNothing);
      expect(api.callCount('leaveCalendar'), 0);
    });

    testWidgets('모바일(좁은 화면)에서는 전체 화면으로 열린다', (tester) async {
      final api = _apiWithOwned();
      await _pumpScreen(tester, api, size: const Size(400, 800));
      await tester.tap(find.byKey(const ValueKey('cal-open-list')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cal-add-mine')));
      await tester.pumpAndSettle();
      // 대화상자가 아니라 앱바가 있는 새 화면.
      expect(find.byType(Dialog), findsNothing);
      expect(
        find.descendant(of: find.byType(AppBar), matching: _text('새 캘린더 만들기')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('cal-create-name')),
        '모바일 캘린더',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('cal-create-submit')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('createCalendar 모바일 캘린더'));
      // 이어서 설정 화면.
      expect(
        find.descendant(of: find.byType(AppBar), matching: _text('캘린더 설정')),
        findsOneWidget,
      );
    });

    testWidgets('준회원에게는 + 버튼이 없다', (tester) async {
      await _pumpScreen(
        tester,
        FakeCalendarApi(),
        session: _session(role: AccountRole.guest),
        guest: true,
      );
      expect(find.byKey(const ValueKey('cal-add-mine')), findsNothing);
      expect(find.byKey(const ValueKey('cal-add-subscribed')), findsNothing);
    });

    testWidgets('일부 훅만 연결하면 나머지는 안내 토스트(패널 단독 사용)', (tester) async {
      _size(tester, const Size(600, 900));
      final api = FakeCalendarApi();
      final controller = _controller(api);
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
      await tester.tap(find.byKey(const ValueKey('cal-add-mine')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining(_notConnected), findsOneWidget);
      await _drainToasts(tester);
    });

    testWidgets('세션 기본 훅에는 다섯 콜백이 모두 있다', (tester) async {
      final hooks = buildCalendarManagementHooks(_session());
      expect(hooks.onCreateCalendar, isNotNull);
      expect(hooks.onSearchSubscribe, isNotNull);
      expect(hooks.onOpenSettings, isNotNull);
      expect(hooks.onLeave, isNotNull);
      expect(hooks.onDelete, isNotNull);
    });
  });

  group('캘린더 설정 — 관리자(소유자) 공유 캘린더', () {
    testWidgets('이름·공개·멤버가 모두 활성이고 소유자와 멤버가 보인다', (tester) async {
      final api = _apiWithOwned();
      await _pumpSettings(tester, api, _ownedShared());
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('cal-settings-name')))
            .enabled,
        isTrue,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('cal-settings-public')),
            )
            .onChanged,
        isNotNull,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('cal-settings-owner')))
            .data,
        '나',
      );
      expect(find.byKey(const ValueKey('cal-member-me')), findsOneWidget);
      expect(find.byKey(const ValueKey('cal-member-u2')), findsOneWidget);
      // 소유자는 권한 드롭다운도 내보내기도 없다.
      expect(find.byKey(const ValueKey('cal-member-role-me')), findsNothing);
      expect(find.byKey(const ValueKey('cal-member-remove-me')), findsNothing);
      expect(
        find.byKey(const ValueKey('cal-member-owner-badge')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('cal-settings-delete')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cal-settings-readonly-note')),
        findsNothing,
      );
    });

    testWidgets('이름을 바꾸면 저장 버튼이 나타나고 PATCH가 나간다', (tester) async {
      final api = _apiWithOwned();
      final controller = await _pumpSettings(tester, api, _ownedShared());
      expect(
        find.byKey(const ValueKey('cal-settings-name-save')),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const ValueKey('cal-settings-name')),
        '새 이름',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('cal-settings-name-save')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('updateCalendar owned'));
      expect(controller.calendarById('owned')!.name, '새 이름');
      await _drainToasts(tester);
    });

    testWidgets('빈 이름은 저장할 수 없다', (tester) async {
      final api = _apiWithOwned();
      await _pumpSettings(tester, api, _ownedShared());
      await tester.enterText(
        find.byKey(const ValueKey('cal-settings-name')),
        ' ',
      );
      await tester.pump();
      final save = tester.widget<FilledButton>(
        find.byKey(const ValueKey('cal-settings-name-save')),
      );
      expect(save.onPressed, isNull);
    });

    testWidgets('비공개로 바꾸면 구독 불가 안내가 보인다', (tester) async {
      final api = _apiWithOwned();
      final controller = await _pumpSettings(tester, api, _ownedShared());
      expect(find.textContaining('검색해서 구독할 수 있어요'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cal-settings-public')));
      await tester.pumpAndSettle();
      expect(controller.calendarById('owned')!.isPublic, isFalse);
      expect(find.textContaining('구독할 수 없어요'), findsOneWidget);
    });

    testWidgets('색은 누구나 바꾼다(PATCH /me)', (tester) async {
      final api = _apiWithOwned();
      await _pumpSettings(tester, api, _ownedShared());
      await tester.tap(find.byKey(const ValueKey('cal-color-#E53935')));
      await tester.pumpAndSettle();
      expect(
        api.calls,
        contains('updateMySettings owned color=#E53935 hidden=null'),
      );
    });

    testWidgets('이름 검색으로 멤버를 추가한다(고른 권한으로)', (tester) async {
      final api = _apiWithOwned();
      await _pumpSettings(tester, api, _ownedShared());
      await _pickDropdown(
        tester,
        find.byKey(const ValueKey('cal-member-add-role')),
        '추가 권한: 읽기',
      );
      await tester.enterText(
        find.byKey(const ValueKey('cal-member-search')),
        '이영',
      );
      await tester.pump();
      // 이미 멤버인 김철수는 제안에 없다.
      await tester.enterText(
        find.byKey(const ValueKey('cal-member-search')),
        '김',
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('cal-suggest-u2')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('cal-member-search')),
        '이영',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('cal-suggest-u3')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('addMember owned u3 read'));
      expect(find.byKey(const ValueKey('cal-member-u3')), findsOneWidget);
      await _drainToasts(tester);
    });

    testWidgets('준회원은 어떤 권한을 골라도 읽기로만 추가된다', (tester) async {
      final api = _apiWithOwned();
      await _pumpSettings(tester, api, _ownedShared());
      await tester.enterText(
        find.byKey(const ValueKey('cal-member-search')),
        '박준',
      );
      await tester.pump();
      expect(find.textContaining('준회원 · 읽기 권한으로 추가돼요'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cal-suggest-g1')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('addMember owned g1 read'));
      expect(find.textContaining('준회원'), findsWidgets);
      await _drainToasts(tester);
    });

    testWidgets('준회원 멤버의 권한 드롭다운은 읽기만 고를 수 있다', (tester) async {
      final api = _apiWithOwned();
      api.members['owned']!.add(
        CalendarMember(userId: 'g1', name: '박준회', role: 'read'),
      );
      await _pumpSettings(tester, api, _ownedShared());
      await tester.tap(find.byKey(const ValueKey('cal-member-role-g1')));
      await tester.pumpAndSettle();
      // 메뉴에서 '관리자'를 눌러도 아무 일도 안 일어난다(비활성).
      await tester.tap(find.text('관리자').last);
      await tester.pumpAndSettle();
      expect(api.callCount('updateMemberRole'), 0);
      // 메뉴를 닫는다.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    });

    testWidgets('멤버 권한을 바꾼다', (tester) async {
      final api = _apiWithOwned();
      await _pumpSettings(tester, api, _ownedShared());
      await _pickDropdown(
        tester,
        find.byKey(const ValueKey('cal-member-role-u2')),
        '관리자',
      );
      expect(api.calls, contains('updateMemberRole owned u2 admin'));
      final dropdown = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('cal-member-role-u2')),
      );
      expect(dropdown.value, 'admin');
    });

    testWidgets('권한 변경이 서버에서 거절되면 토스트로 알리고 값은 그대로', (tester) async {
      final api = _apiWithOwned();
      await _pumpSettings(tester, api, _ownedShared());
      api.failWith = '권한이 올바르지 않습니다.';
      await _pickDropdown(
        tester,
        find.byKey(const ValueKey('cal-member-role-u2')),
        '관리자',
      );
      expect(_text('권한이 올바르지 않습니다.'), findsOneWidget);
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(const ValueKey('cal-member-role-u2')),
            )
            .value,
        'write',
      );
      await _drainToasts(tester);
    });

    testWidgets('멤버 내보내기: 확인 후 removeMember, 취소하면 그대로', (tester) async {
      final api = _apiWithOwned();
      await _pumpSettings(tester, api, _ownedShared());
      await tester.tap(find.byKey(const ValueKey('cal-member-remove-u2')));
      await tester.pumpAndSettle();
      expect(find.textContaining("'김철수' 님을 이 캘린더에서 내보낼까요"), findsOneWidget);
      await tester.tap(_text('취소'));
      await tester.pumpAndSettle();
      expect(api.callCount('removeMember'), 0);

      await tester.tap(find.byKey(const ValueKey('cal-member-remove-u2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cal-confirm-ok')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('removeMember owned u2'));
      expect(find.byKey(const ValueKey('cal-member-u2')), findsNothing);
      await _drainToasts(tester);
    });

    testWidgets('조직도에서 여러 명을 골라 추가한다', (tester) async {
      final api = _apiWithOwned();
      await _pumpSettings(
        tester,
        api,
        _ownedShared(),
        size: const Size(1280, 1000),
      );
      await tester.tap(find.byKey(const ValueKey('cal-member-org')));
      await tester.pumpAndSettle();
      // 멤버 고르기 창 — 이미 멤버인 김철수와 나는 목록에 없다.
      expect(_text('멤버 추가'), findsOneWidget);
      expect(find.text('김철수'), findsNWidgets(1)); // 설정 창의 멤버 줄 하나뿐
      await tester.tap(find.text('이영희').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cal-org-confirm')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('addMember owned u3 write'));
      await _drainToasts(tester);
    });

    testWidgets('서버에서 멤버 목록을 못 받으면 다시 시도할 수 있다', (tester) async {
      final api = _apiWithOwned();
      api.failWith = '캘린더 관리자만 멤버를 관리할 수 있습니다.';
      await _pumpSettings(tester, api, _ownedShared());
      expect(_text('캘린더 관리자만 멤버를 관리할 수 있습니다.'), findsOneWidget);
      api.failWith = null;
      await tester.tap(_text('다시 시도'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cal-member-u2')), findsOneWidget);
    });

    testWidgets('삭제: 경고 문구가 있는 확인 후에만 지운다', (tester) async {
      final api = _apiWithOwned();
      final controller = await _pumpSettings(tester, api, _ownedShared());
      await tester.ensureVisible(
        find.byKey(const ValueKey('cal-settings-delete')),
      );
      await tester.tap(find.byKey(const ValueKey('cal-settings-delete')));
      await tester.pumpAndSettle();
      expect(find.textContaining('모든 일정도 함께 삭제'), findsWidgets);
      await tester.tap(_text('취소'));
      await tester.pumpAndSettle();
      expect(api.callCount('deleteCalendar'), 0);

      await tester.tap(find.byKey(const ValueKey('cal-settings-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cal-confirm-ok')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('deleteCalendar owned'));
      expect(controller.calendarById('owned'), isNull);
      await _drainToasts(tester);
    });
  });

  group('캘린더 설정 — 일반 멤버·구독자·기본·팀', () {
    testWidgets('쓰기 멤버: 읽기 전용, 색만 활성, 나에게만 삭제', (tester) async {
      final api = FakeCalendarApi(
        mine: [
          personalCalendar(),
          sharedCalendar(id: 'member', name: '속한 캘린더', role: 'write'),
        ],
      );
      await _pumpSettings(
        tester,
        api,
        sharedCalendar(id: 'member', role: 'write'),
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('cal-settings-name')))
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('cal-settings-public')),
            )
            .onChanged,
        isNull,
      );
      expect(
        find.byKey(const ValueKey('cal-settings-readonly-note')),
        findsOneWidget,
      );
      // 멤버 관리 영역과 멤버 목록 요청이 없다(서버도 관리자에게만 준다).
      expect(find.byKey(const ValueKey('cal-member-search')), findsNothing);
      expect(api.callCount('fetchMembers'), 0);
      expect(find.byKey(const ValueKey('cal-settings-delete')), findsNothing);
      // 색 변경은 된다.
      await tester.tap(find.byKey(const ValueKey('cal-color-#E53935')));
      await tester.pumpAndSettle();
      expect(
        api.calls,
        contains('updateMySettings member color=#E53935 hidden=null'),
      );
      // 나에게만 삭제 → 확인 → leaveCalendar.
      await tester.ensureVisible(
        find.byKey(const ValueKey('cal-settings-leave')),
      );
      await tester.tap(find.byKey(const ValueKey('cal-settings-leave')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cal-confirm-ok')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('leaveCalendar member'));
      await _drainToasts(tester);
    });

    testWidgets('구독자: 소유자 이름이 보이고 구독 취소가 있다', (tester) async {
      final sub = CalendarInfo(
        id: 'sub',
        teamId: 't1',
        kind: 'personal',
        name: '김철수',
        color: '#43A047',
        isPublic: true,
        ownerId: 'u2',
        ownerName: '김철수',
        role: 'subscriber',
      );
      final api = FakeCalendarApi(subscribed: [sub]);
      await _pumpSettings(tester, api, sub);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('cal-settings-owner')))
            .data,
        '김철수',
      );
      expect(find.textContaining('구독 중'), findsWidgets);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('cal-settings-name')))
            .enabled,
        isFalse,
      );
      expect(find.widgetWithText(OutlinedButton, '구독 취소'), findsOneWidget);
    });

    testWidgets('기본 캘린더: 이름은 못 바꾸고 공개/비공개만 소유자가 바꾼다', (tester) async {
      final api = FakeCalendarApi();
      final controller = await _pumpSettings(tester, api, personalCalendar());
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('cal-settings-name')))
            .enabled,
        isFalse,
      );
      expect(find.text('기본 캘린더의 이름은 바꿀 수 없어요.'), findsOneWidget);
      expect(find.byKey(const ValueKey('cal-member-search')), findsNothing);
      expect(find.byKey(const ValueKey('cal-settings-delete')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('cal-settings-public')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('updateCalendar cal-me'));
      expect(controller.calendarById('cal-me')!.isPublic, isFalse);
    });

    testWidgets('팀 캘린더: 공개 스위치·이름 수정 없이 색만', (tester) async {
      final team = CalendarInfo(
        id: 'team-cal',
        teamId: 't1',
        kind: 'team',
        name: '팀 캘린더',
        color: '#00897B',
        role: 'read',
      );
      final api = FakeCalendarApi(mine: [personalCalendar(), team]);
      await _pumpSettings(tester, api, team);
      expect(find.byKey(const ValueKey('cal-settings-public')), findsNothing);
      expect(find.textContaining('팀 캘린더는 설정이 없고'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('cal-settings-name')))
            .enabled,
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('cal-color-#E53935')));
      await tester.pumpAndSettle();
      expect(
        api.calls,
        contains('updateMySettings team-cal color=#E53935 hidden=null'),
      );
    });
  });

  group('구독', () {
    Future<FakeCalendarApi> openSubscribe(WidgetTester tester) async {
      final api = FakeCalendarApi();
      api.searchable = [
        const CalendarSearchResult(
          id: 'c-kim',
          kind: 'personal',
          name: '김철수',
          color: '#43A047',
          ownerName: '김철수',
        ),
        const CalendarSearchResult(
          id: 'c-design',
          kind: 'shared',
          name: '디자인팀',
          color: '#8E24AA',
          ownerName: '이영희',
        ),
        const CalendarSearchResult(
          id: 'c-done',
          kind: 'shared',
          name: '디자인 리뷰',
          color: '#F9A825',
          ownerName: '박대리',
          subscribed: true,
        ),
      ];
      await _pumpScreen(tester, api);
      await tester.tap(find.byKey(const ValueKey('cal-add-subscribed')));
      await tester.pumpAndSettle();
      return api;
    }

    testWidgets('열면 구독할 수 있는 캘린더가 보이고, 종류·소유자·구독 중이 표시된다', (tester) async {
      await openSubscribe(tester);
      expect(find.byKey(const ValueKey('cal-result-c-kim')), findsOneWidget);
      expect(find.text('기본 캘린더'), findsOneWidget);
      expect(find.text('공유 캘린더 · 소유자 이영희'), findsOneWidget);
      expect(find.byKey(const ValueKey('cal-subscribe-c-kim')), findsOneWidget);
      // 이미 구독 중이면 버튼 대신 "구독 중".
      expect(
        find.byKey(const ValueKey('cal-subscribed-c-done')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('cal-subscribe-c-done')), findsNothing);
    });

    testWidgets('검색어는 멈춘 뒤에 한 번만 서버에 묻는다(디바운스)', (tester) async {
      final api = await openSubscribe(tester);
      final before = api.callCount('searchCalendars');
      await tester.enterText(
        find.byKey(const ValueKey('cal-subscribe-search')),
        '디',
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(
        find.byKey(const ValueKey('cal-subscribe-search')),
        '디자',
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.callCount('searchCalendars'), before);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(api.callCount('searchCalendars'), before + 1);
      expect(api.lastSearchQuery, '디자');
      expect(find.byKey(const ValueKey('cal-result-c-design')), findsOneWidget);
      expect(find.byKey(const ValueKey('cal-result-c-kim')), findsNothing);
    });

    testWidgets('결과가 없으면 안내 문구', (tester) async {
      await openSubscribe(tester);
      await tester.enterText(
        find.byKey(const ValueKey('cal-subscribe-search')),
        '없는이름',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(_text('검색 결과가 없습니다.'), findsOneWidget);
    });

    testWidgets('구독하기를 누르면 구독되고 목록에 "구독 중"으로 바뀐다', (tester) async {
      final api = await openSubscribe(tester);
      await tester.tap(find.byKey(const ValueKey('cal-subscribe-c-kim')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('subscribe c-kim'));
      expect(
        find.byKey(const ValueKey('cal-subscribed-c-kim')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('cal-subscribe-c-kim')), findsNothing);
      await _drainToasts(tester);
    });

    testWidgets('구독 실패(서버 403)는 그대로 토스트로', (tester) async {
      final api = await openSubscribe(tester);
      api.failWith = '공개되지 않은 캘린더입니다.';
      await tester.tap(find.byKey(const ValueKey('cal-subscribe-c-kim')));
      await tester.pumpAndSettle();
      expect(_text('공개되지 않은 캘린더입니다.'), findsOneWidget);
      expect(find.byKey(const ValueKey('cal-subscribe-c-kim')), findsOneWidget);
      await _drainToasts(tester);
    });

    testWidgets('검색이 403이면(준회원 등) 오류를 그대로 보여 준다', (tester) async {
      final api = FakeCalendarApi()..failWith = '준회원은 캘린더를 구독할 수 없습니다.';
      await _pumpScreen(tester, api);
      await tester.tap(find.byKey(const ValueKey('cal-add-subscribed')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cal-subscribe-error')), findsOneWidget);
      expect(_text('준회원은 캘린더를 구독할 수 없습니다.'), findsOneWidget);
    });
  });

  group('나에게만 삭제 · 구독 취소 · 삭제', () {
    testWidgets('구독 취소를 확인하면 leaveCalendar가 불리고 목록에서 사라진다', (tester) async {
      final api = FakeCalendarApi(
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
      await _pumpScreen(tester, api);
      await tester.tap(find.byKey(const ValueKey('cal-menu-sub')));
      await tester.pumpAndSettle();
      await tester.tap(_text('구독 취소'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cal-confirm-ok')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('leaveCalendar sub'));
      expect(_text('철수의 캘린더'), findsNothing);
      // 항목이 사라진 뒤에도 결과 토스트가 보인다.
      expect(_text('구독을 취소했습니다.'), findsOneWidget);
      await _drainToasts(tester);
    });

    testWidgets('공유 캘린더 멤버의 나에게만 삭제', (tester) async {
      final api = FakeCalendarApi(
        mine: [
          personalCalendar(),
          sharedCalendar(id: 'member', name: '속한 캘린더', role: 'read'),
        ],
      );
      await _pumpScreen(tester, api);
      await tester.tap(find.byKey(const ValueKey('cal-menu-member')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('나에게만 삭제'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cal-confirm-ok')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('leaveCalendar member'));
      expect(_text('속한 캘린더'), findsNothing);
      await _drainToasts(tester);
    });

    testWidgets('소유자 삭제: 확인하면 deleteCalendar, 서버 오류는 토스트', (tester) async {
      final api = _apiWithOwned();
      await _pumpScreen(tester, api);
      api.failWith = '캘린더 소유자만 삭제할 수 있습니다.';
      await tester.tap(find.byKey(const ValueKey('cal-menu-owned')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('삭제'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cal-confirm-ok')));
      await tester.pumpAndSettle();
      expect(_text('캘린더 소유자만 삭제할 수 있습니다.'), findsOneWidget);
      expect(_text('내가 만든'), findsOneWidget);
      await _drainToasts(tester);

      api.failWith = null;
      await tester.tap(find.byKey(const ValueKey('cal-menu-owned')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('삭제'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cal-confirm-ok')));
      await tester.pumpAndSettle();
      expect(api.calls.where((c) => c == 'deleteCalendar owned'), hasLength(2));
      expect(_text('내가 만든'), findsNothing);
      expect(_text('캘린더를 삭제했습니다.'), findsOneWidget);
      await _drainToasts(tester);
    });
  });
}
