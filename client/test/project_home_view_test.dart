import 'dart:convert';

import 'package:client/screens/project/project_home_view.dart';
import 'package:client/screens/project/project_widgets.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('홈: 프로젝트 진행률 · 담당 업무 · 이번 주 나의 업무 · 최근 댓글', (tester) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final now = DateTime.now();
    int day(int offset) =>
        DateTime(now.year, now.month, now.day + offset).millisecondsSinceEpoch;
    Map<String, dynamic> task(String n, String title, {int? start, int? due}) =>
        {
          'id': 't$n',
          'projectId': 'p1',
          'projectName': '신제품 런칭 캠페인',
          'key': 'MKT-100$n',
          'title': title,
          'status': 'todo',
          'priority': 'normal',
          'startDate': start,
          'dueDate': due,
          'createdAt': now.millisecondsSinceEpoch,
        };
    final home = {
      'stats': {'total': 6, 'done': 0, 'doing': 0, 'overdue': 1},
      'projects': [
        {
          'id': 'p1',
          'teamId': 't1',
          'name': '신제품 런칭 캠페인',
          'identifier': 'MKT',
          'color': '#E84393',
          'createdAt': now.millisecondsSinceEpoch,
          'taskTotal': 10,
          'taskDone': 1,
        },
      ],
      'myTasks': [
        task('1', '지난 업무', start: day(-5), due: day(-1)),
        task('2', '오늘 진행 중', start: day(-1), due: day(2)),
        task('3', '나중에 시작', start: day(20), due: day(22)),
        task('4', '넷', due: day(30)),
        task('5', '다섯', due: day(30)),
        task('6', '여섯', due: day(30)),
      ],
      'recentComments': [
        {
          'id': 'c1',
          'taskId': 't2',
          'projectId': 'p1',
          'senderName': 'Riley',
          'text': '확인 부탁드려요',
          'createdAt': now.millisecondsSinceEpoch,
          'taskKey': 'MKT-1002',
          'taskTitle': '오늘 진행 중',
        },
      ],
    };
    final client = MockClient((request) async {
      if (request.url.path == '/api/projects/home') {
        return http.Response(
          jsonEncode(home),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('[]', 200);
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

    var calendarOpened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectHomeView(
            session: session,
            teamId: 't1',
            reloadTick: 0,
            onOpenProject: (_) {},
            onOpenMyTasks: () {},
            onOpenCalendar: () => calendarOpened = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 내가 참여한 프로젝트 — 진행률(프로젝트 색 막대)·퍼센트·완료/전체.
    expect(find.text('10%'), findsOneWidget);
    expect(find.text('1/10'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.color, const Color(0xFFE84393));

    // 내가 담당한 업무 — 개수, 다섯 줄 + 더보기.
    expect(
      find.descendant(
        of: find
            .ancestor(of: find.text('내가 담당한 업무'), matching: find.byType(Row))
            .first,
        matching: find.text('6'),
      ),
      findsOneWidget,
    );
    expect(find.text('더보기'), findsOneWidget);

    // 이번 주 나의 업무 — 오늘 진행 중인 업무와 마감이 지난 업무, 먼 업무는 없다.
    Finder inWeek(String t) => find.descendant(
      of: find.byType(SingleChildScrollView).last,
      matching: find.text(t),
    );
    expect(inWeek('오늘 진행 중'), findsOneWidget);
    expect(inWeek('지난 업무'), findsOneWidget);
    expect(inWeek('나중에 시작'), findsNothing);
    expect(find.text('D+1'), findsWidgets);

    await tester.tap(find.text('캘린더'));
    expect(calendarOpened, isTrue);

    expect(find.text('확인 부탁드려요'), findsOneWidget);

    // 줄에 마우스를 올리면 카드 안에서 회색 음영이 칠해진다(카드 바탕에 가리지 않는다).
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    const grey = Color(0xFFF3F4F6);
    Future<void> expectHoverShade(String text, {bool rounded = false}) async {
      await mouse.moveTo(tester.getCenter(find.text(text).first));
      await tester.pumpAndSettle();
      // 그 줄에서 가장 가까운 잉크 판(Material) — 카드 안에 있어야 음영이 보인다.
      final ink = find
          .ancestor(
            of: find.text(text).first,
            matching: find.byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_InkFeatures',
            ),
          )
          .first;
      expect(
        find.ancestor(of: ink, matching: find.byType(ProjectCard)),
        findsOneWidget,
        reason: text,
      );
      expect(ink, findsOneWidget, reason: text);
      expect(
        tester.renderObject(ink),
        rounded ? (paints..rrect(color: grey)) : (paints..rect(color: grey)),
        reason: text,
      );
    }

    await expectHoverShade('넷'); // 내가 담당한 업무
    await expectHoverShade('신제품 런칭 캠페인', rounded: true); // 내가 참여한 프로젝트
    await expectHoverShade('확인 부탁드려요'); // 최근 댓글
  });
}
