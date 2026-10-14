import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import '../models/mention.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../services/api_client.dart'
    show ApiException, UploadCancelToken, UploadCancelledException;
import '../services/app_platform.dart';
import '../services/file_type_utils.dart';
import '../services/memory_file.dart';
import '../services/mention_logic.dart';
import '../services/room_chat_controller.dart' show UploadedAttachment;
import '../services/session.dart';
import '../services/time_format.dart';
import '../services/typing_gate.dart';
import '../widgets/app_toast.dart';
import '../widgets/dropped_files.dart';
import '../widgets/attachment_widgets.dart'
    show DropZoneOverlay, formatFileSize;
import '../widgets/floating_dialog.dart';
import '../widgets/mention_autocomplete.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/rich_text_format.dart';
import '../widgets/room_picker_field.dart';
import '../widgets/xfile_image.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'post_editor_dialog.dart' show fileIconFor;
import '../widgets/retrying_network_image.dart';

/// 예약할 수 있는 대화방인지 — 지금 팀의 방이고, 비밀 대화가 아니고, 내가 글을 쓸 수 있어야 한다(읽기
/// 전용·보관된 토픽은 토픽 관리자만). 서버 /scheduled-messages와 같은 규칙 — 대화방 고르기와 입력칸의
/// 예약 단추가 같이 쓴다. 나와의 대화도 여기에 들어간다.
bool canScheduleIn(Session session, Room room) =>
    room.teamId == session.currentTeam?.id &&
    !room.isSecret &&
    room.canWrite(session);

/// 편집기에 미리 붙여 둘 첨부 — 입력칸·게시글 편집기에서 이미 올려 둔 것이라 다시 올리지 않는다.
/// 미리보기는 [thumbnailBytes](입력칸의 축소 그림)나 [file](로컬 원본)로 그린다.
class ScheduleDraftAttachment {
  final UploadedAttachment uploaded;
  final Uint8List? thumbnailBytes;
  final XFile? file;
  const ScheduleDraftAttachment(
    this.uploaded, {
    this.thumbnailBytes,
    this.file,
  });
}

/// "메시지 예약 생성"([editing]이 없을 때)·"예약 메시지 수정" 창을 연다 — 넓은 창(PC)은 대화상자, 좁은
/// 창(모바일)은 전체 화면. [room]·[title]·[text]·[attachments]는 처음 채워 둘 값(입력칸의 쓰던 글,
/// 게시글 편집기의 제목·본문 등). 예약(수정은 저장)했으면 서버가 돌려준 예약을 돌려주고 짧게 알린다.
Future<ScheduledMessage?> showScheduleMessageEditor(
  BuildContext context,
  Session session, {
  Room? room,
  String? title,
  String text = '',
  List<TextFormatRun>? textFormat,
  List<Mention>? mentions,
  List<ScheduleDraftAttachment> attachments = const [],
  ScheduledMessage? editing,
}) async {
  final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  final editor = ScheduleMessageEditor(
    session: session,
    room: room,
    title: title,
    text: text,
    textFormat: textFormat,
    mentions: mentions,
    attachments: attachments,
    editing: editing,
    asDialog: wide,
  );
  final saved = wide
      ? await showDialog<ScheduledMessage>(
          context: context,
          // 바깥을 잘못 눌러 쓰던 글이 날아가지 않게 — 닫기는 취소·Esc(내용이 있으면 확인 후)로만.
          barrierDismissible: false,
          builder: (_) => editor,
        )
      : await Navigator.of(context).push<ScheduledMessage>(
          MaterialPageRoute(fullscreenDialog: true, builder: (_) => editor),
        );
  if (saved != null && context.mounted) {
    final when = formatScheduleTime(saved.sendAt);
    showAppToast(
      context,
      editing == null ? '메시지를 예약했습니다 · $when' : '예약 메시지를 수정했습니다 · $when',
    );
  }
  return saved;
}

/// 편집기의 첨부 하나 — 새로 고른 파일은 붙이자마자 차례로 올리고(게시글 편집기와 같은 방식), 이미
/// 올라간 것(입력칸에서 넘어온 것·수정할 예약의 첨부)은 [result]가 처음부터 있다.
class _Item {
  _Item.local(
    XFile this.file, {
    required this.name,
    required this.size,
    required this.isImage,
  });

  _Item.ready(
    UploadedAttachment uploaded, {
    this.file,
    this.thumbBytes,
    this.networkThumb,
  }) : name = uploaded.fileName,
       size = uploaded.size,
       isImage = uploaded.isImage,
       result = uploaded;

  final XFile? file;
  final String name;

  /// 새로 고른 파일은 처음엔 0 — 붙인 직후 파일 크기를 읽어 채운다(XFile.length()가 비동기라).
  int size;
  final bool isImage;
  Uint8List? thumbBytes;

  /// 수정할 예약에 이미 붙어 있던 사진의 미리보기 주소(서버가 서명한 것).
  String? networkThumb;

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

// ───────────────────── 발송 시간 계산 ─────────────────────

DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

/// [now]보다 늦은(같은 시각 제외) 가장 이른 15분 단위 — 고를 수 있는 가장 이른 발송 시간.
DateTime _firstSlotAfter(DateTime now) {
  final slot = ceilToScheduleSlot(now);
  return slot.isAfter(now)
      ? slot
      : slot.add(const Duration(minutes: scheduledSlotMinutes));
}

/// 고를 수 있는 가장 늦은 시각 — 지금부터 [maxDays]일 뒤(기본 90일, 예약 메시지·투표 마감).
DateTime _latestAllowed(DateTime now, int maxDays) =>
    maxDays == scheduledMaxDaysAhead
    ? latestScheduleTime(now)
    : now.add(Duration(days: maxDays));

/// 고를 수 있는 가장 늦은 15분 단위(지금부터 [maxDays]일(기본 90일) 뒤와 같거나 이른).
DateTime _lastSlot(DateTime now, [int maxDays = scheduledMaxDaysAhead]) {
  final limit = _latestAllowed(now, maxDays);
  final slot = ceilToScheduleSlot(limit);
  return slot.isAfter(limit)
      ? slot.subtract(const Duration(minutes: scheduledSlotMinutes))
      : slot;
}

bool _slotAllowed(
  DateTime slot,
  DateTime now, [
  int maxDays = scheduledMaxDaysAhead,
]) => slot.isAfter(now) && !slot.isAfter(_latestAllowed(now, maxDays));

/// [value]의 시각은 그대로 두고 날짜만 [day]로 옮긴다 — 그날 고를 수 없는 시각(지난 시각·[maxDays]일 넘음)이면
/// 가장 가까운 고를 수 있는 시각으로 옮긴다(오늘이면 기본 시각, 아니면 첫/마지막 15분 단위).
DateTime _valueOnDay(
  DateTime value,
  DateTime day, [
  int maxDays = scheduledMaxDaysAhead,
]) {
  final now = DateTime.now();
  var next = DateTime(day.year, day.month, day.day, value.hour, value.minute);
  if (!next.isAfter(now)) {
    final preferred = defaultScheduleTime(now);
    next = _dayOf(preferred) == _dayOf(next) ? preferred : _firstSlotAfter(now);
  } else if (next.isAfter(_latestAllowed(now, maxDays))) {
    next = _lastSlot(now, maxDays);
  }
  return next;
}

/// "3시간 15분 뒤" — 발송 시간 아래 안내(분 단위는 올림).
String _untilText(DateTime sendAt, DateTime now) {
  final total = math.max(1, (sendAt.difference(now).inSeconds / 60).ceil());
  if (total < 60) return '$total분 뒤';
  final days = total ~/ (24 * 60);
  final hours = total % (24 * 60) ~/ 60;
  final minutes = total % 60;
  if (days > 0) return hours > 0 ? '$days일 $hours시간 뒤' : '$days일 뒤';
  return minutes > 0 ? '$hours시간 $minutes분 뒤' : '$hours시간 뒤';
}

/// 빠른 선택 — 이름과 그 시각(지금 기준).
List<(String, DateTime)> _quickTimes(DateTime now) => [
  ('1시간 뒤', ceilToScheduleSlot(now.add(const Duration(hours: 1)))),
  ('내일 오전 9:00', DateTime(now.year, now.month, now.day + 1, 9)),
  // 다가오는 월요일(오늘이 월요일이면 다음 주) — 일요일이면 내일이다.
  (
    '다음 주 월요일 오전 9:00',
    DateTime(now.year, now.month, now.day + (8 - now.weekday), 9),
  ),
];

/// 예약 메시지 작성·수정 화면(대화상자/전체 화면 공용) — 대화방, 제목(보드 뷰 토픽만), 메시지(서식 가능),
/// 파일 첨부(10개까지, 고르면 바로 올라간다), 발송 시간(날짜·15분 단위 시각을 한 칸에서·빠른 선택). 칸마다 서버와
/// 같은 규칙으로 바로 알려 주고, Ctrl+Enter로 예약, Esc로 닫는다(쓰던 게 있으면 묻는다).
class ScheduleMessageEditor extends StatefulWidget {
  final Session session;

  /// 처음 골라 둘 대화방(수정이면 무시하고 예약의 대화방).
  final Room? room;
  final String? title;
  final String text;
  final List<TextFormatRun>? textFormat;
  final List<Mention>? mentions;
  final List<ScheduleDraftAttachment> attachments;

  /// 고칠 예약(없으면 새로 만든다).
  final ScheduledMessage? editing;

  /// 대화상자(PC)로 그릴지, 전체 화면(모바일)으로 그릴지.
  final bool asDialog;

  const ScheduleMessageEditor({
    super.key,
    required this.session,
    this.room,
    this.title,
    this.text = '',
    this.textFormat,
    this.mentions,
    this.attachments = const [],
    this.editing,
    this.asDialog = true,
  });

  @override
  State<ScheduleMessageEditor> createState() => ScheduleMessageEditorState();
}

/// 끌어다 놓기처럼 바깥에서 파일을 더할 수 있게(테스트·캡처 포함) 공개해 둔다.
class ScheduleMessageEditorState extends State<ScheduleMessageEditor> {
  late final TextEditingController _title;
  final _titleFocus = FocusNode(debugLabel: 'schedule-title');
  final _message = RichTextEditingController()..mentionsEnabled = true;
  final _messageFocus = FocusNode(debugLabel: 'schedule-message');
  final _mentionKey = GlobalKey<MentionAutocompleteState>();
  final _scroll = ScrollController();
  final _sendAtField = GlobalKey<_ScheduleDateTimeFieldState>();
  final _items = <_Item>[];

  /// 처음 채워진 값 — 닫을 때 "고친 게 있는지", 수정할 때 "무엇이 바뀌었는지"를 가린다.
  late final String _initialTitle;
  late final String _initialText;
  late final List<_Item> _initialItems;

  Room? _room;
  late DateTime _sendAt;
  bool _formatOpen = false;
  bool _submitting = false;
  bool _dragHovering = false;

  String? _roomError;
  String? _titleError;
  String? _messageError;
  String? _filesError;
  String? _timeError;

  /// 입력칸은 커서만 옮겨도 알림이 오므로, 글자가 실제로 바뀔 때만 칸 아래 오류를 지운다.
  String _lastTitle = '';
  String _lastMessage = '';

  /// 업로드 줄이 도는 동안만 있다 — 예약할 때 이게 끝나기를 기다린다.
  Completer<void>? _uploadsIdle;
  _Item? _uploading;

  /// "3시간 뒤" 같은 안내와 고를 수 있는 시각이 멈춰 보이지 않게 30초마다 다시 그린다.
  Timer? _clock;

  ScheduledMessage? get _editing => widget.editing;

  /// 첨부가 아직 올라가는 중인지 — 테스트·도움말 캡처가 업로드가 끝나기를 기다릴 때 쓴다.
  bool get debugUploading => _uploadsIdle != null;

  @override
  void initState() {
    super.initState();
    final editing = _editing;
    final session = widget.session;
    if (editing != null) {
      final roomId = editing.roomId;
      _room = roomId == null ? null : session.roomById(roomId);
      _initialTitle = editing.title ?? '';
      _message.load(
        editing.text,
        editing.textFormat,
        mentions: editing.mentions,
      );
      for (final a in editing.attachments) {
        _items.add(
          _Item.ready(
            UploadedAttachment.fromMessageAttachment(a),
            networkThumb: a.isImage
                ? session.resolveUrl(a.thumbnailUrl ?? a.fileUrl)
                : null,
          ),
        );
      }
      // 발송 실패로 시각이 지났으면(대개 그렇다) 새 기본 시각에서 다시 고르게 한다.
      _sendAt = validateScheduledSendAt(editing.sendAt) == null
          ? editing.sendAt
          : defaultScheduleTime();
      // 그 방에 이제는 쓸 수 없으면(보관·읽기 전용 등) 저장을 누르기 전에 이유부터 보여 다른 방을 고르게 한다.
      final room = _room;
      if (room != null) _roomError = _roomProblem(room);
    } else {
      _room = widget.room;
      _initialTitle = widget.title ?? '';
      _message.load(widget.text, widget.textFormat, mentions: widget.mentions);
      for (final a in widget.attachments) {
        _items.add(
          _Item.ready(a.uploaded, file: a.file, thumbBytes: a.thumbnailBytes),
        );
      }
      _sendAt = defaultScheduleTime();
    }
    _title = TextEditingController(text: _initialTitle);
    _initialText = _message.text;
    _initialItems = List.of(_items);
    _lastTitle = _title.text;
    _lastMessage = _message.text;
    _title.addListener(_onTitleChanged);
    _message.addListener(_onMessageChanged);
    _messageFocus.addListener(_onFocusChanged);
    _sessionView = _readSessionView();
    session.addListener(_onSessionChanged);
    HardwareKeyboard.instance.addHandler(_handleKey);
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _clock?.cancel();
    _dropUploads();
    _title.dispose();
    _titleFocus.dispose();
    _message.dispose();
    _messageFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 올리는 중인 첨부를 멈추고 결과를 버린다(닫을 때).
  void _dropUploads() {
    for (final i in _items) {
      i.removed = true;
      if (i.pending) i.token.cancel();
    }
  }

  /// 세션이 바뀌어도 이 화면에 보이는 것(예약 한도, 고른 방이 아직 있는지·쓸 수 있는지)이 그대로면 다시
  /// 그리지 않는다 — 접속 상태·읽음 같은 잦은 알림마다 편집기 전체를 다시 그리지 않게.
  late Object _sessionView;

  Object _readSessionView() {
    final room = _room;
    final listed = room == null ? null : widget.session.roomById(room.id);
    return (_atLimit, listed != null, listed?.canWrite(widget.session));
  }

  /// 다른 기기에서 예약을 지웠거나(한도) 방에서 나갔을 때 등.
  void _onSessionChanged() {
    if (!mounted) return;
    final view = _readSessionView();
    if (view == _sessionView) return;
    setState(() {
      _sessionView = view;
      // 고른 방에 쓸 수 있는지가 바뀌었으면(보관·읽기 전용이 풀리거나 걸림, 방에서 나감) 칸 아래 안내도 맞춘다.
      final room = _room;
      if (room != null) _roomError = _roomProblem(room);
    });
  }

  /// 한글처럼 IME로 조합하는 동안에는 앱 전체를 다시 그리는 알림을 잠깐 미룬다(채팅 입력칸과 같다 —
  /// typing_gate.dart). 이 창 뒤의 채팅 화면도 같은 알림으로 다시 그려진다.
  void _gateTyping(TextEditingValue value) {
    final composing = value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      TypingGate.instance.composing();
    } else {
      TypingGate.instance.committed();
    }
  }

  void _onTitleChanged() {
    _gateTyping(_title.value);
    if (_title.text == _lastTitle) return;
    _lastTitle = _title.text;
    if (_titleError != null) setState(() => _titleError = null);
  }

  void _onMessageChanged() {
    _gateTyping(_message.value);
    if (_message.text == _lastMessage) return;
    _lastMessage = _message.text;
    if (_messageError != null) setState(() => _messageError = null);
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  /// Ctrl+V — 글자 붙여넣기는 그대로 두고, 클립보드에 그림이 있으면 첨부로도 붙인다(입력칸과 같다).
  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        HardwareKeyboard.instance.isControlPressed &&
        (_messageFocus.hasFocus || _titleFocus.hasFocus)) {
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

  bool get _isBoard => _room?.isBoard ?? false;

  /// 새 예약인데 이미 30건이면 만들 수 없다(서버와 같은 한도) — 목록을 받아 온 뒤에만 판단한다.
  bool get _atLimit =>
      _editing == null &&
      widget.session.scheduledMessagesLoaded &&
      widget.session.scheduledMessages.length >= scheduledMessageMaxCount;

  /// 고른 방에 예약할 수 없는 이유(서버 문구와 같다) — 괜찮으면 null.
  String? _roomProblem(Room room) {
    final session = widget.session;
    if (session.roomById(room.id) == null) {
      return '이 대화방에 더 이상 참여하고 있지 않습니다. 다른 대화방을 선택하세요.';
    }
    if (room.isSecret) return '비밀 대화에는 예약할 수 없습니다.';
    if (room.teamId != session.currentTeam?.id) {
      return '지금 팀의 대화방만 선택할 수 있습니다.';
    }
    if (!room.canWrite(session)) {
      return room.isArchived
          ? '보관된 토픽입니다. 토픽 관리자만 글을 쓸 수 있습니다.'
          : '읽기 전용 토픽입니다. 토픽 관리자만 글을 쓸 수 있습니다.';
    }
    return null;
  }

  /// 파일을 첨부 목록에 더하고 바로 올리기 시작한다(파일 첨부 버튼·끌어다 놓기·붙여넣기). 10개를
  /// 넘는 만큼은 빼고 알린다.
  void addFiles(List<XFile> files) {
    if (files.isEmpty || !mounted || _submitting) return;
    final room = scheduledAttachmentMaxCount - _items.length;
    final accepted = files.take(math.max(0, room)).toList();
    if (accepted.length < files.length) {
      showAppToast(context, scheduledAttachmentLimitMessage);
    }
    if (accepted.isEmpty) return;
    final added = [
      for (final f in accepted)
        _Item.local(
          f,
          name: f.name,
          size: 0,
          isImage: looksLikeImagePath(f.name),
        ),
    ];
    setState(() {
      _items.addAll(added);
      _filesError = validateScheduledAttachmentCount(_items.length);
    });
    for (final item in added) {
      unawaited(
        item.file!.length().then((n) {
          if (mounted) setState(() => item.size = n);
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

  /// 붙인 파일을 하나씩 차례로 올린다 — 방과 무관한 업로드(session.uploadAttachments)라 대화방을 나중에
  /// 바꿔도 그대로 쓴다.
  Future<void> _pumpUploads() async {
    if (_uploadsIdle != null) return; // 이미 도는 중이면 새 파일도 그 줄이 이어서 올린다.
    final idle = _uploadsIdle = Completer<void>();
    try {
      while (mounted) {
        final next = _items
            .where((i) => i.pending && !i.removed && i.file != null)
            .firstOrNull;
        if (next == null) break;
        final token = next.token;
        setState(() => _uploading = next);
        try {
          final uploaded = await widget.session.uploadAttachments(
            [next.file!],
            cancelToken: token,
            onProgress: (_, sent, total) {
              if (!mounted || next.removed) return;
              setState(() {
                next.sent = sent;
                next.total = total;
              });
            },
          );
          if (!mounted || next.removed || token != next.token) continue;
          setState(() => next.result = uploaded.single);
        } on UploadCancelledException {
          continue; // 뺀 첨부 — 이미 목록에서 없어졌다.
        } catch (e) {
          if (!mounted || next.removed || token != next.token) continue;
          setState(() => next.error = '$e');
          showAppToast(context, "'${next.name}' 파일을 올리지 못했습니다: $e");
        }
      }
    } finally {
      _uploadsIdle = null;
      if (mounted) setState(() => _uploading = null);
      idle.complete();
    }
  }

  void _remove(_Item item) {
    item.removed = true;
    if (item.pending) item.token.cancel();
    setState(() {
      _items.remove(item);
      if (_filesError != null) {
        _filesError = validateScheduledAttachmentCount(_items.length);
      }
    });
  }

  void _retry(_Item item) {
    setState(() {
      item.error = null;
      item.sent = 0;
      item.total = 0;
      item.token = UploadCancelToken();
    });
    unawaited(_pumpUploads());
  }

  bool get _hasFailedUpload => _items.any((i) => i.error != null);

  void _onRoomChanged(Room room) {
    setState(() {
      _room = room;
      _roomError = _roomProblem(room);
      _sessionView = _readSessionView();
      if (!room.isBoard) _titleError = null;
    });
  }

  void _setSendAt(DateTime value) {
    setState(() {
      _sendAt = value;
      _timeError = null;
    });
  }

  /// 서버와 같은 규칙으로 먼저 걸러 칸 아래에 바로 알린다. 첫 번째로 걸린 칸으로 커서를 옮긴다.
  bool _validate() {
    final room = _room;
    final roomError = room == null ? '대화방을 선택하세요.' : _roomProblem(room);
    final titleError = room != null && room.isBoard
        ? validateScheduledTitle(_title.text, isBoard: true)
        : null;
    final messageError = validateScheduledText(_message.text);
    final filesError = validateScheduledAttachmentCount(_items.length);
    final timeError = validateScheduledSendAt(_sendAt);
    setState(() {
      _roomError = roomError;
      _titleError = titleError;
      _messageError = messageError;
      _filesError = filesError;
      _timeError = timeError;
    });
    if (titleError != null && roomError == null) {
      _titleFocus.requestFocus();
    } else if (messageError != null && roomError == null) {
      _messageFocus.requestFocus();
    }
    return roomError == null &&
        titleError == null &&
        messageError == null &&
        filesError == null &&
        timeError == null;
  }

  bool _sameText(
    ({String text, List<TextFormatRun>? format}) now,
    List<Mention> nowMentions,
    ScheduledMessage m,
  ) =>
      now.text == m.text &&
      jsonEncode(textFormatToJson(now.format)) ==
          jsonEncode(textFormatToJson(m.textFormat)) &&
      jsonEncode(mentionsToJson(nowMentions)) ==
          jsonEncode(mentionsToJson(m.mentions));

  bool get _attachmentsChanged {
    if (_items.length != _initialItems.length) return true;
    for (var i = 0; i < _items.length; i++) {
      if (!identical(_items[i], _initialItems[i])) return true;
    }
    return false;
  }

  Future<void> _submit() async {
    if (_submitting || _atLimit) return;
    if (!_validate()) return;
    if (_hasFailedUpload) {
      showAppToast(context, '올리지 못한 첨부 파일이 있습니다. 다시 시도하거나 빼 주세요.');
      return;
    }
    setState(() => _submitting = true);
    try {
      // 아직 올라가는 첨부가 있으면 끝날 때까지 기다렸다가 이어서 예약한다.
      while (_uploadsIdle != null) {
        await _uploadsIdle!.future;
      }
      if (!mounted) return;
      if (_hasFailedUpload) {
        showAppToast(context, '올리지 못한 첨부 파일이 있습니다. 다시 시도하거나 빼 주세요.');
        return;
      }
      final room = _room!;
      final body = _message.formatted();
      final mentions = mentionsToSend(_message, room, widget.session.userId);
      final attachments = [for (final i in _items) i.result!];
      final editing = _editing;
      final session = widget.session;
      final ScheduledMessage saved;
      if (editing == null) {
        saved = await session.scheduleMessage(
          roomId: room.id,
          title: room.isBoard ? _title.text : null,
          text: body.text,
          textFormat: body.format,
          mentions: mentions,
          attachments: attachments,
          sendAt: _sendAt,
        );
      } else {
        // 바뀐 칸만 보낸다 — 발송 시간은 서버가 늘 다시 보므로(지난 시각이면 거절) 늘 보낸다.
        final textChanged = !_sameText(body, mentions, editing);
        saved = await session.updateScheduledMessage(
          editing.id,
          roomId: room.id == editing.roomId ? null : room.id,
          title: room.isBoard ? _title.text.trim() : null,
          text: textChanged ? body.text : null,
          textFormat: textChanged ? body.format : null,
          mentions: textChanged ? mentions : null,
          attachments: _attachmentsChanged ? attachments : null,
          sendAt: _sendAt,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(saved);
    } catch (e) {
      // 서버가 거절하면 그 문구 그대로(한도·권한·시간 등) — 창은 열어 둔 채로 고칠 수 있게 한다.
      if (mounted) {
        showAppToast(
          context,
          e is ApiException ? e.message : '예약하지 못했습니다: $e',
          duration: const Duration(seconds: 3),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  bool get _dirty =>
      _title.text.trim() != _initialTitle.trim() ||
      _message.text.trim() != _initialText.trim() ||
      _attachmentsChanged;

  /// 취소·Esc·뒤로 가기 — 발송 시간 판(달력·시간 목록)이 떠 있으면 판만 닫고, 쓰던 내용이 있으면 한 번 묻는다.
  Future<void> _requestClose() async {
    if (_sendAtField.currentState?.hidePopup() ?? false) return;
    if (_submitting) return;
    if (_dirty) {
      final editing = _editing != null;
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(editing ? '수정 취소' : '작성 취소'),
          content: Text(
            editing ? '고친 내용을 저장하지 않고 닫을까요?' : '작성 중인 예약 메시지를 버리고 닫을까요?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('계속 쓰기'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text(
                '닫기',
                style: TextStyle(color: Colors.redAccent),
              ),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    _dropUploads();
    Navigator.of(context).pop();
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
        // 아무 칸도 누르지 않은 채로도 Esc·Ctrl+Enter가 이 창에 닿게 처음 포커스를 창 안에 둔다(이
        // 창은 바깥 누르기로 닫히지 않아서 Esc를 받아 줄 다른 곳이 없다).
        child: Focus(
          autofocus: true,
          child: widget.asDialog ? _buildDialog(context) : _buildPage(context),
        ),
      ),
    );
    if (!AppPlatform.isWindows && !kIsWeb) return editor;
    return DropTarget(
      // 이 창 위에 다른 창(달력·확인 창 등)이 떠 있으면 받지 않는다.
      enable: ModalRoute.isCurrentOf(context) ?? true,
      onDragEntered: (_) => setState(() => _dragHovering = true),
      onDragExited: (_) => setState(() => _dragHovering = false),
      onDragDone: (details) {
        setState(() => _dragHovering = false);
        addFiles(droppedFiles(details));
      },
      child: editor,
    );
  }

  String get _screenTitle => _editing == null ? '메시지 예약 생성' : '예약 메시지 수정';

  Widget _buildDialog(BuildContext context) {
    return FloatingDialog(
      title: _screenTitle,
      maxWidth: 600,
      maxHeight: 860,
      // 스크롤바를 창 오른쪽 모서리에 붙인다 — 오른쪽 여백은 안쪽(입력칸·단추·제목 줄)이 스스로 둔다.
      padding: const EdgeInsets.fromLTRB(20, 20, 0, 20),
      headerEndPadding: 12,
      child: Stack(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: MutedScrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    // 스크롤바(창 끝에 붙은 10px)가 입력칸을 덮지 않게 오른쪽을 비운다.
                    padding: const EdgeInsets.only(right: 20),
                    child: _buildForm(context),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // 단추 끝을 위 입력칸들의 오른쪽 끝(스크롤바 자리를 비운 곳)에 맞춘다.
              Padding(
                padding: const EdgeInsets.only(right: 20),
                child: _buildActions(context),
              ),
            ],
          ),
          if (_dragHovering)
            const Positioned.fill(
              child: IgnorePointer(child: DropZoneOverlay()),
            ),
        ],
      ),
    );
  }

  Widget _buildPage(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '취소',
          onPressed: _requestClose,
        ),
        title: Text(_screenTitle),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: _buildForm(context),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: _buildActions(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final editing = _editing != null;
    final pending = _items.where((i) => i.pending).length;
    final String busyLabel;
    if (pending > 0) {
      busyLabel = '업로드 중 ${_items.length - pending}/${_items.length}';
    } else {
      busyLabel = editing ? '저장 중' : '예약 중';
    }
    return Row(
      children: [
        // 남는 폭을 안내 글자가 다 차지해서 단추들이 늘 오른쪽 끝(입력칸 끝)에 붙는다.
        Expanded(
          child: AppPlatform.isWindows && widget.asDialog
              ? Text(
                  'Ctrl + Enter 로 ${editing ? '저장' : '예약'} · Esc 로 닫기',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: hint),
                )
              : const SizedBox.shrink(),
        ),
        TextButton(
          onPressed: _submitting ? null : _requestClose,
          child: const Text('취소'),
        ),
        const SizedBox(width: 8),
        FilledButton(
          key: const ValueKey('schedule-submit'),
          onPressed: _submitting || _atLimit ? null : _submit,
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
              : Text(editing ? '저장' : '예약'),
        ),
      ],
    );
  }

  Widget _buildForm(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final editing = _editing;
    final session = widget.session;
    // 고칠 예약의 대화방이 사라졌으면(나갔거나 삭제됨) 원래 이름을 알려 주고 다시 고르게 한다.
    final lostRoomName = editing != null && _room == null
        ? session.scheduledRoomName(editing)
        : null;
    // 창을 열어 둔 사이 고른 시각이 지나 버렸으면 예약을 누르기 전에도 바로 알린다.
    final now = DateTime.now();
    final timeProblem =
        _timeError ??
        (_sendAt.isAfter(now)
            ? null
            : validateScheduledSendAt(_sendAt, now: now));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_atLimit) ...[
          const _Notice(
            key: ValueKey('schedule-limit'),
            text:
                '예약 메시지는 최대 $scheduledMessageMaxCount건까지 만들 수 있습니다. '
                '목록에서 필요 없는 예약을 취소한 뒤 다시 만들어 주세요.',
          ),
          const SizedBox(height: 14),
        ],
        const _Label('대화방'),
        RoomPickerField(
          key: const ValueKey('schedule-room'),
          session: session,
          value: _room,
          filter: (r) => canScheduleIn(session, r),
          onChanged: _onRoomChanged,
        ),
        if (lostRoomName != null && _roomError == null)
          _FieldHint("원래 대화방 '$lostRoomName'에는 보낼 수 없습니다. 다른 대화방을 선택하세요."),
        if (_roomError != null) _FieldError(_roomError!),
        const SizedBox(height: 16),
        if (_isBoard) ...[
          const _Label('제목', note: '보드 뷰 토픽에는 게시글로 올라갑니다'),
          TextField(
            key: const ValueKey('schedule-title'),
            controller: _title,
            focusNode: _titleFocus,
            enabled: !_submitting,
            maxLength: scheduledTitleMaxLength,
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _messageFocus.requestFocus(),
            decoration: InputDecoration(
              hintText: '게시글 제목을 입력하세요',
              border: const OutlineInputBorder(),
              isDense: true,
              errorText: _titleError,
            ),
          ),
          const SizedBox(height: 6),
        ],
        _Label(
          '메시지',
          trailing: SizedBox(
            height: 28,
            child: Theme(
              data: theme.copyWith(visualDensity: VisualDensity.compact),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_room != null && roomAllowsMention(_room!))
                    MentionButton(
                      onPressed: _submitting
                          ? null
                          : () => _mentionKey.currentState?.insertTrigger(),
                    ),
                  RichFormatToggleButton(
                    open: _formatOpen,
                    onPressed: () {
                      setState(() => _formatOpen = !_formatOpen);
                      _messageFocus.requestFocus();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
        _buildMessageField(context),
        _buildMessageFooter(context),
        const SizedBox(height: 14),
        _buildAttachments(context),
        const SizedBox(height: 18),
        const _Label('발송 시간'),
        _buildTimePicker(context),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: timeProblem != null
              ? _FieldError(timeProblem, padded: false)
              : Text(
                  '${_untilText(_sendAt, now)}에 보냅니다 · '
                  '15분 단위로 최대 $scheduledMaxDaysAhead일 뒤까지 예약할 수 있어요.',
                  key: const ValueKey('schedule-time-hint'),
                  style: TextStyle(fontSize: 12, color: hint),
                ),
        ),
      ],
    );
  }

  Widget _buildMessageField(BuildContext context) {
    final theme = Theme.of(context);
    final error = _messageError != null;
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
      borderSide: BorderSide(color: color, width: width),
    );
    final room = _room;
    Widget mentionWrap(Widget field) => room == null
        ? field
        : MentionAutocomplete(
            key: _mentionKey,
            controller: _message,
            focusNode: _messageFocus,
            room: room,
            myUserId: widget.session.userId,
            resolveUrl: widget.session.resolveUrl,
            child: field,
          );
    return RichFormatFrame(
      open: _formatOpen,
      focused: _messageFocus.hasFocus,
      toolbar: RichFormatToolbar(
        controller: _message,
        focusNode: _messageFocus,
      ),
      child: mentionWrap(
        RichFieldWrapper(
          controller: _message,
          child: TextField(
            key: const ValueKey('schedule-message'),
            controller: _message,
            focusNode: _messageFocus,
            enabled: !_submitting,
            minLines: 4,
            maxLines: 10,
            keyboardType: TextInputType.multiline,
            textAlignVertical: TextAlignVertical.top,
            decoration: InputDecoration(
              hintText: _isBoard ? '게시글 내용을 입력하세요' : '보낼 메시지를 입력하세요',
              isDense: true,
              contentPadding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
              border: _formatOpen
                  ? InputBorder.none
                  : const OutlineInputBorder(),
              enabledBorder: _formatOpen
                  ? InputBorder.none
                  : error
                  ? border(theme.colorScheme.error, 1)
                  : null,
              focusedBorder: _formatOpen
                  ? InputBorder.none
                  : error
                  ? border(theme.colorScheme.error, 2)
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  /// 메시지 아래 줄 — 왼쪽은 입력 오류, 오른쪽은 글자 수(서버처럼 앞뒤 공백을 뺀 글자 단위).
  Widget _buildMessageFooter(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _message,
      builder: (context, value, _) {
        final length = postTextLength(value.text.trim());
        final over = length > scheduledTextMaxLength;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  _messageError ?? '',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
              Text(
                '$length/$scheduledTextMaxLength',
                key: const ValueKey('schedule-message-counter'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: over ? FontWeight.w700 : FontWeight.normal,
                  color: over ? theme.colorScheme.error : theme.hintColor,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAttachments(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final full = _items.length >= scheduledAttachmentMaxCount;
    final over = _items.length > scheduledAttachmentMaxCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text(
              '파일 첨부',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(width: 6),
            Text(
              '${_items.length}/$scheduledAttachmentMaxCount',
              key: const ValueKey('schedule-files-counter'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: over ? FontWeight.w700 : FontWeight.normal,
                color: over ? theme.colorScheme.error : hint,
              ),
            ),
            const Spacer(),
            OutlinedButton.icon(
              key: const ValueKey('schedule-attach'),
              onPressed: _submitting || full ? null : _pickFiles,
              icon: const Icon(Icons.attach_file, size: 18),
              label: const Text('파일 첨부'),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
        if (_items.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              AppPlatform.isWindows
                  ? '파일을 이 창에 끌어다 놓거나 붙여넣어도 첨부됩니다. 고르면 바로 올라가요.'
                  : '파일은 $scheduledAttachmentMaxCount개까지 첨부할 수 있어요. 고르면 바로 올라가요.',
              style: TextStyle(fontSize: 12, color: hint),
            ),
          )
        else ...[
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: SingleChildScrollView(
              // 지우기(x) 단추가 모서리 밖으로 조금 나와 있어서 그만큼 비워 둔다.
              padding: const EdgeInsets.only(top: 6, right: 6),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final item in _items)
                    _AttachmentTile(
                      key: ObjectKey(item),
                      item: item,
                      uploading: identical(_uploading, item),
                      onRemove: _submitting ? null : () => _remove(item),
                      onRetry: () => _retry(item),
                    ),
                ],
              ),
            ),
          ),
        ],
        if (_filesError != null) _FieldError(_filesError!),
      ],
    );
  }

  Widget _buildTimePicker(BuildContext context) {
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 날짜와 시각을 한 칸에서 — 누르면 달력과 그 밑 시간 드롭다운이 펼쳐진다(투표 마감 시각과 같다).
        ScheduleDateTimeField(
          key: _sendAtField,
          value: _sendAt,
          enabled: !_submitting,
          onChanged: _setSendAt,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (label, at) in _quickTimes(now))
              ChoiceChip(
                label: Text(label),
                selected: _sendAt == at,
                visualDensity: VisualDensity.compact,
                onSelected: _submitting || !_slotAllowed(at, now)
                    ? null
                    : (_) => _setSendAt(at),
              ),
          ],
        ),
      ],
    );
  }
}

/// 굵은 항목 이름 — 오른쪽에 짧은 설명([note])이나 단추([trailing])를 붙일 수 있다.
class _Label extends StatelessWidget {
  final String text;
  final String? note;
  final Widget? trailing;
  const _Label(this.text, {this.note, this.trailing});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            text,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          if (note != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                note!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: hint),
              ),
            ),
          ],
          if (trailing != null) ...[const Spacer(), trailing!],
        ],
      ),
    );
  }
}

/// 칸 아래의 빨간 오류 글자.
class _FieldError extends StatelessWidget {
  final String text;
  final bool padded;
  const _FieldError(this.text, {this.padded = true});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padded
          ? const EdgeInsets.fromLTRB(16, 6, 16, 0)
          : EdgeInsets.zero,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }
}

/// 칸 아래의 회색 안내 글자.
class _FieldHint extends StatelessWidget {
  final String text;
  const _FieldHint(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
      ),
    );
  }
}

/// 맨 위의 경고 띠(예약 한도에 닿았을 때).
class _Notice extends StatelessWidget {
  final String text;
  const _Notice({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// 입력칸처럼 테두리를 두른 상자 — 날짜·시각 칸이 같은 높이·모양으로 나란히 서게 한다(InputDecorator로
/// 감싸면 안의 드롭다운 높이 때문에 두 칸 높이가 어긋났다).
class _PickerBox extends StatelessWidget {
  final IconData icon;
  final bool active;
  final bool enabled;
  final Widget child;

  /// 상자 높이와 왼쪽 아이콘 크기 — 기본은 입력칸과 같은 48/18, 달력 밑 시간 칸처럼 작게 쓸 때만 바꾼다.
  final double height;
  final double iconSize;
  const _PickerBox({
    required this.icon,
    required this.active,
    required this.enabled,
    required this.child,
    this.height = 48,
    this.iconSize = 18,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = !enabled
        ? theme.disabledColor
        : active
        ? scheme.primary
        : scheme.outline;
    // 강조 테두리(2px)가 되어도 안의 글자가 움직이지 않게 그만큼 안쪽 여백을 줄인다.
    final width = active ? 2.0 : 1.0;
    return Container(
      height: height,
      padding: EdgeInsets.only(left: 13 - width, right: 7 - width),
      decoration: BoxDecoration(
        border: Border.all(color: color, width: width),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Icon(icon, size: iconSize, color: enabled ? theme.hintColor : color),
          const SizedBox(width: 10),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 날짜 칸 — 누르면 바로 아래(자리가 모자라면 위)에 달력이 펼쳐진다. 오늘부터 90일 뒤까지만 고를 수 있다.
class _DateField extends StatefulWidget {
  final DateTime value;
  final DateTime first;
  final DateTime last;
  final bool enabled;
  final ValueChanged<DateTime> onPicked;
  const _DateField({
    required this.value,
    required this.first,
    required this.last,
    required this.enabled,
    required this.onPicked,
  });

  @override
  State<_DateField> createState() => _DateFieldState();
}

class _DateFieldState extends State<_DateField> with WidgetsBindingObserver {
  final _overlay = OverlayPortalController();

  /// 달력을 열 때 포커스를 이 칸으로 옮긴다 — 메시지를 쓰던 중이면 휴대폰 화상 키보드가 내려가서
  /// 칸 아래로 펼친 달력을 가리지 않는다.
  final _focus = FocusNode(debugLabel: 'schedule-date');

  /// 달력과 그걸 여는 칸을 한 묶음으로 본다 — 안 그러면 열린 채로 칸을 다시 눌렀을 때 "바깥을
  /// 눌렀다"로 먼저 닫히고 이어서 다시 열려 버린다.
  final _tapGroup = UniqueKey();
  bool _above = false;
  double _dx = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focus.dispose();
    super.dispose();
  }

  /// 화상 키보드가 내려가거나 창 크기가 바뀌면 폼이 다시 자리를 잡으며 칸이 움직일 수 있다 — 그
  /// 프레임이 그려진 뒤 떠 있는 달력의 위·아래 자리를 다시 정한다.
  @override
  void didChangeMetrics() {
    if (!_overlay.isShowing) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _overlay.isShowing) setState(_place);
    });
  }

  /// 떠 있던 달력을 닫았으면 true.
  bool hideCalendar() {
    if (!_overlay.isShowing) return false;
    _overlay.hide();
    if (mounted) setState(() {});
    return true;
  }

  /// 화면 아래·오른쪽 끝을 넘지 않게 — 아래 자리가 모자라면 칸 위로 띄운다.
  void _place() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.sizeOf(context);
    final below = screen.height - origin.dy - box.size.height;
    _above = below < _calendarHeight + 16 && origin.dy > below;
    final maxLeft = math.max(8.0, screen.width - _calendarWidth - 8);
    _dx = origin.dx.clamp(8.0, maxLeft) - origin.dx;
  }

  void _toggle() {
    if (hideCalendar()) return;
    _focus.requestFocus();
    setState(_place);
    _overlay.show();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _overlay,
      overlayChildBuilder: (context, info) => _FieldPopupPosition(
        info: info,
        above: _above,
        dx: _dx,
        child: Align(
          alignment: _above ? Alignment.bottomLeft : Alignment.topLeft,
          child: TapRegion(
            groupId: _tapGroup,
            onTapOutside: (_) => hideCalendar(),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              color: theme.colorScheme.surfaceContainerHigh,
              child: _ScheduleCalendar(
                value: widget.value,
                first: widget.first,
                last: widget.last,
                onPicked: (day) {
                  hideCalendar();
                  widget.onPicked(day);
                },
              ),
            ),
          ),
        ),
      ),
      child: TapRegion(
        groupId: _tapGroup,
        child: InkWell(
          key: const ValueKey('schedule-date'),
          focusNode: _focus,
          borderRadius: BorderRadius.circular(4),
          onTap: widget.enabled ? _toggle : null,
          child: _PickerBox(
            icon: Icons.calendar_today_outlined,
            active: _overlay.isShowing,
            enabled: widget.enabled,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    formatScheduleDate(widget.value),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: widget.enabled
                          ? theme.colorScheme.onSurface
                          : theme.disabledColor,
                    ),
                  ),
                ),
                Icon(
                  _overlay.isShowing
                      ? Icons.arrow_drop_up
                      : Icons.arrow_drop_down,
                  size: 24,
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

const _calendarWidth = 296.0;
const _calendarHeight = 330.0;
const _weekdayHeaders = ['일', '월', '화', '수', '목', '금', '토'];

/// 발송 날짜 달력 — [first]~[last] 밖의 날은 흐리게 두고 누를 수 없다. 오늘은 굵게, 고른 날은 동그라미.
class _ScheduleCalendar extends StatefulWidget {
  final DateTime value;
  final DateTime first;
  final DateTime last;
  final ValueChanged<DateTime> onPicked;
  const _ScheduleCalendar({
    required this.value,
    required this.first,
    required this.last,
    required this.onPicked,
  });

  @override
  State<_ScheduleCalendar> createState() => _ScheduleCalendarState();
}

class _ScheduleCalendarState extends State<_ScheduleCalendar> {
  late DateTime _month = DateTime(widget.value.year, widget.value.month);

  bool get _canPrev =>
      _month.isAfter(DateTime(widget.first.year, widget.first.month));
  bool get _canNext =>
      _month.isBefore(DateTime(widget.last.year, widget.last.month));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hint = theme.hintColor;
    final today = _dayOf(DateTime.now());
    final selected = _dayOf(widget.value);
    // 그 달이 걸친 주만큼(5~6줄) — 앞뒤로 모자란 자리는 비워 둔다(이웃 달 날짜는 고를 수 없게).
    final leading = _month.weekday % 7;
    final firstCell = DateTime(_month.year, _month.month, 1 - leading);
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final rows = ((leading + daysInMonth) / 7).ceil();

    Widget arrow(IconData icon, String tooltip, VoidCallback? onTap) =>
        IconButton(
          icon: Icon(icon, size: 20),
          tooltip: tooltip,
          visualDensity: VisualDensity.compact,
          onPressed: onTap,
        );

    return SizedBox(
      width: _calendarWidth,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                arrow(
                  Icons.chevron_left,
                  '이전 달',
                  _canPrev
                      ? () => setState(
                          () =>
                              _month = DateTime(_month.year, _month.month - 1),
                        )
                      : null,
                ),
                Expanded(
                  child: Text(
                    '${_month.year}년 ${_month.month}월',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
                arrow(
                  Icons.chevron_right,
                  '다음 달',
                  _canNext
                      ? () => setState(
                          () =>
                              _month = DateTime(_month.year, _month.month + 1),
                        )
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                for (final (i, label) in _weekdayHeaders.indexed)
                  Expanded(
                    child: Center(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          color: i == 0
                              ? Colors.red.shade400
                              : i == 6
                              ? Colors.blue.shade400
                              : hint,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            for (var row = 0; row < rows; row++)
              Row(
                children: [
                  for (var col = 0; col < 7; col++)
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          final day = DateTime(
                            firstCell.year,
                            firstCell.month,
                            firstCell.day + row * 7 + col,
                          );
                          if (day.month != _month.month) {
                            return const SizedBox(height: 36);
                          }
                          final enabled =
                              !day.isBefore(widget.first) &&
                              !day.isAfter(widget.last);
                          final isSelected = day == selected;
                          return InkWell(
                            key: ValueKey(
                              'schedule-day-${day.year}-${day.month}-${day.day}',
                            ),
                            onTap: enabled ? () => widget.onPicked(day) : null,
                            borderRadius: BorderRadius.circular(999),
                            child: SizedBox(
                              height: 36,
                              child: Center(
                                child: Container(
                                  width: 32,
                                  height: 32,
                                  alignment: Alignment.center,
                                  decoration: isSelected
                                      ? BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: scheme.primary,
                                        )
                                      : day == today
                                      ? BoxDecoration(
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: scheme.primary.withValues(
                                              alpha: 0.5,
                                            ),
                                          ),
                                        )
                                      : null,
                                  child: Text(
                                    '${day.day}',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: isSelected || day == today
                                          ? FontWeight.w700
                                          : FontWeight.normal,
                                      color: isSelected
                                          ? scheme.onPrimary
                                          : enabled
                                          ? null
                                          : theme.disabledColor,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// 시각 칸 — 15분 단위 목록(오전 12:00 … 오후 11:45). 그날 고를 수 없는 시각(지난 시각·90일을 넘는
/// 시각)은 흐리게 두고 누를 수 없다.
class _TimeField extends StatelessWidget {
  final int minutes;
  final bool enabled;
  final bool Function(int minutes) allowed;
  final ValueChanged<int> onChanged;
  const _TimeField({
    required this.minutes,
    required this.enabled,
    required this.allowed,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _PickerBox(
      icon: Icons.schedule,
      active: false,
      enabled: enabled,
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          key: const ValueKey('schedule-time'),
          value: minutes,
          isExpanded: true,
          isDense: true,
          menuMaxHeight: 320,
          borderRadius: BorderRadius.circular(8),
          icon: Icon(Icons.arrow_drop_down, size: 24, color: theme.hintColor),
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurface,
          ),
          onChanged: enabled
              ? (m) {
                  if (m != null) onChanged(m);
                }
              : null,
          items: [
            for (var m = 0; m < 24 * 60; m += scheduledSlotMinutes)
              DropdownMenuItem(
                value: m,
                enabled: allowed(m),
                child: Text(
                  formatScheduleClock(DateTime(2000, 1, 1, 0, m)),
                  style: allowed(m)
                      ? null
                      : TextStyle(color: theme.disabledColor),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 첨부 하나 — 사진은 정사각형 미리보기, 파일은 이름·크기 칩. 올리는 중이면 진행 막대, 실패하면 다시 시도.
class _AttachmentTile extends StatelessWidget {
  final _Item item;
  final bool uploading;
  final VoidCallback? onRemove;
  final VoidCallback onRetry;
  const _AttachmentTile({
    super.key,
    required this.item,
    required this.uploading,
    required this.onRemove,
    required this.onRetry,
  });

  static const _tile = 72.0;

  @override
  Widget build(BuildContext context) {
    final body = item.isImage ? _buildImage(context) : _buildFile(context);
    return Tooltip(
      message: item.name,
      waitDuration: const Duration(milliseconds: 600),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          body,
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

  Widget _preview(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final fallback = Icon(Icons.image_outlined, color: scheme.onSurfaceVariant);
    final bytes = item.thumbBytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        width: _tile,
        height: _tile,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      );
    }
    final file = item.file;
    if (file != null) {
      return XFileImage(
        file,
        width: _tile,
        height: _tile,
        fit: BoxFit.cover,
        // 원본(수천 px)을 통째로 풀지 않고 미리보기 크기로만 푼다.
        cacheWidth: (_tile * dpr).round(),
        errorBuilder: (_, _, _) => fallback,
      );
    }
    final url = item.networkThumb;
    if (url != null) {
      return RetryingNetworkImage(
        imageUrl: url,
        width: _tile,
        height: _tile,
        fit: BoxFit.cover,
        errorWidget: (_, _, _) => fallback,
      );
    }
    return fallback;
  }

  Widget _buildImage(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final progress = item.progress;
    return SizedBox(
      width: _tile,
      height: _tile,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: Center(child: _preview(context)),
              ),
            ),
          ),
          if (item.error != null)
            Positioned.fill(
              child: Material(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: onRetry,
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.refresh, color: Colors.white, size: 20),
                      SizedBox(height: 2),
                      Text(
                        '다시 시도',
                        style: TextStyle(color: Colors.white, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else if (item.pending)
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
                          : '대기 중',
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
        ],
      ),
    );
  }

  Widget _buildFile(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final size = formatFileSize(item.size);
    final Widget status;
    if (item.error != null) {
      status = InkWell(
        onTap: onRetry,
        child: Text(
          '올리지 못함 · 다시 시도',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.error,
          ),
        ),
      );
    } else if (item.pending) {
      final progress = item.progress;
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
                : '대기',
            style: TextStyle(fontSize: 11, color: hint),
          ),
        ],
      );
    } else {
      status = Text(size, style: TextStyle(fontSize: 11, color: hint));
    }
    return Container(
      width: 208,
      height: _tile,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(
          color: item.error != null
              ? theme.colorScheme.error
              : theme.dividerColor,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            fileIconFor(item.name),
            size: 26,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
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

/// 첨부 모서리의 작은 지우기(x) 단추.
class _RemoveBadge extends StatelessWidget {
  final VoidCallback onTap;
  const _RemoveBadge({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '첨부 빼기',
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

/// 날짜(달력)와 15분 단위 시각을 두 칸으로 나란히 고르는 입력 — 고를 수 있는 범위(지금 이후~90일 안)와
/// 날짜를 바꿨을 때 그날 고를 수 없는 시각이면 가장 가까운 시각으로 옮기는 규칙은 [ScheduleDateTimeField]와
/// 같다. 할 일 편집기의 직접 지정 알림이 쓴다.
class SchedulePicker extends StatelessWidget {
  final DateTime value;
  final bool enabled;
  final ValueChanged<DateTime> onChanged;
  const SchedulePicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  void _pickDate(DateTime day) => onChanged(_valueOnDay(value, day));

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final first = _firstSlotAfter(now);
    final last = _lastSlot(now);
    final day = _dayOf(value);
    final date = _DateField(
      value: value,
      first: _dayOf(first),
      last: _dayOf(last),
      enabled: enabled,
      onPicked: _pickDate,
    );
    final time = _TimeField(
      minutes: value.hour * 60 + value.minute,
      enabled: enabled,
      allowed: (m) => _slotAllowed(
        DateTime(day.year, day.month, day.day, 0, m),
        DateTime.now(),
      ),
      onChanged: (m) => onChanged(DateTime(day.year, day.month, day.day, 0, m)),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // 좁은 화면(휴대폰)에서는 날짜와 시각을 위아래로 쌓는다.
        if (constraints.maxWidth < 380) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [date, const SizedBox(height: 8), time],
          );
        }
        return Row(
          children: [
            Expanded(flex: 3, child: date),
            const SizedBox(width: 10),
            Expanded(flex: 2, child: time),
          ],
        );
      },
    );
  }
}

/// 날짜와 시각을 **한 칸**에서 고르는 입력 — 칸에는 `10월 5일 (일) 오후 3:00`처럼 한 줄로 보이고, 누르면 바로
/// 아래(자리가 모자라면 위)에 달력이 펼쳐지고 달력 밑의 시간 드롭다운에서 15분 단위 시각까지 고른다. 날짜를
/// 누르면 펼친 채로 날짜만 바뀌고(그날 고를 수 없는 시각이면 [SchedulePicker]와 같은 규칙으로 옮긴다), 시각을
/// 고르거나 바깥을 누르면 닫힌다. 고를 수 있는 범위(지금 이후~90일 안)도 [SchedulePicker]와 같다. 예약 메시지
/// 발송 시간과 투표 마감 시각, 공지 자동 내리기의 "지정" 시각이 쓴다.
class ScheduleDateTimeField extends StatefulWidget {
  final DateTime value;
  final bool enabled;
  final ValueChanged<DateTime> onChanged;

  /// 고를 수 있는 가장 늦은 시각을 지금부터 며칠 뒤로 둘지 — 기본은 예약 메시지·투표 마감과 같은 90일
  /// ([scheduledMaxDaysAhead]). 공지 자동 내리기는 서버 한도(1년)에 맞춰 더 길게 준다.
  final int maxDaysAhead;
  const ScheduleDateTimeField({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.maxDaysAhead = scheduledMaxDaysAhead,
  });

  /// [key]를 준 칸의 펼친 판(달력·시간 목록)을 닫았으면 true — 다른 화면의 편집기가 Esc·뒤로 가기에서 창보다
  /// 판을 먼저 닫게(예약 편집기의 hidePopup과 같다).
  static bool hidePopupOf(GlobalKey key) {
    final state = key.currentState;
    return state is _ScheduleDateTimeFieldState && state.hidePopup();
  }

  @override
  State<ScheduleDateTimeField> createState() => _ScheduleDateTimeFieldState();
}

class _ScheduleDateTimeFieldState extends State<ScheduleDateTimeField>
    with WidgetsBindingObserver {
  final _overlay = OverlayPortalController();

  /// 판을 열 때 포커스를 이 칸으로 옮긴다 — 글을 쓰던 중이면 휴대폰 화상 키보드가 내려가서 펼친 판을
  /// 가리지 않는다(_DateField와 같다).
  final _focus = FocusNode(debugLabel: 'schedule-datetime');

  /// 칸과 펼친 달력을 한 묶음으로 본다 — 열린 채 칸을 다시 누르면 닫히기만 한다(_DateField와 같다).
  final _tapGroup = UniqueKey();

  /// 칸 위에 펼치는지(아래 자리가 모자라고 위가 더 넓을 때), 오른쪽 끝을 넘지 않게 옮긴 가로 거리 —
  /// [_place]가 정한다.
  bool _above = false;
  double _dx = 0;

  /// 달력 밑 시간 드롭다운의 목록이 펼쳐져 있는지.
  bool _timeOpen = false;

  /// 달력이 가장 길 때(6주)의 높이 — 자리를 잴 때 쓴다.
  static const _calendarMaxHeight = 300.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (!_overlay.isShowing) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _overlay.isShowing) setState(_place);
    });
  }

  /// 펼친 판(달력·시간 목록)을 닫았으면 true — 예약 편집기의 Esc·뒤로 가기가 편집기보다 판을 먼저 닫게.
  bool hidePopup() {
    if (!_overlay.isShowing) return false;
    _overlay.hide();
    _timeOpen = false;
    if (mounted) setState(() {});
    return true;
  }

  /// 아래 자리가 모자라고 위가 더 넓으면 칸 위로 펼친다. 오른쪽 끝도 넘지 않게. 시간 목록은 판 안에서
  /// 달력을 덮으며 펼쳐지므로 판 크기는 그대로다.
  void _place() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.sizeOf(context);
    // 칸과의 틈(6) + 화면 끝 여백(8).
    final below = screen.height - origin.dy - box.size.height - 14;
    final above = origin.dy - 14;
    const full = _calendarMaxHeight + 1 + _ScheduleTimeBox.height;
    _above = below < full && above > below;
    final maxLeft = math.max(8.0, screen.width - _calendarWidth - 8);
    _dx = origin.dx.clamp(8.0, maxLeft) - origin.dx;
  }

  void _toggle() {
    if (hidePopup()) return;
    _focus.requestFocus();
    setState(_place);
    _overlay.show();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final value = widget.value;
    final day = _dayOf(value);
    final minutes = value.hour * 60 + value.minute;
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _overlay,
      overlayChildBuilder: (context, info) => _FieldPopupPosition(
        info: info,
        above: _above,
        dx: _dx,
        child: Align(
          alignment: _above ? Alignment.bottomLeft : Alignment.topLeft,
          child: TapRegion(
            groupId: _tapGroup,
            onTapOutside: (_) => hidePopup(),
            child: Material(
              key: const ValueKey('schedule-datetime-popup'),
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              color: theme.colorScheme.surfaceContainerHigh,
              child: Stack(
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _ScheduleCalendar(
                        value: value,
                        first: _dayOf(_firstSlotAfter(now)),
                        last: _dayOf(_lastSlot(now, widget.maxDaysAhead)),
                        onPicked: (d) => widget.onChanged(
                          _valueOnDay(value, d, widget.maxDaysAhead),
                        ),
                      ),
                      SizedBox(
                        width: _calendarWidth,
                        child: Divider(height: 1, color: theme.dividerColor),
                      ),
                      _ScheduleTimeBox(
                        minutes: minutes,
                        open: _timeOpen,
                        onTap: () => setState(() => _timeOpen = !_timeOpen),
                      ),
                    ],
                  ),
                  // 시간 목록은 칸 바로 위로, 달력을 덮으며 펼친다(판 크기가 바뀌지 않아 화면 밖으로 안 나간다).
                  if (_timeOpen)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: _ScheduleTimeBox.boxBottom + 4,
                      child: _ScheduleTimeList(
                        minutes: minutes,
                        allowed: (m) => _slotAllowed(
                          DateTime(day.year, day.month, day.day, 0, m),
                          DateTime.now(),
                          widget.maxDaysAhead,
                        ),
                        onPicked: (m) {
                          hidePopup();
                          widget.onChanged(
                            DateTime(day.year, day.month, day.day, 0, m),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
      child: TapRegion(
        groupId: _tapGroup,
        child: InkWell(
          key: const ValueKey('schedule-datetime'),
          focusNode: _focus,
          borderRadius: BorderRadius.circular(4),
          onTap: widget.enabled ? _toggle : null,
          child: _PickerBox(
            icon: Icons.event_outlined,
            active: _overlay.isShowing,
            enabled: widget.enabled,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    formatScheduleTime(value),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: widget.enabled
                          ? theme.colorScheme.onSurface
                          : theme.disabledColor,
                    ),
                  ),
                ),
                Icon(
                  _overlay.isShowing
                      ? Icons.arrow_drop_up
                      : Icons.arrow_drop_down,
                  size: 24,
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

/// 달력 밑의 시간 드롭다운 칸 — `시간` 글자 아래에 지금 시각과 ▾. 누르면 [_ScheduleTimeList]가 이 칸 바로 위로
/// 펼쳐진다(달력을 덮는다). 목록을 따로 띄우지 않고 판 안에 그리는 이유: 펼친 달력 판은 바깥을 누르면 닫히는데,
/// 따로 뜨는 메뉴의 항목을 누르는 것도 "바깥"으로 잡혀 판이 먼저 닫혀 버린다.
class _ScheduleTimeBox extends StatelessWidget {
  /// 시각 칸 높이 — 펼친 목록의 글자 크기(14)에 맞춘 작은 칸.
  static const _boxHeight = 36.0;

  /// 이 칸 전체 높이(위 여백·글자·칸·아래 여백)와, 판 아래 끝에서 시각 칸 위 끝까지의 거리.
  static const height = 8 + 24 + _boxHeight + 12.0;
  static const boxBottom = 12 + _boxHeight;

  final int minutes;
  final bool open;
  final VoidCallback onTap;
  const _ScheduleTimeBox({
    required this.minutes,
    required this.open,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: _calendarWidth,
      height: height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 24,
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  '시간',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: theme.hintColor,
                  ),
                ),
              ),
            ),
            InkWell(
              key: const ValueKey('schedule-time-box'),
              borderRadius: BorderRadius.circular(4),
              onTap: onTap,
              child: _PickerBox(
                icon: Icons.schedule,
                active: open,
                enabled: true,
                height: _boxHeight,
                iconSize: 16,
                child: Row(
                  children: [
                    Expanded(
                      // 펼친 목록의 글자와 같은 크기.
                      child: Text(
                        formatScheduleClock(DateTime(2000, 1, 1, 0, minutes)),
                        style: TextStyle(
                          fontSize: _ScheduleTimeList.fontSize,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    Icon(
                      open ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                      size: 20,
                      color: theme.hintColor,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 시간 드롭다운의 목록 — 15분 단위(오전 12:00 … 오후 11:45), 펼칠 때 고른 시각이 보이게 스크롤해 둔다. 그날
/// 고를 수 없는 시각(지난 시각·90일을 넘는 시각)은 흐리게 두고 누를 수 없다.
class _ScheduleTimeList extends StatefulWidget {
  static const height = 216.0;
  static const fontSize = 14.0;
  static const _rowHeight = 36.0;

  final int minutes;
  final bool Function(int minutes) allowed;
  final ValueChanged<int> onPicked;
  const _ScheduleTimeList({
    required this.minutes,
    required this.allowed,
    required this.onPicked,
  });

  @override
  State<_ScheduleTimeList> createState() => _ScheduleTimeListState();
}

class _ScheduleTimeListState extends State<_ScheduleTimeList> {
  // 고른 시각이 둘째 줄쯤 오게 — 그 앞 시각도 조금 보인다.
  late final _scroll = ScrollController(
    initialScrollOffset: math.max(
      0,
      (widget.minutes ~/ scheduledSlotMinutes - 1) *
          _ScheduleTimeList._rowHeight,
    ),
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      key: const ValueKey('schedule-time-list'),
      elevation: 4,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: _ScheduleTimeList.height,
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemExtent: _ScheduleTimeList._rowHeight,
          itemCount: 24 * 60 ~/ scheduledSlotMinutes,
          itemBuilder: (context, i) {
            final m = i * scheduledSlotMinutes;
            final enabled = widget.allowed(m);
            final selected = m == widget.minutes;
            return InkWell(
              key: ValueKey('schedule-slot-$m'),
              onTap: enabled ? () => widget.onPicked(m) : null,
              child: Container(
                color: selected ? scheme.primaryContainer : null,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        formatScheduleClock(DateTime(2000, 1, 1, 0, m)),
                        style: TextStyle(
                          fontSize: _ScheduleTimeList.fontSize,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.normal,
                          color: selected
                              ? scheme.onPrimaryContainer
                              : enabled
                              ? null
                              : theme.disabledColor,
                        ),
                      ),
                    ),
                    if (selected)
                      Icon(
                        Icons.check,
                        size: 16,
                        color: scheme.onPrimaryContainer,
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 칸에 붙여 띄우는 판의 자리 — 칸 아래 6(위로 펼치면 칸 위 6)에 왼쪽 끝을 맞추고 [dx]만큼 옮긴다. 레이아웃 때 칸의 자리
/// ([info])로 정한다 — CompositedTransformFollower(그릴 때 자리가 정해짐)로 따라붙이면 판 안의 툴팁(‹ 이전 달 등)이 자리를
/// 못 재서 마우스를 올렸다 떼면 "'debugNeedsLayout': is not true" 오류가 났다(DateTimeRangeField와 같다).
class _FieldPopupPosition extends StatelessWidget {
  final OverlayChildLayoutInfo info;
  final bool above;
  final double dx;
  final Widget child;
  const _FieldPopupPosition({
    required this.info,
    required this.above,
    required this.dx,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final field = MatrixUtils.transformRect(
      info.childPaintTransform,
      Offset.zero & info.childSize,
    );
    return Stack(
      children: [
        Positioned(
          left: field.left + dx,
          top: above ? null : field.bottom + 6,
          bottom: above ? info.overlaySize.height - field.top + 6 : null,
          child: child,
        ),
      ],
    );
  }
}
