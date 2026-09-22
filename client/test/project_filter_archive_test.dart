import 'dart:convert';

import 'package:client/models/project.dart';
import 'package:client/screens/project/project_detail_view.dart';
import 'package:client/screens/project/task_filter.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _json = {'content-type': 'application/json'};

Map<String, dynamic> _task(
  String id,
  String title, {
  String status = 'todo',
  String priority = 'normal',
  String? assignee,
  Map<String, dynamic> custom = const {},
}) => {
  'id': id,
  'projectId': 'p1',
  'seq': 1,
  'key': 'TA-$id',
  'projectName': '잔디톡',
  'title': title,
  'assigneeId': assignee,
  'status': status,
  'priority': priority,
  'referenceIds': <String>[],
  'customValues': custom,
  'createdAt': DateTime.now().millisecondsSinceEpoch,
};

Session _session(Future<http.Response> Function(http.Request) handler) {
  final session = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: MockClient(handler),
  );
  return session;
}

void main() {
  test('TaskFilter: 검색·상태·우선순위·담당자·필드 조합', () {
    final statuses = [
      const TaskStatusDef(
        id: 's1',
        projectId: 'p1',
        name: '할 일',
        color: '#111111',
        category: TaskStatus.todo,
      ),
      const TaskStatusDef(
        id: 's2',
        projectId: 'p1',
        name: '완료',
        color: '#222222',
        category: TaskStatus.done,
      ),
    ];
    const priorities = [
      TaskPriorityDef(
        id: 'pr-high',
        projectId: 'p1',
        name: '긴급',
        color: '#EF4444',
        level: TaskPriority.high,
      ),
      TaskPriorityDef(
        id: 'pr-normal',
        projectId: 'p1',
        name: '보통',
        color: '#5B8DEF',
        level: TaskPriority.normal,
      ),
    ];
    const fields = [
      TaskFieldDef(
        id: 'f1',
        projectId: 'p1',
        name: '고객사',
        kind: 'select',
        options: ['A', 'B'],
      ),
      TaskFieldDef(id: 'f2', projectId: 'p1', name: '메모', kind: 'text'),
    ];
    final a = Task.fromJson(
      _task(
        '1',
        '로그인 오류',
        priority: 'high',
        assignee: 'u1',
        custom: {'f1': 'A', 'f2': '긴급 건'},
      ),
    );
    final b = Task.fromJson(_task('2', '배포 준비', status: 'done'));

    bool m(TaskFilter f, Task t) => f.matches(
      t,
      statuses: statuses,
      priorities: priorities,
      fields: fields,
    );
    expect(m(const TaskFilter(query: '로그인'), a), isTrue);
    expect(m(const TaskFilter(query: '로그인'), b), isFalse);
    expect(m(const TaskFilter(query: 'ta-2'), b), isTrue); // 업무 번호도 검색
    expect(
      m(const TaskFilter(statusIds: {'s1'}), a),
      isTrue,
    ); // 상태 id 없음 → 분류의 첫 상태
    expect(m(const TaskFilter(statusIds: {'s1'}), b), isFalse);
    // 우선순위는 프로젝트가 정한 항목(id)으로 고른다 — 예전 업무는 같은 단계의 첫 항목으로 본다.
    expect(m(const TaskFilter(priorityIds: {'pr-high'}), a), isTrue);
    expect(m(const TaskFilter(priorityIds: {'pr-normal'}), a), isFalse);
    expect(m(const TaskFilter(assigneeId: 'u1'), a), isTrue);
    expect(m(const TaskFilter(assigneeId: noAssigneeFilter), b), isTrue);
    expect(m(const TaskFilter(assigneeId: noAssigneeFilter), a), isFalse);
    expect(m(const TaskFilter(fieldValues: {'f1': 'A'}), a), isTrue);
    expect(m(const TaskFilter(fieldValues: {'f1': 'B'}), a), isFalse);
    expect(m(const TaskFilter(fieldValues: {'f2': '긴급'}), a), isTrue);
    expect(const TaskFilter().isEmpty, isTrue);
    expect(const TaskFilter(query: 'x', assigneeId: 'u1').activeCount, 2);
  });

  Future<http.Response> Function(http.Request) handler({
    bool archived = false,
  }) {
    return (request) async {
      final path = request.url.path;
      if (path == '/api/projects/p1') {
        return http.Response(
          jsonEncode({
            'id': 'p1',
            'teamId': 't1',
            'name': '잔디톡',
            'identifier': 'TA',
            'color': '#5B8DEF',
            'myRole': 'owner',
            'archived': archived,
            'createdAt': DateTime.now().millisecondsSinceEpoch,
            'members': [
              {'id': 'u1', 'username': 'riley', 'name': 'Riley'},
            ],
          }),
          200,
          headers: _json,
        );
      }
      if (path == '/api/projects/p1/tasks') {
        return http.Response(
          jsonEncode([
            _task('1', '로그인 오류', custom: {'f1': 'A'}),
            _task('2', '배포 준비', custom: {'f1': 'B'}),
            _task('3', '문서 정리'),
          ]),
          200,
          headers: _json,
        );
      }
      if (path == '/api/projects/p1/task-fields') {
        return http.Response(
          jsonEncode([
            {
              'id': 'f1',
              'projectId': 'p1',
              'name': '고객사',
              'kind': 'select',
              'options': ['A', 'B'],
              'position': 0,
            },
          ]),
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
              'name': '할 일',
              'color': '#5B8DEF',
              'category': 'todo',
              'position': 0,
            },
          ]),
          200,
          headers: _json,
        );
      }
      return http.Response('[]', 200, headers: _json);
    };
  }

  Future<void> pumpDetail(WidgetTester tester, Session session) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectDetailView(
            session: session,
            projectId: 'p1',
            reloadTick: 0,
            onDeleted: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('리스트에 사용자 정의 필드 열이 붙고, 필터로 값이 같은 업무만 본다', (tester) async {
    final session = _session(handler());
    await pumpDetail(tester, session);

    // 열 머리글 + 값
    expect(find.text('고객사'), findsOneWidget);
    expect(find.text('로그인 오류'), findsOneWidget);
    expect(find.text('배포 준비'), findsOneWidget);
    expect(find.text('문서 정리'), findsOneWidget);

    // 필터: 고객사 = A. 사용자 정의 필드는 "필터 추가"로 꺼내 쓴다.
    await tester.tap(find.text('필터링'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('필터 추가'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '고객사'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('filter-field-f1')),
        matching: find.text('전체'),
      ),
    );
    await tester.pumpAndSettle();
    // 드롭다운이 열려 있는 동안엔 목록 쪽 'A' 칸은 눌리지 않는다.
    await tester.tap(find.text('A').hitTestable().last);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('로그인 오류'), findsOneWidget);
    expect(find.text('배포 준비'), findsNothing);
    expect(find.text('문서 정리'), findsNothing);
    // 걸린 조건은 목록 위에 칩으로 남는다.
    expect(find.text('고객사: A'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('종료된 프로젝트: 배너가 보이고 새 업무 버튼이 없다', (tester) async {
    final session = _session(handler(archived: true));
    await pumpDetail(tester, session);
    expect(find.textContaining('종료된 프로젝트입니다'), findsOneWidget);
    expect(find.text('새 업무'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
