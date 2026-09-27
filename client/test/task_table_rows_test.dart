import 'package:client/models/project.dart';
import 'package:client/screens/project/task_views.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Task _task(String id, String title) => Task.fromJson({
  'id': id,
  'projectId': 'p1',
  'key': 'TA-$id',
  'projectName': '신제품 런칭 캠페인',
  'title': title,
  'status': 'todo',
  'priority': 'normal',
  'typeName': '캠페인',
  'typeColor': '#E91E63',
  'startDate': DateTime(2026, 9, 1).millisecondsSinceEpoch,
  'dueDate': DateTime(2026, 9, 30).millisecondsSinceEpoch,
  'createdAt': DateTime.now().millisecondsSinceEpoch,
  'creatorName': 'Riley',
});

void main() {
  setUp(TaskListTable.resetRememberedWidths);

  // "내 업무"(프로젝트 이름 두 줄)와 프로젝트 "리스트"(한 줄) 모두 줄 간격이 46px.
  for (final showProject in [true, false]) {
    testWidgets('업무 표 줄 높이 — 프로젝트 이름 ${showProject ? '보임' : '숨김'}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1300, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final session = Session(
        notifications: NotificationService(),
        settings: AppSettings(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskListTable(
              showProjectName: showProject,
              members: showProject ? null : const [],
              tasks: [_task('1', '가'), _task('2', '나')],
              session: session,
              onOpen: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final pitch =
          tester.getTopLeft(find.text('나')).dy -
          tester.getTopLeft(find.text('가')).dy;
      expect(pitch, 46);
      expect(
        find.text('신제품 런칭 캠페인'),
        showProject ? findsNWidgets(2) : findsNothing,
      );
    });
  }
}
