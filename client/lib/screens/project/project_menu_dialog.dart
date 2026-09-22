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
import 'task_config_manager.dart'
    show ProjectFieldEditor, ProjectPriorityEditor, ProjectStatusEditor;
import 'task_type_manager.dart' show ProjectTypeEditor;
import 'template_automation_manager.dart' show ProjectTemplateAutomationEditor;

/// "프로젝트 메뉴"를 닫은 결과 — 내용이 바뀌었는지, 프로젝트가 지워졌는지.
enum ProjectMenuResult { changed, deleted }

/// 프로젝트 화면 오른쪽 위 톱니 버튼으로 여는 통합 설정 창 — 왼쪽 메뉴(기본 정보 / 필드·상태 /
/// 멤버 / 알림 / 템플릿·자동화 / 삭제)로 오른쪽 내용을 바꾼다. 항목별 권한은 서버가 다시
/// 확인하므로 여기서는 화면만 나눈다.
Future<ProjectMenuResult?> showProjectMenuDialog(
  BuildContext context,
  Session session,
  String projectId,
) {
  return showDialog<ProjectMenuResult>(
    context: context,
    builder: (_) => _ProjectMenuDialog(session: session, projectId: projectId),
  );
}

/// 팀원 중 아직 이 프로젝트에 없는 정회원 이상을 골라 추가한다. 추가했으면 true.
Future<bool> addMembersToProject(
  BuildContext context,
  Session session,
  Project project,
) async {
  final all = await session.fetchTeamMembers();
  if (!context.mounted) return false;
  final existing = project.members.map((m) => m.id).toSet();
  final candidates = all
      .where((u) => !existing.contains(u.id) && u.role != 'guest')
      .toList();
  if (candidates.isEmpty) {
    showAppToast(context, '추가할 수 있는 팀원이 없습니다. (준회원은 프로젝트에 참여할 수 없습니다.)');
    return false;
  }
  final picked = await showDialog<List<String>>(
    context: context,
    builder: (_) => _MemberPickDialog(session: session, candidates: candidates),
  );
  if (picked == null || picked.isEmpty || !context.mounted) return false;
  try {
    await session.api!.addProjectMembers(project.id, picked);
    return true;
  } catch (e) {
    if (context.mounted) showAppToast(context, '구성원을 추가하지 못했습니다: $e');
    return false;
  }
}

enum _Section { basic, fields, members, notifications, automation, danger }

String _sectionLabel(_Section s) => switch (s) {
  _Section.basic => '기본 정보',
  _Section.fields => '필드 / 상태',
  _Section.members => '멤버',
  _Section.notifications => '알림',
  _Section.automation => '템플릿 · 자동화',
  _Section.danger => '삭제',
};

IconData _sectionIcon(_Section s) => switch (s) {
  _Section.basic => Icons.info_outline,
  _Section.fields => Icons.dashboard_customize_outlined,
  _Section.members => Icons.people_outline,
  _Section.notifications => Icons.notifications_none,
  _Section.automation => Icons.bolt_outlined,
  _Section.danger => Icons.delete_outline,
};

class _ProjectMenuDialog extends StatefulWidget {
  final Session session;
  final String projectId;
  const _ProjectMenuDialog({required this.session, required this.projectId});

  @override
  State<_ProjectMenuDialog> createState() => _ProjectMenuDialogState();
}

class _ProjectMenuDialogState extends State<_ProjectMenuDialog> {
  _Section _section = _Section.basic;
  Project? _project;
  String? _error;
  bool _changed = false;

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
    _changed = true;
    await _load();
  }

  void _close({bool deleted = false}) {
    Navigator.of(context).pop(
      deleted
          ? ProjectMenuResult.deleted
          : (_changed ? ProjectMenuResult.changed : null),
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
        title: '프로젝트 메뉴',
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
        return _FieldsPane(session: widget.session, projectId: project.id);
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
        return ProjectTemplateAutomationEditor(
          session: widget.session,
          projectId: project.id,
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
                // 라벨이 길어도(템플릿 · 자동화) 메뉴 폭을 넘지 않게 줄여서 맞춘다.
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
class _Pane extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                  description!,
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
            child: scrollable
                ? MutedScrollbar(child: SingleChildScrollView(child: child))
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
                ? '공개: 정회원 이상 권한을 가진 모든 멤버가 초대 없이 프로젝트를 찾아 참여하고 업무를 만들 수 있습니다.'
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
  final String projectId;
  const _FieldsPane({required this.session, required this.projectId});

  @override
  State<_FieldsPane> createState() => _FieldsPaneState();
}

class _FieldsPaneState extends State<_FieldsPane> {
  // 기본 필드 카드의 스크롤 — 기본(Primary) 컨트롤러를 다른 목록과 나눠 쓰면 스크롤바가
  // 그려지지 않으므로 이 카드 전용으로 하나 만든다.
  final _basicScroll = ScrollController();

  @override
  void dispose() {
    _basicScroll.dispose();
    super.dispose();
  }

  Session get session => widget.session;
  String get projectId => widget.projectId;

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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (desc != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    desc,
                    style: TextStyle(color: theme.hintColor, fontSize: 12),
                  ),
                ],
              ],
            ),
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
          child: card(
            '사용자 정의 필드',
            '프로젝트에 필요한 입력 항목을 직접 추가합니다.',
            ProjectFieldEditor(session: session, projectId: projectId),
          ),
        ),
      ],
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final members = _of('member', _leftQuery);
    final owners = _of('owner', _rightQuery);
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
            project.isPublic
                ? '공개 프로젝트라 정회원 이상은 초대 없이도 참여할 수 있습니다. '
                      '프로젝트 담당자는 설정을 바꿀 수 있고, 팀 소유자·관리자는 담당자가 아니어도 관리할 수 있습니다.'
                : '비공개 프로젝트라 여기에 추가된 멤버만 접근할 수 있습니다. '
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
  final void Function(AppUser user) onRemove;

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
          Checkbox(
            value: widget.checked.contains(user.id),
            onChanged: (v) => widget.onToggle(user.id, v == true),
          ),
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
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: '프로젝트에서 제외',
            visualDensity: VisualDensity.compact,
            onPressed: () => widget.onRemove(user),
          ),
        ],
      ),
    );
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
                          '없습니다. 여기로 끌어다 놓으세요.',
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
  const _MemberPickDialog({required this.session, required this.candidates});

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
      title: const Text('멤버 초대하기'),
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
