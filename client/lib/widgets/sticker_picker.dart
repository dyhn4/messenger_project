import 'package:flutter/material.dart';

import '../data/stickers.dart';
import '../services/app_settings.dart';
import 'category_tab_row.dart';
import 'sticker_view.dart';

/// 카테고리 탭 + 이모티콘 그리드. 채팅/댓글 화면에서 메시지 목록 위에 떠 있는 오버레이 카드로
/// 쓰인다(입력창을 밀어내지 않고 그 위에 겹쳐 보이는 카카오톡 방식) — 그래서 스스로 배경/그림자를
/// 가진 카드 모양이다. 하나를 탭하면 [onSelected]만 호출하고 스스로 닫히지 않는다 — 실제로
/// 보낼지/취소할지, 패널을 닫을지는 호출부(채팅/댓글 화면)가 정한다.
///
/// 맨 앞 탭은 "자주 쓰는" — 이 기기에서 많이 고른 이모티콘(같으면 최근에 고른 것부터, [AppSettings.
/// frequentStickerIds])이다. 고른 적이 있을 때만 보이고, 패널을 열면 그 탭부터 보여 준다. 패널을 연
/// 동안에는 순서를 바꾸지 않는다(누르는 사이 칸이 움직이지 않게) — 다음에 열 때 반영된다. 이 탭은 끌어서
/// 옮기지 않고 늘 맨 앞이다.
///
/// 그 뒤 탭은 기본으로 서버에 올린 그림 이모티콘 세트(예: "리마인")가 먼저, 그 뒤에 기본 이모지
/// 세트가 온다 — 단, [settings]에 저장해 둔 순서(탭을 꾹 눌러서 끌어 바꾼 적이 있으면)가
/// 있으면 그 순서를 따른다(category_tab_row.dart). 그림 세트가 새로 올라오면(서버 목록을
/// 다시 받으면) 스스로 탭을 다시 그린다.
///
/// 세트가 많아 세트 이름 줄이 한 화면에 안 들어가면 그 줄 양끝에 이전/다음 페이지 단추(‹ ›)가
/// 나타난다(category_tab_row.dart).
class StickerPicker extends StatefulWidget {
  final void Function(Sticker sticker) onSelected;
  final AppSettings settings;
  const StickerPicker({
    super.key,
    required this.onSelected,
    required this.settings,
  });

  @override
  State<StickerPicker> createState() => _StickerPickerState();
}

/// "자주 쓰는" 탭의 이름(세트 이름과 겹치지 않게 보이지 않는 글자로 시작) — 화면에는 [_frequentLabel].
const _frequentName = '\u0000frequent';
const _frequentLabel = '자주 쓰는';

class _StickerPickerState extends State<StickerPicker> {
  /// 탭은 이름으로 기억한다 — 서버 세트가 늘거나 줄어도 보던 탭이 그대로 남게.
  String? _categoryName;

  /// 패널을 열 때 읽어 둔 "자주 쓰는" 이모티콘 id(순서 그대로).
  late final List<String> _frequentIds = widget.settings.frequentStickerIds();

  /// [natural](기본 순서) 중 [order]에 있는 이름은 그 순서대로, 없는 이름(아직 안 끌어서
  /// 넣어본 새 세트)은 기본 순서 그대로 뒤에 남는다.
  List<StickerCategory> _ordered(
    List<StickerCategory> natural,
    List<String> order,
  ) {
    if (order.isEmpty) return natural;
    final byName = {for (final c in natural) c.name: c};
    final result = [
      for (final name in order)
        if (byName.remove(name) != null)
          natural.firstWhere((c) => c.name == name),
    ];
    result.addAll(byName.values);
    return result;
  }

  /// 지금 고를 수 있는 이모티콘 중 [_frequentIds]에 있는 것(숨기거나 지운 세트의 것은 뺀다).
  StickerCategory? _frequent(List<StickerCategory> categories) {
    if (_frequentIds.isEmpty) return null;
    final byId = {
      for (final c in categories)
        for (final s in c.stickers) s.id: s,
    };
    final stickers = [
      for (final id in _frequentIds)
        if (byId[id] != null) byId[id]!,
    ];
    return stickers.isEmpty ? null : StickerCategory(_frequentName, stickers);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: serverStickers,
      builder: (context, _) {
        final sets = _ordered([
          ...serverStickers.visibleCategories,
          ...stickerCategories,
        ], widget.settings.stickerCategoryOrder);
        final frequent = _frequent(sets);
        final categories = [?frequent, ...sets];
        final category = categories.firstWhere(
          (c) => c.name == _categoryName,
          orElse: () => categories.first,
        );
        final images = category.stickers.any((s) => s.isImage);
        return Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(12),
          color: Theme.of(context).colorScheme.surface,
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 450,
            // 그리드 자체가 스크롤되니 몇 줄만 보여도 충분하다 — 나머지는 스크롤해서 본다. 그림
            // 이모티콘은 칸이 커서 두 줄쯤 보이게 조금 더 높다.
            height: images ? 220 : 140,
            child: Column(
              children: [
                CategoryTabRow<StickerCategory>(
                  items: categories,
                  selected: category,
                  labelOf: (c) =>
                      c.name == _frequentName ? _frequentLabel : c.name,
                  onSelected: (c) => setState(() => _categoryName = c.name),
                  // "자주 쓰는" 탭은 순서에 넣지 않는다 — 늘 맨 앞이다.
                  onReorder: (newOrder) =>
                      widget.settings.setStickerCategoryOrder([
                        for (final c in newOrder)
                          if (c.name != _frequentName) c.name,
                      ]),
                ),
                const Divider(height: 1),
                Expanded(
                  child: GridView.builder(
                    key: ValueKey(category.name), // 탭을 바꾸면 맨 위부터
                    padding: const EdgeInsets.all(4),
                    // 고정 열 개수 대신 칸 최대 폭을 못박아서, 패널 너비와 무관하게 이모지(28)나
                    // 그림(64) 크기 대비 칸이 너무 넓어지지 않게 한다.
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: images ? 74 : 48,
                      mainAxisSpacing: 2,
                      crossAxisSpacing: 2,
                    ),
                    itemCount: category.stickers.length,
                    itemBuilder: (context, i) {
                      final sticker = category.stickers[i];
                      return Tooltip(
                        message: sticker.label,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () {
                            widget.settings.recordStickerUse(sticker.id);
                            widget.onSelected(sticker);
                          },
                          child: Center(
                            child: StickerView(
                              stickerId: sticker.id,
                              sticker: sticker,
                              emojiSize: 28,
                              imageSize: 64,
                              smooth: true,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
