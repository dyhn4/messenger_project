import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// message_bubble.dart의 실제 구조(긴 텍스트를 마우스로 드래그해서 선택, 그 바깥은
/// 여전히 롱프레스로 액션시트가 뜨는 GestureDetector로 감싸져 있음)를 흉내내서, 클릭+드래그
/// 선택이 실제로 되는지, 그리고 그 드래그가 바깥 onLongPress와 경합해 액션시트를 잘못
/// 띄우지 않는지 확인한다.
void main() {
  Widget harness({required VoidCallback onLongPress}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: GestureDetector(
            onLongPress: onLongPress,
            child: Container(
              width: 300,
              padding: const EdgeInsets.all(12),
              color: Colors.grey.shade200,
              child: const SelectableText('안녕하세요 이것은 테스트 메시지입니다'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('마우스로 텍스트 위를 클릭+드래그하면 선택되고, 커서가 I-beam으로 바뀐다', (tester) async {
    var longPressed = false;
    await tester.pumpWidget(harness(onLongPress: () => longPressed = true));

    // SelectableText 내부에 mouse 커서를 text로 지정한 MouseRegion이 있어야 한다.
    final textCursorRegions = tester
        .widgetList<MouseRegion>(find.byType(MouseRegion))
        .where((r) => r.cursor == SystemMouseCursors.text);
    expect(textCursorRegions, isNotEmpty);

    final selectableFinder = find.byType(SelectableText);
    final start = tester.getTopLeft(selectableFinder) + const Offset(4, 8);
    final end = tester.getTopLeft(selectableFinder) + const Offset(120, 8);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: start);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.down(start);
    await tester.pump(const Duration(milliseconds: 50));
    await mouse.moveTo(end);
    await tester.pump(const Duration(milliseconds: 50));
    await mouse.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    final state = tester.state<EditableTextState>(find.byType(EditableText));
    expect(
      state.textEditingValue.selection.isCollapsed,
      isFalse,
      reason: '드래그로 텍스트가 선택돼야 한다',
    );
    // 클릭+드래그(빠른 이동)는 롱프레스 타이머보다 먼저 끝나므로 바깥 롱프레스가 안 불려야 한다.
    expect(longPressed, isFalse);
  });

  testWidgets('텍스트 위에서 오래 누르고 있으면(드래그 없이) 크래시 없이 처리된다', (tester) async {
    await tester.pumpWidget(harness(onLongPress: () {}));

    final selectableFinder = find.byType(SelectableText);
    final point = tester.getCenter(selectableFinder);

    final gesture = await tester.startGesture(point);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
