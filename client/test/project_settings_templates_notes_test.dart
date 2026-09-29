import 'dart:async';
import 'dart:convert';

import 'package:client/models/project.dart';
import 'package:client/screens/project/project_menu_dialog.dart';
import 'package:client/screens/project/project_templates_view.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// 프로젝트 설정 > 필드 / 상태의 "업무 템플릿" 칸과 > 노트(노트 수정·삭제 권한).

const _json = {'content-type': 'application/json'};

Map<String, dynamic> _template() => {
  'id': 'tpl1',
  'teamId': 't1',
  'name': '소프트웨어 개발',
  'description': '개발팀 기본 구성',
  'statuses': [
    {'name': '할 일', 'color': '#5B8DEF', 'category': 'todo'},
    {'name': '진행 중', 'color': '#F59E0B', 'category': 'doing'},
    {'name': '완료', 'color': '#10B981', 'category': 'done'},
  ],
  'types': [
    {'name': '기능', 'color': '#5B8DEF'},
    {'name': '버그', 'color': '#EF4444'},
  ],
  'priorities': [
    {'name': '보통', 'color': '#5B8DEF', 'level': 'normal'},
  ],
  'fields': [
    {'name': '고객사', 'kind': 'text', 'options': []},
  ],
  'creatorName': 'Riley',
  'createdAt': 0,
  'updatedAt': 0,
  'canEdit': true,
};

Map<String, dynamic> _project({
  String myRole = 'owner',
  bool withTemplate = false,
  String edit = 'all',
  String delete = 'all',
}) => {
  'id': 'p1',
  'teamId': 't1',
  'name': '잔디톡',
  'description': '메신저 앱',
  'identifier': 'TA',
  'color': '#5B8DEF',
  'myRole': myRole,
  'createdAt': 0,
  'noteEditPermission': edit,
  'noteDeletePermission': delete,
  'templateId': withTemplate ? 'tpl1' : null,
  'template': withTemplate ? _template() : null,
  'members': [
    {'id': 'u1', 'username': 'riley', 'name': 'Riley', 'projectRole': 'owner'},
    {'id': 'u2', 'username': 'sam', 'name': 'Sam', 'projectRole': 'member'},
  ],
};

Session _session(MockClient client) {
  final session = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: client,
  );
  return session;
}

/// 설정 창을 열고 왼쪽 메뉴 [section]으로 간다. 창이 돌려준 결과는 [onResult]로.
Future<void> _open(
  WidgetTester tester,
  Session session,
  String section, {
  ValueChanged<ProjectMenuResult?>? onResult,
}) async {
  tester.view.physicalSize = const Size(1400, 950);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              final r = await showProjectMenuDialog(context, session, 'p1');
              onResult?.call(r);
            },
            child: const Text('열기'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(section).first);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  testWidgets('업무 템플릿 칸: 템플릿을 쓴 프로젝트는 템플릿 카드만 보인다(새 업무 양식 없음)', (tester) async {
    final calls = <String, dynamic>{};
    var forms = <Map<String, dynamic>>[
      {
        'id': 'tt1',
        'projectId': 'p1',
        'name': '버그 신고',
        'title': '[버그] ',
        'priority': 'high',
      },
    ];
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'POST' &&
          path == '/api/projects/p1/task-templates') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        calls['POST $path'] = body;
        final created = {'id': 'tt2', 'projectId': 'p1', ...body};
        forms = [...forms, created];
        return http.Response(jsonEncode(created), 201, headers: _json);
      }
      if (path == '/api/projects/p1') {
        return http.Response(
          jsonEncode(_project(withTemplate: true)),
          200,
          headers: _json,
        );
      }
      if (path == '/api/projects/p1/task-templates') {
        return http.Response(jsonEncode(forms), 200, headers: _json);
      }
      return http.Response('[]', 200, headers: _json);
    });
    final session = _session(client);
    await _open(tester, session, '필드 / 상태');

    // 사용자 정의 필드 칸 아래에 업무 템플릿 칸 — 템플릿 카드(이름·설명·구성·상태 색)가 보이고
    // "템플릿 저장" 버튼은 없다.
    expect(find.text('업무 템플릿'), findsOneWidget);
    final fieldsTop = tester.getTopLeft(find.text('사용자 정의 필드'));
    final boxTop = tester.getTopLeft(find.text('업무 템플릿'));
    expect(boxTop.dy, greaterThan(fieldsTop.dy));
    expect(boxTop.dx, closeTo(fieldsTop.dx, 1));
    expect(find.byType(ProjectTemplateSummaryCard), findsOneWidget);
    expect(find.text('소프트웨어 개발'), findsOneWidget);
    expect(find.text('개발팀 기본 구성'), findsOneWidget);
    expect(find.text('상태 3 · 유형 2 · 우선순위 1 · 필드 1'), findsOneWidget);
    expect(find.text('진행 중'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '템플릿 저장'), findsNothing);

    // "새 업무 양식"은 설정에서 뺐다 — 양식 목록·추가 버튼이 없다.
    expect(find.text('새 업무 양식'), findsNothing);
    expect(find.text('양식 추가'), findsNothing);
    expect(find.text('버그 신고'), findsNothing);

    await _finish(tester);
  });

  testWidgets('업무 템플릿 칸: 템플릿을 안 쓴 프로젝트는 템플릿 저장 → 연결되어 카드로 바뀐다', (tester) async {
    Map<String, dynamic>? posted;
    var linked = false;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'POST' && path == '/api/projects/templates') {
        posted = jsonDecode(request.body) as Map<String, dynamic>;
        linked = true;
        return http.Response(
          jsonEncode({..._template(), 'name': posted!['name']}),
          201,
          headers: _json,
        );
      }
      switch (path) {
        case '/api/projects/p1':
          return http.Response(
            jsonEncode(
              linked
                  ? {
                      ..._project(withTemplate: true),
                      'template': {..._template(), 'name': posted!['name']},
                    }
                  : _project(),
            ),
            200,
            headers: _json,
          );
        case '/api/projects/p1/task-statuses':
          return http.Response(
            jsonEncode([
              {
                'id': 's1',
                'projectId': 'p1',
                'name': '대기',
                'color': '#94A3B8',
                'category': 'todo',
                'position': 0,
              },
              {
                'id': 's2',
                'projectId': 'p1',
                'name': '끝',
                'color': '#10B981',
                'category': 'done',
                'position': 1,
              },
            ]),
            200,
            headers: _json,
          );
        case '/api/projects/p1/task-priorities':
          return http.Response(
            jsonEncode([
              {
                'id': 'pr1',
                'projectId': 'p1',
                'name': '보통',
                'color': '#5B8DEF',
                'level': 'normal',
                'position': 0,
              },
            ]),
            200,
            headers: _json,
          );
      }
      return http.Response('[]', 200, headers: _json);
    });
    final session = _session(client);
    ProjectMenuResult? result;
    await _open(tester, session, '필드 / 상태', onResult: (r) => result = r);

    expect(find.byType(ProjectTemplateSummaryCard), findsNothing);
    final save = find.widgetWithText(FilledButton, '템플릿 저장');
    expect(save, findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);

    // 사이드바 ⋯ > 템플릿 저장과 같은 편집기가 지금 구성으로 채워져 창으로 뜬다.
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.byType(ProjectTemplateEditor), findsOneWidget);
    expect(find.text('새 템플릿 만들기'), findsOneWidget);
    expect(find.widgetWithText(TextField, '잔디톡'), findsOneWidget);
    // 뒤의 설정 창에도 같은 상태가 보이므로 편집기 안에서만 찾는다.
    expect(
      find.descendant(
        of: find.byType(ProjectTemplateEditor),
        matching: find.text('대기'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, '템플릿 저장').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(posted?['teamId'], 't1');
    expect(posted?['sourceProjectId'], 'p1');
    expect(posted?['name'], '잔디톡');
    expect(
      [for (final s in posted!['statuses'] as List) s['name']],
      ['대기', '끝'],
    );

    // 편집 창은 닫히고, 다시 읽은 프로젝트가 연결되어 있어 카드로 바뀐다.
    expect(find.byType(ProjectTemplateEditor), findsNothing);
    expect(find.byType(ProjectTemplateSummaryCard), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '템플릿 저장'), findsNothing);

    // 바뀐 게 있으니 창을 닫으면 호출부가 다시 읽는다.
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
    expect(result, ProjectMenuResult.changed);

    await _finish(tester);
  });

  testWidgets('노트: 수정·삭제 권한을 고르면 바로 저장된다', (tester) async {
    final patches = <Map<String, dynamic>>[];
    var edit = 'all';
    var delete = 'all';
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'PATCH' && path == '/api/projects/p1') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        patches.add(body);
        edit = body['noteEditPermission'] as String? ?? edit;
        delete = body['noteDeletePermission'] as String? ?? delete;
        return http.Response(
          jsonEncode(_project(edit: edit, delete: delete)),
          200,
          headers: _json,
        );
      }
      if (path == '/api/projects/p1') {
        return http.Response(
          jsonEncode(_project(edit: edit, delete: delete)),
          200,
          headers: _json,
        );
      }
      return http.Response('[]', 200, headers: _json);
    });
    final session = _session(client);
    await _open(tester, session, '노트');

    expect(find.text('노트 수정 권한'), findsOneWidget);
    expect(find.text('노트 삭제 권한'), findsOneWidget);
    expect(
      find.text(
        "노트를 수정할 수 있는 권한을 설정합니다. '생성자와 관리자' 선택 시, 작성자 본인과 관리자만 수정할 수 있습니다.",
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        "노트를 삭제할 수 있는 권한을 설정합니다. '생성자와 관리자' 선택 시, 작성자 본인과 관리자만 삭제할 수 있습니다.",
      ),
      findsOneWidget,
    );
    expect(find.text('모두'), findsNWidgets(2));
    expect(find.text('생성자와 관리자'), findsNWidgets(2));
    // 수정 권한이 삭제 권한보다 위에 있다.
    expect(
      tester.getTopLeft(find.text('노트 수정 권한')).dy,
      lessThan(tester.getTopLeft(find.text('노트 삭제 권한')).dy),
    );

    String? group(String prefix) => tester
        .widget<RadioGroup<String>>(
          find.ancestor(
            of: find.byKey(ValueKey('$prefix-all')),
            matching: find.byType(RadioGroup<String>),
          ),
        )
        .groupValue;
    expect(group('note-edit'), 'all');
    expect(group('note-delete'), 'all');

    // 글자를 눌러도 고를 수 있다.
    await tester.tap(find.byKey(const ValueKey('note-edit-creator_admin')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(patches, [
      {'noteEditPermission': 'creator_admin'},
    ]);
    expect(group('note-edit'), 'creator_admin');
    expect(group('note-delete'), 'all');

    // 라디오 동그라미를 눌러도 된다.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('note-delete-creator_admin')),
        matching: find.byType(Radio<String>),
      ),
    );
    await tester.pumpAndSettle();
    expect(patches.last, {'noteDeletePermission': 'creator_admin'});
    expect(group('note-delete'), 'creator_admin');

    // 이미 고른 값을 다시 누르면 요청하지 않는다.
    await tester.tap(find.byKey(const ValueKey('note-delete-creator_admin')));
    await tester.pumpAndSettle();
    expect(patches, hasLength(2));

    await tester.tap(find.byKey(const ValueKey('note-edit-all')));
    await tester.pumpAndSettle();
    expect(patches.last, {'noteEditPermission': 'all'});
    expect(group('note-edit'), 'all');
    expect(group('note-delete'), 'creator_admin');

    await _finish(tester);
  });

  testWidgets('노트: 저장에 실패하면 원래 값으로 되돌리고 알린다', (tester) async {
    var patched = 0;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'PATCH') {
        patched++;
        return http.Response(
          jsonEncode({'error': '프로젝트를 관리할 권한이 없습니다.'}),
          403,
          headers: _json,
        );
      }
      if (path == '/api/projects/p1') {
        return http.Response(jsonEncode(_project()), 200, headers: _json);
      }
      return http.Response('[]', 200, headers: _json);
    });
    final session = _session(client);
    await _open(tester, session, '노트');

    await tester.tap(find.byKey(const ValueKey('note-delete-creator_admin')));
    await tester.pumpAndSettle();
    expect(patched, 1);
    expect(find.text('노트 권한을 저장하지 못했습니다: 프로젝트를 관리할 권한이 없습니다.'), findsOneWidget);
    final group = tester.widget<RadioGroup<String>>(
      find.ancestor(
        of: find.byKey(const ValueKey('note-delete-all')),
        matching: find.byType(RadioGroup<String>),
      ),
    );
    expect(group.groupValue, 'all');

    await _finish(tester);
  });

  testWidgets('노트: 앞 저장이 끝나기 전에 다른 권한을 고르면 이어서 저장한다', (tester) async {
    final patches = <Map<String, dynamic>>[];
    var edit = 'all';
    var delete = 'all';
    // 첫 PATCH는 응답을 붙잡아 두고, 그 사이에 삭제 권한을 고른다.
    final hold = Completer<void>();
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'PATCH' && path == '/api/projects/p1') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        patches.add(body);
        if (patches.length == 1) await hold.future;
        edit = body['noteEditPermission'] as String? ?? edit;
        delete = body['noteDeletePermission'] as String? ?? delete;
        return http.Response(
          jsonEncode(_project(edit: edit, delete: delete)),
          200,
          headers: _json,
        );
      }
      if (path == '/api/projects/p1') {
        return http.Response(
          jsonEncode(_project(edit: edit, delete: delete)),
          200,
          headers: _json,
        );
      }
      return http.Response('[]', 200, headers: _json);
    });
    final session = _session(client);
    await _open(tester, session, '노트');

    String? group(String prefix) => tester
        .widget<RadioGroup<String>>(
          find.ancestor(
            of: find.byKey(ValueKey('$prefix-all')),
            matching: find.byType(RadioGroup<String>),
          ),
        )
        .groupValue;

    await tester.tap(find.byKey(const ValueKey('note-edit-creator_admin')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('note-delete-creator_admin')));
    await tester.pump();
    // 누른 즉시 둘 다 바뀌어 보이지만, 요청은 아직 하나뿐이다(한 번에 하나씩).
    expect(group('note-edit'), 'creator_admin');
    expect(group('note-delete'), 'creator_admin');
    expect(patches, [
      {'noteEditPermission': 'creator_admin'},
    ]);

    hold.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(patches, [
      {'noteEditPermission': 'creator_admin'},
      {'noteDeletePermission': 'creator_admin'},
    ]);
    expect(edit, 'creator_admin');
    expect(delete, 'creator_admin');
    expect(group('note-edit'), 'creator_admin');
    expect(group('note-delete'), 'creator_admin');

    await _finish(tester);
  });

  testWidgets('노트: 서버가 권한 값을 안 주면 수정은 모두, 삭제는 생성자와 관리자', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/projects/p1') {
        final p = _project()
          ..remove('noteEditPermission')
          ..remove('noteDeletePermission');
        return http.Response(jsonEncode(p), 200, headers: _json);
      }
      return http.Response('[]', 200, headers: _json);
    });
    await _open(tester, _session(client), '노트');

    String? group(String prefix) => tester
        .widget<RadioGroup<String>>(
          find.ancestor(
            of: find.byKey(ValueKey('$prefix-all')),
            matching: find.byType(RadioGroup<String>),
          ),
        )
        .groupValue;
    expect(group('note-edit'), 'all');
    expect(group('note-delete'), 'creator_admin');

    // 모델 기본값도 같다(생성자·JSON 모두).
    final bare = Project(
      id: 'p1',
      teamId: 't1',
      name: '잔디톡',
      identifier: 'TA',
      createdAt: DateTime(2026),
    );
    expect(bare.noteEditPermission, 'all');
    expect(bare.noteDeletePermission, 'creator_admin');

    await _finish(tester);
  });

  testWidgets('노트: 관리자가 아니면 권한을 볼 수만 있다', (tester) async {
    var patched = 0;
    final client = MockClient((request) async {
      if (request.method == 'PATCH') patched++;
      if (request.url.path == '/api/projects/p1') {
        return http.Response(
          jsonEncode(_project(myRole: 'member', edit: 'creator_admin')),
          200,
          headers: _json,
        );
      }
      return http.Response('[]', 200, headers: _json);
    });
    // 팀을 관리할 수 없는 일반 구성원(현재 팀 없음 → canManageCurrentTeam false).
    final session = _session(client);
    await _open(tester, session, '노트');

    expect(
      find.textContaining('프로젝트 담당자와 팀 소유자·관리자만 바꿀 수 있습니다'),
      findsOneWidget,
    );
    final radios = tester.widgetList<Radio<String>>(find.byType(Radio<String>));
    expect(radios, hasLength(4));
    expect(radios.every((r) => r.enabled == false), isTrue);
    final selected = tester.widget<RadioGroup<String>>(
      find.ancestor(
        of: find.byKey(const ValueKey('note-edit-all')),
        matching: find.byType(RadioGroup<String>),
      ),
    );
    expect(selected.groupValue, 'creator_admin');

    await tester.tap(find.byKey(const ValueKey('note-edit-all')));
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('note-delete-creator_admin')),
        matching: find.byType(Radio<String>),
      ),
    );
    await tester.pumpAndSettle();
    expect(patched, 0);

    await _finish(tester);
  });
}
