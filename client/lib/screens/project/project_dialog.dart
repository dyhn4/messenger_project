import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/muted_scrollbar.dart';
import 'project_detail_view.dart';
import 'project_forms.dart';
import 'project_home_view.dart';

/// "프로젝트" 창 — 토픽(대화)과 별개로 업무를 계획·추적하는 공간. 상단 툴바의 과녁 아이콘
/// 버튼으로 연다. 채팅 위에 뜨는 큰 대화상자 하나 안에서 왼쪽 사이드바(홈/내 업무/캘린더/
/// 간트차트/노트 + 프로젝트 목록)와 오른쪽 내용이 함께 움직인다.
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

class ProjectDialog extends StatefulWidget {
  final Session session;
  const ProjectDialog({super.key, required this.session});

  @override
  State<ProjectDialog> createState() => _ProjectDialogState();
}

class _ProjectDialogState extends State<ProjectDialog> {
  ProjectView _view = ProjectView.home;
  String? _projectId; // _view == ProjectView.project일 때만 의미 있다.

  List<Project>? _projects;
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
      final list = await widget.session.api!.fetchProjects(teamId);
      if (!mounted) return;
      setState(() {
        _projects = list;
        _error = null;
        // 열어둔 프로젝트가 사라졌으면(삭제되었거나 제외됨) 홈으로 돌아간다.
        if (_projectId != null && !list.any((p) => p.id == _projectId)) {
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

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080, maxHeight: 760),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 220,
              child: _Sidebar(
                session: widget.session,
                projects: _projects,
                view: _view,
                projectId: _projectId,
                onSelect: _select,
                onCreateProject: _createProject,
                onToggleFavorite: _toggleFavorite,
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: _buildContent(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final teamId = _teamId;
    if (_error != null) return Center(child: Text(_error!));
    if (teamId == null) {
      return const Center(child: Text('먼저 팀을 선택하세요.'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 창 오른쪽 위 닫기 버튼 — 사이드바가 왼쪽 끝까지 차 있어서 공용 FloatingDialog의
        // 제목줄 대신 내용 쪽에 둔다.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
          child: Row(
            children: [
              Expanded(child: Text(_titleFor(_view), style: Theme.of(context).textTheme.titleMedium)),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: '닫기',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Expanded(child: _buildBody(context, teamId)),
      ],
    );
  }

  String _titleFor(ProjectView view) => switch (view) {
    ProjectView.home => '홈',
    ProjectView.myTasks => '내 업무',
    ProjectView.calendar => '캘린더',
    ProjectView.gantt => '간트차트',
    ProjectView.notes => '노트',
    ProjectView.project => _projects
            ?.where((p) => p.id == _projectId)
            .map((p) => p.name)
            .firstOrNull ??
        '프로젝트',
  };

  Widget _buildBody(BuildContext context, String teamId) {
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
        );
      case ProjectView.project:
        final id = _projectId;
        if (id == null) return const SizedBox.shrink();
        return ProjectDetailView(
          key: ValueKey(id),
          session: widget.session,
          projectId: id,
          reloadTick: _reloadTick,
          onDeleted: () {
            _select(ProjectView.home);
            _loadProjects();
          },
        );
      case ProjectView.calendar:
        return const _ComingSoon(
          icon: Icons.calendar_today_outlined,
          label: '캘린더',
        );
      case ProjectView.gantt:
        return const _ComingSoon(icon: Icons.view_timeline_outlined, label: '간트차트');
      case ProjectView.notes:
        return const _ComingSoon(icon: Icons.description_outlined, label: '노트');
    }
  }
}

/// 왼쪽 사이드바 — 고정 메뉴(홈/내 업무/캘린더/간트차트/노트) + 내 프로젝트 목록.
class _Sidebar extends StatelessWidget {
  final Session session;
  final List<Project>? projects;
  final ProjectView view;
  final String? projectId;
  final void Function(ProjectView view, {String? projectId}) onSelect;
  final VoidCallback onCreateProject;
  final ValueChanged<Project> onToggleFavorite;

  const _Sidebar({
    required this.session,
    required this.projects,
    required this.view,
    required this.projectId,
    required this.onSelect,
    required this.onCreateProject,
    required this.onToggleFavorite,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final list = projects ?? const <Project>[];
    final favorites = list.where((p) => p.favorite).toList();
    final others = list.where((p) => !p.favorite).toList();

    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: MutedScrollbar(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  Icon(
                    Icons.track_changes,
                    size: 20,
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
                      tooltip: '새 프로젝트',
                      visualDensity: VisualDensity.compact,
                      onPressed: onCreateProject,
                    ),
                ],
              ),
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
                  selected: view == ProjectView.project && projectId == project.id,
                  onTap: () => onSelect(ProjectView.project, projectId: project.id),
                  onToggleFavorite: () => onToggleFavorite(project),
                ),
              const Divider(indent: 16, endIndent: 16, height: 20),
            ],
            for (final project in others)
              _ProjectItem(
                project: project,
                selected: view == ProjectView.project && projectId == project.id,
                onTap: () => onSelect(ProjectView.project, projectId: project.id),
                onToggleFavorite: () => onToggleFavorite(project),
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
        contentPadding: const EdgeInsets.only(left: 28, right: 4),
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

/// 아직 안 만든 화면(캘린더/간트차트/노트) 자리.
class _ComingSoon extends StatelessWidget {
  final IconData icon;
  final String label;
  const _ComingSoon({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: hint),
          const SizedBox(height: 12),
          Text('$label는 준비 중입니다.', style: TextStyle(color: hint)),
          const SizedBox(height: 4),
          Text(
            '지금은 홈과 내 업무, 프로젝트별 업무 목록을 쓸 수 있습니다.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: hint),
          ),
        ],
      ),
    );
  }
}
