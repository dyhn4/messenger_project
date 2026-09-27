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

  var favorite = false;
  Map<String, dynamic> project() => {
    'favorite': favorite,
    'description': '브리프부터 광고 집행까지 컬럼으로 따라갑니다.',
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
      if (request.method == 'PATCH' && path == '/api/projects/p1/favorite') {
        favorite = jsonDecode(request.body)['favorite'] as bool;
        return http.Response('{}', 200, headers: json);
      }
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
    // (홈 화면의 날짜에도 "3"이 나올 수 있어 굵은 배지 글자만 센다.)
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            w.data == '3' &&
            w.style?.fontWeight == FontWeight.w700,
      ),
      findsOneWidget,
    );

    // 검색칸은 창 가운데, 종은 오른쪽 끝에 온다.
    final search = tester.getRect(find.text('검색어를 입력하세요.'));
    final bell = tester.getCenter(find.byTooltip('알림'));
    final width = tester.getSize(find.byType(ProjectDialog)).width;
    expect((search.center.dx - width / 2).abs(), lessThan(60));
    expect(bell.dx, greaterThan(width - 100));
    // 사이드바에는 알림 항목이 더 이상 없다(종으로 옮겼다).
    expect(find.text('내 업무'), findsOneWidget);
  });

  testWidgets('사이드바: 즐겨찾기 머리글의 꺽쇠로 목록을 접었다 편다', (tester) async {
    favorite = true;
    addTearDown(() => favorite = false);
    await pumpDialog(tester, buildSession());

    final header = find.text('즐겨찾기 1');
    expect(header, findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsWidgets);
    final shown = find.text('잔디톡').evaluate().length;

    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.chevron_right), findsWidgets);
    expect(find.text('잔디톡'), findsNWidgets(shown - 1));

    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(find.text('잔디톡'), findsNWidgets(shown));
  });

  testWidgets('프로젝트 머리: 색 막대 · 큰 이름 · 즐겨찾기 별 · 설명', (tester) async {
    addTearDown(() => favorite = false);
    await pumpDialog(tester, buildSession());

    // 사이드바에서 프로젝트를 연다.
    await tester.tap(find.text('잔디톡').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final name = find.byWidgetPredicate(
      (w) => w is Text && w.data == '잔디톡' && w.style?.fontSize == 22,
    );
    expect(name, findsOneWidget);
    expect(find.text('브리프부터 광고 집행까지 컬럼으로 따라갑니다.'), findsOneWidget);
    // "새 업무"·"프로젝트 설정"은 이름과 같은 맨 윗줄 오른쪽, 탭 줄은 그 바로 아래.
    final newTask = tester.getRect(find.text('새 업무'));
    final settings = tester.getRect(find.byTooltip('프로젝트 설정'));
    final nameRect = tester.getRect(name);
    expect(newTask.left, greaterThan(nameRect.right));
    expect(newTask.top, lessThan(nameRect.bottom));
    expect(settings.top, lessThan(nameRect.bottom));
    final tabTop = tester.getTopLeft(find.text('대시보드')).dy;
    expect(tabTop, greaterThan(newTask.bottom));
    expect(tabTop - nameRect.top, lessThan(90));
    // 이름 오른쪽의 별 — 누르면 즐겨찾기가 되고 채워진 별로 바뀐다.
    final star = find.byIcon(Icons.star_outline_rounded);
    expect(star, findsOneWidget);
    expect(
      tester.getTopLeft(star).dx,
      greaterThan(tester.getTopRight(name).dx),
    );
    await tester.tap(star);
    await tester.pumpAndSettle();
    expect(favorite, isTrue);
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    expect(find.text('즐겨찾기 1'), findsOneWidget); // 사이드바에도 반영
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
