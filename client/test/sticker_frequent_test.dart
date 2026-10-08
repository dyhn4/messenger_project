import 'package:client/data/stickers.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/widgets/sticker_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 이모티콘 패널의 "자주 쓰는" 탭 — 이 기기에서 많이 고른 이모티콘(같으면 최근에 고른 것부터)을 맨 앞 탭에 모으고, 패널을
/// 열면 그 탭부터 보여 준다. 고른 적이 없으면 탭이 없다. 패널을 연 동안에는 순서가 바뀌지 않는다.

Future<Sticker?> _pumpPicker(WidgetTester tester, AppSettings settings) async {
  Sticker? picked;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: StickerPicker(
            onSelected: (s) => picked = s,
            settings: settings,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return picked;
}

Finder _tab(String label) =>
    find.descendant(of: find.byType(StickerPicker), matching: find.text(label));

Finder _sticker(String emoji) =>
    find.descendant(of: find.byType(GridView), matching: find.text(emoji));

void main() {
  test('많이 고른 순, 같으면 최근에 고른 순 — 정해 둔 개수만, 오래 안 쓴 것부터 버린다', () async {
    final settings = AppSettings();
    final t0 = DateTime(2026, 1, 1);
    await settings.recordStickerUse('grin', now: t0);
    await settings.recordStickerUse(
      'cool',
      now: t0.add(const Duration(minutes: 1)),
    );
    await settings.recordStickerUse(
      'wink',
      now: t0.add(const Duration(minutes: 2)),
    );
    await settings.recordStickerUse(
      'grin',
      now: t0.add(const Duration(minutes: 3)),
    );
    expect(settings.frequentStickerIds(), ['grin', 'wink', 'cool']);
    expect(settings.frequentStickerIds(limit: 2), ['grin', 'wink']);

    for (var i = 0; i < AppSettings.maxStickerUsageEntries + 5; i++) {
      await settings.recordStickerUse(
        'x$i',
        now: t0.add(Duration(hours: 1, minutes: i)),
      );
    }
    expect(settings.stickerUsage.length, AppSettings.maxStickerUsageEntries);
    // 많이 고른 것도 가장 오래 안 썼으면 버린다 — 넘친 만큼 오래된 것부터.
    expect(settings.stickerUsage.containsKey('cool'), isFalse);
    expect(settings.stickerUsage.containsKey('x0'), isFalse);
    expect(settings.stickerUsage.containsKey('x64'), isTrue);
  });

  testWidgets('고른 적이 없으면 "자주 쓰는" 탭이 없다', (tester) async {
    await _pumpPicker(tester, AppSettings());
    expect(_tab('자주 쓰는'), findsNothing);
    expect(_tab(stickerCategories.first.name), findsOneWidget);
  });

  testWidgets('고른 적이 있으면 맨 앞에 "자주 쓰는" 탭이 생기고 그 탭부터 보인다 — 많이 고른 것이 앞이다', (
    tester,
  ) async {
    final settings = AppSettings();
    await settings.recordStickerUse('cool');
    await settings.recordStickerUse('party');
    await settings.recordStickerUse('party');
    await _pumpPicker(tester, settings);
    expect(_tab('자주 쓰는'), findsOneWidget);
    final party = findStickerById('party')!.emoji;
    final cool = findStickerById('cool')!.emoji;
    expect(_sticker(party), findsOneWidget);
    expect(_sticker(cool), findsOneWidget);
    expect(
      tester.getTopLeft(_sticker(party)).dx,
      lessThan(tester.getTopLeft(_sticker(cool)).dx),
    );
    // 이 탭은 앞쪽(첫 세트 탭보다 왼쪽)에 있다.
    expect(
      tester.getTopLeft(_tab('자주 쓰는')).dx,
      lessThan(tester.getTopLeft(_tab(stickerCategories.first.name)).dx),
    );
  });

  testWidgets('이모티콘을 고르면 횟수가 오르지만, 연 동안에는 칸 순서가 그대로다', (tester) async {
    final settings = AppSettings();
    await settings.recordStickerUse('party');
    await settings.recordStickerUse('party');
    await settings.recordStickerUse('cool');
    Sticker? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StickerPicker(
              onSelected: (s) => picked = s,
              settings: settings,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final cool = findStickerById('cool')!.emoji;
    final party = findStickerById('party')!.emoji;
    for (var i = 0; i < 3; i++) {
      await tester.tap(_sticker(cool));
      await tester.pump();
    }
    expect(picked?.id, 'cool');
    expect(settings.stickerUsage['cool']!.count, 4);
    // 패널을 연 동안에는 그대로(누르는 사이 칸이 움직이지 않게).
    expect(
      tester.getTopLeft(_sticker(party)).dx,
      lessThan(tester.getTopLeft(_sticker(cool)).dx),
    );
    // 다시 열면 반영된다.
    await tester.pumpWidget(const SizedBox());
    await _pumpPicker(tester, settings);
    expect(
      tester.getTopLeft(_sticker(cool)).dx,
      lessThan(tester.getTopLeft(_sticker(party)).dx),
    );
  });

  testWidgets('지금 없는 이모티콘(지우거나 숨긴 세트의 것)은 "자주 쓰는"에 보이지 않는다 — 다 없으면 탭도 없다', (
    tester,
  ) async {
    final settings = AppSettings();
    await settings.recordStickerUse('srv:gone');
    await _pumpPicker(tester, settings);
    expect(_tab('자주 쓰는'), findsNothing);
  });
}
