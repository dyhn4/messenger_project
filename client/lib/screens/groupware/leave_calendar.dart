import 'package:flutter/gestures.dart'
    show DragStartBehavior, PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/groupware.dart';
import '../../models/groupware_resources.dart';
import '../../services/api_client.dart' show ApiException;
import '../../services/groupware_api.dart';
import 'approval_forms.dart' show showLeaveRequestDialog, toastSubmitted;
import 'groupware_screen.dart' show GroupwareChanges;
import '../../l10n/tr.dart';

/// 휴가 달력의 부서 하나 — 조직도 트리 순서, [depth] 1이 맨 위(서버 leaveDepartments.js).
typedef LeaveDepartment = ({
  String id,
  String name,
  String? parentId,
  int depth,
});

/// 휴가 달력·앞으로 30일 목록의 부서 거르기를 이 기기에 기억하는 키 — 부서 id 또는 'none'(부서 없음), 키가 없으면 모든 부서.
const kLeaveDepartmentPref = 'leave_calendar_department';

/// 기억해 둔 부서 거르기(없거나 못 읽으면 null — 모든 부서). 그 부서가 아직 있는지는 받은 부서 목록으로 따로 본다.
/// 휴가 탭은 이 값을 읽은 뒤에 처음 받으므로, 저장소가 답하지 않으면(플러그인이 없는 환경 — 시험 등) 잠깐만 기다리고 모든 부서로 연다.
Future<String?> loadLeaveDepartment() async {
  try {
    final prefs = await SharedPreferences.getInstance().timeout(
      const Duration(milliseconds: 500),
    );
    final saved = prefs.getString(kLeaveDepartmentPref);
    return saved == null || saved.isEmpty ? null : saved;
  } catch (_) {
    // 설정 저장소를 못 쓰거나 늦다 — 모든 부서로.
    return null;
  }
}

/// 부서 거르기를 기억한다 — null(모든 부서)이면 지운다. 못 쓰면 조용히 넘어간다(다음에 모든 부서로 열릴 뿐).
Future<void> saveLeaveDepartment(String? departmentId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    if (departmentId == null) {
      await prefs.remove(kLeaveDepartmentPref);
    } else {
      await prefs.setString(kLeaveDepartmentPref, departmentId);
    }
  } catch (_) {
    // 기억하지 못해도 지금 화면의 거르기는 그대로 쓴다.
  }
}

/// [value]가 [departments]에서 아직 고를 수 있는 값인지 — null(모든 부서)은 늘, 'none'(부서 없음)·부서 id는 부서 목록이 있을 때만.
/// 조직도가 비었거나 그 부서가 지워졌으면 false(모든 부서로 되돌린다).
bool leaveDepartmentValid(List<LeaveDepartment> departments, String? value) =>
    value == null ||
    (departments.isNotEmpty &&
        (value == 'none' || departments.any((d) => d.id == value)));

/// 부서 거르기 드롭다운 — "모든 부서"(null), 부서마다(깊이만큼 들여 쓴다 — 트리 순서 그대로), "부서 없음"('none').
/// 부서 목록이 비면(조직도에 부서가 없다) 부르는 쪽이 숨긴다. 좁은 화면(360px)에서도 넘치지 않게 가로를 채우고 이름은 말줄임.
class LeaveDepartmentFilter extends StatelessWidget {
  final List<LeaveDepartment> departments;
  final String? value;
  final ValueChanged<String?> onChanged;
  const LeaveDepartmentFilter({
    super.key,
    required this.departments,
    required this.value,
    required this.onChanged,
  });

  /// "모든 부서"의 드롭다운 값 — null 값 항목 대신 빈 문자열을 쓴다(선택 표시가 흔들리지 않게).
  static const _all = '';

  @override
  Widget build(BuildContext context) {
    final current = leaveDepartmentValid(departments, value)
        ? value ?? _all
        : _all;
    // 펼친 목록의 한 줄 — 깊이 1은 들여 쓰지 않고, 한 단계마다 14px(너무 깊어도 6단계까지만).
    Widget line(String text, {double indent = 0, Key? key}) => Padding(
      key: key,
      padding: EdgeInsets.only(left: indent),
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    final labels = [
      tr('모든 부서'),
      for (final d in departments) d.name,
      tr('부서 없음'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: tr('부서'),
              isDense: true,
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                key: const ValueKey('leave-dept-filter'),
                value: current,
                isExpanded: true,
                isDense: true,
                // 닫힌 칸에는 들여쓰기 없이 이름만.
                selectedItemBuilder: (_) => [
                  for (final l in labels)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        l,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                items: [
                  DropdownMenuItem(
                    value: _all,
                    child: line(
                      labels.first,
                      key: const ValueKey('leave-dept-all'),
                    ),
                  ),
                  for (final d in departments)
                    DropdownMenuItem(
                      value: d.id,
                      child: line(
                        d.name,
                        indent: (d.depth - 1).clamp(0, 6) * 14.0,
                        key: ValueKey('leave-dept-${d.id}'),
                      ),
                    ),
                  DropdownMenuItem(
                    value: 'none',
                    child: line(
                      labels.last,
                      key: const ValueKey('leave-dept-none'),
                    ),
                  ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  onChanged(v == _all ? null : v);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 휴가 탭의 달력 보기 — 한 달 격자(일요일부터, 캘린더 화면과 같다)에 승인된 휴가·출장과 내가 올린 결재 중 휴가(점선)·공휴일을 보이고,
/// 날을 누르면 그날 누가 쉬는지 아래에 펼친다(서버 GET /groupware/leave/month).
///
/// 날을 길게 누른 채(터치) 또는 마우스로 누른 채 끌어 여러 날을 고르면, 손을 뗄 때 그 기간(앞뒤 바로잡음 — 보이는 격자 안, 주말·공휴일이
/// 끼어도 된다: 서버가 근무일만 센다)으로 휴가 신청 창을 연다. 고른 날의 상세에도 "이날 휴가 신청"이 있다. 올렸으면 알리고 [changes]를
/// 울려 달력·휴가 탭을 다시 받는다.
///
/// [departmentId]는 부서 거르기(uuid · 'none' · null — 부르는 쪽이 정한다, 바뀌면 다시 받는다). 받을 때마다 [onLoaded]로 응답을
/// 넘긴다(부서 목록으로 드롭다운을 그리고, 기억한 부서가 없어졌으면 모든 부서로 되돌리게). [balance]는 신청 창의 남은 연차 표시용.
class LeaveMonthCalendar extends StatefulWidget {
  final GroupwareApi api;
  final GroupwareContext ctx;
  final GroupwareChanges changes;
  final String? departmentId;
  final ValueChanged<LeaveMonth>? onLoaded;
  final LeaveBalance? balance;
  const LeaveMonthCalendar({
    super.key,
    required this.api,
    required this.ctx,
    required this.changes,
    this.departmentId,
    this.onLoaded,
    this.balance,
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

/// 날 칸의 높이와, 바깥 여백(위아래 1px씩)을 더한 한 주 줄의 높이 — 끌어 고를 때 손가락 위치를 날로 바꾸는 데 쓴다.
const _cellHeight = 66.0;
const _rowExtent = _cellHeight + 2;

class _LeaveMonthCalendarState extends State<LeaveMonthCalendar> {
  late DateTime _month;
  late String _selected = widget.ctx.today;
  LeaveMonth? _data;
  String? _error;

  /// 끌어 고르는 중인 기간 — 처음 누른 날과 지금 손가락이 있는 날('YYYY-MM-DD', 순서는 끈 방향 그대로). 고르지 않을 때는 null.
  String? _dragFrom;
  String? _dragTo;

  @override
  void initState() {
    super.initState();
    final today = DateTime.parse(widget.ctx.today);
    _month = DateTime(today.year, today.month);
    widget.changes.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(LeaveMonthCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changes != widget.changes) {
      oldWidget.changes.removeListener(_load);
      widget.changes.addListener(_load);
    }
    // 부서 거르기가 바뀌면 그 부서로 다시 받는다(받는 동안은 보던 달력을 그대로 둔다).
    if (oldWidget.departmentId != widget.departmentId) _load();
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
    final department = widget.departmentId;
    try {
      final data = await widget.api.leaveMonth(key, departmentId: department);
      // 그 사이 달이나 부서를 바꿨으면 늦게 온 응답은 버린다.
      if (mounted && key == _monthKey && department == widget.departmentId) {
        setState(() {
          _data = data;
          _error = null;
        });
        widget.onLoaded?.call(data);
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException
              ? trServer(e.message)
              : tr('휴가 달력을 받지 못했습니다.'),
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
      _dragFrom = _dragTo = null;
    });
    _load();
  }

  /// 끌어 고른 기간(앞뒤 바로잡음) — 고르지 않을 때는 null.
  (String, String)? get _selection {
    final from = _dragFrom;
    final to = _dragTo;
    if (from == null || to == null) return null;
    return from.compareTo(to) <= 0 ? (from, to) : (to, from);
  }

  void _startSelect(DateTime day) => setState(() {
    _dragFrom = _dragTo = dateKeyOf(day);
  });

  void _moveSelect(DateTime day) {
    final key = dateKeyOf(day);
    if (_dragFrom == null || key == _dragTo) return;
    setState(() => _dragTo = key);
  }

  /// 손을 뗐다 — 고른 기간으로 휴가 신청 창을 열고, 창이 닫히면 고른 칸 표시를 지운다.
  Future<void> _endSelect() async {
    final range = _selection;
    if (range == null) return;
    await _requestLeave(range.$1, range.$2);
    if (mounted) setState(() => _dragFrom = _dragTo = null);
  }

  /// 고르다 말았다(다른 몸짓이 이겼거나 취소됐다) — 고른 칸 표시만 지운다.
  void _cancelSelect() {
    if (_dragFrom == null) return;
    setState(() => _dragFrom = _dragTo = null);
  }

  /// [start]~[end]로 미리 채운 휴가 신청 창 — 올렸으면 알리고 [GroupwareChanges]를 울린다(이 달력과 휴가 탭이 다시 받는다).
  Future<void> _requestLeave(String start, String end) async {
    final doc = await showLeaveRequestDialog(
      context,
      api: widget.api,
      ctx: widget.ctx,
      balance: widget.balance,
      initialStart: start,
      initialEnd: end,
    );
    if (!mounted || doc == null) return;
    toastSubmitted(context, doc);
    widget.changes.bump();
  }

  /// 주 줄들 — 길게 누른 채 끌기(터치·마우스 모두)와 마우스로 누른 채 끌기로 기간을 고른다. 터치의 그냥 끌기는 바깥 목록의 스크롤로
  /// 남겨 둔다(마우스 끌기만 받는 안쪽 감지기). 손가락 위치는 칸 너비(가로 7등분)·줄 높이로 날로 바꾸고, 격자 밖으로 나가면 끝 칸에 붙인다.
  Widget _weekRows({
    required DateTime gridStart,
    required int weeks,
    required LeaveMonth? data,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      DateTime dayAt(Offset p) {
        final col = (p.dx / (constraints.maxWidth / 7)).floor().clamp(0, 6);
        final row = (p.dy / _rowExtent).floor().clamp(0, weeks - 1);
        return gridStart.add(Duration(days: row * 7 + col));
      }

      final selection = _selection;
      return GestureDetector(
        onLongPressStart: (d) => _startSelect(dayAt(d.localPosition)),
        onLongPressMoveUpdate: (d) => _moveSelect(dayAt(d.localPosition)),
        onLongPressEnd: (_) => _endSelect(),
        onLongPressCancel: _cancelSelect,
        child: GestureDetector(
          supportedDevices: const {PointerDeviceKind.mouse},
          // 처음 누른 곳부터 고르게(끌기로 인정된 곳이 아니라).
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: (d) => _startSelect(dayAt(d.localPosition)),
          onPanUpdate: (d) => _moveSelect(dayAt(d.localPosition)),
          onPanEnd: (_) => _endSelect(),
          onPanCancel: _cancelSelect,
          child: Column(
            children: [
              for (var w = 0; w < weeks; w++)
                Row(
                  children: [
                    for (var d = 0; d < 7; d++)
                      Expanded(
                        child: Builder(
                          builder: (context) {
                            final day = gridStart.add(
                              Duration(days: w * 7 + d),
                            );
                            final key = dateKeyOf(day);
                            return _DayCell(
                              day: day,
                              inMonth: day.month == _month.month,
                              today: widget.ctx.today,
                              selected: _selected,
                              inSelection:
                                  selection != null &&
                                  key.compareTo(selection.$1) >= 0 &&
                                  key.compareTo(selection.$2) <= 0,
                              data: data,
                              onTap: (key) => setState(() => _selected = key),
                            );
                          },
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = _data;
    // 격자 — 그달 1일이 든 주의 일요일부터 6주 안에서 그달 마지막 날이 든 주까지.
    final first = DateTime(_month.year, _month.month);
    final gridStart = first.subtract(Duration(days: first.weekday % 7));
    final last = DateTime(_month.year, _month.month + 1, 0);
    final weeks = ((last.difference(gridStart).inDays + 1) / 7).ceil();
    final selection = _selection;
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
              _weekRows(gridStart: gridStart, weeks: weeks, data: data),
            ],
          ),
        ),
        // 끌어 고르는 중이면 고른 기간, 아니면 끌어 고를 수 있다는 한 줄 안내.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: selection == null
              ? Text(
                  tr('날을 길게 누르거나 끌어서 고르면 그 기간으로 휴가를 신청합니다.'),
                  key: const ValueKey('leave-cal-hint'),
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                )
              : Text(
                  tr('{range} — 손을 떼면 이 기간으로 휴가를 신청합니다.', {
                    'range': selection.$1 == selection.$2
                        ? shortDateText(selection.$1)
                        : '${shortDateText(selection.$1)}~${shortDateText(selection.$2)}',
                  }),
                  key: const ValueKey('leave-cal-selection'),
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.secondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
        if (data != null)
          _DayDetail(
            day: _selected,
            data: data,
            ctx: widget.ctx,
            onRequest: () => _requestLeave(_selected, _selected),
          ),
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

  /// 끌어 고르는 기간 안의 날 — 칸을 칠하고 테두리를 굵게(그달 밖 날도 보이는 격자 안이면 고를 수 있다).
  final bool inSelection;
  final LeaveMonth? data;
  final ValueChanged<String> onTap;
  const _DayCell({
    required this.day,
    required this.inMonth,
    required this.today,
    required this.selected,
    this.inSelection = false,
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
        key: inSelection ? ValueKey('leave-cal-selected-$key') : null,
        height: _cellHeight,
        margin: const EdgeInsets.all(1),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: inSelection
              ? theme.colorScheme.secondaryContainer
              : isSelected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.6)
              : null,
          border: Border.all(
            color: inSelection
                ? theme.colorScheme.secondary
                : key == today && inMonth
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

/// 고른 날 — 공휴일, 휴가(결재 중이면 표시), 출장. 머리 줄 끝의 "이날 휴가 신청"([onRequest])은 그날 하루로 신청 창을 연다.
class _DayDetail extends StatelessWidget {
  final String day;
  final LeaveMonth data;
  final GroupwareContext ctx;
  final VoidCallback onRequest;
  const _DayDetail({
    required this.day,
    required this.data,
    required this.ctx,
    required this.onRequest,
  });

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
          Row(
            children: [
              Expanded(
                child: Text(
                  '${shortDateText(day)}${holiday == null ? '' : ' · $holiday'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              TextButton.icon(
                key: const ValueKey('leave-cal-request-day'),
                onPressed: onRequest,
                icon: const Icon(Icons.add, size: 16),
                label: Text(tr('이날 휴가 신청')),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
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
