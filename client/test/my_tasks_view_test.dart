import 'dart:convert';

import 'package:client/screens/project/my_tasks_view.dart';
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
  testWidgets('내 업무: 리스트 → 캘린더(월/주) → 필터', (tester) async {
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

    // 캘린더(월)
    await tester.tap(find.text('캘린더'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('${now.year}년 ${now.month}월'), findsOneWidget);
    expect(find.textContaining('해당 일의 업무'), findsOneWidget);

    // 주 보기 전환 + 이전/다음
    await tester.tap(find.text('주'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    await tester.tap(find.text('오늘'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 좁은 폭에서도 오버플로 없이
    tester.view.physicalSize = const Size(700, 700);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 필터 열기 → 적용
    await tester.tap(find.text('필터링'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('참조').last);
    await tester.tap(find.text('적용'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('필터링 1'), findsOneWidget);
  });
}
