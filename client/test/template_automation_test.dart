import 'dart:convert';

import 'package:client/models/room.dart';
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

/// 노드 편집기로 만든 규칙 — 우선순위가 바뀌면 IF 우선순위 = 높음일 때 채팅방 알림 + 담당자 변경.
Map<String, dynamic> _graphRule() => {
  'id': 'a2',
  'projectId': 'p1',
  'name': '높은 우선순위 알림',
  'enabled': true,
  'trigger': 'field_changed',
  'actions': [],
  'graph': {
    'nodes': [
      {
        'id': 'n1',
        'kind': 'trigger',
        'type': 'field_changed',
        'config': {'field': 'priority'},
        'x': 60,
        'y': 120,
      },
      {
        'id': 'n2',
        'kind': 'condition',
        'type': 'if',
        'config': {'field': 'priority', 'op': 'eq', 'value': 'pr3'},
        'x': 360,
        'y': 110,
      },
      {
        'id': 'n3',
        'kind': 'action',
        'type': 'chat_message',
        'config': {'roomId': 'r1', 'text': '확인 부탁드립니다.'},
        'x': 680,
        'y': 40,
      },
      {
        'id': 'n4',
        'kind': 'action',
        'type': 'set_field',
        'config': {'field': 'assignee', 'value': 'u2'},
        'x': 680,
        'y': 240,
      },
    ],
    'edges': [
      {'from': 'n1', 'port': 'out', 'to': 'n2'},
      {'from': 'n2', 'port': 'yes', 'to': 'n3'},
      {'from': 'n2', 'port': 'yes', 'to': 'n4'},
    ],
  },
};

/// 필드 변경 트리거가 여러 필드(상태·유형)를 감지하는 규칙.
Map<String, dynamic> _multiFieldRule() => {
  'id': 'a3',
  'projectId': 'p1',
  'name': '상태나 유형이 바뀌면 보관',
  'enabled': true,
  'trigger': 'field_changed',
  'actions': [],
  'graph': {
    'nodes': [
      {
        'id': 'n1',
        'kind': 'trigger',
        'type': 'field_changed',
        'config': {
          'fields': ['status', 'type'],
        },
        'x': 60,
        'y': 120,
      },
      {
        'id': 'n2',
        'kind': 'action',
        'type': 'archive_task',
        'config': {},
        'x': 360,
        'y': 120,
      },
    ],
    'edges': [
      {'from': 'n1', 'port': 'out', 'to': 'n2'},
    ],
  },
};

/// 노드 편집기 이전에 만든 규칙(graph 없음).
Map<String, dynamic> _legacyRule() => {
  'id': 'a1',
  'projectId': 'p1',
  'name': '높음은 Sam에게',
  'enabled': true,
  'trigger': 'task_created',
  'condition': {'priority': 'high'},
  'actions': [
    {'kind': 'set_assignee', 'userId': 'u2'},
  ],
  'graph': null,
};

void main() {
  testWidgets('새 업무 양식(설정 > 필드 / 상태 > 업무 템플릿 칸): 양식만 보여주고 저장한다', (
    tester,
  ) async {
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
          jsonEncode({'id': 'x', 'projectId': 'p1', 'name': 'n'}),
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
      return http.Response('[]', 200, headers: _json);
    });
    final session = _session(client);

    // "프로젝트 설정 > 필드 / 상태"의 업무 템플릿 칸이 이 편집기를 바깥 스크롤 안에 넣는다 —
    // 목록이 스스로 스크롤하지 않고 내용 높이만큼만 차지해야 한다.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProjectTemplateAutomationEditor(
              session: session,
              projectId: 'p1',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 자동화 탭은 "자동화" 메뉴로 옮겨졌다.
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('자동화 규칙'), findsNothing);

    expect(find.text('만든 양식이 없습니다.'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
    // 안내 문구도 "새 업무" 창의 이름(양식에서 불러오기)과 맞는다.
    expect(find.textContaining('"양식에서 불러오기"'), findsOneWidget);
    expect(find.textContaining('템플릿'), findsNothing);

    // 양식 추가
    await tester.tap(find.text('양식 추가'));
    await tester.pumpAndSettle();
    expect(find.text('양식 추가'), findsNWidgets(2)); // 버튼 + 창 제목
    await tester.enterText(find.widgetWithText(TextField, '양식 이름'), '버그 신고');
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

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('자동화 메뉴: 규칙 요약·켜기/끄기, 이전 방식 규칙, 새 편집기 열기, 실행 기록', (tester) async {
    // 노드 편집기가 1400×900에서 맞춰져 있다.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final calls = <String, dynamic>{};
    var listLoads = 0;
    final client = MockClient((request) async {
      final path = request.url.path;
      final key = '${request.method} $path';
      if (request.method != 'GET') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        calls[key] = body;
        return http.Response(
          jsonEncode({..._graphRule(), ...body}),
          200,
          headers: _json,
        );
      }
      switch (path) {
        case '/api/projects/p1':
          return http.Response(jsonEncode(_project()), 200, headers: _json);
        case '/api/projects/p1/task-statuses':
          return http.Response(jsonEncode(_statuses()), 200, headers: _json);
        case '/api/projects/p1/task-priorities':
          return http.Response(
            jsonEncode([
              {
                'id': 'pr3',
                'projectId': 'p1',
                'name': '높음',
                'color': '#EF4444',
                'level': 'high',
              },
            ]),
            200,
            headers: _json,
          );
        case '/api/projects/p1/automations':
          listLoads++;
          return http.Response(
            jsonEncode([_graphRule(), _multiFieldRule(), _legacyRule()]),
            200,
            headers: _json,
          );
        case '/api/projects/p1/automation-runs':
          final now = DateTime.now().millisecondsSinceEpoch;
          return http.Response(
            jsonEncode([
              {
                'id': 'r2',
                'automationName': '높은 우선순위 알림',
                'taskId': 't2',
                'taskKey': 'TA-8',
                'trigger': 'field_changed',
                'summary': '채팅방 알림 → 필드 변경',
                'ok': true,
                'createdAt': now,
              },
              {
                'id': 'r1',
                'automationName': '높음은 Sam에게',
                'taskId': 't1',
                'taskKey': 'TA-7',
                'trigger': 'status_changed',
                'summary': '담당자 지정 → 댓글 남기기',
                'ok': true,
                'createdAt': now,
              },
            ]),
            200,
            headers: _json,
          );
      }
      return http.Response('[]', 200, headers: _json);
    });
    final session = _session(client);
    // 채팅방 알림 노드가 가리키는 방 — 편집기는 내가 들어가 있지 않은(지워진) 방이면 저장을 막는다.
    session.rooms.add(
      Room(
        id: 'r1',
        teamId: 't1',
        type: RoomType.topic,
        name: '잔디톡 팀',
        members: const [],
        createdAt: DateTime(2026),
        lastRead: const {},
      ),
    );

    // "프로젝트 설정 > 자동화"가 이 편집기를 보여준다.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectTemplateAutomationEditor(
            session: session,
            projectId: 'p1',
            automations: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('자동화 규칙'), findsOneWidget);
    expect(find.text('실행 기록'), findsOneWidget);
    expect(find.text('업무 템플릿'), findsNothing);
    expect(listLoads, 1);

    // 노드 규칙: 이름 + 트리거에서 따라간 한 줄 요약, 편집 가능.
    expect(find.text('높은 우선순위 알림'), findsOneWidget);
    expect(
      find.text('필드 변경(우선순위) → IF 우선순위 같음 높음 → 채팅방 알림, 필드 변경'),
      findsOneWidget,
    );
    // 감지할 필드가 여러 개면 가운뎃점으로 잇는다.
    expect(find.text('필드 변경(상태·유형) → 업무 보관'), findsOneWidget);
    expect(find.byTooltip('편집'), findsNWidgets(2));

    // 이전 방식 규칙: 회색 칩 + 예전 요약, 편집 버튼은 막혀 있다.
    expect(find.text('높음은 Sam에게'), findsOneWidget);
    expect(find.text('이전 방식'), findsOneWidget);
    expect(find.textContaining('담당자를 Sam(으)로'), findsOneWidget);
    final legacyEdit = find.descendant(
      of: find.byTooltip('새 편집기에서 다시 만들어 주세요'),
      matching: find.byType(IconButton),
    );
    expect(tester.widget<IconButton>(legacyEdit).onPressed, isNull);
    // 이전 방식 줄은 눌러도 편집기가 열리지 않는다.
    await tester.tap(find.text('높음은 Sam에게'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('automation-canvas')), findsNothing);

    // 켜기/끄기는 줄마다 따로 간다.
    Finder switchOf(String name) => find.descendant(
      of: find.widgetWithText(ListTile, name),
      matching: find.byType(Switch),
    );
    await tester.tap(switchOf('높은 우선순위 알림'));
    await tester.pumpAndSettle();
    expect(calls['PATCH /api/automations/a2'], {'enabled': false});
    await tester.tap(switchOf('높음은 Sam에게'));
    await tester.pumpAndSettle();
    expect(calls['PATCH /api/automations/a1'], {'enabled': false});
    calls.clear();
    final loadsBefore = listLoads;

    // "새 자동화"는 빈 편집기를 연다 — 저장 없이 나오면 목록을 다시 읽지 않는다.
    await tester.tap(find.text('새 자동화'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('automation-canvas')), findsOneWidget);
    expect(find.byKey(const ValueKey('node-n1')), findsNothing);
    await tester.tap(find.byTooltip('뒤로'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('automation-canvas')), findsNothing);
    expect(listLoads, loadsBefore);
    expect(calls, isEmpty);

    // 노드 규칙 줄을 누르면 그 규칙으로 편집기가 열리고, 저장하면 PATCH 후 목록을 다시 읽는다.
    await tester.tap(find.text('높은 우선순위 알림'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('automation-canvas')), findsOneWidget);
    expect(find.byKey(const ValueKey('node-n3')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('rule-name')))
          .controller!
          .text,
      '높은 우선순위 알림',
    );
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('automation-canvas')), findsNothing);
    final saved = calls['PATCH /api/automations/a2'] as Map;
    expect(saved['name'], '높은 우선순위 알림');
    expect((saved['graph'] as Map)['edges'], hasLength(3));
    // 예전 {field} 모양으로 온 트리거는 손대지 않고 저장해도 {fields}로 바뀌어 간다.
    final trigger = ((saved['graph'] as Map)['nodes'] as List).first as Map;
    expect(trigger['config'], {
      'fields': ['priority'],
    });
    expect(listLoads, loadsBefore + 1);

    // 실행 기록: 새 트리거 이름, 이전 방식의 상태 변경도 그대로.
    await tester.tap(find.text('실행 기록'));
    await tester.pumpAndSettle();
    expect(find.textContaining('높은 우선순위 알림 · TA-8'), findsOneWidget);
    expect(find.text('필드 변경 → 채팅방 알림 → 필드 변경'), findsOneWidget);
    expect(find.text('상태 변경 → 담당자 지정 → 댓글 남기기'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('새 업무: 양식을 고르면 항목이 미리 채워진다', (tester) async {
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
    // 설정의 "새 업무 양식"과 같은 이름(양식)으로 부른다 — 프로젝트 템플릿과 헷갈리지 않게.
    expect(find.text('양식에서 불러오기'), findsWidgets);
    expect(find.textContaining('템플릿'), findsNothing);

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
