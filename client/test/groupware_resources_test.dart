// 회의실·자원 예약과 휴가 달력(앱) — 모양 읽기, "예약" 탭(시간표·예약 창·겹침 안내·취소), 관리 탭 자원 관리, 휴가 달력(격자·고른 날),
// 캘린더 일정 편집 창의 "회의실·자원"(고르기·빼기·반복이면 막기)과 상세. 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/calendar.dart';
import 'package:client/models/groupware.dart';
import 'package:client/models/groupware_resources.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/calendar/event_detail.dart';
import 'package:client/screens/calendar/event_editor.dart';
import 'package:client/screens/groupware/groupware_screen.dart'
    show GroupwareChanges;
import 'package:client/screens/groupware/leave_calendar.dart';
import 'package:client/screens/groupware/resource_tab.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/calendar_controller.dart';
import 'package:client/services/groupware_api.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_calendar_api.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

GroupwareContext _ctx({bool manager = false}) => GroupwareContext.fromJson({
  'scope': 'team',
  'teamId': 'T1',
  'isManager': manager,
  'today': '2026-10-17',
  'leaveTypes': [
    {'key': 'annual', 'label': '연차', 'deducts': true, 'half': false},
  ],
  'expenseCategories': ['식대'],
  'limits': {'approversMax': 5, 'ccMax': 10, 'attachmentsMax': 5},
});

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

class _Harness {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{};
  late final Session session;
  _Harness({AccountRole role = AccountRole.member}) {
    session = Session(
      notifications: _QuietNotifications(),
      settings: AppSettings(),
    );
    session.serverUrl = 'https://test.local';
    session.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient((request) async {
        requests.add(request);
        final route = routes['${request.method} ${request.url.path}'];
        return route != null
            ? route(request)
            : _json({'error': 'no route'}, status: 404);
      }),
    );
    session.userId = 'U-me';
    session.name = '나';
    session.accountRole = role;
    final team = Team(id: 'T1', name: '본사', createdAt: DateTime(2026));
    session.teams.add(team);
    session.currentTeam = team;
  }

  GroupwareApi get api => GroupwareApi(session.api!, teamId: 'T1');
  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
  Map<String, dynamic> lastBody(String method, String path) =>
      jsonDecode(called(method, path).last.body) as Map<String, dynamic>;
}

/// 편집 창 안에서 [finder]를 화면 가운데로 굴린다(아래 저장 줄에 가리지 않게).
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1100, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

// 오늘 — 예약 탭은 오늘부터 보인다(지난 시간 검사는 서버 몫이라 앱 시험에서는 상관없음).
final _day = DateTime.now();
int _at(int h, [int m = 0]) =>
    DateTime(_day.year, _day.month, _day.day, h, m).millisecondsSinceEpoch;

Map<String, dynamic> _room(
  String id,
  String name, {
  String kind = 'room',
  bool enabled = true,
  Map<String, dynamic>? busy,
}) => {
  'id': id,
  'kind': kind,
  'name': name,
  'location': '3층',
  'capacity': 12,
  'enabled': enabled,
  'busy': ?busy,
};

Map<String, dynamic> _booking(
  String id,
  String resourceId, {
  required int start,
  required int end,
  String title = '주간 회의',
  bool mine = false,
  String? eventId,
  String userName = '홍길동',
}) => {
  'id': id,
  'resourceId': resourceId,
  'resourceName': resourceId == 'R1' ? '대회의실' : '빔프로젝터',
  'resourceKind': 'room',
  'title': title,
  'userId': mine ? 'U-me' : 'U-x',
  'userName': userName,
  'start': start,
  'end': end,
  'eventId': eventId,
  'mine': mine,
  'canCancel': mine,
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('모양 읽기', () {
    test('자원·예약·휴가 달력·일정의 자원', () {
      final r = GroupwareResource.fromJson(
        _room(
          'R1',
          '대회의실',
          busy: _booking('B1', 'R1', start: _at(10), end: _at(11)),
        ),
      );
      expect(r.kindLabel, '회의실');
      expect(r.detail, '3층 · 12명');
      expect(r.busy!.userName, '홍길동');
      expect(
        GroupwareResource.fromJson({
          'id': 'R2',
          'name': '법인차',
          'kind': 'vehicle',
        }).detail,
        '',
      );
      final b = ResourceBooking.fromJson(
        _booking('B1', 'R1', start: _at(10), end: _at(11, 30), eventId: 'E1'),
      );
      expect(b.fromEvent, isTrue);
      expect(bookingRangeText(b), '${_day.month}/${_day.day} 10:00~11:30');
      final month = LeaveMonth.fromJson({
        'month': '2026-10',
        'holidays': [
          {'date': '2026-10-09', 'name': '한글날'},
        ],
        'leaves': [
          {
            'documentId': 'D1',
            'userId': 'U1',
            'name': '김가',
            'label': '연차',
            'startDate': '2026-10-19',
            'endDate': '2026-10-20',
            'status': 'approved',
          },
        ],
        'trips': [
          {
            'documentId': 'D2',
            'userId': 'U2',
            'name': '이나',
            'destination': '부산',
            'startDate': '2026-10-20',
            'endDate': '2026-10-20',
          },
        ],
      });
      expect(month.holidays['2026-10-09'], '한글날');
      expect(month.leavesOn('2026-10-20').single.name, '김가');
      expect(month.leavesOn('2026-10-21'), isEmpty);
      expect(month.tripsOn('2026-10-20').single.destination, '부산');
      final occ = EventOccurrence.fromJson({
        'key': 'E1:1',
        'eventId': 'E1',
        'calendarId': 'c1',
        'title': '고객 미팅',
        'start': 1,
        'end': 2,
        'resource': {
          'bookingId': 'B1',
          'resourceId': 'R1',
          'name': '대회의실',
          'kind': 'room',
        },
      });
      expect(occ.resource!.name, '대회의실');
      expect(
        const EventInput(
          title: 't',
          start: 1,
          end: 2,
          resourceId: 'R1',
        ).toJson()['resourceId'],
        'R1',
      );
      expect(
        const EventInput(title: 't', start: 1, end: 2).toJson(),
        isNot(contains('resourceId')),
      );
      expect(kBuiltinCalendarIds, contains(kBookingsCalendarId));
    });
  });

  group('예약 탭', () {
    void routes(_Harness h) {
      h.routes['GET /api/groupware/resources'] = (_) => _json([
        _room('R1', '대회의실'),
        _room('R2', '빔프로젝터', kind: 'equipment'),
        _room('R3', '법인차', kind: 'vehicle', enabled: false),
      ]);
      h.routes['GET /api/groupware/bookings'] = (_) => _json([
        _booking('B1', 'R1', start: _at(10), end: _at(11)),
        _booking(
          'B2',
          'R1',
          start: _at(14),
          end: _at(15),
          title: '고객 미팅',
          mine: true,
          eventId: 'E1',
        ),
      ]);
      h.routes['GET /api/groupware/bookings/mine'] = (_) => _json([
        _booking(
          'B2',
          'R1',
          start: _at(14),
          end: _at(15),
          title: '고객 미팅',
          mine: true,
          eventId: 'E1',
        ),
      ]);
    }

    testWidgets('자원마다 시간표 — 끈 자원은 빠짐, 날을 넘기면 그날 예약을 받는다', (tester) async {
      final h = _Harness();
      routes(h);
      await _pump(
        tester,
        ResourceTab(
          api: h.api,
          ctx: _ctx(),
          changes: GroupwareChanges(),
          session: h.session,
        ),
      );
      expect(find.byKey(const ValueKey('resource-R1')), findsOneWidget);
      expect(find.byKey(const ValueKey('resource-R2')), findsOneWidget);
      expect(find.byKey(const ValueKey('resource-R3')), findsNothing);
      expect(find.byKey(const ValueKey('booking-B1')), findsOneWidget);
      expect(find.byKey(const ValueKey('my-booking-B2')), findsOneWidget);
      expect(find.textContaining('캘린더 일정'), findsOneWidget);
      final firstFrom = h
          .called('GET', '/api/groupware/bookings')
          .last
          .url
          .queryParameters['from'];
      await tester.tap(find.byTooltip('다음 날'));
      await tester.pumpAndSettle();
      final nextFrom = h
          .called('GET', '/api/groupware/bookings')
          .last
          .url
          .queryParameters['from'];
      expect(int.parse(nextFrom!) - int.parse(firstFrom!), greaterThan(0));
      expect(find.text('오늘'), findsOneWidget);
    });

    testWidgets('예약 창 — 겹치면 서버 글을 창 안에, 고치면 예약', (tester) async {
      final h = _Harness();
      routes(h);
      var attempts = 0;
      h.routes['POST /api/groupware/bookings'] = (r) {
        attempts += 1;
        if (attempts == 1) {
          return _json({
            'error': '이미 예약된 시간입니다 (10/18 10:00~11:00 홍길동)',
          }, status: 409);
        }
        return _json(
          _booking(
            'B9',
            'R2',
            start: _at(10),
            end: _at(11),
            title: '빔프로젝터 예약',
            mine: true,
          ),
          status: 201,
        );
      };
      await _pump(
        tester,
        ResourceTab(
          api: h.api,
          ctx: _ctx(),
          changes: GroupwareChanges(),
          session: h.session,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('resource-book')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('booking-title')),
        '팀 회의',
      );
      await tester.tap(find.byKey(const ValueKey('booking-save')));
      await tester.pumpAndSettle();
      expect(find.text('이미 예약된 시간입니다 (10/18 10:00~11:00 홍길동)'), findsOneWidget);
      final first = h.lastBody('POST', '/api/groupware/bookings');
      expect(first['resourceId'], 'R1');
      expect(first['title'], '팀 회의');
      expect(first['teamId'], 'T1');
      // 기본은 1시간 — 밤 11시 넘어 열면 자정에서 끊겨 30분이 된다(시각에 따라).
      final length = (first['end'] as int) - (first['start'] as int);
      expect(length == 3600000 || length == 1800000, isTrue, reason: '$length');
      // 다른 자원으로 바꿔 다시.
      await tester.tap(find.byKey(const ValueKey('booking-resource')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('빔프로젝터 (장비)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('booking-save')));
      await tester.pumpAndSettle();
      expect(h.lastBody('POST', '/api/groupware/bookings')['resourceId'], 'R2');
      expect(find.byKey(const ValueKey('booking-save')), findsNothing);
      expect(find.textContaining('빔프로젝터을(를) 예약했습니다'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('시간표의 빈 곳을 누르면 그 자원·그 30분으로 예약 창', (tester) async {
      final h = _Harness();
      routes(h);
      await _pump(
        tester,
        ResourceTab(
          api: h.api,
          ctx: _ctx(),
          changes: GroupwareChanges(),
          session: h.session,
        ),
      );
      final bar = find.descendant(
        of: find.byKey(const ValueKey('resource-R2')),
        matching: find.byType(GestureDetector),
      );
      // 07:00~22:00 막대의 맨 왼쪽 근처 — 07:00.
      final rect = tester.getRect(bar.first);
      await tester.tapAt(Offset(rect.left + 2, rect.center.dy));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const ValueKey('booking-resource')),
            )
            .initialValue,
        'R2',
      );
      expect(
        tester
            .widget<DropdownButton<int>>(
              find.byKey(const ValueKey('booking-start')),
            )
            .value,
        7 * 60,
      );
    });

    testWidgets('예약을 누르면 자세히 — 내 일정 예약은 취소(일정은 남는다는 안내)', (tester) async {
      final h = _Harness();
      routes(h);
      h.routes['DELETE /api/groupware/bookings/B2'] = (_) =>
          _json({'ok': true});
      await _pump(
        tester,
        ResourceTab(
          api: h.api,
          ctx: _ctx(),
          changes: GroupwareChanges(),
          session: h.session,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('booking-B1')));
      await tester.pumpAndSettle();
      expect(find.text('잡은 사람: 홍길동'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('booking-cancel')),
        findsNothing,
        reason: '남의 예약',
      );
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('my-booking-B2')));
      await tester.pumpAndSettle();
      expect(find.textContaining('일정은 남고 회의실만 빠집니다'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('booking-cancel')));
      await tester.pumpAndSettle();
      expect(h.called('DELETE', '/api/groupware/bookings/B2'), hasLength(1));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('준회원은 현황만', (tester) async {
      final h = _Harness(role: AccountRole.guest);
      routes(h);
      await _pump(
        tester,
        ResourceTab(
          api: h.api,
          ctx: _ctx(),
          changes: GroupwareChanges(),
          session: h.session,
        ),
      );
      expect(find.byKey(const ValueKey('resource-book')), findsNothing);
      expect(find.text('준회원은 현황만 볼 수 있습니다.'), findsOneWidget);
    });
  });

  testWidgets('관리 — 자원 더하기·끄기·지우기', (tester) async {
    final h = _Harness();
    h.routes['GET /api/groupware/resources'] = (_) =>
        _json([_room('R1', '대회의실')]);
    h.routes['POST /api/groupware/resources'] = (_) =>
        _json(_room('R2', '법인차', kind: 'vehicle'), status: 201);
    h.routes['PATCH /api/groupware/resources/R1'] = (_) =>
        _json(_room('R1', '대회의실', enabled: false));
    h.routes['DELETE /api/groupware/resources/R1'] = (_) => _json({'ok': true});
    await _pump(
      tester,
      SingleChildScrollView(
        child: ResourcesAdminSection(api: h.api, changes: GroupwareChanges()),
      ),
    );
    expect(find.text('회의실 · 3층 · 12명'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('resource-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('차량'));
    await tester.enterText(find.byKey(const ValueKey('resource-name')), '법인차');
    await tester.enterText(
      find.byKey(const ValueKey('resource-capacity')),
      '0',
    );
    await tester.tap(find.byKey(const ValueKey('resource-save')));
    await tester.pumpAndSettle();
    expect(find.text('수용 인원은 1 이상의 숫자로 넣으세요.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('resource-capacity')),
      '5',
    );
    await tester.tap(find.byKey(const ValueKey('resource-save')));
    await tester.pumpAndSettle();
    expect(h.lastBody('POST', '/api/groupware/resources'), {
      'teamId': 'T1',
      'kind': 'vehicle',
      'name': '법인차',
      'location': '',
      'capacity': 5,
      'description': '',
    });
    await tester.tap(find.byKey(const ValueKey('resource-enabled-R1')));
    await tester.pumpAndSettle();
    expect(h.lastBody('PATCH', '/api/groupware/resources/R1'), {
      'teamId': 'T1',
      'enabled': false,
    });
    await tester.tap(find.byKey(const ValueKey('resource-delete-R1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('resource-delete-confirm')));
    await tester.pumpAndSettle();
    expect(h.called('DELETE', '/api/groupware/resources/R1'), hasLength(1));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('휴가 달력 — 칸에 이름(결재 중은 테두리만)·공휴일, 날을 누르면 그날, 다음 달', (tester) async {
    final h = _Harness();
    h.routes['GET /api/groupware/leave/month'] = (r) {
      final month = r.url.queryParameters['month'];
      if (month != '2026-10') return _json({'month': month});
      return _json({
        'month': '2026-10',
        'holidays': [
          {'date': '2026-10-09', 'name': '한글날'},
        ],
        'leaves': [
          {
            'documentId': 'D1',
            'userId': 'U1',
            'name': '김가',
            'label': '연차',
            'startDate': '2026-10-19',
            'endDate': '2026-10-20',
            'status': 'approved',
          },
          {
            'documentId': 'D3',
            'userId': 'U-me',
            'name': '나',
            'label': '오전 반차',
            'startDate': '2026-10-20',
            'endDate': '2026-10-20',
            'status': 'pending',
            'mine': true,
          },
          for (final (i, n) in ['박다', '최라'].indexed)
            {
              'documentId': 'D${10 + i}',
              'userId': 'U$i',
              'name': n,
              'label': '병가',
              'startDate': '2026-10-20',
              'endDate': '2026-10-20',
              'status': 'approved',
            },
        ],
        'trips': [
          {
            'documentId': 'D2',
            'userId': 'U2',
            'name': '이나',
            'destination': '부산',
            'startDate': '2026-10-17',
            'endDate': '2026-10-17',
          },
        ],
      });
    };
    await _pump(
      tester,
      SingleChildScrollView(
        child: LeaveMonthCalendar(
          api: h.api,
          ctx: _ctx(),
          changes: GroupwareChanges(),
        ),
      ),
    );
    expect(find.text('2026년 10월'), findsOneWidget);
    expect(find.text('한글날'), findsOneWidget);
    final cell20 = find.byKey(const ValueKey('leave-cal-day-2026-10-20'));
    expect(
      find.descendant(of: cell20, matching: find.text('+2')),
      findsOneWidget,
      reason: '네 명 중 두 명만',
    );
    // 오늘(10/17)이 골라져 있다 — 출장.
    expect(find.text('이나 · 출장 (부산)'), findsOneWidget);
    await tester.tap(cell20);
    await tester.pumpAndSettle();
    expect(find.text('김가 · 연차'), findsOneWidget);
    expect(find.text('나 · 오전 반차 (결재 중)'), findsOneWidget);
    expect(find.text('10/19~10/20'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('leave-cal-next')));
    await tester.pumpAndSettle();
    expect(find.text('2026년 11월'), findsOneWidget);
    expect(
      h
          .called('GET', '/api/groupware/leave/month')
          .last
          .url
          .queryParameters['month'],
      '2026-11',
    );
    expect(find.text('쉬거나 출장 간 사람이 없습니다.'), findsOneWidget);
  });

  group('캘린더 일정 편집 창의 회의실·자원', () {
    Future<(FakeCalendarApi, CalendarController)> open(
      WidgetTester tester,
      _Harness h, {
      EventOccurrence? editing,
    }) async {
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fake = FakeCalendarApi(events: [?editing]);
      final controller = CalendarController(
        apiProvider: () => fake,
        userId: () => 'U-me',
      );
      await controller.setTeam('t1');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showEventEditor(
                  context,
                  h.session,
                  controller,
                  editing: editing,
                  initialStart: DateTime(_day.year, _day.month, _day.day, 10),
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

    testWidgets('빈 자원을 골라 만들면 resourceIds — 잡힌 자원은 못 고름, 장소를 채움, 반복이면 막힘', (
      tester,
    ) async {
      final h = _Harness();
      h.routes['GET /api/groupware/resources'] = (r) => _json([
        _room(
          'R1',
          '대회의실',
          busy: r.url.queryParameters.containsKey('from')
              ? _booking('B1', 'R1', start: _at(10), end: _at(11))
              : null,
        ),
        _room('R2', '소회의실'),
      ]);
      final (fake, _) = await open(tester, h);
      await tester.enterText(
        find.byKey(const ValueKey('event-title')),
        '주간 회의',
      );
      // 편집 창 아래 저장 줄에 가릴 수 있어 단추를 직접 누른다.
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('event-resource-add')),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      final query = h
          .called('GET', '/api/groupware/resources')
          .last
          .url
          .queryParameters;
      expect(int.parse(query['from']!), _at(10));
      expect(int.parse(query['to']!), _at(11));
      expect(find.textContaining('예약됨 10:00~11:00 홍길동'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('event-resource-R1')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('event-resource-R1')),
        findsOneWidget,
        reason: '잡힌 자원은 눌러도 안 닫힘',
      );
      await tester.tap(find.byKey(const ValueKey('event-resource-R2')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('event-resource-chip-R2')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('event-location')))
            .controller!
            .text,
        '소회의실',
      );
      await tester.tap(find.byKey(const ValueKey('event-save')));
      await tester.pumpAndSettle();
      expect(fake.lastCreateInput!.resourceIds, ['R2']);
      expect(fake.lastCreateInput!.location, '소회의실');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('고칠 때 — 자원을 안 건드리면 resourceIds를 보내지 않음', (tester) async {
      final h = _Harness();
      h.routes['GET /api/groupware/resources'] = (_) =>
          _json([_room('R1', '대회의실')]);
      final editing = EventOccurrence(
        key: 'E1:${_at(10)}',
        eventId: 'E1',
        calendarId: 'cal-me',
        title: '고객 미팅',
        location: '대회의실',
        start: _at(10),
        end: _at(11),
        canEdit: true,
        canDelete: true,
        resource: const EventResource(
          bookingId: 'B1',
          resourceId: 'R1',
          name: '대회의실',
        ),
      );
      final (fake, _) = await open(tester, h, editing: editing);
      expect(
        find.byKey(const ValueKey('event-resource-chip-R1')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('event-title')),
        '고객 미팅 2',
      );
      await tester.tap(find.byKey(const ValueKey('event-save')));
      await tester.pumpAndSettle();
      expect(fake.lastEventFields, isNot(contains('resourceIds')));
      expect(fake.lastEventFields!['title'], '고객 미팅 2');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('고칠 때 — 칩의 X로 빼면 resourceIds 빈 목록', (tester) async {
      final h = _Harness();
      h.routes['GET /api/groupware/resources'] = (_) =>
          _json([_room('R1', '대회의실')]);
      final editing = EventOccurrence(
        key: 'E1:${_at(10)}',
        eventId: 'E1',
        calendarId: 'cal-me',
        title: '고객 미팅',
        location: '대회의실',
        start: _at(10),
        end: _at(11),
        canEdit: true,
        canDelete: true,
        resource: const EventResource(
          bookingId: 'B1',
          resourceId: 'R1',
          name: '대회의실',
        ),
      );
      final (fake2, _) = await open(tester, h, editing: editing);
      await _reveal(
        tester,
        find.byKey(const ValueKey('event-resource-chip-R1')),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('event-resource-chip-R1')),
          matching: find.byIcon(Icons.clear),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('event-resource-add')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('event-save')));
      await tester.pumpAndSettle();
      expect(fake2.lastEventFields!.containsKey('resourceIds'), isTrue);
      expect(fake2.lastEventFields!['resourceIds'], isEmpty);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('자원이 없으면(그룹웨어 없는 서버 포함) 칸이 없다', (tester) async {
      final h = _Harness();
      await open(tester, h);
      expect(find.byKey(const ValueKey('event-resource-add')), findsNothing);
      expect(find.text('회의실·자원'), findsNothing);
    });

    testWidgets('상세 — 자원 줄, 회의실 예약(내장)은 그룹웨어에서 바꾸라는 안내', (tester) async {
      final h = _Harness();
      final fake = FakeCalendarApi();
      final controller = CalendarController(
        apiProvider: () => fake,
        userId: () => 'U-me',
      );
      await controller.setTeam('t1');
      Future<void> show(EventOccurrence e) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showEventDetail(
                    context,
                    session: h.session,
                    controller: controller,
                    event: e,
                  ),
                  child: const Text('보기'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('보기'));
        await tester.pumpAndSettle();
      }

      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await show(
        EventOccurrence(
          key: 'booking:B1',
          calendarId: kBookingsCalendarId,
          source: 'booking',
          title: '주간 회의',
          location: '대회의실',
          start: _at(10),
          end: _at(11),
          resource: const EventResource(
            bookingId: 'B1',
            resourceId: 'R1',
            name: '대회의실',
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('event-detail-resource')),
        findsOneWidget,
      );
      expect(find.text('대회의실'), findsOneWidget, reason: '장소가 자원 이름과 같으면 한 번만');
      expect(
        find.byKey(const ValueKey('event-detail-booking')),
        findsOneWidget,
      );
      expect(find.text('회의실 예약'), findsOneWidget);
      expect(find.byKey(const ValueKey('event-edit')), findsNothing);
    });
  });
}
