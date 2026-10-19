import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../data/stickers.dart';
import '../models/integration.dart';
import '../models/mention.dart';
import '../models/room.dart';
import '../services/api_client.dart'
    show UploadCancelToken, UploadCancelledException;
import '../services/app_platform.dart';
import '../services/clipboard_paste.dart';
import '../services/file_type_utils.dart';
import '../services/image_thumbnail.dart';
import '../services/photo_quality.dart';
import '../services/memory_file.dart';
import '../services/mention_logic.dart';
import '../services/room_chat_controller.dart';
import '../services/table_image.dart';
import '../services/typing_gate.dart';
import '../services/session.dart';
import '../screens/capture/capture_window.dart'
    if (dart.library.js_interop) '../screens/capture/capture_window_stub.dart';
import '../screens/poll_create_dialog.dart';
import '../screens/schedule_message_dialog.dart';
import '../screens/scheduled_messages_screen.dart' show ScheduledRoomBar;
import 'app_toast.dart';
import 'attachment_widgets.dart';
import 'call_button.dart';
import 'capture_upload_dialog.dart';
import 'inquiry_compose.dart';
import 'integration_widgets.dart';
import 'mention_autocomplete.dart';
import 'muted_scrollbar.dart';
import 'rich_text_format.dart';
import '../l10n/tr.dart';

/// 첨부 하나의 클라이언트 쪽 진행 상태. 첨부한 즉시(_ChatInputBarState._stageAndUpload)
/// 업로드가 시작되고, [result]가 채워지면 업로드가 끝난 것 — "보내기"는 이미 끝난 결과만
/// RoomChatController.sendUploadedAttachment에 넘긴다(다시 올리지 않는다).
class _PendingAttachment {
  final XFile file;
  final bool isImage;
  final String displayName;
  final int totalBytes;
  final Uint8List? thumbnailBytes;
  final UploadCancelToken cancelToken;

  /// 업로드 진행률(바이트) — RoomChatController.uploadAttachment의 onProgress가 갱신한다.
  int sentBytes = 0;

  /// 업로드가 끝나면 채워진다. null인 동안은 아직 업로드 중.
  UploadedAttachment? result;

  _PendingAttachment({
    required this.file,
    required this.isImage,
    required this.displayName,
    required this.totalBytes,
    required this.thumbnailBytes,
    required this.cancelToken,
  });
}

class ChatInputBar extends StatefulWidget {
  final RoomChatController controller;

  /// 화상회의 버튼(CallButton)을 이 입력칸 버튼 줄에 그리는 데 필요하다 — 원래 채팅 헤더에
  /// 있었는데, 입력칸 아래 다른 첨부 버튼들과 나란히 있는 게 더 눈에 잘 띄어서 옮겼다.
  final Session session;
  final Room room;

  /// 이모티콘 패널/미리보기는 이제 채팅 화면(chat_panel.dart)이 메시지 목록 위에 떠 있는
  /// 오버레이로 그린다(입력창을 밀어내지 않기 위해) — 그래서 상태 자체도 이 위젯이 아니라
  /// 부모가 들고 있고, 여기는 버튼과 "보낼 때 같이 실어 보내기"만 담당한다.
  final Sticker? pendingSticker;
  final bool stickerPickerOpen;

  /// 이모티콘 토글 버튼을 패널(chat_panel.dart의 StickerPicker)과 같은 TapRegion 그룹으로
  /// 묶는 값 — 안 묶으면 패널이 열린 상태에서 이 버튼을 눌러 닫으려는 탭이 "패널 바깥 탭"으로도
  /// 잡혀서, onTapOutside가 먼저(pointer down) 닫고 이 버튼의 onPressed(pointer up)가 다시
  /// 열어버리는 깜빡임이 생긴다.
  final Object stickerPickerGroupId;
  final VoidCallback onToggleStickerPicker;

  /// 전송 시도 후(성공하든 실패하든 다른 첨부와 동일하게 낙관적으로) 부모가 pendingSticker를
  /// 지우도록 알린다.
  final VoidCallback onStickerConsumed;

  /// 붙여넣을 때 클립보드를 읽는 함수 — 테스트가 가짜 클립보드를 끼운다.
  @visibleForTesting
  static ClipboardReader clipboardReader = readSystemClipboard;

  const ChatInputBar({
    super.key,
    required this.controller,
    required this.session,
    required this.room,
    this.pendingSticker,
    this.stickerPickerOpen = false,
    required this.stickerPickerGroupId,
    required this.onToggleStickerPicker,
    required this.onStickerConsumed,
  });

  @override
  State<ChatInputBar> createState() => ChatInputBarState();
}

/// 클릭으로 첨부를 고르는 것과 완전히 같은 스테이징 목록(_attachments)에 드래그앤드롭으로
/// 받은 파일도 추가할 수 있도록, 부모(chat_panel.dart)가 GlobalKey로 이 State에 접근해
/// addDroppedFiles를 호출할 수 있게 public으로 둔다(다른 필드/메서드는 계속 private).
class ChatInputBarState extends State<ChatInputBar> {
  final _controller = RichTextEditingController();
  final _focusNode = FocusNode();

  /// 첨부 목록(가로) — 넘치면([_attachmentsOverflow]) 아래에 스크롤바를 단다.
  final _attachmentScroll = ScrollController();
  bool _attachmentsOverflow = false;
  final _mentionKey = GlobalKey<MentionAutocompleteState>();
  final _attachments = <_PendingAttachment>[];
  bool _sending = false;

  /// 서식 도구모음(굵게·기울임 등)을 입력칸 위에 펼쳤는지 — 아래 줄의 "T" 버튼으로 켜고 끈다.
  bool _formatOpen = false;

  /// 첨부 중 하나라도 아직 업로드가 안 끝났으면 true — "보내기"를 비활성화하는 데 쓴다
  /// (사용자가 큰 파일을 올리는 동안 텍스트만 먼저 보내는 것도 헷갈릴 수 있어, 업로드가 다
  /// 끝날 때까지 통째로 막는 쪽을 택했다).
  bool get _uploading => _attachments.any((a) => a.result == null);

  /// 이모티콘 패널에서 하나를 고르면(chat_panel.dart의 _selectSticker) 부모가 GlobalKey로
  /// 이걸 불러 입력칸에 포커스를 되돌린다 — 안 그러면 이모티콘을 클릭한 뒤 곧바로 Enter를
  /// 눌러도 _handleKey의 "입력칸이 포커스를 갖고 있을 때만 Enter=보내기" 조건에 걸려 아무
  /// 일도 안 일어난다(이모티콘 그리드 칸을 누른 시점엔 입력칸이 포커스를 안 갖고 있으므로).
  void focusInput() {
    if (_canWrite) _focusNode.requestFocus();
  }

  /// 읽기 전용·보관된 토픽에서 이 사람이 글을 쓸 수 있는지(토픽을 관리할 수 있는 사람만) — 못
  /// 쓰면 입력칸 대신 안내 줄만 보인다. 토픽 설정·토픽 관리자가 바뀌면 세션 알림으로 다시 본다.
  late bool _canWrite = _liveRoom.canWrite(widget.session);

  /// 읽기 전용 또는 보관된 토픽인지(쓸 수 있는 관리자에게는 입력칸 위에 얇은 안내만 붙인다).
  late bool _restricted = _isRestricted(_liveRoom);
  late bool _archived = _liveRoom.isArchived;

  /// 부모가 같은 방 객체를 들고 있지만, 세션이 방을 다시 받아 바꿔 끼웠을 수도 있어서 세션 쪽을 먼저 본다.
  Room get _liveRoom => widget.session.roomById(widget.room.id) ?? widget.room;

  static bool _isRestricted(Room room) =>
      room.type == RoomType.topic && (room.readOnly || room.isArchived);

  String get _readOnlyNotice => _archived
      ? tr('보관된 토픽입니다. 토픽 관리자만 글을 쓸 수 있습니다.')
      : tr('읽기 전용 토픽입니다. 토픽 관리자만 글을 쓸 수 있습니다.');

  /// 세션이 바뀔 때마다 부르지만, 쓰기 가능 여부가 실제로 바뀐 때만 다시 그린다(입력 중 불필요한
  /// 다시 그리기를 줄이려고).
  void _onSessionChanged() {
    if (!mounted) return;
    final room = _liveRoom;
    final canWrite = room.canWrite(widget.session);
    final restricted = _isRestricted(room);
    final archived = room.isArchived;
    if (canWrite == _canWrite &&
        restricted == _restricted &&
        archived == _archived) {
      return;
    }
    final lostWrite = _canWrite && !canWrite;
    setState(() {
      _canWrite = canWrite;
      _restricted = restricted;
      _archived = archived;
      if (lostWrite) _dropComposerState();
    });
  }

  /// 글을 쓸 수 없게 되면 올리던 첨부·서식 도구모음을 치우고, 부모가 들고 있는 이모티콘
  /// 패널/미리보기도 닫게 한다(보낼 길이 없는데 남아 있지 않게).
  void _dropComposerState() {
    for (final a in _attachments) {
      a.cancelToken.cancel();
    }
    _attachments.clear();
    _formatOpen = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _canWrite) return;
      if (widget.pendingSticker != null) widget.onStickerConsumed();
      if (widget.stickerPickerOpen) widget.onToggleStickerPicker();
    });
  }

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
    HardwareKeyboard.instance.addHandler(_handleKey);
    // 비밀 대화는 서버가 서식을 받지 않는다(본문이 암호문이라 위치가 안 맞는다).
    _controller.formattingEnabled = !widget.room.isSecret;
    // 포커스를 얻으면(클릭/터치) 안내 문구(hintText)를 바로 감추고 커서만 보이게 한다 —
    // hintText는 build() 시점 값이라 포커스가 바뀔 때 다시 그려줘야 반영된다.
    _focusNode.addListener(_onFocusChange);
    _restoreDraft();
    _controller.addListener(_onTextChanged);
    _loadSlashCommands();
    _remoteDraftSub = widget.session.chatDrafts.remoteChanges.listen(
      _onRemoteDraft,
    );
  }

  /// 입력칸에 마지막으로 꺼내 둔(또는 맡긴) 글 — 이것과 같으면 손대지 않은 것이라 닫을 때 다시 맡기지 않는다. 그래야 다른 기기에서
  /// 고친 더 새 글을 이 기기의 옛 글로 덮지 않는다(draft_sync.dart).
  String _loadedText = '';
  StreamSubscription<String>? _remoteDraftSub;

  /// 다른 기기에서 이 방의 임시 저장을 고쳤다 — 입력칸에 손대지 않았고 지금 쓰고 있지 않으면(포커스 없음) 새 글로 바꾼다.
  void _onRemoteDraft(String roomId) {
    if (!mounted || roomId != widget.room.id) return;
    if (_focusNode.hasFocus || _controller.text != _loadedText) return;
    _controller.clear();
    _loadedText = '';
    _restoreDraft();
  }

  /// 이 팀의 슬래시 명령을 미리 받아 둔다(자동 완성 — 연동을 쓸 수 있는 방에서만).
  void _loadSlashCommands() {
    final room = _liveRoom;
    if (!roomAcceptsIntegrations(room)) return;
    unawaited(
      widget.session.teamCommands(room.teamId).then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  /// 입력칸이 `/명령`을 치는 중이면 고를 수 있는 슬래시 명령(앞부분이 맞는 것) — 아니면 빈 목록.
  List<Integration> get _slashSuggestions {
    final query = slashCommandQuery(_controller.text);
    final room = _liveRoom;
    if (query == null || !roomAcceptsIntegrations(room)) return const [];
    return [
      for (final c in widget.session.cachedTeamCommands(room.teamId))
        if ((c.command ?? '').startsWith(query)) c,
    ];
  }

  String? _lastSlashQuery;

  void _pickSlashCommand(Integration c) {
    final text = '/${c.command} ';
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _focusNode.requestFocus();
  }

  /// 보내려는 글이 이 팀의 슬래시 명령이면 실행하고 true — 아니면(그냥 `/`로 시작하는 글 포함) false로 보통 메시지처럼 보낸다.
  Future<bool> _trySlashCommand() async {
    final raw = _controller.text;
    final invocation = parseSlashInvocation(raw);
    final room = _liveRoom;
    if (invocation == null || !roomAcceptsIntegrations(room)) return false;
    final commands = await widget.session.teamCommands(room.teamId);
    Integration? command;
    for (final c in commands) {
      if (c.command == invocation.command) command = c;
    }
    if (command == null || !mounted) return false;
    setState(() => _sending = true);
    _controller.clear();
    String? reply;
    try {
      final result = await widget.session.runSlashCommand(
        room,
        command: invocation.command,
        text: invocation.text,
      );
      reply = result.ephemeral;
    } catch (e) {
      // 실패하면 친 글을 되돌려 고쳐서 다시 보낼 수 있게.
      if (_controller.text.isEmpty) _controller.text = raw;
      if (mounted) {
        showAppToast(
          context,
          tr('/{invocation.command} 실행 실패: {e}', {
            'invocation.command': invocation.command,
            'e': e,
          }),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _focusNode.requestFocus();
      }
    }
    // 답 창은 보내기 상태를 푼 뒤에 띄운다(창이 떠 있는 동안 입력 줄이 계속 "보내는 중"으로 남지 않게).
    if (reply != null && mounted) {
      unawaited(
        showSlashReplyDialog(
          context,
          command: invocation.command,
          botName: command.name,
          emoji: command.emoji,
          text: reply,
        ),
      );
    }
    return true;
  }

  /// 이 방에서 쓰다 만 글이 있으면 입력칸에 되살린다(다른 방에 갔다 온 경우 — [_saveDraft]).
  /// 멘션은 [MentionAutocomplete]가 나중에 켜는 mentionsEnabled가 켜져 있어야 남으므로 먼저 같은 값으로 켠다.
  void _restoreDraft() {
    final draft = widget.controller.draft;
    if (draft == null) return;
    _controller.mentionsEnabled = roomAllowsMention(_liveRoom);
    _controller.load(draft.text, draft.format, mentions: draft.mentions);
    _loadedText = _controller.text;
  }

  /// 입력칸이 사라지거나 다른 방으로 바뀔 때 쓰던 글을 그 방의 컨트롤러에 맡긴다(보내고 비웠으면 지운다).
  void _saveDraft(RoomChatController controller) {
    if (_controller.text == _loadedText) return;
    controller.draft = _controller.text.trim().isEmpty
        ? null
        : _controller.snapshot();
    _loadedText = _controller.text;
  }

  /// 한글 등을 IME로 조합하는 중이면, 그동안 앱 전체를 다시 그리는 알림을 잠깐 미룬다 — 빠르게
  /// 칠 때 그 다시 그리기가 키 처리를 늦춰서 글자가 빠지거나 뭉개지던 문제(typing_gate.dart).
  void _onTextChanged() {
    final composing = _controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      TypingGate.instance.composing();
    } else {
      TypingGate.instance.committed();
    }
    // 슬래시 명령 고르기 목록은 `/…`를 칠 때만 다시 그린다(글자마다 입력 줄 전체를 다시 그리지 않게).
    final slashQuery = slashCommandQuery(_controller.text);
    if (slashQuery != _lastSlashQuery) {
      _lastSlashQuery = slashQuery;
      if (mounted) setState(() {});
    }
    // 쓰는 동안에도 잠깐 멈추면 임시 저장한다 — 앱이 갑자기 꺼져도 남게(보내고 비우면 지워진다).
    _draftTimer?.cancel();
    _draftTimer = Timer(_draftSaveDelay, () {
      if (mounted) _saveDraft(widget.controller);
    });
  }

  Timer? _draftTimer;
  static const _draftSaveDelay = Duration(milliseconds: 600);

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant ChatInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sessionChanged = !identical(oldWidget.session, widget.session);
    if (sessionChanged) {
      oldWidget.session.removeListener(_onSessionChanged);
      widget.session.addListener(_onSessionChanged);
    }
    // 같은 자리에 다른 방이 오면(부모가 키 없이 바꿔 끼운 경우) 그 방 기준으로 다시 본다.
    if (sessionChanged || oldWidget.room.id != widget.room.id) {
      final room = _liveRoom;
      _canWrite = room.canWrite(widget.session);
      _restricted = _isRestricted(room);
      _archived = room.isArchived;
    }
    // 다른 방의 컨트롤러로 바뀌면 쓰던 글은 원래 방에 맡기고 새 방의 글을 꺼낸다.
    if (!identical(oldWidget.controller, widget.controller)) {
      _draftTimer?.cancel();
      _saveDraft(oldWidget.controller);
      _controller.clear();
      _loadedText = '';
      _restoreDraft();
    }
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    _saveDraft(widget.controller);
    _remoteDraftSub?.cancel();
    widget.session.removeListener(_onSessionChanged);
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _focusNode.removeListener(_onFocusChange);
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    _attachmentScroll.dispose();
    super.dispose();
  }

  // Ctrl+V(붙여넣기)는 여기서 다루지 않는다 — 입력칸의 PasteTextIntent를 [_ChatPasteAction]이 가로채서
  // 클립보드의 이미지·표를 보고 처리한다(아래 _paste). Ctrl+Shift+V(서식·표 변환 없는 붙여넣기)도 마찬가지.
  bool _handleKey(KeyEvent event) {
    // 환경설정 "메시지 전송 옵션" — 기본은 Enter로 보내고 Shift+Enter로 줄바꿈, 반대로 고르면
    // Shift+Enter로 보내고 Enter로 줄바꿈. 보낼 때는 true를 돌려줘서 TextField의 기본 줄바꿈
    // 삽입을 막아야 한다(안 그러면 보내는 키를 눌러도 줄바꿈이 먼저 들어가 버린다).
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final sendKey = widget.session.settings.sendWithShiftEnter ? shift : !shift;
    // 멘션 자동완성 목록이 떠 있으면 Enter는 목록에서 고르는 데 쓴다(mention_autocomplete.dart).
    if (_mentionKey.currentState?.isOpen == true) return false;
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        _focusNode.hasFocus &&
        sendKey) {
      _send();
      return true;
    }
    return false;
  }

  late final _pasteAction = _ChatPasteAction(this);

  /// Ctrl+V — 클립보드를 읽어 [decidePaste]대로 처리한다(잔디의 표 이미지 붙여넣기). 엑셀 표(글자·HTML·비트맵이 함께
  /// 온다)는 글자를 붙이지 않고 이미지를 업로드 미리보기로 올리고, 이미지 없이 탭·HTML 표만 있으면 표를 PNG로 그려서 같은
  /// 미리보기로 올린다. 그 밖에는 평소처럼 글자를 붙인다([defaultPaste] — 입력칸의 기본 붙여넣기). 표가 아닌 이미지+글자는
  /// 예전처럼 글자도 붙이고 이미지도 올린다.
  Future<void> _paste(VoidCallback defaultPaste) async {
    PasteDecision decision;
    try {
      decision = decidePaste(await ChatInputBar.clipboardReader());
    } catch (_) {
      decision = const PasteAsText();
    }
    if (!mounted) return;
    switch (decision) {
      case PasteAsText():
        defaultPaste();
      case PasteAsImage(:final bytes):
        await _stagePastedPng(bytes, 'image.png');
      case PasteAsImageAndText(:final bytes):
        defaultPaste();
        await _stagePastedPng(bytes, 'image.png');
      case PasteAsTable(:final table):
        Uint8List png;
        try {
          png = await renderTablePng(table);
        } catch (_) {
          // 그리지 못하면 표 대신 글자로 붙여넣는다.
          if (mounted) defaultPaste();
          return;
        }
        if (!mounted) return;
        await _stagePastedPng(png, 'table.png');
    }
  }

  /// Ctrl+Shift+V — 표·서식 변환 없이 언제나 글자만 커서 자리에 붙여넣는다.
  Future<void> _pasteAsPlainText() async {
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {}
    if (text == null || text.isEmpty || !mounted) return;
    final value = _controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    _controller.value = value.copyWith(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
      composing: TextRange.empty,
    );
  }

  /// 붙여넣은 PNG를 클릭으로 고른 첨부와 같은 업로드 미리보기에 올린다(디스크에 쓰지 않고 메모리에서 바로).
  Future<void> _stagePastedPng(Uint8List bytes, String displayName) async {
    final file = bytesAsFile(
      bytes,
      'paste_${DateTime.now().microsecondsSinceEpoch}.png',
      mimeType: 'image/png',
    );
    unawaited(_stageAndUpload(file, true, displayName));
  }

  bool _capturing = false;

  /// "화면 캡처" — 화면을 찍어 전체 화면 오버레이에서 영역을 고르게 하고(capture_window.dart),
  /// 결과에 따라 업로드 대화상자/바로 보내기/저장을 한다. [hideMessenger]는 찍는 동안 메신저
  /// 창을 숨길지(메신저가 캡처에 안 찍힘) 여부.
  Future<void> _startCapture(bool hideMessenger) async {
    if (_capturing) return;
    setState(() => _capturing = true);
    CaptureOutcome? outcome;
    try {
      outcome = await startScreenCapture(hideMessenger: hideMessenger);
    } catch (e) {
      if (mounted) showAppToast(context, tr('화면을 캡처하지 못했습니다: {e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
    if (outcome?.error != null && mounted) {
      showAppToast(context, tr('화면을 캡처하지 못했습니다: {p0}', {'p0': outcome!.error}));
    }
    final file = outcome?.file;
    if (outcome == null || file == null || !mounted) return;
    switch (outcome.action) {
      case 'send':
        await _uploadCapture(widget.room, file, '');
      case 'dialog':
        final choice = await showCaptureUploadDialog(
          context,
          session: widget.session,
          initialRoom: widget.room,
          file: file,
        );
        if (choice != null) {
          await _uploadCapture(choice.room, file, choice.message);
        }
      case 'save':
        await _saveCapture(file);
    }
  }

  /// [room]에 캡처 이미지를 올려서 바로 보낸다. 다른 방에 올릴 수도 있어서(업로드 대화상자의
  /// 공유 대화방) 그 방의 컨트롤러를 따로 가져온다.
  Future<void> _uploadCapture(Room room, File file, String caption) async {
    final controller = widget.session.controllerFor(room);
    if (mounted) showAppToast(context, tr('캡처를 업로드하는 중입니다...'));
    try {
      final bytes = await file.readAsBytes();
      final thumb = await generateThumbnail(bytes);
      final uploaded = await controller.uploadAttachment(
        XFile(file.path),
        isImage: true,
        originalBytes: bytes,
        thumbBytes: thumb,
      );
      await controller.sendUploadedAttachment(uploaded, caption: caption);
      if (mounted) showAppToast(context, tr('캡처를 보냈습니다.'));
    } catch (e) {
      if (mounted) showAppToast(context, tr('캡처를 보내지 못했습니다: {e}', {'e': e}));
    }
  }

  Future<void> _saveCapture(File file) async {
    final name = file.uri.pathSegments.last;
    final path = await FilePicker.saveFile(
      dialogTitle: tr('캡처 저장'),
      fileName: name,
      type: FileType.custom,
      allowedExtensions: ['png'],
    );
    if (path == null) return;
    try {
      await file.copy(path.toLowerCase().endsWith('.png') ? path : '$path.png');
      if (mounted) showAppToast(context, tr('캡처를 저장했습니다.'));
    } catch (e) {
      if (mounted) showAppToast(context, tr('저장하지 못했습니다: {e}', {'e': e}));
    }
  }

  /// 이미지든 아니든 이 버튼 하나로 고른다 — 이미지인지는 확장자로 판별해서(끌어다 놓기와
  /// 같은 방식) 이미지면 썸네일을 만들어 미리보기로 보여준다. 여러 개를 한 번에 고를 수
  /// 있고, 고른 파일마다 각자 스테이징+업로드를 시작한다(병렬로 올라가고, _send()가 그
  /// 시점까지 쌓인 걸 한 번에 보낸다).
  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    final picked = result?.files ?? const [];
    if (picked.isEmpty || !mounted) return;
    for (final file in picked) {
      // 웹은 경로 없이 바이트만 온다 — xFile이 둘 다 감싼다.
      if (file.path == null && file.bytes == null) continue;
      unawaited(
        _stageAndUpload(file.xFile, looksLikeImagePath(file.name), file.name),
      );
    }
  }

  /// "문의하기" — 팀장과의 1:1 대화방에서 문의(티켓)를 만들고 같은 내용을 메시지로도 보낸다(inquiry_compose.dart).
  Future<void> _showInquiryDialog() =>
      sendInquiryTo(context, widget.session, widget.room);

  /// 파일 탐색기에서 채팅 입력칸(또는 chat_panel.dart 전체)으로 끌어다 놓은 파일들을 추가한다
  /// (chat_panel.dart의 DropTarget.onDragDone에서 호출). 클릭으로 고를 때(_pickFile)와
  /// 완전히 같은 방식으로 즉시 업로드가 시작된다 — 다만 "어느 버튼으로 골랐는지" 신호가 없어서
  /// 이미지 여부는 확장자로 판별한다(looksLikeImagePath).
  void addDroppedFiles(List<XFile> files) {
    if (files.isEmpty || !mounted) return;
    if (!_canWrite) {
      // 읽기 전용·보관된 토픽 — 끌어다 놓아도 올리지 않고 이유만 알린다.
      showAppToast(context, _readOnlyNotice);
      return;
    }
    for (final file in files) {
      unawaited(
        _stageAndUpload(file, looksLikeImagePath(file.name), file.name),
      );
    }
  }

  /// 첨부 하나를 스테이징 목록에 즉시 추가하고(썸네일/용량이 바로 보이도록), 곧바로 서버
  /// 업로드를 시작한다 — "보내기"를 누르기 전부터 진행률이 보이고, 실제로 보내기를 누르는
  /// 시점엔 이미 업로드가 끝나 있어 지연 없이 바로 전송된다.
  Future<void> _stageAndUpload(
    XFile picked,
    bool isImage,
    String displayName,
  ) async {
    var file = picked;
    var bytes = await picked.readAsBytes();
    // 휴대폰 데이터면 사진을 일반 화질로 줄여 보낸다(photo_quality.dart — 환경설정에서 끌 수 있음).
    if (isImage) {
      final reduced = await photoForUpload(
        widget.session.settings,
        picked,
        bytes,
        name: displayName,
      );
      if (reduced != null) {
        file = reduced.file;
        bytes = reduced.bytes;
      }
    }
    final thumbBytes = isImage ? await generateThumbnail(bytes) : null;
    if (!mounted) return;

    final attachment = _PendingAttachment(
      file: file,
      isImage: isImage,
      displayName: displayName,
      totalBytes: bytes.length,
      thumbnailBytes: thumbBytes,
      cancelToken: UploadCancelToken(),
    );
    setState(() => _attachments.add(attachment));

    try {
      final uploaded = await widget.controller.uploadAttachment(
        file,
        isImage: isImage,
        originalBytes: bytes,
        thumbBytes: thumbBytes,
        onProgress: (sent, total) {
          if (!mounted) return;
          setState(() => attachment.sentBytes = sent);
        },
        cancelToken: attachment.cancelToken,
      );
      if (!mounted) return;
      setState(() => attachment.result = uploaded);
    } on UploadCancelledException {
      // 조용히 무시 — X 버튼으로 이미 목록에서 제거됨(_cancelAttachment 참고).
    } catch (e) {
      if (!mounted) return;
      setState(() => _attachments.remove(attachment));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('업로드 실패: {e}', {'e': e}))));
    }
  }

  /// 업로드 중이든 이미 끝났든 상관없이 첨부를 취소/제거한다. 아직 업로드 중이면
  /// cancelToken으로 네트워크 전송 자체를 중단시킨다(ApiClient.uploadFile 참고).
  void _cancelAttachment(_PendingAttachment a) {
    a.cancelToken.cancel();
    setState(() => _attachments.remove(a));
  }

  Future<void> _send() async {
    // 읽기 전용·보관된 토픽에서는 입력칸이 없지만, 남아 있던 이모티콘 등이 새지 않게 한 번 더 막는다.
    if (!_canWrite) return;
    final (:text, :format) = _controller.formatted();
    // 비우기 전에 잡아 둔다 — 멘션 구간은 입력칸이 들고 있다.
    final mentions = mentionsToSend(
      _controller,
      _liveRoom,
      widget.session.userId,
    );
    final sticker = widget.pendingSticker;
    if (_attachments.isEmpty && text.isEmpty && sticker == null) return;
    if (_uploading) return; // 버튼 자체도 막지만, 이중 방어.
    // `/명령 내용` — 이 팀의 슬래시 명령이면 메시지 대신 명령을 실행한다(첨부·이모티콘이 없을 때만).
    if (_attachments.isEmpty &&
        sticker == null &&
        !_sending &&
        await _trySlashCommand()) {
      return;
    }
    if (!mounted) return;

    final toSend = List<_PendingAttachment>.from(_attachments);
    setState(() {
      _attachments.clear();
      _sending = true;
    });
    _controller.clear();
    // 조합하느라 미뤄 둔 화면 갱신을 지금 내보낸다 — 보낸 메시지가 바로 보이게.
    TypingGate.instance.flush();
    widget.onStickerConsumed();
    // 보내기 버튼을 마우스로 눌렀을 때 포커스가 버튼으로 넘어가버리는 걸 막고, 계속
    // 이어서 입력할 수 있도록 입력칸에 커서를 유지한다.
    _focusNode.requestFocus();

    try {
      // 이모티콘과 메시지는 같은 말풍선으로 합치지 않고 각자 메시지로 보내되, 이모티콘이
      // 타임라인에서 메시지보다 먼저(위에) 보이도록 반드시 순서대로(동시 아님) 보낸다.
      if (sticker != null) await widget.controller.sendSticker(sticker.id);

      if (toSend.isEmpty) {
        await widget.controller.sendText(
          text,
          format: format,
          mentions: mentions,
        );
      } else {
        // 첨부와 함께 입력한 메시지는 별도 메시지로 보내지 않고, 첫 번째 첨부의 캡션으로
        // 붙인다. 업로드는 첨부하는 순간 이미 끝나 있으므로(_stageAndUpload) 여기선 그
        // 결과로 메시지만 보낸다. 사진은 한 말풍선에 격자로 모아 보내고(여러 장이면),
        // 파일도 여러 개면 한 말풍선에 목록으로 모아 보낸다(아래 "전체 다운로드"가 붙는다).
        final images = [
          for (final a in toSend)
            if (a.result!.isImage) a.result!,
        ];
        final files = [
          for (final a in toSend)
            if (!a.result!.isImage) a.result!,
        ];
        var caption = text;
        List<TextFormatRun>? captionFormat = format;
        List<Mention>? captionMentions = mentions;
        if (images.isNotEmpty) {
          await widget.controller.sendUploadedAttachments(
            images,
            caption: caption,
            captionFormat: captionFormat,
            captionMentions: captionMentions,
          );
          caption = '';
          captionFormat = null;
          captionMentions = null;
        }
        if (files.isNotEmpty) {
          await widget.controller.sendUploadedAttachments(
            files,
            caption: caption.isEmpty ? null : caption,
            captionFormat: captionFormat,
            captionMentions: captionMentions,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('전송 실패: {e}', {'e': e}))));
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _focusNode.requestFocus();
      }
    }
  }

  /// 단추 줄에 멘션(@)·투표 단추를 따로 놓을 자리가 있는지 — 단추 줄은 고정 폭 단추들이라 좁은 화면(휴대폰에
  /// 팀장 문의 단추까지 붙은 경우 등)에서 하나 더 넣으면 줄이 넘친다. 지금 보일 단추 수로 필요한
  /// 폭을 어림해서(단추당 48) 남는 자리가 있을 때만 별도 단추로 그리고(멘션이 먼저, 둘 다 촘촘한 폭 40),
  /// 없으면 파일 단추가 (파일 · 투표 · 멘션) 메뉴가 되어 거기에 합친다 — 어떤 폭에서도 세 기능에 모두
  /// 들어갈 수 있고 줄은 넘치지 않는다.
  ({bool mention, bool poll}) _standaloneButtons(double maxWidth) {
    final session = widget.session;
    final room = _liveRoom;
    var others = 3; // 이모티콘 · 파일 · 보내기.
    if (!room.isSecret) others++; // 서식(T)
    if (AppPlatform.isWindows) others++; // 화면 캡처
    if (_showCallButton && session.callsEnabled) others++;
    if (session.canSendInquiryIn(widget.room)) others++;
    if (canScheduleIn(session, room)) others++;
    var left = maxWidth - others * 48.0;
    const compact = 40.0;
    final mention = roomAllowsMention(room) && left >= compact;
    if (mention) left -= compact;
    final poll = canCreatePollIn(session, room) && left >= compact;
    return (mention: mention, poll: poll);
  }

  /// 멘션·투표 중 별도 단추를 못 놓은 것이 있으면(좁은 화면) 파일 단추가 메뉴가 된다.
  bool _needsAttachMenu(double maxWidth) {
    final room = _liveRoom;
    final own = _standaloneButtons(maxWidth);
    return (canCreatePollIn(widget.session, room) && !own.poll) ||
        (roomAllowsMention(room) && !own.mention);
  }

  /// 좁은 화면의 파일 단추 — 별도 단추를 못 놓은 기능(투표·멘션)을 메뉴 항목으로 모아 둔다.
  Widget _buildAttachMenu(double maxWidth) {
    final room = _liveRoom;
    final own = _standaloneButtons(maxWidth);
    final poll = canCreatePollIn(widget.session, room) && !own.poll;
    final mention = roomAllowsMention(room) && !own.mention;
    return PopupMenuButton<String>(
      key: const ValueKey('chat-attach-menu'),
      icon: const Icon(Icons.attach_file),
      tooltip: [
        tr('파일'),
        if (poll) tr('투표'),
        if (mention) tr('멘션'),
      ].join(' · '),
      enabled: !_sending,
      onSelected: (v) {
        switch (v) {
          case 'poll':
            _openPollCreator();
          case 'mention':
            _mentionKey.currentState?.insertTrigger();
          default:
            _pickFile();
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'file', child: Text(tr('파일 보내기'))),
        if (poll) PopupMenuItem(value: 'poll', child: Text(tr('투표'))),
        if (mention)
          PopupMenuItem(
            key: ValueKey('chat-attach-mention'),
            value: 'mention',
            child: Text(tr('멘션 (@)')),
          ),
      ],
    );
  }

  /// "투표"(막대그래프 단추) — 투표 만들기 창을 연다. 만들어지면 서버가 방에 뿌리는 message:new로
  /// 목록에 나타난다(다른 메시지 전송과 같다). 쓰던 글·첨부는 건드리지 않는다.
  Future<void> _openPollCreator() async {
    if (!_canWrite || _sending) return;
    await showPollCreator(context, session: widget.session, room: _liveRoom);
  }

  /// "메시지 예약"(시계 단추) — 쓰던 글(서식 포함)과 이미 올라간 첨부를 채운 채로 예약 편집기를 연다.
  /// 예약하면 넘긴 글·첨부를 입력칸에서 비운다(예약으로 옮겨 갔으니). 취소하면 그대로 남는다.
  Future<void> _openScheduleEditor() async {
    if (!_canWrite || _sending || _uploading) return;
    final draftText = _controller.text;
    final (:text, :format) = _controller.formatted();
    final staged = List<_PendingAttachment>.from(_attachments);
    final saved = await showScheduleMessageEditor(
      context,
      widget.session,
      room: _liveRoom,
      text: text,
      textFormat: format,
      mentions: mentionsToSend(_controller, _liveRoom, widget.session.userId),
      attachments: [
        for (final a in staged)
          ScheduleDraftAttachment(
            a.result!,
            thumbnailBytes: a.thumbnailBytes,
            file: a.file,
          ),
      ],
    );
    if (saved == null || !mounted) return;
    setState(() => _attachments.removeWhere(staged.contains));
    // 그 사이 새로 쓴 글이 있으면(다른 경로로 입력칸이 바뀐 드문 경우) 지우지 않는다.
    if (_controller.text == draftText) _controller.clear();
  }

  /// 입력칸 위의 "예약된 메시지 N개 · 보기" 줄 — 이 방에 내 예약이 있을 때만 보인다.
  Widget _buildScheduledBar() => ScheduledRoomBar(
    session: widget.session,
    room: _liveRoom,
    padding: const EdgeInsets.only(bottom: 6),
  );

  /// 나와의 대화에는 함께할 사람이 없어서 화상회의 단추를 두지 않는다.
  bool get _showCallButton => !_liveRoom.isSelf;

  /// 글을 쓸 수 없는 사람에게 입력칸 대신 보여주는 안내 줄(입력칸·첨부·이모티콘 버튼 없음).
  /// 화상회의는 글쓰기가 아니라서 진행 중인 회의에 참여할 수 있게 버튼을 남긴다.
  Widget _buildReadOnlyNotice(BuildContext context) {
    final theme = Theme.of(context);
    final callButton =
        widget.session.callsEnabled && !widget.room.isSecret && _showCallButton;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 쓸 수 없게 된 뒤에도 남은 예약(보낼 때 실패한다)을 찾아 정리할 수 있게 둔다.
            _buildScheduledBar(),
            _buildReadOnlyBox(theme, callButton),
          ],
        ),
      ),
    );
  }

  /// 읽기 전용·보관 안내 상자 — [callButton]이면 오른쪽 끝에 화상회의 단추가 붙는다.
  Widget _buildReadOnlyBox(ThemeData theme, bool callButton) {
    return Container(
      key: const ValueKey('chat-input-read-only-notice'),
      constraints: const BoxConstraints(minHeight: 46),
      padding: EdgeInsets.fromLTRB(14, 4, callButton ? 4 : 14, 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            _archived ? Icons.inventory_2_outlined : Icons.lock_outline,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          // 좁은 화면에서는 두 문장을 두 줄로 나눠서, 한글이 낱자로 어색하게 끊기지 않게 한다.
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: _archived ? tr('보관된 토픽입니다.') : tr('읽기 전용 토픽입니다.'),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    TextSpan(text: constraints.maxWidth < 360 ? '\n' : ' '),
                    TextSpan(text: tr('토픽 관리자만 글을 쓸 수 있습니다.')),
                  ],
                ),
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          // 화상회의를 쓰지 않는 서버면 CallButton이 스스로 빈칸이 된다.
          if (_showCallButton)
            Theme(
              data: theme.copyWith(visualDensity: VisualDensity.compact),
              child: CallButton(session: widget.session, room: widget.room),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_canWrite) return _buildReadOnlyNotice(context);
    final uploading = _uploading;
    final hintColor = Theme.of(context).hintColor;
    // 입력칸 둘레(보내기·첨부·서식 단추 등)를 눌러도 입력칸 "바깥"을 누른 것으로 치지 않는다. 웹에서 터치하면 Flutter는
    // 입력칸 바깥을 누르는 순간 포커스를 놓았다가(_send가 곧 다시 잡는다) 그 사이 그린 프레임에서 키보드가 떠 있는 높이를
    // 화면 높이로 몰래 다시 잰다(엔진 handleFrameworkResize — 입력 중이 아닐 때만). 그 뒤 뒤로가기로 키보드를 닫으면
    // 다시 입력 중이라 그 줄어든 높이에 묶여서, 안드로이드 웹 앱 아래에 키보드만큼 빈 공간이 남았다.
    return TextFieldTapRegion(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            // 입력칸(TextField)이 이 칸 전체 폭을 채우도록(예전엔 Row 안 Expanded로
            // 채웠지만, 이제는 입력칸이 직접 자식이라 stretch로 채운다).
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildScheduledBar(),
              // 읽기 전용·보관된 토픽인데 토픽 관리자라 쓸 수 있는 경우 — 다른 멤버는 못 쓴다는 걸
              // 잊지 않게 얇게 알려 준다.
              if (_restricted)
                Padding(
                  key: const ValueKey('chat-input-read-only-hint'),
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                  child: Row(
                    children: [
                      Icon(
                        _archived
                            ? Icons.inventory_2_outlined
                            : Icons.edit_off_outlined,
                        size: 14,
                        color: hintColor,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _archived
                              ? tr('보관된 토픽 — 토픽 관리자만 글을 쓸 수 있어요')
                              : tr('읽기 전용 토픽 — 토픽 관리자만 글을 쓸 수 있어요'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: hintColor),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_attachments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SizedBox(
                    // 이미지 카드(200x64)와 파일 카드가 들어갈 수 있는 고정 높이 — 업로드
                    // 중이든 끝났든 같은 카드(UploadingAttachment)를 그대로 쓰므로(완료돼도
                    // 다른 위젯으로 안 바뀜) 높이를 상태에 따라 바꿀 필요가 없다. 넘쳐서 안 보이는
                    // 첨부가 있으면 그 아래에 가로 스크롤바(채팅방과 같은 10px, 늘 보임) 자리를 더한다.
                    height: 80 + (_attachmentsOverflow ? 14 : 0),
                    child: NotificationListener<ScrollMetricsNotification>(
                      onNotification: (n) {
                        final overflow = n.metrics.maxScrollExtent > 0;
                        if (overflow != _attachmentsOverflow) {
                          setState(() => _attachmentsOverflow = overflow);
                        }
                        return false;
                      },
                      child: MutedScrollbar(
                        key: const ValueKey('chat-attachments-scrollbar'),
                        controller: _attachmentScroll,
                        child: ListView.builder(
                          key: const ValueKey('chat-attachments'),
                          controller: _attachmentScroll,
                          scrollDirection: Axis.horizontal,
                          padding: EdgeInsets.only(
                            bottom: _attachmentsOverflow ? 14 : 0,
                          ),
                          itemCount: _attachments.length,
                          itemBuilder: (context, i) {
                            final a = _attachments[i];
                            return Padding(
                              padding: const EdgeInsets.only(right: 10, top: 6),
                              child: UploadingAttachment(
                                thumbnailBytes: a.thumbnailBytes,
                                displayName: a.displayName,
                                totalBytes: a.totalBytes,
                                sentBytes: a.sentBytes,
                                completed: a.result != null,
                                onCancel: () => _cancelAttachment(a),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              // 입력칸을 위에 두고, 첨부 아이콘+보내기 버튼은 그 아래 별도 줄에 둔다(첨부
              // 이미지 참고 — 예전엔 입력칸과 같은 줄 왼쪽/오른쪽에 있었다).
              // TextField(EditableText)는 여러 줄일 때 조상 ScrollConfiguration과 무관하게
              // 항상 자체 스크롤바를 강제로 붙인다(TextField에 그 동작을 끌 방법도 없다) —
              // 그래서 따로 Scrollbar를 얹지 않고, 그 자동 스크롤바가 이 테마를 그대로
              // 입도록(채팅방과 같은 두께 10px, 항상 보임) ScrollbarTheme만 씌운다.
              // 서식 도구모음을 펼치면 입력칸 테두리 안쪽 맨 위에 도구모음 줄을 얹는다. 펼치든
              // 접든 TextField는 같은 자리(Column의 마지막)에 두어서 입력 중인 상태·포커스가
              // 그대로 이어지게 한다.
              if (_slashSuggestions case final suggestions
                  when suggestions.isNotEmpty)
                SlashCommandSuggestions(
                  commands: suggestions,
                  onPick: _pickSlashCommand,
                ),
              RichFormatFrame(
                open: _formatOpen,
                focused: _focusNode.hasFocus,
                toolbar: RichFormatToolbar(
                  controller: _controller,
                  focusNode: _focusNode,
                ),
                child: ScrollbarTheme(
                  data: mutedScrollbarThemeData,
                  child: MentionAutocomplete(
                    key: _mentionKey,
                    controller: _controller,
                    focusNode: _focusNode,
                    room: _liveRoom,
                    myUserId: widget.session.userId,
                    resolveUrl: widget.session.resolveUrl,
                    child: RichFieldWrapper(
                      controller: _controller,
                      // 붙여넣기: Ctrl+V는 클립보드의 이미지·표를 보고(_paste), Ctrl+Shift+V는 언제나 글자만(_pasteAsPlainText).
                      child: Shortcuts(
                        shortcuts: const <ShortcutActivator, Intent>{
                          SingleActivator(
                            LogicalKeyboardKey.keyV,
                            control: true,
                            shift: true,
                          ): _PlainPasteIntent(),
                        },
                        child: Actions(
                          actions: <Type, Action<Intent>>{
                            PasteTextIntent: _pasteAction,
                            _PlainPasteIntent:
                                CallbackAction<_PlainPasteIntent>(
                                  onInvoke: (_) {
                                    unawaited(_pasteAsPlainText());
                                    return null;
                                  },
                                ),
                          },
                          child: TextField(
                            key: const ValueKey('chat-input'),
                            controller: _controller,
                            focusNode: _focusNode,
                            decoration: InputDecoration(
                              // 포커스를 얻으면(클릭/터치) 안내 문구 자체를 감춰서 커서만 보이게
                              // 한다(_onFocusChange가 포커스 변화 시 다시 그림).
                              hintText: _focusNode.hasFocus
                                  ? null
                                  : tr('메시지 입력'),
                              border: _formatOpen
                                  ? InputBorder.none
                                  : const OutlineInputBorder(),
                              // 기본 오른쪽 여백(12)이면 스크롤바가 테두리에서 너무 떨어져
                              // 보인다 — 오른쪽만 줄여서 스크롤바를 테두리에 가깝게 붙인다.
                              contentPadding: const EdgeInsets.fromLTRB(
                                12,
                                12,
                                2,
                                12,
                              ),
                            ),
                            minLines: 1,
                            maxLines: 6,
                            // Windows(물리 키보드)에서는 textInputAction이 .send면 Flutter가
                            // Shift 여부와 무관하게 Enter를 전부 "제출"로 처리해버려서(줄바꿈이
                            // 아예 안 먹힘) .newline으로 둬서 기본 동작은 항상 줄바꿈으로 만들고,
                            // 대신 순수 Enter(=Shift 안 눌림)는 _handleKey가 가로채 직접 보낸다.
                            // 모바일은 소프트 키보드의 "전송" 액션 버튼이 주 전송 수단이라 .send를
                            // 그대로 둔다.
                            textInputAction: AppPlatform.isWindows
                                ? TextInputAction.newline
                                : TextInputAction.send,
                            onSubmitted: (_) => _send(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              // 검색/멤버/스레드 패널이 열려 있거나 창이 좁으면 이 줄의 폭이 꽤 좁아진다 — 버튼
              // 개수(캡처·화상회의·문의)와 글꼴에 따라 필요한 폭이 달라서, 예전처럼 고정 폭(320)
              // 기준으로 안내 문구를 두면 360px 안팎에서 넘쳐 보내기 버튼이 밀려났다. 이제 버튼을
              // 다 놓고 남은 자리에 안내 문구가 통째로 들어갈 때만 보인다(_SendKeyHint).
              LayoutBuilder(
                builder: (context, constraints) => Row(
                  children: [
                    TapRegion(
                      groupId: widget.stickerPickerGroupId,
                      child: IconButton(
                        icon: Icon(
                          Icons.emoji_emotions_outlined,
                          color: widget.stickerPickerOpen
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        onPressed: _sending
                            ? null
                            : widget.onToggleStickerPicker,
                        tooltip: tr('이모티콘'),
                      ),
                    ),
                    // 멘션 — 입력칸에 @를 넣어 대화 멤버 자동완성을 연다(비밀 대화는 지원하지 않는다).
                    // 좁아서 자리가 없으면 아래 파일 단추의 메뉴에 "멘션"으로 들어간다.
                    if (_standaloneButtons(constraints.maxWidth).mention)
                      MentionButton(
                        onPressed: _sending
                            ? null
                            : () => _mentionKey.currentState?.insertTrigger(),
                      ),
                    // 멘션·투표를 만들 수 있는 방인데 별도 단추를 놓을 자리가 없으면(좁은 화면) 파일 단추가
                    // 같은 자리의 메뉴(파일 보내기 · 투표 · 멘션)가 된다.
                    if (_needsAttachMenu(constraints.maxWidth))
                      _buildAttachMenu(constraints.maxWidth)
                    else
                      IconButton(
                        icon: const Icon(Icons.attach_file),
                        onPressed: _sending ? null : _pickFile,
                        tooltip: tr('파일 보내기'),
                      ),
                    // 투표 만들기 — 비밀 대화에서는 서버가 막으니 단추 자체를 숨긴다.
                    if (_standaloneButtons(constraints.maxWidth).poll)
                      IconButton(
                        key: const ValueKey('chat-poll'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.poll_outlined),
                        onPressed: _sending ? null : _openPollCreator,
                        tooltip: tr('투표'),
                      ),
                    if (!widget.room.isSecret)
                      RichFormatToggleButton(
                        open: _formatOpen,
                        onPressed: () {
                          setState(() => _formatOpen = !_formatOpen);
                          _focusNode.requestFocus();
                        },
                      ),
                    // 화면 캡처는 Windows 전용 — 누르면 메신저 창을 숨기고 찍을지 포함해서
                    // 찍을지 먼저 고른다.
                    if (AppPlatform.isWindows)
                      PopupMenuButton<bool>(
                        icon: const Icon(Icons.filter_center_focus),
                        tooltip: tr('화면 캡처'),
                        enabled: !_sending && !_capturing,
                        onSelected: _startCapture,
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: true,
                            child: Text(tr('메신저 창 숨기고 캡처')),
                          ),
                          PopupMenuItem(
                            value: false,
                            child: Text(tr('메신저 창 포함하여 캡처')),
                          ),
                        ],
                      ),
                    if (_showCallButton)
                      CallButton(session: widget.session, room: widget.room),
                    // 이 DM 상대가 내 팀의 "팀장"일 때만 보인다(session.canSendInquiryIn).
                    if (widget.session.canSendInquiryIn(widget.room))
                      IconButton(
                        icon: const Icon(Icons.contact_support_outlined),
                        onPressed: _sending ? null : _showInquiryDialog,
                        tooltip: tr('팀장에게 문의하기'),
                      ),
                    // 줄바꿈/전송 키 안내는 PC(물리 키보드)에서만.
                    Expanded(
                      child: AppPlatform.isWindows
                          ? _SendKeyHint(
                              widget.session.settings.sendWithShiftEnter
                                  ? tr('Shift + Enter 로 전송')
                                  : tr('Shift + Enter 로 줄바꿈'),
                            )
                          : const SizedBox.shrink(),
                    ),
                    // 메시지 예약 — 보내기 바로 옆에 둔다(비밀 대화는 서버가 예약을 받지 않는다).
                    if (canScheduleIn(widget.session, _liveRoom))
                      IconButton(
                        key: const ValueKey('chat-schedule'),
                        icon: const Icon(Icons.schedule_send_outlined),
                        onPressed: _sending || uploading
                            ? null
                            : _openScheduleEditor,
                        tooltip: uploading
                            ? tr('업로드가 끝나면 예약할 수 있어요')
                            : tr('메시지 예약'),
                      ),
                    if (_sending)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.send),
                        onPressed: uploading ? null : _send,
                        tooltip: uploading
                            ? tr('업로드가 끝나면 보낼 수 있어요')
                            : tr('보내기'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 입력칸 아래 줄의 "Shift + Enter 로 …" 안내 — 버튼들을 다 놓고 남은 폭([Expanded])에 글자가
/// 통째로 들어갈 때만 보내기 버튼 바로 왼쪽에 붙이고, 모자라면 아예 숨긴다(잘린 안내는 쓸모가 없고,
/// 억지로 두면 줄이 넘쳐 보내기 버튼이 밀려난다).
class _SendKeyHint extends StatelessWidget {
  final String text;
  const _SendKeyHint(this.text);

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(
      context,
    ).style.merge(TextStyle(fontSize: 11, color: Theme.of(context).hintColor));
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.maybeLocaleOf(context),
          maxLines: 1,
        )..layout();
        final width = painter.width;
        painter.dispose();
        const gap = 8.0; // 보내기 버튼과의 간격
        if (width + gap > constraints.maxWidth) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: gap),
            child: Text(text, style: style, maxLines: 1, softWrap: false),
          ),
        );
      },
    );
  }
}

/// Ctrl+Shift+V — 표·서식 변환 없이 글자만 붙여넣는다(입력칸의 Shortcuts가 이 의도를 낸다).
class _PlainPasteIntent extends Intent {
  const _PlainPasteIntent();
}

/// 입력칸의 붙여넣기(PasteTextIntent)를 덮어쓰는 동작 — 기본 붙여넣기(글자)를 [callingAction]으로 넘겨받아 두었다가,
/// 클립보드를 읽어 본 결과 글자로 붙일 때만 부른다([ChatInputBarState._paste]). Action.invoke는 이 클래스 안에서만 부를 수 있어
/// 여기서 감싸 넘긴다.
class _ChatPasteAction extends Action<PasteTextIntent> {
  final ChatInputBarState _owner;
  _ChatPasteAction(this._owner);

  @override
  Object? invoke(PasteTextIntent intent) {
    final fallback = callingAction;
    unawaited(_owner._paste(() => fallback?.invoke(intent)));
    return null;
  }
}
