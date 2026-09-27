import 'package:client/screens/project/filter_controls.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('필터 달력: ↑/↓에 마우스를 올려도 오류 없이, 달력이 화면 오른쪽 밖으로 안 나간다', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    DateTime? value;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: FilterPanelButton(
              label: '필터링',
              panelBuilder: (context) => FilterPanel(
                quickChips: const [],
                children: [
                  StatefulBuilder(
                    builder: (context, setState) => FilterRow(
                      label: '시작일',
                      onRemove: () {},
                      child: FilterDateField(
                        value: value,
                        onChanged: (d) => setState(() => value = d),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('필터링'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('연도-월-일'));
    await tester.pumpAndSettle();
    expect(find.byType(FilterCalendar), findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    for (final icon in [Icons.arrow_upward, Icons.arrow_downward]) {
      await mouse.moveTo(tester.getCenter(find.byIcon(icon)));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    }
    // 눌러도 달이 바뀌고 달력은 그대로.
    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(FilterCalendar), findsOneWidget);

    // 달력 카드 전체가 화면 안에 있다.
    final card = tester.getRect(
      find
          .ancestor(
            of: find.byType(FilterCalendar),
            matching: find.byType(FilterPopupCard),
          )
          .first,
    );
    expect(card.right, lessThanOrEqualTo(800));
    expect(card.left, greaterThanOrEqualTo(0));
  });
}
