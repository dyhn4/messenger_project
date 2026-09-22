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

  Widget bellApp(Session session, void Function(ProjectNotification) onOpen) =>
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: ProjectNotificationsBell(session: session, onOpen: onOpen),
          ),
        ),
      );

  testWidgets('알림 종: 팝업 목록·읽음 처리·이동·모두 읽음', (tester) async {
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
    await tester.pumpWidget(bellApp(session, (n) => opened = n));
    await tester.pumpAndSettle();

    // 팝업은 종을 눌러야 열린다.
    expect(find.text('알림'), findsNothing);
    await tester.tap(find.byTooltip('알림'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('알림'), findsOneWidget);
    expect(find.textContaining('Riley님이 업무를 배정했습니다'), findsOneWidget);

    await tester.tap(find.textContaining('Riley님이 업무를 배정했습니다'));
    await tester.pumpAndSettle();
    expect(calls['read'], {
      'ids': ['n1'],
    });
    expect(opened?.taskId, 't-n1');
    // 항목을 누르면 팝업이 닫힌다.
    expect(find.text('알림'), findsNothing);

    unreadRead = false;
    calls.clear();
    await tester.tap(find.byTooltip('알림'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('모두 읽음'));
    await tester.pumpAndSettle();
    expect(calls['read'], <String, dynamic>{});

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('알림 종: 받은 알림이 없으면 "알림이 없습니다"', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final client = MockClient((request) async {
      if (request.url.path == '/api/project-notifications') {
        return http.Response(
          '{"unreadCount":0,"items":[]}',
          200,
          headers: json,
        );
      }
      return http.Response('[]', 200, headers: json);
    });
    await tester.pumpWidget(bellApp(_session(client), (_) {}));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('알림'));
    await tester.pumpAndSettle();
    expect(find.text('알림'), findsOneWidget);
    expect(find.text('알림이 없습니다'), findsOneWidget);
    expect(find.text('모두 읽음'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('알림 정책: 관리자는 종류별로 끄고, 개인은 자기 것만 끈다', (tester) async {
    tester.view.physicalSize = const Size(1200, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final patches = <String, Map<String, dynamic>>{};
    var policy = {
      'status': true,
      'priority': true,
      'assigned': true,
      'referenced': true,
      'dueDate': true,
      'taskType': true,
      'customField': true,
      'created': true,
      'deleted': true,
      'comment': true,
      'due': true,
    };
    var muted = false;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        patches[path] = body;
        if (path.endsWith('/notification-policy')) {
          policy = {...policy, ...body.cast<String, bool>()};
          return http.Response(jsonEncode(policy), 200, headers: json);
        }
        muted = body['muted'] as bool;
        return http.Response(jsonEncode({'muted': muted}), 200, headers: json);
      }
      if (path.endsWith('/notification-policy')) {
        return http.Response(jsonEncode(policy), 200, headers: json);
      }
      return http.Response(jsonEncode({'muted': muted}), 200, headers: json);
    });

    Future<void> pump(Session session, {required bool canManage}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProjectNotificationSettingsEditor(
              key: ValueKey(canManage),
              session: session,
              projectId: 'p1',
              canManage: canManage,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // 관리자 — 정책을 끌 수 있다.
    await pump(_session(client), canManage: true);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('모든 멤버에게 적용됩니다'), findsOneWidget);
    for (final label in ['상태 변경', '우선순위 변경', '담당자 변경', '마감일 변경', '유형 변경']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    await tester.tap(find.text('우선순위 변경'));
    await tester.pumpAndSettle();
    expect(patches['/api/projects/p1/notification-policy'], {
      'priority': false,
    });

    // 개인 설정은 정책과 별개로 항상 바꿀 수 있다.
    await tester.tap(find.text('이 프로젝트 알림 끄기'));
    await tester.pumpAndSettle();
    expect(patches['/api/projects/p1/notification-settings'], {'muted': true});

    // 관리자가 아니면 정책 스위치가 잠긴다(내 설정은 그대로 열려 있다).
    patches.clear();
    await pump(_session(client), canManage: false);
    expect(find.textContaining('프로젝트 담당자나 팀 관리자여야 합니다'), findsOneWidget);
    final statusTile = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '상태 변경'),
    );
    expect(statusTile.onChanged, isNull);
    final mine = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '이 프로젝트 알림 끄기'),
    );
    expect(mine.onChanged, isNotNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
