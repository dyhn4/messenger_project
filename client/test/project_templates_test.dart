import 'dart:convert';

import 'package:client/models/project.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/project/filter_controls.dart';
import 'package:client/screens/project/project_dialog.dart';
import 'package:client/screens/project/project_forms.dart';
import 'package:client/screens/project/project_templates_view.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _json = {'content-type': 'application/json'};

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

Map<String, dynamic> _templateJson(Map<String, dynamic> body, String id) => {
  ...body,
  'id': id,
  'teamId': 't1',
  'creatorName': 'Riley',
  'createdAt': 0,
  'updatedAt': 0,
  'canEdit': true,
};

void main() {
  testWidgets('템플릿: 빈 목록 → 새 템플릿 만들기 → 저장 → 카드 · 수정 · 이 템플릿으로 만들기', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final templates = <Map<String, dynamic>>[];
    Map<String, dynamic>? posted;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/projects/templates' && request.method == 'GET') {
        return http.Response(jsonEncode(templates), 200, headers: _json);
      }
      if (path == '/api/projects/templates' && request.method == 'POST') {
        posted = jsonDecode(request.body) as Map<String, dynamic>;
        final t = _templateJson(posted!, 'tpl1');
        templates.add(t);
        return http.Response(jsonEncode(t), 201, headers: _json);
      }
      return http.Response('{}', 404);
    });
    final session = _session(client)..canCreateProject = true;
    ProjectTemplate? used;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectTemplatesView(
            session: session,
            teamId: 't1',
            onUseTemplate: (t) => used = t,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 빈 목록 안내 + 버튼 두 개(머리글·가운데).
    expect(find.text('프로젝트 템플릿'), findsOneWidget);
    expect(find.text('템플릿이 없습니다'), findsOneWidget);
    expect(find.text('새 템플릿 만들기'), findsNWidgets(2));

    await tester.tap(find.text('새 템플릿 만들기').last);
    await tester.pumpAndSettle();
    expect(find.byType(ProjectTemplateEditor), findsOneWidget);
    expect(find.text('상태'), findsOneWidget);
    expect(find.text('작업 유형'), findsOneWidget);
    expect(find.text('우선순위'), findsOneWidget);
    expect(find.text('사용자 정의 필드가 없습니다.'), findsOneWidget);

    // 이름이 없으면 저장할 수 없다.
    FilledButton saveButton() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '템플릿 저장'),
    );
    expect(saveButton().onPressed, isNull);
    await tester.enterText(find.byType(TextField).first, '소프트웨어 개발');
    await tester.pump();
    expect(saveButton().onPressed, isNotNull);

    // 상태 하나 추가("새 상태") 후 완료로 표시.
    await tester.tap(find.text('추가').first);
    await tester.pumpAndSettle();
    expect(find.text('새 상태'), findsOneWidget);
    // "새 상태" 줄의 완료 표시를 켠다.
    await tester.tap(
      find.descendant(
        of: find
            .ancestor(of: find.text('새 상태'), matching: find.byType(Row))
            .first,
        matching: find.byIcon(Icons.radio_button_unchecked),
      ),
    );
    await tester.pump();

    // 필드 추가 → 단일 선택(선택지 하나가 딸려 온다).
    await tester.tap(find.text('필드 추가'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(FilterPopupCard),
        matching: find.text('단일 선택'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('옵션 1'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '템플릿 저장'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(posted!['teamId'], 't1');
    expect(posted!['name'], '소프트웨어 개발');
    // 빈 템플릿에서 시작했으니 연결할 프로젝트가 없다.
    expect(posted!.containsKey('sourceProjectId'), isFalse);
    final statuses = (posted!['statuses'] as List).cast<Map>();
    expect(
      [for (final s in statuses) s['name']],
      ['할 일', '진행 중', '완료', '새 상태'],
    );
    expect(
      [for (final s in statuses) s['category']],
      ['todo', 'doing', 'done', 'done'],
    );
    expect((posted!['priorities'] as List).length, 4);
    expect(posted!['fields'], [
      {
        'name': '단일 선택',
        'kind': 'select',
        'options': ['옵션 1'],
      },
    ]);

    // 저장하면 목록으로 — 카드와 "이 템플릿으로 만들기".
    expect(find.byType(ProjectTemplateEditor), findsNothing);
    expect(find.text('소프트웨어 개발'), findsOneWidget);
    expect(find.textContaining('상태 4'), findsOneWidget);
    await tester.tap(find.text('이 템플릿으로 만들기'));
    expect(used?.id, 'tpl1');

    // ⋯ > 수정 → 같은 내용의 "템플릿 수정" 편집기.
    await tester.tap(find.byTooltip('템플릿 메뉴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('수정'));
    await tester.pumpAndSettle();
    expect(find.text('템플릿 수정'), findsOneWidget);
    expect(find.text('새 상태'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(find.byType(ProjectTemplateEditor), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('프로젝트를 템플릿으로 저장하는 초안이면 sourceProjectId가 같이 간다', (tester) async {
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Map<String, dynamic>? posted;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/projects/templates' && request.method == 'POST') {
        posted = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(_templateJson(posted!, 'tpl9')),
          201,
          headers: _json,
        );
      }
      return http.Response('[]', 200, headers: _json);
    });
    final session = _session(client);

    // 사이드바 프로젝트 ⋯ > "템플릿 저장"처럼 프로젝트 구성으로 채운 초안을 연다.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectTemplatesView(
            session: session,
            teamId: 't1',
            draft: const ProjectTemplate(
              name: '잔디톡',
              statuses: [
                TemplateStatus(
                  name: '할 일',
                  color: '#5B8DEF',
                  category: TaskStatus.todo,
                ),
                TemplateStatus(
                  name: '완료',
                  color: '#10B981',
                  category: TaskStatus.done,
                ),
              ],
              priorities: [
                TemplatePriority(
                  name: '보통',
                  color: '#5B8DEF',
                  level: TaskPriority.normal,
                ),
              ],
              sourceProjectId: 'p9',
            ),
            draftTick: 1,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ProjectTemplateEditor), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '템플릿 저장'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(posted?['sourceProjectId'], 'p9');
    expect(posted?['name'], '잔디톡');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('사이드바 ⋯ > 템플릿 저장: 그 프로젝트가 연결되고(sourceProjectId) 이름은 40자로 잘린다', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 프로젝트 이름은 60자까지, 템플릿 이름은 40자까지다.
    final longName = '가' * 50;
    Map<String, dynamic>? posted;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/projects/templates' && request.method == 'POST') {
        posted = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(_templateJson(posted!, 'tpl1')),
          201,
          headers: _json,
        );
      }
      switch (path) {
        case '/api/projects':
          return http.Response(
            request.url.queryParameters['archived'] == '1'
                ? '[]'
                : jsonEncode([
                    {
                      'id': 'p1',
                      'teamId': 't1',
                      'name': longName,
                      'identifier': 'TA',
                      'color': '#5B8DEF',
                      'myRole': 'owner',
                      'createdAt': 0,
                    },
                  ]),
            200,
            headers: _json,
          );
        case '/api/projects/home':
          return http.Response(
            jsonEncode({
              'stats': {'total': 0, 'done': 0, 'doing': 0, 'overdue': 0},
              'projects': [],
              'myTasks': [],
              'recentComments': [],
            }),
            200,
            headers: _json,
          );
        case '/api/project-notifications':
          return http.Response(
            '{"unreadCount":0,"items":[]}',
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
      }
      return http.Response('[]', 200, headers: _json);
    });
    final session = _session(client)
      ..currentTeam = Team(
        id: 't1',
        name: '팀',
        createdAt: DateTime(2026),
        isOwner: true,
      );

    await tester.pumpWidget(
      MaterialApp(home: ProjectDialog(session: session, embedInWindow: true)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 실제 사이드바 줄의 ⋯ 메뉴로 연다(테스트 기본 플랫폼은 터치라 ⋯가 늘 보인다).
    await tester.tap(find.byTooltip('프로젝트 메뉴').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '템플릿 저장'));
    await tester.pumpAndSettle();
    expect(find.byType(ProjectTemplateEditor), findsOneWidget);
    // 편집기 이름 칸부터 40자로 잘려 있다(그대로 두면 서버가 400으로 거절한다).
    expect(find.widgetWithText(TextField, '가' * 40), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '템플릿 저장'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(posted?['sourceProjectId'], 'p1');
    expect(posted?['teamId'], 't1');
    expect(posted?['name'], '가' * 40);
    expect(
      [for (final s in posted!['statuses'] as List) s['name']],
      ['대기', '끝'],
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('프로젝트 생성: 오른쪽에서 템플릿을 고르면 templateId가 함께 간다', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Map<String, dynamic>? sent;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/projects/templates') {
        return http.Response(
          jsonEncode([
            _templateJson({
              'name': 'JANDI Setting',
              'statuses': [],
              'types': [],
              'priorities': [],
              'fields': [],
            }, 'tpl1'),
          ]),
          200,
          headers: _json,
        );
      }
      if (request.method == 'POST' && path == '/api/projects') {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'id': 'p1',
            'teamId': 't1',
            'name': sent!['name'],
            'identifier': sent!['identifier'],
            'color': '#5B8DEF',
            'createdAt': 0,
          }),
          201,
          headers: _json,
        );
      }
      return http.Response('{}', 404);
    });
    final session = _session(client);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showNewProjectDialog(context, session, 't1'),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    expect(find.text('프로젝트 템플릿'), findsOneWidget);
    expect(find.text('빈 프로젝트'), findsOneWidget);
    await tester.tap(find.text('JANDI Setting'));
    await tester.pumpAndSettle();
    // 왼쪽 위에 고른 템플릿이 표시된다.
    expect(find.text('템플릿'), findsOneWidget);
    expect(find.text('JANDI Setting'), findsNWidgets(2));

    await tester.enterText(find.byType(TextField).first, 'Mobile App');
    await tester.enterText(find.byType(TextField).at(1), 'MA');
    await tester.tap(find.widgetWithText(FilledButton, '프로젝트 생성'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(sent?['templateId'], 'tpl1');
  });
}
