import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/wiki.dart';
import '../../services/api_client.dart' show ApiClient;
import '../../services/chat_socket.dart';
import '../../services/ot_text.dart';
import '../../services/session.dart';
import '../../services/wiki_doc.dart';
import '../../widgets/app_toast.dart';
import '../project/note_markdown.dart' show NoteBody;

/// 팀 위키 열기 — 지금 팀의 위키(서버 wiki.js).
Future<void> openWikiScreen(BuildContext context, Session session) {
  final team = session.currentTeam;
  if (team == null) {
    showAppToast(context, '팀을 먼저 고르세요.');
    return Future.value();
  }
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => WikiScreen(
        session: session,
        teamId: team.id,
        teamName: team.name,
        transport: ChatSocketWikiTransport(session.chatSocket),
      ),
    ),
  );
}

/// 앱의 소켓으로 위키 동시 편집(wiki_doc.dart의 통로).
class ChatSocketWikiTransport implements WikiTransport {
  final ChatSocket socket;
  ChatSocketWikiTransport(this.socket);

  @override
  void request(
    String event,
    Map<String, dynamic> payload,
    void Function(Map<String, dynamic>) onAck,
  ) => socket.wikiRequest(event, payload, onAck);

  @override
  void emit(String event, Map<String, dynamic> payload) =>
      socket.wikiEmit(event, payload);

  @override
  Stream<Map<String, dynamic>> get events => socket.wikiEvents;

  @override
  Stream<void> get reconnected => socket.reconnected;
}

String _date(DateTime? d) => d == null
    ? ''
    : '${d.year}/${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

Color _hexColor(String hex) {
  final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
  return v == null ? Colors.grey : Color(0xFF000000 | v);
}

/// 팀 위키 — 왼쪽 페이지 나무, 오른쪽 페이지(넓은 화면). 좁은 화면은 나무 → 페이지로 넘어간다. 페이지는 열자마자 동시 편집 문서에
/// 들어가 다른 사람의 변경이 바로 보이고, "편집"을 누르면 같은 글을 함께 고친다(OT — services/wiki_doc.dart).
class WikiScreen extends StatefulWidget {
  final Session session;
  final String teamId;
  final String teamName;
  final WikiTransport transport;
  final String? initialPageId;

  const WikiScreen({
    super.key,
    required this.session,
    required this.teamId,
    required this.teamName,
    required this.transport,
    this.initialPageId,
  });

  @override
  State<WikiScreen> createState() => _WikiScreenState();
}

class _WikiScreenState extends State<WikiScreen> {
  WikiTree? _tree;
  String? _error;
  late String? _selected = widget.initialPageId;
  StreamSubscription<Map<String, dynamic>>? _sub;

  ApiClient get _api => widget.session.api!;

  @override
  void initState() {
    super.initState();
    _sub = widget.transport.events.listen((e) {
      if (e['type'] == 'tree' && e['teamId'] == widget.teamId) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final tree = await _api.fetchWikiTree(widget.teamId);
      if (mounted) setState(() => _tree = tree);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _newPage({String? parentId}) async {
    final title = await _askText(
      context,
      parentId == null ? '새 페이지' : '하위 페이지',
      action: '만들기',
    );
    if (title == null || title.isEmpty) return;
    try {
      final row = await _api.createWikiPage(
        widget.teamId,
        title,
        parentId: parentId,
      );
      await _load();
      if (mounted) setState(() => _selected = row.id);
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    }
  }

  Future<void> _search() async {
    final id = await showDialog<String>(
      context: context,
      builder: (_) => _SearchDialog(api: _api, teamId: widget.teamId),
    );
    if (id != null && mounted) setState(() => _selected = id);
  }

  Future<void> _trash() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _TrashDialog(api: _api, teamId: widget.teamId),
    );
    await _load();
  }

  Widget _treePane() {
    final tree = _tree;
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '페이지',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                key: const ValueKey('wiki-search'),
                tooltip: '찾기',
                onPressed: _search,
                icon: const Icon(Icons.search, size: 20),
              ),
              IconButton(
                key: const ValueKey('wiki-trash'),
                tooltip: '휴지통',
                onPressed: _trash,
                icon: const Icon(Icons.delete_outline, size: 20),
              ),
              if (tree?.canEdit ?? false)
                IconButton(
                  key: const ValueKey('wiki-new-page'),
                  tooltip: '새 페이지',
                  onPressed: () => _newPage(),
                  icon: const Icon(Icons.note_add_outlined, size: 20),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: tree == null
              ? Center(
                  child: _error != null
                      ? Text(_error!)
                      : const CircularProgressIndicator(),
                )
              : tree.pages.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    tree.canEdit
                        ? '아직 페이지가 없습니다. 위의 + 로 첫 페이지를 만드세요.'
                        : '아직 페이지가 없습니다.',
                    style: TextStyle(color: hint),
                  ),
                )
              : ListView(
                  children: [
                    for (final p in tree.pages)
                      ListTile(
                        key: ValueKey('wiki-row-${p.id}'),
                        dense: true,
                        selected: p.id == _selected,
                        contentPadding: EdgeInsets.only(
                          left: 12.0 + p.depth * 16,
                          right: 8,
                        ),
                        leading: Icon(
                          p.depth == 0
                              ? Icons.article_outlined
                              : Icons.subdirectory_arrow_right,
                          size: 18,
                        ),
                        title: Text(
                          p.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => setState(() => _selected = p.id),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _pagePane() {
    final id = _selected;
    if (id == null) {
      return Center(
        child: Text(
          '왼쪽에서 페이지를 고르세요.',
          style: TextStyle(color: Theme.of(context).hintColor),
        ),
      );
    }
    return WikiPagePane(
      key: ValueKey('wiki-page-$id'),
      session: widget.session,
      pageId: id,
      transport: widget.transport,
      pages: _tree?.pages ?? const [],
      onOpenPage: (next) => setState(() => _selected = next),
      onNewChild: () => _newPage(parentId: id),
      onClosed: () {
        setState(() => _selected = null);
        _load();
      },
      onTreeChanged: _load,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 800;
        if (wide) {
          return Scaffold(
            appBar: AppBar(title: Text('위키 · ${widget.teamName}')),
            body: Row(
              children: [
                SizedBox(width: 280, child: _treePane()),
                const VerticalDivider(width: 1),
                Expanded(child: _pagePane()),
              ],
            ),
          );
        }
        // 좁은 화면 — 나무를 보다가 페이지를 고르면 페이지만(← 로 나무로).
        return PopScope(
          canPop: _selected == null,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) setState(() => _selected = null);
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text('위키 · ${widget.teamName}'),
              leading: _selected == null
                  ? null
                  : IconButton(
                      tooltip: '페이지 목록',
                      onPressed: () => setState(() => _selected = null),
                      icon: const Icon(Icons.arrow_back),
                    ),
            ),
            body: _selected == null ? _treePane() : _pagePane(),
          ),
        );
      },
    );
  }
}

/// 페이지 하나 — 동시 편집 문서에 들어가 본문을 보여 주고(보기: 마크다운), "편집"이면 같은 글을 함께 고친다. 위에는 함께 보고
/// 있는 사람과 다른 사람의 커서 줄, ⋯에 하위 페이지·제목 바꾸기·옮기기·판 기록·휴지통.
class WikiPagePane extends StatefulWidget {
  final Session session;
  final String pageId;
  final WikiTransport transport;
  final List<WikiPageRow> pages;
  final ValueChanged<String> onOpenPage;
  final VoidCallback onNewChild;
  final VoidCallback onClosed;
  final VoidCallback onTreeChanged;

  const WikiPagePane({
    super.key,
    required this.session,
    required this.pageId,
    required this.transport,
    required this.pages,
    required this.onOpenPage,
    required this.onNewChild,
    required this.onClosed,
    required this.onTreeChanged,
  });

  @override
  State<WikiPagePane> createState() => WikiPagePaneState();
}

class WikiPagePaneState extends State<WikiPagePane> {
  WikiPage? _page;
  String? _error;
  late final WikiDocSession doc = WikiDocSession(
    widget.transport,
    widget.pageId,
  );
  StreamSubscription<TextOp>? _remoteSub;
  final _editor = TextEditingController();
  final _editorFocus = FocusNode(debugLabel: 'wiki-editor');
  bool _editing = false;

  /// 다른 사람의 변경을 입력칸에 넣는 중 — 그 변경을 다시 내 변경으로 보내지 않게.
  bool _applyingRemote = false;
  TextSelection? _lastSentSelection;
  bool _toldLost = false;
  bool _closed = false;

  ApiClient get _api => widget.session.api!;

  @override
  void initState() {
    super.initState();
    _editor.addListener(_onEditorChanged);
    doc.addListener(_onDoc);
    _remoteSub = doc.remoteChanges.listen(_onRemote);
    _loadPage();
    unawaited(doc.open());
  }

  @override
  void dispose() {
    _remoteSub?.cancel();
    doc.removeListener(_onDoc);
    doc.dispose();
    _editor.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  Future<void> _loadPage() async {
    try {
      final page = await _api.fetchWikiPage(widget.pageId);
      if (mounted) setState(() => _page = page);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _onDoc() {
    if (!mounted) return;
    if (doc.removed && !_closed) {
      _closed = true;
      showAppToast(context, '이 페이지가 휴지통으로 옮겨졌습니다.');
      widget.onClosed();
      return;
    }
    if (doc.lostLocalEdits && !_toldLost) {
      _toldLost = true;
      showAppToast(context, '연결이 끊긴 동안 많이 바뀌어 내 마지막 수정 일부가 반영되지 못했습니다.');
    }
    // 들어간 직후 — 편집 중이면 입력칸을 문서 글로 맞춘다.
    if (_editing &&
        _editor.text != doc.text &&
        !_applyingRemote &&
        doc.synced) {
      _setEditorText(doc.text, _editor.selection);
    }
    setState(() {});
  }

  void _setEditorText(String text, TextSelection selection) {
    _applyingRemote = true;
    final len = text.length;
    _editor.value = TextEditingValue(
      text: text,
      selection: TextSelection(
        baseOffset: selection.baseOffset.clamp(0, len),
        extentOffset: selection.extentOffset.clamp(0, len),
      ),
    );
    _applyingRemote = false;
  }

  /// 다른 사람의 연산 — 내 커서·조합 중인 글자 범위를 그만큼 옮겨서 입력칸에 넣는다.
  void _onRemote(TextOp op) {
    if (!_editing) return;
    final v = _editor.value;
    final sel = v.selection.isValid
        ? v.selection
        : TextSelection.collapsed(offset: v.text.length);
    final composing = v.composing.isValid && !v.composing.isCollapsed
        ? TextRange(
            start: transformIndex(v.composing.start, op),
            end: transformIndex(v.composing.end, op),
          )
        : TextRange.empty;
    _applyingRemote = true;
    _editor.value = TextEditingValue(
      text: doc.text,
      selection: TextSelection(
        baseOffset: transformIndex(
          sel.baseOffset,
          op,
        ).clamp(0, doc.text.length),
        extentOffset: transformIndex(
          sel.extentOffset,
          op,
        ).clamp(0, doc.text.length),
      ),
      composing: composing,
    );
    _applyingRemote = false;
  }

  void _onEditorChanged() {
    if (_applyingRemote || !_editing) return;
    final v = _editor.value;
    if (v.text != doc.text) doc.localEdit(v.text);
    if (v.selection.isValid && v.selection != _lastSentSelection) {
      _lastSentSelection = v.selection;
      doc.sendCursor(v.selection.baseOffset, v.selection.extentOffset);
    }
  }

  void _toggleEdit() {
    setState(() => _editing = !_editing);
    if (_editing) {
      _setEditorText(
        doc.text,
        TextSelection.collapsed(offset: doc.text.length),
      );
      _editorFocus.requestFocus();
    }
  }

  Future<void> _action(String action) async {
    try {
      switch (action) {
        case 'child':
          widget.onNewChild();
        case 'rename':
          final title = await _askText(
            context,
            '제목 바꾸기',
            initial: doc.title,
            action: '바꾸기',
          );
          if (title == null || title.isEmpty || title == doc.title) return;
          await _api.updateWikiPage(widget.pageId, title: title);
          widget.onTreeChanged();
        case 'move':
          final target = await showDialog<({String? id})>(
            context: context,
            builder: (_) =>
                _MoveDialog(pages: widget.pages, pageId: widget.pageId),
          );
          if (target == null) return;
          await _api.updateWikiPage(
            widget.pageId,
            move: true,
            parentId: target.id,
          );
          widget.onTreeChanged();
          await _loadPage();
        case 'versions':
          await showDialog<void>(
            context: context,
            builder: (_) => _VersionsDialog(
              api: _api,
              pageId: widget.pageId,
              canEdit: doc.canEdit,
            ),
          );
        case 'delete':
          final ok = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('페이지 삭제'),
              content: Text("'${doc.title}'과(와) 그 아래 페이지를 휴지통으로 옮길까요?"),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(c).pop(false),
                  child: const Text('취소'),
                ),
                TextButton(
                  key: const ValueKey('wiki-delete-ok'),
                  onPressed: () => Navigator.of(c).pop(true),
                  child: const Text('휴지통으로'),
                ),
              ],
            ),
          );
          if (ok != true) return;
          await _api.deleteWikiPage(widget.pageId);
          _closed = true;
          widget.onClosed();
      }
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    }
  }

  /// 다른 사람 커서가 있는 줄(1부터).
  int _lineOf(int index) =>
      '\n'
          .allMatches(doc.text.substring(0, index.clamp(0, doc.text.length)))
          .length +
      1;

  Widget _presence() {
    final me = widget.session.userId;
    final others = doc.editors.where((e) => e.userId != me).toList();
    if (others.isEmpty) return const SizedBox.shrink();
    final hint = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        key: const ValueKey('wiki-presence'),
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('함께 보는 중', style: TextStyle(fontSize: 12, color: hint)),
          for (final e in others)
            Chip(
              visualDensity: VisualDensity.compact,
              avatar: CircleAvatar(
                backgroundColor: _hexColor(e.color),
                child: Text(
                  e.name.isEmpty ? '?' : e.name.characters.first,
                  style: const TextStyle(fontSize: 11, color: Colors.white),
                ),
              ),
              label: Text(
                doc.cursors[e.userId] == null
                    ? e.name
                    : '${e.name} · ${_lineOf(doc.cursors[e.userId]!.head)}행',
                style: const TextStyle(fontSize: 12),
              ),
              side: BorderSide(color: _hexColor(e.color)),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final page = _page;
    if (doc.error != null && page == null) {
      return Center(child: Text(doc.error!));
    }
    if (page == null && !doc.joined) {
      return Center(
        child: _error != null
            ? Text(_error!)
            : const CircularProgressIndicator(),
      );
    }
    final title = doc.joined ? doc.title : (page?.row.title ?? '');
    final body = doc.joined ? doc.text : (page?.body ?? '');
    final canEdit = doc.joined && doc.canEdit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (page != null && page.path.isNotEmpty)
                Wrap(
                  children: [
                    for (final p in page.path) ...[
                      InkWell(
                        onTap: () => widget.onOpenPage(p.id),
                        child: Text(
                          p.title,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                      Text(' / ', style: TextStyle(fontSize: 12, color: hint)),
                    ],
                  ],
                ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      key: const ValueKey('wiki-title'),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (doc.joined && !doc.synced)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        '저장 중…',
                        key: const ValueKey('wiki-saving'),
                        style: TextStyle(fontSize: 12, color: hint),
                      ),
                    ),
                  if (canEdit)
                    FilledButton.tonalIcon(
                      key: const ValueKey('wiki-edit'),
                      onPressed: _toggleEdit,
                      icon: Icon(
                        _editing
                            ? Icons.visibility_outlined
                            : Icons.edit_outlined,
                        size: 18,
                      ),
                      label: Text(_editing ? '보기' : '편집'),
                    ),
                  PopupMenuButton<String>(
                    key: const ValueKey('wiki-menu'),
                    tooltip: '더보기',
                    onSelected: _action,
                    itemBuilder: (_) => [
                      if (canEdit) ...[
                        const PopupMenuItem(
                          value: 'child',
                          child: Text('하위 페이지 만들기'),
                        ),
                        const PopupMenuItem(
                          value: 'rename',
                          child: Text('제목 바꾸기'),
                        ),
                        const PopupMenuItem(value: 'move', child: Text('옮기기')),
                      ],
                      const PopupMenuItem(
                        value: 'versions',
                        child: Text('판 기록'),
                      ),
                      if (page?.canRemove ?? false)
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('휴지통으로'),
                        ),
                    ],
                  ),
                ],
              ),
              if (page != null)
                Text(
                  [
                    if (page.row.updatedByName != null) page.row.updatedByName!,
                    _date(page.row.updatedAt),
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
              if (!doc.joined && doc.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '함께 편집하려면 연결이 필요합니다 — ${doc.error}',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              _presence(),
            ],
          ),
        ),
        const Divider(height: 16),
        Expanded(
          child: _editing
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: TextField(
                    key: const ValueKey('wiki-editor'),
                    controller: _editor,
                    focusNode: _editorFocus,
                    expands: true,
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(
                      fontSize: 14.5,
                      height: 1.5,
                      fontFamilyFallback: ['D2Coding', 'monospace'],
                    ),
                    decoration: const InputDecoration(
                      hintText:
                          '마크다운으로 쓰세요 — # 제목, - 목록, **굵게**, [링크](https://…)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                )
              : SingleChildScrollView(
                  key: const ValueKey('wiki-view'),
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  child: body.trim().isEmpty
                      ? Text(
                          canEdit ? '비어 있습니다. "편집"을 눌러 쓰세요.' : '비어 있습니다.',
                          style: TextStyle(color: hint),
                        )
                      : NoteBody(body, resolveUrl: widget.session.resolveUrl),
                ),
        ),
      ],
    );
  }
}

/// 글 하나 묻기 — 입력칸은 창이 닫히는 애니메이션이 끝난 뒤 정리되게 창이 들고 있는다.
Future<String?> _askText(
  BuildContext context,
  String title, {
  String initial = '',
  String action = '확인',
}) => showDialog<String>(
  context: context,
  builder: (_) => _TextDialog(title: title, initial: initial, action: action),
);

class _TextDialog extends StatefulWidget {
  final String title;
  final String initial;
  final String action;
  const _TextDialog({
    required this.title,
    required this.initial,
    required this.action,
  });

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const ValueKey('wiki-text-input'),
      controller: _c,
      autofocus: true,
      maxLength: 100,
      onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('취소'),
      ),
      FilledButton(
        key: const ValueKey('wiki-text-ok'),
        onPressed: () => Navigator.of(context).pop(_c.text.trim()),
        child: Text(widget.action),
      ),
    ],
  );
}

/// 옮길 위 페이지 고르기 — 자기와 그 아래는 고를 수 없다. (id: null)이면 맨 위.
class _MoveDialog extends StatelessWidget {
  final List<WikiPageRow> pages;
  final String pageId;
  const _MoveDialog({required this.pages, required this.pageId});

  @override
  Widget build(BuildContext context) {
    // 자기 아래(나무 차례에서 자기 다음에 오는 더 깊은 줄들)는 뺀다.
    final blocked = <String>{pageId};
    final start = pages.indexWhere((p) => p.id == pageId);
    if (start >= 0) {
      for (
        var i = start + 1;
        i < pages.length && pages[i].depth > pages[start].depth;
        i++
      ) {
        blocked.add(pages[i].id);
      }
    }
    return AlertDialog(
      title: const Text('옮길 곳'),
      content: SizedBox(
        width: 360,
        height: 360,
        child: ListView(
          children: [
            ListTile(
              key: const ValueKey('wiki-move-root'),
              dense: true,
              leading: const Icon(Icons.vertical_align_top),
              title: const Text('맨 위로'),
              onTap: () => Navigator.of(context).pop((id: null)),
            ),
            for (final p in pages)
              if (!blocked.contains(p.id))
                ListTile(
                  key: ValueKey('wiki-move-${p.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.only(left: 16.0 + p.depth * 16),
                  title: Text(p.title),
                  onTap: () => Navigator.of(context).pop((id: p.id)),
                ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
      ],
    );
  }
}

/// 판 기록 — 판을 눌러 보고, 그 판으로 되돌린다(지금 것은 서버가 먼저 판으로 남긴다).
class _VersionsDialog extends StatefulWidget {
  final ApiClient api;
  final String pageId;
  final bool canEdit;
  const _VersionsDialog({
    required this.api,
    required this.pageId,
    required this.canEdit,
  });

  @override
  State<_VersionsDialog> createState() => _VersionsDialogState();
}

class _VersionsDialogState extends State<_VersionsDialog> {
  List<WikiVersion>? _versions;
  WikiVersion? _open;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.api
        .fetchWikiVersions(widget.pageId)
        .then((v) {
          if (mounted) setState(() => _versions = v);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = '$e');
        });
  }

  Future<void> _show(WikiVersion v) async {
    try {
      final full = await widget.api.fetchWikiVersion(widget.pageId, v.id);
      if (mounted) setState(() => _open = full);
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    }
  }

  Future<void> _restore(WikiVersion v) async {
    try {
      await widget.api.restoreWikiVersion(widget.pageId, v.id);
      if (!mounted) return;
      showAppToast(context, '그 판으로 되돌렸습니다.');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final open = _open;
    final hint = Theme.of(context).hintColor;
    return AlertDialog(
      title: Text(open == null ? '판 기록' : '판 — ${_date(open.createdAt)}'),
      content: SizedBox(
        width: 520,
        height: 440,
        child: open != null
            ? SingleChildScrollView(child: NoteBody(open.body ?? ''))
            : _versions == null
            ? Center(
                child: _error != null
                    ? Text(_error!)
                    : const CircularProgressIndicator(),
              )
            : _versions!.isEmpty
            ? Center(
                child: Text(
                  '아직 남은 판이 없습니다. 편집하는 동안 10분마다, 모두 나가면 판이 남습니다.',
                  style: TextStyle(color: hint),
                ),
              )
            : ListView(
                children: [
                  for (final v in _versions!)
                    ListTile(
                      key: ValueKey('wiki-version-${v.id}'),
                      dense: true,
                      title: Text(_date(v.createdAt)),
                      subtitle: Text(
                        [
                          if (v.editorNames != null) v.editorNames!,
                          '${v.size}자',
                        ].join(' · '),
                      ),
                      onTap: () => _show(v),
                    ),
                ],
              ),
      ),
      actions: [
        if (open != null) ...[
          TextButton(
            onPressed: () => setState(() => _open = null),
            child: const Text('목록'),
          ),
          if (widget.canEdit)
            FilledButton(
              key: const ValueKey('wiki-version-restore'),
              onPressed: () => _restore(open),
              child: const Text('이 판으로 되돌리기'),
            ),
        ],
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}

class _SearchDialog extends StatefulWidget {
  final ApiClient api;
  final String teamId;
  const _SearchDialog({required this.api, required this.teamId});

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  List<WikiSearchHit>? _hits;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      if (q.trim().isEmpty) {
        if (mounted) setState(() => _hits = null);
        return;
      }
      final hits = await widget.api
          .searchWiki(widget.teamId, q.trim())
          .catchError((Object _) => <WikiSearchHit>[]);
      if (mounted) setState(() => _hits = hits);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final hits = _hits;
    return AlertDialog(
      title: const Text('위키에서 찾기'),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('wiki-search-input'),
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '제목·본문',
              ),
              onChanged: _changed,
            ),
            Expanded(
              child: hits == null
                  ? const SizedBox.shrink()
                  : hits.isEmpty
                  ? Center(
                      child: Text(
                        '찾는 페이지가 없습니다.',
                        style: TextStyle(color: hint),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final h in hits)
                          ListTile(
                            key: ValueKey('wiki-hit-${h.id}'),
                            title: Text(h.title),
                            subtitle: Text(
                              [
                                if (h.path.isNotEmpty) h.path,
                                h.excerpt,
                              ].join('\n'),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => Navigator.of(context).pop(h.id),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}

class _TrashDialog extends StatefulWidget {
  final ApiClient api;
  final String teamId;
  const _TrashDialog({required this.api, required this.teamId});

  @override
  State<_TrashDialog> createState() => _TrashDialogState();
}

class _TrashDialogState extends State<_TrashDialog> {
  List<WikiPageRow>? _rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await widget.api
        .fetchWikiTrash(widget.teamId)
        .catchError((Object _) => <WikiPageRow>[]);
    if (mounted) setState(() => _rows = rows);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return AlertDialog(
      title: const Text('위키 휴지통'),
      content: SizedBox(
        width: 420,
        height: 360,
        child: rows == null
            ? const Center(child: CircularProgressIndicator())
            : rows.isEmpty
            ? Center(
                child: Text(
                  '휴지통이 비어 있습니다.',
                  style: TextStyle(color: Theme.of(context).hintColor),
                ),
              )
            : ListView(
                children: [
                  for (final r in rows)
                    ListTile(
                      key: ValueKey('wiki-trash-${r.id}'),
                      title: Text(r.title),
                      subtitle: Text('${_date(r.deletedAt)} 삭제'),
                      trailing: r.canRemove
                          ? TextButton(
                              key: ValueKey('wiki-restore-${r.id}'),
                              onPressed: () async {
                                try {
                                  await widget.api.restoreWikiPage(r.id);
                                  await _load();
                                } catch (e) {
                                  if (context.mounted) {
                                    showAppToast(context, '$e');
                                  }
                                }
                              },
                              child: const Text('되살리기'),
                            )
                          : null,
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}
