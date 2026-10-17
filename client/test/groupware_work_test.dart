// 근태·휴가 관리(앱) — 범위 설정(휴가 종류·지출 분류·출근 알림), 외근 출근, 주 52시간 막대, 유연근무, 연차 사용 촉진(받은 사람·관리자),
// 출근 알림 소켓. 서버(groupwareWork.js)는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/groupware.dart';
import 'package:client/models/groupware_work.dart';
import 'package:client/screens/groupware/attendance_tab.dart';
import 'package:client/screens/groupware/groupware_screen.dart'
    show GroupwareChanges;
import 'package:client/screens/groupware/groupware_work_admin.dart';
import 'package:client/screens/groupware/leave_tab.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
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
  {
    'key': 'annual',
    'label': '연차',
    'deducts': true,
    'half': false,
    'enabled': true,
    'builtin': true,
  },
  {
    'key': 'sick',
    'label': '병가',
    'deducts': false,
    'half': false,
    'enabled': false,
    'builtin': true,
  },
  {
    'key': 'c_ab12',
    'label': '안식휴가',
    'deducts': false,
    'half': false,
    'enabled': true,
    'builtin': false,
  },
];

GroupwareContext _ctx({Map<String, dynamic>? schedule}) =>
    GroupwareContext.fromJson({
      'scope': 'team',
      'teamId': 'T1',
      'isManager': true,
      'today': '2026-10-17',
      'workStart': 540,
      'workEnd': 1080,
      'leaveTypes': _leaveTypes,
      'expenseCategories': ['식대'],
      'schedule': schedule,
      'weeklyLimitMinutes': 3120,
      'weeklyWarnMinutes': 2880,
      'limits': {'approversMax': 5, 'ccMax': 10, 'attachmentsMax': 5},
    });

/// 띄운 결재(그룹웨어) 알림을 기록만 하는 알림 서비스.
class _RecordingNotifications extends NotificationService {
  final shown =
      <({String title, String body, String documentId, String? teamId})>[];

  @override
  Future<void> showApprovalNotification({
    required String title,
    required String body,
    required String documentId,
    String? teamId,
  }) async => shown.add((
    title: title,
    body: body,
    documentId: documentId,
    teamId: teamId,
  ));
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
  bool scroll = true,
}) async {
  tester.view.physicalSize = const Size(1100, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: scroll ? SingleChildScrollView(child: child) : child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, dynamic> _promotion({
  List<String> plan = const [],
  int stage = 1,
}) => {
  'id': 'P1',
  'userId': 'U-me',
  'stage': stage,
  'periodStart': '2026-05-10',
  'periodEnd': '2027-05-10',
  'expiry': '2027-05-09',
  'remainingHalfDays': 6,
  'deadline': '2026-10-27',
  'message': '연말 전에 꼭 쓰세요',
  'designatedDates': stage == 2 ? ['2027-03-02'] : [],
  'planDates': plan,
  'sentByName': '인사팀',
  'sentAt': DateTime(2026, 10, 17, 9).millisecondsSinceEpoch,
};

void main() {
  group('모양 읽기', () {
    test('휴가 종류 — 꺼진 것은 신청 목록에서 빠지고, 보낼 때 더한 종류만 연차 차감을 보낸다', () {
      final ctx = _ctx();
      expect(ctx.leaveTypes.map((t) => t.key), ['annual', 'sick', 'c_ab12']);
      expect(ctx.enabledLeaveTypes.map((t) => t.key), ['annual', 'c_ab12']);
      expect(ctx.leaveTypes[0].toJson(), {
        'key': 'annual',
        'label': '연차',
        'enabled': true,
      });
      expect(ctx.leaveTypes[2].toJson(), {
        'key': 'c_ab12',
        'label': '안식휴가',
        'enabled': true,
        'deducts': false,
      });
      final o = GroupwareOptions.fromJson({
        'leaveTypes': _leaveTypes,
        'expenseCategories': ['식대', '교통비'],
        'clockInReminder': true,
        'reminderDelayMinutes': 15,
      });
      expect(o.leaveTypes.length, 3);
      expect(o.expenseCategories, ['식대', '교통비']);
      expect(o.clockInReminder, isTrue);
      expect(o.clockOutReminder, isFalse);
      expect(o.reminderDelayMinutes, 15);
    });

    test('근무 형태 설명·시간 글자·촉진 단계', () {
      expect(
        WorkSchedule.fromJson({
          'mode': 'staggered',
          'label': '시차출퇴근',
          'start': 420,
          'end': 960,
        })!.description,
        '시차출퇴근 07:00~16:00',
      );
      expect(
        WorkSchedule.fromJson({
          'mode': 'core',
          'label': '선택근무',
          'coreStart': 600,
          'coreEnd': 900,
        })!.description,
        '선택근무(핵심 10:00~15:00)',
      );
      expect(WorkSchedule.fromJson(null), isNull);
      expect(durationText(510), '8시간 30분');
      expect(durationText(45), '45분');
      expect(PromotionStage.fromWire('second'), PromotionStage.second);
      expect(PromotionStage.fromWire('???'), PromotionStage.none);
      final p = LeavePromotion.fromJson(_promotion());
      expect(p.awaitingPlan('2026-10-27'), isTrue);
      expect(p.awaitingPlan('2026-10-28'), isFalse, reason: '마감이 지나면 낼 수 없다');
      expect(
        LeavePromotion.fromJson(
          _promotion(plan: ['2026-12-24']),
        ).awaitingPlan('2026-10-20'),
        isFalse,
      );
    });
  });

  group('출퇴근 탭', () {
    void routes(_Harness h, {Map<String, dynamic>? week}) {
      h.routes['GET /api/groupware/attendance/today'] = (_) => _json({
        'today': '2026-10-17',
        'record': null,
        'openRecord': null,
        'canClockIn': true,
        'canClockOut': false,
        'inLan': false,
        'workStart': 420,
        'workEnd': 960,
        'week': week,
      });
      h.routes['GET /api/groupware/attendance/month'] = (_) => _json({
        'month': '2026-10',
        'days': [
          {
            'date': '2026-10-16',
            'holiday': null,
            'leave': null,
            'record': {
              'id': 'R0',
              'workDate': '2026-10-16',
              'clockInAt': DateTime(2026, 10, 16, 7).millisecondsSinceEpoch,
              'clockOutAt': DateTime(2026, 10, 16, 23).millisecondsSinceEpoch,
              'clockInMode': 'field',
              'note': '고객사',
              'breakdown': {
                'workedMinutes': 960,
                'breakMinutes': 60,
                'netMinutes': 900,
                'overtimeMinutes': 420,
                'nightMinutes': 60,
              },
            },
          },
        ],
        'summary': {
          'daysWorked': 1,
          'workedMinutes': 960,
          'netMinutes': 900,
          'actualOvertimeMinutes': 420,
          'nightMinutes': 60,
          'holidayWorkMinutes': 0,
        },
        'weeks': [
          {
            'weekStart': '2026-10-12',
            'weekEnd': '2026-10-18',
            'netMinutes': 3200,
            'overtimeMinutes': 800,
            'status': 'over',
          },
        ],
      });
    }

    testWidgets('외근은 장소를 적어야 출근 — 형태와 장소를 보낸다, 근무 형태·이번 주 막대·주마다 표시', (
      tester,
    ) async {
      final h = _Harness();
      routes(
        h,
        week: {
          'weekStart': '2026-10-12',
          'weekEnd': '2026-10-18',
          'netMinutes': 2940,
          'status': 'warn',
        },
      );
      h.routes['POST /api/groupware/attendance/clock-in'] = (_) => _json({
        'id': 'R1',
        'workDate': '2026-10-17',
        'clockInAt': DateTime(2026, 10, 17, 6, 55).millisecondsSinceEpoch,
        'clockInMode': 'field',
        'note': '판교 고객사',
      }, status: 201);
      final ctx = _ctx(
        schedule: {
          'mode': 'staggered',
          'label': '시차출퇴근',
          'start': 420,
          'end': 960,
        },
      );
      await _pump(
        tester,
        AttendanceTab(
          api: h.api,
          ctx: ctx,
          changes: GroupwareChanges(),
          session: h.session,
        ),
        scroll: false,
      );
      expect(find.text('근무 형태: 시차출퇴근 07:00~16:00'), findsOneWidget);
      expect(find.byKey(const ValueKey('attendance-week')), findsOneWidget);
      expect(find.text('52시간에 가까움'), findsOneWidget);
      expect(find.textContaining('49시간'), findsWidgets);
      expect(
        find.byKey(const ValueKey('attendance-week-2026-10-12')),
        findsOneWidget,
      );
      expect(find.textContaining('연장 7시간'), findsWidgets);
      expect(find.textContaining('외근(고객사)'), findsOneWidget);

      await tester.tap(find.text('외근'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('attendance-clock-in')));
      await tester.pumpAndSettle();
      expect(
        h.called('POST', '/api/groupware/attendance/clock-in'),
        isEmpty,
        reason: '장소 없이 외근 출근 안 됨',
      );
      await tester.enterText(
        find.byKey(const ValueKey('attendance-place')),
        '판교 고객사',
      );
      await tester.tap(find.byKey(const ValueKey('attendance-clock-in')));
      await tester.pumpAndSettle();
      expect(h.lastBody('POST', '/api/groupware/attendance/clock-in'), {
        'teamId': 'T1',
        'mode': 'field',
        'note': '판교 고객사',
      });
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('사무실 출근은 장소 없이 형태만', (tester) async {
      final h = _Harness();
      routes(h);
      h.routes['POST /api/groupware/attendance/clock-in'] = (_) => _json({
        'id': 'R1',
        'workDate': '2026-10-17',
        'clockInAt': DateTime(2026, 10, 17, 8, 55).millisecondsSinceEpoch,
      }, status: 201);
      await _pump(
        tester,
        AttendanceTab(
          api: h.api,
          ctx: _ctx(),
          changes: GroupwareChanges(),
          session: h.session,
        ),
        scroll: false,
      );
      expect(find.byKey(const ValueKey('attendance-place')), findsNothing);
      expect(find.byKey(const ValueKey('attendance-schedule')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('attendance-clock-in')));
      await tester.pumpAndSettle();
      expect(h.lastBody('POST', '/api/groupware/attendance/clock-in'), {
        'teamId': 'T1',
        'mode': 'office',
      });
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('휴가 탭 — 연차 사용 촉진', () {
    void routes(_Harness h, List<Map<String, dynamic>> promotions) {
      h.routes['GET /api/groupware/leave/balance'] = (_) => _json({
        'hireDate': '2020-05-10',
        'period': {'year': 6, 'start': '2026-05-10', 'end': '2027-05-10'},
        'grantedHalfDays': 34,
        'usedHalfDays': 28,
        'remainingHalfDays': 6,
        'adjustments': [],
      });
      h.routes['GET /api/groupware/leave/calendar'] = (_) => _json([]);
      h.routes['GET /api/groupware/documents'] = (_) => _json([]);
      h.routes['GET /api/groupware/leave/promotions/mine'] = (_) =>
          _json(promotions);
      h.routes['POST /api/groupware/leave/promotions/P1/read'] = (_) =>
          _json(_promotion());
    }

    testWidgets('1차 통지를 보이면 확인으로 남기고, 쓸 날을 고르면 낸다', (tester) async {
      final h = _Harness();
      routes(h, [_promotion()]);
      h.routes['POST /api/groupware/leave/promotions/P1/plan'] = (_) =>
          _json(_promotion(plan: ['2026-10-20']));
      await _pump(
        tester,
        LeaveTab(
          api: h.api,
          ctx: _ctx(),
          changes: GroupwareChanges(),
          session: h.session,
        ),
        scroll: false,
      );
      expect(find.byKey(const ValueKey('leave-promotion-P1')), findsOneWidget);
      expect(find.text('연차 사용 촉진 안내'), findsOneWidget);
      expect(find.textContaining('2026-10-27까지 쓸 날을 정해'), findsOneWidget);
      expect(find.textContaining('인사팀'), findsOneWidget);
      expect(
        h.called('POST', '/api/groupware/leave/promotions/P1/read'),
        hasLength(1),
      );

      await tester.tap(find.byKey(const ValueKey('leave-promotion-submit')));
      await tester.pumpAndSettle();
      expect(find.text('2027-05-09까지, 3일까지 고를 수 있습니다.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('leave-dates-save')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('leave-dates-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('20'));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('2026-10-20'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('leave-dates-save')));
      await tester.pumpAndSettle();
      expect(h.lastBody('POST', '/api/groupware/leave/promotions/P1/plan'), {
        'dates': ['2026-10-20'],
      });
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('낸 계획·2차 지정은 보여 주기만', (tester) async {
      final h = _Harness();
      routes(h, [
        {
          ..._promotion(plan: ['2026-12-24']),
          'readAt': 1,
        },
        {..._promotion(stage: 2), 'id': 'P2', 'readAt': 1},
      ]);
      await _pump(
        tester,
        LeaveTab(
          api: h.api,
          ctx: _ctx(),
          changes: GroupwareChanges(),
          session: h.session,
        ),
        scroll: false,
      );
      expect(find.text('낸 계획: 2026-12-24'), findsOneWidget);
      expect(find.text('연차 사용 시기 지정 통보'), findsOneWidget);
      expect(find.textContaining('회사가 정한 연차 쓸 날: 2027-03-02'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('leave-promotion-submit')),
        findsNothing,
      );
      expect(
        h.called('POST', '/api/groupware/leave/promotions/P1/read'),
        isEmpty,
        reason: '이미 확인한 통지',
      );
    });
  });

  group('관리 탭', () {
    testWidgets('휴가 종류 — 끄고 이름 바꾸고 더한 종류(연차 차감)를 보낸다, 연차는 끌 수 없다', (
      tester,
    ) async {
      final h = _Harness();
      final options = {
        'leaveTypes': _leaveTypes,
        'expenseCategories': ['식대', '교통비'],
        'clockInReminder': false,
        'clockOutReminder': false,
        'reminderDelayMinutes': 10,
      };
      h.routes['GET /api/groupware/options'] = (_) => _json(options);
      h.routes['PATCH /api/groupware/options'] = (_) => _json(options);
      var changed = 0;
      await _pump(
        tester,
        GroupwareOptionsSection(
          api: h.api,
          changes: GroupwareChanges(),
          onChanged: () => changed++,
        ),
      );
      expect(find.text('연차 · 안식휴가'), findsOneWidget, reason: '켜진 것만');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('gw-leave-types')),
          matching: find.text('바꾸기'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Switch>(
              find.byKey(const ValueKey('gw-leave-type-0-enabled')),
            )
            .onChanged,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('gw-leave-type-1-enabled')));
      await tester.enterText(
        find.byKey(const ValueKey('gw-leave-type-2-label')),
        '리프레시 휴가',
      );
      await tester.tap(find.byKey(const ValueKey('gw-leave-type-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('gw-leave-types-save')));
      await tester.pumpAndSettle();
      expect(find.text('휴가 종류 이름을 넣으세요.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('gw-leave-type-3-label')),
        '포상휴가',
      );
      await tester.tap(find.byKey(const ValueKey('gw-leave-type-3-deducts')));
      await tester.tap(find.byKey(const ValueKey('gw-leave-types-save')));
      await tester.pumpAndSettle();
      expect(h.lastBody('PATCH', '/api/groupware/options'), {
        'teamId': 'T1',
        'leaveTypes': [
          {'key': 'annual', 'label': '연차', 'enabled': true},
          {'key': 'sick', 'label': '병가', 'enabled': true},
          {
            'key': 'c_ab12',
            'label': '리프레시 휴가',
            'enabled': true,
            'deducts': false,
          },
          {'key': '', 'label': '포상휴가', 'enabled': true, 'deducts': true},
        ],
      });
      expect(changed, 1);

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('gw-expense-categories')),
          matching: find.text('바꾸기'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('gw-category-input')),
        '도서',
      );
      await tester.tap(find.byKey(const ValueKey('gw-category-add')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('gw-category-교통비')),
          matching: find.byIcon(Icons.clear),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('gw-categories-save')));
      await tester.pumpAndSettle();
      expect(h.lastBody('PATCH', '/api/groupware/options'), {
        'teamId': 'T1',
        'expenseCategories': ['식대', '도서'],
      });

      await tester.tap(find.byKey(const ValueKey('gw-clock-in-reminder')));
      await tester.pumpAndSettle();
      expect(h.lastBody('PATCH', '/api/groupware/options'), {
        'teamId': 'T1',
        'clockInReminder': true,
      });
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('유연근무 — 선택근무로 정하고, 기본으로 되돌린다', (tester) async {
      final h = _Harness();
      h.routes['GET /api/groupware/schedules'] = (_) => _json([
        {'userId': 'U-a', 'name': '김가', 'schedule': null},
        {
          'userId': 'U-b',
          'name': '이나',
          'schedule': {'mode': 'free', 'label': '자율 출퇴근'},
        },
      ]);
      h.routes['PUT /api/groupware/schedules/U-a'] = (_) =>
          _json({'userId': 'U-a', 'name': '김가'});
      h.routes['DELETE /api/groupware/schedules/U-b'] = (_) =>
          _json({'ok': true});
      await _pump(tester, WorkSchedulesSection(api: h.api, ctx: _ctx()));
      expect(find.text('기본 09:00~18:00'), findsOneWidget);
      expect(find.text('자율 출퇴근'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('gw-schedule-U-a')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('gw-schedule-default')), findsNothing);
      await tester.tap(find.text('선택근무'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('gw-schedule-core-a')),
        '10:30',
      );
      await tester.enterText(
        find.byKey(const ValueKey('gw-schedule-core-b')),
        '1500',
      );
      await tester.tap(find.byKey(const ValueKey('gw-schedule-save')));
      await tester.pumpAndSettle();
      expect(find.text('핵심 시간대를 HH:MM으로 넣으세요.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('gw-schedule-core-b')),
        '15:00',
      );
      await tester.tap(find.byKey(const ValueKey('gw-schedule-save')));
      await tester.pumpAndSettle();
      expect(h.lastBody('PUT', '/api/groupware/schedules/U-a'), {
        'teamId': 'T1',
        'mode': 'core',
        'coreStart': '10:30',
        'coreEnd': '15:00',
      });

      await tester.tap(find.byKey(const ValueKey('gw-schedule-U-b')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('gw-schedule-default')));
      await tester.pumpAndSettle();
      expect(h.called('DELETE', '/api/groupware/schedules/U-b'), hasLength(1));
    });

    testWidgets('주 52시간 — 넘은 사람 표시, 지난주로, 다음 주보다 앞으로는 못 간다', (tester) async {
      final h = _Harness();
      h.routes['GET /api/groupware/attendance/weekly'] = (r) {
        final day = r.url.queryParameters['week']!;
        return _json({
          'weekStart': day == '2026-10-17' ? '2026-10-12' : '2026-10-05',
          'weekEnd': day == '2026-10-17' ? '2026-10-18' : '2026-10-11',
          'members': [
            {
              'userId': 'U-a',
              'name': '김가',
              'netMinutes': 3200,
              'overtimeMinutes': 800,
              'holidayMinutes': 120,
              'status': 'over',
            },
            {'userId': 'U-b', 'name': '이나', 'netMinutes': 2400, 'status': 'ok'},
          ],
        });
      };
      await _pump(tester, WeeklyHoursSection(api: h.api, ctx: _ctx()));
      expect(find.text('10/12~10/18'), findsOneWidget);
      expect(find.text('52시간 넘음'), findsOneWidget);
      expect(find.textContaining('연장 13시간 20분 · 휴일 2시간'), findsOneWidget);
      await tester.tap(find.byTooltip('지난주'));
      await tester.pumpAndSettle();
      expect(
        h
            .called('GET', '/api/groupware/attendance/weekly')
            .last
            .url
            .queryParameters['week'],
        '2026-10-10',
      );
      expect(find.text('10/5~10/11'), findsOneWidget);
      await tester.tap(find.byTooltip('다음 주'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('다음 주'));
      await tester.pumpAndSettle();
      expect(
        h
            .called('GET', '/api/groupware/attendance/weekly')
            .map((r) => r.url.queryParameters['week']),
        ['2026-10-17', '2026-10-10', '2026-10-17'],
      );
    });

    testWidgets('연차 촉진 — 1차 기간인 사람만 골라 보내고, 2차는 날을 정해 통보', (tester) async {
      final h = _Harness();
      Map<String, dynamic> member(
        String id,
        String name,
        String stage, {
        List<Map<String, dynamic>> notices = const [],
      }) => {
        'userId': id,
        'name': name,
        'expiry': '2027-01-31',
        'firstYear': false,
        'firstStart': '2026-08-01',
        'firstEnd': '2026-08-10',
        'secondDeadline': '2026-11-30',
        'remainingHalfDays': 4,
        'stage': stage,
        'notices': notices,
      };
      h.routes['GET /api/groupware/leave/promotions'] = (_) => _json({
        'members': [
          member('U-a', '김가', 'first'),
          member(
            'U-b',
            '이나',
            'second',
            notices: [
              {..._promotion(), 'userId': 'U-b', 'readAt': 1},
            ],
          ),
          member('U-c', '박다', 'upcoming'),
        ],
      });
      h.routes['POST /api/groupware/leave/promotions'] = (_) => _json({
        'sent': [
          {'userId': 'U-a'},
        ],
        'skipped': [],
      }, status: 201);
      h.routes['POST /api/groupware/leave/promotions/second'] = (_) =>
          _json({..._promotion(stage: 2), 'userId': 'U-b'}, status: 201);
      await _pump(
        tester,
        LeavePromotionSection(
          api: h.api,
          ctx: _ctx(),
          changes: GroupwareChanges(),
        ),
      );
      expect(find.text('1차 촉진 기간'), findsOneWidget);
      expect(find.text('2차 촉진 필요'), findsOneWidget);
      expect(find.textContaining('1차 보냄·확인함'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('gw-promotion-select-U-c')),
        findsNothing,
        reason: '1차 기간이 아니면 고를 수 없다',
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('gw-promotion-send')),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const ValueKey('gw-promotion-select-U-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('gw-promotion-send')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('gw-promotion-confirm')));
      await tester.pumpAndSettle();
      expect(h.lastBody('POST', '/api/groupware/leave/promotions'), {
        'teamId': 'T1',
        'userIds': ['U-a'],
      });
      expect(find.textContaining('1명에게 보냈습니다.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));

      await tester.tap(find.byKey(const ValueKey('gw-promotion-second-U-b')));
      await tester.pumpAndSettle();
      expect(find.text('2027-01-31까지, 2일까지 고를 수 있습니다.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('leave-dates-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('20'));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('leave-dates-save')));
      await tester.pumpAndSettle();
      expect(h.lastBody('POST', '/api/groupware/leave/promotions/second'), {
        'teamId': 'T1',
        'userId': 'U-b',
        'dates': ['2026-10-20'],
      });
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('출근 알림(소켓 attendance:reminder)', () {
    test('토스트와 기기 알림(문서 id 없음 — 누르면 그룹웨어 화면)', () async {
      final notifications = _RecordingNotifications();
      final session = Session(
        notifications: notifications,
        settings: AppSettings(),
      );
      final toasts = <String>[];
      final sub = session.toasts.listen(toasts.add);
      session.handleAttendanceReminder({
        'kind': 'in',
        'title': '출근 기록',
        'body': '아직 출근을 누르지 않았습니다.',
        'teamId': 'T1',
      });
      await Future<void>.delayed(Duration.zero);
      expect(toasts.single, '출근 기록 — 아직 출근을 누르지 않았습니다.');
      expect(notifications.shown.single.documentId, '');
      expect(notifications.shown.single.teamId, 'T1');
      expect(
        NotificationService.parseApprovalPayload(
          NotificationService.approvalPayload('', 'T1'),
        )!.documentId,
        '',
      );
      await sub.cancel();
    });

    test('둘째 창(알림 끔)에서는 토스트만', () async {
      final notifications = _RecordingNotifications();
      final session = Session(
        notifications: notifications,
        settings: AppSettings(),
        suppressNotifications: true,
      );
      session.handleAttendanceReminder({
        'kind': 'out',
        'title': '퇴근 기록',
        'body': '',
      });
      expect(notifications.shown, isEmpty);
    });
  });
}
