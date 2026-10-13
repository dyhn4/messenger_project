import 'package:client/data/stickers.dart';
import 'package:client/models/sticker_pack.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/widgets/sticker_picker.dart';
import 'package:client/widgets/sticker_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 이모티콘 패널 — 마우스를 올린 이모티콘만 1.4배로, 주변 이모티콘보다 앞(목록 위 오버레이)에 커져 보이고, 마우스가
/// 떠나면 원래대로 돌아온다. 커진 모습이 흐려지지 않게 처음부터 커진 크기로 그려 두고 평소에는 줄여 보여 준다.
/// 이모티콘 이름 툴팁은 띄우지 않는다.
void main() {
  testWidgets('마우스를 올린 이모티콘만 앞에서 1.4배로 보이고, 떠나면 돌아온다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StickerPicker(onSelected: (_) {}, settings: AppSettings()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final stickers = stickerCategories.first.stickers;
    final grid = find.byType(GridView);
    final enlarged = find.byType(CompositedTransformFollower);
    Finder glyph(Sticker s) =>
        find.descendant(of: grid, matching: find.text(s.emoji));

    expect(
      find.descendant(of: grid, matching: find.byType(Tooltip)),
      findsNothing,
    );
    expect(enlarged, findsNothing);
    final idle = tester.getRect(glyph(stickers[0])).width;

    // 커진 크기로 그려 둔다(줄여서 보여 준다) — 그림이면 그 크기로 불러온다.
    final view = tester.widget<StickerView>(
      find.ancestor(of: glyph(stickers[0]), matching: find.byType(StickerView)),
    );
    expect(view.emojiSize, closeTo(28 * 1.4, 0.01));
    expect(view.imageSize, closeTo(64 * 1.4, 0.01));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(glyph(stickers[0])));
    await tester.pumpAndSettle();

    // 커진 이모티콘은 하나뿐이고, 1.4배 폭으로 그려진다.
    expect(enlarged, findsOneWidget);
    final shown = find.descendant(
      of: enlarged,
      matching: find.text(stickers[0].emoji),
    );
    expect(tester.getRect(shown).width / idle, closeTo(1.4, 0.01));

    // 그리드 밖(오버레이)에 그려진다 — 그리드 안의 다른 칸보다 앞이다.
    final viewport = tester.renderObject(
      find.descendant(of: grid, matching: find.byType(Viewport)),
    );
    RenderObject? node = tester.renderObject(enlarged);
    var insideGrid = false;
    while (node != null) {
      if (identical(node, viewport)) insideGrid = true;
      node = node.parent;
    }
    expect(insideGrid, isFalse);

    // 칸 안의 원래 이모티콘은 커진 동안 감춘다(겹쳐 보이지 않게).
    final inPlace = find.ancestor(
      of: find.text(stickers[0].emoji).first,
      matching: find.byType(Visibility),
    );
    expect(tester.widget<Visibility>(inPlace.first).visible, isFalse);

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(enlarged, findsNothing);
    expect(tester.getRect(glyph(stickers[0])).width, closeTo(idle, 0.01));
  });

  testWidgets('스크롤하는 동안에는 확대를 접고, 멈추면 마우스 아래 이모티콘만 다시 키운다', (tester) async {
    // 기본 이모지 세트는 한 화면에 다 들어가서, 스크롤되는 그림 세트(30개)를 맨 앞 탭으로 둔다. 그림은 테스트에서
    // 받아지지 않아 자리 표시만 보이지만 칸·확대 동작은 같다.
    serverStickers.replace([
      ServerStickerPack.fromJson({
        'id': 'p1',
        'name': '리마인',
        'hidden': false,
        'stickers': [
          for (var i = 1; i <= 30; i++)
            {
              'id': 's$i',
              'packId': 'p1',
              'url': '/files/token$i',
              'fileName': '$i.png',
              'mimeType': 'image/png',
              'hidden': false,
            },
        ],
      }),
    ], (u) => 'https://srv$u');
    addTearDown(serverStickers.clear);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StickerPicker(onSelected: (_) {}, settings: AppSettings()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final grid = find.byType(GridView);
    final enlarged = find.byType(CompositedTransformFollower);
    double offset() => tester
        .state<ScrollableState>(
          find.descendant(of: grid, matching: find.byType(Scrollable)),
        )
        .position
        .pixels;
    // 둘째 줄 이모티콘 위 — 스크롤하면 그 자리에 다른 이모티콘이 온다.
    final at = tester.getCenter(
      find.descendant(of: grid, matching: find.byType(StickerView)).at(8),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(at);
    await tester.pumpAndSettle();
    expect(enlarged, findsOneWidget);

    // 휠로 스크롤하면 바로 접힌다(줄어드는 애니메이션 없이 — 밀려나는 이모티콘이 목록 밖에 보이지 않게).
    await tester.sendEventToBinding(
      PointerScrollEvent(position: at, scrollDelta: const Offset(0, 60)),
    );
    await tester.pump();
    await tester.pump();
    expect(offset(), greaterThan(0));
    expect(enlarged, findsNothing);

    // 멈추면 그때 마우스 아래에 있는 이모티콘이 커진다.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(enlarged, findsOneWidget);
    expect(
      tester.widget<CompositedTransformFollower>(enlarged).showWhenUnlinked,
      isFalse,
    );
  });
}
