import 'dart:convert';

import 'package:client/screens/project/project_detail_view.dart';
import 'package:client/screens/project/task_views.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/screens/project/filter_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  String? assignee,
}) => {
  'id': id,
  'projectId': 'p1',
  'seq': 1,
  'key': 'TA-$id',
  'projectName': '잔디톡',
  'title': title,
  'assigneeId': assignee,
  'status': status,
  'priority': 'normal',
  'typeId': type,
  'typeName': type,
  'typeColor': color,
  'referenceIds': <String>[],
  'creatorId': 'u1',
  'creatorName': 'Riley',
  'creatorAvatarType': 'initial',
  'startDate': start,
  'dueDate': due,
  'createdAt': DateTime.now().millisecondsSinceEpoch,
};

void main() {
  setUp(TaskListTable.resetRememberedWidths);
  testWidgets('프로젝트 보기: 대시보드·칸반(드래그)·리스트·간트·캘린더', (tester) async {
    tester.view.physicalSize = const Size(1300, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final now = DateTime.now();
    int day(int offset) =>
        DateTime(now.year, now.month, now.day + offset).millisecondsSinceEpoch;
    final tasks = [
      _task(
        '1',
        '기획서 작성',
        start: day(-2),
        due: day(2),
        type: 'Feature',
        color: '#1E88E5',
        assignee: 'u1',
      ),
      _task(
        '2',
        '디자인 시안',
        status: 'doing',
        start: day(-5),
        due: day(-1),
        type: 'Bug',
        color: '#E53935',
        assignee: 'u2',
      ),
      _task('3', '배포 준비', status: 'done', start: day(-9), due: day(-6)),
      _task('4', '일정 없는 업무'),
      {..._task('5', '보관한 업무'), 'archived': true},
    ];
    String? tasksArchivedQuery;
    tasks[0]['commentCount'] = 3;
    tasks[0]['assigneeName'] = 'Riley';
    final patched = <String, dynamic>{};
    final orders = <List<dynamic>>[];

    final client = MockClient((request) async {
      final path = request.url.path;
      const json = {'content-type': 'application/json'};
      if (request.method == 'PATCH' && path.startsWith('/api/tasks/')) {
        patched[path] = jsonDecode(request.body);
        final id = path.split('/').last;
        return http.Response(
          jsonEncode(tasks.firstWhere((t) => t['id'] == id)),
          200,
          headers: json,
        );
      }
      if (request.method == 'POST' && path == '/api/projects/p1/tasks/order') {
        orders.add(jsonDecode(request.body)['ids'] as List<dynamic>);
        return http.Response('{"ok":true}', 200, headers: json);
      }
      if (path == '/api/projects/p1') {
        return http.Response(
          jsonEncode({
            'id': 'p1',
            'teamId': 't1',
            'name': '잔디톡',
            'identifier': 'TA',
            'color': '#5B8DEF',
            'myRole': 'owner',
            'createdAt': DateTime.now().millisecondsSinceEpoch,
            'members': [
              {'id': 'u1', 'username': 'riley', 'name': 'Riley'},
              {'id': 'u2', 'username': 'sam', 'name': 'Sam'},
            ],
          }),
          200,
          headers: json,
        );
      }
      if (path == '/api/projects/p1/task-statuses') {
        return http.Response(
          jsonEncode([
            for (final (i, s) in [
              ('s-todo', '할 일', 'todo'),
              ('s-doing', '진행 중', 'doing'),
              ('s-review', '검수', 'doing'),
              ('s-done', '완료', 'done'),
            ].indexed)
              {
                'id': s.$1,
                'projectId': 'p1',
                'name': s.$2,
                'color': '#5B8DEF',
                'category': s.$3,
                'position': i,
              },
          ]),
          200,
          headers: json,
        );
      }
      if (path == '/api/projects/p1/tasks') {
        tasksArchivedQuery = request.url.queryParameters['archived'];
        return http.Response(jsonEncode(tasks), 200, headers: json);
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

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectDetailView(
            session: session,
            projectId: 'p1',
            reloadTick: 0,
            onDeleted: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    Future<void> openTab(String label) async {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: label);
    }

    // 처음은 대시보드.
    expect(find.text('멤버별 업무현황'), findsOneWidget);

    // 리스트 — 담당자 칸
    await openTab('리스트');
    expect(find.text('기획서 작성'), findsOneWidget);
    expect(find.text('담당자'), findsOneWidget);

    // 필터 패널 — 리스트에는 '상태' 줄이 있고, 칸반보드에는 없다.
    Finder inPanel(String t) =>
        find.descendant(of: find.byType(FilterPanel), matching: find.text(t));
    Future<void> toggleFilter() async {
      await tester.tap(find.text('필터링').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    await toggleFilter();
    expect(inPanel('상태'), findsOneWidget);
    expect(inPanel('우선순위'), findsOneWidget);
    // 보관한 업무는 평소 리스트에 없고, "보관된 업무"를 골랐을 때만(그것만, 흐리게) 보인다.
    expect(find.text('보관한 업무'), findsNothing);
    await tester.tap(inPanel('보관된 업무'));
    await tester.pumpAndSettle();
    expect(find.text('기획서 작성'), findsNothing);
    expect(find.text('보관한 업무'), findsOneWidget);
    expect(find.byTooltip('보관된 업무'), findsOneWidget);
    expect(
      tester
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.text('보관한 업무'),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity,
      0.45,
    );
    await tester.tap(inPanel('보관된 업무'));
    await tester.pumpAndSettle();
    expect(find.text('기획서 작성'), findsOneWidget);
    expect(find.text('보관한 업무'), findsNothing);
    // 필터 추가 → 시작일·마감일.
    await tester.tap(inPanel('필터 추가'));
    await tester.pumpAndSettle();
    Finder inMenu(String t) => find.descendant(
      of: find.byType(FilterPopupCard).last,
      matching: find.text(t),
    );
    expect(inMenu('시작일'), findsOneWidget);
    await tester.tap(inMenu('마감일'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filter-due')), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('filter-due')),
        matching: find.text('연도-월-일'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('오늘'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 오늘까지 마감 — '기획서 작성'(모레 마감)은 빠지고 '디자인 시안'(어제 마감)은 남는다.
    expect(find.text('기획서 작성'), findsNothing);
    expect(find.text('디자인 시안'), findsWidgets);
    expect(find.textContaining('마감일 '), findsOneWidget); // 목록 위 칩
    await tester.tap(find.byTooltip('필터 빼기'));
    await tester.pumpAndSettle();
    expect(find.text('기획서 작성'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(FilterPanel), findsNothing);

    await openTab('대시보드');
    expect(find.text('전체 업무'), findsOneWidget);
    expect(find.text('지연'), findsNWidgets(2)); // 숫자 카드 + 완료율 범례
    expect(find.text('멤버별 업무현황'), findsOneWidget);
    // 카드 제목 + 도넛 가운데 글자 두 곳.
    expect(find.text('전체 완료율'), findsNWidgets(2));

    await openTab('간트차트');
    // 상태별로 묶인 간트차트.
    expect(find.text('상태 / 업무'), findsOneWidget);
    await tester.tap(find.text('주'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await openTab('캘린더');
    expect(find.textContaining('해당 일의 업무'), findsOneWidget);

    // 칸반: 할 일 → 완료로 끌어다 놓기
    // 보관한 것까지 받아 오지만, 필터 없는 리스트에는 보관한 업무가 없다.
    expect(tasksArchivedQuery, 'all');
    await openTab('리스트');
    expect(find.text('보관한 업무'), findsNothing);
    expect(find.byTooltip('보관된 업무'), findsNothing);

    await openTab('칸반보드');
    // 칸반(과 간트·캘린더·대시보드)에는 보관한 업무가 없다.
    expect(find.text('보관한 업무'), findsNothing);
    expect(find.text('업무를 여기로 끌어다 놓으세요'), findsOneWidget); // 빈 '검수' 열
    await toggleFilter();
    expect(inPanel('담당자'), findsOneWidget);
    expect(inPanel('상태'), findsNothing);
    expect(inPanel('보관된 업무'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(FilterPanel), findsNothing);
    // 카드: 댓글 수 · 업무 번호 · 담당자 이름, 열마다 "+ 업무 추가".
    expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
    expect(find.text('3'), findsWidgets);
    expect(find.text('TA-1'), findsOneWidget);
    expect(find.text('Riley'), findsWidgets);
    expect(find.text('업무 추가'), findsNWidgets(4));
    await tester.tap(find.text('업무 추가').at(2));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    final card = find.text('기획서 작성');
    final doneHeader = find.text('완료').first;
    final from = tester.getCenter(card);
    final to = tester.getCenter(doneHeader) + const Offset(0, 120);
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(from + const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(to);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(patched['/api/tasks/1'], {'statusId': 's-done'});
    // 옮긴 열('완료')의 순서도 같이 저장한다.
    expect(orders.single, containsAll(['1', '3']));
    expect(find.text('검수'), findsOneWidget);

    // 같은 열 안에서 위로 끌기 — 상태는 그대로, 순서만 저장.
    patched.clear();
    orders.clear();
    final lower = tester.getCenter(find.text('일정 없는 업무'));
    final upper = tester.getTopLeft(find.text('기획서 작성'));
    final g2 = await tester.startGesture(lower);
    await tester.pump(const Duration(milliseconds: 100));
    await g2.moveTo(lower + const Offset(0, -20));
    await tester.pump(const Duration(milliseconds: 100));
    await g2.moveTo(Offset(lower.dx, upper.dy - 20));
    await tester.pump(const Duration(milliseconds: 100));
    await g2.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(patched, isEmpty);
    expect(orders.single, ['4', '1']);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
