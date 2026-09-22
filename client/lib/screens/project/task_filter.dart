import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
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

  const TaskFilter({
    this.quick,
    this.query = '',
    this.statusIds = const {},
    this.priorityIds = const {},
    this.assigneeId,
    this.typeId,
    this.fieldValues = const {},
    this.fieldRanges = const {},
  });

  int get activeCount =>
      (quick == null ? 0 : 1) +
      (query.trim().isEmpty ? 0 : 1) +
      (statusIds.isEmpty ? 0 : 1) +
      (priorityIds.isEmpty ? 0 : 1) +
      (assigneeId == null ? 0 : 1) +
      (typeId == null ? 0 : 1) +
      fieldValues.length +
      fieldRanges.length;

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
  }) => TaskFilter(
    quick: quick == _keep ? this.quick : quick as QuickFilter?,
    query: query ?? this.query,
    statusIds: statusIds ?? this.statusIds,
    priorityIds: priorityIds ?? this.priorityIds,
    assigneeId: assigneeId == _keep ? this.assigneeId : assigneeId as String?,
    typeId: typeId == _keep ? this.typeId : typeId as String?,
    fieldValues: fieldValues ?? this.fieldValues,
    fieldRanges: fieldRanges ?? this.fieldRanges,
  );

  TaskFilter copyQuick(QuickFilter? q) => _copy(quick: q);
  TaskFilter copyAssignee(String? id) => _copy(assigneeId: id);
  TaskFilter copyType(String? id) => _copy(typeId: id);
  TaskFilter copyStatus(String? id) =>
      _copy(statusIds: id == null ? const {} : {id});
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

  const TaskFilterButton({
    super.key,
    required this.filter,
    required this.statuses,
    required this.priorities,
    required this.types,
    required this.members,
    required this.fields,
    required this.onChanged,
  });

  @override
  State<TaskFilterButton> createState() => _TaskFilterButtonState();
}

class _TaskFilterButtonState extends State<TaskFilterButton> {
  final _menu = MenuController();
  final _addMenu = MenuController();
  final _scroll = ScrollController();

  /// "필터 추가"로 꺼내 둔 사용자 정의 필드 — 값이 걸려 있는 것은 항상 보인다.
  final _extraFields = <String>{};

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  TaskFilter get f => widget.filter;

  Widget _labeled(String label, Widget child, {Key? key}) => Padding(
    key: key,
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        SizedBox(
          width: 68,
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        Expanded(child: child),
      ],
    ),
  );

  /// "전체"가 기본인 한 개짜리 선택 — 고르면 그 값 하나만 걸린다.
  Widget _pick({
    required String? value,
    required List<({String id, String name})> options,
    required ValueChanged<String?> onChanged,
  }) => DropdownButtonFormField<String?>(
    key: ValueKey('$value-${options.length}'),
    initialValue: options.any((o) => o.id == value) ? value : null,
    isExpanded: true,
    isDense: true,
    decoration: const InputDecoration(
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      border: OutlineInputBorder(),
    ),
    items: [
      const DropdownMenuItem(value: null, child: Text('전체')),
      for (final o in options)
        DropdownMenuItem(value: o.id, child: Text(o.name)),
    ],
    onChanged: onChanged,
  );

  /// 사용자 정의 필드 한 줄 — 선택은 고르기, 글자는 입력, 숫자·날짜·진행률은 최소/최대.
  Widget _fieldInput(TaskFieldDef field) {
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
        decoration: const InputDecoration(
          hintText: '포함하는 글자',
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          border: OutlineInputBorder(),
        ),
        onChanged: (v) => widget.onChanged(f.copyFieldValue(field.id, v)),
      );
    }
    final range = f.fieldRanges[field.id] ?? const FieldRange();
    InputDecoration deco(String hint) => InputDecoration(
      hintText: hint,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      border: const OutlineInputBorder(),
    );
    return Row(
      children: [
        Expanded(
          child: TextFormField(
            initialValue: range.min?.toString() ?? '',
            keyboardType: TextInputType.number,
            decoration: deco('최소'),
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
            decoration: deco('최대'),
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
    final theme = Theme.of(context);
    final shown = {
      ...f.fieldValues.keys,
      ...f.fieldRanges.keys,
      ..._extraFields,
    };
    final rest = widget.fields.where((x) => !shown.contains(x.id)).toList();
    return SizedBox(
      width: 320,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 460),
          child: MutedScrollbar(
            controller: _scroll,
            child: SingleChildScrollView(
              controller: _scroll,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Text(
                        '필터링',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: f.isEmpty
                            ? null
                            : () {
                                _extraFields.clear();
                                widget.onChanged(const TaskFilter());
                              },
                        child: const Text('지우기'),
                      ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '빠른 필터링',
                      style: TextStyle(color: theme.hintColor, fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final q in QuickFilter.values)
                        ChoiceChip(
                          label: Text(quickFilterLabel(q)),
                          selected: f.quick == q,
                          visualDensity: VisualDensity.compact,
                          onSelected: (on) =>
                              widget.onChanged(f.copyQuick(on ? q : null)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _labeled(
                    '상태',
                    _pick(
                      value: f.statusIds.firstOrNull,
                      options: [
                        for (final s in widget.statuses)
                          (id: s.id, name: s.name),
                      ],
                      onChanged: (v) => widget.onChanged(f.copyStatus(v)),
                    ),
                  ),
                  _labeled(
                    '담당자',
                    _pick(
                      value: f.assigneeId,
                      options: [
                        (id: noAssigneeFilter, name: '담당자 없음'),
                        for (final m in widget.members)
                          (id: m.id, name: m.name),
                      ],
                      onChanged: (v) => widget.onChanged(f.copyAssignee(v)),
                    ),
                  ),
                  _labeled(
                    '유형',
                    _pick(
                      value: f.typeId,
                      options: [
                        for (final t in widget.types) (id: t.id, name: t.name),
                      ],
                      onChanged: (v) => widget.onChanged(f.copyType(v)),
                    ),
                  ),
                  _labeled(
                    '우선순위',
                    _pick(
                      value: f.priorityIds.firstOrNull,
                      options: [
                        for (final p in widget.priorities)
                          (id: p.id, name: p.name),
                      ],
                      onChanged: (v) => widget.onChanged(f.copyPriority(v)),
                    ),
                  ),
                  for (final field in widget.fields)
                    if (shown.contains(field.id))
                      _labeled(
                        field.name,
                        _fieldInput(field),
                        key: ValueKey('filter-field-${field.id}'),
                      ),
                  Align(
                    alignment: Alignment.centerLeft,
                    // MenuItemButton을 쓰면 누르는 순간 위 필터 패널까지 같이 닫힌다.
                    // 필드를 고른 뒤에도 패널은 열려 있어야 하므로 이 작은 메뉴만 닫는다.
                    child: MenuAnchor(
                      controller: _addMenu,
                      menuChildren: [
                        if (rest.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Text('추가할 필드가 없습니다'),
                          ),
                        for (final field in rest)
                          SizedBox(
                            width: 180,
                            child: TextButton(
                              style: TextButton.styleFrom(
                                alignment: Alignment.centerLeft,
                                shape: const RoundedRectangleBorder(),
                              ),
                              onPressed: () {
                                _addMenu.close();
                                setState(() => _extraFields.add(field.id));
                              },
                              child: Text(field.name),
                            ),
                          ),
                      ],
                      builder: (context, controller, _) => TextButton.icon(
                        onPressed: () => controller.isOpen
                            ? controller.close()
                            : controller.open(),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('필터 추가'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(-240, 6),
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll(
          Theme.of(context).colorScheme.surface,
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
      ),
      menuChildren: [_panel(context)],
      builder: (context, controller, _) => TextButton.icon(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.filter_list, size: 18),
        label: Text(f.isEmpty ? '필터링' : '필터링: ${f.activeCount}'),
      ),
    );
  }
}
