import 'dart:async';
import 'dart:math' as math;

import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import '../models/message.dart';
import '../models/room.dart';
import '../services/api_client.dart' show UploadCancelToken;
import '../services/app_platform.dart';
import '../services/file_type_utils.dart';
import '../services/memory_file.dart';
import '../services/mention_logic.dart';
import '../services/room_chat_controller.dart';
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/mention_autocomplete.dart';
import '../widgets/attachment_widgets.dart'
    show DropZoneOverlay, formatFileSize;
import '../widgets/dropped_files.dart';
import '../widgets/rich_text_format.dart';
import '../widgets/xfile_image.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'schedule_message_dialog.dart';
import '../widgets/retrying_network_image.dart';
import '../l10n/tr.dart';

/// 게시글 작성·수정 창이 지금 몇 개 떠 있는지. 떠 있는 동안은 뒤에 깔린 채팅방·댓글 패널의 파일
/// 드롭 영역을 꺼서(chat_panel.dart, message_thread_screen.dart) 편집기에 끌어다 놓은 파일이 뒤
/// 화면 입력칸에도 같이 들어가지 않게 한다 — desktop_drop은 가려진 드롭 영역에도 이벤트를 준다.
final postEditorsOpen = ValueNotifier<int>(0);

/// 본문 글자 수를 이만큼 넘게 쓰면 입력칸 아래에 "n/20000"을 보여준다(평소엔 숨김).
const _bodyCounterFrom = postTextMaxLength * 9 ~/ 10;

/// 게시글 작성([post]가 없을 때)·수정 창을 연다 — 넓은 창(PC)은 대화상자, 좁은 창(모바일)은 전체
/// 화면. [initialFiles]는 보드에 끌어다 놓은 파일처럼 처음부터 붙여 둘 파일. 게시(수정은 저장)했으면
/// true.
Future<bool> showPostEditor(
  BuildContext context, {
  required Session session,
  required Room room,
  Message? post,
  List<XFile> initialFiles = const [],
}) async {
  final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  final editor = PostEditor(
    session: session,
    room: room,
    post: post,
    initialFiles: initialFiles,
    asDialog: wide,
  );
  postEditorsOpen.value++;
  try {
    final saved = wide
        ? await showDialog<bool>(
            context: context,
            // 바깥을 잘못 눌러 쓰던 글이 날아가지 않게 — 닫기는 취소·Esc(내용이 있으면 확인 후)로만.
            barrierDismissible: false,
            builder: (_) => editor,
          )
        : await Navigator.of(context).push<bool>(
            MaterialPageRoute(fullscreenDialog: true, builder: (_) => editor),
          );
    return saved ?? false;
  } finally {
    postEditorsOpen.value--;
  }
}

/// 편집기에 붙인 파일 하나 — 붙이자마자 차례로 올리고(_pumpUploads), 게시할 때는 올라간
/// 결과([result])만 모아 보낸다. 게시 버튼을 누를 때까지 기다리지 않아서, 글을 쓰는 동안 업로드가
/// 끝나 있다(채팅 입력칸과 같은 방식).
class _Draft {
  _Draft({
    required this.file,
    required this.name,
    required this.size,
    required this.isImage,
  });

  final XFile file;
  final String name;

  /// 처음엔 0 — 붙인 직후 파일 크기를 읽어 채운다(XFile.length()가 비동기라).
  int size;
  final bool isImage;

  /// 다시 시도하면 새 토큰으로 바꾼다 — 예전 시도의 늦은 결과를 알아보려고.
  UploadCancelToken token = UploadCancelToken();
  int sent = 0;
  int total = 0;
  UploadedAttachment? result;
  String? error;

  /// 목록에서 뺐는지 — 올리는 중에 빼면 끝난 뒤 결과를 버린다.
  bool removed = false;

  bool get pending => result == null && error == null;

  double? get progress {
    final all = total > 0 ? total : size;
    return all > 0 ? (sent / all).clamp(0.0, 1.0) : null;
  }
}

/// 게시글 작성·수정 화면(대화상자/전체 화면 공용) — 제목·본문(서식 가능)·첨부(최대 30개, Windows는
/// 끌어다 놓기·이미지 붙여넣기도). Ctrl+Enter로 게시, Esc로 닫는다. 수정 모드는 제목·본문만 고칠 수
/// 있다(서버가 첨부 수정을 받지 않아 첨부는 보여주기만 한다).
class PostEditor extends StatefulWidget {
  final Session session;
  final Room room;

  /// 고칠 게시글(없으면 새 글).
  final Message? post;
  final List<XFile> initialFiles;

  /// 대화상자(PC)로 그릴지, 전체 화면(모바일)으로 그릴지.
  final bool asDialog;

  const PostEditor({
    super.key,
    required this.session,
    required this.room,
    this.post,
    this.initialFiles = const [],
    this.asDialog = true,
  });

  @override
  State<PostEditor> createState() => PostEditorState();
}

/// 끌어다 놓기처럼 바깥에서 파일을 더할 수 있게(테스트·캡처 포함) 공개해 둔다.
class PostEditorState extends State<PostEditor> {
  late final _title = TextEditingController(text: widget.post?.title ?? '');
  final _titleFocus = FocusNode(debugLabel: 'post-title');
  final _body = RichTextEditingController();
  final _bodyFocus = FocusNode(debugLabel: 'post-body');
  final _drafts = <_Draft>[];
  String? _titleError;
  String? _bodyError;

  /// 고른 말머리 id(없으면 null) — 고치는 글이면 지금 말머리로 시작한다(지워진 말머리면 고르지 않은 것으로).
  late String? _categoryId = widget.room
      .boardCategoryById(widget.post?.categoryId)
      ?.id;

  /// 새 글을 필독으로 올릴지 — 토픽을 관리할 수 있는 사람에게만 보인다(서버도 다시 확인한다).
  bool _mustRead = false;

  /// 입력칸은 커서만 옮겨도(포커스를 받을 때 등) 알림이 오므로, 글자가 실제로 바뀔 때만 칸 아래
  /// 오류를 지우려고 마지막 글을 기억해 둔다.
  String _lastTitle = '';
  String _lastBody = '';
  bool _submitting = false;
  bool _dragHovering = false;

  /// "예약"을 눌러 첨부 업로드를 기다리는 중이거나 예약 창이 떠 있는 동안 — 게시·예약 단추를 막고,
  /// 위에 뜬 예약 창에 끌어다 놓은 파일이 이 편집기에도 같이 들어오지 않게 끌어다 놓기를 끈다.
  bool _scheduling = false;

  /// 그중 첨부 업로드를 기다리는 동안만 — 예약 단추에 진행 표시를 띄운다(예약 창이 떠 있는 동안에는
  /// 돌지 않게).
  bool _waitingUploadsToSchedule = false;

  /// 서식 도구모음을 펼쳤는지 — PC 대화상자는 늘 펼치고, 휴대폰은 본문 칸을 넓게 쓰도록 접어 두었다가
  /// 제목줄의 "서식" 단추(채팅 입력칸과 같은 T 단추)로 편다.
  late bool _formatOpen = widget.asDialog;

  /// 업로드 줄이 도는 동안만 있다 — 게시할 때 이게 끝나기를 기다린다.
  Completer<void>? _uploadsIdle;
  _Draft? _uploading;

  bool get _editing => widget.post != null;

  /// 말머리를 고를 수 있는지(이 보드에 말머리가 있을 때).
  bool get _hasCategories => widget.room.boardCategories.isNotEmpty;

  /// 필독 체크 — 새 글이고 토픽을 관리할 수 있을 때.
  bool get _canMarkMustRead =>
      !_editing && widget.room.canManage(widget.session);

  /// 고치는 글의 말머리가 바뀌었는지(지워진 말머리를 들고 있던 글은 고르지 않으면 그대로 둔다).
  bool get _categoryChanged {
    final post = widget.post;
    if (post == null) return false;
    return _categoryId != widget.room.boardCategoryById(post.categoryId)?.id;
  }

  /// 이 보드의 컨트롤러 — 편집기를 열 때 한 번 받아 둔다. 방이 사라진 뒤(내보내짐·삭제) 다시 찾으면
  /// 목록에 없는 방의 컨트롤러가 새로 만들어진다.
  late final RoomChatController _controller;

  /// 편집기를 열 때 이 보드가 내 목록에 있었는지 — 있다가 사라지면 편집기도 닫는다.
  late final bool _roomListed;
  bool _closedForRemovedRoom = false;

  /// 첨부가 아직 올라가는 중인지 — 테스트·도움말 캡처가 업로드가 끝나기를 기다릴 때 쓴다.
  bool get debugUploading => _uploadsIdle != null;

  @override
  void initState() {
    super.initState();
    _controller = widget.session.controllerFor(widget.room);
    _roomListed = widget.session.roomById(widget.room.id) != null;
    widget.session.addListener(_onSessionChanged);
    final post = widget.post;
    // 본문 안의 "@이름" — 고치는 글이면 기존 멘션 구간을 이어 받는다.
    _body.mentionsEnabled = roomAllowsMention(widget.room);
    if (post != null) {
      _body.load(post.text ?? '', post.textFormat, mentions: post.mentions);
    }
    _lastTitle = _title.text;
    _lastBody = _body.text;
    _title.addListener(_onTitleChanged);
    _body.addListener(_onBodyChanged);
    _bodyFocus.addListener(_onFocusChanged);
    HardwareKeyboard.instance.addHandler(_handleKey);
    if (widget.initialFiles.isNotEmpty) {
      // 알림(30개 초과)은 화면이 그려진 뒤에야 띄울 수 있어서 한 프레임 미룬다.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) addFiles(widget.initialFiles);
      });
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    HardwareKeyboard.instance.removeHandler(_handleKey);
    for (final d in _drafts) {
      d.removed = true;
      d.token.cancel();
    }
    _title.dispose();
    _titleFocus.dispose();
    _body.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  /// 쓰던 보드에서 내보내졌거나 보드가 삭제됐으면(목록에서 사라짐) 더 올릴 수 없으니 묻지 않고
  /// 닫는다 — 안내 토스트는 홈 화면이 띄운다. 모바일은 채팅 화면이 먼저 목록까지 닫아 줄 수 있어서,
  /// 이미 닫히는 중이면 건드리지 않는다.
  void _onSessionChanged() {
    if (!_roomListed || _closedForRemovedRoom || !mounted) return;
    if (widget.session.roomById(widget.room.id) != null) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    _closedForRemovedRoom = true;
    for (final d in _drafts) {
      d.removed = true;
      d.token.cancel();
    }
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop(false);
    } else {
      // 위에 "작성 취소" 확인 창이 떠 있으면 편집기만 빼낸다(확인 창은 닫히면 그걸로 끝난다).
      navigator.removeRoute(route);
    }
  }

  void _onTitleChanged() {
    if (_title.text == _lastTitle) return;
    _lastTitle = _title.text;
    if (_titleError != null) setState(() => _titleError = null);
  }

  void _onBodyChanged() {
    if (_body.text == _lastBody) return;
    _lastBody = _body.text;
    if (_bodyError != null) setState(() => _bodyError = null);
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  /// Ctrl+V — 글자 붙여넣기는 그대로 두고, 클립보드에 그림이 있으면 첨부로도 붙인다(채팅 입력칸과 같다).
  bool _handleKey(KeyEvent event) {
    if (_editing || event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        HardwareKeyboard.instance.isControlPressed &&
        (_bodyFocus.hasFocus || _titleFocus.hasFocus)) {
      unawaited(_pasteImage());
    }
    return false;
  }

  Future<void> _pasteImage() async {
    Uint8List? bytes;
    try {
      bytes = await Pasteboard.image;
    } catch (_) {
      return; // 그림 붙여넣기를 못 하는 플랫폼 — 글자 붙여넣기는 이미 됐다.
    }
    if (bytes == null || bytes.isEmpty || !mounted) return;
    addFiles([
      bytesAsFile(
        bytes,
        'image_${DateTime.now().microsecondsSinceEpoch}.png',
        mimeType: 'image/png',
      ),
    ]);
  }

  /// 파일을 첨부 목록에 더하고 바로 올리기 시작한다(파일 첨부 버튼·끌어다 놓기·붙여넣기). 30개를
  /// 넘는 만큼은 빼고 알린다.
  void addFiles(List<XFile> files) {
    if (_editing || files.isEmpty || !mounted) return;
    final room = postAttachmentsMaxCount - _drafts.length;
    final accepted = files.take(math.max(0, room)).toList();
    if (accepted.length < files.length) {
      showAppToast(
        context,
        tr('첨부 파일은 {postAttachmentsMaxCount}개까지 올릴 수 있습니다.', {
          'postAttachmentsMaxCount': postAttachmentsMaxCount,
        }),
      );
    }
    if (accepted.isEmpty) return;
    final added = [
      for (final f in accepted)
        _Draft(
          file: f,
          name: f.name,
          size: 0,
          isImage: looksLikeImagePath(f.name),
        ),
    ];
    setState(() => _drafts.addAll(added));
    for (final d in added) {
      unawaited(
        d.file.length().then((n) {
          if (mounted) setState(() => d.size = n);
        }, onError: (_) {}),
      );
    }
    unawaited(_pumpUploads());
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    final picked = [
      for (final f in result?.files ?? const <PlatformFile>[])
        // 웹은 경로 없이 바이트만 온다 — xFile이 둘 다 감싼다.
        if (f.path != null || f.bytes != null) f.xFile,
    ];
    if (picked.isNotEmpty && mounted) addFiles(picked);
  }

  /// 붙인 파일을 하나씩 차례로 올린다 — 30개를 한꺼번에 올려 서버와 회선을 붙잡지 않게.
  Future<void> _pumpUploads() async {
    if (_uploadsIdle != null) return; // 이미 도는 중이면 새 파일도 그 줄이 이어서 올린다.
    final idle = _uploadsIdle = Completer<void>();
    try {
      while (mounted) {
        final next = _drafts.where((d) => d.pending && !d.removed).firstOrNull;
        if (next == null) break;
        final token = next.token;
        setState(() => _uploading = next);
        try {
          final uploaded = await _controller.uploadLocalFile(
            next.file,
            isImage: next.isImage,
            cancelToken: token,
            onProgress: (sent, total) {
              if (!mounted || next.removed) return;
              setState(() {
                next.sent = sent;
                next.total = total;
              });
            },
          );
          if (!mounted || next.removed || token != next.token) continue;
          setState(() => next.result = uploaded);
        } catch (e) {
          if (!mounted || next.removed || token != next.token) continue;
          setState(() => next.error = '$e');
          showAppToast(
            context,
            tr('\'{next.name}\' 파일을 올리지 못했습니다: {e}', {
              'next.name': next.name,
              'e': e,
            }),
          );
        }
      }
    } finally {
      _uploadsIdle = null;
      if (mounted) setState(() => _uploading = null);
      idle.complete();
    }
  }

  void _remove(_Draft d) {
    d.removed = true;
    d.token.cancel();
    setState(() => _drafts.remove(d));
  }

  void _retry(_Draft d) {
    setState(() {
      d.error = null;
      d.sent = 0;
      d.total = 0;
      d.token = UploadCancelToken();
    });
    unawaited(_pumpUploads());
  }

  /// 서버(parsePostFields)·컨트롤러와 같은 규칙으로 먼저 걸러서 칸 아래에 바로 알려준다.
  bool _validate(String title, String body) {
    final titleError = title.isEmpty
        ? tr('제목을 입력하세요.')
        : postTextLength(title) > postTitleMaxLength
        ? tr('제목은 {postTitleMaxLength}자까지 쓸 수 있습니다.', {
            'postTitleMaxLength': postTitleMaxLength,
          })
        : null;
    final bodyError = body.isEmpty
        ? tr('내용을 입력하세요.')
        : postTextLength(body) > postTextMaxLength
        ? tr('내용은 {postTextMaxLength}자까지 쓸 수 있습니다.', {
            'postTextMaxLength': postTextMaxLength,
          })
        : null;
    setState(() {
      _titleError = titleError;
      _bodyError = bodyError;
    });
    if (titleError != null) {
      _titleFocus.requestFocus();
    } else if (bodyError != null) {
      _bodyFocus.requestFocus();
    }
    return titleError == null && bodyError == null;
  }

  bool get _hasFailedUpload => _drafts.any((d) => d.error != null);

  Future<void> _submit() async {
    if (_submitting || _scheduling) return;
    final title = _title.text.trim();
    final body = _body.formatted();
    final mentions = mentionsToSend(_body, widget.room, widget.session.userId);
    if (!_validate(title, body.text)) return;
    if (_hasFailedUpload) {
      showAppToast(context, tr('올리지 못한 첨부 파일이 있습니다. 다시 시도하거나 빼 주세요.'));
      return;
    }
    setState(() => _submitting = true);
    try {
      final post = widget.post;
      if (post != null) {
        await _controller.editPost(
          post.id,
          title: title,
          text: body.text,
          textFormat: body.format,
          mentions: mentions,
          setCategory: _categoryChanged,
          categoryId: _categoryId,
        );
      } else {
        // 아직 올라가는 첨부가 있으면 끝날 때까지 기다렸다가 이어서 게시한다.
        while (_uploadsIdle != null) {
          await _uploadsIdle!.future;
        }
        if (!mounted) return;
        if (_hasFailedUpload) {
          showAppToast(context, tr('올리지 못한 첨부 파일이 있습니다. 다시 시도하거나 빼 주세요.'));
          return;
        }
        await _controller.sendPost(
          title: title,
          text: body.text,
          textFormat: body.format,
          mentions: mentions,
          attachments: [for (final d in _drafts) d.result!],
          categoryId: _categoryId,
          mustRead: _mustRead,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      // 읽기 전용·보관 등 서버가 거절하면 그 문구 그대로(MessageSendException/ApiException).
      if (mounted) showAppToast(context, '$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 새 글에서만 — 이 보드에 예약할 수 있을 때(지금 팀의 보드이고 내가 글을 쓸 수 있을 때).
  bool get _canSchedule =>
      !_editing && canScheduleIn(widget.session, widget.room);

  /// "예약" — 지금 쓴 제목·본문(서식 포함)·첨부를 채운 채로 예약 창을 연다(첨부가 다 올라간 뒤에).
  /// 예약하면 게시하지 않고 이 편집기를 닫는다 — 쓰던 글은 예약으로 옮겨 갔다. 예약 창에서 취소하면
  /// 이 편집기로 돌아와 계속 쓸 수 있다.
  Future<void> _schedule() async {
    if (_submitting || _scheduling || !_canSchedule) return;
    if (_hasFailedUpload) {
      showAppToast(context, tr('올리지 못한 첨부 파일이 있습니다. 다시 시도하거나 빼 주세요.'));
      return;
    }
    setState(() {
      _scheduling = true;
      _waitingUploadsToSchedule = _uploadsIdle != null;
    });
    try {
      while (_uploadsIdle != null) {
        await _uploadsIdle!.future;
      }
      if (!mounted) return;
      setState(() => _waitingUploadsToSchedule = false);
      if (_hasFailedUpload) {
        showAppToast(context, tr('올리지 못한 첨부 파일이 있습니다. 다시 시도하거나 빼 주세요.'));
        return;
      }
      final body = _body.formatted();
      final saved = await showScheduleMessageEditor(
        context,
        widget.session,
        room: widget.room,
        title: _title.text.trim(),
        text: body.text,
        textFormat: body.format,
        mentions: mentionsToSend(_body, widget.room, widget.session.userId),
        attachments: [
          for (final d in _drafts)
            ScheduleDraftAttachment(d.result!, file: d.isImage ? d.file : null),
        ],
      );
      if (saved == null || !mounted) return;
      // 올려 둔 첨부는 예약이 가져갔으니 업로드를 건드리지 않고 목록에서만 뗀다.
      for (final d in _drafts) {
        d.removed = true;
      }
      Navigator.of(context).pop(false);
    } finally {
      if (mounted) {
        setState(() {
          _scheduling = false;
          _waitingUploadsToSchedule = false;
        });
      }
    }
  }

  bool get _dirty {
    final post = widget.post;
    if (post != null) {
      return _title.text != (post.title ?? '') ||
          _body.text != (post.text ?? '') ||
          _categoryChanged;
    }
    return _title.text.trim().isNotEmpty ||
        _body.text.trim().isNotEmpty ||
        _drafts.isNotEmpty;
  }

  /// 취소·Esc·뒤로 가기 — 쓰던 내용이 있으면 한 번 묻는다.
  Future<void> _requestClose() async {
    if (_submitting || _scheduling) return;
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(_editing ? tr('수정 취소') : tr('작성 취소')),
          content: Text(
            _editing ? tr('고친 내용을 저장하지 않고 닫을까요?') : tr('작성 중인 게시글을 버리고 닫을까요?'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(tr('계속 쓰기')),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(tr('닫기'), style: TextStyle(color: Colors.redAccent)),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    for (final d in _drafts) {
      d.removed = true;
      d.token.cancel();
    }
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final editor = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true):
              _submit,
          const SingleActivator(LogicalKeyboardKey.numpadEnter, control: true):
              _submit,
          const SingleActivator(LogicalKeyboardKey.escape): _requestClose,
        },
        child: widget.asDialog ? _buildDialog(context) : _buildPage(context),
      ),
    );
    if ((!AppPlatform.isWindows && !kIsWeb) || _editing) return editor;
    return DropTarget(
      enable: !_scheduling,
      onDragEntered: (_) => setState(() => _dragHovering = true),
      onDragExited: (_) => setState(() => _dragHovering = false),
      onDragDone: (details) {
        setState(() => _dragHovering = false);
        if (_submitting) return;
        addFiles(droppedFiles(details));
      },
      child: editor,
    );
  }

  Widget _buildDialog(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: math.min(760, screen.width - 48),
        height: math.min(800, screen.height - 48),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(context),
                const Divider(height: 1),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                    child: _buildForm(context, attachmentsMaxHeight: 196),
                  ),
                ),
                const Divider(height: 1),
                _buildFooter(context),
              ],
            ),
            if (_dragHovering)
              const Positioned.fill(
                child: IgnorePointer(child: DropZoneOverlay()),
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
          icon: const Icon(Icons.close),
          tooltip: tr('취소'),
          onPressed: _requestClose,
        ),
        title: Text(_editing ? tr('게시글 수정') : tr('게시글 작성')),
        // 예약 단추까지 들어가면 360px 휴대폰에서 제목이 잘려서, 아이콘 단추 둘을 조금 좁게 둔다.
        titleSpacing: _canSchedule ? 4 : null,
        actions: [
          Theme(
            data: Theme.of(context).copyWith(
              visualDensity: _canSchedule ? VisualDensity.compact : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                RichFormatToggleButton(
                  open: _formatOpen,
                  onPressed: () {
                    setState(() => _formatOpen = !_formatOpen);
                    _bodyFocus.requestFocus();
                  },
                ),
                if (_canSchedule)
                  _waitingUploadsToSchedule
                      ? const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 11),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          key: const ValueKey('post-schedule'),
                          icon: const Icon(Icons.schedule_send_outlined),
                          tooltip: tr('예약'),
                          onPressed: _submitting || _scheduling
                              ? null
                              : _schedule,
                        ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _buildSubmitButton(context),
          ),
        ],
      ),
      body: Stack(
        children: [
          SafeArea(
            // 휴대폰은 키보드가 화면 절반쯤을 가려서, 대화상자처럼 본문 칸을 남는 높이만큼 늘려 채우면
            // 키보드가 올라올 때 본문 칸이 거의 사라지고 첨부가 있으면 넘친다 — 칸은 내용만큼(최소
            // 여러 줄) 키우고 화면 전체를 스크롤한다.
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: TopicChip(session: widget.session, room: widget.room),
                ),
                const SizedBox(height: 12),
                if (_hasCategories || _canMarkMustRead) ...[
                  _buildPostOptions(context),
                  const SizedBox(height: 10),
                ],
                _buildTitleField(context),
                const SizedBox(height: 6),
                _buildBodyField(context, expand: false),
                _buildBodyFooter(context),
                const SizedBox(height: 10),
                _editing
                    ? _buildExistingAttachments(context, 168)
                    : _buildDrafts(context, 168),
              ],
            ),
          ),
          if (_dragHovering)
            const Positioned.fill(
              child: IgnorePointer(child: DropZoneOverlay()),
            ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
      child: Row(
        children: [
          Icon(
            _editing ? Icons.edit_note : Icons.post_add,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Text(
            _editing ? tr('게시글 수정') : tr('게시글 작성'),
            style: theme.textTheme.titleLarge?.copyWith(
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Align(
              alignment: Alignment.centerLeft,
              child: TopicChip(session: widget.session, room: widget.room),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: tr('닫기'),
            onPressed: _submitting ? null : _requestClose,
          ),
        ],
      ),
    );
  }

  Widget _buildForm(
    BuildContext context, {
    required double attachmentsMaxHeight,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_hasCategories || _canMarkMustRead) ...[
          _buildPostOptions(context),
          const SizedBox(height: 10),
        ],
        _buildTitleField(context),
        const SizedBox(height: 6),
        Expanded(child: _buildBodyField(context)),
        _buildBodyFooter(context),
        const SizedBox(height: 10),
        _editing
            ? _buildExistingAttachments(context, attachmentsMaxHeight)
            : _buildDrafts(context, attachmentsMaxHeight),
      ],
    );
  }

  /// 제목 위 한 줄 — 말머리 고르기(보드에 말머리가 있을 때)와 "필독으로 올리기"(새 글·토픽 관리자).
  Widget _buildPostOptions(BuildContext context) {
    final categories = widget.room.boardCategories;
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (_hasCategories)
          DropdownMenu<String?>(
            key: const ValueKey('post-category'),
            initialSelection: _categoryId,
            enabled: !_submitting,
            width: 200,
            label: Text(tr('말머리')),
            inputDecorationTheme: const InputDecorationTheme(
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 12),
            ),
            onSelected: (id) => setState(() => _categoryId = id),
            dropdownMenuEntries: [
              DropdownMenuEntry<String?>(value: null, label: tr('말머리 없음')),
              for (final c in categories)
                DropdownMenuEntry<String?>(
                  value: c.id,
                  label: c.name,
                  leadingIcon: CircleAvatar(
                    radius: 6,
                    backgroundColor: c.swatch,
                  ),
                ),
            ],
          ),
        if (_canMarkMustRead)
          Tooltip(
            message: tr('멤버에게 "[필독]" 알림이 가고, 읽은 사람·안 읽은 사람을 확인할 수 있습니다.'),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _submitting
                  ? null
                  : () => setState(() => _mustRead = !_mustRead),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    key: const ValueKey('post-must-read'),
                    value: _mustRead,
                    onChanged: _submitting
                        ? null
                        : (v) => setState(() => _mustRead = v ?? false),
                  ),
                  Text(tr('필독으로 올리기')),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTitleField(BuildContext context) {
    return TextField(
      key: const ValueKey('post-title'),
      controller: _title,
      focusNode: _titleFocus,
      autofocus: true,
      enabled: !_submitting,
      maxLength: postTitleMaxLength,
      textInputAction: TextInputAction.next,
      onSubmitted: (_) => _bodyFocus.requestFocus(),
      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        hintText: tr('제목을 입력하세요'),
        errorText: _titleError,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
      ),
    );
  }

  /// 서식 도구모음 + 여러 줄 본문 — 채팅 입력칸의 서식 틀(RichFormatFrame)과 같은 모양으로 늘 펼쳐 둔다.
  /// [expand]면 주어진 높이를 다 채우고(대화상자), 아니면 내용만큼 늘어난다(휴대폰 전체 화면).
  Widget _buildBodyField(BuildContext context, {bool expand = true}) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final focused = _bodyFocus.hasFocus;
    final hasError = _bodyError != null;
    const radius = BorderRadius.all(Radius.circular(8));
    final rawField = RichFieldWrapper(
      controller: _body,
      child: TextField(
        key: const ValueKey('post-body'),
        controller: _body,
        focusNode: _bodyFocus,
        enabled: !_submitting,
        expands: expand,
        minLines: expand ? null : 8,
        maxLines: null,
        keyboardType: TextInputType.multiline,
        textAlignVertical: TextAlignVertical.top,
        style: const TextStyle(fontSize: 14.5, height: 1.5),
        decoration: InputDecoration(
          hintText: tr('내용을 입력하세요'),
          border: InputBorder.none,
          contentPadding: EdgeInsets.all(14),
        ),
      ),
    );
    // 본문에서도 "@"로 멤버를 멘션할 수 있다(비밀 대화는 지원하지 않는다).
    final field = roomAllowsMention(widget.room)
        ? MentionAutocomplete(
            controller: _body,
            focusNode: _bodyFocus,
            room: widget.room,
            myUserId: widget.session.userId,
            resolveUrl: widget.session.resolveUrl,
            child: rawField,
          )
        : rawField;
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: Border.all(
          color: hasError
              ? theme.colorScheme.error
              : focused
              ? theme.colorScheme.primary
              : theme.colorScheme.outline,
          width: focused || hasError ? 2 : 1,
        ),
        borderRadius: radius,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Column(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_formatOpen) ...[
              Container(
                color: dark
                    ? Colors.white.withValues(alpha: 0.04)
                    : const Color(0xFFF7F8FA),
                child: RichFormatToolbar(
                  controller: _body,
                  focusNode: _bodyFocus,
                ),
              ),
              Divider(height: 1, color: theme.dividerColor),
            ],
            expand ? Expanded(child: field) : field,
          ],
        ),
      ),
    );
  }

  /// 본문 아래 줄 — 왼쪽은 입력 오류, 오른쪽은 한도에 가까워졌을 때만 글자 수.
  Widget _buildBodyFooter(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _body,
      builder: (context, value, _) {
        // 서버처럼 글자 단위로 센다 — UTF-16 길이가 글자 수보다 작을 수는 없으니, 한도 근처일
        // 때만 글자를 센다(긴 본문에서 한 글자 칠 때마다 전부 세지 않게).
        final raw = value.text.length;
        final length = raw < _bodyCounterFrom
            ? raw
            : postTextLength(value.text);
        final showCounter = length >= _bodyCounterFrom;
        if (_bodyError == null && !showCounter) {
          return const SizedBox(height: 6);
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _bodyError ?? '',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
              if (showCounter)
                Text(
                  '$length/$postTextMaxLength',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: length > postTextMaxLength
                        ? theme.colorScheme.error
                        : theme.hintColor,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDrafts(BuildContext context, double maxHeight) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              tr('첨부 파일'),
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${_drafts.length}/$postAttachmentsMaxCount',
              style: TextStyle(fontSize: 12, color: hint),
            ),
            const Spacer(),
            OutlinedButton.icon(
              key: const ValueKey('post-attach'),
              onPressed: _submitting ? null : _pickFiles,
              icon: const Icon(Icons.attach_file, size: 18),
              label: Text(tr('파일 첨부')),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
        if (_drafts.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              AppPlatform.isWindows
                  ? tr('사진·파일을 이 창에 끌어다 놓거나 붙여넣어도 첨부됩니다.')
                  : tr('사진·파일을 {postAttachmentsMaxCount}개까지 첨부할 수 있습니다.', {
                      'postAttachmentsMaxCount': postAttachmentsMaxCount,
                    }),
              style: TextStyle(fontSize: 12, color: hint),
            ),
          )
        else ...[
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              // 지우기(x) 단추가 모서리 밖으로 조금 나와 있어서 그만큼 비워 둔다.
              padding: const EdgeInsets.only(top: 6, right: 6),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final d in _drafts)
                    d.isImage
                        ? _ImageDraftTile(
                            key: ObjectKey(d),
                            draft: d,
                            uploading: identical(_uploading, d),
                            onRemove: _submitting ? null : () => _remove(d),
                            onRetry: () => _retry(d),
                          )
                        : _FileDraftTile(
                            key: ObjectKey(d),
                            draft: d,
                            uploading: identical(_uploading, d),
                            onRemove: _submitting ? null : () => _remove(d),
                            onRetry: () => _retry(d),
                          ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 수정 모드의 첨부 — 서버가 게시글 첨부 수정을 받지 않아 보여주기만 한다.
  Widget _buildExistingAttachments(BuildContext context, double maxHeight) {
    final attachments = widget.post?.attachments ?? const [];
    if (attachments.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              tr('첨부 파일 {attachments.length}개', {
                'attachments.length': attachments.length,
              }),
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                tr('첨부 파일은 수정할 수 없습니다.'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: theme.hintColor),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final a in attachments)
                  a.isImage
                      ? _ExistingImageTile(
                          session: widget.session,
                          attachment: a,
                        )
                      : _FileChip(
                          name: a.fileName ?? tr('파일'),
                          status: Text(
                            a.fileSize == null
                                ? ''
                                : formatFileSize(a.fileSize!),
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.hintColor,
                            ),
                          ),
                        ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFooter(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
      child: Row(
        children: [
          // 남는 폭을 안내 글자가 다 차지해서 단추들이 늘 오른쪽 끝에 붙는다(Flexible + Spacer로 나누면
          // 안내가 짧을 때 남는 절반이 단추 오른쪽에 빈칸으로 남았다).
          Expanded(
            child: AppPlatform.isWindows
                ? Text(
                    tr('Ctrl + Enter 로 {p0} · Esc 로 닫기', {
                      'p0': _editing ? tr('저장') : tr('게시'),
                    }),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: hint),
                  )
                : const SizedBox.shrink(),
          ),
          TextButton(
            onPressed: _submitting || _scheduling ? null : _requestClose,
            child: Text(tr('취소')),
          ),
          if (_canSchedule) ...[
            const SizedBox(width: 8),
            OutlinedButton.icon(
              key: const ValueKey('post-schedule'),
              onPressed: _submitting || _scheduling ? null : _schedule,
              icon: _waitingUploadsToSchedule
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.schedule_send_outlined, size: 18),
              label: Text(tr('예약')),
            ),
          ],
          const SizedBox(width: 8),
          _buildSubmitButton(context),
        ],
      ),
    );
  }

  Widget _buildSubmitButton(BuildContext context) {
    final String busyLabel;
    final pending = _drafts.where((d) => d.pending).length;
    if (_editing) {
      busyLabel = tr('저장 중');
    } else if (pending > 0) {
      final done = _drafts.length - pending;
      busyLabel = tr('업로드 중 {done}/{_drafts.length}', {
        'done': done,
        '_drafts.length': _drafts.length,
      });
    } else {
      busyLabel = tr('게시 중');
    }
    return FilledButton(
      key: const ValueKey('post-submit'),
      onPressed: _submitting || _scheduling ? null : _submit,
      child: _submitting
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(busyLabel),
              ],
            )
          : Text(_editing ? tr('저장') : tr('게시')),
    );
  }
}

/// 어느 보드에 올리는지 — "보드 뷰" 아이콘 + 토픽 이름(공지 작성창도 같이 쓴다).
class TopicChip extends StatelessWidget {
  final Session session;
  final Room room;
  const TopicChip({super.key, required this.session, required this.room});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.dashboard_outlined, size: 13, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              room.displayName(session.userId ?? ''),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 첨부 목록 모서리의 작은 지우기(x) 단추.
class _RemoveBadge extends StatelessWidget {
  final VoidCallback onTap;
  const _RemoveBadge({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tr('첨부 빼기'),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.65),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1.5),
          ),
          child: const Icon(Icons.close, size: 12, color: Colors.white),
        ),
      ),
    );
  }
}

const _tileSize = 76.0;

/// 사진 첨부 — 정사각형 미리보기 위에 업로드 진행률(또는 실패·다시 시도).
class _ImageDraftTile extends StatelessWidget {
  final _Draft draft;
  final bool uploading;
  final VoidCallback? onRemove;
  final VoidCallback onRetry;
  const _ImageDraftTile({
    super.key,
    required this.draft,
    required this.uploading,
    required this.onRemove,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final scheme = Theme.of(context).colorScheme;
    final progress = draft.progress;
    return SizedBox(
      width: _tileSize,
      height: _tileSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ColoredBox(
              color: scheme.surfaceContainerHighest,
              child: XFileImage(
                draft.file,
                width: _tileSize,
                height: _tileSize,
                fit: BoxFit.cover,
                // 원본(수천 px)을 통째로 풀지 않고 미리보기 크기로만 푼다.
                cacheWidth: (_tileSize * dpr).round(),
                errorBuilder: (_, _, _) => Icon(
                  Icons.image_not_supported_outlined,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          if (draft.error != null)
            Positioned.fill(
              child: Material(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: onRetry,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.refresh, color: Colors.white, size: 20),
                      SizedBox(height: 2),
                      Text(
                        tr('다시 시도'),
                        style: TextStyle(color: Colors.white, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else if (draft.pending)
            Positioned(
              left: 4,
              right: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.fromLTRB(4, 3, 4, 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      uploading && progress != null
                          ? '${(progress * 100).round()}%'
                          : tr('대기 중'),
                      style: const TextStyle(color: Colors.white, fontSize: 9),
                    ),
                    const SizedBox(height: 2),
                    LinearProgressIndicator(
                      value: uploading ? progress : 0,
                      minHeight: 3,
                      backgroundColor: Colors.white24,
                      valueColor: const AlwaysStoppedAnimation(Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          if (onRemove != null)
            Positioned(
              top: -6,
              right: -6,
              child: _RemoveBadge(onTap: onRemove!),
            ),
        ],
      ),
    );
  }
}

/// 파일 첨부 — 파일 모양 아이콘 + 이름 + 크기(올리는 중이면 진행 막대).
class _FileDraftTile extends StatelessWidget {
  final _Draft draft;
  final bool uploading;
  final VoidCallback? onRemove;
  final VoidCallback onRetry;
  const _FileDraftTile({
    super.key,
    required this.draft,
    required this.uploading,
    required this.onRemove,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final size = formatFileSize(draft.size);
    final Widget status;
    if (draft.error != null) {
      status = InkWell(
        onTap: onRetry,
        child: Text(
          tr('올리지 못함 · 다시 시도'),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.error,
          ),
        ),
      );
    } else if (draft.pending) {
      final progress = draft.progress;
      status = Row(
        children: [
          Text(size, style: TextStyle(fontSize: 11, color: hint)),
          const SizedBox(width: 6),
          Expanded(
            child: LinearProgressIndicator(
              value: uploading ? progress : 0,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
              backgroundColor: theme.dividerColor,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            uploading && progress != null
                ? '${(progress * 100).round()}%'
                : tr('대기'),
            style: TextStyle(fontSize: 11, color: hint),
          ),
        ],
      );
    } else {
      status = Text(size, style: TextStyle(fontSize: 11, color: hint));
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _FileChip(
          name: draft.name,
          status: status,
          failed: draft.error != null,
        ),
        if (onRemove != null)
          Positioned(top: -6, right: -6, child: _RemoveBadge(onTap: onRemove!)),
      ],
    );
  }
}

/// 파일 한 개를 보여주는 가로 칩(새 첨부·수정 모드의 기존 첨부 공용).
class _FileChip extends StatelessWidget {
  final String name;
  final Widget status;
  final bool failed;
  const _FileChip({
    required this.name,
    required this.status,
    this.failed = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 220,
      height: _tileSize,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(
          color: failed ? theme.colorScheme.error : theme.dividerColor,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(fileIconFor(name), size: 26, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                status,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 수정 모드의 기존 사진 — 서버의 미리보기(없으면 원본)를 작은 정사각형으로.
class _ExistingImageTile extends StatelessWidget {
  final Session session;
  final MessageAttachment attachment;
  const _ExistingImageTile({required this.session, required this.attachment});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ColoredBox(
        color: scheme.surfaceContainerHighest,
        child: RetryingNetworkImage(
          imageUrl: session.resolveUrl(
            attachment.thumbnailUrl ?? attachment.fileUrl,
          ),
          width: _tileSize,
          height: _tileSize,
          fit: BoxFit.cover,
          errorWidget: (_, _, _) => SizedBox(
            width: _tileSize,
            height: _tileSize,
            child: Icon(Icons.image_outlined, color: scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

/// 파일 이름(확장자)에 맞는 아이콘 — 첨부 칩이 한눈에 구분되게.
IconData fileIconFor(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'pdf' => Icons.picture_as_pdf_outlined,
    'xls' || 'xlsx' || 'csv' => Icons.table_chart_outlined,
    'doc' ||
    'docx' ||
    'hwp' ||
    'hwpx' ||
    'txt' ||
    'md' => Icons.description_outlined,
    'ppt' || 'pptx' || 'key' => Icons.slideshow_outlined,
    'zip' || '7z' || 'rar' || 'gz' => Icons.folder_zip_outlined,
    'png' ||
    'jpg' ||
    'jpeg' ||
    'gif' ||
    'webp' ||
    'bmp' => Icons.image_outlined,
    'mp4' || 'mov' || 'avi' || 'mkv' => Icons.movie_outlined,
    'mp3' || 'wav' || 'm4a' => Icons.audiotrack_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}
