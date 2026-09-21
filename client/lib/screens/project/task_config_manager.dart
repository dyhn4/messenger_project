import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/floating_dialog.dart';
import 'project_forms.dart' show projectColorChoices;

/// 프로젝트의 업무 상태(칸반 열)와 사용자 정의 필드를 관리한다 — 프로젝트 담당자와 팀
/// 소유자·관리자만 열 수 있다(서버도 다시 확인한다). 상태는 이름/색/순서를 자유롭게 바꾸되
/// 반드시 "할 일/진행 중/완료" 중 한 분류에 속하고(진행률·완료 집계용), 분류마다 하나는 남아야 한다.
Future<void> showTaskConfigManagerDialog(
  BuildContext context,
  Session session,
  String projectId,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _TaskConfigManager(session: session, projectId: projectId),
  );
}

class _TaskConfigManager extends StatelessWidget {
  final Session session;
  final String projectId;
  const _TaskConfigManager({required this.session, required this.projectId});

  @override
  Widget build(BuildContext context) {
    return FloatingDialog(
      title: '상태 · 필드 관리',
      maxWidth: 520,
      maxHeight: 620,
      child: DefaultTabController(
        length: 2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const TabBar(
              tabs: [
                Tab(text: '상태'),
                Tab(text: '사용자 정의 필드'),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: TabBarView(
                children: [
                  _StatusTab(session: session, projectId: projectId),
                  _FieldTab(session: session, projectId: projectId),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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

// ───────────────────────── 상태 ─────────────────────────

class _StatusTab extends StatefulWidget {
  final Session session;
  final String projectId;
  const _StatusTab({required this.session, required this.projectId});

  @override
  State<_StatusTab> createState() => _StatusTabState();
}

class _StatusTabState extends State<_StatusTab> {
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
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '칸반보드의 열이 되는 상태입니다. 위에서부터 왼쪽 열 순서입니다.',
          style: TextStyle(color: hint, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: ListView(
            children: [
              for (var i = 0; i < statuses.length; i++)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: parseTypeColor(statuses[i].color),
                      shape: BoxShape.circle,
                    ),
                  ),
                  title: Text(statuses[i].name),
                  subtitle: Text(
                    _categoryLabel(statuses[i].category),
                    style: TextStyle(color: hint, fontSize: 11),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_upward, size: 18),
                        tooltip: '위로',
                        onPressed: i == 0 ? null : () => _move(i, -1),
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_downward, size: 18),
                        tooltip: '아래로',
                        onPressed: i == statuses.length - 1
                            ? null
                            : () => _move(i, 1),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        tooltip: '수정',
                        onPressed: () => _edit(existing: statuses[i]),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        tooltip: '삭제',
                        onPressed: () => _delete(statuses[i]),
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
            label: const Text('상태 추가'),
          ),
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
  'select': '선택',
};

class _FieldTab extends StatefulWidget {
  final Session session;
  final String projectId;
  const _FieldTab({required this.session, required this.projectId});

  @override
  State<_FieldTab> createState() => _FieldTabState();
}

class _FieldTabState extends State<_FieldTab> {
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
          options: existing.kind == 'select' ? result.options : null,
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
                          f.kind == 'select'
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
    final options = _kind == 'select'
        ? _options.text
              .split(RegExp(r'[,\n]'))
              .map((o) => o.trim())
              .where((o) => o.isNotEmpty)
              .toSet()
              .toList()
        : <String>[];
    if (_kind == 'select' && options.isEmpty) {
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
            if (_kind == 'select') ...[
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
