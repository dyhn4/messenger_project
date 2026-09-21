import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/user_avatar.dart';
import 'notes_view.dart';
import 'project_notifications.dart';
import 'project_forms.dart';
import 'project_settings_dialog.dart';
import 'project_views.dart';
import 'project_widgets.dart';
import 'task_views.dart';
import 'task_config_manager.dart';
import 'task_filter.dart';
import 'template_automation_manager.dart';
import 'task_type_manager.dart';

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

/// 프로젝트 안에서 업무를 보는 방식 — 같은 업무를 다섯 가지 모양으로 본다.
enum _ProjectTab { dashboard, kanban, list, gantt, calendar, notes }

class _ProjectDetailViewState extends State<ProjectDetailView> {
  _ProjectTab _tab = _ProjectTab.list;
  Project? _project;
  List<Task>? _tasks;
  List<TaskStatusDef> _statuses = const [];
  List<TaskFieldDef> _fields = const [];
  List<TaskType> _types = const [];
  TaskFilter _filter = const TaskFilter();
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
      final statuses = await widget.session.api!.fetchTaskStatuses(
        widget.projectId,
      );
      final fields = await widget.session.api!.fetchTaskFields(
        widget.projectId,
      );
      final types = await widget.session.api!.fetchTaskTypes(widget.projectId);
      if (mounted) {
        setState(() {
          _project = project;
          _tasks = tasks;
          _statuses = statuses;
          _fields = fields;
          _types = types;
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

  /// 칸반보드에서 카드를 다른 열로 끌어다 놓았을 때 — 서버에 반영하고 다시 불러온다.
  Future<void> _changeStatus(Task task, TaskStatusDef status) async {
    try {
      await widget.session.api!.updateTask(task.id, statusId: status.id);
    } catch (e) {
      if (mounted) showAppToast(context, '상태를 바꾸지 못했습니다: $e');
    }
    if (mounted) _load();
  }

  Future<void> _openTask(Task task) async {
    await showTaskDetailDialog(context, widget.session, task.id);
    if (mounted) _load();
  }

  Future<void> _addMembers() async {
    final project = _project;
    if (project == null) return;
    if (await addMembersToProject(context, widget.session, project)) _load();
  }

  Future<void> _openFilter() async {
    final project = _project;
    if (project == null) return;
    final result = await showTaskFilterDialog(
      context,
      initial: _filter,
      statuses: _statuses,
      members: project.members,
      types: _types,
      fields: _fields,
    );
    if (result != null && mounted) setState(() => _filter = result);
  }

  Future<void> _openSettings() async {
    final result = await showProjectSettingsDialog(
      context,
      widget.session,
      widget.projectId,
    );
    if (!mounted) return;
    if (result == ProjectSettingsResult.deleted) {
      widget.onDeleted();
    } else if (result == ProjectSettingsResult.changed) {
      _load();
    }
  }

  Widget _buildView(Project project, List<Task> allTasks) {
    final tasks = _filter.isEmpty
        ? allTasks
        : [
            for (final t in allTasks)
              if (_filter.matches(t, statuses: _statuses, fields: _fields)) t,
          ];
    if (allTasks.isEmpty &&
        _tab != _ProjectTab.dashboard &&
        _tab != _ProjectTab.notes) {
      return const EmptyHint('아직 등록된 업무가 없습니다. "새 업무"로 시작해보세요.');
    }
    if (tasks.isEmpty &&
        _tab != _ProjectTab.dashboard &&
        _tab != _ProjectTab.notes) {
      return const EmptyHint('조건에 맞는 업무가 없습니다. 필터를 바꿔보세요.');
    }
    switch (_tab) {
      case _ProjectTab.dashboard:
        return TaskDashboardView(
          statuses: _statuses,
          tasks: tasks,
          members: project.members,
          session: widget.session,
          onOpen: _openTask,
        );
      case _ProjectTab.kanban:
        return TaskKanbanView(
          statuses: _statuses,
          readOnly: project.archived,
          tasks: tasks,
          members: project.members,
          session: widget.session,
          onOpen: _openTask,
          onStatusChange: _changeStatus,
        );
      case _ProjectTab.list:
        return TaskListTable(
          tasks: tasks,
          session: widget.session,
          onOpen: _openTask,
          members: project.members,
          fields: _fields,
        );
      case _ProjectTab.gantt:
        return TaskGanttView(tasks: tasks, onOpen: _openTask);
      case _ProjectTab.calendar:
        return TaskCalendarView(tasks: tasks, onOpen: _openTask);
      case _ProjectTab.notes:
        return NotesView(
          session: widget.session,
          teamId: project.teamId,
          projectId: project.id,
          reloadTick: widget.reloadTick,
        );
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
              IconButton(
                icon: const Icon(Icons.notifications_none),
                tooltip: '알림 설정',
                onPressed: () => showProjectNotificationSettingsDialog(
                  context,
                  widget.session,
                  project,
                ),
              ),
              if (!project.archived)
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
                      onTap: () => showTaskTypeManagerDialog(
                        context,
                        widget.session,
                        widget.projectId,
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.label_outline),
                          SizedBox(width: 8),
                          Text('업무 유형 관리'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      onTap: () async {
                        await showTaskConfigManagerDialog(
                          context,
                          widget.session,
                          widget.projectId,
                        );
                        if (mounted) _load();
                      },
                      child: const Row(
                        children: [
                          Icon(Icons.view_column_outlined),
                          SizedBox(width: 8),
                          Text('상태 · 필드 관리'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      onTap: () async {
                        await showTemplateAutomationManagerDialog(
                          context,
                          widget.session,
                          widget.projectId,
                        );
                        if (mounted) _load();
                      },
                      child: const Row(
                        children: [
                          Icon(Icons.bolt_outlined),
                          SizedBox(width: 8),
                          Text('템플릿 · 자동화 관리'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      onTap: _openSettings,
                      child: const Row(
                        children: [
                          Icon(Icons.settings_outlined),
                          SizedBox(width: 8),
                          Text('프로젝트 설정'),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        if (project.archived)
          Container(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.inventory_2_outlined, size: 16, color: hint),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '종료된 프로젝트입니다. 읽기만 할 수 있습니다.',
                    style: TextStyle(color: hint, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              for (final tab in _ProjectTab.values)
                _ViewTab(
                  label: switch (tab) {
                    _ProjectTab.dashboard => '대시보드',
                    _ProjectTab.kanban => '칸반보드',
                    _ProjectTab.list => '리스트',
                    _ProjectTab.gantt => '간트차트',
                    _ProjectTab.calendar => '캘린더',
                    _ProjectTab.notes => '노트',
                  },
                  icon: switch (tab) {
                    _ProjectTab.dashboard => Icons.dashboard_outlined,
                    _ProjectTab.kanban => Icons.view_kanban_outlined,
                    _ProjectTab.list => Icons.format_list_bulleted,
                    _ProjectTab.gantt => Icons.view_timeline_outlined,
                    _ProjectTab.calendar => Icons.calendar_today_outlined,
                    _ProjectTab.notes => Icons.description_outlined,
                  },
                  selected: _tab == tab,
                  onTap: () => setState(() => _tab = tab),
                ),
              const Spacer(),
              if (_tab != _ProjectTab.notes)
                TextButton.icon(
                  onPressed: _openFilter,
                  icon: const Icon(Icons.filter_list, size: 18),
                  label: Text(
                    _filter.isEmpty ? '필터' : '필터 ${_filter.activeCount}',
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildView(project, tasks)),
      ],
    );
  }
}

class _ViewTab extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _ViewTab({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final hint = Theme.of(context).hintColor;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: selected ? primary : hint),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: selected ? primary : hint,
                fontWeight: selected ? FontWeight.w600 : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 팀원 중에서 프로젝트에 추가할 사람을 고르는 작은 창.
