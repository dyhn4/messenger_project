// 정산 연결(앱) — 승인된 구매 요청·출장 신청의 "정산하기"(살아 있는 정산이 없을 때만), 정산 지출 창(정산 대상 띠·예산으로 미리 채운
// 금액·내용·예산과의 차이·settlesId), 원래 결재의 정산 상태 줄(정산 안 함·결재 중·정산됨·반려 뒤 다시), 지출 결재의 정산 대상·예산·차이,
// 결재함의 "정산 안 됨" 거르기(?unsettled=1). 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/groupware.dart';
import 'package:client/screens/groupware/approval_forms.dart'
    show settleDiffText, showExpenseRequestDialog;
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

const _lead = 'U-lead';
const _purchaseTitle = '구매 요청 — 모니터 외 1건 (530,000원)';

GroupwareContext _ctx({bool manager = true}) => GroupwareContext.fromJson({
  'scope': 'team',
  'teamId': 'T1',
  'teamName': '본사',
  'isManager': manager,
  'workStart': 540,
  'workEnd': 1080,
  'today': '2026-10-17',
  'pendingForMe': 0,
  'leaveTypes': [
    {'key': 'annual', 'label': '연차', 'deducts': true, 'half': false},
  ],
  'expenseCategories': ['식대', '출장비'],
  'limits': {'approversMax': 5, 'ccMax': 10, 'attachmentsMax': 5},
});

const _steps = [
  {
    'id': 'S1',
    'order': 1,
    'approverId': _lead,
    'approverName': '팀장',
    'status': 'approved',
  },
];

/// 승인된 구매 요청(예산 = 품목 합계 530,000원).
Map<String, dynamic> _purchase({
  String status = 'approved',
  bool canSettle = false,
  Map<String, dynamic>? settlement,
}) => {
  'id': 'D-p',
  'kind': 'purchase',
  'docNumber': '구매-2026-0003',
  'title': _purchaseTitle,
  'payload': {
    'templateName': '구매 요청',
    'fields': [
      {'key': 'reason', 'label': '구매 사유', 'type': 'textarea'},
    ],
    'values': {
      'items': {'rows': [], 'total': 530000},
      'reason': '신규 입사자 자리',
    },
    'total': 530000,
    'itemCount': 2,
  },
  'attachments': [],
  'status': status,
  'authorId': 'U-me',
  'authorName': '홍길동',
  'createdAt': DateTime(2026, 10, 10, 9).millisecondsSinceEpoch,
  'steps': _steps,
  'canSettle': canSettle,
  'settlement': settlement,
};

/// 위 구매 요청을 정산하는 지출 결재(600,000원 — 예산보다 70,000원 많이 씀).
Map<String, dynamic> _expense({int amount = 600000, int? budget = 530000}) => {
  'id': 'D-e',
  'kind': 'expense',
  'docNumber': '지출-2026-0010',
  'title': '모니터 정산',
  'payload': {
    'amount': amount,
    'category': '식대',
    'spentOn': '2026-10-16',
    'settles': {
      'id': 'D-p',
      'kind': 'purchase',
      'title': _purchaseTitle,
      'docNumber': '구매-2026-0003',
      'budget': budget,
    },
  },
  'attachments': [],
  'status': 'pending',
  'authorId': 'U-me',
  'authorName': '홍길동',
  'createdAt': DateTime(2026, 10, 17, 9).millisecondsSinceEpoch,
  'steps': [
    {
      'id': 'S2',
      'order': 1,
      'approverId': _lead,
      'approverName': '팀장',
      'status': 'pending',
    },
  ],
};

class _Harness {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{};
  late final Session session;

  /// 상세에 내려 줄 구매 요청 — 테스트가 바꿔 끼운다(정산을 올린 뒤 다시 받을 때 등).
  Map<String, dynamic> purchase = _purchase(canSettle: true);
  _Harness() {
    routes['GET /api/groupware/documents'] = (_) => _json([]);
    routes['GET /api/groupware/candidates'] = (_) => _json([
      {'id': _lead, 'name': '팀장', 'username': 'lead'},
    ]);
    routes['GET /api/groupware/approval-lines'] = (_) => _json({
      'lines': [],
      'suggested': {
        'approverIds': [_lead],
        'ccIds': [],
        'source': 'org',
      },
    });
    routes['POST /api/groupware/documents'] = (r) {
      // 서버처럼 — 정산을 올리면 원래 결재에는 결재 중인 정산이 붙고 더는 정산하기를 못 누른다.
      purchase = _purchase(
        settlement: {
          'id': 'D-e',
          'docNumber': '지출-2026-0010',
          'title': '모니터 정산',
          'status': 'pending',
          'amount': (jsonDecode(r.body) as Map)['amount'],
        },
      );
      return _json(_expense(), status: 201);
    };
    routes['GET /api/groupware/documents/D-p'] = (_) => _json(purchase);
    routes['GET /api/groupware/documents/D-e'] = (_) => _json(_expense());
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
  Map<String, dynamic> bodyOf(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;
}

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pumpDetail(
  WidgetTester tester,
  _Harness h, {
  String id = 'D-p',
}) async {
  _bigView(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ApprovalDetailDialog(
          key: UniqueKey(),
          api: h.api,
          ctx: _ctx(),
          session: h.session,
          documentId: id,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// "정산" 줄 안의 글자들.
Finder _inSettlement(String text) => find.descendant(
  of: find.byKey(const ValueKey('approval-settlement')),
  matching: find.text(text),
);

void main() {
  test('모양 읽기 — 정산·정산 대상·예산·차이 문구', () {
    final p = ApprovalDocument.fromJson(
      _purchase(
        canSettle: true,
        settlement: {
          'id': 'D-e',
          'title': '모니터 정산',
          'status': 'approved',
          'amount': 500000,
        },
      ),
    );
    expect(p.canSettle, isTrue);
    expect(p.settlement!.status, ApprovalStatus.approved);
    expect(p.settlement!.amount, 500000);
    expect(settleBudgetOf(p), 530000);
    final e = ApprovalDocument.fromJson(_expense());
    expect(e.settles!.id, 'D-p');
    expect(e.settles!.kind, ApprovalKind.purchase);
    expect(e.settles!.budget, 530000);
    expect(settleDiffText(70000), '예산보다 70,000원 많습니다');
    expect(settleDiffText(-30000), '예산보다 30,000원 적습니다');
    expect(settleDiffText(0), '예산과 같습니다');
  });

  group('원래 결재(구매·출장)의 정산', () {
    testWidgets('정산할 수 있으면 "정산 안 함"과 정산하기 단추', (tester) async {
      final h = _Harness();
      await _pumpDetail(tester, h);
      expect(find.byKey(const ValueKey('approval-settle')), findsOneWidget);
      expect(_inSettlement('정산 안 함'), findsOneWidget);
    });

    testWidgets('결재 중인 정산이 있으면 단추가 없고, 번호·금액·차이를 보이며 누르면 그 지출 결재를 연다', (
      tester,
    ) async {
      final h = _Harness()
        ..purchase = _purchase(
          settlement: {
            'id': 'D-e',
            'docNumber': '지출-2026-0010',
            'title': '모니터 정산',
            'status': 'pending',
            'amount': 600000,
          },
        );
      await _pumpDetail(tester, h);
      expect(find.byKey(const ValueKey('approval-settle')), findsNothing);
      expect(_inSettlement('정산 결재 중'), findsOneWidget);
      expect(
        _inSettlement('지출-2026-0010 · 모니터 정산 · 600,000원 · 예산보다 70,000원 많습니다'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('approval-settlement')));
      await tester.pumpAndSettle();
      expect(h.called('GET', '/api/groupware/documents/D-e'), hasLength(1));
      expect(find.text('모니터 정산'), findsWidgets, reason: '겹쳐 연 지출 결재 상세');
    });

    testWidgets('승인된 정산은 "정산됨", 반려된 정산은 다시 올릴 수 있다고 보인다', (tester) async {
      final h = _Harness()
        ..purchase = _purchase(
          settlement: {
            'id': 'D-e',
            'title': '모니터 정산',
            'status': 'approved',
            'amount': 530000,
          },
        );
      await _pumpDetail(tester, h);
      expect(_inSettlement('정산됨'), findsOneWidget);
      expect(_inSettlement('모니터 정산 · 530,000원 · 예산과 같습니다'), findsOneWidget);

      final again = _Harness()
        ..purchase = _purchase(
          canSettle: true,
          settlement: {
            'id': 'D-e',
            'title': '모니터 정산',
            'status': 'rejected',
            'amount': 600000,
          },
        );
      await _pumpDetail(tester, again);
      expect(_inSettlement('정산 반려 — 다시 올릴 수 있습니다'), findsOneWidget);
      expect(find.byKey(const ValueKey('approval-settle')), findsOneWidget);
    });

    testWidgets('승인 전 구매 요청에는 정산 줄이 없다', (tester) async {
      final h = _Harness()..purchase = _purchase(status: 'pending');
      await _pumpDetail(tester, h);
      expect(find.byKey(const ValueKey('approval-settlement')), findsNothing);
      expect(find.byKey(const ValueKey('approval-settle')), findsNothing);
    });

    testWidgets(
      '정산하기 — 띠·예산으로 채운 금액·내용, 차이가 바로 바뀌고, settlesId를 보낸 뒤 상세를 다시 받는다',
      (tester) async {
        final h = _Harness();
        await _pumpDetail(tester, h);
        await tester.tap(find.byKey(const ValueKey('approval-settle')));
        await tester.pumpAndSettle();

        expect(find.text('지출 결재'), findsOneWidget);
        final banner = find.byKey(const ValueKey('expense-settles-banner'));
        expect(banner, findsOneWidget);
        expect(
          find.descendant(
            of: banner,
            matching: find.text('정산: $_purchaseTitle'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: banner,
            matching: find.text('구매 · 구매-2026-0003 · 예산 530,000원'),
          ),
          findsOneWidget,
        );
        final amount = tester.widget<TextField>(
          find.byKey(const ValueKey('expense-amount')),
        );
        expect(amount.controller!.text, '530000', reason: '예산으로 미리 채움');
        final body = tester.widget<TextField>(
          find.byKey(const ValueKey('approval-request-body')),
        );
        expect(body.controller!.text, '$_purchaseTitle 정산');
        Text diff() => tester.widget<Text>(
          find.byKey(const ValueKey('expense-settle-diff')),
        );
        expect(diff().data, '예산과 같습니다');

        await tester.enterText(
          find.byKey(const ValueKey('expense-amount')),
          '600,000',
        );
        await tester.pump();
        expect(diff().data, '예산보다 70,000원 많습니다');
        await tester.enterText(
          find.byKey(const ValueKey('expense-amount')),
          '500000',
        );
        await tester.pump();
        expect(diff().data, '예산보다 30,000원 적습니다');
        await tester.enterText(
          find.byKey(const ValueKey('expense-amount')),
          '600000',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('approval-request-submit')));
        await tester.pumpAndSettle();
        final sent = h.bodyOf(
          h.called('POST', '/api/groupware/documents').single,
        );
        expect(sent['kind'], 'expense');
        expect(sent['settlesId'], 'D-p');
        expect(sent['amount'], 600000);
        expect(sent['body'], '$_purchaseTitle 정산');
        expect(sent['approverIds'], [_lead]);

        expect(find.textContaining('결재를 올렸습니다'), findsOneWidget);
        expect(
          h.called('GET', '/api/groupware/documents/D-p'),
          hasLength(2),
          reason: '올린 뒤 상세를 다시 받는다',
        );
        expect(find.byKey(const ValueKey('approval-settle')), findsNothing);
        expect(_inSettlement('정산 결재 중'), findsOneWidget);
        await tester.pump(const Duration(seconds: 3));
      },
    );

    testWidgets('보통 지출 결재에는 settlesId를 보내지 않는다', (tester) async {
      final h = _Harness();
      _bigView(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                // 정산 대상 없이 여는 보통 지출 결재 창.
                onPressed: () => showExpenseRequestDialog(
                  context,
                  api: h.api,
                  ctx: _ctx(),
                  session: h.session,
                ),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('expense-settles-banner')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('expense-settle-diff')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('expense-amount')),
        '12000',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('approval-request-submit')));
      await tester.pumpAndSettle();
      final sent = h.bodyOf(
        h.called('POST', '/api/groupware/documents').single,
      );
      expect(sent.containsKey('settlesId'), isFalse);
      expect(sent['amount'], 12000);
    });
  });

  group('정산 지출 결재', () {
    testWidgets('정산 대상·예산·차이를 보이고, 정산 대상을 누르면 원래 결재를 연다', (tester) async {
      final h = _Harness();
      await _pumpDetail(tester, h, id: 'D-e');
      final target = find.byKey(const ValueKey('approval-settles'));
      expect(target, findsOneWidget);
      expect(
        find.descendant(
          of: target,
          matching: find.text('구매 · 구매-2026-0003 · $_purchaseTitle'),
        ),
        findsOneWidget,
      );
      expect(find.text('예산'), findsOneWidget);
      expect(find.text('530,000원'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('approval-settle-diff')),
          matching: find.text('+70,000원 (예산보다 70,000원 많습니다)'),
        ),
        findsOneWidget,
      );

      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(h.called('GET', '/api/groupware/documents/D-p'), hasLength(1));
      expect(find.text(_purchaseTitle), findsWidgets, reason: '겹쳐 연 원래 결재');
    });

    testWidgets('예산을 모르는 출장 정산은 예산·차이 줄이 없다', (tester) async {
      final h = _Harness();
      h.routes['GET /api/groupware/documents/D-e'] = (_) =>
          _json(_expense(budget: null));
      await _pumpDetail(tester, h, id: 'D-e');
      expect(find.byKey(const ValueKey('approval-settles')), findsOneWidget);
      expect(find.text('예산'), findsNothing);
      expect(find.byKey(const ValueKey('approval-settle-diff')), findsNothing);
    });
  });

  group('결재함의 "정산 안 됨"', () {
    Future<GroupwareChanges> pumpTab(
      WidgetTester tester,
      _Harness h, {
      bool manager = true,
    }) async {
      _bigView(tester);
      final changes = GroupwareChanges();
      addTearDown(changes.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ApprovalTab(
              api: h.api,
              ctx: _ctx(manager: manager),
              changes: changes,
              session: h.session,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return changes;
    }

    List<Map<String, String>> listQueries(_Harness h) => [
      for (final r in h.called('GET', '/api/groupware/documents'))
        {...r.url.queryParameters}..remove('teamId'),
    ];

    testWidgets('내가 올린 문서에서 켜면 ?unsettled=1, 결재할 문서로 옮기면 꺼지고 사라진다', (
      tester,
    ) async {
      final h = _Harness();
      h.routes['GET /api/groupware/documents'] = (r) =>
          _json(r.url.queryParameters['unsettled'] == '1' ? [_purchase()] : []);
      await pumpTab(tester, h);
      final chip = find.byKey(const ValueKey('approval-filter-unsettled'));
      expect(chip, findsOneWidget, reason: '처음 함은 "내가 올린 문서"');
      expect(listQueries(h).last['unsettled'], isNull);

      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(listQueries(h).last, {'box': 'mine', 'unsettled': '1'});
      expect(find.text(_purchaseTitle), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('approval-box-inbox')));
      await tester.pumpAndSettle();
      expect(chip, findsNothing);
      expect(listQueries(h).last, {'box': 'inbox'});

      // 관리자의 전체 문서에서는 다시 고를 수 있고, 꺼진 채로 시작한다.
      await tester.tap(find.byKey(const ValueKey('approval-box-all')));
      await tester.pumpAndSettle();
      expect(chip, findsOneWidget);
      expect(listQueries(h).last, {'box': 'all'});
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(listQueries(h).last, {'box': 'all', 'unsettled': '1'});
    });

    testWidgets('빈 목록이면 정산할 결재가 없다고 알린다', (tester) async {
      final h = _Harness();
      await pumpTab(tester, h, manager: false);
      await tester.tap(find.byKey(const ValueKey('approval-filter-unsettled')));
      await tester.pumpAndSettle();
      expect(find.text('정산할 구매·출장 결재가 없습니다.'), findsOneWidget);
      expect(find.byKey(const ValueKey('approval-box-all')), findsNothing);
    });
  });
}
