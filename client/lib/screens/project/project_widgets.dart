import 'package:flutter/material.dart';

import '../../models/project.dart';

/// 홈 카드의 파란 글자·아이콘 색.
const homeAccent = Color(0xFF3B82F6);

/// 홈 카드의 줄(프로젝트·업무·댓글)에 마우스를 올렸을 때 칠하는 회색.
Color homeHoverColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06)
    : const Color(0xFFF3F4F6);

/// 대시보드의 카드 한 장 — 왼쪽 위 옅은 파란 네모 안 아이콘 + 굵은 제목(+ 개수), 아래 회색 설명,
/// 오른쪽 위 "모두 보기 ›" 같은 링크. "내가 참여한 프로젝트", "최근 댓글" 등이 같이 쓴다.
class ProjectCard extends StatelessWidget {
  final String title;
  final IconData icon;

  /// 제목 옆에 붙는 숫자(예: "내가 담당한 업무 31"). null이면 안 붙는다.
  final int? count;
  final String? subtitle;

  /// 오른쪽 위 파란 링크 글자(예: "모두 보기") — [onAction]과 같이 준다.
  final String? actionLabel;
  final VoidCallback? onAction;
  final Widget child;

  const ProjectCard({
    super.key,
    required this.title,
    this.icon = Icons.assignment_outlined,
    this.count,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: dark ? theme.dividerColor : const Color(0xFFE6E8EC),
        ),
        boxShadow: dark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      // 줄의 마우스 호버 음영(InkWell)은 가장 가까운 Material 위에 그려진다 — 카드 바탕색보다 위에
      // 보이도록 투명한 Material을 한 겹 깐다(없으면 카드 밑 화면에 그려져 가려진다).
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: homeAccent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 16, color: homeAccent),
                ),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (count != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: hint,
                    ),
                  ),
                ],
                const Spacer(),
                if (actionLabel != null)
                  InkWell(
                    onTap: onAction,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            actionLabel!,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: homeAccent,
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right,
                            size: 16,
                            color: homeAccent,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(subtitle!, style: TextStyle(fontSize: 12, color: hint)),
            ],
            const SizedBox(height: 12),
            child,
          ],
        ),
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
/// 줄 사이 구분선은 [TaskRow.list]가 넣는다.
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

  /// 줄들 사이에 얇은 구분선을 넣은 목록.
  static Widget list(List<Widget> rows) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (i, row) in rows.indexed) ...[
        if (i > 0) const Divider(height: 1, thickness: 1),
        row,
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final sub = [
      if (task.key != null) task.key!,
      if (showProject && task.projectName != null) task.projectName!,
    ].join(' · ');

    return InkWell(
      onTap: onTap,
      hoverColor: homeHoverColor(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 10),
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
                      fontSize: 14,
                      decoration: task.status == TaskStatus.done
                          ? TextDecoration.lineThrough
                          : null,
                      color: task.status == TaskStatus.done ? hint : null,
                    ),
                  ),
                  if (sub.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: hint),
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
    final label = days == 0 ? 'D-DAY' : (days > 0 ? 'D-$days' : 'D+${-days}');
    // 지났으면 빨강, 일주일 안이면 주황, 그보다 멀면 옅은 회색.
    final color = days < 0
        ? const Color(0xFFEF4444)
        : (days <= 7 ? const Color(0xFFF59E0B) : Theme.of(context).hintColor);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
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
