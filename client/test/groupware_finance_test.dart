// 급여명세서·법인카드(앱) — 모델 읽기, 급여 탭(내 명세서 — 금액 가림·해마다 합계·명세서 보기, 담당자의 대장 목록), 명세서 고치기(보낸 뒤에는
// 정정 사유), 명세서 PDF, 지출 탭의 "내 법인카드"(골라서 청구 — 금액 고정·cardTransactionIds), 법인카드 관리(카드·사용 건·상태 거르기),
// 지출 결재 상세의 청구한 사용 건. 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/groupware.dart';
import 'package:client/models/groupware_finance.dart';
import 'package:client/screens/groupware/approval_tab.dart';
import 'package:client/screens/groupware/card_admin.dart';
import 'package:client/screens/groupware/corporate_cards.dart';
import 'package:client/screens/groupware/groupware_screen.dart'
    show GroupwareChanges;
import 'package:client/screens/groupware/payroll_admin.dart';
import 'package:client/screens/groupware/payroll_tab.dart';
import 'package:client/screens/groupware/payslip_view.dart';
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

GroupwareContext _ctx({
  bool manager = false,
  bool payrollManage = false,
  int cardsMine = 1,
}) => GroupwareContext.fromJson({
  'scope': 'server',
  'isManager': manager,
  'workStart': 540,
  'workEnd': 1080,
  'today': '2026-10-19',
  'pendingForMe': 0,
  'leaveTypes': [],
  'expenseCategories': ['식대', '교통비', '접대비'],
  'limits': {'approversMax': 5, 'ccMax': 10, 'attachmentsMax': 5},
  'payroll': {'canManage': payrollManage},
  'cards': {'total': 2, 'mine': cardsMine},
  'receiptOcr': false,
});

const _run = {
  'id': 'R1',
  'title': '2026년 10월 급여',
  'payMonth': '2026-10',
  'payDate': '2026-10-25',
  'status': 'published',
  'note': '10월분 연장근로수당 포함',
  'slipCount': 3,
  'viewedCount': 1,
};

Map<String, dynamic> _slip({bool full = true, int revision = 1}) => {
  'id': 'P1',
  'runId': 'R1',
  'userId': 'U-me',
  'userName': '김철수',
  'employeeNo': 'E-001',
  'department': '영업팀',
  'position': '대리',
  'revision': revision,
  'viewedAt': null,
  'gross': 3380000,
  'taxable': 3180000,
  'taxFree': 200000,
  'deductionTotal': 373440,
  'net': 3006560,
  if (full) ...{
    'earnings': [
      {'name': '기본급', 'amount': 3000000},
      {'name': '식대', 'amount': 200000, 'taxFree': true},
      {'name': '연장근로수당', 'amount': 180000, 'basis': '10시간 × 12,000원 × 1.5'},
    ],
    'deductions': [
      {'name': '국민연금', 'amount': 151050},
      {'name': '소득세', 'amount': 202170},
      {'name': '지방소득세', 'amount': 20220},
    ],
    'work': {'workDays': 21, 'workMinutes': 10080, 'overtimeMinutes': 600},
    'memo': '수고하셨습니다',
    'corrections': [],
  },
  'run': _run,
  'companyName': '탱고 주식회사',
};

Map<String, dynamic> _tx(
  String id, {
  int amount = 5600,
  String merchant = '스타벅스',
  String status = 'open',
  int receipts = 0,
  bool canClaim = true,
  String? memo,
  String? category,
}) => {
  'id': id,
  'cardId': 'C1',
  'cardName': '영업 카드',
  'issuer': '신한',
  'last4': '5678',
  'usedAt': DateTime(2026, 10, 18, 12, 30).millisecondsSinceEpoch,
  'usedOn': '2026-10-18',
  'merchant': merchant,
  'amount': amount,
  'approvalNo': '3001',
  'source': 'excel',
  'userId': 'U-me',
  'userName': '김철수',
  'memo': memo,
  'category': category,
  'receipts': [
    for (var i = 0; i < receipts; i++)
      {
        'fileUrl': '/files/r$i',
        'fileName': '영수증$i.jpg',
        'mimeType': 'image/jpeg',
      },
  ],
  'mismatches': [],
  'status': status,
  'canEdit': status == 'open',
  'canClaim': canClaim,
  'unassigned': false,
};

class _Harness {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{};
  late final Session session;
  _Harness() {
    routes['GET /api/groupware/payroll/mine'] = (_) => _json({
      'canManage': false,
      'items': [_slip(full: false)],
    });
    routes['GET /api/groupware/payroll/payslips/P1'] = (_) => _json(_slip());
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

  GroupwareApi get api => GroupwareApi(session.api!);
  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
}

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1100, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  group('모델', () {
    test('명세서·대장·사용 건 읽기와 금액 글', () {
      final s = Payslip.fromJson(_slip());
      expect(s.earnings.length, 3);
      expect(s.earnings[1].taxFree, isTrue);
      expect(s.earnings[2].basis, contains('1.5'));
      expect(s.work!.overtimeMinutes, 600);
      expect(s.run!.published, isTrue);
      expect(signedWonText(-12300), '-12,300원');
      expect(payrollHoursText(630), '10시간 30분');
      final t = CardTransaction.fromJson({
        ..._tx('T1'),
        'mismatches': ['amount', 'date'],
        'receiptScan': {'total': 5700, 'date': '2026-10-25'},
      });
      expect(t.mismatchText, '영수증과 다릅니다: 금액(5,700원), 날짜(2026-10-25)');
      expect(CardTxStatus.fromWire('settled'), CardTxStatus.settled);
      final claimed = ClaimedCardTransaction.listOf({
        'cardTransactions': [
          {
            'id': 'T1',
            'cardName': '영업 카드',
            'last4': '5678',
            'merchant': 'A',
            'amount': 1000,
            'receipts': [],
          },
        ],
      });
      expect(claimed.single.amount, 1000);
      final ctx = _ctx(payrollManage: true);
      expect(ctx.payrollAvailable, isTrue);
      expect(ctx.payrollCanManage, isTrue);
      expect(ctx.cardsMine, 1);
    });

    test('명세서 PDF — 한글 글꼴로 만든다', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final bytes = await buildPayslipPdf(
        slip: Payslip.fromJson(_slip(revision: 2)),
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(bytes.length, greaterThan(1000));
    });
  });

  group('급여 탭', () {
    testWidgets('내 명세서 — 금액은 가렸다가 눈 단추로 보이고, 누르면 명세서', (tester) async {
      _bigView(tester);
      final h = _Harness();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PayrollTab(
              api: h.api,
              ctx: _ctx(),
              changes: GroupwareChanges(),
              session: h.session,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2026년 10월 급여'), findsOneWidget);
      expect(find.text('3,006,560원'), findsNothing);
      expect(find.text('•••••원'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('payroll-reveal')));
      await tester.pumpAndSettle();
      expect(find.text('3,006,560원'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('my-payslip-P1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('payslip-title')), findsOneWidget);
      expect(find.text('식대 (비과세)'), findsOneWidget);
      expect(find.text('10시간 × 12,000원 × 1.5'), findsOneWidget);
      expect(find.text('10월분 연장근로수당 포함'), findsOneWidget);
      expect(find.textContaining('사번 E-001'), findsOneWidget);
      expect(find.text('연장 10시간'), findsOneWidget);
      expect(
        h.called('GET', '/api/groupware/payroll/payslips/P1'),
        hasLength(1),
      );
      // 다시 가려 둔다(다른 테스트에 남지 않게).
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('payroll-reveal')));
      await tester.pumpAndSettle();
    });

    testWidgets('담당자 — "급여 관리"에서 대장 목록(보냄·확인 수)', (tester) async {
      _bigView(tester);
      final h = _Harness()
        ..routes['GET /api/groupware/payroll/mine'] = ((_) =>
            _json({'canManage': true, 'items': []}))
        ..routes['GET /api/groupware/payroll/runs'] = ((_) => _json([_run]));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PayrollTab(
              api: h.api,
              ctx: _ctx(payrollManage: true),
              changes: GroupwareChanges(),
              session: h.session,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('받은 급여명세서가 없습니다.'), findsOneWidget);
      await tester.tap(find.text('급여 관리'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('payroll-run-R1')), findsOneWidget);
      expect(find.textContaining('보냄 · 확인 1/3명'), findsOneWidget);
      expect(find.byKey(const ValueKey('payroll-new-run')), findsOneWidget);
    });

    testWidgets('명세서 고치기 — 보낸 뒤에는 정정 사유가 있어야 저장하고, 항목·사유를 보낸다', (tester) async {
      _bigView(tester);
      final h = _Harness();
      Map<String, dynamic>? sent;
      h.routes['PUT /api/groupware/payroll/payslips/P1'] = (r) {
        sent = jsonDecode(r.body) as Map<String, dynamic>;
        return _json(_slip(revision: 2));
      };
      Payslip? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => saved = await showDialog<Payslip>(
                  context: context,
                  builder: (_) => PayslipEditorDialog(
                    api: h.api,
                    slip: Payslip.fromJson(_slip()),
                    published: true,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('slip-editor-total')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('slip-e-amount-0')),
        '3100000',
      );
      await tester.pump();
      expect(find.textContaining('실수령 3,106,560원'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('slip-editor-save')));
      await tester.pumpAndSettle();
      expect(find.text('이미 보낸 명세서입니다. 정정 사유를 쓰세요.'), findsOneWidget);
      expect(sent, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('slip-editor-reason')),
        '기본급 인상분',
      );
      await tester.tap(find.byKey(const ValueKey('slip-editor-save')));
      await tester.pumpAndSettle();
      expect(sent!['reason'], '기본급 인상분');
      expect((sent!['earnings'] as List).first, {
        'name': '기본급',
        'amount': 3100000,
      });
      expect((sent!['earnings'] as List)[1], {
        'name': '식대',
        'amount': 200000,
        'taxFree': true,
      });
      expect(sent!['work'], {
        'workDays': 21,
        'workMinutes': 10080,
        'overtimeMinutes': 600,
      });
      expect(saved!.revision, 2);
    });
  });

  group('법인카드', () {
    testWidgets('내 법인카드 — 두 건을 골라 청구하면 합계로 금액이 고정되고 cardTransactionIds를 보낸다', (
      tester,
    ) async {
      _bigView(tester);
      final h = _Harness();
      h.routes['GET /api/groupware/card-transactions'] = (_) => _json({
        'month': null,
        'items': [
          _tx('T1', receipts: 1, memo: '거래처 미팅', category: '접대비'),
          _tx('T2', amount: 15000, merchant: '택시', receipts: 1),
        ],
        'totals': {'all': 20600, 'open': 20600, 'openCount': 2},
      });
      Map<String, dynamic>? posted;
      h.routes['POST /api/groupware/documents'] = (r) {
        posted = jsonDecode(r.body) as Map<String, dynamic>;
        return _json({
          'id': 'D1',
          'kind': 'expense',
          'title': 't',
          'payload': {'amount': 20600},
          'status': 'pending',
          'authorId': 'U-me',
          'authorName': '김철수',
          'steps': [
            {
              'id': 'S1',
              'order': 0,
              'approverId': 'U-lead',
              'approverName': '팀장',
              'status': 'pending',
            },
          ],
        }, status: 201);
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MyCardSection(
                api: h.api,
                ctx: _ctx(),
                changes: GroupwareChanges(),
                session: h.session,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('스타벅스'), findsOneWidget);
      expect(find.text('택시'), findsOneWidget);
      // 고르지 않으면 청구 단추가 꺼져 있다.
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('card-claim')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('card-tx-T1')));
      await tester.tap(find.byKey(const ValueKey('card-tx-T2')));
      await tester.pump();
      expect(find.text('2건 · 20,600원'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('card-claim')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('expense-card-banner')), findsOneWidget);
      final amount = tester.widget<TextField>(
        find.byKey(const ValueKey('expense-amount')),
      );
      expect(amount.controller!.text, '20600');
      expect(amount.readOnly, isTrue);
      // 분류는 사용 건에 정한 분류(접대비).
      expect(find.text('접대비'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('approval-request-submit')));
      await tester.pumpAndSettle();
      expect(posted!['amount'], 20600);
      expect(posted!['cardTransactionIds'], ['T1', 'T2']);
      expect(posted!['category'], '접대비');
      expect(posted!['spentOn'], '2026-10-18');
      expect(posted!['body'], contains('스타벅스(거래처 미팅)'));
      // 올렸다는 알림이 사라질 때까지.
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('법인카드 관리 — 카드(한도 대비 사용)·사용 건·상태 거르기', (tester) async {
      _bigView(tester);
      final h = _Harness();
      h.routes['GET /api/groupware/cards'] = (_) => _json({
        'month': '2026-10',
        'cards': [
          {
            'id': 'C1',
            'name': '영업 카드',
            'issuer': '신한',
            'last4': '5678',
            'holders': [
              {'id': 'U-me', 'name': '김철수'},
            ],
            'monthlyLimit': 1000000,
            'enabled': true,
            'used': 140600,
          },
        ],
      });
      h.routes['GET /api/groupware/card-transactions'] = (_) => _json({
        'month': '2026-10',
        'mine': false,
        'items': [
          _tx('T1'),
          _tx(
            'T3',
            merchant: '한우마을',
            amount: 120000,
            status: 'claiming',
            canClaim: false,
          ),
          _tx(
            'T4',
            merchant: '스타벅스',
            amount: -5600,
            status: 'excluded',
            canClaim: false,
          ),
        ],
        'totals': {
          'all': 120000,
          'open': 5600,
          'claiming': 120000,
          'excluded': -5600,
          'openCount': 1,
        },
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CardAdminView(
                api: h.api,
                ctx: _ctx(manager: true),
                changes: GroupwareChanges(),
                session: h.session,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('영업 카드 (신한 5678)'), findsOneWidget);
      expect(find.text('140,600원 / 1,000,000원'), findsOneWidget);
      expect(find.byKey(const ValueKey('admin-card-tx-T3')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('card-filter-claiming')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin-card-tx-T3')), findsOneWidget);
      expect(find.byKey(const ValueKey('admin-card-tx-T1')), findsNothing);
      expect(find.byKey(const ValueKey('admin-card-tx-T4')), findsNothing);
    });

    testWidgets('지출 결재 상세 — 청구한 사용 건과 영수증', (tester) async {
      _bigView(tester);
      final h = _Harness();
      h.routes['GET /api/groupware/documents/D1'] = (_) => _json({
        'id': 'D1',
        'kind': 'expense',
        'docNumber': '지출-2026-0001',
        'title': '법인카드 청구',
        'payload': {
          'amount': 20600,
          'category': '접대비',
          'spentOn': '2026-10-18',
          'cardTransactions': [
            {
              'id': 'T1',
              'cardName': '영업 카드',
              'issuer': '신한',
              'last4': '5678',
              'usedAt': DateTime(2026, 10, 18, 12, 30).millisecondsSinceEpoch,
              'merchant': '스타벅스',
              'amount': 5600,
              'approvalNo': '3001',
              'memo': '거래처 미팅',
              'receipts': [
                {
                  'fileUrl': '/files/x',
                  'fileName': '영수증.jpg',
                  'mimeType': 'image/jpeg',
                },
              ],
            },
            {
              'id': 'T2',
              'cardName': '영업 카드',
              'issuer': '신한',
              'last4': '5678',
              'merchant': '택시',
              'amount': 15000,
              'receipts': [],
            },
          ],
        },
        'attachments': [],
        'status': 'pending',
        'authorId': 'U-me',
        'authorName': '김철수',
        'steps': [
          {
            'id': 'S1',
            'order': 0,
            'approverId': 'U-lead',
            'approverName': '팀장',
            'status': 'pending',
          },
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ApprovalDetailDialog(
              api: h.api,
              ctx: _ctx(),
              session: h.session,
              documentId: 'D1',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('approval-card-transactions')),
        findsOneWidget,
      );
      expect(find.text('스타벅스 — 거래처 미팅'), findsOneWidget);
      expect(find.text('영수증.jpg'), findsOneWidget);
      expect(find.text('영수증 없음'), findsOneWidget);
    });
  });
}
