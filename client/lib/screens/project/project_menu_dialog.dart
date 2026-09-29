import 'package:flutter/material.dart';

import '../../models/admin.dart' show accountRoleLabel;
import '../../models/app_user.dart';
import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/floating_dialog.dart';
import '../../widgets/muted_scrollbar.dart';
import '../../widgets/role_badge.dart';
import '../../widgets/user_avatar.dart';
import 'project_forms.dart' show projectColorChoices;
import 'project_notifications.dart' show ProjectNotificationSettingsEditor;
import 'project_templates_view.dart'
    show
        ProjectTemplateSummaryCard,
        projectTemplateDraftFor,
        showProjectTemplateEditorDialog;
import 'task_config_manager.dart'
    show ProjectFieldEditor, ProjectPriorityEditor, ProjectStatusEditor;
import 'task_type_manager.dart' show ProjectTypeEditor;
import 'template_automation_manager.dart' show ProjectAutomationEditor;

/// "프로젝트 메뉴"를 닫은 결과 — 내용이 바뀌었는지, 프로젝트가 지워졌는지.
enum ProjectMenuResult { changed, deleted }

/// 프로젝트 화면 오른쪽 위 톱니 버튼으로 여는 통합 설정 창 — 왼쪽 메뉴(기본 정보 / 필드·상태 /
/// 멤버 / 알림 / 자동화 / 노트 / 삭제)로 오른쪽 내용을 바꾼다. 업무 템플릿은 필드 / 상태 화면의
/// "업무 템플릿" 칸에 있다. 항목별 권한은 서버가 다시 확인하므로 여기서는 화면만 나눈다.
Future<ProjectMenuResult?> showProjectMenuDialog(
  BuildContext context,
  Session session,
  String projectId,
) async {
  final changed = _ChangeFlag();
  final result = await showDialog<ProjectMenuResult>(
    context: context,
    builder: (_) => _ProjectMenuDialog(
      session: session,
      projectId: projectId,
      changed: changed,
    ),
  );
  // 창 오른쪽 위 X(FloatingDialog)는 결과 없이 바로 닫으므로, 바뀐 게 있었는지는 여기서 다시 본다.
  return result ?? (changed.value ? ProjectMenuResult.changed : null);
}

/// 설정 창 안에서 뭔가 바뀌었는지 — 창이 어떤 방법으로 닫혀도 호출부가 알 수 있게 창 밖에 둔다.
class _ChangeFlag {
  bool value = false;
}

/// 팀원 중 아직 이 프로젝트에 없는 정회원 이상을 골라 추가한다. 추가했으면 true.
/// [asOwner]면 고른 사람을 넣은 뒤 바로 담당자로 올린다(공개 프로젝트의 "담당자 추가").
Future<bool> addMembersToProject(
  BuildContext context,
  Session session,
  Project project, {
  bool asOwner = false,
}) async {
  final all = await session.fetchTeamMembers();
  if (!context.mounted) return false;
  final existing = project.members.map((m) => m.id).toSet();
  // 담당자 추가는 이미 프로젝트에 들어와 있는 일반 멤버도 담당자로 올릴 수 있어야 한다
  // (공개 프로젝트는 정회원 이상 모두가 자동 멤버인데 멤버 목록을 따로 보여주지 않아서, 여기서 고른다).
  // 그래서 이미 담당자인 사람만 뺀다.
  final excluded = asOwner
      ? {
          for (final e in project.memberRoles.entries)
            if (e.value == 'owner') e.key,
        }
      : existing;
  final candidates = all
      .where((u) => !excluded.contains(u.id) && u.role != 'guest')
      .toList();
  if (candidates.isEmpty) {
    showAppToast(
      context,
      asOwner
          ? '담당자로 지정할 수 있는 팀원이 없습니다. (준회원은 담당자가 될 수 없습니다.)'
          : '추가할 수 있는 팀원이 없습니다. (준회원은 프로젝트에 참여할 수 없습니다.)',
    );
    return false;
  }
  final picked = await showDialog<List<String>>(
    context: context,
    builder: (_) => _MemberPickDialog(
      session: session,
      candidates: candidates,
      title: asOwner ? '담당자 추가' : '멤버 초대하기',
    ),
  );
  if (picked == null || picked.isEmpty || !context.mounted) return false;
  try {
    // 이미 멤버인 사람은 다시 추가하지 않고 역할만 바꾼다.
    final newcomers = picked.where((id) => !existing.contains(id)).toList();
    if (newcomers.isNotEmpty) {
      await session.api!.addProjectMembers(project.id, newcomers);
    }
    if (asOwner) {
      for (final id in picked) {
        await session.api!.setProjectMemberRole(project.id, id, 'owner');
      }
    }
    return true;
  } catch (e) {
    if (context.mounted) showAppToast(context, '구성원을 추가하지 못했습니다: $e');
    return false;
  }
}

enum _Section {
  basic,
  fields,
  members,
  notifications,
  automation,
  notes,
  danger,
}

String _sectionLabel(_Section s) => switch (s) {
  _Section.basic => '기본 정보',
  _Section.fields => '필드 / 상태',
  _Section.members => '멤버',
  _Section.notifications => '알림',
  _Section.automation => '자동화',
  _Section.notes => '노트',
  _Section.danger => '삭제',
};

IconData _sectionIcon(_Section s) => switch (s) {
  _Section.basic => Icons.info_outline,
  _Section.fields => Icons.dashboard_customize_outlined,
  _Section.members => Icons.people_outline,
  _Section.notifications => Icons.notifications_none,
  _Section.automation => Icons.bolt_outlined,
  _Section.notes => Icons.description_outlined,
  _Section.danger => Icons.delete_outline,
};

class _ProjectMenuDialog extends StatefulWidget {
  final Session session;
  final String projectId;
  final _ChangeFlag changed;
  const _ProjectMenuDialog({
    required this.session,
    required this.projectId,
    required this.changed,
  });

  @override
  State<_ProjectMenuDialog> createState() => _ProjectMenuDialogState();
}

class _ProjectMenuDialogState extends State<_ProjectMenuDialog> {
  _Section _section = _Section.basic;
  Project? _project;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await widget.session.api!.fetchProject(widget.projectId);
      if (mounted) {
        setState(() {
          _project = p;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 하위 화면이 뭔가 바꿨을 때 — 프로젝트를 다시 읽고 닫을 때 호출부에도 알린다.
  Future<void> _reload() async {
    widget.changed.value = true;
    await _load();
  }

  void _close({bool deleted = false}) {
    Navigator.of(context).pop(
      deleted
          ? ProjectMenuResult.deleted
          : (widget.changed.value ? ProjectMenuResult.changed : null),
    );
  }

  @override
  Widget build(BuildContext context) {
    final project = _project;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: FloatingDialog(
        title: '프로젝트 설정',
        maxWidth: 1000,
        maxHeight: 700,
        child: _error != null
            ? Center(child: Text(_error!))
            : project == null
            ? const Center(child: CircularProgressIndicator())
            : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 190, child: _buildNav(context)),
                  const SizedBox(width: 16),
                  Expanded(child: _buildPane(project)),
                ],
              ),
      ),
    );
  }

  Widget _buildNav(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final s in _Section.values)
            _NavItem(
              icon: _sectionIcon(s),
              label: _sectionLabel(s),
              selected: _section == s,
              danger: s == _Section.danger,
              onTap: () => setState(() => _section = s),
            ),
        ],
      ),
    );
  }

  Widget _buildPane(Project project) {
    switch (_section) {
      case _Section.basic:
        return _BasicPane(
          key: ValueKey('basic-${project.id}'),
          session: widget.session,
          project: project,
          onSaved: _reload,
        );
      case _Section.fields:
        return _FieldsPane(
          session: widget.session,
          project: project,
          onChanged: _reload,
        );
      case _Section.members:
        return _MembersPane(
          session: widget.session,
          project: project,
          onChanged: _reload,
        );
      case _Section.notifications:
        return _Pane(
          title: '알림',
          // 알림 화면은 목록이 스스로 스크롤한다 — 여기서 또 감싸면 높이가 무한이 되어
          // 아무것도 안 그려진다.
          scrollable: false,
          child: ProjectNotificationSettingsEditor(
            session: widget.session,
            projectId: project.id,
            canManage: project.isOwner || widget.session.canManageCurrentTeam,
          ),
        );
      case _Section.automation:
        return _Pane(
          title: '자동화',
          scrollable: false,
          child: ProjectAutomationEditor(
            key: ValueKey('automations-${project.id}'),
            session: widget.session,
            projectId: project.id,
          ),
        );
      case _Section.notes:
        return _NotesPane(
          session: widget.session,
          project: project,
          onChanged: _reload,
        );
      case _Section.danger:
        return _DangerPane(
          session: widget.session,
          project: project,
          onArchivedChanged: _reload,
          onDeleted: () => _close(deleted: true),
        );
    }
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool danger;
  final VoidCallback onTap;
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.danger,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = danger ? Colors.redAccent : theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Material(
        color: selected ? color.withValues(alpha: 0.10) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: danger
                      ? Colors.redAccent
                      : (selected ? color : theme.hintColor),
                ),
                const SizedBox(width: 10),
                // 라벨이 길어도 메뉴 폭을 넘지 않게 줄여서 맞춘다.
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: danger
                          ? Colors.redAccent
                          : (selected ? color : null),
                      fontWeight: selected ? FontWeight.bold : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 오른쪽 내용의 공통 틀 — 제목 + 설명 + 본문을 테두리 있는 카드에 담는다.
class _Pane extends StatefulWidget {
  final String title;
  final String? description;
  final Widget? action;
  final Widget child;

  /// false면 내용이 스스로 스크롤한다(멤버 화면처럼 안에 목록이 따로 있는 경우).
  final bool scrollable;
  const _Pane({
    required this.title,
    this.description,
    this.action,
    required this.child,
    this.scrollable = true,
  });

  @override
  State<_Pane> createState() => _PaneState();
}

class _PaneState extends State<_Pane> {
  /// 본문 스크롤 — 데스크톱에서는 SingleChildScrollView가 PrimaryScrollController에 안 붙어서,
  /// 컨트롤러 없이 스크롤바를 달면 디버그 모드에서 "ScrollPosition이 없다" 오류가 난다.
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.title;
    final description = widget.description;
    final action = widget.action;
    final child = widget.child;
    final head = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (description != null) ...[
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(color: theme.hintColor, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
        ?action,
      ],
    );
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          head,
          const SizedBox(height: 16),
          Expanded(
            child: widget.scrollable
                ? MutedScrollbar(
                    controller: _scroll,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      child: child,
                    ),
                  )
                : child,
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── 1. 기본 정보 ─────────────────────────

class _BasicPane extends StatefulWidget {
  final Session session;
  final Project project;
  final Future<void> Function() onSaved;
  const _BasicPane({
    super.key,
    required this.session,
    required this.project,
    required this.onSaved,
  });

  @override
  State<_BasicPane> createState() => _BasicPaneState();
}

class _BasicPaneState extends State<_BasicPane> {
  late final _name = TextEditingController(text: widget.project.name);
  late final _description = TextEditingController(
    text: widget.project.description ?? '',
  );
  late String _color = widget.project.color.toUpperCase();
  late bool _isPublic = widget.project.isPublic;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      showAppToast(context, '프로젝트 이름을 입력하세요.');
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.session.api!.updateProject(
        widget.project.id,
        name: name,
        description: _description.text.trim(),
        color: _color,
        isPublic: _isPublic,
      );
      if (mounted) showAppToast(context, '저장했습니다.');
      await widget.onSaved();
    } catch (e) {
      if (mounted) showAppToast(context, '저장하지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _label(String text, {String? hint}) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: text,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          if (hint != null)
            TextSpan(
              text: '  $hint',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).hintColor,
              ),
            ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return _Pane(
      title: '프로젝트 정보',
      description: '프로젝트의 기본 정보를 변경할 수 있습니다.',
      action: FilledButton(
        onPressed: _saving ? null : _save,
        child: const Text('저장'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label('프로젝트 이름'),
          TextField(
            controller: _name,
            maxLength: 60,
            decoration: const InputDecoration(
              counterText: '',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 20),
          _label('대표 색상'),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final hex in projectColorChoices)
                InkWell(
                  onTap: () => setState(() => _color = hex),
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 32,
                    height: 32,
                    padding: const EdgeInsets.all(2.5),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _color == hex
                            ? Theme.of(context).colorScheme.onSurface
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: parseTypeColor(hex),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          _label('프로젝트 키', hint: '업무 번호에 쓰이므로 만든 뒤에는 바꿀 수 없습니다.'),
          TextField(
            enabled: false,
            controller: TextEditingController(text: widget.project.identifier),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 20),
          _label('설명'),
          TextField(
            controller: _description,
            minLines: 3,
            maxLines: 5,
            decoration: const InputDecoration(
              hintText: '프로젝트에 대한 설명을 추가하세요...',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          _label('공개 설정'),
          DropdownButtonFormField<bool>(
            initialValue: _isPublic,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: const [
              DropdownMenuItem(value: true, child: Text('공개')),
              DropdownMenuItem(value: false, child: Text('비공개')),
            ],
            onChanged: (v) => setState(() => _isPublic = v ?? true),
          ),
          const SizedBox(height: 8),
          Text(
            _isPublic
                ? '공개: 정회원 이상 팀원 모두가 참여 절차 없이 자동으로 멤버가 되어 바로 업무를 보고 만들 수 있습니다.'
                : '비공개: 프로젝트 멤버로 추가된 멤버만 접근할 수 있습니다.',
            style: TextStyle(color: hint, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── 2. 필드 / 상태 ─────────────────────────

class _FieldsPane extends StatefulWidget {
  final Session session;
  final Project project;

  /// "업무 템플릿" 칸에서 이 프로젝트를 템플릿으로 저장했을 때 — 프로젝트를 다시 읽어 카드로 바꾼다.
  final Future<void> Function() onChanged;
  const _FieldsPane({
    required this.session,
    required this.project,
    required this.onChanged,
  });

  @override
  State<_FieldsPane> createState() => _FieldsPaneState();
}

class _FieldsPaneState extends State<_FieldsPane> {
  // 기본 필드 카드의 스크롤 — 기본(Primary) 컨트롤러를 다른 목록과 나눠 쓰면 스크롤바가
  // 그려지지 않으므로 이 카드 전용으로 하나 만든다.
  final _basicScroll = ScrollController();

  // 오른쪽 열(사용자 정의 필드 + 업무 템플릿)의 스크롤.
  final _sideScroll = ScrollController();

  /// 오른쪽 열이 넘쳐서 스크롤바가 보이는지 — 그때만 스크롤바 자리를 비워 둔다(안 넘치면 카드가
  /// 왼쪽 카드처럼 오른쪽 끝까지 닿는다).
  bool _sideScrollable = false;

  @override
  void dispose() {
    _basicScroll.dispose();
    _sideScroll.dispose();
    super.dispose();
  }

  Session get session => widget.session;
  String get projectId => widget.project.id;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // [scrollToEdge]면 오른쪽 안쪽 여백을 내용이 아니라 스크롤 영역이 갖는다 — 그래야
    // 스크롤바가 카드 오른쪽 선에 붙고, 항목의 삭제 버튼을 가리지 않는다.
    Widget card(
      String title,
      String? desc,
      Widget child, {
      bool scrollToEdge = false,
    }) => Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: EdgeInsets.fromLTRB(16, 14, scrollToEdge ? 0 : 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.only(right: scrollToEdge ? 16 : 0),
            child: _cardHeader(theme, title, desc),
          ),
          const SizedBox(height: 10),
          Expanded(child: child),
        ],
      ),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: card(
            '기본 필드',
            '상태 · 유형 · 우선순위는 프로젝트의 기본 메타데이터입니다.',
            // 세 구획이 각자 스크롤하면 어디를 굴려야 할지 알 수 없다 — 스크롤바는
            // "기본 필드" 카드에 하나만 두고 세 구획이 같이 쓴다.
            MutedScrollbar(
              controller: _basicScroll,
              child: SingleChildScrollView(
                controller: _basicScroll,
                // 스크롤바(10px)가 삭제 버튼 위에 겹치지 않도록 내용만 안쪽으로 들인다.
                padding: const EdgeInsets.only(right: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ProjectStatusEditor(session: session, projectId: projectId),
                    const Divider(height: 24),
                    ProjectTypeEditor(session: session, projectId: projectId),
                    const Divider(height: 24),
                    ProjectPriorityEditor(
                      session: session,
                      projectId: projectId,
                    ),
                  ],
                ),
              ),
            ),
            scrollToEdge: true,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 사용자 정의 필드 목록은 스스로 스크롤하므로 카드 높이를 정해 두고, 그 아래
              // "업무 템플릿" 칸까지 이 열 전체를 한 스크롤로 움직인다(양식 목록은 따로 스크롤하지 않는다).
              final fieldsHeight = (constraints.maxHeight * 0.5).clamp(
                240.0,
                340.0,
              );
              return NotificationListener<ScrollMetricsNotification>(
                onNotification: (n) {
                  if (n.depth != 0) return false;
                  final scrollable =
                      n.metrics.maxScrollExtent > n.metrics.minScrollExtent;
                  if (scrollable != _sideScrollable) {
                    setState(() => _sideScrollable = scrollable);
                  }
                  return false;
                },
                child: MutedScrollbar(
                  controller: _sideScroll,
                  child: SingleChildScrollView(
                    controller: _sideScroll,
                    // 스크롤바(10px)가 칸 테두리를 덮지 않도록 넘칠 때만 오른쪽을 비운다.
                    padding: EdgeInsets.only(right: _sideScrollable ? 14 : 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: fieldsHeight,
                          child: card(
                            '사용자 정의 필드',
                            '프로젝트에 필요한 입력 항목을 직접 추가합니다.',
                            ProjectFieldEditor(
                              session: session,
                              projectId: projectId,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _TaskTemplateBox(
                          key: ValueKey('task-template-box-$projectId'),
                          session: session,
                          project: widget.project,
                          onChanged: widget.onChanged,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 필드 / 상태 화면의 카드 머리글(굵은 제목 + 회색 설명) — 세 칸이 같은 모양을 쓴다.
Widget _cardHeader(ThemeData theme, String title, String? desc) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    Text(
      title,
      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
    ),
    if (desc != null) ...[
      const SizedBox(height: 4),
      Text(desc, style: TextStyle(color: theme.hintColor, fontSize: 12)),
    ],
  ],
);

/// 필드 / 상태 > "업무 템플릿" 칸 — 이 프로젝트가 프로젝트 템플릿을 썼으면(그 템플릿으로 만들었거나
/// 이 프로젝트를 템플릿으로 저장했으면) 그 템플릿 카드를, 아니면 "템플릿 저장" 버튼을 보여준다.
/// 템플릿이 지워지면 서버가 연결을 끊어서 다시 "템플릿 저장"이 보인다.
class _TaskTemplateBox extends StatefulWidget {
  final Session session;
  final Project project;
  final Future<void> Function() onChanged;
  const _TaskTemplateBox({
    super.key,
    required this.session,
    required this.project,
    required this.onChanged,
  });

  @override
  State<_TaskTemplateBox> createState() => _TaskTemplateBoxState();
}

class _TaskTemplateBoxState extends State<_TaskTemplateBox> {
  bool _busy = false;

  /// 사이드바 프로젝트 ⋯ > "템플릿 저장"과 같은 편집기(지금 구성으로 채운 새 템플릿)를 창으로 연다 —
  /// 저장하면 서버가 이 프로젝트를 새 템플릿에 연결하므로 다시 읽으면 카드로 바뀐다.
  Future<void> _saveAsTemplate() async {
    setState(() => _busy = true);
    try {
      final draft = await projectTemplateDraftFor(
        widget.session,
        widget.project,
      );
      if (!mounted) return;
      final saved = await showProjectTemplateEditorDialog(
        context,
        widget.session,
        teamId: widget.project.teamId,
        draft: draft,
      );
      if (saved != null) await widget.onChanged();
    } catch (e) {
      if (mounted) showAppToast(context, '프로젝트 설정을 불러오지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final template = widget.project.template;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _cardHeader(
            theme,
            '업무 템플릿',
            template != null
                ? '이 프로젝트가 사용한 프로젝트 템플릿입니다. 템플릿을 고쳐도 이 프로젝트의 구성은 바뀌지 않습니다.'
                : '프로젝트 템플릿을 사용하지 않은 프로젝트입니다. 지금의 상태·유형·우선순위·사용자 정의 필드 '
                      '구성을 템플릿으로 저장하면 새 프로젝트를 만들 때 불러올 수 있습니다.',
          ),
          const SizedBox(height: 10),
          if (template != null)
            ProjectTemplateSummaryCard(template: template, detailed: true)
          else
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _busy ? null : _saveAsTemplate,
                icon: const Icon(Icons.grid_view_outlined, size: 18),
                label: const Text('템플릿 저장'),
              ),
            ),
        ],
      ),
    );
  }
}

// ───────────────────────── 3. 멤버 ─────────────────────────

class _MembersPane extends StatefulWidget {
  final Session session;
  final Project project;
  final Future<void> Function() onChanged;
  const _MembersPane({
    required this.session,
    required this.project,
    required this.onChanged,
  });

  @override
  State<_MembersPane> createState() => _MembersPaneState();
}

class _MembersPaneState extends State<_MembersPane> {
  final _checked = <String>{};
  String _leftQuery = '';
  String _rightQuery = '';
  bool _busy = false;

  Project get project => widget.project;

  String _roleOf(String userId) => project.memberRoles[userId] ?? 'member';

  List<AppUser> _of(String role, String query) {
    final q = query.trim().toLowerCase();
    return [
      for (final m in project.members)
        if (_roleOf(m.id) == role &&
            (q.isEmpty || m.name.toLowerCase().contains(q)))
          m,
    ];
  }

  Future<void> _add() async {
    if (await addMembersToProject(context, widget.session, project)) {
      await widget.onChanged();
    }
  }

  /// [userIds]를 [role]로 옮긴다 — 담당자가 한 명도 안 남는 이동은 서버가 막고, 그 문구를 그대로 보여준다.
  Future<void> _move(List<String> userIds, String role) async {
    final targets = userIds.where((id) => _roleOf(id) != role).toList();
    if (targets.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      for (final id in targets) {
        await widget.session.api!.setProjectMemberRole(project.id, id, role);
      }
      _checked.removeAll(targets);
      await widget.onChanged();
    } catch (e) {
      if (mounted) showAppToast(context, '역할을 바꾸지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(AppUser user) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('멤버 제외'),
        content: Text('${user.name}님을 이 프로젝트에서 제외할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('제외'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.session.api!.removeProjectMember(project.id, user.id);
      await widget.onChanged();
    } catch (e) {
      if (mounted) showAppToast(context, '제외하지 못했습니다: $e');
    }
  }

  /// 공개 프로젝트의 "담당자 추가" — 고른 사람을 프로젝트에 넣고 바로 담당자로 올린다.
  Future<void> _addOwner() async {
    if (await addMembersToProject(
      context,
      widget.session,
      project,
      asOwner: true,
    )) {
      await widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final owners = _of('owner', _rightQuery);
    // 공개 프로젝트는 정회원 이상 팀원 모두가 자동으로 멤버라 초대·제외가 없다 — 담당자만
    // 지정하면 되고, 인원 제한도 없다. 담당자의 X는 프로젝트에서 빼는 게 아니라 일반 멤버로
    // 내리는 것이다(빼도 공개 프로젝트라 다시 자동으로 들어온다).
    if (project.isPublic) {
      final canManage = project.isOwner || widget.session.canManageCurrentTeam;
      return _Pane(
        title: '프로젝트 담당자',
        description: '프로젝트에 담당자를 지정합니다.',
        scrollable: false,
        action: canManage
            ? FilledButton.icon(
                onPressed: _addOwner,
                icon: const Icon(Icons.person_add_alt, size: 18),
                label: const Text('담당자 추가'),
              )
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '공개 프로젝트는 정회원 이상 팀원 모두가 멤버입니다.',
              style: TextStyle(color: theme.hintColor, fontSize: 12),
            ),
            const SizedBox(height: 2),
            Text(
              '따로 초대하거나 제외할 필요가 없어 멤버 목록은 표시되지 않으며, '
              '프로젝트 담당자 수에는 제한이 없습니다.',
              style: TextStyle(color: theme.hintColor, fontSize: 12),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _MemberList(
                title: '프로젝트 담당자',
                role: 'owner',
                users: owners,
                session: widget.session,
                checked: const {},
                selectable: false,
                roleOf: _roleOf,
                onQuery: (v) => setState(() => _rightQuery = v),
                onToggle: (_, _) {},
                onDropped: (_) {},
                onRemove: canManage ? (u) => _move([u.id], 'member') : null,
                removeTooltip: '담당자 해제',
              ),
            ),
          ],
        ),
      );
    }

    final members = _of('member', _leftQuery);
    final checkedMembers = members
        .where((m) => _checked.contains(m.id))
        .map((m) => m.id)
        .toList();
    final checkedOwners = owners
        .where((m) => _checked.contains(m.id))
        .map((m) => m.id)
        .toList();

    return _Pane(
      title: '멤버 관리',
      description: '멤버를 끌어다 놓거나 가운데 화살표로 역할을 바꿀 수 있습니다.',
      scrollable: false,
      action: FilledButton.icon(
        onPressed: _add,
        icon: const Icon(Icons.person_add_alt, size: 18),
        label: const Text('멤버 초대하기'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '비공개 프로젝트라 여기에 추가된 멤버만 접근할 수 있습니다. '
            '프로젝트 담당자는 설정을 바꿀 수 있고, 팀 소유자·관리자는 담당자가 아니어도 관리할 수 있습니다.',
            style: TextStyle(color: theme.hintColor, fontSize: 12),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _MemberList(
                    title: '프로젝트 멤버',
                    role: 'member',
                    users: members,
                    session: widget.session,
                    checked: _checked,
                    roleOf: _roleOf,
                    onQuery: (v) => setState(() => _leftQuery = v),
                    onToggle: (id, on) => setState(
                      () => on ? _checked.add(id) : _checked.remove(id),
                    ),
                    onDropped: (ids) => _move(ids, 'member'),
                    onRemove: _remove,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.chevron_right),
                        tooltip: '담당자로',
                        onPressed: checkedMembers.isEmpty
                            ? null
                            : () => _move(checkedMembers, 'owner'),
                      ),
                      IconButton(
                        icon: const Icon(Icons.chevron_left),
                        tooltip: '멤버로',
                        onPressed: checkedOwners.isEmpty
                            ? null
                            : () => _move(checkedOwners, 'member'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _MemberList(
                    title: '프로젝트 담당자',
                    role: 'owner',
                    users: owners,
                    session: widget.session,
                    checked: _checked,
                    roleOf: _roleOf,
                    onQuery: (v) => setState(() => _rightQuery = v),
                    onToggle: (id, on) => setState(
                      () => on ? _checked.add(id) : _checked.remove(id),
                    ),
                    onDropped: (ids) => _move(ids, 'owner'),
                    onRemove: _remove,
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

/// 멤버 목록 한 쪽 — 카드를 끌어다 반대쪽에 놓으면 역할이 바뀐다.
class _MemberList extends StatefulWidget {
  final String title;
  final String role;
  final List<AppUser> users;
  final Session session;
  final Set<String> checked;
  final String Function(String userId) roleOf;
  final ValueChanged<String> onQuery;
  final void Function(String userId, bool on) onToggle;
  final void Function(List<String> userIds) onDropped;

  /// 줄 오른쪽 X — null이면 X를 그리지 않는다(공개 프로젝트에서 관리 권한이 없을 때).
  final void Function(AppUser user)? onRemove;

  /// X의 툴팁 — 공개 프로젝트의 담당자 목록에서는 "담당자 해제"다(프로젝트에서 빼지 않는다).
  final String removeTooltip;

  /// 목록이 하나뿐일 때(공개 프로젝트의 담당자 목록)는 역할을 옮길 상대가 없어서 체크상자와
  /// 끌어다 놓기를 빼고 이름만 보여준다.
  final bool selectable;

  const _MemberList({
    required this.title,
    required this.role,
    required this.users,
    required this.session,
    required this.checked,
    required this.roleOf,
    required this.onQuery,
    required this.onToggle,
    required this.onDropped,
    required this.onRemove,
    this.removeTooltip = '프로젝트에서 제외',
    this.selectable = true,
  });

  @override
  State<_MemberList> createState() => _MemberListState();
}

class _MemberListState extends State<_MemberList> {
  // 양쪽 목록이 기본(Primary) 스크롤 컨트롤러를 같이 쓰면 스크롤바가 그려지지 않는다.
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _row(AppUser user) {
    final theme = Theme.of(context);
    final card = Material(
      color: Colors.transparent,
      child: Row(
        children: [
          if (widget.selectable)
            Checkbox(
              value: widget.checked.contains(user.id),
              onChanged: (v) => widget.onToggle(user.id, v == true),
            )
          else
            const SizedBox(width: 8),
          UserAvatar(
            user: user,
            resolveUrl: widget.session.resolveUrl,
            radius: 13,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              user.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (user.role != null)
            RoleBadge(
              label: accountRoleLabel(user.role!),
              bg: roleBadgeColors(context, user.role!).bg,
              fg: roleBadgeColors(context, user.role!).fg,
            ),
          if (widget.onRemove != null)
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: widget.removeTooltip,
              visualDensity: VisualDensity.compact,
              onPressed: () => widget.onRemove!(user),
            ),
        ],
      ),
    );
    if (!widget.selectable) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: card,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Draggable<String>(
        data: user.id,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 220,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(user.name, overflow: TextOverflow.ellipsis),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.35, child: card),
        child: card,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => widget.roleOf(d.data) != widget.role,
      onAcceptWithDetails: (d) => widget.onDropped([d.data]),
      builder: (context, candidate, _) {
        final hovering = candidate.isNotEmpty;
        return Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: hovering ? theme.colorScheme.primary : theme.dividerColor,
              width: hovering ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    widget.title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${widget.users.length}',
                    style: TextStyle(color: theme.hintColor),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(
                  hintText: '멤버 검색',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: widget.onQuery,
              ),
              const SizedBox(height: 6),
              Expanded(
                child: widget.users.isEmpty
                    ? Center(
                        child: Text(
                          widget.selectable
                              ? '없습니다. 여기로 끌어다 놓으세요.'
                              : '아직 담당자가 없습니다.',
                          style: TextStyle(
                            color: theme.hintColor,
                            fontSize: 12,
                          ),
                        ),
                      )
                    : MutedScrollbar(
                        controller: _scroll,
                        child: ListView(
                          controller: _scroll,
                          children: [for (final u in widget.users) _row(u)],
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ───────────────────────── 노트 ─────────────────────────

/// 노트 수정·삭제 권한 — 'all'(모두) | 'creator_admin'(생성자와 관리자). 고르면 바로 저장하고,
/// 실패하면 원래대로 되돌린다. 바꿀 수 있는 사람은 프로젝트 담당자와 팀 소유자·관리자뿐이다
/// (서버도 다시 확인한다). 노트 댓글은 이 설정과 무관하다.
class _NotesPane extends StatefulWidget {
  final Session session;
  final Project project;
  final Future<void> Function() onChanged;
  const _NotesPane({
    required this.session,
    required this.project,
    required this.onChanged,
  });

  @override
  State<_NotesPane> createState() => _NotesPaneState();
}

class _NotesPaneState extends State<_NotesPane> {
  /// 화면에 보이는(마지막으로 고른) 값.
  late String _edit;
  late String _delete;

  /// 서버에 저장된 값 — 저장에 실패하면 여기로 되돌린다.
  late String _savedEdit;
  late String _savedDelete;
  bool _saving = false;

  bool get _canManage =>
      widget.project.isOwner || widget.session.canManageCurrentTeam;

  @override
  void initState() {
    super.initState();
    _edit = _savedEdit = widget.project.noteEditPermission;
    _delete = _savedDelete = widget.project.noteDeletePermission;
  }

  @override
  void didUpdateWidget(_NotesPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 다시 불러온 프로젝트(다른 사람이 바꾼 값 포함)를 따라간다 — 저장 중에는 고른 값을 그대로 둔다.
    if (!_saving) {
      _edit = _savedEdit = widget.project.noteEditPermission;
      _delete = _savedDelete = widget.project.noteDeletePermission;
    }
  }

  /// 누르자마자 바뀐 것처럼 보이고 바로 저장한다. 앞 저장이 끝나기 전에 또 고르면 버리지 않고
  /// 앞 저장이 끝난 뒤 이어서 보낸다(라디오는 저장 중에도 누를 수 있다).
  void _choose({String? edit, String? delete}) {
    if (!_canManage) return;
    if ((edit ?? _edit) == _edit && (delete ?? _delete) == _delete) return;
    setState(() {
      _edit = edit ?? _edit;
      _delete = delete ?? _delete;
    });
    _flush();
  }

  /// 저장된 값과 다른 동안 한 번에 하나씩 PATCH한다 — 바뀐 항목만 보낸다.
  Future<void> _flush() async {
    if (_saving) return;
    _saving = true;
    var saved = false;
    while (mounted && (_edit != _savedEdit || _delete != _savedDelete)) {
      final edit = _edit;
      final delete = _delete;
      try {
        await widget.session.api!.updateProject(
          widget.project.id,
          noteEditPermission: edit != _savedEdit ? edit : null,
          noteDeletePermission: delete != _savedDelete ? delete : null,
        );
        _savedEdit = edit;
        _savedDelete = delete;
        saved = true;
      } catch (e) {
        if (!mounted) return;
        // 실패하면 마지막으로 저장된 값으로 되돌린다(그 사이 고른 것도 같이 취소).
        setState(() {
          _edit = _savedEdit;
          _delete = _savedDelete;
        });
        showAppToast(context, '노트 권한을 저장하지 못했습니다: $e');
        break;
      }
    }
    _saving = false;
    if (saved && mounted) await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final canManage = _canManage;
    return _Pane(
      title: '노트',
      description: canManage
          ? '프로젝트 노트를 수정·삭제할 수 있는 사람을 정합니다.'
          : '프로젝트 노트를 수정·삭제할 수 있는 사람입니다. 프로젝트 담당자와 팀 소유자·관리자만 바꿀 수 있습니다.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PermissionSection(
            keyPrefix: 'note-edit',
            title: '노트 수정 권한',
            description:
                "노트를 수정할 수 있는 권한을 설정합니다. '생성자와 관리자' 선택 시, "
                '작성자 본인과 관리자만 수정할 수 있습니다.',
            value: _edit,
            enabled: canManage,
            onChanged: (v) => _choose(edit: v),
          ),
          const SizedBox(height: 24),
          _PermissionSection(
            keyPrefix: 'note-delete',
            title: '노트 삭제 권한',
            description:
                "노트를 삭제할 수 있는 권한을 설정합니다. '생성자와 관리자' 선택 시, "
                '작성자 본인과 관리자만 삭제할 수 있습니다.',
            value: _delete,
            enabled: canManage,
            onChanged: (v) => _choose(delete: v),
          ),
        ],
      ),
    );
  }
}

/// 권한 한 가지 — 굵은 작은 제목 아래 둥근 테두리 칸에 회색 설명과 "모두 / 생성자와 관리자" 라디오.
class _PermissionSection extends StatelessWidget {
  /// 테스트에서 고를 때 쓰는 키 앞부분 — 라디오 줄의 키는 '[keyPrefix]-값'.
  final String keyPrefix;
  final String title;
  final String description;
  final String value;
  final bool enabled;
  final ValueChanged<String> onChanged;
  const _PermissionSection({
    required this.keyPrefix,
    required this.title,
    required this.description,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  static const _options = [('all', '모두'), ('creator_admin', '생성자와 관리자')];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: theme.dividerColor),
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                description,
                style: TextStyle(color: theme.hintColor, fontSize: 12),
              ),
              const SizedBox(height: 6),
              RadioGroup<String>(
                groupValue: value,
                onChanged: (v) {
                  if (v != null && enabled) onChanged(v);
                },
                child: Wrap(
                  spacing: 20,
                  children: [
                    for (final (v, label) in _options)
                      InkWell(
                        key: ValueKey('$keyPrefix-$v'),
                        borderRadius: BorderRadius.circular(6),
                        onTap: enabled ? () => onChanged(v) : null,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Radio<String>(value: v, enabled: enabled),
                              Text(
                                label,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: enabled ? null : theme.disabledColor,
                                ),
                              ),
                            ],
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
    );
  }
}

// ───────────────────────── 5. 종료 / 삭제 ─────────────────────────

class _DangerPane extends StatefulWidget {
  final Session session;
  final Project project;
  final Future<void> Function() onArchivedChanged;
  final VoidCallback onDeleted;
  const _DangerPane({
    required this.session,
    required this.project,
    required this.onArchivedChanged,
    required this.onDeleted,
  });

  @override
  State<_DangerPane> createState() => _DangerPaneState();
}

class _DangerPaneState extends State<_DangerPane> {
  final _confirm = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _setArchived(bool archived) async {
    setState(() => _busy = true);
    try {
      await widget.session.api!.updateProject(
        widget.project.id,
        archived: archived,
      );
      if (mounted) {
        showAppToast(context, archived ? '프로젝트를 종료했습니다.' : '프로젝트를 다시 시작했습니다.');
      }
      await widget.onArchivedChanged();
    } catch (e) {
      if (mounted) showAppToast(context, '바꾸지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    setState(() => _busy = true);
    try {
      await widget.session.api!.deleteProject(widget.project.id);
      widget.onDeleted();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showAppToast(context, '삭제하지 못했습니다: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final project = widget.project;
    final canDelete = _confirm.text.trim() == project.name;
    return _Pane(
      title: project.archived ? '프로젝트 다시 시작 / 삭제' : '프로젝트 종료 / 삭제',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  project.archived ? '프로젝트 다시 시작' : '프로젝트 종료',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  project.archived
                      ? '다시 시작하면 업무를 만들고 고칠 수 있습니다.'
                      : '프로젝트를 종료하면 업무 생성·수정·삭제 등 모든 쓰기 작업이 제한됩니다. 읽기는 가능합니다.',
                  style: TextStyle(color: theme.hintColor, fontSize: 12),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  style: project.archived
                      ? null
                      : FilledButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                        ),
                  onPressed: _busy
                      ? null
                      : () => _setArchived(!project.archived),
                  child: Text(project.archived ? '다시 시작' : '프로젝트 종료'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.redAccent),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: Colors.redAccent,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '프로젝트 삭제',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                      ).copyWith(color: Colors.redAccent),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '프로젝트를 삭제하면 모든 업무·댓글·노트가 영구히 삭제되며 복구할 수 없습니다.',
                  style: TextStyle(color: theme.hintColor, fontSize: 12),
                ),
                const SizedBox(height: 12),
                Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: '계속하려면 프로젝트 이름 '),
                      TextSpan(
                        text: '"${project.name}"',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const TextSpan(text: '을 입력하세요'),
                    ],
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _confirm,
                  decoration: const InputDecoration(
                    hintText: '프로젝트 이름 입력',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                  ),
                  onPressed: (_busy || !canDelete) ? null : _delete,
                  child: const Text('프로젝트 영구 삭제'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── 멤버 고르기 ─────────────────────────

class _MemberPickDialog extends StatefulWidget {
  final Session session;
  final List<AppUser> candidates;

  /// 대화상자 제목 — 멤버 초대와 담당자 추가가 같은 고르기 화면을 쓴다.
  final String title;
  const _MemberPickDialog({
    required this.session,
    required this.candidates,
    required this.title,
  });

  @override
  State<_MemberPickDialog> createState() => _MemberPickDialogState();
}

class _MemberPickDialogState extends State<_MemberPickDialog> {
  final _selected = <String>{};
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        height: 360,
        child: MutedScrollbar(
          controller: _scroll,
          child: ListView(
            controller: _scroll,
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
