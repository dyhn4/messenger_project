import 'dart:async';
import 'dart:math' as math;

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/poll.dart';
import '../models/room.dart';
import '../services/api_client.dart' show UploadCancelToken;
import '../services/file_type_utils.dart';
import '../services/room_chat_controller.dart'
    show UploadedAttachment, uploadPlainFile;
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/attachment_widgets.dart' show formatFileSize;
import '../widgets/room_picker_field.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'post_editor_dialog.dart' show fileIconFor;
import 'schedule_message_dialog.dart' show ScheduleDateTimeField;
import '../l10n/tr.dart';

/// 투표를 만들 수 있는 방인지 — 비밀 대화에서는 못 만든다(서버가 400으로 막는다). 읽기 전용·보관된
/// 토픽은 토픽 관리자만 글을 쓸 수 있으니 투표도 같다. 입력칸 옆 "투표" 단추와 보드의 단추가 같이 쓴다.
bool canCreatePollIn(Session session, Room room) =>
    !room.isSecret && room.canWrite(session);

/// 투표 만들기 화면을 연다 — 넓은 창(PC)은 대화상자, 좁은 창(모바일)은 전체 화면. 만들었으면 true.
/// [room]을 주면(입력창 도구모음의 "투표"·보드) 그 방이 대화방 칸에 미리 채워지고(바꿀 수도 있다),
/// 안 주면(메뉴의 "투표") 칸이 비어 있어 방을 골라야 만들 수 있다.
Future<bool> showPollCreator(
  BuildContext context, {
  required Session session,
  Room? room,
}) async {
  final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  final creator = PollCreator(session: session, room: room, asDialog: wide);
  final created = wide
      ? await showDialog<bool>(
          context: context,
          // 바깥을 잘못 눌러 쓰던 내용이 날아가지 않게 — 닫기는 취소·X(내용이 있으면 확인 후)로만.
          barrierDismissible: false,
          builder: (_) => creator,
        )
      : await Navigator.of(context).push<bool>(
          MaterialPageRoute(fullscreenDialog: true, builder: (_) => creator),
        );
  return created ?? false;
}

/// 붙인 파일 하나 — 붙이자마자 올리고(보드 토픽만), 만들 때는 올라간 결과만 보낸다.
class _PollFile {
  _PollFile({
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

/// 투표 만들기(대화상자/전체 화면 공용) — 제목, 보기(2~20개), 마감 시각(필수·15분 단위·90일 안), 옵션
/// (자세한 설명·익명 투표·복수 선택), 보드 뷰 토픽이면 파일 첨부(30개까지). 필수 항목이 다 찼을 때만
/// 만들 수 있고, 만든 투표는 고칠 수 없다는 안내를 붙인다.
class PollCreator extends StatefulWidget {
  final Session session;

  /// 처음에 채워 둘 대화방 — 없으면 맨 위 "대화방" 칸에서 골라야 한다.
  final Room? room;
  final bool asDialog;

  const PollCreator({
    super.key,
    required this.session,
    this.room,
    this.asDialog = true,
  });

  @override
  State<PollCreator> createState() => PollCreatorState();
}

class PollCreatorState extends State<PollCreator> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _options = <TextEditingController>[];
  final _optionFocus = <FocusNode>[];
  final _files = <_PollFile>[];

  bool _showDescription = false;
  bool _anonymous = false;
  bool _multiple = false;
  late DateTime _closesAt = ceilToScheduleSlot(
    DateTime.now().add(const Duration(days: 1)),
  );
  bool _submitting = false;
  String? _serverError;
  Completer<void>? _uploadsIdle;

  /// 투표가 올라갈 대화방 — 맨 위 "대화방" 칸의 값.
  late Room? _room = widget.room;

  bool get _isBoard => _room?.isBoard ?? false;

  /// 대화방 칸에서 고를 수 있는 방 — 내가 이 팀에서 참여 중이고 투표를 올릴 수 있는 방(비밀 대화·
  /// 읽기 전용/보관된 토픽(관리자 제외)은 빠진다).
  bool _pickable(Room r) => canCreatePollIn(widget.session, r);

  /// 방을 바꿨을 때 — 보드 토픽이 아니게 되면 붙여 둔 첨부는 쓸 수 없으니 치우고 알린다.
  void _onRoomPicked(Room room) {
    final hadFiles = _files.isNotEmpty;
    setState(() {
      _room = room;
      _serverError = null;
      if (!room.isBoard && hadFiles) {
        for (final f in _files) {
          f.removed = true;
          f.token.cancel();
        }
        _files.clear();
      }
    });
    if (hadFiles && !room.isBoard) {
      showAppToast(context, tr('보드 토픽이 아니라서 붙인 파일을 뺐습니다.'));
    }
  }

  @override
  void initState() {
    super.initState();
    _title.addListener(_rebuild);
    _description.addListener(_rebuild);
    for (var i = 0; i < pollOptionsMinCount; i++) {
      _addOptionField();
    }
  }

  @override
  void dispose() {
    for (final f in _files) {
      f.removed = true;
      f.token.cancel();
    }
    _title.dispose();
    _description.dispose();
    for (final c in _options) {
      c.dispose();
    }
    for (final f in _optionFocus) {
      f.dispose();
    }
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() => _serverError = null);
  }

  void _addOptionField() {
    final c = TextEditingController()..addListener(_rebuild);
    _options.add(c);
    _optionFocus.add(FocusNode());
  }

  void _addOption() {
    if (_options.length >= pollOptionsMaxCount) return;
    setState(_addOptionField);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _optionFocus.last.requestFocus();
    });
  }

  void _removeOption(int index) {
    if (_options.length <= pollOptionsMinCount) return;
    setState(() {
      _options.removeAt(index).dispose();
      _optionFocus.removeAt(index).dispose();
    });
  }

  PollDraftCheck get _check => checkPollDraft(
    title: _title.text,
    options: [for (final c in _options) c.text],
    closesAt: _closesAt,
  );

  /// 첨부가 아직 올라가는 중인지 — 테스트가 업로드가 끝나기를 기다릴 때 쓴다.
  bool get debugUploading => _uploadsIdle != null;

  bool get _hasPendingUpload => _files.any((f) => f.pending);
  bool get _hasFailedUpload => _files.any((f) => f.error != null);

  /// 서버가 받아 줄 입력이 다 찼는지 — 만들기 단추를 켜는 조건.
  bool get canSubmit =>
      !_submitting &&
      _room != null &&
      _check.ok &&
      !_hasPendingUpload &&
      !_hasFailedUpload &&
      _description.text.characters.length <= pollDescriptionMaxLength;

  bool get _dirty =>
      _title.text.trim().isNotEmpty ||
      _description.text.trim().isNotEmpty ||
      _options.any((c) => c.text.trim().isNotEmpty) ||
      _files.isNotEmpty;

  // ── 첨부 ──────────────────────────────────────────────────────────

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
    if (!_isBoard || files.isEmpty || !mounted) return;
    final room = pollAttachmentsMaxCount - _files.length;
    final accepted = files.take(math.max(0, room)).toList();
    if (accepted.length < files.length) {
      showAppToast(
        context,
        tr('첨부 파일은 {pollAttachmentsMaxCount}개까지 올릴 수 있습니다.', {
          'pollAttachmentsMaxCount': pollAttachmentsMaxCount,
        }),
      );
    }
    if (accepted.isEmpty) return;
    final added = [
      for (final f in accepted)
        _PollFile(
          file: f,
          name: f.name,
          size: 0,
          isImage: looksLikeImagePath(f.name),
        ),
    ];
    setState(() => _files.addAll(added));
    for (final p in added) {
      unawaited(
        p.file.length().then((n) {
          if (mounted) setState(() => p.size = n);
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
            next.file,
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
      idle.complete();
    }
  }

  void _removeFile(_PollFile f) {
    f.removed = true;
    f.token.cancel();
    setState(() => _files.remove(f));
  }

  // ── 만들기·닫기 ───────────────────────────────────────────────────

  Future<void> _submit() async {
    if (!canSubmit) return;
    setState(() {
      _submitting = true;
      _serverError = null;
    });
    try {
      await widget.session.createPoll(
        _room!,
        title: _title.text,
        description: _showDescription ? _description.text : null,
        options: [for (final c in _options) c.text],
        anonymous: _anonymous,
        multiple: _multiple,
        closesAt: _closesAt,
        attachments: [for (final f in _files) f.result!],
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      // 서버 문구 그대로(비밀 대화·읽기 전용·마감 시각 범위 등) — 입력은 그대로 두고 알린다.
      if (mounted) setState(() => _serverError = '$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _requestClose() async {
    if (_submitting) return;
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(tr('작성 취소')),
          content: Text(tr('작성 중인 투표를 버리고 닫을까요?')),
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
    Navigator.of(context).pop(false);
  }

  // ── 화면 ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final editor = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: widget.asDialog ? _buildDialog(context) : _buildPage(context),
    );
    return editor;
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
                  Icon(Icons.poll_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Text(
                    tr('투표 만들기'),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    key: const ValueKey('poll-create-close'),
                    icon: const Icon(Icons.close),
                    tooltip: tr('닫기'),
                    onPressed: _submitting ? null : _requestClose,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                children: _formChildren(context),
              ),
            ),
            const Divider(height: 1),
            _bottomNotes(context),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _submitting ? null : _requestClose,
                    child: Text(tr('취소')),
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
          icon: const Icon(Icons.close),
          tooltip: tr('취소'),
          onPressed: _submitting ? null : _requestClose,
        ),
        title: Text(tr('투표 만들기')),
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
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: _formChildren(context),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _bottomNotes(context),
            ),
          ],
        ),
      ),
    );
  }

  /// 목록 아래에 늘 보이는 안내 — 수정할 수 없다는 안내(만들기를 누르기 전에 꼭 보이게)와 서버가 거절한
  /// 문구. 폼이 길어서 스크롤 안에 두면 아래로 밀려 안 보인다.
  Widget _bottomNotes(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_serverError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                _serverError!,
                key: const ValueKey('poll-create-error'),
                style: TextStyle(fontSize: 13, color: theme.colorScheme.error),
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.6,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 16, color: hint),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tr('투표는 만든 뒤에 수정할 수 없습니다. 마감하거나 삭제만 할 수 있어요.'),
                    key: const ValueKey('poll-no-edit-notice'),
                    style: TextStyle(fontSize: 12, color: hint),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _submitButton() {
    final uploading = _hasPendingUpload;
    return FilledButton(
      key: const ValueKey('poll-create-submit'),
      onPressed: canSubmit ? _submit : null,
      child: _submitting
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(uploading ? tr('업로드 중') : tr('만들기')),
    );
  }

  List<Widget> _formChildren(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final check = _check;
    final filled = _options.where((c) => c.text.trim().isNotEmpty).length;
    return [
      // 어느 대화방에 올라가는지 — 투표는 그 방의 모든 멤버가 함께 본다. 입력창의 "투표"로 열었으면
      // 그 방이 미리 채워져 있고(바꿀 수 있다), 메뉴의 "투표"로 열었으면 비어 있다.
      _SectionLabel(tr('대화방')),
      KeyedSubtree(
        key: const ValueKey('poll-room-field'),
        child: IgnorePointer(
          ignoring: _submitting,
          child: RoomPickerField(
            session: widget.session,
            value: _room,
            filter: _pickable,
            onChanged: _onRoomPicked,
          ),
        ),
      ),
      const SizedBox(height: 16),
      _SectionLabel(tr('투표 제목')),
      TextField(
        key: const ValueKey('poll-title-field'),
        controller: _title,
        enabled: !_submitting,
        autofocus: _room != null,
        maxLength: pollTitleMaxLength,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          hintText: tr('투표 제목을 입력하세요'),
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 8),
      _SectionLabel(
        tr('보기'),
        trailing: '${_options.length}/$pollOptionsMaxCount',
      ),
      for (var i = 0; i < _options.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  key: ValueKey('poll-option-field-$i'),
                  controller: _options[i],
                  focusNode: _optionFocus[i],
                  enabled: !_submitting,
                  maxLength: pollOptionMaxLength,
                  buildCounter:
                      (
                        _, {
                        required currentLength,
                        required isFocused,
                        maxLength,
                      }) => null,
                  textInputAction: i == _options.length - 1
                      ? TextInputAction.done
                      : TextInputAction.next,
                  decoration: InputDecoration(
                    hintText: tr('보기 {p0}', {'p0': i + 1}),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    border: const OutlineInputBorder(),
                    errorText: i < check.optionErrors.length
                        ? check.optionErrors[i]
                        : null,
                  ),
                ),
              ),
              SizedBox(
                width: 40,
                child: _options.length > pollOptionsMinCount
                    ? IconButton(
                        key: ValueKey('poll-option-remove-$i'),
                        icon: const Icon(Icons.remove_circle_outline),
                        tooltip: tr('보기 삭제'),
                        visualDensity: VisualDensity.compact,
                        onPressed: _submitting ? null : () => _removeOption(i),
                      )
                    : null,
              ),
            ],
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('poll-add-option'),
          onPressed: _submitting || _options.length >= pollOptionsMaxCount
              ? null
              : _addOption,
          icon: const Icon(Icons.add, size: 18),
          label: Text(tr('보기 추가')),
        ),
      ),
      if (filled < pollOptionsMinCount)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            tr('보기를 {pollOptionsMinCount}개 이상 입력하세요.', {
              'pollOptionsMinCount': pollOptionsMinCount,
            }),
            style: TextStyle(fontSize: 12, color: hint),
          ),
        ),
      const SizedBox(height: 8),
      _SectionLabel(tr('마감 시각')),
      ScheduleDateTimeField(
        value: _closesAt,
        enabled: !_submitting,
        onChanged: (v) => setState(() {
          _closesAt = v;
          _serverError = null;
        }),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          check.closesAtError ??
              tr('지금부터 최대 {scheduledMaxDaysAhead}일 안에서 15분 단위로 고를 수 있습니다.', {
                'scheduledMaxDaysAhead': scheduledMaxDaysAhead,
              }),
          key: const ValueKey('poll-closes-hint'),
          style: TextStyle(
            fontSize: 12,
            color: check.closesAtError != null ? theme.colorScheme.error : hint,
          ),
        ),
      ),
      const SizedBox(height: 12),
      _SectionLabel(tr('옵션')),
      SwitchListTile(
        key: const ValueKey('poll-description-switch'),
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(tr('자세한 설명')),
        value: _showDescription,
        onChanged: _submitting
            ? null
            : (v) => setState(() => _showDescription = v),
      ),
      if (_showDescription)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            key: const ValueKey('poll-description-field'),
            controller: _description,
            enabled: !_submitting,
            maxLength: pollDescriptionMaxLength,
            minLines: 3,
            maxLines: 6,
            decoration: InputDecoration(
              hintText: tr('투표에 대한 자세한 설명을 입력하세요'),
              border: OutlineInputBorder(),
            ),
          ),
        ),
      SwitchListTile(
        key: const ValueKey('poll-anonymous-switch'),
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(tr('익명 투표')),
        subtitle: Text(tr('누가 어떤 보기에 투표했는지 볼 수 없습니다.')),
        value: _anonymous,
        onChanged: _submitting ? null : (v) => setState(() => _anonymous = v),
      ),
      SwitchListTile(
        key: const ValueKey('poll-multiple-switch'),
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(tr('복수 선택')),
        subtitle: Text(tr('보기를 여러 개 고를 수 있습니다.')),
        value: _multiple,
        onChanged: _submitting ? null : (v) => setState(() => _multiple = v),
      ),
      if (_isBoard) ...[
        const SizedBox(height: 8),
        _SectionLabel(
          tr('첨부 파일'),
          trailing: '${_files.length}/$pollAttachmentsMaxCount',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('poll-attach'),
            onPressed: _submitting ? null : _pickFiles,
            icon: const Icon(Icons.attach_file, size: 18),
            label: Text(tr('파일 첨부')),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
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
      ],
    ];
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
  final _PollFile file;
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
              message: tr('첨부 빼기'),
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
