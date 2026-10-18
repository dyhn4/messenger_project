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

/// FloatingDatePill의 꺽쇠를 누르면 뜨는 미니 달력 — 날짜를 고르면 채팅 목록에서 그 날짜의
/// 구분선으로 이동한다(chat_panel.dart의 _jumpToDate 참고). 일요일은 빨강, 토요일은 파랑으로
/// 표시하고, 선택된 날짜는 검은 원으로 표시한다.
class DatePickerPopup extends StatefulWidget {
  final DateTime initialMonth;
  final DateTime? selectedDate;
  final VoidCallback onClose;
  final ValueChanged<DateTime> onDateSelected;
  const DatePickerPopup({
    super.key,
    required this.initialMonth,
    required this.onClose,
    required this.onDateSelected,
    this.selectedDate,
  });

  @override
  State<DatePickerPopup> createState() => _DatePickerPopupState();
}

class _DatePickerPopupState extends State<DatePickerPopup> {
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    _month = DateTime(widget.initialMonth.year, widget.initialMonth.month, 1);
  }

  void _prevMonth() =>
      setState(() => _month = DateTime(_month.year, _month.month - 1, 1));

  void _nextMonth() =>
      setState(() => _month = DateTime(_month.year, _month.month + 1, 1));

  void _goToday() {
    final now = DateTime.now();
    setState(() => _month = DateTime(now.year, now.month, 1));
  }

  @override
  Widget build(BuildContext context) {
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final leadingBlanks =
        _month.weekday % 7; // Dart weekday: 월=1..일=7 → 일요일 시작 기준.
    final hintColor = Theme.of(context).hintColor;

    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(context).colorScheme.surface,
      child: Container(
        width: 300,
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('선택 날짜로 이동'),
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                InkWell(
                  onTap: widget.onClose,
                  borderRadius: BorderRadius.circular(12),
                  child: Icon(Icons.close, size: 18, color: hintColor),
                ),
              ],
            ),
            const SizedBox(height: 10),
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
                  _DayCell(
                    date: DateTime(_month.year, _month.month, day),
                    selected: _isSameDay(widget.selectedDate, day),
                    onTap: (date) => widget.onDateSelected(date),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool _isSameDay(DateTime? d, int day) =>
      d != null &&
      d.year == _month.year &&
      d.month == _month.month &&
      d.day == day;
}

class _DayCell extends StatelessWidget {
  final DateTime date;
  final bool selected;
  final ValueChanged<DateTime> onTap;
  const _DayCell({
    required this.date,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isSunday = date.weekday == DateTime.sunday;
    final isSaturday = date.weekday == DateTime.saturday;
    final textColor = selected
        ? Colors.white
        : isSunday
        ? Colors.red
        : isSaturday
        ? Colors.blue
        : null;
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: () => onTap(date),
      child: Container(
        margin: const EdgeInsets.all(2),
        alignment: Alignment.center,
        decoration: selected
            ? const BoxDecoration(shape: BoxShape.circle, color: Colors.black87)
            : null,
        child: Text('${date.day}', style: TextStyle(color: textColor)),
      ),
    );
  }
}
