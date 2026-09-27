import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'notes_view.dart';
import 'project_menu_dialog.dart';
import 'project_forms.dart';
import 'project_views.dart';
import 'project_widgets.dart';
import 'task_detail_panel.dart' show TaskPanelScope;
import 'task_views.dart';
import 'task_filter.dart';
import 'gantt_chart_view.dart';

/// 프로젝트 하나의 업무 목록 — 상태별(할 일/진행 중/완료)로 묶어서 보여준다.
/// 칸반보드(드래그로 상태 이동)는 다음 단계이고, 지금은 같은 데이터를 목록으로 본다.
class ProjectDetailView extends StatefulWidget {
  final Session session;
  final String projectId;
  final int reloadTick;
  final VoidCallback onDeleted;

  /// 프로젝트 설정을 닫았을 때(이름·설명·색이 바뀌었을 수 있다) — 바깥 머리를 새로 그리게.
  final VoidCallback? onProjectChanged;

  /// 맨 윗줄 왼쪽의 프로젝트 머리(색 막대·이름·즐겨찾기·설명) — 오른쪽에 "새 업무"·설정 버튼.
  final Widget? header;

  const ProjectDetailView({
    super.key,
    required this.session,
    required this.projectId,
    required this.reloadTick,
    required this.onDeleted,
    this.onProjectChanged,
    this.header,
    this.listTabTick = 0,
  });

  /// 바뀔 때마다(0이 아니면 처음 만들 때도) 리스트 탭으로 옮긴다 — 업무 링크로 열었을 때.
  final int listTabTick;

  @override
  State<ProjectDetailView> createState() => _ProjectDetailViewState();
}

/// 프로젝트 안에서 업무를 보는 방식 — 같은 업무를 다섯 가지 모양으로 본다.
enum _ProjectTab { dashboard, kanban, list, gantt, calendar, notes }

class _ProjectDetailViewState extends State<ProjectDetailView> {
  /// 처음 열면 대시보드부터(다른 프로젝트로 바꿀 때는 보던 탭을 그대로 둔다 — didUpdateWidget).
  _ProjectTab _tab = _ProjectTab.dashboard;
  Project? _project;
  List<Task>? _tasks;
  List<TaskStatusDef> _statuses = const [];
  List<TaskFieldDef> _fields = const [];
  List<TaskPriorityDef> _priorities = const [];
  List<TaskType> _types = const [];
  TaskFilter _filter = const TaskFilter();

  /// 지금 탭에 실제로 거는 필터 — 칸반보드는 열이 곧 상태라 상태 조건은 빼고 본다(지우지는 않고
  /// 다른 탭으로 가면 다시 걸린다).
  TaskFilter get _viewFilter =>
      _tab == _ProjectTab.kanban ? _filter.without(statuses: true) : _filter;

  /// 필터 버튼·칩에서 바꾼 값 — 칸반에서는 숨겨 둔 상태 조건을 그대로 둔다.
  void _setFilter(TaskFilter f) => setState(
    () => _filter = _tab == _ProjectTab.kanban
        ? f.withStatusIds(_filter.statusIds)
        : f,
  );
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.listTabTick != 0) _tab = _ProjectTab.list;
    _load();
  }

  @override
  void didUpdateWidget(ProjectDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listTabTick != widget.listTabTick) _tab = _ProjectTab.list;
    if (oldWidget.projectId != widget.projectId) {
      // 다른 프로젝트로 바뀌면 앞 프로젝트 내용이 잠깐이라도 새 이름 아래 보이면 안 된다.
      // 필터도 앞 프로젝트의 상태·유형·필드 id를 가리키고 있어 같이 비운다(탭은 유지).
      _project = null;
      _tasks = null;
      _statuses = const [];
      _fields = const [];
      _types = const [];
      _priorities = const [];
      _filter = const TaskFilter();
    }
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
      final priorities = await widget.session.api!.fetchTaskPriorities(
        widget.projectId,
      );
      if (mounted) {
        setState(() {
          _project = project;
          _tasks = tasks;
          _statuses = statuses;
          _fields = fields;
          _types = types;
          _priorities = priorities;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// [statusId]를 주면(칸반 열의 "+") 그 상태를 골라둔 채 연다.
  Future<void> _newTask({String? statusId}) async {
    final project = _project;
    if (project == null) return;
    // 지금 프로젝트로 골라둔 채 열되, 창 안에서 다른 프로젝트로 바꿀 수도 있게 팀의 프로젝트
    // 목록을 함께 넘긴다(목록을 못 불러와도 이 프로젝트로는 만들 수 있게 그냥 진행한다).
    List<Project> projects = const [];
    try {
      projects = await widget.session.api!.fetchProjects(project.teamId);
    } catch (_) {}
    if (!mounted) return;
    final created = await showNewTaskDialog(
      context,
      widget.session,
      projects: projects,
      projectId: project.id,
      projectName: project.name,
      members: project.members,
      initialStatusId: statusId,
    );
    if (created != null) _load();
  }

  /// 칸반보드에서 카드를 놓았을 때 — 다른 열이면([newStatus]) 상태를 바꾸고, 그 열의 순서를
  /// 저장한 뒤 다시 불러온다.
  Future<void> _moveTask(
    Task task,
    TaskStatusDef? newStatus,
    List<String> orderedIds,
  ) async {
    final api = widget.session.api!;
    try {
      if (newStatus != null) {
        await api.updateTask(task.id, statusId: newStatus.id);
      }
      await api.reorderTasks(task.projectId, orderedIds);
    } catch (e) {
      if (mounted) showAppToast(context, '업무를 옮기지 못했습니다: $e');
    }
    if (mounted) await _load();
  }

  Future<void> _openTask(Task task) async {
    await showTaskDetailDialog(context, widget.session, task.id);
    if (mounted) _load();
  }

  /// 대시보드의 숫자 카드를 눌렀을 때 — 리스트 탭으로 옮기고 그 조건 하나만 건다.
  void _applyQuick(QuickFilter? quick) => setState(() {
    _filter = const TaskFilter().copyQuick(quick);
    _tab = _ProjectTab.list;
  });

  Future<void> _openMenu() async {
    final result = await showProjectMenuDialog(
      context,
      widget.session,
      widget.projectId,
    );
    if (!mounted) return;
    if (result == ProjectMenuResult.deleted) {
      widget.onDeleted();
    } else {
      // 상태·필드·유형을 바꿨을 수 있으니 닫으면 항상 다시 읽는다.
      _load();
      widget.onProjectChanged?.call();
    }
  }

  Widget _buildView(Project project, List<Task> allTasks) {
    final filter = _viewFilter;
    final tasks = filter.isEmpty
        ? allTasks
        : [
            for (final t in allTasks)
              if (filter.matches(
                t,
                myUserId: widget.session.userId,
                statuses: _statuses,
                priorities: _priorities,
                fields: _fields,
              ))
                t,
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
        // 대시보드는 필터와 무관하게 늘 프로젝트 전체를 센다 — 숫자 카드가 거는 조건이 리스트 쪽이다.
        return TaskDashboardView(
          tasks: allTasks,
          members: project.members,
          session: widget.session,
          onOpen: _openTask,
          onStatTap: _applyQuick,
        );
      case _ProjectTab.kanban:
        return TaskKanbanView(
          statuses: _statuses,
          readOnly: project.archived,
          tasks: tasks,
          members: project.members,
          session: widget.session,
          onOpen: _openTask,
          onMove: _moveTask,
          onAdd: (status) => _newTask(statusId: status.id),
        );
      case _ProjectTab.list:
        return TaskListTable(
          // 한 프로젝트 안이라 업무 아래 프로젝트 이름은 뺀다.
          showProjectName: false,
          tasks: tasks,
          session: widget.session,
          onOpen: _openTask,
          members: project.members,
          fields: _fields,
          readOnly: project.archived,
          onChanged: _load,
        );
      case _ProjectTab.gantt:
        // 프로젝트 안의 간트차트는 상태별로 묶는다.
        return GanttChartView(
          session: widget.session,
          tasks: tasks,
          statuses: _statuses,
          prefsKey: 'project:${widget.projectId}',
          readOnly: project.archived,
          onOpen: _openTask,
          onChanged: _load,
        );
      case _ProjectTab.calendar:
        return TaskCalendarView(
          tasks: tasks,
          onOpen: _openTask,
          session: widget.session,
        );
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 왼쪽 프로젝트 머리, 오른쪽 위 "새 업무"·설정. 멤버는 대시보드의 "멤버별 업무현황"에서
              // 보고, 초대·역할은 프로젝트 설정에서 한다.
              Expanded(child: widget.header ?? const SizedBox.shrink()),
              const SizedBox(width: 12),
              if (!project.archived)
                FilledButton.icon(
                  onPressed: _newTask,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('새 업무'),
                ),
              // 프로젝트 설정은 전부 "프로젝트 설정" 한 창에 모여 있다(기본 정보 / 필드·상태 /
              // 멤버 / 알림 / 템플릿·자동화 / 삭제).
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: '프로젝트 설정',
                onPressed: _openMenu,
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
              // 창이 좁으면 탭들이 자리를 넘겨서 노란 경고 줄무늬가 났다 — 탭 줄만 가로로 밀 수
              // 있게 한다. "노트"는 줄의 맨 오른쪽.
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final tab in _ProjectTab.values)
                        if (tab != _ProjectTab.notes)
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
                              _ProjectTab.calendar =>
                                Icons.calendar_today_outlined,
                              _ProjectTab.notes => Icons.description_outlined,
                            },
                            selected: _tab == tab,
                            onTap: () => setState(() => _tab = tab),
                          ),
                    ],
                  ),
                ),
              ),
              // "노트" — 프로젝트 창이면 오른쪽 노트 패널로 열고, 아니면(대화상자) 탭 안에.
              _ViewTab(
                label: '노트',
                icon: Icons.description_outlined,
                selected: _tab == _ProjectTab.notes,
                onTap: () {
                  final open = TaskPanelScope.maybeOf(context)?.openNotes;
                  if (open != null) {
                    open(project.id);
                  } else {
                    setState(() => _tab = _ProjectTab.notes);
                  }
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // 필터링은 탭 줄 아래(구분선 밑) 오른쪽.
        if (_tab != _ProjectTab.notes && _tab != _ProjectTab.dashboard)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: TaskFilterButton(
                filter: _viewFilter,
                statuses: _statuses,
                priorities: _priorities,
                types: _types,
                members: project.members,
                fields: _fields,
                showStatus: _tab != _ProjectTab.kanban,
                onChanged: _setFilter,
              ),
            ),
          ),
        if (_tab != _ProjectTab.notes &&
            _tab != _ProjectTab.dashboard &&
            !_viewFilter.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Wrap(
              runSpacing: 4,
              children: activeFilterChips(
                context,
                filter: _viewFilter,
                statuses: _statuses,
                priorities: _priorities,
                types: _types,
                members: project.members,
                fields: _fields,
                onChanged: _setFilter,
              ),
            ),
          ),
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
