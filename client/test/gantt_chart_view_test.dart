import 'dart:convert';

import 'package:client/models/project.dart';
import 'package:client/screens/project/gantt_chart_view.dart';
import 'package:client/screens/project/task_detail_panel.dart';
import 'package:client/widgets/grab_cursors.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _json = {'content-type': 'application/json'};

void main() {
  setUp(GanttChartView.resetPrefs);
  final today = DateTime.now();
  int day(int offset) => DateTime(
    today.year,
    today.month,
    today.day + offset,
  ).millisecondsSinceEpoch;

  Task task(
    String id,
    String project,
    String title, {
    required int start,
    required int due,
    String? myRole,
  }) => Task.fromJson({
    'id': id,
    'projectId': project,
    'projectName': project == 'p1' ? '신제품 런칭 캠페인' : '겨울 신메뉴 출시',
    'title': title,
    'status': 'doing',
    'priority': 'medium',
    'startDate': start,
    'dueDate': due,
    'createdAt': day(-30),
    'myRole': ?myRole,
  });

  late Map<String, dynamic> patched;

  Session session() {
    patched = {};
    final s = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    s.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient((request) async {
        if (request.method == 'PATCH') {
          patched = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'id': 't1',
              'projectId': 'p1',
              'title': 'x',
              'status': 'doing',
              'priority': 'medium',
              'createdAt': day(0),
            }),
            200,
            headers: _json,
          );
        }
        if (request.url.path == '/api/projects') {
          return http.Response(
            jsonEncode([
              for (final (id, name, color) in [
                ('p1', '신제품 런칭 캠페인', '#EC4899'),
                ('p2', '겨울 신메뉴 출시', '#F97316'),
                ('p3', '빈 프로젝트', '#10B981'),
              ])
                {
                  'id': id,
                  'teamId': 't1',
                  'name': name,
                  'identifier': id.toUpperCase(),
                  'color': color,
                  'createdAt': day(-60),
                },
            ]),
            200,
            headers: _json,
          );
        }
        return http.Response('[]', 200, headers: _json);
      }),
    );
    return s;
  }

  final tasks = [
    task('t1', 'p1', '랜딩페이지 히어로 카피', start: day(-3), due: day(2)),
    task(
      't2',
      'p1',
      '인스타그램 릴스 편집',
      start: day(1),
      due: day(5),
      myRole: 'assignee',
    ),
    task('t3', 'p2', '흑임자 라떼 3차 배합 테스트', start: day(-10), due: day(-2)),
  ];

  Future<void> pump(
    WidgetTester tester, {
    VoidCallback? onChanged,
    List<TaskStatusDef>? statuses,
    double panelInset = 0,
    VoidCallback? tasksChanged,
  }) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    Widget chart = GanttChartView(
      session: session(),
      teamId: 't1',
      prefsKey: statuses == null ? 'team' : 'project:p1',
      statuses: statuses,
      tasks: tasks,
      onOpen: (_) {},
      onChanged: onChanged ?? () {},
    );
    if (panelInset > 0) {
      chart = TaskPanelInset(width: panelInset, child: chart);
    }
    chart = TaskPanelScope(
      openTask: (_) {},
      tasksChanged: tasksChanged,
      child: chart,
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: chart)));
    await tester.pumpAndSettle();
  }

  testWidgets('프로젝트별로 묶이고, 월 축척 머리글에 분기·월과 오늘이 보인다', (tester) async {
    await pump(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('프로젝트 / 업무'), findsOneWidget);
    expect(find.text('신제품 런칭 캠페인'), findsOneWidget);
    expect(find.text('겨울 신메뉴 출시'), findsOneWidget);
    expect(find.text('빈 프로젝트'), findsNothing); // 업무가 없으면 묶음도 없다
    expect(find.text('랜딩페이지 히어로 카피'), findsOneWidget);
    expect(find.text('${today.month}월'), findsWidgets);
    final q = (today.month - 1) ~/ 3 + 1;
    expect(find.text('${today.year} $q분기'), findsWidgets);
    expect(find.text('3개 프로젝트 선택됨'), findsOneWidget);

    // 묶음 접기.
    await tester.tap(find.text('신제품 런칭 캠페인'));
    await tester.pumpAndSettle();
    expect(find.text('랜딩페이지 히어로 카피'), findsNothing);
  });

  testWidgets('축척(일·주·분기)과 확대/축소를 바꿔도 깨지지 않는다', (tester) async {
    await pump(tester);
    for (final s in ['일', '주', '분기', '월']) {
      await tester.tap(find.text(s));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: s);
    }
    await tester.tap(find.byTooltip('확대'));
    await tester.pumpAndSettle();
    expect(find.text('125%'), findsOneWidget);
    await tester.tap(find.byTooltip('축소'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('축소'));
    await tester.pumpAndSettle();
    expect(find.text('75%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('내 업무만 보기 · 프로젝트 고르기', (tester) async {
    await pump(tester);
    await tester.tap(find.text('내 업무'));
    await tester.pumpAndSettle();
    expect(find.text('인스타그램 릴스 편집'), findsOneWidget);
    expect(find.text('랜딩페이지 히어로 카피'), findsNothing);
    expect(find.text('겨울 신메뉴 출시'), findsNothing);
    await tester.tap(find.text('내 업무'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('3개 프로젝트 선택됨'));
    await tester.pumpAndSettle();
    // 검색 — 이름이나 키로 거른다.
    expect(find.text('프로젝트 이름/프로젝트 키'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '겨울');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InkWell, '빈 프로젝트'), findsNothing);
    await tester.enterText(find.byType(TextField), 'p3');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InkWell, '빈 프로젝트'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    // 하나 끄기(팝업 목록 안의 항목 — 뒤쪽 묶음 머리줄에도 같은 이름이 있다).
    final pickerList = find.ancestor(
      of: find.byType(Checkbox).first,
      matching: find.byType(ListView),
    );
    await tester.tap(
      find.descendant(
        of: pickerList,
        matching: find.widgetWithText(InkWell, '겨울 신메뉴 출시'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2개 프로젝트 선택됨'), findsOneWidget);
    expect(find.text('흑임자 라떼 3차 배합 테스트'), findsNothing);
    // 전체 선택 → 전체 해제.
    await tester.tap(find.text('전체 선택'));
    await tester.pumpAndSettle();
    expect(find.text('3개 프로젝트 선택됨'), findsOneWidget);
    await tester.tap(find.text('전체 해제'));
    await tester.pumpAndSettle();
    expect(find.text('0개 프로젝트 선택됨'), findsOneWidget);
  });

  testWidgets('일 축척에서 막대를 끌면 그만큼 일정이 옮겨져 저장된다', (tester) async {
    var changed = 0;
    var panelNotified = 0;
    await pump(
      tester,
      onChanged: () => changed++,
      tasksChanged: () => panelNotified++,
    );
    await tester.tap(find.text('일'));
    await tester.pumpAndSettle();

    // 랜딩페이지 막대의 툴팁으로 막대를 찾는다.
    final bar = find.byWidgetPredicate(
      (w) => w is Tooltip && (w.message?.startsWith('랜딩페이지') ?? false),
    );
    expect(bar, findsOneWidget);
    final center = tester.getCenter(bar);
    final g = await tester.startGesture(center, kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(18, 0)); // 하루 36px → 2일
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();
    // 옮기기 — 시작일·마감일 둘 다 보여주고 묻는다.
    expect(find.text('일정 변경'), findsOneWidget);
    expect(find.text('시작일'), findsOneWidget);
    expect(find.text('마감일'), findsOneWidget);
    expect(changed, 0);
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();

    DateTime at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);
    expect(changed, 1);
    expect(panelNotified, 1); // 열린 업무 패널도 다시 읽는다
    expect(at(patched['startDate'] as int), at(day(-1)));
    expect(at(patched['dueDate'] as int), at(day(4)));
  });

  Finder barOf(String prefix) => find.byWidgetPredicate(
    (w) => w is Tooltip && (w.message?.startsWith(prefix) ?? false),
  );

  testWidgets('막대 가운데는 손, 양 끝은 좌우 화살표 커서', (tester) async {
    await pump(tester);
    await tester.tap(find.text('일'));
    await tester.pumpAndSettle();
    final rect = tester.getRect(barOf('랜딩페이지'));
    MouseCursor cursorAt(Offset p) {
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, p, tester.view.viewId);
      for (final e in result.path) {
        final target = e.target;
        if (target is RenderMouseRegion && target.cursor != MouseCursor.defer) {
          return target.cursor;
        }
      }
      return MouseCursor.defer;
    }

    expect(cursorAt(rect.center), SystemMouseCursors.grab);
    expect(
      cursorAt(Offset(rect.left + 1, rect.center.dy)),
      SystemMouseCursors.resizeLeftRight,
    );
    expect(
      cursorAt(Offset(rect.right - 1, rect.center.dy)),
      SystemMouseCursors.resizeLeftRight,
    );
  });

  testWidgets('막대 오른쪽 끝을 끌면 마감일만 늘어난다', (tester) async {
    await pump(tester);
    await tester.tap(find.text('일'));
    await tester.pumpAndSettle();
    final rect = tester.getRect(barOf('랜딩페이지'));
    final g = await tester.startGesture(
      Offset(rect.right - 1, rect.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(18, 0)); // 108px → 3일
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();
    // 늘리기 — 바뀐 마감일만 보여준다.
    expect(find.text('일정 변경'), findsOneWidget);
    expect(find.text('시작일'), findsNothing);
    expect(find.text('마감일'), findsOneWidget);
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    DateTime at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);
    expect(at(patched['startDate'] as int), at(day(-3)));
    expect(at(patched['dueDate'] as int), at(day(5)));
  });

  testWidgets('일정 변경을 취소하면 저장하지 않고 막대가 제자리로 돌아온다', (tester) async {
    await pump(tester);
    await tester.tap(find.text('일'));
    await tester.pumpAndSettle();
    final before = tester.getRect(barOf('랜딩페이지'));
    final g = await tester.startGesture(
      before.center,
      kind: PointerDeviceKind.mouse,
    );
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(18, 0));
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(patched, isEmpty);
    expect(tester.getRect(barOf('랜딩페이지')), before);
  });

  testWidgets('막대를 누르는 순간 쥔 손 커서로 바뀐다', (tester) async {
    await pump(tester);
    await tester.tap(find.text('일'));
    await tester.pumpAndSettle();
    final center = tester.getRect(barOf('랜딩페이지')).center;
    MouseCursor cursorAt(Offset p) {
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, p, tester.view.viewId);
      for (final e in result.path) {
        final target = e.target;
        if (target is RenderMouseRegion && target.cursor != MouseCursor.defer) {
          return target.cursor;
        }
      }
      return MouseCursor.defer;
    }

    final g = await tester.startGesture(center, kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(cursorAt(center), GrabCursors.closed);
    await g.up();
    await tester.pumpAndSettle();
    expect(cursorAt(center), GrabCursors.open);
  });

  testWidgets('업무 패널이 열려 화면이 새로 만들어져도 고른 축척·확대는 그대로다', (tester) async {
    await pump(tester);
    await tester.tap(find.text('주'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('확대'));
    await tester.pumpAndSettle();
    // 패널이 열린 것처럼 다른 구조로 다시 그린다(State가 새로 만들어진다).
    await pump(tester, panelInset: 421);
    expect(find.text('125%'), findsOneWidget);
    final w = '${today.month}/';
    expect(find.textContaining(w), findsWidgets); // 주 눈금("9/21" 꼴)
  });

  testWidgets('프로젝트 안에서는 상태별로 묶는다', (tester) async {
    TaskStatusDef st(String id, String name, String cat, int pos) =>
        TaskStatusDef.fromJson({
          'id': id,
          'projectId': 'p1',
          'name': name,
          'color': '#5B8DEF',
          'category': cat,
          'position': pos,
        });
    await pump(
      tester,
      statuses: [st('s1', '브리프', 'todo', 0), st('s2', '제작 중', 'doing', 1)],
    );
    expect(tester.takeException(), isNull);
    expect(find.text('상태 / 업무'), findsOneWidget);
    expect(find.text('제작 중'), findsOneWidget); // 업무가 모두 doing
    expect(find.text('브리프'), findsNothing); // 업무 없는 상태는 묶음이 없다
    expect(find.textContaining('프로젝트 선택됨'), findsNothing);
    expect(find.text('랜딩페이지 히어로 카피'), findsOneWidget);
  });
}
