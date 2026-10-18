import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/muted_scrollbar.dart';
import '../../widgets/date_drop_calendar.dart';
import '../../widgets/user_avatar.dart';
import 'task_detail_panel.dart' show TaskPanelInset, TaskPanelScope;
import '../../l10n/tr.dart';

final kWeekdayLabels = [
  tr('일'),
  tr('월'),
  tr('화'),
  tr('수'),
  tr('목'),
  tr('금'),
  tr('토'),
];

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String formatYmd(DateTime d) =>
    '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';

String formatMd(DateTime d) => '${d.month}.${d.day}';

/// 캘린더/목록 양쪽에서 쓰는 업무의 날짜 범위 — 시작일·마감일 중 하나만 있으면 그 하루로 본다.
/// 둘 다 없으면 null(캘린더에는 안 나온다).
(DateTime, DateTime)? taskRange(Task t) {
  final s = t.startDate == null ? null : dateOnly(t.startDate!);
  final e = t.dueDate == null ? null : dateOnly(t.dueDate!);
  final start = s ?? e;
  final end = e ?? s;
  if (start == null || end == null) return null;
  return start.isAfter(end) ? (end, start) : (start, end);
}

/// 업무의 우선순위 색 — 프로젝트가 정한 색, 없으면 단계 기본색.
Color taskPriorityDisplayColor(Task t) => t.priorityColor != null
    ? parseTypeColor(t.priorityColor)
    : taskPriorityColor(t.priority);

/// 업무의 상태 색 — 프로젝트가 정한 색, 없으면 분류 기본색.
Color taskStatusDisplayColor(Task t) => t.statusColor != null
    ? parseTypeColor(t.statusColor)
    : taskStatusColor(t.status);

Color taskStatusColor(TaskStatus s) => switch (s) {
  TaskStatus.todo => const Color(0xFF607D8B),
  TaskStatus.doing => const Color(0xFFEF8F00),
  TaskStatus.done => const Color(0xFF2E9E6B),
};

Color taskPriorityColor(TaskPriority p) => switch (p) {
  TaskPriority.high => const Color(0xFFE53935),
  TaskPriority.normal => const Color(0xFF1E88E5),
  TaskPriority.low => const Color(0xFF78909C),
};

/// 캘린더 막대/패널 색 — 유형이 있으면 유형 색, 없으면 상태 색.
Color taskDisplayColor(Task t) => t.typeColor != null
    ? parseTypeColor(t.typeColor)
    : taskStatusColor(t.status);

/// 업무 목록 표 — "내 업무"와 프로젝트 "리스트" 보기가 같이 쓴다. [members]를 주면 마지막 칸이
/// 생성자 대신 담당자(구성원 목록에서 찾아서)를 보여준다.
/// 한 프로젝트가 정해둔 고를 수 있는 값들 — 표의 배지를 눌렀을 때 쓰고, 프로젝트별로 캐싱한다
/// ("내 업무"는 여러 프로젝트의 업무가 섞여 있어서 업무마다 소속 프로젝트 것을 받아와야 한다).
class _ProjectOptions {
  final List<TaskStatusDef> statuses;
  final List<TaskPriorityDef> priorities;
  final List<TaskType> types;
  const _ProjectOptions(this.statuses, this.priorities, this.types);
}

/// 배지 메뉴에 뜨는 항목 하나. [id]가 null이면 "없음"(값을 비운다).
class _PillOption {
  final String? id;
  final String name;
  final Color color;
  const _PillOption(this.id, this.name, this.color);
}

class TaskListTable extends StatefulWidget {
  final List<Task> tasks;
  final Session session;
  final ValueChanged<Task> onOpen;
  final String emptyText;
  final List<AppUser>? members;

  /// 프로젝트의 사용자 정의 필드 — 주면 표 오른쪽에 필드마다 열이 붙는다.
  final List<TaskFieldDef> fields;

  /// true면 배지를 눌러도 바꿀 수 없다(종료된 프로젝트).
  final bool readOnly;

  /// 배지로 유형·우선순위·상태를 바꿨을 때 — 부른 쪽이 목록을 다시 읽는다.
  final VoidCallback? onChanged;

  /// 업무 제목 아래에 프로젝트 이름을 보일지 — 여러 프로젝트가 섞인 "내 업무"만 보인다.
  final bool showProjectName;

  const TaskListTable({
    super.key,
    this.showProjectName = true,
    required this.tasks,
    required this.session,
    required this.onOpen,
    this.emptyText = '업무가 없습니다.',
    this.members,
    this.fields = const [],
    this.readOnly = false,
    this.onChanged,
  });

  @override
  State<TaskListTable> createState() => _TaskListTableState();

  /// 기억해 둔 "업무" 열 폭을 지운다 — 테스트끼리 값이 이어지지 않게.
  @visibleForTesting
  static void resetRememberedWidths() =>
      _TaskListTableState._titleWidths.clear();
}

/// 부모 바로 아래에 그 하위 업무가 오도록 줄 순서를 다시 짠다. 정렬·필터 때문에 부모가
/// 목록에 없으면 하위 업무는 제자리에 평평하게 둔다(들여쓰기할 기준이 없으므로).
List<({Task task, bool indented})> arrangeWithSubtasks(List<Task> tasks) {
  final ids = {for (final t in tasks) t.id};
  final childrenOf = <String, List<Task>>{};
  for (final t in tasks) {
    final parent = t.parentTaskId;
    if (parent != null && ids.contains(parent)) {
      childrenOf.putIfAbsent(parent, () => []).add(t);
    }
  }
  final rows = <({Task task, bool indented})>[];
  for (final t in tasks) {
    // 부모가 목록에 있는 하위 업무는 부모를 따라 아래에서 끼워 넣는다.
    if (t.parentTaskId != null && ids.contains(t.parentTaskId)) continue;
    rows.add((task: t, indented: false));
    for (final child in childrenOf[t.id] ?? const <Task>[]) {
      rows.add((task: child, indented: true));
    }
  }
  return rows;
}

class _TaskListTableState extends State<TaskListTable> {
  /// "업무" 열 폭 — 표("내 업무" / 프로젝트 리스트)마다 하나씩, 표 바깥에 기억해 둔다.
  /// 처음 한 번 창 폭에 맞춰 정하고, 그 뒤로는 구분선을 끌 때만 바뀐다 — 업무 패널이 열리거나
  /// 창이 줄어도(그때 표가 새로 만들어져도) 구분선이 제자리에 있게 하려는 것이다.
  static final _titleWidths = <bool, double>{};

  double? get _titleW => _titleWidths[widget.members != null];
  set _titleW(double? w) => w == null
      ? _titleWidths.remove(widget.members != null)
      : _titleWidths[widget.members != null] = w;

  /// 표의 가로 스크롤 — 스크롤바에 직접 물려야 막대를 끌어 움직일 수 있다(데스크톱에서
  /// 가로 스크롤 뷰는 기본 컨트롤러가 붙지 않는다).
  final _hScroll = ScrollController();

  /// 표 안의 세로 목록 — 세로 스크롤바를 표 오른쪽 끝이 아니라 **보이는 영역**의 오른쪽 끝에
  /// 그리려고 바깥으로 꺼내 쓴다(표가 가로로 넘치거나 업무 패널 뒤로 밀리면 표 끝이 안 보인다).
  final _vScroll = ScrollController();

  @override
  void dispose() {
    _hScroll.dispose();
    _vScroll.dispose();
    super.dispose();
  }

  final _optionsCache = <String, _ProjectOptions>{};

  Future<_ProjectOptions> _optionsFor(String projectId) async {
    final cached = _optionsCache[projectId];
    if (cached != null) return cached;
    final api = widget.session.api!;
    final results = await Future.wait([
      api.fetchTaskStatuses(projectId),
      api.fetchTaskPriorities(projectId),
      api.fetchTaskTypes(projectId),
    ]);
    final options = _ProjectOptions(
      results[0] as List<TaskStatusDef>,
      results[1] as List<TaskPriorityDef>,
      results[2] as List<TaskType>,
    );
    _optionsCache[projectId] = options;
    return options;
  }

  /// 배지에서 고른 값을 서버에 반영하고 목록을 다시 읽는다(열린 업무 패널도).
  Future<void> _apply(Future<void> Function() save) async {
    try {
      await save();
      widget.onChanged?.call();
      if (mounted) TaskPanelScope.notifyChanged(context);
    } catch (e) {
      if (mounted) showAppToast(context, tr('바꾸지 못했습니다: {e}', {'e': e}));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tasks.isEmpty) {
      return Center(
        child: Text(
          tr(widget.emptyText),
          style: TextStyle(color: Theme.of(context).hintColor),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // "업무" 뒤에 오는 열의 개수(유형·우선순위·상태·시작일·마감일·사람 열 + 사용자 정의 필드).
        final others =
            _TaskTable.fixedColumns(withMembers: widget.members != null) +
            widget.fields.length;
        // 가로 여백(24+24)과 표 테두리(1+1)를 뺀, 표 내용이 실제로 쓸 수 있는 폭.
        final available = constraints.maxWidth - 48 - 2;
        // 화면에 들어오게 맞출 열 수. 프로젝트 리스트에서 업무 패널이 옆에 열려 있으면
        // 담당자 열까지만 맞추고, 그 뒤(생성자·생성일·사용자 정의 필드)는 패널 뒤로 밀어
        // 둔다 — 패널이 표를 덮은 것처럼 보이고, 가로 스크롤로 볼 수 있다.
        final panelOpen = TaskPanelInset.of(context) > 0;
        final coverTrailing = widget.members != null && panelOpen;
        final fitCols = coverTrailing
            ? _TaskTable.fixedColumns(withMembers: false)
            : others;
        // "업무" 열은 구분선으로 넓힐 수 있다. 창이 좁아도 최소한 이만큼은 넓힐 수 있게 하되
        // (예전엔 좁은 창에서 최소=최대가 돼 구분선이 안 움직였다), 오른쪽 칸이 적어도 한 칸은
        // 보이게 남긴다.
        final maxTitleW = math.max(
          _TaskTable._minTitleW,
          math.min(
            math.max(
              available - _TaskTable._minOtherW * fitCols,
              _TaskTable._minTitleW + 280,
            ),
            available - _TaskTable._minOtherW,
          ),
        );
        // 처음엔 창 폭의 35%(맞출 열들이 최소 폭으로 다 들어갈 만큼까지)로 정해 두고 기억한다.
        final remembered = _titleW ??= math.max(
          _TaskTable._minTitleW,
          math.min(
            available * 0.35,
            available - _TaskTable._minOtherW * fitCols,
          ),
        );
        // 기억한 폭을 그대로 쓴다. 창이 아주 좁아져 오른쪽 칸이 한 칸도 안 보일 때만 그만큼
        // 잠깐 줄인다(기억한 값은 그대로라 창을 다시 넓히면 원래 자리로 돌아온다).
        final titleW = math.max(
          math.min(40.0, available),
          math.min(remembered, available - _TaskTable._minOtherW),
        );
        // 나머지 열은 남는 자리를 똑같이 나눠 갖는다 — 넓은 창에서 고르게 벌어진다.
        final otherW = math.max(
          _TaskTable._minOtherW,
          (available - titleW) / fitCols,
        );
        // "업무" 열 오른쪽 칸들의 전체 폭과 보이는 폭 — 넘치면 표 아래 스크롤 줄로 그 칸들만
        // 좌우로 움직인다("업무" 열은 제자리).
        final rightW = otherW * others;
        final rightVisibleW = available - titleW;
        final overflow = rightW > rightVisibleW + 0.5;
        return MutedScrollbar(
          controller: _vScroll,
          notificationPredicate: (n) => n.metrics.axis == Axis.vertical,
          child: Padding(
            padding: EdgeInsets.fromLTRB(24, 16, 24, overflow ? 6 : 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _TaskTable(
                    tasks: widget.tasks,
                    session: widget.session,
                    onOpen: widget.onOpen,
                    members: widget.members,
                    fields: widget.fields,
                    readOnly: widget.readOnly,
                    showProjectName: widget.showProjectName,
                    titleW: titleW,
                    otherW: otherW,
                    onTitleWidthTo: (x) => setState(
                      () => _titleW = x.clamp(_TaskTable._minTitleW, maxTitleW),
                    ),
                    verticalController: _vScroll,
                    horizontalController: _hScroll,
                    optionsFor: _optionsFor,
                    apply: _apply,
                  ),
                ),
                if (overflow)
                  Padding(
                    // 표 왼쪽 테두리(1) + "업무" 열 폭만큼 들여서 오른쪽 칸 구간 아래에만 둔다.
                    padding: EdgeInsets.only(left: titleW + 1, right: 1),
                    child: MutedScrollbar(
                      controller: _hScroll,
                      child: SingleChildScrollView(
                        controller: _hScroll,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(width: rightW, height: 14),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 월/주 캘린더 + 선택한 날의 업무 패널 — "내 업무", 프로젝트 "캘린더", 전체 "캘린더"가 같이 쓴다.
class TaskCalendarView extends StatefulWidget {
  final List<Task> tasks;
  final ValueChanged<Task> onOpen;
  const TaskCalendarView({
    super.key,
    required this.tasks,
    required this.onOpen,
    this.session,
    this.projectColors,
  });

  /// 일별 목록의 담당자 사진 주소를 풀 때 쓴다(없으면 이니셜로만).
  final Session? session;

  /// 주면 막대·일별 목록 색을 프로젝트 색으로(여러 프로젝트를 모아 보는 사이드바 캘린더).
  /// 없으면 업무 색(유형, 없으면 상태).
  final Map<String, Color>? projectColors;

  @override
  State<TaskCalendarView> createState() => _TaskCalendarViewState();
}

class _TaskCalendarViewState extends State<TaskCalendarView> {
  /// 막대·일별 목록 색 — 프로젝트 색이 주어졌으면 그것, 아니면 업무 색.
  Color _colorOf(Task t) =>
      widget.projectColors?[t.projectId] ?? taskDisplayColor(t);

  bool _monthMode = true;
  DateTime _focused = dateOnly(DateTime.now());
  DateTime _selected = dateOnly(DateTime.now());

  void _openTask(Task t) => widget.onOpen(t);

  /// 일별 목록 스크롤 — 데스크톱에서는 ListView가 PrimaryScrollController에 안 붙어서, 컨트롤러
  /// 없이 스크롤바를 달면 디버그 모드에서 "ScrollPosition이 없다" 오류가 난다.
  final _dayScroll = ScrollController();

  @override
  void dispose() {
    _dayScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _buildCalendar(widget.tasks);

  // ───────────────────────── 캘린더 ─────────────────────────

  DateTime get _weekStart =>
      _focused.subtract(Duration(days: _focused.weekday % 7));

  void _shift(int delta) {
    setState(() {
      _focused = _monthMode
          ? DateTime(_focused.year, _focused.month + delta, 1)
          : _focused.add(Duration(days: 7 * delta));
    });
  }

  void _goToday() {
    setState(() {
      _focused = dateOnly(DateTime.now());
      _selected = _focused;
    });
  }

  Widget _buildCalendar(List<Task> tasks) {
    final scheduled = [
      for (final t in tasks)
        if (taskRange(t) != null) t,
    ];
    final title = _monthMode
        ? tr('{_focused.year}년 {_focused.month}월', {
            '_focused.year': _focused.year,
            '_focused.month': _focused.month,
          })
        : tr('{_weekStart.year}년 {_weekStart.month}월 {_weekStart.day}일 주', {
            '_weekStart.year': _weekStart.year,
            '_weekStart.month': _weekStart.month,
            '_weekStart.day': _weekStart.day,
          });

    // 그 달의 주(행)별 날짜들.
    final weeks = <List<DateTime>>[];
    if (_monthMode) {
      final first = DateTime(_focused.year, _focused.month, 1);
      final gridStart = first.subtract(Duration(days: first.weekday % 7));
      final daysInMonth = DateTime(_focused.year, _focused.month + 1, 0).day;
      final rows = ((first.weekday % 7) + daysInMonth / 7).ceil();
      final weekCount = (((first.weekday % 7) + daysInMonth) / 7).ceil();
      assert(rows >= 0);
      for (var w = 0; w < weekCount; w++) {
        weeks.add([
          for (var d = 0; d < 7; d++) gridStart.add(Duration(days: w * 7 + d)),
        ]);
      }
    } else {
      final start = _weekStart;
      weeks.add([for (var d = 0; d < 7; d++) start.add(Duration(days: d))]);
    }

    final selectedTasks = [
      for (final t in scheduled)
        if (!_selected.isBefore(taskRange(t)!.$1) &&
            !_selected.isAfter(taskRange(t)!.$2))
          t,
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 760;
        final grid = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _shift(-1),
                ),
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _shift(1),
                ),
                const SizedBox(width: 4),
                OutlinedButton(
                  onPressed: _goToday,
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(tr('오늘')),
                ),
                const Spacer(),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: [
                    ButtonSegment(value: true, label: Text(tr('월'))),
                    ButtonSegment(value: false, label: Text(tr('주'))),
                  ],
                  selected: {_monthMode},
                  onSelectionChanged: (s) =>
                      setState(() => _monthMode = s.first),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      child: Text(
                        kWeekdayLabels[i],
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: i == 0
                              ? Colors.redAccent
                              : (i == 6 ? Colors.blueAccent : null),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            Expanded(
              child: Column(
                children: [
                  for (final week in weeks)
                    Expanded(
                      child: _WeekRow(
                        colorOf: _colorOf,
                        days: week,
                        tasks: scheduled,
                        month: _monthMode ? _focused.month : null,
                        selected: _selected,
                        maxLanes: _monthMode ? 3 : 8,
                        onSelectDay: (d) => setState(() => _selected = d),
                        onOpenTask: _openTask,
                      ),
                    ),
                ],
              ),
            ),
          ],
        );

        final panel = _DayPanel(
          colorOf: _colorOf,
          date: _selected,
          tasks: selectedTasks,
          session: widget.session,
          onOpen: _openTask,
          scroll: _dayScroll,
        );
        // 업무 패널이 옆에 열려 있으면 일별 목록 자리는 그 패널이 덮는다 — 목록은 빼고
        // 달력만 남긴다(패널을 닫으면 다시 나온다).
        if (TaskPanelInset.of(context) > 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: grid,
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
          child: narrow
              ? Column(
                  children: [
                    Expanded(flex: 3, child: grid),
                    const SizedBox(height: 12),
                    Expanded(flex: 2, child: panel),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: grid),
                    const SizedBox(width: 16),
                    SizedBox(width: 300, child: panel),
                  ],
                ),
        );
      },
    );
  }
}

// ───────────────────────── 리스트 표 ─────────────────────────

/// 리스트 표의 가로·세로 구분선 색 — 테마 기본 구분선(dividerColor)은 거의 안 보일 만큼
/// 옅어서, 칸 경계가 드러나도록 회색을 쓴다(어두운 테마에서도 같은 회색으로 보이게 투명도만
/// 조절한다).
Color _tableGridLine(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? Colors.grey.withValues(alpha: 0.45)
    : Colors.grey.shade400;

class _TaskTable extends StatelessWidget {
  final List<Task> tasks;
  final Session session;
  final ValueChanged<Task> onOpen;
  final List<AppUser>? members;
  final List<TaskFieldDef> fields;
  final bool readOnly;
  final bool showProjectName;

  /// "업무" 열의 폭, 나머지 열 하나의 폭, 그리고 구분선을 끌어 옮겼을 때 알려줄 콜백
  /// (표 왼쪽 끝에서 잰 새 경계 위치를 그대로 준다).
  final double titleW;
  final double otherW;
  final ValueChanged<double> onTitleWidthTo;

  /// 세로 목록의 컨트롤러 — 스크롤바는 바깥(TaskListTable)이 그린다.
  final ScrollController verticalController;

  /// "업무" 열 오른쪽 칸들의 가로 위치 — 머리글과 모든 줄이 이걸 따라 함께 움직인다.
  final ScrollController horizontalController;

  /// 구분선 손잡이의 절반 폭 — 얇은 선만으론 잡기 어려워서 좌우로 조금 넓게 잡는다.
  static const _handleHalf = 5.0;

  final Future<_ProjectOptions> Function(String projectId) optionsFor;
  final Future<void> Function(Future<void> Function()) apply;

  const _TaskTable({
    required this.tasks,
    required this.session,
    required this.onOpen,
    required this.titleW,
    required this.otherW,
    required this.onTitleWidthTo,
    required this.verticalController,
    required this.horizontalController,
    required this.optionsFor,
    required this.apply,
    this.readOnly = false,
    this.showProjectName = true,
    this.members,
    this.fields = const [],
  });

  /// "업무" 뒤에 늘 오는 열의 개수: 유형·우선순위·상태·시작일·마감일 + 사람 열.
  /// 사람 열은 프로젝트 "리스트"([members]가 있을 때)면 담당자·생성자·생성일, "내 업무"면 생성자.
  static int fixedColumns({required bool withMembers}) => withMembers ? 8 : 6;

  /// 더 줄일 수 없는 폭 — 여기까지 좁아지면 그 아래로는 가로 스크롤로 넘긴다.
  static const _minTitleW = 200.0;
  static const _minOtherW = 110.0;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    // 표의 가로/세로 구분선 — 테마 기본 구분선 색은 너무 옅어서 칸 경계가 잘 안 보인다.
    final border = _tableGridLine(context);
    final rows = arrangeWithSubtasks(tasks);
    Widget head(String text, {double? width}) {
      final child = Text(
        text,
        textAlign: width == null ? TextAlign.start : TextAlign.center,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: hint,
        ),
      );
      return width == null
          ? SizedBox(
              width: titleW,
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: child,
              ),
            )
          : SizedBox(width: width, child: child);
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Column(
            children: [
              Container(
                height: 36,
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: Row(
                  children: [
                    head(tr('업무')),
                    Expanded(
                      child: _HScrollWindow(
                        controller: horizontalController,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            head(tr('유형'), width: otherW),
                            head(tr('우선순위'), width: otherW),
                            head(tr('상태'), width: otherW),
                            head(tr('시작일'), width: otherW),
                            head(tr('마감일'), width: otherW),
                            if (members != null) ...[
                              head(tr('담당자'), width: otherW),
                              head(tr('생성자'), width: otherW),
                              head(tr('생성일'), width: otherW),
                            ] else
                              head(tr('생성자'), width: otherW),
                            for (final f in fields) head(f.name, width: otherW),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                // 스크롤바는 바깥(TaskListTable)에서 보이는 영역 끝에 그린다 — 여기서는 끈다.
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(
                    context,
                  ).copyWith(scrollbars: false),
                  // 줄 사이가 아니라 줄마다 아래에 선을 그린다 — 마지막 업무 아래에도
                  // 선이 남아서 표가 끝까지 칸으로 보인다.
                  child: ListView.builder(
                    controller: verticalController,
                    itemCount: rows.length,
                    itemBuilder: (context, i) => DecoratedBox(
                      // 줄 상태(배지의 메뉴·체크, 제목 고치기)가 자리가 아니라 그 업무를 따라가게 업무 id로 묶는다 —
                      // 다시 불러와 순서가 바뀌어도 다른 업무의 배지 상태를 이어받지 않는다.
                      key: ValueKey(rows[i].task.id),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: border)),
                      ),
                      child: _TaskTableRow(
                        task: rows[i].task,
                        indented: rows[i].indented,
                        session: session,
                        members: members,
                        fields: fields,
                        titleW: titleW,
                        otherW: otherW,
                        horizontalController: horizontalController,
                        readOnly: readOnly,
                        showProjectName: showProjectName,
                        optionsFor: optionsFor,
                        apply: apply,
                        onTap: () => onOpen(rows[i].task),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          // "업무"와 "유형" 사이의 구분선 — 끌어서 첫 열의 폭을 바꾼다.
          Positioned(
            left: titleW - _handleHalf,
            top: 0,
            bottom: 0,
            width: _handleHalf * 2,
            child: _ColumnResizeHandle(
              width: titleW,
              color: border,
              onChanged: onTitleWidthTo,
            ),
          ),
        ],
      ),
    );
  }
}

/// 열 사이의 구분선 손잡이 — 누른 순간의 폭과 위치를 기억해두고, 그 뒤로는 마우스가 움직인
/// 만큼만 더해서 새 폭을 알려준다.
///
/// 이 "누른 순간 기준"이 중요하다. Listener의 localPosition은 **누를 때** 잡힌 좌표계를
/// 그대로 쓰므로 끄는 동안 계속 커지는데, 여기에 매 프레임 새로 그려진(=이미 움직인) 폭을
/// 또 더하면 마우스보다 몇 배 빨리 달아난다. 반대로 이동량만 매번 더하면 한 프레임에 여러 번
/// 들어온 이동을 놓쳐서 느리게 따라온다 — 시작점을 고정해야 정확히 마우스를 따라온다.
///
/// GestureDetector가 아니라 Listener를 쓰는 이유: 표가 가로 스크롤 안에 있어서 가로 드래그
/// 제스처끼리 경합해 손잡이가 아니라 표가 스크롤돼 버린다.
class _ColumnResizeHandle extends StatefulWidget {
  final double width;
  final Color color;
  final ValueChanged<double> onChanged;
  const _ColumnResizeHandle({
    required this.width,
    required this.color,
    required this.onChanged,
  });

  @override
  State<_ColumnResizeHandle> createState() => _ColumnResizeHandleState();
}

class _ColumnResizeHandleState extends State<_ColumnResizeHandle> {
  double? _startWidth;
  double? _startX;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          _startWidth = widget.width;
          _startX = e.localPosition.dx;
        },
        onPointerMove: (e) {
          final startWidth = _startWidth;
          final startX = _startX;
          if (startWidth == null || startX == null) return;
          widget.onChanged(startWidth + (e.localPosition.dx - startX));
        },
        onPointerUp: (_) => _startWidth = _startX = null,
        onPointerCancel: (_) => _startWidth = _startX = null,
        child: Center(child: Container(width: 1, color: widget.color)),
      ),
    );
  }
}

/// 표 안에서 바로 바꿀 수 있는 배지 — 누르면 그 프로젝트가 정해둔 값들이 아래로 펼쳐진다.
/// 지금 값은 파랑 글씨 + 오른쪽 체크로 표시한다.
class _EditablePill extends StatefulWidget {
  /// 아직 안 고른 항목이면 null — 알약 대신 "—"로 보여준다(눌러서 고를 수 있는 건 그대로).
  final String? text;
  final Color color;
  final double menuWidth;

  /// 고를 수 있는 값들과, 그중 지금 값이 무엇인지. 옛 업무는 id가 비어 있을 수 있어서
  /// (같은 분류·단계의 첫 항목으로 본다) 목록을 받아와야 체크 위치를 알 수 있다.
  final Future<({List<_PillOption> options, String? currentId})> Function()
  loadOptions;
  final Future<void> Function(String? id) onPick;

  const _EditablePill({
    required this.text,
    required this.color,
    required this.menuWidth,
    required this.loadOptions,
    required this.onPick,
  });

  @override
  State<_EditablePill> createState() => _EditablePillState();
}

class _EditablePillState extends State<_EditablePill> {
  final _menu = MenuController();
  List<_PillOption>? _options;
  String? _currentId;
  bool _loading = false;

  /// 열 때마다 목록과 "지금 값"을 다시 읽는다 — 예전에는 처음 연 값을 계속 들고 있어서, 배지로 값을 바꾼 뒤
  /// 다시 열면 이전 값에 체크가 남아 있었다. 목록은 표가 프로젝트별로 기억해 두므로(_optionsFor) 다시 읽어도
  /// 서버를 다시 부르지 않고, 처음 한 번만 불러오는 동안 동그라미를 보인다.
  Future<void> _open() async {
    if (_menu.isOpen) {
      _menu.close();
      return;
    }
    if (_loading) return;
    if (_options == null) setState(() => _loading = true);
    try {
      final loaded = await widget.loadOptions();
      if (!mounted) return;
      setState(() {
        _options = loaded.options;
        _currentId = loaded.currentId;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showAppToast(context, tr('목록을 불러오지 못했습니다: {e}', {'e': e}));
      }
      return;
    }
    _menu.open();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MenuAnchor(
      controller: _menu,
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 4),
        ),
        backgroundColor: WidgetStatePropertyAll(theme.colorScheme.surface),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: theme.dividerColor),
          ),
        ),
      ),
      menuChildren: [
        for (final option in _options ?? const <_PillOption>[])
          SizedBox(
            width: widget.menuWidth,
            child: MenuItemButton(
              onPressed: () => widget.onPick(option.id),
              trailingIcon: option.id == _currentId
                  ? Icon(
                      Icons.check,
                      size: 16,
                      color: theme.colorScheme.primary,
                    )
                  : null,
              child: Text(
                option.name,
                style: TextStyle(
                  fontSize: 13,
                  color: option.id == _currentId
                      ? theme.colorScheme.primary
                      : null,
                ),
              ),
            ),
          ),
      ],
      builder: (context, controller, _) => InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: _open,
        child: _loading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : widget.text == null
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('—', style: TextStyle(color: theme.hintColor)),
              )
            : TaskPill(widget.text!, widget.color),
      ),
    );
  }
}

class TaskPill extends StatelessWidget {
  final String text;
  final Color color;
  const TaskPill(this.text, this.color, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _TaskTableRow extends StatefulWidget {
  final Task task;
  final Session session;
  final VoidCallback onTap;
  final List<AppUser>? members;
  final List<TaskFieldDef> fields;
  final double titleW;
  final double otherW;

  /// "업무" 열 오른쪽 칸들의 가로 위치(_TaskTable.horizontalController).
  final ScrollController horizontalController;

  /// 부모 바로 아래에 붙는 하위 업무면 한 칸 들여쓰고 앞에 ↳를 붙인다.
  final bool indented;
  final bool readOnly;
  final bool showProjectName;
  final Future<_ProjectOptions> Function(String projectId) optionsFor;
  final Future<void> Function(Future<void> Function()) apply;
  const _TaskTableRow({
    required this.task,
    required this.session,
    required this.onTap,
    required this.titleW,
    required this.otherW,
    required this.horizontalController,
    required this.optionsFor,
    required this.apply,
    this.indented = false,
    this.readOnly = false,
    this.showProjectName = true,
    this.members,
    this.fields = const [],
  });

  @override
  State<_TaskTableRow> createState() => _TaskTableRowState();
}

/// 표 한 줄의 제목 줄 높이(연필 버튼·제목 고치기 입력칸도 이 안에 들어간다).
const _titleLineHeight = 24.0;

class _TaskTableRowState extends State<_TaskTableRow> {
  /// 마우스가 업무 칸 위에 있는지 — 있을 때만 제목 옆에 연필이 보인다.
  bool _hovering = false;

  /// 제목을 고쳐 쓰는 중이면 그 입력 컨트롤러(아니면 null).
  TextEditingController? _editing;
  final _editFocus = FocusNode();

  Task get task => widget.task;
  Session get session => widget.session;
  bool get _showProject => widget.showProjectName && task.projectName != null;
  List<AppUser>? get members => widget.members;
  List<TaskFieldDef> get fields => widget.fields;
  double get otherW => widget.otherW;

  /// 보관한 업무는 표에서 바로 고칠 수 없다(업무 패널에서 "보관 해제"부터).
  bool get readOnly => widget.readOnly || widget.task.archived;
  VoidCallback get onTap => widget.onTap;
  Future<_ProjectOptions> Function(String) get optionsFor => widget.optionsFor;
  Future<void> Function(Future<void> Function()) get apply => widget.apply;

  @override
  void dispose() {
    _editing?.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  void _startEditing() {
    setState(() => _editing = TextEditingController(text: task.title));
    // 입력칸이 만들어진 다음에 포커스를 줘야 바로 글을 쓸 수 있다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editFocus.requestFocus();
    });
  }

  void _cancelEditing() {
    _editing?.dispose();
    setState(() => _editing = null);
  }

  Future<void> _commitTitle() async {
    final controller = _editing;
    if (controller == null) return;
    final title = controller.text.trim();
    _cancelEditing();
    if (title.isEmpty || title == task.title) return;
    await apply(() => session.api!.updateTask(task.id, title: title));
  }

  /// 날짜 칸에서 고른 날짜를 저장한다(null이면 비운다).
  Future<void> _saveDate(DateTime? picked, {required bool due}) => apply(
    () => session.api!.updateTask(
      task.id,
      startDate: due ? null : picked,
      clearStartDate: !due && picked == null,
      dueDate: due ? picked : null,
      clearDueDate: due && picked == null,
    ),
  );

  /// 날짜 칸 하나 — 읽기 전용이 아니면 눌러서 그 칸 아래에 달력을 펼친다.
  Widget _dateCell(Widget child, {required bool due}) => readOnly
      ? child
      : DateDropButton(
          value: due ? task.dueDate : task.startDate,
          onPicked: (picked) => _saveDate(picked, due: due),
          child: child,
        );

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final done = task.status == TaskStatus.done;
    final overdueDays = task.isOverdue ? -(task.daysUntilDue ?? 0) : 0;
    // 칸이 좁아 내용이 넘칠 때(긴 유형 이름, D+n 뱃지가 붙은 마감일 등)는 잘라내지 않고 줄여서 맞춘다.
    Widget cell(Widget child, double width) => SizedBox(
      width: width,
      child: Center(
        child: FittedBox(fit: BoxFit.scaleDown, child: child),
      ),
    );

    // 사람 열 — 프로젝트 리스트 보기([members]가 있을 때)는 담당자·생성자·생성일, "내 업무"는 생성자.
    final assignee = members?.where((m) => m.id == task.assigneeId).firstOrNull;
    final creator = task.creatorName == null
        ? null
        : AppUser(
            id: task.creatorId ?? '',
            username: task.creatorName!,
            name: task.creatorName!,
            avatarType: task.creatorAvatarType,
            avatarEmoji: task.creatorAvatarEmoji,
            avatarColor: task.creatorAvatarColor,
            avatarUrl: task.creatorAvatarUrl,
          );
    Widget personCell(AppUser? person) => person == null
        ? Text('—', style: TextStyle(color: hint))
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              UserAvatar(
                user: person,
                resolveUrl: session.resolveUrl,
                radius: 10,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  person.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: InkWell(
        onTap: _editing == null ? onTap : null,
        // InkWell은 자기 안의 무엇이든 포커스를 가지면 줄 전체를 포커스 색(회색)으로 칠한다. 배지 메뉴는
        // 이 줄 안에서 펼쳐져(MenuAnchor — OverlayPortal) 메뉴 항목이 마우스만 올려도 포커스를 가져가고, 닫힌
        // 뒤에도 포커스가 줄 안에 남아 다른 탭에 다녀올 때까지 회색이 지워지지 않았다. 제목 고치기 입력칸도 같다.
        focusColor: Colors.transparent,
        child: Padding(
          // 줄 높이 — 프로젝트 이름 줄이 있으면 위아래를 좁혀 두 줄이 한 칸에 촘촘히, 없으면 한
          // 줄을 가운데에 둔다(어느 쪽이든 약 46px).
          padding: EdgeInsets.symmetric(vertical: _showProject ? 4 : 11),
          // 보관한 업무는 줄 전체를 흐리게.
          child: Opacity(
            opacity: task.archived ? 0.45 : 1,
            child: Row(
              children: [
                SizedBox(
                  width: widget.titleW,
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: widget.indented ? 40 : 16,
                      right: 8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 줄 높이를 고정한다 — 마우스를 올렸을 때만 나오는 연필 때문에 줄이
                        // 커졌다 작아졌다 하면 아래 구분선들이 흔들린다.
                        SizedBox(
                          height: _titleLineHeight,
                          child: Row(
                            children: [
                              // 부모 바로 아래에 붙는 하위 업무 표시.
                              if (widget.indented) ...[
                                Icon(
                                  Icons.subdirectory_arrow_right,
                                  size: 14,
                                  color: hint,
                                ),
                                const SizedBox(width: 6),
                              ],
                              // 보관한 업무 표시(보관함 아이콘).
                              if (task.archived) ...[
                                Tooltip(
                                  message: tr('보관된 업무'),
                                  child: Icon(
                                    Icons.inventory_2_outlined,
                                    size: 14,
                                    color: hint,
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ],
                              if (task.key != null)
                                Text(
                                  task.key!,
                                  style: const TextStyle(
                                    color: Color(0xFF5B8DEF),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              if (task.myRole == 'reference') ...[
                                const SizedBox(width: 6),
                                TaskPill(tr('참조'), const Color(0xFF8E6BD9)),
                              ],
                              const SizedBox(width: 8),
                              if (_editing != null)
                                Expanded(
                                  child: TextField(
                                    controller: _editing,
                                    focusNode: _editFocus,
                                    autofocus: true,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                                    decoration: const InputDecoration(
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      border: OutlineInputBorder(),
                                    ),
                                    onSubmitted: (_) => _commitTitle(),
                                    onTapOutside: (_) => _commitTitle(),
                                  ),
                                )
                              else ...[
                                Flexible(
                                  child: Text(
                                    task.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      decoration: done
                                          ? TextDecoration.lineThrough
                                          : null,
                                      color: done ? hint : null,
                                    ),
                                  ),
                                ),
                                // 마우스를 올렸을 때만 보이는 연필 — 누르면 제목을 그 자리에서 고친다.
                                if (_hovering && !readOnly)
                                  IconButton(
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 16,
                                    ),
                                    tooltip: tr('제목 수정'),
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints.tightFor(
                                      width: 28,
                                      height: _titleLineHeight,
                                    ),
                                    onPressed: _startEditing,
                                  ),
                                const Spacer(),
                              ],
                            ],
                          ),
                        ),
                        if (_showProject)
                          Text(
                            task.projectName!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: hint,
                              fontSize: 11,
                              height: 1.3,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                // 유형·우선순위·상태는 배지를 눌러 그 자리에서 바꾼다(종료된 프로젝트는 제외).
                Expanded(
                  child: _HScrollWindow(
                    controller: widget.horizontalController,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        cell(
                          readOnly
                              ? (task.typeName == null
                                    ? Text('—', style: TextStyle(color: hint))
                                    : TaskPill(
                                        task.typeName!,
                                        parseTypeColor(task.typeColor),
                                      ))
                              : _EditablePill(
                                  text: task.typeName,
                                  color: parseTypeColor(task.typeColor),
                                  menuWidth: otherW,
                                  loadOptions: () async => (
                                    options: [
                                      _PillOption(null, tr('없음'), Colors.grey),
                                      for (final t in (await optionsFor(
                                        task.projectId,
                                      )).types)
                                        _PillOption(
                                          t.id,
                                          t.name,
                                          parseTypeColor(t.color),
                                        ),
                                    ],
                                    currentId: task.typeId,
                                  ),
                                  onPick: (id) => apply(
                                    () => session.api!.updateTask(
                                      task.id,
                                      typeId: id,
                                      clearType: id == null,
                                    ),
                                  ),
                                ),
                          otherW,
                        ),
                        cell(
                          readOnly
                              ? (task.priorityName == null
                                    ? Text('—', style: TextStyle(color: hint))
                                    : TaskPill(
                                        task.priorityName!,
                                        taskPriorityDisplayColor(task),
                                      ))
                              : _EditablePill(
                                  text: task.priorityName,
                                  color: taskPriorityDisplayColor(task),
                                  menuWidth: otherW,
                                  loadOptions: () async {
                                    final list = (await optionsFor(
                                      task.projectId,
                                    )).priorities;
                                    return (
                                      options: [
                                        for (final p in list)
                                          _PillOption(
                                            p.id,
                                            p.name,
                                            parseTypeColor(p.color),
                                          ),
                                      ],
                                      // 옛 업무는 priorityId가 비어 있다 — 같은 단계의 첫 항목으로 본다.
                                      currentId:
                                          list.any(
                                            (e) => e.id == task.priorityId,
                                          )
                                          ? task.priorityId
                                          : list
                                                .where(
                                                  (e) =>
                                                      e.level == task.priority,
                                                )
                                                .map((e) => e.id)
                                                .firstOrNull,
                                    );
                                  },
                                  onPick: (id) => apply(
                                    () => session.api!.updateTask(
                                      task.id,
                                      priorityId: id,
                                    ),
                                  ),
                                ),
                          otherW,
                        ),
                        cell(
                          readOnly
                              ? TaskPill(
                                  task.statusLabel,
                                  taskStatusDisplayColor(task),
                                )
                              : _EditablePill(
                                  text: task.statusLabel,
                                  color: taskStatusDisplayColor(task),
                                  menuWidth: otherW,
                                  loadOptions: () async {
                                    final list = (await optionsFor(
                                      task.projectId,
                                    )).statuses;
                                    return (
                                      options: [
                                        for (final s in list)
                                          _PillOption(
                                            s.id,
                                            s.name,
                                            parseTypeColor(s.color),
                                          ),
                                      ],
                                      // 옛 업무는 statusId가 비어 있다 — 같은 분류의 첫 상태로 본다.
                                      currentId:
                                          list.any((e) => e.id == task.statusId)
                                          ? task.statusId
                                          : list
                                                .where(
                                                  (e) =>
                                                      e.category == task.status,
                                                )
                                                .map((e) => e.id)
                                                .firstOrNull,
                                    );
                                  },
                                  onPick: (id) => apply(
                                    () => session.api!.updateTask(
                                      task.id,
                                      statusId: id,
                                    ),
                                  ),
                                ),
                          otherW,
                        ),
                        cell(
                          _dateCell(
                            Text(
                              task.startDate == null
                                  ? '—'
                                  : formatYmd(task.startDate!),
                              style: TextStyle(fontSize: 12, color: hint),
                            ),
                            due: false,
                          ),
                          otherW,
                        ),
                        cell(
                          _dateCell(
                            task.dueDate == null
                                ? Text('—', style: TextStyle(color: hint))
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        formatYmd(task.dueDate!),
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: task.isOverdue
                                              ? Colors.redAccent
                                              : hint,
                                        ),
                                      ),
                                      if (task.isOverdue) ...[
                                        const SizedBox(width: 6),
                                        TaskPill(
                                          'D+$overdueDays',
                                          Colors.redAccent,
                                        ),
                                      ],
                                    ],
                                  ),
                            due: true,
                          ),
                          otherW,
                        ),
                        if (members != null) ...[
                          cell(personCell(assignee), otherW),
                          cell(personCell(creator), otherW),
                          cell(
                            Text(
                              formatYmd(task.createdAt),
                              style: TextStyle(fontSize: 12, color: hint),
                            ),
                            otherW,
                          ),
                        ] else
                          cell(personCell(creator), otherW),
                        for (final f in fields)
                          cell(
                            Text(
                              f.display(task.customValues[f.id]) ?? '—',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: task.customValues[f.id] == null
                                    ? hint
                                    : null,
                              ),
                            ),
                            otherW,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 표에서 "업무" 열 오른쪽 칸들 — 가로로 넘치면 [controller]의 위치만큼 왼쪽으로 밀어서 그린다.
/// 머리글과 모든 줄이 같은 컨트롤러를 따라가므로 "업무" 열은 제자리에 있고 나머지만 좌우로
/// 움직인다. 넘친 부분은 잘라서(보이는 칸 밖은) 그리지 않는다.
class _HScrollWindow extends StatelessWidget {
  final ScrollController controller;
  final Widget child;
  const _HScrollWindow({required this.controller, required this.child});

  @override
  Widget build(BuildContext context) => UnconstrainedBox(
    constrainedAxis: Axis.vertical,
    alignment: Alignment.centerLeft,
    clipBehavior: Clip.hardEdge,
    child: ListenableBuilder(
      listenable: controller,
      builder: (context, child) => Transform.translate(
        offset: Offset(controller.hasClients ? -controller.offset : 0, 0),
        child: child,
      ),
      child: child,
    ),
  );
}

// ───────────────────────── 캘린더 부품 ─────────────────────────

class _Segment {
  final Task task;
  final int startCol;
  final int endCol;
  final bool continuesLeft;
  final bool continuesRight;
  int lane = 0;
  _Segment(
    this.task,
    this.startCol,
    this.endCol,
    this.continuesLeft,
    this.continuesRight,
  );
}

/// 캘린더 한 주(한 행) — 날짜 칸 위에 그 주에 걸친 업무를 막대로 얹는다. 여러 날에 걸친 업무는
/// 칸을 가로질러 하나의 막대로 보이고, 겹치는 막대는 위아래 줄(lane)로 나눈다.
class _WeekRow extends StatelessWidget {
  final List<DateTime> days;
  final List<Task> tasks;

  /// 월 보기에서 "이번 달"인 달(다른 달 날짜는 흐리게). 주 보기에서는 null.
  final int? month;
  final DateTime selected;
  final int maxLanes;
  final ValueChanged<DateTime> onSelectDay;
  final ValueChanged<Task> onOpenTask;
  final Color Function(Task) colorOf;

  const _WeekRow({
    required this.days,
    required this.tasks,
    required this.month,
    required this.selected,
    required this.maxLanes,
    required this.onSelectDay,
    required this.onOpenTask,
    required this.colorOf,
  });

  static const _dayHeader = 24.0;
  static const _barHeight = 18.0;
  static const _barGap = 2.0;

  List<_Segment> _segments() {
    final first = days.first;
    final last = days.last;
    final result = <_Segment>[];
    for (final t in tasks) {
      final range = taskRange(t)!;
      if (range.$2.isBefore(first) || range.$1.isAfter(last)) continue;
      final s = range.$1.isBefore(first) ? first : range.$1;
      final e = range.$2.isAfter(last) ? last : range.$2;
      result.add(
        _Segment(
          t,
          s.difference(first).inDays,
          e.difference(first).inDays,
          range.$1.isBefore(first),
          range.$2.isAfter(last),
        ),
      );
    }
    result.sort((a, b) {
      final c = a.startCol.compareTo(b.startCol);
      if (c != 0) return c;
      return (b.endCol - b.startCol).compareTo(a.endCol - a.startCol);
    });
    final laneEnds = <int>[];
    for (final seg in result) {
      var lane = laneEnds.indexWhere((end) => end < seg.startCol);
      if (lane == -1) {
        laneEnds.add(seg.endCol);
        lane = laneEnds.length - 1;
      } else {
        laneEnds[lane] = seg.endCol;
      }
      seg.lane = lane;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final border = Theme.of(context).dividerColor;
    final today = dateOnly(DateTime.now());
    final segments = _segments();

    return LayoutBuilder(
      builder: (context, constraints) {
        final colW = constraints.maxWidth / 7;
        // 칸 높이에 들어가는 만큼만 그린다(넘치는 건 "+n").
        final fit =
            ((constraints.maxHeight - _dayHeader - 14) / (_barHeight + _barGap))
                .floor();
        final lanes = math.max(1, math.min(maxLanes, fit));
        final hiddenPerDay = List<int>.filled(7, 0);
        for (final seg in segments) {
          if (seg.lane >= lanes) {
            for (var c = seg.startCol; c <= seg.endCol; c++) {
              hiddenPerDay[c]++;
            }
          }
        }

        return Stack(
          children: [
            Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: _DayCell(
                      date: days[i],
                      column: i,
                      dimmed: month != null && days[i].month != month,
                      isToday: days[i] == today,
                      isSelected: days[i] == selected,
                      hidden: hiddenPerDay[i],
                      border: border,
                      onTap: () => onSelectDay(days[i]),
                    ),
                  ),
              ],
            ),
            for (final seg in segments)
              if (seg.lane < lanes)
                Positioned(
                  left: seg.startCol * colW + (seg.continuesLeft ? 0 : 3),
                  top: _dayHeader + seg.lane * (_barHeight + _barGap),
                  width:
                      (seg.endCol - seg.startCol + 1) * colW -
                      (seg.continuesLeft ? 0 : 3) -
                      (seg.continuesRight ? 0 : 3),
                  height: _barHeight,
                  child: _TaskBar(
                    color: colorOf(seg.task),
                    task: seg.task,
                    roundLeft: !seg.continuesLeft,
                    roundRight: !seg.continuesRight,
                    onTap: () => onOpenTask(seg.task),
                  ),
                ),
          ],
        );
      },
    );
  }
}

class _DayCell extends StatelessWidget {
  final DateTime date;
  final int column;
  final bool dimmed;
  final bool isToday;
  final bool isSelected;
  final int hidden;
  final Color border;
  final VoidCallback onTap;
  const _DayCell({
    required this.date,
    required this.column,
    required this.dimmed,
    required this.isToday,
    required this.isSelected,
    required this.hidden,
    required this.border,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final hint = Theme.of(context).hintColor;
    final numColor = dimmed
        ? hint.withValues(alpha: 0.6)
        : (column == 0
              ? Colors.redAccent
              : (column == 6 ? Colors.blueAccent : null));
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: isSelected
              ? primary.withValues(alpha: 0.08)
              : (dimmed
                    ? Theme.of(context).colorScheme.surfaceContainerLow
                    : null),
          border: Border(
            right: BorderSide(color: border),
            bottom: BorderSide(color: border),
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              left: 6,
              top: 4,
              child: Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: isToday
                    ? BoxDecoration(color: primary, shape: BoxShape.circle)
                    : null,
                child: Text(
                  '${date.day}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isToday ? Colors.white : numColor,
                  ),
                ),
              ),
            ),
            if (hidden > 0)
              Positioned(
                right: 6,
                bottom: 2,
                child: Text(
                  '+$hidden',
                  style: TextStyle(fontSize: 10, color: hint),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TaskBar extends StatelessWidget {
  final Task task;
  final Color color;
  final bool roundLeft;
  final bool roundRight;
  final VoidCallback onTap;
  const _TaskBar({
    required this.task,
    required this.color,
    required this.roundLeft,
    required this.roundRight,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final done = task.status == TaskStatus.done;
    final color = done ? const Color(0xFF90A4AE) : this.color;
    return Tooltip(
      message: '${task.key ?? ''} ${task.title}'.trim(),
      child: InkWell(
        onTap: onTap,
        child: Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.22),
            borderRadius: BorderRadius.horizontal(
              left: Radius.circular(roundLeft ? 4 : 0),
              right: Radius.circular(roundRight ? 4 : 0),
            ),
          ),
          child: Text(
            task.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color.lerp(color, Colors.black, 0.45),
              decoration: done ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// 달력에서 고른 날의 업무 목록 — 날짜와 건수, 그 아래 업무마다 왼쪽 색 막대 · 제목 ·
/// 프로젝트 · 기간 · 담당자를 보여주고, 업무 사이는 얇은 실선으로 나눈다.
class _DayPanel extends StatelessWidget {
  final Color Function(Task) colorOf;
  final DateTime date;
  final List<Task> tasks;
  final Session? session;
  final ValueChanged<Task> onOpen;

  /// 목록과 스크롤바가 같이 쓰는 컨트롤러(달력 화면이 가진다).
  final ScrollController scroll;
  const _DayPanel({
    required this.colorOf,
    required this.date,
    required this.tasks,
    required this.session,
    required this.onOpen,
    required this.scroll,
  });

  Widget _item(BuildContext context, Task t) {
    final hint = Theme.of(context).hintColor;
    final r = taskRange(t)!;
    final done = t.status == TaskStatus.done;
    return InkWell(
      onTap: () => onOpen(t),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 업무 색(유형, 없으면 상태) 막대 — 내용 높이만큼.
              Container(
                width: 3,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: colorOf(t),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        decoration: done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    if (t.projectName != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        t.projectName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: hint),
                      ),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      r.$1 == r.$2
                          ? formatYmd(r.$1)
                          : '${formatYmd(r.$1)} ~ ${formatYmd(r.$2)}',
                      style: TextStyle(fontSize: 12, color: hint),
                    ),
                    const SizedBox(height: 8),
                    if (t.assigneeName == null)
                      Text(
                        tr('미배정'),
                        style: TextStyle(fontSize: 12, color: hint),
                      )
                    else
                      Row(
                        children: [
                          UserAvatar(
                            user: AppUser(
                              id: t.assigneeId ?? '',
                              username: t.assigneeName!,
                              name: t.assigneeName!,
                              avatarType: t.assigneeAvatarType,
                              avatarEmoji: t.assigneeAvatarEmoji,
                              avatarColor: t.assigneeAvatarColor,
                              avatarUrl: t.assigneeAvatarUrl,
                            ),
                            resolveUrl: session?.resolveUrl,
                            radius: 9,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              t.assigneeName!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${formatYmd(date)} (${kWeekdayLabels[date.weekday % 7]})',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 6),
          Text(
            tr('해당 일의 업무 {tasks.length}건', {'tasks.length': tasks.length}),
            style: TextStyle(color: hint, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: tasks.isEmpty
                ? Center(
                    child: Text(tr('업무가 없습니다.'), style: TextStyle(color: hint)),
                  )
                : MutedScrollbar(
                    controller: scroll,
                    child: ListView.separated(
                      controller: scroll,
                      padding: const EdgeInsets.only(right: 8),
                      itemCount: tasks.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 1,
                        thickness: 1,
                        color: theme.dividerColor,
                      ),
                      itemBuilder: (context, i) => _item(context, tasks[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
