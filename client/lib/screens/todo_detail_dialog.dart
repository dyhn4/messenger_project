import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../models/app_user.dart';
import '../models/room.dart';
import '../models/todo.dart';
import '../services/chat_socket.dart' show SimpleCommentDeleted;
import '../services/folder_dialog.dart' show openFolderInExplorer;
import '../services/session.dart';
import '../services/time_format.dart';
import '../services/todo_api.dart';
import '../services/todo_download.dart';
import '../services/todo_upload.dart';
import '../widgets/app_toast.dart';
import '../widgets/attachment_widgets.dart'
    show ChatImageAttachments, DownloadableFile;
import '../widgets/avatar_utils.dart';
import '../widgets/compact_menu.dart';
import '../widgets/post_comments.dart';
import '../widgets/todo_menu.dart';
import '../widgets/todo_widgets.dart';
import '../widgets/user_avatar.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'todo_editor_dialog.dart';

/// 방을 여는 손잡이 — 패널이 자기 context로 만든다(대화상자 안의 context로는 홈 화면을 못 찾는다).
typedef TodoOpenRoom = void Function(Room room, {String? messageId});

/// 첨부를 전부 받는 손잡이 — 앱에서는 [downloadTodoAttachments], 테스트는 가짜를 끼운다.
typedef TodoDownloader =
    Future<void> Function(
      BuildContext context,
      Session session,
      Todo todo, {
      void Function(int done, int total)? onProgress,
    });

/// 할 일 상세를 연다 — [mode]를 안 주면 넓은 창(PC)은 대화상자, 좁은 창(모바일)은 전체 화면. [TodoViewMode.panel]이면
/// 가장 가까운 Navigator(PC 할 일 패널의 중첩 Navigator)에 패널 안 화면으로 올린다 — 머리 `← 할 일 … ✕`의 ←는 상세만
/// 닫고, ✕는 [onClosePanel](패널 전체 닫기)을 부른다. 열려 있는 동안 서버가 바꾸거나 지우면(소켓 todo:changed) 스스로 다시
/// 받아 그리고, 지워졌으면 닫는다(그 위에 띄운 ••• 메뉴·진척률 메뉴·수정 창·삭제 확인도 같이). 내가 고치거나 지우거나
/// 진척률·즐겨찾기를 바꿨으면 true를 돌려준다(목록이 다시 받는다).
///
/// [onOpenRoom]은 대화방 칸·"원본 메시지 보기"를 눌렀을 때 그 방을 여는 손잡이 — 없으면 그 단추들은 안 보인다.
/// [api]·[changed]·[download]·[commentStream]은 테스트가 가짜를 끼우는 자리.
Future<bool> showTodoDetail(
  BuildContext context, {
  required Session session,
  required Todo todo,
  TodoOpenRoom? onOpenRoom,
  TodoApi? api,
  Stream<Map<String, dynamic>>? changed,
  TodoDownloader? download,
  Stream<TodoComment>? commentStream,
  TodoViewMode? mode,
  VoidCallback? onClosePanel,
}) async {
  final viewMode =
      mode ??
      (MediaQuery.sizeOf(context).width >= wideBreakpoint
          ? TodoViewMode.dialog
          : TodoViewMode.page);
  final detail = TodoDetail(
    session: session,
    todo: todo,
    onOpenRoom: onOpenRoom,
    api: api,
    changed: changed,
    download: download,
    commentStream: commentStream,
    mode: viewMode,
    onClosePanel: onClosePanel,
  );
  final closed = switch (viewMode) {
    TodoViewMode.dialog => showDialog<bool>(
      context: context,
      builder: (_) => detail,
    ),
    TodoViewMode.page => Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => detail)),
    TodoViewMode.panel => Navigator.of(
      context,
    ).push<bool>(todoPanelRoute((_) => detail)),
  };
  return await closed ?? false;
}

/// 할 일 상세(대화상자/전체 화면/패널 안 화면 공용 — 잔디 상세 모양): 만든 사람 줄(`○○ 님이 할 일을 추가했습니다.`·시각,
/// 오른쪽에 즐겨찾기 ★와 ••• 메뉴) → 제목 → 설명 → 테두리 상자[진행률(전체 %) · 대화방 · 담당자(`총 N명`, 내 줄은 진척률
/// 고르기 상자, 다른 사람은 색 글자) · 일정(기간·알림)] → 첨부 → 원본 메시지 보기. ••• 메뉴는 즐겨찾기(누구나)·할 일
/// 수정(만든 사람·담당자)·파일 다운로드(첨부가 있을 때)·할 일 삭제(만든 사람). 담당자 없는 개인 할 일은 만든 사람이
/// 진행률 칸에서 바로 고른다.
class TodoDetail extends StatefulWidget {
  final Session session;
  final Todo todo;
  final TodoOpenRoom? onOpenRoom;
  final TodoApi? api;
  final Stream<Map<String, dynamic>>? changed;
  final TodoDownloader? download;

  /// 새 댓글 소식 — 없으면 소켓(todo:comment:new). 테스트가 가짜를 끼우는 자리.
  final Stream<TodoComment>? commentStream;

  /// 그리는 모양 — 안 주면 [asDialog]로 정한다(true = 대화상자, false = 전체 화면).
  final TodoViewMode mode;

  /// 패널 모드의 ✕ — 패널 전체를 닫는다(TodosPanel.onClose). 없으면 ✕가 안 보인다.
  final VoidCallback? onClosePanel;

  const TodoDetail({
    super.key,
    required this.session,
    required this.todo,
    this.onOpenRoom,
    this.api,
    this.changed,
    this.download,
    this.commentStream,
    bool asDialog = true,
    TodoViewMode? mode,
    this.onClosePanel,
  }) : mode = mode ?? (asDialog ? TodoViewMode.dialog : TodoViewMode.page);

  /// 대화상자로 그리는지(예전 이름 — [mode]가 [TodoViewMode.dialog]인가).
  bool get asDialog => mode == TodoViewMode.dialog;

  @override
  State<TodoDetail> createState() => _TodoDetailState();
}

class _TodoDetailState extends State<TodoDetail> {
  late final TodoApi _api = widget.api ?? widget.session.todoApi;
  late Todo _todo = widget.todo;
  bool _changed = false;

  /// 서버에 보내는 중인 내 진척률 — 응답 전에 고른 값을 먼저 보인다(실패하면 원래대로).
  int? _pendingProgress;

  /// 즐겨찾기를 서버에 보내는 중(연달아 눌러 요청이 엇갈리지 않게).
  bool _favoriteBusy = false;

  /// 첨부를 내려받는 중인지, 받기 시작했으면 받은 개수/전체 개수(첨부 칸에 진행 막대).
  bool _downloading = false;
  int? _downloadDone;
  int _downloadTotal = 0;

  /// 내가 지우는 중이거나 소켓 deleted로 이미 닫는 중이면 소켓 deleted를 따로 처리하지 않는다(창을 두 번 닫지 않게).
  bool _deleting = false;

  /// 떠 있는 삭제 확인 창 — 대화상자는 루트 Navigator에 뜨므로 패널 모드(상세는 패널의 중첩 Navigator)에서는 상세와 다른
  /// Navigator에 있다. 지워졌다는 알림이 오면 이것도 따로 닫는다.
  Route<Object?>? _confirmRoute;
  StreamSubscription<Map<String, dynamic>>? _sub;

  /// 댓글(오래된 것부터) — 받기 전이면 null. 못 받았으면 [_commentsError].
  List<TodoComment>? _comments;
  String? _commentsError;
  final _commentController = TextEditingController();
  bool _sendingComment = false;
  StreamSubscription<TodoComment>? _commentSub;
  StreamSubscription<TodoComment>? _commentEditedSub;
  StreamSubscription<SimpleCommentDeleted>? _commentDeletedSub;

  @override
  void initState() {
    super.initState();
    final stream = widget.changed ?? widget.session.chatSocket.todoChanged;
    _sub = stream.listen((e) {
      if (e['todoId'] != _todo.id || _deleting) return;
      if (e['kind'] == 'deleted') {
        _closeDeleted();
        return;
      }
      // 즐겨찾기는 내 것만 온다(user:<나>) — 다시 받을 것 없이 별만 맞춘다. 내가 보내는 중이면 그 응답을 따른다.
      final favorite = e['favorite'];
      if (e['kind'] == 'favorite' && favorite is bool) {
        if (mounted && !_favoriteBusy) {
          setState(() => _todo = _todo.copyWith(favorite: favorite));
        }
        return;
      }
      unawaited(_reload());
    });
    unawaited(_loadComments());
    final comments =
        widget.commentStream ?? widget.session.chatSocket.todoComments;
    _commentSub = comments.listen((c) {
      if (c.todoId != _todo.id || !mounted) return;
      setState(() => _addComment(c));
    });
    final socket = widget.session.chatSocket;
    _commentEditedSub = socket.todoCommentEdited.listen((c) {
      if (c.todoId != _todo.id || !mounted) return;
      setState(() => _replaceComment(c));
    });
    _commentDeletedSub = socket.todoCommentDeleted.listen((e) {
      if (e.parentId != _todo.id || !mounted) return;
      setState(() => _removeComment(e.id));
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _commentSub?.cancel();
    _commentEditedSub?.cancel();
    _commentDeletedSub?.cancel();
    _commentController.dispose();
    // 패널 안 상세가 먼저 닫혔는데(팀을 바꿔 패널이 목록으로 돌아감) 루트 Navigator의 삭제 확인이 남았으면 다음 프레임에
    // 닫는다 — 결과는 null이라 DELETE를 보내지 않는다.
    final confirm = _confirmRoute;
    _confirmRoute = null;
    if (confirm != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => closeTodoRoute(confirm),
      );
    }
    super.dispose();
  }

  /// 열려 있는 동안 지워졌다(소켓 deleted) — 알리고, 위에 떠 있는 것들을 결과 없이(null) 먼저 닫은 뒤 상세를 닫는다.
  /// 맨 위 창을 true로 닫으면 수정 창(Todo)·메뉴(String/int)는 결과 타입이 안 맞아 터지고, 삭제 확인은 [삭제]를 누른 것이
  /// 된다. popUntil은 pop이라 수정 창의 "작성 취소" 확인(PopScope)도 거치지 않는다.
  void _closeDeleted() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    // 같은 알림이 또 와도 다시 닫지 않게, 떠 있던 삭제 확인이 닫혀도 DELETE를 보내지 않게.
    _deleting = true;
    _toast('이 할 일이 삭제되었습니다.');
    final nav = Navigator.of(context);
    // 패널 모드에서는 상세(패널의 중첩 Navigator)와 달리 삭제 확인과 메뉴(••• · 진척률 · 수정 화면의 알림 메뉴)가 창 전체
    // (루트 Navigator)에 떠 있어 아래 popUntil로는 안 닫힌다 — 따로 닫는다.
    final root = Navigator.of(context, rootNavigator: true);
    if (!identical(root, nav)) {
      final confirm = _confirmRoute;
      if (confirm != null && confirm.navigator != nav) closeTodoRoute(confirm);
      closeTodoPopups(root);
    }
    // 같은 Navigator의 ••• 메뉴·진척률 메뉴·수정 창(과 대화상자·전체 화면 모드의 삭제 확인)을 닫고 상세를 닫는다.
    nav.popUntil((r) => r == route);
    nav.pop(true);
  }

  Future<void> _reload() async {
    try {
      final fresh = await _api.get(_todo.id);
      if (mounted) setState(() => _todo = fresh);
    } catch (_) {
      // 다시 받지 못해도 지금 화면은 그대로 둔다.
    }
  }

  Future<void> _loadComments() async {
    try {
      final comments = await _api.comments(_todo.id);
      if (mounted) setState(() => _comments = comments);
    } catch (e) {
      if (mounted) setState(() => _commentsError = '댓글을 불러오지 못했습니다: $e');
    }
  }

  /// 내가 보낸 댓글의 응답과 소켓 소식이 둘 다 오니 같은 댓글은 한 번만 넣는다. 아직 목록을 받는 중이면 받은 목록에
  /// 들어 있을 테니 건너뛴다.
  /// 고친 댓글로 바꾼다(소켓 소식과 내 응답이 둘 다 와도 같은 값이다).
  void _replaceComment(TodoComment c) {
    final comments = _comments;
    if (comments == null) return;
    _comments = [for (final e in comments) e.id == c.id ? c : e];
  }

  void _removeComment(String id) {
    final comments = _comments;
    if (comments == null) return;
    _comments = [
      for (final e in comments)
        if (e.id != id) e,
    ];
  }

  Future<void> _editComment(TodoComment c, String text) async {
    final updated = await _api.updateComment(_todo.id, c.id, text);
    if (mounted) setState(() => _replaceComment(updated));
  }

  Future<void> _deleteComment(TodoComment c) async {
    await _api.deleteComment(_todo.id, c.id);
    if (mounted) setState(() => _removeComment(c.id));
  }

  void _addComment(TodoComment c) {
    final comments = _comments;
    if (comments == null || comments.any((e) => e.id == c.id)) return;
    _comments = [...comments, c];
  }

  Future<void> _postComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty || _sendingComment) return;
    setState(() => _sendingComment = true);
    _commentController.clear();
    try {
      final created = await _api.postComment(_todo.id, text);
      if (mounted) setState(() => _addComment(created));
    } catch (e) {
      // 못 보냈으면 쓴 글을 돌려 놓는다(그 사이 새로 친 게 없을 때만).
      if (mounted && _commentController.text.isEmpty) {
        _commentController.text = text;
      }
      if (mounted) _toast('댓글을 등록하지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _sendingComment = false);
    }
  }

  AppUser? _memberOf(String? userId) {
    if (userId == null) return null;
    return _room?.members.where((m) => m.id == userId).firstOrNull;
  }

  /// 알림 토스트 — 앱 맨 위 Overlay(창 가운데 아래)에 뜬다(패널 모드에서도 — [showAppToast]).
  void _toast(String message) => showAppToast(context, message);

  Room? get _room =>
      widget.session.rooms.where((r) => r.id == _todo.roomId).firstOrNull;

  /// 내 진척률을 바꾼다 — 서버가 `progress`를 "내 진척률"로 받아(담당자는 자기 것, 담당자 없는 할 일은 만든 사람이
  /// 할 일의 것) 전체 진척률까지 다시 계산한 할 일을 돌려준다. 보내는 동안 고른 값을 먼저 보이고, 그 사이 다른 값은
  /// 무시한다.
  Future<void> _setProgress(int progress) async {
    final t = _todo;
    if (_pendingProgress != null ||
        !t.canSetProgress ||
        progress == t.myProgress) {
      return;
    }
    setState(() => _pendingProgress = progress);
    try {
      final updated = await _api.update(t.id, {'progress': progress});
      if (!mounted) return;
      setState(() {
        _todo = updated;
        _changed = true;
      });
    } catch (e) {
      if (mounted) _toast('진척률을 바꾸지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _pendingProgress = null);
    }
  }

  /// 즐겨찾기(★·••• 메뉴) — 누르면 바로 바꿔 보이고 서버에 보낸다. 실패하면 되돌리고 알린다. 목록도 다시 받게 바뀜으로
  /// 친다(즐겨찾기한 것이 목록 위로 올라간다).
  Future<void> _toggleFavorite() async {
    if (_favoriteBusy) return;
    final before = _todo.favorite;
    setState(() {
      _favoriteBusy = true;
      _todo = _todo.copyWith(favorite: !before);
    });
    try {
      final favorite = await _api.setFavorite(_todo.id, !before);
      if (!mounted) return;
      setState(() {
        _todo = _todo.copyWith(favorite: favorite);
        _changed = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _todo = _todo.copyWith(favorite: before));
      _toast('즐겨찾기를 바꾸지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _favoriteBusy = false);
    }
  }

  /// 할 일 수정 — 상세와 같은 모양으로 연다(패널 안이면 패널 안에).
  Future<void> _edit() async {
    final updated = await showTodoEditor(
      context,
      session: widget.session,
      editing: _todo,
      api: _api,
      mode: widget.mode,
      onClosePanel: widget.onClosePanel,
    );
    if (updated == null || !mounted) return;
    setState(() {
      _todo = updated;
      _changed = true;
    });
    _toast('할 일을 수정했습니다.');
  }

  /// 첨부 전부 받기(••• → 파일 다운로드) — 받는 동안 첨부 칸에 진행 막대를 보이고, 끝난 알림은 내려받기 쪽이 띄운다.
  Future<void> _download() async {
    if (_downloading || _todo.attachments.isEmpty) return;
    final TodoDownloader download = widget.download ?? downloadTodoAttachments;
    setState(() => _downloading = true);
    try {
      await download(
        context,
        widget.session,
        _todo,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _downloadDone = done;
            _downloadTotal = total;
          });
        },
      );
    } catch (e) {
      if (mounted) _toast('다운로드하지 못했습니다: $e');
    } finally {
      if (mounted) {
        setState(() {
          _downloading = false;
          _downloadDone = null;
        });
      }
    }
  }

  Future<void> _delete() async {
    // 지워졌다는 알림이 오면 확인 창도 닫으려고 붙잡아 둔다(패널 모드에서는 상세와 다른 Navigator에 뜬다).
    final ok = await confirmTodoDelete(
      context,
      _todo,
      onRoute: (route) => _confirmRoute = route,
    );
    _confirmRoute = null;
    if (!ok || !mounted || _deleting) return;
    // 지우고 나면 상세가 닫혀 context가 사라지므로 알릴 곳(앱 맨 위 Overlay)을 먼저 잡아 둔다.
    final overlay = Overlay.of(context, rootOverlay: true);
    _deleting = true;
    try {
      await _api.delete(_todo.id);
      showAppToastOnOverlay(overlay, '할 일을 삭제했습니다.');
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _deleting = false;
      if (mounted) _toast('할 일을 삭제하지 못했습니다: $e');
    }
  }

  /// 폴더 경로를 윈도우 탐색기로 연다. 못 열면(폴더가 없음·PC가 아님) 까닭을 알리고, PC가 아니면 경로를 복사해 둔다.
  Future<void> _openFolder(String path) async {
    final error = await openFolderInExplorer(path);
    if (error == null || !mounted) return;
    if (!Platform.isWindows) {
      await Clipboard.setData(ClipboardData(text: path));
      if (mounted) _toast('$error 경로를 복사했습니다.');
      return;
    }
    _toast(error);
  }

  void _openRoom({String? messageId}) {
    final room = _room;
    final open = widget.onOpenRoom;
    if (room == null || open == null) return;
    Navigator.of(context).pop(_changed);
    open(room, messageId: messageId);
  }

  // ── 화면 ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: switch (widget.mode) {
        TodoViewMode.dialog => _buildDialog(context),
        TodoViewMode.page => _buildPage(context),
        TodoViewMode.panel => _buildPanel(context),
      },
    );
  }

  /// 패널 안 화면 — 머리 `← 할 일 … ✕`(←는 상세만 닫기, ✕는 패널 전체 닫기) 아래로 본문이 스크롤된다. ★·•••는 본문의
  /// 만든 사람 줄에 있다. 바탕을 칠해 밀려 들어오는 동안 아래 목록이 비치지 않게 한다.
  Widget _buildPanel(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TodoPageHeader(
            onBack: () => Navigator.of(context).pop(_changed),
            onClose: widget.onClosePanel,
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _bodyChildren(context),
              ),
            ),
          ),
          const Divider(height: 1),
          _commentInput(),
        ],
      ),
    );
  }

  /// 대화상자(넓은 창에서 패널 밖) — 머리 `할 일 … ✕`(패널 안 화면의 머리와 같은 글꼴), 내용만큼만 높고 길면 본문이
  /// 스크롤된다.
  Widget _buildDialog(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: math.min(560, screen.width - 48),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: math.min(720, screen.height - 48),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '할 일',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
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
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _bodyChildren(context),
                  ),
                ),
              ),
              const Divider(height: 1),
              _commentInput(),
            ],
          ),
        ),
      ),
    );
  }

  /// 전체 화면(좁은 창) — 앱바 `← 할 일`.
  Widget _buildPage(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('todo-detail-close'),
          icon: const Icon(Icons.arrow_back),
          tooltip: '뒤로',
          onPressed: () => Navigator.of(context).pop(_changed),
        ),
        title: const Text('할 일'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SafeArea(
              bottom: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _bodyChildren(context),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          _commentInput(),
        ],
      ),
    );
  }

  /// 맨 아래 고정된 댓글 입력칸(공지 상세와 같은 모양).
  Widget _commentInput() => PostCommentInput(
    controller: _commentController,
    sending: _sendingComment,
    onSubmit: _postComment,
    inputKey: const ValueKey('todo-comment-input'),
    sendKey: const ValueKey('todo-comment-send'),
  );

  /// 댓글 — 구분선 아래 `댓글 N`과 목록(공지 상세와 같은 모양).
  List<Widget> _commentSection(BuildContext context) {
    final comments = _comments;
    final error = _commentsError;
    return [
      const SizedBox(height: 20),
      const Divider(height: 1),
      const SizedBox(height: 12),
      PostCommentCount(
        comments?.length ?? 0,
        textKey: const ValueKey('todo-comment-count'),
      ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            error,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        )
      else
        PostCommentList<TodoComment>(
          comments: comments,
          itemPadding: const EdgeInsets.only(top: 8, bottom: 6),
          emptyPadding: const EdgeInsets.only(top: 8),
          itemBuilder: (c) {
            // ⋯는 고치거나 지울 수 있을 때만(작성자는 수정·삭제, 관리자는 삭제 — [simpleCommentPermissions]).
            final can = simpleCommentPermissions(
              widget.session,
              _room,
              c.authorId,
            );
            return PostCommentTile(
              key: ValueKey('todo-comment-${c.id}'),
              commentId: c.id,
              avatarUser: _memberOf(c.authorId),
              authorName: c.authorName,
              createdAt: c.createdAt,
              editedAt: c.editedAt,
              text: c.text,
              resolveUrl: widget.session.resolveUrl,
              onEdit: can.edit ? (text) => _editComment(c, text) : null,
              onDelete: can.delete ? () => _deleteComment(c) : null,
              // 할 일이 지워지면 ••• 메뉴처럼 같이 닫힌다(_closeDeleted의 closeTodoPopups).
              menuRouteSettings: todoPopupRouteSettings,
            );
          },
        ),
    ];
  }

  /// 본문 — 만든 사람 줄(★ •••) → 제목 → 설명 → 상자(진행률 · 대화방 · 담당자 · 일정) → 첨부 → 원본 메시지.
  List<Widget> _bodyChildren(BuildContext context) {
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
    final description = t.description ?? '';
    return [
      _creatorLine(context),
      const SizedBox(height: 14),
      Text(
        t.title,
        key: const ValueKey('todo-detail-title'),
        style: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          height: 1.35,
        ),
      ),
      if (description.isNotEmpty) ...[
        const SizedBox(height: 8),
        SelectableText(
          description,
          key: const ValueKey('todo-detail-description'),
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
      ],
      const SizedBox(height: 16),
      _infoBox(context, room, canOpenRoom),
      if (t.attachments.isNotEmpty) ...[
        const SizedBox(height: 20),
        _Label('첨부', trailing: '${t.attachments.length}개'),
        if (_downloadDone != null) _downloadProgress(context),
        // 전부 받기는 •••의 "파일 다운로드"(사진·파일 모두)가 맡아서 말풍선의 "전체 다운로드" 줄은 두지 않는다 — 사진
        // 격자 아래에도, 파일 목록 아래에도.
        if (images.isNotEmpty)
          ChatImageAttachments(
            session: widget.session,
            attachments: images,
            room: room,
            showDownloadAll: false,
          ),
        if (images.isNotEmpty && files.isNotEmpty) const SizedBox(height: 8),
        // 파일은 한 줄에 하나.
        for (final (i, f) in files.indexed) ...[
          if (i > 0) const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: DownloadableFile(
              session: widget.session,
              url: widget.session.resolveUrl(f.fileUrl),
              fileName: f.fileName ?? '파일',
            ),
          ),
        ],
      ],
      // 폴더 경로(만든 사람이 생성 창에서 고른 것) — 누르면 이 PC의 윈도우 탐색기로 연다.
      if (t.downloadPath case final path?) ...[
        const SizedBox(height: 20),
        const _Label('파일 다운로드'),
        _FolderPathLink(
          key: const ValueKey('todo-detail-download-path'),
          path: path,
          onOpen: () => _openFolder(path),
        ),
      ],
      if (t.uploadPath case final path?) ...[
        const SizedBox(height: 20),
        const _Label('파일 업로드'),
        _FolderPathLink(
          key: const ValueKey('todo-detail-upload-path'),
          path: path,
          onOpen: () => _openFolder(path),
        ),
      ],
      if (t.sourceMessageId != null && canOpenRoom) ...[
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('todo-detail-source'),
            onPressed: () => _openRoom(messageId: t.sourceMessageId),
            // 본문 왼쪽 끝에 맞춘다(기본 여백이면 한 칸 들여 보인다).
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              visualDensity: VisualDensity.compact,
            ),
            icon: const Icon(Icons.chat_bubble_outline, size: 16),
            label: const Text('원본 메시지 보기'),
          ),
        ),
      ],
      ..._commentSection(context),
    ];
  }

  /// 만든 사람 줄 — 아바타, `홍길동 님이 할 일을 추가했습니다.`(이름만 굵게 — 좁으면 잔디처럼 한 줄에서 말줄임, 두 줄로
  /// 접으면 낱말 중간에서 끊긴다), 아래 만든 시각, 오른쪽 ★ · •••.
  Widget _creatorLine(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final creator = _todo.creator;
    final name = creator?.name ?? '알 수 없음';
    return Row(
      key: const ValueKey('todo-detail-created'),
      children: [
        AvatarView(
          username: name,
          avatarType: creator?.avatarType ?? 'initial',
          avatarEmoji: creator?.avatarEmoji,
          avatarColor: creator?.avatarColor,
          avatarUrl: creator?.avatarUrl,
          resolveUrl: widget.session.resolveUrl,
          radius: 18,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    const TextSpan(text: ' 님이 할 일을 추가했습니다.'),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: hint),
              ),
              const SizedBox(height: 2),
              Text(
                formatPostDateTime(_todo.createdAt),
                key: const ValueKey('todo-detail-created-at'),
                style: TextStyle(fontSize: 12, color: hint),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        _star(context),
        _menu(context),
      ],
    );
  }

  /// 즐겨찾기 별(사람마다 따로) — 켜져 있으면 노란 별.
  Widget _star(BuildContext context) {
    final on = _todo.favorite;
    return IconButton(
      key: const ValueKey('todo-detail-star'),
      tooltip: on ? '즐겨찾기 해제' : '즐겨찾기',
      onPressed: _toggleFavorite,
      icon: Icon(
        on ? Icons.star : Icons.star_border,
        size: 22,
        color: on ? Colors.amber : Theme.of(context).hintColor,
      ),
    );
  }

  /// ••• 메뉴(잔디) — 즐겨찾기/즐겨찾기 해제(누구나) · 할 일 수정(만든 사람·담당자) · 파일 다운로드(첨부가 있을 때) ·
  /// 할 일 삭제(만든 사람, 빨강). 창 전체(루트 Navigator, [todoPopupRouteName])에 띄운다 — 패널 안 상세에서 열어도 바깥
  /// (채팅 쪽)을 누르면 닫힌다(자리는 단추 오른쪽 끝에 맞춰 패널 안).
  Widget _menu(BuildContext context) {
    return PopupMenuButton<TodoMenuAction>(
      key: const ValueKey('todo-detail-menu'),
      tooltip: '더보기',
      icon: Icon(Icons.more_horiz, color: Theme.of(context).hintColor),
      useRootNavigator: true,
      routeSettings: todoPopupRouteSettings,
      position: PopupMenuPosition.under,
      color: CompactMenu.color(context),
      shape: CompactMenu.shape,
      menuPadding: CompactMenu.menuPadding,
      constraints: todoMenuConstraints,
      onSelected: (action) => switch (action) {
        TodoMenuAction.favorite => _toggleFavorite(),
        TodoMenuAction.edit => _edit(),
        TodoMenuAction.download => _download(),
        TodoMenuAction.upload => uploadTodoFiles(
          context,
          widget.session,
          _todo,
        ),
        TodoMenuAction.delete => _delete(),
      },
      // 목록·일정 카드의 ⋯와 같은 항목(todo_menu.dart).
      itemBuilder: (context) =>
          todoMenuItems(context, _todo, downloading: _downloading),
    );
  }

  /// 테두리 상자 — 진행률 · 대화방 · 담당자 · 일정.
  Widget _infoBox(BuildContext context, Room? room, bool canOpenRoom) {
    return Container(
      key: const ValueKey('todo-detail-box'),
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 16),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _progressLine(context),
          const SizedBox(height: 6),
          _roomLine(context, room, canOpenRoom),
          const SizedBox(height: 18),
          ..._assigneeLines(context),
          const SizedBox(height: 18),
          ..._scheduleLines(context),
        ],
      ),
    );
  }

  /// 상자 안 칸 이름(진행률·대화방) — 회색, 값과 한 칸 띄운다.
  Widget _fieldLabel(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(right: 10),
    child: Text(
      text,
      style: TextStyle(fontSize: 14, color: Theme.of(context).hintColor),
    ),
  );

  /// `진행률 75%` — 전체(집계) 진척률을 굵게 진척률 색으로. 담당자 없는 개인 할 일을 내가 바꿀 수 있으면 값 대신 고르기
  /// 상자(담당자가 있으면 내 담당자 줄에서 고른다).
  Widget _progressLine(BuildContext context) {
    final t = _todo;
    final selectable = t.assignees.isEmpty && t.canSetProgress;
    return Row(
      children: [
        _fieldLabel(context, '진행률'),
        if (selectable)
          TodoProgressSelect(
            key: const ValueKey('todo-detail-my-progress'),
            progress: _pendingProgress ?? t.myProgress ?? t.progress,
            onSelected: _setProgress,
          )
        else
          Flexible(
            child: Text(
              todoPercentText(t.progress),
              key: const ValueKey('todo-detail-status'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: todoProgressColor(context, t.progress),
              ),
            ),
          ),
      ],
    );
  }

  /// `대화방 영업 토픽 ›` — 방 이름을 굵게. 방을 여는 손잡이가 있으면 눌러 그 방으로 간다(상세는 닫힌다).
  Widget _roomLine(BuildContext context, Room? room, bool canOpen) {
    final name =
        room?.displayName(widget.session.userId ?? '') ??
        _todo.roomName ??
        '대화방';
    return Row(
      children: [
        _fieldLabel(context, '대화방'),
        Flexible(
          child: InkWell(
            key: const ValueKey('todo-detail-room'),
            onTap: canOpen ? () => _openRoom() : null,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (canOpen)
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: Theme.of(context).hintColor,
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 담당자 — `총 N명` 아래로 한 줄에 한 명(아바타, 이름, 나면 `(나)`, 오른쪽에 그 사람의 진척률). 내 줄은 고르기 상자
  /// (내 진척률을 바꾼다), 다른 사람은 같은 자리에 색 글자만. 담당자가 없으면 `담당자 없음`.
  List<Widget> _assigneeLines(BuildContext context) {
    final t = _todo;
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    if (t.assignees.isEmpty) {
      return [
        Text(
          '담당자 없음',
          key: const ValueKey('todo-detail-no-assignee'),
          style: TextStyle(fontSize: 14, color: hint),
        ),
      ];
    }
    final me = widget.session.userId;
    return [
      Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: '총 '),
            TextSpan(
              text: '${t.assignees.length}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const TextSpan(text: '명'),
          ],
        ),
        key: const ValueKey('todo-detail-assignee-summary'),
        style: TextStyle(fontSize: 14, color: hint),
      ),
      const SizedBox(height: 6),
      for (final a in t.assignees) _assigneeLine(context, a, isMe: a.id == me),
    ];
  }

  Widget _assigneeLine(BuildContext context, AppUser a, {required bool isMe}) {
    final t = _todo;
    final mine = isMe && t.canSetProgress;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        key: ValueKey('todo-detail-assignee-${a.id}'),
        children: [
          UserAvatar(
            user: a,
            resolveUrl: widget.session.resolveUrl,
            radius: 16,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    a.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                if (isMe) ...[
                  const SizedBox(width: 4),
                  Text(
                    '(나)',
                    style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          TodoProgressSelect(
            key: mine ? const ValueKey('todo-detail-my-progress') : null,
            progress: mine
                ? _pendingProgress ?? t.myProgress ?? t.progressOf(a.id)
                : t.progressOf(a.id),
            onSelected: mine ? _setProgress : null,
          ),
        ],
      ),
    );
  }

  /// 일정 — 기간(🕐, 지난 기한·미완료면 빨강, 없으면 `없음`)과 알림(⏰, 보낸 것은 흐리게, 없으면 `없음`).
  List<Widget> _scheduleLines(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final t = _todo;
    final period = t.periodText;
    final overdue = t.isOverdue();
    return [
      Text('일정', style: TextStyle(fontSize: 14, color: hint)),
      const SizedBox(height: 8),
      _iconLine(
        context,
        Icons.schedule,
        Text(
          period ?? '없음',
          key: const ValueKey('todo-detail-period'),
          style: TextStyle(
            fontSize: 14,
            color: period == null
                ? hint
                : overdue
                ? theme.colorScheme.error
                : null,
            fontWeight: overdue ? FontWeight.w600 : null,
          ),
        ),
      ),
      const SizedBox(height: 8),
      _iconLine(
        context,
        Icons.alarm,
        t.reminders.isEmpty
            ? Text(
                '없음',
                key: const ValueKey('todo-detail-no-reminder'),
                style: TextStyle(fontSize: 14, color: hint),
              )
            : Column(
                key: const ValueKey('todo-detail-reminders'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (i, r) in t.reminders.indexed)
                    Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                      child: Text(
                        formatTodoDateTime(r.remindAt) +
                            (r.sent ? ' (알림 보냄)' : ''),
                        style: TextStyle(
                          fontSize: 14,
                          color: r.sent ? hint : null,
                        ),
                      ),
                    ),
                ],
              ),
      ),
    ];
  }

  /// 아이콘(회색) + 내용 한 줄 — 일정 칸의 기간·알림.
  Widget _iconLine(BuildContext context, IconData icon, Widget child) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 1),
        child: Icon(icon, size: 18, color: Theme.of(context).hintColor),
      ),
      const SizedBox(width: 10),
      Expanded(child: child),
    ],
  );

  /// 첨부를 내려받는 동안 — `다운로드 중 1/3`과 진행 막대.
  Widget _downloadProgress(BuildContext context) {
    final done = _downloadDone ?? 0;
    return Padding(
      key: const ValueKey('todo-download-progress'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            '다운로드 중 $done/$_downloadTotal',
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: _downloadTotal == 0 ? null : done / _downloadTotal,
                minHeight: 4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 폴더 경로 한 줄 — 📁 + 경로(강조색·밑줄). 누르면 [onOpen](윈도우 탐색기로 열기).
class _FolderPathLink extends StatelessWidget {
  final String path;
  final VoidCallback onOpen;
  const _FolderPathLink({super.key, required this.path, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Align(
      alignment: Alignment.centerLeft,
      child: Tooltip(
        message: '윈도우 탐색기로 열기',
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.folder_open_outlined, size: 18, color: primary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    path,
                    style: TextStyle(
                      fontSize: 14,
                      color: primary,
                      decoration: TextDecoration.underline,
                      decorationColor: primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
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
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: hint,
              ),
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
