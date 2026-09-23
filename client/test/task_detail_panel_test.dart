import 'dart:convert';

import 'package:client/models/project.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/project/project_dialog.dart';
import 'package:client/screens/project/task_detail_panel.dart';
import 'package:client/screens/project/task_views.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _json = {'content-type': 'application/json'};

void main() {
  final now = DateTime.now().millisecondsSinceEpoch;
  late List<({String method, String path, Map<String, dynamic>? body})> calls;

  Map<String, dynamic> task(
    String id,
    String title, {
    String? parent,
    List<Map<String, dynamic>> checklist = const [],
    List<Map<String, dynamic>> subtasks = const [],
  }) => {
    'id': id,
    'projectId': 'p1',
    'projectName': '신제품 런칭 캠페인',
    'key': 'MKT-$id',
    'title': title,
    'status': 'doing',
    'statusId': 's2',
    'statusName': '검수',
    'priority': 'high',
    'priorityId': 'pr-high',
    'priorityName': '높음',
    'parentTaskId': parent,
    'archived': false,
    'checklistDone': checklist.where((c) => c['done'] == true).length,
    'checklistTotal': checklist.length,
    'subtaskCount': subtasks.length,
    'checklist': checklist,
    'subtasks': subtasks,
    'comments': <Map<String, dynamic>>[],
    'createdAt': now,
  };

  Session buildSession() {
    calls = [];
    final s = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    s.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (request.method != 'GET') {
          calls.add((
            method: request.method,
            path: path,
            body: request.body.isEmpty
                ? null
                : jsonDecode(request.body) as Map<String, dynamic>,
          ));
        }
        if (request.method == 'POST' && path == '/api/tasks/1001/checklist') {
          return http.Response(
            jsonEncode({
              'id': 'c9',
              'taskId': '1001',
              'text': '새 항목',
              'done': false,
            }),
            201,
            headers: _json,
          );
        }
        if (path == '/api/tasks/1001') {
          return http.Response(
            jsonEncode(
              task(
                '1001',
                '디스플레이 배너 3종',
                checklist: [
                  {
                    'id': 'c1',
                    'taskId': '1001',
                    'text': '300×250 시안',
                    'done': true,
                  },
                  {
                    'id': 'c2',
                    'taskId': '1001',
                    'text': '320×100 시안',
                    'done': false,
                  },
                ],
                subtasks: [task('1032', '매체 규격 검수 회의', parent: '1001')],
              ),
            ),
            200,
            headers: _json,
          );
        }
        if (path == '/api/projects/p1') {
          return http.Response(
            jsonEncode({
              'id': 'p1',
              'teamId': 't1',
              'name': '신제품 런칭 캠페인',
              'identifier': 'MKT',
              'color': '#5B8DEF',
              'myRole': 'owner',
              'createdAt': now,
              'members': [
                {'id': 'u1', 'username': 'riley', 'name': 'Riley'},
                {'id': 'u2', 'username': 'mina', 'name': 'Mina Kim'},
              ],
            }),
            200,
            headers: _json,
          );
        }
        if (path == '/api/projects/p1/task-statuses') {
          return http.Response(
            jsonEncode([
              {
                'id': 's1',
                'projectId': 'p1',
                'name': '브리프',
                'color': '#94A3B8',
                'category': 'todo',
                'position': 0,
              },
              {
                'id': 's2',
                'projectId': 'p1',
                'name': '검수',
                'color': '#F59E0B',
                'category': 'doing',
                'position': 1,
              },
            ]),
            200,
            headers: _json,
          );
        }
        if (path == '/api/tasks/1032') {
          return http.Response(
            jsonEncode(task('1032', '매체 규격 검수 회의', parent: '1001')),
            200,
            headers: _json,
          );
        }
        if (path == '/api/tasks/1004') {
          return http.Response(
            jsonEncode(task('1004', '광고 문구 법무 검수')),
            200,
            headers: _json,
          );
        }
        if (path == '/api/projects/p1/tasks') {
          return http.Response(
            jsonEncode([
              task('1001', '디스플레이 배너 3종'),
              task('1004', '광고 문구 법무 검수'),
            ]),
            200,
            headers: _json,
          );
        }
        return http.Response('[]', 200, headers: _json);
      }),
    );
    s.userId = 'u1';
    s.currentTeam = Team(id: 't1', name: '팀', createdAt: DateTime.now());
    return s;
  }

  Future<void> pumpPanel(WidgetTester tester, {String taskId = '1001'}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskDetailPanel(
            session: buildSession(),
            taskId: taskId,
            expanded: false,
            onToggleExpand: () {},
            onClose: () {},
            onOpenTask: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('패널: 제목·체크리스트·하위 업무가 보인다', (tester) async {
    await pumpPanel(tester);
    expect(tester.takeException(), isNull);

    expect(find.text('MKT-1001'), findsOneWidget);
    expect(find.text('디스플레이 배너 3종'), findsOneWidget);
    expect(find.text('체크리스트 (1/2)'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('300×250 시안'), findsOneWidget);
    expect(find.text('하위 업무 (1)'), findsOneWidget);
    expect(find.text('매체 규격 검수 회의'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('패널: 체크리스트 항목을 추가하고 켠다', (tester) async {
    await pumpPanel(tester);

    await tester.enterText(
      find.widgetWithText(TextField, '+ 새 체크리스트 항목 추가 (Enter)'),
      '매체 규격 검수',
    );
    await tester.tap(find.widgetWithText(FilledButton, '추가').first);
    await tester.pumpAndSettle();
    final added = calls.firstWhere((c) => c.path.endsWith('/checklist'));
    expect(added.body?['text'], '매체 규격 검수');

    // 아직 안 켠 항목을 켠다.
    await tester.tap(find.byType(Checkbox).last);
    await tester.pumpAndSettle();
    final toggled = calls.firstWhere(
      (c) => c.path.contains('/checklist-items/'),
    );
    expect(toggled.method, 'PATCH');
    expect(toggled.body?['done'], true);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('패널: 하위 업무를 추가하면 부모를 달고 만든다', (tester) async {
    await pumpPanel(tester);

    await tester.enterText(
      find.widgetWithText(TextField, '+ 새 하위 업무 (Enter)'),
      '규격 재확인',
    );
    await tester.tap(find.widgetWithText(FilledButton, '추가').last);
    await tester.pumpAndSettle();
    final made = calls.firstWhere((c) => c.path == '/api/projects/p1/tasks');
    expect(made.body?['title'], '규격 재확인');
    expect(made.body?['parentTaskId'], '1001');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('패널: 삼점 메뉴에 복사·이동·보관·삭제가 있다', (tester) async {
    await pumpPanel(tester);

    await tester.tap(find.byTooltip('업무 메뉴'));
    await tester.pumpAndSettle();
    for (final label in ['업무 복사', '업무 이동', '업무 보관', '업무 삭제']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    await tester.tap(find.text('업무 보관'));
    await tester.pumpAndSettle();
    final archived = calls.firstWhere((c) => c.path.endsWith('/archive'));
    expect(archived.body?['archived'], true);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  test('목록: 하위 업무가 부모 바로 아래로 들여써서 온다', () {
    Task t(String id, {String? parent}) => Task.fromJson({
      'id': id,
      'projectId': 'p1',
      'title': id,
      'status': 'todo',
      'priority': 'normal',
      'parentTaskId': parent,
      'createdAt': now,
    });
    // 목록 순서상 자식이 부모와 떨어져 있어도 부모 뒤로 모이고, 부모가 없으면 평평하게 둔다.
    final rows = arrangeWithSubtasks([
      t('a'),
      t('b'),
      t('a-1', parent: 'a'),
      t('x-1', parent: '없는부모'),
    ]);
    expect(
      rows.map((r) => '${r.task.id}${r.indented ? '(들여씀)' : ''}').toList(),
      ['a', 'a-1(들여씀)', 'b', 'x-1'],
    );
  });

  testWidgets('프로젝트 창: 업무를 열면 팝업이 아니라 오른쪽 패널로 뜬다', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final session = buildSession();
    await tester.pumpWidget(
      MaterialApp(home: ProjectDialog(session: session, embedInWindow: true)),
    );
    await tester.pumpAndSettle();

    // 목록·검색·알림이 업무를 열 때 쓰는 통로와 같은 경로로 연다.
    final scope = tester.widget<TaskPanelScope>(find.byType(TaskPanelScope));
    scope.openTask('1001');
    await tester.pumpAndSettle();

    expect(find.byType(TaskDetailPanel), findsOneWidget);
    expect(find.byType(Dialog), findsNothing); // 가운데 팝업이 아니다
    // 패널은 창 오른쪽에 붙되, 상단 바(로고·검색·알림 종)를 덮지 않고 그 아래에서 시작한다.
    final panel = tester.getRect(find.byType(TaskDetailPanel));
    expect(panel.right, closeTo(1500, 1));
    expect(panel.width, closeTo(kTaskPanelWidth, 1));
    final bell = tester.getRect(find.byTooltip('알림'));
    expect(panel.top, greaterThanOrEqualTo(bell.bottom));
    expect(find.byTooltip('알림'), findsOneWidget); // 종이 가려지지 않는다

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('크게 보기: 왼쪽 메뉴와 상단 바는 그대로 두고 내용 자리만 채운다', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ProjectDialog(session: buildSession(), embedInWindow: true),
      ),
    );
    await tester.pumpAndSettle();
    tester.widget<TaskPanelScope>(find.byType(TaskPanelScope)).openTask('1001');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('크게 보기'));
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.byType(TaskDetailPanel));
    // 상단 바(알림 종)와 왼쪽 메뉴("간트차트")는 계속 보이고, 패널은 그 오른쪽 아래를 채운다.
    expect(find.byTooltip('알림'), findsOneWidget);
    final menu = tester.getRect(find.text('간트차트'));
    expect(find.text('간트차트'), findsOneWidget);
    expect(panel.left, greaterThan(menu.right));
    expect(panel.right, closeTo(1500, 1));
    expect(panel.width, greaterThan(kTaskPanelWidth));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('패널: 참조자를 드롭다운에서 고르고 칩으로 뺀다', (tester) async {
    await pumpPanel(tester);

    expect(find.text('참조'), findsOneWidget);
    await tester.tap(find.text('+ 추가'));
    await tester.pumpAndSettle();
    // 구성원이 뜬다.
    expect(find.text('Mina Kim'), findsOneWidget);

    await tester.tap(find.text('Mina Kim'));
    await tester.pumpAndSettle();
    final saved = calls.firstWhere((c) => c.method == 'PATCH');
    expect(saved.body?['referenceIds'], ['u2']);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('패널: 상위 업무 칸은 하위 업무에서만 보이고, 거기서 바꿀 수 있다', (tester) async {
    // 부모가 없는 업무에는 그 칸이 아예 없다.
    await pumpPanel(tester, taskId: '1004');
    expect(find.text('상위 업무'), findsNothing);

    // 하위 업무를 열면 보이고, 지금 상위 업무가 적혀 있다.
    await pumpPanel(tester, taskId: '1032');
    expect(find.text('상위 업무'), findsOneWidget);

    await tester.tap(find.text('디스플레이 배너 3종').last);
    await tester.pumpAndSettle();
    // 같은 프로젝트의 다른 업무가 후보로 뜨고, 떼어낼 수 있는 "없음"도 있다.
    expect(find.text('광고 문구 법무 검수'), findsOneWidget);
    expect(find.text('없음'), findsWidgets);

    await tester.tap(find.text('광고 문구 법무 검수'));
    await tester.pumpAndSettle();
    final saved = calls.firstWhere(
      (c) => c.method == 'PATCH' && c.body!.containsKey('parentTaskId'),
    );
    expect(saved.body?['parentTaskId'], '1004');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
