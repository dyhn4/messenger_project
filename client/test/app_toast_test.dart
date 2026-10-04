import 'package:client/widgets/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 앱 토스트(showAppToast) — 어디서 불러도 앱 맨 위(루트) Overlay의 창 가운데 아래에 같은 모양으로 뜬다. 화면 일부에만 깔린
/// Overlay(PC 할 일 패널의 중첩 Navigator, 채팅·댓글 목록의 Overlay.wrap) 안에서 불러도 그 좁은 칸 안에서 찌그러지지 않고,
/// 화상 키보드가 올라와 있으면 그 위에 뜬다.

/// 창 오른쪽 420 칸에 [Overlay.wrap]을 깔고 그 안의 context를 돌려준다(채팅·댓글 목록과 같은 자리).
Future<BuildContext> _pumpNarrowOverlay(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  late BuildContext inner;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            const Expanded(child: SizedBox()),
            SizedBox(
              key: const ValueKey('narrow'),
              width: 420,
              child: Overlay.wrap(
                child: Builder(
                  builder: (context) {
                    inner = context;
                    return const SizedBox.expand();
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  return inner;
}

void main() {
  testWidgets('좁은 Overlay.wrap 안에서 불러도 창 맨 위 Overlay의 가운데 아래에, 찌그러지지 않고 뜬다', (
    tester,
  ) async {
    final inner = await _pumpNarrowOverlay(tester, const Size(1280, 800));
    // 그 좁은 칸이 가장 가까운 Overlay다(예전에는 여기에 떠서 폭이 0이 됐다).
    expect(
      tester.getRect(find.byKey(const ValueKey('narrow'))).width,
      lessThan(1280 * 0.6),
    );
    showAppToast(inner, '좁은 칸에서 띄운 알림');
    await tester.pump();
    final toast = find.text('좁은 칸에서 띄운 알림');
    expect(toast, findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('narrow')),
        matching: toast,
      ),
      findsNothing,
    );
    expect(tester.getSize(toast).width, greaterThan(300));
    expect(tester.getCenter(toast).dx, closeTo(640, 1));
    expect(tester.getBottomLeft(toast).dy, greaterThan(800 - 60));
    await tester.pump(const Duration(seconds: 3));
    expect(toast, findsNothing);
  });

  testWidgets('화상 키보드가 올라와 있으면 키보드 위에 뜬다(없으면 예전처럼 아래에서 32)', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    late BuildContext inner;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              inner = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    showAppToast(inner, '키보드 없을 때');
    await tester.pump();
    final low = tester.getBottomLeft(find.text('키보드 없을 때')).dy;
    expect(low, greaterThan(844 - 60));
    await tester.pump(const Duration(seconds: 3));

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    showAppToast(inner, '키보드 있을 때');
    await tester.pump();
    final high = tester.getBottomLeft(find.text('키보드 있을 때')).dy;
    expect(high, lessThan(844 - 300));
    expect(high, closeTo(low - 300, 1));
    await tester.pump(const Duration(seconds: 3));
  });
}
