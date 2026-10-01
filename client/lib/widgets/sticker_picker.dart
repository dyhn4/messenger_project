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
///
/// 세트가 많아 세트 이름 줄이 한 화면에 안 들어가면 그 줄 양끝에 **이전/다음 페이지 단추**(‹ ›)가 나타나서,
/// 누를 때마다 한 화면(보이는 폭)씩 넘긴다 — 마우스 휠로는 가로 스크롤이 잘 안 돼서 PC에서 뒤쪽 세트에 닿기
/// 어려웠다. 끝에 닿으면 그쪽 단추는 꺼진다.
class StickerPicker extends StatefulWidget {
  final void Function(Sticker sticker) onSelected;
  const StickerPicker({super.key, required this.onSelected});

  @override
  State<StickerPicker> createState() => _StickerPickerState();
}

class _StickerPickerState extends State<StickerPicker> {
  /// 탭은 이름으로 기억한다 — 서버 세트가 늘거나 줄어도 보던 탭이 그대로 남게.
  String? _categoryName;

  /// 세트 이름 줄의 가로 스크롤 — 페이지 단추가 이걸 한 화면씩 움직인다.
  final _tabScroll = ScrollController();

  /// 세트 이름 줄이 한 화면을 넘는지(페이지 단추를 보일지), 맨 앞/맨 뒤인지(그쪽 단추를 끌지).
  bool _tabsOverflow = false;
  bool _tabsAtStart = true;
  bool _tabsAtEnd = true;

  @override
  void dispose() {
    _tabScroll.dispose();
    super.dispose();
  }

  /// 스크롤 위치·크기가 바뀔 때마다 단추 상태를 다시 계산한다(바뀐 게 있을 때만 다시 그린다).
  bool _onTabMetrics(ScrollMetrics m) {
    final overflow = m.maxScrollExtent > 0.5;
    final atStart = m.pixels <= m.minScrollExtent + 0.5;
    final atEnd = m.pixels >= m.maxScrollExtent - 0.5;
    if (overflow != _tabsOverflow ||
        atStart != _tabsAtStart ||
        atEnd != _tabsAtEnd) {
      setState(() {
        _tabsOverflow = overflow;
        _tabsAtStart = atStart;
        _tabsAtEnd = atEnd;
      });
    }
    return false;
  }

  /// 세트 이름 줄을 한 화면(보이는 폭의 90% — 걸친 칩이 다음 화면 첫머리에 보이게 조금 겹친다)만큼 넘긴다.
  void _pageTabs(int direction) {
    if (!_tabScroll.hasClients) return;
    final pos = _tabScroll.position;
    final target = (pos.pixels + direction * pos.viewportDimension * 0.9).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    _tabScroll.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  Widget _pageButton({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      width: 28,
      child: IconButton(
        key: key,
        padding: EdgeInsets.zero,
        iconSize: 20,
        visualDensity: VisualDensity.compact,
        tooltip: tooltip,
        icon: Icon(icon),
        onPressed: onPressed,
      ),
    );
  }

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
                  child: Row(
                    children: [
                      if (_tabsOverflow)
                        _pageButton(
                          key: const ValueKey('sticker-tabs-prev'),
                          icon: Icons.chevron_left,
                          tooltip: '이전 세트',
                          onPressed: _tabsAtStart ? null : () => _pageTabs(-1),
                        ),
                      Expanded(
                        // ScrollMetricsNotification은 크기가 바뀔 때(첫 배치·세트 목록 변경), ScrollNotification은
                        // 스크롤 위치가 바뀔 때 온다 — 둘 다 단추 상태를 다시 계산한다.
                        child: NotificationListener<ScrollMetricsNotification>(
                          onNotification: (n) => _onTabMetrics(n.metrics),
                          child: NotificationListener<ScrollNotification>(
                            onNotification: (n) => _onTabMetrics(n.metrics),
                            child: ListView.builder(
                              controller: _tabScroll,
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              itemCount: categories.length,
                              itemBuilder: (context, i) {
                                final c = categories[i];
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
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
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                    ),
                                    onSelected: (_) =>
                                        setState(() => _categoryName = c.name),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      if (_tabsOverflow)
                        _pageButton(
                          key: const ValueKey('sticker-tabs-next'),
                          icon: Icons.chevron_right,
                          tooltip: '다음 세트',
                          onPressed: _tabsAtEnd ? null : () => _pageTabs(1),
                        ),
                    ],
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
