import 'package:flutter_test/flutter_test.dart';

/// "필드 / 상태" 편집기의 말풍선 하나를 다른 말풍선 자리로 끌어다 놓는다
/// (ReorderableBubbleList는 Draggable/DragTarget을 직접 쓴다).
Future<void> dragBubble(
  WidgetTester tester, {
  required String from,
  required String to,
}) async {
  // 말풍선은 제목과 작은 설명(분류·단계)을 함께 그리는데 둘의 글자가 같을 수 있다
  // ('진행 중' 상태의 분류도 '진행 중') — 트리에서 먼저 나오는 제목 쪽을 잡는다.
  final source = tester.getCenter(find.text(from).first);
  final target = tester.getCenter(find.text(to).first);
  final gesture = await tester.startGesture(source);
  // Draggable은 탭과 구분하려고 조금 움직여야 끌기가 시작된다.
  await tester.pump(const Duration(milliseconds: 100));
  await gesture.moveBy(const Offset(0, -20));
  await tester.pump();
  await gesture.moveTo(target);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}
