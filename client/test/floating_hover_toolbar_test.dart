import 'package:client/widgets/hover_toolbar.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 이 위젯은 예전에 두 번 실패했던 "말풍선 밖으로 겹쳐 뜨는 툴바"를 다시 만든 것이라
/// 그 실패들이 재발하지 않는지 지킨다.
///  * Stack의 Positioned로 넘치게 그리기 → 넘친 영역에 클릭이 안 먹음.
///  * CompositedTransformFollower로 Overlay에 띄우기 → 툴바 버튼의 Tooltip이 레이아웃 중에
///    좌표를 물어보다가 'RenderFollowerLayer' 오류 + 'debugNeedsLayout' 단언으로 크래시.
void main() {
  Widget harness({
    required OverlayPortalController controller,
    VoidCallback? onPressed,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(width: 200, height: 40, child: Text('말풍선')),
              FloatingHoverToolbar(
                controller: controller,
                toolbarBuilder: (context) => HoverToolbar(
                  children: [
                    HoverToolbarButton(
                      icon: Icons.mode_comment_outlined,
                      tooltip: '댓글',
                      onPressed: onPressed,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('보이기 전에는 툴바가 트리에 없고, 앵커는 레이아웃을 차지하지 않는다', (tester) async {
    final controller = OverlayPortalController();
    await tester.pumpWidget(harness(controller: controller));

    expect(find.byType(HoverToolbar), findsNothing);
    // 앵커가 0크기라서 아래 내용이 안 밀린다.
    expect(tester.getSize(find.byType(FloatingHoverToolbar)), Size.zero);
  });

  testWidgets('show()하면 앵커 바로 아래에 뜨고, 그 버튼 클릭도 먹는다', (tester) async {
    final controller = OverlayPortalController();
    var pressed = 0;
    await tester.pumpWidget(
      harness(controller: controller, onPressed: () => pressed++),
    );

    final anchorTopLeft = tester.getTopLeft(find.byType(FloatingHoverToolbar));

    controller.show();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(HoverToolbar), findsOneWidget);

    // 앵커(말풍선 왼쪽 아래) 기준으로 기본 offset(0,2)만큼 아래에 그려진다.
    expect(
      tester.getTopLeft(find.byType(HoverToolbar)),
      anchorTopLeft + const Offset(0, 2),
    );

    // Stack 오버플로 방식에서 안 먹던 부분 — Overlay로 띄운 툴바는 클릭이 정상 동작해야 한다.
    await tester.tap(find.byIcon(Icons.mode_comment_outlined));
    await tester.pump();
    expect(pressed, 1);

    controller.hide();
    await tester.pumpAndSettle();
    expect(find.byType(HoverToolbar), findsNothing);
  });

  testWidgets('툴바 버튼에 마우스를 올려 툴팁이 떠도 크래시하지 않는다', (tester) async {
    // 사용자가 실제로 만난 크래시 재현: 툴바 위로 마우스를 올린 뒤 댓글/더보기 버튼으로
    // 옮기면 Tooltip이 뜨는데, 툴바가 CompositedTransformFollower 안에 있으면 여기서
    // 'The paint transform cannot be reliably computed because of RenderFollowerLayer(s)'
    // + 'debugNeedsLayout' 단언이 터졌다.
    final controller = OverlayPortalController();
    await tester.pumpWidget(harness(controller: controller, onPressed: () {}));

    controller.show();
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    await mouse.moveTo(
      tester.getCenter(find.byIcon(Icons.mode_comment_outlined)),
    );
    await tester.pump();
    // 툴팁이 뜰 때까지 기다린다(Tooltip의 기본 waitDuration/showDuration).
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('댓글'), findsOneWidget); // 툴팁이 실제로 떴다.
  });

  testWidgets('스크롤로 앵커가 화면 밖으로 나가도 크래시 없이 처리된다', (tester) async {
    final controller = OverlayPortalController();
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: scrollController,
            children: [
              const SizedBox(height: 40, child: Text('말풍선')),
              FloatingHoverToolbar(
                controller: controller,
                toolbarBuilder: (context) => const HoverToolbar(
                  children: [
                    HoverToolbarButton(icon: Icons.more_vert, tooltip: '더보기'),
                  ],
                ),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );

    controller.show();
    await tester.pumpAndSettle();
    expect(find.byType(HoverToolbar), findsOneWidget);

    scrollController.jumpTo(1500);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
