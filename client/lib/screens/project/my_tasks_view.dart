import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/floating_dialog.dart';
import '../../widgets/muted_scrollbar.dart';
import 'project_forms.dart';
import 'task_views.dart';

/// "내 업무" 필터. 비어 있는 항목은 "전체".
class _Filters {
  final Set<TaskStatus> statuses;
  final Set<TaskPriority> priorities;
  final String? projectId;
  final String? typeName;

  /// 'assignee'(담당) | 'reference'(참조) | null(전체)
  final String? role;
  const _Filters({
    this.statuses = const {},
    this.priorities = const {},
    this.projectId,
    this.typeName,
    this.role,
  });

  int get activeCount =>
      (statuses.isEmpty ? 0 : 1) +
      (priorities.isEmpty ? 0 : 1) +
      (projectId == null ? 0 : 1) +
      (typeName == null ? 0 : 1) +
      (role == null ? 0 : 1);

  bool matches(Task t) {
    if (statuses.isNotEmpty && !statuses.contains(t.status)) return false;
    if (priorities.isNotEmpty && !priorities.contains(t.priority)) return false;
    if (projectId != null && t.projectId != projectId) return false;
    if (typeName != null && t.typeName != typeName) return false;
    if (role != null && t.myRole != role) return false;
    return true;
  }
}

/// 프로젝트 → "내 업무": 내가 담당자이거나 참조자로 걸린 업무를 리스트/캘린더로 본다.
class MyTasksView extends StatefulWidget {
  final Session session;
  final String teamId;
  final int reloadTick;

  /// 창이 좁을 때(프로젝트 창 800px 이하) — 표 대신 업무·상태만 있는 목록으로 보여준다.
  final bool narrow;

  const MyTasksView({
    super.key,
    required this.session,
    required this.teamId,
    required this.reloadTick,
    this.narrow = false,
  });

  @override
  State<MyTasksView> createState() => _MyTasksViewState();
}

class _MyTasksViewState extends State<MyTasksView> {
  List<Task>? _tasks;
  List<Project> _projects = const [];
  String? _error;

  _Filters _filters = const _Filters();

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
      final api = widget.session.api!;
      final results = await Future.wait([
        api.fetchMyTasks(widget.teamId),
        api.fetchProjects(widget.teamId),
      ]);
      if (mounted) {
        setState(() {
          _tasks = results[0] as List<Task>;
          _projects = results[1] as List<Project>;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _openTask(Task task) async {
    await showTaskDetailDialog(context, widget.session, task.id);
    if (mounted) _load();
  }

  Future<void> _newTask() async {
    if (_projects.isEmpty) {
      showAppToast(context, '참여 중인 프로젝트가 없어서 업무를 만들 수 없습니다.');
      return;
    }
    final created = await showNewTaskDialog(
      context,
      widget.session,
      projects: _projects,
    );
    if (created != null && mounted) _load();
  }

  Future<void> _openFilter(List<Task> all) async {
    final result = await showDialog<_Filters>(
      context: context,
      builder: (_) => _FilterDialog(
        initial: _filters,
        projects: _projects,
        typeNames: {
          for (final t in all)
            if (t.typeName != null) t.typeName!,
        }.toList()..sort(),
      ),
    );
    if (result != null && mounted) setState(() => _filters = result);
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final all = _tasks;
    if (all == null) return const Center(child: CircularProgressIndicator());
    final visible = all.where(_filters.matches).toList();
    final hint = Theme.of(context).hintColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '내 업무',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '내가 담당자이거나 참조된 업무가 표시됩니다.',
                      style: TextStyle(color: hint),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: _newTask,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('새 업무'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _openFilter(all),
              icon: const Icon(Icons.filter_list, size: 18),
              label: Text(
                _filters.activeCount == 0
                    ? '필터링'
                    : '필터링 ${_filters.activeCount}',
              ),
            ),
          ),
        ),
        Expanded(
          child: TaskListTable(
            tasks: visible,
            session: widget.session,
            onOpen: _openTask,
            narrow: widget.narrow,
            emptyText: all.isEmpty ? '담당하거나 참조된 업무가 없습니다.' : '조건에 맞는 업무가 없습니다.',
            // 표에서 배지로 유형·우선순위·상태를 바꾸면 목록을 다시 읽는다.
            onChanged: _load,
          ),
        ),
      ],
    );
  }
}

// ───────────────────────── 필터 ─────────────────────────

class _FilterDialog extends StatefulWidget {
  final _Filters initial;
  final List<Project> projects;
  final List<String> typeNames;
  const _FilterDialog({
    required this.initial,
    required this.projects,
    required this.typeNames,
  });

  @override
  State<_FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends State<_FilterDialog> {
  late final _statuses = {...widget.initial.statuses};
  late final _priorities = {...widget.initial.priorities};
  late String? _projectId = widget.initial.projectId;
  late String? _typeName = widget.initial.typeName;
  late String? _role = widget.initial.role;

  Widget _section(String title, List<Widget> chips) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 6, children: chips),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return FloatingDialog(
      title: '필터링',
      maxWidth: 460,
      maxHeight: 620,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: MutedScrollbar(
              child: ListView(
                children: [
                  _section('내 역할', [
                    ChoiceChip(
                      label: const Text('전체'),
                      selected: _role == null,
                      onSelected: (_) => setState(() => _role = null),
                    ),
                    ChoiceChip(
                      label: const Text('담당'),
                      selected: _role == 'assignee',
                      onSelected: (_) => setState(() => _role = 'assignee'),
                    ),
                    ChoiceChip(
                      label: const Text('참조'),
                      selected: _role == 'reference',
                      onSelected: (_) => setState(() => _role = 'reference'),
                    ),
                  ]),
                  _section('상태', [
                    for (final s in TaskStatus.values)
                      FilterChip(
                        label: Text(taskStatusLabel(s)),
                        selected: _statuses.contains(s),
                        onSelected: (v) => setState(
                          () => v ? _statuses.add(s) : _statuses.remove(s),
                        ),
                      ),
                  ]),
                  _section('우선순위', [
                    for (final p in TaskPriority.values)
                      FilterChip(
                        label: Text(taskPriorityLabel(p)),
                        selected: _priorities.contains(p),
                        onSelected: (v) => setState(
                          () => v ? _priorities.add(p) : _priorities.remove(p),
                        ),
                      ),
                  ]),
                  if (widget.projects.isNotEmpty)
                    _section('프로젝트', [
                      ChoiceChip(
                        label: const Text('전체'),
                        selected: _projectId == null,
                        onSelected: (_) => setState(() => _projectId = null),
                      ),
                      for (final p in widget.projects)
                        ChoiceChip(
                          label: Text(p.name),
                          selected: _projectId == p.id,
                          onSelected: (_) => setState(() => _projectId = p.id),
                        ),
                    ]),
                  if (widget.typeNames.isNotEmpty)
                    _section('유형', [
                      ChoiceChip(
                        label: const Text('전체'),
                        selected: _typeName == null,
                        onSelected: (_) => setState(() => _typeName = null),
                      ),
                      for (final name in widget.typeNames)
                        ChoiceChip(
                          label: Text(name),
                          selected: _typeName == name,
                          onSelected: (_) => setState(() => _typeName = name),
                        ),
                    ]),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(const _Filters()),
                child: const Text('초기화'),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('취소'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(
                  _Filters(
                    statuses: _statuses,
                    priorities: _priorities,
                    projectId: _projectId,
                    typeName: _typeName,
                    role: _role,
                  ),
                ),
                child: const Text('적용'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
