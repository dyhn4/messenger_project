import 'package:client/widgets/category_tab_row.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 세트/카테고리 탭 줄(widgets/category_tab_row.dart) — 채팅 입력창 이모티콘 목록과 프로필
/// 카드 "캐릭터 선택하기"가 같이 쓴다. 고르기와, 꾹 눌러서 끄는 순서 바꾸기(채팅 쪽만)를 본다.

Future<void> _pump(
  WidgetTester tester, {
  required List<String> items,
  required String selected,
  void Function(String)? onSelected,
  void Function(List<String>)? onReorder,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CategoryTabRow<String>(
          items: items,
          selected: selected,
          labelOf: (s) => s,
          onSelected: onSelected ?? (_) {},
          onReorder: onReorder,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('칩을 누르면 onSelected가 불린다', (tester) async {
    String? picked;
    await _pump(
      tester,
      items: const ['가', '나', '다'],
      selected: '가',
      onSelected: (s) => picked = s,
    );
    await tester.tap(find.widgetWithText(ChoiceChip, '나'));
    expect(picked, '나');
  });

  testWidgets('onReorder를 안 주면 꾹 눌러도 드래그 핸들이 없다(그냥 목록)', (tester) async {
    await _pump(tester, items: const ['가', '나', '다'], selected: '가');
    expect(find.byType(ReorderableListView), findsNothing);
  });

  testWidgets('onReorder를 주면 꾹 눌러서 끌어 순서를 바꿀 수 있다', (tester) async {
    List<String>? newOrder;
    await _pump(
      tester,
      items: const ['가', '나', '다'],
      selected: '가',
      onReorder: (order) => newOrder = order,
    );
    expect(find.byType(ReorderableListView), findsOneWidget);

    final start = tester.getCenter(find.widgetWithText(ChoiceChip, '가'));
    final end = tester.getCenter(find.widgetWithText(ChoiceChip, '다'));
    final gesture = await tester.startGesture(start);
    // ReorderableDelayedDragStartListener — 꾹 눌러야(길게 누르기 시간을 넘겨야) 드래그가
    // 시작된다. 짧게 누르고 바로 움직이면 그냥 탭으로 끝난다.
    await tester.pump(kLongPressTimeout + kPressTimeout);
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    // '가'가 원래 자리(맨 앞)에서 '다' 쪽으로 옮겨진다(정확히 어디서 멈추는지는 드래그 픽셀
    // 위치에 달렸지만, 더는 맨 앞이 아니어야 한다).
    expect(newOrder, isNotNull);
    expect(newOrder!.first, isNot('가'));
    expect(newOrder, containsAll(['가', '나', '다']));
  });
}
