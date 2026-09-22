import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'project_forms.dart' show projectColorChoices;

String _categoryLabel(TaskStatus c) => taskStatusLabel(c);

Future<bool> _confirm(
  BuildContext context,
  String title,
  String message,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message),
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

// ───────────────────────── 공통(구획 · 말풍선) ─────────────────────────

/// "기본 필드" 안의 한 구획(상태 / 유형 / 우선순위). 왼쪽 위에 제목, 그 줄 오른쪽 끝에 작은
/// "추가" 버튼을 두고, 아래에 항목들을 말풍선으로 쌓는다.
///
/// 스스로 스크롤하지 않는다 — 세 구획이 "기본 필드" 카드 하나의 스크롤을 같이 쓴다(구획마다
/// 스크롤바가 따로 생기면 어디를 굴려야 할지 알 수 없다).
class ConfigSection extends StatelessWidget {
  final String title;
  final String description;
  final String addLabel;
  final VoidCallback onAdd;
  final List<Widget> children;

  /// 항목이 하나도 없을 때 대신 보여줄 문구.
  final String emptyHint;

  const ConfigSection({
    super.key,
    required this.title,
    required this.description,
    required this.addLabel,
    required this.onAdd,
    required this.children,
    required this.emptyHint,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 14),
              label: Text(addLabel),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        Text(
          description,
          style: TextStyle(color: theme.hintColor, fontSize: 12),
        ),
        const SizedBox(height: 8),
        if (children.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text(
                emptyHint,
                style: TextStyle(color: theme.hintColor, fontSize: 12),
              ),
            ),
          )
        else
          ...children,
      ],
    );
  }
}

/// 구획 안의 항목 한 줄 — 연한 바탕에 둥근 모서리의 말풍선.
class ConfigBubble extends StatelessWidget {
  final Color dotColor;
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  const ConfigBubble({
    super.key,
    required this.dotColor,
    required this.title,
    this.subtitle,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.6,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: TextStyle(color: theme.hintColor, fontSize: 11),
                    ),
                ],
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// 말풍선 오른쪽에 붙는 작은 아이콘 버튼(위로/아래로/수정/삭제).
Widget configAction(IconData icon, String tooltip, VoidCallback? onPressed) =>
    IconButton(
      icon: Icon(icon, size: 16),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
      onPressed: onPressed,
    );

// ───────────────────────── 상태 ─────────────────────────

/// 프로젝트의 업무 상태(칸반 열)를 추가·수정·삭제·정렬한다. 상태는 이름/색/순서를 자유롭게
/// 바꾸되 반드시 "할 일/진행 중/완료" 중 한 분류에 속하고(진행률·완료 집계용), 분류마다
/// 하나는 남아야 한다. "프로젝트 메뉴"의 "필드 / 상태"에서 쓴다.
class ProjectStatusEditor extends StatefulWidget {
  final Session session;
  final String projectId;
  const ProjectStatusEditor({
    super.key,
    required this.session,
    required this.projectId,
  });

  @override
  State<ProjectStatusEditor> createState() => _ProjectStatusEditorState();
}

class _ProjectStatusEditorState extends State<ProjectStatusEditor> {
  List<TaskStatusDef>? _statuses;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.session.api!.fetchTaskStatuses(
        widget.projectId,
      );
      if (mounted) {
        setState(() {
          _statuses = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _edit({TaskStatusDef? existing}) async {
    final result = await showDialog<_StatusEditResult>(
      context: context,
      builder: (_) => _StatusEditDialog(existing: existing),
    );
    if (result == null) return;
    try {
      final api = widget.session.api!;
      if (existing == null) {
        await api.createTaskStatus(
          widget.projectId,
          name: result.name,
          color: result.color,
          category: result.category,
        );
      } else {
        await api.updateTaskStatus(
          existing.id,
          name: result.name,
          color: result.color,
        );
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '저장하지 못했습니다: $e');
    }
  }

  Future<void> _delete(TaskStatusDef s) async {
    final ok = await _confirm(
      context,
      '상태 삭제',
      "'${s.name}' 상태를 삭제할까요? 이 상태의 업무는 같은 분류(${_categoryLabel(s.category)})의 첫 상태로 옮겨집니다.",
    );
    if (!ok) return;
    try {
      await widget.session.api!.deleteTaskStatus(s.id);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '삭제하지 못했습니다: $e');
    }
  }

  Future<void> _move(int index, int delta) async {
    final list = [..._statuses!];
    final to = index + delta;
    if (to < 0 || to >= list.length) return;
    final item = list.removeAt(index);
    list.insert(to, item);
    setState(() => _statuses = list);
    try {
      await widget.session.api!.reorderTaskStatuses(widget.projectId, [
        for (final s in list) s.id,
      ]);
    } catch (e) {
      if (mounted) showAppToast(context, '순서를 바꾸지 못했습니다: $e');
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final statuses = _statuses;
    if (_error != null) return Center(child: Text(_error!));
    if (statuses == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ConfigSection(
      title: '상태',
      description: '칸반보드의 열이 되는 상태입니다. 위에서부터 왼쪽 열 순서입니다.',
      addLabel: '추가',
      onAdd: _edit,
      emptyHint: '등록된 상태가 없습니다.',
      children: [
        for (var i = 0; i < statuses.length; i++)
          ConfigBubble(
            dotColor: parseTypeColor(statuses[i].color),
            title: statuses[i].name,
            subtitle: _categoryLabel(statuses[i].category),
            actions: [
              configAction(
                Icons.arrow_upward,
                '위로',
                i == 0 ? null : () => _move(i, -1),
              ),
              configAction(
                Icons.arrow_downward,
                '아래로',
                i == statuses.length - 1 ? null : () => _move(i, 1),
              ),
              configAction(
                Icons.edit_outlined,
                '수정',
                () => _edit(existing: statuses[i]),
              ),
              configAction(
                Icons.delete_outline,
                '삭제',
                () => _delete(statuses[i]),
              ),
            ],
          ),
      ],
    );
  }
}

class _StatusEditResult {
  final String name;
  final String color;
  final TaskStatus category;
  const _StatusEditResult(this.name, this.color, this.category);
}

class _StatusEditDialog extends StatefulWidget {
  final TaskStatusDef? existing;
  const _StatusEditDialog({this.existing});

  @override
  State<_StatusEditDialog> createState() => _StatusEditDialogState();
}

class _StatusEditDialogState extends State<_StatusEditDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late String _color =
      widget.existing?.color.toUpperCase() ?? projectColorChoices.first;
  late TaskStatus _category = widget.existing?.category ?? TaskStatus.doing;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(_StatusEditResult(name, _color, _category));
  }

  @override
  Widget build(BuildContext context) {
    final creating = widget.existing == null;
    return AlertDialog(
      title: Text(creating ? '상태 추가' : '상태 수정'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              maxLength: 20,
              decoration: const InputDecoration(
                labelText: '상태 이름',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            const Text('색'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final hex in projectColorChoices)
                  InkWell(
                    onTap: () => setState(() => _color = hex),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: parseTypeColor(hex),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _color == hex
                              ? Theme.of(context).colorScheme.onSurface
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              creating ? '분류 (진행률·완료 집계에 쓰입니다)' : '분류 (바꿀 수 없습니다)',
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final c in TaskStatus.values)
                  ChoiceChip(
                    label: Text(_categoryLabel(c)),
                    selected: _category == c,
                    onSelected: creating
                        ? (_) => setState(() => _category = c)
                        : null,
                  ),
              ],
            ),
          ],
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

// ───────────────────────── 필드 ─────────────────────────

const _kindLabels = {
  'text': '텍스트',
  'number': '숫자',
  'date': '날짜',
  'select': '단일 선택',
  'multiSelect': '다중 선택',
  'progress': '진행률',
};

/// 프로젝트의 사용자 정의 필드(텍스트/숫자/날짜/선택)를 추가·수정·삭제한다.
class ProjectFieldEditor extends StatefulWidget {
  final Session session;
  final String projectId;
  const ProjectFieldEditor({
    super.key,
    required this.session,
    required this.projectId,
  });

  @override
  State<ProjectFieldEditor> createState() => _ProjectFieldEditorState();
}

class _ProjectFieldEditorState extends State<ProjectFieldEditor> {
  List<TaskFieldDef>? _fields;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.session.api!.fetchTaskFields(widget.projectId);
      if (mounted) {
        setState(() {
          _fields = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _edit({TaskFieldDef? existing}) async {
    final result = await showDialog<_FieldEditResult>(
      context: context,
      builder: (_) => _FieldEditDialog(existing: existing),
    );
    if (result == null) return;
    try {
      final api = widget.session.api!;
      if (existing == null) {
        await api.createTaskField(
          widget.projectId,
          name: result.name,
          kind: result.kind,
          options: result.options,
        );
      } else {
        await api.updateTaskField(
          existing.id,
          name: result.name,
          options: existing.hasOptions ? result.options : null,
        );
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '저장하지 못했습니다: $e');
    }
  }

  Future<void> _delete(TaskFieldDef f) async {
    final ok = await _confirm(
      context,
      '필드 삭제',
      "'${f.name}' 필드를 삭제할까요? 업무에 입력해 둔 이 필드의 값은 더 이상 보이지 않습니다.",
    );
    if (!ok) return;
    try {
      await widget.session.api!.deleteTaskField(f.id);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '삭제하지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final fields = _fields;
    if (_error != null) return Center(child: Text(_error!));
    if (fields == null) return const Center(child: CircularProgressIndicator());
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '업무 등록·상세에 "추가 정보"로 나타나는 입력 항목입니다. (최대 20개)',
          style: TextStyle(color: hint, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: fields.isEmpty
              ? Center(
                  child: Text('만든 필드가 없습니다.', style: TextStyle(color: hint)),
                )
              : ListView(
                  children: [
                    for (final f in fields)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(f.name),
                        subtitle: Text(
                          f.hasOptions
                              ? '${_kindLabels[f.kind]} · ${f.options.join(', ')}'
                              : _kindLabels[f.kind] ?? f.kind,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: hint, fontSize: 11),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              tooltip: '수정',
                              onPressed: () => _edit(existing: f),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18),
                              tooltip: '삭제',
                              onPressed: () => _delete(f),
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
            label: const Text('필드 추가'),
          ),
        ),
      ],
    );
  }
}

class _FieldEditResult {
  final String name;
  final String kind;
  final List<String> options;
  const _FieldEditResult(this.name, this.kind, this.options);
}

class _FieldEditDialog extends StatefulWidget {
  final TaskFieldDef? existing;
  const _FieldEditDialog({this.existing});

  @override
  State<_FieldEditDialog> createState() => _FieldEditDialogState();
}

class _FieldEditDialogState extends State<_FieldEditDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _options = TextEditingController(
    text: widget.existing?.options.join(', ') ?? '',
  );
  late String _kind = widget.existing?.kind ?? 'text';
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _options.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '필드 이름을 입력하세요.');
      return;
    }
    final options = _kind == 'select' || _kind == 'multiSelect'
        ? _options.text
              .split(RegExp(r'[,\n]'))
              .map((o) => o.trim())
              .where((o) => o.isNotEmpty)
              .toSet()
              .toList()
        : <String>[];
    if ((_kind == 'select' || _kind == 'multiSelect') && options.isEmpty) {
      setState(() => _error = '선택지를 하나 이상 입력하세요(쉼표로 구분).');
      return;
    }
    Navigator.of(context).pop(_FieldEditResult(name, _kind, options));
  }

  @override
  Widget build(BuildContext context) {
    final creating = widget.existing == null;
    return AlertDialog(
      title: Text(creating ? '필드 추가' : '필드 수정'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              maxLength: 20,
              decoration: const InputDecoration(
                labelText: '필드 이름',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              creating ? '종류' : '종류 (바꿀 수 없습니다)',
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final e in _kindLabels.entries)
                  ChoiceChip(
                    label: Text(e.value),
                    selected: _kind == e.key,
                    onSelected: creating
                        ? (_) => setState(() => _kind = e.key)
                        : null,
                  ),
              ],
            ),
            if (_kind == 'select' || _kind == 'multiSelect') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _options,
                decoration: const InputDecoration(
                  labelText: '선택지 (쉼표로 구분)',
                  hintText: '예: 상, 중, 하',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ],
          ],
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

// ───────────────────────── 우선순위 ─────────────────────────

/// 프로젝트의 업무 우선순위를 추가·수정·삭제·정렬한다. 이름/색/순서는 자유롭게 바꾸되 반드시
/// "낮음/보통/높음" 중 한 단계에 속하고(정렬·통계용), 단계마다 하나는 남아야 한다.
/// "프로젝트 메뉴"의 "필드 / 상태"에서 쓴다.
class ProjectPriorityEditor extends StatefulWidget {
  final Session session;
  final String projectId;
  const ProjectPriorityEditor({
    super.key,
    required this.session,
    required this.projectId,
  });

  @override
  State<ProjectPriorityEditor> createState() => _ProjectPriorityEditorState();
}

class _ProjectPriorityEditorState extends State<ProjectPriorityEditor> {
  List<TaskPriorityDef>? _priorities;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.session.api!.fetchTaskPriorities(
        widget.projectId,
      );
      if (mounted) {
        setState(() {
          _priorities = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _edit({TaskPriorityDef? existing}) async {
    final result = await showDialog<_PriorityEditResult>(
      context: context,
      builder: (_) => _PriorityEditDialog(existing: existing),
    );
    if (result == null) return;
    try {
      final api = widget.session.api!;
      if (existing == null) {
        await api.createTaskPriority(
          widget.projectId,
          name: result.name,
          color: result.color,
          level: result.level,
        );
      } else {
        await api.updateTaskPriority(
          existing.id,
          name: result.name,
          color: result.color,
        );
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '저장하지 못했습니다: $e');
    }
  }

  Future<void> _delete(TaskPriorityDef s) async {
    final ok = await _confirm(
      context,
      '우선순위 삭제',
      "'${s.name}' 우선순위를 삭제할까요? 이 우선순위의 업무는 같은 단계(${taskPriorityLabel(s.level)})의 첫 우선순위로 옮겨집니다.",
    );
    if (!ok) return;
    try {
      await widget.session.api!.deleteTaskPriority(s.id);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '삭제하지 못했습니다: $e');
    }
  }

  Future<void> _move(int index, int delta) async {
    final list = [..._priorities!];
    final to = index + delta;
    if (to < 0 || to >= list.length) return;
    final item = list.removeAt(index);
    list.insert(to, item);
    setState(() => _priorities = list);
    try {
      await widget.session.api!.reorderTaskPriorities(widget.projectId, [
        for (final s in list) s.id,
      ]);
    } catch (e) {
      if (mounted) showAppToast(context, '순서를 바꾸지 못했습니다: $e');
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final priorities = _priorities;
    if (_error != null) return Center(child: Text(_error!));
    if (priorities == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ConfigSection(
      title: '우선순위',
      description: '업무에 붙는 우선순위입니다. 위에서부터 보여주는 순서입니다.',
      addLabel: '추가',
      onAdd: _edit,
      emptyHint: '등록된 우선순위가 없습니다.',
      children: [
        for (var i = 0; i < priorities.length; i++)
          ConfigBubble(
            dotColor: parseTypeColor(priorities[i].color),
            title: priorities[i].name,
            subtitle: taskPriorityLabel(priorities[i].level),
            actions: [
              configAction(
                Icons.arrow_upward,
                '위로',
                i == 0 ? null : () => _move(i, -1),
              ),
              configAction(
                Icons.arrow_downward,
                '아래로',
                i == priorities.length - 1 ? null : () => _move(i, 1),
              ),
              configAction(
                Icons.edit_outlined,
                '수정',
                () => _edit(existing: priorities[i]),
              ),
              configAction(
                Icons.delete_outline,
                '삭제',
                () => _delete(priorities[i]),
              ),
            ],
          ),
      ],
    );
  }
}

class _PriorityEditResult {
  final String name;
  final String color;
  final TaskPriority level;
  const _PriorityEditResult(this.name, this.color, this.level);
}

class _PriorityEditDialog extends StatefulWidget {
  final TaskPriorityDef? existing;
  const _PriorityEditDialog({this.existing});

  @override
  State<_PriorityEditDialog> createState() => _PriorityEditDialogState();
}

class _PriorityEditDialogState extends State<_PriorityEditDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late String _color =
      widget.existing?.color.toUpperCase() ?? projectColorChoices.first;
  late TaskPriority _level = widget.existing?.level ?? TaskPriority.normal;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(_PriorityEditResult(name, _color, _level));
  }

  @override
  Widget build(BuildContext context) {
    final creating = widget.existing == null;
    return AlertDialog(
      title: Text(creating ? '우선순위 추가' : '우선순위 수정'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              maxLength: 20,
              decoration: const InputDecoration(
                labelText: '우선순위 이름',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            const Text('색'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final hex in projectColorChoices)
                  InkWell(
                    onTap: () => setState(() => _color = hex),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: parseTypeColor(hex),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _color == hex
                              ? Theme.of(context).colorScheme.onSurface
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              creating ? '단계 (정렬·통계에 쓰입니다)' : '단계 (바꿀 수 없습니다)',
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final c in TaskPriority.values)
                  ChoiceChip(
                    label: Text(taskPriorityLabel(c)),
                    selected: _level == c,
                    onSelected: creating
                        ? (_) => setState(() => _level = c)
                        : null,
                  ),
              ],
            ),
          ],
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
