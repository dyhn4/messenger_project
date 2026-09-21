import 'dart:convert';

import 'package:client/screens/project/task_config_manager.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('상태·필드 관리: 상태 추가/순서/삭제, 선택 필드 추가', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final calls = <String, dynamic>{};
    const json = {'content-type': 'application/json'};
    Map<String, dynamic> st(String id, String name, String cat, int pos) => {
      'id': id,
      'projectId': 'p1',
      'name': name,
      'color': '#5B8DEF',
      'category': cat,
      'position': pos,
    };
    final client = MockClient((request) async {
      final path = request.url.path;
      final key = '${request.method} $path';
      if (request.method != 'GET') {
        calls[key] = request.body.isEmpty ? null : jsonDecode(request.body);
        return http.Response('{}', 200, headers: json);
      }
      if (path == '/api/projects/p1/task-statuses') {
        return http.Response(
          jsonEncode([
            st('a', '할 일', 'todo', 0),
            st('b', '진행 중', 'doing', 1),
            st('c', '완료', 'done', 2),
          ]),
          200,
          headers: json,
        );
      }
      return http.Response('[]', 200, headers: json);
    });
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
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
              onPressed: () =>
                  showTaskConfigManagerDialog(context, session, 'p1'),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('진행 중'), findsWidgets);

    // 순서: 두 번째를 위로
    await tester.tap(find.byTooltip('위로').at(1));
    await tester.pumpAndSettle();
    expect(calls['POST /api/projects/p1/task-statuses/order'], {
      'ids': ['b', 'a', 'c'],
    });

    // 상태 추가(기본 분류 '진행 중')
    await tester.tap(find.text('상태 추가'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '상태 이름'), '검수');
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(calls['POST /api/projects/p1/task-statuses'], {
      'name': '검수',
      'color': '#5B8DEF',
      'category': 'doing',
    });

    // 삭제
    await tester.tap(find.byTooltip('삭제').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '삭제'));
    await tester.pumpAndSettle();
    expect(
      calls.keys.any((k) => k.startsWith('DELETE /api/task-statuses/')),
      isTrue,
    );

    // 필드 탭: 선택 필드 추가
    await tester.tap(find.text('사용자 정의 필드'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('필드 추가'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '필드 이름'), '고객사');
    await tester.tap(find.text('선택'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '선택지 (쉼표로 구분)'),
      'A사, B사',
    );
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(calls['POST /api/projects/p1/task-fields'], {
      'name': '고객사',
      'kind': 'select',
      'options': ['A사', 'B사'],
    });

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
