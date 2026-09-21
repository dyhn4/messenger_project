import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/floating_dialog.dart';
import '../../widgets/muted_scrollbar.dart';
import '../../widgets/user_avatar.dart';
import 'project_forms.dart';

/// 프로젝트 설정을 닫은 결과 — 내용이 바뀌었는지, 프로젝트가 지워졌는지.
enum ProjectSettingsResult { changed, deleted }

/// 프로젝트 설정 — 기본 정보(이름/설명/색상/공개), 구성원(초대·역할·제외), 삭제.
/// 프로젝트 담당자와 팀 소유자·관리자만 열 수 있다(서버도 다시 확인한다).
Future<ProjectSettingsResult?> showProjectSettingsDialog(
  BuildContext context,
  Session session,
  String projectId,
) {
  return showDialog<ProjectSettingsResult>(
    context: context,
    builder: (_) => _ProjectSettings(session: session, projectId: projectId),
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

class _ProjectSettings extends StatefulWidget {
  final Session session;
  final String projectId;
  const _ProjectSettings({required this.session, required this.projectId});

  @override
  State<_ProjectSettings> createState() => _ProjectSettingsState();
}

class _ProjectSettingsState extends State<_ProjectSettings> {
  Project? _project;
  String? _error;
  final _name = TextEditingController();
  final _description = TextEditingController();
  String _color = projectColorChoices.first;
  bool _isPublic = true;
  bool _saving = false;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load(initial: true);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _load({bool initial = false}) async {
    try {
      final p = await widget.session.api!.fetchProject(widget.projectId);
      if (!mounted) return;
      setState(() {
        _project = p;
        _error = null;
        if (initial) {
          _name.text = p.name;
          _description.text = p.description ?? '';
          _color = p.color.toUpperCase();
          _isPublic = p.isPublic;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
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
        widget.projectId,
        name: name,
        description: _description.text.trim(),
        color: _color,
        isPublic: _isPublic,
      );
      _changed = true;
      if (mounted) showAppToast(context, '저장했습니다.');
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '저장하지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addMembers() async {
    final project = _project;
    if (project == null) return;
    if (await addMembersToProject(context, widget.session, project)) {
      _changed = true;
      await _load();
    }
  }

  Future<void> _setRole(AppUser user, String role) async {
    try {
      await widget.session.api!.setProjectMemberRole(
        widget.projectId,
        user.id,
        role,
      );
      _changed = true;
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '역할을 바꾸지 못했습니다: $e');
    }
  }

  Future<void> _remove(AppUser user) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('구성원 제외'),
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
      await widget.session.api!.removeProjectMember(widget.projectId, user.id);
      _changed = true;
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '제외하지 못했습니다: $e');
    }
  }

  Future<void> _setArchived(bool archived) async {
    final project = _project;
    if (project == null) return;
    if (archived) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('프로젝트 종료'),
          content: Text(
            '"${project.name}"을(를) 종료할까요? 업무·노트는 그대로 남고 읽기만 할 수 있으며, '
            '사이드바의 "종료된 프로젝트"로 옮겨집니다. 언제든 다시 시작할 수 있습니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: const Text('종료'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await widget.session.api!.updateProject(
        widget.projectId,
        archived: archived,
      );
      _changed = true;
      if (mounted) {
        showAppToast(context, archived ? '프로젝트를 종료했습니다.' : '프로젝트를 다시 시작했습니다.');
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '바꾸지 못했습니다: $e');
    }
  }

  Future<void> _delete() async {
    final project = _project;
    if (project == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('프로젝트 삭제'),
        content: Text('"${project.name}"의 업무와 댓글이 모두 삭제됩니다. 되돌릴 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.session.api!.deleteProject(project.id);
      if (mounted) Navigator.of(context).pop(ProjectSettingsResult.deleted);
    } catch (e) {
      if (mounted) showAppToast(context, '삭제하지 못했습니다: $e');
    }
  }

  Widget _section(String title, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 10),
    child: Row(
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        const Spacer(),
        ?trailing,
      ],
    ),
  );

  Widget _colorPicker() => Wrap(
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
  );

  Widget _memberRow(Project project, AppUser user) {
    final role = project.memberRoles[user.id] ?? 'member';
    final isOwner = role == 'owner';
    final ownerCount = project.memberRoles.values
        .where((r) => r == 'owner')
        .length;
    final lastOwner = isOwner && ownerCount <= 1;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: UserAvatar(
        user: user,
        resolveUrl: widget.session.resolveUrl,
        radius: 14,
      ),
      title: Text(user.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: user.position == null ? null : Text(user.position!),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButton<String>(
            value: role,
            underline: const SizedBox.shrink(),
            isDense: true,
            items: [
              const DropdownMenuItem(value: 'owner', child: Text('담당자')),
              DropdownMenuItem(
                value: 'member',
                enabled: !lastOwner,
                child: const Text('구성원'),
              ),
            ],
            onChanged: (v) {
              if (v != null && v != role) _setRole(user, v);
            },
          ),
          IconButton(
            icon: const Icon(Icons.person_remove_outlined, size: 20),
            tooltip: isOwner ? '담당자는 먼저 구성원으로 바꿔야 제외할 수 있습니다' : '제외',
            onPressed: isOwner ? null : () => _remove(user),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final project = _project;
    final hint = Theme.of(context).hintColor;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          Navigator.of(
            context,
          ).pop(_changed ? ProjectSettingsResult.changed : null);
        }
      },
      child: FloatingDialog(
        title: '프로젝트 설정',
        maxWidth: 560,
        maxHeight: 720,
        child: _error != null
            ? Center(child: Text(_error!))
            : project == null
            ? const Center(child: CircularProgressIndicator())
            : MutedScrollbar(
                child: ListView(
                  padding: const EdgeInsets.only(right: 12),
                  children: [
                    _section('기본 정보'),
                    TextField(
                      controller: _name,
                      maxLength: 60,
                      decoration: const InputDecoration(
                        labelText: '프로젝트 이름',
                        counterText: '',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _description,
                      minLines: 3,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: '설명',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text('대표 색상', style: TextStyle(color: hint)),
                    const SizedBox(height: 8),
                    _colorPicker(),
                    const SizedBox(height: 14),
                    Text(
                      '프로젝트 키: ${project.identifier} (변경할 수 없습니다)',
                      style: TextStyle(color: hint, fontSize: 12),
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('공개 프로젝트'),
                      subtitle: Text(
                        _isPublic
                            ? '정회원 이상 팀원이 초대 없이 찾아서 참여할 수 있습니다.'
                            : '초대한 구성원만 볼 수 있습니다.',
                        style: const TextStyle(fontSize: 12),
                      ),
                      value: _isPublic,
                      onChanged: (v) => setState(() => _isPublic = v),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: _saving ? null : _save,
                        child: const Text('저장'),
                      ),
                    ),
                    const Divider(height: 32),
                    _section(
                      '구성원 ${project.members.length}명',
                      trailing: TextButton.icon(
                        onPressed: _addMembers,
                        icon: const Icon(Icons.person_add_alt, size: 18),
                        label: const Text('구성원 추가'),
                      ),
                    ),
                    for (final m in project.members) _memberRow(project, m),
                    const Divider(height: 32),
                    _section(project.archived ? '프로젝트 다시 시작' : '프로젝트 종료'),
                    Text(
                      project.archived
                          ? '다시 시작하면 업무를 만들고 고칠 수 있습니다.'
                          : '업무를 모두 마무리한 프로젝트를 보관합니다. 읽기만 할 수 있고, 마감 알림도 멈춥니다.',
                      style: TextStyle(color: hint, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () => _setArchived(!project.archived),
                        icon: Icon(
                          project.archived
                              ? Icons.play_circle_outline
                              : Icons.inventory_2_outlined,
                          size: 18,
                        ),
                        label: Text(project.archived ? '다시 시작' : '프로젝트 종료'),
                      ),
                    ),
                    const Divider(height: 32),
                    _section('프로젝트 삭제'),
                    Text(
                      '업무와 댓글이 모두 삭제되며 되돌릴 수 없습니다.',
                      style: TextStyle(color: hint, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                        ),
                        onPressed: _delete,
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('프로젝트 삭제'),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
      ),
    );
  }
}

class _MemberPickDialog extends StatefulWidget {
  final Session session;
  final List<AppUser> candidates;
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
