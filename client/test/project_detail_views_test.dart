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
    ];
    final patched = <String, dynamic>{};

    final client = MockClient((request) async {
      final path = request.url.path;
      const json = {'content-type': 'application/json'};
      if (request.method == 'PATCH' && path.startsWith('/api/tasks/')) {
        patched[path] = jsonDecode(request.body);
        return http.Response('{}', 200, headers: json);
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

    // 기본은 리스트 — 담당자 칸
    expect(find.text('기획서 작성'), findsOneWidget);
    expect(find.text('담당자'), findsOneWidget);

    Future<void> openTab(String label) async {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: label);
    }

    await openTab('대시보드');
    expect(find.text('상태별 업무'), findsOneWidget);
    expect(find.text('담당자별 업무'), findsOneWidget);
    expect(find.text('진행률'), findsOneWidget);

    await openTab('간트차트');
    expect(find.text('업무'), findsWidgets);
    await tester.tap(find.text('주'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await openTab('캘린더');
    expect(find.textContaining('해당 일의 업무'), findsOneWidget);

    // 칸반: 할 일 → 완료로 끌어다 놓기
    await openTab('칸반보드');
    expect(find.text('업무를 여기로 끌어다 놓으세요'), findsOneWidget); // 빈 '검수' 열
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
    expect(find.text('검수'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
