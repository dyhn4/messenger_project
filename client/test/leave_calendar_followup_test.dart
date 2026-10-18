// 휴가 달력 후속(앱) — 부서 거르기(드롭다운 들여쓰기·departmentId 보내기·'none'·숨김·기기에 기억·없어진 부서는 모든 부서로),
// 달력에서 날을 끌어(마우스)·길게 눌러 끌어(터치, 거꾸로도) 그 기간으로 휴가 신청 창 열기, 고른 날의 "이날 휴가 신청", 하루짜리 종류는
// 시작 날만, 360px에서 넘치지 않기. 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/groupware.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/groupware/approval_forms.dart';
import 'package:client/screens/groupware/groupware_screen.dart'
    show GroupwareChanges;
import 'package:client/screens/groupware/leave_calendar.dart';
import 'package:client/screens/groupware/leave_tab.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/groupware_api.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

GroupwareContext _ctx({bool halfFirst = false}) => GroupwareContext.fromJson({
  'scope': 'team',
  'teamId': 'T1',
  'isManager': false,
  'today': '2026-10-17',
  'leaveTypes': [
    if (halfFirst)
      {'key': 'am', 'label': '오전 반차', 'deducts': true, 'half': true},
    {'key': 'annual', 'label': '연차', 'deducts': true, 'half': false},
  ],
  'expenseCategories': ['식대'],
  'limits': {'approversMax': 5, 'ccMax': 10, 'attachmentsMax': 5},
});

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

/// 부서 트리 — 개발본부 › 플랫폼팀, 영업팀(이름이 긴 부서 하나로 좁은 화면 말줄임도 본다).
const _departments = [
  {'id': 'D1', 'name': '개발본부', 'parentId': null, 'depth': 1},
  {'id': 'D2', 'name': '플랫폼팀', 'parentId': 'D1', 'depth': 2},
  {
    'id': 'D3',
    'name': '아주아주 긴 이름의 해외 영업 및 고객 성공 담당 부서',
    'parentId': null,
    'depth': 1,
  },
];

class _Harness {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{};
  late final Session session;

  /// 가짜 서버가 돌려줄 부서 목록(비우면 조직도에 부서가 없는 것).
  List<Map<String, Object?>> departments = _departments;

  _Harness() {
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
    session.accountRole = AccountRole.member;
    final team = Team(id: 'T1', name: '본사', createdAt: DateTime(2026));
    session.teams.add(team);
    session.currentTeam = team;

    // 한 달 휴가 — 서버처럼 알 수 없는 부서는 거르지 않는다(departmentId null).
    routes['GET /api/groupware/leave/month'] = (r) {
      final wanted = r.url.queryParameters['departmentId'];
      final applied =
          wanted == 'none' || departments.any((d) => d['id'] == wanted)
          ? wanted
          : null;
      return _json({
        'month': r.url.queryParameters['month'],
        'holidays': [],
        'leaves': [
          {
            'documentId': 'L1',
            'userId': 'U1',
            'name': '김가',
            'label': '연차',
            'startDate': '2026-10-20',
            'endDate': '2026-10-20',
            'status': 'approved',
          },
        ],
        'trips': [],
        'departments': departments,
        'departmentId': applied,
      });
    };
    routes['GET /api/groupware/leave/balance'] = (_) => _json({
      'hireDate': '2020-05-10',
      'grantedHalfDays': 30,
      'usedHalfDays': 4,
      'pendingHalfDays': 0,
      'remainingHalfDays': 26,
    });
    routes['GET /api/groupware/leave/calendar'] = (_) => _json([
      {
        'documentId': 'L1',
        'userId': 'U1',
        'name': '김가',
        'leaveType': 'annual',
        'startDate': '2026-10-20',
        'endDate': '2026-10-20',
      },
    ]);
    routes['GET /api/groupware/documents'] = (_) => _json([]);
    routes['GET /api/groupware/leave/promotions/mine'] = (_) => _json([]);
    routes['GET /api/groupware/candidates'] = (_) => _json([
      {'id': 'U-lead', 'name': '팀장', 'username': 'lead'},
    ]);
    routes['GET /api/groupware/approval-lines'] = (_) => _json({
      'lines': [],
      'suggested': {
        'approverIds': ['U-lead'],
        'ccIds': [],
        'source': 'org',
      },
    });
    routes['POST /api/groupware/documents'] = (r) => _json({
      'id': 'D-new',
      'kind': 'leave',
      'title': '휴가 신청',
      'payload': jsonDecode(r.body),
      'attachments': [],
      'status': 'pending',
      'authorId': 'U-me',
      'authorName': '나',
      'createdAt': DateTime(2026, 10, 17, 9).millisecondsSinceEpoch,
      'steps': [],
    }, status: 201);
  }

  GroupwareApi get api => GroupwareApi(session.api!, teamId: 'T1');
  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();

  /// 마지막 [path] 요청의 departmentId(없으면 null).
  String? lastDepartment(String path) =>
      called('GET', path).last.url.queryParameters['departmentId'];
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(1100, 2000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

Widget _leaveTab(_Harness h) => LeaveTab(
  api: h.api,
  ctx: _ctx(),
  changes: GroupwareChanges(),
  session: h.session,
);

Finder _day(String key) => find.byKey(ValueKey('leave-cal-day-$key'));

Future<void> _pickDepartment(WidgetTester tester, String itemKey) async {
  await tester.tap(find.byKey(const ValueKey('leave-dept-filter')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(itemKey)));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('부서별로 거르기', () {
    testWidgets(
      '부서를 깊이만큼 들여 보이고, 고르면 달력·30일 목록에 departmentId를 보낸다(부서 없음은 none)',
      (tester) async {
        final h = _Harness();
        await _pump(tester, _leaveTab(h));
        expect(find.byKey(const ValueKey('leave-dept-filter')), findsOneWidget);
        expect(h.lastDepartment('/api/groupware/leave/month'), isNull);
        expect(find.text('모든 부서'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('leave-dept-filter')));
        await tester.pumpAndSettle();
        double indentOf(String key) =>
            (tester.widget<Padding>(find.byKey(ValueKey(key))).padding
                    as EdgeInsets)
                .left;
        expect(indentOf('leave-dept-D1'), 0);
        expect(indentOf('leave-dept-D2'), 14, reason: '플랫폼팀은 개발본부 아래(깊이 2)');
        expect(indentOf('leave-dept-D3'), 0);
        expect(find.byKey(const ValueKey('leave-dept-all')), findsOneWidget);
        expect(find.byKey(const ValueKey('leave-dept-none')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('leave-dept-D2')));
        await tester.pumpAndSettle();
        expect(h.lastDepartment('/api/groupware/leave/month'), 'D2');
        expect(h.lastDepartment('/api/groupware/leave/calendar'), 'D2');
        expect(find.text('플랫폼팀'), findsOneWidget, reason: '닫힌 칸은 들여쓰기 없이 이름');

        // 30일 목록으로 바꿔도 같은 거르기가 보이고 걸린다.
        await tester.tap(find.text('앞으로 30일'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('leave-dept-filter')), findsOneWidget);
        await _pickDepartment(tester, 'leave-dept-none');
        expect(h.lastDepartment('/api/groupware/leave/calendar'), 'none');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(kLeaveDepartmentPref), 'none');

        await tester.tap(find.text('달력'));
        await tester.pumpAndSettle();
        expect(h.lastDepartment('/api/groupware/leave/month'), 'none');
        await _pickDepartment(tester, 'leave-dept-all');
        expect(h.lastDepartment('/api/groupware/leave/month'), isNull);
        expect(h.lastDepartment('/api/groupware/leave/calendar'), isNull);
        expect(prefs.containsKey(kLeaveDepartmentPref), isFalse);
      },
    );

    testWidgets('조직도에 부서가 없으면 드롭다운을 숨긴다', (tester) async {
      final h = _Harness()..departments = const [];
      await _pump(tester, _leaveTab(h));
      expect(find.byKey(const ValueKey('leave-calendar')), findsOneWidget);
      expect(find.byKey(const ValueKey('leave-dept-filter')), findsNothing);
    });

    testWidgets('고른 부서를 기기에 기억해 다음에 그 부서로 연다', (tester) async {
      SharedPreferences.setMockInitialValues({kLeaveDepartmentPref: 'D2'});
      final h = _Harness();
      await _pump(tester, _leaveTab(h));
      final months = h.called('GET', '/api/groupware/leave/month');
      expect(months, hasLength(1), reason: '기억한 부서를 읽은 뒤 한 번만 받는다');
      expect(months.single.url.queryParameters['departmentId'], 'D2');
      expect(h.lastDepartment('/api/groupware/leave/calendar'), 'D2');
      expect(find.text('플랫폼팀'), findsOneWidget);
    });

    testWidgets('기억한 부서가 없어졌으면 모든 부서로 되돌리고 기억도 지운다', (tester) async {
      SharedPreferences.setMockInitialValues({kLeaveDepartmentPref: 'GONE'});
      final h = _Harness();
      await _pump(tester, _leaveTab(h));
      expect(h.lastDepartment('/api/groupware/leave/month'), isNull);
      expect(h.lastDepartment('/api/groupware/leave/calendar'), isNull);
      expect(find.text('모든 부서'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(kLeaveDepartmentPref), isFalse);
    });

    testWidgets('부서가 없어진 조직도에서 기억한 "부서 없음"도 모든 부서로', (tester) async {
      SharedPreferences.setMockInitialValues({kLeaveDepartmentPref: 'none'});
      final h = _Harness()..departments = const [];
      await _pump(tester, _leaveTab(h));
      expect(h.lastDepartment('/api/groupware/leave/month'), isNull);
      expect(find.byKey(const ValueKey('leave-dept-filter')), findsNothing);
    });
  });

  group('달력에서 날을 끌어 휴가 신청', () {
    Future<_Harness> open(WidgetTester tester, {bool halfFirst = false}) async {
      final h = _Harness();
      await _pump(
        tester,
        SingleChildScrollView(
          child: LeaveMonthCalendar(
            api: h.api,
            ctx: _ctx(halfFirst: halfFirst),
            changes: GroupwareChanges(),
          ),
        ),
      );
      return h;
    }

    testWidgets('마우스로 끌면 고른 칸을 칠하고, 놓으면 그 기간으로 신청 창 — 올리면 달력을 다시 받는다', (
      tester,
    ) async {
      final h = await open(tester);
      expect(find.text('날을 길게 누르거나 끌어서 고르면 그 기간으로 휴가를 신청합니다.'), findsOneWidget);
      final gesture = await tester.startGesture(
        tester.getCenter(_day('2026-10-21')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(tester.getCenter(_day('2026-10-22')));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(_day('2026-10-26')));
      await tester.pump();
      expect(find.byKey(const ValueKey('leave-cal-selection')), findsOneWidget);
      expect(find.textContaining('10/21~10/26'), findsOneWidget);
      for (final d in ['21', '22', '23', '24', '25', '26']) {
        expect(
          find.byKey(ValueKey('leave-cal-selected-2026-10-$d')),
          findsOneWidget,
        );
      }
      expect(
        find.byKey(const ValueKey('leave-cal-selected-2026-10-20')),
        findsNothing,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('시작 10/21'), findsOneWidget);
      expect(find.text('끝 10/26'), findsOneWidget);

      final before = h.called('GET', '/api/groupware/leave/month').length;
      await tester.tap(find.byKey(const ValueKey('approval-request-submit')));
      await tester.pumpAndSettle();
      final body =
          jsonDecode(h.called('POST', '/api/groupware/documents').single.body)
              as Map<String, dynamic>;
      expect(body['kind'], 'leave');
      expect(body['startDate'], '2026-10-21');
      expect(body['endDate'], '2026-10-26');
      expect(find.textContaining('결재를 올렸습니다.'), findsOneWidget);
      expect(
        h.called('GET', '/api/groupware/leave/month').length,
        greaterThan(before),
        reason: '올린 뒤 달력을 다시 받는다',
      );
      expect(find.byKey(const ValueKey('leave-cal-selection')), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('길게 눌러 거꾸로 끌어도 시작 ≤ 끝으로 채운다(보이는 격자의 지난달 날까지)', (tester) async {
      await open(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(_day('2026-10-23')),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('leave-cal-selection')), findsOneWidget);
      await gesture.moveTo(tester.getCenter(_day('2026-10-19')));
      await tester.pump();
      expect(find.textContaining('10/19~10/23'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('시작 10/19'), findsOneWidget);
      expect(find.text('끝 10/23'), findsOneWidget);
      await tester.tap(find.text('취소').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('leave-cal-selection')), findsNothing);

      // 그달 첫 주에서 격자에 보이는 지난달 날(9/29)까지 — 거꾸로.
      final g2 = await tester.startGesture(
        tester.getCenter(_day('2026-10-02')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await g2.moveTo(tester.getCenter(_day('2026-09-29')));
      await tester.pump();
      await g2.up();
      await tester.pumpAndSettle();
      expect(find.text('시작 9/29'), findsOneWidget);
      expect(find.text('끝 10/2'), findsOneWidget);
    });

    testWidgets('그냥 누르면 그날 상세(신청 창은 안 연다) — "이날 휴가 신청"은 그날 하루로', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(_day('2026-10-20'));
      await tester.pumpAndSettle();
      expect(find.text('김가 · 연차'), findsOneWidget);
      expect(find.text('휴가 신청'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('leave-cal-request-day')));
      await tester.pumpAndSettle();
      expect(find.text('휴가 신청'), findsOneWidget);
      expect(find.text('시작 10/20'), findsOneWidget);
      expect(find.text('끝 10/20'), findsOneWidget);
    });

    testWidgets('처음 종류가 하루짜리(반차)면 시작 날 하나만 쓴다', (tester) async {
      await open(tester, halfFirst: true);
      final gesture = await tester.startGesture(
        tester.getCenter(_day('2026-10-21')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(tester.getCenter(_day('2026-10-23')));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('날짜 10/21'), findsOneWidget);
      expect(find.textContaining('끝'), findsNothing);
    });
  });

  testWidgets('기존 호출(미리 채움 없음)은 그대로 빈 날짜로 연다', (tester) async {
    final h = _Harness();
    await _pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              showLeaveRequestDialog(context, api: h.api, ctx: _ctx()),
          child: const Text('열기'),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(find.text('시작'), findsOneWidget);
    expect(find.text('끝'), findsOneWidget);
  });

  testWidgets('360px — 부서 거르기·달력·안내·상세가 넘치지 않는다', (tester) async {
    SharedPreferences.setMockInitialValues({kLeaveDepartmentPref: 'D3'});
    final h = _Harness();
    await _pump(tester, _leaveTab(h), size: const Size(360, 2400));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('leave-dept-filter')), findsOneWidget);
    await tester.tap(_day('2026-10-20'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('leave-cal-request-day')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('leave-dept-filter')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
