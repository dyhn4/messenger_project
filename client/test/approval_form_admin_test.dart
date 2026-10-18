// 관리 탭의 결재 양식 편집(approval_form_admin.dart) — 칸 끌어 옮기기(서버 key 유지)·칸 설명·사람 칸 "여러 명"·표 칸의 열 편집과 검사,
// 양식마다(기본 양식도)의 기본 결재선·참조자 창(역할 바꾸기·전결 한 명·순서·참조자·비우기·알 수 없는 사람). 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/screens/groupware/approval_form_admin.dart';
import 'package:client/screens/groupware/groupware_screen.dart'
    show GroupwareChanges;
import 'package:client/services/api_client.dart';
import 'package:client/services/groupware_api.dart';
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

/// 가짜 서버 — 양식 목록은 [forms]를 그대로 주고, PATCH는 [onPatch]가 있으면 그것으로(없으면 보낸 기본값을 목록에 입혀 돌려준다).
class _Harness {
  final requests = <http.Request>[];
  late List<Map<String, dynamic>> forms;
  http.Response Function(http.Request)? onPatch;
  late final GroupwareApi api;

  _Harness() {
    forms = [
      {
        'id': 'builtin:draft',
        'kind': 'draft',
        'builtin': true,
        'name': '일반 기안서',
        'fields': [
          {
            'key': 'content',
            'label': '기안 내용',
            'type': 'textarea',
            'required': true,
          },
        ],
        'allowAttachments': true,
        'enabled': true,
        'defaultLine': [
          {'userId': 'U-gone', 'role': 'approve'},
        ],
        'defaultCcIds': [],
      },
      {
        'id': 'F-edu',
        'kind': 'form',
        'builtin': false,
        'name': '교육 신청',
        'fields': [
          {'key': 'f1', 'label': '교육명', 'type': 'text', 'required': true},
          {
            'key': 'f2',
            'label': '장소',
            'type': 'text',
            'required': false,
            'help': '건물·층',
          },
        ],
        'allowAttachments': false,
        'enabled': true,
        'defaultLine': [
          {'userId': 'U-a', 'role': 'final'},
        ],
        'defaultCcIds': ['U-b'],
      },
    ];
    api = GroupwareApi(
      ApiClient(
        baseUrl: 'https://test.local',
        token: 't',
        httpClient: MockClient((request) async {
          requests.add(request);
          final route = '${request.method} ${request.url.path}';
          if (route == 'GET /api/groupware/forms') return _json(forms);
          if (route == 'GET /api/groupware/candidates') {
            return _json([
              {'id': 'U-lead', 'name': '팀장', 'username': 'lead'},
              {'id': 'U-a', 'name': '김부장', 'username': 'kim'},
              {'id': 'U-b', 'name': '이과장', 'username': 'lee'},
            ]);
          }
          if (route == 'POST /api/groupware/forms') {
            return _json({...forms[1], 'id': 'F-new'}, status: 201);
          }
          if (request.method == 'PATCH') {
            if (onPatch != null) return onPatch!(request);
            final id = request.url.pathSegments.last;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final i = forms.indexWhere((f) => f['id'] == id);
            forms[i] = {
              ...forms[i],
              if (body.containsKey('defaultLine'))
                'defaultLine': body['defaultLine'],
              if (body.containsKey('defaultCcIds'))
                'defaultCcIds': body['defaultCcIds'],
            };
            return _json(forms[i]);
          }
          return _json({'error': 'no route'}, status: 404);
        }),
      ),
      teamId: 'T1',
    );
  }

  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
  Map<String, dynamic> bodyOf(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;
}

Future<void> _pump(WidgetTester tester, _Harness h) async {
  tester.view.physicalSize = const Size(1200, 1800);
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
}

Future<void> _openMenu(WidgetTester tester, String formId, String item) async {
  await tester.tap(find.byKey(ValueKey('gw-form-menu-$formId')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

/// 드롭다운을 열고 [label] 항목을 고른다(닫힌 드롭다운에도 같은 글이 숨어 있어 마지막 것 — 열린 메뉴).
Future<void> _choose(WidgetTester tester, String key, String label) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Finder _text(String key) => find.byKey(ValueKey(key));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('양식 고치기 — 끌어 옮겨도 칸 key를 그대로 보내고, 칸 설명·사람 칸 "여러 명"을 보낸다', (
    tester,
  ) async {
    final h = _Harness();
    await _pump(tester, h);
    expect(find.textContaining('기본 결재선 1명'), findsNWidgets(2));
    expect(find.textContaining('기본 참조 1명'), findsOneWidget);

    await _openMenu(tester, 'F-edu', '고치기');
    expect(
      tester.widget<TextField>(_text('gw-form-field-1-help')).controller!.text,
      '건물·층',
    );

    // 첫 칸(교육명)의 손잡이를 둘째 칸 아래로.
    await tester.drag(_text('gw-form-field-0-drag'), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(_text('gw-form-field-0-label')).controller!.text,
      '장소',
    );
    expect(
      tester.widget<TextField>(_text('gw-form-field-1-label')).controller!.text,
      '교육명',
    );
    await tester.enterText(_text('gw-form-field-1-help'), '  정식 과정 이름  ');
    await tester.enterText(_text('gw-form-field-0-help'), '');

    await tester.tap(_text('gw-form-field-add'));
    await tester.pumpAndSettle();
    await tester.enterText(_text('gw-form-field-2-label'), '강사');
    expect(_text('gw-form-field-2-multiple'), findsNothing);
    await _choose(tester, 'gw-form-field-2-type', '사람');
    await tester.tap(_text('gw-form-field-2-multiple'));
    await tester.pumpAndSettle();

    await tester.tap(_text('gw-form-save'));
    await tester.pumpAndSettle();
    final body = h.bodyOf(
      h.called('PATCH', '/api/groupware/forms/F-edu').single,
    );
    expect(body['fields'], [
      {'key': 'f2', 'label': '장소', 'type': 'text', 'required': false},
      {
        'key': 'f1',
        'label': '교육명',
        'type': 'text',
        'required': true,
        'help': '정식 과정 이름',
      },
      {'label': '강사', 'type': 'person', 'required': false, 'multiple': true},
    ]);
  });

  testWidgets('표 칸 — 빈 열 하나로 시작, 빈 이름·겹치는 이름은 막고, 열 이름·종류를 보낸다', (
    tester,
  ) async {
    final h = _Harness();
    await _pump(tester, h);
    await tester.tap(_text('gw-form-create'));
    await tester.pumpAndSettle();
    await tester.enterText(_text('gw-form-name'), '참석 명단');
    await tester.enterText(_text('gw-form-field-0-label'), '참석자');
    expect(_text('gw-form-field-0-col-0-label'), findsNothing);
    await _choose(tester, 'gw-form-field-0-type', '표');
    expect(_text('gw-form-field-0-col-0-label'), findsOneWidget);
    expect(_text('gw-form-field-0-col-1-label'), findsNothing);

    await tester.tap(_text('gw-form-save'));
    await tester.pumpAndSettle();
    expect(find.text('"참석자" 표의 1번째 열 이름을 넣으세요.'), findsOneWidget);

    await tester.enterText(_text('gw-form-field-0-col-0-label'), '이름');
    await tester.tap(_text('gw-form-field-0-col-add'));
    await tester.pumpAndSettle();
    await tester.enterText(_text('gw-form-field-0-col-1-label'), ' 이름 ');
    await tester.tap(_text('gw-form-save'));
    await tester.pumpAndSettle();
    expect(find.text('"참석자" 표에 "이름" 열이 두 번 있습니다.'), findsOneWidget);
    expect(h.called('POST', '/api/groupware/forms'), isEmpty);

    await tester.enterText(_text('gw-form-field-0-col-1-label'), '참가비');
    await _choose(tester, 'gw-form-field-0-col-1-type', '금액(원)');
    // 열을 하나 더 넣었다 빼면 나머지 열은 그대로.
    await tester.tap(_text('gw-form-field-0-col-add'));
    await tester.pumpAndSettle();
    await tester.enterText(_text('gw-form-field-0-col-2-label'), '비고');
    await tester.tap(_text('gw-form-field-0-col-0-remove'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(_text('gw-form-field-0-col-0-label'))
          .controller!
          .text,
      '참가비',
      reason: '첫 열을 빼면 둘째 열이 올라온다',
    );
    expect(
      find.descendant(
        of: _text('gw-form-field-0-col-0-type'),
        matching: find.text('금액(원)'),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(_text('gw-form-field-0-col-1-label'))
          .controller!
          .text,
      '비고',
    );
  });

  testWidgets('표 칸 — 열은 최대 8개, 저장하면 열 이름·종류를 보낸다', (tester) async {
    final h = _Harness();
    await _pump(tester, h);
    await tester.tap(_text('gw-form-create'));
    await tester.pumpAndSettle();
    await tester.enterText(_text('gw-form-name'), '참석 명단');
    await tester.enterText(_text('gw-form-field-0-label'), '참석자');
    await _choose(tester, 'gw-form-field-0-type', '표');
    await tester.enterText(_text('gw-form-field-0-col-0-label'), '이름');
    await tester.tap(_text('gw-form-field-0-col-add'));
    await tester.pumpAndSettle();
    await tester.enterText(_text('gw-form-field-0-col-1-label'), '참가비');
    await _choose(tester, 'gw-form-field-0-col-1-type', '금액(원)');
    for (var j = 2; j < 8; j++) {
      await tester.tap(_text('gw-form-field-0-col-add'));
      await tester.pumpAndSettle();
      await tester.enterText(_text('gw-form-field-0-col-$j-label'), '열$j');
    }
    final add = tester.widget<TextButton>(_text('gw-form-field-0-col-add'));
    expect(add.onPressed, isNull, reason: '열은 8개까지');
    for (var j = 7; j >= 2; j--) {
      await tester.tap(_text('gw-form-field-0-col-$j-remove'));
      await tester.pumpAndSettle();
    }

    await tester.tap(_text('gw-form-save'));
    await tester.pumpAndSettle();
    expect(
      h.bodyOf(h.called('POST', '/api/groupware/forms').single)['fields'],
      [
        {
          'label': '참석자',
          'type': 'table',
          'required': false,
          'columns': [
            {'label': '이름', 'type': 'text'},
            {'label': '참가비', 'type': 'money'},
          ],
        },
      ],
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('기본 결재선 — 기본 양식에도, 역할·전결 한 명·순서·참조자를 보내고 목록에 사람 수', (
    tester,
  ) async {
    final h = _Harness();
    await _pump(tester, h);

    await tester.tap(_text('gw-form-menu-builtin:draft'));
    await tester.pumpAndSettle();
    expect(find.text('고치기'), findsNothing, reason: '기본 양식은 고치지 못한다');
    expect(find.text('지우기'), findsNothing);
    await tester.tap(_text('gw-form-defaults-builtin:draft'));
    await tester.pumpAndSettle();

    // 후보에 없는 사람은 "(알 수 없음)" — 뺄 수 있다.
    expect(
      tester.widget<Text>(_text('gw-form-defaults-name-0')).data,
      '(알 수 없음)',
    );
    await tester.tap(_text('gw-form-defaults-remove-0'));
    await tester.pumpAndSettle();
    expect(_text('gw-form-defaults-name-0'), findsNothing);

    await tester.tap(_text('gw-form-defaults-add-approver'));
    await tester.pumpAndSettle();
    await tester.enterText(_text('gw-form-defaults-search'), 'kim');
    await tester.pumpAndSettle();
    expect(_text('gw-form-defaults-pick-U-lead'), findsNothing);
    await tester.tap(_text('gw-form-defaults-pick-U-a'));
    await tester.pumpAndSettle();
    await tester.tap(_text('gw-form-defaults-add-approver'));
    await tester.pumpAndSettle();
    expect(
      _text('gw-form-defaults-pick-U-a'),
      findsNothing,
      reason: '이미 넣은 사람',
    );
    await tester.tap(_text('gw-form-defaults-pick-U-lead'));
    await tester.pumpAndSettle();

    // 김부장을 전결로(결재 → 합의 → 전결), 다음에 팀장을 전결로 하면 김부장은 결재로 돌아간다.
    await tester.tap(_text('gw-form-defaults-role-0'));
    await tester.pumpAndSettle();
    await tester.tap(_text('gw-form-defaults-role-0'));
    await tester.pumpAndSettle();
    await tester.tap(_text('gw-form-defaults-role-1'));
    await tester.pumpAndSettle();
    await tester.tap(_text('gw-form-defaults-role-1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('전결은 한 명만'), findsOneWidget);
    // 팀장을 위로, 김부장은 합의로.
    await tester.tap(_text('gw-form-defaults-up-1'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(_text('gw-form-defaults-name-0')).data, '팀장');
    await tester.tap(_text('gw-form-defaults-role-1'));
    await tester.pumpAndSettle();

    // 참조자 — 결재자는 고를 수 없다.
    await tester.tap(_text('gw-form-defaults-add-cc'));
    await tester.pumpAndSettle();
    expect(_text('gw-form-defaults-pick-U-a'), findsNothing);
    expect(_text('gw-form-defaults-pick-U-lead'), findsNothing);
    await tester.tap(_text('gw-form-defaults-pick-U-b'));
    await tester.pumpAndSettle();
    expect(_text('gw-form-defaults-cc-U-b'), findsOneWidget);

    await tester.tap(_text('gw-form-defaults-save'));
    await tester.pumpAndSettle();
    final body = h.bodyOf(
      h.called('PATCH', '/api/groupware/forms/builtin:draft').single,
    );
    expect(body, {
      'teamId': 'T1',
      'defaultLine': [
        {'userId': 'U-lead', 'role': 'final'},
        {'userId': 'U-a', 'role': 'agree'},
      ],
      'defaultCcIds': ['U-b'],
    });
    expect(find.text('기본 결재선을 저장했습니다.'), findsOneWidget);
    expect(_text('gw-form-defaults-save'), findsNothing);
    expect(find.textContaining('기본 결재선 2명 · 기본 참조 1명'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('기본 결재선 — 서버가 거르면 창에 오류, 비우기는 빈 목록으로 지운다', (tester) async {
    final h = _Harness();
    await _pump(tester, h);
    await _openMenu(tester, 'F-edu', '기본 결재선');
    expect(tester.widget<Text>(_text('gw-form-defaults-name-0')).data, '김부장');
    expect(find.text('전결'), findsOneWidget);
    expect(_text('gw-form-defaults-cc-U-b'), findsOneWidget);

    h.onPatch = (_) =>
        _json({'error': '기본 참조자에 고를 수 없는 사람이 있습니다.'}, status: 400);
    await tester.tap(_text('gw-form-defaults-save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('기본 참조자에 고를 수 없는 사람이 있습니다.'), findsOneWidget);
    expect(_text('gw-form-defaults-save'), findsOneWidget, reason: '창은 그대로');

    h.onPatch = null;
    await tester.tap(_text('gw-form-defaults-clear'));
    await tester.pumpAndSettle();
    expect(_text('gw-form-defaults-name-0'), findsNothing);
    expect(_text('gw-form-defaults-cc-U-b'), findsNothing);
    await tester.tap(_text('gw-form-defaults-save'));
    await tester.pumpAndSettle();
    final patches = h.called('PATCH', '/api/groupware/forms/F-edu');
    expect(patches, hasLength(2));
    expect(h.bodyOf(patches.last), {
      'teamId': 'T1',
      'defaultLine': [],
      'defaultCcIds': [],
    });
    expect(
      find.descendant(
        of: _text('gw-form-F-edu'),
        matching: find.textContaining('기본'),
      ),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 3));
  });
}
