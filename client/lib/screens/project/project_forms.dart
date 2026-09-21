import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/floating_dialog.dart';
import '../../widgets/muted_scrollbar.dart';
import '../../widgets/user_avatar.dart';
import 'project_widgets.dart';

// intl의 DateFormat(locale: 'ko')는 initializeDateFormatting()을 먼저 부르지 않으면
// LocaleDataException을 던진다(이 앱은 그 초기화를 어디서도 안 한다 — time_format.dart와
// 같은 이유로 여기도 직접 문자열을 조립한다).
String _formatDue(DateTime dt) =>
    '${dt.year}.${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')}';

String _formatCommentTime(DateTime dt) {
  final isPm = dt.hour >= 12;
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  return '${dt.month}월 ${dt.day}일 ${isPm ? '오후' : '오전'} $hour12:${dt.minute.toString().padLeft(2, '0')}';
}

/// "프로젝트 생성" — 이름, 대표 색상, 프로젝트 키, 설명, 공개 설정을 입력한다. 만든 사람이
/// 담당자(owner)가 되고, 구성원은 만든 뒤 프로젝트 화면에서 초대한다(공개 프로젝트는 팀의
/// 정회원 이상이 초대 없이 찾아서 참여할 수도 있다).
Future<Project?> showNewProjectDialog(
  BuildContext context,
  Session session,
  String teamId,
) {
  return showDialog<Project>(
    context: context,
    builder: (_) => _NewProjectDialog(session: session, teamId: teamId),
  );
}

/// 프로젝트 대표 색상 후보 — 첫 번째가 기본값.
const projectColorChoices = <String>[
  '#5B8DEF',
  '#10B981',
  '#F59E0B',
  '#EF4444',
  '#A78BFA',
  '#F472B6',
  '#64748B',
];

class _NewProjectDialog extends StatefulWidget {
  final Session session;
  final String teamId;
  const _NewProjectDialog({required this.session, required this.teamId});

  @override
  State<_NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<_NewProjectDialog> {
  final _name = TextEditingController();
  final _identifier = TextEditingController();
  final _description = TextEditingController();
  String _color = projectColorChoices.first;
  bool _isPublic = true;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _identifier.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = '프로젝트 이름을 입력하세요.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final project = await widget.session.api!.createProject(
        teamId: widget.teamId,
        name: _name.text.trim(),
        identifier: _identifier.text.trim().toUpperCase(),
        description: _description.text.trim().isEmpty
            ? null
            : _description.text.trim(),
        color: _color,
        isPublic: _isPublic,
      );
      if (mounted) Navigator.of(context).pop(project);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
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
    return FloatingDialog(
      title: '프로젝트 생성',
      maxWidth: 520,
      maxHeight: 780,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: MutedScrollbar(
              child: ListView(
                padding: const EdgeInsets.only(right: 12),
                children: [
                  _label('프로젝트 이름'),
                  TextField(
                    controller: _name,
                    autofocus: true,
                    maxLength: 60,
                    decoration: const InputDecoration(
                      hintText: '프로젝트 이름을 입력하세요',
                      counterText: '',
                      border: OutlineInputBorder(),
                    ),
                    // 이름을 적으면 키를 아직 안 건드린 경우에 한해 영문 앞글자로 추천한다.
                    onChanged: (v) {
                      if (_identifier.text.isNotEmpty) return;
                      final guess = v
                          .toUpperCase()
                          .replaceAll(RegExp(r'[^A-Z0-9]'), '')
                          .replaceFirst(
                            RegExp(r'^[0-9]+'),
                            '',
                          ); // 키는 영문으로 시작해야 한다.
                      if (guess.length >= 2) {
                        _identifier.text = guess.substring(
                          0,
                          guess.length > 4 ? 4 : guess.length,
                        );
                      }
                    },
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
                  _label(
                    '프로젝트 키',
                    hint: '프로젝트를 구분하기 위한 식별 키를 입력하세요. (예: HR, CX, DEV)',
                  ),
                  TextField(
                    controller: _identifier,
                    maxLength: 10,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      hintText: 'MKT',
                      counterText: '',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _label('설명'),
                  TextField(
                    controller: _description,
                    maxLines: 3,
                    minLines: 3,
                    decoration: const InputDecoration(
                      hintText: '프로젝트에 대한 설명을 추가하세요...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('공개 설정', style: TextStyle(color: hint)),
                  const SizedBox(height: 8),
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
                        ? '정회원 이상 권한을 가진 모든 멤버가 별도 초대 없이 프로젝트를 확인하고 참여할 수 있습니다.'
                        : '초대한 구성원만 프로젝트를 확인할 수 있습니다.',
                    style: TextStyle(color: hint, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text(
                      '프로젝트 생성',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "새 업무" — [projectId]를 주면 그 프로젝트에 바로 만들고, 없으면 [projects]에서 고르게 한다.
Future<Task?> showNewTaskDialog(
  BuildContext context,
  Session session, {
  List<Project> projects = const [],
  String? projectId,
  List<AppUser> members = const [],
  String? initialTitle,
  String? initialDescription,
}) {
  return showDialog<Task>(
    context: context,
    builder: (_) => _NewTaskDialog(
      session: session,
      projects: projects,
      projectId: projectId,
      members: members,
      initialTitle: initialTitle,
      initialDescription: initialDescription,
    ),
  );
}

class _NewTaskDialog extends StatefulWidget {
  final Session session;
  final List<Project> projects;
  final String? projectId;
  final List<AppUser> members;
  final String? initialTitle;
  final String? initialDescription;
  const _NewTaskDialog({
    required this.session,
    required this.projects,
    required this.projectId,
    required this.members,
    this.initialTitle,
    this.initialDescription,
  });

  @override
  State<_NewTaskDialog> createState() => _NewTaskDialogState();
}

class _NewTaskDialogState extends State<_NewTaskDialog> {
  late final _title = TextEditingController(text: widget.initialTitle);
  late final _description = TextEditingController(
    text: widget.initialDescription,
  );
  late String? _projectId = widget.projectId ?? widget.projects.firstOrNull?.id;
  late List<AppUser> _members = widget.members;
  String? _assigneeId;
  List<TaskStatusDef> _statuses = const [];
  String? _statusId;
  List<TaskFieldDef> _fields = const [];
  List<TaskTemplate> _templates = const [];
  String? _templateId;
  final _customValues = <String, dynamic>{};
  TaskPriority _priority = TaskPriority.normal;
  List<TaskType> _types = const [];
  String? _typeId;
  final _referenceIds = <String>{};
  DateTime? _startDate;
  DateTime? _dueDate;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_members.isEmpty) _loadMembers();
    _loadTypes();
  }

  /// 유형은 프로젝트마다 따로 관리하므로, 프로젝트를 고르거나 바꿀 때 그 프로젝트 것으로 받아온다.
  Future<void> _loadTypes() async {
    final id = _projectId;
    if (id == null) return;
    try {
      final types = await widget.session.api!.fetchTaskTypes(id);
      if (mounted) {
        setState(() {
          _types = types;
          if (!types.any((t) => t.id == _typeId)) _typeId = null;
        });
      }
    } catch (_) {
      // 유형을 못 받아와도 업무는 유형 없이 만들 수 있다.
    }
    try {
      final statuses = await widget.session.api!.fetchTaskStatuses(id);
      final fields = await widget.session.api!.fetchTaskFields(id);
      final templates = await widget.session.api!.fetchTaskTemplates(id);
      if (mounted) {
        setState(() {
          _templates = templates;
          _templateId = null;
          _statuses = statuses;
          if (!statuses.any((s) => s.id == _statusId)) {
            _statusId = statuses.firstOrNull?.id;
          }
          _fields = fields;
          _customValues.clear();
        });
      }
    } catch (_) {
      // 상태/필드를 못 받아와도 기본 상태(할 일)로 만들 수 있다.
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  /// 템플릿을 고르면 제목·설명·우선순위·유형·담당자·마감일을 그 값으로 채운다(비어 있는 항목은 그대로 둔다).
  void _applyTemplate(TaskTemplate t) {
    setState(() {
      _templateId = t.id;
      if (t.title.isNotEmpty) _title.text = t.title;
      if (t.description != null) _description.text = t.description!;
      _priority = t.priority;
      if (t.typeId != null && _types.any((x) => x.id == t.typeId)) {
        _typeId = t.typeId;
      }
      if (t.assigneeId != null && _members.any((m) => m.id == t.assigneeId)) {
        _assigneeId = t.assigneeId;
      }
      if (t.dueOffsetDays != null) {
        final now = DateTime.now();
        _dueDate = DateTime(now.year, now.month, now.day + t.dueOffsetDays!);
      }
    });
  }

  /// 담당자 후보는 그 프로젝트의 구성원 — 프로젝트를 바꾸면 다시 받아온다.
  Future<void> _loadMembers() async {
    final id = _projectId;
    if (id == null) return;
    try {
      final project = await widget.session.api!.fetchProject(id);
      if (mounted) {
        setState(() {
          _members = project.members;
          if (!_members.any((m) => m.id == _assigneeId)) _assigneeId = null;
          _referenceIds.removeWhere((id) => !_members.any((m) => m.id == id));
        });
      }
    } catch (_) {
      // 담당자를 못 고르는 정도라 조용히 넘어간다(업무는 담당자 없이도 만들 수 있다).
    }
  }

  Future<void> _submit() async {
    final projectId = _projectId;
    if (projectId == null) {
      setState(() => _error = '프로젝트를 고르세요.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final task = await widget.session.api!.createTask(
        projectId: projectId,
        title: _title.text.trim(),
        description: _description.text.trim().isEmpty
            ? null
            : _description.text.trim(),
        assigneeId: _assigneeId,
        statusId: _statusId,
        customValues: _customValues.isEmpty ? null : _customValues,
        priority: _priority,
        typeId: _typeId,
        referenceIds: _referenceIds.toList(),
        startDate: _startDate,
        dueDate: _dueDate,
      );
      if (mounted) Navigator.of(context).pop(task);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FloatingDialog(
      title: '새 업무',
      maxWidth: 520,
      maxHeight: 640,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: MutedScrollbar(
              child: ListView(
                children: [
                  if (widget.projectId == null && widget.projects.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: DropdownButtonFormField<String>(
                        initialValue: _projectId,
                        decoration: const InputDecoration(
                          labelText: '프로젝트',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final project in widget.projects)
                            DropdownMenuItem(
                              value: project.id,
                              child: Text(project.name),
                            ),
                        ],
                        onChanged: (v) {
                          setState(() => _projectId = v);
                          _loadMembers();
                          _loadTypes();
                        },
                      ),
                    ),
                  if (_templates.isNotEmpty) ...[
                    DropdownButtonFormField<String>(
                      key: ValueKey('tpl-$_templateId-${_templates.length}'),
                      initialValue: _templateId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '템플릿에서 불러오기',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (final t in _templates)
                          DropdownMenuItem(
                            value: t.id,
                            child: Text(
                              t.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        final t = _templates
                            .where((x) => x.id == v)
                            .firstOrNull;
                        if (t != null) _applyTemplate(t);
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: _title,
                    autofocus: true,
                    maxLength: 200,
                    decoration: const InputDecoration(
                      labelText: '업무 제목',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  TextField(
                    controller: _description,
                    maxLines: 4,
                    minLines: 2,
                    decoration: const InputDecoration(
                      labelText: '설명 (선택)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _AssigneeField(
                    session: widget.session,
                    members: _members,
                    value: _assigneeId,
                    onChanged: (v) => setState(() => _assigneeId = v),
                  ),
                  const SizedBox(height: 12),
                  _ReferenceField(
                    session: widget.session,
                    members: _members,
                    selectedIds: _referenceIds.toList(),
                    onChanged: (ids) => setState(() {
                      _referenceIds
                        ..clear()
                        ..addAll(ids);
                    }),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _TypeField(
                          types: _types,
                          value: _typeId,
                          onChanged: (v) => setState(() => _typeId = v),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          key: ValueKey(
                            'status-$_statusId-${_statuses.length}',
                          ),
                          initialValue: _statusId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: '상태',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final s in _statuses)
                              DropdownMenuItem(
                                value: s.id,
                                child: Text(
                                  s.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) => setState(() => _statusId = v),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<TaskPriority>(
                          initialValue: _priority,
                          decoration: const InputDecoration(
                            labelText: '우선순위',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final p in TaskPriority.values)
                              DropdownMenuItem(
                                value: p,
                                child: Text(taskPriorityLabel(p)),
                              ),
                          ],
                          onChanged: (v) => setState(
                            () => _priority = v ?? TaskPriority.normal,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _DueDateField(
                    label: '시작일',
                    value: _startDate,
                    onChanged: (v) => setState(() => _startDate = v),
                  ),
                  _DueDateField(
                    value: _dueDate,
                    onChanged: (v) => setState(() => _dueDate = v),
                  ),
                  if (_fields.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _CustomFieldsEditor(
                      fields: _fields,
                      values: _customValues,
                      commitOnChange: true,
                      onChanged: (id, v) => setState(() {
                        if (v == null) {
                          _customValues.remove(id);
                        } else {
                          _customValues[id] = v;
                        }
                      }),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('취소'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('등록'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 업무 상세 — 상태/담당자/마감일을 그 자리에서 바꾸고, 댓글로 논의한다.
Future<void> showTaskDetailDialog(
  BuildContext context,
  Session session,
  String taskId,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _TaskDetailDialog(session: session, taskId: taskId),
  );
}

class _TaskDetailDialog extends StatefulWidget {
  final Session session;
  final String taskId;
  const _TaskDetailDialog({required this.session, required this.taskId});

  @override
  State<_TaskDetailDialog> createState() => _TaskDetailDialogState();
}

class _TaskDetailDialogState extends State<_TaskDetailDialog> {
  final _comment = TextEditingController();
  Task? _task;
  List<AppUser> _members = const [];
  List<TaskType> _types = const [];
  List<TaskStatusDef> _statuses = const [];
  List<TaskFieldDef> _fields = const [];
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final task = await widget.session.api!.fetchTask(widget.taskId);
      final project = await widget.session.api!.fetchProject(task.projectId);
      final types = await widget.session.api!.fetchTaskTypes(task.projectId);
      final statuses = await widget.session.api!.fetchTaskStatuses(
        task.projectId,
      );
      final fields = await widget.session.api!.fetchTaskFields(task.projectId);
      if (mounted) {
        setState(() {
          _task = task;
          _members = project.members;
          _types = types;
          _statuses = statuses;
          _fields = fields;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 바꾼 항목 하나를 바로 저장한다(상태/담당자/마감일은 눌러서 즉시 반영되는 게 자연스럽다).
  Future<void> _patch({
    String? statusId,
    Map<String, dynamic>? customValues,
    TaskPriority? priority,
    String? assigneeId,
    bool clearAssignee = false,
    String? typeId,
    bool clearType = false,
    List<String>? referenceIds,
    DateTime? startDate,
    bool clearStartDate = false,
    DateTime? dueDate,
    bool clearDueDate = false,
  }) async {
    setState(() => _saving = true);
    try {
      final updated = await widget.session.api!.updateTask(
        widget.taskId,
        statusId: statusId,
        customValues: customValues,
        priority: priority,
        assigneeId: assigneeId,
        clearAssignee: clearAssignee,
        typeId: typeId,
        clearType: clearType,
        referenceIds: referenceIds,
        startDate: startDate,
        clearStartDate: clearStartDate,
        dueDate: dueDate,
        clearDueDate: clearDueDate,
      );
      if (mounted) {
        setState(() {
          // 응답에는 댓글이 안 들어있어서, 지금 들고 있는 댓글은 그대로 유지한다.
          _task = updated;
        });
        await _load();
      }
    } catch (e) {
      if (mounted) showAppToast(context, '저장하지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 이 업무가 [status] 상태인지 — 상태 id가 없는 예전 업무는 같은 분류의 첫 상태로 본다.
  bool _isCurrentStatus(Task task, TaskStatusDef status) {
    if (task.statusId != null && _statuses.any((s) => s.id == task.statusId)) {
      return task.statusId == status.id;
    }
    return _statuses.firstWhere((s) => s.category == task.status).id ==
        status.id;
  }

  Future<void> _addComment() async {
    final text = _comment.text.trim();
    if (text.isEmpty) return;
    _comment.clear();
    try {
      await widget.session.api!.addTaskComment(widget.taskId, text);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '댓글을 남기지 못했습니다: $e');
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('업무 삭제'),
        content: const Text('이 업무와 달린 댓글이 모두 삭제됩니다. 계속할까요?'),
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
      await widget.session.api!.deleteTask(widget.taskId);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showAppToast(context, '삭제하지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final task = _task;
    return FloatingDialog(
      title: task?.key ?? '업무',
      maxWidth: 560,
      maxHeight: 780,
      child: _error != null
          ? Center(child: Text(_error!))
          : task == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: MutedScrollbar(
                    child: ListView(
                      children: [
                        Text(
                          task.title,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        if (task.projectName != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            task.projectName!,
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: hint),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            for (final status in _statuses)
                              ChoiceChip(
                                label: Text(status.name),
                                avatar: Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: parseTypeColor(status.color),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                selected: _isCurrentStatus(task, status),
                                onSelected: _saving
                                    ? null
                                    : (_) => _patch(statusId: status.id),
                              ),
                            const SizedBox(width: 4),
                            DdayBadge(task: task),
                          ],
                        ),
                        const SizedBox(height: 16),
                        _AssigneeField(
                          session: widget.session,
                          members: _members,
                          value: task.assigneeId,
                          onChanged: (v) => v == null
                              ? _patch(clearAssignee: true)
                              : _patch(assigneeId: v),
                        ),
                        const SizedBox(height: 12),
                        _ReferenceField(
                          session: widget.session,
                          members: _members,
                          selectedIds: task.referenceIds,
                          onChanged: (ids) => _patch(referenceIds: ids),
                        ),
                        const SizedBox(height: 12),
                        _TypeField(
                          types: _types,
                          value: task.typeId,
                          onChanged: (v) => v == null
                              ? _patch(clearType: true)
                              : _patch(typeId: v),
                        ),
                        const SizedBox(height: 12),
                        _DueDateField(
                          label: '시작일',
                          value: task.startDate,
                          onChanged: (v) => v == null
                              ? _patch(clearStartDate: true)
                              : _patch(startDate: v),
                        ),
                        _DueDateField(
                          value: task.dueDate,
                          onChanged: (v) => v == null
                              ? _patch(clearDueDate: true)
                              : _patch(dueDate: v),
                        ),
                        if (_fields.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _CustomFieldsEditor(
                            fields: _fields,
                            values: task.customValues,
                            commitOnChange: false,
                            onChanged: (id, v) => _patch(customValues: {id: v}),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Text('우선순위', style: TextStyle(color: hint)),
                            const SizedBox(width: 12),
                            DropdownButton<TaskPriority>(
                              value: task.priority,
                              underline: const SizedBox.shrink(),
                              items: [
                                for (final p in TaskPriority.values)
                                  DropdownMenuItem(
                                    value: p,
                                    child: Text(taskPriorityLabel(p)),
                                  ),
                              ],
                              onChanged: _saving
                                  ? null
                                  : (v) =>
                                        v == null ? null : _patch(priority: v),
                            ),
                          ],
                        ),
                        if (task.description != null &&
                            task.description!.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(task.description!),
                          ),
                        ],
                        const SizedBox(height: 20),
                        Text(
                          '댓글 ${task.comments.length}',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 8),
                        if (task.comments.isEmpty)
                          const EmptyHint('아직 댓글이 없습니다')
                        else
                          for (final comment in task.comments)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${comment.senderName} · ${_formatCommentTime(comment.createdAt)}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(color: hint),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(comment.text),
                                ],
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _comment,
                        decoration: const InputDecoration(
                          hintText: '댓글 남기기',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: (_) => _addComment(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      icon: const Icon(Icons.send, size: 18),
                      onPressed: _addComment,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _delete,
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: Colors.redAccent,
                    ),
                    label: const Text(
                      '업무 삭제',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// 담당자 고르기 — 프로젝트 구성원 중에서(또는 "담당자 없음").
class _AssigneeField extends StatelessWidget {
  final Session session;
  final List<AppUser> members;
  final String? value;
  final ValueChanged<String?> onChanged;
  const _AssigneeField({
    required this.session,
    required this.members,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // 목록에 없는 담당자(구성원에서 빠진 경우)면 드롭다운이 값을 못 찾으므로 null로 떨어뜨린다.
    final safeValue = members.any((m) => m.id == value) ? value : null;
    return DropdownButtonFormField<String?>(
      initialValue: safeValue,
      decoration: const InputDecoration(
        labelText: '담당자',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        const DropdownMenuItem(value: null, child: Text('담당자 없음')),
        for (final user in members)
          DropdownMenuItem(
            value: user.id,
            child: Row(
              children: [
                UserAvatar(
                  user: user,
                  resolveUrl: session.resolveUrl,
                  radius: 10,
                ),
                const SizedBox(width: 8),
                Text(user.name),
              ],
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

/// 업무 유형 고르기 — 그 프로젝트의 유형 목록에서(없음도 가능).
class _TypeField extends StatelessWidget {
  final List<TaskType> types;
  final String? value;
  final ValueChanged<String?> onChanged;
  const _TypeField({
    required this.types,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final safeValue = types.any((t) => t.id == value) ? value : null;
    return DropdownButtonFormField<String?>(
      key: ValueKey('type-$safeValue-${types.length}'),
      initialValue: safeValue,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: '유형',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        const DropdownMenuItem(value: null, child: Text('유형 없음')),
        for (final type in types)
          DropdownMenuItem(
            value: type.id,
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: parseTypeColor(type.color),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(type.name, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

/// 참조자 고르기 — 고른 사람은 칩으로 보이고, 누르면 구성원 체크 목록이 뜬다.
class _ReferenceField extends StatelessWidget {
  final Session session;
  final List<AppUser> members;
  final List<String> selectedIds;
  final ValueChanged<List<String>> onChanged;
  const _ReferenceField({
    required this.session,
    required this.members,
    required this.selectedIds,
    required this.onChanged,
  });

  Future<void> _pick(BuildContext context) async {
    final result = await showDialog<List<String>>(
      context: context,
      builder: (_) => _ReferencePickDialog(
        session: session,
        members: members,
        initial: selectedIds,
      ),
    );
    if (result != null) onChanged(result);
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final selected = [
      for (final id in selectedIds)
        if (members.any((m) => m.id == id))
          members.firstWhere((m) => m.id == id),
    ];
    return InkWell(
      onTap: () => _pick(context),
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: '참조자',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        child: selected.isEmpty
            ? Text('참조자 없음 (눌러서 추가)', style: TextStyle(color: hint))
            : Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final user in selected)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      avatar: UserAvatar(
                        user: user,
                        resolveUrl: session.resolveUrl,
                        radius: 9,
                      ),
                      label: Text(user.name),
                    ),
                ],
              ),
      ),
    );
  }
}

class _ReferencePickDialog extends StatefulWidget {
  final Session session;
  final List<AppUser> members;
  final List<String> initial;
  const _ReferencePickDialog({
    required this.session,
    required this.members,
    required this.initial,
  });

  @override
  State<_ReferencePickDialog> createState() => _ReferencePickDialogState();
}

class _ReferencePickDialogState extends State<_ReferencePickDialog> {
  late final _selected = widget.initial.toSet();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('참조자 선택'),
      content: SizedBox(
        width: 360,
        height: 360,
        child: MutedScrollbar(
          child: ListView(
            children: [
              for (final user in widget.members)
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
          onPressed: () => Navigator.of(context).pop(_selected.toList()),
          child: const Text('확인'),
        ),
      ],
    );
  }
}

/// 날짜 고르기(시작일/마감일) — 누르면 달력이 뜨고, X로 지울 수 있다.
class _DueDateField extends StatelessWidget {
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  const _DueDateField({
    this.label = '마감일',
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Row(
      children: [
        Icon(Icons.event_outlined, size: 18, color: hint),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: hint)),
        const SizedBox(width: 12),
        TextButton(
          onPressed: () async {
            final now = DateTime.now();
            final picked = await showDatePicker(
              context: context,
              initialDate: value ?? now,
              firstDate: DateTime(now.year - 1),
              lastDate: DateTime(now.year + 5),
            );
            if (picked != null) onChanged(picked);
          },
          child: Text(value == null ? '설정 안 함' : _formatDue(value!)),
        ),
        if (value != null)
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: '$label 지우기',
            onPressed: () => onChanged(null),
          ),
      ],
    );
  }
}

/// 프로젝트의 사용자 정의 필드 입력칸들 — 새 업무에서는 바뀔 때마다([commitOnChange]),
/// 상세에서는 입력을 마쳤을 때(포커스를 잃거나 Enter) 값을 넘긴다. 지우면 null.
class _CustomFieldsEditor extends StatelessWidget {
  final List<TaskFieldDef> fields;
  final Map<String, dynamic> values;
  final bool commitOnChange;
  final void Function(String fieldId, dynamic value) onChanged;
  const _CustomFieldsEditor({
    required this.fields,
    required this.values,
    required this.commitOnChange,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('추가 정보', style: TextStyle(color: hint, fontSize: 12)),
        const SizedBox(height: 8),
        for (final f in fields)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: switch (f.kind) {
              'date' => _DueDateField(
                label: f.name,
                value: values[f.id] is num
                    ? DateTime.fromMillisecondsSinceEpoch(
                        (values[f.id] as num).toInt(),
                      )
                    : null,
                onChanged: (d) => onChanged(f.id, d?.millisecondsSinceEpoch),
              ),
              'select' => DropdownButtonFormField<String?>(
                key: ValueKey('cf-${f.id}-${values[f.id]}'),
                initialValue: f.options.contains(values[f.id])
                    ? values[f.id] as String
                    : null,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: f.name,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text('선택 안 함')),
                  for (final o in f.options)
                    DropdownMenuItem(value: o, child: Text(o)),
                ],
                onChanged: (v) => onChanged(f.id, v),
              ),
              _ => _CustomTextInput(
                key: ValueKey('cf-${f.id}'),
                field: f,
                value: values[f.id],
                commitOnChange: commitOnChange,
                onChanged: (v) => onChanged(f.id, v),
              ),
            },
          ),
      ],
    );
  }
}

class _CustomTextInput extends StatefulWidget {
  final TaskFieldDef field;
  final dynamic value;
  final bool commitOnChange;
  final ValueChanged<dynamic> onChanged;
  const _CustomTextInput({
    super.key,
    required this.field,
    required this.value,
    required this.commitOnChange,
    required this.onChanged,
  });

  @override
  State<_CustomTextInput> createState() => _CustomTextInputState();
}

class _CustomTextInputState extends State<_CustomTextInput> {
  late final _controller = TextEditingController(
    text: widget.field.display(widget.value) ?? '',
  );
  final _focus = FocusNode();
  String _committed = '';

  bool get _isNumber => widget.field.kind == 'number';

  @override
  void initState() {
    super.initState();
    _committed = _controller.text;
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final text = _controller.text.trim();
    if (text == _committed) return;
    _committed = text;
    if (text.isEmpty) {
      widget.onChanged(null);
    } else if (_isNumber) {
      final n = num.tryParse(text);
      if (n != null) widget.onChanged(n);
    } else {
      widget.onChanged(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      keyboardType: _isNumber
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      decoration: InputDecoration(
        labelText: widget.field.name,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: widget.commitOnChange ? (_) => _commit() : null,
      onSubmitted: (_) => _commit(),
    );
  }
}
