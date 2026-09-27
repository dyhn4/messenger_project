import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
import 'filter_controls.dart';

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
/// "빠른 필터링" 한 줄짜리 조건 — 대시보드 카드를 눌렀을 때도 이 값이 걸린다.
enum QuickFilter { incomplete, done, overdue, mine }

String quickFilterLabel(QuickFilter q) => switch (q) {
  QuickFilter.incomplete => '미완료 업무',
  QuickFilter.done => '완료된 업무',
  QuickFilter.overdue => '지연 업무',
  QuickFilter.mine => '내 업무',
};

class TaskFilter {
  final QuickFilter? quick;
  final String query;
  final Set<String> statusIds;
  final Set<String> priorityIds;
  final String? assigneeId;
  final String? typeId;

  /// {필드id: 값} — 선택 필드는 정확히 일치, 텍스트 필드는 포함(대소문자 무시).
  final Map<String, String> fieldValues;

  /// {필드id: 범위} — 숫자·날짜 필드.
  final Map<String, FieldRange> fieldRanges;

  /// 이 날 이후(그날 포함)에 시작하는 업무.
  final DateTime? startFrom;

  /// 이 날까지(그날 포함) 마감인 업무.
  final DateTime? dueBy;

  const TaskFilter({
    this.quick,
    this.query = '',
    this.statusIds = const {},
    this.priorityIds = const {},
    this.assigneeId,
    this.typeId,
    this.fieldValues = const {},
    this.fieldRanges = const {},
    this.startFrom,
    this.dueBy,
  });

  int get activeCount =>
      (quick == null ? 0 : 1) +
      (query.trim().isEmpty ? 0 : 1) +
      (statusIds.isEmpty ? 0 : 1) +
      (priorityIds.isEmpty ? 0 : 1) +
      (assigneeId == null ? 0 : 1) +
      (typeId == null ? 0 : 1) +
      fieldValues.length +
      fieldRanges.length +
      (startFrom == null ? 0 : 1) +
      (dueBy == null ? 0 : 1);

  bool get isEmpty => activeCount == 0;

  /// [statuses]는 상태 id가 없는 예전 업무를 같은 분류의 첫 상태로 보기 위해 필요하다.
  TaskFilter _copy({
    Object? quick = _keep,
    String? query,
    Set<String>? statusIds,
    Set<String>? priorityIds,
    Object? assigneeId = _keep,
    Object? typeId = _keep,
    Map<String, String>? fieldValues,
    Map<String, FieldRange>? fieldRanges,
    Object? startFrom = _keep,
    Object? dueBy = _keep,
  }) => TaskFilter(
    quick: quick == _keep ? this.quick : quick as QuickFilter?,
    query: query ?? this.query,
    statusIds: statusIds ?? this.statusIds,
    priorityIds: priorityIds ?? this.priorityIds,
    assigneeId: assigneeId == _keep ? this.assigneeId : assigneeId as String?,
    typeId: typeId == _keep ? this.typeId : typeId as String?,
    fieldValues: fieldValues ?? this.fieldValues,
    fieldRanges: fieldRanges ?? this.fieldRanges,
    startFrom: startFrom == _keep ? this.startFrom : startFrom as DateTime?,
    dueBy: dueBy == _keep ? this.dueBy : dueBy as DateTime?,
  );

  TaskFilter copyStartFrom(DateTime? d) => _copy(startFrom: d);
  TaskFilter copyDueBy(DateTime? d) => _copy(dueBy: d);

  TaskFilter copyQuick(QuickFilter? q) => _copy(quick: q);
  TaskFilter copyAssignee(String? id) => _copy(assigneeId: id);
  TaskFilter copyType(String? id) => _copy(typeId: id);
  TaskFilter copyStatus(String? id) =>
      _copy(statusIds: id == null ? const {} : {id});

  /// 상태 조건만 [ids]로 바꾼다 — 칸반에서 숨겨 둔 상태 조건을 되살릴 때.
  TaskFilter withStatusIds(Set<String> ids) => _copy(statusIds: ids);
  TaskFilter copyPriority(String? id) =>
      _copy(priorityIds: id == null ? const {} : {id});

  TaskFilter copyFieldValue(String fieldId, String? value) {
    final next = {...fieldValues};
    if (value == null || value.trim().isEmpty) {
      next.remove(fieldId);
    } else {
      next[fieldId] = value;
    }
    return _copy(fieldValues: next);
  }

  TaskFilter copyFieldRange(String fieldId, FieldRange range) {
    final next = {...fieldRanges};
    if (range.isEmpty) {
      next.remove(fieldId);
    } else {
      next[fieldId] = range;
    }
    return _copy(fieldRanges: next);
  }

  /// 조건 하나를 뺀 새 필터 — 목록 위 조건 칩의 × 버튼이 쓴다.
  TaskFilter without({
    bool quick = false,
    bool query = false,
    bool statuses = false,
    bool priorities = false,
    bool assignee = false,
    bool type = false,
    bool start = false,
    bool due = false,
    String? fieldId,
  }) => TaskFilter(
    quick: quick ? null : this.quick,
    query: query ? '' : this.query,
    statusIds: statuses ? const {} : statusIds,
    priorityIds: priorities ? const {} : priorityIds,
    assigneeId: assignee ? null : assigneeId,
    typeId: type ? null : typeId,
    fieldValues: fieldId == null
        ? fieldValues
        : ({...fieldValues}..remove(fieldId)),
    fieldRanges: fieldId == null
        ? fieldRanges
        : ({...fieldRanges}..remove(fieldId)),
    startFrom: start ? null : startFrom,
    dueBy: due ? null : dueBy,
  );

  bool matches(
    Task t, {
    String? myUserId,
    List<TaskStatusDef> statuses = const [],
    List<TaskPriorityDef> priorities = const [],
    List<TaskFieldDef> fields = const [],
  }) {
    switch (quick) {
      case QuickFilter.incomplete:
        if (t.status == TaskStatus.done) return false;
      case QuickFilter.done:
        if (t.status != TaskStatus.done) return false;
      case QuickFilter.overdue:
        if (!t.isOverdue) return false;
      case QuickFilter.mine:
        if (t.assigneeId != myUserId) return false;
      case null:
        break;
    }
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
    if (priorityIds.isNotEmpty) {
      var id = t.priorityId;
      if (id == null || !priorities.any((p) => p.id == id)) {
        id = priorities
            .where((p) => p.level == t.priority)
            .map((p) => p.id)
            .firstOrNull;
      }
      if (!priorityIds.contains(id)) return false;
    }
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
      } else if (def.kind == 'multiSelect') {
        if (v is! List || !v.contains(e.value)) return false;
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
    DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
    if (startFrom != null) {
      final s = t.startDate;
      if (s == null || day(s).isBefore(day(startFrom!))) return false;
    }
    if (dueBy != null) {
      final d = t.dueDate;
      if (d == null || day(d).isAfter(day(dueBy!))) return false;
    }
    return true;
  }
}

const noAssigneeFilter = '__none__';

/// _copy에서 "안 바꿈"과 "null로 지움"을 구분하는 표식.
const _keep = Object();

/// 목록 위에 걸려 있는 조건을 칩으로 보여준다 — × 를 누르면 그 조건만 뺀다.
List<Widget> activeFilterChips(
  BuildContext context, {
  required TaskFilter filter,
  required List<TaskStatusDef> statuses,
  required List<TaskPriorityDef> priorities,
  required List<TaskType> types,
  required List<AppUser> members,
  required List<TaskFieldDef> fields,
  required ValueChanged<TaskFilter> onChanged,
}) {
  String nameOf<T>(
    Iterable<T> list,
    String? id,
    String Function(T) name,
    String Function(T) idOf,
  ) {
    for (final e in list) {
      if (idOf(e) == id) return name(e);
    }
    return '(삭제됨)';
  }

  Widget chip(String label, TaskFilter next) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: InputChip(
      label: Text(label),
      onDeleted: () => onChanged(next),
      visualDensity: VisualDensity.compact,
    ),
  );

  return [
    if (filter.quick != null)
      chip(quickFilterLabel(filter.quick!), filter.without(quick: true)),
    if (filter.query.trim().isNotEmpty)
      chip('"${filter.query.trim()}"', filter.without(query: true)),
    for (final id in filter.statusIds)
      chip(
        nameOf(statuses, id, (s) => s.name, (s) => s.id),
        filter.without(statuses: true),
      ),
    for (final id in filter.priorityIds)
      chip(
        nameOf(priorities, id, (p) => p.name, (p) => p.id),
        filter.without(priorities: true),
      ),
    if (filter.assigneeId != null)
      chip(
        filter.assigneeId == noAssigneeFilter
            ? '담당자 없음'
            : nameOf(members, filter.assigneeId, (m) => m.name, (m) => m.id),
        filter.without(assignee: true),
      ),
    if (filter.typeId != null)
      chip(
        nameOf(types, filter.typeId, (t) => t.name, (t) => t.id),
        filter.without(type: true),
      ),
    for (final e in filter.fieldValues.entries)
      chip(
        '${nameOf(fields, e.key, (f) => f.name, (f) => f.id)}: ${e.value}',
        filter.without(fieldId: e.key),
      ),
    for (final e in filter.fieldRanges.entries)
      chip(
        nameOf(fields, e.key, (f) => f.name, (f) => f.id),
        filter.without(fieldId: e.key),
      ),
    if (filter.startFrom != null)
      chip(
        '시작일 ${FilterDateField.format(filter.startFrom!)}부터',
        filter.without(start: true),
      ),
    if (filter.dueBy != null)
      chip(
        '마감일 ${FilterDateField.format(filter.dueBy!)}까지',
        filter.without(due: true),
      ),
  ];
}

/// 목록 위 "필터링" 버튼 — 누르면 아래로 펼쳐지고, 바꿀 때마다 [onChanged]로 바로 알린다.
class TaskFilterButton extends StatefulWidget {
  final TaskFilter filter;
  final List<TaskStatusDef> statuses;
  final List<TaskPriorityDef> priorities;
  final List<TaskType> types;
  final List<AppUser> members;
  final List<TaskFieldDef> fields;
  final ValueChanged<TaskFilter> onChanged;

  /// false면 "상태" 줄을 숨긴다(칸반보드 — 열이 곧 상태라서).
  final bool showStatus;

  const TaskFilterButton({
    super.key,
    required this.filter,
    required this.statuses,
    required this.priorities,
    required this.types,
    required this.members,
    required this.fields,
    required this.onChanged,
    this.showStatus = true,
  });

  @override
  State<TaskFilterButton> createState() => _TaskFilterButtonState();
}

class _TaskFilterButtonState extends State<TaskFilterButton> {
  /// "필터 추가"로 꺼내 둔 사용자 정의 필드(와 시작일·마감일) — 값이 걸려 있는 것은 항상 보인다.
  final _extraFields = <String>{};

  static const _startId = '__start__';
  static const _dueId = '__due__';

  TaskFilter get f => widget.filter;

  static const _inputDecoration = InputDecoration(
    isDense: true,
    filled: true,
    fillColor: Color(0xFFF1F3F6),
    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(8)),
      borderSide: BorderSide(color: Color(0xFFD6DAE1)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(8)),
      borderSide: BorderSide(color: Color(0xFFD6DAE1)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(8)),
      borderSide: BorderSide(color: filterAccent),
    ),
  );

  InputDecoration _deco(BuildContext context, String hint) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return _inputDecoration.copyWith(
      hintText: hint,
      fillColor: dark
          ? Theme.of(context).colorScheme.surfaceContainerHighest
          : null,
    );
  }

  /// "전체"가 기본인 한 개짜리 선택 — 고르면 그 값 하나만 걸린다.
  Widget _pick({
    required String? value,
    required List<({String id, String name})> options,
    required ValueChanged<String?> onChanged,
  }) => FilterDropdown<String>(
    value: options.any((o) => o.id == value) ? value : null,
    options: [for (final o in options) (value: o.id, label: o.name)],
    onChanged: onChanged,
  );

  /// 사용자 정의 필드 한 줄 — 선택은 고르기, 글자는 입력, 숫자·날짜·진행률은 최소/최대.
  Widget _fieldInput(BuildContext context, TaskFieldDef field) {
    if (field.hasOptions) {
      return _pick(
        value: f.fieldValues[field.id],
        options: [for (final o in field.options) (id: o, name: o)],
        onChanged: (v) => widget.onChanged(f.copyFieldValue(field.id, v)),
      );
    }
    if (field.kind == 'text') {
      return TextFormField(
        initialValue: f.fieldValues[field.id] ?? '',
        style: const TextStyle(fontSize: 13),
        decoration: _deco(context, '포함하는 글자'),
        onChanged: (v) => widget.onChanged(f.copyFieldValue(field.id, v)),
      );
    }
    final range = f.fieldRanges[field.id] ?? const FieldRange();
    return Row(
      children: [
        Expanded(
          child: TextFormField(
            initialValue: range.min?.toString() ?? '',
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 13),
            decoration: _deco(context, '최소'),
            onChanged: (v) => widget.onChanged(
              f.copyFieldRange(
                field.id,
                FieldRange(min: num.tryParse(v), max: range.max),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: TextFormField(
            initialValue: range.max?.toString() ?? '',
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 13),
            decoration: _deco(context, '최대'),
            onChanged: (v) => widget.onChanged(
              f.copyFieldRange(
                field.id,
                FieldRange(min: range.min, max: num.tryParse(v)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _panel(BuildContext context) {
    final shown = {
      ...f.fieldValues.keys,
      ...f.fieldRanges.keys,
      if (f.startFrom != null) _startId,
      if (f.dueBy != null) _dueId,
      ..._extraFields,
    };
    final rest = [
      if (!shown.contains(_startId)) (id: _startId, label: '시작일'),
      if (!shown.contains(_dueId)) (id: _dueId, label: '마감일'),
      for (final x in widget.fields)
        if (!shown.contains(x.id)) (id: x.id, label: x.name),
    ];
    return FilterPanel(
      onClear: f.isEmpty
          ? null
          : () {
              setState(_extraFields.clear);
              widget.onChanged(const TaskFilter());
            },
      quickChips: [
        for (final q in QuickFilter.values)
          FilterQuickChip(
            label: quickFilterLabel(q),
            selected: f.quick == q,
            onTap: () => widget.onChanged(f.copyQuick(f.quick == q ? null : q)),
          ),
      ],
      children: [
        if (widget.showStatus)
          FilterRow(
            label: '상태',
            child: _pick(
              value: f.statusIds.firstOrNull,
              options: [
                for (final s in widget.statuses) (id: s.id, name: s.name),
              ],
              onChanged: (v) => widget.onChanged(f.copyStatus(v)),
            ),
          ),
        FilterRow(
          label: '담당자',
          child: _pick(
            value: f.assigneeId,
            options: [
              (id: noAssigneeFilter, name: '담당자 없음'),
              for (final m in widget.members) (id: m.id, name: m.name),
            ],
            onChanged: (v) => widget.onChanged(f.copyAssignee(v)),
          ),
        ),
        FilterRow(
          label: '유형',
          child: _pick(
            value: f.typeId,
            options: [for (final t in widget.types) (id: t.id, name: t.name)],
            onChanged: (v) => widget.onChanged(f.copyType(v)),
          ),
        ),
        FilterRow(
          label: '우선순위',
          child: _pick(
            value: f.priorityIds.firstOrNull,
            options: [
              for (final p in widget.priorities) (id: p.id, name: p.name),
            ],
            onChanged: (v) => widget.onChanged(f.copyPriority(v)),
          ),
        ),
        if (shown.contains(_startId))
          FilterRow(
            key: const ValueKey('filter-start'),
            label: '시작일',
            child: FilterDateField(
              value: f.startFrom,
              onChanged: (d) => widget.onChanged(f.copyStartFrom(d)),
            ),
            onRemove: () {
              setState(() => _extraFields.remove(_startId));
              widget.onChanged(f.without(start: true));
            },
          ),
        if (shown.contains(_dueId))
          FilterRow(
            key: const ValueKey('filter-due'),
            label: '마감일',
            child: FilterDateField(
              value: f.dueBy,
              onChanged: (d) => widget.onChanged(f.copyDueBy(d)),
            ),
            onRemove: () {
              setState(() => _extraFields.remove(_dueId));
              widget.onChanged(f.without(due: true));
            },
          ),
        for (final field in widget.fields)
          if (shown.contains(field.id))
            FilterRow(
              key: ValueKey('filter-field-${field.id}'),
              label: field.name,
              child: _fieldInput(context, field),
              onRemove: () {
                setState(() => _extraFields.remove(field.id));
                widget.onChanged(f.without(fieldId: field.id));
              },
            ),
        FilterAddButton(
          options: rest,
          onSelected: (id) => setState(() => _extraFields.add(id)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return FilterPanelButton(
      label: f.isEmpty ? '필터링' : '필터링: ${f.activeCount}',
      panelBuilder: _panel,
    );
  }
}
