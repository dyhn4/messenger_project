import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/dashed_add_button.dart';
import '../../widgets/date_drop_calendar.dart';
import '../../widgets/muted_scrollbar.dart';
import '../../widgets/user_avatar.dart';
import 'task_comments_section.dart';
import 'task_views.dart' show formatYmd;

/// 미니 모드일 때의 패널 폭 — 목록과 나란히 두기에 답답하지 않은 선.
const kTaskPanelWidth = 420.0;

/// 업무 상세를 오른쪽에 붙여 보여주는 패널. 예전에는 가운데 팝업(FloatingDialog)이었는데,
/// 목록을 보면서 바로 고칠 수 있도록 패널로 바꿨다. 오른쪽 위 화살표로 창 전체를 덮는
/// 넓은 모드로 바꿀 수 있고, 삼점 메뉴에 복사·이동·보관·삭제가 들어 있다.
class TaskDetailPanel extends StatefulWidget {
  final Session session;
  final String taskId;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final VoidCallback onClose;

  /// 업무를 고쳤을 때 — 뒤에 있는 목록도 다시 읽게 한다.
  final VoidCallback? onChanged;

  /// 하위 업무를 눌렀을 때 그 업무로 갈아타기.
  final ValueChanged<String> onOpenTask;

  const TaskDetailPanel({
    super.key,
    required this.session,
    required this.taskId,
    required this.expanded,
    required this.onToggleExpand,
    required this.onClose,
    required this.onOpenTask,
    this.onChanged,
    this.reloadTick = 0,
  });

  /// 바뀌면 업무를 다시 읽는다 — 패널이 열린 채 뒤 화면(간트차트 막대 끌기, 목록 배지 등)에서
  /// 업무를 고쳤을 때 패널에도 바로 보이게.
  final int reloadTick;

  @override
  State<TaskDetailPanel> createState() => _TaskDetailPanelState();
}

class _TaskDetailPanelState extends State<TaskDetailPanel> {
  Task? _task;
  Project? _project;
  List<TaskStatusDef> _statuses = const [];
  List<TaskPriorityDef> _priorities = const [];
  List<TaskType> _types = const [];
  String? _error;

  final _newChecklist = TextEditingController();
  final _newSubtask = TextEditingController();
  final _scroll = ScrollController();

  /// 상위 업무 id → 제목(상세 응답에 부모 제목이 없어서 한 번 받아와 기억해둔다).
  final _parentTitles = <String, String>{};

  /// 제목/설명을 고쳐 쓰는 중이면 그 입력 컨트롤러.
  TextEditingController? _editingTitle;
  TextEditingController? _editingDescription;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(TaskDetailPanel old) {
    super.didUpdateWidget(old);
    if (old.taskId != widget.taskId) {
      _task = null;
      _editingTitle = null;
      _editingDescription = null;
      _load();
    } else if (old.reloadTick != widget.reloadTick) {
      _load();
    }
  }

  @override
  void dispose() {
    _newChecklist.dispose();
    _newSubtask.dispose();
    _scroll.dispose();
    _editingTitle?.dispose();
    _editingDescription?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final api = widget.session.api!;
      final task = await api.fetchTask(widget.taskId);
      final project = await api.fetchProject(task.projectId);
      final results = await Future.wait([
        api.fetchTaskStatuses(task.projectId),
        api.fetchTaskPriorities(task.projectId),
        api.fetchTaskTypes(task.projectId),
      ]);
      if (!mounted) return;
      setState(() {
        _task = task;
        _project = project;
        _statuses = results[0] as List<TaskStatusDef>;
        _priorities = results[1] as List<TaskPriorityDef>;
        _types = results[2] as List<TaskType>;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 서버에 반영하고 이 패널과 뒤 목록을 같이 새로고침한다.
  Future<void> _apply(Future<void> Function() save) async {
    try {
      await save();
      await _load();
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) showAppToast(context, '바꾸지 못했습니다: $e');
    }
  }

  bool get _readOnly => _project?.archived ?? false;

  // ── 삼점 메뉴 ─────────────────────────────────────────────────────────

  Future<void> _copy() async {
    try {
      final copy = await widget.session.api!.copyTask(widget.taskId);
      widget.onChanged?.call();
      if (mounted) showAppToast(context, '${copy.key ?? '업무'}로 복사했습니다.');
      widget.onOpenTask(copy.id);
    } catch (e) {
      if (mounted) showAppToast(context, '복사하지 못했습니다: $e');
    }
  }

  Future<void> _move() async {
    final task = _task;
    if (task == null) return;
    final projects = await widget.session.api!.fetchProjects(
      widget.session.currentTeam!.id,
    );
    if (!mounted) return;
    final targets = [
      for (final p in projects)
        if (p.id != task.projectId && !p.archived) p,
    ];
    if (targets.isEmpty) {
      showAppToast(context, '옮길 다른 프로젝트가 없습니다.');
      return;
    }
    final picked = await showDialog<Project>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('어느 프로젝트로 옮길까요?'),
        children: [
          for (final p in targets)
            SimpleDialogOption(
              onPressed: () => Navigator.of(c).pop(p),
              child: Text(p.name),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await _apply(() async {
      await widget.session.api!.moveTask(task.id, picked.id);
      if (mounted) showAppToast(context, '${picked.name}(으)로 옮겼습니다.');
    });
  }

  Future<void> _archive() async {
    final task = _task;
    if (task == null) return;
    await _apply(
      () => widget.session.api!.setTaskArchived(task.id, !task.archived),
    );
    if (mounted) {
      showAppToast(context, task.archived ? '보관을 해제했습니다.' : '업무를 보관했습니다.');
    }
    if (!task.archived) widget.onClose();
  }

  Future<void> _delete() async {
    final task = _task;
    if (task == null) return;
    final subtasks = task.subtasks.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('업무 삭제'),
        content: Text(
          subtasks == 0
              ? "'${task.title}'을(를) 삭제할까요? 되돌릴 수 없습니다."
              : "'${task.title}'을(를) 삭제할까요? 하위 업무 $subtasks개도 같이 삭제됩니다. 되돌릴 수 없습니다.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.session.api!.deleteTask(task.id);
      widget.onChanged?.call();
      widget.onClose();
    } catch (e) {
      if (mounted) showAppToast(context, '삭제하지 못했습니다: $e');
    }
  }

  // ── 조각들 ────────────────────────────────────────────────────────────

  Widget _header(Task? task) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
      child: Row(
        children: [
          if (task?.key != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFE94E77).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.link, size: 13, color: Color(0xFFE94E77)),
                  const SizedBox(width: 5),
                  Text(
                    task!.key!,
                    style: const TextStyle(
                      color: Color(0xFFE94E77),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          const Spacer(),
          if (task != null && !_readOnly)
            MenuAnchor(
              menuChildren: [
                MenuItemButton(
                  leadingIcon: const Icon(Icons.copy_outlined, size: 16),
                  onPressed: _copy,
                  child: const Text('업무 복사'),
                ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.open_with, size: 16),
                  onPressed: _move,
                  child: const Text('업무 이동'),
                ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.inventory_2_outlined, size: 16),
                  onPressed: _archive,
                  child: Text(task.archived ? '보관 해제' : '업무 보관'),
                ),
                MenuItemButton(
                  leadingIcon: const Icon(
                    Icons.delete_outline,
                    size: 16,
                    color: Colors.redAccent,
                  ),
                  onPressed: _delete,
                  child: const Text(
                    '업무 삭제',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                ),
              ],
              builder: (context, controller, _) => IconButton(
                icon: const Icon(Icons.more_horiz, size: 20),
                tooltip: '업무 메뉴',
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
              ),
            ),
          IconButton(
            icon: Icon(
              widget.expanded ? Icons.close_fullscreen : Icons.open_in_full,
              size: 18,
            ),
            tooltip: widget.expanded ? '작게 보기' : '크게 보기',
            onPressed: widget.onToggleExpand,
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            tooltip: '닫기',
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  /// 제목 — 연필을 누르면 그 자리에서 고친다.
  Widget _title(Task task) {
    final editing = _editingTitle;
    if (editing != null) {
      return TextField(
        controller: editing,
        autofocus: true,
        maxLines: null,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        decoration: const InputDecoration(border: OutlineInputBorder()),
        onSubmitted: (_) => _commitTitle(task),
        onTapOutside: (_) => _commitTitle(task),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            task.title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ),
        if (!_readOnly)
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 18),
            tooltip: '제목 수정',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(
              () => _editingTitle = TextEditingController(text: task.title),
            ),
          ),
      ],
    );
  }

  void _commitTitle(Task task) {
    final controller = _editingTitle;
    if (controller == null) return;
    final title = controller.text.trim();
    controller.dispose();
    setState(() => _editingTitle = null);
    if (title.isEmpty || title == task.title) return;
    _apply(() => widget.session.api!.updateTask(task.id, title: title));
  }

  Widget _row(String label, Widget child, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: child),
        ?trailing,
      ],
    ),
  );

  /// 색 점 + 이름으로 보이고, 누르면 그 프로젝트가 정해둔 값들이 펼쳐지는 칸.
  Widget _picker({
    required String? name,
    required Color? color,
    required List<({String? id, String name, Color color})> options,
    required String? currentId,
    required ValueChanged<String?> onPick,
  }) {
    final theme = Theme.of(context);
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (color != null) ...[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
        ],
        Text(
          name ?? '없음',
          style: TextStyle(
            fontSize: 13,
            color: name == null ? theme.hintColor : null,
          ),
        ),
      ],
    );
    if (_readOnly) return Align(alignment: Alignment.centerLeft, child: label);
    return Align(
      alignment: Alignment.centerLeft,
      child: MenuAnchor(
        menuChildren: [
          for (final o in options)
            SizedBox(
              width: 180,
              child: MenuItemButton(
                onPressed: () => onPick(o.id),
                trailingIcon: o.id == currentId
                    ? Icon(
                        Icons.check,
                        size: 16,
                        color: theme.colorScheme.primary,
                      )
                    : null,
                child: Text(
                  o.name,
                  style: TextStyle(
                    fontSize: 13,
                    color: o.id == currentId ? theme.colorScheme.primary : null,
                  ),
                ),
              ),
            ),
        ],
        builder: (context, controller, _) => InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: label,
          ),
        ),
      ),
    );
  }

  Widget _assigneeRow(Task task) {
    final members = _project?.members ?? const <AppUser>[];
    final me = widget.session.userId;
    final assignee = members.where((m) => m.id == task.assigneeId).firstOrNull;
    final canAssignMe =
        me != null && task.assigneeId != me && members.any((m) => m.id == me);
    return _row(
      '담당자',
      _readOnly
          ? Text(assignee?.name ?? '미배정')
          : MenuAnchor(
              menuChildren: [
                MenuItemButton(
                  onPressed: () => _apply(
                    () => widget.session.api!.updateTask(
                      task.id,
                      clearAssignee: true,
                    ),
                  ),
                  child: const Text('미배정'),
                ),
                for (final m in members)
                  MenuItemButton(
                    onPressed: () => _apply(
                      () => widget.session.api!.updateTask(
                        task.id,
                        assigneeId: m.id,
                      ),
                    ),
                    child: Text(m.name),
                  ),
              ],
              builder: (context, controller, _) => Align(
                alignment: Alignment.centerLeft,
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: assignee == null
                        ? Text(
                            '미배정',
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context).hintColor,
                            ),
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              UserAvatar(
                                user: assignee,
                                resolveUrl: widget.session.resolveUrl,
                                radius: 10,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                assignee.name,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
      trailing: canAssignMe
          ? TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 12),
              ),
              onPressed: () => _apply(
                () => widget.session.api!.updateTask(task.id, assigneeId: me),
              ),
              child: const Text('나에게 할당'),
            )
          : null,
    );
  }

  Widget _periodRow(Task task) {
    final hint = Theme.of(context).hintColor;
    Widget one(DateTime? value, bool due) => DateDropButton(
      value: value,
      onPicked: (picked) => _apply(
        () => widget.session.api!.updateTask(
          task.id,
          startDate: due ? null : picked,
          clearStartDate: !due && picked == null,
          dueDate: due ? picked : null,
          clearDueDate: due && picked == null,
        ),
      ),
      child: Text(
        value == null ? (due ? '마감일' : '시작일') : formatYmd(value),
        style: TextStyle(fontSize: 13, color: value == null ? hint : null),
      ),
    );
    return _row(
      '기간',
      Row(
        children: [
          Icon(Icons.calendar_today_outlined, size: 13, color: hint),
          const SizedBox(width: 4),
          one(task.startDate, false),
          Text('—', style: TextStyle(color: hint)),
          one(task.dueDate, true),
        ],
      ),
    );
  }

  Widget _meta(Task task) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _assigneeRow(task),
        _referenceRow(task),
        _periodRow(task),
        _row(
          '상태',
          _picker(
            name: task.statusLabel,
            color: parseTypeColor(task.statusColor),
            currentId: task.statusId,
            options: [
              for (final s in _statuses)
                (id: s.id, name: s.name, color: parseTypeColor(s.color)),
            ],
            onPick: (id) => _apply(
              () => widget.session.api!.updateTask(task.id, statusId: id),
            ),
          ),
        ),
        _row(
          '유형',
          _picker(
            name: task.typeName,
            color: task.typeName == null
                ? null
                : parseTypeColor(task.typeColor),
            currentId: task.typeId,
            options: [
              (id: null, name: '없음', color: Colors.grey),
              for (final t in _types)
                (id: t.id, name: t.name, color: parseTypeColor(t.color)),
            ],
            onPick: (id) => _apply(
              () => widget.session.api!.updateTask(
                task.id,
                typeId: id,
                clearType: id == null,
              ),
            ),
          ),
        ),
        _row(
          '우선순위',
          _picker(
            // 아직 안 고른 우선순위는 "없음"으로 — 목록의 "—"와 같은 상태다.
            name: task.priorityName,
            color: task.priorityName == null
                ? null
                : parseTypeColor(task.priorityColor),
            currentId: task.priorityId,
            options: [
              for (final p in _priorities)
                (id: p.id, name: p.name, color: parseTypeColor(p.color)),
            ],
            onPick: (id) => _apply(
              () => widget.session.api!.updateTask(task.id, priorityId: id),
            ),
          ),
        ),
        // 상위 업무 칸은 하위 업무일 때만 보여준다 — 일반 업무는 부모의 "새 하위 업무"로
        // 하위가 되고, 여기서는 어느 업무에 딸려 있는지 확인하고 바꾸는 용도다.
        if (task.parentTaskId != null) _row('상위 업무', _parentRow(task)),
      ],
    );
  }

  /// 참조자 — 칩으로 보이고 "+ 추가"로 구성원 중에서 고른다. ×로 한 명씩 뺀다.
  Widget _referenceRow(Task task) {
    final members = _project?.members ?? const <AppUser>[];
    final picked = [
      for (final id in task.referenceIds)
        if (members.any((m) => m.id == id))
          members.firstWhere((m) => m.id == id),
    ];
    void save(List<String> ids) => _apply(
      () => widget.session.api!.updateTask(task.id, referenceIds: ids),
    );
    final rest = [
      for (final m in members)
        if (!task.referenceIds.contains(m.id)) m,
    ];
    return _row(
      '참조',
      Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final user in picked)
            Chip(
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              labelStyle: const TextStyle(fontSize: 12),
              avatar: UserAvatar(
                user: user,
                resolveUrl: widget.session.resolveUrl,
                radius: 9,
              ),
              label: Text(user.name),
              onDeleted: _readOnly
                  ? null
                  : () => save([
                      for (final id in task.referenceIds)
                        if (id != user.id) id,
                    ]),
            ),
          if (!_readOnly)
            MenuAnchor(
              menuChildren: [
                if (rest.isEmpty)
                  const SizedBox(
                    width: 200,
                    child: MenuItemButton(child: Text('더 고를 구성원이 없습니다')),
                  ),
                for (final m in rest)
                  SizedBox(
                    width: 200,
                    child: MenuItemButton(
                      onPressed: () => save([...task.referenceIds, m.id]),
                      leadingIcon: UserAvatar(
                        user: m,
                        resolveUrl: widget.session.resolveUrl,
                        radius: 10,
                      ),
                      child: Text(m.name, style: const TextStyle(fontSize: 13)),
                    ),
                  ),
              ],
              builder: (context, controller, _) => DashedAddButton(
                label: '+ 추가',
                onTap: () =>
                    controller.isOpen ? controller.close() : controller.open(),
              ),
            ),
        ],
      ),
    );
  }

  /// 상위 업무 — 없으면 "없음". 누르면 같은 프로젝트의 업무 중에서 고른다.
  Widget _parentRow(Task task) {
    final theme = Theme.of(context);
    final parentTitle = _parentTitle(task);
    if (_readOnly) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          parentTitle ?? '없음',
          style: TextStyle(
            fontSize: 13,
            color: parentTitle == null ? theme.hintColor : null,
          ),
        ),
      );
    }
    return _ParentTaskPicker(
      title: parentTitle,
      currentId: task.parentTaskId,
      // 하위 업무가 있는 업무는 남의 하위가 될 수 없고, 하위 업무는 상위가 될 수 없다(두 단계까지).
      canHaveParent: task.subtasks.isEmpty,
      loadCandidates: () async {
        final all = await widget.session.api!.fetchProjectTasks(task.projectId);
        return [
          for (final t in all)
            if (t.id != task.id && t.parentTaskId == null) t,
        ];
      },
      onPick: (id) => _apply(
        () => widget.session.api!.updateTask(
          task.id,
          parentTaskId: id,
          clearParent: id == null,
        ),
      ),
    );
  }

  /// 상위 업무 제목 — 상세 응답에는 부모 제목이 없어서 필요할 때 받아와 캐싱한다.
  String? _parentTitle(Task task) {
    final id = task.parentTaskId;
    if (id == null) return null;
    final cached = _parentTitles[id];
    if (cached != null) return cached;
    widget.session.api!
        .fetchTask(id)
        .then((parent) {
          if (mounted) setState(() => _parentTitles[id] = parent.title);
        })
        .catchError((_) => null);
    return '…';
  }

  Widget _description(Task task) {
    final theme = Theme.of(context);
    final editing = _editingDescription;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text(
              '설명',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const Spacer(),
            if (!_readOnly && editing == null)
              TextButton.icon(
                icon: const Icon(Icons.edit_outlined, size: 14),
                label: const Text('편집'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                ),
                onPressed: () => setState(
                  () => _editingDescription = TextEditingController(
                    text: task.description ?? '',
                  ),
                ),
              ),
          ],
        ),
        if (editing == null)
          Text(
            task.description?.isNotEmpty == true
                ? task.description!
                : '설명을 추가하세요...',
            style: TextStyle(
              color: task.description?.isNotEmpty == true
                  ? null
                  : theme.hintColor,
            ),
          )
        else ...[
          TextField(
            controller: editing,
            autofocus: true,
            minLines: 3,
            maxLines: 10,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  editing.dispose();
                  setState(() => _editingDescription = null);
                },
                child: const Text('취소'),
              ),
              const SizedBox(width: 6),
              FilledButton(
                onPressed: () {
                  final text = editing.text.trim();
                  editing.dispose();
                  setState(() => _editingDescription = null);
                  _apply(
                    () => widget.session.api!.updateTask(
                      task.id,
                      description: text,
                    ),
                  );
                },
                child: const Text('저장'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _checklist(Task task) {
    final theme = Theme.of(context);
    final total = task.checklist.length;
    final done = task.checklist.where((i) => i.done).length;
    final percent = total == 0 ? 0 : (done / total * 100).round();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.checklist, size: 16, color: theme.hintColor),
              const SizedBox(width: 6),
              Text(
                '체크리스트 ($done/$total)',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 8),
              Text(
                '$percent%',
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: total == 0 ? 0 : done / total,
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '체크리스트 진행률은 업무 상세에만 표시되며 전체·대시보드 진행률에는 포함되지 않습니다.',
            style: TextStyle(color: theme.hintColor, fontSize: 11),
          ),
          const SizedBox(height: 6),
          for (final item in task.checklist)
            Row(
              children: [
                Checkbox(
                  value: item.done,
                  visualDensity: VisualDensity.compact,
                  shape: const CircleBorder(),
                  onChanged: _readOnly
                      ? null
                      : (v) => _apply(
                          () => widget.session.api!.updateChecklistItem(
                            item.id,
                            done: v == true,
                          ),
                        ),
                ),
                Expanded(
                  child: Text(
                    item.text,
                    style: TextStyle(
                      fontSize: 13,
                      decoration: item.done ? TextDecoration.lineThrough : null,
                      color: item.done ? theme.hintColor : null,
                    ),
                  ),
                ),
                if (!_readOnly)
                  IconButton(
                    icon: const Icon(Icons.close, size: 14),
                    tooltip: '삭제',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _apply(
                      () => widget.session.api!.deleteChecklistItem(item.id),
                    ),
                  ),
              ],
            ),
          if (!_readOnly) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newChecklist,
                    decoration: const InputDecoration(
                      hintText: '+ 새 체크리스트 항목 추가 (Enter)',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _addChecklist(task),
                  ),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed: () => _addChecklist(task),
                  child: const Text('추가'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  void _addChecklist(Task task) {
    final text = _newChecklist.text.trim();
    if (text.isEmpty) return;
    _newChecklist.clear();
    _apply(() => widget.session.api!.addChecklistItem(task.id, text));
  }

  Widget _subtasks(Task task) {
    final theme = Theme.of(context);
    // 하위 업무에는 또 하위 업무를 둘 수 없다(서버도 막는다).
    final canAdd = !_readOnly && task.parentTaskId == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Icons.subdirectory_arrow_right,
              size: 16,
              color: theme.hintColor,
            ),
            const SizedBox(width: 6),
            Text(
              '하위 업무 (${task.subtasks.length})',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final sub in task.subtasks) ...[
          const Divider(height: 1),
          _subtaskRow(sub),
        ],
        if (canAdd) ...[
          const Divider(height: 1),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newSubtask,
                  decoration: const InputDecoration(
                    hintText: '+ 새 하위 업무 (Enter)',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _addSubtask(task),
                ),
              ),
              const SizedBox(width: 6),
              FilledButton(
                onPressed: () => _addSubtask(task),
                child: const Text('추가'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 하위 업무 한 줄 — 제목, 그리고 오른쪽에 담당자·마감일·상태.
  /// 담당자·마감일은 비어 있어도 자리를 비워두지 않고 "미배정" 동그라미와 "-"를 그려서,
  /// 여러 줄의 칸이 위아래로 가지런히 맞게 한다.
  Widget _subtaskRow(Task sub) {
    final theme = Theme.of(context);
    final assignee = (_project?.members ?? const <AppUser>[])
        .where((m) => m.id == sub.assigneeId)
        .firstOrNull;
    final due = sub.dueDate;
    return InkWell(
      onTap: () => widget.onOpenTask(sub.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                sub.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: assignee?.name ?? '미배정',
              child: assignee != null
                  ? UserAvatar(
                      user: assignee,
                      resolveUrl: widget.session.resolveUrl,
                      radius: 10,
                    )
                  : CircleAvatar(
                      radius: 10,
                      backgroundColor: theme.hintColor.withValues(alpha: 0.15),
                      child: Icon(
                        Icons.person_outline,
                        size: 13,
                        color: theme.hintColor,
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            // 마감일은 "9.↵26."처럼 월·일을 두 줄로 좁게 — 폭을 고정해 줄마다 칸이 맞는다.
            SizedBox(
              width: 24,
              child: Text(
                due == null ? '-' : '${due.month}.\n${due.day}.',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.15,
                  color: sub.isOverdue ? Colors.redAccent : theme.hintColor,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: parseTypeColor(sub.statusColor).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                sub.statusLabel,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: parseTypeColor(sub.statusColor),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _addSubtask(Task task) {
    final title = _newSubtask.text.trim();
    if (title.isEmpty) return;
    _newSubtask.clear();
    _apply(
      () => widget.session.api!.createTask(
        projectId: task.projectId,
        parentTaskId: task.id,
        title: title,
      ),
    );
  }

  /// 댓글 · 기록 탭.
  Widget _comments(Task task) => TaskCommentsSection(
    session: widget.session,
    task: task,
    members: _project?.members ?? const <AppUser>[],
    readOnly: _readOnly,
    canModerate: _project?.memberRoles[widget.session.userId] == 'owner',
    apply: _apply,
  );

  /// 프로젝트 이름 · 만든 날짜 한 줄, 오른쪽 끝에 만든 사람.
  Widget _byline(Task task) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: parseTypeColor(_project?.color),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        // 글자 칸이 남는 폭을 다 차지해야 생성자가 오른쪽 끝에 붙는다(Flexible+Spacer면
        // 남는 폭을 반씩 나눠 생성자가 가운데로 간다).
        Expanded(
          child: Text(
            '${task.projectName ?? ''} · ${formatYmd(task.createdAt)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: theme.hintColor, fontSize: 12),
          ),
        ),
        if (task.creatorName != null) _creator(task),
      ],
    );
  }

  /// 업무를 만든 사람 — 프로필 사진과 이름.
  Widget _creator(Task task) {
    final theme = Theme.of(context);
    return Tooltip(
      message: '생성자',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          UserAvatar(
            user: AppUser(
              id: task.creatorId ?? '',
              username: task.creatorName!,
              name: task.creatorName!,
              avatarType: task.creatorAvatarType,
              avatarEmoji: task.creatorAvatarEmoji,
              avatarColor: task.creatorAvatarColor,
              avatarUrl: task.creatorAvatarUrl,
            ),
            resolveUrl: widget.session.resolveUrl,
            radius: 10,
          ),
          const SizedBox(width: 6),
          Text(
            task.creatorName!,
            style: TextStyle(color: theme.hintColor, fontSize: 12),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final task = _task;
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(task),
          const Divider(height: 1),
          if (_project?.archived == true)
            Container(
              width: double.infinity,
              color: theme.colorScheme.surfaceContainerHigh,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '종료된 프로젝트의 업무입니다. 읽기만 할 수 있습니다.',
                style: TextStyle(color: theme.hintColor, fontSize: 12),
              ),
            ),
          Expanded(
            child: _error != null
                ? Center(child: Text(_error!))
                : task == null
                ? const Center(child: CircularProgressIndicator())
                : MutedScrollbar(
                    controller: _scroll,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      child: widget.expanded
                          ? _expandedBody(task)
                          : _miniBody(task),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _miniBody(Task task) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _title(task),
      const SizedBox(height: 4),
      _byline(task),
      const SizedBox(height: 12),
      _meta(task),
      const SizedBox(height: 16),
      _description(task),
      const SizedBox(height: 16),
      _checklist(task),
      const SizedBox(height: 16),
      _subtasks(task),
      const SizedBox(height: 20),
      _comments(task),
    ],
  );

  /// 넓은 모드 — 왼쪽에 내용(제목·설명·체크리스트·하위 업무·댓글), 오른쪽에 항목들.
  Widget _expandedBody(Task task) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        flex: 2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _title(task),
            const SizedBox(height: 4),
            _byline(task),
            const SizedBox(height: 20),
            _description(task),
            const SizedBox(height: 16),
            _checklist(task),
            const SizedBox(height: 16),
            _subtasks(task),
            const SizedBox(height: 20),
            _comments(task),
          ],
        ),
      ),
      const SizedBox(width: 24),
      SizedBox(width: 320, child: _meta(task)),
    ],
  );
}

/// 업무 패널이 본문 오른쪽에 나란히 붙어 있을 때 그 폭(없으면 0) — 업무 목록 표가 이만큼은
/// "패널 뒤로 가려진 자리"로 보고, 패널이 없을 때의 열 배치를 유지한 채 뒤쪽 열(생성자·생성일
/// 등)만 패널 아래로 밀어 둔다(가로 스크롤로 볼 수 있다).
class TaskPanelInset extends InheritedWidget {
  final double width;
  const TaskPanelInset({super.key, required this.width, required super.child});

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TaskPanelInset>()?.width ?? 0;

  @override
  bool updateShouldNotify(TaskPanelInset old) => old.width != width;
}

/// "프로젝트" 창이 아래 화면들에게 "업무 상세는 오른쪽 패널로 연다"고 알려주는 통로.
/// 목록·홈·검색·알림 등 여러 곳에서 업무를 여는데, 그때마다 콜백을 넘겨 내려보내는 대신
/// 이 Scope를 찾아 [open]을 부른다. Scope가 없으면(프로젝트 창 밖) 예전처럼 팝업으로 뜬다.
class TaskPanelScope extends InheritedWidget {
  final ValueChanged<String> openTask;

  /// 뒤 화면에서 업무를 고쳤다고 알린다 — 열려 있는 업무 패널이 다시 읽는다.
  final VoidCallback? tasksChanged;

  const TaskPanelScope({
    super.key,
    required this.openTask,
    this.tasksChanged,
    required super.child,
  });

  /// [context] 위에 Scope가 있으면 열린 업무 패널에 "업무가 바뀌었다"고 알린다.
  static void notifyChanged(BuildContext context) =>
      maybeOf(context)?.tasksChanged?.call();

  static TaskPanelScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TaskPanelScope>();

  @override
  bool updateShouldNotify(TaskPanelScope old) => false;
}

/// "상위 업무" 칸 — 누르면 같은 프로젝트의 업무가 뜨고, 검색으로 좁힐 수 있다.
/// 지금 상위 업무는 파란 글씨와 체크로 표시한다.
class _ParentTaskPicker extends StatefulWidget {
  final String? title;
  final String? currentId;
  final bool canHaveParent;
  final Future<List<Task>> Function() loadCandidates;
  final ValueChanged<String?> onPick;

  const _ParentTaskPicker({
    required this.title,
    required this.currentId,
    required this.canHaveParent,
    required this.loadCandidates,
    required this.onPick,
  });

  @override
  State<_ParentTaskPicker> createState() => _ParentTaskPickerState();
}

class _ParentTaskPickerState extends State<_ParentTaskPicker> {
  final _menu = MenuController();
  final _query = TextEditingController();
  List<Task>? _candidates;
  bool _loading = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    if (_menu.isOpen) {
      _menu.close();
      return;
    }
    if (_candidates == null && !_loading) {
      setState(() => _loading = true);
      try {
        final list = await widget.loadCandidates();
        if (!mounted) return;
        setState(() {
          _candidates = list;
          _loading = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() => _loading = false);
        showAppToast(context, '업무를 불러오지 못했습니다: $e');
        return;
      }
    }
    _query.clear();
    _menu.open();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _query.text.trim().toLowerCase();
    final shown = [
      for (final t in _candidates ?? const <Task>[])
        if (q.isEmpty || t.title.toLowerCase().contains(q)) t,
    ];
    return Align(
      alignment: Alignment.centerLeft,
      child: MenuAnchor(
        controller: _menu,
        style: MenuStyle(
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 6),
          ),
          backgroundColor: WidgetStatePropertyAll(theme.colorScheme.surface),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: theme.dividerColor),
            ),
          ),
        ),
        menuChildren: [
          SizedBox(
            width: 320,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
              child: TextField(
                controller: _query,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search...',
                  prefixIcon: Icon(Icons.search, size: 16),
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
          SizedBox(
            width: 320,
            child: MenuItemButton(
              onPressed: () => widget.onPick(null),
              trailingIcon: widget.currentId == null
                  ? Icon(
                      Icons.check,
                      size: 16,
                      color: theme.colorScheme.primary,
                    )
                  : null,
              child: Text(
                '없음',
                style: TextStyle(
                  fontSize: 13,
                  color: widget.currentId == null
                      ? theme.colorScheme.primary
                      : null,
                ),
              ),
            ),
          ),
          for (final t in shown)
            SizedBox(
              width: 320,
              child: MenuItemButton(
                onPressed: () => widget.onPick(t.id),
                trailingIcon: t.id == widget.currentId
                    ? Icon(
                        Icons.check,
                        size: 16,
                        color: theme.colorScheme.primary,
                      )
                    : null,
                child: Text(
                  t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: t.id == widget.currentId
                        ? FontWeight.w700
                        : FontWeight.normal,
                    color: t.id == widget.currentId
                        ? theme.colorScheme.primary
                        : null,
                  ),
                ),
              ),
            ),
        ],
        builder: (context, controller, _) => InkWell(
          borderRadius: BorderRadius.circular(6),
          // 하위 업무를 거느린 업무는 남의 하위가 될 수 없다(서버도 막는다).
          onTap: widget.canHaveParent ? _open : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: _loading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    widget.title ?? '없음',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: widget.title == null ? theme.hintColor : null,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
