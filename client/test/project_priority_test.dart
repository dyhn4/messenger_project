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
  testWidgets('우선순위 편집: 추가 · 순서 · 삭제', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final calls = <String, dynamic>{};
    const json = {'content-type': 'application/json'};
    Map<String, dynamic> p(String id, String name, String level, int pos) => {
      'id': id,
      'projectId': 'p1',
      'name': name,
      'color': '#5B8DEF',
      'level': level,
      'position': pos,
    };
    final client = MockClient((request) async {
      final path = request.url.path;
      final key = '${request.method} $path';
      if (request.method != 'GET') {
        calls[key] = request.body.isEmpty ? null : jsonDecode(request.body);
        return http.Response('{}', 200, headers: json);
      }
      if (path == '/api/projects/p1/task-priorities') {
        return http.Response(
          jsonEncode([
            p('low', '낮음', 'low', 0),
            p('normal', '보통', 'normal', 1),
            p('high', '높음', 'high', 2),
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
        home: Scaffold(
          body: ProjectPriorityEditor(session: session, projectId: 'p1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('낮음'), findsWidgets);
    expect(find.text('높음'), findsWidgets);

    // 순서: 두 번째를 위로
    await tester.tap(find.byTooltip('위로').at(1));
    await tester.pumpAndSettle();
    expect(calls['POST /api/projects/p1/task-priorities/order'], {
      'ids': ['normal', 'low', 'high'],
    });

    // 추가 — 단계 기본값은 "보통"
    await tester.tap(find.text('추가')); // 제목 줄 오른쪽의 작은 추가 버튼
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '우선순위 이름'), '긴급');
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(calls['POST /api/projects/p1/task-priorities'], {
      'name': '긴급',
      'color': '#5B8DEF',
      'level': 'normal',
    });

    // 삭제
    await tester.tap(find.byTooltip('삭제').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '삭제'));
    await tester.pumpAndSettle();
    expect(
      calls.keys.any((k) => k.startsWith('DELETE /api/task-priorities/')),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
