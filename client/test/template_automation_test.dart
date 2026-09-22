import 'dart:convert';

import 'package:client/screens/project/project_forms.dart';
import 'package:client/screens/project/template_automation_manager.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _json = {'content-type': 'application/json'};

Map<String, dynamic> _project() => {
  'id': 'p1',
  'teamId': 't1',
  'name': '잔디톡',
  'identifier': 'TA',
  'createdAt': DateTime.now().millisecondsSinceEpoch,
  'members': [
    {'id': 'u1', 'username': 'riley', 'name': 'Riley'},
    {'id': 'u2', 'username': 'sam', 'name': 'Sam'},
  ],
};

List<Map<String, dynamic>> _statuses() => [
  for (final (i, s) in [
    ('s1', '할 일', 'todo'),
    ('s2', '진행 중', 'doing'),
    ('s3', '완료', 'done'),
  ].indexed)
    {
      'id': s.$1,
      'projectId': 'p1',
      'name': s.$2,
      'color': '#5B8DEF',
      'category': s.$3,
      'position': i,
    },
];

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

void main() {
  testWidgets('템플릿·자동화 관리: 템플릿 저장, 규칙 저장/켜기·끄기', (tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final calls = <String, dynamic>{};
    final client = MockClient((request) async {
      final path = request.url.path;
      final key = '${request.method} $path';
      if (request.method != 'GET') {
        calls[key] = jsonDecode(request.body);
        return http.Response(
          jsonEncode({
            'id': 'x',
            'projectId': 'p1',
            'name': 'n',
            'trigger': 'task_created',
            'enabled': true,
          }),
          200,
          headers: _json,
        );
      }
      if (path == '/api/projects/p1') {
        return http.Response(jsonEncode(_project()), 200, headers: _json);
      }
      if (path == '/api/projects/p1/task-statuses') {
        return http.Response(jsonEncode(_statuses()), 200, headers: _json);
      }
      if (path == '/api/projects/p1/automation-runs') {
        return http.Response(
          jsonEncode([
            {
              'id': 'r1',
              'automationName': '높음은 Sam에게',
              'taskId': 't1',
              'taskKey': 'TA-7',
              'trigger': 'task_created',
              'summary': '담당자 지정 → 댓글 남기기',
              'ok': true,
              'createdAt': DateTime.now().millisecondsSinceEpoch,
            },
          ]),
          200,
          headers: _json,
        );
      }
      if (path == '/api/projects/p1/automations') {
        return http.Response(
          jsonEncode([
            {
              'id': 'a1',
              'projectId': 'p1',
              'name': '높음은 Sam에게',
              'enabled': true,
              'trigger': 'task_created',
              'condition': {'priority': 'high'},
              'actions': [
                {'kind': 'set_assignee', 'userId': 'u2'},
              ],
            },
          ]),
          200,
          headers: _json,
        );
      }
      return http.Response('[]', 200, headers: _json);
    });
    final session = _session(client);

    // "프로젝트 메뉴 > 템플릿 · 자동화"가 이 편집기를 보여준다.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectTemplateAutomationEditor(
            session: session,
            projectId: 'p1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 템플릿 추가
    await tester.tap(find.text('템플릿 추가'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '템플릿 이름'), '버그 신고');
    await tester.enterText(
      find.widgetWithText(TextField, '업무 제목 (미리 채울 내용)'),
      '[버그] ',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '마감일: 등록일로부터 N일 뒤 (비우면 안 채움)'),
      '3',
    );
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    final tpl = calls['POST /api/projects/p1/task-templates'] as Map;
    expect(tpl['name'], '버그 신고');
    expect(tpl['title'], '[버그]');
    expect(tpl['dueOffsetDays'], 3);
    expect(tpl['priority'], 'normal');

    // 자동화 탭: 기존 규칙 요약 + 켜기/끄기
    await tester.tap(find.text('자동화 규칙'));
    await tester.pumpAndSettle();
    expect(find.text('높음은 Sam에게'), findsOneWidget);
    expect(find.textContaining('담당자를 Sam(으)로'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(calls['PATCH /api/automations/a1'], {'enabled': false});

    // 규칙 추가: 상태 변경 → 완료, 동작 = 알림(Riley)
    await tester.tap(find.text('규칙 추가'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '규칙 이름'), '완료 알림');
    await tester.tap(find.text('상태가 바뀌었을 때'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('어떤 상태로든'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('완료').last);
    await tester.pumpAndSettle();
    // 기본 동작(담당자 지정)의 사용자 선택
    await tester.tap(find.text('사용자'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Riley').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    final rule = calls['POST /api/projects/p1/automations'] as Map;
    expect(rule['name'], '완료 알림');
    expect(rule['trigger'], 'status_changed');
    expect(rule['triggerStatusId'], 's3');
    expect(rule['actions'], [
      {'kind': 'set_assignee', 'userId': 'u1'},
    ]);

    // 실행 기록 탭
    await tester.tap(find.text('실행 기록'));
    await tester.pumpAndSettle();
    expect(find.textContaining('높음은 Sam에게 · TA-7'), findsOneWidget);
    expect(find.textContaining('담당자 지정 → 댓글 남기기'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('새 업무: 템플릿을 고르면 항목이 미리 채워진다', (tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Map<String, dynamic>? created;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'POST' && path == '/api/projects/p1/tasks') {
        created = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'id': 't1',
            'projectId': 'p1',
            'key': 'TA-1',
            'title': created!['title'],
            'status': 'todo',
            'priority': created!['priority'],
            'createdAt': DateTime.now().millisecondsSinceEpoch,
          }),
          201,
          headers: _json,
        );
      }
      if (path == '/api/projects/p1/task-templates') {
        return http.Response(
          jsonEncode([
            {
              'id': 'tp1',
              'projectId': 'p1',
              'name': '버그 신고',
              'title': '[버그] ',
              'description': '재현 방법:',
              'priority': 'high',
              'assigneeId': 'u2',
              'dueOffsetDays': 2,
            },
          ]),
          200,
          headers: _json,
        );
      }
      if (path == '/api/projects/p1/task-statuses') {
        return http.Response(jsonEncode(_statuses()), 200, headers: _json);
      }
      if (path == '/api/projects/p1') {
        return http.Response(jsonEncode(_project()), 200, headers: _json);
      }
      return http.Response('[]', 200, headers: _json);
    });
    final session = _session(client);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showNewTaskDialog(
                context,
                session,
                projectId: 'p1',
                members: const [],
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('버그 신고').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '[버그] '), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '생성'));
    await tester.pumpAndSettle();
    expect(created?['title'], '[버그]');
    expect(created?['description'], '재현 방법:');
    expect(created?['priority'], 'high');
    expect(created?['assigneeId'], 'u2');
    final due = DateTime.fromMillisecondsSinceEpoch(created!['dueDate'] as int);
    final expected = DateTime.now().add(const Duration(days: 2));
    expect(
      DateTime(due.year, due.month, due.day),
      DateTime(expected.year, expected.month, expected.day),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
