// 급여·법인카드 후속(남은 것 — 앱) — 연말정산 공제 자료(근로자가 내기·담당자가 확인·비밀번호 다시 묻기), 내보내기 양식(고르기·만들기,
// 급여 이체 미리 보기, 4대보험 신고 파일에 주민등록번호를 넣어 POST), CODEF 연동 점검 결과. 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/groupware.dart';
import 'package:client/models/groupware_finance_tools.dart';
import 'package:client/screens/groupware/export_templates.dart';
import 'package:client/screens/groupware/finance_tools.dart';
import 'package:client/screens/groupware/groupware_screen.dart'
    show GroupwareChanges;
import 'package:client/screens/groupware/payroll_reports.dart';
import 'package:client/screens/groupware/payroll_tab.dart';
import 'package:client/screens/groupware/year_end_claim.dart';
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
  'expenseCategories': ['식대'],
  'limits': {'approversMax': 5, 'ccMax': 10, 'attachmentsMax': 5},
  'payroll': {'canManage': manager},
  'cards': {'total': 0, 'mine': 0},
  'receiptOcr': false,
});

/// 내려받기를 가로채는 세션 — 경로·파일 이름·POST 본문을 남긴다.
class _DownloadSession extends Session {
  _DownloadSession()
    : super(notifications: NotificationService(), settings: AppSettings());
  final downloads =
      <({String path, String fileName, Map<String, dynamic>? body})>[];

  @override
  Future<String> downloadAuthedFile(
    String path, {
    required String fileName,
    Map<String, dynamic>? body,
  }) async {
    downloads.add((path: path, fileName: fileName, body: body));
    throw ApiException('시험 — 열지 않음');
  }
}

class _Harness {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{};
  late final _DownloadSession session;
  _Harness() {
    session = _DownloadSession();
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
  tester.view.physicalSize = const Size(1200, 2400);
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

const _estimate = {
  'earnedIncome': 30000000,
  'taxBase': 20000000,
  'computedTax': 1740000,
  'earnedCredit': 740000,
  'claimCredit': 450000,
  'decidedTax': 550000,
  'withheldIncomeTax': 900000,
  'diffIncomeTax': -350000,
  'diffLocalTax': -35000,
  'claim': {
    'deductions': {'card': 2625000, 'rentLoan': 0},
    'credits': {'pensionAccount': 450000, 'medical': 0},
  },
};

Map<String, dynamic> _mine({
  bool exists = false,
  bool confirmed = false,
  bool canEdit = true,
}) => {
  'year': 2025,
  'exists': exists,
  if (exists) ...{
    'submittedAt': 1,
    'updatedByName': '김철수',
    'updatedAt': 1,
    'confirmedAt': confirmed ? 2 : null,
    'confirmedByName': confirmed ? '담당자' : null,
    'claim': {
      'card': {'credit': 20000000},
      'pension': {'savings': 3000000},
      'housing': {'mortgageLimit': 8000000},
      'education': [
        {'kind': 'college', 'amount': 5000000},
      ],
      'marriage': true,
    },
  },
  'canEdit': canEdit,
  'profile': {'dependents': 2},
  'totals': {'months': 12, 'taxable': 50000000, 'incomeTax': 900000},
  'estimate': _estimate,
};

Map<String, dynamic> _templates({
  List<Map<String, dynamic>> saved = const [],
}) => {
  'templates': saved,
  'builtins': [
    {
      'id': 'builtin-transfer',
      'kind': 'transfer',
      'name': '기본(모든 칸)',
      'builtin': true,
      'columns': [
        {'field': 'bankCode', 'header': '은행코드'},
        {'field': 'amount', 'header': '이체금액'},
      ],
    },
    {
      'id': 'builtin-acquire',
      'kind': 'acquire',
      'name': '기본(모든 칸)',
      'builtin': true,
      'columns': [
        {'field': 'name', 'header': '성명'},
        {'field': 'rrn', 'header': '주민등록번호'},
      ],
    },
  ],
  'fields': {
    'transfer': ['bankCode', 'account', 'amount', 'holder', 'fixed', 'blank'],
    'acquire': ['name', 'rrn', 'eventDate', 'fixed', 'blank'],
  },
};

void main() {
  setUp(GroupwareApi.clearPayrollUnlock);

  group('모델', () {
    test('공제 자료·어림의 공제·양식·연동 점검 읽기', () {
      final my = MyYearEnd.fromJson(_mine(exists: true, confirmed: true));
      expect(my.detail.status.confirmed, isTrue);
      expect(my.detail.claim!.value('card', 'credit'), 20000000);
      expect(my.detail.claim!.value('card', 'debitCash'), 0);
      expect(my.detail.claim!.mortgageLimit, 8000000);
      expect(my.detail.claim!.education.single.kind, 'college');
      expect(my.detail.claim!.marriage, isTrue);
      expect(my.estimate.claimDeductions['card'], 2625000);
      expect(my.estimate.claimCredits['pensionAccount'], 450000);
      expect(my.estimate.claimCredit, 450000);
      final set = ExportTemplateSet.fromJson(
        _templates(
          saved: [
            {
              'id': 'ab12',
              'kind': 'transfer',
              'name': '국민',
              'header': false,
              'fileType': 'csv',
              'columns': [
                {'field': 'fixed', 'header': '구분', 'value': '01'},
              ],
            },
          ],
        ),
      );
      expect(set.forKind('transfer').map((t) => t.id), [
        'builtin-transfer',
        'ab12',
      ]);
      expect(set.forKind('acquire').single.wantsRrn, isTrue);
      final saved = set.templates.single;
      expect(saved.header, isFalse);
      expect(saved.toJson()['columns'], [
        {'field': 'fixed', 'header': '구분', 'value': '01'},
      ]);
      expect(normalizeRrnInput('900101-1234567'), '9001011234567');
      expect(normalizeRrnInput('901301-1234567'), isNull);
      final probe = CodefProbeResult.fromJson({
        'target': 'card',
        'ok': true,
        'code': 'CF-00000',
        'count': 2,
        'parsed': 1,
        'keys': ['resA', 'resB'],
        'fields': {
          'amount': {
            'names': ['resUsedAmount'],
            'matched': {},
            'missing': 2,
            'required': true,
          },
        },
      });
      expect(probe.fields['amount']!.required, isTrue);
      expect(probe.keys, ['resA', 'resB']);
    });
  });

  group('연말정산 공제 자료', () {
    testWidgets('근로자 — 내 급여에서 열고, 넣어서 내면 서버에 그 모양으로', (tester) async {
      _bigView(tester);
      final h = _Harness();
      var submitted = false;
      h.routes['GET /api/groupware/payroll/mine'] = (_) =>
          _json({'canManage': false, 'locked': false, 'items': []});
      h.routes['GET /api/groupware/payroll/year-end/mine'] = (_) =>
          _json(_mine(exists: submitted));
      h.routes['PUT /api/groupware/payroll/year-end/mine'] = (_) {
        submitted = true;
        return _json(_mine(exists: true));
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
      await tester.tap(find.byKey(const ValueKey('my-year-end')));
      await tester.pumpAndSettle();
      expect(find.text('2025년 귀속'), findsOneWidget);
      expect(find.text('아직 내지 않았습니다'), findsOneWidget);
      // 어림 — 공제 자료로 넣은 공제와 환급.
      expect(find.text('  신용카드 등 소득공제'), findsOneWidget);
      expect(find.text('  연금계좌 세액공제'), findsOneWidget);
      expect(find.textContaining('환급 350,000원'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('my-year-end-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('claim-card.credit')),
        '20,000,000',
      );
      await tester.enterText(
        find.byKey(const ValueKey('claim-pension.savings')),
        '3000000',
      );
      await tester.enterText(
        find.byKey(const ValueKey('claim-births.first')),
        '1',
      );
      await tester.tap(find.byKey(const ValueKey('claim-education-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('claim-education-amount-0')),
        '2000000',
      );
      // 숫자가 아니면 보내지 않는다.
      await tester.enterText(
        find.byKey(const ValueKey('claim-monthlyRent')),
        'abc',
      );
      await tester.tap(find.byKey(const ValueKey('claim-save')));
      await tester.pumpAndSettle();
      expect(h.called('PUT', '/api/groupware/payroll/year-end/mine'), isEmpty);
      expect(find.textContaining('0 이상의 숫자'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('claim-monthlyRent')),
        '',
      );
      await tester.tap(find.byKey(const ValueKey('claim-save')));
      await tester.pumpAndSettle();
      final body = h.lastBody('PUT', '/api/groupware/payroll/year-end/mine');
      expect(body['year'], 2025);
      final claim = body['claim'] as Map;
      expect(claim['card']['credit'], 20000000);
      expect(claim['pension']['savings'], 3000000);
      expect(claim['births']['first'], 1);
      expect(claim['housing']['mortgageLimit'], 18000000);
      expect(claim['education'], [
        {'kind': 'school', 'amount': 2000000},
      ]);
      expect(claim['monthlyRent'], 0);
      expect(claim['marriage'], false);
      expect(find.text('냈습니다 — 담당자 확인 전'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('근로자 — 담당자가 확인했으면 보기만', (tester) async {
      _bigView(tester);
      final h = _Harness();
      h.routes['GET /api/groupware/payroll/year-end/mine'] = (_) =>
          _json(_mine(exists: true, confirmed: true, canEdit: false));
      await _pumpButton(
        tester,
        (context) =>
            openMyYearEndScreen(context, api: h.api, today: '2026-10-20'),
      );
      expect(find.text('담당자가 확인했습니다'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('my-year-end-edit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('claim-save')), findsNothing);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('claim-card.credit')),
      );
      expect(field.enabled, isFalse);
      expect(field.controller!.text, '20000000');
    });

    testWidgets('근로자 — 비밀번호 다시 묻기(423)면 확인하고 다시 받는다', (tester) async {
      _bigView(tester);
      final h = _Harness();
      h.routes['GET /api/groupware/payroll/year-end/mine'] = (r) =>
          r.url.queryParameters['unlock'] == 'tok'
          ? _json(_mine())
          : _json({
              'error': '연말정산 자료를 보려면 비밀번호를 다시 확인하세요.',
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
        (context) =>
            openMyYearEndScreen(context, api: h.api, today: '2026-10-20'),
        settle: false,
      );
      expect(find.byKey(const ValueKey('payroll-password')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('payroll-password')),
        'pw',
      );
      await tester.tap(find.byKey(const ValueKey('payroll-password-ok')));
      await tester.pumpAndSettle();
      expect(find.text('아직 내지 않았습니다'), findsOneWidget);
    });

    testWidgets('담당자 — 연말정산 자료의 사람마다 공제 자료를 열고 저장하고 확인', (tester) async {
      _bigView(tester);
      final h = _Harness();
      h.routes['GET /api/groupware/payroll/year-summary'] = (_) => _json({
        'year': 2025,
        'people': [
          {
            'userId': 'U-me',
            'name': '김철수',
            'profile': {'dependents': 2},
            'totals': {'months': 12, 'taxable': 50000000},
            'claim': {'exists': true, 'submittedAt': 1},
            'estimate': _estimate,
          },
        ],
        'draftRuns': [],
      });
      h.routes['GET /api/groupware/payroll/year-end/claims/U-me'] = (_) =>
          _json(_mine(exists: true));
      h.routes['PUT /api/groupware/payroll/year-end/claims/U-me'] = (_) =>
          _json(_mine(exists: true, confirmed: true));
      await tester.pumpWidget(
        MaterialApp(
          home: YearEndScreen(api: h.api, session: h.session, ctx: _ctx()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('공제 자료 냄 — 확인 전'), findsOneWidget);
      expect(find.textContaining('카드 공제 2,625,000원'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('year-end-claim-U-me')));
      await tester.pumpAndSettle();
      expect(find.text('김철수 — 2025년 귀속 공제 자료'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('claim-medical.special')),
        '1500000',
      );
      await tester.tap(find.byKey(const ValueKey('claim-confirm')));
      await tester.pumpAndSettle();
      final body = h.lastBody(
        'PUT',
        '/api/groupware/payroll/year-end/claims/U-me',
      );
      expect(body['confirmed'], true);
      expect(body['year'], 2025);
      final claim = body['claim'] as Map;
      expect(claim['medical']['special'], 1500000);
      // 처음 값은 그대로 다시 보낸다.
      expect(claim['card']['credit'], 20000000);
      expect(claim['housing']['mortgageLimit'], 8000000);
      expect(claim['marriage'], true);
      // 저장하면 집계를 다시 받는다.
      expect(h.called('GET', '/api/groupware/payroll/year-summary').length, 2);
    });
  });

  group('내보내기 양식', () {
    testWidgets('양식 고르기 — 새 양식을 만들어 저장하고 그 양식으로 고른다', (tester) async {
      _bigView(tester);
      final h = _Harness();
      var saved = <Map<String, dynamic>>[];
      h.routes['GET /api/groupware/payroll/export-templates'] = (_) =>
          _json(_templates(saved: saved));
      h.routes['PUT /api/groupware/payroll/export-templates'] = (r) {
        final body = jsonDecode(r.body) as Map;
        saved = [
          for (final t in (body['templates'] as List))
            {...(t as Map).cast<String, dynamic>(), 'id': 'new1'},
        ];
        return _json(_templates(saved: saved));
      };
      ExportTemplate? picked;
      await _pumpButton(tester, (context) async {
        picked = await pickExportTemplate(
          context,
          api: h.api,
          kind: 'transfer',
          title: '급여 이체 파일',
        );
      });
      expect(find.text('기본(모든 칸)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('export-template-new')));
      await tester.pumpAndSettle();
      // 고른 양식(기본)의 열에서 시작한다.
      expect(
        find.byKey(const ValueKey('export-column-field-1')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('export-template-name')),
        '신한 대량이체',
      );
      await tester.tap(find.byKey(const ValueKey('export-template-header')));
      await tester.tap(find.byKey(const ValueKey('export-column-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('export-column-field-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('고정 값').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('export-column-value-2')),
        '급여',
      );
      await tester.tap(find.byKey(const ValueKey('export-template-save')));
      await tester.pumpAndSettle();
      final body = h.lastBody('PUT', '/api/groupware/payroll/export-templates');
      final t = (body['templates'] as List).single as Map;
      expect(t['name'], '신한 대량이체');
      expect(t['kind'], 'transfer');
      expect(t['header'], false);
      expect((t['columns'] as List).length, 3);
      expect((t['columns'] as List).last, {
        'field': 'fixed',
        'header': '',
        'value': '급여',
      });
      expect(find.text('신한 대량이체'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('export-template-ok')));
      await tester.pumpAndSettle();
      expect(picked?.id, 'new1');
    });

    testWidgets('4대보험 신고 파일 — 주민등록번호 칸이 있는 양식이면 번호를 받아 POST로', (tester) async {
      _bigView(tester);
      final h = _Harness();
      h.routes['GET /api/groupware/payroll/insurance-reports'] = (_) => _json({
        'items': [
          {
            'id': 'IR1',
            'userId': 'U-me',
            'userName': '김철수',
            'kind': 'acquire',
            'eventDate': '2026-10-05',
            'deadline': '2026-11-15',
            'jobCode': '0A1',
          },
        ],
        'suggestions': [],
        'lossReasons': [],
        'today': '2026-10-20',
      });
      h.routes['GET /api/groupware/payroll/settings'] = (_) => _json({
        'people': [
          {'id': 'U-me', 'name': '김철수', 'username': 'kim'},
        ],
      });
      h.routes['GET /api/groupware/payroll/export-templates'] = (_) =>
          _json(_templates());
      await tester.pumpWidget(
        MaterialApp(
          home: InsuranceReportsScreen(api: h.api, session: h.session),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('insurance-export')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('취득 신고 파일(아직 안 한 것)'));
      await tester.pumpAndSettle();
      expect(find.text('1명 — 김철수'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('export-template-ok')));
      await tester.pumpAndSettle();
      // 형식이 틀리면 창에 남는다.
      await tester.enterText(
        find.byKey(const ValueKey('rrn-IR1')),
        '901301-1234567',
      );
      await tester.tap(find.byKey(const ValueKey('rrn-ok')));
      await tester.pumpAndSettle();
      expect(find.textContaining('13자리를 확인하세요'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('rrn-IR1')),
        '900101-1234567',
      );
      await tester.tap(find.byKey(const ValueKey('rrn-ok')));
      await tester.pumpAndSettle();
      final d = h.session.downloads.single;
      expect(d.path, '/api/groupware/payroll/insurance-reports/export');
      expect(d.fileName, '4대보험_취득.xlsx');
      expect(d.body!['kind'], 'acquire');
      expect(d.body!['rrns'], {'IR1': '9001011234567'});
      // 기본 양식이면 template을 보내지 않는다(서버가 기본으로).
      expect(d.body!.containsKey('template'), isFalse);
      // 주소에는 번호가 없다.
      expect(d.path.contains('900101'), isFalse);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('CODEF 연동 점검', () {
    testWidgets('연동 창의 점검 단추 → 결과(꼭 필요한 칸을 못 찾으면 빨갛게, 칸 이름과 .env 예시)', (
      tester,
    ) async {
      _bigView(tester);
      final h = _Harness();
      h.routes['GET /api/groupware/finance/settings'] = (_) => _json({
        'accounts': {'categories': {}},
        'defaultAccounts': {'categories': {}},
        'categories': [],
        'codef': {
          'enabled': true,
          'canConnect': false,
          'hometaxKinds': [],
          'cardConnected': true,
          'hometaxConnected': false,
          'organizations': {},
          'paths': {'card': '/v1/kr/card/b/account/approval-list'},
        },
      });
      h.routes['POST /api/groupware/codef/probe'] = (_) => _json({
        'target': 'card',
        'organization': '0306',
        'path': '/v1/kr/card/b/account/approval-list',
        'from': '2026-10-13',
        'to': '2026-10-20',
        'ok': true,
        'code': 'CF-00000',
        'count': 3,
        'parsed': 0,
        'skipped': 0,
        'errors': [
          {'error': '금액을 읽지 못했습니다.', 'count': 3},
        ],
        'keys': ['resApprovalAmt', 'resUsedDate'],
        'fields': {
          'usedDate': {
            'names': ['resUsedDate'],
            'matched': {'resUsedDate': 3},
            'missing': 0,
            'required': true,
          },
          'amount': {
            'names': ['resUsedAmount', 'resApprovalAmount'],
            'matched': {},
            'missing': 3,
            'required': true,
          },
        },
      });
      await _pumpButton(
        tester,
        (context) => showCodefDialog(context, api: h.api),
      );
      await tester.tap(find.byKey(const ValueKey('codef-probe')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('카드 승인내역'));
      await tester.pumpAndSettle();
      expect(
        h.lastBody('POST', '/api/groupware/codef/probe')['target'],
        'card',
      );
      expect(find.text('연동 점검 — 카드 승인내역'), findsOneWidget);
      expect(find.textContaining('응답 CF-00000 · 3줄 · 읽은 줄 0'), findsOneWidget);
      expect(find.text('resUsedDate (3줄)'), findsOneWidget);
      final amount = tester.widget<Text>(
        find.byKey(const ValueKey('codef-probe-field-amount')),
      );
      expect(amount.data, contains('못 찾음'));
      expect(
        amount.style?.color,
        Theme.of(
          tester.element(find.byType(AlertDialog).last),
        ).colorScheme.error,
      );
      expect(find.text('resApprovalAmt, resUsedDate'), findsOneWidget);
      expect(
        find.text('CODEF_FIELD_MAP={"card":{"amount":"…"}}'),
        findsOneWidget,
      );
    });
  });
}
