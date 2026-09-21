import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/floating_dialog.dart';
import '../../widgets/muted_scrollbar.dart';
import 'project_widgets.dart' show EmptyHint;

IconData projectNotificationIcon(String kind) => switch (kind) {
  'assigned' => Icons.assignment_ind_outlined,
  'referenced' => Icons.visibility_outlined,
  'comment' => Icons.mode_comment_outlined,
  'status' => Icons.swap_horiz,
  'due' => Icons.alarm,
  _ => Icons.notifications_none,
};

/// 프로젝트 알림함 — 업무 배정/참조/댓글/상태 변경/마감 임박 알림을 최근 순으로 보여준다.
/// 알림을 누르면 읽음 처리하고 [onOpen]으로 그 프로젝트/업무로 이동한다.
class ProjectNotificationsView extends StatefulWidget {
  final Session session;
  final int reloadTick;
  final void Function(ProjectNotification n) onOpen;

  const ProjectNotificationsView({
    super.key,
    required this.session,
    required this.reloadTick,
    required this.onOpen,
  });

  @override
  State<ProjectNotificationsView> createState() =>
      _ProjectNotificationsViewState();
}

class _ProjectNotificationsViewState extends State<ProjectNotificationsView> {
  List<ProjectNotification>? _items;
  String? _error;
  StreamSubscription<Map<String, dynamic>>? _sub;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
    // 이 화면을 보고 있는 동안 새 알림이 오면 바로 목록에 끼워 넣는다.
    _sub = widget.session.chatSocket.projectNotifications.listen(
      (_) => _load(),
    );
  }

  @override
  void didUpdateWidget(ProjectNotificationsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadTick != widget.reloadTick) _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final (items, _) = await widget.session.api!.fetchProjectNotifications();
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _open(ProjectNotification n) async {
    if (!n.read) {
      try {
        await widget.session.api!.markProjectNotificationsRead(ids: [n.id]);
        await _load();
      } catch (_) {
        // 읽음 표시가 실패해도 이동은 한다.
      }
    }
    widget.onOpen(n);
  }

  Future<void> _readAll() async {
    try {
      await widget.session.api!.markProjectNotificationsRead();
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, '읽음 처리하지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    final items = _items;
    if (items == null) return const Center(child: CircularProgressIndicator());
    final hint = Theme.of(context).hintColor;
    final hasUnread = items.any((n) => !n.read);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '알림',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: hasUnread ? _readAll : null,
                icon: const Icon(Icons.done_all, size: 18),
                label: const Text('모두 읽음'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: items.isEmpty
              ? const EmptyHint('받은 프로젝트 알림이 없습니다.')
              : MutedScrollbar(
                  controller: _scroll,
                  child: ListView.separated(
                    controller: _scroll,
                    padding: const EdgeInsets.only(right: 10),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final n = items[i];
                      return ListTile(
                        leading: CircleAvatar(
                          radius: 18,
                          backgroundColor: parseTypeColor(
                            n.projectColor,
                          ).withValues(alpha: 0.18),
                          child: Icon(
                            projectNotificationIcon(n.kind),
                            size: 18,
                            color: parseTypeColor(n.projectColor),
                          ),
                        ),
                        title: Text(
                          n.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: n.read
                                ? FontWeight.normal
                                : FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(
                          n.body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: n.read ? hint : null),
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              _ago(n.createdAt),
                              style: TextStyle(color: hint, fontSize: 11),
                            ),
                            if (!n.read)
                              Container(
                                margin: const EdgeInsets.only(top: 6),
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: Colors.redAccent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                        ),
                        onTap: () => _open(n),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return '방금';
  if (d.inHours < 1) return '${d.inMinutes}분 전';
  if (d.inDays < 1) return '${d.inHours}시간 전';
  if (d.inDays < 7) return '${d.inDays}일 전';
  return '${t.month}/${t.day}';
}

/// 이 프로젝트에서 내가 받을 알림을 고른다 — 나만의 설정이라 구성원이면 누구나 열 수 있다.
Future<void> showProjectNotificationSettingsDialog(
  BuildContext context,
  Session session,
  Project project,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _NotificationSettingsDialog(
      session: session,
      projectId: project.id,
      projectName: project.name,
    ),
  );
}

class _NotificationSettingsDialog extends StatefulWidget {
  final Session session;
  final String projectId;
  final String projectName;
  const _NotificationSettingsDialog({
    required this.session,
    required this.projectId,
    required this.projectName,
  });

  @override
  State<_NotificationSettingsDialog> createState() =>
      _NotificationSettingsDialogState();
}

class _NotificationSettingsDialogState
    extends State<_NotificationSettingsDialog> {
  ProjectNotificationSettings? _settings;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.session.api!
        .fetchProjectNotificationSettings(widget.projectId)
        .then((s) {
          if (mounted) setState(() => _settings = s);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e.toString());
        });
  }

  Future<void> _update({
    bool? muted,
    bool? assigned,
    bool? referenced,
    bool? comment,
    bool? status,
    bool? due,
  }) async {
    try {
      final s = await widget.session.api!.updateProjectNotificationSettings(
        widget.projectId,
        muted: muted,
        assigned: assigned,
        referenced: referenced,
        comment: comment,
        status: status,
        due: due,
      );
      if (mounted) setState(() => _settings = s);
    } catch (e) {
      if (mounted) showAppToast(context, '저장하지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    Widget row(String title, String sub, bool value, ValueChanged<bool> on) =>
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(title),
          subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
          value: value,
          onChanged: s?.muted == true ? null : on,
        );
    return FloatingDialog(
      title: '알림 설정 · ${widget.projectName}',
      maxWidth: 460,
      maxHeight: 560,
      child: _error != null
          ? Center(child: Text(_error!))
          : s == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('이 프로젝트 알림 끄기'),
                  subtitle: const Text(
                    '켜면 아래 알림을 모두 받지 않습니다.',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: s.muted,
                  onChanged: (v) => _update(muted: v),
                ),
                const Divider(),
                row(
                  '내게 업무 배정',
                  '누군가 나를 담당자로 지정했을 때',
                  s.assigned,
                  (v) => _update(assigned: v),
                ),
                row(
                  '참조자로 지정',
                  '누군가 나를 참조자로 추가했을 때',
                  s.referenced,
                  (v) => _update(referenced: v),
                ),
                row(
                  '댓글',
                  '내가 담당·생성·참조한 업무에 댓글이 달렸을 때',
                  s.comment,
                  (v) => _update(comment: v),
                ),
                row(
                  '상태 변경',
                  '내가 담당하거나 만든 업무의 상태가 바뀌었을 때',
                  s.status,
                  (v) => _update(status: v),
                ),
                row(
                  '마감 임박',
                  '내가 담당한 업무의 마감이 하루 앞으로 다가왔을 때',
                  s.due,
                  (v) => _update(due: v),
                ),
              ],
            ),
    );
  }
}
