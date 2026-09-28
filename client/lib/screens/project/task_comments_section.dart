import 'package:flutter/material.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
import '../../services/session.dart';
import '../../services/time_format.dart';
import '../../widgets/hover_toolbar.dart' show hoverMenuItem;
import '../../widgets/rich_text_format.dart';
import '../../widgets/my_avatar.dart';
import '../../widgets/user_avatar.dart';

/// 댓글 한 개(업무·노트 공통).
class CommentEntry {
  final String id;

  /// 답글이면 그 댓글(한 단계까지만).
  final String? parentId;
  final String? senderId;
  final String senderName;
  final String text;
  final List<TextFormatRun>? format;
  final DateTime createdAt;
  final DateTime? editedAt;
  const CommentEntry({
    required this.id,
    this.parentId,
    this.senderId,
    required this.senderName,
    required this.text,
    this.format,
    required this.createdAt,
    this.editedAt,
  });
}

/// 댓글을 달고·고치고·지우는 방법 — 업무·노트마다 다른 API를 쓴다.
class CommentActions {
  final Future<void> Function(
    String text,
    List<TextFormatRun>? format, {
    String? parentId,
  })
  add;
  final Future<void> Function(
    String id,
    String text,
    List<TextFormatRun>? format,
  )
  update;
  final Future<void> Function(String id) delete;
  const CommentActions({
    required this.add,
    required this.update,
    required this.delete,
  });
}

/// "댓글 (n) | 기록" 탭 — 업무 패널과 노트가 같이 쓴다.
///
/// 댓글 탭: 위에 새 댓글 입력칸(서식 도구모음), 아래 회색 바탕에 댓글 카드들(최신이 위). 카드 밑
/// 도구모음의 첫 버튼이 답글, 삼점이 수정·삭제. 답글은 한 단계까지라 답글의 "답글"도 같은 댓글
/// 아래에 단다. 기록 탭 내용은 [history]가 그린다.
class CommentsSection extends StatefulWidget {
  final Session session;
  final List<CommentEntry> comments;

  /// 댓글 쓴 사람 사진을 찾을 구성원(없으면 이니셜).
  final List<AppUser> members;
  final bool readOnly;

  /// 프로젝트 담당자 — 남의 댓글도 지울 수 있다(서버도 같은 규칙).
  final bool canModerate;
  final CommentActions actions;

  /// 기록 탭 내용.
  final WidgetBuilder history;

  const CommentsSection({
    super.key,
    required this.session,
    required this.comments,
    required this.members,
    required this.readOnly,
    required this.canModerate,
    required this.actions,
    required this.history,
  });

  @override
  State<CommentsSection> createState() => _CommentsSectionState();
}

/// 업무 상세 아래쪽 댓글·기록 — 공용 [CommentsSection]에 업무 댓글과 업무 기록을 넣는다.
class TaskCommentsSection extends StatelessWidget {
  final Session session;
  final Task task;
  final List<AppUser> members;
  final bool readOnly;
  final bool canModerate;

  /// 서버에 반영하고 업무를 다시 불러온다(업무 상세 패널의 _apply).
  final Future<void> Function(Future<void> Function() save) apply;

  const TaskCommentsSection({
    super.key,
    required this.session,
    required this.task,
    required this.members,
    required this.readOnly,
    required this.canModerate,
    required this.apply,
  });

  @override
  Widget build(BuildContext context) {
    final api = session.api!;
    return CommentsSection(
      session: session,
      comments: [
        for (final c in task.comments)
          CommentEntry(
            id: c.id,
            parentId: c.parentCommentId,
            senderId: c.senderId,
            senderName: c.senderName,
            text: c.text,
            format: c.textFormat,
            createdAt: c.createdAt,
            editedAt: c.editedAt,
          ),
      ],
      members: members,
      readOnly: readOnly,
      canModerate: canModerate,
      actions: CommentActions(
        add: (text, format, {parentId}) => apply(
          () => api.addTaskComment(
            task.id,
            text,
            textFormat: format,
            parentCommentId: parentId,
          ),
        ),
        update: (id, text, format) =>
            apply(() => api.updateTaskComment(id, text, textFormat: format)),
        delete: (id) => apply(() => api.deleteTaskComment(id)),
      ),
      history: (_) =>
          TaskHistoryView(session: session, task: task, members: members),
    );
  }
}

class _CommentsSectionState extends State<CommentsSection> {
  int _tab = 0;

  final _newText = RichTextEditingController();
  final _newFocus = FocusNode();

  /// 답글 입력칸이 열린 댓글(스레드의 맨 위 댓글).
  String? _replyTo;
  final _replyText = RichTextEditingController();
  final _replyFocus = FocusNode();

  /// 고치는 중인 댓글.
  String? _editing;
  final _editText = RichTextEditingController();
  final _editFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _newText.addListener(_refresh);
    _replyText.addListener(_refresh);
    _editText.addListener(_refresh);
  }

  @override
  void didUpdateWidget(covariant CommentsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.readOnly && widget.readOnly) {
      _replyTo = null;
      _editing = null;
      _newFocus.unfocus();
      _replyFocus.unfocus();
      _editFocus.unfocus();
    }
  }

  @override
  void dispose() {
    _newText.dispose();
    _newFocus.dispose();
    _replyText.dispose();
    _replyFocus.dispose();
    _editText.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  AppUser _userFor(String? id, String name) =>
      widget.members.where((m) => m.id == id).firstOrNull ??
      AppUser(id: id ?? '', username: '', name: name);

  // ── 저장 ──────────────────────────────────────────────────────────────

  Future<void> _submitNew() async {
    if (widget.readOnly) return;
    final (:text, :format) = _newText.formatted();
    if (text.isEmpty) return;
    _newText.clear();
    _newFocus.unfocus();
    await widget.actions.add(text, format);
  }

  void _openReply(String threadId) {
    setState(() {
      _editing = null;
      _replyTo = threadId;
      _replyText.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _replyFocus.requestFocus(),
    );
  }

  Future<void> _submitReply(String threadId) async {
    if (widget.readOnly) return;
    final (:text, :format) = _replyText.formatted();
    if (text.isEmpty) return;
    setState(() => _replyTo = null);
    _replyText.clear();
    await widget.actions.add(text, format, parentId: threadId);
  }

  void _startEdit(CommentEntry c) {
    setState(() {
      _replyTo = null;
      _editing = c.id;
    });
    _editText.load(c.text, c.format);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _editFocus.requestFocus(),
    );
  }

  Future<void> _submitEdit(CommentEntry c) async {
    if (widget.readOnly) return;
    final (:text, :format) = _editText.formatted();
    if (text.isEmpty) return;
    setState(() => _editing = null);
    await widget.actions.update(c.id, text, format);
  }

  Future<void> _delete(CommentEntry c, {required bool hasReplies}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('댓글 삭제'),
        content: Text(
          hasReplies ? '이 댓글을 삭제할까요? 달린 답글도 함께 삭제됩니다.' : '이 댓글을 삭제할까요?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.actions.delete(c.id);
  }

  // ── 그리기 ────────────────────────────────────────────────────────────

  ButtonStyle _saveStyle(ThemeData theme) => FilledButton.styleFrom(
    disabledBackgroundColor: theme.colorScheme.primary.withValues(alpha: 0.3),
    disabledForegroundColor: Colors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  );

  Widget _tabs(ThemeData theme) {
    Widget tab(String label, int index) {
      final selected = _tab == index;
      return InkWell(
        onTap: () => setState(() => _tab = index),
        child: Container(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 10),
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected
                    ? theme.colorScheme.primary
                    : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected ? theme.colorScheme.primary : null,
            ),
          ),
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [tab('댓글 (${widget.comments.length})', 0), tab('기록', 1)],
      ),
    );
  }

  Widget _newCommentInput(ThemeData theme, {bool enabled = true}) {
    final me = widget.session.userId;
    final inMembers = widget.members.any((m) => m.id == me);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 구성원 목록에 내가 없으면(노트) 세션의 내 프로필로.
          if (inMembers)
            UserAvatar(
              user: _userFor(me, ''),
              resolveUrl: widget.session.resolveUrl,
              radius: 14,
            )
          else
            MyAvatar(session: widget.session, radius: 14),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                IgnorePointer(
                  ignoring: !enabled,
                  child: ExcludeFocus(
                    excluding: !enabled,
                    child: Opacity(
                      opacity: enabled ? 1 : 0.55,
                      child: RichEditorBox(
                        controller: _newText,
                        focusNode: _newFocus,
                        hintText: '댓글을 입력하세요...',
                        alwaysShowToolbar: false,
                        onSubmit: enabled ? _submitNew : null,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  style: _saveStyle(theme),
                  onPressed: !enabled || _newText.text.trim().isEmpty
                      ? null
                      : _submitNew,
                  child: const Text('저장'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 답글·수정 입력칸 + [저장] [취소].
  Widget _inlineEditor({
    required ThemeData theme,
    required RichTextEditingController controller,
    required FocusNode focusNode,
    required String hint,
    required VoidCallback onSave,
    required VoidCallback onCancel,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RichEditorBox(
          controller: controller,
          focusNode: focusNode,
          hintText: hint,
          minLines: 3,
          onSubmit: onSave,
          onCancel: onCancel,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton(
              style: _saveStyle(theme),
              onPressed: controller.text.trim().isEmpty ? null : onSave,
              child: const Text('저장'),
            ),
            const SizedBox(width: 4),
            TextButton(onPressed: onCancel, child: const Text('취소')),
          ],
        ),
      ],
    );
  }

  /// 댓글(또는 답글) 한 개 — 아바타, 이름·시각, 본문, 도구모음(답글 / 삼점: 수정·삭제).
  Widget _comment(
    ThemeData theme,
    CommentEntry c, {
    required String threadId,
    required bool hasReplies,
  }) {
    final mine = c.senderId != null && c.senderId == widget.session.userId;
    final canDelete = mine || widget.canModerate;
    final editing = !widget.readOnly && _editing == c.id;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UserAvatar(
          user: _userFor(c.senderId, c.senderName),
          resolveUrl: widget.session.resolveUrl,
          radius: 12,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      c.senderName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    formatRelativeTime(c.createdAt) +
                        (c.editedAt != null ? ' (수정됨)' : ''),
                    style: TextStyle(fontSize: 11, color: theme.hintColor),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (editing)
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 6),
                  child: _inlineEditor(
                    theme: theme,
                    controller: _editText,
                    focusNode: _editFocus,
                    hint: '댓글을 입력하세요...',
                    onSave: () => _submitEdit(c),
                    onCancel: () => setState(() => _editing = null),
                  ),
                )
              else
                FormattedText(
                  c.text,
                  format: c.format,
                  style: const TextStyle(fontSize: 13),
                ),
              if (!widget.readOnly && !editing)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    children: [
                      _toolButton(
                        theme,
                        icon: Icons.reply,
                        tooltip: '답글',
                        onPressed: () => _openReply(threadId),
                      ),
                      if (mine || canDelete)
                        MenuAnchor(
                          menuChildren: [
                            if (mine)
                              hoverMenuItem(
                                icon: Icons.edit_outlined,
                                label: '수정',
                                onPressed: () => _startEdit(c),
                              ),
                            if (canDelete)
                              hoverMenuItem(
                                icon: Icons.delete_outline,
                                label: '삭제',
                                color: Colors.redAccent,
                                onPressed: () =>
                                    _delete(c, hasReplies: hasReplies),
                              ),
                          ],
                          builder: (context, controller, _) => _toolButton(
                            theme,
                            icon: Icons.more_horiz,
                            tooltip: '더보기',
                            onPressed: () => controller.isOpen
                                ? controller.close()
                                : controller.open(),
                          ),
                        ),
                    ],
                  ),
                )
              else
                const SizedBox(height: 6),
            ],
          ),
        ),
      ],
    );
  }

  Widget _toolButton(
    ThemeData theme, {
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) => IconButton(
    icon: Icon(icon, size: 17),
    tooltip: tooltip,
    color: theme.hintColor,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
    padding: EdgeInsets.zero,
    onPressed: onPressed,
  );

  Widget _thread(ThemeData theme, CommentEntry c, List<CommentEntry> replies) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _comment(theme, c, threadId: c.id, hasReplies: replies.isNotEmpty),
          for (final r in replies)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 6),
              child: _comment(theme, r, threadId: c.id, hasReplies: false),
            ),
          if (!widget.readOnly && _replyTo == c.id)
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 4, 0, 10),
              child: _inlineEditor(
                theme: theme,
                controller: _replyText,
                focusNode: _replyFocus,
                hint: '답글을 입력하세요...',
                onSave: () => _submitReply(c.id),
                onCancel: () => setState(() => _replyTo = null),
              ),
            ),
        ],
      ),
    );
  }

  Widget _commentsTab(ThemeData theme) {
    final all = widget.comments;
    final threads = all.where((c) => c.parentId == null).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final replies = <String, List<CommentEntry>>{};
    for (final c in all) {
      if (c.parentId != null) {
        (replies[c.parentId!] ??= []).add(c);
      }
    }
    for (final list in replies.values) {
      list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }
    final dark = theme.brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 읽기 전용(종료된 프로젝트·보관한 업무)이면 입력칸을 흐리게 두고 저장할 수 없다.
        _newCommentInput(theme, enabled: !widget.readOnly),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: dark
                ? Colors.white.withValues(alpha: 0.04)
                : const Color(0xFFF1F3F6),
            borderRadius: BorderRadius.circular(8),
          ),
          child: threads.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    '댓글이 없습니다.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.hintColor, fontSize: 12),
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, c) in threads.indexed) ...[
                      if (i > 0) const SizedBox(height: 10),
                      _thread(theme, c, replies[c.id] ?? const []),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _tabs(theme),
        if (_tab == 0) _commentsTab(theme) else widget.history(context),
      ],
    );
  }
}

/// 업무 기록 탭 — 상태 구간별로 묶은 누가 언제 무엇을 바꿨는지.
class TaskHistoryView extends StatefulWidget {
  final Session session;
  final Task task;
  final List<AppUser> members;
  const TaskHistoryView({
    super.key,
    required this.session,
    required this.task,
    required this.members,
  });

  @override
  State<TaskHistoryView> createState() => _TaskHistoryViewState();
}

class _TaskHistoryViewState extends State<TaskHistoryView> {
  AppUser _userFor(String? id, String name) =>
      widget.members.where((m) => m.id == id).firstOrNull ??
      AppUser(id: id ?? '', username: '', name: name);

  /// 접어 둔 상태 구간(머리줄 기록의 id).
  final _collapsed = <String>{};

  static String _ymd(DateTime d) =>
      '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';

  Widget _actor(ThemeData theme, String? id, String name) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      UserAvatar(
        user: _userFor(id, name),
        resolveUrl: widget.session.resolveUrl,
        radius: 10,
      ),
      const SizedBox(width: 6),
      Text(name, style: const TextStyle(fontSize: 12)),
    ],
  );

  /// 기록 탭 — 상태 구간별로 묶는다. 업무를 만들거나 상태를 바꾼 기록이 구간의 머리줄(상태
  /// 이름·날짜·한 사람)이 되고, 그 상태에 머무는 동안의 다른 기록들이 왼쪽 세로줄 아래로
  /// 달린다. 최근 구간이 위, 구간 안에서도 최근 기록이 위. 제목·설명을 바꾼 기록은 새 내용을
  /// 회색 상자로 함께 보여준다.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final task = widget.task;
    final list = task.activities;
    if (list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Text(
          '기록이 없습니다.',
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.hintColor, fontSize: 12),
        ),
      );
    }
    // 서버는 최신순으로 준다 — 오래된 것부터 훑으며 구간을 나눈다.
    final groups = <(TaskActivity?, List<TaskActivity>)>[];
    for (final a in list.reversed) {
      if (a.startsStatus || groups.isEmpty) {
        groups.add((a.startsStatus ? a : null, []));
        if (a.startsStatus) continue;
      }
      groups.last.$2.add(a);
    }
    final heads = <_HistoryHead>[];
    for (final (i, (head, items)) in groups.indexed) {
      if (head != null) {
        heads.add(
          _HistoryHead(
            key: head.id,
            name: head.detail ?? task.statusLabel,
            color: head.color != null
                ? parseTypeColor(head.color)
                : theme.hintColor,
            date: head.createdAt,
            actorId: head.actorId,
            actorName: head.actorName,
            tooltip: '${head.text} · ${formatDateTime(head.createdAt)}',
          ),
        );
        continue;
      }
      // 기록을 남기기 전에 만든 업무라 첫 구간의 머리줄이 없다 — 업무를 만든 날짜·사람과,
      // 그때 상태(뒤에 상태 변경 기록이 있으면 그 "이전 상태", 없으면 지금 상태)로 채운다.
      final next = i + 1 < groups.length ? groups[i + 1].$1 : null;
      final unchanged = next == null;
      heads.add(
        _HistoryHead(
          key: 'initial',
          name: unchanged
              ? task.statusLabel
              : (next.previous ?? task.statusLabel),
          color: unchanged && task.statusColor != null
              ? parseTypeColor(task.statusColor)
              : theme.hintColor,
          date: task.createdAt,
          actorId: task.creatorId ?? items.first.actorId,
          actorName: task.creatorName ?? items.first.actorName,
          tooltip: '업무를 만들었습니다. · ${formatDateTime(task.createdAt)}',
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, (_, items)) in groups.indexed.toList().reversed)
            _historyGroup(theme, heads[i], items.reversed.toList()),
        ],
      ),
    );
  }

  /// 상태 구간 하나 — 머리줄(상태 색 동그라미 · 상태 이름 · 날짜 · 꺾쇠 · 한 사람)과,
  /// 그 아래 상태 색 세로줄에 달린 기록들. 머리줄을 누르면 접고 편다.
  Widget _historyGroup(
    ThemeData theme,
    _HistoryHead head,
    List<TaskActivity> items,
  ) {
    final collapsed = _collapsed.contains(head.key);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Tooltip(
            message: head.tooltip,
            waitDuration: const Duration(milliseconds: 500),
            child: InkWell(
              onTap: items.isEmpty
                  ? null
                  : () => setState(
                      () => collapsed
                          ? _collapsed.remove(head.key)
                          : _collapsed.add(head.key),
                    ),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: head.color, width: 2.5),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        head.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: head.color,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _ymd(head.date),
                      style: TextStyle(fontSize: 12, color: theme.hintColor),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      collapsed ? Icons.chevron_right : Icons.expand_more,
                      size: 18,
                      color: items.isEmpty
                          ? theme.hintColor.withValues(alpha: 0.4)
                          : theme.hintColor,
                    ),
                    const Spacer(),
                    _actor(theme, head.actorId, head.actorName),
                  ],
                ),
              ),
            ),
          ),
          if (!collapsed && items.isNotEmpty)
            Container(
              // 동그라미 가운데(6px)에 세로줄이 오도록.
              margin: const EdgeInsets.only(left: 5),
              padding: const EdgeInsets.fromLTRB(17, 4, 0, 4),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: head.color.withValues(alpha: 0.6),
                    width: 2,
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final a in items) _historyItem(theme, a)],
              ),
            ),
        ],
      ),
    );
  }

  Widget _historyItem(ThemeData theme, TaskActivity a) {
    final dark = theme.brightness == Brightness.dark;
    final green = dark ? Colors.green.shade300 : const Color(0xFF16A34A);
    final hasNew = a.detail?.isNotEmpty ?? false;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Tooltip(
                  message: formatDateTime(a.createdAt),
                  waitDuration: const Duration(milliseconds: 500),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: a.text),
                        TextSpan(
                          text: '  ${formatRelativeTime(a.createdAt)}',
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.hintColor,
                          ),
                        ),
                      ],
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _actor(theme, a.actorId, a.actorName),
            ],
          ),
          // 제목 — "이전 제목(취소선) › 새 제목" 말풍선.
          if (a.kind == 'title' && hasNew)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (a.previous?.isNotEmpty ?? false) ...[
                    _valuePill(a.previous!, theme.hintColor, struck: true),
                    Icon(Icons.chevron_right, size: 16, color: theme.hintColor),
                  ],
                  _valuePill(a.detail!, green),
                ],
              ),
            ),
          // 설명 — 새 설명을 회색 상자로.
          if (a.kind == 'description' && hasNew)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: dark
                    ? Colors.white.withValues(alpha: 0.05)
                    : const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                a.detail!,
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: dark ? Colors.green.shade300 : const Color(0xFF2E7D32),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 기록의 값 말풍선 — 테두리와 글자를 같은 색으로. 이전 값은 취소선.
  Widget _valuePill(String text, Color color, {bool struck = false}) =>
      Container(
        constraints: const BoxConstraints(maxWidth: 360),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: color,
            decoration: struck ? TextDecoration.lineThrough : null,
            decorationColor: color,
          ),
        ),
      );
}

/// 기록 탭 상태 구간의 머리줄에 쓸 값.
class _HistoryHead {
  final String key;
  final String name;
  final Color color;
  final DateTime date;
  final String? actorId;
  final String actorName;
  final String tooltip;
  const _HistoryHead({
    required this.key,
    required this.name,
    required this.color,
    required this.date,
    required this.actorId,
    required this.actorName,
    required this.tooltip,
  });
}
