import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/floating_dialog.dart';

/// 프로젝트의 업무 템플릿과 자동화 규칙을 관리한다 — 프로젝트 담당자와 팀 소유자·관리자만
/// 열 수 있다(서버도 다시 확인한다).
///
/// 템플릿은 "새 업무"에서 불러와 제목·설명·우선순위·유형·담당자·마감(오늘+N일)을 미리 채우고,
/// 자동화는 "업무가 만들어졌을 때 / 상태가 바뀌었을 때" 조건이 맞으면 배정·상태·우선순위 변경,
/// 참조자 추가, 댓글, 알림을 대신 해준다(자동화가 일으킨 변화는 다시 자동화를 부르지 않는다).
Future<void> showTemplateAutomationManagerDialog(
  BuildContext context,
  Session session,
  String projectId,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ManagerDialog(session: session, projectId: projectId),
  );
}

/// 편집 창들이 고르기 목록으로 쓰는 프로젝트 정보.
class _Ctx {
  final List<AppUser> members;
  final List<TaskType> types;
  final List<TaskStatusDef> statuses;
  const _Ctx(this.members, this.types, this.statuses);

  String memberName(String? id) =>
      members.where((m) => m.id == id).map((m) => m.name).firstOrNull ??
      '(알 수 없음)';
  String statusName(String? id) =>
      statuses.where((s) => s.id == id).map((s) => s.name).firstOrNull ??
      '(삭제된 상태)';
  String typeName(String? id) =>
      types.where((t) => t.id == id).map((t) => t.name).firstOrNull ??
      '(삭제된 유형)';
}

class _ManagerDialog extends StatefulWidget {
  final Session session;
  final String projectId;
  const _ManagerDialog({required this.session, required this.projectId});

  @override
  State<_ManagerDialog> createState() => _ManagerDialogState();
}

class _ManagerDialogState extends State<_ManagerDialog> {
  _Ctx? _ctx;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = widget.session.api!;
      final project = await api.fetchProject(widget.projectId);
      final types = await api.fetchTaskTypes(widget.projectId);
      final statuses = await api.fetchTaskStatuses(widget.projectId);
      if (mounted) {
        setState(() => _ctx = _Ctx(project.members, types, statuses));
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctx = _ctx;
    return FloatingDialog(
      title: '템플릿 · 자동화 관리',
      maxWidth: 600,
      maxHeight: 680,
      child: _error != null
          ? Center(child: Text(_error!))
          : ctx == null
          ? const Center(child: CircularProgressIndicator())
          : DefaultTabController(
              length: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const TabBar(
                    tabs: [
                      Tab(text: '업무 템플릿'),
                      Tab(text: '자동화 규칙'),
                      Tab(text: '실행 기록'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _TemplatesTab(
                          session: widget.session,
                          projectId: widget.projectId,
                          ctx: ctx,
                        ),
                        _AutomationsTab(
                          session: widget.session,
                          projectId: widget.projectId,
                          ctx: ctx,
                        ),
                        _RunsTab(
                          session: widget.session,
                          projectId: widget.projectId,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

Future<bool> _confirmDelete(
  BuildContext context,
  String title,
  String msg,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(msg),
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
  return ok == true;
}

// ───────────────────────── 템플릿 ─────────────────────────

class _TemplatesTab extends StatefulWidget {
  final Session session;
  final String projectId;
  final _Ctx ctx;
  const _TemplatesTab({
    required this.session,
    required this.projectId,
    required this.ctx,
  });

  @override
  State<_TemplatesTab> createState() => _TemplatesTabState();
}

class _TemplatesTabState extends State<_TemplatesTab> {
  List<TaskTemplate>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.session.api!.fetchTaskTemplates(
        widget.projectId,
      );
      if (mounted) {
        setState(() {
          _items = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _edit({TaskTemplate? existing}) async {
    final result = await showDialog<_TemplateInput>(
      context: context,
      builder: (_) => _TemplateEditDialog(ctx: widget.ctx, existing: existing),
    );
    if (result == null) return;
    try {
      await widget.session.api!.saveTaskTemplate(
        widget.projectId,
        templateId: existing?.id,
        name: result.name,
        title: result.title,
        description: result.description,
        priority: result.priority,
        typeId: result.typeId,
        assigneeId: result.assigneeId,
        dueOffsetDays: result.dueOffsetDays,
      );
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '저장하지 못했습니다: $e');
    }
  }

  Future<void> _delete(TaskTemplate t) async {
    if (!await _confirmDelete(context, '템플릿 삭제', "'${t.name}' 템플릿을 삭제할까요?")) {
      return;
    }
    try {
      await widget.session.api!.deleteTaskTemplate(t.id);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '삭제하지 못했습니다: $e');
    }
  }

  String _summary(TaskTemplate t) => [
    if (t.title.isNotEmpty) '제목 "${t.title}"',
    '우선순위 ${taskPriorityLabel(t.priority)}',
    if (t.typeId != null) '유형 ${widget.ctx.typeName(t.typeId)}',
    if (t.assigneeId != null) '담당 ${widget.ctx.memberName(t.assigneeId)}',
    if (t.dueOffsetDays != null) '마감 +${t.dueOffsetDays}일',
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final items = _items;
    if (items == null) return const Center(child: CircularProgressIndicator());
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '"새 업무"에서 템플릿을 고르면 항목이 미리 채워집니다.',
          style: TextStyle(color: hint, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text('만든 템플릿이 없습니다.', style: TextStyle(color: hint)),
                )
              : ListView(
                  children: [
                    for (final t in items)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.description_outlined),
                        title: Text(t.name),
                        subtitle: Text(
                          _summary(t),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: hint, fontSize: 11),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              tooltip: '수정',
                              onPressed: () => _edit(existing: t),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18),
                              tooltip: '삭제',
                              onPressed: () => _delete(t),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: () => _edit(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('템플릿 추가'),
          ),
        ),
      ],
    );
  }
}

class _TemplateInput {
  final String name;
  final String title;
  final String description;
  final TaskPriority priority;
  final String? typeId;
  final String? assigneeId;
  final int? dueOffsetDays;
  const _TemplateInput({
    required this.name,
    required this.title,
    required this.description,
    required this.priority,
    this.typeId,
    this.assigneeId,
    this.dueOffsetDays,
  });
}

class _TemplateEditDialog extends StatefulWidget {
  final _Ctx ctx;
  final TaskTemplate? existing;
  const _TemplateEditDialog({required this.ctx, this.existing});

  @override
  State<_TemplateEditDialog> createState() => _TemplateEditDialogState();
}

class _TemplateEditDialogState extends State<_TemplateEditDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _description = TextEditingController(
    text: widget.existing?.description ?? '',
  );
  late final _due = TextEditingController(
    text: widget.existing?.dueOffsetDays?.toString() ?? '',
  );
  late TaskPriority _priority =
      widget.existing?.priority ?? TaskPriority.normal;
  late String? _typeId =
      widget.ctx.types.any((t) => t.id == widget.existing?.typeId)
      ? widget.existing?.typeId
      : null;
  late String? _assigneeId =
      widget.ctx.members.any((m) => m.id == widget.existing?.assigneeId)
      ? widget.existing?.assigneeId
      : null;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _title.dispose();
    _description.dispose();
    _due.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '템플릿 이름을 입력하세요.');
      return;
    }
    int? due;
    if (_due.text.trim().isNotEmpty) {
      due = int.tryParse(_due.text.trim());
      if (due == null || due < 0) {
        setState(() => _error = '마감일은 0 이상의 숫자(일)로 입력하세요.');
        return;
      }
    }
    Navigator.of(context).pop(
      _TemplateInput(
        name: name,
        title: _title.text.trim(),
        description: _description.text.trim(),
        priority: _priority,
        typeId: _typeId,
        assigneeId: _assigneeId,
        dueOffsetDays: due,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '템플릿 추가' : '템플릿 수정'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                maxLength: 30,
                decoration: const InputDecoration(
                  labelText: '템플릿 이름',
                  counterText: '',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: '업무 제목 (미리 채울 내용)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _description,
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: '설명 (미리 채울 내용)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<TaskPriority>(
                initialValue: _priority,
                decoration: const InputDecoration(
                  labelText: '우선순위',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final p in TaskPriority.values)
                    DropdownMenuItem(
                      value: p,
                      child: Text(taskPriorityLabel(p)),
                    ),
                ],
                onChanged: (v) => setState(() => _priority = v ?? _priority),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String?>(
                initialValue: _typeId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '유형',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text('유형 없음')),
                  for (final t in widget.ctx.types)
                    DropdownMenuItem(value: t.id, child: Text(t.name)),
                ],
                onChanged: (v) => setState(() => _typeId = v),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String?>(
                initialValue: _assigneeId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '담당자',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text('담당자 없음')),
                  for (final m in widget.ctx.members)
                    DropdownMenuItem(value: m.id, child: Text(m.name)),
                ],
                onChanged: (v) => setState(() => _assigneeId = v),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _due,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '마감일: 등록일로부터 N일 뒤 (비우면 안 채움)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _submit, child: const Text('저장')),
      ],
    );
  }
}

// ───────────────────────── 자동화 ─────────────────────────

const _actionLabels = {
  'set_assignee': '담당자 지정',
  'set_status': '상태 변경',
  'set_priority': '우선순위 변경',
  'add_reference': '참조자 추가',
  'add_comment': '댓글 남기기',
  'notify': '알림 보내기',
};

String _describeAction(AutomationAction a, _Ctx ctx) => switch (a.kind) {
  'set_assignee' => '담당자를 ${ctx.memberName(a.userId)}(으)로',
  'set_status' => '상태를 ${ctx.statusName(a.statusId)}(으)로',
  'set_priority' =>
    '우선순위를 ${taskPriorityLabel(taskPriorityFromWire(a.priority))}(으)로',
  'add_reference' => '${ctx.memberName(a.userId)}을(를) 참조자로 추가',
  'add_comment' => "댓글 '${a.text}' 남기기",
  'notify' => '${ctx.memberName(a.userId)}에게 알림',
  _ => a.kind,
};

class _AutomationsTab extends StatefulWidget {
  final Session session;
  final String projectId;
  final _Ctx ctx;
  const _AutomationsTab({
    required this.session,
    required this.projectId,
    required this.ctx,
  });

  @override
  State<_AutomationsTab> createState() => _AutomationsTabState();
}

class _AutomationsTabState extends State<_AutomationsTab> {
  List<AutomationRule>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.session.api!.fetchAutomations(widget.projectId);
      if (mounted) {
        setState(() {
          _items = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _edit({AutomationRule? existing}) async {
    final result = await showDialog<_RuleInput>(
      context: context,
      builder: (_) => _RuleEditDialog(ctx: widget.ctx, existing: existing),
    );
    if (result == null) return;
    try {
      await widget.session.api!.saveAutomation(
        widget.projectId,
        ruleId: existing?.id,
        name: result.name,
        trigger: result.trigger,
        triggerStatusId: result.triggerStatusId,
        conditionPriority: result.conditionPriority,
        conditionTypeId: result.conditionTypeId,
        actions: result.actions,
      );
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '저장하지 못했습니다: $e');
    }
  }

  Future<void> _toggle(AutomationRule r, bool v) async {
    try {
      await widget.session.api!.setAutomationEnabled(r.id, v);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '바꾸지 못했습니다: $e');
    }
  }

  Future<void> _delete(AutomationRule r) async {
    if (!await _confirmDelete(context, '규칙 삭제', "'${r.name}' 규칙을 삭제할까요?")) {
      return;
    }
    try {
      await widget.session.api!.deleteAutomation(r.id);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '삭제하지 못했습니다: $e');
    }
  }

  String _when(AutomationRule r) {
    final base = r.trigger == 'task_created'
        ? '업무가 만들어질 때'
        : r.triggerStatusId == null
        ? '상태가 바뀔 때'
        : "상태가 '${widget.ctx.statusName(r.triggerStatusId)}'(으)로 바뀔 때";
    final cond = [
      if (r.conditionPriority != null)
        '우선순위 ${taskPriorityLabel(taskPriorityFromWire(r.conditionPriority))}',
      if (r.conditionTypeId != null)
        '유형 ${widget.ctx.typeName(r.conditionTypeId)}',
    ];
    return cond.isEmpty ? base : '$base (${cond.join(', ')}인 업무)';
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final items = _items;
    if (items == null) return const Center(child: CircularProgressIndicator());
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '조건이 맞으면 동작을 대신 실행합니다. 자동화가 일으킨 변화는 다른 규칙을 다시 부르지 않습니다.',
          style: TextStyle(color: hint, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text('만든 규칙이 없습니다.', style: TextStyle(color: hint)),
                )
              : ListView(
                  children: [
                    for (final r in items)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        isThreeLine: true,
                        leading: Switch(
                          value: r.enabled,
                          onChanged: (v) => _toggle(r, v),
                        ),
                        title: Text(r.name),
                        subtitle: Text(
                          '언제: ${_when(r)}\n'
                          '동작: ${r.actions.map((a) => _describeAction(a, widget.ctx)).join(' → ')}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: hint, fontSize: 11),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              tooltip: '수정',
                              onPressed: () => _edit(existing: r),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18),
                              tooltip: '삭제',
                              onPressed: () => _delete(r),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: () => _edit(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('규칙 추가'),
          ),
        ),
      ],
    );
  }
}

class _RuleInput {
  final String name;
  final String trigger;
  final String? triggerStatusId;
  final String? conditionPriority;
  final String? conditionTypeId;
  final List<AutomationAction> actions;
  const _RuleInput({
    required this.name,
    required this.trigger,
    this.triggerStatusId,
    this.conditionPriority,
    this.conditionTypeId,
    required this.actions,
  });
}

/// 편집 중인 동작 한 줄 — 종류에 맞는 값 하나만 쓴다.
class _ActionDraft {
  String kind;
  String? userId;
  String? statusId;
  String? priority;
  final TextEditingController text;
  _ActionDraft(
    this.kind, {
    this.userId,
    this.statusId,
    this.priority,
    String? text,
  }) : text = TextEditingController(text: text ?? '');
}

class _RuleEditDialog extends StatefulWidget {
  final _Ctx ctx;
  final AutomationRule? existing;
  const _RuleEditDialog({required this.ctx, this.existing});

  @override
  State<_RuleEditDialog> createState() => _RuleEditDialogState();
}

class _RuleEditDialogState extends State<_RuleEditDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late String _trigger = widget.existing?.trigger ?? 'task_created';
  late String? _triggerStatusId =
      widget.ctx.statuses.any((s) => s.id == widget.existing?.triggerStatusId)
      ? widget.existing?.triggerStatusId
      : null;
  late String? _condPriority = widget.existing?.conditionPriority;
  late String? _condTypeId =
      widget.ctx.types.any((t) => t.id == widget.existing?.conditionTypeId)
      ? widget.existing?.conditionTypeId
      : null;
  late final List<_ActionDraft> _actions = [
    for (final a in widget.existing?.actions ?? const <AutomationAction>[])
      _ActionDraft(
        a.kind,
        userId: a.userId,
        statusId: a.statusId,
        priority: a.priority,
        text: a.text,
      ),
  ];
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_actions.isEmpty) _actions.add(_ActionDraft('set_assignee'));
  }

  @override
  void dispose() {
    _name.dispose();
    for (final a in _actions) {
      a.text.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '규칙 이름을 입력하세요.');
      return;
    }
    final actions = <AutomationAction>[];
    for (final d in _actions) {
      switch (d.kind) {
        case 'set_assignee' || 'add_reference' || 'notify':
          if (d.userId == null) {
            setState(() => _error = '동작마다 사용자를 골라주세요.');
            return;
          }
          actions.add(AutomationAction(d.kind, userId: d.userId));
        case 'set_status':
          if (d.statusId == null) {
            setState(() => _error = '바꿀 상태를 골라주세요.');
            return;
          }
          actions.add(AutomationAction(d.kind, statusId: d.statusId));
        case 'set_priority':
          actions.add(
            AutomationAction(d.kind, priority: d.priority ?? 'normal'),
          );
        case 'add_comment':
          final text = d.text.text.trim();
          if (text.isEmpty) {
            setState(() => _error = '댓글 내용을 입력하세요.');
            return;
          }
          actions.add(AutomationAction(d.kind, text: text));
      }
    }
    Navigator.of(context).pop(
      _RuleInput(
        name: name,
        trigger: _trigger,
        triggerStatusId: _trigger == 'status_changed' ? _triggerStatusId : null,
        conditionPriority: _condPriority,
        conditionTypeId: _condTypeId,
        actions: actions,
      ),
    );
  }

  Widget _userDropdown(_ActionDraft d) => DropdownButtonFormField<String>(
    key: ValueKey('u-${d.hashCode}-${d.userId}'),
    initialValue: widget.ctx.members.any((m) => m.id == d.userId)
        ? d.userId
        : null,
    isExpanded: true,
    decoration: const InputDecoration(
      labelText: '사용자',
      border: OutlineInputBorder(),
      isDense: true,
    ),
    items: [
      for (final m in widget.ctx.members)
        DropdownMenuItem(value: m.id, child: Text(m.name)),
    ],
    onChanged: (v) => setState(() => d.userId = v),
  );

  Widget _paramField(_ActionDraft d) {
    switch (d.kind) {
      case 'set_status':
        return DropdownButtonFormField<String>(
          key: ValueKey('s-${d.hashCode}-${d.statusId}'),
          initialValue: widget.ctx.statuses.any((s) => s.id == d.statusId)
              ? d.statusId
              : null,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '상태',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            for (final s in widget.ctx.statuses)
              DropdownMenuItem(value: s.id, child: Text(s.name)),
          ],
          onChanged: (v) => setState(() => d.statusId = v),
        );
      case 'set_priority':
        return DropdownButtonFormField<String>(
          key: ValueKey('p-${d.hashCode}-${d.priority}'),
          initialValue: d.priority ?? 'normal',
          decoration: const InputDecoration(
            labelText: '우선순위',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            for (final p in TaskPriority.values)
              DropdownMenuItem(
                value: taskPriorityToWire(p),
                child: Text(taskPriorityLabel(p)),
              ),
          ],
          onChanged: (v) => setState(() => d.priority = v),
        );
      case 'add_comment':
        return TextField(
          controller: d.text,
          maxLength: 500,
          decoration: const InputDecoration(
            labelText: '댓글 내용',
            counterText: '',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        );
      default:
        return _userDropdown(d);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctx = widget.ctx;
    final hint = Theme.of(context).hintColor;
    return AlertDialog(
      title: Text(widget.existing == null ? '규칙 추가' : '규칙 수정'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                maxLength: 40,
                decoration: const InputDecoration(
                  labelText: '규칙 이름',
                  counterText: '',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Text('언제', style: TextStyle(color: hint)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('업무가 만들어졌을 때'),
                    selected: _trigger == 'task_created',
                    onSelected: (_) =>
                        setState(() => _trigger = 'task_created'),
                  ),
                  ChoiceChip(
                    label: const Text('상태가 바뀌었을 때'),
                    selected: _trigger == 'status_changed',
                    onSelected: (_) =>
                        setState(() => _trigger = 'status_changed'),
                  ),
                ],
              ),
              if (_trigger == 'status_changed') ...[
                const SizedBox(height: 10),
                DropdownButtonFormField<String?>(
                  key: ValueKey('ts-$_triggerStatusId'),
                  initialValue: _triggerStatusId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '어떤 상태로 바뀔 때',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('어떤 상태로든')),
                    for (final s in ctx.statuses)
                      DropdownMenuItem(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (v) => setState(() => _triggerStatusId = v),
                ),
              ],
              const SizedBox(height: 14),
              Text('조건 (선택)', style: TextStyle(color: hint)),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      key: ValueKey('cp-$_condPriority'),
                      initialValue: _condPriority,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '우선순위',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('모두')),
                        for (final p in TaskPriority.values)
                          DropdownMenuItem(
                            value: taskPriorityToWire(p),
                            child: Text(taskPriorityLabel(p)),
                          ),
                      ],
                      onChanged: (v) => setState(() => _condPriority = v),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      key: ValueKey('ct-$_condTypeId'),
                      initialValue: _condTypeId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '유형',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('모두')),
                        for (final t in ctx.types)
                          DropdownMenuItem(value: t.id, child: Text(t.name)),
                      ],
                      onChanged: (v) => setState(() => _condTypeId = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text('동작 (위에서부터 차례로)', style: TextStyle(color: hint)),
              const SizedBox(height: 6),
              for (var i = 0; i < _actions.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 150,
                        child: DropdownButtonFormField<String>(
                          key: ValueKey('k-${_actions[i].hashCode}'),
                          initialValue: _actions[i].kind,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            for (final e in _actionLabels.entries)
                              DropdownMenuItem(
                                value: e.key,
                                child: Text(
                                  e.value,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) => setState(
                            () => _actions[i].kind = v ?? _actions[i].kind,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: _paramField(_actions[i])),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: '동작 삭제',
                        onPressed: _actions.length <= 1
                            ? null
                            : () => setState(
                                () => _actions.removeAt(i).text.dispose(),
                              ),
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _actions.length >= 5
                      ? null
                      : () => setState(
                          () => _actions.add(_ActionDraft('notify')),
                        ),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('동작 추가'),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 4),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _submit, child: const Text('저장')),
      ],
    );
  }
}

// ───────────────────────── 실행 기록 ─────────────────────────

class _RunsTab extends StatefulWidget {
  final Session session;
  final String projectId;
  const _RunsTab({required this.session, required this.projectId});

  @override
  State<_RunsTab> createState() => _RunsTabState();
}

class _RunsTabState extends State<_RunsTab> {
  List<AutomationRunLog>? _runs;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.session.api!.fetchAutomationRuns(
        widget.projectId,
      );
      if (mounted) {
        setState(() {
          _runs = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  static String _when(DateTime t) {
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.month}/${l.day} ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final runs = _runs;
    if (runs == null) return const Center(child: CircularProgressIndicator());
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '규칙이 실행된 최근 기록입니다(최대 100개).',
                style: TextStyle(color: hint, fontSize: 12),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              tooltip: '새로고침',
              onPressed: _load,
            ),
          ],
        ),
        Expanded(
          child: runs.isEmpty
              ? Center(
                  child: Text(
                    '아직 실행된 규칙이 없습니다.',
                    style: TextStyle(color: hint),
                  ),
                )
              : ListView(
                  children: [
                    for (final r in runs)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          r.ok
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          size: 20,
                          color: r.ok ? Colors.green : Colors.redAccent,
                        ),
                        title: Text(
                          '${r.automationName}${r.taskKey == null ? '' : ' · ${r.taskKey}'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${r.trigger == 'task_created' ? '업무 생성' : '상태 변경'} → ${r.summary}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: hint, fontSize: 11),
                        ),
                        trailing: Text(
                          _when(r.createdAt),
                          style: TextStyle(color: hint, fontSize: 11),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
