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

/// 기간(시작일~종료일) 선택용 달력 — date_picker_popup.dart의 "선택 날짜로 이동" 달력과 같은
/// 모양(월 이동 화살표, "오늘" 버튼, 일/토 빨강·파랑 표시, 검은 원 선택 표시)이지만, 팝업으로
/// 따로 안 띄우고 대화상자 안에 그대로 얹어 쓰는 용도라 elevation/닫기 버튼 없이 달력 내용만
/// 그린다. 하루만 고르는 그 위젯과 달리 두 번 탭해서 기간을 고른다 — 첫 탭이 시작일,
/// 그다음 탭이 종료일(시작일보다 빠르면 그 날짜로 시작일을 다시 잡은 걸로 본다).
class DateRangeCalendarPanel extends StatefulWidget {
  final DateTime? start;
  final DateTime? end;
  final DateTime? lastDate;
  final void Function(DateTime? start, DateTime? end) onChanged;

  /// true면 기간이 아니라 하루만 고른다 — 누를 때마다 그 날짜가 [start]로 넘어간다
  /// (표의 시작일/마감일 칸처럼 날짜 하나만 바꾸는 자리에서 쓴다).
  final bool singlePick;

  const DateRangeCalendarPanel({
    super.key,
    required this.start,
    required this.end,
    required this.onChanged,
    this.lastDate,
    this.singlePick = false,
  });

  @override
  State<DateRangeCalendarPanel> createState() => _DateRangeCalendarPanelState();
}

class _DateRangeCalendarPanelState extends State<DateRangeCalendarPanel> {
  late DateTime _month;

  /// 시/분을 뗀 오늘 — 달력 칸과 비교하려면 날짜만 있어야 한다.
  DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void initState() {
    super.initState();
    final anchor = widget.start ?? DateTime.now();
    _month = DateTime(anchor.year, anchor.month, 1);
  }

  void _prevMonth() =>
      setState(() => _month = DateTime(_month.year, _month.month - 1, 1));

  void _nextMonth() =>
      setState(() => _month = DateTime(_month.year, _month.month + 1, 1));

  /// "오늘" 버튼 — 오늘이 있는 달로 옮기고, 오늘을 실제로 고른다(그 날을 직접 누른 것과 같다).
  /// 그래서 시작일이 비어 있으면 시작일이, 시작일만 정해져 있으면 마감일이 된다.
  void _goToday() {
    final today = _today;
    setState(() => _month = DateTime(today.year, today.month, 1));
    if (widget.lastDate != null && today.isAfter(widget.lastDate!)) return;
    _tapDate(today);
  }

  void _tapDate(DateTime date) {
    if (widget.singlePick) {
      widget.onChanged(date, null);
      return;
    }
    final start = widget.start;
    final end = widget.end;
    if (start == null || end != null) {
      // 처음 고르거나, 이미 기간이 다 정해진 뒤 다시 누르면 새로 시작한다.
      widget.onChanged(date, null);
    } else if (date.isBefore(start)) {
      widget.onChanged(date, null);
    } else {
      widget.onChanged(start, date);
    }
  }

  @override
  Widget build(BuildContext context) {
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final leadingBlanks =
        _month.weekday % 7; // Dart weekday: 월=1..일=7 → 일요일 시작 기준.
    final hintColor = Theme.of(context).hintColor;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            InkWell(
              onTap: _prevMonth,
              borderRadius: BorderRadius.circular(16),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.chevron_left, size: 20),
              ),
            ),
            Text(
              '${_month.year}/${_month.month.toString().padLeft(2, '0')}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            InkWell(
              onTap: _nextMonth,
              borderRadius: BorderRadius.circular(16),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.chevron_right, size: 20),
              ),
            ),
            const Spacer(),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _goToday,
              child: Text(tr('오늘'), style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Center(
                  child: Text(
                    _weekdayHeaders[i],
                    style: TextStyle(
                      fontSize: 12,
                      color: i == 0
                          ? Colors.red
                          : i == 6
                          ? Colors.blue
                          : hintColor,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (var i = 0; i < leadingBlanks; i++) const SizedBox.shrink(),
            for (var day = 1; day <= daysInMonth; day++)
              _RangeDayCell(
                date: DateTime(_month.year, _month.month, day),
                today: _today,
                start: widget.start,
                end: widget.end,
                lastDate: widget.lastDate,
                onTap: _tapDate,
              ),
          ],
        ),
      ],
    );
  }
}

class _RangeDayCell extends StatelessWidget {
  final DateTime date;
  final DateTime today;
  final DateTime? start;
  final DateTime? end;
  final DateTime? lastDate;
  final ValueChanged<DateTime> onTap;
  const _RangeDayCell({
    required this.date,
    required this.today,
    required this.start,
    required this.end,
    required this.lastDate,
    required this.onTap,
  });

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final disabled = lastDate != null && date.isAfter(lastDate!);
    final isStart = start != null && _isSameDay(date, start!);
    final isEnd = end != null && _isSameDay(date, end!);
    final isEndpoint = isStart || isEnd;
    // 달력을 열자마자 오늘이 어디인지 보이도록 회색 동그라미로 표시한다. 고른 날(검은 동그라미)
    // 이기도 하면 그쪽이 이긴다.
    final isToday = _isSameDay(date, today);
    final inRange =
        start != null &&
        end != null &&
        date.isAfter(start!) &&
        date.isBefore(end!);
    final isSunday = date.weekday == DateTime.sunday;
    final isSaturday = date.weekday == DateTime.saturday;
    final textColor = disabled
        ? Theme.of(context).disabledColor
        : isEndpoint
        ? Colors.white
        : isSunday
        ? Colors.red
        : isSaturday
        ? Colors.blue
        : null;

    return InkWell(
      onTap: disabled ? null : () => onTap(date),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        color: inRange ? Colors.black12 : null,
        alignment: Alignment.center,
        child: Container(
          margin: const EdgeInsets.all(2),
          alignment: Alignment.center,
          decoration: isEndpoint
              ? const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black87,
                )
              : isToday
              ? BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.grey.withValues(alpha: 0.35),
                )
              : null,
          child: Text('${date.day}', style: TextStyle(color: textColor)),
        ),
      ),
    );
  }
}
