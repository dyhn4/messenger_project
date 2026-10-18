import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import 'filter_controls.dart';
import 'project_forms.dart';
import 'task_filter.dart' show QuickFilter, quickFilterLabel;
import 'task_views.dart';
import '../../l10n/tr.dart';

/// "내 업무" 필터 — 빠른 필터링(미완료/완료/지연) 하나와 "필터 추가"로 꺼내는 프로젝트·시작일·마감일.
/// 비어 있는 항목은 "전체".
class _Filters {
  final QuickFilter? quick;
  final String? projectId;

  /// 이 날 이후(그날 포함)에 시작하는 업무.
  final DateTime? startFrom;

  /// 이 날까지(그날 포함) 마감인 업무.
  final DateTime? dueBy;

  const _Filters({this.quick, this.projectId, this.startFrom, this.dueBy});

  int get activeCount =>
      (quick == null ? 0 : 1) +
      (projectId == null ? 0 : 1) +
      (startFrom == null ? 0 : 1) +
      (dueBy == null ? 0 : 1);

  _Filters copyWith({
    Object? quick = _keep,
    Object? projectId = _keep,
    Object? startFrom = _keep,
    Object? dueBy = _keep,
  }) => _Filters(
    quick: quick == _keep ? this.quick : quick as QuickFilter?,
    projectId: projectId == _keep ? this.projectId : projectId as String?,
    startFrom: startFrom == _keep ? this.startFrom : startFrom as DateTime?,
    dueBy: dueBy == _keep ? this.dueBy : dueBy as DateTime?,
  );

  bool matches(Task t) {
    // 보관한 업무는 "보관된 업무"를 골랐을 때만 보이고(그때는 보관한 것만), 필터가 없거나
    // 다른 빠른 필터일 때는 늘 뺀다.
    if (t.archived != (quick == QuickFilter.archived)) return false;
    switch (quick) {
      case QuickFilter.incomplete:
        if (t.status == TaskStatus.done) return false;
      case QuickFilter.done:
        if (t.status != TaskStatus.done) return false;
      case QuickFilter.overdue:
        if (!t.isOverdue) return false;
      case QuickFilter.mine:
      case QuickFilter.archived:
      case null:
        break;
    }
    if (projectId != null && t.projectId != projectId) return false;
    if (startFrom != null) {
      final start = t.startDate;
      if (start == null || dateOnly(start).isBefore(startFrom!)) return false;
    }
    if (dueBy != null) {
      final due = t.dueDate;
      if (due == null || dateOnly(due).isAfter(dueBy!)) return false;
    }
    return true;
  }
}

/// 기본 정렬 — 프로젝트 키 오름차순, 같은 프로젝트 안에서는 업무 번호 오름차순
/// ("MKT-1009"를 "MKT"와 1009로 나눠 비교해서 1009가 999보다 뒤에 온다). 키가 없으면 맨 뒤.
int compareTaskKeys(Task a, Task b) {
  (String, int)? split(String? key) {
    if (key == null) return null;
    final dash = key.lastIndexOf('-');
    if (dash < 0) return (key, 0);
    return (key.substring(0, dash), int.tryParse(key.substring(dash + 1)) ?? 0);
  }

  final ka = split(a.key);
  final kb = split(b.key);
  if (ka == null || kb == null) {
    return ka == null ? (kb == null ? 0 : 1) : -1;
  }
  final byProject = ka.$1.compareTo(kb.$1);
  return byProject != 0 ? byProject : ka.$2.compareTo(kb.$2);
}

/// copyWith에서 "안 바꿈"과 "null로 지움"을 구분하는 표식.
const _keep = Object();

/// "필터 추가"로 꺼낼 수 있는 필터(순서대로 보인다).
final _extraFilters = [
  (id: 'project', label: tr('프로젝트')),
  (id: 'start', label: tr('시작일')),
  (id: 'due', label: tr('마감일')),
];

/// 프로젝트 → "내 업무": 내가 담당자이거나 참조자로 걸린 업무를 리스트/캘린더로 본다.
class MyTasksView extends StatefulWidget {
  final Session session;
  final String teamId;
  final int reloadTick;

  const MyTasksView({
    super.key,
    required this.session,
    required this.teamId,
    required this.reloadTick,
  });

  @override
  State<MyTasksView> createState() => _MyTasksViewState();
}

class _MyTasksViewState extends State<MyTasksView> {
  List<Task>? _tasks;
  List<Project> _projects = const [];
  String? _error;

  _Filters _filters = const _Filters();

  /// "필터 추가"로 꺼내 둔 필터 줄('project' | 'start' | 'due') — 값이 비어 있어도 줄은 남는다.
  final _shownFilters = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MyTasksView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadTick != widget.reloadTick) _load();
  }

  Future<void> _load() async {
    try {
      final api = widget.session.api!;
      final results = await Future.wait([
        // 보관한 업무도 받아서 표에 흐리게 보여준다("보관된 업무"로 따로 볼 수 있다).
        api.fetchMyTasks(widget.teamId, includeArchived: true),
        api.fetchProjects(widget.teamId),
      ]);
      if (mounted) {
        setState(() {
          _tasks = results[0] as List<Task>;
          _projects = results[1] as List<Project>;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _openTask(Task task) async {
    await showTaskDetailDialog(context, widget.session, task.id);
    if (mounted) _load();
  }

  Future<void> _newTask() async {
    if (_projects.isEmpty) {
      showAppToast(context, tr('참여 중인 프로젝트가 없어서 업무를 만들 수 없습니다.'));
      return;
    }
    final created = await showNewTaskDialog(
      context,
      widget.session,
      projects: _projects,
    );
    if (created != null && mounted) _load();
  }

  void _setFilters(_Filters f) => setState(() => _filters = f);

  /// 필터 줄을 뺀다 — 걸려 있던 값도 같이 지운다.
  void _removeFilter(String id) => setState(() {
    _shownFilters.remove(id);
    _filters = switch (id) {
      'project' => _filters.copyWith(projectId: null),
      'start' => _filters.copyWith(startFrom: null),
      _ => _filters.copyWith(dueBy: null),
    };
  });

  Widget _filterPanel(BuildContext context) {
    final f = _filters;
    final shown = [
      for (final e in _extraFilters)
        if (_shownFilters.contains(e.id)) e,
    ];
    return FilterPanel(
      onClear: f.activeCount == 0 && _shownFilters.isEmpty
          ? null
          : () => setState(() {
              _shownFilters.clear();
              _filters = const _Filters();
            }),
      quickChips: [
        for (final q in [
          QuickFilter.incomplete,
          QuickFilter.done,
          QuickFilter.overdue,
          QuickFilter.archived,
        ])
          FilterQuickChip(
            label: quickFilterLabel(q),
            selected: f.quick == q,
            onTap: () =>
                _setFilters(f.copyWith(quick: f.quick == q ? null : q)),
          ),
      ],
      children: [
        FilterAddButton(
          options: [
            for (final e in _extraFilters)
              if (!_shownFilters.contains(e.id)) e,
          ],
          onSelected: (id) => setState(() => _shownFilters.add(id)),
        ),
        if (shown.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(top: 8, bottom: 12),
            child: Divider(height: 1),
          ),
          for (final e in shown)
            FilterRow(
              key: ValueKey('my-filter-${e.id}'),
              label: e.label,
              onRemove: () => _removeFilter(e.id),
              child: switch (e.id) {
                'project' => FilterDropdown<String>(
                  value: f.projectId,
                  options: [
                    for (final p in _projects) (value: p.id, label: p.name),
                  ],
                  onChanged: (v) => _setFilters(f.copyWith(projectId: v)),
                ),
                'start' => FilterDateField(
                  value: f.startFrom,
                  onChanged: (d) => _setFilters(f.copyWith(startFrom: d)),
                ),
                _ => FilterDateField(
                  value: f.dueBy,
                  onChanged: (d) => _setFilters(f.copyWith(dueBy: d)),
                ),
              },
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final all = _tasks;
    if (all == null) return const Center(child: CircularProgressIndicator());
    final visible = all.where(_filters.matches).toList()..sort(compareTaskKeys);
    final hint = Theme.of(context).hintColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('내 업무'),
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tr('내가 담당자이거나 참조된 업무가 표시됩니다.'),
                      style: TextStyle(color: hint),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: _newTask,
                icon: const Icon(Icons.add, size: 18),
                label: Text(tr('새 업무')),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilterPanelButton(
              label: _filters.activeCount == 0
                  ? tr('필터링')
                  : tr('필터링 {_filters.activeCount}', {
                      '_filters.activeCount': _filters.activeCount,
                    }),
              panelBuilder: _filterPanel,
            ),
          ),
        ),
        Expanded(
          child: TaskListTable(
            tasks: visible,
            session: widget.session,
            onOpen: _openTask,
            // 보관한 업무만 남은 경우도 "업무가 없다"로 본다("보관된 업무"를 고른 때는 제외).
            emptyText:
                _filters.quick != QuickFilter.archived &&
                    all.every((t) => t.archived)
                ? tr('담당하거나 참조된 업무가 없습니다.')
                : tr('조건에 맞는 업무가 없습니다.'),
            // 표에서 배지로 유형·우선순위·상태를 바꾸면 목록을 다시 읽는다.
            onChanged: _load,
          ),
        ),
      ],
    );
  }
}
