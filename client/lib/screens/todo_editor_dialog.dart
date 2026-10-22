import 'dart:async';
import 'dart:math' as math;

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../models/todo.dart';
import '../services/api_client.dart' show UploadCancelToken;
import '../services/app_platform.dart';
import '../services/file_type_utils.dart';
import '../services/folder_dialog.dart'
    if (dart.library.js_interop) '../services/folder_dialog_stub.dart';
import '../services/room_chat_controller.dart'
    show UploadedAttachment, uploadPlainFile;
import '../services/session.dart';
import '../services/todo_api.dart';
import '../services/todo_upload.dart' show localFolderOrNull;
import '../widgets/app_toast.dart';
import '../widgets/attachment_widgets.dart' show formatFileSize;
import '../widgets/compact_menu.dart';
import '../widgets/date_time_range_field.dart';
import '../widgets/room_picker_field.dart';
import '../widgets/todo_widgets.dart';
import '../widgets/user_avatar.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'post_editor_dialog.dart' show fileIconFor;
import 'schedule_message_dialog.dart' show SchedulePicker;
import '../l10n/tr.dart';

/// 할 일 만들기·고치기 화면을 연다 — [mode]를 안 주면 넓은 창(PC)은 대화상자, 좁은 창(모바일)은 전체 화면.
/// [TodoViewMode.panel]이면 가장 가까운 Navigator(PC 할 일 패널의 중첩 Navigator)에 패널 안 화면으로 올린다 — 머리
/// `← 할 일 … ✕`의 ←는 이 화면만 닫고(쓰던 내용이 있으면 먼저 묻는다), ✕는 [onClosePanel](패널 전체 닫기 — 역시 먼저
/// 묻는다)을 부른다. 패널 밖에서 패널을 닫거나 바꿀 때(같은 메뉴 타일·다른 패널·댓글 열기)도 쓰던 내용이 있으면 먼저
/// 묻는다([TodoPanelDrafts]). 저장했으면 서버가 돌려준 할 일, 닫기만 했으면(고치기에서 바꾼 게 없이 [저장하기]도) null.
///
/// - [editing]을 주면 고치기다: 대화방은 잠기고(한 번 만든 할 일은 다른 방으로 옮길 수 없다 — 만들 때도 대화방 칸 아래에
///   이 안내가 늘 보인다), 담당자 칸은 만든 사람만 바꿀 수 있다(담당자는 읽기 전용 — `canManage`).
/// - [room]을 주면 그 방이 대화방 칸에 채워진다. [lockRoom]이면 못 바꾼다(메시지·댓글에서 "할 일로 등록"할 때).
/// - 새로 만들 때 담당자 기본값은 나다(지울 수 있다 — 나와의 대화도 같다). 고른 대화방을 다른 방으로 바꾸면 첨부와
///   담당자가 초기화된다(잔디와 같다 — 지울 게 있으면 먼저 묻는다).
/// - [initialTitle]·[initialDescription]·[initialAttachments]·[sourceMessageId]·[sourceCommentId]는 메시지·댓글에서
///   만들 때 미리 채우는 값이다(제목·설명은 고칠 수 있다). [initialAssignees]·[initialDue]는 회의록의 할 일에서 만들 때
///   (담당자 — 주면 기본값 "나" 대신, 기한 — 그날 하루).
/// - [api]는 테스트가 가짜를 끼우는 자리 — 안 주면 [SessionTodos.todoApi].
Future<Todo?> showTodoEditor(
  BuildContext context, {
  required Session session,
  Room? room,
  bool lockRoom = false,
  Todo? editing,
  String? initialTitle,
  String? initialDescription,
  List<UploadedAttachment> initialAttachments = const [],
  List<AppUser>? initialAssignees,
  DateTime? initialDue,
  String? sourceMessageId,
  String? sourceCommentId,
  TodoApi? api,
  TodoViewMode? mode,
  VoidCallback? onClosePanel,
}) {
  final viewMode =
      mode ??
      (MediaQuery.sizeOf(context).width >= wideBreakpoint
          ? TodoViewMode.dialog
          : TodoViewMode.page);
  final editor = TodoEditor(
    session: session,
    room: room,
    lockRoom: lockRoom,
    editing: editing,
    initialTitle: initialTitle,
    initialDescription: initialDescription,
    initialAttachments: initialAttachments,
    initialAssignees: initialAssignees,
    initialDue: initialDue,
    sourceMessageId: sourceMessageId,
    sourceCommentId: sourceCommentId,
    api: api,
    mode: viewMode,
    onClosePanel: onClosePanel,
  );
  return switch (viewMode) {
    TodoViewMode.dialog => showDialog<Todo>(
      context: context,
      // 바깥을 잘못 눌러 쓰던 내용이 날아가지 않게 — 닫기는 취소·X(내용이 있으면 확인 후)로만.
      barrierDismissible: false,
      builder: (_) => editor,
    ),
    TodoViewMode.page => Navigator.of(context).push<Todo>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => editor),
    ),
    TodoViewMode.panel => Navigator.of(
      context,
    ).push<Todo>(todoPanelRoute((_) => editor)),
  };
}

// 잔디 생성 창의 모양 값 — 칸마다 왼쪽에 회색 아이콘(이름표 없음), 오른쪽에 같은 높이의 옅은 테두리 상자.

/// 한 줄짜리 칸(대화방·제목·파일 업로드·담당자 상자·기간·알림)의 높이와 모서리 — 높이는 공용 대화방 칸
/// (RoomPickerField — 위아래 여백 14 + 테두리 + 한 줄)과 같게 맞췄다. PC의 촘촘한 밀도(compact)에서도 줄지 않게 글자 칸과
/// 단추는 표준 밀도로 그린다.
const double _fieldHeight = 50;
const double _fieldRadius = 8;

/// 왼쪽 아이콘 크기와 아이콘~칸 사이.
const double _iconSize = 20;
const double _iconGap = 12;

/// 줄과 줄 사이.
const double _rowGap = 20;

/// 칸 테두리 — 잔디처럼 옅은 회색. 대화방 칸(RoomPickerField)도 같은 색으로 맞춘다.
Color _fieldBorder(ThemeData theme) => theme.colorScheme.outlineVariant;

/// 옅은 회색 바탕 — 파일 업로드 단추·담당자 상자·추가한 알림 줄(목록의 `+ 할 일 생성` 단추와 같은 색).
Color _softFill(ThemeData theme) => theme.colorScheme.surfaceContainerHighest;

/// 왼쪽 아이콘 색 — 차분한 회색(어두운 테마에서도 보이게 outline).
Color _iconColor(ThemeData theme) => theme.colorScheme.outline;

/// 붙인 파일 하나 — 붙이자마자 올리고, 저장할 때는 올라간 결과만 보낸다. 이미 서버에 있는 첨부(고치기·메시지에서
/// 만들기)는 처음부터 [result]가 있다.
class _TodoFile {
  _TodoFile.picked({
    required XFile this.file,
    required this.name,
    required this.size,
    required this.isImage,
  });

  _TodoFile.existing(UploadedAttachment this.result)
    : file = null,
      name = result.fileName,
      size = result.size,
      isImage = result.isImage;

  final XFile? file;
  final String name;

  /// 새로 고른 파일은 처음엔 0 — 붙인 직후 파일 크기를 읽어 채운다(XFile.length()가 비동기라).
  int size;
  final bool isImage;
  final UploadCancelToken token = UploadCancelToken();
  int sent = 0;
  int total = 0;
  UploadedAttachment? result;
  String? error;
  bool removed = false;

  bool get pending => result == null && error == null;
  double? get progress {
    final all = total > 0 ? total : size;
    return all > 0 ? (sent / all).clamp(0.0, 1.0) : null;
  }
}

/// 알림 일정 한 칸 — 이미 서버에 있는 것은 [id]가 있다([sent]면 이미 울렸다).
class _ReminderDraft {
  _ReminderDraft({this.id, required this.at, this.sent = false});
  final String? id;
  DateTime at;
  final bool sent;
}

/// 할 일 만들기·고치기(대화상자/전체 화면/패널 안 화면 공용) — 잔디 생성 창 모양: 칸마다 왼쪽에 회색 아이콘(이름표·글자
/// 수 카운터 없음), 위에서부터 대화방(맨 위 — 아래에 "만든 뒤에는 못 바꾼다" 안내), 제목(필수), 설명, 파일(`파일 다운로드 (경로
/// 선택)` — 받아 갈 파일을 30개까지 붙이거나(오른쪽 아래 `N / 30`), PC에서는 파일 대신 폴더를 골라 그 경로를 지정, 그 아래
/// `업로드 경로 지정` — 결과물을 올릴 폴더, PC 전용), 담당자(회색 상자 + 오른쪽 아래 `✏ 담당자 관리` — 방 멤버 중 여러 명, 새로 만들 때 기본은 나),
/// 기간(`시작 ~ 종료` 한 칸 — 누르면 달력과 시작/종료 시간 판), 알림(`알림을 받아보세요 (선택) ▾` — 5개까지), 맨 아래 [취소][저장하기].
/// 제목이 있고 입력이 서버 규칙 안일 때만 저장할 수 있다.
class TodoEditor extends StatefulWidget {
  final Session session;
  final Room? room;
  final bool lockRoom;
  final Todo? editing;
  final String? initialTitle;
  final String? initialDescription;
  final List<UploadedAttachment> initialAttachments;
  final List<AppUser>? initialAssignees;
  final DateTime? initialDue;
  final String? sourceMessageId;
  final String? sourceCommentId;
  final TodoApi? api;

  /// 그리는 모양 — 안 주면 [asDialog]로 정한다(true = 대화상자, false = 전체 화면).
  final TodoViewMode mode;

  /// 패널 모드의 ✕ — 패널 전체를 닫는다(TodosPanel.onClose). 없으면 ✕가 안 보인다.
  final VoidCallback? onClosePanel;

  const TodoEditor({
    super.key,
    required this.session,
    this.room,
    this.lockRoom = false,
    this.editing,
    this.initialTitle,
    this.initialDescription,
    this.initialAttachments = const [],
    this.initialAssignees,
    this.initialDue,
    this.sourceMessageId,
    this.sourceCommentId,
    this.api,
    bool asDialog = true,
    TodoViewMode? mode,
    this.onClosePanel,
  }) : mode = mode ?? (asDialog ? TodoViewMode.dialog : TodoViewMode.page);

  /// 대화상자로 그리는지(예전 이름 — [mode]가 [TodoViewMode.dialog]인가).
  bool get asDialog => mode == TodoViewMode.dialog;

  @override
  State<TodoEditor> createState() => TodoEditorState();
}

class TodoEditorState extends State<TodoEditor> implements TodoDraft {
  late final TodoApi _api = widget.api ?? widget.session.todoApi;
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _files = <_TodoFile>[];
  final _reminders = <_ReminderDraft>[];

  /// 받아 갈 파일이 있는 폴더(`파일 첨부(또는 폴더 경로 지정)`에서 파일 대신 폴더를 고름)와 결과물을 올릴 폴더(`파일 업로드 (경로
  /// 선택)`) — 없으면 null.
  String? _downloadPath;
  String? _uploadPath;

  /// "대화방에 알리기"(만들 때만, 기본 켜짐) — 할 일 카드는 어느 쪽이든 그 방에 올라가고 토픽·그룹이면 담당자를 멘션한다.
  /// 켜면 방 멤버 모두에게 알림이 가고, 끄면 담당자만 멘션(알림 센터)으로 받는다.
  bool _announce = true;
  List<AppUser> _assignees = [];
  DateTime? _start;
  DateTime? _due;

  /// 시작/종료 시간(자정부터 분) — 그 날짜가 있을 때만 있고, null이면 `시간 없음`(날짜만).
  int? _startMinutes;
  int? _dueMinutes;
  late Room? _room;
  bool _submitting = false;
  String? _serverError;
  Completer<void>? _uploadsIdle;
  late final String _initialSnapshot;

  /// 기간 칸 — 뒤로 가기가 편집기보다 펼친 기간 판을 먼저 닫게.
  final _periodKey = GlobalKey<DateTimeRangeFieldState>();

  /// 떠 있는 창(작성 취소·대화방 변경 확인·담당자 관리·알림 시각 — 대화상자는 루트 Navigator에 뜬다). 패널 안 화면(중첩
  /// Navigator)이 먼저 닫히면(상세가 지워졌다는 알림으로 함께 닫힘·팀 전환) 창만 남지 않게 [dispose]에서 치운다.
  final _dialogs = <Route<Object?>>{};

  /// 패널 안 화면이면 들어가 있는 "쓰는 중인 할 일" 목록 — 홈 화면이 패널을 밖에서 닫거나 바꾸기 전에 이 화면에 묻는다.
  TodoDraftRegistry? _drafts;

  Todo? get _editing => widget.editing;
  bool get _isEdit => _editing != null;

  /// 담당자 칸을 바꿀 수 있는지 — 새로 만들 때와 만든 사람만(담당자는 읽기 전용).
  bool get _canManageAssignees => _editing?.canManage ?? true;

  /// 대화방 칸을 못 바꾸는지 — 고치기이거나 메시지·댓글에서 열었을 때.
  bool get _roomLocked => _isEdit || widget.lockRoom;

  @override
  void initState() {
    super.initState();
    final editing = _editing;
    _room =
        widget.room ??
        (editing == null
            ? null
            : widget.session.rooms
                  .where((r) => r.id == editing.roomId)
                  .firstOrNull);
    if (editing != null) {
      _title.text = editing.title;
      _description.text = editing.description ?? '';
      _assignees = List.of(editing.assignees);
      _start = editing.start;
      _due = editing.due;
      _startMinutes = editing.startMinutes;
      _dueMinutes = editing.dueMinutes;
      _downloadPath = editing.downloadPath;
      _uploadPath = editing.uploadPath;
      for (final a in editing.attachments) {
        _files.add(
          _TodoFile.existing(
            UploadedAttachment(
              isImage: a.isImage,
              url: a.fileUrl,
              fileName: a.fileName ?? '',
              size: a.fileSize ?? 0,
              mimeType: a.mimeType,
              thumbnailUrl: a.thumbnailUrl,
            ),
          ),
        );
      }
      for (final r in editing.reminders) {
        _reminders.add(_ReminderDraft(id: r.id, at: r.remindAt, sent: r.sent));
      }
    } else {
      _title.text = widget.initialTitle ?? '';
      _description.text = widget.initialDescription ?? '';
      // 담당자 기본값은 나(잔디) — 지울 수 있다. 대화방이 아직 없으면 처음 고를 때 채운다. 회의록의 할 일은 거기 적힌 담당자로.
      _assignees = widget.initialAssignees != null
          ? List.of(widget.initialAssignees!)
          : _defaultAssignees(_room);
      final due = widget.initialDue;
      if (due != null) {
        _start = DateTime(due.year, due.month, due.day);
        _due = _start;
      }
      for (final a in widget.initialAttachments.take(todoAttachmentsMaxCount)) {
        _files.add(_TodoFile.existing(a));
      }
    }
    _title.addListener(_rebuild);
    _description.addListener(_rebuild);
    // 기본 담당자(나)도 처음 값에 넣는다 — 그대로 닫으면 "바뀐 게 있나" 묻지 않는다.
    _initialSnapshot = _snapshot();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // PC 할 일 패널 안 화면이면 패널의 "쓰는 중인 할 일" 목록에 든다(대화상자·전체 화면은 패널 밖이라 없다).
    final drafts = widget.mode == TodoViewMode.panel
        ? TodoPanelDrafts.maybeOf(context)
        : null;
    if (!identical(drafts, _drafts)) {
      _drafts?.remove(this);
      _drafts = drafts?..add(this);
    }
  }

  @override
  void dispose() {
    _drafts?.remove(this);
    _drafts = null;
    // 화면을 치우는 중에는 다른 Navigator를 바꿀 수 없어 남은 창은 다음 프레임에 닫는다(결과는 null — 기다리던 쪽은 이미
    // 없다).
    final leftovers = _dialogs.toList();
    _dialogs.clear();
    if (leftovers.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => leftovers.forEach(closeTodoRoute),
      );
    }
    _clearFiles();
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() => _serverError = null);
  }

  /// [showDialog]와 같고, 떠 있는 동안 [_dialogs]에 담아 둔다.
  Future<T?> _showDialog<T>(WidgetBuilder builder) async {
    Route<Object?>? route;
    var open = true;
    try {
      return await showDialog<T>(
        context: context,
        builder: (dialogContext) {
          // 닫히는 동안 다시 그려져도 닫힌 창을 다시 담지 않게 [open]일 때만.
          if (open && route == null) {
            route = ModalRoute.of(dialogContext);
            final captured = route;
            if (captured != null) _dialogs.add(captured);
          }
          return builder(dialogContext);
        },
      );
    } finally {
      open = false;
      _dialogs.remove(route);
    }
  }

  /// 아래쪽 알림(토스트) — 앱 맨 위 Overlay(창 가운데 아래)에 뜬다(패널 안 화면에서도 — [showAppToast]).
  void _toast(String message) => showAppToast(context, message);

  /// 입력 상태를 한 줄로 — 닫을 때 "바뀐 게 있나" 비교용.
  String _snapshot() => [
    _room?.id,
    _title.text.trim(),
    _description.text.trim(),
    ..._assignees.map((a) => a.id),
    _start?.toIso8601String(),
    _due?.toIso8601String(),
    '$_startMinutes~$_dueMinutes',
    ..._files.map((f) => f.result?.url ?? f.name),
    ..._reminders.map((r) => '${r.id}@${r.at.millisecondsSinceEpoch}'),
    'download:$_downloadPath',
    'upload:$_uploadPath',
  ].join('|');

  /// 처음 연 뒤로 바뀐 입력이 있는지(닫을 때 "작성 취소"로 물을지).
  bool get isDirty => _snapshot() != _initialSnapshot;

  /// 패널을 밖에서 닫거나 바꿀 때 물어야 하는지 — 바뀐 게 있고 저장하는 중이 아닐 때.
  @override
  bool get needsDiscardConfirm => !_submitting && isDirty;

  TodoDraftCheck get _check => checkTodoDraft(
    title: _title.text,
    description: _description.text,
    start: _start,
    due: _due,
    startMinutes: _startMinutes,
    dueMinutes: _dueMinutes,
    attachmentCount: _files.length,
    assigneeCount: _assignees.length,
    reminderCount: _reminders.length,
  );

  bool get _hasPendingUpload => _files.any((f) => f.pending);
  bool get _hasFailedUpload => _files.any((f) => f.error != null);

  /// 첨부가 아직 올라가는 중인지 — 테스트가 업로드가 끝나기를 기다릴 때 쓴다.
  bool get debugUploading => _uploadsIdle != null;

  /// 지금 붙어 있는 첨부 수 — 테스트용.
  int get attachmentCount => _files.length;

  /// 저장할 수 있는지 — 대화방이 있고 입력이 서버 규칙 안이고 올리는 중인 파일이 없을 때.
  bool get canSubmit =>
      !_submitting &&
      _room != null &&
      _check.ok &&
      !_hasPendingUpload &&
      !_hasFailedUpload;

  // ── 대화방·담당자 ──────────────────────────────────────────────────

  /// [room]의 멤버 중 나 — 멤버 목록에 내가 없으면 null.
  AppUser? _meIn(Room? room) {
    final myId = widget.session.userId;
    if (room == null || myId == null) return null;
    return room.members.where((m) => m.id == myId).firstOrNull;
  }

  /// 새로 만들 때의 담당자 기본값 — [room]의 나 한 명(대화방이 없으면 비어 있다).
  List<AppUser> _defaultAssignees(Room? room) => [?_meIn(room)];

  /// 대화방을 바꾸면 사라질 입력이 있는지 — 첨부가 있거나 담당자가 기본값([나])이 아닐 때.
  bool _hasRoomBoundInput(Room room) =>
      _files.isNotEmpty ||
      _assignees.map((a) => a.id).join('|') !=
          _defaultAssignees(room).map((a) => a.id).join('|');

  /// 대화방 고르기. 처음 고르면 담당자를 나로 채운다. 이미 고른 방에서 다른 방으로 바꾸면 첨부와 담당자가 초기화된다
  /// (잔디: 할 일의 대화방을 바꾸면 올린 첨부 파일과 담당자 정보가 초기화) — 지울 게 있으면 먼저 묻고, 취소하면 원래
  /// 방·첨부·담당자 그대로다. 대화방 칸은 [_room]을 보여 주므로 묻는 동안에도, 취소한 뒤에도 원래 방이 보인다.
  Future<void> _onRoomPicked(Room room) async {
    final before = _room;
    if (before?.id == room.id) return;
    if (before != null && _hasRoomBoundInput(before)) {
      final change = await _confirmRoomChange();
      if (!change || !mounted) return;
    }
    setState(() {
      if (before != null) _clearFiles();
      _room = room;
      _assignees = _defaultAssignees(room);
      _serverError = null;
    });
  }

  /// "대화방을 바꾸면 첨부와 담당자가 초기화된다" 확인 — [변경]을 눌렀을 때만 true.
  Future<bool> _confirmRoomChange() async {
    final change = await _showDialog<bool>(
      (dialogContext) => AlertDialog(
        content: Text(tr('대화방을 변경하면\n첨부한 파일과 담당자 정보가 초기화됩니다.')),
        actions: [
          TextButton(
            key: const ValueKey('todo-room-change-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const ValueKey('todo-room-change-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('변경')),
          ),
        ],
      ),
    );
    return change == true;
  }

  /// 담당자 고르기(담당자 관리) — 이 대화방 멤버 중에서 여러 명.
  Future<void> _pickAssignees() async {
    final room = _room;
    if (room == null || !_canManageAssignees) return;
    final picked = await _showDialog<List<AppUser>>(
      (_) => _AssigneePickerDialog(
        session: widget.session,
        members: room.members,
        selected: _assignees,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _assignees = picked;
      _serverError = null;
    });
  }

  /// 테스트가 선택 대화상자 없이 담당자를 정할 때 쓴다(방 멤버만 남는다).
  void setAssignees(List<AppUser> users) {
    final members = {for (final m in _room?.members ?? const <AppUser>[]) m.id};
    setState(() {
      _assignees = [
        for (final u in users)
          if (members.contains(u.id)) u,
      ];
    });
  }

  // ── 첨부 ──────────────────────────────────────────────────────────

  /// `파일 첨부(또는 폴더 경로 지정)` — PC는 파일을 고르면 붙이고, 파일을 고르지 않고 [열기]를 누르면 그때 열린 폴더를 받아 갈
  /// 경로로 지정한다(folder_dialog.dart). 모바일은 예전처럼 파일만 고른다.
  Future<void> _pickDownload() async {
    // 폴더 경로는 할 일을 관리하는 사람(만든 사람)만 바꿀 수 있어서(서버도 담당자의 경로 변경을 거절한다) 담당자는 파일만 고른다.
    if (!AppPlatform.isWindows || !_canManageAssignees) return _pickFiles();
    final picked = await pickFilesOrFolder(
      title: tr('파일을 고르거나, 폴더를 연 채로 [열기]를 누르면 그 폴더 경로가 지정됩니다'),
    );
    if (picked == null || !mounted) return;
    final folder = picked.folder;
    if (folder != null) {
      setDownloadPath(folder);
    } else {
      addFiles([for (final f in picked.files) XFile(f)]);
    }
  }

  /// `업로드 경로 지정` — 결과물을 올릴 폴더를 고른다(PC).
  Future<void> _pickUploadFolder() async {
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: tr('담당자가 파일을 올릴 폴더 선택'),
      // Windows 폴더 창은 시작 위치를 받자마자 그 서버에 접속한다(확인 없이 SMB 로그인 정보가 간다) — 저장된 경로가 공유
      // 폴더(UNC)면 시작 위치로 넘기지 않는다(localFolderOrNull).
      initialDirectory: localFolderOrNull(_uploadPath),
    );
    if (folder != null && mounted) setUploadPath(folder);
  }

  /// 받아 갈 파일이 있는 폴더를 지정한다(null이면 지운다) — 테스트가 직접 부르기도 한다.
  void setDownloadPath(String? path) => setState(() {
    _downloadPath = path;
    _serverError = null;
  });

  /// 결과물을 올릴 폴더를 지정한다(null이면 지운다) — 테스트가 직접 부르기도 한다.
  void setUploadPath(String? path) => setState(() {
    _uploadPath = path;
    _serverError = null;
  });

  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    final picked = [
      for (final f in result?.files ?? const <PlatformFile>[])
        // 웹은 경로 없이 바이트만 온다 — xFile이 둘 다 감싼다.
        if (f.path != null || f.bytes != null) f.xFile,
    ];
    if (picked.isNotEmpty && mounted) addFiles(picked);
  }

  /// 파일을 목록에 더하고 바로 올리기 시작한다. 30개를 넘는 만큼은 빼고 알린다(테스트가 직접 부르기도 한다).
  void addFiles(List<XFile> files) {
    if (files.isEmpty || !mounted) return;
    final room = todoAttachmentsMaxCount - _files.length;
    final accepted = files.take(math.max(0, room)).toList();
    if (accepted.length < files.length) {
      _toast(
        tr('첨부 파일은 {todoAttachmentsMaxCount}개까지 올릴 수 있습니다.', {
          'todoAttachmentsMaxCount': todoAttachmentsMaxCount,
        }),
      );
    }
    if (accepted.isEmpty) return;
    final added = [
      for (final f in accepted)
        _TodoFile.picked(
          file: f,
          name: f.name,
          size: 0,
          isImage: looksLikeImagePath(f.name),
        ),
    ];
    setState(() => _files.addAll(added));
    for (final t in added) {
      unawaited(
        t.file!.length().then((n) {
          if (mounted) setState(() => t.size = n);
        }, onError: (_) {}),
      );
    }
    unawaited(_pumpUploads());
  }

  /// 붙인 파일을 하나씩 차례로 올린다.
  Future<void> _pumpUploads() async {
    if (_uploadsIdle != null) return;
    final idle = _uploadsIdle = Completer<void>();
    try {
      while (mounted) {
        final next = _files.where((f) => f.pending && !f.removed).firstOrNull;
        if (next == null) break;
        try {
          final uploaded = await uploadPlainFile(
            widget.session.api!,
            next.file!,
            isImage: next.isImage,
            cancelToken: next.token,
            onProgress: (sent, total) {
              if (!mounted || next.removed) return;
              setState(() {
                next.sent = sent;
                next.total = total;
              });
            },
          );
          if (!mounted || next.removed) continue;
          setState(() => next.result = uploaded);
        } catch (e) {
          if (!mounted || next.removed) continue;
          setState(() => next.error = '$e');
          _toast(
            tr('\'{next.name}\' 파일을 올리지 못했습니다: {e}', {
              'next.name': next.name,
              'e': e,
            }),
          );
        }
      }
    } finally {
      _uploadsIdle = null;
      idle.complete();
    }
  }

  void _removeFile(_TodoFile f) {
    f.removed = true;
    f.token.cancel();
    setState(() => _files.remove(f));
  }

  /// 첨부를 모두 뺀다 — 올리는 중인 것은 [_removeFile]처럼 올리기를 멈춘다(대화방을 바꿀 때·창을 닫을 때).
  void _clearFiles() {
    for (final f in _files) {
      f.removed = true;
      f.token.cancel();
    }
    _files.clear();
  }

  // ── 알림 일정 ─────────────────────────────────────────────────────

  void _addReminder(DateTime at) {
    if (_reminders.length >= todoRemindersMaxCount) {
      _toast(
        tr('알림은 {todoRemindersMaxCount}개까지 추가할 수 있습니다.', {
          'todoRemindersMaxCount': todoRemindersMaxCount,
        }),
      );
      return;
    }
    if (!at.isAfter(DateTime.now())) {
      _toast(tr('이미 지난 시각에는 알림을 만들 수 없습니다.'));
      return;
    }
    if (_reminders.any((r) => r.at == at)) {
      _toast(tr('같은 시각의 알림이 이미 있습니다.'));
      return;
    }
    setState(() {
      _reminders.add(_ReminderDraft(at: at));
      _reminders.sort((a, b) => a.at.compareTo(b.at));
      _serverError = null;
    });
  }

  /// "기한 하루 전"·"기한 1시간 전" — 종료 시간이 있으면 기한일의 그 시각, 없으면 기한일 오후 6시를 기한 시각으로 본다.
  /// 기한이 없으면 안내만.
  void _addRelativeReminder(Duration before) {
    final due = _due;
    if (due == null) {
      _toast(tr('기한을 먼저 정하세요.'));
      return;
    }
    _addReminder(todoReminderBeforeDue(due, before, dueMinutes: _dueMinutes));
  }

  /// 알림 메뉴의 "기한 하루 전"·"기한 1시간 전" 문구 — 기한이 있으면 울릴 시각(`기한 하루 전 (2026/10/24 오후 6:00)`),
  /// 없으면 기준만(`기한 하루 전 (전날 오후 6시)` — 종료 시간이 없는 기한은 오후 6시 기준).
  String _relativeReminderLabel(String name, Duration before, String fallback) {
    final due = _due;
    if (due == null) return '$name ($fallback)';
    final at = todoReminderBeforeDue(due, before, dueMinutes: _dueMinutes);
    return '$name (${formatTodoDateTime(at)})';
  }

  Future<void> _addCustomReminder() async {
    var value = ceilToScheduleSlot(
      DateTime.now().add(const Duration(hours: 1)),
    );
    final picked = await _showDialog<DateTime>(
      (dialogContext) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(tr('알림 시각')),
          content: SizedBox(
            width: 360,
            child: SchedulePicker(
              value: value,
              onChanged: (v) => setLocal(() => value = v),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(tr('취소')),
            ),
            FilledButton(
              key: const ValueKey('todo-reminder-custom-ok'),
              onPressed: () => Navigator.of(dialogContext).pop(value),
              child: Text(tr('추가')),
            ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) _addReminder(picked);
  }

  // ── 저장·닫기 ─────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (!canSubmit) return;
    final editing = _editing;
    final changes = editing == null ? null : _changedFields(editing);
    // 고치기에서 바뀐 칸이 하나도 없으면(아무것도 안 고쳤거나, 담당자를 뺐다가 다시 넣는 등 원래대로 돌려놨으면) 서버에
    // 보내지 않고 그냥 닫는다(잔디처럼) — 빈 수정은 서버가 "수정할 내용이 없습니다."로 거절한다. 결과는 null이라 상세는
    // "수정했습니다"를 띄우지 않고 다시 받지도 않는다.
    if (changes != null && changes.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _submitting = true;
      _serverError = null;
    });
    try {
      final description = _description.text.trim();
      final attachments = [for (final f in _files) f.result!];
      final Todo saved;
      if (editing == null) {
        saved = await _api.create(
          _room!.id,
          title: _title.text.trim(),
          description: description.isEmpty ? null : description,
          assigneeIds: [for (final a in _assignees) a.id],
          startDate: _start == null ? null : todoDateWire(_start!),
          dueDate: _due == null ? null : todoDateWire(_due!),
          startTime: _startTimeWire,
          dueTime: _dueTimeWire,
          attachments: attachments,
          // 이미 지난 시각의 알림은 서버가 거절하므로 만들 때는 미래 것만 보낸다(추가할 때 이미 걸렀다).
          reminders: [for (final r in _reminders) r.at],
          downloadPath: _downloadPath,
          uploadPath: _uploadPath,
          announce: _announce,
          sourceMessageId: widget.sourceMessageId,
          sourceCommentId: widget.sourceCommentId,
        );
      } else {
        saved = await _api.update(editing.id, changes!);
      }
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      // 서버 문구 그대로(권한·기한 순서 등) — 입력은 그대로 두고 알린다.
      if (mounted) setState(() => _serverError = '$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 서버에 보내는 시작/종료 시간('HH:mm') — 그 날짜가 없거나 `시간 없음`이면 null.
  String? get _startTimeWire => _start == null || _startMinutes == null
      ? null
      : todoTimeWire(_startMinutes!);
  String? get _dueTimeWire =>
      _due == null || _dueMinutes == null ? null : todoTimeWire(_dueMinutes!);

  /// 고치기 — 바뀐 칸만 보낸다(담당자가 보내면 안 되는 `assigneeIds`는 바꾼 적 없으면 아예 빼서 403을 피한다).
  Map<String, dynamic> _changedFields(Todo before) {
    final fields = <String, dynamic>{};
    final title = _title.text.trim();
    if (title != before.title) fields['title'] = title;
    final description = _description.text.trim();
    if (description != (before.description ?? '')) {
      fields['description'] = description.isEmpty ? null : description;
    }
    final startWire = _start == null ? null : todoDateWire(_start!);
    final dueWire = _due == null ? null : todoDateWire(_due!);
    if (startWire != before.startDate) fields['startDate'] = startWire;
    if (dueWire != before.dueDate) fields['dueDate'] = dueWire;
    // 시간은 바뀌었을 때만 — 날짜를 지우면 서버가 그 시간도 함께 지우므로 따로 보내지 않는다.
    if (_start != null && _startMinutes != before.startMinutes) {
      fields['startTime'] = _startTimeWire;
    }
    if (_due != null && _dueMinutes != before.dueMinutes) {
      fields['dueTime'] = _dueTimeWire;
    }
    if (_canManageAssignees) {
      final now = _assignees.map((a) => a.id).toSet();
      final was = before.assignees.map((a) => a.id).toSet();
      if (now.length != was.length || !now.containsAll(was)) {
        fields['assigneeIds'] = [for (final a in _assignees) a.id];
      }
    }
    final urls = [for (final f in _files) f.result!.url];
    final beforeUrls = [for (final a in before.attachments) a.fileUrl];
    if (urls.join('|') != beforeUrls.join('|')) {
      fields['attachments'] = [for (final f in _files) f.result!.toPayload()];
    }
    final reminderNow = [
      for (final r in _reminders)
        '${r.id ?? ''}@${r.at.millisecondsSinceEpoch}',
    ];
    final reminderBefore = [
      for (final r in before.reminders)
        '${r.id}@${r.remindAt.millisecondsSinceEpoch}',
    ];
    // 폴더 경로 — 지웠으면 null을 보낸다.
    if (_downloadPath != before.downloadPath) {
      fields['downloadPath'] = _downloadPath;
    }
    if (_uploadPath != before.uploadPath) fields['uploadPath'] = _uploadPath;
    if (reminderNow.join('|') != reminderBefore.join('|')) {
      fields['reminders'] = [
        for (final r in _reminders)
          {'id': ?r.id, 'remindAt': r.at.millisecondsSinceEpoch},
      ];
    }
    return fields;
  }

  /// 쓰던 내용을 버려도 되는지 — 바뀐 게 없으면 묻지 않고 true, 있으면 "작성 취소" 확인에서 [닫기]를 눌렀을 때만 true.
  /// 이 화면의 ←·✕·[취소]·뒤로 가기, 그리고 패널 안 화면이면 홈 화면이 패널을 닫거나 바꾸기 전에도 묻는다.
  @override
  Future<bool> confirmDiscard() async {
    if (!isDirty) return true;
    final discard = await _showDialog<bool>(
      (dialogContext) => AlertDialog(
        title: Text(tr('작성 취소')),
        content: Text(
          _isEdit ? tr('수정한 내용을 버리고 닫을까요?') : tr('작성 중인 할 일을 버리고 닫을까요?'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(_isEdit ? tr('계속 수정') : tr('계속 쓰기')),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('닫기'), style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    return discard == true;
  }

  Future<void> _requestClose() async {
    if (_submitting) return;
    if (!await confirmDiscard() || !mounted) return;
    Navigator.of(context).pop();
  }

  /// 패널 모드의 ✕ — 쓰던 내용이 있으면 먼저 묻고 패널 전체를 닫는다(패널 자신의 닫기라 홈 화면은 다시 묻지 않는다).
  Future<void> _requestClosePanel() async {
    final close = widget.onClosePanel;
    if (_submitting || close == null) return;
    if (!await confirmDiscard() || !mounted) return;
    close();
  }

  // ── 화면 ──────────────────────────────────────────────────────────

  String get _heading => _isEdit ? tr('할 일 수정') : tr('할 일 생성');

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 기간 판이 펼쳐져 있으면 그것만 닫는다(안드로이드 뒤로 가기).
        if (_periodKey.currentState?.hidePopup() ?? false) return;
        _requestClose();
      },
      child: switch (widget.mode) {
        TodoViewMode.dialog => _buildDialog(context),
        TodoViewMode.page => _buildPage(context),
        TodoViewMode.panel => _buildPanel(context),
      },
    );
  }

  /// 패널 안 화면(잔디 할 일 생성 화면) — 머리 `← 할 일 … ✕`(←는 이 화면만 닫기, ✕는 패널 전체 닫기 — 쓰던 내용이
  /// 있으면 둘 다 먼저 묻는다), 스크롤되는 입력 칸들, 아래 [취소][저장하기] 줄. 바탕을 칠해 밀려 들어오는 동안 아래
  /// 화면이 비치지 않게 한다.
  Widget _buildPanel(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TodoPageHeader(
            onBack: _requestClose,
            onClose: widget.onClosePanel == null ? null : _requestClosePanel,
          ),
          const Divider(height: 1),
          Expanded(
            child: _formScroll(
              context,
              const EdgeInsets.fromLTRB(16, 20, 16, 12),
            ),
          ),
          const Divider(height: 1),
          _errorLine(context),
          _actionRow(context, horizontal: 16),
        ],
      ),
    );
  }

  /// 대화상자(넓은 창에서 패널 밖 — 메시지·댓글·알림 센터의 "할 일로 등록") — 머리는 패널 안 화면 머리와 같은 모양에
  /// ← 없이 `할 일 생성`/`할 일 수정` + ✕.
  Widget _buildDialog(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: math.min(560, screen.width - 48),
        height: math.min(780, screen.height - 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _heading,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('todo-editor-close'),
                    icon: const Icon(Icons.close),
                    tooltip: tr('닫기'),
                    onPressed: _submitting ? null : _requestClose,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _formScroll(
                context,
                const EdgeInsets.fromLTRB(20, 20, 20, 12),
              ),
            ),
            const Divider(height: 1),
            _errorLine(context),
            _actionRow(context),
          ],
        ),
      ),
    );
  }

  /// 전체 화면(모바일) — 앱 바에 ✕ · 제목 · [저장하기].
  Widget _buildPage(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('todo-editor-close'),
          icon: const Icon(Icons.close),
          tooltip: tr('취소'),
          onPressed: _submitting ? null : _requestClose,
        ),
        title: Text(_heading),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _submitButton(),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _formScroll(
                context,
                const EdgeInsets.fromLTRB(16, 16, 16, 24),
              ),
            ),
            _errorLine(context),
          ],
        ),
      ),
    );
  }

  Widget _formScroll(BuildContext context, EdgeInsets padding) =>
      SingleChildScrollView(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _formChildren(context),
        ),
      );

  /// 아래 [취소][저장하기] 줄(대화상자·패널 안 화면) — 잔디처럼 오른쪽 끝에, 취소는 흐린 글자 단추.
  Widget _actionRow(BuildContext context, {double horizontal = 20}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(horizontal, 12, horizontal, 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: _submitting ? null : _requestClose,
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).hintColor,
            ),
            child: Text(tr('취소')),
          ),
          const SizedBox(width: 8),
          _submitButton(),
        ],
      ),
    );
  }

  /// 목록 아래에 늘 보이는 서버 거절 문구 — 폼이 길어서 스크롤 안에 두면 아래로 밀려 안 보인다.
  Widget _errorLine(BuildContext context) {
    final error = _serverError;
    if (error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          error,
          key: const ValueKey('todo-editor-error'),
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.error,
          ),
        ),
      ),
    );
  }

  Widget _submitButton() {
    final uploading = _hasPendingUpload;
    return FilledButton(
      key: const ValueKey('todo-submit'),
      onPressed: canSubmit ? _submit : null,
      child: _submitting
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(uploading ? tr('업로드 중') : tr('저장하기')),
    );
  }

  /// 글자 칸 모양 — 옅은 테두리의 낮은 상자(한 줄이면 높이 [_fieldHeight]), 안내 글만 있고 이름표·글자 수 카운터는 없다
  /// (글자 수 한도 maxLength는 그대로).
  InputDecoration _inputDecoration(
    ThemeData theme, {
    required String hint,
    String? errorText,
  }) {
    final scheme = theme.colorScheme;
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(_fieldRadius),
          borderSide: BorderSide(color: color, width: width),
        );
    return InputDecoration(
      hintText: hint,
      hintStyle: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
      isDense: true,
      visualDensity: VisualDensity.standard,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
      counterText: '',
      errorText: errorText,
      border: border(_fieldBorder(theme)),
      enabledBorder: border(_fieldBorder(theme)),
      disabledBorder: border(_fieldBorder(theme).withValues(alpha: 0.6)),
      focusedBorder: border(scheme.primary, 1.5),
      errorBorder: border(scheme.error),
      focusedErrorBorder: border(scheme.error, 1.5),
    );
  }

  List<Widget> _formChildren(BuildContext context) {
    final theme = Theme.of(context);
    final check = _check;
    const gap = SizedBox(height: _rowGap);
    // 잔디 생성 창 순서 — 대화방 → 제목 → 설명 → 파일 업로드 → 담당자 → 기간 → 알림. 칸 이름표 대신 왼쪽에 아이콘
    // (줄 순서를 확인하는 키 todo-label-<칸>은 그 아이콘에).
    return [
      _FieldRow(
        id: 'room',
        icon: Icons.chat_bubble_outline,
        label: tr('대화방'),
        child: _roomField(context),
      ),
      gap,
      _FieldRow(
        id: 'title',
        icon: Icons.title,
        label: tr('제목'),
        child: TextField(
          key: const ValueKey('todo-title-field'),
          controller: _title,
          enabled: !_submitting,
          autofocus: _room != null && _title.text.isEmpty,
          maxLength: todoTitleMaxLength,
          textInputAction: TextInputAction.next,
          style: theme.textTheme.bodyMedium,
          decoration: _inputDecoration(theme, hint: tr('제목을 입력하세요')),
        ),
      ),
      gap,
      _FieldRow(
        id: 'description',
        icon: Icons.format_quote,
        label: tr('설명'),
        child: TextField(
          key: const ValueKey('todo-description-field'),
          controller: _description,
          enabled: !_submitting,
          maxLength: todoDescriptionMaxLength,
          minLines: 3,
          maxLines: 8,
          style: theme.textTheme.bodyMedium,
          decoration: _inputDecoration(
            theme,
            hint: tr('설명을 입력하세요 (선택)'),
            errorText: check.descriptionError,
          ),
        ),
      ),
      gap,
      _FieldRow(
        id: 'files',
        icon: Icons.insert_drive_file_outlined,
        label: tr('파일'),
        child: _fileField(context),
      ),
      gap,
      _FieldRow(
        id: 'assignees',
        icon: Icons.people_outline,
        label: tr('담당자'),
        child: _assigneeField(context),
      ),
      gap,
      _FieldRow(
        id: 'period',
        icon: Icons.schedule,
        label: tr('기간'),
        child: _periodField(context, check),
      ),
      gap,
      _FieldRow(
        id: 'reminders',
        icon: Icons.alarm,
        label: tr('알림'),
        child: _reminderField(context),
      ),
      // 만들 때만 — 고칠 때는 카드를 다시 올리지 않는다(새로 추가된 담당자에게는 알림만 간다).
      if (!_isEdit) ...[gap, _announceField(context)],
    ];
  }

  /// "대화방에 알리기" 체크 — 할 일 카드는 어느 쪽이든 그 대화방에 올라가고 토픽·그룹이면 담당자를 멘션한다. 켜면(기본)
  /// 방 멤버 모두에게 알림이 가고, 끄면 담당자만 멘션(알림 센터)으로 받는다.
  Widget _announceField(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return InkWell(
      key: const ValueKey('todo-announce'),
      borderRadius: BorderRadius.circular(_fieldRadius),
      onTap: _submitting ? null : () => setState(() => _announce = !_announce),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              key: const ValueKey('todo-announce-check'),
              value: _announce,
              visualDensity: VisualDensity.compact,
              onChanged: _submitting
                  ? null
                  : (v) => setState(() => _announce = v ?? true),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('대화방에 알리기')),
                    const SizedBox(height: 2),
                    Text(
                      _announce
                          ? tr('대화방 멤버 모두에게 알리고, 담당자는 멘션합니다.')
                          : tr('할 일 카드는 대화방에 올라가고, 알림은 담당자에게만 멘션으로 갑니다.'),
                      style: TextStyle(fontSize: 12, color: hint),
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

  /// 대화방 — 고르는 칸(▾) 또는 잠긴 칸(🔒), 그 바로 아래 "만든 뒤에는 대화방을 바꿀 수 없다"는 안내(잔디처럼 만들 때는
  /// 고르기 전에 미리, 고칠 때는 칸이 잠긴 까닭으로).
  Widget _roomField(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_roomLocked)
          Container(
            key: const ValueKey('todo-room-locked'),
            height: _fieldHeight,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: _softFill(theme).withValues(alpha: 0.5),
              border: Border.all(color: _fieldBorder(theme)),
              borderRadius: BorderRadius.circular(_fieldRadius),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _room?.displayName(widget.session.userId ?? '') ??
                        _editing?.roomName ??
                        tr('대화방'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(Icons.lock_outline, size: 16, color: hint),
              ],
            ),
          )
        else
          KeyedSubtree(
            key: const ValueKey('todo-room-field'),
            child: IgnorePointer(
              ignoring: _submitting,
              // 공용 대화방 칸(RoomPickerField)의 테두리·▾를 이 창의 다른 칸과 같게(옅은 테두리, ▾ 20 — 높이 50).
              child: Theme(
                data: theme.copyWith(dividerColor: _fieldBorder(theme)),
                child: IconTheme.merge(
                  data: IconThemeData(size: _iconSize, color: hint),
                  child: RoomPickerField(
                    session: widget.session,
                    value: _room,
                    filter: widget.session.canCreateTodoIn,
                    onChanged: _onRoomPicked,
                  ),
                ),
              ),
            ),
          ),
        Padding(
          key: const ValueKey('todo-room-hint'),
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            _isEdit
                ? tr('한 번 만든 할 일은 다른 대화방으로 옮길 수 없습니다.')
                : tr('할 일 생성 후에는 대화방 변경이 불가능합니다.'),
            style: TextStyle(fontSize: 12, color: hint),
          ),
        ),
      ],
    );
  }

  /// 파일 — `파일 첨부(또는 폴더 경로 지정)`(가로 전체 옅은 단추, 그 오른쪽 아래 `N / 30`(N 굵게), 그 아래 붙인 파일과 지정한
  /// 폴더 경로), 그 아래 `업로드 경로 지정`(PC — 결과물을 올릴 폴더)와 지정한 경로.
  Widget _fileField(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final full = _files.length >= todoAttachmentsMaxCount;
    final buttonStyle = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(_fieldHeight),
      visualDensity: VisualDensity.standard,
      backgroundColor: _softFill(theme),
      foregroundColor: scheme.onSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_fieldRadius),
      ),
      textStyle: theme.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w500,
      ),
    );
    final downloadPath = _downloadPath;
    final uploadPath = _uploadPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.tonalIcon(
          key: const ValueKey('todo-attach'),
          onPressed: _submitting || full ? null : _pickDownload,
          icon: const Icon(Icons.add, size: 18),
          label: Text(
            _canManageAssignees ? tr('파일 첨부(또는 폴더 경로 지정)') : tr('파일 첨부'),
          ),
          style: buttonStyle,
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text.rich(
            key: const ValueKey('todo-file-count'),
            TextSpan(
              children: [
                TextSpan(
                  text: '${_files.length}',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                TextSpan(text: ' / $todoAttachmentsMaxCount'),
              ],
            ),
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12, color: theme.hintColor),
          ),
        ),
        for (final f in _files)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _FileTile(
              key: ObjectKey(f),
              file: f,
              onRemove: _submitting ? null : () => _removeFile(f),
              onRetry: () {
                setState(() {
                  f.error = null;
                  f.sent = 0;
                  f.total = 0;
                });
                unawaited(_pumpUploads());
              },
            ),
          ),
        if (downloadPath != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _FolderPathTile(
              key: const ValueKey('todo-download-path'),
              path: downloadPath,
              onClear: _submitting ? null : () => setDownloadPath(null),
              clearKey: const ValueKey('todo-download-path-clear'),
              editable: _canManageAssignees,
            ),
          ),
        // 결과물을 올릴 폴더 — 윈도우 폴더 경로라 PC에서만 고른다(모바일은 이미 지정된 경로만 보이고 지울 수 있다). 경로는
        // 할 일을 관리하는 사람만 바꾸므로 담당자에게는 단추와 지우기를 보이지 않는다(경로는 보기만).
        if (AppPlatform.isWindows && _canManageAssignees) ...[
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            key: const ValueKey('todo-upload-path-button'),
            onPressed: _submitting ? null : _pickUploadFolder,
            icon: const Icon(Icons.drive_folder_upload_outlined, size: 18),
            label: Text(tr('업로드 경로 지정')),
            style: buttonStyle,
          ),
        ],
        if (uploadPath != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _FolderPathTile(
              key: const ValueKey('todo-upload-path'),
              path: uploadPath,
              onClear: _submitting ? null : () => setUploadPath(null),
              clearKey: const ValueKey('todo-upload-path-clear'),
              editable: _canManageAssignees,
            ),
          ),
        if (AppPlatform.isWindows && uploadPath == null && _canManageAssignees)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              tr('지정하지 않으면 담당자가 올린 파일은 나에게 메시지로 옵니다.'),
              key: const ValueKey('todo-upload-path-hint'),
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
          ),
      ],
    );
  }

  /// 담당자 — 옅은 회색 상자에 담당자 칩(아바타 + 이름, 나는 "(나)", x로 빼기), 상자 오른쪽 아래 `✏ 담당자 관리`(잔디).
  /// 담당자로 고칠 때는 칩만(읽기 전용 — 빼기·담당자 관리 없음)이고 그 까닭을 작게 알린다.
  Widget _assigneeField(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final readOnly = !_canManageAssignees;
    final myId = widget.session.userId;
    final box = Container(
      key: const ValueKey('todo-assignee-box'),
      constraints: const BoxConstraints(minHeight: _fieldHeight),
      padding: const EdgeInsets.all(8),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: _softFill(theme),
        borderRadius: BorderRadius.circular(_fieldRadius),
      ),
      child: _assignees.isNotEmpty
          ? Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final a in _assignees)
                  _assigneeChip(a, me: a.id == myId, readOnly: readOnly),
              ],
            )
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                readOnly
                    ? tr('담당자가 없습니다.')
                    : _room == null && !_isEdit
                    ? tr('대화방을 먼저 선택하세요.')
                    : tr('담당자를 지정하지 않았습니다.'),
                style: TextStyle(fontSize: 13, color: hint),
              ),
            ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        box,
        if (readOnly)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              tr('담당자는 만든 사람만 바꿀 수 있습니다.'),
              style: TextStyle(fontSize: 12, color: hint),
            ),
          )
        else
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('todo-assignee-add'),
              onPressed: _submitting || _room == null ? null : _pickAssignees,
              icon: const Icon(Icons.edit, size: 14),
              label: Text(tr('담당자 관리')),
              style: TextButton.styleFrom(
                foregroundColor: hint,
                // 단추 글꼴은 테마에서 이어받는다(새 TextStyle은 글꼴·옛한글 대체 글꼴을 잃는다).
                textStyle: theme.textTheme.labelLarge?.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                ),
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
            ),
          ),
      ],
    );
  }

  /// 담당자 칩 하나 — 회색 상자 위의 바탕색 칩. 바꿀 수 있으면 x로 빼는 [InputChip], 읽기 전용이면 보통 [Chip](눌리지
  /// 않는 InputChip은 흐린 "꺼짐" 색으로 그려져 이름이 잘 안 읽힌다).
  Widget _assigneeChip(AppUser a, {required bool me, required bool readOnly}) {
    final theme = Theme.of(context);
    final key = ValueKey('todo-assignee-chip-${a.id}');
    final avatar = UserAvatar(
      user: a,
      resolveUrl: widget.session.resolveUrl,
      radius: 10,
    );
    final label = Text(me ? tr('{a.name} (나)', {'a.name': a.name}) : a.name);
    final labelStyle = theme.textTheme.bodyMedium;
    final background = theme.colorScheme.surface;
    if (readOnly) {
      return Chip(
        key: key,
        avatar: avatar,
        label: label,
        labelStyle: labelStyle,
        backgroundColor: background,
        side: BorderSide.none,
        shape: const StadiumBorder(),
        visualDensity: VisualDensity.compact,
      );
    }
    return InputChip(
      key: key,
      avatar: avatar,
      label: label,
      labelStyle: labelStyle,
      backgroundColor: background,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      visualDensity: VisualDensity.compact,
      deleteIcon: const Icon(Icons.close, size: 16),
      deleteButtonTooltipMessage: tr('담당자에서 빼기'),
      onDeleted: _submitting
          ? null
          : () => setState(() => _assignees.remove(a)),
    );
  }

  /// 기간 — 한 칸(`2026/10/13 오전 9:00 ~ 2026/10/14 오후 6:00`, 좁으면 `~` 뒤에서 두 줄, 비어 있으면 `기간을 선택하세요
  /// (선택)`, 정했으면 ✕ — 날짜와 시간을 모두 지운다). 누르면 칸 바로 아래(자리가 모자라면 위)에 투표 마감 시각과 같은 모양의
  /// 판([DateTimeRangeField]): 기간 달력(첫 누름 시작일, 둘째 누름 종료일)과 그 아래 `시작 시간` · 바로 밑 `종료 시간`
  /// (`시간 없음` 또는 15분 단위). 날짜를 새로 고르고 그 시간이 비어 있으면 지금 이후의 가장 가까운 15분 단위
  /// ([todoDefaultTimeMinutes])로 채운다. 판은 바깥 · 칸 · Esc(안드로이드는 뒤로 가기)로 닫는다. 같은 날이면 시간으로
  /// 순서를 본다([checkTodoDraft] — 칸 아래 안내).
  Widget _periodField(BuildContext context, TodoDraftCheck check) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DateTimeRangeField(
          key: _periodKey,
          keyPrefix: 'todo',
          value: DateTimeRangeSelection(
            start: _start,
            end: _due,
            startMinutes: _startMinutes,
            endMinutes: _dueMinutes,
          ),
          enabled: !_submitting,
          placeholder: tr('기간을 선택하세요 (선택)'),
          defaultMinutes: todoDefaultTimeMinutes,
          formatPoint: formatTodoDay,
          formatClock: formatTodoClock,
          height: _fieldHeight,
          radius: _fieldRadius,
          borderColor: _fieldBorder(theme),
          onChanged: (v) => setState(() {
            _start = v.start;
            _due = v.end;
            _startMinutes = v.startMinutes;
            _dueMinutes = v.endMinutes;
            _serverError = null;
          }),
        ),
        if (check.periodError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              check.periodError!,
              key: const ValueKey('todo-period-error'),
              style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }

  /// 알림 — 테두리 선택 상자 `알림을 받아보세요 (선택) ▾`(누르면 상자 폭의 메뉴: 기한 하루 전 / 기한 1시간 전 / 직접
  /// 지정 — 기한이 있으면 앞의 둘에 울릴 시각을 함께 보인다), 그 아래 추가한 알림(한 줄에 하나, x로 지우기). 5개를 채우면 상자가 꺼진다. 메뉴는 창 전체(루트 Navigator,
  /// [todoPopupRouteName])에 띄운다 — 패널 안 화면에서 열어도 바깥(채팅 쪽)을 누르면 닫힌다(자리는 상자 바로 아래).
  Widget _reminderField(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final full = _reminders.length >= todoRemindersMaxCount;
    final enabled = !_submitting && !full;
    final textColor = enabled
        ? theme.colorScheme.onSurface
        : theme.disabledColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => PopupMenuButton<String>(
            key: const ValueKey('todo-reminder-add'),
            enabled: enabled,
            tooltip: tr('알림 추가'),
            useRootNavigator: true,
            routeSettings: todoPopupRouteSettings,
            position: PopupMenuPosition.under,
            offset: const Offset(0, 4),
            borderRadius: BorderRadius.circular(_fieldRadius),
            color: CompactMenu.color(context),
            shape: CompactMenu.shape,
            menuPadding: CompactMenu.menuPadding,
            // 선택 상자처럼 메뉴도 상자 폭 그대로.
            constraints: BoxConstraints.tightFor(width: constraints.maxWidth),
            onSelected: (v) {
              switch (v) {
                case 'day':
                  _addRelativeReminder(const Duration(days: 1));
                case 'hour':
                  _addRelativeReminder(const Duration(hours: 1));
                case 'custom':
                  unawaited(_addCustomReminder());
              }
            },
            itemBuilder: (context) => [
              for (final (value, label) in [
                (
                  'day',
                  _relativeReminderLabel(
                    tr('기한 하루 전'),
                    const Duration(days: 1),
                    tr('전날 오후 6시'),
                  ),
                ),
                (
                  'hour',
                  _relativeReminderLabel(
                    tr('기한 1시간 전'),
                    const Duration(hours: 1),
                    tr('기한일 오후 5시'),
                  ),
                ),
                ('custom', tr('직접 지정')),
              ])
                PopupMenuItem<String>(
                  key: ValueKey('todo-reminder-option-$value'),
                  value: value,
                  height: CompactMenu.itemHeight,
                  padding: CompactMenu.itemPadding,
                  child: Text(label, style: CompactMenu.textStyle),
                ),
            ],
            child: Container(
              height: _fieldHeight,
              // ▾ 자리를 대화방 칸의 ▾와 맞춘다(오른쪽 여백 12).
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                border: Border.all(
                  color: enabled
                      ? _fieldBorder(theme)
                      : _fieldBorder(theme).withValues(alpha: 0.6),
                ),
                borderRadius: BorderRadius.circular(_fieldRadius),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      full
                          ? tr('알림은 {todoRemindersMaxCount}개까지 추가할 수 있습니다.', {
                              'todoRemindersMaxCount': todoRemindersMaxCount,
                            })
                          : tr('알림을 받아보세요 (선택)'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: textColor,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.arrow_drop_down,
                    size: _iconSize,
                    color: enabled ? hint : theme.disabledColor,
                  ),
                ],
              ),
            ),
          ),
        ),
        for (var i = 0; i < _reminders.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              key: ValueKey('todo-reminder-$i'),
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(
                color: _softFill(theme),
                borderRadius: BorderRadius.circular(_fieldRadius),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      formatTodoDateTime(_reminders[i].at) +
                          (_reminders[i].sent ? tr(' (알림 보냄)') : ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: _reminders[i].sent ? hint : null,
                      ),
                    ),
                  ),
                  IconButton(
                    key: ValueKey('todo-reminder-remove-$i'),
                    icon: const Icon(Icons.close, size: 16),
                    tooltip: tr('알림 삭제'),
                    color: hint,
                    visualDensity: VisualDensity.compact,
                    onPressed: _submitting
                        ? null
                        : () => setState(() => _reminders.removeAt(i)),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 입력 한 줄 — 왼쪽 회색 아이콘(칸 이름표 대신 — 키 `todo-label-<id>`, 화면 읽기 프로그램에는 [label]) + 오른쪽 입력.
/// 아이콘은 한 줄짜리 칸(높이 [_fieldHeight])의 가운데 높이에 둔다(여러 줄인 설명 칸은 첫 줄 높이).
class _FieldRow extends StatelessWidget {
  final String id;
  final IconData icon;
  final String label;
  final Widget child;
  const _FieldRow({
    required this.id,
    required this.icon,
    required this.label,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: (_fieldHeight - _iconSize) / 2),
          child: Icon(
            icon,
            key: ValueKey('todo-label-$id'),
            size: _iconSize,
            color: _iconColor(Theme.of(context)),
            semanticLabel: label,
          ),
        ),
        const SizedBox(width: _iconGap),
        Expanded(child: child),
      ],
    );
  }
}

/// 첨부 한 줄 — 파일 아이콘 + 이름 + 크기(올리는 중이면 진행 막대, 실패하면 다시 시도), 오른쪽 x로 빼기.
/// 지정한 폴더 경로 한 줄 — 📁 경로(길면 말줄임, 마우스를 올리면 전체) + ✕(지우기).
class _FolderPathTile extends StatelessWidget {
  final String path;
  final VoidCallback? onClear;
  final Key clearKey;

  /// false면 지우기(✕)를 아예 보이지 않는다 — 경로를 바꿀 수 없는 담당자(보내는 중에 잠깐 끄는 [onClear] null과 구분).
  final bool editable;
  const _FolderPathTile({
    super.key,
    required this.path,
    required this.onClear,
    required this.clearKey,
    this.editable = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        border: Border.all(color: _fieldBorder(theme)),
        borderRadius: BorderRadius.circular(_fieldRadius),
      ),
      child: Row(
        children: [
          Icon(
            Icons.folder_outlined,
            size: 20,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Tooltip(
              message: path,
              child: Text(
                path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
          if (editable)
            IconButton(
              key: clearKey,
              tooltip: tr('경로 지우기'),
              icon: const Icon(Icons.close, size: 18),
              onPressed: onClear,
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  final _TodoFile file;
  final VoidCallback? onRemove;
  final VoidCallback onRetry;
  const _FileTile({
    super.key,
    required this.file,
    required this.onRemove,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final Widget status;
    if (file.error != null) {
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
    } else if (file.pending) {
      status = Row(
        children: [
          Text(
            formatFileSize(file.size),
            style: TextStyle(fontSize: 11, color: hint),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: LinearProgressIndicator(
              value: file.progress,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      );
    } else {
      status = Text(
        formatFileSize(file.size),
        style: TextStyle(fontSize: 11, color: hint),
      );
    }
    return Container(
      height: 52,
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(
          color: file.error != null
              ? theme.colorScheme.error
              : _fieldBorder(theme),
        ),
        borderRadius: BorderRadius.circular(_fieldRadius),
      ),
      child: Row(
        children: [
          Icon(
            fileIconFor(file.name),
            size: 22,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 3),
                status,
              ],
            ),
          ),
          if (onRemove != null)
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: tr('첨부 빼기'),
              color: hint,
              visualDensity: VisualDensity.compact,
              onPressed: onRemove,
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// 담당자 관리 — 이 대화방 멤버 목록에서 여러 명을 체크한다(이름 검색 포함, 30명까지).
class _AssigneePickerDialog extends StatefulWidget {
  final Session session;
  final List<AppUser> members;
  final List<AppUser> selected;
  const _AssigneePickerDialog({
    required this.session,
    required this.members,
    required this.selected,
  });

  @override
  State<_AssigneePickerDialog> createState() => _AssigneePickerDialogState();
}

class _AssigneePickerDialogState extends State<_AssigneePickerDialog> {
  late final Set<String> _ids = {for (final u in widget.selected) u.id};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final members = [
      for (final m in widget.members)
        if (q.isEmpty || m.name.toLowerCase().contains(q)) m,
    ]..sort((a, b) => a.name.compareTo(b.name));
    return AlertDialog(
      title: Text(tr('담당자 관리')),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: 360,
        height: 420,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                key: const ValueKey('todo-assignee-search'),
                decoration: InputDecoration(
                  hintText: tr('이름 검색'),
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 20),
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: ListView(
                children: [
                  for (final m in members)
                    CheckboxListTile(
                      key: ValueKey('todo-assignee-option-${m.id}'),
                      dense: true,
                      value: _ids.contains(m.id),
                      secondary: UserAvatar(
                        user: m,
                        resolveUrl: widget.session.resolveUrl,
                        radius: 14,
                      ),
                      title: Text(
                        m.id == widget.session.userId
                            ? tr('{m.name} (나)', {'m.name': m.name})
                            : m.name,
                      ),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          if (_ids.length >= todoAssigneesMaxCount) {
                            showAppToast(
                              context,
                              tr(
                                '담당자는 {todoAssigneesMaxCount}명까지 지정할 수 있습니다.',
                                {
                                  'todoAssigneesMaxCount':
                                      todoAssigneesMaxCount,
                                },
                              ),
                            );
                            return;
                          }
                          _ids.add(m.id);
                        } else {
                          _ids.remove(m.id);
                        }
                      }),
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
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('todo-assignee-ok'),
          onPressed: () => Navigator.of(context).pop([
            for (final m in widget.members)
              if (_ids.contains(m.id)) m,
          ]),
          child: Text(tr('확인 ({_ids.length})', {'_ids.length': _ids.length})),
        ),
      ],
    );
  }
}
