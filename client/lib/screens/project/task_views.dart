import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/muted_scrollbar.dart';
import '../../widgets/user_avatar.dart';

const kWeekdayLabels = ['일', '월', '화', '수', '목', '금', '토'];

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String formatYmd(DateTime d) =>
    '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';

String formatMd(DateTime d) => '${d.month}.${d.day}';

/// 캘린더/목록 양쪽에서 쓰는 업무의 날짜 범위 — 시작일·마감일 중 하나만 있으면 그 하루로 본다.
/// 둘 다 없으면 null(캘린더에는 안 나온다).
(DateTime, DateTime)? taskRange(Task t) {
  final s = t.startDate == null ? null : dateOnly(t.startDate!);
  final e = t.dueDate == null ? null : dateOnly(t.dueDate!);
  final start = s ?? e;
  final end = e ?? s;
  if (start == null || end == null) return null;
  return start.isAfter(end) ? (end, start) : (start, end);
}

/// 업무의 상태 색 — 프로젝트가 정한 색, 없으면 분류 기본색.
Color taskStatusDisplayColor(Task t) => t.statusColor != null
    ? parseTypeColor(t.statusColor)
    : taskStatusColor(t.status);

Color taskStatusColor(TaskStatus s) => switch (s) {
  TaskStatus.todo => const Color(0xFF607D8B),
  TaskStatus.doing => const Color(0xFFEF8F00),
  TaskStatus.done => const Color(0xFF2E9E6B),
};

Color taskPriorityColor(TaskPriority p) => switch (p) {
  TaskPriority.high => const Color(0xFFE53935),
  TaskPriority.normal => const Color(0xFF1E88E5),
  TaskPriority.low => const Color(0xFF78909C),
};

/// 캘린더 막대/패널 색 — 유형이 있으면 유형 색, 없으면 상태 색.
Color taskDisplayColor(Task t) => t.typeColor != null
    ? parseTypeColor(t.typeColor)
    : taskStatusColor(t.status);

/// 업무 목록 표 — "내 업무"와 프로젝트 "리스트" 보기가 같이 쓴다. [members]를 주면 마지막 칸이
/// 생성자 대신 담당자(구성원 목록에서 찾아서)를 보여준다.
class TaskListTable extends StatelessWidget {
  final List<Task> tasks;
  final Session session;
  final ValueChanged<Task> onOpen;
  final String emptyText;
  final List<AppUser>? members;

  /// 프로젝트의 사용자 정의 필드 — 주면 표 오른쪽에 필드마다 열이 붙는다.
  final List<TaskFieldDef> fields;

  const TaskListTable({
    super.key,
    required this.tasks,
    required this.session,
    required this.onOpen,
    this.emptyText = '업무가 없습니다.',
    this.members,
    this.fields = const [],
  });

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      return Center(
        child: Text(
          emptyText,
          style: TextStyle(color: Theme.of(context).hintColor),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final tableWidth = math.max(
          constraints.maxWidth - 48,
          900.0 + fields.length * _TaskTable._fieldW,
        );
        return Scrollbar(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
            child: SizedBox(
              width: tableWidth,
              height: constraints.maxHeight - 36,
              child: _TaskTable(
                tasks: tasks,
                session: session,
                onOpen: onOpen,
                members: members,
                fields: fields,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 월/주 캘린더 + 선택한 날의 업무 패널 — "내 업무", 프로젝트 "캘린더", 전체 "캘린더"가 같이 쓴다.
class TaskCalendarView extends StatefulWidget {
  final List<Task> tasks;
  final ValueChanged<Task> onOpen;
  const TaskCalendarView({
    super.key,
    required this.tasks,
    required this.onOpen,
  });

  @override
  State<TaskCalendarView> createState() => _TaskCalendarViewState();
}

class _TaskCalendarViewState extends State<TaskCalendarView> {
  bool _monthMode = true;
  DateTime _focused = dateOnly(DateTime.now());
  DateTime _selected = dateOnly(DateTime.now());

  void _openTask(Task t) => widget.onOpen(t);

  @override
  Widget build(BuildContext context) => _buildCalendar(widget.tasks);

  // ───────────────────────── 캘린더 ─────────────────────────

  DateTime get _weekStart =>
      _focused.subtract(Duration(days: _focused.weekday % 7));

  void _shift(int delta) {
    setState(() {
      _focused = _monthMode
          ? DateTime(_focused.year, _focused.month + delta, 1)
          : _focused.add(Duration(days: 7 * delta));
    });
  }

  void _goToday() {
    setState(() {
      _focused = dateOnly(DateTime.now());
      _selected = _focused;
    });
  }

  Widget _buildCalendar(List<Task> tasks) {
    final scheduled = [
      for (final t in tasks)
        if (taskRange(t) != null) t,
    ];
    final title = _monthMode
        ? '${_focused.year}년 ${_focused.month}월'
        : '${_weekStart.year}년 ${_weekStart.month}월 ${_weekStart.day}일 주';

    // 그 달의 주(행)별 날짜들.
    final weeks = <List<DateTime>>[];
    if (_monthMode) {
      final first = DateTime(_focused.year, _focused.month, 1);
      final gridStart = first.subtract(Duration(days: first.weekday % 7));
      final daysInMonth = DateTime(_focused.year, _focused.month + 1, 0).day;
      final rows = ((first.weekday % 7) + daysInMonth / 7).ceil();
      final weekCount = (((first.weekday % 7) + daysInMonth) / 7).ceil();
      assert(rows >= 0);
      for (var w = 0; w < weekCount; w++) {
        weeks.add([
          for (var d = 0; d < 7; d++) gridStart.add(Duration(days: w * 7 + d)),
        ]);
      }
    } else {
      final start = _weekStart;
      weeks.add([for (var d = 0; d < 7; d++) start.add(Duration(days: d))]);
    }

    final selectedTasks = [
      for (final t in scheduled)
        if (!_selected.isBefore(taskRange(t)!.$1) &&
            !_selected.isAfter(taskRange(t)!.$2))
          t,
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 760;
        final grid = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _shift(-1),
                ),
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _shift(1),
                ),
                const SizedBox(width: 4),
                OutlinedButton(
                  onPressed: _goToday,
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('오늘'),
                ),
                const Spacer(),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(value: true, label: Text('월')),
                    ButtonSegment(value: false, label: Text('주')),
                  ],
                  selected: {_monthMode},
                  onSelectionChanged: (s) =>
                      setState(() => _monthMode = s.first),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      child: Text(
                        kWeekdayLabels[i],
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: i == 0
                              ? Colors.redAccent
                              : (i == 6 ? Colors.blueAccent : null),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            Expanded(
              child: Column(
                children: [
                  for (final week in weeks)
                    Expanded(
                      child: _WeekRow(
                        days: week,
                        tasks: scheduled,
                        month: _monthMode ? _focused.month : null,
                        selected: _selected,
                        maxLanes: _monthMode ? 3 : 8,
                        onSelectDay: (d) => setState(() => _selected = d),
                        onOpenTask: _openTask,
                      ),
                    ),
                ],
              ),
            ),
          ],
        );

        final panel = _DayPanel(
          date: _selected,
          tasks: selectedTasks,
          onOpen: _openTask,
        );

        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
          child: narrow
              ? Column(
                  children: [
                    Expanded(flex: 3, child: grid),
                    const SizedBox(height: 12),
                    Expanded(flex: 2, child: panel),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: grid),
                    const SizedBox(width: 16),
                    SizedBox(width: 260, child: panel),
                  ],
                ),
        );
      },
    );
  }
}

// ───────────────────────── 리스트 표 ─────────────────────────

class _TaskTable extends StatelessWidget {
  final List<Task> tasks;
  final Session session;
  final ValueChanged<Task> onOpen;
  final List<AppUser>? members;
  final List<TaskFieldDef> fields;
  const _TaskTable({
    required this.tasks,
    required this.session,
    required this.onOpen,
    this.members,
    this.fields = const [],
  });

  static const _typeW = 120.0;
  static const _priorityW = 90.0;
  static const _statusW = 100.0;
  static const _startW = 100.0;
  static const _dueW = 130.0;
  static const _creatorW = 130.0;
  static const _fieldW = 120.0;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final border = Theme.of(context).dividerColor;
    Widget head(String text, {double? width}) {
      final child = Text(
        text,
        textAlign: width == null ? TextAlign.start : TextAlign.center,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: hint,
        ),
      );
      return width == null
          ? Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: child,
              ),
            )
          : SizedBox(width: width, child: child);
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            height: 36,
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: Row(
              children: [
                head('업무'),
                head('유형', width: _typeW),
                head('우선순위', width: _priorityW),
                head('상태', width: _statusW),
                head('시작일', width: _startW),
                head('마감일', width: _dueW),
                head(members == null ? '생성자' : '담당자', width: _creatorW),
                for (final f in fields) head(f.name, width: _fieldW),
              ],
            ),
          ),
          Expanded(
            child: MutedScrollbar(
              child: ListView.separated(
                itemCount: tasks.length,
                separatorBuilder: (_, _) => Divider(height: 1, color: border),
                itemBuilder: (context, i) => _TaskTableRow(
                  task: tasks[i],
                  session: session,
                  members: members,
                  fields: fields,
                  onTap: () => onOpen(tasks[i]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TaskPill extends StatelessWidget {
  final String text;
  final Color color;
  const TaskPill(this.text, this.color, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _TaskTableRow extends StatelessWidget {
  final Task task;
  final Session session;
  final VoidCallback onTap;
  final List<AppUser>? members;
  final List<TaskFieldDef> fields;
  const _TaskTableRow({
    required this.task,
    required this.session,
    required this.onTap,
    this.members,
    this.fields = const [],
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final done = task.status == TaskStatus.done;
    final overdueDays = task.isOverdue ? -(task.daysUntilDue ?? 0) : 0;
    // 칸이 좁아 내용이 넘칠 때(긴 유형 이름, D+n 뱃지가 붙은 마감일 등)는 잘라내지 않고 줄여서 맞춘다.
    Widget cell(Widget child, double width) => SizedBox(
      width: width,
      child: Center(
        child: FittedBox(fit: BoxFit.scaleDown, child: child),
      ),
    );

    // 마지막 칸 — [members]가 있으면(프로젝트 리스트 보기) 담당자, 없으면 생성자.
    final AppUser? person;
    if (members != null) {
      person = members!.where((m) => m.id == task.assigneeId).firstOrNull;
    } else if (task.creatorName == null) {
      person = null;
    } else {
      person = AppUser(
        id: task.creatorId ?? '',
        username: task.creatorName!,
        name: task.creatorName!,
        avatarType: task.creatorAvatarType,
        avatarEmoji: task.creatorAvatarEmoji,
        avatarColor: task.creatorAvatarColor,
        avatarUrl: task.creatorAvatarUrl,
      );
    }

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 16, right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (task.key != null)
                          Text(
                            task.key!,
                            style: const TextStyle(
                              color: Color(0xFF5B8DEF),
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        if (task.myRole == 'reference') ...[
                          const SizedBox(width: 6),
                          TaskPill('참조', const Color(0xFF8E6BD9)),
                        ],
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              decoration: done
                                  ? TextDecoration.lineThrough
                                  : null,
                              color: done ? hint : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (task.projectName != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        task.projectName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: hint, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            cell(
              task.typeName == null
                  ? Text('—', style: TextStyle(color: hint))
                  : TaskPill(task.typeName!, parseTypeColor(task.typeColor)),
              _TaskTable._typeW,
            ),
            cell(
              TaskPill(
                taskPriorityLabel(task.priority),
                taskPriorityColor(task.priority),
              ),
              _TaskTable._priorityW,
            ),
            cell(
              TaskPill(task.statusLabel, taskStatusDisplayColor(task)),
              _TaskTable._statusW,
            ),
            cell(
              Text(
                task.startDate == null ? '—' : formatYmd(task.startDate!),
                style: TextStyle(fontSize: 12, color: hint),
              ),
              _TaskTable._startW,
            ),
            cell(
              task.dueDate == null
                  ? Text('—', style: TextStyle(color: hint))
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          formatYmd(task.dueDate!),
                          style: TextStyle(
                            fontSize: 12,
                            color: task.isOverdue ? Colors.redAccent : hint,
                          ),
                        ),
                        if (task.isOverdue) ...[
                          const SizedBox(width: 6),
                          TaskPill('D+$overdueDays', Colors.redAccent),
                        ],
                      ],
                    ),
              _TaskTable._dueW,
            ),
            cell(
              person == null
                  ? Text('—', style: TextStyle(color: hint))
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        UserAvatar(
                          user: person,
                          resolveUrl: session.resolveUrl,
                          radius: 10,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            person.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
              _TaskTable._creatorW,
            ),
            for (final f in fields)
              cell(
                Text(
                  f.display(task.customValues[f.id]) ?? '—',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: task.customValues[f.id] == null ? hint : null,
                  ),
                ),
                _TaskTable._fieldW,
              ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── 캘린더 부품 ─────────────────────────

class _Segment {
  final Task task;
  final int startCol;
  final int endCol;
  final bool continuesLeft;
  final bool continuesRight;
  int lane = 0;
  _Segment(
    this.task,
    this.startCol,
    this.endCol,
    this.continuesLeft,
    this.continuesRight,
  );
}

/// 캘린더 한 주(한 행) — 날짜 칸 위에 그 주에 걸친 업무를 막대로 얹는다. 여러 날에 걸친 업무는
/// 칸을 가로질러 하나의 막대로 보이고, 겹치는 막대는 위아래 줄(lane)로 나눈다.
class _WeekRow extends StatelessWidget {
  final List<DateTime> days;
  final List<Task> tasks;

  /// 월 보기에서 "이번 달"인 달(다른 달 날짜는 흐리게). 주 보기에서는 null.
  final int? month;
  final DateTime selected;
  final int maxLanes;
  final ValueChanged<DateTime> onSelectDay;
  final ValueChanged<Task> onOpenTask;

  const _WeekRow({
    required this.days,
    required this.tasks,
    required this.month,
    required this.selected,
    required this.maxLanes,
    required this.onSelectDay,
    required this.onOpenTask,
  });

  static const _dayHeader = 24.0;
  static const _barHeight = 18.0;
  static const _barGap = 2.0;

  List<_Segment> _segments() {
    final first = days.first;
    final last = days.last;
    final result = <_Segment>[];
    for (final t in tasks) {
      final range = taskRange(t)!;
      if (range.$2.isBefore(first) || range.$1.isAfter(last)) continue;
      final s = range.$1.isBefore(first) ? first : range.$1;
      final e = range.$2.isAfter(last) ? last : range.$2;
      result.add(
        _Segment(
          t,
          s.difference(first).inDays,
          e.difference(first).inDays,
          range.$1.isBefore(first),
          range.$2.isAfter(last),
        ),
      );
    }
    result.sort((a, b) {
      final c = a.startCol.compareTo(b.startCol);
      if (c != 0) return c;
      return (b.endCol - b.startCol).compareTo(a.endCol - a.startCol);
    });
    final laneEnds = <int>[];
    for (final seg in result) {
      var lane = laneEnds.indexWhere((end) => end < seg.startCol);
      if (lane == -1) {
        laneEnds.add(seg.endCol);
        lane = laneEnds.length - 1;
      } else {
        laneEnds[lane] = seg.endCol;
      }
      seg.lane = lane;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final border = Theme.of(context).dividerColor;
    final today = dateOnly(DateTime.now());
    final segments = _segments();

    return LayoutBuilder(
      builder: (context, constraints) {
        final colW = constraints.maxWidth / 7;
        // 칸 높이에 들어가는 만큼만 그린다(넘치는 건 "+n").
        final fit =
            ((constraints.maxHeight - _dayHeader - 14) / (_barHeight + _barGap))
                .floor();
        final lanes = math.max(1, math.min(maxLanes, fit));
        final hiddenPerDay = List<int>.filled(7, 0);
        for (final seg in segments) {
          if (seg.lane >= lanes) {
            for (var c = seg.startCol; c <= seg.endCol; c++) {
              hiddenPerDay[c]++;
            }
          }
        }

        return Stack(
          children: [
            Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: _DayCell(
                      date: days[i],
                      column: i,
                      dimmed: month != null && days[i].month != month,
                      isToday: days[i] == today,
                      isSelected: days[i] == selected,
                      hidden: hiddenPerDay[i],
                      border: border,
                      onTap: () => onSelectDay(days[i]),
                    ),
                  ),
              ],
            ),
            for (final seg in segments)
              if (seg.lane < lanes)
                Positioned(
                  left: seg.startCol * colW + (seg.continuesLeft ? 0 : 3),
                  top: _dayHeader + seg.lane * (_barHeight + _barGap),
                  width:
                      (seg.endCol - seg.startCol + 1) * colW -
                      (seg.continuesLeft ? 0 : 3) -
                      (seg.continuesRight ? 0 : 3),
                  height: _barHeight,
                  child: _TaskBar(
                    task: seg.task,
                    roundLeft: !seg.continuesLeft,
                    roundRight: !seg.continuesRight,
                    onTap: () => onOpenTask(seg.task),
                  ),
                ),
          ],
        );
      },
    );
  }
}

class _DayCell extends StatelessWidget {
  final DateTime date;
  final int column;
  final bool dimmed;
  final bool isToday;
  final bool isSelected;
  final int hidden;
  final Color border;
  final VoidCallback onTap;
  const _DayCell({
    required this.date,
    required this.column,
    required this.dimmed,
    required this.isToday,
    required this.isSelected,
    required this.hidden,
    required this.border,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final hint = Theme.of(context).hintColor;
    final numColor = dimmed
        ? hint.withValues(alpha: 0.6)
        : (column == 0
              ? Colors.redAccent
              : (column == 6 ? Colors.blueAccent : null));
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: isSelected
              ? primary.withValues(alpha: 0.08)
              : (dimmed
                    ? Theme.of(context).colorScheme.surfaceContainerLow
                    : null),
          border: Border(
            right: BorderSide(color: border),
            bottom: BorderSide(color: border),
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              left: 6,
              top: 4,
              child: Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: isToday
                    ? BoxDecoration(color: primary, shape: BoxShape.circle)
                    : null,
                child: Text(
                  '${date.day}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isToday ? Colors.white : numColor,
                  ),
                ),
              ),
            ),
            if (hidden > 0)
              Positioned(
                right: 6,
                bottom: 2,
                child: Text(
                  '+$hidden',
                  style: TextStyle(fontSize: 10, color: hint),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TaskBar extends StatelessWidget {
  final Task task;
  final bool roundLeft;
  final bool roundRight;
  final VoidCallback onTap;
  const _TaskBar({
    required this.task,
    required this.roundLeft,
    required this.roundRight,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final done = task.status == TaskStatus.done;
    final color = done ? const Color(0xFF90A4AE) : taskDisplayColor(task);
    return Tooltip(
      message: '${task.key ?? ''} ${task.title}'.trim(),
      child: InkWell(
        onTap: onTap,
        child: Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.22),
            borderRadius: BorderRadius.horizontal(
              left: Radius.circular(roundLeft ? 4 : 0),
              right: Radius.circular(roundRight ? 4 : 0),
            ),
          ),
          child: Text(
            task.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color.lerp(color, Colors.black, 0.45),
              decoration: done ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _DayPanel extends StatelessWidget {
  final DateTime date;
  final List<Task> tasks;
  final ValueChanged<Task> onOpen;
  const _DayPanel({
    required this.date,
    required this.tasks,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${formatYmd(date)} (${kWeekdayLabels[date.weekday % 7]})',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(
            '해당 일의 업무 ${tasks.length}건',
            style: TextStyle(color: hint, fontSize: 12),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: tasks.isEmpty
                ? Center(
                    child: Text('업무가 없습니다.', style: TextStyle(color: hint)),
                  )
                : MutedScrollbar(
                    child: ListView.separated(
                      itemCount: tasks.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 4),
                      itemBuilder: (context, i) {
                        final t = tasks[i];
                        final r = taskRange(t)!;
                        return InkWell(
                          onTap: () => onOpen(t),
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 3,
                                  height: 34,
                                  margin: const EdgeInsets.only(right: 10),
                                  decoration: BoxDecoration(
                                    color: taskDisplayColor(t),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        t.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          decoration:
                                              t.status == TaskStatus.done
                                              ? TextDecoration.lineThrough
                                              : null,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        r.$1 == r.$2
                                            ? formatMd(r.$1)
                                            : '${formatMd(r.$1)} ~ ${formatMd(r.$2)}',
                                        style: TextStyle(
                                          color: hint,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
