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

const _json = {'content-type': 'application/json'};

void main() {
  final now = DateTime.now();

  Map<String, dynamic> task(
    String id,
    String title, {
    String status = 'todo',
    String? assignee,
    DateTime? due,
  }) => {
    'id': id,
    'projectId': 'p1',
    'key': 'TA-$id',
    'title': title,
    'status': status,
    'priority': 'normal',
    'assigneeId': assignee,
    'dueDate': due?.millisecondsSinceEpoch,
    'createdAt': now.millisecondsSinceEpoch,
  };

  Session session() {
    final s = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    s.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient((request) async {
        switch (request.url.path) {
          case '/api/projects/p1':
            return http.Response(
              jsonEncode({
                'id': 'p1',
                'teamId': 't1',
                'name': '잔디톡',
                'identifier': 'TA',
                'color': '#5B8DEF',
                'myRole': 'owner',
                'createdAt': now.millisecondsSinceEpoch,
                'members': [
                  {'id': 'u1', 'username': 'riley', 'name': 'Riley'},
                  {'id': 'u2', 'username': 'sam', 'name': 'Sam'},
                ],
              }),
              200,
              headers: _json,
            );
          case '/api/projects/p1/tasks':
            return http.Response(
              jsonEncode([
                task('1', '완료된 일', status: 'done', assignee: 'u1'),
                task('2', '하는 중', assignee: 'u1'),
                task(
                  '3',
                  '늦은 일',
                  assignee: 'u2',
                  due: now.subtract(const Duration(days: 2)),
                ),
              ]),
              200,
              headers: _json,
            );
          default:
            return http.Response('[]', 200, headers: _json);
        }
      }),
    );
    return s;
  }

  Future<void> pumpDashboard(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 950);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectDetailView(
            session: session(),
            projectId: 'p1',
            reloadTick: 0,
            onDeleted: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('대시보드'));
    await tester.pumpAndSettle();
  }

  testWidgets('대시보드 숫자 카드를 누르면 리스트 탭에 그 조건만 걸린다', (tester) async {
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);

    // "완료" 카드 → 리스트에 완료된 업무만.
    await tester.tap(find.text('완료').first);
    await tester.pumpAndSettle();
    expect(find.text('완료된 업무'), findsOneWidget); // 걸린 조건 칩
    expect(find.text('완료된 일'), findsOneWidget);
    expect(find.text('하는 중'), findsNothing);

    // 대시보드로 돌아가 "지연" 카드 → 마감이 지난 업무만.
    await tester.tap(find.text('대시보드'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('지연').first);
    await tester.pumpAndSettle();
    expect(find.text('지연 업무'), findsOneWidget);
    expect(find.text('늦은 일'), findsOneWidget);
    expect(find.text('완료된 일'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('멤버별 업무현황 전체보기에서 멤버의 업무를 본다', (tester) async {
    await pumpDashboard(tester);

    // 카드에 멤버가 담당 수와 함께 보인다.
    expect(find.text('Riley'), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget);

    await tester.tap(find.text('전체보기'));
    await tester.pumpAndSettle();
    expect(find.textContaining('멤버를 선택하면'), findsOneWidget);
    expect(find.text('멤버 2명'), findsOneWidget);

    await tester.tap(find.text('Sam').last);
    await tester.pumpAndSettle();
    expect(find.text('Sam · 담당 업무 1'), findsOneWidget);
    expect(find.text('늦은 일'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
