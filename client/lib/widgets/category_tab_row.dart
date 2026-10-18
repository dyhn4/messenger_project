import 'package:flutter/material.dart';
import '../l10n/tr.dart';

/// 세트/카테고리 이름을 ChoiceChip으로 가로로 나열하는 줄 — 채팅 입력창 이모티콘 목록
/// (sticker_picker.dart)과 프로필 카드 "캐릭터 선택하기"(my_profile_dialog.dart)가 같이 쓴다.
///
/// 줄이 한 화면에 안 들어가면 양 끝에 이전/다음 페이지 단추(‹ ›)가 나타나서, 누를 때마다
/// 한 화면(보이는 폭)씩 넘긴다(마우스 휠로는 가로 스크롤이 잘 안 돼서 PC에서 뒤쪽 세트에
/// 닿기 어려웠다). 끝에 닿으면 그쪽 단추는 꺼진다.
///
/// [onReorder]를 주면(채팅 입력창 쪽만) 칩을 꾹 눌러서 끌면 순서를 바꿀 수 있다(드래그).
/// 빠른 탭은 그대로 [onSelected]로 고르는 동작이라 서로 안 부딪힌다.
class CategoryTabRow<T> extends StatefulWidget {
  final List<T> items;
  final T selected;
  final String Function(T item) labelOf;
  final void Function(T item) onSelected;
  final void Function(List<T> newOrder)? onReorder;

  const CategoryTabRow({
    super.key,
    required this.items,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
    this.onReorder,
  });

  @override
  State<CategoryTabRow<T>> createState() => _CategoryTabRowState<T>();
}

class _CategoryTabRowState<T> extends State<CategoryTabRow<T>> {
  final _scroll = ScrollController();
  bool _overflow = false;
  bool _atStart = true;
  bool _atEnd = true;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 스크롤 위치·크기가 바뀔 때마다 단추 상태를 다시 계산한다(바뀐 게 있을 때만 다시 그린다).
  bool _onMetrics(ScrollMetrics m) {
    final overflow = m.maxScrollExtent > 0.5;
    final atStart = m.pixels <= m.minScrollExtent + 0.5;
    final atEnd = m.pixels >= m.maxScrollExtent - 0.5;
    if (overflow != _overflow || atStart != _atStart || atEnd != _atEnd) {
      setState(() {
        _overflow = overflow;
        _atStart = atStart;
        _atEnd = atEnd;
      });
    }
    return false;
  }

  /// 한 화면(보이는 폭의 90% — 걸친 칩이 다음 화면 첫머리에 보이게 조금 겹친다)만큼 넘긴다.
  void _page(int direction) {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final target = (pos.pixels + direction * pos.viewportDimension * 0.9).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    _scroll.animateTo(
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

  Widget _chip(T item) {
    final selected = widget.labelOf(item) == widget.labelOf(widget.selected);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        label: Text(widget.labelOf(item)),
        // 선택 시 체크마크가 붙으면 글자가 가운데서 옆으로 밀려 보이므로 끈다.
        showCheckmark: false,
        selected: selected,
        visualDensity: VisualDensity.compact,
        // 최소 터치 영역 확보용 여백이 위아래 비대칭으로 남는 걸 없애서 글자가 칩 세로
        // 가운데에 오도록 한다.
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        onSelected: (_) => widget.onSelected(item),
      ),
    );
  }

  Widget _list() {
    final onReorder = widget.onReorder;
    final padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 2);
    if (onReorder == null) {
      return ListView.builder(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: widget.items.length,
        itemBuilder: (context, i) => _chip(widget.items[i]),
      );
    }
    // 꾹 눌러서 끄는 동안만 드래그로 바뀐다(ReorderableDelayedDragStartListener) — 짧게
    // 탭하는 동작(onSelected로 고르기)과 안 부딪힌다. 기본 드래그 손잡이(한쪽에 ≡ 아이콘)는
    // 칩 모양을 깨서 끄고, 칩 전체를 그 리스너로 감싼다.
    return ReorderableListView.builder(
      scrollController: _scroll,
      scrollDirection: Axis.horizontal,
      padding: padding,
      buildDefaultDragHandles: false,
      itemCount: widget.items.length,
      itemBuilder: (context, i) {
        final item = widget.items[i];
        return ReorderableDelayedDragStartListener(
          key: ValueKey(widget.labelOf(item)),
          index: i,
          child: _chip(item),
        );
      },
      onReorderItem: (oldIndex, newIndex) {
        final list = [...widget.items];
        final moved = list.removeAt(oldIndex);
        list.insert(newIndex, moved);
        onReorder(list);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // ChoiceChip 자체 높이(패딩 포함)보다 이 줄이 낮으면 칩이 눌려서 글자가 위로 밀려
      // 보인다 — 칩이 눌리지 않을 만큼 넉넉하게 준다.
      height: 32,
      child: Row(
        children: [
          if (_overflow)
            _pageButton(
              key: const ValueKey('category-tabs-prev'),
              icon: Icons.chevron_left,
              tooltip: tr('이전'),
              onPressed: _atStart ? null : () => _page(-1),
            ),
          Expanded(
            // ScrollMetricsNotification은 크기가 바뀔 때(첫 배치·목록 변경), ScrollNotification은
            // 스크롤 위치가 바뀔 때 온다 — 둘 다 단추 상태를 다시 계산한다.
            child: NotificationListener<ScrollMetricsNotification>(
              onNotification: (n) => _onMetrics(n.metrics),
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) => _onMetrics(n.metrics),
                child: _list(),
              ),
            ),
          ),
          if (_overflow)
            _pageButton(
              key: const ValueKey('category-tabs-next'),
              icon: Icons.chevron_right,
              tooltip: tr('다음'),
              onPressed: _atEnd ? null : () => _page(1),
            ),
        ],
      ),
    );
  }
}
