// 급여·법인카드 후속(앱) — 모델 읽기, 명세서 열 때 비밀번호 다시 묻기(잠긴 목록·423), 급여 설정(원천징수 정보·급여 계좌·비밀번호 확인),
// 연말정산 자료(정산분 넣기), 퇴직금 계산, 4대보험 신고(신고함 표시), 현금영수증·전자세금계산서, 카드사·홈택스 연동(꺼짐), 영수증 보관.
// 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/groupware.dart';
import 'package:client/models/groupware_finance.dart';
import 'package:client/models/groupware_finance_tools.dart';
import 'package:client/screens/groupware/finance_tools.dart';
import 'package:client/screens/groupware/groupware_screen.dart'
    show GroupwareChanges;
import 'package:client/screens/groupware/payroll_admin.dart';
import 'package:client/screens/groupware/payroll_reports.dart';
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

GroupwareContext _ctx({bool manager = true}) => GroupwareContext.fromJson({
  'scope': 'server',
  'isManager': manager,
  'workStart': 540,
  'workEnd': 1080,
  'today': '2026-10-20',
  'pendingForMe': 0,
  'leaveTypes': [],
  'expenseCategories': ['식대', '교통비', '비품·소모품'],
  'limits': {'approversMax': 5, 'ccMax': 10, 'attachmentsMax': 5},
  'payroll': {'canManage': true},
  'cards': {'total': 1, 'mine': 0},
  'receiptOcr': false,
});

const _run = {
  'id': 'R1',
  'title': '2026년 10월 급여',
  'payMonth': '2026-10',
  'payDate': '2026-10-25',
  'status': 'published',
  'slipCount': 1,
  'viewedCount': 0,
};

Map<String, dynamic> _slip({bool locked = false, bool full = true}) => {
  'id': 'P1',
  'runId': 'R1',
  'userId': 'U-me',
  'userName': '김철수',
  'revision': 1,
  'gross': locked ? null : 3500000,
  'taxable': locked ? null : 3300000,
  'taxFree': locked ? null : 200000,
  'deductionTotal': locked ? null : 300000,
  'net': locked ? null : 3200000,
  if (full) ...{
    'earnings': [
      {'name': '기본급', 'amount': 3300000},
      {'name': '식대', 'amount': 200000, 'taxFree': true},
    ],
    'deductions': [
      {
        'name': '소득세',
        'amount': 41630,
        'basis': '간이세액표 3,300,000원 · 가족 3명 · 8~20세 자녀 1명',
      },
    ],
    'corrections': [],
  },
  'run': _run,
};

const _people = [
  {'id': 'U-me', 'name': '김철수', 'username': 'kim'},
  {'id': 'U-2', 'name': '이영희', 'username': 'lee'},
];

Map<String, dynamic> _payrollSettings() => {
  'staffIds': [],
  'companyName': null,
  'template': {'earnings': [], 'deductions': []},
  'insurance': {'pension': 4.75},
  'employeeNos': {},
  'taxProfiles': {
    'U-me': {'dependents': 3, 'children': 1, 'ratio': 100},
  },
  'bankAccounts': {
    'U-me': {'bankCode': '088', 'number': '110123456789', 'holder': '김철수'},
  },
  'banks': [
    {'code': '004', 'name': 'KB국민은행'},
    {'code': '088', 'name': '신한은행'},
  ],
  'requireReauth': false,
  'canEditStaff': true,
  'people': _people,
};

Map<String, dynamic> _finance({bool codef = false}) => {
  'accounts': {
    'categories': {
      '식대': {'code': '811', 'name': '복리후생비'},
    },
    'fallback': {'code': '848', 'name': '잡비'},
    'cardPayable': {'code': '253', 'name': '미지급금'},
  },
  'defaultAccounts': {'categories': {}},
  'categories': ['식대', '교통비'],
  'voucherFormat': 'generic',
  'receiptRetentionYears': 5,
  'receiptFiling': 'corporate',
  'receiptPurge': false,
  'codef': {
    'enabled': codef,
    'env': 'production',
    'canConnect': codef,
    'hometaxKinds': [],
    'cardConnected': false,
    'hometaxConnected': false,
    'autoSync': false,
    'organizations': {'신한': '0306'},
  },
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
  Map<String, dynamic> lastBody(String method, String path) =>
      (jsonDecode(called(method, path).last.body) as Map)
          .cast<String, dynamic>();
}

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pumpButton(
  WidgetTester tester,
  Future<void> Function(BuildContext) open, {
  bool settle = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => open(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // 뒤 화면의 불러오는 표시가 계속 돌아 settle하지 않는다 — 몇 번 그린다.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
}

void main() {
  setUp(GroupwareApi.clearPayrollUnlock);

  group('모델', () {
    test('급여 설정·연간 집계·퇴직금·증빙·지출 설정 읽기', () {
      final s = PayrollSettings.fromJson(_payrollSettings());
      expect(s.taxProfiles['U-me']!.dependents, 3);
      expect(s.taxProfiles['U-me']!.isDefault, isFalse);
      expect(const TaxProfile().isDefault, isTrue);
      expect(const TaxProfile(auto: false).toJson()['auto'], false);
      expect(s.bankAccounts['U-me']!.number, '110123456789');
      expect(s.banks.last.name, '신한은행');
      final y = PayrollYearSummary.fromJson({
        'year': 2025,
        'people': [
          {
            'userId': 'U-me',
            'name': '김철수',
            'profile': {'dependents': 2},
            'totals': {'months': 12, 'taxable': 40000000, 'incomeTax': 900000},
            'estimate': {'decidedTax': 1393500, 'diffIncomeTax': 493500},
          },
        ],
        'draftRuns': [
          {'id': 'R2', 'title': '2월 급여', 'payMonth': '2026-02'},
        ],
      });
      expect(y.people.single.estimate.diffIncomeTax, 493500);
      expect(y.draftRuns.single.title, '2월 급여');
      expect(settleText(-1230), '환급 1,230원');
      expect(settleText(500), '추징 500원');
      final f = FinanceSettings.fromJson(_finance(codef: true));
      expect(f.accounts.categories['식대']!.label, '811 복리후생비');
      expect(f.accounts.named['cardPayable']!.name, '미지급금');
      expect(f.codef.organizations['신한'], '0306');
      final page = TaxDocumentPage.fromJson({
        'month': '2026-10',
        'items': [
          {
            'id': 'D1',
            'kind': 'tax_invoice',
            'issuedOn': '2026-10-15',
            'totalAmount': 330000,
          },
        ],
        'totals': {'count': 1, 'total': 330000},
      });
      expect(page.items.single.invoice, isTrue);
      expect(page.total, 330000);
      final card = CorporateCard.fromJson({
        'id': 'C1',
        'name': '법인',
        'issuer': '신한',
        'last4': '1234',
        'codefOrg': '0306',
      });
      expect(card.codefOrg, '0306');
      expect(
        ReceiptFile.fromJson({'fileName': 'a.jpg', 'purgedAt': 1}).purgedAt,
        isNotNull,
      );
    });
  });

  group('명세서 비밀번호 다시 묻기', () {
    testWidgets('잠긴 목록 — 눈 단추가 비밀번호를 묻고, 확인 표로 다시 받는다', (tester) async {
      _bigView(tester);
      final h = _Harness();
      h.routes['GET /api/groupware/payroll/mine'] = (r) {
        final unlocked = r.url.queryParameters['unlock'] == 'tok';
        return _json({
          'canManage': false,
          'reauthRequired': true,
          'locked': !unlocked,
          'items': [_slip(locked: !unlocked, full: false)],
        });
      };
      h.routes['POST /api/groupware/payroll/unlock'] = (r) {
        final body = jsonDecode(r.body) as Map;
        return body['password'] == 'pw'
            ? _json({
                'token': 'tok',
                'expiresAt': DateTime.now()
                    .add(const Duration(minutes: 10))
                    .millisecondsSinceEpoch,
              })
            : _json({'error': '비밀번호가 올바르지 않습니다.'}, status: 403);
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PayrollTab(
              api: h.api,
              ctx: _ctx(manager: false),
              changes: GroupwareChanges(),
              session: h.session,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('payroll-reveal')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('payroll-password')), findsOneWidget);
      // 틀리면 창에 문구.
      await tester.enterText(
        find.byKey(const ValueKey('payroll-password')),
        'nope',
      );
      await tester.tap(find.byKey(const ValueKey('payroll-password-ok')));
      await tester.pumpAndSettle();
      expect(find.text('비밀번호가 올바르지 않습니다.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('payroll-password')),
        'pw',
      );
      await tester.tap(find.byKey(const ValueKey('payroll-password-ok')));
      await tester.pumpAndSettle();
      expect(find.text('3,200,000원'), findsWidgets);
      expect(GroupwareApi.payrollUnlockToken, 'tok');
      // 다시 가린다(다른 테스트에 남지 않게).
      await tester.tap(find.byKey(const ValueKey('payroll-reveal')));
      await tester.pumpAndSettle();
    });

    testWidgets('명세서 화면 — 423이면 비밀번호를 묻고 다시 연다', (tester) async {
      _bigView(tester);
      final h = _Harness();
      h.routes['GET /api/groupware/payroll/payslips/P1'] = (r) =>
          r.url.queryParameters['unlock'] == 'tok'
          ? _json(_slip())
          : _json({
              'error': '명세서를 보려면 비밀번호를 다시 확인하세요.',
              'code': 'payroll_locked',
            }, status: 423);
      h.routes['POST /api/groupware/payroll/unlock'] = (_) => _json({
        'token': 'tok',
        'expiresAt': DateTime.now()
            .add(const Duration(minutes: 10))
            .millisecondsSinceEpoch,
      });
      await _pumpButton(
        tester,
        (context) => openPayslipScreen(context, api: h.api, payslipId: 'P1'),
        settle: false,
      );
      expect(find.byKey(const ValueKey('payroll-password')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('payroll-password')),
        'pw',
      );
      await tester.tap(find.byKey(const ValueKey('payroll-password-ok')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('payslip-title')), findsOneWidget);
      expect(find.textContaining('간이세액표'), findsOneWidget);
    });
  });

  group('급여 담당자', () {
    testWidgets('급여 설정 — 원천징수 정보·급여 계좌·비밀번호 확인을 보낸다', (tester) async {
      _bigView(tester);
      final h = _Harness();
      h.routes['GET /api/groupware/payroll/settings'] = (_) =>
          _json(_payrollSettings());
      h.routes['PUT /api/groupware/payroll/settings'] = (_) =>
          _json(_payrollSettings());
      await _pumpButton(
        tester,
        (context) => showPayrollSettingsDialog(context, api: h.api),
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('payroll-tax-profiles')),
      );
      await tester.tap(find.byKey(const ValueKey('payroll-tax-profiles')));
      await tester.pumpAndSettle();
      // 이영희 — 가족 2명.
      await tester.ensureVisible(
        find.byKey(const ValueKey('tax-dependents-U-2')),
      );
      await tester.tap(find.byKey(const ValueKey('tax-dependents-U-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('가족 2명').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('payroll-require-reauth')),
      );
      await tester.tap(find.byKey(const ValueKey('payroll-require-reauth')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('payroll-settings-save')));
      await tester.pumpAndSettle();
      final body = h.lastBody('PUT', '/api/groupware/payroll/settings');
      expect(body['requireReauth'], true);
      expect(body['taxProfiles']['U-me'], {
        'dependents': 3,
        'children': 1,
        'ratio': 100,
      });
      expect(body['taxProfiles']['U-2'], {
        'dependents': 2,
        'children': 0,
        'ratio': 100,
      });
      expect(body['bankAccounts']['U-me'], {
        'bank': '088',
        'number': '110123456789',
        'holder': '김철수',
      });
      expect(body['bankAccounts']['U-2'], isNull);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('연말정산 자료 — 어림값을 고쳐 작성 중인 대장에 넣는다', (tester) async {
      _bigView(tester);
      final h = _Harness();
      h.routes['GET /api/groupware/payroll/year-summary'] = (_) => _json({
        'year': 2025,
        'people': [
          {
            'userId': 'U-me',
            'name': '김철수',
            'profile': {'dependents': 1},
            'totals': {'months': 12, 'taxable': 40000000, 'incomeTax': 900000},
            'estimate': {
              'decidedTax': 1393500,
              'diffIncomeTax': 493500,
              'diffLocalTax': 49350,
            },
          },
        ],
        'draftRuns': [
          {'id': 'R2', 'title': '2026년 2월 급여', 'payMonth': '2026-02'},
        ],
      });
      h.routes['POST /api/groupware/payroll/runs/R2/year-end'] = (_) =>
          _json({'updated': 1});
      await tester.pumpWidget(
        MaterialApp(
          home: YearEndScreen(api: h.api, session: h.session, ctx: _ctx()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('추징 493,500원'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('year-end-tax-U-me')),
        '-12340',
      );
      await tester.tap(find.byKey(const ValueKey('year-end-apply')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2026년 2월 급여'));
      await tester.pumpAndSettle();
      final body = h.lastBody(
        'POST',
        '/api/groupware/payroll/runs/R2/year-end',
      );
      expect(body['year'], 2025);
      expect(body['rows'], [
        {'userId': 'U-me', 'incomeTax': -12340, 'localTax': 49350},
      ]);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('퇴직금 계산 — 사람·마지막 근무일로 계산 내역을 보인다', (tester) async {
      _bigView(tester);
      final h = _Harness();
      h.routes['GET /api/groupware/payroll/settings'] = (_) =>
          _json(_payrollSettings());
      h.routes['POST /api/groupware/payroll/severance'] = (_) => _json({
        'userId': 'U-me',
        'name': '김철수',
        'hireDate': '2021-11-01',
        'lastDay': '2026-10-20',
        'retireDate': '2026-10-21',
        'serviceDays': 1815,
        'serviceYears': 5,
        'eligible': true,
        'period': {'from': '2026-07-21', 'to': '2026-10-20', 'days': 92},
        'wageBreakdown': [],
        'wages': 9900000,
        'averageDailyWage': 107608.69,
        'dailyWage': 107608.69,
        'amount': 16050000,
        'incomeTax': 180000,
        'localTax': 18000,
        'net': 15852000,
      });
      await _pumpButton(
        tester,
        (context) => showSeveranceDialog(
          context,
          api: h.api,
          ctx: _ctx(),
          session: h.session,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('severance-person')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('김철수 (kim)').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('severance-wages')),
        '9900000',
      );
      await tester.tap(find.byKey(const ValueKey('severance-calc')));
      await tester.pumpAndSettle();
      expect(find.text('퇴직금 16,050,000원'), findsOneWidget);
      expect(find.byKey(const ValueKey('severance-make-run')), findsOneWidget);
      final body = h.lastBody('POST', '/api/groupware/payroll/severance');
      expect(body['userId'], 'U-me');
      expect(body['wages'], 9900000);
      expect(body['lastDay'], '2026-10-20');
    });

    testWidgets('4대보험 신고 — 목록·제안, 신고함 표시', (tester) async {
      _bigView(tester);
      final h = _Harness();
      h.routes['GET /api/groupware/payroll/settings'] = (_) =>
          _json(_payrollSettings());
      h.routes['GET /api/groupware/payroll/insurance-reports'] = (_) => _json({
        'items': [
          {
            'id': 'I1',
            'userId': 'U-me',
            'userName': '김철수',
            'kind': 'lose',
            'eventDate': '2026-11-01',
            'deadline': '2026-12-15',
            'reasonCode': '11',
          },
        ],
        'suggestions': [
          {'userId': 'U-2', 'name': '이영희', 'eventDate': '2026-10-01'},
        ],
        'lossReasons': [
          {'code': '11', 'label': '개인 사정으로 인한 자진 퇴사'},
        ],
        'today': '2026-10-20',
      });
      h.routes['PATCH /api/groupware/payroll/insurance-reports/I1'] = (_) =>
          _json({
            'id': 'I1',
            'userName': '김철수',
            'kind': 'lose',
            'eventDate': '2026-11-01',
            'deadline': '2026-12-15',
            'filedAt': 1,
          });
      await tester.pumpWidget(
        MaterialApp(
          home: InsuranceReportsScreen(api: h.api, session: h.session),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('insurance-suggest-U-2')),
        findsOneWidget,
      );
      expect(find.textContaining('기한 2026-12-15'), findsOneWidget);
      expect(find.textContaining('개인 사정으로 인한 자진 퇴사'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('insurance-filed-I1')));
      await tester.pumpAndSettle();
      expect(
        h.lastBody('PATCH', '/api/groupware/payroll/insurance-reports/I1'),
        containsPair('filed', true),
      );
    });
  });

  group('지출 관리 도구', () {
    testWidgets('현금영수증·전자세금계산서 — 달 합계와 목록', (tester) async {
      _bigView(tester);
      final h = _Harness();
      h.routes['GET /api/groupware/tax-documents'] = (_) => _json({
        'month': '2026-10',
        'items': [
          {
            'id': 'D1',
            'kind': 'tax_invoice',
            'direction': 'purchase',
            'issuedOn': '2026-10-15',
            'supplierName': '(주)공급',
            'supplyAmount': 300000,
            'taxAmount': 30000,
            'totalAmount': 330000,
            'itemName': '토너',
          },
        ],
        'totals': {'count': 1, 'supply': 300000, 'tax': 30000, 'total': 330000},
      });
      await tester.pumpWidget(
        MaterialApp(
          home: TaxDocumentsScreen(api: h.api, session: h.session, ctx: _ctx()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('taxdoc-D1')), findsOneWidget);
      expect(find.textContaining('합계 330,000원'), findsOneWidget);
      expect(find.text('(주)공급'), findsOneWidget);
    });

    testWidgets('카드사·홈택스 연동 — 꺼져 있으면 안내만', (tester) async {
      _bigView(tester);
      final h = _Harness();
      h.routes['GET /api/groupware/finance/settings'] = (_) =>
          _json(_finance());
      await _pumpButton(
        tester,
        (context) => showCodefDialog(context, api: h.api),
      );
      expect(find.byKey(const ValueKey('codef-disabled')), findsOneWidget);
      expect(find.byKey(const ValueKey('codef-sync')), findsNothing);
    });

    testWidgets('영수증 보관 — 현황과 보관 기간 저장', (tester) async {
      _bigView(tester);
      final h = _Harness();
      h.routes['GET /api/groupware/finance/receipts'] = (_) => _json({
        'retentionYears': 5,
        'filing': 'corporate',
        'purge': false,
        'count': 3,
        'bytes': 3 * 1024 * 1024,
        'expired': 1,
        'purged': 0,
        'years': [
          {
            'year': 2019,
            'count': 1,
            'bytes': 1024,
            'keepUntil': '2025-03-31',
            'expired': 1,
          },
        ],
      });
      h.routes['PUT /api/groupware/finance/settings'] = (_) =>
          _json(_finance());
      await _pumpButton(
        tester,
        (context) => showReceiptRetentionDialog(context, api: h.api),
      );
      expect(find.textContaining('영수증 3개 · 3.0MB · 기한 지남 1개'), findsOneWidget);
      expect(find.text('2025-03-31까지 보관'), findsOneWidget);
      expect(find.byKey(const ValueKey('retention-purge-now')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('retention-purge')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('retention-save')));
      await tester.pumpAndSettle();
      expect(h.lastBody('PUT', '/api/groupware/finance/settings'), {
        'receiptRetentionYears': 5,
        'receiptFiling': 'corporate',
        'receiptPurge': true,
      });
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('회계 전표 — 포함할 것을 고른다', (tester) async {
      _bigView(tester);
      final h = _Harness();
      await _pumpButton(
        tester,
        (context) => showVoucherExportDialog(
          context,
          api: h.api,
          session: h.session,
          month: '2026-10',
        ),
      );
      expect(
        h.api.financeVouchersPath('2026-10', {'cards', 'expenses'}),
        contains('sources=cards%2Cexpenses'),
      );
      await tester.tap(find.byKey(const ValueKey('voucher-source-cards')));
      await tester.tap(find.byKey(const ValueKey('voucher-source-expenses')));
      await tester.pumpAndSettle();
      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('엑셀로 받기'),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        ),
      );
      expect(button.onPressed, isNull);
    });
  });
}
