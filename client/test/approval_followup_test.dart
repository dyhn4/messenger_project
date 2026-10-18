// 결재 후속(앱) — 후결(맨 뒤로·단계 번호·첫 결재자는 안 됨), 전결 규정 안내와 손 전결 건너뛰기, 합의 "반대 의견으로 진행", 후결 확인,
// 전자서명 검증 창, 보관함 검색(글·기간)·더 보기, 반대 알림, 결재란의 반대·후결과 인쇄의 전자서명. 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/groupware.dart';
import 'package:client/screens/groupware/approval_forms.dart';
import 'package:client/screens/groupware/approval_notifications.dart';
import 'package:client/screens/groupware/approval_print.dart';
import 'package:client/screens/groupware/approval_tab.dart';
import 'package:client/screens/groupware/groupware_screen.dart'
    show ApprovalDocumentTile, GroupwareChanges;
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
  'isManager': false,
  'today': '2026-10-18',
  'pendingForMe': 0,
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
  bool sealed = false,
  String? comment,
}) => {
  'id': id,
  'order': order,
  'stage': stage ?? order,
  'role': role,
  'approverId': 'U-$name',
  'approverName': name,
  'status': status,
  'sealed': sealed,
  'comment': comment,
  'decidedAt': status == 'approved' || status == 'disagreed'
      ? DateTime(2026, 10, 18, 10).millisecondsSinceEpoch
      : null,
};

/// 지출 문서 하나 — [status]·칸들·내 차례 여부와 반대 가능·후결 표시를 바꿔 쓴다.
Map<String, dynamic> _doc({
  String id = 'D1',
  String status = 'pending',
  bool myTurn = true,
  bool canDisagree = false,
  bool postForMe = false,
  List<Map<String, dynamic>>? steps,
  Map<String, dynamic>? finalRule,
  int? createdAt,
}) => {
  'id': id,
  'kind': 'expense',
  'docNumber': '지출-2026-0007',
  'title': '팀 회식비 $id',
  'payload': {
    'amount': 120000,
    'category': '식대',
    'spentOn': '2026-10-17',
    'finalRule': ?finalRule,
  },
  'attachments': [],
  'status': status,
  'authorId': 'U-writer',
  'authorName': '김기안',
  'createdAt': createdAt ?? DateTime(2026, 10, 18, 9).millisecondsSinceEpoch,
  'steps':
      steps ??
      [
        _step('s1', 0, '팀장', 'approved', sealed: true),
        _step('s2', 1, '홍길동', 'pending', role: 'agree'),
        _step('s3', 2, '본부장', 'waiting', stage: 2),
      ],
  'myTurn': myTurn,
  'canDisagree': canDisagree,
  'postForMe': postForMe,
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
    routes['GET /api/groupware/context'] = (_) =>
        _json({'scope': 'team', 'today': '2026-10-18', 'pendingForMe': 0});
  }

  GroupwareApi get api => GroupwareApi(session.api!, teamId: 'T1');
  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
  Map<String, dynamic> bodyOf(http.Request r) =>
      r.body.isEmpty ? const {} : jsonDecode(r.body) as Map<String, dynamic>;
}

void _view(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Finder _key(String k) => find.byKey(ValueKey(k));

Future<void> _pumpDetail(WidgetTester tester, _Harness h) async {
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
}

void main() {
  group('결재선 — 후결', () {
    test('후결이 되면 맨 뒤로(다른 후결 뒤), 이어진 후결은 같은 단계, 새 결재자는 후결 앞에', () {
      final c = ApprovalLineController();
      addTearDown(c.dispose);
      c.setLine(['a', 'b', 'c'], const []);
      // a: 결재 → 합의 → 전결 → 후결 — 후결이 되며 맨 끝으로.
      for (var i = 0; i < 3; i++) {
        expect(c.cycleRole('a'), isFalse);
      }
      expect(c.roleOf('a'), LineRole.post);
      expect(c.approverIds, ['b', 'c', 'a']);
      expect(c.stageNumbers, [1, 2, 3]);
      // c도 후결로 — a 뒤로, 이어진 후결은 한 단계.
      for (var i = 0; i < 3; i++) {
        c.cycleRole('c');
      }
      expect(c.approverIds, ['b', 'a', 'c']);
      expect(c.stageNumbers, [1, 2, 2], reason: '이어진 후결은 같은 단계');
      // 새 결재자는 후결 칸들 앞에.
      c.addApprover('d');
      expect(c.approverIds, ['b', 'd', 'a', 'c']);
      expect(c.stageNumbers, [1, 2, 3, 3]);
      // 후결과 후결 아닌 칸의 경계는 화살표로 못 넘는다.
      expect(c.canMove(1, 1), isFalse);
      expect(c.canMove(2, -1), isFalse);
      expect(c.canMove(2, 1), isTrue);
      c.moveApprover(1, 1);
      expect(c.approverIds, ['b', 'd', 'a', 'c'], reason: '그대로');
      // 후결에서 결재로 — 맨 앞 후결 칸이라 자리는 그대로.
      c.cycleRole('a');
      expect(c.roleOf('a'), LineRole.approve);
      expect(c.approverIds, ['b', 'd', 'a', 'c']);
      // 가운데 후결이 결재로 돌아가면 후결 칸들 앞으로.
      c.setLine(
        ['b', 'p1', 'p2', 'p3'],
        const [],
        const {'p1': LineRole.post, 'p2': LineRole.post, 'p3': LineRole.post},
      );
      c.cycleRole('p2');
      expect(c.approverIds, ['b', 'p2', 'p1', 'p3']);
    });

    test('후결 앞에 결재할 사람이 없으면 후결은 건너뛴다, 전결 규정이면 전결도 건너뛴다', () {
      final c = ApprovalLineController();
      addTearDown(c.dispose);
      c.setLine(['x'], const []);
      c.cycleRole('x');
      c.cycleRole('x');
      expect(c.roleOf('x'), LineRole.finalApprove);
      expect(c.cycleRole('x'), isTrue, reason: '혼자면 후결이 될 수 없다');
      expect(c.roleOf('x'), LineRole.approve);

      c.setLine(['p', 'q'], const []);
      c.cycleRole('p', allowFinal: false); // 결재 → 합의
      expect(c.roleOf('p'), LineRole.agree);
      c.cycleRole('p', allowFinal: false); // 합의 → (전결 건너뜀) → 후결
      expect(c.roleOf('p'), LineRole.post);
      expect(c.approverIds, ['q', 'p']);
      expect(c.roles.values, isNot(contains(LineRole.finalApprove)));

      // 저장한 결재선에 후결이 가운데 있어도 맨 뒤로 모은다.
      c.setLine(['m', 'n', 'o'], const [], const {'m': LineRole.post});
      expect(c.approverIds, ['n', 'o', 'm']);
    });

    testWidgets('전결 규정 안내 — 역할 칩은 전결을 건너뛰고, 혼자 남은 결재자는 후결이 안 된다', (
      tester,
    ) async {
      final h = _Harness();
      h.routes['GET /api/groupware/candidates'] = (_) => _json([
        {'id': 'U-a', 'name': '대리', 'username': 'a'},
        {'id': 'U-b', 'name': '팀장', 'username': 'b'},
      ]);
      h.routes['GET /api/groupware/approval-lines'] = (_) => _json({
        'lines': [],
        'suggested': {
          'approverIds': ['U-a', 'U-b'],
          'ccIds': [],
          'source': 'org',
          'roles': {'U-b': 'final'},
          'finalUserId': 'U-b',
        },
        'finalRule': {
          'id': 'R1',
          'kind': 'expense',
          'minAmount': 1000000,
          'positionLabel': '팀장',
        },
      });
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
              kind: 'expense',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final hint = tester.widget<Text>(
        find.descendant(
          of: _key('approval-line-final-rule-hint'),
          matching: find.byType(Text),
        ),
      );
      expect(hint.data, contains('팀장 이상의 첫 결재자가 전결합니다 (1,000,000원 이상 문서)'));
      expect(hint.data, contains('전결은 고를 수 없습니다'));
      expect(
        controller.roleOf('U-b'),
        LineRole.finalApprove,
        reason: '규정으로 정한 사람',
      );

      // 대리: 결재 → 합의 → (전결 건너뜀) → 후결 — 맨 뒤로.
      await tester.tap(_key('approval-line-role-U-a'));
      await tester.pump();
      expect(controller.roleOf('U-a'), LineRole.agree);
      await tester.tap(_key('approval-line-role-U-a'));
      await tester.pump();
      expect(controller.roleOf('U-a'), LineRole.post);
      expect(controller.approverIds, ['U-b', 'U-a']);
      expect(find.text('후결'), findsOneWidget);

      // 팀장: 전결 → 후결이어야 하지만 앞에 결재할 사람이 없다 → 결재로, 안내.
      await tester.tap(_key('approval-line-role-U-b'));
      await tester.pump();
      expect(controller.roleOf('U-b'), LineRole.approve);
      expect(find.text('후결 앞에 결재할 사람이 한 명 이상 있어야 합니다.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('상세', () {
    testWidgets('합의 차례 — "반대 의견으로 진행"은 의견을 꼭 받아 /disagree로 보낸다', (
      tester,
    ) async {
      final h = _Harness();
      h.routes['GET /api/groupware/documents/D1'] = (_) =>
          _json(_doc(canDisagree: true));
      h.routes['POST /api/groupware/documents/D1/disagree'] = (_) => _json(
        _doc(
          myTurn: false,
          steps: [
            _step('s1', 0, '팀장', 'approved', sealed: true),
            _step(
              's2',
              1,
              '홍길동',
              'disagreed',
              role: 'agree',
              sealed: true,
              comment: '예산 초과',
            ),
            _step('s3', 2, '본부장', 'pending', stage: 2),
          ],
        ),
      );
      await _pumpDetail(tester, h);
      expect(_key('approval-reject'), findsOneWidget);
      expect(_key('approval-step-sealed-0'), findsOneWidget, reason: '서명된 칸');
      expect(_key('approval-step-sealed-1'), findsNothing);

      await tester.tap(_key('approval-disagree'));
      await tester.pumpAndSettle();
      expect(find.text('반대 의견으로 진행'), findsWidgets);
      expect(
        find.text('반대 의견을 남기고 결재를 다음으로 넘깁니다. 막으려면 반려하세요.'),
        findsOneWidget,
      );
      // 비우고 누르면 막는다.
      await tester.tap(_key('approval-comment-ok'));
      await tester.pumpAndSettle();
      expect(h.called('POST', '/api/groupware/documents/D1/disagree'), isEmpty);
      await tester.enterText(_key('approval-comment'), '예산 초과');
      await tester.tap(_key('approval-comment-ok'));
      await tester.pumpAndSettle();
      final sent = h.called('POST', '/api/groupware/documents/D1/disagree');
      expect(sent, hasLength(1));
      expect(h.bodyOf(sent.single), {'comment': '예산 초과'});
      expect(find.text('반대 의견을 남겼습니다. 결재는 계속 진행됩니다.'), findsOneWidget);
      expect(find.text('홍길동 · 합의 · 반대'), findsOneWidget);
      expect(_key('approval-disagree'), findsNothing, reason: '이제 내 차례가 아니다');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('후결 차례 — 반려 없이 "후결 확인", 의견은 골라서', (tester) async {
      final h = _Harness();
      final steps = [
        _step('s1', 0, '팀장', 'approved', sealed: true),
        _step('s2', 1, '홍길동', 'pending', stage: 1, role: 'post'),
      ];
      h.routes['GET /api/groupware/documents/D1'] = (_) =>
          _json(_doc(status: 'approved', postForMe: true, steps: steps));
      h.routes['POST /api/groupware/documents/D1/approve'] = (_) => _json(
        _doc(
          status: 'approved',
          myTurn: false,
          steps: [
            steps[0],
            _step('s2', 1, '홍길동', 'approved', stage: 1, role: 'post'),
          ],
        ),
      );
      await _pumpDetail(tester, h);
      expect(_key('approval-reject'), findsNothing);
      expect(_key('approval-disagree'), findsNothing);
      expect(
        find.descendant(
          of: _key('approval-approve'),
          matching: find.text('후결 확인'),
        ),
        findsOneWidget,
      );
      expect(find.text('홍길동 · 후결 · 결재 차례'), findsOneWidget);
      expect(find.text('후결 2'), findsOneWidget, reason: '결재란 머리');
      expect(find.text('확인 차례'), findsOneWidget);

      await tester.tap(_key('approval-approve'));
      await tester.pumpAndSettle();
      expect(find.text('이미 승인된 결재입니다. 확인한 기록과 의견이 남습니다.'), findsOneWidget);
      await tester.tap(_key('approval-comment-ok'));
      await tester.pumpAndSettle();
      final sent = h.called('POST', '/api/groupware/documents/D1/approve');
      expect(sent, hasLength(1));
      expect(h.bodyOf(sent.single), isEmpty, reason: '의견 없이');
      expect(find.text('후결을 확인했습니다.'), findsOneWidget);
      expect(find.text('확인'), findsOneWidget, reason: '확인한 후결 칸의 도장');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('전결 규정 줄 — 찾았으면 직책·금액, 못 찾았으면 끝까지 결재', (tester) async {
      final h = _Harness();
      var applied = true;
      h.routes['GET /api/groupware/documents/D1'] = (_) => _json(
        _doc(
          myTurn: false,
          finalRule: {
            'positionLabel': '부장',
            'minAmount': 500000,
            'applied': applied,
          },
        ),
      );
      await _pumpDetail(tester, h);
      expect(find.text('부장 이상 전결 (500,000원 이상 문서)'), findsOneWidget);
      applied = false;
      await tester.pumpWidget(const SizedBox());
      await _pumpDetail(tester, h);
      expect(find.text('부장 이상 전결 — 결재선에 해당하는 사람이 없어 끝까지 결재'), findsOneWidget);
    });

    testWidgets('전자서명 검증 — 맞음·바뀜·서명 없음과 지문', (tester) async {
      final h = _Harness();
      h.routes['GET /api/groupware/documents/D1'] = (_) =>
          _json(_doc(myTurn: false));
      var verify = <String, dynamic>{};
      h.routes['GET /api/groupware/documents/D1/verify'] = (_) => _json(verify);
      const digest =
          '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';
      Map<String, dynamic> step(String name, int order, String result) => {
        'id': 's$order',
        'order': order,
        'approverName': name,
        'status': 'approved',
        'result': result,
      };
      await _pumpDetail(tester, h);

      Future<void> open() async {
        await tester.tap(_key('approval-verify'));
        await tester.pumpAndSettle();
      }

      Future<void> close() async {
        await tester.tap(find.text('닫기').last);
        await tester.pumpAndSettle();
      }

      verify = {
        'digest': digest,
        'fingerprint': 'AB12-CD34-EF56-7890',
        'ok': true,
        'steps': [step('팀장', 0, 'valid'), step('인사', 1, 'unsealed')],
      };
      await open();
      expect(find.text('위변조 없음 — 모든 결재가 서명한 그대로입니다.'), findsOneWidget);
      expect(find.text('맞음'), findsOneWidget);
      expect(find.text('서명 없음(이전 결재)'), findsOneWidget);
      expect(
        tester.widget<SelectableText>(_key('approval-verify-digest')).data,
        digest,
      );
      expect(
        tester.widget<SelectableText>(_key('approval-verify-fingerprint')).data,
        'AB12-CD34-EF56-7890',
      );
      await close();

      verify = {
        'digest': digest,
        'fingerprint': 'AB12',
        'ok': false,
        'steps': [
          step('팀장', 0, 'invalid'),
          step('인사', 1, 'signatureChanged'),
          step('재무', 2, 'signatureMissing'),
        ],
      };
      await open();
      final summary = tester.widget<Text>(_key('approval-verify-summary'));
      expect(summary.data, '바뀐 곳이 있습니다');
      expect(
        summary.style?.color,
        Theme.of(
          tester.element(_key('approval-verify-summary')),
        ).colorScheme.error,
      );
      expect(find.text('내용 또는 결정 기록이 바뀜'), findsOneWidget);
      expect(find.text('서명 그림 파일이 바뀜'), findsOneWidget);
      expect(find.text('서명 그림 파일이 없음'), findsOneWidget);
      await close();

      verify = {
        'digest': digest,
        'fingerprint': 'AB12',
        'ok': false,
        'steps': [step('팀장', 0, 'unsealed')],
      };
      await open();
      expect(find.text('검증할 전자서명이 없습니다(이 기능 전에 결정한 결재).'), findsOneWidget);
      await close();
    });
  });

  group('보관함', () {
    Future<void> pumpTab(WidgetTester tester, _Harness h) async {
      _view(tester);
      final changes = GroupwareChanges();
      addTearDown(changes.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ApprovalTab(
              api: h.api,
              ctx: _ctx,
              changes: changes,
              session: h.session,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    List<Map<String, String>> listQueries(_Harness h) => [
      for (final r in h.called('GET', '/api/groupware/documents'))
        {...r.url.queryParameters}..remove('teamId'),
    ];

    testWidgets('글·기간으로 찾으면 box=archive&q=&from=&to=, 비면 "찾는 문서 없음"', (
      tester,
    ) async {
      final h = _Harness();
      h.routes['GET /api/groupware/documents'] = (_) => _json([]);
      await pumpTab(tester, h);
      expect(_key('approval-search'), findsNothing, reason: '다른 함은 돋보기로 연다');
      await tester.tap(_key('approval-box-archive'));
      await tester.pumpAndSettle();
      expect(listQueries(h).last, {'box': 'archive'});
      expect(find.text('찾는 결재 문서가 없습니다.'), findsOneWidget);

      await tester.enterText(_key('approval-search'), '회식');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(listQueries(h).last, {'box': 'archive', 'q': '회식'});

      final today = dateKeyOf(DateTime.now());
      await tester.tap(_key('approval-search-from'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(_key('approval-search-to'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(listQueries(h).last, {
        'box': 'archive',
        'q': '회식',
        'from': today,
        'to': today,
      });
      expect(find.text(today), findsNWidgets(2));

      // 상태 거르기 — 보관함에는 "진행 중"이 없다.
      await tester.tap(_key('approval-search-status'));
      await tester.pumpAndSettle();
      expect(find.text('진행 중'), findsNothing);
      await tester.tap(find.text('반려').last);
      await tester.pumpAndSettle();
      expect(listQueries(h).last['status'], 'rejected');

      // 조건을 건 채 다른 함으로 — 같은 조건으로 거르고 검색 줄이 남는다.
      await tester.tap(_key('approval-box-mine'));
      await tester.pumpAndSettle();
      expect(listQueries(h).last, {
        'box': 'mine',
        'q': '회식',
        'from': today,
        'to': today,
        'status': 'rejected',
      });
      expect(_key('approval-search'), findsOneWidget);
      // 돋보기를 닫으면 조건을 지우고 다시 받는다.
      await tester.tap(_key('approval-search-toggle'));
      await tester.pumpAndSettle();
      expect(listQueries(h).last, {'box': 'mine'});
      expect(_key('approval-search'), findsNothing);
    });

    testWidgets('50건이 오면 "더 보기" — 마지막 문서보다 먼저 올린 것(before)', (tester) async {
      final h = _Harness();
      final base = DateTime(2026, 10, 18, 9).millisecondsSinceEpoch;
      h.routes['GET /api/groupware/documents'] = (r) {
        final before = r.url.queryParameters['before'];
        if (before == null) {
          return _json([
            for (var i = 0; i < 50; i++)
              _doc(
                id: 'A$i',
                status: 'approved',
                myTurn: false,
                createdAt: base - i * 60000,
              ),
          ]);
        }
        return _json([
          _doc(id: 'B0', status: 'approved', myTurn: false, createdAt: 1000),
        ]);
      };
      await pumpTab(tester, h);
      await tester.tap(_key('approval-box-archive'));
      await tester.pumpAndSettle();
      // 위의 함 고르기 줄도 가로 스크롤이라 목록의 스크롤을 집는다.
      final listScroll = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        _key('approval-more'),
        400,
        scrollable: listScroll,
      );
      await tester.tap(_key('approval-more'));
      await tester.pumpAndSettle();
      expect(listQueries(h).last, {
        'box': 'archive',
        'before': '${base - 49 * 60000}',
      });
      await tester.scrollUntilVisible(
        find.text('팀 회식비 B0'),
        400,
        scrollable: listScroll,
      );
      expect(find.text('팀 회식비 B0'), findsOneWidget);
      expect(_key('approval-more'), findsNothing, reason: '1건만 와서 끝');
    });
  });

  group('목록·알림·결재란·인쇄', () {
    testWidgets('후결 차례 표시, 반대 알림', (tester) async {
      final doc = ApprovalDocument.fromJson(
        _doc(
          status: 'approved',
          postForMe: true,
          steps: [
            _step('s1', 0, '팀장', 'approved'),
            _step('s2', 1, '홍길동', 'pending', role: 'post'),
          ],
        ),
      );
      final n = ApprovalNotification.fromJson({
        'id': 'N1',
        'documentId': 'D1',
        'kind': 'disagreed',
        'title': '합의 반대 의견',
        'body': '인사님이 반대 의견을 남겼습니다',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      });
      expect(n.kind, ApprovalNotificationKind.disagreed);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ApprovalDocumentTile(doc: doc, ctx: _ctx, onTap: () {}),
                ApprovalNotificationTile(notification: n, onTap: () {}),
              ],
            ),
          ),
        ),
      );
      expect(_key('approval-doc-post-D1'), findsOneWidget);
      expect(find.textContaining('홍길동 후결 차례'), findsOneWidget);
      expect(find.text('합의 반대 의견'), findsOneWidget);
      expect(find.byIcon(Icons.record_voice_over_outlined), findsOneWidget);
      expect(
        approvalNotificationLook(
          ApprovalNotificationKind.disagreed,
          const ColorScheme.light(),
        ).color,
        Colors.deepOrange,
      );
    });

    test('도장 글자·칸 순서(후결은 맨 뒤), 검증 글, 전자서명을 담은 PDF', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final doc = ApprovalDocument.fromJson(
        _doc(
          status: 'approved',
          myTurn: false,
          steps: [
            _step('s9', 3, '감사', 'approved', stage: 3, role: 'post'),
            _step('s1', 0, '팀장', 'approved', sealed: true),
            _step('s2', 1, '인사', 'disagreed', role: 'agree', sealed: true),
            _step('s3', 2, '본부장', 'approved', stage: 2),
          ],
        ),
      );
      expect(stampOrderOf(doc).map((s) => s.approverName), [
        '팀장',
        '인사',
        '본부장',
        '감사',
      ]);
      expect(stampTextOf(doc.steps[0]), '확인');
      expect(stampTextOf(doc.steps[2]), '반대');
      expect(sealResultText('signatureChanged'), '서명 그림 파일이 바뀜');
      final verification = ApprovalVerification.fromJson({
        'digest': 'abc',
        'fingerprint': 'AB12',
        'ok': true,
        'steps': [
          {
            'id': 's1',
            'order': 0,
            'approverName': '팀장',
            'status': 'approved',
            'result': 'valid',
          },
        ],
      });
      expect(sealSummaryText(verification), '위변조 없음 — 모든 결재가 서명한 그대로입니다.');
      final bytes = await buildApprovalPdf(
        doc,
        _ctx,
        verification: verification,
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });
  });
}
