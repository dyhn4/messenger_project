import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/announcement.dart';
import '../models/room.dart';
import '../services/session.dart';
import '../widgets/app_toast.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'post_editor_dialog.dart' show TopicChip;

/// 공지 본문 글자 수 한도 — 서버(announcements.js)와 같다.
const announcementTextMaxLength = 2000;

/// 한도에 이만큼 가까워지면 입력칸 아래에 "n/2000"을 보여준다(평소엔 숨김 — 게시글 작성창과 같다).
const _counterFrom = announcementTextMaxLength * 9 ~/ 10;

/// 공지 작성 창이 넘겨주는 값 — 글과 "자동 내리기"까지 남은 기간(null이면 자동 내리기 없음, 기본값).
class AnnouncementDraft {
  final String text;
  final Duration? autoUnpinAfter;
  const AnnouncementDraft(this.text, this.autoUnpinAfter);
}

/// 공지 쓰기([announcement]가 없을 때)·수정 창을 연다 — 게시글 작성창(post_editor_dialog.dart)과 같은 틀로,
/// 넓은 창(PC)은 대화상자, 좁은 창(모바일)은 전체 화면이다. 게시글과 달리 **제목 입력칸이 없다**(공지는 글
/// 한 덩어리). [onSubmit]이 등록/저장을 맡는다 — 실패하면 던진 오류를 토스트로 알리고 창과 쓰던 글을 그대로
/// 둔다. 등록(저장)했으면 true.
Future<bool> showAnnouncementEditor(
  BuildContext context, {
  required Session session,
  required Room room,
  Announcement? announcement,
  required Future<void> Function(AnnouncementDraft draft) onSubmit,
}) async {
  final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  final editor = AnnouncementEditor(
    session: session,
    room: room,
    announcement: announcement,
    onSubmit: onSubmit,
    asDialog: wide,
  );
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
}

class AnnouncementEditor extends StatefulWidget {
  final Session session;
  final Room room;

  /// 고칠 공지(없으면 새 공지).
  final Announcement? announcement;
  final Future<void> Function(AnnouncementDraft draft) onSubmit;
  final bool asDialog;

  const AnnouncementEditor({
    super.key,
    required this.session,
    required this.room,
    this.announcement,
    required this.onSubmit,
    this.asDialog = true,
  });

  @override
  State<AnnouncementEditor> createState() => _AnnouncementEditorState();
}

class _AnnouncementEditorState extends State<AnnouncementEditor> {
  late final _controller = TextEditingController(
    text: widget.announcement?.text ?? '',
  );
  final _focus = FocusNode(debugLabel: 'announcement-body');
  String? _error;
  String _lastText = '';
  bool _submitting = false;
  Duration? _autoUnpinAfter;
  // "지정"으로 고른 값인지 — 빠른 선택지와 우연히 같은 길이(예: 24시간=1일)를 골라도 칩 표시가
  // 헷갈리지 않도록 별도로 구분한다.
  bool _isCustom = false;

  static const _quickOptions = <(String, Duration?)>[
    ('없음', null),
    ('1시간', Duration(hours: 1)),
    ('4시간', Duration(hours: 4)),
    ('9시간', Duration(hours: 9)),
    ('1일', Duration(days: 1)),
    ('7일', Duration(days: 7)),
    ('30일', Duration(days: 30)),
  ];

  bool get _editing => widget.announcement != null;

  @override
  void initState() {
    super.initState();
    _lastText = _controller.text;
    _controller.addListener(_onTextChanged);
    _focus.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (_controller.text == _lastText) return;
    _lastText = _controller.text;
    if (_error != null) setState(() => _error = null);
  }

  bool get _dirty {
    final original = widget.announcement?.text;
    if (original != null) return _controller.text != original;
    return _controller.text.trim().isNotEmpty;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final text = _controller.text.trim();
    // 사진 공지는 글 없이 사진만 둘 수 있다(서버도 같은 규칙).
    final allowEmpty = widget.announcement?.hasImage ?? false;
    if (text.isEmpty && !allowEmpty) {
      setState(() => _error = '내용을 입력하세요.');
      _focus.requestFocus();
      return;
    }
    setState(() => _submitting = true);
    try {
      await widget.onSubmit(AnnouncementDraft(text, _autoUnpinAfter));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 취소·Esc·뒤로 가기 — 쓰던 내용이 있으면 한 번 묻는다.
  Future<void> _requestClose() async {
    if (_submitting) return;
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(_editing ? '수정 취소' : '작성 취소'),
          content: Text(
            _editing ? '고친 내용을 저장하지 않고 닫을까요?' : '작성 중인 공지를 버리고 닫을까요?',
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
    Navigator.of(context).pop(false);
  }

  void _selectQuick(Duration? duration) {
    setState(() {
      _autoUnpinAfter = duration;
      _isCustom = false;
    });
  }

  Future<void> _pickCustom() async {
    final result = await showDialog<Duration>(
      context: context,
      builder: (_) => const _CustomAutoUnpinDialog(),
    );
    if (result == null || !mounted) return;
    setState(() {
      _autoUnpinAfter = result;
      _isCustom = true;
    });
  }

  String _customChipLabel() {
    final d = _autoUnpinAfter;
    if (!_isCustom || d == null) return '지정';
    final days = d.inDays;
    final hours = d.inHours % 24;
    if (days > 0 && hours > 0) return '지정 ($days일 $hours시간)';
    if (days > 0) return '지정 ($days일)';
    return '지정 ($hours시간)';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
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
  }

  Widget _buildDialog(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: math.min(760, screen.width - 48),
        height: math.min(640, screen.height - 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context),
            const Divider(height: 1),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _buildBodyField(context)),
                    _buildBodyFooter(context),
                    if (!_editing) ...[
                      const SizedBox(height: 10),
                      _buildAutoUnpin(context),
                    ],
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            _buildFooter(context),
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
          tooltip: '취소',
          onPressed: _requestClose,
        ),
        title: Text(_editing ? '공지 수정' : '공지 쓰기'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _buildSubmitButton(context),
          ),
        ],
      ),
      body: SafeArea(
        // 휴대폰은 키보드가 화면 절반쯤을 가려서, 본문 칸은 내용만큼(최소 여러 줄) 키우고 화면 전체를
        // 스크롤한다(게시글 작성 전체 화면과 같다).
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TopicChip(session: widget.session, room: widget.room),
            ),
            const SizedBox(height: 12),
            _buildBodyField(context, expand: false),
            _buildBodyFooter(context),
            if (!_editing) ...[
              const SizedBox(height: 10),
              _buildAutoUnpin(context),
            ],
          ],
        ),
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
            _editing ? Icons.edit_note : Icons.campaign_outlined,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Text(
            _editing ? '공지 수정' : '공지 쓰기',
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
            tooltip: '닫기',
            onPressed: _submitting ? null : _requestClose,
          ),
        ],
      ),
    );
  }

  /// 여러 줄 본문 — 게시글 작성창의 본문 칸과 같은 테두리·글꼴(서식 도구줄만 뺀다 — 공지는 평문이다).
  Widget _buildBodyField(BuildContext context, {bool expand = true}) {
    final theme = Theme.of(context);
    final focused = _focus.hasFocus;
    final hasError = _error != null;
    const radius = BorderRadius.all(Radius.circular(8));
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
        child: TextField(
          key: const ValueKey('announcement-body'),
          controller: _controller,
          focusNode: _focus,
          autofocus: true,
          enabled: !_submitting,
          expands: expand,
          minLines: expand ? null : 8,
          maxLines: null,
          maxLength: announcementTextMaxLength,
          // 기본 글자 수 표시는 끄고(아래 _buildBodyFooter가 한도 근처에서만 보여준다).
          buildCounter:
              (
                _, {
                required currentLength,
                required isFocused,
                required maxLength,
              }) => null,
          keyboardType: TextInputType.multiline,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(fontSize: 14.5, height: 1.5),
          decoration: const InputDecoration(
            hintText: '공지 내용을 입력하세요',
            border: InputBorder.none,
            contentPadding: EdgeInsets.all(14),
          ),
        ),
      ),
    );
  }

  /// 본문 아래 줄 — 왼쪽은 입력 오류, 오른쪽은 한도에 가까워졌을 때만 글자 수.
  Widget _buildBodyFooter(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) {
        final length = value.text.characters.length;
        final showCounter = length >= _counterFrom;
        if (_error == null && !showCounter) return const SizedBox(height: 6);
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _error ?? '',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
              if (showCounter)
                Text(
                  '$length/$announcementTextMaxLength',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: theme.hintColor,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// "공지 자동 내리기" 빠른 선택 — 새 공지에서만(서버가 수정에서는 글만 바꾼다).
  Widget _buildAutoUnpin(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '공지 자동 내리기',
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (label, duration) in _quickOptions)
              ChoiceChip(
                label: Text(label),
                selected: !_isCustom && _autoUnpinAfter == duration,
                onSelected: _submitting ? null : (_) => _selectQuick(duration),
              ),
            ChoiceChip(
              label: Text(_customChipLabel()),
              selected: _isCustom,
              onSelected: _submitting ? null : (_) => _pickCustom(),
            ),
          ],
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
          Expanded(
            child: Platform.isWindows
                ? Text(
                    'Ctrl + Enter 로 ${_editing ? '저장' : '등록'} · Esc 로 닫기',
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
          _buildSubmitButton(context),
        ],
      ),
    );
  }

  Widget _buildSubmitButton(BuildContext context) {
    return FilledButton(
      key: const ValueKey('announcement-submit'),
      onPressed: _submitting ? null : _submit,
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
                Text(_editing ? '저장 중' : '등록 중'),
              ],
            )
          : Text(_editing ? '저장' : '등록'),
    );
  }
}

/// "지정" 칩을 누르면 뜨는 일/시간 직접 입력 대화상자.
class _CustomAutoUnpinDialog extends StatefulWidget {
  const _CustomAutoUnpinDialog();

  @override
  State<_CustomAutoUnpinDialog> createState() => _CustomAutoUnpinDialogState();
}

class _CustomAutoUnpinDialogState extends State<_CustomAutoUnpinDialog> {
  final _daysController = TextEditingController(text: '0');
  final _hoursController = TextEditingController(text: '0');

  @override
  void dispose() {
    _daysController.dispose();
    _hoursController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('공지 자동 내리기 — 직접 지정'),
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: TextField(
              controller: _daysController,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '일'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _hoursController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '시간'),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () {
            final days = int.tryParse(_daysController.text) ?? 0;
            final hours = int.tryParse(_hoursController.text) ?? 0;
            if (days <= 0 && hours <= 0) return;
            Navigator.of(context).pop(Duration(days: days, hours: hours));
          },
          child: const Text('완료'),
        ),
      ],
    );
  }
}
