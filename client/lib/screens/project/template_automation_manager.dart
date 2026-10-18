import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/role_badge.dart';
import 'automation_flow_editor.dart' show showAutomationFlowEditor;
import '../../l10n/tr.dart';

/// 편집 창과 목록 요약이 쓰는 프로젝트 정보.
class _Ctx {
  final List<AppUser> members;
  final List<TaskType> types;
  final List<TaskStatusDef> statuses;

  /// 자동화 요약(IF 조건)이 쓴다.
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
      tr('(알 수 없음)');
  String statusName(String? id) =>
      statuses.where((s) => s.id == id).map((s) => s.name).firstOrNull ??
      tr('(삭제된 상태)');
  String typeName(String? id) =>
      types.where((t) => t.id == id).map((t) => t.name).firstOrNull ??
      tr('(삭제된 유형)');
  String priorityName(String? id) =>
      priorities.where((p) => p.id == id).map((p) => p.name).firstOrNull ??
      tr('(삭제된 우선순위)');

  /// 자동화 노드의 필드 이름 — 사용자 정의 필드는 `field:<id>`로 온다.
  String fieldLabel(String field) =>
      automationFieldLabels[field] ??
      (field.startsWith('field:')
          ? fields
                    .where((f) => f.id == field.substring(6))
                    .map((f) => f.name)
                    .firstOrNull ??
                tr('(삭제된 필드)')
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

/// 프로젝트의 자동화 규칙과 규칙 실행 기록을 관리한다("프로젝트 설정 > 자동화") — 프로젝트
/// 담당자와 팀 소유자·관리자만 쓸 수 있다(서버도 다시 확인한다).
class ProjectAutomationEditor extends StatefulWidget {
  final Session session;
  final String projectId;
  const ProjectAutomationEditor({
    super.key,
    required this.session,
    required this.projectId,
  });

  @override
  State<ProjectAutomationEditor> createState() =>
      _ProjectAutomationEditorState();
}

class _ProjectAutomationEditorState extends State<ProjectAutomationEditor> {
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
      final priorities = await api.fetchTaskPriorities(widget.projectId);
      final fields = await api.fetchTaskFields(widget.projectId);
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
        ? const Center(child: CircularProgressIndicator())
        : DefaultTabController(
            length: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TabBar(
                  tabs: [
                    Tab(text: tr('자동화 규칙')),
                    Tab(text: tr('실행 기록')),
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
          child: Text(tr('취소')),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.of(c).pop(true),
          child: Text(tr('삭제')),
        ),
      ],
    ),
  );
  return ok == true;
}

// ───────────────────────── 자동화 ─────────────────────────

// 이전 방식 규칙(노드 편집기 이전)의 요약 — 켜기·끄기·삭제만 되므로 목록에서 설명만 보여준다.
String _describeAction(AutomationAction a, _Ctx ctx) => switch (a.kind) {
  'set_assignee' => tr('담당자를 {p0}(으)로', {'p0': ctx.memberName(a.userId)}),
  'set_status' => tr('상태를 {p0}(으)로', {'p0': ctx.statusName(a.statusId)}),
  'set_priority' => tr('우선순위를 {p0}(으)로', {
    'p0': taskPriorityLabel(taskPriorityFromWire(a.priority)),
  }),
  'add_reference' => tr('{p0}을(를) 참조자로 추가', {'p0': ctx.memberName(a.userId)}),
  'add_comment' => tr('댓글 \'{a.text}\' 남기기', {'a.text': a.text}),
  'notify' => tr('{p0}에게 알림', {'p0': ctx.memberName(a.userId)}),
  _ => a.kind,
};

String _legacyWhen(AutomationRule r, _Ctx ctx) {
  final base = r.trigger == 'task_created'
      ? tr('업무가 만들어질 때')
      : r.triggerStatusId == null
      ? tr('상태가 바뀔 때')
      : tr('상태가 \'{p0}\'(으)로 바뀔 때', {'p0': ctx.statusName(r.triggerStatusId)});
  final cond = [
    if (r.conditionPriority != null)
      tr('우선순위 {p0}', {
        'p0': taskPriorityLabel(taskPriorityFromWire(r.conditionPriority)),
      }),
    if (r.conditionTypeId != null)
      tr('유형 {p0}', {'p0': ctx.typeName(r.conditionTypeId)}),
  ];
  return cond.isEmpty
      ? base
      : tr('{base} ({p0}인 업무)', {'base': base, 'p0': cond.join(', ')});
}

String _legacySummary(AutomationRule r, _Ctx ctx) => tr('언제: {p0} · 동작: {p1}', {
  'p0': _legacyWhen(r, ctx),
  'p1': r.actions.map((a) => _describeAction(a, ctx)).join(' → '),
});

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
      if (mounted) showAppToast(context, tr('바꾸지 못했습니다: {e}', {'e': e}));
    }
  }

  Future<void> _delete(AutomationRule r) async {
    if (!await _confirmDelete(
      context,
      tr('규칙 삭제'),
      tr('\'{r.name}\' 규칙을 삭제할까요?', {'r.name': r.name}),
    )) {
      return;
    }
    try {
      await widget.session.api!.deleteAutomation(r.id);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, tr('삭제하지 못했습니다: {e}', {'e': e}));
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
            RoleBadge(label: tr('이전 방식'), bg: chip.bg, fg: chip.fg),
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
            Tooltip(
              message: tr('새 편집기에서 다시 만들어 주세요'),
              child: IconButton(
                icon: Icon(Icons.edit_outlined, size: 18),
                onPressed: null,
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              tooltip: tr('편집'),
              onPressed: () => _openEditor(r),
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: tr('삭제'),
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
                tr(
                  '트리거가 일어나고 조건이 맞으면 액션을 대신 실행합니다. 자동화가 일으킨 변화는 다른 규칙을 다시 부르지 않습니다.',
                ),
                style: TextStyle(color: hint, fontSize: 12),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add, size: 18),
              label: Text(tr('새 자동화')),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text(
                    tr('만든 규칙이 없습니다.'),
                    style: TextStyle(color: hint),
                  ),
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
      (trigger == 'status_changed' ? tr('상태 변경') : trigger);

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
                tr('규칙이 실행된 최근 기록입니다(최대 100개).'),
                style: TextStyle(color: hint, fontSize: 12),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              tooltip: tr('새로고침'),
              onPressed: _load,
            ),
          ],
        ),
        Expanded(
          child: runs.isEmpty
              ? Center(
                  child: Text(
                    tr('아직 실행된 규칙이 없습니다.'),
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
