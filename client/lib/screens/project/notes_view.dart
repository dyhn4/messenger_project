import 'package:flutter/material.dart';

import '../../models/project.dart';
import '../../services/session.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/floating_dialog.dart';
import '../../widgets/muted_scrollbar.dart';
import 'project_widgets.dart' show EmptyHint;

/// 프로젝트 노트 — 회의록·가이드 같은 문서를 프로젝트 구성원이 같이 쓰고 고친다.
/// [projectId]를 주면 그 프로젝트의 노트만(프로젝트 화면의 "노트" 탭), 없으면 내가 참여한 이 팀의
/// 모든 프로젝트 노트를 모아서(사이드바의 "노트") 보여준다.
///
/// 왼쪽은 검색+목록, 오른쪽은 읽기/편집. 좁은 화면(대화상자)에서는 목록과 내용을 번갈아 보여준다.
class NotesView extends StatefulWidget {
  final Session session;
  final String teamId;
  final String? projectId;
  final int reloadTick;

  const NotesView({
    super.key,
    required this.session,
    required this.teamId,
    this.projectId,
    required this.reloadTick,
  });

  @override
  State<NotesView> createState() => _NotesViewState();
}

class _NotesViewState extends State<NotesView> {
  List<ProjectNote>? _notes;
  List<Project> _projects = const [];
  String? _error;
  String _query = '';

  String? _selectedId;
  ProjectNote? _detail;
  bool _loadingDetail = false;

  bool _editing = false;
  String? _createProjectId;
  bool _saving = false;
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _listScroll = ScrollController();
  final _viewScroll = ScrollController();
  final _commentCtrl = TextEditingController();
  List<NoteComment> _comments = const [];

  bool get _creating => _createProjectId != null;

  @override
  void initState() {
    super.initState();
    _loadList();
  }

  @override
  void didUpdateWidget(NotesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadTick != widget.reloadTick) {
      _loadList();
      // 다른 사람이 지금 보고 있는 노트를 고쳤을 수 있다 — 내가 편집 중이 아닐 때만 새로 읽는다.
      if (_selectedId != null && !_editing) _loadDetail(_selectedId!);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _commentCtrl.dispose();
    _listScroll.dispose();
    _viewScroll.dispose();
    super.dispose();
  }

  Future<void> _loadList() async {
    try {
      final api = widget.session.api!;
      final results = await Future.wait([
        api.fetchNotes(
          projectId: widget.projectId,
          teamId: widget.projectId == null ? widget.teamId : null,
        ),
        api.fetchProjects(widget.teamId),
      ]);
      if (!mounted) return;
      final notes = results[0] as List<ProjectNote>;
      setState(() {
        _notes = notes;
        _projects = results[1] as List<Project>;
        _error = null;
        if (_selectedId != null && !notes.any((n) => n.id == _selectedId)) {
          _selectedId = null;
          _detail = null;
          _editing = false;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _loadDetail(String id) async {
    setState(() => _loadingDetail = true);
    try {
      final api = widget.session.api!;
      final note = await api.fetchNote(id);
      final comments = await api.fetchNoteComments(id);
      if (mounted && _selectedId == id) {
        setState(() {
          _detail = note;
          _comments = comments;
        });
      }
    } catch (e) {
      if (mounted) showAppToast(context, '노트를 불러오지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _loadingDetail = false);
    }
  }

  bool get _dirty {
    if (!_editing) return false;
    if (_creating) return _title.text.isNotEmpty || _body.text.isNotEmpty;
    final d = _detail;
    return d != null &&
        (_title.text != d.title || _body.text != (d.body ?? ''));
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('작성 중인 내용이 있습니다'),
        content: const Text('저장하지 않고 나가면 고친 내용이 사라집니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('계속 작성'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('버리기'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _select(ProjectNote note) async {
    if (note.id == _selectedId && !_creating) return;
    if (!await _confirmDiscard()) return;
    setState(() {
      _selectedId = note.id;
      _detail = null;
      _comments = const [];
      _editing = false;
      _createProjectId = null;
    });
    await _loadDetail(note.id);
  }

  Future<void> _startCreate(String projectId) async {
    if (!await _confirmDiscard()) return;
    setState(() {
      _selectedId = null;
      _detail = null;
      _createProjectId = projectId;
      _editing = true;
      _title.clear();
      _body.clear();
    });
  }

  Future<void> _newNote() async {
    if (_projects.isEmpty) {
      showAppToast(context, '참여 중인 프로젝트가 없습니다.');
      return;
    }
    final fixed = widget.projectId;
    if (fixed != null) {
      await _startCreate(fixed);
      return;
    }
    if (_projects.length == 1) {
      await _startCreate(_projects.first.id);
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('어느 프로젝트의 노트인가요?'),
        children: [
          for (final p in _projects)
            SimpleDialogOption(
              onPressed: () => Navigator.of(c).pop(p.id),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: parseTypeColor(p.color),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(p.name, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked != null) await _startCreate(picked);
  }

  void _startEdit() {
    final d = _detail;
    if (d == null) return;
    setState(() {
      _editing = true;
      _title.text = d.title;
      _body.text = d.body ?? '';
    });
  }

  Future<void> _cancelEdit() async {
    if (!await _confirmDiscard()) return;
    setState(() {
      _editing = false;
      _createProjectId = null;
    });
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      showAppToast(context, '노트 제목을 입력하세요.');
      return;
    }
    setState(() => _saving = true);
    try {
      final api = widget.session.api!;
      final ProjectNote saved;
      if (_creating) {
        saved = await api.createNote(
          _createProjectId!,
          title: title,
          body: _body.text,
        );
      } else {
        saved = await api.updateNote(
          _selectedId!,
          title: title,
          body: _body.text,
          baseUpdatedAt: _detail?.updatedAt,
        );
      }
      if (!mounted) return;
      setState(() {
        _selectedId = saved.id;
        _detail = saved;
        _editing = false;
        _createProjectId = null;
      });
      await _loadList();
    } catch (e) {
      if (mounted) showAppToast(context, '저장하지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addComment() async {
    final text = _commentCtrl.text.trim();
    final id = _selectedId;
    if (text.isEmpty || id == null) return;
    _commentCtrl.clear();
    try {
      await widget.session.api!.addNoteComment(id, text);
      final comments = await widget.session.api!.fetchNoteComments(id);
      if (mounted) setState(() => _comments = comments);
    } catch (e) {
      if (mounted) showAppToast(context, '댓글을 남기지 못했습니다: $e');
    }
  }

  bool _canDeleteComment(NoteComment c, ProjectNote note) {
    if (c.senderId == widget.session.userId) return true;
    if (widget.session.canManageCurrentTeam) return true;
    return _projects.any((p) => p.id == note.projectId && p.isOwner);
  }

  Future<void> _deleteComment(NoteComment c) async {
    try {
      await widget.session.api!.deleteNoteComment(c.id);
      final comments = await widget.session.api!.fetchNoteComments(c.noteId);
      if (mounted) setState(() => _comments = comments);
    } catch (e) {
      if (mounted) showAppToast(context, '댓글을 지우지 못했습니다: $e');
    }
  }

  Future<void> _openHistory(ProjectNote note) async {
    final restored = await showDialog<ProjectNote>(
      context: context,
      builder: (_) => _NoteHistoryDialog(session: widget.session, note: note),
    );
    if (restored != null && mounted) {
      setState(() => _detail = restored);
      showAppToast(context, '이전 버전으로 되돌렸습니다.');
      await _loadList();
    }
  }

  bool _canDelete(ProjectNote note) {
    if (note.createdBy == widget.session.userId) return true;
    if (widget.session.canManageCurrentTeam) return true;
    return _projects.any((p) => p.id == note.projectId && p.isOwner);
  }

  Future<void> _delete(ProjectNote note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('노트 삭제'),
        content: Text("'${note.title}' 노트를 삭제할까요? 되돌릴 수 없습니다."),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.session.api!.deleteNote(note.id);
      if (!mounted) return;
      setState(() {
        _selectedId = null;
        _detail = null;
        _editing = false;
      });
      await _loadList();
    } catch (e) {
      if (mounted) showAppToast(context, '삭제하지 못했습니다: $e');
    }
  }

  // ───────────────────────── 화면 ─────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    if (_notes == null) return const Center(child: CircularProgressIndicator());
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        final showingDetail = _selectedId != null || _creating;
        if (wide) {
          return Row(
            children: [
              SizedBox(width: 300, child: _buildList()),
              const VerticalDivider(width: 1),
              Expanded(child: _buildDetail(showBack: false)),
            ],
          );
        }
        return showingDetail ? _buildDetail(showBack: true) : _buildList();
      },
    );
  }

  Widget _buildList() {
    final hint = Theme.of(context).hintColor;
    final q = _query.trim().toLowerCase();
    final notes = [
      for (final n in _notes!)
        if (q.isEmpty ||
            n.title.toLowerCase().contains(q) ||
            (n.preview ?? '').toLowerCase().contains(q))
          n,
    ];
    final scoped = widget.projectId != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  scoped ? '노트' : '전체 노트',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              FilledButton.icon(
                onPressed: _newNote,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('새 노트'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            decoration: const InputDecoration(
              hintText: '노트 검색',
              prefixIcon: Icon(Icons.search, size: 18),
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: notes.isEmpty
              ? EmptyHint(
                  _notes!.isEmpty
                      ? '아직 노트가 없습니다. "새 노트"로 시작해보세요.'
                      : '검색 결과가 없습니다.',
                )
              : MutedScrollbar(
                  controller: _listScroll,
                  child: ListView.builder(
                    controller: _listScroll,
                    itemCount: notes.length,
                    itemBuilder: (context, i) {
                      final n = notes[i];
                      final selected = n.id == _selectedId;
                      return ListTile(
                        dense: true,
                        selected: selected,
                        selectedTileColor: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.08),
                        title: Text(
                          n.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if ((n.preview ?? '').trim().isNotEmpty)
                              Text(
                                n.preview!.replaceAll('\n', ' '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                if (!scoped && n.projectName != null) ...[
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: parseTypeColor(n.projectColor),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      n.projectName!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: hint,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    ' · ',
                                    style: TextStyle(color: hint, fontSize: 11),
                                  ),
                                ],
                                Text(
                                  _formatWhen(n.updatedAt),
                                  style: TextStyle(color: hint, fontSize: 11),
                                ),
                              ],
                            ),
                          ],
                        ),
                        onTap: () => _select(n),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildDetail({required bool showBack}) {
    final hint = Theme.of(context).hintColor;
    final back = showBack
        ? IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: '목록',
            onPressed: () async {
              if (!await _confirmDiscard()) return;
              setState(() {
                _selectedId = null;
                _detail = null;
                _editing = false;
                _createProjectId = null;
              });
            },
          )
        : null;

    if (_editing) return _buildEditor(back);

    final note = _detail;
    if (_selectedId == null) {
      return const Center(child: EmptyHint('노트를 선택하거나 새로 만들어보세요.'));
    }
    if (note == null) {
      return Column(
        children: [
          if (back != null) Align(alignment: Alignment.centerLeft, child: back),
          const Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              ?back,
              Expanded(
                child: Text(
                  note.title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              if (_loadingDetail)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.history),
                tooltip: '수정 이력',
                onPressed: () => _openHistory(note),
              ),
              OutlinedButton.icon(
                onPressed: _startEdit,
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('편집'),
              ),
              if (_canDelete(note))
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '삭제',
                  onPressed: () => _delete(note),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            [
              if (widget.projectId == null && note.projectName != null)
                note.projectName!,
              '${note.createdByName ?? '알 수 없음'} 작성',
              if (note.updatedAt.difference(note.createdAt).inSeconds > 1)
                '${note.updatedByName ?? '알 수 없음'} 수정 ${_formatWhen(note.updatedAt)}'
              else
                _formatWhen(note.createdAt),
            ].join(' · '),
            style: TextStyle(color: hint, fontSize: 12),
          ),
        ),
        const Divider(height: 20),
        Expanded(
          child: MutedScrollbar(
            controller: _viewScroll,
            child: SingleChildScrollView(
              controller: _viewScroll,
              padding: const EdgeInsets.fromLTRB(16, 0, 26, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SelectionArea(child: NoteBody(note.body ?? '')),
                  const SizedBox(height: 24),
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  Text(
                    '댓글 ${_comments.length}',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  if (_comments.isEmpty)
                    Text('아직 댓글이 없습니다.', style: TextStyle(color: hint))
                  else
                    for (final c in _comments)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${c.senderName} · ${_formatWhen(c.createdAt)}',
                                    style: TextStyle(color: hint, fontSize: 11),
                                  ),
                                  const SizedBox(height: 2),
                                  SelectableText(c.text),
                                ],
                              ),
                            ),
                            if (_canDeleteComment(c, note))
                              IconButton(
                                icon: const Icon(Icons.close, size: 16),
                                tooltip: '댓글 삭제',
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _deleteComment(c),
                              ),
                          ],
                        ),
                      ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _commentCtrl,
                          decoration: const InputDecoration(
                            hintText: '댓글 남기기',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _addComment(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _addComment,
                        child: const Text('등록'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEditor(Widget? back) {
    final hint = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ?back,
              Expanded(
                child: Text(
                  _creating ? '새 노트' : '노트 편집',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              TextButton(
                onPressed: _saving ? null : _cancelEdit,
                child: const Text('취소'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: const Text('저장'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _title,
            autofocus: true,
            maxLength: 100,
            decoration: const InputDecoration(
              labelText: '제목',
              counterText: '',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: TextField(
              controller: _body,
              expands: true,
              maxLines: null,
              minLines: null,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                labelText: '내용',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '# 제목 · ## 소제목 · - 목록 · - [ ] 체크 · > 인용 · --- 구분선',
            style: TextStyle(color: hint, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

String _formatWhen(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

/// 노트 본문 — 가벼운 마크다운(제목 #/##/###, 목록 -, 체크 - [ ] / - [x], 인용 >, 구분선 ---)만
/// 줄 단위로 그린다. 그 밖의 글은 그대로 보여준다.
class NoteBody extends StatelessWidget {
  final String text;
  const NoteBody(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final widgets = <Widget>[];
    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        widgets.add(const SizedBox(height: 10));
      } else if (line.startsWith('### ')) {
        widgets.add(
          _pad(
            Text(
              line.substring(4),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            top: 6,
          ),
        );
      } else if (line.startsWith('## ')) {
        widgets.add(
          _pad(
            Text(
              line.substring(3),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            top: 8,
          ),
        );
      } else if (line.startsWith('# ')) {
        widgets.add(
          _pad(
            Text(
              line.substring(2),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            top: 10,
          ),
        );
      } else if (line.trim() == '---') {
        widgets.add(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(height: 1),
          ),
        );
      } else if (RegExp(r'^\s*[-*] \[( |x|X)\] ').hasMatch(line)) {
        final checked = RegExp(r'^\s*[-*] \[[xX]\] ').hasMatch(line);
        final body = line.replaceFirst(RegExp(r'^\s*[-*] \[( |x|X)\] '), '');
        widgets.add(
          _pad(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  checked ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 18,
                  color: checked ? theme.colorScheme.primary : hint,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    body,
                    style: checked
                        ? TextStyle(
                            color: hint,
                            decoration: TextDecoration.lineThrough,
                          )
                        : null,
                  ),
                ),
              ],
            ),
          ),
        );
      } else if (RegExp(r'^\s*[-*] ').hasMatch(line)) {
        final indent = line.length - line.trimLeft().length;
        widgets.add(
          Padding(
            padding: EdgeInsets.only(left: 4.0 + indent * 6, top: 2, bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  '),
                Expanded(child: Text(line.trimLeft().substring(2))),
              ],
            ),
          ),
        );
      } else if (line.startsWith('> ')) {
        widgets.add(
          Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.only(left: 10),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: hint, width: 3)),
            ),
            child: Text(line.substring(2), style: TextStyle(color: hint)),
          ),
        );
      } else {
        widgets.add(_pad(Text(line)));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  static Widget _pad(Widget child, {double top = 2}) => Padding(
    padding: EdgeInsets.only(top: top, bottom: 2),
    child: child,
  );
}

/// 노트 수정 이력 — 왼쪽에 이전 버전들(최근 30개), 오른쪽에 고른 버전의 내용. "이 버전으로 되돌리기"를
/// 누르면 노트가 그 내용으로 바뀌고(되돌리기 직전 내용도 이력에 남는다) 되돌려진 노트를 돌려준다.
class _NoteHistoryDialog extends StatefulWidget {
  final Session session;
  final ProjectNote note;
  const _NoteHistoryDialog({required this.session, required this.note});

  @override
  State<_NoteHistoryDialog> createState() => _NoteHistoryDialogState();
}

class _NoteHistoryDialogState extends State<_NoteHistoryDialog> {
  List<NoteVersion>? _versions;
  NoteVersion? _selected;
  String? _error;
  bool _restoring = false;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.session.api!
        .fetchNoteVersions(widget.note.id)
        .then((list) {
          if (mounted) setState(() => _versions = list);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e.toString());
        });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _select(NoteVersion v) async {
    try {
      final full = await widget.session.api!.fetchNoteVersion(v.id);
      if (mounted) setState(() => _selected = full);
    } catch (e) {
      if (mounted) showAppToast(context, '이력을 불러오지 못했습니다: $e');
    }
  }

  Future<void> _restore() async {
    final v = _selected;
    if (v == null) return;
    setState(() => _restoring = true);
    try {
      final note = await widget.session.api!.restoreNoteVersion(
        widget.note.id,
        v.id,
      );
      if (mounted) Navigator.of(context).pop(note);
    } catch (e) {
      if (mounted) {
        setState(() => _restoring = false);
        showAppToast(context, '되돌리지 못했습니다: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final versions = _versions;
    return FloatingDialog(
      title: '수정 이력 · ${widget.note.title}',
      maxWidth: 820,
      maxHeight: 620,
      child: _error != null
          ? Center(child: Text(_error!))
          : versions == null
          ? const Center(child: CircularProgressIndicator())
          : versions.isEmpty
          ? Center(
              child: Text('아직 수정 이력이 없습니다.', style: TextStyle(color: hint)),
            )
          : Row(
              children: [
                SizedBox(
                  width: 250,
                  child: ListView(
                    children: [
                      for (final v in versions)
                        ListTile(
                          dense: true,
                          selected: _selected?.id == v.id,
                          title: Text(
                            _formatWhen(v.editedAt),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            '${v.editedByName ?? '알 수 없음'} · ${v.title}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _select(v),
                        ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _selected == null
                      ? Center(
                          child: Text(
                            '왼쪽에서 버전을 고르면 그때의 내용이 보입니다.',
                            style: TextStyle(color: hint),
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 0, 8),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      _selected!.title,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                  ),
                                  FilledButton(
                                    onPressed: _restoring ? null : _restore,
                                    child: const Text('이 버전으로 되돌리기'),
                                  ),
                                ],
                              ),
                            ),
                            const Divider(height: 1),
                            Expanded(
                              child: MutedScrollbar(
                                controller: _scroll,
                                child: SingleChildScrollView(
                                  controller: _scroll,
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    12,
                                    24,
                                    16,
                                  ),
                                  child: SelectionArea(
                                    child: NoteBody(_selected!.body ?? ''),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
    );
  }
}
