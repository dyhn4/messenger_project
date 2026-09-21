import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// 맨 아래 여백을 리스트의 padding이 아니라 "맨 아래 항목(index 0) 안쪽"에 넣으면,
/// scrollTo/jumpTo(index: 0)가 곧바로 진짜 맨 아래에 닿는지 확인한다.
///
/// scrollable_positioned_list의 인덱스+alignment 정렬은 리스트 padding을 계산에 안 넣어서,
/// 여백을 padding으로 주면 그만큼 못 미친 자리에 멈춘다(그래서 따로 픽셀 보정을 해야 했고,
/// 그 2단계 이동이 메시지를 보낼 때 화면이 튀는 원인이었다). 여백이 항목의 일부가 되면
/// 정렬 계산에 자연스럽게 포함되므로 보정이 아예 필요 없어진다.
void main() {
  const gap = 34.0;
  const rowHeight = 60.0;

  Widget harness(ItemScrollController controller) {
    return MaterialApp(
      home: Scaffold(
        body: ScrollablePositionedList.builder(
          itemScrollController: controller,
          reverse: true,
          // 아래쪽 padding은 0 — 여백은 아래 itemBuilder가 index 0 항목 안에 넣는다.
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          itemCount: 30,
          itemBuilder: (context, i) {
            final row = SizedBox(height: rowHeight, child: Text('메시지 $i'));
            if (i != 0) return row;
            return Padding(
              padding: const EdgeInsets.only(bottom: gap),
              child: row,
            );
          },
        ),
      ),
    );
  }

  ScrollPosition positionOf(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable).first).position;

  testWidgets('jumpTo(index: 0)이 보정 없이 곧바로 진짜 맨 아래(minScrollExtent)에 닿는다', (
    tester,
  ) async {
    final controller = ItemScrollController();
    await tester.pumpWidget(harness(controller));
    await tester.pumpAndSettle();

    controller.jumpTo(index: 10);
    await tester.pumpAndSettle();

    controller.jumpTo(index: 0);
    await tester.pumpAndSettle();

    final position = positionOf(tester);
    expect(
      position.pixels,
      moreOrLessEquals(position.minScrollExtent, epsilon: 1),
    );
  });

  testWidgets('scrollTo(index: 0)도 보정 없이 곧바로 진짜 맨 아래에 닿는다', (tester) async {
    final controller = ItemScrollController();
    await tester.pumpWidget(harness(controller));
    await tester.pumpAndSettle();

    controller.jumpTo(index: 10);
    await tester.pumpAndSettle();

    unawaited(
      controller.scrollTo(
        index: 0,
        duration: const Duration(milliseconds: 100),
      ),
    );
    await tester.pumpAndSettle();

    final position = positionOf(tester);
    expect(
      position.pixels,
      moreOrLessEquals(position.minScrollExtent, epsilon: 1),
    );
  });

  testWidgets('맨 아래 메시지가 목록 바닥에서 여백만큼 띄워져 보인다', (tester) async {
    final controller = ItemScrollController();
    await tester.pumpWidget(harness(controller));
    await tester.pumpAndSettle();

    controller.jumpTo(index: 0);
    await tester.pumpAndSettle();

    final listBottom = tester
        .getRect(find.byType(ScrollablePositionedList))
        .bottom;
    final lastMessageBottom = tester.getRect(find.text('메시지 0')).bottom;
    expect(listBottom - lastMessageBottom, moreOrLessEquals(gap, epsilon: 1));
  });
}
