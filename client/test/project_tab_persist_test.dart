import 'dart:convert';

import 'package:client/screens/project/project_detail_view.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('프로젝트를 바꿔도 보던 탭이 유지된다', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const json = {'content-type': 'application/json'};
    final now = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic> project(String id, String name) => {
      'id': id,
      'teamId': 't1',
      'name': name,
      'identifier': id.toUpperCase(),
      'color': '#5B8DEF',
      'myRole': 'owner',
      'createdAt': now,
      'members': <Map<String, dynamic>>[],
    };
    Map<String, dynamic> task(String id, String title) => {
      'id': id,
      'projectId': id.startsWith('a') ? 'p1' : 'p2',
      'title': title,
      'status': 'todo',
      'priority': 'normal',
      'createdAt': now,
    };

    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/projects/p1') {
        return http.Response(
          jsonEncode(project('p1', '첫 프로젝트')),
          200,
          headers: json,
        );
      }
      if (path == '/api/projects/p2') {
        return http.Response(
          jsonEncode(project('p2', '둘째 프로젝트')),
          200,
          headers: json,
        );
      }
      if (path == '/api/projects/p1/tasks') {
        return http.Response(
          jsonEncode([task('a1', '첫 업무')]),
          200,
          headers: json,
        );
      }
      if (path == '/api/projects/p2/tasks') {
        return http.Response(
          jsonEncode([task('b1', '둘째 업무')]),
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

    Future<void> show(String projectId) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProjectDetailView(
              session: session,
              projectId: projectId,
              reloadTick: 0,
              onDeleted: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show('p1');
    expect(tester.takeException(), isNull);
    expect(find.text('첫 업무'), findsOneWidget); // 기본은 리스트

    // 대시보드로 옮긴다.
    await tester.tap(find.text('대시보드'));
    await tester.pumpAndSettle();
    expect(find.text('멤버별 업무현황'), findsOneWidget);

    // 다른 프로젝트로 바꿔도 대시보드 그대로이고, 내용은 새 프로젝트 것이다.
    await show('p2');
    expect(tester.takeException(), isNull);
    expect(find.text('멤버별 업무현황'), findsOneWidget);
    expect(find.text('첫 업무'), findsNothing);

    // 리스트로 돌아가면 새 프로젝트의 업무가 보인다.
    await tester.tap(find.text('리스트'));
    await tester.pumpAndSettle();
    expect(find.text('둘째 업무'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
