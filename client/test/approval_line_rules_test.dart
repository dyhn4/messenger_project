// 결재선 규칙(앱) — 규칙 글(line_rule_text.dart), 관리 탭의 규칙 목록·만들기(상위자 수·직책 기준, 금액, 늘 붙일 결재자·참조자)·지우기,
// 관리자가 아니면 목록만, 신청 창이 금액을 바꾸면 그 금액으로 추천을 다시 받아 채우고(손으로 고쳤으면 지키고 "다시 채우기"), 규칙으로
// 채웠으면 "규칙: …" 안내. 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/groupware.dart';
import 'package:client/screens/groupware/approval_form_widgets.dart'
    show FormValues;
import 'package:client/screens/groupware/approval_forms.dart';
import 'package:client/screens/groupware/groupware_screen.dart'
    show GroupwareChanges;
import 'package:client/screens/groupware/line_rule_text.dart';
import 'package:client/screens/groupware/line_rules_section.dart';
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
const _boss = 'U-boss';
const _fin = 'U-fin';
const _hr = 'U-hr';
const _eduForm = '11111111-1111-4111-8111-111111111111';

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
  'expenseCategories': ['식대'],
  'limits': {'approversMax': 5, 'ccMax': 10, 'attachmentsMax': 5},
});

Map<String, dynamic> _expenseRule() => {
  'id': 'R1',
  'kind': 'expense',
  'templateId': null,
  'templateName': null,
  'minAmount': 1000000,
  'mode': 'position',
  'levels': null,
  'positionLabel': '본부장',
  'extraApproverIds': [_fin],
  'ccIds': [_hr],
};

class _Harness {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{};
  late final Session session;
  _Harness() {
    routes['GET /api/groupware/line-rules'] = (_) => _json([
      _expenseRule(),
      {
        'id': 'R2',
        'kind': 'leave',
        'minAmount': null,
        'mode': 'levels',
        'levels': 1,
        'extraApproverIds': [],
        'ccIds': [],
      },
      {
        'id': 'R3',
        'kind': 'form',
        'templateId': _eduForm,
        'templateName': '교육 신청',
        'mode': 'levels',
        'levels': 2,
        'extraApproverIds': [],
        'ccIds': [],
      },
    ]);
    routes['GET /api/groupware/candidates'] = (_) => _json([
      {'id': _lead, 'name': '팀장', 'username': 'lead'},
      {'id': _boss, 'name': '본부장', 'username': 'boss'},
      {'id': _fin, 'name': '재무팀장', 'username': 'fin'},
      {'id': _hr, 'name': '인사팀', 'username': 'hr'},
    ]);
    routes['GET /api/groupware/forms'] = (_) => _json([
      {
        'id': 'builtin:draft',
        'kind': 'draft',
        'builtin': true,
        'name': '일반 기안서',
        'fields': [],
        'enabled': true,
      },
      {
        'id': _eduForm,
        'kind': 'form',
        'builtin': false,
        'name': '교육 신청',
        'fields': [],
        'enabled': true,
      },
    ]);
    routes['GET /api/position-options'] = (_) => _json([
      {'id': 'P1', 'label': '사원'},
      {'id': 'P2', 'label': '팀장'},
      {'id': 'P3', 'label': '본부장'},
    ]);
    routes['POST /api/groupware/line-rules'] = (r) =>
        _json({'id': 'R-new', ...bodyOf(r)}, status: 201);
    routes['DELETE /api/groupware/line-rules/R1'] = (_) => _json({'ok': true});
    // 신청 창의 추천 — 지출 100만 원 이상이면 규칙(팀장 → 본부장 → 재무팀장, 참조 인사팀), 아니면 조직도 상위자 한 명.
    routes['GET /api/groupware/approval-lines'] = (r) {
      final amount = int.tryParse(r.url.queryParameters['amount'] ?? '');
      final byRule =
          r.url.queryParameters['kind'] == 'expense' &&
          amount != null &&
          amount >= 1000000;
      return _json({
        'lines': [],
        'suggested': byRule
            ? {
                'approverIds': [_lead, _boss, _fin],
                'ccIds': [_hr],
                'source': 'rule',
                'rule': _expenseRule(),
              }
            : {
                'approverIds': [_lead],
                'ccIds': [],
                'source': 'org',
              },
      });
    };
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
  Map<String, dynamic> bodyOf(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;
}

void _view(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pumpSection(
  WidgetTester tester,
  _Harness h, {
  bool manager = true,
}) async {
  _view(tester);
  final changes = GroupwareChanges();
  addTearDown(changes.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            LineRulesAdminSection(
              api: h.api,
              ctx: _ctx(manager: manager),
              changes: changes,
              session: h.session,
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 드롭다운을 열고 [label] 항목을 고른다.
Future<void> _choose(WidgetTester tester, String key, String label) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// 사람 고르기 창을 열어 [ids]를 체크하고 확인.
Future<void> _pickPeople(
  WidgetTester tester,
  String key,
  List<String> ids,
) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  for (final id in ids) {
    await tester.tap(find.byKey(ValueKey('line-rule-person-$id')));
    await tester.pump();
  }
  await tester.tap(find.byKey(const ValueKey('line-rule-people-ok')));
  await tester.pumpAndSettle();
}

void main() {
  test('규칙 글 — 종류·금액·어디까지·늘 붙일 사람', () {
    final names = {_fin: '재무팀장', _hr: '인사팀'};
    final rule = ApprovalLineRule.fromJson(_expenseRule());
    expect(
      lineRuleSentence(rule, nameOf: (id) => names[id] ?? '?'),
      '지출 · 100만 원 이상 → 직책 본부장 이상까지 + 결재 재무팀장 · 참조 인사팀',
    );
    expect(
      lineRuleSentence(
        const ApprovalLineRule(id: 'x', kind: 'leave', levels: 1),
      ),
      '휴가 → 상위자 1명까지',
    );
    expect(
      lineRuleSentence(const ApprovalLineRule(id: 'x', kind: 'any', levels: 0)),
      '모든 결재 → 상위자 없이',
    );
    expect(shortWonText(1000000), '100만 원');
    expect(shortWonText(15000000), '1,500만 원');
    expect(shortWonText(200000000), '2억 원');
    expect(shortWonText(1234567), '1,234,567원');
    expect(expenseAmountOf('1,500,000'), 1500000);
    expect(expenseAmountOf(''), isNull);
  });

  test('양식 금액 — 기안은 예산, 구매는 품목 합계, 만든 양식은 금액·품목 칸의 합, 연장근무는 없음', () {
    ApprovalForm form(String kind, List<Map<String, dynamic>> fields) =>
        ApprovalForm.fromJson({
          'id': 'F',
          'kind': kind,
          'name': kind,
          'fields': fields,
        });
    Map<String, dynamic> field(String key, String type) => {
      'key': key,
      'label': key,
      'type': type,
    };
    final rows = [
      {'name': '모니터', 'qty': '2', 'unitPrice': '250,000'},
      {'name': '케이블', 'qty': '3', 'unitPrice': '10000'},
    ];
    final draft = FormValues(form('draft', [field('budget', 'money')]));
    addTearDown(draft.dispose);
    expect(draft.documentAmount, isNull);
    draft.set('budget', '1,200,000');
    expect(draft.documentAmount, 1200000);
    final purchase = FormValues(form('purchase', [field('items', 'items')]))
      ..set('items', rows);
    addTearDown(purchase.dispose);
    expect(purchase.documentAmount, 530000);
    final custom =
        FormValues(
            form('form', [
              field('a', 'money'),
              field('b', 'items'),
              field('c', 'number'),
            ]),
          )
          ..set('a', '70000')
          ..set('b', rows)
          ..set('c', '9');
    addTearDown(custom.dispose);
    expect(custom.documentAmount, 600000);
    final overtime = FormValues(form('overtime', []));
    addTearDown(overtime.dispose);
    expect(overtime.documentAmount, isNull);
  });

  testWidgets('관리 — 규칙 목록을 글로 보인다', (tester) async {
    final h = _Harness();
    await _pumpSection(tester, h);
    expect(find.text('결재선 규칙'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('line-rule-R1')),
        matching: find.text('지출 · 100만 원 이상 → 직책 본부장 이상까지 + 결재 재무팀장 · 참조 인사팀'),
      ),
      findsOneWidget,
    );
    expect(find.text('휴가 → 상위자 1명까지'), findsOneWidget);
    expect(find.text('"교육 신청" 양식 → 상위자 2명까지'), findsOneWidget);
    expect(find.textContaining('규칙은 결재선을 미리 채울 때만 씁니다'), findsOneWidget);
    expect(find.byKey(const ValueKey('line-rule-add')), findsOneWidget);
    expect(find.byKey(const ValueKey('line-rule-delete-R1')), findsOneWidget);
  });

  testWidgets('관리 — 규칙 만들기: 상위자 수·금액·늘 붙일 결재자', (tester) async {
    final h = _Harness();
    await _pumpSection(tester, h);
    await tester.tap(find.byKey(const ValueKey('line-rule-add')));
    await tester.pumpAndSettle();
    await _choose(tester, 'line-rule-kind', '지출');
    expect(
      find.byKey(const ValueKey('line-rule-template')),
      findsNothing,
      reason: '양식 고르기는 "관리자가 만든 양식"일 때만',
    );
    await tester.enterText(
      find.byKey(const ValueKey('line-rule-min-amount')),
      '1000000',
    );
    await tester.pump();
    expect(find.text('1,000,000원(100만 원) 이상인 문서에 씁니다.'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('line-rule-levels')), '2');
    await _pickPeople(tester, 'line-rule-extra', [_fin]);
    expect(find.text('재무팀장'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('line-rule-save')));
    await tester.pumpAndSettle();
    expect(h.bodyOf(h.called('POST', '/api/groupware/line-rules').single), {
      'teamId': 'T1',
      'kind': 'expense',
      'templateId': null,
      'minAmount': 1000000,
      'mode': 'levels',
      'levels': 2,
      'positionLabel': null,
      'extraApproverIds': [_fin],
      'ccIds': [],
    });
    expect(find.text('결재선 규칙을 만들었습니다.'), findsOneWidget);
    expect(
      h.called('GET', '/api/groupware/line-rules'),
      hasLength(2),
      reason: '저장한 뒤 목록을 다시 받는다',
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('관리 — 규칙 만들기: 한 양식만, 직책 기준, 참조자', (tester) async {
    final h = _Harness();
    await _pumpSection(tester, h);
    await tester.tap(find.byKey(const ValueKey('line-rule-add')));
    await tester.pumpAndSettle();
    await _choose(tester, 'line-rule-kind', '관리자가 만든 양식');
    await _choose(tester, 'line-rule-template', '교육 신청');
    await tester.tap(find.byKey(const ValueKey('line-rule-mode-position')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('line-rule-levels')), findsNothing);
    // 직책을 안 고르면 저장하지 않는다.
    await tester.tap(find.byKey(const ValueKey('line-rule-save')));
    await tester.pumpAndSettle();
    expect(find.text('어느 직책까지 채울지 고르세요.'), findsOneWidget);
    await _choose(tester, 'line-rule-position', '본부장');
    await _pickPeople(tester, 'line-rule-cc', [_hr]);
    await tester.tap(find.byKey(const ValueKey('line-rule-save')));
    await tester.pumpAndSettle();
    expect(h.bodyOf(h.called('POST', '/api/groupware/line-rules').single), {
      'teamId': 'T1',
      'kind': 'form',
      'templateId': _eduForm,
      'minAmount': null,
      'mode': 'position',
      'levels': null,
      'positionLabel': '본부장',
      'extraApproverIds': [],
      'ccIds': [_hr],
    });
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('관리 — 지우기는 확인한 뒤 DELETE', (tester) async {
    final h = _Harness();
    await _pumpSection(tester, h);
    await tester.tap(find.byKey(const ValueKey('line-rule-delete-R1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('규칙을 지울까요?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('line-rule-delete-confirm')));
    await tester.pumpAndSettle();
    expect(h.called('DELETE', '/api/groupware/line-rules/R1'), hasLength(1));
  });

  testWidgets('관리자가 아니면 목록만 — 추가·지우기·고치기 없음', (tester) async {
    final h = _Harness();
    await _pumpSection(tester, h, manager: false);
    expect(find.byKey(const ValueKey('line-rule-R1')), findsOneWidget);
    expect(find.byKey(const ValueKey('line-rule-add')), findsNothing);
    expect(find.byKey(const ValueKey('line-rule-delete-R1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('line-rule-R1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('line-rule-kind')), findsNothing);
  });

  testWidgets('신청 창 — 금액을 바꾸면 규칙대로 다시 채우고, 손으로 고쳤으면 지키고 "다시 채우기"', (
    tester,
  ) async {
    final h = _Harness();
    _view(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showExpenseRequestDialog(
                context,
                api: h.api,
                ctx: _ctx(),
                session: h.session,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final first = h.called('GET', '/api/groupware/approval-lines').single;
    expect(first.url.queryParameters['kind'], 'expense');
    expect(first.url.queryParameters.containsKey('amount'), isFalse);
    Finder approver(String id) =>
        find.byKey(ValueKey('approval-line-approver-$id'));
    expect(approver(_lead), findsOneWidget);
    expect(approver(_boss), findsNothing);

    // 100만 원 이상 — 잠시 뒤 그 금액으로 다시 받아 규칙대로 채운다.
    await tester.enterText(
      find.byKey(const ValueKey('expense-amount')),
      '1,500,000',
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      h.called('GET', '/api/groupware/approval-lines'),
      hasLength(1),
      reason: '입력이 멈출 때까지 기다린다',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    final second = h.called('GET', '/api/groupware/approval-lines').last;
    expect(second.url.queryParameters['kind'], 'expense');
    expect(second.url.queryParameters['amount'], '1500000');
    expect(approver(_boss), findsOneWidget);
    expect(approver(_fin), findsOneWidget);
    expect(find.widgetWithText(InputChip, '인사팀'), findsOneWidget);
    expect(
      find.text('규칙: 지출 · 100만 원 이상 → 직책 본부장 이상까지 + 결재 재무팀장 · 참조 인사팀'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('approval-line-refill')), findsNothing);

    // 손으로 재무팀장을 빼면 — 금액을 낮춰도 고친 결재선을 지키고 "다시 채우기"만 보인다.
    await tester.tap(
      find.descendant(of: approver(_fin), matching: find.byTooltip('빼기')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('expense-amount')),
      '50000',
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(
      h
          .called('GET', '/api/groupware/approval-lines')
          .last
          .url
          .queryParameters['amount'],
      '50000',
    );
    expect(approver(_boss), findsOneWidget, reason: '고친 결재선은 그대로');
    expect(approver(_fin), findsNothing);
    expect(find.byKey(const ValueKey('approval-line-rule-hint')), findsNothing);
    expect(find.byKey(const ValueKey('approval-line-refill')), findsOneWidget);
    expect(find.text('규칙이 바뀌었습니다 — 다시 채우기'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('approval-line-refill')));
    await tester.pumpAndSettle();
    expect(approver(_lead), findsOneWidget);
    expect(approver(_boss), findsNothing);
    expect(find.byKey(const ValueKey('approval-line-refill')), findsNothing);
    expect(
      find.byKey(const ValueKey('approval-line-org-hint')),
      findsOneWidget,
    );
  });
}
