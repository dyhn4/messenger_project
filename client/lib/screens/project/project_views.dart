import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/floating_dialog.dart';
import '../../widgets/muted_scrollbar.dart';
import '../../widgets/user_avatar.dart';
import 'task_filter.dart';
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

/// 프로젝트 "대시보드" — 숫자 카드 네 장(전체/완료/진행 중/지연), 전체 완료율, 멤버별 업무현황.
/// 숫자 카드를 누르면 [onStatTap]으로 리스트 탭에 그 조건을 걸어달라고 알린다.
class TaskDashboardView extends StatelessWidget {
  final List<Task> tasks;
  final List<AppUser> members;
  final Session session;
  final ValueChanged<Task> onOpen;
  final void Function(QuickFilter? quick) onStatTap;

  const TaskDashboardView({
    super.key,
    required this.tasks,
    required this.members,
    required this.session,
    required this.onOpen,
    required this.onStatTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final total = tasks.length;
    final done = tasks.where((t) => t.status == TaskStatus.done).length;
    final doing = total - done;
    final overdue = tasks.where((t) => t.isOverdue).length;
    int pct(int n) => total == 0 ? 0 : (n / total * 100).round();

    Widget box({required Widget child, EdgeInsets? padding}) => Container(
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );

    Widget stat(
      String label,
      int value,
      Color dot,
      Color? number,
      QuickFilter? quick,
    ) => Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onStatTap(quick),
        child: box(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: dot,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(label, style: TextStyle(color: hint, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '$value',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  color: number,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    Widget legend(String label, int value, Color color) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(label),
          const Spacer(),
          Text(
            '${pct(value)}%',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );

    final doneColor = theme.colorScheme.primary;
    const doingColor = Color(0xFF2E9E6B);
    const overdueColor = Colors.redAccent;

    return MutedScrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 스크롤 안이라 높이가 무한이다 — stretch를 쓰면 안 되고, 네 카드는 내용이 같아 어차피 키가 같다.
            Row(
              children: [
                stat('전체 업무', total, doneColor, null, null),
                const SizedBox(width: 12),
                stat('완료', done, doneColor, doneColor, QuickFilter.done),
                const SizedBox(width: 12),
                stat(
                  '진행 중',
                  doing,
                  doneColor,
                  doingColor,
                  QuickFilter.incomplete,
                ),
                const SizedBox(width: 12),
                stat(
                  '지연',
                  overdue,
                  overdueColor,
                  overdueColor,
                  QuickFilter.overdue,
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 300,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: box(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '전체 완료율',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Expanded(
                            child: Row(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 150,
                                    height: 150,
                                    child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        SizedBox.expand(
                                          child: CircularProgressIndicator(
                                            value: total == 0
                                                ? 0
                                                : done / total,
                                            strokeWidth: 16,
                                            strokeCap: StrokeCap.round,
                                            backgroundColor: theme
                                                .colorScheme
                                                .surfaceContainerHighest,
                                          ),
                                        ),
                                        Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              '${pct(done)}%',
                                              style: const TextStyle(
                                                fontSize: 26,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            Text(
                                              '전체 완료율',
                                              style: TextStyle(
                                                color: hint,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      legend('완료', done, doneColor),
                                      legend('진행 중', doing, doingColor),
                                      legend('지연', overdue, overdueColor),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: box(
                      // 오른쪽 여백은 안쪽 목록이 갖는다 — 그래야 스크롤바가 카드
                      // 오른쪽 선에 붙고 담당 수("2/5")를 가리지 않는다.
                      padding: const EdgeInsets.fromLTRB(16, 16, 0, 16),
                      child: _MemberWorkload(
                        members: members,
                        tasks: tasks,
                        session: session,
                        onOpen: onOpen,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 멤버별 담당 업무 현황 — 카드 안에는 몇 명만 보이고, "전체보기"로 전부 본다.
class _MemberWorkload extends StatefulWidget {
  final List<AppUser> members;
  final List<Task> tasks;
  final Session session;
  final ValueChanged<Task> onOpen;
  const _MemberWorkload({
    required this.members,
    required this.tasks,
    required this.session,
    required this.onOpen,
  });

  @override
  State<_MemberWorkload> createState() => _MemberWorkloadState();
}

class _MemberWorkloadState extends State<_MemberWorkload> {
  // 대시보드 전체가 이미 스크롤되고 있어서, 이 목록은 자기 컨트롤러를 가져야
  // 스크롤바가 제대로 붙는다.
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Row(
            children: [
              const Text(
                '멤버별 업무현황',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => showMemberWorkloadDialog(
                  context,
                  session: widget.session,
                  members: widget.members,
                  tasks: widget.tasks,
                  onOpen: widget.onOpen,
                ),
                child: const Text('전체보기'),
              ),
            ],
          ),
        ),
        Expanded(
          child: widget.members.isEmpty
              ? Center(
                  child: Text(
                    '프로젝트 멤버가 없습니다.',
                    style: TextStyle(color: hint, fontSize: 12),
                  ),
                )
              : MutedScrollbar(
                  controller: _scroll,
                  child: ListView(
                    controller: _scroll,
                    // 스크롤바(10px)가 담당 수를 덮지 않도록 내용만 안쪽으로 들인다.
                    padding: const EdgeInsets.only(right: 16),
                    children: [
                      for (final m in widget.members.take(5))
                        memberWorkloadRow(
                          context,
                          m,
                          widget.tasks,
                          widget.session,
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// 멤버 한 줄 — 아바타·이름과 담당 업무의 완료/전체, 그리고 진행 막대.
Widget memberWorkloadRow(
  BuildContext context,
  AppUser member,
  List<Task> tasks,
  Session session, {
  VoidCallback? onTap,
  bool selected = false,
}) {
  final hint = Theme.of(context).hintColor;
  final mine = tasks.where((t) => t.assigneeId == member.id).toList();
  final done = mine.where((t) => t.status == TaskStatus.done).length;
  return ListTile(
    dense: true,
    selected: selected,
    contentPadding: EdgeInsets.zero,
    onTap: onTap,
    leading: UserAvatar(
      user: member,
      resolveUrl: session.resolveUrl,
      radius: 14,
    ),
    title: Text(member.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: mine.isEmpty
        ? Text('담당 업무 없음', style: TextStyle(color: hint, fontSize: 11))
        : ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: done / mine.length,
              minHeight: 5,
            ),
          ),
    trailing: Text(
      '$done/${mine.length}',
      style: TextStyle(color: hint, fontSize: 12),
    ),
  );
}

/// "전체보기" — 왼쪽에서 멤버를 고르면 오른쪽에 그 멤버의 담당 업무가 뜬다.
Future<void> showMemberWorkloadDialog(
  BuildContext context, {
  required Session session,
  required List<AppUser> members,
  required List<Task> tasks,
  required ValueChanged<Task> onOpen,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _MemberWorkloadDialog(
      session: session,
      members: members,
      tasks: tasks,
      onOpen: onOpen,
    ),
  );
}

class _MemberWorkloadDialog extends StatefulWidget {
  final Session session;
  final List<AppUser> members;
  final List<Task> tasks;
  final ValueChanged<Task> onOpen;
  const _MemberWorkloadDialog({
    required this.session,
    required this.members,
    required this.tasks,
    required this.onOpen,
  });

  @override
  State<_MemberWorkloadDialog> createState() => _MemberWorkloadDialogState();
}

class _MemberWorkloadDialogState extends State<_MemberWorkloadDialog> {
  String? _selectedId;
  final _left = ScrollController();
  final _right = ScrollController();

  @override
  void dispose() {
    _left.dispose();
    _right.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = widget.members
        .where((m) => m.id == _selectedId)
        .firstOrNull;
    final mine = selected == null
        ? const <Task>[]
        : [
            for (final t in widget.tasks)
              if (t.assigneeId == selected.id) t,
          ];
    return FloatingDialog(
      title: '멤버별 업무현황 — 전체보기',
      maxWidth: 900,
      maxHeight: 600,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '멤버를 선택하면 해당 멤버의 업무 상세를 확인할 수 있어요.',
            style: TextStyle(color: theme.hintColor, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 280,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '멤버 ${widget.members.length}명',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Expanded(
                        child: MutedScrollbar(
                          controller: _left,
                          child: ListView(
                            controller: _left,
                            padding: const EdgeInsets.only(right: 14),
                            children: [
                              for (final m in widget.members)
                                memberWorkloadRow(
                                  context,
                                  m,
                                  widget.tasks,
                                  widget.session,
                                  selected: m.id == _selectedId,
                                  onTap: () =>
                                      setState(() => _selectedId = m.id),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 24),
                Expanded(
                  child: selected == null
                      ? const SizedBox.shrink()
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              '${selected.name} · 담당 업무 ${mine.length}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Expanded(
                              child: mine.isEmpty
                                  ? Center(
                                      child: Text(
                                        '담당한 업무가 없습니다.',
                                        style: TextStyle(
                                          color: theme.hintColor,
                                        ),
                                      ),
                                    )
                                  : MutedScrollbar(
                                      controller: _right,
                                      child: ListView.separated(
                                        controller: _right,
                                        padding: const EdgeInsets.only(
                                          right: 14,
                                        ),
                                        itemCount: mine.length,
                                        separatorBuilder: (_, _) =>
                                            const Divider(height: 1),
                                        itemBuilder: (context, i) {
                                          final t = mine[i];
                                          return ListTile(
                                            dense: true,
                                            contentPadding: EdgeInsets.zero,
                                            title: Text(
                                              t.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            subtitle: Text(
                                              [
                                                ?t.key,
                                                t.statusLabel,
                                                if (t.dueDate != null)
                                                  formatYmd(t.dueDate!),
                                              ].join(' · '),
                                              style: TextStyle(
                                                color: theme.hintColor,
                                                fontSize: 11,
                                              ),
                                            ),
                                            trailing: TaskPill(
                                              t.priorityLabel,
                                              taskPriorityDisplayColor(t),
                                            ),
                                            onTap: () {
                                              Navigator.of(context).pop();
                                              widget.onOpen(t);
                                            },
                                          );
                                        },
                                      ),
                                    ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
