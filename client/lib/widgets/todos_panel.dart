import 'package:flutter/material.dart';

import '../models/room.dart';
import '../models/todo.dart';
import '../screens/todo_detail_dialog.dart';
import '../screens/todo_editor_dialog.dart';
import '../services/session.dart';
import '../services/todo_api.dart';
import '../services/todo_controller.dart';
import 'app_toast.dart';
import 'category_tab_row.dart';
import 'compact_menu.dart';
import 'filter_dropdown.dart';
import 'home_shell_scope.dart';
import 'panel_filters.dart';
import 'side_panel_header.dart';

/// 할 일 패널(side_panels.dart의 'todos') — 잔디의 할 일과 같다. 위에 "+ 할 일 생성", 탭(나의 할 일 / 부여한 할 일 / 팀
/// 할 일), 필터 줄(참여 대화방 · 완료 제외 · 정렬), `"N"개가 로딩되었습니다.` 줄, 카드 목록(무한 스크롤)이다. 카드를 누르면
/// 상세, 왼쪽 체크로 완료를 빠르게 토글한다(만든 사람·담당자).
///
/// 상태는 패널이 열릴 때 만드는 [TodoController]가 들고 있고(Session에는 두지 않는다), 서버의 todo:changed 알림이 오면
/// 조용히 다시 받는다. [controller]·[api]는 테스트가 바꿔 끼우는 값이다.
class TodosPanel extends StatefulWidget {
  final Session session;
  final VoidCallback? onClose;
  final TodoController? controller;
  final TodoApi? api;

  const TodosPanel({
    super.key,
    required this.session,
    this.onClose,
    this.controller,
    this.api,
  });

  @override
  State<TodosPanel> createState() => _TodosPanelState();
}

class _TodosPanelState extends State<TodosPanel> {
  late TodoController _controller;
  bool _ownsController = false;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _attach();
    widget.session.addListener(_onSessionChanged);
  }

  void _attach() {
    final injected = widget.controller;
    if (injected != null) {
      _controller = injected;
      _ownsController = false;
    } else {
      final session = widget.session;
      _controller = TodoController(
        api: widget.api ?? session.todoApi,
        teamId: session.currentTeam!.id,
        changed: session.chatSocket.todoChanged,
        reconnected: session.chatSocket.reconnected,
      );
      _ownsController = true;
    }
    _controller.addListener(_onChanged);
    if (!_controller.loaded) _controller.load();
  }

  void _detach() {
    _controller.removeListener(_onChanged);
    if (_ownsController) _controller.dispose();
  }

  /// 보고 있는 팀이 바뀌면 그 팀의 할 일로 새로 시작한다(내 컨트롤러일 때만).
  void _onSessionChanged() {
    if (!_ownsController) return;
    final teamId = widget.session.currentTeam?.id;
    if (teamId == null || teamId == _controller.teamId) return;
    _detach();
    setState(_attach);
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    // 첫 쪽이 화면을 다 못 채우면 스크롤이 안 생겨 다음 쪽을 못 받는다 — 그때는 직접 이어 받는다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_scroll.position.maxScrollExtent <= 0 && _controller.hasMore) {
        _controller.loadMore();
      }
    });
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    _detach();
    _scroll.dispose();
    super.dispose();
  }

  // ---- 동작 ----

  Future<void> _create() async {
    final shell = HomeShellScope.maybeOf(context);
    final currentId = shell?.panelRoom?.id ?? shell?.currentRoomId;
    final current = widget.session.rooms
        .where(
          (r) =>
              r.id == currentId &&
              r.teamId == _controller.teamId &&
              widget.session.canCreateTodoIn(r),
        )
        .firstOrNull;
    final saved = await showTodoEditor(
      context,
      session: widget.session,
      room: current,
      api: widget.api,
    );
    if (saved == null || !mounted) return;
    showAppToast(context, '할 일을 만들었습니다.');
    _controller.load(silent: true);
  }

  Future<void> _open(Todo todo) async {
    final changed = await showTodoDetail(
      context,
      session: widget.session,
      todo: todo,
      api: widget.api,
      onOpenRoom: (room, {messageId}) => _openRoom(room, messageId),
    );
    if (changed && mounted) _controller.load(silent: true);
  }

  void _openRoom(Room room, String? messageId) =>
      openRoomFromPanel(context, widget.session, room, messageId: messageId);

  Future<void> _toggleDone(Todo todo) async {
    try {
      await _controller.setProgress(todo, todo.isDone ? 0 : 100);
    } catch (e) {
      if (mounted) showAppToast(context, '진척률을 바꾸지 못했습니다: $e');
    }
  }

  // ---- 화면 ----

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SidePanelHeader(title: '할 일', onClose: widget.onClose),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 4),
            child: Row(
              children: [
                FilledButton.icon(
                  key: const ValueKey('todo-create'),
                  onPressed: _create,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('할 일 생성'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: CategoryTabRow<TodoScope>(
              items: TodoScope.values,
              selected: _controller.scope,
              labelOf: (s) => s.label,
              onSelected: _controller.setScope,
            ),
          ),
          _filterBar(context),
          const SizedBox(height: 4),
          PanelResultLine(
            summary: Text(
              '"${_controller.items.length}"개가 로딩되었습니다.',
              key: const ValueKey('panel-loaded-count'),
              style: theme.textTheme.labelLarge,
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _content(context)),
        ],
      ),
    );
  }

  Widget _filterBar(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: RoomFilterButton(
                  session: widget.session,
                  selectedRoomId: _controller.roomId,
                  expand: true,
                  onSelected: _controller.setRoom,
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(
                key: const ValueKey('todo-exclude-done'),
                label: const Text('완료 제외'),
                selected: _controller.excludeDone,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onSelected: _controller.setExcludeDone,
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: PopupMenuButton<TodoSort>(
              key: const ValueKey('todo-sort'),
              tooltip: '정렬',
              position: PopupMenuPosition.under,
              offset: const Offset(0, 4),
              color: CompactMenu.color(context),
              shape: CompactMenu.shape,
              menuPadding: CompactMenu.menuPadding,
              constraints: const BoxConstraints(minWidth: 140, maxWidth: 200),
              initialValue: _controller.sort,
              onSelected: _controller.setSort,
              itemBuilder: (context) => [
                for (final s in TodoSort.values)
                  PopupMenuItem<TodoSort>(
                    key: ValueKey('todo-sort-${s.wire}'),
                    value: s,
                    height: CompactMenu.itemHeight,
                    padding: CompactMenu.itemPadding,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(s.label, style: CompactMenu.textStyle),
                        ),
                        if (s == _controller.sort)
                          const Icon(Icons.check, size: 16),
                      ],
                    ),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.swap_vert, size: 16, color: hint),
                    const SizedBox(width: 2),
                    Text(
                      _controller.sort.label,
                      style: theme.textTheme.labelMedium?.copyWith(color: hint),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    final c = _controller;
    if (!c.loaded) {
      if (c.error != null) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(c.error!, textAlign: TextAlign.center),
              ),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: c.load, child: const Text('다시 시도')),
            ],
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    final items = c.items;
    if (items.isEmpty) return _empty(context);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 240) c.loadMore();
        return false;
      },
      child: ListView.separated(
        key: const ValueKey('todo-list'),
        controller: _scroll,
        itemCount: items.length + (c.hasMore || c.loadingMore ? 1 : 0),
        separatorBuilder: (context, i) => const Divider(height: 1),
        itemBuilder: (context, i) {
          if (i >= items.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final todo = items[i];
          return TodoCard(
            key: ValueKey('todo-${todo.id}'),
            session: widget.session,
            todo: todo,
            onTap: () => _open(todo),
            onToggleDone: todo.canEdit ? () => _toggleDone(todo) : null,
          );
        },
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    final text = switch (_controller.scope) {
      TodoScope.mine => '나에게 지정된 할 일이 없어요.',
      TodoScope.assignedByMe => '내가 만든 할 일이 없어요.',
      TodoScope.team => '이 팀에 등록된 할 일이 없어요.',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.checklist_rounded, size: 40, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(
              text,
              key: const ValueKey('todo-empty'),
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 4),
            Text(
              '"할 일 생성"으로 대화방에 할 일을 만들어 보세요.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 목록의 할 일 카드 — 왼쪽 완료 체크, 제목 + 상태 칩, 기한(지난 기한은 빨강), 담당자 아바타(+N), 대화방 이름, 첨부 수.
class TodoCard extends StatelessWidget {
  final Session session;
  final Todo todo;
  final VoidCallback? onTap;

  /// 완료 체크 — null이면 체크는 보이되 눌리지 않는다(만든 사람·담당자가 아닐 때).
  final VoidCallback? onToggleDone;

  const TodoCard({
    super.key,
    required this.session,
    required this.todo,
    this.onTap,
    this.onToggleDone,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final overdue = todo.isOverdue();
    final period = todo.periodText;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              key: ValueKey('todo-check-${todo.id}'),
              value: todo.isDone,
              shape: const CircleBorder(),
              visualDensity: VisualDensity.compact,
              onChanged: onToggleDone == null ? null : (_) => onToggleDone!(),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          todo.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: todo.isDone ? hint : null,
                            decoration: todo.isDone
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TodoStatusChip(todo: todo),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (period != null)
                        Text(
                          period,
                          key: ValueKey('todo-period-${todo.id}'),
                          style: TextStyle(
                            fontSize: 12,
                            color: overdue ? theme.colorScheme.error : hint,
                            fontWeight: overdue ? FontWeight.w600 : null,
                          ),
                        ),
                      if (todo.assignees.isNotEmpty)
                        TodoAssigneeStack(
                          session: session,
                          assignees: todo.assignees,
                        ),
                      if (todo.attachments.isNotEmpty)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.attach_file, size: 14, color: hint),
                            Text(
                              '${todo.attachments.length}',
                              key: ValueKey('todo-clips-${todo.id}'),
                              style: TextStyle(fontSize: 12, color: hint),
                            ),
                          ],
                        ),
                    ],
                  ),
                  if ((todo.roomName ?? '').isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      todo.roomName!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
