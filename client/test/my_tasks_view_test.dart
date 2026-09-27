import 'dart:convert';

import 'package:client/models/project.dart';
import 'package:client/screens/project/filter_controls.dart';
import 'package:client/screens/project/my_tasks_view.dart';
import 'package:client/screens/project/task_detail_panel.dart';
import 'package:client/screens/project/task_views.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _task(
  String id,
  String title, {
  String status = 'todo',
  int? start,
  int? due,
  String? type,
  String? color,
  String role = 'assignee',
}) => {
  'id': id,
  'projectId': 'p1',
  'seq': 1,
  'key': 'TA-$id',
  'projectName': '잔디톡',
  'title': title,
  'assigneeId': role == 'assignee' ? 'me' : 'other',
  'status': status,
  'priority': 'normal',
  'typeId': type,
  'typeName': type,
  'typeColor': color,
  'referenceIds': <String>[],
  'myRole': role,
  'creatorId': 'c1',
  'creatorName': 'Riley',
  'creatorAvatarType': 'initial',
  'startDate': start,
  'dueDate': due,
  'createdAt': DateTime.now().millisecondsSinceEpoch,
};

void main() {
  setUp(TaskListTable.resetRememberedWidths);
  test('내 업무 기본 정렬: 프로젝트 키 → 업무 번호 오름차순', () {
    Task t(String key) => Task.fromJson({..._task('a', 'x'), 'key': key});
    final list = [t('MKT-1010'), t('FNB-1020'), t('MKT-999'), t('FNB-1003')]
      ..sort(compareTaskKeys);
    expect(list.map((e) => e.key), [
      'FNB-1003',
      'FNB-1020',
      'MKT-999',
      'MKT-1010',
    ]);
  });

  testWidgets('내 업무: 리스트 + 필터(탭 없이 리스트만)', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final now = DateTime.now();
    int day(int offset) =>
        DateTime(now.year, now.month, now.day + offset).millisecondsSinceEpoch;
    final tasks = [
      _task(
        '1',
        '4월 오프라인 행사',
        status: 'done',
        start: day(-3),
        due: day(1),
        type: '행사',
        color: '#FDD835',
      ),
      _task(
        '2',
        '채널 연동 가이드 제작',
        start: day(-8),
        due: day(-1),
        type: 'Improvement',
        color: '#43A047',
      ),
      _task(
        '3',
        '대시보드 수정',
        status: 'doing',
        start: day(0),
        due: day(2),
        type: 'Bug',
        color: '#E53935',
      ),
      _task('4', '참조만 걸린 업무', due: day(3), role: 'reference'),
      _task('5', '일정 없는 업무'),
      for (var i = 0; i < 6; i++)
        _task('x$i', '겹치는 업무 $i', start: day(0), due: day(1)),
    ];

    final client = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/tasks/mine')) {
        return http.Response(
          jsonEncode(tasks),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path.endsWith('/projects')) {
        return http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
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
          body: MyTasksView(session: session, teamId: 't1', reloadTick: 0),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 리스트
    expect(find.text('내 업무'), findsOneWidget);
    expect(find.text('4월 오프라인 행사'), findsOneWidget);
    expect(find.text('참조'), findsOneWidget); // 참조된 업무 표시
    expect(find.text('D+1'), findsOneWidget); // 마감이 지난 업무

    // 줄에 마우스를 올려 연필이 나와도 줄 높이가 그대로 — 아래 줄이 움직이지 않는다.
    final below = find.text('대시보드 수정');
    final before = tester.getTopLeft(below).dy;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(
      location: tester.getCenter(find.text('채널 연동 가이드 제작')),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('제목 수정'), findsOneWidget);
    expect(tester.getTopLeft(below).dy, before);
    await mouse.moveTo(const Offset(1, 1));
    await tester.pumpAndSettle();

    // 리스트/캘린더 탭은 없앴다 — 리스트만 보인다.
    expect(find.text('캘린더'), findsNothing);
    expect(find.text('리스트'), findsNothing);

    // 좁은 폭에서도 오버플로 없이
    tester.view.physicalSize = const Size(700, 700);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 필터 패널: 빠른 필터링 세 개(내 업무·보관은 없음) — 누르면 바로 걸리고 패널은 열려 있다.
    await tester.tap(find.text('필터링'));
    await tester.pumpAndSettle();
    expect(find.text('빠른 필터링'), findsOneWidget);
    expect(find.text('미완료 업무'), findsOneWidget);
    expect(find.text('완료된 업무'), findsOneWidget);
    await tester.tap(find.text('지연 업무'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('필터링 1'), findsOneWidget);
    expect(find.text('채널 연동 가이드 제작'), findsOneWidget);
    expect(find.text('대시보드 수정'), findsNothing);
    expect(find.text('빠른 필터링'), findsOneWidget);
    await tester.tap(find.text('지연 업무'));
    await tester.pumpAndSettle();
    expect(find.text('필터링 1'), findsNothing); // 버튼은 다시 '필터링'

    // 필터 추가 → 프로젝트·시작일·마감일. 마감일을 꺼내면 날짜 칸이 생긴다.
    await tester.tap(find.text('필터 추가'));
    await tester.pumpAndSettle();
    Finder inMenu(String t) => find.descendant(
      of: find.byType(FilterPopupCard).last,
      matching: find.text(t),
    );
    expect(inMenu('프로젝트'), findsOneWidget);
    expect(inMenu('시작일'), findsOneWidget);
    await tester.tap(inMenu('마감일'));
    await tester.pumpAndSettle();
    expect(find.text('빠른 필터링'), findsOneWidget);
    expect(find.text('연도-월-일'), findsOneWidget);

    // 달력에서 오늘을 고르면 오늘까지 마감인 업무만. 달력을 눌러도 패널은 안 닫힌다.
    await tester.tap(find.text('연도-월-일'));
    await tester.pumpAndSettle();
    expect(find.byType(FilterCalendar), findsOneWidget);
    // 머리 "YYYY년 MM월", 요일 줄, 아래 삭제·오늘.
    expect(
      find.text('${now.year}년 ${now.month.toString().padLeft(2, '0')}월'),
      findsOneWidget,
    );
    expect(find.text('삭제'), findsOneWidget);
    await tester.tap(find.text('오늘'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(FilterCalendar), findsNothing);
    final todayText =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    expect(find.text(todayText), findsOneWidget);
    expect(find.text('빠른 필터링'), findsOneWidget);
    expect(find.text('필터링 1'), findsOneWidget);
    expect(find.text('채널 연동 가이드 제작'), findsOneWidget);
    expect(find.text('대시보드 수정'), findsNothing);

    // × 로 그 필터를 빼고, 바깥을 누르면 패널이 닫힌다.
    await tester.tap(find.byTooltip('필터 빼기'));
    await tester.pumpAndSettle();
    expect(find.text('필터링 1'), findsNothing); // 버튼은 다시 '필터링'
    expect(find.text('연도-월-일'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('빠른 필터링'), findsNothing);
  });

  testWidgets('캘린더 보기: 월/주 전환과 이전·다음·오늘', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final now = DateTime.now();
    int day(int offset) =>
        DateTime(now.year, now.month, now.day + offset).millisecondsSinceEpoch;
    final tasks = [
      for (final t in [
        _task('1', '4월 오프라인 행사', start: day(-3), due: day(1)),
        _task('2', '대시보드 수정', start: day(0), due: day(2)),
        for (var i = 0; i < 6; i++)
          _task('x$i', '겹치는 업무 $i', start: day(0), due: day(1)),
      ])
        Task.fromJson(t),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskCalendarView(tasks: tasks, onOpen: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('${now.year}년 ${now.month}월'), findsOneWidget);
    expect(find.textContaining('해당 일의 업무'), findsOneWidget);

    await tester.tap(find.text('주'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    await tester.tap(find.text('오늘'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('캘린더 일별 목록: 제목·프로젝트·기간·담당자, 업무 사이 실선', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    String ymd(DateTime d) =>
        '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';
    final start = today.subtract(const Duration(days: 3));
    final due = today.add(const Duration(days: 2));
    final tasks = [
      Task.fromJson({
        ..._task(
          '1',
          '랜딩페이지 히어로 카피',
          start: start.millisecondsSinceEpoch,
          due: due.millisecondsSinceEpoch,
        ),
        'projectName': '신제품 런칭 캠페인',
        'assigneeId': 'u1',
        'assigneeName': '송병근',
      }),
      Task.fromJson(
        _task(
          '2',
          '디스플레이 배너 3종',
          start: today.millisecondsSinceEpoch,
          due: today.millisecondsSinceEpoch,
        ),
      ),
    ];
    Widget calendar() => TaskCalendarView(tasks: tasks, onOpen: (_) {});

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: calendar())));
    await tester.pumpAndSettle();
    expect(find.text('해당 일의 업무 2건'), findsOneWidget);
    expect(find.text('신제품 런칭 캠페인'), findsOneWidget);
    expect(find.text('${ymd(start)} ~ ${ymd(due)}'), findsOneWidget);
    expect(find.text('송병근'), findsOneWidget);
    expect(find.text('미배정'), findsOneWidget);
    // 두 업무 사이에 실선 하나.
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Divider),
      ),
      findsOneWidget,
    );

    // 업무 패널이 옆에 열리면 일별 목록 자리는 패널이 덮는다(목록이 빠진다).
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TaskPanelInset(width: 421, child: calendar())),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('해당 일의 업무'), findsNothing);
  });

  testWidgets('사이드바 캘린더: 막대와 일별 목록 색이 프로젝트 색', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final tasks = [
      Task.fromJson(
        _task('1', '배너 제작', start: today, due: today, color: '#5B8DEF'),
      ),
    ];
    const pink = Color(0xFFEC4899);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskCalendarView(
            tasks: tasks,
            onOpen: (_) {},
            projectColors: const {'p1': pink},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final barText = tester
        .widgetList<Text>(find.text('배너 제작'))
        .firstWhere((t) => t.style?.fontSize == 11);
    expect(barText.style?.color, Color.lerp(pink, Colors.black, 0.45));
  });
}
