// 결재 양식의 사람 칸·표 칸·칸 설명(앱) — 신청 창에서 사람 고르기(한 사람은 바뀌고 여러 명은 더함, 보낸 id), 표 줄 넣기·더하기·빼기·
// 합계·보낸 모양, 필수 칸 검사, 칸 설명, 문서 금액(표의 금액 열), 상세(FormValuesView)의 사람·표, 인쇄 내용, 좁은 화면(360px).
// 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/groupware.dart';
import 'package:client/screens/groupware/approval_form_widgets.dart';
import 'package:client/screens/groupware/approval_print.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/groupware_api.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

final _ctx = GroupwareContext.fromJson({
  'scope': 'team',
  'teamId': 'T1',
  'teamName': '본사',
  'isManager': true,
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

const _columns = [
  {'label': '품명', 'type': 'text'},
  {'label': '수량', 'type': 'number'},
  {'label': '금액', 'type': 'money'},
  {'label': '날짜', 'type': 'date'},
];

/// 사람 칸 둘(한 사람·여러 명)과 표 칸, 설명이 붙은 글 칸이 있는 양식.
Map<String, dynamic> _formJson() => {
  'id': 'F-p',
  'kind': 'form',
  'builtin': false,
  'name': '장비 반출',
  'fields': [
    {
      'key': 'f1',
      'label': '책임자',
      'type': 'person',
      'required': true,
      'help': '반출을 책임질 사람을 고르세요',
    },
    {'key': 'f2', 'label': '동행', 'type': 'person', 'multiple': true},
    {
      'key': 'f3',
      'label': '반출 목록',
      'type': 'table',
      'required': true,
      'help': '줄마다 장비 하나',
      'columns': _columns,
    },
    {'key': 'f4', 'label': '목적', 'type': 'text', 'help': '어디에 쓰는지'},
  ],
  'allowAttachments': false,
  'enabled': true,
};

Map<String, dynamic> _doc() => {
  'id': 'D-f',
  'kind': 'form',
  'title': '장비 반출',
  'payload': {
    'templateId': 'F-p',
    'templateName': '장비 반출',
    'fields': [
      {'key': 'f1', 'label': '책임자', 'type': 'person', 'multiple': false},
      {'key': 'f2', 'label': '동행', 'type': 'person', 'multiple': true},
      {'key': 'f3', 'label': '반출 목록', 'type': 'table', 'columns': _columns},
      {'key': 'f5', 'label': '빈 사람', 'type': 'person', 'multiple': true},
    ],
    'values': {
      'f1': [
        {'id': 'U-lead', 'name': '팀장'},
      ],
      'f2': [
        {'id': 'U-lead', 'name': '팀장'},
        {'id': 'U-a', 'name': '김철수'},
      ],
      'f3': {
        'rows': [
          ['모니터', 2, 250000, '2026-10-20'],
          ['케이블', 3, 10000, null],
        ],
        'totals': [null, 5, 260000, null],
      },
      'f5': [],
    },
  },
  'attachments': [],
  'status': 'pending',
  'authorId': 'U-me',
  'authorName': '홍길동',
  'createdAt': DateTime(2026, 10, 17, 9).millisecondsSinceEpoch,
  'steps': [
    {
      'id': 'S1',
      'order': 1,
      'approverId': 'U-lead',
      'approverName': '팀장',
      'status': 'pending',
    },
  ],
};

class _Harness {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{};
  late final Session session;
  _Harness() {
    routes['GET /api/groupware/candidates'] = (r) => _json([
      {'id': 'U-lead', 'name': '팀장', 'username': 'lead'},
      {'id': 'U-a', 'name': '김철수', 'username': 'kim'},
      if (r.url.queryParameters['includeSelf'] == '1')
        {'id': 'U-me', 'name': '홍길동', 'username': 'me'},
    ]);
    routes['GET /api/groupware/approval-lines'] = (_) => _json({
      'lines': [],
      'suggested': {
        'approverIds': ['U-lead'],
        'ccIds': [],
        'source': 'org',
      },
    });
    routes['POST /api/groupware/documents'] = (_) => _json(_doc(), status: 201);
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

/// 단추 하나 있는 화면을 띄우고 그 단추로 신청 창을 연다(창이 닫혀도 화면이 남게).
Future<void> _openDialog(
  WidgetTester tester,
  _Harness h, {
  Size size = const Size(1000, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final form = ApprovalForm.fromJson(_formJson());
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const ValueKey('open'),
            onPressed: () => showFormRequestDialog(
              context,
              api: h.api,
              ctx: _ctx,
              session: h.session,
              form: form,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, text);
  await tester.pump();
}

String _cellText(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('사람 칸 — 한 사람은 바뀌고, 여러 명은 더하고 빼며, 보낼 때 id', (tester) async {
    final h = _Harness();
    await _openDialog(tester, h);
    expect(find.text('반출을 책임질 사람을 고르세요'), findsOneWidget, reason: '칸 설명');
    expect(find.text('줄마다 장비 하나'), findsOneWidget);
    expect(find.text('어디에 쓰는지'), findsOneWidget, reason: '입력칸 도움말');

    await _tapKey(tester, 'form-field-f1-pick');
    expect(
      find.byKey(const ValueKey('form-person-U-me')),
      findsOneWidget,
      reason: '나도 고를 수 있다',
    );
    await _tapKey(tester, 'form-person-U-lead');
    expect(
      find.byKey(const ValueKey('form-field-f1-person-U-lead')),
      findsOneWidget,
    );
    await _tapKey(tester, 'form-field-f1-pick');
    await tester.enterText(
      find.byKey(const ValueKey('form-person-search')),
      'me',
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('form-person-U-a')),
      findsNothing,
      reason: '찾기',
    );
    await _tapKey(tester, 'form-person-U-me');
    expect(
      find.byKey(const ValueKey('form-field-f1-person-U-lead')),
      findsNothing,
      reason: '한 사람 칸은 바뀐다',
    );
    expect(
      find.byKey(const ValueKey('form-field-f1-person-U-me')),
      findsOneWidget,
    );

    await _tapKey(tester, 'form-field-f2-pick');
    await _tapKey(tester, 'form-person-U-lead');
    await _tapKey(tester, 'form-person-U-a');
    await _tapKey(tester, 'form-person-done');
    expect(
      find.byKey(const ValueKey('form-field-f2-person-U-lead')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('form-field-f2-person-U-a')),
      findsOneWidget,
    );
    expect(find.text('사람 고르기 (2/10)'), findsOneWidget);
    tester
        .widget<InputChip>(
          find.byKey(const ValueKey('form-field-f2-person-U-lead')),
        )
        .onDeleted!();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('form-field-f2-person-U-lead')),
      findsNothing,
    );
    expect(
      h
          .called('GET', '/api/groupware/candidates')
          .where((r) => r.url.queryParameters['includeSelf'] == '1'),
      hasLength(1),
      reason: '후보는 한 번만 부른다',
    );

    await _enter(tester, 'form-field-f3-0-0', '노트북');
    await _tapKey(tester, 'approval-request-submit');
    final values =
        h.bodyOf(h.called('POST', '/api/groupware/documents').single)['values']
            as Map;
    expect(values['f1'], 'U-me', reason: '한 사람은 id 하나');
    expect(values['f2'], ['U-a'], reason: '여러 명은 id 목록');
  });

  testWidgets('표 칸 — 줄 넣기·더하기·빼기, 합계, 보낸 모양', (tester) async {
    final h = _Harness();
    await _openDialog(tester, h);
    await _tapKey(tester, 'form-field-f1-pick');
    await _tapKey(tester, 'form-person-U-lead');

    expect(
      find.byKey(const ValueKey('form-field-f3-0-0')),
      findsOneWidget,
      reason: '처음엔 빈 줄 하나',
    );
    expect(find.byKey(const ValueKey('form-field-f3-1-0')), findsNothing);
    await _enter(tester, 'form-field-f3-0-0', '모니터');
    await _enter(tester, 'form-field-f3-0-1', '2');
    await _enter(tester, 'form-field-f3-0-2', '250,000');
    await _tapKey(tester, 'form-field-f3-0-3');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await _tapKey(tester, 'form-field-f3-add-row');
    await _enter(tester, 'form-field-f3-1-0', '케이블');
    await _enter(tester, 'form-field-f3-1-1', '3');
    await _enter(tester, 'form-field-f3-1-2', '10000');
    await _tapKey(tester, 'form-field-f3-add-row');
    await _enter(tester, 'form-field-f3-2-0', '어댑터');
    await _enter(tester, 'form-field-f3-2-2', '5000');
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('form-field-f3-totals')))
          .data,
      '수량 합계 5 · 금액 합계 265,000원',
    );

    // 가운데 줄을 빼도 아래 줄 입력이 섞이지 않는다.
    await _tapKey(tester, 'form-field-f3-1-remove');
    expect(find.byKey(const ValueKey('form-field-f3-2-0')), findsNothing);
    expect(_cellText(tester, 'form-field-f3-1-0'), '어댑터');
    expect(_cellText(tester, 'form-field-f3-1-2'), '5000');
    expect(_cellText(tester, 'form-field-f3-0-0'), '모니터');
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('form-field-f3-totals')))
          .data,
      '수량 합계 2 · 금액 합계 255,000원',
    );
    await _tapKey(tester, 'form-field-f3-add-row');

    await _tapKey(tester, 'approval-request-submit');
    final values =
        h.bodyOf(h.called('POST', '/api/groupware/documents').single)['values']
            as Map;
    final rows = (values['f3'] as List).cast<List>();
    expect(rows, hasLength(3), reason: '빈 줄도 그대로(서버가 건너뜀)');
    expect(rows[0].sublist(0, 3), ['모니터', '2', '250000'], reason: '쉼표 빼고');
    expect(rows[0][3], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    expect(rows[1], ['어댑터', '', '5000', '']);
    expect(rows[2], ['', '', '', '']);
    expect(values['f1'], 'U-lead');
    expect(values.containsKey('f2'), isFalse, reason: '안 고른 사람 칸은 빼고 보낸다');
  });

  testWidgets('필수 칸 — 사람·표가 비면 막는다', (tester) async {
    final h = _Harness();
    await _openDialog(tester, h);
    await _tapKey(tester, 'approval-request-submit');
    expect(find.text('"책임자"을(를) 넣으세요.'), findsOneWidget);
    await _tapKey(tester, 'form-field-f1-pick');
    await _tapKey(tester, 'form-person-U-a');
    await _enter(tester, 'form-field-f3-0-0', '   ');
    await _tapKey(tester, 'approval-request-submit');
    expect(
      find.text('"반출 목록"을(를) 넣으세요.'),
      findsOneWidget,
      reason: '빈칸만 있는 줄은 빈 줄',
    );
    expect(h.called('POST', '/api/groupware/documents'), isEmpty);
    await _enter(tester, 'form-field-f3-0-1', '1');
    await _tapKey(tester, 'approval-request-submit');
    expect(h.called('POST', '/api/groupware/documents'), hasLength(1));
  });

  test('문서 금액 — 금액 칸 + 표 칸의 금액 열 합계', () {
    final form = ApprovalForm.fromJson({
      'id': 'F-m',
      'kind': 'form',
      'name': '비용',
      'fields': [
        {'key': 'm', 'label': '선금', 'type': 'money'},
        {'key': 't', 'label': '표', 'type': 'table', 'columns': _columns},
        {
          'key': 'n',
          'label': '숫자만',
          'type': 'table',
          'columns': [
            {'label': '수량', 'type': 'number'},
          ],
        },
      ],
    });
    final values = FormValues(form);
    addTearDown(values.dispose);
    expect(values.documentAmount, isNull);
    values.set('t', [
      ['', '', '', ''],
    ]);
    expect(values.documentAmount, isNull, reason: '빈 줄만이면 없음');
    values
      ..set('m', '70,000')
      ..set('t', [
        ['a', '1', '1,000', ''],
        ['', '', '', ''],
        ['b', '2', '500', ''],
      ])
      ..set('n', [
        ['9'],
      ]);
    expect(values.documentAmount, 71500, reason: '숫자 열은 금액이 아니다');
    expect(values.toJson()['t'], [
      ['a', '1', '1000', ''],
      ['', '', '', ''],
      ['b', '2', '500', ''],
    ]);
  });

  testWidgets('상세 — 사람은 이름들, 표는 열 머리·칸·합계 줄', (tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FormValuesView(doc: ApprovalDocument.fromJson(_doc())),
        ),
      ),
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('form-value-f1'))).data,
      '팀장',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('form-value-f2'))).data,
      '팀장, 김철수',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('form-value-f5'))).data,
      '—',
      reason: '빈 사람 칸',
    );
    final table = find.byKey(const ValueKey('form-value-f3'));
    expect(table, findsOneWidget);
    for (final text in [
      '품명',
      '금액',
      '모니터',
      '250,000원',
      '2026-10-20',
      '합계',
      '5',
      '260,000원',
    ]) {
      expect(
        find.descendant(of: table, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }
  });

  test('인쇄 내용 — 사람은 이름 줄, 표는 머리·줄·합계', () async {
    final doc = ApprovalDocument.fromJson(_doc());
    final content = approvalContentOf(doc, _ctx);
    expect(content.rows, [('책임자', '팀장'), ('동행', '팀장, 김철수'), ('빈 사람', '—')]);
    final t = content.tables.single;
    expect(t.label, '반출 목록');
    expect(t.headers, ['품명', '수량', '금액', '날짜']);
    expect(t.rows, [
      ['모니터', '2', '250,000원', '2026-10-20'],
      ['케이블', '3', '10,000원', ''],
    ]);
    expect(t.totals, ['합계', '5', '260,000원', '']);
    expect(t.numericColumns, {1, 2});
    final bytes = await buildApprovalPdf(doc, _ctx);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  testWidgets('좁은 화면(360px) — 신청 창의 표·사람 칸과 상세 표가 넘치지 않는다', (tester) async {
    final h = _Harness();
    await _openDialog(tester, h, size: const Size(360, 800));
    await _tapKey(tester, 'form-field-f2-pick');
    await _tapKey(tester, 'form-person-U-lead');
    await _tapKey(tester, 'form-person-U-a');
    await _tapKey(tester, 'form-person-U-me');
    await _tapKey(tester, 'form-person-done');
    await _tapKey(tester, 'form-field-f3-add-row');
    await _enter(tester, 'form-field-f3-1-2', '123,456,789');
    await _tapKey(tester, 'form-field-f3-1-3');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FormValuesView(doc: ApprovalDocument.fromJson(_doc())),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
