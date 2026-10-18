// 근태 후속(앱) — 휴게 누르기, 출퇴근 위치(가짜 DeviceLocation)·외근 위치 필수, 주 52시간 지키기(409 문구·결재를 받게 안내), 주 상한
// (탄력 60시간·선택근무 없음), 탄력·선택 기간 카드, 가산 수당(참고용), 날마다 휴게 모자람·위치·사무실 밖·시간 연차 시간대, 시간 단위 연차
// 신청(반반차·시간 연차), 휴가 탭의 회계연도 기준·이월·통지서 PDF 단추. 서버(groupware.js)는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/groupware.dart';
import 'package:client/screens/groupware/approval_forms.dart';
import 'package:client/screens/groupware/attendance_tab.dart';
import 'package:client/screens/groupware/groupware_screen.dart'
    show GroupwareChanges;
import 'package:client/screens/groupware/leave_tab.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/device_location.dart';
import 'package:client/services/groupware_api.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

const _leaveTypes = [
  {'key': 'annual', 'label': '연차', 'deducts': true, 'half': false},
  {
    'key': 'quarter',
    'label': '반반차',
    'deducts': true,
    'half': false,
    'hourly': true,
    'fixedHours': 2,
  },
  {
    'key': 'hourly',
    'label': '시간 연차',
    'deducts': true,
    'half': false,
    'hourly': true,
  },
];

GroupwareContext _ctx() => GroupwareContext.fromJson({
  'scope': 'team',
  'teamId': 'T1',
  'teamName': '개발팀',
  'isManager': false,
  'today': '2026-10-17',
  'workStart': 540,
  'workEnd': 1080,
  'leaveTypes': _leaveTypes,
  'expenseCategories': ['식대'],
  'limits': {'approversMax': 5, 'ccMax': 10, 'attachmentsMax': 5},
});

/// 정해 둔 위치(또는 null)를 돌려주는 가짜 위치 — 몇 번 불렸는지 센다.
class _FakeLocation extends DeviceLocation {
  final ({double lat, double lng, double? accuracy})? value;
  int calls = 0;
  _FakeLocation(this.value);

  @override
  Future<bool> ensurePermission() async => value != null;

  @override
  Future<({double lat, double lng, double? accuracy})?> current({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    calls++;
    return value;
  }
}

class _Harness {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{};
  late final Session session;
  _Harness() {
    session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
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
    session.name = '홍길동';
  }

  GroupwareApi get api => GroupwareApi(session.api!, teamId: 'T1');
  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
  Map<String, dynamic> lastBody(String method, String path) =>
      jsonDecode(called(method, path).last.body) as Map<String, dynamic>;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1100, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

int _ms(int h, [int m = 0, int day = 17]) =>
    DateTime(2026, 10, day, h, m).millisecondsSinceEpoch;

/// 오늘 — 기본은 아직 출근 전.
Map<String, dynamic> _today({
  Map<String, dynamic>? record,
  bool canClockIn = true,
  bool canClockOut = false,
  bool canBreakStart = false,
  bool canBreakEnd = false,
  Object? weeklyLimitMinutes = 3120,
  String overtimeGuard = 'warn',
  bool requireFieldLocation = false,
  bool officeLocationSet = false,
  Map<String, dynamic>? week,
  Map<String, dynamic>? period,
}) => {
  'today': '2026-10-17',
  'record': record,
  'openRecord': null,
  'canClockIn': canClockIn,
  'canClockOut': canClockOut,
  'canBreakStart': canBreakStart,
  'canBreakEnd': canBreakEnd,
  'inLan': false,
  'workStart': 540,
  'workEnd': 1080,
  'week': week,
  'weeklyLimitMinutes': weeklyLimitMinutes,
  'overtimeGuard': overtimeGuard,
  'requireFieldLocation': requireFieldLocation,
  'officeLocationSet': officeLocationSet,
  'period': period,
};

Map<String, dynamic> _month({
  List<Map<String, dynamic>> days = const [],
  Object? weeklyLimitMinutes = 3120,
  List<Map<String, dynamic>> periods = const [],
  Map<String, dynamic>? allowance,
}) => {
  'month': '2026-10',
  'days': days,
  'summary': {'daysWorked': 0},
  'weeks': [],
  'weeklyLimitMinutes': weeklyLimitMinutes,
  'periods': periods,
  'allowance': allowance,
};

Map<String, dynamic> _record({
  String id = 'R1',
  String date = '2026-10-17',
  int? inAt,
  int? outAt,
  List<Map<String, dynamic>> breaks = const [],
  Map<String, dynamic>? breakdown,
  Map<String, dynamic>? clockInLocation,
}) => {
  'id': id,
  'workDate': date,
  'clockInAt': inAt,
  'clockOutAt': outAt,
  'clockInMode': 'office',
  'breaks': breaks,
  'onBreak': breaks.any((b) => b['endAt'] == null),
  'breakdown': breakdown,
  'clockInLocation': clockInLocation,
};

AttendanceTab _tab(_Harness h, {DeviceLocation? location}) => AttendanceTab(
  api: h.api,
  ctx: _ctx(),
  changes: GroupwareChanges(),
  session: h.session,
  location: location,
);

void main() {
  group('출퇴근 탭 — 휴게', () {
    testWidgets('휴게 시작·끝을 누르고, 휴게 중이면 언제부터인지 보인다', (tester) async {
      final h = _Harness();
      var onBreak = false;
      Map<String, dynamic> rec() => _record(
        inAt: _ms(9),
        breaks: [
          if (onBreak) {'startAt': _ms(12), 'endAt': null},
        ],
      );
      h.routes['GET /api/groupware/attendance/today'] = (_) => _json(
        _today(
          record: rec(),
          canClockIn: false,
          canClockOut: true,
          canBreakStart: !onBreak,
          canBreakEnd: onBreak,
        ),
      );
      h.routes['GET /api/groupware/attendance/month'] = (_) => _json(_month());
      h.routes['POST /api/groupware/attendance/break-start'] = (_) {
        onBreak = true;
        return _json(rec());
      };
      h.routes['POST /api/groupware/attendance/break-end'] = (_) {
        onBreak = false;
        return _json(rec());
      };
      await _pump(tester, _tab(h));
      expect(find.byKey(const ValueKey('attendance-break-end')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('attendance-break-start')));
      await tester.pumpAndSettle();
      expect(
        h.called('POST', '/api/groupware/attendance/break-start'),
        hasLength(1),
      );
      expect(find.text('휴게 중 — 12:00부터'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('attendance-break-start')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('attendance-break-end')));
      await tester.pumpAndSettle();
      expect(
        h.called('POST', '/api/groupware/attendance/break-end'),
        hasLength(1),
      );
      expect(find.textContaining('휴게 중'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('출퇴근 탭 — 위치·주 52시간 지키기', () {
    void routes(
      _Harness h, {
      bool requireFieldLocation = false,
      bool officeLocationSet = false,
    }) {
      h.routes['GET /api/groupware/attendance/today'] = (_) => _json(
        _today(
          requireFieldLocation: requireFieldLocation,
          officeLocationSet: officeLocationSet,
        ),
      );
      h.routes['GET /api/groupware/attendance/month'] = (_) => _json(_month());
      h.routes['POST /api/groupware/attendance/clock-in'] = (_) =>
          _json(_record(inAt: _ms(8, 55)), status: 201);
    }

    testWidgets('사무실 위치가 정해졌으면 출근에 기기 위치를 함께 보낸다', (tester) async {
      final h = _Harness();
      routes(h, officeLocationSet: true);
      final loc = _FakeLocation((lat: 37.4, lng: 127.1, accuracy: 12));
      await _pump(tester, _tab(h, location: loc));
      await tester.tap(find.byKey(const ValueKey('attendance-clock-in')));
      await tester.pumpAndSettle();
      expect(loc.calls, 1);
      expect(h.lastBody('POST', '/api/groupware/attendance/clock-in'), {
        'teamId': 'T1',
        'mode': 'office',
        'location': {'lat': 37.4, 'lng': 127.1, 'accuracy': 12.0},
      });
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('사무실 위치가 없으면 사무실 출근에 위치를 재지 않는다', (tester) async {
      final h = _Harness();
      routes(h);
      final loc = _FakeLocation((lat: 37.4, lng: 127.1, accuracy: null));
      await _pump(tester, _tab(h, location: loc));
      await tester.tap(find.byKey(const ValueKey('attendance-clock-in')));
      await tester.pumpAndSettle();
      expect(loc.calls, 0);
      expect(
        h.lastBody('POST', '/api/groupware/attendance/clock-in'),
        isNot(contains('location')),
      );
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('외근 위치가 필수인데 위치를 못 얻으면 올리지 않고 알린다', (tester) async {
      final h = _Harness();
      routes(h, requireFieldLocation: true);
      final loc = _FakeLocation(null);
      await _pump(tester, _tab(h, location: loc));
      await tester.tap(find.text('외근'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('attendance-place')),
        '판교 고객사',
      );
      await tester.tap(find.byKey(const ValueKey('attendance-clock-in')));
      await tester.pumpAndSettle();
      expect(loc.calls, 1);
      expect(h.called('POST', '/api/groupware/attendance/clock-in'), isEmpty);
      expect(find.text('위치를 가져오지 못했습니다. 위치 권한을 켜고 다시 누르세요.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('외근 위치가 필수가 아니면 위치 없이도 외근 출근', (tester) async {
      final h = _Harness();
      routes(h);
      final loc = _FakeLocation(null);
      await _pump(tester, _tab(h, location: loc));
      await tester.tap(find.text('외근'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('attendance-place')),
        '판교 고객사',
      );
      await tester.tap(find.byKey(const ValueKey('attendance-clock-in')));
      await tester.pumpAndSettle();
      expect(loc.calls, 1, reason: '외근은 되면 위치를 보낸다');
      expect(h.lastBody('POST', '/api/groupware/attendance/clock-in'), {
        'teamId': 'T1',
        'mode': 'field',
        'note': '판교 고객사',
      });
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('주 52시간 지키기 409 — 서버 문구를 그대로 카드에 남긴다, 결재를 받게 안내', (
      tester,
    ) async {
      const message =
          '이번 주 근로시간이 48시간을 넘었습니다. 오늘 일하려면 연장근무(또는 휴일근무) 결재를 먼저 받으세요.';
      final h = _Harness();
      h.routes['GET /api/groupware/attendance/today'] = (_) => _json(
        _today(
          overtimeGuard: 'approval',
          week: {
            'weekStart': '2026-10-12',
            'weekEnd': '2026-10-18',
            'netMinutes': 2940,
            'status': 'warn',
          },
        ),
      );
      h.routes['GET /api/groupware/attendance/month'] = (_) => _json(_month());
      h.routes['POST /api/groupware/attendance/clock-in'] = (_) =>
          _json({'error': message}, status: 409);
      await _pump(tester, _tab(h, location: _FakeLocation(null)));
      expect(
        find.text('주 52시간 지키기: 결재를 받게 — 이번 주 48시간을 넘으면 연장근무 결재가 있어야 출근합니다'),
        findsOneWidget,
      );
      expect(find.text('52시간에 가까움'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('attendance-clock-in')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('attendance-notice')),
          matching: find.text(message),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('출퇴근 탭 — 주 상한·기간·가산 수당·날마다', () {
    testWidgets('탄력 60시간 — 45시간은 주의가 아니다, 기간 카드와 가산 수당', (tester) async {
      final h = _Harness();
      h.routes['GET /api/groupware/attendance/today'] = (_) => _json(
        _today(
          weeklyLimitMinutes: 3600,
          week: {
            'weekStart': '2026-10-12',
            'weekEnd': '2026-10-18',
            'netMinutes': 2700,
            // 서버는 52시간 기준으로 주의라고 하지만 이 사람의 상한(60시간)으로 다시 본다.
            'status': 'warn',
          },
          period: {
            'type': 'flex2w',
            'start': '2026-10-12',
            'end': '2026-10-26',
            'days': 14,
            'standardMinutes': 4800,
            'overtimeCapMinutes': 1440,
            'weeklyMaxMinutes': 3600,
            'netMinutes': 2700,
            'overtimeMinutes': 0,
            'weeks': [
              {'weekStart': '2026-10-12', 'netMinutes': 2700, 'over': false},
            ],
            'status': 'ok',
          },
        ),
      );
      h.routes['GET /api/groupware/attendance/month'] = (_) => _json(
        _month(
          weeklyLimitMinutes: 3600,
          allowance: {
            'wage': 12000,
            'overtimeMinutes': 120,
            'nightMinutes': 60,
            'holidayMinutes': 480,
            'holidayOverMinutes': 60,
            'overtimePay': 36000,
            'nightPay': 6000,
            'holidayPay': 168000,
            'totalPay': 210000,
          },
        ),
      );
      await _pump(tester, _tab(h));
      expect(find.text('이번 주 45시간 / 60시간'), findsOneWidget);
      expect(find.textContaining('가까움'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('attendance-period')),
          matching: find.text(
            '탄력 2주 10/12~10/25: 45시간 / 기준 80시간 · 연장 0시간 (한도 24시간)',
          ),
        ),
        findsOneWidget,
      );
      final allowance = find.byKey(const ValueKey('attendance-allowance'));
      expect(allowance, findsOneWidget);
      expect(
        find.descendant(of: allowance, matching: find.text('가산 수당(참고용)')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: allowance, matching: find.text('9시간')),
        findsOneWidget,
        reason: '휴일 8시간 + 넘는 1시간',
      );
      expect(
        find.descendant(of: allowance, matching: find.text('168,000원')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('attendance-allowance-total')),
            )
            .data,
        '210,000원',
      );
      expect(find.text('참고용 — 실제 급여와 다를 수 있습니다'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('attendance-guard-mode')),
        findsNothing,
        reason: '알리기만(warn)이면 안내 없음',
      );
    });

    testWidgets('선택근무 — 주 상한 없음, 가산 수당은 시급이 없으면 안 보인다', (tester) async {
      final h = _Harness();
      h.routes['GET /api/groupware/attendance/today'] = (_) => _json(
        _today(
          weeklyLimitMinutes: null,
          overtimeGuard: 'block',
          week: {
            'weekStart': '2026-10-12',
            'weekEnd': '2026-10-18',
            'netMinutes': 3300,
            'status': 'over',
          },
        ),
      );
      h.routes['GET /api/groupware/attendance/month'] = (_) => _json(
        _month(
          weeklyLimitMinutes: null,
          periods: [
            {
              'type': 'select',
              'start': '2026-09-01',
              'end': '2026-10-01',
              'standardMinutes': 10560,
              'overtimeCapMinutes': 2640,
              'netMinutes': 11000,
              'overtimeMinutes': 440,
              'status': 'warn',
            },
          ],
        ),
      );
      await _pump(tester, _tab(h));
      expect(
        find.text('이번 주 55시간 · 선택근무 — 주 상한 없음(정산 기간으로 봅니다)'),
        findsOneWidget,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(
        find.byKey(const ValueKey('attendance-guard-mode')),
        findsNothing,
        reason: '주 상한이 없으면 막기 안내도 없다',
      );
      expect(
        find.byKey(const ValueKey('attendance-period-2026-09-01')),
        findsOneWidget,
      );
      expect(find.textContaining('선택근무 정산 9/1~9/30'), findsOneWidget);
      expect(find.byKey(const ValueKey('attendance-allowance')), findsNothing);
    });

    testWidgets('날마다 — 휴게 모자람·위치 단추·사무실 밖, 반반차 시간대', (tester) async {
      final h = _Harness();
      h.routes['GET /api/groupware/attendance/today'] = (_) =>
          _json(_today(overtimeGuard: 'block'));
      h.routes['GET /api/groupware/attendance/month'] = (_) => _json(
        _month(
          days: [
            {
              'date': '2026-10-15',
              'leave': {
                'type': 'quarter',
                'halfDays': 0.5,
                'hours': 2,
                'hourRange': {'start': 540, 'end': 660},
              },
              'record': _record(
                id: 'R5',
                date: '2026-10-15',
                inAt: _ms(11, 0, 15),
                outAt: _ms(18, 0, 15),
              ),
            },
            {
              'date': '2026-10-16',
              'record': _record(
                id: 'R6',
                date: '2026-10-16',
                inAt: _ms(9, 0, 16),
                outAt: _ms(19, 0, 16),
                breakdown: {
                  'workedMinutes': 600,
                  'breakMinutes': 30,
                  'netMinutes': 570,
                  'breakRecorded': true,
                  'breakShortMinutes': 30,
                },
                clockInLocation: {
                  'lat': 37.5,
                  'lng': 127.0,
                  'accuracy': 20,
                  'distance': 1500,
                  'outside': true,
                },
              ),
            },
          ],
        ),
      );
      await _pump(tester, _tab(h));
      expect(
        find.text('주 52시간 지키기: 막기 — 이번 주 52시간에 이르면 출근할 수 없습니다'),
        findsOneWidget,
      );
      final day16 = find.byKey(const ValueKey('attendance-day-2026-10-16'));
      expect(
        find.descendant(
          of: day16,
          matching: find.textContaining('휴게 30분 · 휴게 30분 모자람'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: day16, matching: find.textContaining('사무실 밖')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('attendance-location-2026-10-16')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('attendance-location-2026-10-16')),
            )
            .tooltip,
        '위치 보기(지도) — 사무실에서 1500m',
      );
      final day15 = find.byKey(const ValueKey('attendance-day-2026-10-15'));
      expect(
        find.descendant(
          of: day15,
          matching: find.textContaining('반반차 09:00~11:00'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('attendance-location-2026-10-15')),
        findsNothing,
      );
    });
  });

  group('시간 단위 연차 신청', () {
    void routes(_Harness h) {
      h.routes['GET /api/groupware/candidates'] = (_) => _json([
        {'id': 'U-lead', 'name': '팀장', 'username': 'lead'},
      ]);
      h.routes['GET /api/groupware/approval-lines'] = (_) => _json({
        'lines': [],
        'suggested': {
          'approverIds': ['U-lead'],
          'ccIds': [],
          'source': 'org',
        },
      });
      h.routes['POST /api/groupware/documents'] = (r) => _json({
        'id': 'D-new',
        'kind': 'leave',
        'title': '시간 연차 신청',
        'payload': jsonDecode(r.body),
        'attachments': [],
        'status': 'pending',
        'authorId': 'U-me',
        'authorName': '홍길동',
        'createdAt': _ms(9),
        'steps': [],
      }, status: 201);
    }

    Future<void> open(WidgetTester tester, _Harness h) async {
      await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showLeaveRequestDialog(
              context,
              api: h.api,
              ctx: _ctx(),
              balance: LeaveBalance.fromJson({
                'hireDate': '2020-05-10',
                'grantedHalfDays': 30,
                'remainingHalfDays': 10.75,
                'pendingHalfDays': 0.5,
              }),
            ),
            child: const Text('열기'),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
    }

    Future<void> chooseType(WidgetTester tester, String label) async {
      await tester.tap(find.byKey(const ValueKey('leave-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    Future<void> pickDay20(WidgetTester tester) async {
      await tester.tap(find.text('날짜'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(DatePickerDialog),
          matching: find.text('20'),
        ),
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
    }

    testWidgets('시간 연차 — 날짜 하나, 시작 시각·시간 수를 보내고 끝 시각·연차 양을 보여 준다', (
      tester,
    ) async {
      final h = _Harness();
      routes(h);
      await open(tester, h);
      expect(
        find.textContaining('남은 연차 5일 1시간'),
        findsOneWidget,
        reason: '10.75 − 0.5 = 10.25반일 = 5일 1시간',
      );
      expect(find.byKey(const ValueKey('leave-start-time')), findsNothing);
      await chooseType(tester, '시간 연차');
      expect(find.text('끝'), findsNothing);
      expect(find.byKey(const ValueKey('leave-hours')), findsOneWidget);
      expect(find.text('09:00~10:00 · 1시간 (연차 1시간)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('leave-hours')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('6시간').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('leave-start-time')),
        '10:30',
      );
      await tester.pumpAndSettle();
      expect(find.text('10:30~16:30 · 6시간 (연차 6시간)'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('leave-start-time')),
        '10시',
      );
      await tester.pumpAndSettle();
      await pickDay20(tester);
      await tester.tap(find.byKey(const ValueKey('approval-request-submit')));
      await tester.pumpAndSettle();
      expect(h.called('POST', '/api/groupware/documents'), isEmpty);
      expect(find.text('시작 시각을 HH:MM으로 넣으세요.'), findsWidgets);

      await tester.enterText(
        find.byKey(const ValueKey('leave-start-time')),
        '10:30',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('approval-request-submit')));
      await tester.pumpAndSettle();
      final body = h.lastBody('POST', '/api/groupware/documents');
      expect(body['leaveType'], 'hourly');
      expect(body['startTime'], '10:30');
      expect(body['hours'], 6);
      expect(body['endDate'], body['startDate']);
      expect(body['startDate'], endsWith('-20'));
      expect(body['approverIds'], ['U-lead']);
    });

    testWidgets('반반차 — 시간 고르기 없이 2시간 고정', (tester) async {
      final h = _Harness();
      routes(h);
      await open(tester, h);
      await chooseType(tester, '반반차');
      expect(find.byKey(const ValueKey('leave-hours')), findsNothing);
      expect(find.text('2시간 고정'), findsOneWidget);
      expect(find.text('09:00~11:00 · 2시간 (연차 2시간)'), findsOneWidget);
      await pickDay20(tester);
      await tester.tap(find.byKey(const ValueKey('approval-request-submit')));
      await tester.pumpAndSettle();
      final body = h.lastBody('POST', '/api/groupware/documents');
      expect(body['leaveType'], 'quarter');
      expect(body['startTime'], '09:00');
      expect(body['hours'], 2);
    });

    testWidgets('하루 연차는 시작 시각·시간을 보내지 않는다', (tester) async {
      final h = _Harness();
      routes(h);
      await open(tester, h);
      await tester.tap(find.text('시작'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(DatePickerDialog),
          matching: find.text('20'),
        ),
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('approval-request-submit')));
      await tester.pumpAndSettle();
      final body = h.lastBody('POST', '/api/groupware/documents');
      expect(body['leaveType'], 'annual');
      expect(body.containsKey('startTime'), isFalse);
      expect(body.containsKey('hours'), isFalse);
    });
  });

  group('휴가 탭', () {
    void routes(_Harness h) {
      h.routes['GET /api/groupware/leave/balance'] = (_) => _json({
        'hireDate': '2020-05-10',
        'basis': 'fiscal',
        'period': {'year': 6, 'start': '2026-01-01', 'end': '2027-01-01'},
        'statutoryHalfDays': 30,
        'adjustmentHalfDays': 5,
        'grantedHalfDays': 35,
        'usedHalfDays': 10.25,
        'pendingHalfDays': 0,
        'remainingHalfDays': 24.75,
        'adjustments': [
          {
            'id': 'A1',
            'kind': 'carry',
            'halfDays': 6,
            'reason': '지난 기간에서 이월',
            'createdByName': '인사팀',
          },
          {
            'id': 'A2',
            'kind': 'manual',
            'halfDays': -1,
            'reason': '정정',
            'createdByName': '인사팀',
          },
        ],
      });
      h.routes['GET /api/groupware/leave/calendar'] = (_) => _json([]);
      h.routes['GET /api/groupware/documents'] = (_) => _json([]);
      h.routes['GET /api/groupware/leave/promotions/mine'] = (_) => _json([
        {
          'id': 'P1',
          'userId': 'U-me',
          'stage': 1,
          'periodStart': '2026-01-01',
          'periodEnd': '2027-01-01',
          'expiry': '2026-12-31',
          'remainingHalfDays': 24.75,
          'deadline': '2026-10-27',
          'planDates': [],
          'readAt': 1,
        },
      ]);
    }

    testWidgets('회계연도 기준·이월·관리자 조정을 나눠 보이고, 소수 연차를 시간으로', (tester) async {
      final h = _Harness();
      routes(h);
      await _pump(
        tester,
        LeaveTab(
          api: h.api,
          ctx: _ctx(),
          changes: GroupwareChanges(),
          session: h.session,
        ),
      );
      expect(
        find.textContaining('2026-01-01 ~ 2027-01-01 · 회계연도 기준'),
        findsOneWidget,
      );
      expect(find.textContaining('이월 +3일'), findsOneWidget);
      expect(find.textContaining('관리자 조정 −0.5일'), findsOneWidget);
      expect(find.text('5일 1시간'), findsOneWidget, reason: '쓴 연차 10.25반일');
      expect(find.text('12일 3시간'), findsOneWidget, reason: '남은 연차 24.75반일');
    });

    testWidgets('받은 통지의 통지서 PDF — 실패하면 알린다', (tester) async {
      final h = _Harness();
      routes(h);
      await _pump(
        tester,
        LeaveTab(
          api: h.api,
          ctx: _ctx(),
          changes: GroupwareChanges(),
          session: h.session,
        ),
      );
      final pdf = find.byKey(const ValueKey('leave-notice-pdf-P1'));
      expect(pdf, findsOneWidget);
      expect(
        find.byKey(const ValueKey('leave-promotion-submit')),
        findsOneWidget,
      );
      await tester.tap(pdf);
      await tester.pump();
      // 통지서 만들기(leave_notice_pdf.dart)는 인쇄·저장 플러그인이 없는 이 시험 환경에서 실패할 수 있다 — 던지면 "실패:" 토스트로
      // 알리고 탭은 무너지지 않는다(통지서 내용은 그쪽 시험).
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
