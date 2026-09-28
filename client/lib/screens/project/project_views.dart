import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/floating_dialog.dart';
import '../../widgets/muted_scrollbar.dart';
import '../../widgets/user_avatar.dart';
import 'task_filter.dart';
import 'task_views.dart';
import '../../widgets/grab_cursors.dart';

AppUser? _memberById(List<AppUser> members, String? id) =>
    id == null ? null : members.where((m) => m.id == id).firstOrNull;

// ───────────────────────── 칸반보드 ─────────────────────────

/// 상태(할 일/진행 중/완료)별 열에 업무 카드를 늘어놓는다. 카드를 다른 열로 끌어다 놓으면 상태가
/// 바뀌고, 같은 열 안에서 위아래로 끌면 순서가 바뀐다. 실제 저장은 [onMove]가 한다(호출한 화면이
/// 서버에 반영하고 다시 불러온다) — 그동안은 옮긴 모습을 먼저 보여준다.
class TaskKanbanView extends StatefulWidget {
  final List<Task> tasks;
  final List<AppUser> members;
  final Session session;
  final ValueChanged<Task> onOpen;

  /// 카드를 놓았을 때 — 다른 열이면 [newStatus]가 그 열의 상태, 같은 열 안에서 옮겼으면 null.
  /// [orderedIds]는 놓은 뒤 그 열의 업무 id(위에서부터).
  final Future<void> Function(
    Task task,
    TaskStatusDef? newStatus,
    List<String> orderedIds,
  )
  onMove;

  /// 열 머리의 "+"와 열 아래 "+ 업무 추가" — 그 상태로 새 업무를 만든다. null이면 버튼을 숨긴다.
  final ValueChanged<TaskStatusDef>? onAdd;

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
    required this.onMove,
    this.onAdd,
  });

  /// 열 너비 — 화면 폭과 상관없이 고정이고, 열이 많으면 옆으로 스크롤한다.
  static const columnWidth = 280.0;

  @override
  State<TaskKanbanView> createState() => _TaskKanbanViewState();
}

class _TaskKanbanViewState extends State<TaskKanbanView> {
  /// 서버 반영을 기다리는 동안 먼저 보여줄 모습 — 옮긴 업무의 새 열, 열별 새 순서.
  final _statusOverride = <String, String>{};
  final _orderOverride = <String, List<String>>{};

  List<TaskStatusDef> get statuses => widget.statuses;

  /// 업무가 속한 열의 상태 id — 상태 id가 없거나 지워졌다면 같은 분류의 첫 상태로 본다.
  String? _columnOf(Task t) {
    final moved = _statusOverride[t.id];
    if (moved != null) return moved;
    if (t.statusId != null && statuses.any((s) => s.id == t.statusId)) {
      return t.statusId;
    }
    for (final s in statuses) {
      if (s.category == t.status) return s.id;
    }
    return statuses.isEmpty ? null : statuses.first.id;
  }

  /// 열별 업무 — 저장된 순서(boardPosition)대로, 한 번도 옮기지 않은 업무는 원래 순서로 그 아래.
  Map<String, List<Task>> _columns() {
    final columns = {for (final s in statuses) s.id: <Task>[]};
    final original = <String, int>{};
    for (final (i, t) in widget.tasks.indexed) {
      original[t.id] = i;
      columns[_columnOf(t)]?.add(t);
    }
    const last = 1 << 30;
    for (final MapEntry(key: statusId, value: list) in columns.entries) {
      final order = _orderOverride[statusId];
      int rank(Task t) {
        if (order != null) {
          final i = order.indexOf(t.id);
          return i < 0 ? last : i;
        }
        return t.boardPosition ?? last;
      }

      list.sort((a, b) {
        final c = rank(a).compareTo(rank(b));
        return c != 0 ? c : original[a.id]!.compareTo(original[b.id]!);
      });
    }
    return columns;
  }

  Future<void> _drop(
    Task task,
    TaskStatusDef status,
    List<Task> column,
    int index,
  ) async {
    final others = [
      for (final t in column)
        if (t.id != task.id) t.id,
    ];
    others.insert(index.clamp(0, others.length), task.id);
    final sameColumn = _columnOf(task) == status.id;
    if (sameColumn &&
        others.length == column.length &&
        [for (final t in column) t.id].join(',') == others.join(',')) {
      return; // 제자리에 놓았다.
    }
    setState(() {
      _statusOverride[task.id] = status.id;
      _orderOverride[status.id] = others;
    });
    await widget.onMove(task, sameColumn ? null : status, others);
    // 호출한 화면이 다시 불러온 목록(저장된 순서)으로 돌아간다 — 실패했다면 원래 자리로.
    if (mounted) {
      setState(() {
        _statusOverride.clear();
        _orderOverride.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const gap = 14.0;
    final columns = _columns();
    return LayoutBuilder(
      builder: (context, constraints) {
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
                    width: TaskKanbanView.columnWidth,
                    child: _KanbanColumn(
                      readOnly: widget.readOnly,
                      status: status,
                      tasks: columns[status.id]!,
                      members: widget.members,
                      session: widget.session,
                      onOpen: widget.onOpen,
                      onDrop: (task, index) =>
                          _drop(task, status, columns[status.id]!, index),
                      onAdd: widget.readOnly || widget.onAdd == null
                          ? null
                          : () => widget.onAdd!(status),
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

/// 칸반 열 바탕 — 옅은 회색(어두운 테마에서는 한 단계 밝은 면).
Color _kanbanColumnColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? Theme.of(context).colorScheme.surfaceContainerLow
    : const Color(0xFFF2F3F5);

class _KanbanColumn extends StatefulWidget {
  final TaskStatusDef status;
  final List<Task> tasks;
  final List<AppUser> members;
  final Session session;
  final ValueChanged<Task> onOpen;

  /// 카드를 이 열에 놓았을 때 — [index]는 끌고 있던 카드를 뺀 나머지 중 몇 번째 앞인지.
  final void Function(Task task, int index) onDrop;
  final VoidCallback? onAdd;

  final bool readOnly;

  const _KanbanColumn({
    this.readOnly = false,
    required this.status,
    required this.tasks,
    required this.members,
    required this.session,
    required this.onOpen,
    required this.onDrop,
    this.onAdd,
  });

  @override
  State<_KanbanColumn> createState() => _KanbanColumnState();
}

class _KanbanColumnState extends State<_KanbanColumn> {
  // 열이 세 개라 기본(Primary) 스크롤 컨트롤러를 같이 쓰면 "여러 위치에 붙었다"는 오류가 난다 —
  // 열마다 자기 컨트롤러를 갖는다.
  final _scroll = ScrollController();

  /// 카드 위치를 읽으려고 카드마다 다는 키(놓을 자리 계산).
  final _cardKeys = <String, GlobalKey>{};

  /// 끌고 있는 카드를 놓으면 들어갈 자리 — 끌고 있는 카드를 뺀 나머지 중 몇 번째 앞인지.
  int? _insertAt;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  TaskStatusDef get status => widget.status;
  List<Task> get tasks => widget.tasks;
  bool get readOnly => widget.readOnly;

  GlobalKey _keyOf(Task t) => _cardKeys.putIfAbsent(t.id, GlobalKey.new);

  /// 마우스 높이가 어느 카드들의 가운데보다 아래인지 세어 놓을 자리를 정한다. 스크롤로 안 그려진
  /// 카드는 이미 지나간 위쪽 카드면 센다.
  int _indexAt(Offset global, Task dragged) {
    var index = 0;
    var seenBuilt = false;
    for (final t in tasks) {
      if (t.id == dragged.id) continue;
      final box = _keyOf(t).currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) {
        if (!seenBuilt) index++;
        continue;
      }
      seenBuilt = true;
      final center = box.localToGlobal(box.size.center(Offset.zero)).dy;
      if (global.dy > center) index++;
    }
    return index;
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
      child: Row(
        children: [
          // 오른쪽 "+"만큼 비워 이름·개수가 열 가운데에 오게 한다.
          const SizedBox(width: 40),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    status.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 개수 배지 — 회색 둥근 칸.
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: theme.brightness == Brightness.dark
                        ? theme.colorScheme.surfaceContainerHighest
                        : const Color(0xFFE3E5E8),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${tasks.length}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: theme.hintColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 40,
            height: 40,
            child: widget.onAdd == null
                ? null
                : IconButton(
                    tooltip: '업무 추가',
                    onPressed: widget.onAdd,
                    icon: const Icon(Icons.add, size: 18),
                    color: theme.hintColor,
                    visualDensity: VisualDensity.compact,
                  ),
          ),
        ],
      ),
    );
  }

  /// 열 맨 아래 "+ 업무 추가".
  Widget _addButton(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: widget.onAdd,
        icon: Icon(Icons.add, size: 16, color: hint),
        label: Text('업무 추가', style: TextStyle(color: hint, fontSize: 13)),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      ),
    );
  }

  /// 놓을 자리 표시선 — 카드 사이 틈 가운데에 겹쳐 그려서 카드들이 밀리지 않게 한다.
  Widget _withMarker(Widget card, {bool above = false, bool below = false}) {
    if (!above && !below) return card;
    final line = Container(
      height: 3,
      decoration: BoxDecoration(
        color: const Color(0xFF3B82F6),
        borderRadius: BorderRadius.circular(2),
      ),
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        card,
        if (above) Positioned(left: 4, right: 4, top: -6.5, child: line),
        if (below) Positioned(left: 4, right: 4, bottom: -6.5, child: line),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = parseTypeColor(status.color);
    return DragTarget<Task>(
      onWillAcceptWithDetails: (_) => !readOnly,
      onMove: (d) {
        final i = _indexAt(d.offset, d.data);
        if (i != _insertAt) setState(() => _insertAt = i);
      },
      onLeave: (_) => setState(() => _insertAt = null),
      onAcceptWithDetails: (d) {
        final i = _insertAt ?? _indexAt(d.offset, d.data);
        setState(() => _insertAt = null);
        widget.onDrop(d.data, i);
      },
      builder: (context, candidate, _) {
        final dragged = candidate.firstOrNull;
        // 다른 열에서 끌어온 카드일 때만 열 전체를 강조한다.
        final fromOther =
            dragged != null && !tasks.any((t) => t.id == dragged.id);
        final others = [
          for (final t in tasks)
            if (t.id != dragged?.id) t,
        ];
        final insertAt = dragged == null ? null : _insertAt;
        // 표시선을 붙일 카드 — 그 자리 바로 뒤 카드의 위, 맨 끝이면 마지막 카드의 아래.
        final markAbove = insertAt != null && insertAt < others.length
            ? others[insertAt].id
            : null;
        final markBelow =
            insertAt != null && insertAt >= others.length && others.isNotEmpty
            ? others.last.id
            : null;
        final items = <Widget>[
          for (final t in tasks)
            _withMarker(
              KeyedSubtree(
                key: _keyOf(t),
                child: _KanbanCard(
                  readOnly: readOnly,
                  task: t,
                  assignee: _memberById(widget.members, t.assigneeId),
                  session: widget.session,
                  onTap: () => widget.onOpen(t),
                ),
              ),
              above: t.id == markAbove,
              below: t.id == markBelow,
            ),
          if (tasks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  '업무를 여기로 끌어다 놓으세요',
                  style: TextStyle(
                    color: Theme.of(context).hintColor,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
        ];
        // 열 바탕은 내용(카드 + "업무 추가")만큼만 — 둥근 아래 모서리가 버튼 바로 밑에서 끝난다.
        // 카드가 많으면 화면 높이까지 늘고 그 안에서 스크롤한다. 놓기(DragTarget)는 열 아래 빈
        // 곳까지 전체 높이에서 받는다.
        return Align(
          alignment: Alignment.topCenter,
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: fromOther
                  ? color.withValues(alpha: 0.10)
                  : _kanbanColumnColor(context),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: fromOther ? color : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(context),
                Flexible(
                  child: MutedScrollbar(
                    controller: _scroll,
                    child: ListView.separated(
                      controller: _scroll,
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (_, i) => items[i],
                    ),
                  ),
                ),
                if (widget.onAdd != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 2, 10, 10),
                    child: _addButton(context),
                  )
                else
                  const SizedBox(height: 10),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 카드 윗줄의 작은 꼬리표(유형·우선순위) — 옅은 바탕에 같은 색 글자.
class _KanbanTag extends StatelessWidget {
  final String text;
  final Color color;
  const _KanbanTag(this.text, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(6),
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

/// 칸반 카드 — 윗줄: 유형·우선순위 꼬리표와 (있으면) 댓글 수 / 굵은 제목(두 줄까지) /
/// 아랫줄: 업무 번호(파랑)와 담당자 사진·이름.
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

  /// 열 안쪽 여백(좌우 10)과 테두리를 뺀 카드 폭 — 끌 때 따라다니는 카드도 같은 폭.
  static const width = TaskKanbanView.columnWidth - 23;

  /// 담당자 — 구성원 목록에서 찾고, 없으면(내보낸 사람 등) 업무에 딸려 온 이름·사진으로.
  AppUser? get _assignee {
    if (assignee != null) return assignee;
    final name = task.assigneeName;
    if (task.assigneeId == null || name == null) return null;
    return AppUser(
      id: task.assigneeId!,
      username: name,
      name: name,
      avatarType: task.assigneeAvatarType,
      avatarEmoji: task.assigneeAvatarEmoji,
      avatarColor: task.assigneeAvatarColor,
      avatarUrl: task.assigneeAvatarUrl,
    );
  }

  Widget _card(BuildContext context, {bool dragging = false}) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final user = _assignee;
    return Material(
      color: theme.colorScheme.surface,
      elevation: dragging ? 8 : 0,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: theme.brightness == Brightness.dark
                ? theme.dividerColor
                : const Color(0xFFE4E6EA),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      if (task.typeName != null)
                        _KanbanTag(
                          task.typeName!,
                          parseTypeColor(task.typeColor),
                        ),
                      _KanbanTag(
                        task.priorityLabel,
                        taskPriorityDisplayColor(task),
                      ),
                    ],
                  ),
                ),
                if (task.commentCount > 0) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.chat_bubble_outline, size: 14, color: hint),
                  const SizedBox(width: 3),
                  Text(
                    '${task.commentCount}',
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Text(
              task.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (task.key != null)
                  Text(
                    task.key!,
                    style: const TextStyle(
                      color: Color(0xFF5B9BF0),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                const Spacer(),
                if (user != null)
                  Flexible(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        UserAvatar(
                          user: user,
                          resolveUrl: session.resolveUrl,
                          radius: 10,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            user.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: hint),
                          ),
                        ),
                      ],
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
        width: width,
        child: Opacity(opacity: 0.92, child: _card(context, dragging: true)),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: _card(context)),
      child: MouseRegion(
        cursor: GrabCursors.open,
        child: GestureDetector(onTap: onTap, child: _card(context)),
      ),
    );
  }
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

    return _DashboardScroll(
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
                                          value: total == 0 ? 0 : done / total,
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
    );
  }
}

/// 대시보드 전체 스크롤 — 스크롤바와 스크롤 뷰가 같은 컨트롤러를 쓴다. 데스크톱에서는 스크롤 뷰가
/// PrimaryScrollController에 안 붙어서, 컨트롤러 없이 스크롤바를 달면 디버그 모드에서
/// "ScrollPosition이 없다" 오류가 난다.
class _DashboardScroll extends StatefulWidget {
  final EdgeInsets padding;
  final Widget child;
  const _DashboardScroll({required this.padding, required this.child});

  @override
  State<_DashboardScroll> createState() => _DashboardScrollState();
}

class _DashboardScrollState extends State<_DashboardScroll> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MutedScrollbar(
      controller: _scroll,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: widget.padding,
        child: widget.child,
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
