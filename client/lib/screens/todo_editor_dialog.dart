import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../models/todo.dart';
import '../services/api_client.dart' show UploadCancelToken;
import '../services/file_type_utils.dart';
import '../services/room_chat_controller.dart'
    show UploadedAttachment, uploadPlainFile;
import '../services/session.dart';
import '../services/todo_api.dart';
import '../widgets/app_toast.dart';
import '../widgets/attachment_widgets.dart' show formatFileSize;
import '../widgets/date_range_calendar_panel.dart';
import '../widgets/room_picker_field.dart';
import '../widgets/user_avatar.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'post_editor_dialog.dart' show fileIconFor;
import 'schedule_message_dialog.dart' show SchedulePicker;

/// 할 일 만들기·고치기 화면을 연다 — 넓은 창(PC)은 대화상자, 좁은 창(모바일)은 전체 화면. 저장했으면 서버가 돌려준
/// 할 일, 닫기만 했으면 null.
///
/// - [editing]을 주면 고치기다: 대화방은 잠기고(한 번 만든 할 일은 다른 방으로 옮길 수 없다), 담당자 칸은 만든 사람만
///   바꿀 수 있다(담당자는 읽기 전용 — `canManage`).
/// - [room]을 주면 그 방이 대화방 칸에 채워진다. [lockRoom]이면 못 바꾼다(메시지·댓글에서 "할 일로 등록"할 때).
/// - [initialTitle]·[initialDescription]·[initialAttachments]·[sourceMessageId]·[sourceCommentId]는 메시지·댓글에서
///   만들 때 미리 채우는 값이다(제목·설명은 고칠 수 있다).
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
  String? sourceMessageId,
  String? sourceCommentId,
  TodoApi? api,
}) async {
  final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  final editor = TodoEditor(
    session: session,
    room: room,
    lockRoom: lockRoom,
    editing: editing,
    initialTitle: initialTitle,
    initialDescription: initialDescription,
    initialAttachments: initialAttachments,
    sourceMessageId: sourceMessageId,
    sourceCommentId: sourceCommentId,
    api: api,
    asDialog: wide,
  );
  return wide
      ? await showDialog<Todo>(
          context: context,
          // 바깥을 잘못 눌러 쓰던 내용이 날아가지 않게 — 닫기는 취소·X(내용이 있으면 확인 후)로만.
          barrierDismissible: false,
          builder: (_) => editor,
        )
      : await Navigator.of(context).push<Todo>(
          MaterialPageRoute(fullscreenDialog: true, builder: (_) => editor),
        );
}

/// 붙인 파일 하나 — 붙이자마자 올리고, 저장할 때는 올라간 결과만 보낸다. 이미 서버에 있는 첨부(고치기·메시지에서
/// 만들기)는 처음부터 [result]가 있다.
class _TodoFile {
  _TodoFile.picked({
    required File this.file,
    required this.name,
    required this.size,
    required this.isImage,
  });

  _TodoFile.existing(UploadedAttachment this.result)
    : file = null,
      name = result.fileName,
      size = result.size,
      isImage = result.isImage;

  final File? file;
  final String name;
  final int size;
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

/// 할 일 만들기·고치기(대화상자/전체 화면 공용) — 대화방(맨 위), 제목(필수), 설명, 담당자(방 멤버 중 여러 명), 기한
/// (시작일~종료일), 파일 첨부(30개까지), 알림 일정(5개까지). 제목이 있고 입력이 서버 규칙 안일 때만 저장할 수 있다.
class TodoEditor extends StatefulWidget {
  final Session session;
  final Room? room;
  final bool lockRoom;
  final Todo? editing;
  final String? initialTitle;
  final String? initialDescription;
  final List<UploadedAttachment> initialAttachments;
  final String? sourceMessageId;
  final String? sourceCommentId;
  final TodoApi? api;
  final bool asDialog;

  const TodoEditor({
    super.key,
    required this.session,
    this.room,
    this.lockRoom = false,
    this.editing,
    this.initialTitle,
    this.initialDescription,
    this.initialAttachments = const [],
    this.sourceMessageId,
    this.sourceCommentId,
    this.api,
    this.asDialog = true,
  });

  @override
  State<TodoEditor> createState() => TodoEditorState();
}

class TodoEditorState extends State<TodoEditor> {
  late final TodoApi _api = widget.api ?? widget.session.todoApi;
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _files = <_TodoFile>[];
  final _reminders = <_ReminderDraft>[];
  List<AppUser> _assignees = [];
  DateTime? _start;
  DateTime? _due;
  late Room? _room;
  bool _submitting = false;
  String? _serverError;
  Completer<void>? _uploadsIdle;
  late final String _initialSnapshot;

  bool _periodOpen = false;
  final _periodPanelKey = GlobalKey();

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
      for (final a in widget.initialAttachments.take(todoAttachmentsMaxCount)) {
        _files.add(_TodoFile.existing(a));
      }
    }
    _title.addListener(_rebuild);
    _description.addListener(_rebuild);
    _initialSnapshot = _snapshot();
  }

  @override
  void dispose() {
    for (final f in _files) {
      f.removed = true;
      f.token.cancel();
    }
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() => _serverError = null);
  }

  /// 입력 상태를 한 줄로 — 닫을 때 "바뀐 게 있나" 비교용.
  String _snapshot() => [
    _room?.id,
    _title.text.trim(),
    _description.text.trim(),
    ..._assignees.map((a) => a.id),
    _start?.toIso8601String(),
    _due?.toIso8601String(),
    ..._files.map((f) => f.result?.url ?? f.name),
    ..._reminders.map((r) => '${r.id}@${r.at.millisecondsSinceEpoch}'),
  ].join('|');

  bool get _dirty => _snapshot() != _initialSnapshot;

  TodoDraftCheck get _check => checkTodoDraft(
    title: _title.text,
    description: _description.text,
    start: _start,
    due: _due,
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

  void _onRoomPicked(Room room) {
    final members = {for (final m in room.members) m.id};
    final dropped = _assignees.where((a) => !members.contains(a.id)).length;
    setState(() {
      _room = room;
      _serverError = null;
      _assignees = [
        for (final a in _assignees)
          if (members.contains(a.id)) a,
      ];
    });
    if (dropped > 0) {
      showAppToast(context, '이 대화방에 없는 담당자 $dropped명을 뺐습니다.');
    }
  }

  /// 담당자 고르기 — 이 대화방 멤버 중에서 여러 명.
  Future<void> _pickAssignees() async {
    final room = _room;
    if (room == null || !_canManageAssignees) return;
    final picked = await showDialog<List<AppUser>>(
      context: context,
      builder: (_) => _AssigneePickerDialog(
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

  static String _nameOf(File f) => f.path.split(RegExp(r'[\\/]')).last;

  static int _sizeOf(File f) {
    try {
      return f.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    final picked = [
      for (final f in result?.files ?? const <PlatformFile>[])
        if (f.path != null) File(f.path!),
    ];
    if (picked.isNotEmpty && mounted) addFiles(picked);
  }

  /// 파일을 목록에 더하고 바로 올리기 시작한다. 30개를 넘는 만큼은 빼고 알린다(테스트가 직접 부르기도 한다).
  void addFiles(List<File> files) {
    if (files.isEmpty || !mounted) return;
    final room = todoAttachmentsMaxCount - _files.length;
    final accepted = files.take(math.max(0, room)).toList();
    if (accepted.length < files.length) {
      showAppToast(context, '첨부 파일은 $todoAttachmentsMaxCount개까지 올릴 수 있습니다.');
    }
    if (accepted.isEmpty) return;
    setState(() {
      for (final f in accepted) {
        _files.add(
          _TodoFile.picked(
            file: f,
            name: _nameOf(f),
            size: _sizeOf(f),
            isImage: looksLikeImagePath(f.path),
          ),
        );
      }
    });
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
          showAppToast(context, "'${next.name}' 파일을 올리지 못했습니다: $e");
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

  // ── 알림 일정 ─────────────────────────────────────────────────────

  void _addReminder(DateTime at) {
    if (_reminders.length >= todoRemindersMaxCount) {
      showAppToast(context, '알림은 $todoRemindersMaxCount개까지 추가할 수 있습니다.');
      return;
    }
    if (!at.isAfter(DateTime.now())) {
      showAppToast(context, '이미 지난 시각에는 알림을 만들 수 없습니다.');
      return;
    }
    if (_reminders.any((r) => r.at == at)) {
      showAppToast(context, '같은 시각의 알림이 이미 있습니다.');
      return;
    }
    setState(() {
      _reminders.add(_ReminderDraft(at: at));
      _reminders.sort((a, b) => a.at.compareTo(b.at));
      _serverError = null;
    });
  }

  /// "기한 하루 전"·"기한 1시간 전" — 기한일 오후 6시를 기한 시각으로 본다. 기한이 없으면 안내만.
  void _addRelativeReminder(Duration before) {
    final due = _due;
    if (due == null) {
      showAppToast(context, '기한을 먼저 정하세요.');
      return;
    }
    _addReminder(todoReminderBeforeDue(due, before));
  }

  Future<void> _addCustomReminder() async {
    var value = ceilToScheduleSlot(
      DateTime.now().add(const Duration(hours: 1)),
    );
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('알림 시각'),
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
              child: const Text('취소'),
            ),
            FilledButton(
              key: const ValueKey('todo-reminder-custom-ok'),
              onPressed: () => Navigator.of(dialogContext).pop(value),
              child: const Text('추가'),
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
    setState(() {
      _submitting = true;
      _serverError = null;
    });
    try {
      final description = _description.text.trim();
      final attachments = [for (final f in _files) f.result!];
      final Todo saved;
      final editing = _editing;
      if (editing == null) {
        saved = await _api.create(
          _room!.id,
          title: _title.text.trim(),
          description: description.isEmpty ? null : description,
          assigneeIds: [for (final a in _assignees) a.id],
          startDate: _start == null ? null : todoDateWire(_start!),
          dueDate: _due == null ? null : todoDateWire(_due!),
          attachments: attachments,
          // 이미 지난 시각의 알림은 서버가 거절하므로 만들 때는 미래 것만 보낸다(추가할 때 이미 걸렀다).
          reminders: [for (final r in _reminders) r.at],
          sourceMessageId: widget.sourceMessageId,
          sourceCommentId: widget.sourceCommentId,
        );
      } else {
        saved = await _api.update(editing.id, _changedFields(editing));
      }
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      // 서버 문구 그대로(권한·기한 순서 등) — 입력은 그대로 두고 알린다.
      if (mounted) setState(() => _serverError = '$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

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
    if (reminderNow.join('|') != reminderBefore.join('|')) {
      fields['reminders'] = [
        for (final r in _reminders)
          {'id': ?r.id, 'remindAt': r.at.millisecondsSinceEpoch},
      ];
    }
    return fields;
  }

  Future<void> _requestClose() async {
    if (_submitting) return;
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('작성 취소'),
          content: Text(_isEdit ? '수정한 내용을 버리고 닫을까요?' : '작성 중인 할 일을 버리고 닫을까요?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(_isEdit ? '계속 수정' : '계속 쓰기'),
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
    Navigator.of(context).pop();
  }

  // ── 화면 ──────────────────────────────────────────────────────────

  String get _heading => _isEdit ? '할 일 수정' : '할 일 생성';

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: widget.asDialog ? _buildDialog(context) : _buildPage(context),
    );
  }

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
                  Icon(
                    Icons.checklist_rounded,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _heading,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    key: const ValueKey('todo-editor-close'),
                    icon: const Icon(Icons.close),
                    tooltip: '닫기',
                    onPressed: _submitting ? null : _requestClose,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _formChildren(context),
                ),
              ),
            ),
            const Divider(height: 1),
            _errorLine(context),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _submitting ? null : _requestClose,
                    child: const Text('취소'),
                  ),
                  const SizedBox(width: 8),
                  _submitButton(),
                ],
              ),
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
          key: const ValueKey('todo-editor-close'),
          icon: const Icon(Icons.close),
          tooltip: '취소',
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
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _formChildren(context),
                ),
              ),
            ),
            _errorLine(context),
          ],
        ),
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
          : Text(uploading ? '업로드 중' : (_isEdit ? '저장' : '만들기')),
    );
  }

  List<Widget> _formChildren(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final check = _check;
    return [
      const _SectionLabel('대화방'),
      if (_roomLocked)
        Container(
          key: const ValueKey('todo-room-locked'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.5,
            ),
            border: Border.all(color: theme.dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _room?.displayName(widget.session.userId ?? '') ??
                      _editing?.roomName ??
                      '대화방',
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
            child: RoomPickerField(
              session: widget.session,
              value: _room,
              filter: widget.session.canCreateTodoIn,
              onChanged: _onRoomPicked,
            ),
          ),
        ),
      if (_isEdit)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '한 번 만든 할 일은 다른 대화방으로 옮길 수 없습니다.',
            style: TextStyle(fontSize: 12, color: hint),
          ),
        ),
      const SizedBox(height: 16),
      const _SectionLabel('제목'),
      TextField(
        key: const ValueKey('todo-title-field'),
        controller: _title,
        enabled: !_submitting,
        autofocus: _room != null && _title.text.isEmpty,
        maxLength: todoTitleMaxLength,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(
          hintText: '할 일 제목을 입력하세요',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 8),
      const _SectionLabel('설명'),
      TextField(
        key: const ValueKey('todo-description-field'),
        controller: _description,
        enabled: !_submitting,
        maxLength: todoDescriptionMaxLength,
        minLines: 3,
        maxLines: 8,
        decoration: InputDecoration(
          hintText: '설명을 입력하세요 (선택)',
          border: const OutlineInputBorder(),
          errorText: check.descriptionError,
        ),
      ),
      const SizedBox(height: 8),
      _SectionLabel(
        '담당자',
        trailing: '${_assignees.length}/$todoAssigneesMaxCount',
      ),
      _assigneeField(context),
      const SizedBox(height: 16),
      const _SectionLabel('기한'),
      _periodField(context),
      if (check.periodError != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            check.periodError!,
            style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
          ),
        ),
      const SizedBox(height: 16),
      _SectionLabel(
        '파일 첨부',
        trailing: '${_files.length}/$todoAttachmentsMaxCount',
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const ValueKey('todo-attach'),
          onPressed: _submitting || _files.length >= todoAttachmentsMaxCount
              ? null
              : _pickFiles,
          icon: const Icon(Icons.attach_file, size: 18),
          label: const Text('파일 첨부'),
          style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
        ),
      ),
      if (_files.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final f in _files)
                _FileTile(
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
            ],
          ),
        ),
      const SizedBox(height: 16),
      _SectionLabel(
        '알림 일정',
        trailing: '${_reminders.length}/$todoRemindersMaxCount',
      ),
      _reminderSection(context),
    ];
  }

  Widget _assigneeField(BuildContext context) {
    final theme = Theme.of(context);
    final readOnly = !_canManageAssignees;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_assignees.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final a in _assignees)
                InputChip(
                  key: ValueKey('todo-assignee-chip-${a.id}'),
                  avatar: UserAvatar(
                    user: a,
                    resolveUrl: widget.session.resolveUrl,
                    radius: 10,
                  ),
                  label: Text(a.name),
                  visualDensity: VisualDensity.compact,
                  onDeleted: readOnly || _submitting
                      ? null
                      : () => setState(() => _assignees.remove(a)),
                ),
            ],
          )
        else
          Text(
            readOnly ? '담당자가 없습니다.' : '담당자를 지정하지 않았습니다.',
            style: TextStyle(fontSize: 13, color: theme.hintColor),
          ),
        if (!readOnly)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('todo-assignee-add'),
              onPressed: _submitting || _room == null ? null : _pickAssignees,
              icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
              label: Text(_room == null ? '대화방을 먼저 고르세요' : '담당자 선택'),
            ),
          )
        else
          Text(
            '담당자는 만든 사람만 바꿀 수 있습니다.',
            style: TextStyle(fontSize: 12, color: theme.hintColor),
          ),
      ],
    );
  }

  /// 기한 — 칸을 누르면 그 아래로 달력이 펼쳐지고 시작일 → 종료일 차례로 고른다(프로젝트 "새 업무"의 기간 달력과 같다).
  /// 띄우는 팝업이 아니라 폼 안에 펼치는 이유: 이 칸은 폼 아래쪽이라 팝업은 창 밖으로 잘리기 쉽다(모바일 전체 화면도 같다).
  Widget _periodField(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    Widget dateText(DateTime? value, String placeholder) => Text(
      value == null ? placeholder : formatTodoDate(value),
      style: TextStyle(fontSize: 14, color: value == null ? hint : null),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: const ValueKey('todo-period-field'),
          borderRadius: BorderRadius.circular(8),
          onTap: _submitting ? null : _togglePeriod,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(
                color: _periodOpen
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).dividerColor,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.calendar_today_outlined, size: 16, color: hint),
                const SizedBox(width: 8),
                dateText(_start, '시작일'),
                Text('  ~  ', style: TextStyle(color: hint)),
                dateText(_due, '종료일'),
                const Spacer(),
                if (_start != null || _due != null)
                  IconButton(
                    key: const ValueKey('todo-period-clear'),
                    icon: const Icon(Icons.close, size: 16),
                    tooltip: '기한 지우기',
                    visualDensity: VisualDensity.compact,
                    onPressed: _submitting
                        ? null
                        : () => setState(() {
                            _start = null;
                            _due = null;
                          }),
                  ),
              ],
            ),
          ),
        ),
        if (_periodOpen)
          Container(
            key: _periodPanelKey,
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _start == null || _due != null ? '시작일을 선택하세요' : '종료일을 선택하세요',
                  style: TextStyle(color: hint, fontSize: 12),
                ),
                const SizedBox(height: 6),
                DateRangeCalendarPanel(
                  start: _start,
                  end: _due,
                  onChanged: (start, end) {
                    setState(() {
                      _start = start;
                      _due = end;
                      _serverError = null;
                      // 종료일까지 골랐으면 더 볼 게 없으니 접는다.
                      if (end != null) _periodOpen = false;
                    });
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }

  void _togglePeriod() {
    setState(() => _periodOpen = !_periodOpen);
    if (!_periodOpen) return;
    // 펼친 달력이 화면 밖이면 보이는 곳까지 스크롤한다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _periodPanelKey.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 150),
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      }
    });
  }

  Widget _reminderSection(BuildContext context) {
    final theme = Theme.of(context);
    final full = _reminders.length >= todoRemindersMaxCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _reminders.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              key: ValueKey('todo-reminder-$i'),
              children: [
                Icon(
                  Icons.notifications_active_outlined,
                  size: 16,
                  color: theme.hintColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    formatTodoDateTime(_reminders[i].at) +
                        (_reminders[i].sent ? ' (알림 보냄)' : ''),
                    style: TextStyle(
                      fontSize: 14,
                      color: _reminders[i].sent ? theme.hintColor : null,
                    ),
                  ),
                ),
                IconButton(
                  key: ValueKey('todo-reminder-remove-$i'),
                  icon: const Icon(Icons.remove_circle_outline, size: 18),
                  tooltip: '알림 삭제',
                  visualDensity: VisualDensity.compact,
                  onPressed: _submitting
                      ? null
                      : () => setState(() => _reminders.removeAt(i)),
                ),
              ],
            ),
          ),
        PopupMenuButton<String>(
          key: const ValueKey('todo-reminder-add'),
          enabled: !_submitting && !full,
          tooltip: '알림 추가',
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
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'day', child: Text('기한 하루 전 (전날 오후 6시)')),
            PopupMenuItem(value: 'hour', child: Text('기한 1시간 전 (기한일 오후 5시)')),
            PopupMenuItem(value: 'custom', child: Text('직접 지정')),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.add,
                  size: 18,
                  color: full ? theme.disabledColor : theme.colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  '알림 추가',
                  style: TextStyle(
                    color: full
                        ? theme.disabledColor
                        : theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final String? trailing;
  const _SectionLabel(this.text, {this.trailing});

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
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Text(trailing!, style: TextStyle(fontSize: 12, color: hint)),
          ],
        ],
      ),
    );
  }
}

/// 첨부 한 개 — 아이콘 + 이름 + 크기(올리는 중이면 진행 막대), 오른쪽 위 x로 빼기.
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
          '올리지 못함 · 다시 시도',
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
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 220,
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border.all(
              color: file.error != null
                  ? theme.colorScheme.error
                  : theme.dividerColor,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(
                fileIconFor(file.name),
                size: 24,
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
                    const SizedBox(height: 4),
                    status,
                  ],
                ),
              ),
            ],
          ),
        ),
        if (onRemove != null)
          Positioned(
            top: -6,
            right: -6,
            child: Tooltip(
              message: '첨부 빼기',
              child: GestureDetector(
                onTap: onRemove,
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
            ),
          ),
      ],
    );
  }
}

/// 담당자 고르기 — 이 대화방 멤버 목록에서 여러 명을 체크한다(이름 검색 포함, 30명까지).
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
      title: const Text('담당자 선택'),
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
                decoration: const InputDecoration(
                  hintText: '이름 검색',
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
                            ? '${m.name} (나)'
                            : m.name,
                      ),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          if (_ids.length >= todoAssigneesMaxCount) {
                            showAppToast(
                              context,
                              '담당자는 $todoAssigneesMaxCount명까지 지정할 수 있습니다.',
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
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('todo-assignee-ok'),
          onPressed: () => Navigator.of(context).pop([
            for (final m in widget.members)
              if (_ids.contains(m.id)) m,
          ]),
          child: Text('확인 (${_ids.length})'),
        ),
      ],
    );
  }
}
