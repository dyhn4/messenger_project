import 'dart:convert';

import 'package:client/models/project.dart';
import 'package:client/screens/project/project_notifications.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
  const json = {'content-type': 'application/json'};

  testWidgets('프로젝트 알림함: 목록·읽음 처리·이동·모두 읽음', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final calls = <String, dynamic>{};
    var unreadRead = false;
    final now = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic> item(String id, String body, bool read) => {
      'id': id,
      'projectId': 'p1',
      'projectName': '잔디톡',
      'projectColor': '#5B8DEF',
      'taskId': 't-$id',
      'kind': id == 'n1' ? 'assigned' : 'due',
      'title': '잔디톡 · TA-1',
      'body': body,
      'createdAt': now,
      'read': read,
    };
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'POST' &&
          path == '/api/project-notifications/read') {
        calls['read'] = jsonDecode(request.body);
        unreadRead = true;
        return http.Response('{"unreadCount":0}', 200, headers: json);
      }
      if (path == '/api/project-notifications') {
        return http.Response(
          jsonEncode({
            'unreadCount': unreadRead ? 0 : 2,
            'items': [
              item('n1', 'Riley님이 업무를 배정했습니다: 기획서', unreadRead),
              item('n2', '마감이 임박했습니다: 배포', unreadRead),
            ],
          }),
          200,
          headers: json,
        );
      }
      return http.Response('[]', 200, headers: json);
    });
    final session = _session(client);

    ProjectNotification? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectNotificationsView(
            session: session,
            reloadTick: 0,
            onOpen: (n) => opened = n,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Riley님이 업무를 배정했습니다'), findsOneWidget);

    await tester.tap(find.textContaining('Riley님이 업무를 배정했습니다'));
    await tester.pumpAndSettle();
    expect(calls['read'], {
      'ids': ['n1'],
    });
    expect(opened?.taskId, 't-n1');

    unreadRead = false;
    calls.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectNotificationsView(
            session: session,
            reloadTick: 1,
            onOpen: (n) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('모두 읽음'));
    await tester.pumpAndSettle();
    expect(calls['read'], <String, dynamic>{});

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('프로젝트 알림 설정: 종류별 토글, 전체 끄기', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final patches = <Map<String, dynamic>>[];
    var state = {
      'muted': false,
      'assigned': true,
      'referenced': true,
      'comment': true,
      'status': true,
      'due': true,
    };
    final client = MockClient((request) async {
      if (request.method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        patches.add(body);
        state = {...state, ...body.cast<String, bool>()};
      }
      return http.Response(jsonEncode(state), 200, headers: json);
    });
    final session = _session(client);
    final project = Project(
      id: 'p1',
      teamId: 't1',
      name: '잔디톡',
      identifier: 'TA',
      createdAt: DateTime.now(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showProjectNotificationSettingsDialog(
                context,
                session,
                project,
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

    await tester.tap(find.text('댓글'));
    await tester.pumpAndSettle();
    expect(patches.last, {'comment': false});

    await tester.tap(find.text('이 프로젝트 알림 끄기'));
    await tester.pumpAndSettle();
    expect(patches.last, {'muted': true});
    // 전체 끄기 상태에서는 종류별 스위치가 잠긴다.
    final due = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '마감 임박'),
    );
    expect(due.onChanged, isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
