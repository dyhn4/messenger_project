import 'package:client/models/app_notification.dart';
import 'package:client/services/notification_controller.dart';
import 'package:client/widgets/notification_settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_notification_api.dart';

/// 알림 설정 대화상자 — 내용이 창에 다 안 들어가면 스크롤바가 대화상자 오른쪽 모서리에 붙어서 나타나고,
/// 다 들어가면 스크롤이 필요 없다.

Future<NotificationController> _open(
  WidgetTester tester, {
  required double height,
}) async {
  tester.view.physicalSize = Size(900, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final controller = NotificationController(
    apiProvider: () => FakeNotificationApi(
      settings: const NotificationSettings(
        mentionAll: true,
        boardLevel: BoardNotifyLevel.important,
      ),
    ),
  );
  addTearDown(controller.dispose);
  await controller.loadSettings();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: NotificationSettingsDialog(center: controller)),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(NotificationSettingsDialog),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

void main() {
  testWidgets('창이 낮아 내용이 넘치면 스크롤할 수 있고 스크롤바가 대화상자 오른쪽 끝에 붙는다', (tester) async {
    await _open(tester, height: 380);
    expect(_position(tester).maxScrollExtent, greaterThan(0));

    final scrollbar = find.descendant(
      of: find.byType(NotificationSettingsDialog),
      matching: find.byType(Scrollbar),
    );
    expect(scrollbar, findsOneWidget);
    // 대화상자 카드(Dialog 안의 Material)의 오른쪽 끝.
    final dialogRect = tester.getRect(
      find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first,
    );
    final scrollRect = tester.getRect(scrollbar);
    // 스크롤바가 있는 영역의 오른쪽 끝 = 대화상자의 오른쪽 끝(안쪽 여백 없이 모서리에 붙는다).
    expect(scrollRect.right, closeTo(dialogRect.right, 0.5));
  });

  testWidgets('내용이 다 들어가면 스크롤할 게 없다', (tester) async {
    await _open(tester, height: 1200);
    expect(_position(tester).maxScrollExtent, 0);
  });
}
