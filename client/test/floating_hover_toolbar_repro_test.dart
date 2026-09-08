import 'package:client/widgets/hover_toolbar.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// 실제 채팅 목록(ScrollablePositionedList) + 마우스 호버로 여닫기를 흉내내서,
/// 호버할 때마다 예외가 나는지 재현해 본다.
class _HoverRow extends StatefulWidget {
  final String label;
  const _HoverRow({required this.label});

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  final _portal = OverlayPortalController();
  bool _rowHovering = false;
  bool _toolbarHovering = false;
  bool _hovering = false;

  void _update() {
    final next = _rowHovering || _toolbarHovering;
    if (next != _hovering) setState(() => _hovering = next);
    if (_hovering == _portal.isShowing) return;
    _hovering ? _portal.show() : _portal.hide();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          onEnter: (_) {
            _rowHovering = true;
            _update();
          },
          onExit: (_) {
            _rowHovering = false;
            _update();
          },
          child: SizedBox(height: 60, child: Text(widget.label)),
        ),
        FloatingHoverToolbar(
          controller: _portal,
          toolbarBuilder: (context) => MouseRegion(
            onEnter: (_) {
              _toolbarHovering = true;
              _update();
            },
            onExit: (_) {
              _toolbarHovering = false;
              _update();
            },
            child: const HoverToolbar(
              children: [
                HoverToolbarButton(icon: Icons.more_vert, tooltip: '더보기'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

void main() {
  testWidgets('목록 안에서 호버로 여닫아도 예외가 없다', (tester) async {
    final itemScrollController = ItemScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScrollablePositionedList.builder(
            itemScrollController: itemScrollController,
            reverse: true,
            itemCount: 40,
            itemBuilder: (context, i) => _HoverRow(label: '메시지 $i'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    // 여러 메시지 위를 차례로 지나가 본다(툴바가 떴다 사라졌다 반복).
    for (final label in ['메시지 0', '메시지 1', '메시지 2']) {
      await mouse.moveTo(tester.getCenter(find.text(label)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$label 호버 중 예외');
    }

    // 툴바가 떠 있는 상태에서 그 메시지를 목록 밖으로 스크롤시켜 사라지게 한다
    // (= 마우스가 위에 있는 채로 위젯이 unmount되는 상황).
    await mouse.moveTo(tester.getCenter(find.text('메시지 2')));
    await tester.pumpAndSettle();
    itemScrollController.jumpTo(index: 30);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '스크롤로 사라질 때 예외');
  });
}
