import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/muted_scrollbar.dart';
import '../../widgets/user_avatar.dart';
import 'project_forms.dart';
import 'project_widgets.dart';

/// 프로젝트 하나의 업무 목록 — 상태별(할 일/진행 중/완료)로 묶어서 보여준다.
/// 칸반보드(드래그로 상태 이동)는 다음 단계이고, 지금은 같은 데이터를 목록으로 본다.
class ProjectDetailView extends StatefulWidget {
  final Session session;
  final String projectId;
  final int reloadTick;
  final VoidCallback onDeleted;

  const ProjectDetailView({
    super.key,
    required this.session,
    required this.projectId,
    required this.reloadTick,
    required this.onDeleted,
  });

  @override
  State<ProjectDetailView> createState() => _ProjectDetailViewState();
}

class _ProjectDetailViewState extends State<ProjectDetailView> {
  Project? _project;
  List<Task>? _tasks;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ProjectDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadTick != widget.reloadTick ||
        oldWidget.projectId != widget.projectId) {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final project = await widget.session.api!.fetchProject(widget.projectId);
      final tasks = await widget.session.api!.fetchProjectTasks(
        widget.projectId,
      );
      if (mounted) {
        setState(() {
          _project = project;
          _tasks = tasks;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _newTask() async {
    final project = _project;
    if (project == null) return;
    final created = await showNewTaskDialog(
      context,
      widget.session,
      projectId: project.id,
      members: project.members,
    );
    if (created != null) _load();
  }

  Future<void> _openTask(Task task) async {
    await showTaskDetailDialog(context, widget.session, task.id);
    if (mounted) _load();
  }

  Future<void> _addMembers() async {
    final project = _project;
    if (project == null) return;
    final all = await widget.session.fetchTeamMembers();
    if (!mounted) return;
    final existing = project.members.map((m) => m.id).toSet();
    final candidates = all.where((u) => !existing.contains(u.id)).toList();
    if (candidates.isEmpty) {
      showAppToast(context, '이미 팀원이 모두 참여 중입니다.');
      return;
    }
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (_) =>
          _MemberPickDialog(session: widget.session, candidates: candidates),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    try {
      await widget.session.api!.addProjectMembers(project.id, picked);
      _load();
    } catch (e) {
      if (mounted) showAppToast(context, '구성원을 추가하지 못했습니다: $e');
    }
  }

  Future<void> _deleteProject() async {
    final project = _project;
    if (project == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('프로젝트 삭제'),
        content: Text('"${project.name}"의 업무와 댓글이 모두 삭제됩니다. 되돌릴 수 없습니다.'),
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
      await widget.session.api!.deleteProject(project.id);
      widget.onDeleted();
    } catch (e) {
      if (mounted) showAppToast(context, '삭제하지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final project = _project;
    final tasks = _tasks;
    if (project == null || tasks == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final hint = Theme.of(context).hintColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (project.description != null &&
                        project.description!.isNotEmpty)
                      Text(
                        project.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: hint),
                      ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        for (final member in project.members.take(6))
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: UserAvatar(
                              user: member,
                              resolveUrl: widget.session.resolveUrl,
                              radius: 11,
                            ),
                          ),
                        if (project.members.length > 6)
                          Text(
                            '+${project.members.length - 6}',
                            style: Theme.of(
                              context,
                            ).textTheme.labelSmall?.copyWith(color: hint),
                          ),
                        const SizedBox(width: 4),
                        if (project.isOwner ||
                            widget.session.canManageCurrentTeam)
                          IconButton(
                            icon: const Icon(Icons.person_add_alt_1, size: 16),
                            tooltip: '구성원 추가',
                            visualDensity: VisualDensity.compact,
                            onPressed: _addMembers,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: _newTask,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('새 업무'),
              ),
              if (project.isOwner || widget.session.canManageCurrentTeam)
                PopupMenuButton<void>(
                  icon: const Icon(Icons.more_vert),
                  tooltip: '프로젝트 메뉴',
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      onTap: _deleteProject,
                      child: const Row(
                        children: [
                          Icon(Icons.delete_outline, color: Colors.redAccent),
                          SizedBox(width: 8),
                          Text(
                            '프로젝트 삭제',
                            style: TextStyle(color: Colors.redAccent),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: tasks.isEmpty
              ? const EmptyHint('아직 등록된 업무가 없습니다. "새 업무"로 시작해보세요.')
              : MutedScrollbar(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                    children: [
                      for (final status in TaskStatus.values)
                        _StatusSection(
                          status: status,
                          tasks: tasks.where((t) => t.status == status).toList(),
                          onOpen: _openTask,
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// 상태 하나(할 일/진행 중/완료)와 그 업무들.
class _StatusSection extends StatelessWidget {
  final TaskStatus status;
  final List<Task> tasks;
  final ValueChanged<Task> onOpen;
  const _StatusSection({
    required this.status,
    required this.tasks,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              TaskStatusChip(status: status),
              const SizedBox(width: 8),
              Text(
                '${tasks.length}',
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final task in tasks)
            TaskRow(task: task, onTap: () => onOpen(task), showProject: false),
        ],
      ),
    );
  }
}

/// "내 업무" — 팀 전체에서 내가 담당자인 업무를 한 목록으로.
class MyTasksView extends StatefulWidget {
  final Session session;
  final String teamId;
  final int reloadTick;

  const MyTasksView({
    super.key,
    required this.session,
    required this.teamId,
    required this.reloadTick,
  });

  @override
  State<MyTasksView> createState() => _MyTasksViewState();
}

class _MyTasksViewState extends State<MyTasksView> {
  List<Task>? _tasks;
  String? _error;

  /// null이면 전체.
  TaskStatus? _filter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MyTasksView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadTick != widget.reloadTick) _load();
  }

  Future<void> _load() async {
    try {
      final tasks = await widget.session.api!.fetchMyTasks(widget.teamId);
      if (mounted) {
        setState(() {
          _tasks = tasks;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final all = _tasks;
    if (all == null) return const Center(child: CircularProgressIndicator());
    final tasks = _filter == null
        ? all
        : all.where((t) => t.status == _filter).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: Text('전체 ${all.length}'),
                selected: _filter == null,
                onSelected: (_) => setState(() => _filter = null),
              ),
              for (final status in TaskStatus.values)
                ChoiceChip(
                  label: Text(
                    '${taskStatusLabel(status)} ${all.where((t) => t.status == status).length}',
                  ),
                  selected: _filter == status,
                  onSelected: (_) => setState(() => _filter = status),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: tasks.isEmpty
              ? const EmptyHint('담당한 업무가 없습니다')
              : MutedScrollbar(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    children: [
                      for (final task in tasks)
                        TaskRow(
                          task: task,
                          onTap: () async {
                            await showTaskDetailDialog(
                              context,
                              widget.session,
                              task.id,
                            );
                            if (mounted) _load();
                          },
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// 팀원 중에서 프로젝트에 추가할 사람을 고르는 작은 창.
class _MemberPickDialog extends StatefulWidget {
  final Session session;
  final List<dynamic> candidates;
  const _MemberPickDialog({required this.session, required this.candidates});

  @override
  State<_MemberPickDialog> createState() => _MemberPickDialogState();
}

class _MemberPickDialogState extends State<_MemberPickDialog> {
  final _selected = <String>{};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('구성원 추가'),
      content: SizedBox(
        width: 360,
        height: 360,
        child: MutedScrollbar(
          child: ListView(
            children: [
              for (final user in widget.candidates)
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
                      Flexible(child: Text(user.name as String)),
                    ],
                  ),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selected.add(user.id as String);
                    } else {
                      _selected.remove(user.id);
                    }
                  }),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selected.toList()),
          child: const Text('추가'),
        ),
      ],
    );
  }
}
