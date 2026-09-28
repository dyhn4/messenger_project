import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/app_links.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/muted_scrollbar.dart';
import 'project_detail_view.dart';
import 'project_menu_dialog.dart' show ProjectMenuResult, showProjectMenuDialog;
import 'my_tasks_view.dart';
import 'notes_view.dart';
import 'project_notifications.dart';
import 'project_search.dart';
import 'project_forms.dart';
import 'project_home_view.dart';
import 'project_templates_view.dart';
import 'all_projects_view.dart';
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
enum ProjectView {
  home,
  myTasks,
  calendar,
  gantt,
  notes,
  project,
  templates,
  allProjects,
}

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

  /// 뒤 화면에서 업무를 고치면 올린다 — 열린 업무 패널이 다시 읽는다(TaskPanelScope.tasksChanged).
  int _panelReloadTick = 0;

  void _openTask(String taskId) => setState(() {
    _openTaskId = taskId;
    // 업무 패널과 노트 패널은 같은 자리 — 업무를 열면 노트 패널은 닫는다.
    _notePanelProjectId = null;
    _noteExpanded = false;
  });

  /// 프로젝트의 "노트" 탭에서 연 오른쪽 노트 패널(그 프로젝트 id). 업무 패널과 같은 자리.
  String? _notePanelProjectId;
  bool _noteExpanded = false;

  /// 패널 ↔ 크게 보기(본문 자리)를 오가도 노트 화면이 새로 만들어지지 않게(보던 노트 유지).
  final _notePanelKey = GlobalKey();

  void _openNotes(String projectId) => setState(() {
    _notePanelProjectId = projectId;
    _openTaskId = null;
    _taskExpanded = false;
  });

  ProjectView _view = ProjectView.home;
  String? _projectId; // _view == ProjectView.project일 때만 의미 있다.

  List<Project>? _projects;
  List<Project> _archivedProjects = const [];

  /// 사이드바의 내 프로젝트 폴더(개인 설정) — 프로젝트 목록과 같이 다시 읽는다.
  List<ProjectFolder> _folders = const [];
  String? _error;

  /// 내가 참여 중인 프로젝트에서 뭔가 바뀌면(다른 사람이 업무를 만들거나 댓글을 달아도)
  /// 지금 보고 있는 화면을 다시 불러온다. 무엇이 바뀌었는지는 구분하지 않는다(chat_socket.dart).
  StreamSubscription<void>? _changedSub;

  /// 자식 화면(홈/업무 목록)에게 "다시 불러와라"라고 알리는 값 — 이 값이 바뀔 때마다
  /// 자식이 didUpdateWidget에서 자기 데이터를 새로 받아온다.
  int _reloadTick = 0;

  String? get _teamId => widget.session.currentTeam?.id;

  /// 노트 링크로 열 노트(AppLinks.request).
  String? _openNoteId;
  int _openNoteTick = 0;

  /// 노트 링크면 "노트"에서 그 노트를, 업무 링크면 지금 화면 그대로 업무 패널을 연다.
  /// 업무 링크로 열 때 올린다 — 프로젝트 화면을 리스트 탭으로(ProjectDetailView.listTabTick).
  int _listTabTick = 0;

  void _onLinkRequest() {
    final req = AppLinks.request.value;
    if (req == null || !mounted) return;
    if (req.kind == 'task') {
      _openTaskFromLink(req.id);
      return;
    }
    setState(() {
      _view = ProjectView.notes;
      _projectId = null;
      _openNoteId = req.id;
      _openNoteTick = req.tick;
    });
  }

  /// 업무 링크 — 그 업무의 프로젝트를 리스트 탭으로 열고, 업무 패널도 연다.
  Future<void> _openTaskFromLink(String taskId) async {
    try {
      final task = await widget.session.api!.fetchTask(taskId);
      if (!mounted) return;
      setState(() {
        _view = ProjectView.project;
        _projectId = task.projectId;
        _openNoteId = null;
        _listTabTick++;
        _openTaskId = taskId;
        _taskExpanded = false;
      });
    } catch (e) {
      if (mounted) showAppToast(context, '업무를 열지 못했습니다: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    AppLinks.request.addListener(_onLinkRequest);
    // 창이 뜨기 전에 들어온 요청(링크로 새로 연 경우)도 처리한다.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onLinkRequest());
    _loadProjects();
    _changedSub = widget.session.chatSocket.projectChanged.listen((_) {
      if (!mounted) return;
      _loadProjects();
      setState(() => _reloadTick++);
    });
  }

  @override
  void dispose() {
    AppLinks.request.removeListener(_onLinkRequest);
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
      // 폴더는 목록을 정리하는 개인 설정일 뿐이라, 못 받아와도 프로젝트 목록은 그대로 보여준다.
      var folders = _folders;
      try {
        folders = await api.fetchProjectFolders(teamId);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _projects = list;
        _archivedProjects = archived;
        _folders = folders;
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

  /// 사이드바에서 폴더를 만들거나 고치거나 프로젝트를 옮긴 뒤 — 폴더만 다시 읽는다.
  /// 폴더는 개인 사이드바 설정이라 서버가 project:changed를 보내 주지 않으므로 고친 쪽이
  /// 직접 읽어야 하고, 프로젝트 목록·열린 화면(_reloadTick)은 바뀐 게 없으니 건드리지 않는다.
  Future<void> _loadFolders() async {
    final teamId = _teamId;
    if (teamId == null) return;
    try {
      final folders = await widget.session.api!.fetchProjectFolders(teamId);
      if (mounted) setState(() => _folders = folders);
    } catch (_) {
      // 못 받아오면 지금 폴더를 그대로 둔다 — 다음 목록 새로고침 때 맞춰진다.
    }
  }

  /// 템플릿 화면에 처음 띄울 편집 내용("템플릿 저장"·"+ 새 템플릿") — null이면 목록부터.
  ProjectTemplate? _templateDraft;

  /// 템플릿 화면을 열 때마다 +1 — 화면을 새로 만들어 목록(또는 [_templateDraft])부터 보인다.
  int _templatesTick = 0;

  void _select(ProjectView view, {String? projectId}) {
    setState(() {
      if (view == ProjectView.templates) {
        _templateDraft = null;
        _templatesTick++;
      }
      // 메뉴로 옮겨 다닐 때는 링크로 열었던 노트를 다시 열지 않고, 노트 패널도 닫는다.
      _openNoteId = null;
      _notePanelProjectId = null;
      _noteExpanded = false;
      // 홈·내 업무·캘린더·간트차트·노트에서 프로젝트로 넘어가면 보던 업무 패널은 닫는다
      // (프로젝트 화면은 대시보드 탭부터 보인다 — ProjectDetailView의 첫 탭).
      // "노트"로 갈 때도 업무 패널은 닫는다.
      if ((view == ProjectView.project && _view != ProjectView.project) ||
          view == ProjectView.notes) {
        _openTaskId = null;
        _taskExpanded = false;
      }
      _view = view;
      _projectId = projectId;
    });
  }

  /// 알림함에서 알림을 눌렀을 때 — 그 프로젝트를 열고, 업무 알림이면 업무 상세도 띄운다.
  /// 공개 프로젝트 생성 알림(project_created)처럼 업무가 없는 알림은 프로젝트만 연다.
  Future<void> _openNotification(ProjectNotification n) async {
    bool known() => _projects?.any((p) => p.id == n.projectId) == true;
    // 방금 만들어진 공개 프로젝트는 아직 사이드바 목록에 없을 수 있다 — 한 번 새로 받아 본다
    // (목록을 받을 때 서버가 공개 프로젝트 멤버로 자동으로 넣어 준다).
    if (!known()) {
      await _loadProjects();
      if (!mounted) return;
    }
    if (!known()) {
      showAppToast(context, '더 이상 참여 중이 아닌 프로젝트입니다.');
      return;
    }
    _select(ProjectView.project, projectId: n.projectId);
    // 이 State의 context는 TaskPanelScope 바깥이라 showTaskDetailDialog를 부르면 옛 팝업이
    // 뜬다 — 오른쪽 업무 패널을 직접 연다(보관된 업무의 읽기 전용 표시도 패널에만 있다).
    if (n.taskId != null) _openTask(n.taskId!);
  }

  Future<void> _createProject({String? templateId}) async {
    final teamId = _teamId;
    if (teamId == null) return;
    final created = await showNewProjectDialog(
      context,
      widget.session,
      teamId,
      templateId: templateId,
      onNewTemplate: () => _openTemplateEditor(ProjectTemplate.blank()),
    );
    if (created == null || !mounted) return;
    await _loadProjects();
    if (mounted) _select(ProjectView.project, projectId: created.id);
  }

  /// 템플릿 화면을 [draft]로 채운 "새 템플릿 만들기" 편집기로 연다.
  void _openTemplateEditor(ProjectTemplate draft) {
    _select(ProjectView.templates);
    setState(() => _templateDraft = draft);
  }

  /// 프로젝트 ⋯ > "템플릿 저장" — 그 프로젝트의 상태·유형·우선순위·필드로 새 템플릿 편집기를 연다.
  /// 설정 > 필드 / 상태의 "템플릿 저장"과 같은 초안을 써서, 저장하면 이 프로젝트가 새 템플릿에
  /// 연결되고(설정의 "업무 템플릿" 칸이 카드로 바뀐다) 긴 프로젝트 이름도 40자로 잘린다.
  Future<void> _saveAsTemplate(Project project) async {
    try {
      final draft = await projectTemplateDraftFor(widget.session, project);
      if (!mounted) return;
      _openTemplateEditor(draft);
    } catch (e) {
      if (mounted) showAppToast(context, '프로젝트 설정을 불러오지 못했습니다: $e');
    }
  }

  /// 사이드바 프로젝트 ⋯ > "프로젝트 설정" — 프로젝트 화면 오른쪽 위 톱니와 같은 설정 창을 연다.
  Future<void> _openProjectSettings(Project project) async {
    final result = await showProjectMenuDialog(
      context,
      widget.session,
      project.id,
    );
    if (!mounted) return;
    // 열어 둔 프로젝트를 지웠으면 홈으로(프로젝트 화면의 onDeleted와 같다).
    if (result == ProjectMenuResult.deleted &&
        _view == ProjectView.project &&
        _projectId == project.id) {
      _select(ProjectView.home);
    }
    // 무엇이 바뀌었는지는 결과만으로 다 알 수 없다 — 필드·상태만 고치면 "바뀜"이 오지 않고, 창의
    // X 버튼으로 닫으면 이름을 바꿨어도 결과가 비어 온다. 그래서 프로젝트 화면의 톱니처럼 닫으면
    // 늘 사이드바 목록과 보고 있는 화면(그 프로젝트가 열려 있으면 그 화면)을 새로 읽는다.
    await _loadProjects();
    if (mounted) setState(() => _reloadTick++);
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
    _openTask(task.id);
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
      folders: _folders,
      onFoldersChanged: _loadFolders,
      view: _view,
      projectId: _projectId,
      onSelect: (view, {String? projectId}) {
        // 겹쳐 뜬 메뉴에서 골랐으면 고르는 즉시 접는다.
        if (_sidebarOverlayOpen) setState(() => _sidebarOverlayOpen = false);
        _select(view, projectId: projectId);
      },
      onCreateProject: _createProject,
      onToggleFavorite: _toggleFavorite,
      onSaveAsTemplate: _saveAsTemplate,
      onOpenSettings: _openProjectSettings,
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
    final notesProject = _notePanelProjectId;
    final teamId = _teamId;
    if (notesProject != null && teamId != null) {
      return NotesView(
        key: _notePanelKey,
        session: widget.session,
        teamId: teamId,
        projectId: notesProject,
        reloadTick: _reloadTick,
        panelMode: true,
        panelExpanded: _noteExpanded,
        onToggleExpand: () => setState(() => _noteExpanded = !_noteExpanded),
        onClose: () => setState(() {
          _notePanelProjectId = null;
          _noteExpanded = false;
        }),
      );
    }
    final taskId = _openTaskId;
    if (taskId == null) return null;
    return TaskDetailPanel(
      key: ValueKey(taskId),
      session: widget.session,
      taskId: taskId,
      expanded: _taskExpanded,
      onToggleExpand: () => setState(() => _taskExpanded = !_taskExpanded),
      // 닫으면 크게 보기도 풀어 둔다 — 다음에 업무를 누르면 다시 옆 패널로 열린다.
      onClose: () => setState(() {
        _openTaskId = null;
        _taskExpanded = false;
      }),
      onOpenTask: _openTask,
      // 업무를 고치면 뒤에 있는 목록·대시보드도 같이 다시 읽는다.
      onChanged: () => setState(() => _reloadTick++),
      reloadTick: _panelReloadTick,
    );
  }

  /// 상단 바 아래 영역 — 왼쪽 메뉴 + 내용, 그리고 업무 패널.
  ///
  /// 패널은 상단 바(로고·검색·알림 종)를 덮지 않고 그 아래에서 시작한다. 평소(미니)에는
  /// 내용 오른쪽에 나란히 붙고, **크게 보기**나 좁은 창에서는 왼쪽 메뉴는 그대로 둔 채
  /// 내용 자리만 패널이 차지한다.
  Widget _buildBodyArea(Widget? panel) => LayoutBuilder(
    builder: (context, constraints) {
      final expanded = _notePanelProjectId != null
          ? _noteExpanded
          : _taskExpanded;
      final asContent =
          panel != null && (expanded || constraints.maxWidth < 760);
      // 패널을 옆에 세우면 그만큼 본문이 좁아진다 — 왼쪽 메뉴 접힘 판단도 그 폭으로 한다.
      final bodyWidth = panel == null || asContent
          ? constraints.maxWidth
          : constraints.maxWidth - kTaskPanelWidth - 1;
      final body = _buildBodyRow(context, bodyWidth, asContent ? panel : null);
      final side = panel != null && !asContent;
      // 패널이 있든 없든 본문은 늘 같은 자리(Row → Expanded → TaskPanelInset)에 둔다 —
      // 구조가 바뀌면 본문 화면이 새로 만들어져서 보던 상태(간트차트 축척 등)가 초기화된다.
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: TaskPanelInset(
              width: side ? kTaskPanelWidth + 1 : 0,
              child: body,
            ),
          ),
          if (side) ...[
            const VerticalDivider(width: 1),
            SizedBox(width: kTaskPanelWidth, child: panel),
          ],
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final content = TaskPanelScope(
      openTask: _openTask,
      openNotes: _openNotes,
      tasksChanged: () => setState(() => _panelReloadTick++),
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
        // 화면 제목은 각 화면이 직접 크게 그린다(내 업무/캘린더/간트차트/노트). 프로젝트 화면은
        // 상세 화면이 프로젝트 머리(색 막대·이름·즐겨찾기 별·설명)를 "새 업무"·설정 버튼과 한 줄에
        // 위 여백까지 통째로 그린다 — 버튼을 위아래 구분선의 가운데에 맞추려면 여백도 그 줄 안에 있어야 한다.
        if (_view != ProjectView.project) const SizedBox(height: 12),
        Expanded(child: _buildBody(context, teamId, narrow)),
      ],
    );
  }

  /// 지금 열려 있는 프로젝트(사이드바 목록 — 진행 중 또는 종료된 프로젝트). 목록을 아직 못 받았으면 null.
  Project? get _currentProject =>
      _projects?.where((p) => p.id == _projectId).firstOrNull ??
      _archivedProjects.where((p) => p.id == _projectId).firstOrNull;

  Widget _buildBody(BuildContext context, String teamId, bool narrow) {
    switch (_view) {
      case ProjectView.home:
        return ProjectHomeView(
          session: widget.session,
          teamId: teamId,
          reloadTick: _reloadTick,
          onOpenProject: (id) => _select(ProjectView.project, projectId: id),
          onOpenMyTasks: () => _select(ProjectView.myTasks),
          onOpenCalendar: () => _select(ProjectView.calendar),
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
        final current = _currentProject;
        return ProjectDetailView(
          // 일부러 key를 안 준다 — 프로젝트를 바꿔도 State가 유지되어 보던 탭(대시보드 등)이
          // 그대로 남는다. 프로젝트별 데이터는 ProjectDetailView가 스스로 비우고 다시 읽는다.
          session: widget.session,
          projectId: id,
          reloadTick: _reloadTick,
          listTabTick: _listTabTick,
          onDeleted: () {
            _select(ProjectView.home);
            _loadProjects();
          },
          // 프로젝트 설정에서 이름·설명·색을 바꿨을 수 있다 — 머리와 사이드바를 새로 그린다.
          onProjectChanged: _loadProjects,
          header: current == null
              ? null
              : _ProjectHeader(
                  project: current,
                  // 종료된 프로젝트는 즐겨찾기 묶음에 나오지 않으므로 별을 두지 않는다.
                  onToggleFavorite: current.archived
                      ? null
                      : () => _toggleFavorite(current),
                ),
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
      case ProjectView.allProjects:
        return AllProjectsView(
          projects: _projects,
          archivedProjects: _archivedProjects,
          onOpen: (p) => _select(ProjectView.project, projectId: p.id),
          onToggleFavorite: _toggleFavorite,
        );
      case ProjectView.templates:
        return ProjectTemplatesView(
          key: ValueKey('templates-$_templatesTick'),
          session: widget.session,
          teamId: teamId,
          draft: _templateDraft,
          onUseTemplate: (t) => _createProject(templateId: t.id),
        );
      case ProjectView.notes:
        return NotesView(
          session: widget.session,
          teamId: teamId,
          reloadTick: _reloadTick,
          openNoteId: _openNoteId,
          openNoteTick: _openNoteTick,
        );
    }
  }
}

/// 프로젝트 화면 왼쪽 위 — 프로젝트 색 세로 막대, 굵은 이름과 즐겨찾기 별, 아래 설명.
class _ProjectHeader extends StatelessWidget {
  final Project project;

  /// null이면(종료된 프로젝트) 즐겨찾기 별을 그리지 않는다.
  final VoidCallback? onToggleFavorite;
  const _ProjectHeader({required this.project, this.onToggleFavorite});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final description = project.description?.trim() ?? '';
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 4,
            decoration: BoxDecoration(
              color: parseTypeColor(project.color),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        project.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (onToggleFavorite != null) ...[
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: project.favorite ? '즐겨찾기 해제' : '즐겨찾기',
                        onPressed: onToggleFavorite,
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          project.favorite
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          size: 24,
                          color: project.favorite
                              ? const Color(0xFFF5A623)
                              : theme.hintColor,
                        ),
                      ),
                    ],
                  ],
                ),
                if (description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: theme.hintColor),
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

/// 왼쪽 사이드바 — 고정 메뉴(홈/내 업무/캘린더/간트차트/노트) + 내 프로젝트 목록.
/// 프로젝트 목록 순서: 즐겨찾기 → 내 폴더(안의 프로젝트는 들여 씀) → 폴더에 없는 나머지.
class _Sidebar extends StatefulWidget {
  final Session session;
  final List<Project>? projects;
  final List<Project> archivedProjects;

  /// 내 프로젝트 폴더(개인 설정).
  final List<ProjectFolder> folders;

  /// 폴더를 만들거나 고치거나 프로젝트를 옮긴 뒤 — 폴더 목록을 다시 읽는다(소켓 알림이 없어
  /// 고친 쪽이 직접 부른다). 접기/펴기는 그 자리에서 바꾸고 저장만 하므로 부르지 않는다.
  final Future<void> Function() onFoldersChanged;
  final ProjectView view;
  final String? projectId;
  final void Function(ProjectView view, {String? projectId}) onSelect;
  final VoidCallback onCreateProject;
  final ValueChanged<Project> onToggleFavorite;

  /// 프로젝트 ⋯ > "템플릿 저장".
  final ValueChanged<Project> onSaveAsTemplate;

  /// 프로젝트 ⋯ > "프로젝트 설정"(담당자나 팀 관리자에게만 보인다).
  final ValueChanged<Project> onOpenSettings;

  const _Sidebar({
    required this.session,
    required this.projects,
    required this.archivedProjects,
    required this.folders,
    required this.onFoldersChanged,
    required this.view,
    required this.projectId,
    required this.onSelect,
    required this.onCreateProject,
    required this.onToggleFavorite,
    required this.onSaveAsTemplate,
    required this.onOpenSettings,
  });

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  // 오른쪽 내용도 스크롤 뷰라, 사이드바까지 기본(Primary) 컨트롤러를 같이 쓰면 스크롤바가
  // "한 컨트롤러에 스크롤 위치가 여럿"이라며 그리지 못한다 — 사이드바는 자기 것을 쓴다.
  final _scroll = ScrollController();

  /// 즐겨찾기 묶음을 접었는지 — 창을 닫았다 열어도 앱이 켜져 있는 동안은 기억한다.
  static bool _favoritesCollapsed = false;

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
  ValueChanged<Project> get onToggleFavorite => widget.onToggleFavorite;

  Widget _menuItem(String label, VoidCallback onTap) => MenuItemButton(
    onPressed: onTap,
    child: Padding(
      padding: const EdgeInsets.only(left: 8, right: 28),
      child: Text(label),
    ),
  );

  /// "폴더 추가"·"이름 변경"이 같이 쓰는 이름 입력 창. 취소하면 null.
  Future<String?> _askFolderName({
    required String title,
    required String action,
    String initial = '',
  }) => showDialog<String>(
    context: context,
    builder: (_) =>
        _FolderNameDialog(title: title, action: action, initial: initial),
  );

  /// [+] > 폴더 추가. [moveIn]을 주면(프로젝트 ⋯ > 폴더로 이동 > 새 폴더) 만든 폴더에 바로 넣는다.
  Future<void> _addFolder({Project? moveIn}) async {
    final teamId = session.currentTeam?.id;
    if (teamId == null) return;
    final name = await _askFolderName(title: '폴더 추가', action: '추가');
    if (name == null || !mounted) return;
    final ProjectFolder folder;
    try {
      folder = await session.api!.createProjectFolder(teamId, name);
    } catch (e) {
      if (mounted) showAppToast(context, '폴더를 만들지 못했습니다: $e');
      return;
    }
    if (moveIn != null) {
      try {
        await session.api!.setProjectFolder(moveIn.id, folder.id);
      } catch (e) {
        // 폴더는 이미 만들어졌다 — "못 만들었다"고 하면 다시 눌러 같은 이름 폴더가 또 생기므로
        // 옮기기만 실패했다고 알린다.
        if (mounted) {
          showAppToast(context, '폴더는 만들었지만 프로젝트를 옮기지 못했습니다: $e');
        }
      }
    }
    // 옮기기가 실패했어도 새 폴더는 보여야 한다.
    await widget.onFoldersChanged();
  }

  Future<void> _renameFolder(ProjectFolder folder) async {
    final name = await _askFolderName(
      title: '폴더 이름 변경',
      action: '변경',
      initial: folder.name,
    );
    if (name == null || name == folder.name || !mounted) return;
    try {
      await session.api!.updateProjectFolder(folder.id, name: name);
      await widget.onFoldersChanged();
    } catch (e) {
      if (mounted) showAppToast(context, '폴더 이름을 바꾸지 못했습니다: $e');
    }
  }

  Future<void> _deleteFolder(ProjectFolder folder) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text("'${folder.name}' 폴더 삭제"),
        content: const Text('폴더만 삭제되고 안의 프로젝트는 목록에 그대로 남습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await session.api!.deleteProjectFolder(folder.id);
      await widget.onFoldersChanged();
    } catch (e) {
      if (mounted) showAppToast(context, '폴더를 삭제하지 못했습니다: $e');
    }
  }

  /// 폴더 접기/펴기 — 먼저 반영하고(즉각), 저장이 실패하면 되돌린다. 다음에 열어도 그대로다.
  /// PATCH 한 번뿐이다 — 목록을 다시 읽거나 열린 화면을 새로 불러오지 않는다.
  Future<void> _toggleFolder(ProjectFolder folder) async {
    final next = !folder.collapsed;
    setState(() => folder.collapsed = next);
    try {
      await session.api!.updateProjectFolder(folder.id, collapsed: next);
    } catch (e) {
      if (!mounted) return;
      setState(() => folder.collapsed = !next);
      showAppToast(context, '폴더 상태를 저장하지 못했습니다: $e');
    }
  }

  /// 프로젝트를 폴더 [folderId]로 옮긴다. null이면 폴더에서 뺀다(맨 아래 목록으로).
  Future<void> _moveToFolder(Project project, String? folderId) async {
    try {
      await session.api!.setProjectFolder(project.id, folderId);
      await widget.onFoldersChanged();
    } catch (e) {
      if (!mounted) return;
      showAppToast(
        context,
        folderId == null ? '폴더에서 빼지 못했습니다: $e' : '폴더로 옮기지 못했습니다: $e',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final list = projects ?? const <Project>[];
    final folders = widget.folders;
    // 프로젝트 id → 그 프로젝트가 든 내 폴더 id(한 프로젝트는 폴더 한 곳에만 들어간다).
    final folderOf = <String, String>{
      for (final f in folders)
        for (final id in f.projectIds) id: f.id,
    };
    // 폴더 id → 그 안의 진행 중인 프로젝트(사이드바 목록 순서 그대로).
    final inFolder = <String, List<Project>>{
      for (final f in folders)
        f.id: list.where((p) => folderOf[p.id] == f.id).toList(),
    };
    final favorites = list.where((p) => p.favorite).toList();
    // 즐겨찾기가 아니고 어느 폴더에도 없는 프로젝트만 맨 아래 목록에 남는다
    // (즐겨찾기인 프로젝트가 폴더에 있으면 즐겨찾기와 폴더 양쪽에 보인다).
    final others = list
        .where((p) => !p.favorite && !folderOf.containsKey(p.id))
        .toList();

    Widget item(Project project, String section, {bool indent = false}) =>
        _ProjectItem(
          // 즐겨찾기와 폴더에 같은 프로젝트가 같이 보일 수 있어 자리 이름을 붙인다.
          key: ValueKey('$section-${project.id}'),
          project: project,
          indent: indent,
          selected: view == ProjectView.project && projectId == project.id,
          folders: folders,
          folderId: folderOf[project.id],
          onTap: () => onSelect(ProjectView.project, projectId: project.id),
          onToggleFavorite: () => onToggleFavorite(project),
          onSaveAsTemplate: () => widget.onSaveAsTemplate(project),
          // 설정 창을 여는 권한은 프로젝트 화면의 톱니와 같다(프로젝트 담당자 또는 팀 관리자 이상).
          // 창 안의 각 항목은 서버가 다시 확인한다.
          onOpenSettings: project.isOwner || session.canManageCurrentTeam
              ? () => widget.onOpenSettings(project)
              : null,
          onMoveToFolder: (folderId) => _moveToFolder(project, folderId),
          onNewFolder: () => _addFolder(moveIn: project),
        );

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
            // '프로젝트' 머리글 — 폴더 안의 프로젝트를 여기로 끌어다 놓으면 폴더에서 빠진다.
            DragTarget<Project>(
              onWillAcceptWithDetails: (d) => folderOf.containsKey(d.data.id),
              onAcceptWithDetails: (d) => _moveToFolder(d.data, null),
              builder: (context, candidate, _) => _DropHighlight(
                active: candidate.isNotEmpty,
                child: Padding(
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
                      // [+] — 프로젝트 생성 / 전체 프로젝트(내가 참여 중인 프로젝트 목록) /
                      // 템플릿 / 폴더 추가(내 사이드바 정리용).
                      MenuAnchor(
                        menuChildren: [
                          if (session.canCreateProject)
                            _menuItem('프로젝트 생성', onCreateProject),
                          _menuItem(
                            '전체 프로젝트',
                            () => onSelect(ProjectView.allProjects),
                          ),
                          _menuItem(
                            '템플릿',
                            () => onSelect(ProjectView.templates),
                          ),
                          _menuItem('폴더 추가', _addFolder),
                        ],
                        builder: (context, controller, _) => IconButton(
                          icon: const Icon(Icons.add, size: 18),
                          tooltip: '추가',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => controller.isOpen
                              ? controller.close()
                              : controller.open(),
                        ),
                      ),
                    ],
                  ),
                ),
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
              // 왼쪽 꺽쇠 — 누르면 즐겨찾기 목록을 접었다 편다.
              InkWell(
                onTap: () =>
                    setState(() => _favoritesCollapsed = !_favoritesCollapsed),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 16, 4),
                  child: Row(
                    children: [
                      Icon(
                        _favoritesCollapsed
                            ? Icons.chevron_right
                            : Icons.expand_more,
                        size: 16,
                        color: hint,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '즐겨찾기 ${favorites.length}',
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: hint),
                      ),
                    ],
                  ),
                ),
              ),
              if (!_favoritesCollapsed)
                for (final project in favorites) item(project, 'fav'),
              const Divider(indent: 16, endIndent: 16, height: 20),
            ],
            // 내 폴더 — 머리글(접기·⋯ 메뉴·끌어다 놓기) 아래에 안의 프로젝트를 들여 쓴다.
            // 종료된 프로젝트는 폴더에 들어 있어도 맨 아래 "종료된 프로젝트"에만 보인다.
            for (final folder in folders) ...[
              _FolderHeader(
                key: ValueKey('folder-${folder.id}'),
                folder: folder,
                count: inFolder[folder.id]!.length,
                onToggle: () => _toggleFolder(folder),
                onRename: () => _renameFolder(folder),
                onDelete: () => _deleteFolder(folder),
                canAccept: (p) => folderOf[p.id] != folder.id,
                onDrop: (p) => _moveToFolder(p, folder.id),
              ),
              if (!folder.collapsed)
                for (final project in inFolder[folder.id]!)
                  item(project, 'folder', indent: true),
            ],
            for (final project in others) item(project, 'root'),
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
/// 마우스로 끌어다 폴더 머리글(폴더에 넣기)이나 '프로젝트' 머리글(폴더에서 빼기)에 놓을 수 있다.
class _ProjectItem extends StatefulWidget {
  final Project project;
  final bool selected;

  /// 폴더 안의 프로젝트 — 폴더 머리글 아래로 들여 쓴다.
  final bool indent;

  /// 내 폴더들과, 이 프로젝트가 든 폴더(없으면 null) — ⋯ > 폴더로 이동 메뉴에 쓴다.
  final List<ProjectFolder> folders;
  final String? folderId;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final VoidCallback onSaveAsTemplate;

  /// ⋯ > 프로젝트 설정 — null이면(권한 없음) 메뉴에 두지 않는다.
  final VoidCallback? onOpenSettings;

  /// 폴더로 옮긴다. null이면 폴더에서 뺀다.
  final ValueChanged<String?> onMoveToFolder;

  /// ⋯ > 폴더로 이동 > 새 폴더 — 폴더를 만들고 바로 이 프로젝트를 넣는다.
  final VoidCallback onNewFolder;

  const _ProjectItem({
    super.key,
    required this.project,
    required this.selected,
    this.indent = false,
    this.folders = const [],
    this.folderId,
    required this.onTap,
    required this.onToggleFavorite,
    required this.onSaveAsTemplate,
    this.onOpenSettings,
    required this.onMoveToFolder,
    required this.onNewFolder,
  });

  @override
  State<_ProjectItem> createState() => _ProjectItemState();
}

class _ProjectItemState extends State<_ProjectItem> {
  bool _hovering = false;
  bool _dragging = false;
  final _menu = MenuController();

  Widget _menuLabel(String text) =>
      Padding(padding: const EdgeInsets.only(right: 20), child: Text(text));

  /// 끄는 동안 마우스 끝에 따라다니는 작은 딱지(색 점 + 이름).
  Widget _dragFeedback(BuildContext context) => Material(
    elevation: 4,
    borderRadius: BorderRadius.circular(8),
    color: Theme.of(context).colorScheme.surface,
    child: Container(
      width: 200,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: parseTypeColor(widget.project.color),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.project.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final favorite = widget.project.favorite;
    // 마우스를 올렸을 때(또는 메뉴가 열려 있을 때)만 오른쪽에 ⋯ 가 보인다. 터치 기기는 호버가
    // 없고 끌기도 마우스 전용이라, ⋯(폴더로 이동 등)를 늘 보여 준다.
    final showMenu = _hovering || _menu.isOpen || _isTouchPlatform;
    // ⋯ 버튼(과 그 메뉴)은 ListTile 바깥에 겹쳐 둔다. 안에 두면 메뉴를 닫을 때 포커스가 그
    // 버튼으로 돌아오면서 줄 전체가 "포커스됨"으로 보고 회색 포커스 표시를 칠한 채 남는다
    // (마우스를 올리지 않았는데도 회색으로 보이던 문제).
    // 끄는 동안에는 자리만 흐리게 남긴다 — 위젯 구조를 바꾸지 않으려고 Opacity로만 조절한다.
    return _SlopDraggable<Project>(
      data: widget.project,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _dragFeedback(context),
      onDragStarted: () => setState(() => _dragging = true),
      onDragEnd: (_) {
        if (mounted) setState(() => _dragging = false);
      },
      child: Opacity(
        opacity: _dragging ? 0.4 : 1,
        child: _buildRow(context, favorite, showMenu),
      ),
    );
  }

  Widget _buildRow(BuildContext context, bool favorite, bool showMenu) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.only(
              left: widget.indent ? 34 : 16,
              right: 4,
            ),
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
            // 겹쳐 둔 ⋯ 버튼 자리 — 제목이 버튼 밑으로 들어가지 않게 비워 둔다.
            trailing: const SizedBox(width: 36, height: 36),
            onTap: widget.onTap,
          ),
          Positioned(
            right: 4,
            child: Opacity(
              opacity: showMenu ? 1 : 0,
              child: MenuAnchor(
                controller: _menu,
                onClose: () => setState(() {}),
                menuChildren: [
                  MenuItemButton(
                    leadingIcon: Icon(
                      favorite ? Icons.star : Icons.star_border,
                      size: 18,
                    ),
                    onPressed: widget.onToggleFavorite,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 20),
                      child: Text(favorite ? '즐겨찾기 해제' : '즐겨찾기'),
                    ),
                  ),
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.grid_view_outlined, size: 18),
                    onPressed: widget.onSaveAsTemplate,
                    child: const Padding(
                      padding: EdgeInsets.only(right: 20),
                      child: Text('템플릿 저장'),
                    ),
                  ),
                  // 폴더로 이동 — 내 폴더 목록(지금 든 폴더는 체크 표시·비활성) + 새 폴더.
                  SubmenuButton(
                    leadingIcon: const Icon(
                      Icons.drive_file_move_outline,
                      size: 18,
                    ),
                    menuChildren: [
                      for (final f in widget.folders)
                        MenuItemButton(
                          leadingIcon: Icon(
                            f.id == widget.folderId
                                ? Icons.check
                                : Icons.folder_outlined,
                            size: 18,
                          ),
                          onPressed: f.id == widget.folderId
                              ? null
                              : () => widget.onMoveToFolder(f.id),
                          child: _menuLabel(f.name),
                        ),
                      if (widget.folders.isNotEmpty) const Divider(height: 8),
                      MenuItemButton(
                        leadingIcon: const Icon(
                          Icons.create_new_folder_outlined,
                          size: 18,
                        ),
                        onPressed: widget.onNewFolder,
                        child: _menuLabel('새 폴더'),
                      ),
                    ],
                    child: _menuLabel('폴더로 이동'),
                  ),
                  if (widget.folderId != null)
                    MenuItemButton(
                      leadingIcon: const Icon(
                        Icons.folder_off_outlined,
                        size: 18,
                      ),
                      onPressed: () => widget.onMoveToFolder(null),
                      child: _menuLabel('폴더에서 빼기'),
                    ),
                  if (widget.onOpenSettings != null) ...[
                    const Divider(height: 8),
                    MenuItemButton(
                      leadingIcon: const Icon(
                        Icons.settings_outlined,
                        size: 18,
                      ),
                      onPressed: widget.onOpenSettings,
                      child: _menuLabel('프로젝트 설정'),
                    ),
                  ],
                ],
                builder: (context, controller, _) => IconButton(
                  icon: const Icon(Icons.more_horiz, size: 18),
                  visualDensity: VisualDensity.compact,
                  tooltip: '프로젝트 메뉴',
                  onPressed: () => setState(
                    () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 사이드바의 폴더 머리글 — 꺽쇠·폴더 아이콘·이름·프로젝트 수. 누르면 접었다 펴고, 마우스를
/// 올리면(터치 기기는 늘) ⋯(이름 변경 / 폴더 삭제)가 보인다. 프로젝트를 끌어다 놓으면 이 폴더로 옮긴다.
class _FolderHeader extends StatefulWidget {
  final ProjectFolder folder;
  final int count;
  final VoidCallback onToggle;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  /// 끌어 온 프로젝트를 받을지 — 이미 이 폴더에 든 프로젝트는 받지 않는다.
  final bool Function(Project project) canAccept;
  final ValueChanged<Project> onDrop;

  const _FolderHeader({
    super.key,
    required this.folder,
    required this.count,
    required this.onToggle,
    required this.onRename,
    required this.onDelete,
    required this.canAccept,
    required this.onDrop,
  });

  @override
  State<_FolderHeader> createState() => _FolderHeaderState();
}

class _FolderHeaderState extends State<_FolderHeader> {
  bool _hovering = false;
  final _menu = MenuController();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final collapsed = widget.folder.collapsed;
    // 터치 기기는 호버가 없다 — ⋯(이름 변경/폴더 삭제)를 늘 보여 준다.
    final showMenu = _hovering || _menu.isOpen || _isTouchPlatform;
    return DragTarget<Project>(
      onWillAcceptWithDetails: (d) => widget.canAccept(d.data),
      onAcceptWithDetails: (d) => widget.onDrop(d.data),
      builder: (context, candidate, _) {
        final active = candidate.isNotEmpty;
        // ⋯ 버튼은 프로젝트 줄과 같은 이유로(포커스 회색이 남지 않게) InkWell 바깥에 겹쳐 둔다.
        return MouseRegion(
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: _DropHighlight(
            active: active,
            child: Stack(
              alignment: Alignment.centerRight,
              children: [
                InkWell(
                  onTap: widget.onToggle,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 40, 8),
                    child: Row(
                      children: [
                        Icon(
                          collapsed ? Icons.chevron_right : Icons.expand_more,
                          size: 16,
                          color: hint,
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          active || !collapsed
                              ? Icons.folder_open_outlined
                              : Icons.folder_outlined,
                          size: 18,
                          color: active ? theme.colorScheme.primary : hint,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            widget.folder.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${widget.count}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: hint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  right: 4,
                  child: Opacity(
                    opacity: showMenu ? 1 : 0,
                    child: MenuAnchor(
                      controller: _menu,
                      onClose: () => setState(() {}),
                      menuChildren: [
                        MenuItemButton(
                          leadingIcon: const Icon(
                            Icons.edit_outlined,
                            size: 18,
                          ),
                          onPressed: widget.onRename,
                          child: const Padding(
                            padding: EdgeInsets.only(right: 20),
                            child: Text('이름 변경'),
                          ),
                        ),
                        MenuItemButton(
                          leadingIcon: const Icon(
                            Icons.delete_outline,
                            size: 18,
                          ),
                          onPressed: widget.onDelete,
                          child: const Padding(
                            padding: EdgeInsets.only(right: 20),
                            child: Text('폴더 삭제'),
                          ),
                        ),
                      ],
                      builder: (context, controller, _) => IconButton(
                        icon: const Icon(Icons.more_horiz, size: 18),
                        visualDensity: VisualDensity.compact,
                        tooltip: '폴더 메뉴',
                        onPressed: () => setState(
                          () => controller.isOpen
                              ? controller.close()
                              : controller.open(),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 끌어 온 프로젝트를 놓을 수 있는 자리 위에 있을 때 옅은 강조색을 깐다.
class _DropHighlight extends StatelessWidget {
  final bool active;
  final Widget child;
  const _DropHighlight({required this.active, required this.child});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: active ? primary.withValues(alpha: 0.12) : null,
        border: active
            ? Border.all(color: primary.withValues(alpha: 0.6))
            : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }
}

/// 폴더 이름 입력 — "폴더 추가"와 "폴더 이름 변경"이 같이 쓴다. 확인하면 다듬은 이름을, 취소하면 null.
class _FolderNameDialog extends StatefulWidget {
  final String title;
  final String action;
  final String initial;
  const _FolderNameDialog({
    required this.title,
    required this.action,
    this.initial = '',
  });

  @override
  State<_FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<_FolderNameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _name => _controller.text.trim();

  void _submit() {
    if (_name.isEmpty) return;
    Navigator.of(context).pop(_name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(hintText: '폴더 이름'),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _name.isEmpty ? null : _submit,
          child: Text(widget.action),
        ),
      ],
    );
  }
}

/// 안드로이드·iOS(터치) — 호버가 없어 "마우스를 올리면 보이는 ⋯"가 영영 안 보이므로 늘 보여 준다.
/// 앱의 다른 곳처럼 dart:io Platform으로 보되, 테스트가 TargetPlatformVariant
/// (debugDefaultTargetPlatformOverride)로 바꿔 볼 수 있게 그 값이 있으면 먼저 따른다.
bool get _isTouchPlatform {
  final override = debugDefaultTargetPlatformOverride;
  if (override != null) {
    return override == TargetPlatform.android || override == TargetPlatform.iOS;
  }
  return Platform.isAndroid || Platform.isIOS;
}

/// 마우스로 이만큼(논리 픽셀) 넘게 움직여야 끌기로 본다 — 그보다 적게 흔들린 클릭은 그대로 연다.
const _kProjectDragSlop = 6.0;

/// 사이드바 프로젝트 줄 끌기. 기본 Draggable은 마우스에서 1px만 움직여도 끌기가 시작돼
/// 살짝 흔들린 클릭(프로젝트 열기)이 씹힌다 — 작은 문턱을 둔다. 터치는 목록 스크롤과 겹치지
/// 않게 끌기를 받지 않는다(터치에서는 ⋯ > 폴더로 이동을 쓴다).
class _SlopDraggable<T extends Object> extends Draggable<T> {
  const _SlopDraggable({
    required super.child,
    required super.feedback,
    super.data,
    super.dragAnchorStrategy,
    super.onDragStarted,
    super.onDragEnd,
  });

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) => _SlopDragRecognizer()..onStart = onStart;
}

class _SlopDragRecognizer extends MultiDragGestureRecognizer {
  _SlopDragRecognizer()
    : super(debugOwner: null, supportedDevices: {PointerDeviceKind.mouse});

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) =>
      _SlopPointerState(event.position, event.kind, gestureSettings);

  @override
  String get debugDescription => 'project drag';
}

class _SlopPointerState extends MultiDragPointerState {
  _SlopPointerState(super.initialPosition, super.kind, super.gestureSettings);

  @override
  void checkForResolutionAfterMove() {
    if (pendingDelta!.distance > _kProjectDragSlop) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    starter(initialPosition);
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
