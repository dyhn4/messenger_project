import 'package:flutter/material.dart';

import '../data/stickers.dart';
import 'sticker_view.dart';

/// 카테고리 탭 + 이모티콘 그리드. 채팅/댓글 화면에서 메시지 목록 위에 떠 있는 오버레이 카드로
/// 쓰인다(입력창을 밀어내지 않고 그 위에 겹쳐 보이는 카카오톡 방식) — 그래서 스스로 배경/그림자를
/// 가진 카드 모양이다. 하나를 탭하면 [onSelected]만 호출하고 스스로 닫히지 않는다 — 실제로
/// 보낼지/취소할지, 패널을 닫을지는 호출부(채팅/댓글 화면)가 정한다.
///
/// 탭은 서버에 올린 그림 이모티콘 세트(예: "리마인")가 먼저, 그 뒤에 기본 이모지 세트가 온다.
/// 그림 세트가 새로 올라오면(서버 목록을 다시 받으면) 스스로 탭을 다시 그린다.
class StickerPicker extends StatefulWidget {
  final void Function(Sticker sticker) onSelected;
  const StickerPicker({super.key, required this.onSelected});

  @override
  State<StickerPicker> createState() => _StickerPickerState();
}

class _StickerPickerState extends State<StickerPicker> {
  /// 탭은 이름으로 기억한다 — 서버 세트가 늘거나 줄어도 보던 탭이 그대로 남게.
  String? _categoryName;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: serverStickers,
      builder: (context, _) {
        final categories = [
          ...serverStickers.visibleCategories,
          ...stickerCategories,
        ];
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
                SizedBox(
                  // ChoiceChip 자체 높이(패딩 포함)보다 이 줄이 낮으면 칩이 눌려서 글자가
                  // 위로 밀려 보인다 — 칩이 눌리지 않을 만큼 넉넉하게 준다.
                  height: 32,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    itemCount: categories.length,
                    itemBuilder: (context, i) {
                      final c = categories[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ChoiceChip(
                          label: Text(c.name),
                          // 선택 시 체크마크가 붙으면 글자가 가운데서 옆으로 밀려 보이므로 끈다.
                          showCheckmark: false,
                          selected: identical(c, category),
                          visualDensity: VisualDensity.compact,
                          // 최소 터치 영역 확보용 여백이 위아래 비대칭으로 남는 걸 없애서
                          // 글자가 칩 세로 가운데에 오도록 한다.
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          onSelected: (_) =>
                              setState(() => _categoryName = c.name),
                        ),
                      );
                    },
                  ),
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
                          onTap: () => widget.onSelected(sticker),
                          child: Center(
                            child: StickerView(
                              stickerId: sticker.id,
                              sticker: sticker,
                              emojiSize: 28,
                              imageSize: 64,
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
