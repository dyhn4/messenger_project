import 'package:flutter/material.dart';

import '../../models/groupware.dart';
import '../../models/groupware_resources.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/groupware_api.dart';
import 'groupware_screen.dart' show GroupwareChanges;
import '../../l10n/tr.dart';

/// 휴가 탭의 달력 보기 — 한 달 격자(일요일부터, 캘린더 화면과 같다)에 승인된 휴가·출장과 내가 올린 결재 중 휴가(점선)·공휴일을 보이고,
/// 날을 누르면 그날 누가 쉬는지 아래에 펼친다(서버 GET /groupware/leave/month).
class LeaveMonthCalendar extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  const LeaveMonthCalendar({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
  });

  @override
  State<LeaveMonthCalendar> createState() => _LeaveMonthCalendarState();
}

final _weekdayLabels = [
  tr('일'),
  tr('월'),
  tr('화'),
  tr('수'),
  tr('목'),
  tr('금'),
  tr('토'),
];

/// 칸 하나에 보일 이름 수 — 넘치면 "+n".
const _namesPerCell = 2;

class _LeaveMonthCalendarState extends State<LeaveMonthCalendar> {
  late DateTime _month;
  late String _selected = widget.ctx.today;
  LeaveMonth? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    final today = DateTime.parse(widget.ctx.today);
    _month = DateTime(today.year, today.month);
    widget.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.changes.removeListener(_load);
    super.dispose();
  }

  String get _monthKey =>
      '${_month.year}-${_month.month.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    final key = _monthKey;
    try {
      final data = await widget.api.leaveMonth(key);
      if (mounted && key == _monthKey) {
        setState(() {
          _data = data;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException ? trServer(e.message) : tr('휴가 달력을 받지 못했습니다.'),
        );
      }
    }
  }

  void _shift(int months) {
    setState(() {
      _month = DateTime(_month.year, _month.month + months);
      _data = null;
      final today = widget.ctx.today;
      _selected = today.startsWith(_monthKey) ? today : '$_monthKey-01';
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = _data;
    // 격자 — 그달 1일이 든 주의 일요일부터 6주 안에서 그달 마지막 날이 든 주까지.
    final first = DateTime(_month.year, _month.month);
    final gridStart = first.subtract(Duration(days: first.weekday % 7));
    final last = DateTime(_month.year, _month.month + 1, 0);
    final weeks = ((last.difference(gridStart).inDays + 1) / 7).ceil();
    return Column(
      key: const ValueKey('leave-calendar'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                key: const ValueKey('leave-cal-prev'),
                tooltip: tr('지난달'),
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _shift(-1),
              ),
              Text(
                tr('{_month.year}년 {_month.month}월', {
                  '_month.year': _month.year,
                  '_month.month': _month.month,
                }),
                key: const ValueKey('leave-cal-month'),
                style: theme.textTheme.titleMedium,
              ),
              IconButton(
                key: const ValueKey('leave-cal-next'),
                tooltip: tr('다음 달'),
                icon: const Icon(Icons.chevron_right),
                onPressed: () => _shift(1),
              ),
              const Spacer(),
              _Legend(color: theme.colorScheme.tertiary, label: tr('휴가')),
              const SizedBox(width: 8),
              _Legend(color: Colors.blue.shade400, label: tr('출장')),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_error!, style: TextStyle(color: theme.hintColor)),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            children: [
              Row(
                children: [
                  for (final (i, w) in _weekdayLabels.indexed)
                    Expanded(
                      child: Center(
                        child: Text(
                          w,
                          style: TextStyle(
                            fontSize: 12,
                            color: i == 0
                                ? theme.colorScheme.error
                                : i == 6
                                ? Colors.blue.shade600
                                : theme.hintColor,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              for (var w = 0; w < weeks; w++)
                Row(
                  children: [
                    for (var d = 0; d < 7; d++)
                      Expanded(
                        child: _DayCell(
                          day: gridStart.add(Duration(days: w * 7 + d)),
                          inMonth:
                              gridStart.add(Duration(days: w * 7 + d)).month ==
                              _month.month,
                          today: widget.ctx.today,
                          selected: _selected,
                          data: data,
                          onTap: (key) => setState(() => _selected = key),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
        if (data != null)
          _DayDetail(day: _selected, data: data, ctx: widget.ctx),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  const _Legend({required this.color, required this.label});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 12)),
    ],
  );
}

class _DayCell extends StatelessWidget {
  final DateTime day;
  final bool inMonth;
  final String today;
  final String selected;
  final LeaveMonth? data;
  final ValueChanged<String> onTap;
  const _DayCell({
    required this.day,
    required this.inMonth,
    required this.today,
    required this.selected,
    required this.data,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final key = dateKeyOf(day);
    final holiday = inMonth ? data?.holidays[key] : null;
    final leaves = inMonth
        ? data?.leavesOn(key) ?? const []
        : const <MonthLeave>[];
    final trips = inMonth
        ? data?.tripsOn(key) ?? const []
        : const <MonthTrip>[];
    final names = <(String, Color, bool)>[
      for (final l in leaves) (l.name, theme.colorScheme.tertiary, l.pending),
      for (final t in trips) (t.name, Colors.blue.shade400, false),
    ];
    final isSelected = inMonth && key == selected;
    final red = day.weekday == DateTime.sunday || holiday != null;
    final numberColor = !inMonth
        ? theme.disabledColor
        : red
        ? theme.colorScheme.error
        : day.weekday == DateTime.saturday
        ? Colors.blue.shade600
        : null;
    return InkWell(
      key: ValueKey('leave-cal-day-$key'),
      onTap: inMonth ? () => onTap(key) : null,
      child: Container(
        height: 66,
        margin: const EdgeInsets.all(1),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.6)
              : null,
          border: Border.all(
            color: key == today && inMonth
                ? theme.colorScheme.primary
                : theme.dividerColor.withValues(alpha: 0.3),
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${day.day}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: key == today ? FontWeight.w700 : null,
                    color: numberColor,
                  ),
                ),
                if (holiday != null) ...[
                  const SizedBox(width: 2),
                  Expanded(
                    child: Text(
                      holiday,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 9,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
                // 넘친 사람 수는 날짜 줄 끝에(칸 높이를 넘지 않게).
                if (names.length > _namesPerCell)
                  Text(
                    '+${names.length - _namesPerCell}',
                    style: TextStyle(fontSize: 9, color: theme.hintColor),
                  ),
              ],
            ),
            for (final (name, color, pending) in names.take(_namesPerCell))
              Container(
                margin: const EdgeInsets.only(top: 2),
                padding: const EdgeInsets.symmetric(horizontal: 2),
                width: double.infinity,
                decoration: BoxDecoration(
                  color: pending ? null : color.withValues(alpha: 0.85),
                  border: pending ? Border.all(color: color) : null,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: pending ? color : Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 고른 날 — 공휴일, 휴가(결재 중이면 표시), 출장.
class _DayDetail extends StatelessWidget {
  final String day;
  final LeaveMonth data;
  final GroupwareContext ctx;
  const _DayDetail({required this.day, required this.data, required this.ctx});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final holiday = data.holidays[day];
    final leaves = data.leavesOn(day);
    final trips = data.tripsOn(day);
    String range(String s, String e) =>
        s == e ? shortDateText(s) : '${shortDateText(s)}~${shortDateText(e)}';
    return Padding(
      key: const ValueKey('leave-cal-detail'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${shortDateText(day)}${holiday == null ? '' : ' · $holiday'}',
            style: theme.textTheme.titleSmall,
          ),
          if (leaves.isEmpty && trips.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                tr('쉬거나 출장 간 사람이 없습니다.'),
                style: TextStyle(color: theme.hintColor),
              ),
            ),
          for (final l in leaves)
            ListTile(
              key: ValueKey('leave-cal-leave-${l.documentId}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.beach_access_outlined,
                size: 20,
                color: theme.colorScheme.tertiary,
              ),
              title: Text(
                '${l.name} · ${l.label}${l.pending ? tr(' (결재 중)') : ''}',
              ),
              subtitle: Text(range(l.startDate, l.endDate)),
            ),
          for (final t in trips)
            ListTile(
              key: ValueKey('leave-cal-trip-${t.documentId}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.flight_takeoff,
                size: 20,
                color: Colors.blue.shade400,
              ),
              title: Text(
                tr('{t.name} · 출장{p0}', {
                  't.name': t.name,
                  'p0': (t.destination ?? '').isEmpty
                      ? ''
                      : ' (${t.destination})',
                }),
              ),
              subtitle: Text(range(t.startDate, t.endDate)),
            ),
        ],
      ),
    );
  }
}
