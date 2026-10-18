// 회의실·자원 예약 후속(앱) — 예약 창의 반복(매주·2주마다·겹치는 날 빼고)·회의실 추천·예약 규칙·못 잡는 자원, 시간표의 승인 대기·반복
// 표시와 반복 취소(이후 모두), 승인 기다리는 예약(승인·거절·반복 모두), 관리 탭의 예약 규칙 편집·태블릿 화면·사용 통계·예약 알림, 소켓
// resource:reminder 토스트, 좁은 화면(360px). 서버는 가짜 HTTP(서버 groupwareResources.js·resourcePolicy.js 모양).
import 'dart:convert';

import 'package:client/models/groupware.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/groupware/groupware_screen.dart'
    show GroupwareChanges;
import 'package:client/screens/groupware/resource_tab.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/groupware_api.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
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

GroupwareContext _ctx({bool manager = false}) => GroupwareContext.fromJson({
  'scope': 'team',
  'teamId': 'T1',
  'isManager': manager,
  'today': '2026-10-17',
  'leaveTypes': const [],
  'expenseCategories': const [],
  'limits': {'approversMax': 5, 'ccMax': 10, 'attachmentsMax': 5},
});

class _RecordingNotifications extends NotificationService {
  final shown = <({String title, String body, String? teamId})>[];

  @override
  Future<void> cancelForRoom(String roomId) async {}

  @override
  Future<void> showApprovalNotification({
    required String title,
    required String body,
    required String documentId,
    String? teamId,
  }) async => shown.add((title: title, body: body, teamId: teamId));
}

class _Harness {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{};
  late final Session session;
  _Harness() {
    session = Session(
      notifications: _RecordingNotifications(),
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
  }

  GroupwareApi get api => GroupwareApi(session.api!, teamId: 'T1');
  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
  Map<String, dynamic> lastBody(String method, String path) =>
      jsonDecode(called(method, path).last.body) as Map<String, dynamic>;
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

final _day = DateTime.now();
int _at(int h, [int m = 0, int addDays = 0]) => DateTime(
  _day.year,
  _day.month,
  _day.day + addDays,
  h,
  m,
).millisecondsSinceEpoch;

Map<String, dynamic> _room(
  String id,
  String name, {
  String kind = 'room',
  int capacity = 12,
  Map<String, dynamic> extra = const {},
}) => {
  'id': id,
  'kind': kind,
  'name': name,
  'location': '3층',
  'capacity': capacity,
  'enabled': true,
  'canBook': true,
  'needsApproval': false,
  ...extra,
};

Map<String, dynamic> _booking(
  String id,
  String resourceId, {
  required int start,
  required int end,
  String title = '주간 회의',
  bool mine = false,
  String status = 'confirmed',
  String? seriesId,
  String userName = '홍길동',
}) => {
  'id': id,
  'resourceId': resourceId,
  'resourceName': resourceId == 'R1' ? '대회의실' : '소회의실',
  'resourceKind': 'room',
  'title': title,
  'userId': mine ? 'U-me' : 'U-x',
  'userName': userName,
  'start': start,
  'end': end,
  'eventId': null,
  'mine': mine,
  'canCancel': mine,
  'status': status,
  'seriesId': seriesId,
};

ResourceTab _tab(_Harness h) => ResourceTab(
  api: h.api,
  ctx: _ctx(),
  changes: GroupwareChanges(),
  session: h.session,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('예약 탭', () {
    void routes(_Harness h, {List<Map<String, dynamic>>? bookings}) {
      h.routes['GET /api/groupware/resources'] = (_) => _json([
        _room('R1', '대회의실'),
        _room(
          'R2',
          '소회의실',
          capacity: 10,
          extra: {
            'requiresApproval': true,
            'needsApproval': true,
            'availableDays': [1, 2, 3, 4, 5],
            'availableFrom': 540,
            'availableTo': 1080,
            'maxMinutes': 120,
          },
        ),
        _room(
          'R3',
          '임원실',
          extra: {
            'canBook': false,
            'allowedUserIds': ['00000000-0000-0000-0000-000000000001'],
          },
        ),
      ]);
      h.routes['GET /api/groupware/bookings'] = (_) => _json(bookings ?? []);
      h.routes['GET /api/groupware/bookings/mine'] = (_) => _json([
        for (final b in bookings ?? const <Map<String, dynamic>>[])
          if (b['mine'] == true) b,
      ]);
      h.routes['GET /api/groupware/bookings/pending'] = (_) => _json([]);
    }

    testWidgets('반복 예약 — 2주마다·회차·겹치는 날 빼고를 보내고, 잡은 회차·뺀 날·승인 대기를 알린다', (
      tester,
    ) async {
      final h = _Harness();
      routes(h);
      h.routes['POST /api/groupware/bookings'] = (r) {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        return _json({
          ..._booking(
            'B9',
            'R1',
            start: body['start'] as int,
            end: body['end'] as int,
            mine: true,
            status: 'pending',
            seriesId: 'S9',
          ),
          'created': 5,
          'skipped': [
            {'start': _at(10, 0, 14), 'end': _at(11, 0, 14), 'conflict': '홍길동'},
          ],
        }, status: 201);
      };
      await _pump(tester, _tab(h));
      // 승인 기다리는 예약이 없으면 칸도 없다.
      expect(find.byKey(const ValueKey('booking-pending-list')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('resource-book')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('booking-repeat-count')),
        findsNothing,
        reason: '반복 안 함이면 회차 칸이 없다',
      );
      await tester.tap(find.byKey(const ValueKey('booking-repeat')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2주마다').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('booking-repeat-count')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('6회').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('booking-skip-conflicts')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('booking-save')));
      await tester.pumpAndSettle();
      final body = h.lastBody('POST', '/api/groupware/bookings');
      expect(body['resourceId'], 'R1');
      expect(body['repeatWeeks'], 6);
      expect(body['everyWeeks'], 2);
      expect(body['skipConflicts'], true);
      final skippedDay = DateTime.fromMillisecondsSinceEpoch(_at(10, 0, 14));
      expect(find.textContaining('대회의실을(를) 5회 예약했습니다.'), findsOneWidget);
      expect(
        find.textContaining('겹쳐서 뺀 날: ${skippedDay.month}/${skippedDay.day}'),
        findsOneWidget,
      );
      expect(find.textContaining('승인을 기다립니다 — 승인되면 알려 드립니다.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('반복하지 않으면 예전 모양 그대로(repeatWeeks 없음)', (tester) async {
      final h = _Harness();
      routes(h);
      h.routes['POST /api/groupware/bookings'] = (r) => _json(
        _booking('B8', 'R1', start: _at(10), end: _at(11), mine: true),
        status: 201,
      );
      await _pump(tester, _tab(h));
      await tester.tap(find.byKey(const ValueKey('resource-book')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('booking-save')));
      await tester.pumpAndSettle();
      expect(
        h.lastBody('POST', '/api/groupware/bookings'),
        isNot(contains('repeatWeeks')),
      );
      expect(find.textContaining('대회의실을(를) 예약했습니다.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('회의실 추천 — 참석 인원으로 받아 누르면 그 자원, 규칙·승인 필요 안내', (tester) async {
      final h = _Harness();
      routes(h);
      h.routes['GET /api/groupware/resources/suggest'] = (_) => _json([
        {
          ..._room('R2', '소회의실', capacity: 10),
          'spare': 2,
          'needsApproval': true,
        },
        {..._room('R1', '대회의실'), 'spare': 4},
      ]);
      h.routes['POST /api/groupware/bookings'] = (r) => _json(
        _booking('B7', 'R2', start: _at(10), end: _at(11), mine: true),
        status: 201,
      );
      await _pump(tester, _tab(h));
      await tester.tap(find.byKey(const ValueKey('resource-book')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('booking-needs-approval')),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const ValueKey('booking-attendees')),
        '8',
      );
      await tester.tap(find.byKey(const ValueKey('booking-suggest')));
      await tester.pumpAndSettle();
      final query = h
          .called('GET', '/api/groupware/resources/suggest')
          .single
          .url
          .queryParameters;
      expect(query['attendees'], '8');
      expect(query['kind'], 'room');
      expect(int.parse(query['end']!), greaterThan(int.parse(query['start']!)));
      expect(
        find.byKey(const ValueKey('booking-suggestion-R2')),
        findsOneWidget,
      );
      expect(find.text('10명 · 2자리 남음 · 승인 필요'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('booking-suggestion-R2')));
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
        find.byKey(const ValueKey('booking-needs-approval')),
        findsOneWidget,
      );
      expect(
        find.text('예약 규칙: 월·화·수·목·금요일 · 09:00~18:00 · 한 번에 2시간까지'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('booking-save')));
      await tester.pumpAndSettle();
      expect(h.lastBody('POST', '/api/groupware/bookings')['resourceId'], 'R2');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('못 잡는 자원 — 규칙 줄에 "정해진 사람만", 시간표를 눌러도 창이 안 뜸', (tester) async {
      final h = _Harness();
      routes(h);
      await _pump(tester, _tab(h));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('resource-rules-R3')))
            .data,
        '정해진 사람만',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('resource-rules-R2')))
            .data,
        '승인 필요 · 월·화·수·목·금요일 · 09:00~18:00 · 한 번에 2시간까지',
      );
      final bar = find.descendant(
        of: find.byKey(const ValueKey('resource-R3')),
        matching: find.byType(GestureDetector),
      );
      final rect = tester.getRect(bar.first);
      await tester.tapAt(Offset(rect.left + 4, rect.center.dy));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('booking-save')), findsNothing);
    });

    testWidgets('승인 대기·반복 표시, 반복 예약 취소는 "이 회차와 이후 모두"(series=1)', (
      tester,
    ) async {
      final h = _Harness();
      routes(
        h,
        bookings: [
          _booking(
            'B5',
            'R1',
            start: _at(13),
            end: _at(14),
            title: '팀 회의',
            mine: true,
            status: 'pending',
            seriesId: 'S1',
          ),
          _booking('B6', 'R1', start: _at(16), end: _at(17)),
        ],
      );
      h.routes['DELETE /api/groupware/bookings/B5'] = (_) =>
          _json({'ok': true});
      await _pump(tester, _tab(h));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('booking-B5')),
          matching: find.textContaining('승인 대기'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('booking-B5')),
          matching: find.byIcon(Icons.repeat),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('booking-B6')),
          matching: find.textContaining('승인 대기'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('my-booking-pending-B5')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('my-booking-series-B5')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('my-booking-B5')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('booking-detail-pending')),
        findsOneWidget,
      );
      expect(find.text('이 회차만 취소'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('booking-cancel-series')));
      await tester.pumpAndSettle();
      final del = h.called('DELETE', '/api/groupware/bookings/B5').single;
      expect(del.url.queryParameters['series'], '1');
      expect(find.text('이 회차와 이후 예약을 취소했습니다.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('승인 기다리는 예약 — 반복 모두 승인, 사유를 넣어 거절', (tester) async {
      final h = _Harness();
      routes(h);
      var pending = [
        _booking(
          'P1',
          'R2',
          start: _at(10, 0, 1),
          end: _at(11, 0, 1),
          title: '주간 보고',
          seriesId: 'S2',
          userName: '김가',
        ),
        _booking(
          'P2',
          'R2',
          start: _at(15, 0, 1),
          end: _at(16, 0, 1),
          title: '면접',
          userName: '이나',
        ),
      ];
      h.routes['GET /api/groupware/bookings/pending'] = (_) => _json(pending);
      h.routes['POST /api/groupware/bookings/P1/approve'] = (_) {
        pending = [pending.last];
        return _json({'ok': true, 'count': 3});
      };
      h.routes['POST /api/groupware/bookings/P2/reject'] = (_) {
        pending = [];
        return _json({'ok': true, 'count': 1});
      };
      await _pump(tester, _tab(h));
      expect(
        find.byKey(const ValueKey('booking-pending-list')),
        findsOneWidget,
      );
      expect(find.text('소회의실 · 주간 보고'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('booking-approve-P1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('booking-approve-series')));
      await tester.pumpAndSettle();
      expect(h.lastBody('POST', '/api/groupware/bookings/P1/approve'), {
        'teamId': 'T1',
        'series': true,
      });
      expect(find.byKey(const ValueKey('booking-pending-P1')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('booking-reject-P2')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('booking-reject-series')),
        findsNothing,
        reason: '반복이 아니면 "반복 모두"가 없다',
      );
      await tester.enterText(
        find.byKey(const ValueKey('booking-reject-reason')),
        '그 시간엔 점검',
      );
      await tester.tap(find.byKey(const ValueKey('booking-reject-confirm')));
      await tester.pumpAndSettle();
      expect(h.lastBody('POST', '/api/groupware/bookings/P2/reject'), {
        'teamId': 'T1',
        'reason': '그 시간엔 점검',
        'series': false,
      });
      expect(find.byKey(const ValueKey('booking-pending-list')), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('좁은 화면(360px) — 시간표·승인 칸·예약 창이 넘치지 않는다', (tester) async {
      final h = _Harness();
      routes(
        h,
        bookings: [
          _booking(
            'B5',
            'R1',
            start: _at(13),
            end: _at(14),
            mine: true,
            status: 'pending',
            seriesId: 'S1',
          ),
        ],
      );
      h.routes['GET /api/groupware/bookings/pending'] = (_) => _json([
        _booking(
          'P1',
          'R2',
          start: _at(10, 0, 1),
          end: _at(11, 0, 1),
          title: '아주 긴 제목의 주간 업무 보고 회의',
          seriesId: 'S2',
        ),
      ]);
      await _pump(tester, _tab(h), size: const Size(360, 780));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('resource-book')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('booking-repeat')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('매주').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('관리 — 회의실·자원', () {
    void routes(_Harness h) {
      h.routes['GET /api/groupware/resources'] = (_) => _json([
        _room('R1', '대회의실'),
        _room('R2', '소회의실', extra: {'requiresApproval': true}),
        _room('R3', '법인차', kind: 'vehicle', extra: {'maxMinutes': 480}),
      ]);
      h.routes['GET /api/groupware/candidates'] = (_) => _json([
        {
          'id': '00000000-0000-0000-0000-0000000000a1',
          'name': '김가',
          'username': 'kim',
        },
        {
          'id': '00000000-0000-0000-0000-0000000000b2',
          'name': '이나',
          'username': 'lee',
        },
      ]);
    }

    Widget section(_Harness h) => SingleChildScrollView(
      child: ResourcesAdminSection(
        api: h.api,
        changes: GroupwareChanges(),
        serverUrl: 'https://test.local/',
      ),
    );

    testWidgets('목록의 표시와 예약 규칙 편집 — 바뀐 규칙만 보낸다', (tester) async {
      final h = _Harness();
      routes(h);
      h.routes['PATCH /api/groupware/resources/R1'] = (_) =>
          _json(_room('R1', '대회의실'));
      await _pump(tester, section(h));
      expect(find.text('회의실 · 3층 · 12명'), findsOneWidget);
      expect(find.text('회의실 · 3층 · 12명 · 승인 필요'), findsOneWidget);
      expect(find.text('차량 · 3층 · 12명 · 규칙'), findsOneWidget);
      await tester.tap(find.text('대회의실'));
      await tester.pumpAndSettle();
      expect(h.called('GET', '/api/groupware/candidates'), hasLength(1));
      expect(
        h
            .called('GET', '/api/groupware/candidates')
            .single
            .url
            .queryParameters['includeSelf'],
        '1',
      );
      expect(find.byKey(const ValueKey('resource-approvers')), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('resource-requires-approval')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('resource-approvers')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey('people-picker-00000000-0000-0000-0000-0000000000a1'),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('people-picker-done')));
      await tester.pumpAndSettle();
      expect(find.text('김가'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('resource-allowed-users')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey('people-picker-00000000-0000-0000-0000-0000000000b2'),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('people-picker-done')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('resource-day-6')));
      await tester.tap(find.byKey(const ValueKey('resource-day-0')));
      await tester.pumpAndSettle();
      // 시간대는 둘 다 넣어야 한다.
      await tester.enterText(
        find.byKey(const ValueKey('resource-available-from')),
        '09:00',
      );
      await tester.tap(find.byKey(const ValueKey('resource-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('resource-error')), findsOneWidget);
      expect(h.called('PATCH', '/api/groupware/resources/R1'), isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('resource-available-to')),
        '18:00',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('resource-max-minutes')),
      );
      await tester.tap(find.byKey(const ValueKey('resource-max-minutes')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2시간').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('resource-quick-book')),
      );
      await tester.tap(find.byKey(const ValueKey('resource-quick-book')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('resource-save')));
      await tester.pumpAndSettle();
      expect(h.lastBody('PATCH', '/api/groupware/resources/R1'), {
        'teamId': 'T1',
        'kind': 'room',
        'name': '대회의실',
        'location': '3층',
        'capacity': 12,
        'description': '',
        'requiresApproval': true,
        'approverIds': ['00000000-0000-0000-0000-0000000000a1'],
        'allowedUserIds': ['00000000-0000-0000-0000-0000000000b2'],
        'availableDays': [1, 2, 3, 4, 5],
        'availableFrom': 540,
        'availableTo': 1080,
        'maxMinutes': 120,
        'displayQuickBook': true,
      });
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('규칙을 풀면 null로 — 요일 모두·시간대 비움·제한 없음', (tester) async {
      final h = _Harness();
      h.routes['GET /api/groupware/resources'] = (_) => _json([
        _room(
          'R1',
          '대회의실',
          extra: {
            'availableDays': [1, 2, 3, 4, 5],
            'availableFrom': 540,
            'availableTo': 1080,
            'maxMinutes': 60,
          },
        ),
      ]);
      h.routes['PATCH /api/groupware/resources/R1'] = (_) =>
          _json(_room('R1', '대회의실'));
      await _pump(tester, section(h));
      await tester.tap(find.text('대회의실'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('resource-day-6')));
      await tester.tap(find.byKey(const ValueKey('resource-day-0')));
      await tester.enterText(
        find.byKey(const ValueKey('resource-available-from')),
        '',
      );
      await tester.enterText(
        find.byKey(const ValueKey('resource-available-to')),
        '',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('resource-max-minutes')),
      );
      await tester.tap(find.byKey(const ValueKey('resource-max-minutes')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('제한 없음').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('resource-save')));
      await tester.pumpAndSettle();
      final body = h.lastBody('PATCH', '/api/groupware/resources/R1');
      expect(body['availableDays'], isNull);
      expect(body.containsKey('availableDays'), isTrue);
      expect(body['availableFrom'], isNull);
      expect(body['availableTo'], isNull);
      expect(body.containsKey('availableFrom'), isTrue);
      expect(body['maxMinutes'], isNull);
      expect(body.containsKey('maxMinutes'), isTrue);
      expect(body.containsKey('requiresApproval'), isFalse);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('태블릿 화면 — 켜면 주소·QR, 주소 바꾸기(확인), 끄기', (tester) async {
      final h = _Harness();
      routes(h);
      var token = 0;
      h.routes['POST /api/groupware/resources/R1/display'] = (_) {
        token += 1;
        return _json(
          _room(
            'R1',
            '대회의실',
            extra: {'displayPath': '/room-display/tok$token'},
          ),
        );
      };
      h.routes['DELETE /api/groupware/resources/R1/display'] = (_) =>
          _json(_room('R1', '대회의실', extra: {'displayPath': null}));
      await _pump(tester, section(h));
      await tester.tap(find.byKey(const ValueKey('resource-display-R1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('resource-display-url')), findsNothing);
      expect(find.textContaining('주소를 아는 사람은 누구나 볼 수 있으니'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('resource-display-switch')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('resource-display-url')),
            )
            .data,
        'https://test.local/room-display/tok1',
      );
      expect(find.byKey(const ValueKey('resource-display-qr')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('resource-display-rotate')));
      await tester.pumpAndSettle();
      expect(find.textContaining('예전 주소는 더 이상 열리지 않습니다'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('resource-display-rotate-confirm')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('resource-display-url')),
            )
            .data,
        'https://test.local/room-display/tok2',
      );
      await tester.tap(find.byKey(const ValueKey('resource-display-switch')));
      await tester.pumpAndSettle();
      expect(
        h
            .called('DELETE', '/api/groupware/resources/R1/display')
            .single
            .url
            .queryParameters['teamId'],
        'T1',
      );
      expect(find.byKey(const ValueKey('resource-display-url')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('resource-display-close')));
      await tester.pumpAndSettle();
      // 바뀌었으니 목록을 다시 받는다.
      expect(h.called('GET', '/api/groupware/resources'), hasLength(2));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('사용 통계 — 건수·쓴 시간·이용률·쓴 사람, 기간을 바꾸면 다시', (tester) async {
      final h = _Harness();
      routes(h);
      h.routes['GET /api/groupware/resources/stats'] = (_) => _json({
        'resources': [
          {
            'resourceId': 'R1',
            'name': '대회의실',
            'kind': 'room',
            'count': 3,
            'minutes': 270,
            'availableMinutes': 720,
            'utilization': 37.5,
            'userCount': 2,
            'topUsers': [
              {'name': '김가', 'count': 2},
              {'name': '이나', 'count': 1},
            ],
            'byWeekday': [0, 2, 0, 1, 0, 0, 0],
          },
          {
            'resourceId': 'R3',
            'name': '법인차',
            'kind': 'vehicle',
            'count': 0,
            'minutes': 0,
            'availableMinutes': 0,
            'utilization': null,
            'userCount': 0,
            'topUsers': [],
            'byWeekday': [0, 0, 0, 0, 0, 0, 0],
          },
        ],
      });
      await _pump(tester, section(h));
      expect(find.byKey(const ValueKey('resource-stats')), findsOneWidget);
      expect(find.text('이용률 37.5%'), findsOneWidget);
      expect(find.text('3건 · 4시간 30분 · 2명이 씀'), findsOneWidget);
      expect(find.text('많이 쓴 사람: 김가 2건, 이나 1건'), findsOneWidget);
      expect(find.text('이용률 —'), findsOneWidget);
      final first = h
          .called('GET', '/api/groupware/resources/stats')
          .single
          .url
          .queryParameters;
      expect(
        int.parse(first['to']!) - int.parse(first['from']!),
        30 * 86400000,
      );
      await tester.tap(find.byKey(const ValueKey('resource-stats-7')));
      await tester.pumpAndSettle();
      final second = h
          .called('GET', '/api/groupware/resources/stats')
          .last
          .url
          .queryParameters;
      expect(
        int.parse(second['to']!) - int.parse(second['from']!),
        7 * 86400000,
      );
    });

    testWidgets('예약 시작 전 알림 — 고르면 PATCH bookingReminderMinutes', (
      tester,
    ) async {
      final h = _Harness();
      routes(h);
      h.routes['GET /api/groupware/options'] = (_) =>
          _json({'bookingReminderMinutes': 10});
      h.routes['PATCH /api/groupware/options'] = (r) => _json({
        'bookingReminderMinutes':
            (jsonDecode(r.body) as Map)['bookingReminderMinutes'],
      });
      await _pump(tester, section(h));
      expect(
        tester
            .widget<DropdownButton<int>>(
              find.byKey(const ValueKey('booking-reminder-minutes')),
            )
            .value,
        10,
      );
      await tester.tap(find.byKey(const ValueKey('booking-reminder-minutes')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('끔').last);
      await tester.pumpAndSettle();
      expect(h.lastBody('PATCH', '/api/groupware/options'), {
        'teamId': 'T1',
        'bookingReminderMinutes': 0,
      });
      expect(find.text('예약 알림을 껐습니다.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('좁은 화면(360px) — 목록·편집 창이 넘치지 않는다', (tester) async {
      final h = _Harness();
      routes(h);
      h.routes['GET /api/groupware/options'] = (_) =>
          _json({'bookingReminderMinutes': 10});
      h.routes['GET /api/groupware/resources/stats'] = (_) => _json({
        'resources': [
          {
            'resourceId': 'R1',
            'name': '아주 긴 이름의 대회의실 (본관 3층 동쪽 끝)',
            'count': 120,
            'minutes': 9000,
            'utilization': 99.9,
            'userCount': 40,
            'topUsers': [
              {'name': '김가나다라', 'count': 50},
              {'name': '이마바사아', 'count': 40},
              {'name': '박자차카타', 'count': 30},
            ],
            'byWeekday': [1, 30, 25, 20, 24, 20, 0],
          },
        ],
      });
      h.routes['POST /api/groupware/resources/R1/display'] = (_) => _json(
        _room(
          'R1',
          '대회의실',
          extra: {'displayPath': '/room-display/${'x' * 24}'},
        ),
      );
      await _pump(tester, section(h), size: const Size(360, 780));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('대회의실'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('resource-requires-approval')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('resource-display-R1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('resource-display-switch')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('resource-display-url')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('시작 전 알림(소켓 resource:reminder)', () {
    test('토스트와 기기 알림', () async {
      final notifications = _RecordingNotifications();
      final session = Session(
        notifications: notifications,
        settings: AppSettings(),
      );
      final toasts = <String>[];
      final sub = session.toasts.listen(toasts.add);
      session.handleResourceReminder({
        'bookingId': 'B1',
        'resourceName': '대회의실',
        'start': 1,
        'title': '대회의실 예약 10분 전',
        'body': '10/18 10:00 — 주간 회의',
        'teamId': 'T1',
      });
      await Future<void>.delayed(Duration.zero);
      expect(toasts.single, '대회의실 예약 10분 전 — 10/18 10:00 — 주간 회의');
      expect(notifications.shown.single.title, '대회의실 예약 10분 전');
      expect(notifications.shown.single.teamId, 'T1');
      await sub.cancel();
    });

    test('둘째 창(알림 끔)에서는 토스트만', () {
      final notifications = _RecordingNotifications();
      final session = Session(
        notifications: notifications,
        settings: AppSettings(),
        suppressNotifications: true,
      );
      session.handleResourceReminder({'title': '대회의실 예약 5분 전', 'body': ''});
      expect(notifications.shown, isEmpty);
    });
  });
}
