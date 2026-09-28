import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/role_badge.dart';
import 'automation_flow_editor.dart' show showAutomationFlowEditor;

/// 편집 창과 목록 요약이 쓰는 프로젝트 정보.
class _Ctx {
  final List<AppUser> members;
  final List<TaskType> types;
  final List<TaskStatusDef> statuses;

  /// 자동화 요약(IF 조건)에만 쓰여서 템플릿 화면에서는 비어 있다.
  final List<TaskPriorityDef> priorities;
  final List<TaskFieldDef> fields;
  const _Ctx(
    this.members,
    this.types,
    this.statuses, {
    this.priorities = const [],
    this.fields = const [],
  });

  String memberName(String? id) =>
      members.where((m) => m.id == id).map((m) => m.name).firstOrNull ??
      '(알 수 없음)';
  String statusName(String? id) =>
      statuses.where((s) => s.id == id).map((s) => s.name).firstOrNull ??
      '(삭제된 상태)';
  String typeName(String? id) =>
      types.where((t) => t.id == id).map((t) => t.name).firstOrNull ??
      '(삭제된 유형)';
  String priorityName(String? id) =>
      priorities.where((p) => p.id == id).map((p) => p.name).firstOrNull ??
      '(삭제된 우선순위)';

  /// 자동화 노드의 필드 이름 — 사용자 정의 필드는 `field:<id>`로 온다.
  String fieldLabel(String field) =>
      automationFieldLabels[field] ??
      (field.startsWith('field:')
          ? fields
                    .where((f) => f.id == field.substring(6))
                    .map((f) => f.name)
                    .firstOrNull ??
                '(삭제된 필드)'
          : field);

  /// IF 조건 값의 화면 이름 — 상태·우선순위·담당자·유형은 id로, 사용자 정의 필드는 글자 그대로 온다.
  String valueLabel(String field, Object? value) {
    final id = value?.toString();
    return switch (field) {
      'status' => statusName(id),
      'priority' => priorityName(id),
      'assignee' => memberName(id),
      'type' => typeName(id),
      _ => id ?? '',
    };
  }
}

/// 프로젝트의 업무 템플릿("새 업무 양식"), 또는 자동화 규칙과 규칙 실행 기록을 관리한다 —
/// 프로젝트 담당자와 팀 소유자·관리자만 쓸 수 있다(서버도 다시 확인한다). "프로젝트 설정"의
/// 필드 / 상태 > "업무 템플릿" 칸과 "자동화" 메뉴가 프로젝트 정보 로딩을 나눠 쓴다.
class ProjectTemplateAutomationEditor extends StatefulWidget {
  final Session session;
  final String projectId;

  /// true면 자동화(규칙 + 실행 기록) 탭을, false면 새 업무 양식 목록만 보여준다. 양식 목록은
  /// 설정 칸의 스크롤 안에 들어가므로 자체 스크롤 없이 내용 높이만큼만 차지한다.
  final bool automations;
  const ProjectTemplateAutomationEditor({
    super.key,
    required this.session,
    required this.projectId,
    this.automations = false,
  });

  @override
  State<ProjectTemplateAutomationEditor> createState() =>
      _ProjectTemplateAutomationEditorState();
}

class _ProjectTemplateAutomationEditorState
    extends State<ProjectTemplateAutomationEditor> {
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
      // 규칙 요약의 IF 조건이 우선순위·사용자 정의 필드 이름을 쓴다.
      final priorities = widget.automations
          ? await api.fetchTaskPriorities(widget.projectId)
          : const <TaskPriorityDef>[];
      final fields = widget.automations
          ? await api.fetchTaskFields(widget.projectId)
          : const <TaskFieldDef>[];
      if (mounted) {
        setState(
          () => _ctx = _Ctx(
            project.members,
            types,
            statuses,
            priorities: priorities,
            fields: fields,
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctx = _ctx;
    return _error != null
        ? Center(child: Text(_error!))
        : ctx == null
        ? (widget.automations
              ? const Center(child: CircularProgressIndicator())
              : const _Loading())
        : !widget.automations
        ? _TemplatesTab(
            session: widget.session,
            projectId: widget.projectId,
            ctx: ctx,
          )
        : DefaultTabController(
            length: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: '자동화 규칙'),
                    Tab(text: '실행 기록'),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: TabBarView(
                    children: [
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
          );
  }
}

/// 불러오는 중 — 양식 목록은 바깥 스크롤 안(높이 제한 없음)에 놓이므로 작게 한 줄만 차지한다.
class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 16),
    child: Center(
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.4),
      ),
    ),
  );
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

// ───────────────────────── 새 업무 양식 ─────────────────────────

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
    if (!await _confirmDelete(context, '양식 삭제', "'${t.name}' 양식을 삭제할까요?")) {
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
    if (items == null) return const _Loading();
    final hint = Theme.of(context).hintColor;
    // 설정 > 필드 / 상태의 "업무 템플릿" 칸 스크롤 안에 들어가므로 ListView 대신 줄을 그대로 늘어놓는다.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '"새 업무" 창의 "양식에서 불러오기"에서 고르면 제목·설명·우선순위·유형·담당자·마감일이 '
          '미리 채워집니다.',
          style: TextStyle(color: hint, fontSize: 12),
        ),
        const SizedBox(height: 4),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: Text(
                '만든 양식이 없습니다.',
                style: TextStyle(color: hint, fontSize: 13),
              ),
            ),
          )
        else
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
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: () => _edit(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('양식 추가'),
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
      setState(() => _error = '양식 이름을 입력하세요.');
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
      title: Text(widget.existing == null ? '양식 추가' : '양식 수정'),
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
                  labelText: '양식 이름',
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

// 이전 방식 규칙(노드 편집기 이전)의 요약 — 켜기·끄기·삭제만 되므로 목록에서 설명만 보여준다.
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

String _legacyWhen(AutomationRule r, _Ctx ctx) {
  final base = r.trigger == 'task_created'
      ? '업무가 만들어질 때'
      : r.triggerStatusId == null
      ? '상태가 바뀔 때'
      : "상태가 '${ctx.statusName(r.triggerStatusId)}'(으)로 바뀔 때";
  final cond = [
    if (r.conditionPriority != null)
      '우선순위 ${taskPriorityLabel(taskPriorityFromWire(r.conditionPriority))}',
    if (r.conditionTypeId != null) '유형 ${ctx.typeName(r.conditionTypeId)}',
  ];
  return cond.isEmpty ? base : '$base (${cond.join(', ')}인 업무)';
}

String _legacySummary(AutomationRule r, _Ctx ctx) =>
    '언제: ${_legacyWhen(r, ctx)} · '
    '동작: ${r.actions.map((a) => _describeAction(a, ctx)).join(' → ')}';

String _conditionSummary(Map<String, dynamic> c, _Ctx ctx) {
  final field = c['field'] is String ? c['field'] as String : 'status';
  final op = c['op'] is String ? c['op'] as String : 'eq';
  final text = 'IF ${ctx.fieldLabel(field)} ${automationOpLabels[op] ?? op}';
  // 비어 있음 / 비어 있지 않음은 값이 없다.
  return op == 'eq' || op == 'neq'
      ? '$text ${ctx.valueLabel(field, c['value'])}'
      : text;
}

/// 노드 규칙의 한 줄 요약 — "트리거 → IF 조건들 → 액션들". 노드 목록 순서가 아니라 트리거에서
/// 연결을 따라간 순서로 적어서, 캔버스에서 흐름을 읽는 순서와 같게 한다.
String _graphSummary(AutomationGraph g, _Ctx ctx) {
  final trigger = g.trigger;
  if (trigger == null) return '';
  final byId = {for (final n in g.nodes) n.id: n};
  final seen = {trigger.id};
  final queue = [trigger.id];
  final flow = <AutomationNode>[];
  for (var i = 0; i < queue.length; i++) {
    for (final e in g.edges) {
      final next = byId[e.to];
      if (e.from == queue[i] && next != null && seen.add(next.id)) {
        queue.add(next.id);
        flow.add(next);
      }
    }
  }
  final head = automationTriggerLabels[trigger.type] ?? trigger.type;
  // 감지할 필드가 여러 개일 수 있다 — 예전 {field} 모양도 같이 읽는다.
  final fields = automationTriggerFields(trigger.config);
  final watched = fields.contains('any')
      ? ctx.fieldLabel('any')
      : fields.map(ctx.fieldLabel).join('·');
  final actions = [
    for (final n in flow)
      if (n.kind == 'action') automationActionLabels[n.type] ?? n.type,
  ];
  return [
    trigger.type == 'field_changed' && watched.isNotEmpty
        ? '$head($watched)'
        : head,
    for (final n in flow)
      if (n.kind == 'condition') _conditionSummary(n.config, ctx),
    if (actions.isNotEmpty) actions.join(', '),
  ].join(' → ');
}

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

  /// 노드 편집기를 연다([rule]이 없으면 새 규칙). 저장했을 때만 목록을 다시 읽는다.
  Future<void> _openEditor([AutomationRule? rule]) async {
    final saved = await showAutomationFlowEditor(
      context,
      session: widget.session,
      projectId: widget.projectId,
      rule: rule,
    );
    if (saved) await _load();
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

  Widget _ruleTile(AutomationRule r, Color hint) {
    final legacy = r.isLegacy;
    // 회색 알약 — 준회원 배지와 같은 무채색 배색을 쓴다.
    final chip = roleBadgeColors(context, 'guest');
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        Icons.bolt_outlined,
        color: r.enabled ? Theme.of(context).colorScheme.primary : hint,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (legacy) ...[
            const SizedBox(width: 6),
            RoleBadge(label: '이전 방식', bg: chip.bg, fg: chip.fg),
          ],
        ],
      ),
      subtitle: Text(
        legacy
            ? _legacySummary(r, widget.ctx)
            : _graphSummary(r.graph!, widget.ctx),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: hint, fontSize: 11),
      ),
      // 이전 방식 규칙은 새 편집기로 열 수 없다(켜기·끄기·삭제만).
      onTap: legacy ? null : () => _openEditor(r),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(value: r.enabled, onChanged: (v) => _toggle(r, v)),
          if (legacy)
            const Tooltip(
              message: '새 편집기에서 다시 만들어 주세요',
              child: IconButton(
                icon: Icon(Icons.edit_outlined, size: 18),
                onPressed: null,
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              tooltip: '편집',
              onPressed: () => _openEditor(r),
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: '삭제',
            onPressed: () => _delete(r),
          ),
        ],
      ),
    );
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
        Row(
          children: [
            Expanded(
              child: Text(
                '트리거가 일어나고 조건이 맞으면 액션을 대신 실행합니다. '
                '자동화가 일으킨 변화는 다른 규칙을 다시 부르지 않습니다.',
                style: TextStyle(color: hint, fontSize: 12),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('새 자동화'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text('만든 규칙이 없습니다.', style: TextStyle(color: hint)),
                )
              : ListView(children: [for (final r in items) _ruleTile(r, hint)]),
        ),
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

  /// 이전 방식 규칙의 'status_changed'는 새 트리거 목록에 없어서 따로 적는다.
  static String _triggerLabel(String trigger) =>
      automationTriggerLabels[trigger] ??
      (trigger == 'status_changed' ? '상태 변경' : trigger);

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
                          r.summary.isEmpty
                              ? _triggerLabel(r.trigger)
                              : '${_triggerLabel(r.trigger)} → ${r.summary}',
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
