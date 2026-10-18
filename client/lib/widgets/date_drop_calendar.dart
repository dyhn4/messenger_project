import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../l10n/tr.dart';

final _weekdayHeaders = [
  tr('일'),
  tr('월'),
  tr('화'),
  tr('수'),
  tr('목'),
  tr('금'),
  tr('토'),
];

/// 달력 팝업의 폭 — 띄우는 쪽이 화면 밖으로 안 나가게 미리 계산할 때 쓴다.
const kDateDropCalendarWidth = 290.0;

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// 날짜 칸 아래로 떨어지는 작은 달력 — 표의 시작일/마감일을 그 자리에서 고칠 때 쓴다.
/// 앞뒤 달의 날짜는 연하게 같이 보여주고, 오늘은 굵게, 고른 날은 파란 동그라미로 표시한다.
/// 맨 아래 "오늘"을 누르면 오늘로 바로 정한다(날짜가 있으면 오른쪽에 "지우기"가 붙는다).
class DateDropCalendar extends StatefulWidget {
  final DateTime? value;

  /// 날짜를 고르면 그 날짜, "지우기"면 null.
  final ValueChanged<DateTime?> onPicked;
  final bool allowClear;

  const DateDropCalendar({
    super.key,
    required this.value,
    required this.onPicked,
    this.allowClear = true,
  });

  @override
  State<DateDropCalendar> createState() => _DateDropCalendarState();
}

class _DateDropCalendarState extends State<DateDropCalendar> {
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    final anchor = widget.value ?? DateTime.now();
    _month = DateTime(anchor.year, anchor.month, 1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final today = _dayOnly(DateTime.now());
    final selected = widget.value == null ? null : _dayOnly(widget.value!);

    // 달력 칸은 늘 6줄 42칸 — 앞뒤로 모자란 자리는 이웃 달 날짜로 연하게 채운다.
    final firstCell = DateTime(
      _month.year,
      _month.month,
      1 - (_month.weekday % 7),
    );
    final days = [
      for (var i = 0; i < 42; i++) firstCell.add(Duration(days: i)),
    ];

    Widget arrow(IconData icon, VoidCallback onTap) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, size: 18, color: hint),
      ),
    );

    return Container(
      width: kDateDropCalendarWidth,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              arrow(
                Icons.chevron_left,
                () => setState(
                  () => _month = DateTime(_month.year, _month.month - 1, 1),
                ),
              ),
              Expanded(
                child: Text(
                  tr('{_month.year}년 {_month.month}월', {
                    '_month.year': _month.year,
                    '_month.month': _month.month,
                  }),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              arrow(
                Icons.chevron_right,
                () => setState(
                  () => _month = DateTime(_month.year, _month.month + 1, 1),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              for (final label in _weekdayHeaders)
                Expanded(
                  child: Center(
                    child: Text(
                      label,
                      style: TextStyle(fontSize: 12, color: hint),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          for (var row = 0; row < 6; row++)
            Row(
              children: [
                for (var col = 0; col < 7; col++)
                  _DayCell(
                    date: days[row * 7 + col],
                    inMonth: days[row * 7 + col].month == _month.month,
                    isToday: days[row * 7 + col] == today,
                    isSelected: days[row * 7 + col] == selected,
                    onTap: () => widget.onPicked(days[row * 7 + col]),
                  ),
              ],
            ),
          const SizedBox(height: 2),
          Row(
            children: [
              if (widget.allowClear && widget.value != null)
                const SizedBox(width: 56),
              Expanded(
                child: Center(
                  child: TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                    ),
                    onPressed: () => widget.onPicked(today),
                    child: Text(tr('오늘')),
                  ),
                ),
              ),
              if (widget.allowClear && widget.value != null)
                SizedBox(
                  width: 56,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: hint,
                      visualDensity: VisualDensity.compact,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: () => widget.onPicked(null),
                    child: Text(tr('지우기'), style: TextStyle(fontSize: 12)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  final DateTime date;
  final bool inMonth;
  final bool isToday;
  final bool isSelected;
  final VoidCallback onTap;
  const _DayCell({
    required this.date,
    required this.inMonth,
    required this.isToday,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Center(
            child: Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: isSelected
                  ? BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.colorScheme.primary,
                    )
                  : null,
              child: Text(
                '${date.day}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected || isToday
                      ? FontWeight.w700
                      : FontWeight.normal,
                  color: isSelected
                      ? Colors.white
                      : inMonth
                      ? null
                      : theme.disabledColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 표의 날짜 칸 — 누르면 그 칸 바로 아래에 달력이 펼쳐진다. 모달 대화상자가 아니라서
/// 뒤가 어두워지지 않고, 바깥을 누르면 그냥 닫힌다.
class DateDropButton extends StatefulWidget {
  final DateTime? value;
  final ValueChanged<DateTime?> onPicked;
  final Widget child;

  /// 달력 아래 "지우기"를 둘지 — 날짜가 반드시 있어야 하는 칸(일정 시작·종료)은 끈다.
  final bool allowClear;
  const DateDropButton({
    super.key,
    required this.value,
    required this.onPicked,
    required this.child,
    this.allowClear = true,
  });

  @override
  State<DateDropButton> createState() => DateDropButtonState();
}

class DateDropButtonState extends State<DateDropButton> {
  final _overlay = OverlayPortalController();
  final _link = LayerLink();

  /// 달력과 그걸 여는 칸을 한 묶음으로 본다 — 안 그러면 열린 상태에서 그 칸을 다시 눌렀을 때
  /// "바깥을 눌렀다"로 먼저 닫히고, 이어서 탭이 다시 열어버려 토글이 안 된다.
  final _tapGroup = UniqueKey();

  /// 누른 지점의 x — 달력이 칸 가운데가 아니라 "누른 자리" 아래로 떨어지게 한다.
  /// 창 오른쪽 끝을 넘어가지 않도록 여기서 미리 안쪽으로 당겨둔다.
  double _dropDx = 0;

  /// 누른 자리에서 잰 가로 위치 — 손을 떼는 순간(onTap) 그 자리로 달력을 띄운다.
  double _pendingDx = 0;

  void _measure(TapDownDetails details) {
    const width = kDateDropCalendarWidth;
    const margin = 8.0;
    final screenW = MediaQuery.of(context).size.width;
    final wantLeft = details.globalPosition.dx;
    final maxLeft = math.max(margin, screenW - width - margin);
    final left = wantLeft.clamp(margin, maxLeft);
    _pendingDx = details.localPosition.dx + (left - wantLeft);
  }

  void _toggle() {
    // isShowing을 **누를 때가 아니라 뗄 때** 본다. 예전에는 onTapDown에서 setState로 열고
    // 그 사이 다시 그려진 onTap이 "닫기"로 바뀌어, 손을 떼는 순간 방금 연 달력이 도로
    // 닫혔다(한 번 깜빡이고 사라지는 증상).
    if (_overlay.isShowing) {
      _overlay.hide();
      return;
    }
    setState(() => _dropDx = _pendingDx);
    _overlay.show();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return OverlayPortal(
      controller: _overlay,
      overlayChildBuilder: (context) => CompositedTransformFollower(
        link: _link,
        targetAnchor: Alignment.bottomLeft,
        followerAnchor: Alignment.topLeft,
        offset: Offset(_dropDx, 6),
        child: Align(
          alignment: Alignment.topLeft,
          child: TapRegion(
            groupId: _tapGroup,
            onTapOutside: (_) => _overlay.hide(),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              color: theme.colorScheme.surface,
              child: DateDropCalendar(
                value: widget.value,
                allowClear: widget.allowClear,
                onPicked: (picked) {
                  _overlay.hide();
                  widget.onPicked(picked);
                },
              ),
            ),
          ),
        ),
      ),
      child: CompositedTransformTarget(
        link: _link,
        child: TapRegion(
          groupId: _tapGroup,
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            // 누른 자리 아래에 띄우려면 탭 위치가 필요해서 onTapDown으로 재두기만 하고,
            // 실제로 열고 닫는 건 onTap에서 한다(위 _toggle 주석 참고).
            onTapDown: _measure,
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
