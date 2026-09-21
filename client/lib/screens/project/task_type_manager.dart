import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/floating_dialog.dart';
import '../../widgets/muted_scrollbar.dart';

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

/// 프로젝트의 업무 유형(Bug/Feature/행사 등)을 추가·수정·삭제한다 — 프로젝트 담당자와 팀
/// 소유자·관리자만 열 수 있다(서버도 다시 확인한다). 유형을 지워도 그 유형이던 업무는 남고
/// 유형만 비워진다.
Future<void> showTaskTypeManagerDialog(
  BuildContext context,
  Session session,
  String projectId,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _TaskTypeManager(session: session, projectId: projectId),
  );
}

class _TaskTypeManager extends StatefulWidget {
  final Session session;
  final String projectId;
  const _TaskTypeManager({required this.session, required this.projectId});

  @override
  State<_TaskTypeManager> createState() => _TaskTypeManagerState();
}

class _TaskTypeManagerState extends State<_TaskTypeManager> {
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

  @override
  Widget build(BuildContext context) {
    final types = _types;
    return FloatingDialog(
      title: '업무 유형 관리',
      maxWidth: 440,
      maxHeight: 560,
      child: _error != null
          ? Center(child: Text(_error!))
          : types == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: types.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: Text(
                              '등록된 유형이 없습니다.',
                              style: TextStyle(
                                color: Theme.of(context).hintColor,
                              ),
                            ),
                          ),
                        )
                      : MutedScrollbar(
                          child: ListView(
                            shrinkWrap: true,
                            children: [
                              for (final type in types)
                                ListTile(
                                  dense: true,
                                  leading: Container(
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(
                                      color: parseTypeColor(type.color),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  title: Text(type.name),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: const Icon(
                                          Icons.edit_outlined,
                                          size: 18,
                                        ),
                                        tooltip: '수정',
                                        onPressed: () => _edit(existing: type),
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          size: 18,
                                        ),
                                        tooltip: '삭제',
                                        onPressed: () => _delete(type),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: () => _edit(),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('유형 추가'),
                  ),
                ),
              ],
            ),
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
