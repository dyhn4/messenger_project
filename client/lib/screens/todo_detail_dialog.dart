import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../models/todo.dart';
import '../services/session.dart';
import '../services/todo_api.dart';
import '../widgets/app_toast.dart';
import '../widgets/attachment_widgets.dart'
    show ChatFileAttachments, ChatImageAttachments;
import '../widgets/user_avatar.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'todo_editor_dialog.dart';

/// 진척률 단추로 고를 수 있는 값.
const todoProgressSteps = [0, 25, 50, 75, 100];

/// 방을 여는 손잡이 — 패널이 자기 context로 만든다(대화상자 안의 context로는 홈 화면을 못 찾는다).
typedef TodoOpenRoom = void Function(Room room, {String? messageId});

/// 할 일 상세를 연다 — 넓은 창(PC)은 대화상자, 좁은 창(모바일)은 전체 화면. 열려 있는 동안 서버가 바꾸거나 지우면
/// (소켓 todo:changed) 스스로 다시 받아 그리고, 지워졌으면 닫는다. 내가 고치거나 지우거나 진척률을 바꿨으면 true를
/// 돌려준다(목록이 다시 받는다).
///
/// [onOpenRoom]은 대화방 칸·"원본 메시지 보기"를 눌렀을 때 그 방을 여는 손잡이 — 없으면 그 단추들은 안 보인다.
/// [api]·[changed]는 테스트가 가짜를 끼우는 자리.
Future<bool> showTodoDetail(
  BuildContext context, {
  required Session session,
  required Todo todo,
  TodoOpenRoom? onOpenRoom,
  TodoApi? api,
  Stream<Map<String, dynamic>>? changed,
}) async {
  final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  final detail = TodoDetail(
    session: session,
    todo: todo,
    onOpenRoom: onOpenRoom,
    api: api,
    changed: changed,
    asDialog: wide,
  );
  final changedSomething = wide
      ? await showDialog<bool>(context: context, builder: (_) => detail)
      : await Navigator.of(
          context,
        ).push<bool>(MaterialPageRoute(builder: (_) => detail));
  return changedSomething ?? false;
}

/// 할 일 상세(대화상자/전체 화면 공용) — 제목, 상태·진척률(조절은 만든 사람·담당자), 설명, 기간, 담당자, 대화방,
/// 첨부, 알림 일정, 만든 사람·시각, 원본 메시지. 오른쪽 위 ⋯에서 수정(만든 사람·담당자)·삭제(만든 사람).
class TodoDetail extends StatefulWidget {
  final Session session;
  final Todo todo;
  final TodoOpenRoom? onOpenRoom;
  final TodoApi? api;
  final Stream<Map<String, dynamic>>? changed;
  final bool asDialog;

  const TodoDetail({
    super.key,
    required this.session,
    required this.todo,
    this.onOpenRoom,
    this.api,
    this.changed,
    this.asDialog = true,
  });

  @override
  State<TodoDetail> createState() => _TodoDetailState();
}

class _TodoDetailState extends State<TodoDetail> {
  late final TodoApi _api = widget.api ?? widget.session.todoApi;
  late Todo _todo = widget.todo;
  bool _busy = false;
  bool _changed = false;

  /// 내가 지우는 중이면 소켓 deleted를 따로 처리하지 않는다(창을 두 번 닫지 않게).
  bool _deleting = false;
  StreamSubscription<Map<String, dynamic>>? _sub;

  @override
  void initState() {
    super.initState();
    final stream = widget.changed ?? widget.session.chatSocket.todoChanged;
    _sub = stream.listen((e) {
      if (e['todoId'] != _todo.id || _deleting) return;
      if (e['kind'] == 'deleted') {
        if (!mounted) return;
        showAppToast(context, '이 할 일이 삭제되었습니다.');
        Navigator.of(context).pop(true);
        return;
      }
      unawaited(_reload());
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final fresh = await _api.get(_todo.id);
      if (mounted) setState(() => _todo = fresh);
    } catch (_) {
      // 다시 받지 못해도 지금 화면은 그대로 둔다.
    }
  }

  Room? get _room =>
      widget.session.rooms.where((r) => r.id == _todo.roomId).firstOrNull;

  Future<void> _setProgress(int progress) async {
    if (_busy || !_todo.canEdit || progress == _todo.progress) return;
    setState(() => _busy = true);
    try {
      final updated = await _api.update(_todo.id, {'progress': progress});
      if (!mounted) return;
      setState(() {
        _todo = updated;
        _changed = true;
      });
    } catch (e) {
      if (mounted) showAppToast(context, '진척률을 바꾸지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit() async {
    final updated = await showTodoEditor(
      context,
      session: widget.session,
      editing: _todo,
      api: _api,
    );
    if (updated == null || !mounted) return;
    setState(() {
      _todo = updated;
      _changed = true;
    });
    showAppToast(context, '할 일을 수정했습니다.');
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('할 일 삭제'),
        content: Text('"${_todo.title}" 할 일을 삭제할까요?\n삭제하면 되돌릴 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('todo-confirm-delete'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final overlay = Overlay.of(context);
    _deleting = true;
    try {
      await _api.delete(_todo.id);
      showAppToastOnOverlay(overlay, '할 일을 삭제했습니다.');
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _deleting = false;
      if (mounted) showAppToast(context, '할 일을 삭제하지 못했습니다: $e');
    }
  }

  void _openRoom({String? messageId}) {
    final room = _room;
    final open = widget.onOpenRoom;
    if (room == null || open == null) return;
    Navigator.of(context).pop(_changed);
    open(room, messageId: messageId);
  }

  // ── 화면 ──────────────────────────────────────────────────────────

  Widget _menu() {
    if (!_todo.canEdit && !_todo.canManage) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return PopupMenuButton<String>(
      key: const ValueKey('todo-detail-menu'),
      tooltip: '더보기',
      icon: const Icon(Icons.more_vert),
      onSelected: (v) => v == 'edit' ? _edit() : _delete(),
      itemBuilder: (context) => [
        if (_todo.canEdit)
          const PopupMenuItem(
            value: 'edit',
            child: Text('수정', key: ValueKey('todo-menu-edit')),
          ),
        if (_todo.canManage)
          PopupMenuItem(
            value: 'delete',
            child: Text(
              '삭제',
              key: const ValueKey('todo-menu-delete'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: widget.asDialog ? _buildDialog(context) : _buildPage(context),
    );
  }

  Widget _buildDialog(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: math.min(560, screen.width - 48),
        height: math.min(720, screen.height - 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 4, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.checklist_rounded,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '할 일',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  _menu(),
                  IconButton(
                    key: const ValueKey('todo-detail-close'),
                    icon: const Icon(Icons.close),
                    tooltip: '닫기',
                    onPressed: () => Navigator.of(context).pop(_changed),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _bodyChildren(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPage(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('todo-detail-close'),
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(_changed),
        ),
        title: const Text('할 일'),
        actions: [_menu()],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _bodyChildren(context),
          ),
        ),
      ),
    );
  }

  List<Widget> _bodyChildren(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final t = _todo;
    final images = [
      for (final a in t.attachments)
        if (a.isImage) a.toMessageAttachment(),
    ];
    final files = [
      for (final a in t.attachments)
        if (!a.isImage) a.toMessageAttachment(),
    ];
    final room = _room;
    final canOpenRoom = room != null && widget.onOpenRoom != null;
    return [
      Text(
        t.title,
        key: const ValueKey('todo-detail-title'),
        style: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          decoration: t.isDone ? TextDecoration.lineThrough : null,
        ),
      ),
      const SizedBox(height: 12),
      _progressSection(context),
      if ((t.description ?? '').isNotEmpty) ...[
        const SizedBox(height: 20),
        const _Label('설명'),
        SelectableText(
          t.description!,
          key: const ValueKey('todo-detail-description'),
        ),
      ],
      const SizedBox(height: 20),
      const _Label('기한'),
      Text(
        t.periodText ?? '기한 없음',
        key: const ValueKey('todo-detail-period'),
        style: TextStyle(
          color: t.periodText == null
              ? hint
              : t.isOverdue()
              ? theme.colorScheme.error
              : null,
          fontWeight: t.isOverdue() ? FontWeight.w600 : null,
        ),
      ),
      const SizedBox(height: 20),
      _Label('담당자', trailing: '${t.assignees.length}명'),
      if (t.assignees.isEmpty)
        Text('담당자가 없습니다.', style: TextStyle(color: hint))
      else
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            for (final a in t.assignees)
              Row(
                key: ValueKey('todo-detail-assignee-${a.id}'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  UserAvatar(
                    user: a,
                    resolveUrl: widget.session.resolveUrl,
                    radius: 12,
                  ),
                  const SizedBox(width: 6),
                  Text(a.name),
                ],
              ),
          ],
        ),
      const SizedBox(height: 20),
      const _Label('대화방'),
      InkWell(
        key: const ValueKey('todo-detail-room'),
        onTap: canOpenRoom ? () => _openRoom() : null,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  t.roomName ?? '대화방',
                  style: TextStyle(
                    color: canOpenRoom ? theme.colorScheme.primary : null,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (canOpenRoom) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
              ],
            ],
          ),
        ),
      ),
      if (t.sourceMessageId != null && canOpenRoom)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('todo-detail-source'),
            onPressed: () => _openRoom(messageId: t.sourceMessageId),
            icon: const Icon(Icons.chat_bubble_outline, size: 16),
            label: const Text('원본 메시지 보기'),
          ),
        ),
      if (t.attachments.isNotEmpty) ...[
        const SizedBox(height: 20),
        _Label('첨부', trailing: '${t.attachments.length}개'),
        if (images.isNotEmpty)
          ChatImageAttachments(
            session: widget.session,
            attachments: images,
            room: room,
          ),
        if (images.isNotEmpty && files.isNotEmpty) const SizedBox(height: 8),
        if (files.isNotEmpty)
          ChatFileAttachments(session: widget.session, attachments: files),
      ],
      if (t.reminders.isNotEmpty) ...[
        const SizedBox(height: 20),
        const _Label('알림 일정'),
        for (final r in t.reminders)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: [
                Icon(
                  Icons.notifications_active_outlined,
                  size: 16,
                  color: hint,
                ),
                const SizedBox(width: 6),
                Text(
                  formatTodoDateTime(r.remindAt) + (r.sent ? ' (알림 보냄)' : ''),
                  style: TextStyle(color: r.sent ? hint : null),
                ),
              ],
            ),
          ),
      ],
      const SizedBox(height: 24),
      const Divider(height: 1),
      const SizedBox(height: 10),
      Text(
        '${t.creator?.name ?? '알 수 없음'} · ${formatTodoDateTime(t.createdAt)} 생성'
        '${t.updatedAt.isAfter(t.createdAt.add(const Duration(seconds: 1))) ? ' · ${formatTodoDateTime(t.updatedAt)} 수정' : ''}',
        key: const ValueKey('todo-detail-created'),
        style: TextStyle(fontSize: 12, color: hint),
      ),
    ];
  }

  /// 상태 칩 + 진척률 막대 + 진척률 조절(0/25/50/75/100)과 완료 단추. 조절은 만든 사람·담당자만.
  Widget _progressSection(BuildContext context) {
    final theme = Theme.of(context);
    final t = _todo;
    final color = switch (t.status) {
      TodoStatus.todo => theme.hintColor,
      TodoStatus.doing => theme.colorScheme.primary,
      TodoStatus.done => Colors.green.shade600,
    };
    final editable = t.canEdit && !_busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            TodoStatusChip(todo: t, key: const ValueKey('todo-detail-status')),
            const SizedBox(width: 10),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: t.progress / 100,
                  minHeight: 6,
                  color: color,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text('${t.progress}%', style: TextStyle(color: color)),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final p in todoProgressSteps)
              ChoiceChip(
                key: ValueKey('todo-progress-$p'),
                label: Text('$p%'),
                selected: t.progress == p,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onSelected: editable ? (_) => _setProgress(p) : null,
              ),
            if (t.isDone)
              OutlinedButton(
                key: const ValueKey('todo-complete-button'),
                onPressed: editable ? () => _setProgress(0) : null,
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('완료 취소'),
              )
            else
              FilledButton.icon(
                key: const ValueKey('todo-complete-button'),
                onPressed: editable ? () => _setProgress(100) : null,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.check, size: 16),
                label: const Text('완료'),
              ),
          ],
        ),
        if (!t.canEdit)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '만든 사람과 담당자만 수정할 수 있습니다.',
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
          ),
      ],
    );
  }
}

/// 상태 칩 — 대기(회색)·진행 N%(파랑)·완료(초록). 목록 카드와 상세가 같이 쓴다.
class TodoStatusChip extends StatelessWidget {
  final Todo todo;
  const TodoStatusChip({super.key, required this.todo});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (todo.status) {
      TodoStatus.todo => theme.hintColor,
      TodoStatus.doing => theme.colorScheme.primary,
      TodoStatus.done => Colors.green.shade600,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        todo.statusText,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  final String? trailing;
  const _Label(this.text, {this.trailing});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: hint,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 6),
            Text(trailing!, style: TextStyle(fontSize: 12, color: hint)),
          ],
        ],
      ),
    );
  }
}

/// 담당자 아바타 줄(+N) — 목록 카드가 쓴다. 최대 [max]명까지 겹쳐 그리고 나머지는 `+N`.
class TodoAssigneeStack extends StatelessWidget {
  final Session session;
  final List<AppUser> assignees;
  final int max;
  final double radius;
  const TodoAssigneeStack({
    super.key,
    required this.session,
    required this.assignees,
    this.max = 3,
    this.radius = 11,
  });

  @override
  Widget build(BuildContext context) {
    if (assignees.isEmpty) return const SizedBox.shrink();
    final shown = assignees.take(max).toList();
    final extra = assignees.length - shown.length;
    final overlap = radius * 1.3;
    final theme = Theme.of(context);
    return SizedBox(
      height: radius * 2,
      width: radius * 2 + overlap * (shown.length - 1) + (extra > 0 ? 28 : 0),
      child: Stack(
        children: [
          for (final (i, a) in shown.indexed)
            Positioned(
              left: overlap * i,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.surface,
                    width: 1.5,
                  ),
                ),
                child: UserAvatar(
                  user: a,
                  resolveUrl: session.resolveUrl,
                  radius: radius,
                ),
              ),
            ),
          if (extra > 0)
            Positioned(
              left: overlap * shown.length + 4,
              top: 0,
              bottom: 0,
              child: Center(
                child: Text(
                  '+$extra',
                  key: const ValueKey('todo-assignee-extra'),
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
