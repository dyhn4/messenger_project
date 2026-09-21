import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/muted_scrollbar.dart';
import '../../widgets/my_avatar.dart';
import 'project_forms.dart';
import 'project_widgets.dart';

// intl의 DateFormat(..., 'ko')는 initializeDateFormatting()을 먼저 부르지 않으면
// LocaleDataException을 던진다(이 앱은 그 초기화를 어디서도 안 한다 — time_format.dart도
// 같은 이유로 전부 직접 문자열을 조립한다). 요일 이름 하나 때문에 앱 전체에 로케일 초기화를
// 추가하는 대신, 여기도 같은 관례를 따른다.
const _weekdayNames = ['월', '화', '수', '목', '금', '토', '일'];

String _formatGreetingDate(DateTime dt) {
  return '${dt.year}년 ${dt.month}월 ${dt.day}일 ${_weekdayNames[dt.weekday - 1]}요일';
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

  const ProjectHomeView({
    super.key,
    required this.session,
    required this.teamId,
    required this.reloadTick,
    required this.onOpenProject,
    required this.onOpenMyTasks,
  });

  @override
  State<ProjectHomeView> createState() => _ProjectHomeViewState();
}

class _ProjectHomeViewState extends State<ProjectHomeView> {
  ProjectHome? _home;
  String? _error;

  /// "이번 주 나의 업무"에서 고른 날짜(기본은 오늘) — 그날 마감인 업무만 보여준다.
  late DateTime _selectedDay = _dateOnly(DateTime.now());

  /// 프로젝트 목록을 다 펼쳤는지("모두 보기").
  bool _allProjects = false;

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
    final weekTasks = myTasks
        .where(
          (t) =>
              t.dueDate != null &&
              !_dateOnly(t.dueDate!).isBefore(weekDays.first) &&
              !_dateOnly(t.dueDate!).isAfter(weekDays.last),
        )
        .toList();
    final dayTasks = weekTasks
        .where((t) => _dateOnly(t.dueDate!) == _selectedDay)
        .toList();
    final projects = _allProjects || home.projects.length <= 4
        ? home.projects
        : home.projects.take(4).toList();

    return MutedScrollbar(
      child: ListView(
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
                  title: '내가 참여한 프로젝트',
                  subtitle: '내가 참여 중인 프로젝트별 진행률을 확인할 수 있습니다.',
                  action: home.projects.length > 4
                      ? TextButton(
                          onPressed: () =>
                              setState(() => _allProjects = !_allProjects),
                          child: Text(_allProjects ? '접기' : '모두 보기'),
                        )
                      : null,
                  child: projects.isEmpty
                      ? const EmptyHint('참여 중인 프로젝트가 없습니다')
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
                const SizedBox(height: 16),
                ProjectCard(
                  title: '내가 담당한 업무',
                  count: myTasks.length,
                  subtitle: '내가 담당자로 지정된 업무를 진행 상황별로 확인할 수 있습니다.',
                  child: myTasks.isEmpty
                      ? const EmptyHint('담당한 업무가 없습니다')
                      : Column(
                          children: [
                            for (final task in myTasks.take(5))
                              TaskRow(task: task, onTap: () => _openTask(task)),
                            if (myTasks.length > 5)
                              TextButton(
                                onPressed: widget.onOpenMyTasks,
                                child: const Text('더보기'),
                              ),
                          ],
                        ),
                ),
              ];
              final right = [
                ProjectCard(
                  title: '이번 주 나의 업무',
                  subtitle: '이번 주 내가 담당한 업무를 날짜별로 확인할 수 있습니다.',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _WeekStrip(
                        days: weekDays,
                        selected: _selectedDay,
                        hasTask: {
                          for (final day in weekDays)
                            day: weekTasks.any(
                              (t) => _dateOnly(t.dueDate!) == day,
                            ),
                        },
                        onSelect: (day) => setState(() => _selectedDay = day),
                      ),
                      const SizedBox(height: 8),
                      if (dayTasks.isEmpty)
                        const EmptyHint('이 날짜에 마감인 업무가 없습니다')
                      else
                        for (final task in dayTasks)
                          TaskRow(task: task, onTap: () => _openTask(task)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                ProjectCard(
                  title: '최근 댓글',
                  child: home.recentComments.isEmpty
                      ? const EmptyHint('최근 댓글이 없습니다')
                      : Column(
                          children: [
                            for (final comment in home.recentComments.take(5))
                              _CommentRow(
                                comment: comment,
                                onTap: () => _openTaskById(comment.taskId),
                              ),
                          ],
                        ),
                ),
              ];

              if (constraints.maxWidth < 720) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [...left, const SizedBox(height: 16), ...right],
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
                  const SizedBox(width: 16),
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
                '안녕하세요, ${widget.session.name ?? ''} 님',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '오늘은 ${_formatGreetingDate(DateTime.now())}이에요. 오늘도 화이팅!',
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
          label: const Text('새 업무'),
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
                  '완료율 ${home.donePercent}%',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: hint),
                ),
              ],
            ),
          ),
          _Stat(value: home.total, label: '전체'),
          _Stat(value: home.done, label: '완료', color: Colors.blue),
          _Stat(value: home.doing, label: '진행'),
          _Stat(
            value: home.overdue,
            label: '지연',
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

/// 프로젝트 한 줄 — 이름 + 진행률 막대 + 완료/전체.
class _ProjectProgressRow extends StatelessWidget {
  final Project project;
  final VoidCallback onTap;
  const _ProjectProgressRow({required this.project, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 120,
              child: Text(
                project.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: project.progress,
                  minHeight: 6,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest,
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 38,
              child: Text(
                '${(project.progress * 100).round()}%',
                textAlign: TextAlign.right,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            SizedBox(
              width: 48,
              child: Text(
                '${project.taskDone}/${project.taskTotal}',
                textAlign: TextAlign.right,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: hint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 이번 주 날짜 7개(월~일) — 업무가 있는 날은 아래에 점이 찍힌다.
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

  static const _weekdayNames = ['월', '화', '수', '목', '금', '토', '일'];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (final day in days)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => onSelect(day),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: day == selected
                        ? colors.primary
                        : colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: [
                      Text(
                        _weekdayNames[day.weekday - 1],
                        style: TextStyle(
                          fontSize: 11,
                          color: day == selected ? colors.onPrimary : null,
                        ),
                      ),
                      Text(
                        '${day.day}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: day == selected ? colors.onPrimary : null,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: (hasTask[day] ?? false)
                              ? (day == selected
                                    ? colors.onPrimary
                                    : colors.primary)
                              : Colors.transparent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _CommentRow extends StatelessWidget {
  final TaskComment comment;
  final VoidCallback onTap;
  const _CommentRow({required this.comment, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              comment.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 2),
            Text(
              [
                comment.senderName,
                if (comment.taskKey != null) comment.taskKey!,
                if (comment.taskTitle != null) comment.taskTitle!,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: hint),
            ),
          ],
        ),
      ),
    );
  }
}
