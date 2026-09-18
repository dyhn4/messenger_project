import 'package:flutter/material.dart';

import '../../models/project.dart';

/// 대시보드의 카드 한 장(제목 + 설명 + 내용) — "내가 참여한 프로젝트", "최근 댓글" 등이 같이 쓴다.
class ProjectCard extends StatelessWidget {
  final String title;

  /// 제목 옆에 붙는 숫자(예: "내가 담당한 업무 31"). null이면 안 붙는다.
  final int? count;
  final String? subtitle;
  final Widget? action;
  final Widget child;

  const ProjectCard({
    super.key,
    required this.title,
    this.count,
    this.subtitle,
    this.action,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.assignment_outlined,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              if (count != null) ...[
                const SizedBox(width: 6),
                Text('$count', style: TextStyle(color: hint)),
              ],
              const Spacer(),
              ?action,
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: hint),
            ),
          ],
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// 카드 안의 "아직 없습니다" 안내 한 줄.
class EmptyHint extends StatelessWidget {
  final String text;
  const EmptyHint(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Text(text, style: TextStyle(color: Theme.of(context).hintColor)),
      ),
    );
  }
}

/// 업무 한 줄 — 제목 + (번호 · 프로젝트) + 오른쪽 D-day 뱃지. 목록 어디서나 같은 모양을 쓴다.
class TaskRow extends StatelessWidget {
  final Task task;
  final VoidCallback onTap;

  /// 프로젝트 안에서 볼 때는 프로젝트 이름이 중복이라 숨긴다.
  final bool showProject;

  const TaskRow({
    super.key,
    required this.task,
    required this.onTap,
    this.showProject = true,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final sub = [
      if (task.key != null) task.key!,
      if (showProject && task.projectName != null) task.projectName!,
    ].join(' · ');

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      decoration: task.status == TaskStatus.done
                          ? TextDecoration.lineThrough
                          : null,
                      color: task.status == TaskStatus.done ? hint : null,
                    ),
                  ),
                  if (sub.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.labelSmall?.copyWith(color: hint),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            DdayBadge(task: task),
          ],
        ),
      ),
    );
  }
}

/// 마감일까지 남은 날짜 뱃지(D-2 / D-DAY / D+1). 마감일이 없거나 이미 완료면 아무것도 안 그린다.
class DdayBadge extends StatelessWidget {
  final Task task;
  const DdayBadge({super.key, required this.task});

  @override
  Widget build(BuildContext context) {
    final days = task.daysUntilDue;
    if (days == null || task.status == TaskStatus.done) {
      return const SizedBox.shrink();
    }
    final label = days == 0
        ? 'D-DAY'
        : (days > 0 ? 'D-$days' : 'D+${-days}');
    // 지났으면 빨강, 오늘·내일이면 주황, 그 외에는 옅은 회색.
    final color = days < 0
        ? Colors.redAccent
        : (days <= 1 ? Colors.orange : Theme.of(context).hintColor);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 업무 상태 칩(할 일/진행 중/완료).
class TaskStatusChip extends StatelessWidget {
  final TaskStatus status;
  const TaskStatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      TaskStatus.todo => Theme.of(context).hintColor,
      TaskStatus.doing => Theme.of(context).colorScheme.primary,
      TaskStatus.done => Colors.green,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        taskStatusLabel(status),
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
