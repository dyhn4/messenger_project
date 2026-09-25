import 'dart:convert';

import 'package:client/models/team.dart';
import 'package:client/screens/project/project_dialog.dart';
import 'package:client/screens/project/task_views.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUp(TaskListTable.resetRememberedWidths);
  const json = {'content-type': 'application/json'};
  final now = DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> project() => {
    'id': 'p1',
    'teamId': 't1',
    'name': '신제품 런칭 캠페인',
    'identifier': 'MKT',
    'color': '#5B8DEF',
    'myRole': 'owner',
    'createdAt': now,
    'members': <Map<String, dynamic>>[],
  };

  Map<String, dynamic> task(String id, String title) => {
    'id': id,
    'projectId': 'p1',
    'projectName': '신제품 런칭 캠페인',
    'key': 'MKT-100$id',
    'title': title,
    'status': 'doing',
    'statusName': '제작 중',
    'priority': 'high',
    'priorityName': '높음',
    'typeName': '콘텐츠',
    'typeColor': '#5B8DEF',
    'createdAt': now,
  };

  Session buildSession() {
    final client = MockClient((request) async {
      final path = request.url.path;
      final query = request.url.queryParameters;
      if (path == '/api/projects') {
        return http.Response(
          query['archived'] == '1' ? '[]' : jsonEncode([project()]),
          200,
          headers: json,
        );
      }
      if (path == '/api/tasks/mine') {
        return http.Response(
          jsonEncode([task('1', '랜딩페이지 히어로 카피 A/B 2안 작성')]),
          200,
          headers: json,
        );
      }
      if (path == '/api/project-notifications') {
        return http.Response(
          jsonEncode({'unreadCount': 0, 'items': []}),
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
    session.currentTeam = Team(id: 't1', name: '팀', createdAt: DateTime.now());
    return session;
  }

  final strip = find.byWidgetPredicate(
    (w) =>
        w is Icon &&
        (w.icon == Icons.keyboard_double_arrow_right ||
            w.icon == Icons.keyboard_double_arrow_left),
  );

  Future<void> pumpAt(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ProjectDialog(session: buildSession(), embedInWindow: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 좁은 창이면 메뉴가 접혀 있으므로 » 로 펼쳐서 고른다(고르면 도로 접힌다).
    if (strip.evaluate().isNotEmpty) {
      await tester.tap(strip);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('내 업무').first);
    await tester.pumpAndSettle();
  }

  testWidgets('1400px 이상: 표의 모든 열이 가로 스크롤 없이 다 보인다', (tester) async {
    await pumpAt(tester, 1400);

    for (final h in ['업무', '유형', '우선순위', '상태', '시작일', '마감일', '생성자']) {
      expect(find.text(h), findsWidgets, reason: h);
    }
    // 표가 제 칸 안에 들어가면 가로로 굴릴 게 없다(오른쪽 칸 스크롤 줄 자체가 없다).
    expect(
      find.descendant(
        of: find.byType(TaskListTable),
        matching: find.byWidgetPredicate(
          (w) =>
              w is SingleChildScrollView &&
              w.scrollDirection == Axis.horizontal,
        ),
      ),
      findsNothing,
      reason: '가로 스크롤이 남아 있으면 다 안 보인다',
    );
    // 왼쪽 메뉴는 접히지 않는다.
    expect(strip, findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('800~1400px: 열은 그대로 두고 가로로 밀어서 본다', (tester) async {
    await pumpAt(tester, 1000);

    expect(find.text('우선순위'), findsOneWidget); // 열은 살아 있다
    // "업무" 열 오른쪽 칸들만 가로로 미는 스크롤 줄이 생긴다.
    final hScroll = find.descendant(
      of: find.byType(TaskListTable),
      matching: find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      ),
    );
    expect(hScroll, findsOneWidget);
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: hScroll, matching: find.byType(Scrollable)),
        )
        .position;
    expect(position.maxScrollExtent, greaterThan(0));
    expect(strip, findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('800px 이하: 표는 그대로(업무 열 고정 + 가로 스크롤), 왼쪽 메뉴는 » 버튼으로 접힌다', (
    tester,
  ) async {
    await pumpAt(tester, 780);

    // 리스트와 같은 표 — 열은 다 있고, 넘치는 칸은 가로 스크롤 줄로 본다.
    for (final h in ['업무', '유형', '우선순위', '상태', '마감일']) {
      expect(find.text(h), findsWidgets, reason: h);
    }
    expect(find.text('제작 중'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(TaskListTable),
        matching: find.byWidgetPredicate(
          (w) =>
              w is SingleChildScrollView &&
              w.scrollDirection == Axis.horizontal,
        ),
      ),
      findsOneWidget,
    );

    // 메뉴는 접혀 있고, » 를 누르면 겹쳐서 펼쳐진다.
    expect(strip, findsOneWidget);
    expect(find.text('간트차트'), findsNothing);
    await tester.tap(strip);
    await tester.pumpAndSettle();
    expect(find.text('간트차트'), findsOneWidget);

    // 다시 누르면 접힌다.
    await tester.tap(strip);
    await tester.pumpAndSettle();
    expect(find.text('간트차트'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
