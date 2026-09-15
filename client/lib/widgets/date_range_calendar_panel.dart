import 'package:flutter/material.dart';

const _weekdayHeaders = ['일', '월', '화', '수', '목', '금', '토'];

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
  const DateRangeCalendarPanel({
    super.key,
    required this.start,
    required this.end,
    required this.onChanged,
    this.lastDate,
  });

  @override
  State<DateRangeCalendarPanel> createState() => _DateRangeCalendarPanelState();
}

class _DateRangeCalendarPanelState extends State<DateRangeCalendarPanel> {
  late DateTime _month;

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

  void _goToday() {
    final now = DateTime.now();
    setState(() => _month = DateTime(now.year, now.month, 1));
  }

  void _tapDate(DateTime date) {
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
              child: const Text('오늘', style: TextStyle(fontSize: 12)),
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
  final DateTime? start;
  final DateTime? end;
  final DateTime? lastDate;
  final ValueChanged<DateTime> onTap;
  const _RangeDayCell({
    required this.date,
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
              : null,
          child: Text('${date.day}', style: TextStyle(color: textColor)),
        ),
      ),
    );
  }
}
