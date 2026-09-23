import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/muted_scrollbar.dart';
import 'browse_projects_dialog.dart';
import 'project_detail_view.dart';
import 'my_tasks_view.dart';
import 'notes_view.dart';
import 'project_notifications.dart';
import 'project_search.dart';
import 'project_forms.dart';
import 'project_home_view.dart';
import 'task_detail_panel.dart';
import 'team_tasks_view.dart';

/// "프로젝트" 창 — 토픽(대화)과 별개로 업무를 계획·추적하는 공간. 상단 툴바의 과녁 아이콘
/// 버튼으로 연다. 왼쪽 사이드바(홈/내 업무/캘린더/간트차트/노트 + 프로젝트 목록)와 오른쪽
/// 내용이 함께 움직이는 구조는 항상 같지만, 그걸 담는 그릇은 플랫폼마다 다르다 — Windows는
/// 독립된 OS 창(project_window.dart의 openProjectWindow, 작업표시줄에 따로 뜨고 최소화/
/// 최대화/리사이즈가 된다), 그 외(안드로이드)는 지금처럼 큰 대화상자(showProjectDialog).
///
/// 1단계에서는 홈(대시보드)/내 업무/프로젝트별 업무 목록까지만 실제로 동작하고, 캘린더·
/// 간트차트·노트는 자리만 잡아둔다(다음 단계).
Future<void> showProjectDialog(BuildContext context, Session session) {
  return showDialog<void>(
    context: context,
    builder: (_) => ProjectDialog(session: session),
  );
}

/// 지금 오른쪽에 무엇을 그리고 있는지.
enum ProjectView { home, myTasks, calendar, gantt, notes, project }

/// 이 폭 이하로 창이 좁아지면 왼쪽 메뉴(홈/내 업무/캘린더/…/프로젝트 목록)를 고정 220px로
/// 나란히 두는 대신, 메신저 본창과 같은 방식으로 얇은 » 스트립으로 접어두고 누를 때만 내용
/// 위로 겹쳐서 보여준다. 표도 이 아래에서는 좁은 화면용(업무 + 상태만)으로 바뀐다.
const kProjectNarrowBreakpoint = 800.0;

class ProjectDialog extends StatefulWidget {
  final Session session;

  /// Windows에서 진짜 OS 창(project_window.dart)에 이 내용을 그대로 채울 때 true — 그러면
  /// 대화상자(Dialog)로 안 감싸고 창 크기에 맞춰 꽉 채우며, 내용 안의 수동 닫기 버튼도
  /// 그리지 않는다(OS 타이틀바의 기본 닫기 버튼이 대신한다).
  final bool embedInWindow;

  const ProjectDialog({
    super.key,
    required this.session,
    this.embedInWindow = false,
  });

  @override
  State<ProjectDialog> createState() => _ProjectDialogState();
}

class _ProjectDialogState extends State<ProjectDialog> {
  /// 창이 좁아 접어둔 왼쪽 메뉴가 지금 겹쳐서 펼쳐져 있는지.
  bool _sidebarOverlayOpen = false;

  /// 오른쪽에 열어둔 업무 상세 패널 — null이면 안 열린 상태.
  String? _openTaskId;
  bool _taskExpanded = false;

  void _openTask(String taskId) => setState(() => _openTaskId = taskId);

  ProjectView _view = ProjectView.home;
  String? _projectId; // _view == ProjectView.project일 때만 의미 있다.

  List<Project>? _projects;
  List<Project> _archivedProjects = const [];
  String? _error;

  /// 내가 참여 중인 프로젝트에서 뭔가 바뀌면(다른 사람이 업무를 만들거나 댓글을 달아도)
  /// 지금 보고 있는 화면을 다시 불러온다. 무엇이 바뀌었는지는 구분하지 않는다(chat_socket.dart).
  StreamSubscription<void>? _changedSub;

  /// 자식 화면(홈/업무 목록)에게 "다시 불러와라"라고 알리는 값 — 이 값이 바뀔 때마다
  /// 자식이 didUpdateWidget에서 자기 데이터를 새로 받아온다.
  int _reloadTick = 0;

  String? get _teamId => widget.session.currentTeam?.id;

  @override
  void initState() {
    super.initState();
    _loadProjects();
    _changedSub = widget.session.chatSocket.projectChanged.listen((_) {
      if (!mounted) return;
      _loadProjects();
      setState(() => _reloadTick++);
    });
  }

  @override
  void dispose() {
    _changedSub?.cancel();
    super.dispose();
  }

  Future<void> _loadProjects() async {
    final teamId = _teamId;
    if (teamId == null) {
      setState(() => _error = '먼저 팀을 선택하세요.');
      return;
    }
    try {
      final api = widget.session.api!;
      final list = await api.fetchProjects(teamId);
      final archived = await api.fetchProjects(teamId, archived: true);
      if (!mounted) return;
      setState(() {
        _projects = list;
        _archivedProjects = archived;
        _error = null;
        // 열어둔 프로젝트가 사라졌으면(삭제되었거나 제외됨) 홈으로 돌아간다.
        if (_projectId != null &&
            !list.any((p) => p.id == _projectId) &&
            !archived.any((p) => p.id == _projectId)) {
          _view = ProjectView.home;
          _projectId = null;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _select(ProjectView view, {String? projectId}) {
    setState(() {
      _view = view;
      _projectId = projectId;
    });
  }

  /// 알림함에서 알림을 눌렀을 때 — 그 프로젝트를 열고, 업무 알림이면 업무 상세도 띄운다.
  void _openNotification(ProjectNotification n) {
    if (_projects?.any((p) => p.id == n.projectId) != true) {
      showAppToast(context, '더 이상 참여 중이 아닌 프로젝트입니다.');
      return;
    }
    _select(ProjectView.project, projectId: n.projectId);
    if (n.taskId != null) {
      showTaskDetailDialog(context, widget.session, n.taskId!);
    }
  }

  /// 공개 프로젝트 둘러보기 — 참여하면 목록을 새로 받아 그 프로젝트를 바로 연다.
  Future<void> _browseProjects() async {
    final teamId = _teamId;
    if (teamId == null) return;
    final joined = await showBrowseProjectsDialog(
      context,
      widget.session,
      teamId,
    );
    if (joined == null || !mounted) return;
    await _loadProjects();
    if (mounted) _select(ProjectView.project, projectId: joined.id);
  }

  Future<void> _createProject() async {
    final teamId = _teamId;
    if (teamId == null) return;
    final created = await showNewProjectDialog(context, widget.session, teamId);
    if (created == null || !mounted) return;
    await _loadProjects();
    if (mounted) _select(ProjectView.project, projectId: created.id);
  }

  Future<void> _toggleFavorite(Project project) async {
    final next = !project.favorite;
    setState(() => project.favorite = next); // 먼저 반영하고(즉각), 실패하면 되돌린다.
    try {
      await widget.session.api!.setProjectFavorite(project.id, next);
      await _loadProjects();
    } catch (e) {
      if (!mounted) return;
      setState(() => project.favorite = !next);
      showAppToast(context, '즐겨찾기를 바꾸지 못했습니다: $e');
    }
  }

  /// 검색 결과를 눌렀을 때 — 그 업무가 속한 프로젝트를 열고 업무 상세를 띄운다.
  void _openSearchHit(Task task) {
    if (_projects?.any((p) => p.id == task.projectId) == true) {
      _select(ProjectView.project, projectId: task.projectId);
    }
    showTaskDetailDialog(context, widget.session, task.id);
  }

  /// 창 맨 위 줄 — 왼쪽 로고, 가운데 검색칸, 오른쪽 알림 종(+대화상자일 때 닫기).
  /// 검색칸은 좌우 버튼 너비와 상관없이 창 정가운데에 오도록 Stack으로 겹쳐 놓는다.
  Widget _buildTopBar(BuildContext context) {
    final teamId = _teamId;
    return SizedBox(
      height: 56,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final searchWidth = math.min(520.0, constraints.maxWidth - 500);
          return Stack(
            children: [
              if (teamId != null && searchWidth >= 200)
                Positioned.fill(
                  child: Center(
                    child: SizedBox(
                      width: searchWidth,
                      child: ProjectSearchField(
                        session: widget.session,
                        teamId: teamId,
                        onOpen: _openSearchHit,
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 16,
                top: 0,
                bottom: 0,
                child: Row(
                  children: [
                    Icon(
                      Icons.track_changes,
                      size: 22,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '프로젝트',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                right: 8,
                top: 0,
                bottom: 0,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ProjectNotificationsBell(
                      session: widget.session,
                      onOpen: _openNotification,
                    ),
                    if (!widget.embedInWindow)
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: '닫기',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 왼쪽 메뉴 — 넓으면 나란히, 좁으면 » 스트립으로 접어두고 겹쳐서 펼친다(메신저 본창과 동일).
  /// [contentOverride]를 주면 오른쪽 내용 자리를 그걸로 바꾼다 — 업무 패널을 "크게 보기"로
  /// 열 때 쓴다(왼쪽 메뉴와 상단 바는 그대로 두고 내용 자리만 패널이 차지한다).
  Widget _buildBodyRow(
    BuildContext context,
    double width, [
    Widget? contentOverride,
  ]) {
    final sidebar = _Sidebar(
      session: widget.session,
      projects: _projects,
      archivedProjects: _archivedProjects,
      view: _view,
      projectId: _projectId,
      onSelect: (view, {String? projectId}) {
        // 겹쳐 뜬 메뉴에서 골랐으면 고르는 즉시 접는다.
        if (_sidebarOverlayOpen) setState(() => _sidebarOverlayOpen = false);
        _select(view, projectId: projectId);
      },
      onCreateProject: _createProject,
      onBrowse: _browseProjects,
      onToggleFavorite: _toggleFavorite,
    );
    final narrow = width <= kProjectNarrowBreakpoint;
    final content = contentOverride ?? _buildContent(context, narrow);

    if (!narrow) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 220, child: sidebar),
          const VerticalDivider(width: 1),
          Expanded(child: content),
        ],
      );
    }

    return Stack(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SidebarToggleStrip(
              expanded: _sidebarOverlayOpen,
              onTap: () =>
                  setState(() => _sidebarOverlayOpen = !_sidebarOverlayOpen),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: GestureDetector(
                // 메뉴가 펼쳐진 동안 내용 쪽을 누르면 그 클릭이 안쪽 버튼으로 새지 않고
                // 메뉴만 접히게 한다.
                behavior: HitTestBehavior.translucent,
                onTap: _sidebarOverlayOpen
                    ? () => setState(() => _sidebarOverlayOpen = false)
                    : null,
                child: IgnorePointer(
                  ignoring: _sidebarOverlayOpen,
                  child: content,
                ),
              ),
            ),
          ],
        ),
        // 스트립(28px) 바로 옆에서 시작해 내용 위로 겹쳐 뜬다 — 스트립은 안 가려서 다시 접을 수 있다.
        if (_sidebarOverlayOpen)
          Positioned(
            left: 28,
            top: 0,
            bottom: 0,
            width: 220,
            child: Material(elevation: 8, child: sidebar),
          ),
      ],
    );
  }

  /// 업무 상세 패널을 곁들인 창 내용. 좁은 창에서는 나란히 둘 자리가 없어 늘 넓은 모드로 연다.
  Widget? _taskPanel() {
    final taskId = _openTaskId;
    if (taskId == null) return null;
    return TaskDetailPanel(
      key: ValueKey(taskId),
      session: widget.session,
      taskId: taskId,
      expanded: _taskExpanded,
      onToggleExpand: () => setState(() => _taskExpanded = !_taskExpanded),
      onClose: () => setState(() => _openTaskId = null),
      onOpenTask: _openTask,
      // 업무를 고치면 뒤에 있는 목록·대시보드도 같이 다시 읽는다.
      onChanged: () => setState(() => _reloadTick++),
    );
  }

  /// 상단 바 아래 영역 — 왼쪽 메뉴 + 내용, 그리고 업무 패널.
  ///
  /// 패널은 상단 바(로고·검색·알림 종)를 덮지 않고 그 아래에서 시작한다. 평소(미니)에는
  /// 내용 오른쪽에 나란히 붙고, **크게 보기**나 좁은 창에서는 왼쪽 메뉴는 그대로 둔 채
  /// 내용 자리만 패널이 차지한다.
  Widget _buildBodyArea(Widget? panel) => LayoutBuilder(
    builder: (context, constraints) {
      final asContent =
          panel != null && (_taskExpanded || constraints.maxWidth < 760);
      // 패널을 옆에 세우면 그만큼 본문이 좁아진다 — 왼쪽 메뉴 접힘 판단도 그 폭으로 한다.
      final bodyWidth = panel == null || asContent
          ? constraints.maxWidth
          : constraints.maxWidth - kTaskPanelWidth - 1;
      final body = _buildBodyRow(context, bodyWidth, asContent ? panel : null);
      if (panel == null || asContent) return body;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: body),
          const VerticalDivider(width: 1),
          SizedBox(width: kTaskPanelWidth, child: panel),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final content = TaskPanelScope(
      openTask: _openTask,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTopBar(context),
          const Divider(height: 1),
          Expanded(child: _buildBodyArea(_taskPanel())),
        ],
      ),
    );
    if (widget.embedInWindow) {
      return Scaffold(body: content);
    }
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080, maxHeight: 760),
        child: content,
      ),
    );
  }

  Widget _buildContent(BuildContext context, bool narrow) {
    final teamId = _teamId;
    if (_error != null) return Center(child: Text(_error!));
    if (teamId == null) {
      return const Center(child: Text('먼저 팀을 선택하세요.'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 화면 제목은 각 화면이 직접 크게 그린다(내 업무/캘린더/간트차트/노트). 여기서는
        // 프로젝트 상세일 때만 프로젝트 이름을 얹는다 — 그 화면엔 이름을 보여줄 자리가 없다.
        if (_view == ProjectView.project)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              _titleFor(_view),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          )
        else
          const SizedBox(height: 12),
        Expanded(child: _buildBody(context, teamId, narrow)),
      ],
    );
  }

  String _titleFor(ProjectView view) => switch (view) {
    ProjectView.home => '홈',
    ProjectView.myTasks => '내 업무',
    ProjectView.calendar => '캘린더',
    ProjectView.gantt => '간트차트',
    ProjectView.notes => '노트',
    ProjectView.project =>
      _projects
              ?.where((p) => p.id == _projectId)
              .map((p) => p.name)
              .firstOrNull ??
          '프로젝트',
  };

  Widget _buildBody(BuildContext context, String teamId, bool narrow) {
    switch (_view) {
      case ProjectView.home:
        return ProjectHomeView(
          session: widget.session,
          teamId: teamId,
          reloadTick: _reloadTick,
          onOpenProject: (id) => _select(ProjectView.project, projectId: id),
          onOpenMyTasks: () => _select(ProjectView.myTasks),
        );
      case ProjectView.myTasks:
        return MyTasksView(
          session: widget.session,
          teamId: teamId,
          reloadTick: _reloadTick,
          narrow: narrow,
        );
      case ProjectView.project:
        final id = _projectId;
        if (id == null) return const SizedBox.shrink();
        return ProjectDetailView(
          // 일부러 key를 안 준다 — 프로젝트를 바꿔도 State가 유지되어 보던 탭(대시보드 등)이
          // 그대로 남는다. 프로젝트별 데이터는 ProjectDetailView가 스스로 비우고 다시 읽는다.
          session: widget.session,
          projectId: id,
          reloadTick: _reloadTick,
          onDeleted: () {
            _select(ProjectView.home);
            _loadProjects();
          },
        );
      case ProjectView.calendar:
        return TeamTasksView(
          session: widget.session,
          teamId: teamId,
          reloadTick: _reloadTick,
          gantt: false,
        );
      case ProjectView.gantt:
        return TeamTasksView(
          session: widget.session,
          teamId: teamId,
          reloadTick: _reloadTick,
          gantt: true,
        );
      case ProjectView.notes:
        return NotesView(
          session: widget.session,
          teamId: teamId,
          reloadTick: _reloadTick,
        );
    }
  }
}

/// 왼쪽 사이드바 — 고정 메뉴(홈/내 업무/캘린더/간트차트/노트) + 내 프로젝트 목록.
class _Sidebar extends StatefulWidget {
  final Session session;
  final List<Project>? projects;
  final List<Project> archivedProjects;
  final ProjectView view;
  final String? projectId;
  final void Function(ProjectView view, {String? projectId}) onSelect;
  final VoidCallback onCreateProject;
  final VoidCallback onBrowse;
  final ValueChanged<Project> onToggleFavorite;

  const _Sidebar({
    required this.session,
    required this.projects,
    required this.archivedProjects,
    required this.view,
    required this.projectId,
    required this.onSelect,
    required this.onCreateProject,
    required this.onBrowse,
    required this.onToggleFavorite,
  });

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  // 오른쪽 내용도 스크롤 뷰라, 사이드바까지 기본(Primary) 컨트롤러를 같이 쓰면 스크롤바가
  // "한 컨트롤러에 스크롤 위치가 여럿"이라며 그리지 못한다 — 사이드바는 자기 것을 쓴다.
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Session get session => widget.session;
  List<Project>? get projects => widget.projects;
  List<Project> get archivedProjects => widget.archivedProjects;
  ProjectView get view => widget.view;
  String? get projectId => widget.projectId;
  void Function(ProjectView view, {String? projectId}) get onSelect =>
      widget.onSelect;
  VoidCallback get onCreateProject => widget.onCreateProject;
  VoidCallback get onBrowse => widget.onBrowse;
  ValueChanged<Project> get onToggleFavorite => widget.onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final list = projects ?? const <Project>[];
    final favorites = list.where((p) => p.favorite).toList();
    final others = list.where((p) => !p.favorite).toList();

    // ColoredBox가 아니라 Material로 칠한다 — 사이 배경이 ColoredBox면 ListTile의 선택 색과
    // 클릭 효과가 그 뒤에 가려서 안 보인다(Flutter가 assert로 경고한다).
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: MutedScrollbar(
        controller: _scroll,
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            _SidebarItem(
              icon: Icons.home_outlined,
              label: '홈',
              selected: view == ProjectView.home,
              onTap: () => onSelect(ProjectView.home),
            ),
            _SidebarItem(
              icon: Icons.checklist_outlined,
              label: '내 업무',
              selected: view == ProjectView.myTasks,
              onTap: () => onSelect(ProjectView.myTasks),
            ),
            _SidebarItem(
              icon: Icons.calendar_today_outlined,
              label: '캘린더',
              selected: view == ProjectView.calendar,
              onTap: () => onSelect(ProjectView.calendar),
            ),
            _SidebarItem(
              icon: Icons.view_timeline_outlined,
              label: '간트차트',
              selected: view == ProjectView.gantt,
              onTap: () => onSelect(ProjectView.gantt),
            ),
            _SidebarItem(
              icon: Icons.description_outlined,
              label: '노트',
              selected: view == ProjectView.notes,
              onTap: () => onSelect(ProjectView.notes),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '프로젝트',
                      style: Theme.of(
                        context,
                      ).textTheme.labelMedium?.copyWith(color: hint),
                    ),
                  ),
                  if (session.canCreateProject)
                    IconButton(
                      icon: const Icon(Icons.add, size: 18),
                      tooltip: '프로젝트 생성',
                      visualDensity: VisualDensity.compact,
                      onPressed: onCreateProject,
                    ),
                ],
              ),
            ),
            _SidebarItem(
              icon: Icons.explore_outlined,
              label: '공개 프로젝트 찾기',
              selected: false,
              onTap: onBrowse,
            ),
            if (projects == null)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(
                  session.canCreateProject
                      ? '아직 참여 중인 프로젝트가 없습니다. 위 + 로 만들어보세요.'
                      : '아직 참여 중인 프로젝트가 없습니다.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: hint),
                ),
              ),
            if (favorites.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  '즐겨찾기 ${favorites.length}',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: hint),
                ),
              ),
              for (final project in favorites)
                _ProjectItem(
                  project: project,
                  selected:
                      view == ProjectView.project && projectId == project.id,
                  onTap: () =>
                      onSelect(ProjectView.project, projectId: project.id),
                  onToggleFavorite: () => onToggleFavorite(project),
                ),
              const Divider(indent: 16, endIndent: 16, height: 20),
            ],
            for (final project in others)
              _ProjectItem(
                project: project,
                selected:
                    view == ProjectView.project && projectId == project.id,
                onTap: () =>
                    onSelect(ProjectView.project, projectId: project.id),
                onToggleFavorite: () => onToggleFavorite(project),
              ),
            if (archivedProjects.isNotEmpty)
              ExpansionTile(
                dense: true,
                shape: const Border(),
                collapsedShape: const Border(),
                initiallyExpanded: archivedProjects.any(
                  (p) => view == ProjectView.project && projectId == p.id,
                ),
                title: Text(
                  '종료된 프로젝트 ${archivedProjects.length}',
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: hint),
                ),
                children: [
                  for (final p in archivedProjects)
                    ListTile(
                      dense: true,
                      selected:
                          view == ProjectView.project && projectId == p.id,
                      leading: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: parseTypeColor(p.color).withValues(alpha: 0.5),
                          shape: BoxShape.circle,
                        ),
                      ),
                      title: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: hint),
                      ),
                      onTap: () =>
                          onSelect(ProjectView.project, projectId: p.id),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 20),
      title: Text(label),
      selected: selected,
      selectedTileColor: Theme.of(
        context,
      ).colorScheme.primaryContainer.withValues(alpha: 0.4),
      onTap: onTap,
    );
  }
}

/// 사이드바의 프로젝트 한 줄 — 마우스를 올리면 즐겨찾기 별이 나타난다(방 목록과 같은 방식).
class _ProjectItem extends StatefulWidget {
  final Project project;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  const _ProjectItem({
    required this.project,
    required this.selected,
    required this.onTap,
    required this.onToggleFavorite,
  });

  @override
  State<_ProjectItem> createState() => _ProjectItemState();
}

class _ProjectItemState extends State<_ProjectItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final showStar = _hovering || widget.project.favorite;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.only(left: 16, right: 4),
        horizontalTitleGap: 10,
        // 만들 때 고른 대표 색상 — 사이드바에서 프로젝트를 한눈에 구분하게 한다.
        leading: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: parseTypeColor(widget.project.color),
            shape: BoxShape.circle,
          ),
        ),
        minLeadingWidth: 10,
        title: Text(
          widget.project.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        selected: widget.selected,
        selectedTileColor: Theme.of(
          context,
        ).colorScheme.primaryContainer.withValues(alpha: 0.4),
        trailing: Opacity(
          opacity: showStar ? 1 : 0,
          child: IconButton(
            icon: Icon(
              widget.project.favorite ? Icons.star : Icons.star_border,
              size: 16,
              color: widget.project.favorite ? Colors.amber : null,
            ),
            visualDensity: VisualDensity.compact,
            tooltip: widget.project.favorite ? '즐겨찾기 해제' : '즐겨찾기',
            onPressed: widget.onToggleFavorite,
          ),
        ),
        onTap: widget.onTap,
      ),
    );
  }
}

/// 왼쪽 메뉴가 접혔을 때(창 폭 <= [kProjectNarrowBreakpoint]) 대신 보이는 얇은 화살표 스트립.
/// 접힌 상태(»)를 누르면 메뉴가 겹침 오버레이로 뜨고, 펼쳐진 상태(«)를 누르면 다시 접힌다 —
/// 메신저 본창(desktop_home_screen.dart)의 _SidebarToggleStrip과 같은 모양·동작이다.
class _SidebarToggleStrip extends StatelessWidget {
  final bool expanded;
  final VoidCallback onTap;
  const _SidebarToggleStrip({required this.expanded, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: InkWell(
          onTap: onTap,
          child: Center(
            child: Icon(
              expanded
                  ? Icons.keyboard_double_arrow_left
                  : Icons.keyboard_double_arrow_right,
              size: 18,
              color: Theme.of(context).hintColor,
            ),
          ),
        ),
      ),
    );
  }
}
