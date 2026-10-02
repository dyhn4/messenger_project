import 'package:client/data/stickers.dart';
import 'package:client/models/sticker_pack.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/widgets/sticker_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 이모티콘 선택창의 세트 이름 줄 — 세트가 많아 한 화면에 안 들어가면 좌우 페이지 단추가 나타나서 한 화면씩
/// 넘기고, 끝에 닿으면 그쪽 단추가 꺼진다. 세트가 적으면 단추가 없다.

ServerStickerPack _pack(int i) => ServerStickerPack.fromJson({
  'id': 'p$i',
  'name': '이모티콘 세트 $i',
  'hidden': false,
  'stickers': [
    {
      'id': 's$i',
      'packId': 'p$i',
      'url': '/files/t$i',
      'fileName': '$i.jpg',
      'mimeType': 'image/jpeg',
      'hidden': false,
    },
  ],
});

Future<void> _pump(WidgetTester tester, {required int packs}) async {
  serverStickers.replace([
    for (var i = 1; i <= packs; i++) _pack(i),
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
}

final _prev = find.byKey(const ValueKey('category-tabs-prev'));
final _next = find.byKey(const ValueKey('category-tabs-next'));

double _offset(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(StickerPicker),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position
    .pixels;

void main() {
  testWidgets('세트가 적어 한 줄에 다 들어가면 페이지 단추가 없다(기본 이모지 세트만)', (tester) async {
    await _pump(tester, packs: 0);
    expect(_prev, findsNothing);
    expect(_next, findsNothing);
  });

  testWidgets('세트가 많으면 양끝에 단추가 나타나고, 처음엔 이전이 꺼져 있다', (tester) async {
    await _pump(tester, packs: 14);
    expect(_prev, findsOneWidget);
    expect(_next, findsOneWidget);
    expect(tester.widget<IconButton>(_prev).onPressed, isNull);
    expect(tester.widget<IconButton>(_next).onPressed, isNotNull);
  });

  testWidgets('다음을 누르면 한 화면(보이는 폭 90%)씩 넘어가고, 끝에 닿으면 다음이 꺼진다', (tester) async {
    await _pump(tester, packs: 14);
    expect(_offset(tester), 0);
    await tester.tap(_next);
    await tester.pumpAndSettle();
    final first = _offset(tester);
    expect(first, greaterThan(100)); // 보이는 폭(약 360)의 90% 안팎
    expect(tester.widget<IconButton>(_prev).onPressed, isNotNull);

    // 끝까지 넘긴다.
    for (
      var i = 0;
      i < 10 && tester.widget<IconButton>(_next).onPressed != null;
      i++
    ) {
      await tester.tap(_next);
      await tester.pumpAndSettle();
    }
    expect(tester.widget<IconButton>(_next).onPressed, isNull);
    expect(tester.widget<IconButton>(_prev).onPressed, isNotNull);

    // 이전으로 되돌아간다.
    final end = _offset(tester);
    await tester.tap(_prev);
    await tester.pumpAndSettle();
    expect(_offset(tester), lessThan(end));
    expect(tester.widget<IconButton>(_next).onPressed, isNotNull);
  });

  testWidgets('넘긴 뒤에도 세트를 골라 그 이모티콘 목록으로 바꿀 수 있다', (tester) async {
    await _pump(tester, packs: 14);
    await tester.tap(_next);
    await tester.pumpAndSettle();
    // 화면에 보이는 칩 중 뒤쪽 세트 하나를 누른다.
    final chips = find.byType(ChoiceChip);
    expect(chips, findsWidgets);
    await tester.tap(find.byType(ChoiceChip).last, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(StickerPicker), findsOneWidget);
  });
}
