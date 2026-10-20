// 전결 규정·결재 통계 엑셀·결재 전자서명(앱 관리 탭) — 전결 규정 글(final_rules_section.dart), 목록·만들기(POST)·고치기(PUT)·
// 지우기(확인 뒤 DELETE), 양식 고르기는 "관리자가 만든 양식"일 때만, 직책 목록이 비면 안내, 관리자가 아니면 섹션 없음. 결재 통계의
// "엑셀로 내보내기"는 보고 있는 기간의 내보내기 경로를 Session.downloadAuthedFile로 받고(받는 동안 단추를 막고, 실패하면 알림),
// 결재 전자서명은 펼칠 때만 키를 받아 지문을 보이고 공개 키를 복사한다. 서버는 가짜 HTTP.
import 'dart:async';
import 'dart:convert';

import 'package:client/models/groupware.dart';
import 'package:client/screens/groupware/approval_settings.dart';
import 'package:client/screens/groupware/final_rules_section.dart';
import 'package:client/screens/groupware/groupware_screen.dart'
    show GroupwareChanges;
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/groupware_api.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

const _eduForm = '11111111-1111-4111-8111-111111111111';
const _f1 = '22222222-2222-4222-8222-222222222222';

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

/// 내려받기만 가로채는 세션 — [downloads]에 경로·파일 이름을 적고 [download]가 끝나기를 기다린다(실패로 끝내면 화면이 알림을 띄운다).
class _DownloadSession extends Session {
  _DownloadSession()
    : super(notifications: NotificationService(), settings: AppSettings());
  final downloads = <({String path, String fileName})>[];
  Completer<String> download = Completer<String>();

  @override
  Future<String> downloadAuthedFile(
    String path, {
    required String fileName,
    Map<String, dynamic>? body,
  }) {
    downloads.add((path: path, fileName: fileName));
    return download.future;
  }
}

class _Harness {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{};
  late final _DownloadSession session;
  _Harness({List<String> positions = const ['사원', '팀장', '본부장', '대표']}) {
    routes['GET /api/groupware/final-rules'] = (_) => _json([
      {
        'id': _f1,
        'kind': 'expense',
        'templateId': null,
        'templateName': null,
        'minAmount': 1000000,
        'positionLabel': '본부장',
      },
      {
        'id': 'F2',
        'kind': 'any',
        'templateId': null,
        'minAmount': null,
        'positionLabel': '팀장',
      },
      {
        'id': 'F3',
        'kind': 'form',
        'templateId': _eduForm,
        'templateName': '교육 신청',
        'minAmount': null,
        'positionLabel': '대표',
      },
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
      for (final (i, p) in positions.indexed) {'id': 'P$i', 'label': p},
    ]);
    routes['POST /api/groupware/final-rules'] = (r) =>
        _json({'id': 'F-new', ...bodyOf(r)}, status: 201);
    routes['PUT /api/groupware/final-rules/$_f1'] = (r) =>
        _json({'id': _f1, ...bodyOf(r)});
    routes['DELETE /api/groupware/final-rules/$_f1'] = (_) =>
        _json({'ok': true});
    routes['GET /api/groupware/stats'] = (r) => _json({
      'from': r.url.queryParameters['from'],
      'to': r.url.queryParameters['to'],
      'totals': {
        'total': 2,
        'approved': 1,
        'rejected': 0,
        'pending': 1,
        'avgHours': 2,
      },
      'byKind': [
        {
          'label': '지출',
          'total': 2,
          'approved': 1,
          'rejected': 0,
          'avgHours': 2,
        },
      ],
      'byApprover': [
        {
          'userId': 'U-lead',
          'name': '팀장',
          'decided': 3,
          'approved': 2,
          'rejected': 0,
          'disagreed': 4,
          'proxied': 0,
          'waiting': 1,
          'avgHours': 1.5,
        },
      ],
    });
    routes['GET /api/groupware/seal-key'] = (_) => _json({
      'fingerprint': 'ab:cd:ef:01',
      'publicKey':
          '-----BEGIN PUBLIC KEY-----\nMCow\n-----END PUBLIC KEY-----\n',
      'algorithm': 'Ed25519',
    });
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

Future<void> _pump(WidgetTester tester, Widget child) async {
  _view(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ListView(children: [child])),
    ),
  );
  await tester.pumpAndSettle();
}

Future<GroupwareChanges> _pumpSection(
  WidgetTester tester,
  _Harness h, {
  bool manager = true,
}) async {
  final changes = GroupwareChanges();
  addTearDown(changes.dispose);
  await _pump(
    tester,
    FinalRulesAdminSection(
      api: h.api,
      ctx: _ctx(manager: manager),
      changes: changes,
      session: h.session,
    ),
  );
  return changes;
}

/// 드롭다운을 열고 [label] 항목을 고른다.
Future<void> _choose(WidgetTester tester, String key, String label) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// 규정 줄의 메뉴를 열고 [label]을 누른다.
Future<void> _menu(WidgetTester tester, String id, String label) async {
  await tester.tap(find.byKey(ValueKey('gw-final-rule-menu-$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  test('규정 글 — 종류·금액 → 직책 이상 전결', () {
    expect(
      finalRuleSentence(
        const ApprovalFinalRule(
          id: 'x',
          kind: 'expense',
          minAmount: 10000000,
          positionLabel: '대표',
        ),
      ),
      '지출 · 1,000만 원 이상 → 대표 이상 전결',
    );
    expect(
      finalRuleSentence(
        const ApprovalFinalRule(id: 'x', kind: 'any', positionLabel: '팀장'),
      ),
      '모든 결재 → 팀장 이상 전결',
    );
    expect(
      finalRuleSentence(
        const ApprovalFinalRule(
          id: 'x',
          kind: 'form',
          templateId: _eduForm,
          positionLabel: '본부장',
        ),
      ),
      '관리자가 만든 양식 1개 → 본부장 이상 전결',
      reason: '양식 이름을 모르면',
    );
  });

  testWidgets('목록 — 규정을 글로 보이고 설명·예시가 있다', (tester) async {
    final h = _Harness();
    await _pumpSection(tester, h);
    expect(find.text('전결 규정'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('gw-final-rule-$_f1')),
        matching: find.text('지출 · 100만 원 이상 → 본부장 이상 전결'),
      ),
      findsOneWidget,
    );
    expect(find.text('모든 결재 → 팀장 이상 전결'), findsOneWidget);
    expect(find.text('"교육 신청" 양식 → 대표 이상 전결'), findsOneWidget);
    expect(find.textContaining('결재 종류와 금액마다 누가 전결할지 정합니다.'), findsOneWidget);
    expect(find.textContaining('예: 지출 → 팀장 전결'), findsOneWidget);
    expect(find.byKey(const ValueKey('gw-final-rule-add')), findsOneWidget);
    expect(find.byKey(ValueKey('gw-final-rule-menu-$_f1')), findsOneWidget);
  });

  testWidgets('만들기 — 종류·금액·직책을 POST, 저장한 뒤 다시 받는다', (tester) async {
    final h = _Harness();
    await _pumpSection(tester, h);
    await tester.tap(find.byKey(const ValueKey('gw-final-rule-add')));
    await tester.pumpAndSettle();
    await _choose(tester, 'gw-final-rule-kind', '지출');
    await tester.enterText(
      find.byKey(const ValueKey('gw-final-rule-amount')),
      '10000000',
    );
    await tester.pump();
    expect(find.text('10,000,000원(1,000만 원) 이상인 문서에 씁니다.'), findsOneWidget);
    // 직책을 안 고르면 저장하지 않는다.
    await tester.tap(find.byKey(const ValueKey('gw-final-rule-save')));
    await tester.pumpAndSettle();
    expect(find.text('전결할 직책을 고르세요.'), findsOneWidget);
    expect(h.called('POST', '/api/groupware/final-rules'), isEmpty);
    await _choose(tester, 'gw-final-rule-position', '대표');
    await tester.tap(find.byKey(const ValueKey('gw-final-rule-save')));
    await tester.pumpAndSettle();
    expect(h.bodyOf(h.called('POST', '/api/groupware/final-rules').single), {
      'teamId': 'T1',
      'kind': 'expense',
      'templateId': null,
      'minAmount': 10000000,
      'positionLabel': '대표',
    });
    expect(find.text('전결 규정을 만들었습니다.'), findsOneWidget);
    expect(h.called('GET', '/api/groupware/final-rules'), hasLength(2));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('고치기 — 메뉴의 "고치기"는 처음 값을 채우고 PUT', (tester) async {
    final h = _Harness();
    await _pumpSection(tester, h);
    await _menu(tester, _f1, '고치기');
    expect(find.text('전결 규정 고치기'), findsOneWidget);
    expect(find.text('1000000'), findsOneWidget, reason: '금액 기준을 채운다');
    await tester.enterText(
      find.byKey(const ValueKey('gw-final-rule-amount')),
      '',
    );
    await _choose(tester, 'gw-final-rule-position', '팀장');
    await tester.tap(find.byKey(const ValueKey('gw-final-rule-save')));
    await tester.pumpAndSettle();
    expect(
      h.bodyOf(h.called('PUT', '/api/groupware/final-rules/$_f1').single),
      {
        'teamId': 'T1',
        'kind': 'expense',
        'templateId': null,
        'minAmount': null,
        'positionLabel': '팀장',
      },
    );
    expect(find.text('전결 규정을 고쳤습니다.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('지우기 — 확인한 뒤 DELETE, 취소하면 그대로', (tester) async {
    final h = _Harness();
    await _pumpSection(tester, h);
    await _menu(tester, _f1, '지우기');
    expect(find.textContaining('규정을 지울까요?'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(h.called('DELETE', '/api/groupware/final-rules/$_f1'), isEmpty);
    await _menu(tester, _f1, '지우기');
    await tester.tap(
      find.byKey(const ValueKey('gw-final-rule-delete-confirm')),
    );
    await tester.pumpAndSettle();
    expect(h.called('DELETE', '/api/groupware/final-rules/$_f1'), hasLength(1));
    expect(h.called('GET', '/api/groupware/final-rules'), hasLength(2));
  });

  testWidgets('양식 고르기는 "관리자가 만든 양식"일 때만 — 만든 양식만 보인다', (tester) async {
    final h = _Harness();
    await _pumpSection(tester, h);
    await tester.tap(find.byKey(const ValueKey('gw-final-rule-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('gw-final-rule-form')), findsNothing);
    await _choose(tester, 'gw-final-rule-kind', '관리자가 만든 양식');
    expect(find.byKey(const ValueKey('gw-final-rule-form')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('gw-final-rule-form')));
    await tester.pumpAndSettle();
    expect(find.text('일반 기안서'), findsNothing, reason: '기본 양식은 고르지 않는다');
    await tester.tap(find.text('교육 신청').last);
    await tester.pumpAndSettle();
    await _choose(tester, 'gw-final-rule-position', '본부장');
    await tester.tap(find.byKey(const ValueKey('gw-final-rule-save')));
    await tester.pumpAndSettle();
    final body = h.bodyOf(
      h.called('POST', '/api/groupware/final-rules').single,
    );
    expect(body['kind'], 'form');
    expect(body['templateId'], _eduForm);
    expect(body['positionLabel'], '본부장');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('종류를 양식에서 다른 것으로 바꾸면 양식 고르기가 사라지고 templateId는 보내지 않는다', (
    tester,
  ) async {
    final h = _Harness();
    await _pumpSection(tester, h);
    await tester.tap(find.byKey(const ValueKey('gw-final-rule-add')));
    await tester.pumpAndSettle();
    await _choose(tester, 'gw-final-rule-kind', '관리자가 만든 양식');
    await _choose(tester, 'gw-final-rule-form', '교육 신청');
    await _choose(tester, 'gw-final-rule-kind', '휴가');
    expect(find.byKey(const ValueKey('gw-final-rule-form')), findsNothing);
    await _choose(tester, 'gw-final-rule-position', '팀장');
    await tester.tap(find.byKey(const ValueKey('gw-final-rule-save')));
    await tester.pumpAndSettle();
    final body = h.bodyOf(
      h.called('POST', '/api/groupware/final-rules').single,
    );
    expect(body['kind'], 'leave');
    expect(body['templateId'], isNull);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('직책 목록이 비면 안내하고 저장하지 않는다', (tester) async {
    final h = _Harness(positions: const []);
    await _pumpSection(tester, h);
    await tester.tap(find.byKey(const ValueKey('gw-final-rule-add')));
    await tester.pumpAndSettle();
    expect(find.text('직책 목록이 비어 있습니다 — 관리자 콘솔에서 직책을 먼저 만드세요.'), findsOneWidget);
    expect(find.byKey(const ValueKey('gw-final-rule-position')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('gw-final-rule-save')));
    await tester.pumpAndSettle();
    expect(h.called('POST', '/api/groupware/final-rules'), isEmpty);
  });

  testWidgets('바뀜 알림(changes)이 오면 다시 받는다', (tester) async {
    final h = _Harness();
    final changes = await _pumpSection(tester, h);
    expect(h.called('GET', '/api/groupware/final-rules'), hasLength(1));
    changes.bump();
    await tester.pumpAndSettle();
    expect(h.called('GET', '/api/groupware/final-rules'), hasLength(2));
  });

  testWidgets('관리자가 아니면 섹션이 없고 부르지도 않는다', (tester) async {
    final h = _Harness();
    await _pumpSection(tester, h, manager: false);
    expect(find.text('전결 규정'), findsNothing);
    expect(find.byKey(const ValueKey('gw-final-rule-add')), findsNothing);
    expect(h.called('GET', '/api/groupware/final-rules'), isEmpty);
  });

  testWidgets('결재 통계 — 반대 수, 엑셀로 내보내기(보고 있는 기간, 받는 동안 막힘, 실패 알림)', (
    tester,
  ) async {
    final h = _Harness();
    await _pump(
      tester,
      ApprovalStatsSection(api: h.api, ctx: _ctx(), session: h.session),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('gw-stats-approver-U-lead')),
        matching: find.text('4'),
      ),
      findsOneWidget,
      reason: '반대 칸',
    );
    expect(find.text('반대'), findsOneWidget);
    // 이전 달로 넘겨 그 달 전체를 받는다.
    await tester.tap(find.byTooltip('이전 달'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('gw-stats-export')));
    await tester.pump();
    final d = h.session.downloads.single;
    expect(
      d.path,
      '/api/groupware/stats/export?teamId=T1&from=2026-09-01&to=2026-09-30',
    );
    expect(d.fileName, '결재통계_본사_2026-09-01_2026-09-30.xlsx');
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('gw-stats-export')))
          .onPressed,
      isNull,
      reason: '받는 동안 다시 못 누른다',
    );
    h.session.download.completeError(const ApiException('디스크가 가득 찼습니다.'));
    await tester.pumpAndSettle();
    expect(find.text('실패: 디스크가 가득 찼습니다.'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('gw-stats-export')))
          .onPressed,
      isNotNull,
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('결재 통계 — 세션이 없으면 내보내기 단추가 없다', (tester) async {
    final h = _Harness();
    await _pump(tester, ApprovalStatsSection(api: h.api, ctx: _ctx()));
    expect(find.byKey(const ValueKey('gw-stats-export')), findsNothing);
  });

  testWidgets('결재 전자서명 — 펼칠 때만 키를 받아 지문을 보이고 공개 키를 복사', (tester) async {
    final h = _Harness();
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pump(tester, ApprovalSealKeySection(api: h.api));
    expect(find.text('결재 전자서명'), findsOneWidget);
    expect(h.called('GET', '/api/groupware/seal-key'), isEmpty);
    await tester.tap(find.byKey(const ValueKey('gw-seal-key')));
    await tester.pumpAndSettle();
    expect(h.called('GET', '/api/groupware/seal-key'), hasLength(1));
    expect(find.textContaining('서버가 그 결정을 이 키로 서명합니다.'), findsOneWidget);
    expect(find.text('ab:cd:ef:01'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('gw-seal-key-copy')));
    await tester.pumpAndSettle();
    expect(copied, [
      '-----BEGIN PUBLIC KEY-----\nMCow\n-----END PUBLIC KEY-----\n',
    ]);
    expect(find.text('공개 키를 복사했습니다.'), findsOneWidget);
    // 접었다 다시 펼쳐도 다시 부르지 않는다.
    await tester.tap(find.text('결재 전자서명'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('결재 전자서명'));
    await tester.pumpAndSettle();
    expect(h.called('GET', '/api/groupware/seal-key'), hasLength(1));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('결재 전자서명 — 못 받으면 까닭을 보인다', (tester) async {
    final h = _Harness();
    h.routes['GET /api/groupware/seal-key'] = (_) =>
        _json({'error': '서명 키가 없습니다.'}, status: 500);
    await _pump(tester, ApprovalSealKeySection(api: h.api));
    await tester.tap(find.byKey(const ValueKey('gw-seal-key')));
    await tester.pumpAndSettle();
    expect(find.text('키를 불러오지 못했습니다: 서명 키가 없습니다.'), findsOneWidget);
    expect(find.byKey(const ValueKey('gw-seal-key-copy')), findsNothing);
  });
}
