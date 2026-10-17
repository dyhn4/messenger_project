// 결재 고급(앱) — 결재선 역할(결재·합의·전결)과 단계 번호, 문서 번호·대결·전결 표시와 결재란, 승인 창의 전결·대결 안내, PDF 만들기,
// 대결 맡기기, 서명 지우기, 관리 탭 결재 통계, 도장 글자 배치. 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/groupware.dart';
import 'package:client/screens/groupware/approval_forms.dart';
import 'package:client/screens/groupware/approval_print.dart';
import 'package:client/screens/groupware/approval_settings.dart';
import 'package:client/screens/groupware/approval_tab.dart';
import 'package:client/screens/groupware/groupware_screen.dart'
    show GroupwareChanges;
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

final _ctx = GroupwareContext.fromJson({
  'scope': 'team',
  'teamId': 'T1',
  'isManager': true,
  'today': '2026-10-17',
  'pendingForMe': 1,
  'leaveTypes': [
    {'key': 'annual', 'label': '연차', 'deducts': true, 'half': false},
  ],
  'expenseCategories': ['식대'],
  'limits': {'approversMax': 10, 'ccMax': 10, 'attachmentsMax': 5},
});

Map<String, dynamic> _step(
  String id,
  int order,
  String name,
  String status, {
  int? stage,
  String role = 'approve',
  String? actedBy,
  int? decided,
}) => {
  'id': id,
  'order': order,
  'stage': stage ?? order,
  'role': role,
  'approverId': 'U-$name',
  'approverName': name,
  'status': status,
  'actedByName': actedBy,
  'decidedAt': decided,
};

Map<String, dynamic> _doc({
  bool myTurn = true,
  String? actingFor,
  bool finalForMe = false,
  List<Map<String, dynamic>>? steps,
}) => {
  'id': 'D1',
  'kind': 'leave',
  'docNumber': '휴가-2026-0012',
  'title': '연차 신청 (11/2, 1일)',
  'payload': {
    'leaveType': 'annual',
    'startDate': '2026-11-02',
    'endDate': '2026-11-02',
    'halfDays': 2,
  },
  'attachments': [],
  'status': 'pending',
  'authorId': 'U-me',
  'authorName': '홍길동',
  'createdAt': DateTime(2026, 10, 17, 9).millisecondsSinceEpoch,
  'steps':
      steps ??
      [
        _step(
          's1',
          0,
          '팀장',
          'approved',
          actedBy: '부팀장',
          decided: DateTime(2026, 10, 17, 10).millisecondsSinceEpoch,
        ),
        _step('s2', 1, '인사', 'pending', stage: 1, role: 'agree'),
        _step('s3', 2, '재무', 'pending', stage: 1, role: 'agree'),
        _step('s4', 3, '본부장', 'waiting', stage: 2, role: 'final'),
        _step('s5', 4, '대표', 'waiting', stage: 3),
      ],
  'myTurn': myTurn,
  'actingFor': actingFor,
  'finalForMe': finalForMe,
};

class _Harness {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{};
  late final Session session;
  _Harness() {
    session = Session(
      notifications: NotificationService(),
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
    session.name = '홍길동';
  }

  GroupwareApi get api => GroupwareApi(session.api!, teamId: 'T1');
  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
  Map<String, dynamic> bodyOf(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;
}

void _view(WidgetTester tester) {
  tester.view.physicalSize = const Size(1100, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  group('모양 읽기', () {
    test('칸 역할·단계·생략·대결, 문서 번호·대결·전결', () {
      final doc = ApprovalDocument.fromJson(
        _doc(actingFor: '본부장', finalForMe: true),
      );
      expect(doc.docNumber, '휴가-2026-0012');
      expect(doc.actingFor, '본부장');
      expect(doc.finalForMe, isTrue);
      expect(doc.steps.map((s) => s.role), [
        LineRole.approve,
        LineRole.agree,
        LineRole.agree,
        LineRole.finalApprove,
        LineRole.approve,
      ]);
      expect(doc.steps.map((s) => s.stage), [0, 1, 1, 2, 3]);
      expect(doc.steps.first.actedByName, '부팀장');
      expect(
        ApprovalStepStatus.fromWire('skipped'),
        ApprovalStepStatus.skipped,
      );
      // 예전 칸(단계 없음)은 순서가 곧 단계.
      expect(
        ApprovalStep.fromJson({
          'id': 'x',
          'order': 3,
          'approverName': 'a',
          'status': 'waiting',
        }).stage,
        3,
      );
      expect(LineRole.approve.next, LineRole.agree);
      expect(LineRole.finalApprove.next, LineRole.approve);
      expect(
        rolesToJson({
          'a': LineRole.approve,
          'b': LineRole.agree,
          'c': LineRole.finalApprove,
        }),
        {'b': 'agree', 'c': 'final'},
      );
      expect(rolesFromJson({'b': 'agree'}), {'b': LineRole.agree});
    });

    test('통계·평균 시간 글자·대결 기간·도장 글자', () {
      final stats = ApprovalStats.fromJson({
        'from': '2026-10-01',
        'to': '2026-10-17',
        'totals': {
          'total': 3,
          'approved': 1,
          'rejected': 1,
          'pending': 1,
          'avgHours': 7,
        },
        'byKind': [
          {'label': '휴가', 'total': 2, 'avgHours': 7},
        ],
        'byApprover': [
          {
            'userId': 'U-lead',
            'name': '팀장',
            'decided': 2,
            'proxied': 1,
            'waiting': 1,
            'avgHours': 3.5,
          },
        ],
      });
      expect(stats.totals.total, 3);
      expect(stats.byApprover.single.proxied, 1);
      expect(hoursText(null), '—');
      expect(hoursText(3.5), '3.5시간');
      expect(hoursText(50), '2일 2시간');
      const d = ApprovalDelegation(
        id: 'x',
        userId: 'a',
        userName: 'A',
        delegateId: 'b',
        delegateName: 'B',
        startDate: '2026-10-15',
        endDate: '2026-10-18',
      );
      expect(d.activeOn('2026-10-17'), isTrue);
      expect(d.activeOn('2026-10-19'), isFalse);
      expect(stampGlyphs('홍길동'), ['홍', '길', '동', '인']);
      expect(stampGlyphs('김수'), ['김', '수', '인']);
      expect(stampGlyphs('남궁민수'), ['남', '궁', '민', '수']);
      expect(stampGlyphs('알렉산드라'), ['알렉산드라']);
    });
  });

  test('결재선 — 역할을 눌러 바꾸고, 이어진 합의는 같은 단계 번호, 전결은 한 명', () {
    final c = ApprovalLineController();
    addTearDown(c.dispose);
    c.setLine(['a', 'b', 'c', 'd'], const [], {'b': LineRole.agree});
    expect(c.stageNumbers, [1, 2, 3, 4]);
    c.cycleRole('c'); // 결재 → 합의
    expect(c.roleOf('c'), LineRole.agree);
    expect(c.stageNumbers, [1, 2, 2, 3], reason: '이어진 합의');
    c.cycleRole('d');
    c.cycleRole('d'); // → 전결
    expect(c.roleOf('d'), LineRole.finalApprove);
    c.cycleRole('a');
    c.cycleRole('a'); // a도 전결로 가면 d는 결재로
    expect(c.roleOf('a'), LineRole.finalApprove);
    expect(c.roleOf('d'), LineRole.approve);
    c.removeApprover('b');
    expect(c.roles.containsKey('b'), isFalse);
    c.cycleRole('a'); // 전결 → 결재
    expect(c.roles.containsKey('a'), isFalse);
  });

  testWidgets('결재선 고르기 — 역할 칩을 눌러 합의로, 저장하면 역할까지', (tester) async {
    final h = _Harness();
    h.routes['GET /api/groupware/candidates'] = (_) => _json([
      {'id': 'U-a', 'name': '팀장', 'username': 'a'},
      {'id': 'U-b', 'name': '인사', 'username': 'b'},
    ]);
    h.routes['GET /api/groupware/approval-lines'] = (_) => _json({
      'lines': [],
      'suggested': {
        'approverIds': ['U-a', 'U-b'],
        'ccIds': [],
        'source': 'saved',
        'roles': {'U-b': 'final'},
      },
    });
    h.routes['POST /api/groupware/approval-lines'] = (r) =>
        _json({'id': 'L1', 'name': '합의', ...h.bodyOf(r)}, status: 201);
    final controller = ApprovalLineController();
    addTearDown(controller.dispose);
    _view(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ApprovalLinePicker(
            api: h.api,
            ctx: _ctx,
            controller: controller,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      controller.roleOf('U-b'),
      LineRole.finalApprove,
      reason: '저장한 결재선의 역할을 채운다',
    );
    expect(find.text('전결'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('approval-line-role-U-a')));
    await tester.pump();
    expect(controller.roleOf('U-a'), LineRole.agree);
    expect(find.text('합의'), findsOneWidget);
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '합의');
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    expect(
      h.bodyOf(
        h.called('POST', '/api/groupware/approval-lines').single,
      )['roles'],
      {'U-a': 'agree', 'U-b': 'final'},
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('상세 — 문서 번호·결재란(대결·합의·전결·생략)·대결 안내, 전결 승인 창의 안내', (tester) async {
    final h = _Harness();
    h.routes['GET /api/groupware/documents/D1'] = (_) =>
        _json(_doc(actingFor: '본부장', finalForMe: true));
    h.routes['POST /api/groupware/documents/D1/approve'] = (_) => _json({
      ..._doc(myTurn: false),
      'status': 'approved',
      'steps': [
        _step('s1', 0, '팀장', 'approved'),
        _step(
          's4',
          1,
          '본부장',
          'approved',
          stage: 1,
          role: 'final',
          actedBy: '홍길동',
          decided: DateTime(2026, 10, 17, 11).millisecondsSinceEpoch,
        ),
        _step('s5', 2, '대표', 'skipped', stage: 2),
      ],
    });
    h.routes['GET /api/groupware/context'] = (_) =>
        _json({'scope': 'team', 'today': '2026-10-17', 'pendingForMe': 0});
    _view(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ApprovalDetailDialog(
            api: h.api,
            ctx: _ctx,
            session: h.session,
            documentId: 'D1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('휴가 · 홍길동 · 휴가-2026-0012'), findsOneWidget);
    expect(find.byKey(const ValueKey('approval-acting-for')), findsOneWidget);
    // 결재란 — 칸마다 역할·단계.
    expect(find.byKey(const ValueKey('approval-stamp-0')), findsOneWidget);
    expect(find.text('합의 2'), findsNWidgets(2));
    expect(find.text('전결 3'), findsOneWidget);
    expect(find.text('대결 부팀장'), findsWidgets);
    expect(find.text('팀장 · 결재 · 승인'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('approval-approve')));
    await tester.pumpAndSettle();
    expect(find.text('전결 승인'), findsWidgets);
    expect(find.textContaining('남은 결재는 생략'), findsOneWidget);
    expect(find.textContaining('본부장님 대신(대결)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('approval-comment-ok')));
    await tester.pumpAndSettle();
    expect(
      h.called('POST', '/api/groupware/documents/D1/approve'),
      hasLength(1),
    );
    expect(find.textContaining('결재가 끝났습니다'), findsOneWidget);
    expect(find.text('생략'), findsWidgets, reason: '전결로 생략된 칸');
    await tester.pump(const Duration(seconds: 3));
  });

  test('PDF — 한글 글꼴로 결재란·내용·이력을 담은 PDF', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final doc = ApprovalDocument.fromJson({
      ..._doc(),
      'kind': 'purchase',
      'payload': {
        'templateName': '구매 요청',
        'fields': [
          {'key': 'items', 'label': '구매 품목', 'type': 'items'},
          {'key': 'reason', 'label': '구매 사유', 'type': 'textarea'},
        ],
        'values': {
          'items': {
            'rows': [
              {'name': '모니터', 'qty': 2, 'unitPrice': 250000, 'amount': 500000},
            ],
            'total': 500000,
          },
          'reason': '신규 입사자',
        },
      },
    });
    final content = approvalContentOf(doc, _ctx);
    expect(content.items.single['name'], '모니터');
    expect(content.itemsTotal, 500000);
    expect(content.longTexts.single, ('구매 사유', '신규 입사자'));
    final leave = approvalContentOf(ApprovalDocument.fromJson(_doc()), _ctx);
    expect(leave.rows.first, ('종류', '연차'));
    final bytes = await buildApprovalPdf(doc, _ctx);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(1000));
  });

  testWidgets('대결 맡기기 — 사람·기간·사유를 보내고 목록에 보인다', (tester) async {
    final h = _Harness();
    var list = <Map<String, dynamic>>[];
    h.routes['GET /api/groupware/delegations'] = (_) => _json(list);
    h.routes['GET /api/groupware/candidates'] = (_) => _json([
      {'id': 'U-dep', 'name': '부팀장', 'username': 'dep'},
    ]);
    h.routes['POST /api/groupware/delegations'] = (r) {
      final b = h.bodyOf(r);
      final row = {
        'id': 'G1',
        'userId': 'U-me',
        'userName': '홍길동',
        'delegateId': b['delegateId'],
        'delegateName': '부팀장',
        'startDate': b['startDate'],
        'endDate': b['endDate'],
        'reason': b['reason'],
      };
      list = [row];
      return _json(row, status: 201);
    };
    final changes = GroupwareChanges();
    addTearDown(changes.dispose);
    _view(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () => showDelegationsDialog(
                c,
                api: h.api,
                ctx: _ctx,
                session: h.session,
                changes: changes,
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(find.text('없음'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('delegation-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delegation-save')));
    await tester.pumpAndSettle();
    expect(find.text('대신 결재할 사람을 고르세요.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('delegation-delegate')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('부팀장 (dep)').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('delegation-reason')),
      '출장',
    );
    await tester.tap(find.byKey(const ValueKey('delegation-save')));
    await tester.pumpAndSettle();
    expect(h.bodyOf(h.called('POST', '/api/groupware/delegations').single), {
      'teamId': 'T1',
      'delegateId': 'U-dep',
      'startDate': '2026-10-17',
      'endDate': '2026-10-17',
      'reason': '출장',
    });
    expect(find.text('부팀장님이 대신'), findsOneWidget);
    expect(find.textContaining('지금 효력'), findsOneWidget);
    expect(changes.value, 1, reason: '결재함·뱃지를 다시 받게');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('내 서명 — 없으면 안내, 지우기는 DELETE', (tester) async {
    final h = _Harness();
    var sig = 'https://test.local/files/sig';
    h.routes['GET /api/groupware/context'] = (_) => _json({
      'scope': 'team',
      'today': '2026-10-17',
      'pendingForMe': 0,
      'signatureUrl': sig,
    });
    h.routes['DELETE /api/groupware/signature'] = (_) {
      sig = '';
      return _json({'ok': true});
    };
    _view(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () =>
                  showSignatureDialog(c, api: h.api, session: h.session),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('signature-current')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('signature-clear')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(h.called('DELETE', '/api/groupware/signature'), hasLength(1));
    expect(find.byKey(const ValueKey('signature-none')), findsOneWidget);
    expect(find.byKey(const ValueKey('signature-stamp')), findsOneWidget);
    expect(find.byKey(const ValueKey('signature-draw')), findsOneWidget);
  });

  testWidgets('관리 — 결재 통계(이번 달, 이전 달로 넘김)', (tester) async {
    final h = _Harness();
    h.routes['GET /api/groupware/stats'] = (r) => _json({
      'from': r.url.queryParameters['from'],
      'to': r.url.queryParameters['to'],
      'totals': {
        'total': 3,
        'approved': 1,
        'rejected': 1,
        'pending': 1,
        'avgHours': 7,
      },
      'byKind': [
        {
          'label': '휴가',
          'total': 2,
          'approved': 1,
          'rejected': 1,
          'avgHours': 7,
        },
      ],
      'byApprover': [
        {
          'userId': 'U-lead',
          'name': '팀장',
          'decided': 2,
          'rejected': 1,
          'proxied': 1,
          'waiting': 1,
          'avgHours': 3.5,
        },
      ],
    });
    _view(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ApprovalStatsSection(api: h.api, ctx: _ctx),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final first = h
        .called('GET', '/api/groupware/stats')
        .single
        .url
        .queryParameters;
    expect(first['from'], '2026-10-01');
    expect(first['to'], '2026-10-17', reason: '이번 달은 오늘까지');
    expect(find.textContaining('올린 결재 3건'), findsOneWidget);
    expect(find.byKey(const ValueKey('gw-stats-kind-휴가')), findsOneWidget);
    expect(find.text('3.5시간'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('gw-stats-next')))
          .onPressed,
      isNull,
      reason: '앞으로는 못 감',
    );
    await tester.tap(find.byTooltip('이전 달'));
    await tester.pumpAndSettle();
    final prev = h
        .called('GET', '/api/groupware/stats')
        .last
        .url
        .queryParameters;
    expect(prev['from'], '2026-09-01');
    expect(prev['to'], '2026-09-30');
  });
}
