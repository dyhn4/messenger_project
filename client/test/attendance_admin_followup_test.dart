// 근태·휴가 관리 후속(앱 관리 화면) — 주 52시간 지키기·연차 기준(회계연도)·연차 이월·가산율·사무실 위치·외근 위치 필수(범위 설정),
// 탄력·선택근무 정산 기간(근무 형태), 사람마다 주 상한과 기간 현황(주 52시간), 통상시급·총 가산 수당·이월 조정 표시(관리 탭), 연차 촉진
// 서면 통지서 PDF. 서버(groupwareWork.js·groupware.js)는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/groupware.dart';
import 'package:client/models/groupware_work.dart';
import 'package:client/screens/groupware/groupware_admin_tab.dart';
import 'package:client/screens/groupware/groupware_screen.dart'
    show GroupwareChanges;
import 'package:client/screens/groupware/groupware_work_admin.dart';
import 'package:client/screens/groupware/leave_notice_pdf.dart';
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

GroupwareContext _ctx() => GroupwareContext.fromJson({
  'scope': 'team',
  'teamId': 'T1',
  'teamName': '본사',
  'isManager': true,
  'today': '2026-10-17',
  'workStart': 540,
  'workEnd': 1080,
  'leaveTypes': [
    {
      'key': 'annual',
      'label': '연차',
      'deducts': true,
      'half': false,
      'enabled': true,
      'builtin': true,
    },
  ],
  'expenseCategories': ['식대'],
  'weeklyLimitMinutes': 3120,
  'weeklyWarnMinutes': 2880,
  'limits': {'approversMax': 5, 'ccMax': 10, 'attachmentsMax': 5},
});

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
    session.token = 't';
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
  double height = 2400,
}) async {
  tester.view.physicalSize = Size(1100, height);
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

/// 화면 밖일 수 있는 것을 보이게 한 뒤 누른다.
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 범위 설정 서버 흉내 — PATCH 본문을 지금 설정에 덮어쓰고(officeLocation null이면 지움) 돌려준다. 5명 이상인데 법정 가산율보다
/// 낮으면 서버처럼 400.
Map<String, dynamic> _optionsServer(_Harness h, {int carryDays = 0}) {
  final options = <String, dynamic>{
    'leaveTypes': const [],
    'expenseCategories': const ['식대'],
    'clockInReminder': false,
    'clockOutReminder': false,
    'reminderDelayMinutes': 10,
    'overtimeGuard': 'warn',
    'leaveBasis': 'hire',
    'fiscalStartMonth': 1,
    'carryOverMaxDays': carryDays,
    'payRates': {
      'overtime': 50,
      'night': 50,
      'holiday': 50,
      'holidayOver': 100,
      'smallBusiness': false,
    },
    'officeLocation': null,
    'requireFieldLocation': false,
  };
  h.routes['GET /api/groupware/options'] = (_) => _json(options);
  h.routes['PATCH /api/groupware/options'] = (r) {
    final body = jsonDecode(r.body) as Map<String, dynamic>..remove('teamId');
    final rates = body['payRates'] as Map?;
    if (rates != null &&
        rates['smallBusiness'] != true &&
        (rates['overtime'] as num) < 50) {
      return _json({
        'error': '상시 5명 이상 사업장은 법정 가산율(50%)보다 낮게 정할 수 없습니다.',
      }, status: 400);
    }
    options.addAll(body);
    return _json(options);
  };
  return options;
}

Map<String, dynamic> _notice({required String id, required int stage}) => {
  'id': id,
  'userId': 'U-a',
  'stage': stage,
  'periodStart': '2026-05-10',
  'periodEnd': '2027-05-10',
  'expiry': '2027-05-09',
  'remainingHalfDays': 7.5,
  'deadline': '2026-10-27',
  'message': '연말 전에 꼭 쓰세요',
  'designatedDates': stage == 2 ? ['2027-03-02', '2027-03-03'] : [],
  'planDates': stage == 1 ? ['2026-12-24'] : [],
  'plannedAt': stage == 1
      ? DateTime(2026, 10, 20, 10).millisecondsSinceEpoch
      : null,
  'sentByName': '인사팀',
  'sentAt': DateTime(2026, 10, 17, 9).millisecondsSinceEpoch,
  'readAt': stage == 1
      ? DateTime(2026, 10, 17, 11).millisecondsSinceEpoch
      : null,
};

void main() {
  group('범위 설정', () {
    testWidgets('주 52시간 지키기·연차 기준(회계연도)·이월 일수·가산율·사무실 위치·외근 위치 필수를 보낸다', (
      tester,
    ) async {
      final h = _Harness();
      _optionsServer(h);
      await _pump(
        tester,
        GroupwareOptionsSection(api: h.api, changes: GroupwareChanges()),
      );
      const path = '/api/groupware/options';
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('gw-carry-run')))
            .onPressed,
        isNull,
        reason: '이월 일수가 0이면 이월할 수 없다',
      );
      expect(find.textContaining('알리기만 합니다'), findsOneWidget);

      // 주 52시간 지키기 — 결재를 받게.
      await _tap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('gw-overtime-guard')),
          matching: find.text('결재를 받게'),
        ),
      );
      expect(h.lastBody('PATCH', path), {
        'teamId': 'T1',
        'overtimeGuard': 'approval',
      });
      expect(find.textContaining('승인된 연장·휴일근무 결재가 있어야'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));

      // 연차 기준 — 회계연도로(묻고), 그다음 시작 달.
      expect(find.byKey(const ValueKey('gw-fiscal-month')), findsNothing);
      await _tap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('gw-leave-basis')),
          matching: find.text('회계연도'),
        ),
      );
      expect(find.textContaining('새 기준으로 다시 계산됩니다'), findsWidgets);
      await _tap(tester, find.byKey(const ValueKey('gw-leave-basis-confirm')));
      expect(h.lastBody('PATCH', path), {
        'teamId': 'T1',
        'leaveBasis': 'fiscal',
        'fiscalStartMonth': 1,
      });
      expect(find.byKey(const ValueKey('gw-fiscal-month')), findsOneWidget);
      expect(find.textContaining('퇴사할 때 입사일 기준으로'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await _tap(tester, find.byKey(const ValueKey('gw-fiscal-month')));
      await tester.tap(find.text('3월 1일 시작').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('gw-leave-basis-confirm')));
      await tester.pumpAndSettle();
      expect(h.lastBody('PATCH', path), {
        'teamId': 'T1',
        'fiscalStartMonth': 3,
      });
      await tester.pump(const Duration(seconds: 3));

      // 연차 이월 일수.
      await _tap(tester, find.byKey(const ValueKey('gw-carry-days')));
      await tester.tap(find.text('5일까지').last);
      await tester.pumpAndSettle();
      expect(h.lastBody('PATCH', path), {
        'teamId': 'T1',
        'carryOverMaxDays': 5,
      });
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('gw-carry-run')))
            .onPressed,
        isNotNull,
      );
      await tester.pump(const Duration(seconds: 3));

      // 가산율 — 법정보다 낮으면 서버가 거절하고 그 까닭을 보인다, 고쳐서 저장, 5명 미만으로.
      await tester.enterText(
        find.byKey(const ValueKey('gw-pay-overtime')),
        '40',
      );
      await _tap(tester, find.byKey(const ValueKey('gw-pay-save')));
      expect(find.textContaining('법정 가산율(50%)보다 낮게'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.enterText(
        find.byKey(const ValueKey('gw-pay-overtime')),
        '75',
      );
      await tester.enterText(
        find.byKey(const ValueKey('gw-pay-holiday-over')),
        '150',
      );
      await _tap(tester, find.byKey(const ValueKey('gw-pay-save')));
      expect(h.lastBody('PATCH', path), {
        'teamId': 'T1',
        'payRates': {
          'overtime': 75,
          'night': 50,
          'holiday': 50,
          'holidayOver': 150,
          'smallBusiness': false,
        },
      });
      await tester.pump(const Duration(seconds: 3));
      await _tap(tester, find.byKey(const ValueKey('gw-pay-small-business')));
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('gw-pay-night')))
            .enabled,
        isFalse,
        reason: '5명 미만이면 가산율 칸을 쓰지 않는다',
      );
      await _tap(tester, find.byKey(const ValueKey('gw-pay-save')));
      expect(
        (h.lastBody('PATCH', path)['payRates'] as Map)['smallBusiness'],
        isTrue,
      );
      await tester.pump(const Duration(seconds: 3));

      // 사무실 위치 — 반경이 범위 밖이면 보내지 않는다, 저장, 지우기.
      await tester.enterText(
        find.byKey(const ValueKey('gw-office-lat')),
        '37.5665',
      );
      await tester.enterText(
        find.byKey(const ValueKey('gw-office-lng')),
        '126.978',
      );
      await tester.enterText(
        find.byKey(const ValueKey('gw-office-radius')),
        '20',
      );
      final before = h.called('PATCH', path).length;
      await _tap(tester, find.byKey(const ValueKey('gw-office-save')));
      expect(find.text('사무실 반경은 50~5000m로 정하세요.'), findsOneWidget);
      expect(h.called('PATCH', path), hasLength(before));
      await tester.pump(const Duration(seconds: 3));
      await tester.enterText(
        find.byKey(const ValueKey('gw-office-radius')),
        '300',
      );
      expect(find.byKey(const ValueKey('gw-office-clear')), findsNothing);
      await _tap(tester, find.byKey(const ValueKey('gw-office-save')));
      expect(h.lastBody('PATCH', path), {
        'teamId': 'T1',
        'officeLocation': {'lat': 37.5665, 'lng': 126.978, 'radius': 300},
      });
      expect(find.textContaining('반경 300m'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await _tap(tester, find.byKey(const ValueKey('gw-office-clear')));
      expect(h.lastBody('PATCH', path), {
        'teamId': 'T1',
        'officeLocation': null,
      });
      expect(find.textContaining('사무실 위치를 정하지 않았습니다'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));

      // 외근 위치 필수.
      await _tap(
        tester,
        find.byKey(const ValueKey('gw-require-field-location')),
      );
      expect(h.lastBody('PATCH', path), {
        'teamId': 'T1',
        'requireFieldLocation': true,
      });
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('연차 이월 — 미리 보고(넣을 사람·건너뛸 까닭) 확인하면 미리 본 사람만 실제로 넣는다', (
      tester,
    ) async {
      final h = _Harness();
      _optionsServer(h, carryDays: 3);
      h.routes['POST /api/groupware/leave/carry-over'] = (r) {
        final dryRun = (jsonDecode(r.body) as Map)['dryRun'] == true;
        return _json({
          'capDays': 3,
          'dryRun': dryRun,
          'applied': [
            {
              'userId': 'U-a',
              'name': '김가',
              'halfDays': 5,
              'from': '2025-05-10',
              'to': '2026-05-09',
            },
          ],
          'skipped': [
            {'userId': 'U-b', 'name': '이나', 'reason': '이번 기간에 이미 이월했습니다.'},
          ],
        });
      };
      await _pump(
        tester,
        GroupwareOptionsSection(api: h.api, changes: GroupwareChanges()),
      );
      const path = '/api/groupware/leave/carry-over';
      await _tap(tester, find.byKey(const ValueKey('gw-carry-run')));
      expect(h.lastBody('POST', path), {'teamId': 'T1', 'dryRun': true});
      expect(find.text('연차 이월 미리 보기'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('gw-carry-applied-U-a')),
          matching: find.text('+2.5일'),
        ),
        findsOneWidget,
      );
      expect(find.text('2025-05-10~2026-05-09 기간에서'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('gw-carry-skipped-U-b')),
          matching: find.text('이번 기간에 이미 이월했습니다.'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('gw-carry-confirm')));
      await tester.pumpAndSettle();
      expect(h.called('POST', path), hasLength(2));
      expect(h.lastBody('POST', path), {
        'teamId': 'T1',
        'dryRun': false,
        'userIds': ['U-a'],
      });
      expect(find.text('1명의 연차를 이월했습니다. (1명 건너뜀)'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));

      // 미리 보기에서 취소하면 넣지 않는다.
      await _tap(tester, find.byKey(const ValueKey('gw-carry-run')));
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(h.called('POST', path), hasLength(3));
      expect(h.lastBody('POST', path)['dryRun'], isTrue);
    });
  });

  group('유연근무 — 탄력·선택근무 정산 기간', () {
    testWidgets('기간 종류·시작일·개월을 보내고, 선택근무 정산은 선택근무·자율에만', (tester) async {
      final h = _Harness();
      h.routes['GET /api/groupware/schedules'] = (_) => _json([
        {'userId': 'U-a', 'name': '김가', 'schedule': null},
        {
          'userId': 'U-b',
          'name': '이나',
          'schedule': {
            'mode': 'free',
            'label': '자율 출퇴근',
            'periodType': 'select',
            'periodLabel': '선택근무 정산',
            'periodStart': '2026-10-01',
            'periodMonths': 3,
          },
        },
      ]);
      h.routes['PUT /api/groupware/schedules/U-a'] = (_) =>
          _json({'userId': 'U-a', 'name': '김가'});
      h.routes['PUT /api/groupware/schedules/U-b'] = (_) =>
          _json({'userId': 'U-b', 'name': '이나'});
      await _pump(tester, WorkSchedulesSection(api: h.api, ctx: _ctx()));
      expect(find.text('자율 출퇴근 · 선택근무 정산 3개월 2026-10-01부터'), findsOneWidget);

      // 시차출퇴근 — 선택근무 정산은 고를 수 없다, 탄력 2주는 시작일이 있어야.
      await _tap(tester, find.byKey(const ValueKey('gw-schedule-U-a')));
      await _tap(tester, find.byKey(const ValueKey('gw-schedule-period-type')));
      expect(find.text('탄력 3개월'), findsWidgets);
      expect(find.text('선택근무 정산'), findsNothing);
      await tester.tap(find.text('탄력 2주').last);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('gw-schedule-period-months')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('gw-schedule-save')));
      await tester.pumpAndSettle();
      expect(find.text('기간이 시작하는 날을 정하세요.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('gw-schedule-period-start')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(DatePickerDialog),
          matching: find.text('12'),
        ),
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('2026-10-12부터'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('gw-schedule-save')));
      await tester.pumpAndSettle();
      expect(h.lastBody('PUT', '/api/groupware/schedules/U-a'), {
        'teamId': 'T1',
        'mode': 'staggered',
        'start': '09:00',
        'end': '18:00',
        'periodType': 'flex2w',
        'periodStart': '2026-10-12',
      });

      // 선택근무(핵심 시간대) — 선택근무 정산 3개월.
      await _tap(tester, find.byKey(const ValueKey('gw-schedule-U-a')));
      await tester.tap(find.text('선택근무'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('gw-schedule-period-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('선택근무 정산').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('gw-schedule-period-months')),
          matching: find.text('3개월'),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('gw-schedule-period-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('gw-schedule-save')));
      await tester.pumpAndSettle();
      expect(h.lastBody('PUT', '/api/groupware/schedules/U-a'), {
        'teamId': 'T1',
        'mode': 'core',
        'coreStart': '10:00',
        'coreEnd': '15:00',
        'periodType': 'select',
        'periodStart': '2026-10-17',
        'periodMonths': 3,
      });

      // 선택근무 정산이던 사람을 시차출퇴근으로 바꾸면 기간은 주 단위로(보내지 않음 — 서버가 지운다).
      await _tap(tester, find.byKey(const ValueKey('gw-schedule-U-b')));
      expect(find.text('2026-10-01부터'), findsOneWidget);
      await tester.tap(find.text('시차출퇴근'));
      await tester.pumpAndSettle();
      expect(find.text('주 단위(주 52시간)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('gw-schedule-save')));
      await tester.pumpAndSettle();
      expect(h.lastBody('PUT', '/api/groupware/schedules/U-b'), {
        'teamId': 'T1',
        'mode': 'staggered',
        'start': '09:00',
        'end': '18:00',
      });
    });
  });

  testWidgets('주 52시간 — 사람마다 상한·기간 현황, 위에 지키기 방식', (tester) async {
    final h = _Harness();
    h.routes['GET /api/groupware/options'] = (_) =>
        _json({'overtimeGuard': 'block'});
    h.routes['GET /api/groupware/attendance/weekly'] = (_) => _json({
      'weekStart': '2026-10-12',
      'weekEnd': '2026-10-18',
      'overtimeGuard': 'block',
      'members': [
        {
          'userId': 'U-a',
          'name': '김가',
          'netMinutes': 3000,
          'status': 'ok',
          'weeklyLimitMinutes': 3600,
          'periodType': 'flex2w',
          'period': {
            'type': 'flex2w',
            'start': '2026-10-12',
            'end': '2026-10-26',
            'days': 14,
            'standardMinutes': 4800,
            'overtimeCapMinutes': 1440,
            'weeklyMaxMinutes': 3600,
            'netMinutes': 3000,
            'overtimeMinutes': 0,
            'weeks': [],
            'status': 'ok',
          },
        },
        {
          'userId': 'U-b',
          'name': '이나',
          'netMinutes': 3300,
          'status': 'over',
          'weeklyLimitMinutes': null,
          'periodType': 'select',
          'period': {
            'type': 'select',
            'start': '2026-10-01',
            'end': '2026-11-01',
            'standardMinutes': 10560,
            'overtimeCapMinutes': 3168,
            'netMinutes': 14000,
            'overtimeMinutes': 3440,
            'status': 'over',
          },
        },
        {'userId': 'U-c', 'name': '박다', 'netMinutes': 2900, 'status': 'warn'},
      ],
    });
    await _pump(tester, WeeklyHoursSection(api: h.api, ctx: _ctx()));
    expect(
      find.textContaining('주 52시간 지키기: 막기'),
      findsOneWidget,
      reason: '범위 설정의 지키기 방식',
    );
    expect(find.text('실근로 50시간 / 60시간'), findsOneWidget);
    expect(
      find.text('탄력 2주 10/12~10/25: 실근로 50시간 / 기준 80시간 · 연장 0시간(한도 24시간)'),
      findsOneWidget,
    );
    expect(find.textContaining('실근로 55시간 · 선택근무 — 기간 기준'), findsOneWidget);
    expect(find.text('정산 기간 한도 넘음'), findsOneWidget);
    final period = tester.widget<Text>(
      find.byKey(const ValueKey('gw-weekly-period-U-b')),
    );
    expect(
      period.style?.color,
      Theme.of(tester.element(find.byType(Scaffold))).colorScheme.error,
    );
    expect(find.text('실근로 48시간 20분 / 52시간'), findsOneWidget);
    expect(find.text('48시간 넘음'), findsOneWidget);
    expect(find.byKey(const ValueKey('gw-weekly-period-U-c')), findsNothing);
  });

  testWidgets('연차 촉진 — 보낸 통지마다 통지서 PDF 저장·인쇄 메뉴', (tester) async {
    final h = _Harness();
    h.routes['GET /api/groupware/leave/promotions'] = (_) => _json({
      'members': [
        {
          'userId': 'U-a',
          'name': '김가',
          'expiry': '2027-05-09',
          'firstYear': false,
          'firstStart': '2026-11-09',
          'firstEnd': '2026-11-18',
          'secondDeadline': '2027-03-09',
          'remainingHalfDays': 7.5,
          'stage': 'done',
          'notices': [_notice(id: 'P1', stage: 1), _notice(id: 'P2', stage: 2)],
        },
      ],
    });
    await _pump(
      tester,
      LeavePromotionSection(
        api: h.api,
        ctx: _ctx(),
        changes: GroupwareChanges(),
      ),
    );
    expect(find.byKey(const ValueKey('gw-notice-pdf-P1')), findsOneWidget);
    expect(find.byKey(const ValueKey('gw-notice-pdf-P2')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('gw-notice-pdf-P2')));
    await tester.pumpAndSettle();
    expect(find.text('2차 통지서 PDF로 저장'), findsOneWidget);
    expect(find.text('2차 통지서 인쇄'), findsOneWidget);
  });

  group('관리 탭 — 통상시급·가산 수당·이월 조정', () {
    void routes(_Harness h) {
      h.routes['GET /api/groupware/members'] = (_) => _json([
        {
          'id': 'U-a',
          'name': '김가',
          'username': 'a',
          'role': 'member',
          'hireDate': '2020-05-10',
          'grantedHalfDays': 34,
          'usedHalfDays': 6,
          'pendingHalfDays': 0,
          'remainingHalfDays': 28,
        },
        {
          'id': 'U-b',
          'name': '이나',
          'username': 'b',
          'role': 'member',
          'hireDate': '2021-03-02',
          'grantedHalfDays': 37.5,
          'usedHalfDays': 2,
          'pendingHalfDays': 0,
          'remainingHalfDays': 35.5,
          'hourlyWage': 10000,
        },
      ]);
      h.routes['GET /api/groupware/attendance/summary'] = (_) => _json({
        'month': '2026-10',
        'members': [
          {
            'userId': 'U-a',
            'name': '김가',
            'daysWorked': 12,
            'workedMinutes': 5760,
            'leaveHalfDays': 0,
          },
          {
            'userId': 'U-b',
            'name': '이나',
            'daysWorked': 10,
            'workedMinutes': 4800,
            'leaveHalfDays': 2.75,
            'allowance': {
              'wage': 10000,
              'overtimeMinutes': 120,
              'nightMinutes': 60,
              'overtimePay': 30000,
              'nightPay': 5000,
              'totalPay': 35000,
            },
          },
        ],
      });
      h.routes['PUT /api/groupware/members/U-a/wage'] = (_) =>
          _json({'userId': 'U-a', 'hourlyWage': 12000});
      h.routes['PUT /api/groupware/members/U-b/wage'] = (_) =>
          _json({'userId': 'U-b', 'hourlyWage': null});
      h.routes['GET /api/groupware/leave/balance'] = (_) => _json({
        'hireDate': '2021-03-02',
        'period': {'start': '2026-03-02', 'end': '2027-03-02', 'year': 5},
        'usedHalfDays': 2,
        'pendingHalfDays': 0,
        'adjustments': [
          {
            'id': 'A1',
            'kind': 'carry',
            'halfDays': 5,
            'reason': '이월 — 2025-03-02~2026-03-01에 남은 3일 중 2.5일',
            'createdByName': '관리자',
          },
          {
            'id': 'A2',
            'kind': 'manual',
            'halfDays': -1,
            'reason': '출근율 80% 미만',
            'createdByName': '관리자',
          },
        ],
      });
    }

    Future<void> pumpTab(WidgetTester tester, _Harness h) => _pump(
      tester,
      GroupwareAdminTab(
        api: h.api,
        ctx: _ctx(),
        changes: GroupwareChanges(),
        session: h.session,
      ),
      scroll: false,
      height: 6000,
    );

    testWidgets('통상시급 정하기·지우기, 총 가산 수당 칸', (tester) async {
      final h = _Harness();
      routes(h);
      await pumpTab(tester, h);
      final summaryB = find.byKey(const ValueKey('gw-summary-allowance-U-b'));
      await tester.scrollUntilVisible(
        summaryB,
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<Text>(summaryB).data, '35,000원');
      expect(find.text('총 가산 수당'), findsOneWidget, reason: '시급을 정한 사람만');
      expect(
        find.byKey(const ValueKey('gw-summary-allowance-U-a')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('gw-summary-allowance-note')),
        findsOneWidget,
      );
      expect(find.textContaining('휴가 1일 3시간'), findsOneWidget);

      final wageA = find.byKey(const ValueKey('gw-member-wage-U-a'));
      await tester.scrollUntilVisible(
        wageA,
        -400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(of: wageA, matching: find.text('시급')),
        findsOneWidget,
      );
      expect(find.text('시급 10,000원'), findsOneWidget);
      await _tap(tester, wageA);
      expect(find.byKey(const ValueKey('gw-wage-clear')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('gw-wage-input')), '0');
      await tester.tap(find.byKey(const ValueKey('gw-wage-save')));
      await tester.pumpAndSettle();
      expect(find.text('통상시급을 원 단위 숫자로 넣으세요.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('gw-wage-input')),
        '12,000',
      );
      await tester.tap(find.byKey(const ValueKey('gw-wage-save')));
      await tester.pumpAndSettle();
      expect(h.lastBody('PUT', '/api/groupware/members/U-a/wage'), {
        'teamId': 'T1',
        'hourlyWage': 12000,
      });
      await tester.pump(const Duration(seconds: 3));

      await _tap(tester, find.byKey(const ValueKey('gw-member-wage-U-b')));
      expect(find.text('10000'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('gw-wage-clear')));
      await tester.pumpAndSettle();
      expect(h.lastBody('PUT', '/api/groupware/members/U-b/wage'), {
        'teamId': 'T1',
        'hourlyWage': null,
      });
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('연차 조정 창 — 이번 기간 조정 내역에 이월을 표시', (tester) async {
      final h = _Harness();
      routes(h);
      await pumpTab(tester, h);
      final adjust = find.byKey(const ValueKey('gw-adjust-U-b'));
      await tester.scrollUntilVisible(
        adjust,
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await _tap(tester, adjust);
      expect(
        h
            .called('GET', '/api/groupware/leave/balance')
            .single
            .url
            .queryParameters['userId'],
        'U-b',
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('gw-adjustment-A1')),
          matching: find.text('이월'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('gw-adjustment-A2')),
          matching: find.text('조정'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('+2.5일 · 이월 — 2025-03-02'), findsOneWidget);
      expect(find.textContaining('-0.5일 · 출근율 80% 미만'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('연차 촉진 서면 통지서 PDF', () {
    test('1차(촉진)·2차(시기 지정) 모두 한글 글꼴로 만든다', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      for (final stage in [1, 2]) {
        final notice = LeavePromotion.fromJson(
          _notice(id: 'P$stage', stage: stage),
        );
        expect(
          leaveNoticeTitle(notice),
          stage == 1 ? '연차 사용 촉진 통지서' : '연차 사용 시기 지정 통지서',
        );
        final bytes = await buildLeaveNoticePdf(
          notice: notice,
          employeeName: '김가',
          scopeLabel: '본사',
        );
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        expect(bytes.length, greaterThan(1000));
      }
      // 덧붙인 말·확인 시각이 없어도 만든다.
      final bare = LeavePromotion.fromJson({
        ..._notice(id: 'P3', stage: 2),
        'message': null,
        'sentAt': null,
        'sentByName': null,
      });
      final bytes = await buildLeaveNoticePdf(
        notice: bare,
        employeeName: '이나',
        scopeLabel: '회사 전체',
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });
  });
}
