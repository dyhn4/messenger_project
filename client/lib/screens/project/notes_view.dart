import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/app_user.dart';
import '../../models/project.dart';
import '../../services/app_links.dart';
import '../../services/session.dart';
import '../../services/time_format.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/dashed_add_button.dart';
import '../../widgets/floating_dialog.dart';
import '../../widgets/hover_toolbar.dart' show hoverMenuItem;
import '../../widgets/muted_scrollbar.dart';
import '../../widgets/user_avatar.dart';
import '../../widgets/rich_text_format.dart';
import 'note_markdown.dart';
import 'note_task_links.dart';
import 'task_comments_section.dart';
import 'project_widgets.dart' show EmptyHint;

/// 목록 정렬.
enum _NoteSort { created, updated, title }

String _sortLabel(_NoteSort s) => switch (s) {
  _NoteSort.created => '생성순',
  _NoteSort.updated => '수정순',
  _NoteSort.title => '제목순',
};

String _ymdKo(DateTime t) {
  final l = t.toLocal();
  return '${l.year}년 ${l.month}월 ${l.day}일';
}

/// 프로젝트 노트 — 회의록·가이드 같은 문서를 프로젝트 구성원이 같이 쓰고 고친다.
/// [projectId]를 주면 그 프로젝트의 노트만(프로젝트 화면의 "노트" 탭), 없으면 내가 참여한 이 팀의
/// 모든 프로젝트 노트를 모아서(사이드바의 "노트") 보여준다.
///
/// 두 가지 모양:
/// - 목록 — 아무 노트도 열지 않았을 때. 검색·프로젝트·정렬 아래로 노트를 크게 늘어놓는다.
/// - 노트 — 노트를 열었거나 새로 쓸 때. 왼쪽에 좁은 목록(접을 수 있음, "계층형"이면 프로젝트별로
///   묶음), 오른쪽에 읽기 화면이나 편집기.
class NotesView extends StatefulWidget {
  final Session session;
  final String teamId;
  final String? projectId;
  final int reloadTick;

  /// 노트 링크로 열 노트 — [openNoteTick]이 바뀔 때마다 그 노트를 연다.
  final String? openNoteId;
  final int openNoteTick;

  /// 프로젝트의 "노트" 탭에서 연 오른쪽 노트 패널이면 true — 머리줄에 크게 보기(⤢)·닫기(✕)가
  /// 붙고, 목록은 팀 전체 노트를 받아 [projectId]로 거른 채 시작한다(드롭다운으로 바꿀 수 있다).
  final bool panelMode;
  final bool panelExpanded;
  final VoidCallback? onToggleExpand;
  final VoidCallback? onClose;

  const NotesView({
    super.key,
    required this.session,
    required this.teamId,
    this.projectId,
    required this.reloadTick,
    this.openNoteId,
    this.openNoteTick = 0,
    this.panelMode = false,
    this.panelExpanded = false,
    this.onToggleExpand,
    this.onClose,
  });

  @override
  State<NotesView> createState() => _NotesViewState();
}

class _NotesViewState extends State<NotesView> {
  List<ProjectNote>? _notes;
  List<Project> _projects = const [];
  String? _error;

  // 목록 거르기
  String _query = '';
  late String? _projectFilter = widget.panelMode ? widget.projectId : null;

  /// 목록을 한 프로젝트로 고정하는지(프로젝트의 "노트" 탭 안). 패널은 팀 전체를 받고 거른다.
  String? get _scopedProjectId => widget.panelMode ? null : widget.projectId;
  _NoteSort _sort = _NoteSort.created;
  bool _tree = false;
  bool _listCollapsed = false;

  String? _selectedId;
  ProjectNote? _detail;
  bool _loadingDetail = false;

  /// 노트 내용을 못 불러왔을 때의 안내(돌기만 하는 표시 대신 보여준다).
  String? _detailError;

  bool _editing = false;

  /// 편집하다가 저장이 권한 때문에 막혔고 서버도 이제 고칠 수 없다고 하면 true — 편집기를 읽기
  /// 전용으로 바꾼다(쓰던 글은 복사할 수 있게 남겨 둔다).
  bool _editLocked = false;

  /// 편집기를 잠글 때 서버에서 새로 받은 노트 — 편집을 끝내면 이걸로 [_detail]을 바꿔 낡은
  /// canEdit으로 '수정'·되돌리기가 다시 보이지 않게 한다.
  ProjectNote? _lockedNote;

  /// 새 노트를 쓰는 중이면 그 노트가 들어갈 프로젝트(아래 선택 칸으로 바꾼다).
  String? _createProjectId;
  bool _saving = false;
  bool _uploading = false;
  final _title = TextEditingController();
  final _body = RichTextEditingController();
  final _bodyFocus = FocusNode();

  /// 편집을 시작한 순간의 본문(마크다운) — 고쳤는지 비교할 기준.
  String _baseline = '';
  String _baselineTitle = '';

  final _searchCtrl = TextEditingController();
  final _listScroll = ScrollController();
  final _viewScroll = ScrollController();

  List<NoteComment> _comments = const [];

  bool get _creating => _createProjectId != null;
  bool get _noteOpen => _selectedId != null || _creating;

  @override
  void initState() {
    super.initState();
    _title.addListener(_refresh);
    _loadList();
    if (widget.openNoteId != null) _openById(widget.openNoteId!);
  }

  /// 링크로 들어온 노트를 연다(목록에 아직 없어도 id로 바로 읽는다).
  Future<void> _openById(String id) async {
    if (!await _confirmDiscard()) return;
    if (!mounted) return;
    setState(() {
      _selectedId = id;
      _detail = null;
      _comments = const [];
      _editing = false;
      _createProjectId = null;
    });
    await _loadDetail(id);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(NotesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.panelMode && oldWidget.projectId != widget.projectId) {
      _projectFilter = widget.projectId;
    }
    if (oldWidget.projectId != widget.projectId) {
      // 다른 프로젝트의 노트 화면이 되었으니 고르고 있던 노트를 놓는다.
      _selectedId = null;
      _detail = null;
      _comments = const [];
      _editing = false;
      _createProjectId = null;
      _loadList();
      return;
    }
    if (oldWidget.openNoteTick != widget.openNoteTick &&
        widget.openNoteId != null) {
      _openById(widget.openNoteId!);
    }
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
    _bodyFocus.dispose();
    _searchCtrl.dispose();
    _listScroll.dispose();
    _viewScroll.dispose();
    super.dispose();
  }

  Future<void> _loadList() async {
    try {
      final api = widget.session.api!;
      final results = await Future.wait([
        api.fetchNotes(
          projectId: _scopedProjectId,
          teamId: _scopedProjectId == null ? widget.teamId : null,
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
    setState(() {
      _loadingDetail = true;
      _detailError = null;
    });
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
      if (mounted && _selectedId == id) {
        setState(() => _detailError = '노트를 불러오지 못했습니다: $e');
      }
    } finally {
      if (mounted) setState(() => _loadingDetail = false);
    }
  }

  // ── 편집 ──

  String _currentMarkdown() {
    final f = _body.formatted();
    return noteRichToMarkdown(f.text, f.format);
  }

  bool get _dirty {
    if (!_editing) return false;
    return _title.text.trim() != _baselineTitle ||
        _currentMarkdown() != _baseline;
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

  /// 편집기를 [title]·[body](마크다운)로 채운다.
  void _fillEditor(String title, String body) {
    _title.text = title;
    final r = noteMarkdownToRich(body);
    _body.load(r.text, r.runs);
    _baselineTitle = title.trim();
    _baseline = _currentMarkdown();
  }

  Future<void> _select(ProjectNote note) async {
    if (note.id == _selectedId && !_creating && !_editing) return;
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

  /// 노트를 닫고 목록 화면으로.
  Future<void> _closeNote() async {
    if (!await _confirmDiscard()) return;
    setState(() {
      _selectedId = null;
      _detail = null;
      _editing = false;
      _createProjectId = null;
    });
  }

  Future<void> _newNote() async {
    if (_projects.isEmpty) {
      showAppToast(context, '참여 중인 프로젝트가 없습니다.');
      return;
    }
    if (!await _confirmDiscard()) return;
    final projectId =
        _scopedProjectId ??
        (_projects.any((p) => p.id == _projectFilter)
            ? _projectFilter!
            : _projects.first.id);
    setState(() {
      _selectedId = null;
      _detail = null;
      _createProjectId = projectId;
      _editing = true;
      _editLocked = false;
      _fillEditor('', '');
    });
  }

  void _startEdit() {
    final d = _detail;
    // 노트 수정 권한(프로젝트 설정 > 노트)은 서버가 사람마다 계산해 준다.
    if (d == null || !d.canEdit) return;
    setState(() {
      _editing = true;
      _editLocked = false;
      _fillEditor(d.title, d.body ?? '');
    });
  }

  Future<void> _cancelEdit() async {
    if (!await _confirmDiscard()) return;
    final fresh = _editLocked ? _lockedNote : null;
    setState(() {
      _editing = false;
      _editLocked = false;
      _lockedNote = null;
      _createProjectId = null;
      if (fresh != null && fresh.id == _selectedId) _detail = fresh;
    });
    // 삭제 권한도 같이 바뀌었을 수 있다 — 목록의 ✕를 맞춘다.
    if (fresh != null) await _loadList();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      showAppToast(context, '노트 제목을 입력하세요.');
      return;
    }
    final body = _currentMarkdown();
    setState(() => _saving = true);
    try {
      final api = widget.session.api!;
      final ProjectNote saved;
      if (_creating) {
        saved = await api.createNote(
          _createProjectId!,
          title: title,
          body: body,
        );
      } else {
        saved = await api.updateNote(
          _selectedId!,
          title: title,
          body: body,
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
      await _loadDetail(saved.id);
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, '저장하지 못했습니다: $e');
      final id = _selectedId;
      if (!_creating && id != null) _recheckEditPermission(id);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 저장이 실패했을 때 — 그 사이 노트 수정 권한이 바뀌었을 수 있어 다시 물어보고, 이제 고칠 수 없으면
  /// 편집기를 읽기 전용으로 바꾼다. 충돌 검사 기준(열 때의 수정 시각)이 바뀌지 않게 [_detail]은 그대로 둔다.
  Future<void> _recheckEditPermission(String id) async {
    try {
      final fresh = await widget.session.api!.fetchNote(id);
      if (!mounted || _selectedId != id || fresh.canEdit) return;
      setState(() {
        if (_editing) {
          _editLocked = true;
          _lockedNote = fresh;
        } else {
          // 다시 묻는 사이에 편집을 그만뒀으면 보기 화면의 메뉴만 맞춘다.
          _detail = fresh;
        }
      });
    } catch (_) {
      // 다시 묻지 못해도 편집기는 그대로 둔다(저장 실패 안내는 이미 했다).
    }
  }

  /// 표 넣기 — 2칸짜리 머리글 + 빈 줄 하나.
  void _insertTable() {
    _body.insertBlock('| 항목 | 내용 |\n| --- | --- |\n|  |  |');
    _bodyFocus.requestFocus();
  }

  /// 그림 넣기 — 골라서 올리고, 본문에 그림 줄을 넣는다(보기 화면에서 그림으로 보인다).
  Future<void> _insertImage() async {
    final picked = await FilePicker.pickFiles(type: FileType.image);
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final up = await widget.session.api!.uploadFile(File(path));
      final name = picked!.files.single.name;
      _body.insertBlock(
        '$noteImagePrefix$name',
        href: '$noteImageHref${up.url}',
      );
      _bodyFocus.requestFocus();
    } catch (e) {
      if (mounted) showAppToast(context, '그림을 올리지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// 노트 복제 — 같은 프로젝트에 "제목 (복사본)"으로 본문까지 그대로 만들고 새 노트를 연다.
  Future<void> _duplicate(ProjectNote note) async {
    try {
      final body =
          note.body ?? (await widget.session.api!.fetchNote(note.id)).body;
      final copy = await widget.session.api!.createNote(
        note.projectId,
        title: '${note.title} (복사본)',
        body: body ?? '',
      );
      if (!mounted) return;
      await _loadList();
      if (!mounted) return;
      setState(() {
        _selectedId = copy.id;
        _detail = copy;
        _editing = false;
      });
      await _loadDetail(copy.id);
      if (mounted) showAppToast(context, '노트를 복제했습니다.');
    } catch (e) {
      if (mounted) showAppToast(context, '복제하지 못했습니다: $e');
    }
  }

  // ── 댓글 · 이력 · 삭제 ──

  Future<void> _reloadComments(String noteId) async {
    final comments = await widget.session.api!.fetchNoteComments(noteId);
    if (mounted && _selectedId == noteId) setState(() => _comments = comments);
  }

  /// 댓글 저장·수정·삭제를 하고 목록을 다시 읽는다. 실패하면 알린다.
  Future<void> _commentAction(
    String noteId,
    Future<void> Function() run,
  ) async {
    try {
      await run();
      await _reloadComments(noteId);
    } catch (e) {
      if (mounted) showAppToast(context, '댓글을 저장하지 못했습니다: $e');
    }
  }

  /// 남의 댓글도 지울 수 있는지 — 팀 관리자나 그 프로젝트 담당자.
  bool _canModerateComments(ProjectNote note) =>
      widget.session.canManageCurrentTeam ||
      _projects.any((p) => p.id == note.projectId && p.isOwner);

  Future<void> _openHistory(ProjectNote note) async {
    final restored = await showDialog<ProjectNote>(
      context: context,
      builder: (_) => _NoteHistoryDialog(
        session: widget.session,
        note: note,
        // 되돌리기도 노트를 고치는 것이라 수정 권한이 있어야 한다.
        canRestore: note.canEdit,
      ),
    );
    if (restored != null && mounted) {
      setState(() => _detail = restored);
      showAppToast(context, '이전 버전으로 되돌렸습니다.');
      await _loadList();
    }
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
      if (_selectedId == note.id) {
        setState(() {
          _selectedId = null;
          _detail = null;
          _editing = false;
        });
      }
      await _loadList();
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, '삭제하지 못했습니다: $e');
      // 삭제 권한이 바뀌었을 수 있다 — 목록과 보고 있는 노트를 새로 읽어 ✕·삭제 메뉴를 맞춘다.
      await _loadList();
      if (mounted && _selectedId == note.id && !_editing) {
        await _loadDetail(note.id);
      }
    }
  }

  // ───────────────────────── 목록 거르기 ─────────────────────────

  Project? _projectOf(String id) =>
      _projects.where((p) => p.id == id).firstOrNull;

  List<ProjectNote> _visibleNotes() {
    final q = _query.trim().toLowerCase();
    final list = [
      for (final n in _notes!)
        if ((_projectFilter == null || n.projectId == _projectFilter) &&
            (q.isEmpty ||
                n.title.toLowerCase().contains(q) ||
                (n.preview ?? '').toLowerCase().contains(q)))
          n,
    ];
    switch (_sort) {
      case _NoteSort.created:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case _NoteSort.updated:
        list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      case _NoteSort.title:
        list.sort((a, b) => a.title.compareTo(b.title));
    }
    return list;
  }

  DateTime _shownDate(ProjectNote n) =>
      _sort == _NoteSort.updated ? n.updatedAt : n.createdAt;

  // ───────────────────────── 화면 ─────────────────────────

  /// 패널이면 크게 보기(⤢)/작게 보기(⤡)와 닫기(✕).
  List<Widget> _panelButtons() => widget.panelMode
      ? [
          IconButton(
            icon: Icon(
              widget.panelExpanded
                  ? Icons.close_fullscreen
                  : Icons.open_in_full,
              size: 18,
            ),
            tooltip: widget.panelExpanded ? '작게 보기' : '크게 보기',
            visualDensity: VisualDensity.compact,
            onPressed: widget.onToggleExpand,
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            tooltip: '닫기',
            visualDensity: VisualDensity.compact,
            onPressed: widget.onClose,
          ),
        ]
      : const [];

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    if (_notes == null) return const Center(child: CircularProgressIndicator());
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!_noteOpen) return _browse();
        final wide = constraints.maxWidth >= 720;
        if (!wide) return _noteArea(showBack: true);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_listCollapsed) ...[
              SizedBox(width: 290, child: _sideList()),
              const VerticalDivider(width: 1),
            ],
            Expanded(child: _noteArea(showBack: false)),
          ],
        );
      },
    );
  }

  Widget _searchField({bool dense = false}) {
    final theme = Theme.of(context);
    return TextField(
      controller: _searchCtrl,
      style: TextStyle(fontSize: dense ? 13 : 14),
      decoration: InputDecoration(
        hintText: '검색어를 입력하세요.',
        prefixIcon: const Icon(Icons.search, size: 18),
        prefixIconConstraints: const BoxConstraints(minWidth: 40),
        isDense: true,
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerLow,
        contentPadding: EdgeInsets.symmetric(vertical: dense ? 10 : 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: theme.dividerColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: theme.dividerColor),
        ),
      ),
      onChanged: (v) => setState(() => _query = v),
    );
  }

  Widget _projectDropdown() => _Dropdown<String?>(
    value: _projectFilter,
    items: [
      (null, '전체 프로젝트', null),
      for (final p in _projects) (p.id, p.name, parseTypeColor(p.color)),
    ],
    onChanged: (v) => setState(() => _projectFilter = v),
  );

  Widget _sortDropdown() => _Dropdown<_NoteSort>(
    value: _sort,
    items: [for (final s in _NoteSort.values) (s, _sortLabel(s), null)],
    onChanged: (v) => setState(() => _sort = v),
  );

  /// 목록 화면 — 노트를 연 게 없을 때.
  Widget _browse() {
    final notes = _visibleNotes();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  '노트',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Spacer(),
              DashedAddButton(label: '+ 새 노트', onTap: _newNote),
              if (widget.panelMode) const SizedBox(width: 4),
              ..._panelButtons(),
            ],
          ),
          const SizedBox(height: 18),
          _searchField(),
          const SizedBox(height: 8),
          Row(
            children: [
              if (_scopedProjectId == null) ...[
                Expanded(child: _projectDropdown()),
                const SizedBox(width: 8),
              ],
              Expanded(child: _sortDropdown()),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: notes.isEmpty
                ? EmptyHint(
                    _notes!.isEmpty
                        ? '아직 노트가 없습니다. "새 노트"로 시작해보세요.'
                        : '조건에 맞는 노트가 없습니다.',
                  )
                : MutedScrollbar(
                    controller: _listScroll,
                    child: ListView.builder(
                      controller: _listScroll,
                      padding: const EdgeInsets.only(right: 12),
                      itemCount: notes.length,
                      itemBuilder: (context, i) {
                        final n = notes[i];
                        return _BrowseItem(
                          note: n,
                          project: _projectOf(n.projectId),
                          date: _shownDate(n),
                          canDelete: n.canDelete,
                          onOpen: () => _select(n),
                          onDelete: () => _delete(n),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 노트를 연 상태의 왼쪽 좁은 목록.
  Widget _sideList() {
    final theme = Theme.of(context);
    final notes = _visibleNotes();
    Widget noteRow(ProjectNote n, {required bool bullet}) => _SideNoteRow(
      note: n,
      project: _projectOf(n.projectId),
      date: _shownDate(n),
      selected: n.id == _selectedId,
      bullet: bullet,
      onTap: () => _select(n),
    );

    // 계층형 + 전체 프로젝트면 프로젝트별로 묶는다.
    final grouped = _tree && _projectFilter == null && _scopedProjectId == null;
    final children = <Widget>[];
    if (grouped) {
      final byProject = <String, List<ProjectNote>>{};
      for (final n in notes) {
        (byProject[n.projectId] ??= []).add(n);
      }
      final order = [
        for (final p in _projects)
          if (byProject.containsKey(p.id)) p.id,
        for (final id in byProject.keys)
          if (!_projects.any((p) => p.id == id)) id,
      ];
      for (final id in order) {
        final p = _projectOf(id);
        final list = byProject[id]!;
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: parseTypeColor(p?.color ?? list.first.projectColor),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    p?.name ?? list.first.projectName ?? '프로젝트',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: theme.hintColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        for (final n in list) {
          children.add(
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: noteRow(n, bullet: true),
            ),
          );
        }
      }
    } else {
      for (final (i, n) in notes.indexed) {
        if (i > 0 && !_tree) {
          children.add(Divider(height: 1, color: theme.dividerColor));
        }
        children.add(noteRow(n, bullet: _tree));
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 10, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // 누르면 노트를 닫고 목록 화면으로.
              Tooltip(
                message: '노트 목록',
                child: InkWell(
                  onTap: _closeNote,
                  borderRadius: BorderRadius.circular(6),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                    child: Text(
                      '노트',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
              const Spacer(),
              DashedAddButton(label: '+ 새 노트', onTap: _newNote),
              IconButton(
                // 왼쪽 패널 접기 모양(오른쪽 패널 아이콘을 좌우로 뒤집어 쓴다).
                icon: Transform.flip(
                  flipX: true,
                  child: const Icon(Icons.view_sidebar_outlined, size: 18),
                ),
                tooltip: '목록 접기',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _listCollapsed = true),
              ),
              ..._panelButtons(),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _searchField(dense: true)),
              const SizedBox(width: 6),
              InkWell(
                onTap: () => setState(() => _tree = !_tree),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _tree
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        size: 20,
                        color: _tree
                            ? theme.colorScheme.primary
                            : theme.hintColor,
                      ),
                      const SizedBox(width: 4),
                      const Text('계층형', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (_scopedProjectId == null) ...[
                Expanded(child: _projectDropdown()),
                const SizedBox(width: 6),
              ],
              Expanded(child: _sortDropdown()),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: children.isEmpty
                ? const EmptyHint('노트가 없습니다.')
                : MutedScrollbar(
                    controller: _listScroll,
                    child: ListView(
                      controller: _listScroll,
                      padding: const EdgeInsets.only(right: 8, bottom: 12),
                      children: children,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 오른쪽 — 편집기 또는 읽기 화면.
  Widget _noteArea({required bool showBack}) {
    final lead = showBack
        ? IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: '목록',
            onPressed: _closeNote,
          )
        : _listCollapsed
        ? IconButton(
            icon: const Icon(Icons.keyboard_double_arrow_right, size: 18),
            tooltip: '목록 펼치기',
            onPressed: () => setState(() => _listCollapsed = false),
          )
        : null;
    if (_editing) return _editor(lead);
    return _viewer(lead);
  }

  Widget _viewer(Widget? lead) {
    final hint = Theme.of(context).hintColor;
    final note = _detail;
    if (note == null) {
      final error = _detailError;
      return Column(
        children: [
          Row(
            children: [
              ?lead,
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: '닫기',
                onPressed: _closeNote,
              ),
            ],
          ),
          Expanded(
            child: Center(
              child: error == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(error, style: TextStyle(color: hint)),
                        const SizedBox(height: 8),
                        OutlinedButton(
                          onPressed: () => _loadDetail(_selectedId!),
                          child: const Text('다시 시도'),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      );
    }
    final project = _projectOf(note.projectId);
    final theme = Theme.of(context);
    String two(int v) => v.toString().padLeft(2, '0');
    final u = note.updatedAt.toLocal();
    final updated =
        '${u.year}.${two(u.month)}.${two(u.day)} ${two(u.hour)}:${two(u.minute)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 번호 칩 · 수정 이력 · ⋯(수정 / 노트 복제 / 삭제)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
          child: Row(
            children: [
              ?lead,
              if (note.key != null)
                Tooltip(
                  message: '링크 복사',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    // 채팅·댓글에 붙여넣으면 "[MKT-N10] 제목" 링크가 된다(AppLinks).
                    onTap: () async {
                      await Clipboard.setData(
                        ClipboardData(
                          text: AppLinks.note(
                            id: note.id,
                            key: note.key,
                            title: note.title,
                            project: project?.name ?? note.projectName,
                            color: project?.color ?? note.projectColor,
                            person: note.createdByName,
                          ),
                        ),
                      );
                      if (mounted) showAppToast(context, '링크를 복사했습니다.');
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: theme.dividerColor),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.link, size: 13, color: hint),
                          const SizedBox(width: 4),
                          Text(
                            note.key!,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.7,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              const Spacer(),
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
                icon: const Icon(Icons.history, size: 20),
                tooltip: '수정 이력',
                visualDensity: VisualDensity.compact,
                onPressed: () => _openHistory(note),
              ),
              MenuAnchor(
                alignmentOffset: const Offset(-110, 4),
                menuChildren: [
                  if (note.canEdit)
                    hoverMenuItem(
                      icon: Icons.edit_outlined,
                      label: '수정',
                      onPressed: _startEdit,
                    ),
                  hoverMenuItem(
                    icon: Icons.copy_outlined,
                    label: '노트 복제',
                    onPressed: () => _duplicate(note),
                  ),
                  if (note.canDelete)
                    hoverMenuItem(
                      icon: Icons.delete_outline,
                      label: '삭제',
                      color: Colors.redAccent,
                      onPressed: () => _delete(note),
                    ),
                ],
                builder: (context, menu, _) => IconButton(
                  icon: const Icon(Icons.more_horiz, size: 20),
                  tooltip: '더보기',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => menu.isOpen ? menu.close() : menu.open(),
                ),
              ),
              // 넓은 화면에선 왼쪽 목록 머리줄에 있으므로, 좁은(패널) 화면에서만.
              if (!widget.panelExpanded) ..._panelButtons(),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
          child: Text(
            note.title,
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Row(
            children: [
              if (project != null || note.projectName != null) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: parseTypeColor(project?.color ?? note.projectColor),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  project?.name ?? note.projectName!,
                  style: const TextStyle(fontSize: 12),
                ),
                Text('  ·  ', style: TextStyle(color: hint, fontSize: 12)),
              ],
              Text(
                '최종 수정 $updated',
                style: TextStyle(color: hint, fontSize: 12),
              ),
              const Spacer(),
              if (note.createdByName != null) ...[
                UserAvatar(
                  user: AppUser(
                    id: note.createdBy ?? '',
                    username: note.createdByName!,
                    name: note.createdByName!,
                    avatarType: note.createdByAvatarType,
                    avatarEmoji: note.createdByAvatarEmoji,
                    avatarColor: note.createdByAvatarColor,
                    avatarUrl: note.createdByAvatarUrl,
                  ),
                  resolveUrl: widget.session.resolveUrl,
                  radius: 10,
                ),
                const SizedBox(width: 6),
                Text(note.createdByName!, style: const TextStyle(fontSize: 12)),
              ],
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Divider(height: 28),
        ),
        // 본문과 댓글을 한 스크롤로 — 본문이 짧으면 댓글은 화면 아래쪽에 붙고, 댓글이 늘면
        // 같이 스크롤된다.
        Expanded(
          child: MutedScrollbar(
            controller: _viewScroll,
            child: CustomScrollView(
              controller: _viewScroll,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(28, 0, 30, 16),
                  sliver: SliverToBoxAdapter(
                    child: SelectionArea(
                      child: NoteBody(
                        note.body ?? '',
                        resolveUrl: widget.session.resolveUrl,
                      ),
                    ),
                  ),
                ),
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: _commentsSection(note),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 댓글 · 기록 — 업무 패널의 댓글과 같은 공용 위젯(답글·더보기·서식 도구모음).
  /// 기록 탭에는 노트를 누가 언제 쓰고 고쳤는지.
  Widget _commentsSection(ProjectNote note) {
    final api = widget.session.api!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 30, 16),
      child: CommentsSection(
        session: widget.session,
        comments: [
          for (final c in _comments)
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
        members: const [],
        readOnly: _projectOf(note.projectId)?.archived ?? false,
        canModerate: _canModerateComments(note),
        actions: CommentActions(
          add: (text, format, {parentId}) => _commentAction(
            note.id,
            () => api.addNoteComment(
              note.id,
              text,
              textFormat: format,
              parentCommentId: parentId,
            ),
          ),
          update: (id, text, format) => _commentAction(
            note.id,
            () => api.updateNoteComment(id, text, textFormat: format),
          ),
          delete: (id) =>
              _commentAction(note.id, () => api.deleteNoteComment(id)),
        ),
        history: (_) => _NoteHistoryList(
          key: ValueKey('${note.id}-${note.updatedAt.millisecondsSinceEpoch}'),
          session: widget.session,
          note: note,
        ),
      ),
    );
  }

  /// 편집기 — 큰 제목 칸, 서식 도구모음, 본문, 아래 줄(취소 · 프로젝트 · 저장).
  Widget _editor(Widget? lead) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    Widget toolButton(IconData icon, String tip, VoidCallback? onPressed) =>
        IconButton(
          icon: Icon(icon, size: 18),
          tooltip: tip,
          color: hint,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          padding: EdgeInsets.zero,
          onPressed: onPressed,
        );
    final projectId = _creating ? _createProjectId : _detail?.projectId;
    final project = projectId == null ? null : _projectOf(projectId);
    // 수정 권한이 없는 노트(저장하다 권한이 바뀐 걸 알게 된 경우 등)는 읽기 전용으로만 보여준다.
    final readOnly =
        _editLocked || (!_creating && _detail != null && !_detail!.canEdit);
    final canSave = !_saving && !readOnly && _title.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
          child: Row(
            children: [
              ?lead,
              Expanded(
                child: TextField(
                  controller: _title,
                  autofocus: true,
                  readOnly: readOnly,
                  maxLength: 100,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                  ),
                  decoration: InputDecoration(
                    hintText: '제목을 입력하세요',
                    hintStyle: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      color: hint.withValues(alpha: 0.6),
                    ),
                    counterText: '',
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onSubmitted: (_) => _bodyFocus.requestFocus(),
                ),
              ),
            ],
          ),
        ),
        if (readOnly)
          Container(
            margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.lock_outline,
                  size: 16,
                  color: Colors.deepOrange,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '이 노트를 수정할 권한이 없습니다(노트 작성자와 관리자만 수정할 수 있습니다). '
                    '쓰던 내용은 복사해 둘 수 있습니다.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          )
        else
          Container(
            color: theme.brightness == Brightness.dark
                ? Colors.white.withValues(alpha: 0.04)
                : const Color(0xFFF7F8FA),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: RichFormatToolbar(
              controller: _body,
              focusNode: _bodyFocus,
              showColor: true,
              showHeadings: true,
              showRule: true,
              trailing: [
                toolButton(Icons.table_chart_outlined, '표', _insertTable),
                _uploading
                    ? const Padding(
                        padding: EdgeInsets.all(7),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : toolButton(Icons.image_outlined, '그림', _insertImage),
              ],
            ),
          ),
        Divider(height: 1, color: theme.dividerColor),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 12, 0),
            // 줄 맨 앞이나 공백 뒤에서 "/"를 치면 이 프로젝트의 업무 링크 목록이 뜬다.
            child: NoteTaskLinkMenu(
              controller: _body,
              focusNode: _bodyFocus,
              projectId: projectId,
              projectName: project?.name ?? _detail?.projectName,
              projectColor: project?.color ?? _detail?.projectColor,
              loadTasks: (id) => widget.session.api!.fetchProjectTasks(id),
              enabled: !readOnly,
              child: RichFieldWrapper(
                controller: _body,
                child: TextField(
                  controller: _body,
                  focusNode: _bodyFocus,
                  readOnly: readOnly,
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  keyboardType: TextInputType.multiline,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontSize: 15, height: 1.5),
                  decoration: InputDecoration(
                    hintText: '내용을 입력하세요',
                    hintStyle: TextStyle(
                      fontSize: 17,
                      color: hint.withValues(alpha: 0.7),
                    ),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
            ),
          ),
        ),
        Divider(height: 1, color: theme.dividerColor),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: _saving ? null : _cancelEdit,
                icon: const Icon(Icons.chevron_left, size: 18),
                label: const Text('취소'),
                style: TextButton.styleFrom(foregroundColor: theme.hintColor),
              ),
              const Spacer(),
              // 새 노트는 들어갈 프로젝트를 여기서 고른다(있는 노트는 옮길 수 없어 보여주기만).
              SizedBox(
                width: 180,
                child: _Dropdown<String?>(
                  value: projectId,
                  enabled: _creating && _scopedProjectId == null,
                  items: [
                    for (final p in _projects)
                      (p.id, p.name, parseTypeColor(p.color)),
                  ],
                  onChanged: (v) => setState(() => _createProjectId = v),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: canSave ? _save : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(84, 44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text('저장'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 목록 화면의 노트 한 줄 — 큰 제목, 한 줄 미리보기, 프로젝트 · 날짜. 마우스를 올리면 제목이
/// 파랗게 되고 오른쪽에 ✕(삭제)가 나온다.
class _BrowseItem extends StatefulWidget {
  final ProjectNote note;
  final Project? project;
  final DateTime date;
  final bool canDelete;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  const _BrowseItem({
    required this.note,
    required this.project,
    required this.date,
    required this.canDelete,
    required this.onOpen,
    required this.onDelete,
  });

  @override
  State<_BrowseItem> createState() => _BrowseItemState();
}

class _BrowseItemState extends State<_BrowseItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = widget.note;
    final preview = notePlainPreview(n.preview);
    final projectName = widget.project?.name ?? n.projectName;
    final projectColor = parseTypeColor(
      widget.project?.color ?? n.projectColor,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: widget.onOpen,
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 18, 6, 18),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      n.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                        color: _hover ? theme.colorScheme.primary : null,
                      ),
                    ),
                    if (preview.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.75,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (projectName != null) ...[
                          Text(
                            projectName,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: projectColor,
                            ),
                          ),
                          Text(
                            '  ·  ',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.hintColor,
                            ),
                          ),
                        ],
                        Text(
                          _ymdKo(widget.date),
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.hintColor,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (widget.canDelete)
                Visibility(
                  visible: _hover,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: IconButton(
                    icon: Icon(Icons.close, size: 18, color: theme.hintColor),
                    tooltip: '삭제',
                    onPressed: widget.onDelete,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 노트를 연 상태의 왼쪽 목록 한 줄. 평평한 목록이면 제목 + 프로젝트(색)·날짜, 계층형이면
/// • 제목만. 고른 노트는 옅은 파란 바탕, 마우스를 올리면 제목이 파랗게.
class _SideNoteRow extends StatefulWidget {
  final ProjectNote note;
  final Project? project;
  final DateTime date;
  final bool selected;
  final bool bullet;
  final VoidCallback onTap;
  const _SideNoteRow({
    required this.note,
    required this.project,
    required this.date,
    required this.selected,
    required this.bullet,
    required this.onTap,
  });

  @override
  State<_SideNoteRow> createState() => _SideNoteRowState();
}

class _SideNoteRowState extends State<_SideNoteRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = widget.note;
    final primary = theme.colorScheme.primary;
    final titleColor = widget.selected || _hover ? primary : null;
    final projectName = widget.project?.name ?? n.projectName;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: widget.bullet
              ? const EdgeInsets.symmetric(horizontal: 8, vertical: 8)
              : const EdgeInsets.fromLTRB(10, 14, 10, 14),
          decoration: BoxDecoration(
            color: widget.selected ? primary.withValues(alpha: 0.06) : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: widget.bullet
              ? Row(
                  children: [
                    Text(
                      '•',
                      style: TextStyle(color: theme.hintColor, fontSize: 13),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        n.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: titleColor,
                          fontWeight: widget.selected ? FontWeight.w600 : null,
                        ),
                      ),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      n.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: titleColor,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (projectName != null) ...[
                          Flexible(
                            child: Text(
                              projectName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: parseTypeColor(
                                  widget.project?.color ?? n.projectColor,
                                ),
                              ),
                            ),
                          ),
                          Text(
                            '  ·  ',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.hintColor,
                            ),
                          ),
                        ],
                        Text(
                          _ymdKo(widget.date),
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.hintColor,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// 노트 기록 탭 — 처음 쓴 것과 고친 것들을 최신순으로(수정 이력에서 읽는다).
class _NoteHistoryList extends StatefulWidget {
  final Session session;
  final ProjectNote note;
  const _NoteHistoryList({
    super.key,
    required this.session,
    required this.note,
  });

  @override
  State<_NoteHistoryList> createState() => _NoteHistoryListState();
}

class _NoteHistoryListState extends State<_NoteHistoryList> {
  List<NoteVersion>? _versions;

  @override
  void initState() {
    super.initState();
    widget.session.api!
        .fetchNoteVersions(widget.note.id)
        .then((v) {
          if (mounted) setState(() => _versions = v);
        })
        .catchError((_) {
          if (mounted) setState(() => _versions = const []);
        });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final versions = _versions;
    if (versions == null) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final note = widget.note;
    // 지금 모습(마지막으로 고친 사람) + 이력의 버전들(그 버전을 쓴 사람·시각).
    final entries = <(String, DateTime)>[
      (note.updatedByName ?? note.createdByName ?? '알 수 없음', note.updatedAt),
      for (final v in versions) (v.editedByName ?? '알 수 없음', v.editedAt),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    bool isCreation(DateTime t) =>
        t.difference(note.createdAt).inSeconds.abs() <= 1;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, (name, at)) in entries.indexed) ...[
            if (i > 0) const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  UserAvatar(
                    user: AppUser(id: '', username: name, name: name),
                    radius: 11,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: name,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          TextSpan(
                            text: isCreation(at)
                                ? '님이 노트를 작성했습니다.'
                                : '님이 노트를 수정했습니다.',
                          ),
                        ],
                      ),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  Tooltip(
                    message: _formatWhen(at),
                    child: Text(
                      formatRelativeTime(at),
                      style: TextStyle(fontSize: 11, color: theme.hintColor),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 테두리 있는 드롭다운 칸 — 누르면 아래로 목록이 펼쳐진다. 항목은 (값, 이름, 색 점).
class _Dropdown<T> extends StatelessWidget {
  final T value;
  final List<(T, String, Color?)> items;
  final ValueChanged<T> onChanged;
  final bool enabled;
  const _Dropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = items.where((i) => i.$1 == value).firstOrNull;
    return LayoutBuilder(
      builder: (context, constraints) => MenuAnchor(
        alignmentOffset: const Offset(0, 4),
        style: MenuStyle(
          minimumSize: WidgetStatePropertyAll(Size(constraints.maxWidth, 0)),
        ),
        menuChildren: [
          for (final (v, label, color) in items)
            MenuItemButton(
              onPressed: () => onChanged(v),
              leadingIcon: color == null
                  ? null
                  : Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: v == value ? FontWeight.w600 : null,
                  color: v == value ? theme.colorScheme.primary : null,
                ),
              ),
            ),
        ],
        builder: (context, menu, _) => InkWell(
          onTap: enabled
              ? () => menu.isOpen ? menu.close() : menu.open()
              : null,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(8),
              color: theme.colorScheme.surface,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    current?.$2 ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: enabled ? null : theme.hintColor,
                    ),
                  ),
                ),
                if (enabled)
                  Icon(
                    Icons.keyboard_arrow_down,
                    size: 16,
                    color: theme.hintColor,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _formatWhen(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

/// 노트 수정 이력 — 왼쪽에 이전 버전들(최근 30개), 오른쪽에 고른 버전의 내용. "이 버전으로 되돌리기"를
/// 누르면 노트가 그 내용으로 바뀌고(되돌리기 직전 내용도 이력에 남는다) 되돌려진 노트를 돌려준다.
class _NoteHistoryDialog extends StatefulWidget {
  final Session session;
  final ProjectNote note;

  /// 노트 수정 권한이 없으면 이력은 보기만 한다(되돌리기 버튼 없음).
  final bool canRestore;
  const _NoteHistoryDialog({
    required this.session,
    required this.note,
    this.canRestore = true,
  });

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
                                  if (widget.canRestore)
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
                                    child: NoteBody(
                                      _selected!.body ?? '',
                                      resolveUrl: widget.session.resolveUrl,
                                    ),
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
