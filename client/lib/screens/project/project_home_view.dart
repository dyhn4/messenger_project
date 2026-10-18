import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/muted_scrollbar.dart';
import '../../widgets/my_avatar.dart';
import 'project_forms.dart';
import 'project_widgets.dart';
import '../../l10n/tr.dart';

// intl의 DateFormat(..., 'ko')는 initializeDateFormatting()을 먼저 부르지 않으면
// LocaleDataException을 던진다(이 앱은 그 초기화를 어디서도 안 한다 — time_format.dart도
// 같은 이유로 전부 직접 문자열을 조립한다). 요일 이름 하나 때문에 앱 전체에 로케일 초기화를
// 추가하는 대신, 여기도 같은 관례를 따른다.
final _weekdayNames = [
  tr('월'),
  tr('화'),
  tr('수'),
  tr('목'),
  tr('금'),
  tr('토'),
  tr('일'),
];

String _formatGreetingDate(DateTime dt) {
  return tr('{dt.year}년 {dt.month}월 {dt.day}일 {p0}요일', {
    'dt.year': dt.year,
    'dt.month': dt.month,
    'dt.day': dt.day,
    'p0': _weekdayNames[dt.weekday - 1],
  });
}

/// 프로젝트 "홈" 대시보드 — 인사말/통계, 내가 참여한 프로젝트, 내가 담당한 업무,
/// 이번 주 나의 업무, 최근 댓글. 필요한 값은 GET /projects/home 한 번으로 받아온다.
class ProjectHomeView extends StatefulWidget {
  final Session session;
  final String teamId;

  /// 소켓으로 변경 알림이 올 때마다 부모가 +1 해준다 — 이 값이 바뀌면 다시 불러온다.
  final int reloadTick;
  final ValueChanged<String> onOpenProject;
  final VoidCallback onOpenMyTasks;

  /// "이번 주 나의 업무"의 "캘린더 ›".
  final VoidCallback? onOpenCalendar;

  const ProjectHomeView({
    super.key,
    required this.session,
    required this.teamId,
    required this.reloadTick,
    required this.onOpenProject,
    required this.onOpenMyTasks,
    this.onOpenCalendar,
  });

  @override
  State<ProjectHomeView> createState() => _ProjectHomeViewState();
}

class _ProjectHomeViewState extends State<ProjectHomeView> {
  ProjectHome? _home;
  String? _error;

  /// "이번 주 나의 업무"에서 고른 날짜(기본은 오늘) — 그날 진행 중인 업무를 보여준다.
  late DateTime _selectedDay = _dateOnly(DateTime.now());

  /// 프로젝트 목록을 다 펼쳤는지("모두 보기").
  bool _allProjects = false;

  final _weekScroll = ScrollController();

  /// 화면 전체 목록용 — 데스크톱에서는 ListView가 PrimaryScrollController에 안 붙어서, 컨트롤러
  /// 없이 스크롤바를 달면 디버그 모드에서 "ScrollPosition이 없다" 오류가 난다.
  final _scroll = ScrollController();

  @override
  void dispose() {
    _weekScroll.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// [day]에 진행 중인 업무인지 — 시작일(없으면 마감일)부터 마감일까지. 오늘이면 마감이 지났는데
  /// 아직 안 끝난 업무도 넣는다(오늘 챙겨야 하므로).
  bool _activeOn(Task t, DateTime day) {
    final due = t.dueDate == null ? null : _dateOnly(t.dueDate!);
    if (due == null) return false;
    final start = t.startDate == null ? due : _dateOnly(t.startDate!);
    if (!day.isBefore(start) && !day.isAfter(due)) return true;
    return day == _dateOnly(DateTime.now()) && t.isOverdue;
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ProjectHomeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadTick != widget.reloadTick) _load();
  }

  Future<void> _load() async {
    try {
      final home = await widget.session.api!.fetchProjectHome(widget.teamId);
      if (mounted) {
        setState(() {
          _home = home;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// 이번 주(월~일) 날짜 7개.
  List<DateTime> get _weekDays {
    final today = _dateOnly(DateTime.now());
    final monday = today.subtract(Duration(days: today.weekday - 1));
    return [for (var i = 0; i < 7; i++) monday.add(Duration(days: i))];
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final home = _home;
    if (home == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final myTasks = home.myTasks;
    final weekDays = _weekDays;
    final dayTasks = myTasks.where((t) => _activeOn(t, _selectedDay)).toList()
      ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
    final projects = _allProjects || home.projects.length <= 4
        ? home.projects
        : home.projects.take(4).toList();

    return MutedScrollbar(
      controller: _scroll,
      child: ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        children: [
          _buildGreeting(context, home),
          const SizedBox(height: 16),
          _buildStatsCard(context, home),
          const SizedBox(height: 16),
          // 넓으면 두 칸, 좁으면 한 칸으로 쌓는다.
          LayoutBuilder(
            builder: (context, constraints) {
              final left = [
                ProjectCard(
                  title: tr('내가 참여한 프로젝트'),
                  icon: Icons.assignment_outlined,
                  subtitle: tr('내가 참여 중인 프로젝트별 진행률을 확인할 수 있습니다.'),
                  actionLabel: home.projects.length > 4
                      ? (_allProjects ? tr('접기') : tr('모두 보기'))
                      : null,
                  onAction: () => setState(() => _allProjects = !_allProjects),
                  child: projects.isEmpty
                      ? EmptyHint(tr('참여 중인 프로젝트가 없습니다'))
                      : Column(
                          children: [
                            for (final project in projects)
                              _ProjectProgressRow(
                                project: project,
                                onTap: () => widget.onOpenProject(project.id),
                              ),
                          ],
                        ),
                ),
                const SizedBox(height: 20),
                ProjectCard(
                  title: tr('내가 담당한 업무'),
                  icon: Icons.assignment_turned_in_outlined,
                  count: myTasks.length,
                  subtitle: tr('내가 담당자로 지정된 업무를 진행 상황별로 확인할 수 있습니다.'),
                  child: myTasks.isEmpty
                      ? EmptyHint(tr('담당한 업무가 없습니다'))
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TaskRow.list([
                              for (final task in myTasks.take(5))
                                TaskRow(
                                  task: task,
                                  onTap: () => _openTask(task),
                                ),
                            ]),
                            if (myTasks.length > 5)
                              Center(
                                child: TextButton(
                                  onPressed: widget.onOpenMyTasks,
                                  style: TextButton.styleFrom(
                                    foregroundColor: Theme.of(
                                      context,
                                    ).hintColor,
                                    textStyle: const TextStyle(fontSize: 12),
                                  ),
                                  child: Text(tr('더보기')),
                                ),
                              ),
                          ],
                        ),
                ),
              ];
              final right = [
                ProjectCard(
                  title: tr('이번 주 나의 업무'),
                  icon: Icons.calendar_today_outlined,
                  subtitle: tr('이번 주 내가 담당한 업무를 날짜별로 확인할 수 있습니다.'),
                  actionLabel: widget.onOpenCalendar == null ? null : tr('캘린더'),
                  onAction: widget.onOpenCalendar,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _WeekStrip(
                        days: weekDays,
                        selected: _selectedDay,
                        hasTask: {
                          for (final day in weekDays)
                            day: myTasks.any((t) => _activeOn(t, day)),
                        },
                        onSelect: (day) => setState(() => _selectedDay = day),
                      ),
                      const SizedBox(height: 8),
                      if (dayTasks.isEmpty)
                        EmptyHint(tr('이 날짜에 진행 중인 업무가 없습니다'))
                      else
                        // 다섯 줄쯤 보이고 나머지는 이 안에서 스크롤.
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 310),
                          child: MutedScrollbar(
                            controller: _weekScroll,
                            child: SingleChildScrollView(
                              controller: _weekScroll,
                              padding: const EdgeInsets.only(right: 10),
                              child: TaskRow.list([
                                for (final task in dayTasks)
                                  TaskRow(
                                    task: task,
                                    onTap: () => _openTask(task),
                                  ),
                              ]),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                ProjectCard(
                  title: tr('최근 댓글'),
                  icon: Icons.chat_bubble_outline,
                  child: home.recentComments.isEmpty
                      ? Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: EmptyHint(tr('최근 댓글이 없습니다')),
                        )
                      : TaskRow.list([
                          for (final comment in home.recentComments.take(5))
                            _CommentRow(
                              comment: comment,
                              onTap: () => _openTaskById(comment.taskId),
                            ),
                        ]),
                ),
              ];

              if (constraints.maxWidth < 720) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [...left, const SizedBox(height: 20), ...right],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: left,
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: right,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _openTask(Task task) => _openTaskById(task.id);

  Future<void> _openTaskById(String taskId) async {
    await showTaskDetailDialog(context, widget.session, taskId);
    if (mounted) _load();
  }

  Widget _buildGreeting(BuildContext context, ProjectHome home) {
    final hint = Theme.of(context).hintColor;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('안녕하세요, {p0} 님', {'p0': widget.session.name ?? ''}),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                tr('오늘은 {p0}이에요. 오늘도 화이팅!', {
                  'p0': _formatGreetingDate(DateTime.now()),
                }),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: hint),
              ),
            ],
          ),
        ),
        FilledButton.icon(
          onPressed: home.projects.isEmpty ? null : () => _createTask(home),
          icon: const Icon(Icons.add, size: 18),
          label: Text(tr('새 업무')),
        ),
      ],
    );
  }

  Future<void> _createTask(ProjectHome home) async {
    final created = await showNewTaskDialog(
      context,
      widget.session,
      projects: home.projects,
    );
    if (created != null && mounted) _load();
  }

  Widget _buildStatsCard(BuildContext context, ProjectHome home) {
    final hint = Theme.of(context).hintColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Row(
        children: [
          MyAvatar(session: widget.session, radius: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.session.name ?? '',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  tr('완료율 {home.donePercent}%', {
                    'home.donePercent': home.donePercent,
                  }),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: hint),
                ),
              ],
            ),
          ),
          _Stat(value: home.total, label: tr('전체')),
          _Stat(value: home.done, label: tr('완료'), color: Colors.blue),
          _Stat(value: home.doing, label: tr('진행')),
          _Stat(
            value: home.overdue,
            label: tr('지연'),
            color: home.overdue > 0 ? Colors.redAccent : null,
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final int value;
  final String label;
  final Color? color;
  const _Stat({required this.value, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 20),
      child: Column(
        children: [
          Text(
            '$value',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).hintColor,
            ),
          ),
        ],
      ),
    );
  }
}

/// 프로젝트 한 줄 — 이름 + 프로젝트 색 진행률 막대 + 퍼센트 + 완료/전체.
class _ProjectProgressRow extends StatelessWidget {
  final Project project;
  final VoidCallback onTap;
  const _ProjectProgressRow({required this.project, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return InkWell(
      onTap: onTap,
      hoverColor: homeHoverColor(context),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 13),
        child: Row(
          children: [
            SizedBox(
              width: 122,
              child: Text(
                project.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: project.progress,
                  minHeight: 8,
                  color: parseTypeColor(project.color),
                  backgroundColor: theme.brightness == Brightness.dark
                      ? theme.colorScheme.surfaceContainerHighest
                      : const Color(0xFFF0F1F4),
                ),
              ),
            ),
            const SizedBox(width: 20),
            SizedBox(
              width: 40,
              child: Text(
                '${(project.progress * 100).round()}%',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            SizedBox(
              width: 50,
              child: Text(
                '${project.taskDone}/${project.taskTotal}',
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 12, color: hint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 이번 주 날짜 7개(월~일) — 둥근 회색 칸, 고른 날은 파란 칸. 업무가 있는 날은 아래에 점.
class _WeekStrip extends StatelessWidget {
  final List<DateTime> days;
  final DateTime selected;
  final Map<DateTime, bool> hasTask;
  final ValueChanged<DateTime> onSelect;
  const _WeekStrip({
    required this.days,
    required this.selected,
    required this.hasTask,
    required this.onSelect,
  });

  static final _weekdayNames = [
    tr('월'),
    tr('화'),
    tr('수'),
    tr('목'),
    tr('금'),
    tr('토'),
    tr('일'),
  ];
  static const _selectedColor = Color(0xFF7FB2F0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final dark = theme.brightness == Brightness.dark;
    return Row(
      children: [
        for (final day in days)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Material(
                color: day == selected
                    ? _selectedColor
                    : (dark
                          ? theme.colorScheme.surfaceContainerHighest
                          : const Color(0xFFF3F4F6)),
                elevation: day == selected ? 3 : 0,
                shadowColor: _selectedColor.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => onSelect(day),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Column(
                      children: [
                        Text(
                          _weekdayNames[day.weekday - 1],
                          style: TextStyle(
                            fontSize: 11,
                            color: day == selected ? Colors.white : hint,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${day.day}',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: day == selected ? Colors.white : null,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          width: 4,
                          height: 4,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: (hasTask[day] ?? false)
                                ? (day == selected
                                      ? Colors.white
                                      : _selectedColor)
                                : Colors.transparent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 최근 댓글 한 줄 — 댓글 글(두 줄까지) + (쓴 사람 · 업무 번호 · 업무 제목).
class _CommentRow extends StatelessWidget {
  final TaskComment comment;
  final VoidCallback onTap;
  const _CommentRow({required this.comment, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return InkWell(
      onTap: onTap,
      hoverColor: homeHoverColor(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              comment.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 4),
            Text(
              [
                comment.senderName,
                if (comment.taskKey != null) comment.taskKey!,
                if (comment.taskTitle != null) comment.taskTitle!,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: hint),
            ),
          ],
        ),
      ),
    );
  }
}
