import 'dart:async';

import 'package:flutter/material.dart';

import '../models/message.dart';
import '../models/todo.dart';
import '../screens/post_editor_dialog.dart' show fileIconFor;
import '../services/api_client.dart' show ApiException;
import '../services/session.dart';
import '../services/todo_api.dart';
import 'app_toast.dart';
import 'todo_widgets.dart';
import 'todos_panel.dart' show openTodoInPanel;

/// 할 일을 찾을 수 없을 때 서버가 주는 문구(server/src/todos.js) — 이 문구면 지워진 할 일로 본다.
const _todoNotFound = '할 일을 찾을 수 없습니다.';

/// 다시 받은 할 일을 잠깐 들고 있는다 — 목록을 스크롤하며 카드가 다시 그려질 때마다 서버에 묻지 않게.
final _cache = <String, (Todo, DateTime)>{};
const _cacheTtl = Duration(minutes: 1);

/// 할 일을 만들 때 대화방에 올라간 "할 일 카드"(잔디의 할 일 메시지) — 말풍선 안에 왼쪽 할 일 아이콘, 오른쪽에 만든 사람 ·
/// 진행률, 제목, 설명 앞부분, 기간, 담당자, 첨부 파일. 누르면 할 일 패널이 열려 그 안에 상세가 뜬다(PC — 모바일은 전체
/// 화면 상세, [openTodoInPanel]).
///
/// 메시지에 담긴 스냅샷([Message.sharedTodo])을 먼저 그리고, 할 일을 다시 받아 최신 내용(제목·기간·진행률 등)으로 바꾼다.
/// 열려 있는 동안 그 할 일이 바뀌면(소켓 todo:changed) 다시 받고, 지워지면 "삭제된 할 일"로 바뀐다. [api]·[changed]는
/// 테스트가 가짜를 끼우는 자리.
class TodoMessageCard extends StatefulWidget {
  final Session session;
  final Message message;
  final TodoApi? api;
  final Stream<Map<String, dynamic>>? changed;

  const TodoMessageCard({
    super.key,
    required this.session,
    required this.message,
    this.api,
    this.changed,
  });

  @override
  State<TodoMessageCard> createState() => _TodoMessageCardState();
}

class _TodoMessageCardState extends State<TodoMessageCard> {
  late final TodoApi _api = widget.api ?? widget.session.todoApi;
  SharedTodo get _shared => widget.message.sharedTodo!;
  Todo? _live;
  late bool _deleted = _shared.deleted;
  StreamSubscription<Map<String, dynamic>>? _sub;

  @override
  void initState() {
    super.initState();
    final id = _shared.id;
    if (id == null) return;
    final cached = _cache[id];
    if (cached != null && DateTime.now().difference(cached.$2) < _cacheTtl) {
      _live = cached.$1;
    } else {
      unawaited(_fetch(id));
    }
    final stream = widget.changed ?? widget.session.chatSocket.todoChanged;
    _sub = stream.listen((e) {
      if (e['todoId'] != id || !mounted) return;
      if (e['kind'] == 'deleted') {
        _cache.remove(id);
        setState(() => _deleted = true);
        return;
      }
      // 즐겨찾기는 카드에 보이지 않는다.
      if (e['kind'] == 'favorite') return;
      unawaited(_fetch(id));
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _fetch(String id) async {
    try {
      final todo = await _api.get(id);
      _cache[id] = (todo, DateTime.now());
      if (mounted) setState(() => _live = todo);
    } on ApiException catch (e) {
      if (e.message == _todoNotFound && mounted) {
        _cache.remove(id);
        setState(() => _deleted = true);
      }
    } catch (_) {
      // 다시 받지 못해도 스냅샷은 그대로 보인다.
    }
  }

  Future<void> _open() async {
    if (_deleted) {
      showAppToast(context, '삭제된 할 일입니다.');
      return;
    }
    final id = _shared.id!;
    var todo = _live;
    if (todo == null) {
      await _fetch(id);
      todo = _live;
    }
    if (!mounted) return;
    if (todo == null) {
      if (!_deleted) showAppToast(context, '할 일을 불러오지 못했습니다.');
      return;
    }
    await openTodoInPanel(context, widget.session, todo, api: widget.api);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final shared = _shared;
    final live = _deleted ? null : _live;
    final title = live?.title ?? shared.title;
    final description = live?.description ?? shared.description;
    final period = live?.periodText ?? shared.periodText;
    final assignees = live == null
        ? shared.assigneeNames
        : [for (final a in live.assignees) a.name];
    final files = live == null
        ? shared.attachmentNames
        : [
            for (final a in live.attachments)
              if (a.fileName != null) a.fileName!,
          ];
    final fileCount = live?.attachments.length ?? shared.attachmentCount;
    const shownFiles = 3;
    final creator = live?.creator?.name ?? widget.message.senderName;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 380),
      child: Material(
        key: ValueKey('todo-card-${widget.message.id}'),
        color: theme.colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _open,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.assignment_turned_in_outlined,
                  size: 34,
                  color: _deleted ? hint : const Color(0xFF2E9E6B),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              creator,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (live != null)
                            Text(
                              todoPercentText(live.progress),
                              key: const ValueKey('todo-card-progress'),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: todoProgressColor(
                                  context,
                                  live.progress,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                          decoration: _deleted
                              ? TextDecoration.lineThrough
                              : null,
                          color: _deleted ? hint : null,
                        ),
                      ),
                      if (_deleted) ...[
                        const SizedBox(height: 6),
                        Text(
                          '삭제된 할 일입니다.',
                          key: const ValueKey('todo-card-deleted'),
                          style: TextStyle(fontSize: 13, color: hint),
                        ),
                      ] else ...[
                        if (description != null && description.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            description,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.45,
                              color: hint,
                            ),
                          ),
                        ],
                        if (period != null) ...[
                          const SizedBox(height: 8),
                          _line(context, Icons.schedule, period),
                        ],
                        if (assignees.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          _line(
                            context,
                            Icons.people_outline,
                            '담당 ${assignees.join(', ')}',
                          ),
                        ],
                        for (final name in files.take(shownFiles)) ...[
                          const SizedBox(height: 8),
                          _FileChip(name: name),
                        ],
                        if (fileCount > shownFiles) ...[
                          const SizedBox(height: 6),
                          Text(
                            '외 ${fileCount - shownFiles}개 파일',
                            style: TextStyle(fontSize: 12, color: hint),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _line(BuildContext context, IconData icon, String text) {
    final hint = Theme.of(context).hintColor;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 15, color: hint),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 13, color: hint)),
        ),
      ],
    );
  }
}

/// 첨부 파일 한 줄 — 흰 상자에 파일 종류 아이콘 + 이름(카드를 누르면 상세에서 받는다).
class _FileChip extends StatelessWidget {
  final String name;
  const _FileChip({required this.name});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(fileIconFor(name), size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
