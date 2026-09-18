import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/floating_dialog.dart';
import '../../widgets/muted_scrollbar.dart';
import '../../widgets/user_avatar.dart';
import 'project_widgets.dart';

// intl의 DateFormat(locale: 'ko')는 initializeDateFormatting()을 먼저 부르지 않으면
// LocaleDataException을 던진다(이 앱은 그 초기화를 어디서도 안 한다 — time_format.dart와
// 같은 이유로 여기도 직접 문자열을 조립한다).
String _formatDue(DateTime dt) =>
    '${dt.year}.${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')}';

String _formatCommentTime(DateTime dt) {
  final isPm = dt.hour >= 12;
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  return '${dt.month}월 ${dt.day}일 ${isPm ? '오후' : '오전'} $hour12:${dt.minute.toString().padLeft(2, '0')}';
}

/// "새 프로젝트" — 이름/식별자/설명 + 함께할 구성원. 만든 사람이 담당자(owner)가 된다.
Future<Project?> showNewProjectDialog(
  BuildContext context,
  Session session,
  String teamId,
) {
  return showDialog<Project>(
    context: context,
    builder: (_) => _NewProjectDialog(session: session, teamId: teamId),
  );
}

class _NewProjectDialog extends StatefulWidget {
  final Session session;
  final String teamId;
  const _NewProjectDialog({required this.session, required this.teamId});

  @override
  State<_NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<_NewProjectDialog> {
  final _name = TextEditingController();
  final _identifier = TextEditingController();
  final _description = TextEditingController();
  final _selected = <String>{};
  List<AppUser>? _members;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  @override
  void dispose() {
    _name.dispose();
    _identifier.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _loadMembers() async {
    try {
      final list = await widget.session.fetchTeamMembers();
      list.removeWhere((u) => u.id == widget.session.userId);
      if (mounted) setState(() => _members = list);
    } catch (_) {
      if (mounted) setState(() => _members = []);
    }
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final project = await widget.session.api!.createProject(
        teamId: widget.teamId,
        name: _name.text.trim(),
        identifier: _identifier.text.trim().toUpperCase(),
        description: _description.text.trim().isEmpty
            ? null
            : _description.text.trim(),
        memberIds: _selected.toList(),
      );
      if (mounted) Navigator.of(context).pop(project);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final members = _members;
    return FloatingDialog(
      title: '새 프로젝트',
      maxWidth: 520,
      maxHeight: 640,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: MutedScrollbar(
              child: ListView(
                children: [
                  TextField(
                    controller: _name,
                    autofocus: true,
                    maxLength: 60,
                    decoration: const InputDecoration(
                      labelText: '프로젝트 이름',
                      border: OutlineInputBorder(),
                    ),
                    // 이름을 적으면 식별자를 아직 안 건드린 경우에 한해 앞글자로 추천한다.
                    onChanged: (v) {
                      if (_identifier.text.isNotEmpty) return;
                      final guess = v
                          .toUpperCase()
                          .replaceAll(RegExp(r'[^A-Z0-9]'), '');
                      if (guess.length >= 2) {
                        _identifier.text = guess.substring(
                          0,
                          guess.length > 4 ? 4 : guess.length,
                        );
                      }
                    },
                  ),
                  TextField(
                    controller: _identifier,
                    maxLength: 10,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: '식별자 (업무 번호에 붙습니다 — 예: MKT → MKT-1001)',
                      hintText: 'MKT',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  TextField(
                    controller: _description,
                    maxLines: 3,
                    minLines: 2,
                    decoration: const InputDecoration(
                      labelText: '설명 (선택)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('구성원 (선택)', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 4),
                  Text(
                    '나는 담당자로 자동 포함됩니다. 나중에 프로젝트에서 더 초대할 수 있습니다.',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: hint),
                  ),
                  const SizedBox(height: 8),
                  if (members == null)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else
                    for (final user in members)
                      CheckboxListTile(
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _selected.contains(user.id),
                        title: Row(
                          children: [
                            UserAvatar(
                              user: user,
                              resolveUrl: widget.session.resolveUrl,
                              radius: 12,
                            ),
                            const SizedBox(width: 8),
                            Flexible(child: Text(user.name)),
                          ],
                        ),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _selected.add(user.id);
                          } else {
                            _selected.remove(user.id);
                          }
                        }),
                      ),
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('취소'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('만들기'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "새 업무" — [projectId]를 주면 그 프로젝트에 바로 만들고, 없으면 [projects]에서 고르게 한다.
Future<Task?> showNewTaskDialog(
  BuildContext context,
  Session session, {
  List<Project> projects = const [],
  String? projectId,
  List<AppUser> members = const [],
}) {
  return showDialog<Task>(
    context: context,
    builder: (_) => _NewTaskDialog(
      session: session,
      projects: projects,
      projectId: projectId,
      members: members,
    ),
  );
}

class _NewTaskDialog extends StatefulWidget {
  final Session session;
  final List<Project> projects;
  final String? projectId;
  final List<AppUser> members;
  const _NewTaskDialog({
    required this.session,
    required this.projects,
    required this.projectId,
    required this.members,
  });

  @override
  State<_NewTaskDialog> createState() => _NewTaskDialogState();
}

class _NewTaskDialogState extends State<_NewTaskDialog> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  late String? _projectId = widget.projectId ?? widget.projects.firstOrNull?.id;
  late List<AppUser> _members = widget.members;
  String? _assigneeId;
  TaskStatus _status = TaskStatus.todo;
  TaskPriority _priority = TaskPriority.normal;
  DateTime? _dueDate;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_members.isEmpty) _loadMembers();
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  /// 담당자 후보는 그 프로젝트의 구성원 — 프로젝트를 바꾸면 다시 받아온다.
  Future<void> _loadMembers() async {
    final id = _projectId;
    if (id == null) return;
    try {
      final project = await widget.session.api!.fetchProject(id);
      if (mounted) {
        setState(() {
          _members = project.members;
          if (!_members.any((m) => m.id == _assigneeId)) _assigneeId = null;
        });
      }
    } catch (_) {
      // 담당자를 못 고르는 정도라 조용히 넘어간다(업무는 담당자 없이도 만들 수 있다).
    }
  }

  Future<void> _submit() async {
    final projectId = _projectId;
    if (projectId == null) {
      setState(() => _error = '프로젝트를 고르세요.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final task = await widget.session.api!.createTask(
        projectId: projectId,
        title: _title.text.trim(),
        description: _description.text.trim().isEmpty
            ? null
            : _description.text.trim(),
        assigneeId: _assigneeId,
        status: _status,
        priority: _priority,
        dueDate: _dueDate,
      );
      if (mounted) Navigator.of(context).pop(task);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FloatingDialog(
      title: '새 업무',
      maxWidth: 520,
      maxHeight: 640,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: MutedScrollbar(
              child: ListView(
                children: [
                  if (widget.projectId == null && widget.projects.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: DropdownButtonFormField<String>(
                        initialValue: _projectId,
                        decoration: const InputDecoration(
                          labelText: '프로젝트',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final project in widget.projects)
                            DropdownMenuItem(
                              value: project.id,
                              child: Text(project.name),
                            ),
                        ],
                        onChanged: (v) {
                          setState(() => _projectId = v);
                          _loadMembers();
                        },
                      ),
                    ),
                  TextField(
                    controller: _title,
                    autofocus: true,
                    maxLength: 200,
                    decoration: const InputDecoration(
                      labelText: '업무 제목',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  TextField(
                    controller: _description,
                    maxLines: 4,
                    minLines: 2,
                    decoration: const InputDecoration(
                      labelText: '설명 (선택)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _AssigneeField(
                    session: widget.session,
                    members: _members,
                    value: _assigneeId,
                    onChanged: (v) => setState(() => _assigneeId = v),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<TaskStatus>(
                          initialValue: _status,
                          decoration: const InputDecoration(
                            labelText: '상태',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final s in TaskStatus.values)
                              DropdownMenuItem(
                                value: s,
                                child: Text(taskStatusLabel(s)),
                              ),
                          ],
                          onChanged: (v) =>
                              setState(() => _status = v ?? TaskStatus.todo),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<TaskPriority>(
                          initialValue: _priority,
                          decoration: const InputDecoration(
                            labelText: '우선순위',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final p in TaskPriority.values)
                              DropdownMenuItem(
                                value: p,
                                child: Text(taskPriorityLabel(p)),
                              ),
                          ],
                          onChanged: (v) => setState(
                            () => _priority = v ?? TaskPriority.normal,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _DueDateField(
                    value: _dueDate,
                    onChanged: (v) => setState(() => _dueDate = v),
                  ),
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('취소'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('등록'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 업무 상세 — 상태/담당자/마감일을 그 자리에서 바꾸고, 댓글로 논의한다.
Future<void> showTaskDetailDialog(
  BuildContext context,
  Session session,
  String taskId,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _TaskDetailDialog(session: session, taskId: taskId),
  );
}

class _TaskDetailDialog extends StatefulWidget {
  final Session session;
  final String taskId;
  const _TaskDetailDialog({required this.session, required this.taskId});

  @override
  State<_TaskDetailDialog> createState() => _TaskDetailDialogState();
}

class _TaskDetailDialogState extends State<_TaskDetailDialog> {
  final _comment = TextEditingController();
  Task? _task;
  List<AppUser> _members = const [];
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final task = await widget.session.api!.fetchTask(widget.taskId);
      final project = await widget.session.api!.fetchProject(task.projectId);
      if (mounted) {
        setState(() {
          _task = task;
          _members = project.members;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 바꾼 항목 하나를 바로 저장한다(상태/담당자/마감일은 눌러서 즉시 반영되는 게 자연스럽다).
  Future<void> _patch({
    TaskStatus? status,
    TaskPriority? priority,
    String? assigneeId,
    bool clearAssignee = false,
    DateTime? dueDate,
    bool clearDueDate = false,
  }) async {
    setState(() => _saving = true);
    try {
      final updated = await widget.session.api!.updateTask(
        widget.taskId,
        status: status,
        priority: priority,
        assigneeId: assigneeId,
        clearAssignee: clearAssignee,
        dueDate: dueDate,
        clearDueDate: clearDueDate,
      );
      if (mounted) {
        setState(() {
          // 응답에는 댓글이 안 들어있어서, 지금 들고 있는 댓글은 그대로 유지한다.
          _task = updated;
        });
        await _load();
      }
    } catch (e) {
      if (mounted) showAppToast(context, '저장하지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addComment() async {
    final text = _comment.text.trim();
    if (text.isEmpty) return;
    _comment.clear();
    try {
      await widget.session.api!.addTaskComment(widget.taskId, text);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '댓글을 남기지 못했습니다: $e');
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('업무 삭제'),
        content: const Text('이 업무와 달린 댓글이 모두 삭제됩니다. 계속할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.session.api!.deleteTask(widget.taskId);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showAppToast(context, '삭제하지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final task = _task;
    return FloatingDialog(
      title: task?.key ?? '업무',
      maxWidth: 560,
      maxHeight: 700,
      child: _error != null
          ? Center(child: Text(_error!))
          : task == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: MutedScrollbar(
                    child: ListView(
                      children: [
                        Text(
                          task.title,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        if (task.projectName != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            task.projectName!,
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: hint),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            for (final status in TaskStatus.values)
                              ChoiceChip(
                                label: Text(taskStatusLabel(status)),
                                selected: task.status == status,
                                onSelected: _saving
                                    ? null
                                    : (_) => _patch(status: status),
                              ),
                            const SizedBox(width: 4),
                            DdayBadge(task: task),
                          ],
                        ),
                        const SizedBox(height: 16),
                        _AssigneeField(
                          session: widget.session,
                          members: _members,
                          value: task.assigneeId,
                          onChanged: (v) => v == null
                              ? _patch(clearAssignee: true)
                              : _patch(assigneeId: v),
                        ),
                        const SizedBox(height: 12),
                        _DueDateField(
                          value: task.dueDate,
                          onChanged: (v) => v == null
                              ? _patch(clearDueDate: true)
                              : _patch(dueDate: v),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Text('우선순위', style: TextStyle(color: hint)),
                            const SizedBox(width: 12),
                            DropdownButton<TaskPriority>(
                              value: task.priority,
                              underline: const SizedBox.shrink(),
                              items: [
                                for (final p in TaskPriority.values)
                                  DropdownMenuItem(
                                    value: p,
                                    child: Text(taskPriorityLabel(p)),
                                  ),
                              ],
                              onChanged: _saving
                                  ? null
                                  : (v) => v == null ? null : _patch(priority: v),
                            ),
                          ],
                        ),
                        if (task.description != null &&
                            task.description!.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(task.description!),
                          ),
                        ],
                        const SizedBox(height: 20),
                        Text(
                          '댓글 ${task.comments.length}',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 8),
                        if (task.comments.isEmpty)
                          const EmptyHint('아직 댓글이 없습니다')
                        else
                          for (final comment in task.comments)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${comment.senderName} · ${_formatCommentTime(comment.createdAt)}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(color: hint),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(comment.text),
                                ],
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _comment,
                        decoration: const InputDecoration(
                          hintText: '댓글 남기기',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: (_) => _addComment(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      icon: const Icon(Icons.send, size: 18),
                      onPressed: _addComment,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _delete,
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: Colors.redAccent,
                    ),
                    label: const Text(
                      '업무 삭제',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// 담당자 고르기 — 프로젝트 구성원 중에서(또는 "담당자 없음").
class _AssigneeField extends StatelessWidget {
  final Session session;
  final List<AppUser> members;
  final String? value;
  final ValueChanged<String?> onChanged;
  const _AssigneeField({
    required this.session,
    required this.members,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // 목록에 없는 담당자(구성원에서 빠진 경우)면 드롭다운이 값을 못 찾으므로 null로 떨어뜨린다.
    final safeValue = members.any((m) => m.id == value) ? value : null;
    return DropdownButtonFormField<String?>(
      initialValue: safeValue,
      decoration: const InputDecoration(
        labelText: '담당자',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        const DropdownMenuItem(value: null, child: Text('담당자 없음')),
        for (final user in members)
          DropdownMenuItem(
            value: user.id,
            child: Row(
              children: [
                UserAvatar(
                  user: user,
                  resolveUrl: session.resolveUrl,
                  radius: 10,
                ),
                const SizedBox(width: 8),
                Text(user.name),
              ],
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

/// 마감일 고르기 — 누르면 달력이 뜨고, X로 지울 수 있다.
class _DueDateField extends StatelessWidget {
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  const _DueDateField({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Row(
      children: [
        Icon(Icons.event_outlined, size: 18, color: hint),
        const SizedBox(width: 8),
        Text('마감일', style: TextStyle(color: hint)),
        const SizedBox(width: 12),
        TextButton(
          onPressed: () async {
            final now = DateTime.now();
            final picked = await showDatePicker(
              context: context,
              initialDate: value ?? now,
              firstDate: DateTime(now.year - 1),
              lastDate: DateTime(now.year + 5),
            );
            if (picked != null) onChanged(picked);
          },
          child: Text(value == null ? '설정 안 함' : _formatDue(value!)),
        ),
        if (value != null)
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: '마감일 지우기',
            onPressed: () => onChanged(null),
          ),
      ],
    );
  }
}
