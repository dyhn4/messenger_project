import 'dart:ui' as ui;

import 'package:client/screens/capture/capture_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ui.Image> _blank(int w, int h) {
  final c = Completer2();
  final pixels = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 200);
  ui.decodeImageFromPixels(pixels, w, h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

class Completer2 {
  final _c = <ui.Image>[];
  void complete(ui.Image i) => _c.add(i);
  Future<ui.Image> get future async {
    while (_c.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return _c.first;
  }
}

void main() {
  testWidgets('capture overlay: text, pen, select+delete, cancel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final image = (await tester.runAsync(() => _blank(1000, 600)))!;
    await tester.pumpWidget(debugCaptureOverlay(image));
    await tester.pump();

    Future<void> drag(Offset a, Offset b) async {
      final g = await tester.startGesture(a);
      await g.moveTo(Offset.lerp(a, b, 0.5)!);
      await g.moveTo(b);
      await g.up();
      await tester.pump();
    }

    final g0 = await tester.startGesture(const Offset(100, 200));
    await tester.pump();
    await g0.moveTo(const Offset(700, 500));
    await tester.pump();
    await g0.up();
    await tester.pump();
    expect(find.byIcon(Icons.title), findsOneWidget);

    // 글쓰기
    await tester.tap(find.byIcon(Icons.title));
    await tester.pump();
    final g = await tester.startGesture(const Offset(200, 260));
    await g.up();
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.byType(TextField), findsNothing);

    // 그리기
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();
    await drag(const Offset(300, 300), const Offset(500, 350));

    // 도형
    await tester.tap(find.byIcon(Icons.crop_square).first);
    await tester.pump();
    await drag(const Offset(300, 380), const Offset(450, 440));

    // 선택 → 클릭으로 고르고 Delete
    await tester.tap(find.byIcon(Icons.open_with));
    await tester.pump();
    final s = await tester.startGesture(const Offset(400, 325));
    await s.up();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();

    // 선택 영역만 다시 그리도록, 선택 크기의 RepaintBoundary가 있어야 한다.
    final boundaries = tester
        .widgetList<RepaintBoundary>(find.byType(RepaintBoundary))
        .toList();
    expect(boundaries, isNotEmpty);
    final selectionSized = find.byType(RepaintBoundary).evaluate().any((e) {
      final size = (e.renderObject as RenderBox?)?.size;
      return size != null &&
          (size.width - 600).abs() < 1 &&
          (size.height - 300).abs() < 1;
    });
    expect(selectionSized, isTrue, reason: '선택 영역 크기의 레이어가 있어야 함');

    // 취소를 누르면 예외 없이 오버레이가 화면에서 사라져야 한다(창은 재사용을 위해 남는다).
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pump(const Duration(seconds: 6));
    expect(tester.takeException(), isNull);
    expect(find.byType(CustomPaint), findsNothing);
  });
}
