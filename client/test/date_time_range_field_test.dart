// 기간 입력(DateTimeRangeField)의 판 — 판은 루트 Overlay에 칸 자리를 따라 띄운다. 예전엔 CompositedTransformFollower로
// 따라붙여서, 판 안의 ‹ 이전 달 / 다음 달 › 툴팁이 레이아웃 때 자리를 못 재 마우스를 올렸다 떼면
// "'debugNeedsLayout': is not true" 오류가 났다(OverlayPortal.overlayChildLayoutBuilder로 바꿔 고침).
import 'package:client/screens/schedule_message_dialog.dart';
import 'package:client/widgets/date_time_range_field.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpField(WidgetTester tester) async {
    var value = const DateTimeRangeSelection();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Padding(
              padding: const EdgeInsets.all(20),
              child: DateTimeRangeField(
                value: value,
                onChanged: (v) => setState(() => value = v),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('range-period-field')));
    await tester.pumpAndSettle();
  }

  testWidgets('달 이동 꺾쇠에 마우스를 올렸다 떼도 오류가 나지 않는다', (tester) async {
    await pumpField(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    for (final (key, tip) in [('prev', '이전 달'), ('next', '다음 달')]) {
      await mouse.moveTo(
        tester.getCenter(find.byKey(ValueKey('range-period-$key'))),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(find.text(tip), findsOneWidget, reason: '툴팁이 뜬다');
      await mouse.moveTo(const Offset(5, 590));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('판은 칸 바로 아래 왼쪽 끝에 맞춰 뜬다', (tester) async {
    await pumpField(tester);
    final field = tester.getRect(
      find.byKey(const ValueKey('range-period-field')),
    );
    final popup = tester.getRect(
      find.byKey(const ValueKey('range-period-popup')),
    );
    expect(popup.left, field.left);
    expect(popup.top, field.bottom + 6);
  });

  testWidgets('예약 메시지의 날짜·시각 칸도 다음 달 꺾쇠에 마우스를 올렸다 떼도 오류가 없고, 판은 칸 바로 아래에 뜬다', (
    tester,
  ) async {
    var value = DateTime.now().add(const Duration(days: 1));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Padding(
              padding: const EdgeInsets.all(20),
              child: ScheduleDateTimeField(
                value: value,
                onChanged: (v) => setState(() => value = v),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('schedule-datetime')));
    await tester.pumpAndSettle();
    final field = tester.getRect(
      find.byKey(const ValueKey('schedule-datetime')),
    );
    final popup = tester.getRect(
      find.byKey(const ValueKey('schedule-datetime-popup')),
    );
    expect(popup.left, field.left);
    expect(popup.top, field.bottom + 6);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byTooltip('다음 달')));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await mouse.moveTo(const Offset(5, 590));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });
}
