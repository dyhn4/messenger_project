import 'dart:convert';

import 'package:client/models/calendar.dart';
import 'package:client/models/groupware.dart';
import 'package:client/screens/groupware/approval_forms.dart';
import 'package:client/screens/groupware/approval_notifications.dart';
import 'package:client/screens/groupware/approval_tab.dart'
    show ApprovalDetailDialog;
import 'package:client/screens/groupware/groupware_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/groupware_api.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/menu_entries.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 그룹웨어(전자결재·연차·출퇴근) 화면 — 서버 API(server/src/groupware.js)를 가짜 HTTP로 흉내 내고 화면 흐름을 본다.

/// 띄운 결재 알림을 기록만 하는 알림 서비스(플러그인을 부르지 않는다).
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

const _team = 'T1';
const _me = 'U-me';
const _lead = 'U-lead';
const _boss = 'U-boss';

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _context({
  bool manager = false,
  int pending = 0,
  String? hireDate = '2020-05-10',
}) => {
  'scope': 'team',
  'scopeSetting': 'org',
  'teamId': _team,
  'teamName': '본사',
  'isManager': manager,
  'workStart': 540,
  'workEnd': 1080,
  'today': '2026-10-17',
  'hireDate': hireDate,
  'pendingForMe': pending,
  'leaveTypes': [
    {'key': 'annual', 'label': '연차', 'deducts': true, 'half': false},
    {'key': 'half_am', 'label': '오전 반차', 'deducts': true, 'half': true},
    {'key': 'sick', 'label': '병가', 'deducts': false, 'half': false},
  ],
  'expenseCategories': ['교통비', '식대'],
  'limits': {'approversMax': 5, 'ccMax': 10, 'attachmentsMax': 5},
  'inLan': true,
};

Map<String, dynamic> _doc({
  String id = 'D1',
  String status = 'pending',
  bool myTurn = false,
  bool canWithdraw = false,
  bool canCancel = false,
  List<Map<String, dynamic>>? steps,
}) => {
  'id': id,
  'kind': 'leave',
  'title': '연차 신청 (11/2~11/3, 2일)',
  'body': '가족 여행',
  'payload': {
    'leaveType': 'annual',
    'startDate': '2026-11-02',
    'endDate': '2026-11-03',
    'halfDays': 4,
  },
  'attachments': [],
  'status': status,
  'authorId': _me,
  'authorName': '홍길동',
  'createdAt': DateTime(2026, 10, 17, 9).millisecondsSinceEpoch,
  'steps':
      steps ??
      [
        {
          'id': 's1',
          'order': 0,
          'approverId': _lead,
          'approverName': '팀장',
          'status': 'pending',
        },
        {
          'id': 's2',
          'order': 1,
          'approverId': _boss,
          'approverName': '본부장',
          'status': 'waiting',
        },
      ],
  'myTurn': myTurn,
  'canWithdraw': canWithdraw,
  'canCancel': canCancel,
};

final _balance = {
  'hireDate': '2020-05-10',
  'period': {'year': 6, 'start': '2026-05-10', 'end': '2027-05-10'},
  'statutoryHalfDays': 34,
  'adjustmentHalfDays': 0,
  'grantedHalfDays': 34,
  'usedHalfDays': 6,
  'pendingHalfDays': 4,
  'remainingHalfDays': 28,
  'adjustments': [],
};

class _Harness {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{};
  late final Session session;

  _Harness({bool manager = false, int pending = 0}) {
    routes['GET /api/groupware/context'] = (_) =>
        _json(_context(manager: manager, pending: pending));
    routes['GET /api/groupware/documents'] = (_) => _json([]);
    routes['GET /api/groupware/leave/balance'] = (_) => _json(_balance);
    routes['GET /api/groupware/leave/calendar'] = (_) => _json([]);
    routes['GET /api/groupware/attendance/today'] = (_) => _json({
      'today': '2026-10-17',
      'record': null,
      'openRecord': null,
      'canClockIn': true,
      'canClockOut': false,
      'inLan': true,
      'workStart': 540,
      'workEnd': 1080,
    });
    routes['GET /api/groupware/attendance/month'] = (_) => _json({
      'month': '2026-10',
      'days': [
        {'date': '2026-10-16', 'holiday': null, 'leave': null, 'record': null},
        {'date': '2026-10-17', 'holiday': null, 'leave': null, 'record': null},
      ],
      'summary': {
        'daysWorked': 0,
        'workedMinutes': 0,
        'late': 0,
        'earlyLeave': 0,
        'missingClockOut': 0,
        'absent': 1,
        'leaveHalfDays': 0,
      },
    });
    routes['GET /api/groupware/candidates'] = (_) => _json([
      {'id': _lead, 'name': '팀장', 'username': 'lead'},
      {'id': _boss, 'name': '본부장', 'username': 'boss'},
    ]);
    routes['GET /api/groupware/approval-lines'] = (_) => _json({
      'lines': [
        {
          'id': 'L1',
          'name': '팀장→본부장',
          'approverIds': [_lead, _boss],
          'ccIds': [],
        },
      ],
      'suggested': {
        'approverIds': [_lead, _boss],
        'ccIds': [],
        'source': 'saved',
      },
    });
    routes['GET /api/groupware/members'] = (_) => _json([
      {
        'id': _me,
        'name': '홍길동',
        'username': 'me',
        'role': 'member',
        'hireDate': '2020-05-10',
        'grantedHalfDays': 34,
        'usedHalfDays': 6,
        'pendingHalfDays': 4,
        'remainingHalfDays': 28,
      },
      {
        'id': 'U-new',
        'name': '신입',
        'username': 'new',
        'role': 'member',
        'hireDate': null,
      },
    ]);
    routes['GET /api/groupware/attendance/summary'] = (_) => _json({
      'month': '2026-10',
      'members': [
        {
          'userId': _me,
          'name': '홍길동',
          'daysWorked': 12,
          'workedMinutes': 5760,
          'late': 1,
          'earlyLeave': 0,
          'missingClockOut': 0,
          'absent': 0,
          'leaveHalfDays': 2,
        },
      ],
    });
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
            : http.Response(
                '<html>Cannot</html>',
                404,
                headers: {'content-type': 'text/html'},
              );
      }),
    );
    session.token = 't';
    session.userId = _me;
  }

  GroupwareApi get api => GroupwareApi(session.api!, teamId: _team);

  Map<String, dynamic> lastBody(String path) =>
      jsonDecode(requests.lastWhere((r) => r.url.path == path).body)
          as Map<String, dynamic>;
}

Future<void> _pump(WidgetTester tester, _Harness h) async {
  tester.view.physicalSize = const Size(1100, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: GroupwareScreen(session: h.session, api: h.api),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(Tab, label));
  await tester.pumpAndSettle();
}

void main() {
  group('모델', () {
    test('반일 단위·금액·시각 글자', () {
      expect(halfDaysText(5), '2.5일');
      expect(halfDaysText(30), '15일');
      expect(wonText(1234567), '1,234,567원');
      expect(wonText(900), '900원');
      expect(minutesText(545), '09:05');
      expect(shortDateText('2026-11-02'), '11/2');
    });

    test('문서 요약 — 휴가·지출·근태 수정', () {
      final ctx = GroupwareContext.fromJson(_context());
      final leave = ApprovalDocument.fromJson(_doc());
      expect(leave.summary(ctx), '연차 · 11/2~11/3 · 2일');
      expect(leave.currentStep?.approverName, '팀장');
      final expense = ApprovalDocument.fromJson({
        ..._doc(),
        'kind': 'expense',
        'payload': {'amount': 12000, 'category': '식대', 'spentOn': '2026-10-16'},
      });
      expect(expense.summary(ctx), '식대 · 12,000원');
      final fix = ApprovalDocument.fromJson({
        ..._doc(),
        'kind': 'attendance',
        'payload': {
          'workDate': '2026-10-16',
          'clockIn': '09:00',
          'clockOut': null,
        },
      });
      expect(fix.summary(ctx), '10/16 · 출근 09:00');
    });

    test('입사일이 없으면 연차를 모른다', () {
      expect(LeaveBalance.fromJson(_balance).known, isTrue);
      expect(
        LeaveBalance.fromJson({'hireDate': null, 'usedHalfDays': 0}).known,
        isFalse,
      );
    });

    test('HH:MM 검사', () {
      expect(isHmText('09:30'), isTrue);
      expect(isHmText('24:00'), isFalse);
      expect(isHmText('9:30'), isFalse);
    });
  });

  testWidgets('관리 탭은 관리자에게만', (tester) async {
    final member = _Harness();
    await _pump(tester, member);
    expect(find.widgetWithText(Tab, '관리'), findsNothing);
    expect(find.text('그룹웨어 · 본사'), findsOneWidget);

    // 같은 화면을 다시 띄우면 상태가 재사용되니 한 번 비운다.
    await tester.pumpWidget(const SizedBox());
    final manager = _Harness(manager: true);
    await _pump(tester, manager);
    expect(find.widgetWithText(Tab, '관리'), findsOneWidget);
  });

  testWidgets('결재할 문서 → 상세 → 의견을 달아 승인', (tester) async {
    final h = _Harness(pending: 1);
    h.routes['GET /api/groupware/documents'] = (_) =>
        _json([_doc(myTurn: true)]);
    h.routes['GET /api/groupware/documents/D1'] = (_) =>
        _json(_doc(myTurn: true));
    h.routes['POST /api/groupware/documents/D1/approve'] = (_) => _json(
      _doc(
        steps: [
          {
            'id': 's1',
            'order': 0,
            'approverId': _lead,
            'approverName': '팀장',
            'status': 'approved',
            'comment': '좋습니다',
          },
          {
            'id': 's2',
            'order': 1,
            'approverId': _boss,
            'approverName': '본부장',
            'status': 'pending',
          },
        ],
      ),
    );
    await _pump(tester, h);
    expect(find.text('결재 1'), findsOneWidget, reason: '결재할 문서 수가 탭에 보인다');
    expect(find.byKey(const ValueKey('approval-doc-D1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('approval-doc-D1')));
    await tester.pumpAndSettle();
    expect(find.text('가족 여행'), findsOneWidget);
    expect(find.text('팀장 · 결재 차례'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('approval-approve')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('approval-comment')),
      '좋습니다',
    );
    await tester.tap(find.byKey(const ValueKey('approval-comment-ok')));
    await tester.pumpAndSettle();
    expect(h.lastBody('/api/groupware/documents/D1/approve'), {
      'comment': '좋습니다',
    });
    expect(find.text('팀장 · 승인'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('approval-approve')),
      findsNothing,
      reason: '이제 내 차례가 아니다',
    );
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('반려는 사유 없이 못 한다', (tester) async {
    final h = _Harness(pending: 1);
    h.routes['GET /api/groupware/documents'] = (_) =>
        _json([_doc(myTurn: true)]);
    h.routes['GET /api/groupware/documents/D1'] = (_) =>
        _json(_doc(myTurn: true));
    await _pump(tester, h);
    await tester.tap(find.byKey(const ValueKey('approval-doc-D1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('approval-reject')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('approval-comment-ok')));
    await tester.pumpAndSettle();
    expect(find.text('반려 사유를 쓰세요.'), findsOneWidget);
    expect(h.requests.where((r) => r.url.path.endsWith('/reject')), isEmpty);
  });

  testWidgets('휴가 탭 — 연차 현황, 휴가 신청 창은 추천 결재선을 채운다', (tester) async {
    final h = _Harness();
    await _pump(tester, h);
    await _openTab(tester, '휴가');
    expect(find.text('17일'), findsOneWidget, reason: '생긴 연차 34반일');
    expect(find.text('14일'), findsOneWidget, reason: '남은 연차 28반일');
    expect(find.textContaining('근속 6년'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('leave-request')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('남은 연차 12일'),
      findsOneWidget,
      reason: '결재 중 2일을 뺀 값',
    );
    expect(
      find.byKey(const ValueKey('approval-line-approver-$_lead')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('approval-line-approver-$_boss')),
      findsOneWidget,
    );
    // 날짜를 안 고르면 올리지 않는다.
    await tester.tap(find.byKey(const ValueKey('approval-request-submit')));
    await tester.pumpAndSettle();
    expect(find.text('휴가 날짜를 고르세요.'), findsOneWidget);
    expect(h.requests.where((r) => r.method == 'POST'), isEmpty);
  });

  testWidgets('결재선 — 순서 바꾸기·빼기·결재자 추가', (tester) async {
    final h = _Harness();
    final controller = ApprovalLineController();
    addTearDown(controller.dispose);
    final ctx = GroupwareContext.fromJson(_context());
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ApprovalLinePicker(
            api: h.api,
            ctx: ctx,
            controller: controller,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.approverIds, [_lead, _boss]);
    controller.moveApprover(1, -1);
    expect(controller.approverIds, [_boss, _lead]);
    controller.removeApprover(_lead);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('approval-line-add-approver')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('person-$_lead')));
    await tester.pumpAndSettle();
    expect(controller.approverIds, [_boss, _lead]);
    controller.toggleCc(_lead);
    expect(controller.ccIds, isEmpty, reason: '결재자는 참조자로 넣지 않는다');
  });

  testWidgets('출퇴근 — 출근 단추로 기록한다', (tester) async {
    final h = _Harness();
    h.routes['POST /api/groupware/attendance/clock-in'] = (_) => _json({
      'id': 'R1',
      'workDate': '2026-10-17',
      'clockInAt': DateTime(2026, 10, 17, 8, 55).millisecondsSinceEpoch,
      'clockInLan': true,
      'late': false,
    }, status: 201);
    await _pump(tester, h);
    await _openTab(tester, '출퇴근');
    expect(find.text('사내 와이파이'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('attendance-clock-out')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('attendance-clock-in')));
    await tester.pumpAndSettle();
    expect(
      h.requests.any((r) => r.url.path == '/api/groupware/attendance/clock-in'),
      isTrue,
    );
    expect(h.lastBody('/api/groupware/attendance/clock-in')['teamId'], _team);
    expect(find.textContaining('08:55 출근했습니다'), findsOneWidget);
    expect(find.text('결근 1'), findsOneWidget);
    expect(find.text('수정 요청'), findsNWidgets(2));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('관리 — 입사일 미등록 표시, 근무 시간 저장, 월별 요약', (tester) async {
    final h = _Harness(manager: true);
    h.routes['PATCH /api/groupware/settings'] = (_) =>
        _json({'workStart': 510, 'workEnd': 1050});
    await _pump(tester, h);
    await _openTab(tester, '관리');
    expect(find.text('입사일 미등록 — 눌러서 등록'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('gw-adjust-U-new')),
      findsNothing,
      reason: '입사일이 없으면 연차 조정 단추가 없다',
    );
    expect(find.byKey(const ValueKey('gw-adjust-$_me')), findsOneWidget);
    expect(find.textContaining('출근 12일 · 96시간 · 지각 1'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('gw-work-start')),
      '08:30',
    );
    await tester.enterText(find.byKey(const ValueKey('gw-work-end')), '17:30');
    await tester.tap(find.byKey(const ValueKey('gw-work-save')));
    await tester.pumpAndSettle();
    expect(h.lastBody('/api/groupware/settings'), {
      'teamId': _team,
      'workStart': '08:30',
      'workEnd': '17:30',
    });
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('예전 서버(그룹웨어 없음)면 업데이트하라고 한다', (tester) async {
    final h = _Harness();
    h.routes.remove('GET /api/groupware/context');
    await _pump(tester, h);
    expect(find.textContaining('그룹웨어를 지원하지 않습니다'), findsOneWidget);
  });

  test('메뉴에 그룹웨어가 있고 숫자는 결재할 문서 수', () {
    final entry = menuEntries.firstWhere((e) => e.key == 'groupware');
    final h = _Harness();
    h.session.groupwarePending = 3;
    expect(entry.badge!(h.session), 3);
    expect(entry.section, MenuSection.tools);
  });

  test('캘린더 내장 "팀 휴가"', () {
    expect(CalendarInfo.leaves().isBuiltin, isTrue);
    expect(CalendarInfo.leaves().name, '팀 휴가');
    expect(kBuiltinCalendarIds, contains(kLeavesCalendarId));
  });

  group('결재 알림을 눌렀을 때', () {
    test('payload — 문서 id와 팀 id(회사 전체 범위면 비움)를 왕복한다', () {
      expect(NotificationService.approvalPayload('D1', 'T1'), 'approval:D1:T1');
      expect(NotificationService.approvalPayload('D1', null), 'approval:D1:');
      final team = NotificationService.parseApprovalPayload('approval:D1:T1')!;
      expect(team.documentId, 'D1');
      expect(team.teamId, 'T1');
      final server = NotificationService.parseApprovalPayload('approval:D1:')!;
      expect(server.teamId, isNull);
      // 옛 서버의 푸시(문서 id 없음)는 빈 문서 id — 앱은 알림 센터 결재 탭을 연다.
      expect(
        NotificationService.parseApprovalPayload('approval::')!.documentId,
        '',
      );
      expect(NotificationService.parseApprovalPayload('project:P1'), isNull);
      expect(NotificationService.parseApprovalPayload('room-1'), isNull);
    });

    testWidgets('문서 상세를 그 팀 범위로 열고, 그 문서의 결재 알림을 읽음으로', (tester) async {
      final h = _Harness();
      h.routes['GET /api/groupware/documents/D1'] = (_) =>
          _json(_doc(myTurn: true));
      h.routes['POST /api/groupware/notifications/read'] = (_) =>
          _json({'unreadCount': 0});
      h.routes['GET /api/groupware/notifications'] = (_) =>
          _json({'items': [], 'unreadCount': 0});
      h.session.approvalUnread = 1;
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              ctx = context;
              return const Scaffold();
            },
          ),
        ),
      );
      final opened = openApprovalDocument(
        ctx,
        h.session,
        documentId: 'D1',
        teamId: 'T9',
        markRead: true,
      );
      await tester.pumpAndSettle();
      expect(find.byType(ApprovalDetailDialog), findsOneWidget);
      final context = h.requests.firstWhere(
        (r) => r.url.path == '/api/groupware/context',
      );
      expect(context.url.queryParameters['teamId'], 'T9');
      expect(h.lastBody('/api/groupware/notifications/read'), {
        'documentId': 'D1',
      });
      expect(h.session.approvalUnread, 0);
      Navigator.of(tester.element(find.byType(ApprovalDetailDialog))).pop();
      await tester.pumpAndSettle();
      expect(await opened, isTrue);
    });

    testWidgets('범위를 못 받으면 onError로 알리고 false', (tester) async {
      final h = _Harness();
      h.routes['GET /api/groupware/context'] = (_) =>
          _json({'error': '이 팀의 멤버가 아닙니다.'}, status: 403);
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              ctx = context;
              return const Scaffold();
            },
          ),
        ),
      );
      final errors = <String>[];
      final opened = openApprovalDocument(
        ctx,
        h.session,
        documentId: 'D1',
        teamId: 'T9',
        onError: errors.add,
      );
      await tester.pumpAndSettle();
      expect(await opened, isFalse);
      expect(find.byType(ApprovalDetailDialog), findsNothing);
      expect(errors.single, contains('이 팀의 멤버가 아닙니다.'));
    });

    test('앱이 켜져 있을 때 소켓으로 온 결재 알림은 직접 띄우고 배지를 맞춘다', () {
      final notifications = _RecordingNotifications();
      final session = Session(
        notifications: notifications,
        settings: AppSettings(),
      );
      session.handleApprovalNotification({
        'notification': {
          'id': 'n1',
          'documentId': 'D1',
          'teamId': null,
          'kind': 'request',
          'title': '결재 요청',
          'body': '홍길동 — 연차 신청',
        },
        'unreadCount': 3,
      });
      expect(session.approvalUnread, 3);
      expect(notifications.shown.single.documentId, 'D1');
      expect(notifications.shown.single.teamId, isNull);
      expect(notifications.shown.single.title, '결재 요청');
      session.handleApprovalNotificationSync(0);
      expect(session.approvalUnread, 0);
    });

    test('둘째 창(알림 끔)에서는 띄우지 않고 배지만 맞춘다', () {
      final notifications = _RecordingNotifications();
      final session = Session(
        notifications: notifications,
        settings: AppSettings(),
        suppressNotifications: true,
      );
      session.handleApprovalNotification({
        'notification': {'id': 'n1', 'documentId': 'D1', 'title': '결재 요청'},
        'unreadCount': 1,
      });
      expect(session.approvalUnread, 1);
      expect(notifications.shown, isEmpty);
    });
  });
}
