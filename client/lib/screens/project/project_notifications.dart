import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/muted_scrollbar.dart';

IconData projectNotificationIcon(String kind) => switch (kind) {
  'assigned' => Icons.assignment_ind_outlined,
  'referenced' => Icons.visibility_outlined,
  'comment' => Icons.mode_comment_outlined,
  'status' => Icons.swap_horiz,
  'due' => Icons.alarm,
  'created' => Icons.add_task,
  'deleted' => Icons.delete_outline,
  // 공개 프로젝트가 새로 생겼다는 알림 — 업무가 아니라 프로젝트 자체를 가리킨다.
  'project_created' => Icons.rocket_launch_outlined,
  _ => Icons.notifications_none,
};

/// 상단 알림 종 — 안 읽은 개수를 배지로 보여주고, 누르면 아래로 알림 목록이 펼쳐진다.
/// 항목을 누르면 읽음 처리한 뒤 [onOpen]으로 넘겨서 그 프로젝트/업무로 이동한다.
class ProjectNotificationsBell extends StatefulWidget {
  final Session session;
  final void Function(ProjectNotification n) onOpen;

  /// 있으면 팝업 머리글에 "알림 센터에서 보기"가 붙는다 — 알림 센터의 "프로젝트" 탭은 이 알림함과 같은 내용이다
  /// (진입점은 둘, 화면은 하나). 프로젝트가 별도 OS 창으로 뜨는 Windows에서는 메인 창의 알림 센터를 이 창에서
  /// 열 수 없어서 주지 않는다.
  final VoidCallback? onOpenCenter;

  const ProjectNotificationsBell({
    super.key,
    required this.session,
    required this.onOpen,
    this.onOpenCenter,
  });

  @override
  State<ProjectNotificationsBell> createState() =>
      _ProjectNotificationsBellState();
}

class _ProjectNotificationsBellState extends State<ProjectNotificationsBell> {
  final _menu = MenuController();
  // 메뉴 패널 자체도 스크롤 뷰라, 목록이 기본(Primary) 컨트롤러를 같이 쓰면
  // "한 컨트롤러에 스크롤 위치가 여럿"이라는 오류가 난다 — 목록은 자기 컨트롤러를 쓴다.
  final _listScroll = ScrollController();
  List<ProjectNotification>? _items;
  String? _error;
  StreamSubscription<Map<String, dynamic>>? _sub;

  /// 펼쳐 둔 동안 새 알림이 오면 목록도 따라 갱신한다.
  @override
  void initState() {
    super.initState();
    _sub = widget.session.chatSocket.projectNotifications.listen((_) {
      if (_menu.isOpen) _load();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _listScroll.dispose();
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
    _menu.close();
    if (!n.read) {
      try {
        await widget.session.api!.markProjectNotificationsRead(ids: [n.id]);
        await widget.session.refreshProjectUnread();
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
      await widget.session.refreshProjectUnread();
    } catch (e) {
      if (mounted) showAppToast(context, '읽음 처리하지 못했습니다: $e');
    }
  }

  Widget _tile(BuildContext context, ProjectNotification n) =>
      ProjectNotificationTile(notification: n, onTap: () => _open(n));

  Widget _panel(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final items = _items;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
          child: Row(
            children: [
              const Text(
                '알림',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              const Spacer(),
              if (widget.onOpenCenter != null)
                TextButton(
                  key: const ValueKey('project-bell-open-center'),
                  onPressed: () {
                    _menu.close();
                    widget.onOpenCenter!();
                  },
                  child: const Text('알림 센터에서 보기'),
                ),
              if (items != null && items.any((n) => !n.read))
                TextButton(onPressed: _readAll, child: const Text('모두 읽음')),
            ],
          ),
        ),
        const Divider(height: 1),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Center(child: Text(_error!)),
          )
        else if (items == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: Text('알림이 없습니다', style: TextStyle(color: hint)),
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            // 메뉴 패널은 내용의 고유 너비를 재는데 ListView는 그걸 지원하지 않아서
            // (RenderShrinkWrappingViewport), 스크롤은 되지만 크기를 잴 수 있는 쪽을 쓴다.
            child: SingleChildScrollView(
              controller: _listScroll,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < items.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _tile(context, items[i]),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: _menu,
      // 종 버튼(48) 아래에 패널(400)의 오른쪽 끝을 맞춘다.
      alignmentOffset: const Offset(-352, 6),
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
      menuChildren: [SizedBox(width: 400, child: _panel(context))],
      builder: (context, controller, _) => ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) => IconButton(
          tooltip: '알림',
          icon: Badge(
            isLabelVisible: widget.session.projectUnread > 0,
            backgroundColor: Colors.redAccent,
            label: Text('${widget.session.projectUnread}'),
            child: const Icon(Icons.notifications_none),
          ),
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              _load();
              controller.open();
            }
          },
        ),
      ),
    );
  }
}

/// "방금 / N분 전 / N시간 전 / N일 전 / M/D" — 프로젝트 알림 줄의 시각 표시(알림 센터의 프로젝트 탭도 쓴다).
String projectNotificationAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return '방금';
  if (d.inHours < 1) return '${d.inMinutes}분 전';
  if (d.inDays < 1) return '${d.inHours}시간 전';
  if (d.inDays < 7) return '${d.inDays}일 전';
  return '${t.month}/${t.day}';
}

/// 프로젝트 알림 한 줄 — 종 팝업(ProjectNotificationsBell)과 알림 센터의 "프로젝트" 탭이 같은 모양으로 쓴다
/// (진입점은 둘이어도 보이는 내용은 하나).
class ProjectNotificationTile extends StatelessWidget {
  final ProjectNotification notification;
  final VoidCallback onTap;
  const ProjectNotificationTile({
    super.key,
    required this.notification,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final n = notification;
    final hint = Theme.of(context).hintColor;
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: parseTypeColor(n.projectColor).withValues(alpha: 0.18),
        child: Icon(
          projectNotificationIcon(n.kind),
          size: 16,
          color: parseTypeColor(n.projectColor),
        ),
      ),
      title: Text(
        // 제목이 비어 오면(모르는 종류 등) 프로젝트 이름으로 대신한다.
        n.title.isNotEmpty ? n.title : (n.projectName ?? '프로젝트'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontWeight: n.read ? FontWeight.normal : FontWeight.bold,
        ),
      ),
      subtitle: Text(
        n.body,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: n.read ? hint : null),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            projectNotificationAgo(n.createdAt),
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
      onTap: onTap,
    );
  }
}

/// "프로젝트 메뉴 > 알림" — 여기서 정한 정책은 이 프로젝트의 **모든 멤버**에게 적용된다.
/// 정책은 프로젝트 담당자와 팀 소유자·관리자만 바꿀 수 있고(서버도 다시 확인한다), 그 아래
/// "내 설정"은 각자 자기 알림만 끄는 값이다.
class ProjectNotificationSettingsEditor extends StatefulWidget {
  final Session session;
  final String projectId;

  /// 정책을 바꿀 수 있는 사람인지 — 아니면 읽기만 된다.
  final bool canManage;

  const ProjectNotificationSettingsEditor({
    super.key,
    required this.session,
    required this.projectId,
    this.canManage = false,
  });

  @override
  State<ProjectNotificationSettingsEditor> createState() =>
      _ProjectNotificationSettingsEditorState();
}

class _ProjectNotificationSettingsEditorState
    extends State<ProjectNotificationSettingsEditor> {
  ProjectNotificationPolicy? _policy;
  ProjectNotificationSettings? _mine;
  String? _error;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final api = widget.session.api!;
      final policy = await api.fetchProjectNotificationPolicy(widget.projectId);
      final mine = await api.fetchProjectNotificationSettings(widget.projectId);
      if (mounted) {
        setState(() {
          _policy = policy;
          _mine = mine;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _setPolicy(String key, bool value) async {
    try {
      final p = await widget.session.api!.setProjectNotificationPolicy(
        widget.projectId,
        key,
        value,
      );
      if (mounted) setState(() => _policy = p);
    } catch (e) {
      if (mounted) showAppToast(context, '저장하지 못했습니다: $e');
    }
  }

  Future<void> _setMuted(bool value) async {
    try {
      final m = await widget.session.api!.setProjectNotificationMuted(
        widget.projectId,
        value,
      );
      if (mounted) setState(() => _mine = m);
    } catch (e) {
      if (mounted) showAppToast(context, '저장하지 못했습니다: $e');
    }
  }

  Widget _card(
    BuildContext context,
    String title,
    String desc,
    List<Widget> rows,
  ) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(desc, style: TextStyle(color: theme.hintColor, fontSize: 12)),
          const SizedBox(height: 6),
          ...rows,
        ],
      ),
    );
  }

  Widget _row(String key, String title, {String? sub}) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    dense: true,
    title: Text(title),
    subtitle: sub == null
        ? null
        : Text(sub, style: const TextStyle(fontSize: 12)),
    value: _policy!.valueOf(key),
    onChanged: widget.canManage ? (v) => _setPolicy(key, v) : null,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_error != null) return Center(child: Text(_error!));
    if (_policy == null || _mine == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return MutedScrollbar(
      controller: _scroll,
      child: ListView(
        controller: _scroll,
        padding: const EdgeInsets.only(right: 12),
        children: [
          Text(
            widget.canManage
                ? '여기서 설정한 알림 정책은 이 프로젝트의 모든 멤버에게 적용됩니다.'
                : '이 프로젝트의 알림 정책입니다. 바꾸려면 프로젝트 담당자나 팀 관리자여야 합니다.',
            style: TextStyle(color: theme.hintColor, fontSize: 12),
          ),
          const SizedBox(height: 12),
          _card(context, '업무 변경 알림', '업무 항목이 바뀌면 담당자·참조자에게 알림을 보냅니다.', [
            _row('status', '상태 변경'),
            _row('priority', '우선순위 변경'),
            _row('assigned', '담당자 변경'),
            _row('referenced', '참조자 지정'),
            _row('dueDate', '마감일 변경'),
            _row('taskType', '유형 변경'),
            _row('customField', '사용자 정의 필드 변경'),
          ]),
          _card(context, '업무 생성/삭제 알림', '업무가 생성되거나 삭제될 때 알림을 보냅니다.', [
            _row('created', '업무 생성', sub: '새 업무가 만들어지면 프로젝트 담당자에게 알림'),
            _row('deleted', '업무 삭제', sub: '업무가 삭제되면 프로젝트 담당자와 그 업무의 담당자에게 알림'),
          ]),
          _card(context, '댓글 알림', '댓글 관련 알림입니다.', [
            _row('comment', '댓글 작성', sub: '댓글이 작성되면 업무 담당자·생성자·참조자에게 알림'),
          ]),
          _card(context, '마감 알림', '마감이 다가오면 알림을 보냅니다.', [
            _row('due', '마감 임박', sub: '담당한 업무의 마감 하루 전에 알림'),
          ]),
          _card(context, '내 설정', '나에게만 적용됩니다(정책과 별개).', [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('이 프로젝트 알림 끄기'),
              subtitle: const Text(
                '켜면 위 정책과 상관없이 내게는 알림이 오지 않습니다.',
                style: TextStyle(fontSize: 12),
              ),
              value: _mine!.muted,
              onChanged: _setMuted,
            ),
          ]),
        ],
      ),
    );
  }
}
