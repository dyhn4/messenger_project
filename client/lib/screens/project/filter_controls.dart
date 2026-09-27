import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../widgets/muted_scrollbar.dart';

/// 필터 패널과 그 안의 작은 팝업들(드롭다운 목록·달력·"필터 추가" 메뉴)이 쓰는 부품.
///
/// MenuAnchor 대신 OverlayPortal로 띄운다 — 안쪽 팝업을 누를 때 바깥 패널이 "바깥을 눌렀다"며
/// 닫히지 않도록, 안쪽 팝업은 자기를 연 모든 바깥 팝업의 TapRegion 묶음에도 같이 들어간다.

/// 필터 팝업 안에서 선택된 글자·테두리 색.
const filterAccent = Color(0xFF3B82F6);

/// 지금 위치를 감싸고 있는 팝업들의 TapRegion 묶음 id(바깥 → 안쪽).
class _PopupGroups extends InheritedWidget {
  final List<Object> groups;
  const _PopupGroups({required this.groups, required super.child});

  static List<Object> of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PopupGroups>()?.groups ??
      const [];

  @override
  bool updateShouldNotify(_PopupGroups old) => old.groups != groups;
}

/// 누르는 것([anchorBuilder]) 바로 아래에 [popupBuilder]를 띄운다. 바깥을 누르거나 Esc로 닫는다.
class FilterPopup extends StatefulWidget {
  final Widget Function(BuildContext context, bool open, VoidCallback toggle)
  anchorBuilder;
  final Widget Function(BuildContext context, VoidCallback close) popupBuilder;

  /// 팝업을 누르는 것의 오른쪽 끝에 맞출지(false면 왼쪽 끝).
  final bool alignRight;

  /// 팝업 폭을 누르는 것의 폭과 같게.
  final bool matchWidth;
  final double gap;

  const FilterPopup({
    super.key,
    required this.anchorBuilder,
    required this.popupBuilder,
    this.alignRight = false,
    this.matchWidth = false,
    this.gap = 4,
  });

  @override
  State<FilterPopup> createState() => _FilterPopupState();
}

class _FilterPopupState extends State<FilterPopup> {
  final _overlay = OverlayPortalController();
  final _group = Object();
  final _focus = FocusNode(debugLabel: 'filter-popup');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_overlay.isShowing) {
      _close();
    } else {
      _overlay.show();
      setState(() {});
    }
  }

  void _close() {
    if (!_overlay.isShowing) return;
    _overlay.hide();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final outer = _PopupGroups.of(context);
    final right = widget.alignRight;
    // CompositedTransformFollower 대신 overlayChildLayoutBuilder로 자리를 잡는다 — 팔로워 안에서는
    // 툴팁(달력 ↑/↓ 등)이 위치를 계산하지 못해 오류가 나고, 화면 밖으로 나가는 것도 막을 수 없다.
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _overlay,
      overlayChildBuilder: (_, info) {
        Widget popup = TapRegion(
          groupId: _group,
          onTapOutside: (_) => _close(),
          child: Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: (_, e) {
              if (e is KeyDownEvent &&
                  e.logicalKey == LogicalKeyboardKey.escape) {
                _close();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: _PopupGroups(
              groups: [...outer, _group],
              child: Builder(
                builder: (context) => widget.popupBuilder(context, _close),
              ),
            ),
          ),
        );
        // 바깥 팝업들의 묶음에도 넣어, 여기를 눌러도 바깥 팝업이 닫히지 않게 한다.
        for (final g in outer.reversed) {
          popup = TapRegion(groupId: g, child: popup);
        }
        final anchor = MatrixUtils.transformRect(
          info.childPaintTransform,
          Offset.zero & info.childSize,
        );
        if (widget.matchWidth) {
          popup = SizedBox(width: anchor.width, child: popup);
        }
        return CustomSingleChildLayout(
          delegate: _PopupLayout(
            anchor: anchor,
            alignRight: right,
            gap: widget.gap,
          ),
          child: popup,
        );
      },
      child: TapRegion(
        groupId: _group,
        child: widget.anchorBuilder(context, _overlay.isShowing, _toggle),
      ),
    );
  }
}

/// 팝업 자리 — 누르는 것 바로 아래(왼쪽 또는 오른쪽 끝 맞춤). 창 밖으로 나가면 안쪽으로 밀고,
/// 아래 공간이 모자라면 위로 띄운다(창 가장자리에서 [_margin]만큼 띄운다).
class _PopupLayout extends SingleChildLayoutDelegate {
  final Rect anchor;
  final bool alignRight;
  final double gap;
  const _PopupLayout({
    required this.anchor,
    required this.alignRight,
    required this.gap,
  });

  static const _margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(
        Size(
          (constraints.maxWidth - _margin * 2).clamp(0, double.infinity),
          (constraints.maxHeight - _margin * 2).clamp(0, double.infinity),
        ),
      );

  @override
  Offset getPositionForChild(Size size, Size child) {
    var x = alignRight ? anchor.right - child.width : anchor.left;
    x = x.clamp(
      _margin,
      (size.width - child.width - _margin).clamp(_margin, double.infinity),
    );
    var y = anchor.bottom + gap;
    if (y + child.height > size.height - _margin) {
      final above = anchor.top - gap - child.height;
      y = above >= _margin
          ? above
          : (size.height - child.height - _margin).clamp(
              _margin,
              double.infinity,
            );
    }
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_PopupLayout old) =>
      old.anchor != anchor || old.alignRight != alignRight || old.gap != gap;
}

/// 팝업 바탕 — 흰 카드, 둥근 모서리, 그림자.
class FilterPopupCard extends StatelessWidget {
  final Widget child;
  final double? width;
  final EdgeInsetsGeometry padding;
  const FilterPopupCard({
    super.key,
    required this.child,
    this.width,
    this.padding = const EdgeInsets.symmetric(vertical: 6),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// 필터 칸 바탕 — 옅은 회색 채움, 열려 있으면 파란 테두리.
BoxDecoration _fieldDecoration(BuildContext context, {required bool open}) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  return BoxDecoration(
    color: dark
        ? theme.colorScheme.surfaceContainerHighest
        : const Color(0xFFF1F3F6),
    borderRadius: BorderRadius.circular(8),
    border: Border.all(
      color: open
          ? filterAccent
          : (dark ? theme.dividerColor : const Color(0xFFD6DAE1)),
    ),
  );
}

/// "전체"가 기본인 한 개짜리 고르기 — 칸 아래로 목록이 펼쳐지고, 고른 항목은 파란 글자와 ✓.
class FilterDropdown<T> extends StatelessWidget {
  final T? value;
  final List<({T value, String label})> options;
  final ValueChanged<T?> onChanged;

  /// 아무것도 안 골랐을 때(null) 항목 이름.
  final String allLabel;

  const FilterDropdown({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.allLabel = '전체',
  });

  @override
  Widget build(BuildContext context) {
    final current = options.where((o) => o.value == value).firstOrNull;
    final hint = Theme.of(context).hintColor;
    return FilterPopup(
      matchWidth: true,
      anchorBuilder: (context, open, toggle) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: toggle,
          child: Container(
            height: 36,
            padding: const EdgeInsets.only(left: 12, right: 8),
            decoration: _fieldDecoration(context, open: open),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    current?.label ?? allLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                Icon(
                  open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  size: 18,
                  color: hint,
                ),
              ],
            ),
          ),
        ),
      ),
      popupBuilder: (context, close) {
        Widget item(T? v, String label) {
          final selected = v == value || (v == null && current == null);
          return _MenuRow(
            label: label,
            selected: selected,
            onTap: () {
              close();
              if (!selected) onChanged(v);
            },
          );
        }

        return FilterPopupCard(
          child: _ScrollingColumn(
            maxHeight: 280,
            children: [
              item(null, allLabel),
              for (final o in options) item(o.value, o.label),
            ],
          ),
        );
      },
    );
  }
}

/// 팝업 목록 한 줄 — 마우스를 올리면 옅게 칠하고, 고른 항목은 파란 글자에 ✓.
class _MenuRow extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final EdgeInsetsGeometry padding;
  const _MenuRow({
    required this.label,
    required this.onTap,
    this.selected = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 38,
        padding: padding,
        alignment: Alignment.centerLeft,
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: selected ? filterAccent : null,
                  fontWeight: selected ? FontWeight.w700 : null,
                ),
              ),
            ),
            if (selected)
              const Icon(Icons.check, size: 16, color: filterAccent),
          ],
        ),
      ),
    );
  }
}

/// 항목이 많으면 [maxHeight]까지 늘고 그 안에서 스크롤하는 목록.
class _ScrollingColumn extends StatefulWidget {
  final double maxHeight;
  final List<Widget> children;
  const _ScrollingColumn({required this.maxHeight, required this.children});

  @override
  State<_ScrollingColumn> createState() => _ScrollingColumnState();
}

class _ScrollingColumnState extends State<_ScrollingColumn> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: MutedScrollbar(
        controller: _scroll,
        child: ListView(
          controller: _scroll,
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: widget.children,
        ),
      ),
    );
  }
}

/// 날짜 하나 고르기 — "연도-월-일" 칸, 누르면 아래에 달력이 뜬다.
class FilterDateField extends StatelessWidget {
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  const FilterDateField({
    super.key,
    required this.value,
    required this.onChanged,
  });

  static String format(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FilterPopup(
      anchorBuilder: (context, open, toggle) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: toggle,
          child: Container(
            height: 36,
            padding: const EdgeInsets.only(left: 12, right: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: open
                    ? filterAccent
                    : (theme.brightness == Brightness.dark
                          ? theme.dividerColor
                          : const Color(0xFFD6DAE1)),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value == null ? '연도-월-일' : format(value!),
                    style: TextStyle(
                      fontSize: 13,
                      color: value == null ? theme.hintColor : null,
                    ),
                  ),
                ),
                const Icon(Icons.calendar_today_outlined, size: 16),
              ],
            ),
          ),
        ),
      ),
      popupBuilder: (context, close) => FilterPopupCard(
        width: 268,
        padding: EdgeInsets.zero,
        child: FilterCalendar(
          value: value,
          onPicked: (d) {
            close();
            onChanged(d);
          },
        ),
      ),
    );
  }
}

/// 날짜 칸 아래 달력 — 머리 "2026년 07월 ▾"(누르면 달 고르기)와 ↑/↓(이전·다음 달), 일요일부터
/// 6주, 아래 "삭제"(지우기)·"오늘". 고른 날은 파란 칸, 앞뒤 달의 날은 흐리게.
class FilterCalendar extends StatefulWidget {
  final DateTime? value;

  /// 날을 고르면 그 날, "삭제"면 null.
  final ValueChanged<DateTime?> onPicked;
  const FilterCalendar({
    super.key,
    required this.value,
    required this.onPicked,
  });

  @override
  State<FilterCalendar> createState() => _FilterCalendarState();
}

class _FilterCalendarState extends State<FilterCalendar> {
  static const _blue = Color(0xFF1A73E8);
  static const _weekdays = ['일', '월', '화', '수', '목', '금', '토'];

  late DateTime _month = _firstOf(widget.value ?? DateTime.now());

  /// true면 날짜 대신 열두 달을 보여준다(머리 ▾를 눌렀을 때).
  bool _pickMonth = false;

  static DateTime _firstOf(DateTime d) => DateTime(d.year, d.month);
  static bool _same(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// ↑/↓ — 날짜 화면에서는 한 달씩, 달 고르기 화면에서는 한 해씩.
  void _shift(int delta) => setState(
    () => _month = _pickMonth
        ? DateTime(_month.year + delta, _month.month)
        : DateTime(_month.year, _month.month + delta),
  );

  Widget _header() {
    final label = _pickMonth
        ? '${_month.year}년'
        : '${_month.year}년 ${_month.month.toString().padLeft(2, '0')}월';
    Widget arrow(IconData icon, String tip, int delta) => IconButton(
      tooltip: tip,
      onPressed: () => _shift(delta),
      icon: Icon(icon, size: 18),
      visualDensity: VisualDensity.compact,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 2),
      child: Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => setState(() => _pickMonth = !_pickMonth),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Icon(
                    _pickMonth ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          arrow(Icons.arrow_upward, _pickMonth ? '이전 해' : '이전 달', -1),
          arrow(Icons.arrow_downward, _pickMonth ? '다음 해' : '다음 달', 1),
        ],
      ),
    );
  }

  Widget _dayGrid(ThemeData theme) {
    final today = DateTime.now();
    final value = widget.value;
    // 그 달 1일이 있는 주의 일요일부터 6주.
    final start = DateTime(_month.year, _month.month, 1 - _month.weekday % 7);
    final muted = theme.hintColor.withValues(alpha: 0.6);
    Widget cell(DateTime d) {
      final inMonth = d.month == _month.month;
      final selected = value != null && _same(d, value);
      final isToday = _same(d, today);
      return SizedBox(
        width: 34,
        height: 30,
        child: InkWell(
          borderRadius: BorderRadius.circular(3),
          onTap: () => widget.onPicked(d),
          child: Container(
            alignment: Alignment.center,
            decoration: selected
                ? BoxDecoration(
                    color: _blue,
                    borderRadius: BorderRadius.circular(3),
                  )
                : null,
            child: Text(
              '${d.day}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected || isToday ? FontWeight.w700 : null,
                color: selected
                    ? Colors.white
                    : isToday
                    ? _blue
                    : (inMonth ? null : muted),
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final w in _weekdays)
              SizedBox(
                width: 34,
                height: 28,
                child: Center(
                  child: Text(w, style: const TextStyle(fontSize: 13)),
                ),
              ),
          ],
        ),
        for (var week = 0; week < 6; week++)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 7; i++)
                cell(
                  DateTime(start.year, start.month, start.day + week * 7 + i),
                ),
            ],
          ),
      ],
    );
  }

  Widget _monthGrid() {
    final value = widget.value;
    bool isValue(int m) =>
        value != null && value.year == _month.year && value.month == m;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var row = 0; row < 3; row++)
            Row(
              children: [
                for (var col = 0; col < 4; col++)
                  Expanded(
                    child: SizedBox(
                      height: 56,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => setState(() {
                          _month = DateTime(_month.year, row * 4 + col + 1);
                          _pickMonth = false;
                        }),
                        child: Container(
                          alignment: Alignment.center,
                          margin: const EdgeInsets.all(4),
                          decoration: isValue(row * 4 + col + 1)
                              ? BoxDecoration(
                                  color: _blue,
                                  borderRadius: BorderRadius.circular(4),
                                )
                              : null,
                          child: Text(
                            '${row * 4 + col + 1}월',
                            style: TextStyle(
                              fontSize: 13,
                              color: isValue(row * 4 + col + 1)
                                  ? Colors.white
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget footer(String label, VoidCallback onTap) => TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: _blue,
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 13),
      ),
      child: Text(label),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        _pickMonth ? _monthGrid() : _dayGrid(theme),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
          child: Row(
            children: [
              footer('삭제', () => widget.onPicked(null)),
              const Spacer(),
              footer('오늘', () {
                final now = DateTime.now();
                widget.onPicked(DateTime(now.year, now.month, now.day));
              }),
            ],
          ),
        ),
      ],
    );
  }
}

/// "+ 필터 추가 ▾" — 누르면 아직 안 꺼낸 필터 이름들이 아래로 펼쳐진다.
class FilterAddButton extends StatelessWidget {
  final List<({String id, String label})> options;
  final ValueChanged<String> onSelected;
  const FilterAddButton({
    super.key,
    required this.options,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurface.withValues(alpha: 0.75);
    return Align(
      alignment: Alignment.centerLeft,
      child: FilterPopup(
        anchorBuilder: (context, open, toggle) => TextButton(
          onPressed: toggle,
          style: TextButton.styleFrom(
            foregroundColor: color,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.add, size: 16),
              const SizedBox(width: 4),
              const Text('필터 추가', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 2),
              Icon(Icons.arrow_drop_down, size: 18, color: color),
            ],
          ),
        ),
        popupBuilder: (context, close) => FilterPopupCard(
          width: 220,
          child: options.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Text(
                    '추가할 필터가 없습니다',
                    style: TextStyle(fontSize: 13, color: theme.hintColor),
                  ),
                )
              : _ScrollingColumn(
                  maxHeight: 280,
                  children: [
                    for (final o in options)
                      _MenuRow(
                        label: o.label,
                        padding: const EdgeInsets.symmetric(horizontal: 36),
                        onTap: () {
                          close();
                          onSelected(o.id);
                        },
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// "빠른 필터링" 알약 — 테두리만 있고, 고르면 파란 테두리·글자.
class FilterQuickChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const FilterQuickChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? filterAccent.withValues(alpha: 0.08)
          : Colors.transparent,
      shape: StadiumBorder(
        side: BorderSide(
          color: selected
              ? filterAccent
              : (theme.brightness == Brightness.dark
                    ? theme.dividerColor
                    : const Color(0xFFC9CDD4)),
        ),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: selected ? filterAccent : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// 필터 한 줄 — 왼쪽 이름, 가운데 입력, (있으면) 오른쪽 × 로 이 필터를 뺀다.
class FilterRow extends StatelessWidget {
  final String label;
  final Widget child;
  final VoidCallback? onRemove;
  const FilterRow({
    super.key,
    required this.label,
    required this.child,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14),
            ),
          ),
          Expanded(child: child),
          if (onRemove != null)
            SizedBox(
              width: 28,
              child: IconButton(
                tooltip: '필터 빼기',
                onPressed: onRemove,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                icon: Icon(Icons.close, color: Theme.of(context).hintColor),
              ),
            ),
        ],
      ),
    );
  }
}

/// 필터 패널 본문의 틀 — "필터링" 제목(+ 지우기), 빠른 필터링 알약들, 구분선, 나머지 [children].
class FilterPanel extends StatefulWidget {
  final List<Widget> quickChips;
  final List<Widget> children;

  /// null이면 "지우기"를 숨긴다.
  final VoidCallback? onClear;
  final double width;

  const FilterPanel({
    super.key,
    required this.quickChips,
    required this.children,
    this.onClear,
    this.width = 340,
  });

  @override
  State<FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends State<FilterPanel> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FilterPopupCard(
      width: widget.width,
      padding: EdgeInsets.zero,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 520),
        child: MutedScrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 30,
                  child: Row(
                    children: [
                      const Text(
                        '필터링',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      if (widget.onClear != null)
                        TextButton(
                          onPressed: widget.onClear,
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            textStyle: const TextStyle(fontSize: 12),
                          ),
                          child: const Text('지우기'),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '빠른 필터링',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Wrap(spacing: 4, runSpacing: 6, children: widget.quickChips),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Divider(height: 1),
                ),
                ...widget.children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 목록 위 "필터링" 버튼 — 누르면 버튼 오른쪽 끝에 맞춰 [panelBuilder]가 아래로 펼쳐진다.
class FilterPanelButton extends StatelessWidget {
  final String label;
  final WidgetBuilder panelBuilder;
  const FilterPanelButton({
    super.key,
    required this.label,
    required this.panelBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return FilterPopup(
      alignRight: true,
      gap: 6,
      anchorBuilder: (context, open, toggle) => TextButton.icon(
        onPressed: toggle,
        icon: const Icon(Icons.filter_alt_outlined, size: 18),
        label: Text(label),
      ),
      popupBuilder: (context, close) => panelBuilder(context),
    );
  }
}
