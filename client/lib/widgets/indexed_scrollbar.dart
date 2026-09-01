import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// ScrollablePositionedList 전용 스크롤바.
///
/// 왜 기본 Scrollbar를 못 쓰나: ScrollablePositionedList의 ScrollMetrics는
/// (1) 전체 콘텐츠 높이를 모르기 때문에 "지금 그려진 항목들의 평균 높이"로 maxScrollExtent를
/// **추정**하고, (2) pixels도 절대 위치가 아니라 현재 앵커 항목 기준 상대값이라 jumpTo마다
/// 리셋된다. 그래서 높이가 제각각인 목록에서는 스크롤할 때마다 추정치가 크게 흔들려 기본
/// 스크롤바 썸이 요동친다.
///
/// 그래서 여기서는 스크롤 위치를 직접 모델링한다:
/// - 화면에 그려진 항목의 실제 높이를 [itemKeyAt]이 돌려주는 **안정적인 키**(메시지 id 등)로
///   캐싱해둔다. 인덱스로 캐싱하면 새 메시지가 와서 인덱스가 전부 밀릴 때 캐시가 통째로
///   틀어지지만, id로 캐싱하면 그대로 유효하다.
/// - 아직 한 번도 안 그려진 항목은 이미 측정된 것들의 평균으로 근사한다. 스크롤해서 지나갈
///   때마다 실제 값으로 교체되므로 쓸수록 정확해진다.
/// - 이 높이들의 누적합으로 "콘텐츠 픽셀" 좌표계를 만들어서, 썸의 위치·크기와 드래그 목표
///   지점을 전부 그 좌표로 계산한다. 덕분에 키 큰 댓글 카드는 트랙에서도 그만큼 넓은 구간을
///   차지해서, 짧은 메시지와 같은 속도로 지나가지 않는다.
///
/// 특히 채팅방의 댓글 카드는 "연달아 달린 댓글 여러 개"를 카드 하나로 합쳐 그리기 때문에
/// (chat_panel.dart의 런 처리 참고) 항목 하나가 아주 크고 나머지는 높이 0이다 — 인덱스만으로
/// 계산하면 이 구간이 유독 휙 지나가는 이유가 이것이고, 높이 기반 모델은 이걸 정확히 반영한다.
///
/// [reverse]가 true인 목록(채팅방)에서는 인덱스 0이 화면 맨 **아래**(최신)다. 콘텐츠 좌표도
/// 맨 아래를 0으로 두고 위로 올라갈수록 커지게 잡는다.
class IndexedScrollbar extends StatefulWidget {
  final ItemPositionsListener positionsListener;
  final ItemScrollController scrollController;
  final int itemCount;

  /// [index] 항목을 가리키는, 목록이 바뀌어도 유지되는 키(메시지 id). 높이 캐시의 키로 쓴다.
  final Object? Function(int index) itemKeyAt;

  final Widget child;

  const IndexedScrollbar({
    super.key,
    required this.positionsListener,
    required this.scrollController,
    required this.itemCount,
    required this.itemKeyAt,
    required this.child,
  });

  @override
  State<IndexedScrollbar> createState() => _IndexedScrollbarState();
}

class _IndexedScrollbarState extends State<IndexedScrollbar> {
  static const _thickness = 10.0;
  static const _minThumbHeight = 32.0;
  static const _defaultItemHeight = 60.0;

  bool _hovered = false;
  bool _dragging = false;

  /// 드래그 중에는 내가 방금 요청한 위치를 그대로 그린다 — jumpTo 결과가 반영되기까지
  /// 한 프레임 정도 걸리는데, 그 사이 옛 위치로 되돌아 그리면 썸이 손가락을 못 따라온다.
  double? _dragThumbTop;

  /// 항목 키 → 실제로 측정된 높이(픽셀).
  final _heights = <Object, double>{};
  double _averageHeight = _defaultItemHeight;
  double _viewportHeight = 0;

  Iterable<ItemPosition> get _positions =>
      widget.positionsListener.itemPositions.value;

  @override
  void initState() {
    super.initState();
    // ValueListenableBuilder보다 먼저 등록해서, 썸을 그리기 전에 이번 프레임의 높이가
    // 캐시에 반영되도록 한다.
    widget.positionsListener.itemPositions.addListener(_recordHeights);
  }

  @override
  void dispose() {
    widget.positionsListener.itemPositions.removeListener(_recordHeights);
    super.dispose();
  }

  /// 지금 화면에 그려진 항목들의 실제 높이를 캐시에 기록한다. itemLeadingEdge/TrailingEdge는
  /// 뷰포트 밖까지 포함한 값이라, 일부만 보이는 항목도 전체 높이를 알 수 있다.
  void _recordHeights() {
    if (_viewportHeight <= 0) return;
    var changed = false;
    for (final p in _positions) {
      final key = widget.itemKeyAt(p.index);
      if (key == null) continue;
      final height = (p.itemTrailingEdge - p.itemLeadingEdge) * _viewportHeight;
      if (height < 0) continue;
      final previous = _heights[key];
      if (previous == null || (previous - height).abs() > 0.5) {
        _heights[key] = height;
        changed = true;
      }
    }
    if (changed) {
      // 높이 0인 항목(댓글 런에서 카드에 합쳐진 나머지들)은 평균을 왜곡시키므로 뺀다.
      var sum = 0.0;
      var count = 0;
      for (final h in _heights.values) {
        if (h <= 0) continue;
        sum += h;
        count++;
      }
      if (count > 0) _averageHeight = sum / count;
    }
  }

  double _heightAt(int index) {
    final key = widget.itemKeyAt(index);
    if (key == null) return _averageHeight;
    return _heights[key] ?? _averageHeight;
  }

  /// prefix[i] = 인덱스 0..i-1 항목들의 높이 합 = 항목 i보다 아래(더 최신)에 있는 콘텐츠 높이.
  List<double> _buildPrefix() {
    final n = widget.itemCount;
    final prefix = List<double>.filled(n + 1, 0);
    for (var i = 0; i < n; i++) {
      prefix[i + 1] = prefix[i] + _heightAt(i);
    }
    return prefix;
  }

  /// 지금 뷰포트 아래쪽 경계보다 아래(더 최신)에 있는 콘텐츠의 높이(픽셀).
  double? _contentOffset(List<double> prefix) {
    final positions = _positions;
    if (positions.isEmpty) return null;
    final bottom = positions.reduce((a, b) => a.index < b.index ? a : b);
    if (bottom.index < 0 || bottom.index >= prefix.length - 1) return null;
    // itemLeadingEdge가 음수면 그만큼 항목이 뷰포트 아래로 밀려나 있다는 뜻.
    return prefix[bottom.index] - bottom.itemLeadingEdge * _viewportHeight;
  }

  void _jumpToOffset(double offset, List<double> prefix) {
    if (!widget.scrollController.isAttached || _viewportHeight <= 0) return;
    // prefix[i] <= offset < prefix[i+1]인 i를 이진 탐색으로 찾는다.
    var low = 0;
    var high = widget.itemCount - 1;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (prefix[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    final within = offset - prefix[low];
    // alignment 0 = 그 항목의 leading edge를 뷰포트 leading edge(reverse라 화면 아래쪽)에
    // 붙인다. 음수를 주면 그만큼 항목 안쪽으로 더 지나간 상태가 된다.
    widget.scrollController.jumpTo(
      index: low,
      alignment: -(within / _viewportHeight),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        children: [
          // 기본으로 붙는 데스크톱 스크롤바는 위 주석의 이유로 신뢰할 수 없어서 끈다.
          ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: widget.child,
          ),
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: _thickness,
            child: LayoutBuilder(
              builder: (context, constraints) {
                _viewportHeight = constraints.maxHeight;
                // 썸만 다시 그린다 — 목록 자체를 다시 빌드하면(이 콜백이 목록의 레이아웃
                // 직후에 불리므로) 위젯 생명주기가 꼬여 assertion으로 죽는다.
                return ValueListenableBuilder<Iterable<ItemPosition>>(
                  valueListenable: widget.positionsListener.itemPositions,
                  builder: (context, _, _) {
                    final trackHeight = constraints.maxHeight;
                    if (widget.itemCount == 0 || trackHeight <= 0) {
                      return const SizedBox.shrink();
                    }
                    final prefix = _buildPrefix();
                    final total = prefix[widget.itemCount];
                    final offset = _contentOffset(prefix);
                    if (offset == null || total <= _viewportHeight) {
                      return const SizedBox.shrink(); // 다 보이면 스크롤바가 필요 없다.
                    }

                    final maxOffset = total - _viewportHeight;
                    final thumbHeight = (trackHeight * _viewportHeight / total)
                        .clamp(_minThumbHeight, trackHeight);
                    final travel = trackHeight - thumbHeight;
                    final thumbTop =
                        _dragThumbTop ??
                        ((1 - offset / maxOffset) * travel).clamp(0.0, travel);

                    void jumpToThumbTop(double top) {
                      if (travel <= 0) return;
                      final fraction = (top / travel).clamp(0.0, 1.0);
                      _jumpToOffset((1 - fraction) * maxOffset, prefix);
                    }

                    final active = _hovered || _dragging;
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragStart: (_) => setState(() {
                        _dragging = true;
                        _dragThumbTop = thumbTop;
                      }),
                      onVerticalDragUpdate: (details) {
                        final next =
                            ((_dragThumbTop ?? thumbTop) + details.delta.dy)
                                .clamp(0.0, travel);
                        setState(() => _dragThumbTop = next);
                        jumpToThumbTop(next);
                      },
                      onVerticalDragEnd: (_) => setState(() {
                        _dragging = false;
                        _dragThumbTop = null;
                      }),
                      onVerticalDragCancel: () => setState(() {
                        _dragging = false;
                        _dragThumbTop = null;
                      }),
                      // 트랙의 빈 곳을 누르면 그 위치로 바로 이동한다(기본 스크롤바와 동일).
                      onTapDown: (details) => jumpToThumbTop(
                        (details.localPosition.dy - thumbHeight / 2).clamp(
                          0.0,
                          travel,
                        ),
                      ),
                      child: Container(
                        color: Colors.grey.withValues(
                          alpha: active ? 0.45 : 0.28,
                        ),
                        child: Stack(
                          children: [
                            Positioned(
                              top: thumbTop,
                              left: 0,
                              right: 0,
                              height: thumbHeight,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.grey.withValues(
                                    alpha: active ? 0.75 : 0.6,
                                  ),
                                  borderRadius: BorderRadius.circular(
                                    _thickness / 2,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
