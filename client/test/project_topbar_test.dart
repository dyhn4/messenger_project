import 'dart:convert';

import 'package:client/models/team.dart';
import 'package:client/screens/project/project_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const json = {'content-type': 'application/json'};
  final now = DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> project() => {
    'id': 'p1',
    'teamId': 't1',
    'name': '잔디톡',
    'identifier': 'TA',
    'color': '#5B8DEF',
    'myRole': 'owner',
    'createdAt': now,
    'members': <Map<String, dynamic>>[],
  };

  Session buildSession({int unread = 0}) {
    final client = MockClient((request) async {
      final path = request.url.path;
      final query = request.url.queryParameters;
      if (path == '/api/projects') {
        // ?archived=1은 종료된 프로젝트 목록.
        return http.Response(
          query['archived'] == '1' ? '[]' : jsonEncode([project()]),
          200,
          headers: json,
        );
      }
      if (path == '/api/projects/home') {
        return http.Response(
          jsonEncode({
            'stats': {'total': 0, 'done': 0, 'doing': 0, 'overdue': 0},
            'projects': [project()],
            'myTasks': [],
            'recentComments': [],
          }),
          200,
          headers: json,
        );
      }
      if (path == '/api/tasks/team') {
        return http.Response(
          jsonEncode([
            {
              'id': 'task-1',
              'projectId': 'p1',
              'projectName': '잔디톡',
              'key': 'TA-12',
              'title': '로그인 오류 확인',
              'status': 'todo',
              'priority': 'normal',
              'createdAt': now,
            },
            {
              'id': 'task-2',
              'projectId': 'p1',
              'projectName': '잔디톡',
              'key': 'TA-13',
              'title': '배포 준비',
              'status': 'todo',
              'priority': 'normal',
              'createdAt': now,
            },
          ]),
          200,
          headers: json,
        );
      }
      if (path == '/api/projects/p1') {
        return http.Response(jsonEncode(project()), 200, headers: json);
      }
      if (path == '/api/tasks/task-1') {
        return http.Response(
          jsonEncode({
            'id': 'task-1',
            'projectId': 'p1',
            'projectName': '잔디톡',
            'key': 'TA-12',
            'title': '로그인 오류 확인',
            'status': 'todo',
            'priority': 'normal',
            'createdAt': now,
            'comments': <Map<String, dynamic>>[],
          }),
          200,
          headers: json,
        );
      }
      if (path == '/api/project-notifications') {
        return http.Response(
          jsonEncode({'unreadCount': unread, 'items': []}),
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
    session.projectUnread = unread;
    return session;
  }

  Future<void> pumpDialog(WidgetTester tester, Session session) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: ProjectDialog(session: session, embedInWindow: true)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('상단 바: 왼쪽 로고 · 가운데 검색칸 · 오른쪽 알림 종', (tester) async {
    await pumpDialog(tester, buildSession(unread: 3));

    // 사이드바에도 프로젝트 목록 머리글이 있어서, 맨 위 로고는 첫 번째 것이다.
    final brand = find.text('프로젝트').first;
    expect(tester.getTopLeft(brand).dx, lessThan(120));
    expect(tester.getTopLeft(brand).dy, lessThan(56));
    expect(find.text('검색어를 입력하세요.'), findsOneWidget);
    expect(find.byTooltip('알림'), findsOneWidget);
    // 안 읽은 알림 개수가 종에 배지로 붙는다.
    expect(find.text('3'), findsOneWidget);

    // 검색칸은 창 가운데, 종은 오른쪽 끝에 온다.
    final search = tester.getRect(find.text('검색어를 입력하세요.'));
    final bell = tester.getCenter(find.byTooltip('알림'));
    final width = tester.getSize(find.byType(ProjectDialog)).width;
    expect((search.center.dx - width / 2).abs(), lessThan(60));
    expect(bell.dx, greaterThan(width - 100));
    // 사이드바에는 알림 항목이 더 이상 없다(종으로 옮겼다).
    expect(find.text('내 업무'), findsOneWidget);
  });

  testWidgets('상단 검색: 업무를 찾아 누르면 그 업무 상세가 열린다', (tester) async {
    await pumpDialog(tester, buildSession());

    await tester.enterText(find.byType(TextField).first, '로그인');
    await tester.pumpAndSettle();
    expect(find.text('로그인 오류 확인'), findsOneWidget);
    expect(find.text('배포 준비'), findsNothing);

    await tester.tap(find.text('로그인 오류 확인'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 업무 상세 대화상자가 업무 번호를 제목으로 열린다.
    expect(find.text('TA-12'), findsWidgets);
  });

  testWidgets('화면 제목: 홈·내 업무·노트는 작은 제목 없음, 캘린더/간트차트는 큰 제목', (tester) async {
    await pumpDialog(tester, buildSession());

    // 홈: 사이드바 항목 말고 본문에 '홈' 글자가 따로 붙지 않는다.
    expect(find.text('홈'), findsOneWidget);

    Future<void> open(String label) async {
      await tester.tap(find.text(label).first);
      await tester.pumpAndSettle();
    }

    // 내 업무: 화면이 스스로 그리는 큰 제목 하나뿐(작은 제목이 겹치지 않는다).
    await open('내 업무');
    expect(find.text('내 업무'), findsNWidgets(2)); // 사이드바 + 본문 큰 제목
    final myTasks = tester.widget<Text>(find.text('내 업무').last).style;

    // 캘린더·간트차트도 "내 업무"와 같은 크기의 제목으로 나온다.
    for (final label in ['캘린더', '간트차트']) {
      await open(label);
      expect(find.text(label), findsNWidgets(2));
      final style = tester.widget<Text>(find.text(label).last).style;
      expect(style?.fontWeight, FontWeight.bold, reason: label);
      expect(style?.fontSize, myTasks?.fontSize, reason: label);
    }
  });

  testWidgets('상단 알림 종을 누르면 알림 팝업이 뜬다', (tester) async {
    await pumpDialog(tester, buildSession());

    expect(find.text('알림'), findsNothing);
    await tester.tap(find.byTooltip('알림'));
    await tester.pumpAndSettle();
    expect(find.text('알림'), findsOneWidget);
    expect(find.text('알림이 없습니다'), findsOneWidget);
  });
}
