import 'dart:convert';

import 'package:client/screens/project/project_forms.dart';
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
  testWidgets('새 업무: 제목을 넣어야 생성되고, 상태·우선순위는 칩으로 고른다', (tester) async {
    tester.view.physicalSize = const Size(900, 1100);
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
            'priority': 'normal',
            'createdAt': DateTime.now().millisecondsSinceEpoch,
          }),
          201,
          headers: _json,
        );
      }
      if (path == '/api/projects/p1/task-statuses') {
        return http.Response(
          jsonEncode([
            {
              'id': 's1',
              'projectId': 'p1',
              'name': '아이디어',
              'color': '#5B8DEF',
              'category': 'todo',
              'position': 0,
            },
            {
              'id': 's2',
              'projectId': 'p1',
              'name': '레시피 개발',
              'color': '#2E9E6B',
              'category': 'doing',
              'position': 1,
            },
          ]),
          200,
          headers: _json,
        );
      }
      if (path == '/api/projects/p1/task-priorities') {
        return http.Response(
          jsonEncode([
            {
              'id': 'pr-high',
              'projectId': 'p1',
              'name': '긴급',
              'color': '#EF4444',
              'level': 'high',
              'position': 0,
            },
            {
              'id': 'pr-normal',
              'projectId': 'p1',
              'name': '보통',
              'color': '#5B8DEF',
              'level': 'normal',
              'position': 1,
            },
          ]),
          200,
          headers: _json,
        );
      }
      if (path == '/api/projects/p1') {
        return http.Response(
          jsonEncode({
            'id': 'p1',
            'teamId': 't1',
            'name': '겨울 신메뉴 출시',
            'identifier': 'TA',
            'color': '#5B8DEF',
            'myRole': 'owner',
            'createdAt': DateTime.now().millisecondsSinceEpoch,
            'members': [
              {'id': 'u1', 'username': 'riley', 'name': 'Riley'},
            ],
          }),
          200,
          headers: _json,
        );
      }
      return http.Response('[]', 200, headers: _json);
    });

    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.userId = 'u1';
    session.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: client,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showNewTaskDialog(
                context,
                session,
                projectId: 'p1',
                projectName: '겨울 신메뉴 출시',
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

    // 프로젝트 이름은 바꿀 수 없는 칸에 그대로 보인다.
    expect(find.text('겨울 신메뉴 출시'), findsOneWidget);
    expect(find.text('미배정'), findsOneWidget);
    expect(find.text('시작일'), findsOneWidget);
    expect(find.text('마감일'), findsOneWidget);
    expect(find.text('+ 추가'), findsOneWidget);

    // 제목이 비어 있으면 "생성"은 눌리지 않는다.
    final create = find.widgetWithText(FilledButton, '생성');
    expect(tester.widget<FilledButton>(create).onPressed, isNull);

    await tester.enterText(find.widgetWithText(TextField, '업무 입력'), '신메뉴 기획');
    await tester.pump();
    expect(tester.widget<FilledButton>(create).onPressed, isNotNull);

    // 상태는 첫 항목이 미리 골라져 있고, 다른 칩을 누르면 그쪽으로 바뀐다.
    await tester.tap(find.text('레시피 개발'));
    await tester.pump();
    await tester.tap(find.text('긴급'));
    await tester.pump();
    await tester.tap(find.text('나에게 할당'));
    await tester.pump();
    expect(find.text('나에게 할당'), findsNothing); // 이미 나에게 있으면 숨는다
    expect(find.text('Riley'), findsOneWidget);
    expect(find.text('미배정'), findsNothing);

    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(created?['title'], '신메뉴 기획');
    expect(created?['statusId'], 's2');
    expect(created?['priorityId'], 'pr-high');
    expect(created?['priority'], 'high');
    expect(created?['assigneeId'], 'u1');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
