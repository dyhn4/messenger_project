// 결재 양식(앱) — 양식·칸 모양 읽기, 목록 요약·종류 이름, "새 결재"에서 양식 고르기, 양식 신청 창(품목 표 합계·시간대·필수 칸·제목),
// 상세의 칸·품목 표, 관리 탭의 양식 만들기·켜고 끄기, 근태의 출장·연장근무 표시. 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/groupware.dart';
import 'package:client/screens/groupware/approval_form_admin.dart';
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

Map<String, dynamic> _field(
  String key,
  String label,
  String type, {
  bool required = false,
  List<String>? options,
}) => {
  'key': key,
  'label': label,
  'type': type,
  'required': required,
  'options': ?options,
};

List<Map<String, dynamic>> _forms({bool purchaseEnabled = true}) => [
  {
    'id': 'builtin:draft',
    'kind': 'draft',
    'builtin': true,
    'name': '일반 기안서',
    'description': '품의서',
    'fields': [
      _field('content', '기안 내용', 'textarea', required: true),
      _field('budget', '예산(원)', 'money'),
    ],
    'allowAttachments': true,
    'enabled': true,
  },
  {
    'id': 'builtin:purchase',
    'kind': 'purchase',
    'builtin': true,
    'name': '구매 요청',
    'fields': [
      _field('items', '구매 품목', 'items', required: true),
      _field('reason', '구매 사유', 'textarea', required: true),
    ],
    'allowAttachments': false,
    'enabled': purchaseEnabled,
  },
  {
    'id': 'builtin:overtime',
    'kind': 'overtime',
    'builtin': true,
    'name': '연장근무 신청',
    'fields': [
      _field('workDate', '근무일', 'date', required: true),
      _field('time', '근무 시간', 'timeRange', required: true),
      _field(
        'overtimeType',
        '종류',
        'select',
        required: true,
        options: ['연장근무', '야간근무'],
      ),
    ],
    'allowAttachments': false,
    'enabled': true,
  },
  {
    'id': 'F-edu',
    'kind': 'form',
    'builtin': false,
    'name': '교육 신청',
    'fields': [_field('f1', '교육명', 'text', required: true)],
    'allowAttachments': false,
    'enabled': true,
  },
];

Map<String, dynamic> _purchaseDoc() => {
  'id': 'D-p',
  'kind': 'purchase',
  'title': '구매 요청 — 모니터 외 1건 (530,000원)',
  'payload': {
    'templateId': null,
    'templateName': '구매 요청',
    'fields': [
      _field('items', '구매 품목', 'items'),
      _field('reason', '구매 사유', 'textarea'),
      _field('vendor', '구매처', 'text'),
    ],
    'values': {
      'items': {
        'rows': [
          {'name': '모니터', 'qty': 2, 'unitPrice': 250000, 'amount': 500000},
          {'name': '케이블', 'qty': 3, 'unitPrice': 10000, 'amount': 30000},
        ],
        'total': 530000,
      },
      'reason': '신규 입사자 자리',
      'vendor': null,
    },
    'total': 530000,
    'itemCount': 2,
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
  _Harness({bool purchaseEnabled = true}) {
    routes['GET /api/groupware/forms'] = (_) =>
        _json(_forms(purchaseEnabled: purchaseEnabled));
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
      final b = jsonDecode(r.body) as Map<String, dynamic>;
      return _json({
        ..._purchaseDoc(),
        'id': 'D-new',
        'kind': b['kind'],
        'title': b['title'] ?? '자동 제목',
      }, status: 201);
    };
    routes['GET /api/groupware/documents/D-p'] = (_) => _json(_purchaseDoc());
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

Future<void> _pumpTab(WidgetTester tester, _Harness h) async {
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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

Future<void> _openForm(WidgetTester tester, String formId) async {
  await tester.tap(find.byKey(const ValueKey('approval-new')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('new-approval-$formId')));
  await tester.pumpAndSettle();
}

void main() {
  group('모양 읽기', () {
    test('양식·칸, 값 글자, 종류 이름·요약', () {
      final forms = [for (final f in _forms()) ApprovalForm.fromJson(f)];
      expect(forms.map((f) => f.kind), [
        ApprovalKind.draft,
        ApprovalKind.purchase,
        ApprovalKind.overtime,
        ApprovalKind.form,
      ]);
      expect(forms[2].fields[2].options, ['연장근무', '야간근무']);
      expect(forms.every((f) => f.kind.isForm), isTrue);
      expect(ApprovalKind.leave.isForm, isFalse);
      const money = FormFieldDef(
        key: 'm',
        label: '금액',
        type: FormFieldType.money,
      );
      expect(formValueText(money, 1500000), '1,500,000원');
      const range = FormFieldDef(
        key: 'r',
        label: '기간',
        type: FormFieldType.dateRange,
      );
      expect(
        formValueText(range, {'start': '2026-10-20', 'end': '2026-10-22'}),
        '2026-10-20 ~ 2026-10-22',
      );
      const time = FormFieldDef(
        key: 't',
        label: '시간',
        type: FormFieldType.timeRange,
      );
      expect(
        formValueText(time, {
          'start': '22:00',
          'end': '01:30',
          'minutes': 210,
          'overnight': true,
        }),
        '22:00 ~ 01:30(다음 날) (3시간 30분)',
      );
      expect(formValueText(money, null), isNull);

      final purchase = ApprovalDocument.fromJson(_purchaseDoc());
      expect(purchase.summary(_ctx), '품목 2건 · 530,000원');
      expect(purchase.kindLabel, '구매');
      final custom = ApprovalDocument.fromJson({
        ..._purchaseDoc(),
        'kind': 'form',
        'payload': {'templateName': '교육 신청', 'fields': [], 'values': {}},
      });
      expect(custom.kindLabel, '교육 신청');
      expect(custom.summary(_ctx), '교육 신청');
      final trip = ApprovalDocument.fromJson({
        ..._purchaseDoc(),
        'kind': 'trip',
        'payload': {
          'destination': '부산',
          'startDate': '2026-10-20',
          'endDate': '2026-10-22',
          'days': 3,
        },
      });
      expect(trip.summary(_ctx), '부산 · 10/20~10/22 · 3일');
      final ot = ApprovalDocument.fromJson({
        ..._purchaseDoc(),
        'kind': 'overtime',
        'payload': {
          'overtimeType': '야간근무',
          'workDate': '2026-10-16',
          'startTime': '22:00',
          'endTime': '01:30',
          'minutes': 210,
        },
      });
      expect(ot.summary(_ctx), '야간근무 · 10/16 22:00~01:30 · 3.5시간');
      expect(
        ApprovalKind.fromWire('nope'),
        ApprovalKind.form,
        reason: '모르는 종류는 양식으로',
      );
    });

    test('근태의 출장·연장근무', () {
      final day = AttendanceDay.fromJson({
        'date': '2026-10-16',
        'trip': true,
        'overtimeMinutes': 90,
      });
      expect(day.trip, isTrue);
      expect(day.overtimeMinutes, 90);
      final summary = AttendanceSummary.fromJson({
        'tripDays': 2,
        'overtimeMinutes': 270,
      });
      expect(summary.tripDays, 2);
      expect(summary.overtimeText, '4.5시간');
    });
  });

  testWidgets('"새 결재" — 휴가·지출과 켜진 양식만 고를 수 있다', (tester) async {
    final h = _Harness(purchaseEnabled: false);
    await _pumpTab(tester, h);
    await tester.tap(find.byKey(const ValueKey('approval-new')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('new-approval-leave')), findsOneWidget);
    expect(find.byKey(const ValueKey('new-approval-expense')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('new-approval-builtin:draft')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('new-approval-builtin:purchase')),
      findsNothing,
      reason: '꺼진 양식',
    );
    expect(find.byKey(const ValueKey('new-approval-F-edu')), findsOneWidget);
    expect(find.text('품의서'), findsOneWidget, reason: '설명');
  });

  testWidgets('구매 요청 — 품목 표 합계, 빈 사유는 막고, 올리면 품목·사유를 보낸다', (tester) async {
    final h = _Harness();
    await _pumpTab(tester, h);
    await _openForm(tester, 'builtin:purchase');
    expect(
      find.byKey(const ValueKey('approval-request-body')),
      findsNothing,
      reason: '양식은 사유 칸 대신 양식 칸',
    );
    await tester.enterText(
      find.byKey(const ValueKey('form-item-0-name')),
      '모니터',
    );
    await tester.enterText(find.byKey(const ValueKey('form-item-0-qty')), '2');
    await tester.enterText(
      find.byKey(const ValueKey('form-item-0-price')),
      '250,000',
    );
    await tester.tap(find.byKey(const ValueKey('form-item-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('form-item-1-name')),
      '케이블',
    );
    await tester.enterText(find.byKey(const ValueKey('form-item-1-qty')), '3');
    await tester.enterText(
      find.byKey(const ValueKey('form-item-1-price')),
      '10000',
    );
    await tester.pump();
    expect(find.text('합계 530,000원'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('approval-request-submit')));
    await tester.pumpAndSettle();
    expect(find.text('"구매 사유"을(를) 넣으세요.'), findsOneWidget);
    expect(h.called('POST', '/api/groupware/documents'), isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('form-field-reason')),
      '신규 입사자 자리',
    );
    await tester.tap(find.byKey(const ValueKey('approval-request-submit')));
    await tester.pumpAndSettle();
    final body = h.bodyOf(h.called('POST', '/api/groupware/documents').single);
    expect(body['kind'], 'purchase');
    expect(body.containsKey('formId'), isFalse, reason: '기본 양식은 종류로');
    expect(body['approverIds'], [_lead], reason: '조직도 추천 결재선');
    expect(body['values'], {
      'items': [
        {'name': '모니터', 'qty': '2', 'unitPrice': '250000'},
        {'name': '케이블', 'qty': '3', 'unitPrice': '10000'},
      ],
      'reason': '신규 입사자 자리',
    });
    expect(body.containsKey('title'), isFalse, reason: '비우면 서버가 자동 제목');
    expect(find.textContaining('결재를 올렸습니다'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('연장근무 — 시간대는 HH:MM, 고르기, 날짜', (tester) async {
    final h = _Harness();
    await _pumpTab(tester, h);
    await _openForm(tester, 'builtin:overtime');
    await tester.enterText(
      find.byKey(const ValueKey('form-field-time-start')),
      '22:00',
    );
    await tester.enterText(
      find.byKey(const ValueKey('form-field-time-end')),
      '1시',
    );
    await tester.tap(find.byKey(const ValueKey('approval-request-submit')));
    await tester.pumpAndSettle();
    expect(find.text('"근무일"을(를) 넣으세요.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('form-field-workDate')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('approval-request-submit')));
    await tester.pumpAndSettle();
    expect(find.text('"근무 시간"을(를) HH:MM으로 넣으세요.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('form-field-time-end')),
      '01:30',
    );
    await tester.tap(find.byKey(const ValueKey('form-field-overtimeType')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('야간근무').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('approval-request-submit')));
    await tester.pumpAndSettle();
    final values =
        h.bodyOf(h.called('POST', '/api/groupware/documents').single)['values']
            as Map;
    expect(values['time'], {'start': '22:00', 'end': '01:30'});
    expect(values['overtimeType'], '야간근무');
    expect(values['workDate'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('일반 기안서는 제목이 필요하고, 직접 만든 양식은 formId로 올린다', (tester) async {
    final h = _Harness();
    await _pumpTab(tester, h);
    await _openForm(tester, 'builtin:draft');
    expect(
      find.byKey(const ValueKey('form-attach')),
      findsOneWidget,
      reason: '첨부 받는 양식',
    );
    await tester.enterText(
      find.byKey(const ValueKey('form-field-content')),
      '워크숍 개최의 건',
    );
    await tester.tap(find.byKey(const ValueKey('approval-request-submit')));
    await tester.pumpAndSettle();
    expect(find.text('제목을 넣으세요.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('form-title')),
      '하반기 워크숍 품의',
    );
    await tester.tap(find.byKey(const ValueKey('approval-request-submit')));
    await tester.pumpAndSettle();
    final draft = h.bodyOf(h.called('POST', '/api/groupware/documents').single);
    expect(draft['title'], '하반기 워크숍 품의');
    await tester.pump(const Duration(seconds: 3));

    await _openForm(tester, 'F-edu');
    expect(find.byKey(const ValueKey('form-attach')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('form-field-f1')),
      '보안 교육',
    );
    await tester.tap(find.byKey(const ValueKey('approval-request-submit')));
    await tester.pumpAndSettle();
    final custom = h.bodyOf(h.called('POST', '/api/groupware/documents').last);
    expect(custom['kind'], 'form');
    expect(custom['formId'], 'F-edu');
    expect(custom['values'], {'f1': '보안 교육'});
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('상세 — 올릴 때의 칸으로 품목 표·여러 줄 글·빈 칸을 그린다', (tester) async {
    final h = _Harness();
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ApprovalDetailDialog(
            api: h.api,
            ctx: _ctx,
            session: h.session,
            documentId: 'D-p',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('구매 · 홍길동'), findsOneWidget);
    expect(find.byKey(const ValueKey('form-value-items')), findsOneWidget);
    expect(find.text('모니터'), findsOneWidget);
    expect(find.text('500,000원'), findsOneWidget);
    expect(find.text('합계 530,000원'), findsOneWidget);
    expect(find.text('신규 입사자 자리'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('form-value-vendor'))).data,
      '—',
    );
  });

  testWidgets('관리 — 양식 만들기(칸·고를 거리·필수·첨부), 기본 양식 끄기', (tester) async {
    final h = _Harness();
    h.routes['POST /api/groupware/forms'] = (r) =>
        _json({..._forms()[3], 'id': 'F-new'}, status: 201);
    h.routes['PATCH /api/groupware/forms/builtin:purchase'] = (_) =>
        _json({..._forms()[1], 'enabled': false});
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final changes = GroupwareChanges();
    addTearDown(changes.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ApprovalFormsAdminSection(api: h.api, changes: changes),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('교육 신청 (직접 만든 양식)'), findsOneWidget);
    // 기본 양식의 ⋯ 메뉴는 "기본 결재선"뿐 — 고치기·지우기는 없다.
    await tester.tap(find.byKey(const ValueKey('gw-form-menu-builtin:draft')));
    await tester.pumpAndSettle();
    expect(find.text('기본 결재선'), findsOneWidget);
    expect(find.text('고치기'), findsNothing, reason: '기본 양식은 고치지 못한다');
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('gw-form-enabled-builtin:purchase')),
    );
    await tester.pumpAndSettle();
    expect(
      h.bodyOf(
        h.called('PATCH', '/api/groupware/forms/builtin:purchase').single,
      ),
      {'teamId': 'T1', 'enabled': false},
    );

    await tester.tap(find.byKey(const ValueKey('gw-form-create')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('gw-form-name')), '장비 대여');
    await tester.enterText(
      find.byKey(const ValueKey('gw-form-field-0-label')),
      '장비명',
    );
    await tester.tap(find.byKey(const ValueKey('gw-form-field-0-required')));
    await tester.tap(find.byKey(const ValueKey('gw-form-field-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('gw-form-field-1-label')),
      '용도',
    );
    await tester.tap(find.byKey(const ValueKey('gw-form-field-1-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('고르기').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('gw-form-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('고를 거리를 쉼표로 나눠'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('gw-form-field-1-options')),
      '업무, 교육',
    );
    await tester.tap(find.byKey(const ValueKey('gw-form-attachments')));
    await tester.tap(find.byKey(const ValueKey('gw-form-save')));
    await tester.pumpAndSettle();
    expect(h.bodyOf(h.called('POST', '/api/groupware/forms').single), {
      'teamId': 'T1',
      'name': '장비 대여',
      'fields': [
        {'label': '장비명', 'type': 'text', 'required': true},
        {
          'label': '용도',
          'type': 'select',
          'required': false,
          'options': ['업무', '교육'],
        },
      ],
      'allowAttachments': true,
    });
    await tester.pump(const Duration(seconds: 3));
  });
}
