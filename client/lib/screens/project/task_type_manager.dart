import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'task_config_manager.dart'
    show ConfigBubble, ConfigSection, ReorderableBubbleList, configAction;

const _typePalette = <String>[
  '#E53935',
  '#FB8C00',
  '#FDD835',
  '#43A047',
  '#00ACC1',
  '#1E88E5',
  '#5E35B1',
  '#D81B60',
  '#78909C',
];

/// 프로젝트의 업무 유형(Bug/Feature/행사 등)을 추가·수정·삭제한다. 유형을 지워도 그 유형이던
/// 업무는 남고 유형만 비워진다. "프로젝트 메뉴"의 "필드 / 상태"에서 쓴다.
class ProjectTypeEditor extends StatefulWidget {
  final Session session;
  final String projectId;
  const ProjectTypeEditor({
    super.key,
    required this.session,
    required this.projectId,
  });

  @override
  State<ProjectTypeEditor> createState() => _ProjectTypeEditorState();
}

class _ProjectTypeEditorState extends State<ProjectTypeEditor> {
  List<TaskType>? _types;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final types = await widget.session.api!.fetchTaskTypes(widget.projectId);
      if (mounted) {
        setState(() {
          _types = types;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _edit({TaskType? existing}) async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _TypeEditDialog(existing: existing),
    );
    if (result == null) return;
    final (name, color) = result;
    try {
      final api = widget.session.api!;
      if (existing == null) {
        await api.createTaskType(widget.projectId, name: name, color: color);
      } else {
        await api.updateTaskType(existing.id, name: name, color: color);
      }
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '저장하지 못했습니다: $e');
    }
  }

  Future<void> _delete(TaskType type) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('유형 삭제'),
        content: Text("'${type.name}' 유형을 삭제할까요? 이 유형이던 업무는 남고 유형만 비워집니다."),
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
      await widget.session.api!.deleteTaskType(type.id);
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '삭제하지 못했습니다: $e');
    }
  }

  /// 말풍선을 끌어다 놓아 순서가 바뀌었을 때 — 화면을 먼저 바꾸고, 저장에 실패하면 다시
  /// 불러온다.
  Future<void> _reorder(List<TaskType> list) async {
    setState(() => _types = list);
    try {
      await widget.session.api!.reorderTaskTypes(widget.projectId, [
        for (final t in list) t.id,
      ]);
    } catch (e) {
      if (mounted) showAppToast(context, '순서를 바꾸지 못했습니다: $e');
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final types = _types;
    return _error != null
        ? Center(child: Text(_error!))
        : types == null
        ? const Center(child: CircularProgressIndicator())
        : ConfigSection(
            title: '유형',
            description: '업무를 분류하는 꼬리표입니다(버그·기능 등). 끌어서 순서를 바꿀 수 있습니다.',
            addLabel: '추가',
            onAdd: _edit,
            emptyHint: '등록된 유형이 없습니다.',
            children: [
              ReorderableBubbleList<TaskType>(
                items: types,
                idOf: (t) => t.id,
                onReorder: _reorder,
                itemBuilder: (type) => ConfigBubble(
                  dotColor: parseTypeColor(type.color),
                  title: type.name,
                  actions: [
                    configAction(
                      Icons.edit_outlined,
                      '수정',
                      () => _edit(existing: type),
                    ),
                    configAction(
                      Icons.delete_outline,
                      '삭제',
                      () => _delete(type),
                    ),
                  ],
                ),
              ),
            ],
          );
  }
}

/// 유형 이름 + 색 고르기. 저장하면 (이름, '#RRGGBB')를 돌려준다.
class _TypeEditDialog extends StatefulWidget {
  final TaskType? existing;
  const _TypeEditDialog({this.existing});

  @override
  State<_TypeEditDialog> createState() => _TypeEditDialogState();
}

class _TypeEditDialogState extends State<_TypeEditDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late String _color = widget.existing?.color.toUpperCase() ?? _typePalette[5];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '유형 추가' : '유형 수정'),
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
                labelText: '유형 이름',
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
                for (final hex in _typePalette)
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
                              ? Colors.black87
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: _color == hex
                          ? const Icon(
                              Icons.check,
                              size: 16,
                              color: Colors.white,
                            )
                          : null,
                    ),
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

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop((name, _color));
  }
}
