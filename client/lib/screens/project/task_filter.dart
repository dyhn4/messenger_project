import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
import '../../widgets/floating_dialog.dart';
import '../../widgets/muted_scrollbar.dart';

/// 숫자/날짜 필드의 범위 조건 — [min]/[max] 중 하나만 있어도 된다(날짜는 밀리초, [max]는 그날 끝까지).
class FieldRange {
  final num? min;
  final num? max;
  const FieldRange({this.min, this.max});

  bool get isEmpty => min == null && max == null;

  bool contains(dynamic v) {
    if (v is! num) return false;
    if (min != null && v < min!) return false;
    if (max != null && v > max!) return false;
    return true;
  }
}

/// 프로젝트 화면의 업무 필터 — 다섯 가지 보기(리스트/칸반/간트/캘린더/대시보드)에 같이 적용된다.
/// 비어 있는 항목은 "전체". 사용자 정의 필드는 선택 필드는 값이 같은 것, 텍스트 필드는 글자가 들어 있는 것만 본다.
class TaskFilter {
  final String query;
  final Set<String> statusIds;
  final Set<TaskPriority> priorities;
  final String? assigneeId;
  final String? typeId;

  /// {필드id: 값} — 선택 필드는 정확히 일치, 텍스트 필드는 포함(대소문자 무시).
  final Map<String, String> fieldValues;

  /// {필드id: 범위} — 숫자·날짜 필드.
  final Map<String, FieldRange> fieldRanges;

  const TaskFilter({
    this.query = '',
    this.statusIds = const {},
    this.priorities = const {},
    this.assigneeId,
    this.typeId,
    this.fieldValues = const {},
    this.fieldRanges = const {},
  });

  int get activeCount =>
      (query.trim().isEmpty ? 0 : 1) +
      (statusIds.isEmpty ? 0 : 1) +
      (priorities.isEmpty ? 0 : 1) +
      (assigneeId == null ? 0 : 1) +
      (typeId == null ? 0 : 1) +
      fieldValues.length +
      fieldRanges.length;

  bool get isEmpty => activeCount == 0;

  /// [statuses]는 상태 id가 없는 예전 업무를 같은 분류의 첫 상태로 보기 위해 필요하다.
  bool matches(
    Task t, {
    List<TaskStatusDef> statuses = const [],
    List<TaskFieldDef> fields = const [],
  }) {
    final q = query.trim().toLowerCase();
    if (q.isNotEmpty &&
        !t.title.toLowerCase().contains(q) &&
        !(t.key ?? '').toLowerCase().contains(q)) {
      return false;
    }
    if (statusIds.isNotEmpty) {
      var id = t.statusId;
      if (id == null || !statuses.any((s) => s.id == id)) {
        id = statuses
            .where((s) => s.category == t.status)
            .map((s) => s.id)
            .firstOrNull;
      }
      if (!statusIds.contains(id)) return false;
    }
    if (priorities.isNotEmpty && !priorities.contains(t.priority)) return false;
    if (assigneeId != null) {
      // '__none__'은 담당자 없는 업무.
      if (assigneeId == noAssigneeFilter) {
        if (t.assigneeId != null) return false;
      } else if (t.assigneeId != assigneeId) {
        return false;
      }
    }
    if (typeId != null && t.typeId != typeId) return false;
    for (final e in fieldValues.entries) {
      final def = fields.where((f) => f.id == e.key).firstOrNull;
      final v = t.customValues[e.key];
      if (def == null) continue;
      if (def.kind == 'select') {
        if (v != e.value) return false;
      } else {
        if (!(v?.toString().toLowerCase().contains(e.value.toLowerCase()) ??
            false)) {
          return false;
        }
      }
    }
    for (final e in fieldRanges.entries) {
      if (!e.value.contains(t.customValues[e.key])) return false;
    }
    return true;
  }
}

const noAssigneeFilter = '__none__';

/// 필터 창 — 적용하면 새 [TaskFilter]를, 취소하면 null을 돌려준다.
Future<TaskFilter?> showTaskFilterDialog(
  BuildContext context, {
  required TaskFilter initial,
  required List<TaskStatusDef> statuses,
  required List<AppUser> members,
  required List<TaskType> types,
  required List<TaskFieldDef> fields,
}) {
  return showDialog<TaskFilter>(
    context: context,
    builder: (_) => _TaskFilterDialog(
      initial: initial,
      statuses: statuses,
      members: members,
      types: types,
      fields: fields,
    ),
  );
}

class _TaskFilterDialog extends StatefulWidget {
  final TaskFilter initial;
  final List<TaskStatusDef> statuses;
  final List<AppUser> members;
  final List<TaskType> types;
  final List<TaskFieldDef> fields;
  const _TaskFilterDialog({
    required this.initial,
    required this.statuses,
    required this.members,
    required this.types,
    required this.fields,
  });

  @override
  State<_TaskFilterDialog> createState() => _TaskFilterDialogState();
}

class _TaskFilterDialogState extends State<_TaskFilterDialog> {
  late final _query = TextEditingController(text: widget.initial.query);
  late final _statusIds = {...widget.initial.statusIds};
  late final _priorities = {...widget.initial.priorities};
  late String? _assigneeId = widget.initial.assigneeId;
  late String? _typeId = widget.initial.typeId;
  late final Map<String, String> _fieldValues = {...widget.initial.fieldValues};
  final _scroll = ScrollController();
  final _textControllers = <String, TextEditingController>{};
  late final Map<String, FieldRange> _ranges = {...widget.initial.fieldRanges};

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    for (final c in _textControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        child,
      ],
    ),
  );

  TaskFilter _build() {
    final values = {..._fieldValues}..removeWhere((_, v) => v.trim().isEmpty);
    return TaskFilter(
      query: _query.text,
      statusIds: _statusIds,
      priorities: _priorities,
      assigneeId: _assigneeId,
      typeId: _typeId,
      fieldValues: values,
      fieldRanges: {..._ranges}..removeWhere((_, r) => r.isEmpty),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filterable = widget.fields
        .where((f) => f.kind == 'select' || f.kind == 'text')
        .toList();
    final rangeable = widget.fields
        .where((f) => f.kind == 'number' || f.kind == 'date')
        .toList();
    return FloatingDialog(
      title: '필터',
      maxWidth: 480,
      maxHeight: 640,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: MutedScrollbar(
              controller: _scroll,
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.only(right: 12),
                children: [
                  _section(
                    '검색',
                    TextField(
                      controller: _query,
                      decoration: const InputDecoration(
                        hintText: '제목 또는 업무 번호',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  _section(
                    '상태',
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final s in widget.statuses)
                          FilterChip(
                            label: Text(s.name),
                            selected: _statusIds.contains(s.id),
                            onSelected: (v) => setState(
                              () => v
                                  ? _statusIds.add(s.id)
                                  : _statusIds.remove(s.id),
                            ),
                          ),
                      ],
                    ),
                  ),
                  _section(
                    '우선순위',
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final p in TaskPriority.values)
                          FilterChip(
                            label: Text(taskPriorityLabel(p)),
                            selected: _priorities.contains(p),
                            onSelected: (v) => setState(
                              () => v
                                  ? _priorities.add(p)
                                  : _priorities.remove(p),
                            ),
                          ),
                      ],
                    ),
                  ),
                  _section(
                    '담당자',
                    DropdownButtonFormField<String?>(
                      initialValue: _assigneeId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('전체')),
                        const DropdownMenuItem(
                          value: noAssigneeFilter,
                          child: Text('담당자 없음'),
                        ),
                        for (final m in widget.members)
                          DropdownMenuItem(value: m.id, child: Text(m.name)),
                      ],
                      onChanged: (v) => setState(() => _assigneeId = v),
                    ),
                  ),
                  if (widget.types.isNotEmpty)
                    _section(
                      '유형',
                      DropdownButtonFormField<String?>(
                        initialValue: _typeId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: null,
                            child: Text('전체'),
                          ),
                          for (final t in widget.types)
                            DropdownMenuItem(value: t.id, child: Text(t.name)),
                        ],
                        onChanged: (v) => setState(() => _typeId = v),
                      ),
                    ),
                  for (final f in filterable)
                    _section(
                      f.name,
                      f.kind == 'select'
                          ? DropdownButtonFormField<String?>(
                              initialValue:
                                  f.options.contains(_fieldValues[f.id])
                                  ? _fieldValues[f.id]
                                  : null,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                              items: [
                                const DropdownMenuItem(
                                  value: null,
                                  child: Text('전체'),
                                ),
                                for (final o in f.options)
                                  DropdownMenuItem(value: o, child: Text(o)),
                              ],
                              onChanged: (v) => setState(() {
                                if (v == null) {
                                  _fieldValues.remove(f.id);
                                } else {
                                  _fieldValues[f.id] = v;
                                }
                              }),
                            )
                          : TextField(
                              controller: _textControllers.putIfAbsent(
                                f.id,
                                () => TextEditingController(
                                  text: _fieldValues[f.id] ?? '',
                                ),
                              ),
                              decoration: const InputDecoration(
                                hintText: '포함하는 글자',
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                              onChanged: (v) => _fieldValues[f.id] = v,
                            ),
                    ),
                  for (final f in rangeable)
                    _section(
                      f.name,
                      f.kind == 'number'
                          ? _NumberRange(
                              key: ValueKey('nr-${f.id}'),
                              initial: _ranges[f.id],
                              onChanged: (r) => _ranges[f.id] = r,
                            )
                          : _DateRange(
                              initial: _ranges[f.id],
                              onChanged: (r) =>
                                  setState(() => _ranges[f.id] = r),
                            ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(const TaskFilter()),
                child: const Text('초기화'),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('취소'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(_build()),
                child: const Text('적용'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NumberRange extends StatefulWidget {
  final FieldRange? initial;
  final ValueChanged<FieldRange> onChanged;
  const _NumberRange({super.key, this.initial, required this.onChanged});

  @override
  State<_NumberRange> createState() => _NumberRangeState();
}

class _NumberRangeState extends State<_NumberRange> {
  late final _min = TextEditingController(
    text: widget.initial?.min?.toString() ?? '',
  );
  late final _max = TextEditingController(
    text: widget.initial?.max?.toString() ?? '',
  );

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged(
    FieldRange(
      min: num.tryParse(_min.text.trim()),
      max: num.tryParse(_max.text.trim()),
    ),
  );

  @override
  Widget build(BuildContext context) {
    InputDecoration deco(String hint) => InputDecoration(
      hintText: hint,
      isDense: true,
      border: const OutlineInputBorder(),
    );
    const keyboard = TextInputType.numberWithOptions(
      decimal: true,
      signed: true,
    );
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _min,
            keyboardType: keyboard,
            decoration: deco('최소'),
            onChanged: (_) => _emit(),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Text('~'),
        ),
        Expanded(
          child: TextField(
            controller: _max,
            keyboardType: keyboard,
            decoration: deco('최대'),
            onChanged: (_) => _emit(),
          ),
        ),
      ],
    );
  }
}

class _DateRange extends StatelessWidget {
  final FieldRange? initial;
  final ValueChanged<FieldRange> onChanged;
  const _DateRange({this.initial, required this.onChanged});

  String _fmt(num? ms) {
    if (ms == null) return '지정 안 함';
    final d = DateTime.fromMillisecondsSinceEpoch(ms.toInt());
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Future<DateTime?> _pick(BuildContext context, num? current) {
    final now = DateTime.now();
    return showDatePicker(
      context: context,
      initialDate: current == null
          ? now
          : DateTime.fromMillisecondsSinceEpoch(current.toInt()),
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 10),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = initial ?? const FieldRange();
    return Row(
      children: [
        TextButton(
          onPressed: () async {
            final d = await _pick(context, r.min);
            if (d != null) {
              onChanged(FieldRange(min: d.millisecondsSinceEpoch, max: r.max));
            }
          },
          child: Text('부터 ${_fmt(r.min)}'),
        ),
        TextButton(
          onPressed: () async {
            final d = await _pick(context, r.max);
            if (d != null) {
              // 그날 끝까지 포함한다.
              final end = DateTime(d.year, d.month, d.day, 23, 59, 59, 999);
              onChanged(
                FieldRange(min: r.min, max: end.millisecondsSinceEpoch),
              );
            }
          },
          child: Text('까지 ${_fmt(r.max)}'),
        ),
        if (!r.isEmpty)
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: '지우기',
            onPressed: () => onChanged(const FieldRange()),
          ),
      ],
    );
  }
}
