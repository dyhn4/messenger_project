import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/muted_scrollbar.dart';
import '../../widgets/user_avatar.dart';
import 'task_views.dart';

AppUser? _memberById(List<AppUser> members, String? id) =>
    id == null ? null : members.where((m) => m.id == id).firstOrNull;

// ───────────────────────── 칸반보드 ─────────────────────────

/// 상태(할 일/진행 중/완료)별 열에 업무 카드를 늘어놓고, 카드를 다른 열로 끌어다 놓으면 상태가
/// 바뀐다. 실제 저장은 [onStatusChange]가 한다(호출한 화면이 서버에 반영하고 다시 불러온다).
class TaskKanbanView extends StatelessWidget {
  final List<Task> tasks;
  final List<AppUser> members;
  final Session session;
  final ValueChanged<Task> onOpen;
  final void Function(Task task, TaskStatusDef status) onStatusChange;

  /// 프로젝트의 상태 목록 = 칸반의 열(왼쪽부터 순서대로).
  final List<TaskStatusDef> statuses;

  /// true면 카드를 끌어서 옮길 수 없다(종료된 프로젝트).
  final bool readOnly;

  const TaskKanbanView({
    super.key,
    required this.statuses,
    this.readOnly = false,
    required this.tasks,
    required this.members,
    required this.session,
    required this.onOpen,
    required this.onStatusChange,
  });

  /// 업무가 속한 열의 상태 id — 상태 id가 없거나 지워졌다면 같은 분류의 첫 상태로 본다.
  String? _columnOf(Task t) {
    if (t.statusId != null && statuses.any((s) => s.id == t.statusId)) {
      return t.statusId;
    }
    for (final s in statuses) {
      if (s.category == t.status) return s.id;
    }
    return statuses.isEmpty ? null : statuses.first.id;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        const minColumn = 240.0;
        final n = statuses.length;
        final avail = constraints.maxWidth - 48;
        final fitted = n == 0 ? avail : (avail - gap * (n - 1)) / n;
        final columnWidth = fitted < minColumn ? minColumn : fitted;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
          child: SizedBox(
            height: constraints.maxHeight - 36,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final status in statuses) ...[
                  SizedBox(
                    width: columnWidth,
                    child: _KanbanColumn(
                      readOnly: readOnly,
                      status: status,
                      tasks: [
                        for (final t in tasks)
                          if (_columnOf(t) == status.id) t,
                      ],
                      members: members,
                      session: session,
                      onOpen: onOpen,
                      onDrop: (task) => onStatusChange(task, status),
                    ),
                  ),
                  if (status != statuses.last) const SizedBox(width: gap),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _KanbanColumn extends StatefulWidget {
  final TaskStatusDef status;
  final List<Task> tasks;
  final List<AppUser> members;
  final Session session;
  final ValueChanged<Task> onOpen;
  final ValueChanged<Task> onDrop;

  final bool readOnly;

  const _KanbanColumn({
    this.readOnly = false,
    required this.status,
    required this.tasks,
    required this.members,
    required this.session,
    required this.onOpen,
    required this.onDrop,
  });

  @override
  State<_KanbanColumn> createState() => _KanbanColumnState();
}

class _KanbanColumnState extends State<_KanbanColumn> {
  // 열이 세 개라 기본(Primary) 스크롤 컨트롤러를 같이 쓰면 "여러 위치에 붙었다"는 오류가 난다 —
  // 열마다 자기 컨트롤러를 갖는다.
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  TaskStatusDef get status => widget.status;
  List<Task> get tasks => widget.tasks;
  List<AppUser> get members => widget.members;
  Session get session => widget.session;
  ValueChanged<Task> get onOpen => widget.onOpen;
  ValueChanged<Task> get onDrop => widget.onDrop;
  bool get readOnly => widget.readOnly;

  @override
  Widget build(BuildContext context) {
    final color = parseTypeColor(status.color);
    return DragTarget<Task>(
      onWillAcceptWithDetails: (d) => !readOnly && d.data.statusId != status.id,
      onAcceptWithDetails: (d) => onDrop(d.data),
      builder: (context, candidate, _) {
        final hovering = candidate.isNotEmpty;
        return Container(
          decoration: BoxDecoration(
            color: hovering
                ? color.withValues(alpha: 0.10)
                : Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: hovering ? color : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      status.name,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${tasks.length}',
                      style: TextStyle(color: Theme.of(context).hintColor),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: tasks.isEmpty
                    ? Center(
                        child: Text(
                          '업무를 여기로 끌어다 놓으세요',
                          style: TextStyle(
                            color: Theme.of(context).hintColor,
                            fontSize: 12,
                          ),
                        ),
                      )
                    : MutedScrollbar(
                        controller: _scroll,
                        child: ListView.separated(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                          itemCount: tasks.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, i) => _KanbanCard(
                            readOnly: readOnly,
                            task: tasks[i],
                            assignee: _memberById(members, tasks[i].assigneeId),
                            session: session,
                            onTap: () => onOpen(tasks[i]),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _KanbanCard extends StatelessWidget {
  final Task task;
  final AppUser? assignee;
  final Session session;
  final VoidCallback onTap;
  final bool readOnly;

  const _KanbanCard({
    this.readOnly = false,
    required this.task,
    required this.assignee,
    required this.session,
    required this.onTap,
  });

  Widget _card(BuildContext context, {bool dragging = false}) {
    final hint = Theme.of(context).hintColor;
    final done = task.status == TaskStatus.done;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: dragging ? 8 : 0,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
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
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                const Spacer(),
                TaskPill(
                  taskPriorityLabel(task.priority),
                  taskPriorityColor(task.priority),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              task.title,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                decoration: done ? TextDecoration.lineThrough : null,
                color: done ? hint : null,
              ),
            ),
            if (task.typeName != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TaskPill(task.typeName!, parseTypeColor(task.typeColor)),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.event_outlined, size: 13, color: hint),
                const SizedBox(width: 4),
                Text(
                  task.dueDate == null ? '마감일 없음' : formatYmd(task.dueDate!),
                  style: TextStyle(
                    fontSize: 11,
                    color: task.isOverdue ? Colors.redAccent : hint,
                  ),
                ),
                if (task.isOverdue) ...[
                  const SizedBox(width: 4),
                  TaskPill('D+${-(task.daysUntilDue ?? 0)}', Colors.redAccent),
                ],
                const Spacer(),
                if (assignee != null)
                  Tooltip(
                    message: assignee!.name,
                    child: UserAvatar(
                      user: assignee!,
                      resolveUrl: session.resolveUrl,
                      radius: 10,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Draggable<Task>(
      maxSimultaneousDrags: readOnly ? 0 : 1,
      data: task,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: SizedBox(
        width: 240,
        child: Opacity(opacity: 0.92, child: _card(context, dragging: true)),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: _card(context)),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: GestureDetector(onTap: onTap, child: _card(context)),
      ),
    );
  }
}

// ───────────────────────── 간트차트 ─────────────────────────

/// 업무를 시작일~마감일 막대로 늘어놓은 타임라인. 왼쪽에 업무 이름이 고정되고 오른쪽만 가로로
/// 스크롤된다. 일정이 없는 업무는 맨 아래에 이름만 나온다.
class TaskGanttView extends StatefulWidget {
  final List<Task> tasks;
  final ValueChanged<Task> onOpen;
  const TaskGanttView({super.key, required this.tasks, required this.onOpen});

  @override
  State<TaskGanttView> createState() => _TaskGanttViewState();
}

class _TaskGanttViewState extends State<TaskGanttView> {
  static const _leftW = 240.0;
  static const _rowH = 36.0;
  static const _headerH = 52.0;

  final _bodyH = ScrollController();
  final _headH = ScrollController();
  bool _dayZoom = true;

  double get _dayW => _dayZoom ? 32 : 12;

  @override
  void initState() {
    super.initState();
    _bodyH.addListener(() {
      if (_headH.hasClients && _headH.offset != _bodyH.offset) {
        _headH.jumpTo(_bodyH.offset);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToToday());
  }

  @override
  void dispose() {
    _bodyH.dispose();
    _headH.dispose();
    super.dispose();
  }

  late DateTime _minDate;
  late DateTime _maxDate;

  void _computeRange(List<Task> scheduled) {
    final today = dateOnly(DateTime.now());
    var lo = today;
    var hi = today;
    for (final t in scheduled) {
      final r = taskRange(t)!;
      if (r.$1.isBefore(lo)) lo = r.$1;
      if (r.$2.isAfter(hi)) hi = r.$2;
    }
    lo = lo.subtract(const Duration(days: 7));
    hi = hi.add(const Duration(days: 21));
    // 일요일에 맞추고, 적어도 8주는 보이게.
    lo = lo.subtract(Duration(days: lo.weekday % 7));
    if (hi.difference(lo).inDays < 56) hi = lo.add(const Duration(days: 56));
    _minDate = lo;
    _maxDate = hi;
  }

  void _scrollToToday() {
    if (!mounted || !_bodyH.hasClients) return;
    final today = dateOnly(DateTime.now());
    final x = today.difference(_minDate).inDays * _dayW - 160;
    _bodyH.jumpTo(x.clamp(0, _bodyH.position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final scheduled = [
      for (final t in widget.tasks)
        if (taskRange(t) != null) t,
    ]..sort((a, b) => taskRange(a)!.$1.compareTo(taskRange(b)!.$1));
    final unscheduled = [
      for (final t in widget.tasks)
        if (taskRange(t) == null) t,
    ];
    _computeRange(scheduled);
    final days = _maxDate.difference(_minDate).inDays + 1;
    final gridW = days * _dayW;
    final hint = Theme.of(context).hintColor;
    final border = Theme.of(context).dividerColor;
    final today = dateOnly(DateTime.now());

    if (widget.tasks.isEmpty) {
      return Center(
        child: Text('업무가 없습니다.', style: TextStyle(color: hint)),
      );
    }

    Widget label(Task t) => InkWell(
      onTap: () => widget.onOpen(t),
      child: Container(
        height: _rowH,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: border)),
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: taskDisplayColor(t),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            if (t.key != null)
              Text(
                t.key!,
                style: const TextStyle(
                  color: Color(0xFF5B8DEF),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                t.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  decoration: t.status == TaskStatus.done
                      ? TextDecoration.lineThrough
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // 위쪽 날짜 눈금(월 줄 + 일 줄).
    Widget header() {
      final months = <Widget>[];
      var d = _minDate;
      while (!d.isAfter(_maxDate)) {
        final monthEnd = DateTime(d.year, d.month + 1, 0);
        final end = monthEnd.isAfter(_maxDate) ? _maxDate : monthEnd;
        final span = end.difference(d).inDays + 1;
        months.add(
          Container(
            width: span * _dayW,
            height: _headerH / 2,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 8),
            decoration: BoxDecoration(
              border: Border(
                right: BorderSide(color: border),
                bottom: BorderSide(color: border),
              ),
            ),
            child: Text(
              '${d.year}년 ${d.month}월',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        );
        d = end.add(const Duration(days: 1));
      }
      return SizedBox(
        width: gridW,
        height: _headerH,
        child: Column(
          children: [
            Row(children: months),
            SizedBox(
              height: _headerH / 2,
              child: Row(
                children: [
                  for (var i = 0; i < days; i++)
                    Builder(
                      builder: (context) {
                        final date = _minDate.add(Duration(days: i));
                        final isSun = date.weekday == DateTime.sunday;
                        final show = _dayZoom || isSun;
                        return Container(
                          width: _dayW,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: date == today
                                ? Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.15)
                                : null,
                            border: Border(right: BorderSide(color: border)),
                          ),
                          child: show
                              ? Text(
                                  '${date.day}',
                                  overflow: TextOverflow.visible,
                                  softWrap: false,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: isSun
                                        ? Colors.redAccent
                                        : (date.weekday == DateTime.saturday
                                              ? Colors.blueAccent
                                              : null),
                                  ),
                                )
                              : null,
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    Widget bar(Task t) {
      final r = taskRange(t)!;
      final left = r.$1.difference(_minDate).inDays * _dayW;
      final width = (r.$2.difference(r.$1).inDays + 1) * _dayW;
      final done = t.status == TaskStatus.done;
      final color = done ? const Color(0xFF90A4AE) : taskDisplayColor(t);
      return Positioned(
        left: left + 1,
        top: 7,
        width: width - 2,
        height: _rowH - 14,
        child: Tooltip(
          message: '${t.title}\n${formatYmd(r.$1)} ~ ${formatYmd(r.$2)}',
          child: InkWell(
            onTap: () => widget.onOpen(t),
            child: Container(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: done ? 0.45 : 0.85),
                borderRadius: BorderRadius.circular(4),
              ),
              child: width > 60
                  ? Text(
                      t.title,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : null,
            ),
          ),
        ),
      );
    }

    final rows = scheduled.length + unscheduled.length;
    final todayX = today.difference(_minDate).inDays * _dayW + _dayW / 2;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              OutlinedButton(
                onPressed: _scrollToToday,
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
                  ButtonSegment(value: true, label: Text('일')),
                  ButtonSegment(value: false, label: Text('주')),
                ],
                selected: {_dayZoom},
                onSelectionChanged: (s) {
                  setState(() => _dayZoom = s.first);
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _scrollToToday(),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: border),
                borderRadius: BorderRadius.circular(10),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: _leftW,
                        height: _headerH,
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.only(left: 12),
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLow,
                        child: Text(
                          '업무',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: hint,
                          ),
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          controller: _headH,
                          scrollDirection: Axis.horizontal,
                          physics: const NeverScrollableScrollPhysics(),
                          child: header(),
                        ),
                      ),
                    ],
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: _leftW,
                            child: Column(
                              children: [
                                for (final t in scheduled) label(t),
                                for (final t in unscheduled) label(t),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Scrollbar(
                              controller: _bodyH,
                              child: SingleChildScrollView(
                                controller: _bodyH,
                                scrollDirection: Axis.horizontal,
                                child: SizedBox(
                                  width: gridW,
                                  height: rows * _rowH,
                                  child: Stack(
                                    children: [
                                      Positioned.fill(
                                        child: CustomPaint(
                                          painter: _GanttGridPainter(
                                            minDate: _minDate,
                                            days: days,
                                            dayW: _dayW,
                                            rowH: _rowH,
                                            rows: rows,
                                            lineColor: border,
                                            weekendColor: Theme.of(
                                              context,
                                            ).colorScheme.surfaceContainerLow,
                                          ),
                                        ),
                                      ),
                                      for (var i = 0; i < scheduled.length; i++)
                                        Positioned(
                                          top: i * _rowH,
                                          left: 0,
                                          right: 0,
                                          height: _rowH,
                                          child: Stack(
                                            children: [bar(scheduled[i])],
                                          ),
                                        ),
                                      Positioned(
                                        left: todayX - 1,
                                        top: 0,
                                        bottom: 0,
                                        width: 2,
                                        child: ColoredBox(
                                          color: Colors.redAccent.withValues(
                                            alpha: 0.7,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GanttGridPainter extends CustomPainter {
  final DateTime minDate;
  final int days;
  final double dayW;
  final double rowH;
  final int rows;
  final Color lineColor;
  final Color weekendColor;
  const _GanttGridPainter({
    required this.minDate,
    required this.days,
    required this.dayW,
    required this.rowH,
    required this.rows,
    required this.lineColor,
    required this.weekendColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final weekend = Paint()..color = weekendColor;
    for (var i = 0; i < days; i++) {
      final wd = minDate.add(Duration(days: i)).weekday;
      if (wd == DateTime.saturday || wd == DateTime.sunday) {
        canvas.drawRect(Rect.fromLTWH(i * dayW, 0, dayW, size.height), weekend);
      }
    }
    final line = Paint()
      ..color = lineColor
      ..strokeWidth = 1;
    for (var r = 1; r <= rows; r++) {
      canvas.drawLine(Offset(0, r * rowH), Offset(size.width, r * rowH), line);
    }
  }

  @override
  bool shouldRepaint(_GanttGridPainter old) =>
      old.days != days ||
      old.dayW != dayW ||
      old.rows != rows ||
      old.minDate != minDate;
}

// ───────────────────────── 대시보드 ─────────────────────────

/// 프로젝트 전체 진행 현황 — 상태·우선순위·유형·담당자별 집계와 마감 임박 업무.
class TaskDashboardView extends StatelessWidget {
  final List<Task> tasks;
  final List<AppUser> members;
  final Session session;
  final ValueChanged<Task> onOpen;

  /// 프로젝트 상태 목록 — 주면 "상태별 업무"가 이 상태들로 나뉜다(없으면 세 분류).
  final List<TaskStatusDef>? statuses;

  const TaskDashboardView({
    super.key,
    this.statuses,
    required this.tasks,
    required this.members,
    required this.session,
    required this.onOpen,
  });

  String? _firstOfCategory(TaskStatus c) {
    for (final s in statuses ?? const <TaskStatusDef>[]) {
      if (s.category == c) return s.id;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final total = tasks.length;
    final done = tasks.where((t) => t.status == TaskStatus.done).length;
    final doing = tasks.where((t) => t.status == TaskStatus.doing).length;
    final overdue = tasks.where((t) => t.isOverdue).length;
    final percent = total == 0 ? 0 : (done / total * 100).round();

    Widget stat(String label, int value, Color color) => Container(
      width: 170,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: hint, fontSize: 12)),
          const SizedBox(height: 6),
          Text(
            '$value',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );

    Widget card(String title, Widget child, {double width = 360}) => Container(
      width: width,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );

    /// 라벨 + 막대 + 개수 한 줄.
    Widget barRow(
      String label,
      int count,
      int max,
      Color color, {
      Widget? lead,
    }) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            SizedBox(
              width: 110,
              child: Row(
                children: [
                  if (lead != null) ...[lead, const SizedBox(width: 6)],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: max == 0 ? 0 : count / max,
                  minHeight: 10,
                  color: color,
                  backgroundColor: color.withValues(alpha: 0.12),
                ),
              ),
            ),
            SizedBox(
              width: 32,
              child: Text(
                '$count',
                textAlign: TextAlign.end,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    // 유형별
    final byType = <String, (int, Color)>{};
    for (final t in tasks) {
      final key = t.typeName ?? '유형 없음';
      final color = t.typeColor != null
          ? parseTypeColor(t.typeColor)
          : const Color(0xFF90A4AE);
      final prev = byType[key];
      byType[key] = ((prev?.$1 ?? 0) + 1, color);
    }
    // 담당자별
    final byAssignee = <String?, List<Task>>{};
    for (final t in tasks) {
      (byAssignee[t.assigneeId] ??= []).add(t);
    }
    final assigneeRows = byAssignee.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    final soon = [
      for (final t in tasks)
        if (t.status != TaskStatus.done &&
            t.dueDate != null &&
            (t.daysUntilDue ?? 99) <= 7)
          t,
    ]..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));

    return MutedScrollbar(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              stat('전체 업무', total, Theme.of(context).colorScheme.primary),
              stat('완료', done, taskStatusColor(TaskStatus.done)),
              stat('진행 중', doing, taskStatusColor(TaskStatus.doing)),
              stat('지연', overdue, Colors.redAccent),
              Container(
                width: 260,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('진행률', style: TextStyle(color: hint, fontSize: 12)),
                    const SizedBox(height: 6),
                    Text(
                      '$percent%',
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: total == 0 ? 0 : done / total,
                        minHeight: 8,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.start,
            children: [
              card(
                '상태별 업무',
                Column(
                  children: [
                    if (statuses != null && statuses!.isNotEmpty)
                      for (final s in statuses!)
                        barRow(
                          s.name,
                          tasks
                              .where(
                                (t) =>
                                    t.statusId == s.id ||
                                    (t.statusId == null &&
                                        t.status == s.category &&
                                        s.id == _firstOfCategory(s.category)),
                              )
                              .length,
                          total,
                          parseTypeColor(s.color),
                        )
                    else
                      for (final s in TaskStatus.values)
                        barRow(
                          taskStatusLabel(s),
                          tasks.where((t) => t.status == s).length,
                          total,
                          taskStatusColor(s),
                        ),
                  ],
                ),
              ),
              card(
                '우선순위별 업무',
                Column(
                  children: [
                    for (final p in TaskPriority.values.reversed)
                      barRow(
                        taskPriorityLabel(p),
                        tasks.where((t) => t.priority == p).length,
                        total,
                        taskPriorityColor(p),
                      ),
                  ],
                ),
              ),
              card(
                '유형별 업무',
                byType.isEmpty
                    ? Text('업무가 없습니다.', style: TextStyle(color: hint))
                    : Column(
                        children: [
                          for (final e in byType.entries)
                            barRow(e.key, e.value.$1, total, e.value.$2),
                        ],
                      ),
              ),
              card(
                '담당자별 업무',
                assigneeRows.isEmpty
                    ? Text('업무가 없습니다.', style: TextStyle(color: hint))
                    : Column(
                        children: [
                          for (final e in assigneeRows)
                            Builder(
                              builder: (context) {
                                final user = _memberById(members, e.key);
                                return barRow(
                                  user?.name ?? '담당자 없음',
                                  e.value.length,
                                  math.max(1, assigneeRows.first.value.length),
                                  Theme.of(context).colorScheme.primary,
                                  lead: user == null
                                      ? const Icon(
                                          Icons.person_outline,
                                          size: 16,
                                        )
                                      : UserAvatar(
                                          user: user,
                                          resolveUrl: session.resolveUrl,
                                          radius: 8,
                                        ),
                                );
                              },
                            ),
                        ],
                      ),
              ),
              card(
                '마감 임박·지연 업무',
                soon.isEmpty
                    ? Text(
                        '7일 안에 마감이거나 지연된 업무가 없습니다.',
                        style: TextStyle(color: hint, fontSize: 12),
                      )
                    : Column(
                        children: [
                          for (final t in soon.take(6))
                            InkWell(
                              onTap: () => onOpen(t),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 6,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        t.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      formatMd(t.dueDate!),
                                      style: TextStyle(
                                        color: hint,
                                        fontSize: 11,
                                      ),
                                    ),
                                    if (t.isOverdue) ...[
                                      const SizedBox(width: 6),
                                      TaskPill(
                                        'D+${-(t.daysUntilDue ?? 0)}',
                                        Colors.redAccent,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                width: 360,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
