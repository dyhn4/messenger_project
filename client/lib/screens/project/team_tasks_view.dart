import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import 'project_forms.dart';
import 'gantt_chart_view.dart';
import 'task_views.dart';

/// 사이드바 "캘린더" / "간트차트" — 내가 참여 중인 모든 프로젝트의 업무를 한 화면에서 본다
/// (프로젝트 하나 안에서 보는 같은 이름의 보기와 같은 위젯을 쓴다).
class TeamTasksView extends StatefulWidget {
  final Session session;
  final String teamId;
  final int reloadTick;

  /// true면 간트차트, false면 캘린더.
  final bool gantt;

  const TeamTasksView({
    super.key,
    required this.session,
    required this.teamId,
    required this.reloadTick,
    required this.gantt,
  });

  @override
  State<TeamTasksView> createState() => _TeamTasksViewState();
}

class _TeamTasksViewState extends State<TeamTasksView> {
  List<Task>? _tasks;
  String? _error;

  /// 프로젝트 id → 프로젝트 색(캘린더 막대 색).
  Map<String, Color> _projectColors = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(TeamTasksView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadTick != widget.reloadTick) _load();
  }

  Future<void> _load() async {
    try {
      final api = widget.session.api!;
      final results = await Future.wait([
        api.fetchTeamTasks(widget.teamId),
        api.fetchProjects(widget.teamId),
      ]);
      if (mounted) {
        setState(() {
          _tasks = results[0] as List<Task>;
          _projectColors = {
            for (final p in results[1] as List<Project>)
              p.id: parseTypeColor(p.color),
          };
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

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final tasks = _tasks;
    if (tasks == null) return const Center(child: CircularProgressIndicator());
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // "내 업무" 화면과 같은 크기의 제목.
              Text(
                widget.gantt ? '간트차트' : '캘린더',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.gantt
                    ? '프로젝트별 업무 일정을 확인합니다. 막대를 드래그하면 일정을 수정할 수 있습니다.'
                    : '참여 중인 모든 프로젝트의 업무 일정을 날짜별로 봅니다.',
                style: TextStyle(color: hint),
              ),
            ],
          ),
        ),
        if (!widget.gantt) ...[
          const SizedBox(height: 12),
          const Divider(height: 1),
        ],
        Expanded(
          child: widget.gantt
              ? GanttChartView(
                  session: widget.session,
                  teamId: widget.teamId,
                  prefsKey: 'team',
                  tasks: tasks,
                  onOpen: _openTask,
                  onChanged: _load,
                )
              : TaskCalendarView(
                  tasks: tasks,
                  onOpen: _openTask,
                  session: widget.session,
                  projectColors: _projectColors,
                ),
        ),
      ],
    );
  }
}
