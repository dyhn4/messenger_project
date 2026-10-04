import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/announcement.dart';
import '../models/room.dart';
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/rich_text_format.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'post_editor_dialog.dart' show TopicChip;
import 'schedule_message_dialog.dart' show ScheduleDateTimeField;

/// 공지 본문 글자 수 한도 — 서버(announcements.js)와 같다.
const announcementTextMaxLength = 2000;

/// "공지 자동 내리기 > 지정"으로 고를 수 있는 가장 먼 날 — 서버(announcements.js parseAutoUnpinAt)는 366일까지
/// 받는데, 하루 여유를 두고 1년(365일)까지만 고르게 한다.
const announcementAutoUnpinMaxDays = 365;

/// 한도에 이만큼 가까워지면 입력칸 아래에 "n/2000"을 보여준다(평소엔 숨김 — 게시글 작성창과 같다).
const _counterFrom = announcementTextMaxLength * 9 ~/ 10;

/// 공지 작성 창이 넘겨주는 값 — 글(앞뒤 공백 뗌)과 그 글에 맞춘 서식 구간([format], 서식 도구모음으로 고른 것 —
/// 없으면 null), "자동 내리기"까지 남은 기간(null이면 자동 내리기 없음, 기본값. "지정"으로 시각을 골랐으면 등록을
/// 누른 때부터 그 시각까지).
class AnnouncementDraft {
  final String text;
  final Duration? autoUnpinAfter;
  final List<TextFormatRun>? format;
  const AnnouncementDraft(this.text, this.autoUnpinAfter, {this.format});
}

/// 공지 쓰기([announcement]가 없을 때)·수정 창을 연다 — 게시글 작성창(post_editor_dialog.dart)과 같은 틀로,
/// 넓은 창(PC)은 대화상자, 좁은 창(모바일)은 전체 화면이다. 게시글과 달리 **제목 입력칸이 없다**(공지는 글
/// 한 덩어리). 본문 칸 위에는 프로젝트 노트 편집기와 같은 서식 도구모음(글자색·제목·굵게…·목록·구분선)이 늘
/// 붙어 있다. [onSubmit]이 등록/저장을 맡는다 — 실패하면 던진 오류를 토스트로 알리고 창과 쓰던 글을 그대로
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
  /// 서식을 입력한 그대로 보여주는 본문 컨트롤러 — 글은 평문, 서식은 따로(rich_text_format.dart).
  final _controller = RichTextEditingController();
  final _focus = FocusNode(debugLabel: 'announcement-body');
  String? _error;
  String _lastText = '';
  bool _submitting = false;

  /// 빠른 선택으로 고른 자동 내리기 기간(없음이면 null).
  Duration? _autoUnpinAfter;

  /// "지정"을 골랐는지와 그때 고른 시각 — 달력+시각 한 칸(ScheduleDateTimeField)이 칩 아래에 펼쳐진다.
  bool _isCustom = false;
  DateTime? _customAt;
  final _customField = GlobalKey(debugLabel: 'announcement-auto-unpin-at');

  /// 수정 창을 열 때의 글·서식(JSON) — 바뀌었는지(닫기 전에 물을지) 비교한다.
  String _originalText = '';
  String _originalFormat = 'null';

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
    final a = widget.announcement;
    if (a != null) {
      _controller.load(a.text, a.textFormat);
      final saved = _controller.formatted();
      _originalText = saved.text;
      _originalFormat = jsonEncode(textFormatToJson(saved.format));
    }
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
    if (!_editing) return _controller.text.trim().isNotEmpty;
    final now = _controller.formatted();
    return now.text != _originalText ||
        jsonEncode(textFormatToJson(now.format)) != _originalFormat;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final draft = _controller.formatted();
    final text = draft.text;
    // 사진 공지는 글 없이 사진만 둘 수 있다(서버도 같은 규칙).
    final allowEmpty = widget.announcement?.hasImage ?? false;
    if (text.isEmpty && !allowEmpty) {
      setState(() => _error = '내용을 입력하세요.');
      _focus.requestFocus();
      return;
    }
    var autoUnpinAfter = _autoUnpinAfter;
    final customAt = _customAt;
    if (!_editing && _isCustom && customAt != null) {
      autoUnpinAfter = customAt.difference(DateTime.now());
      // 창을 열어 둔 사이에 고른 시각이 지났으면 다시 고르게 한다(서버도 지난 시각은 받지 않는다).
      if (autoUnpinAfter <= Duration.zero) {
        showAppToast(context, '자동 내리기 시각이 지났습니다. 다시 골라 주세요.');
        return;
      }
    }
    setState(() => _submitting = true);
    try {
      await widget.onSubmit(
        AnnouncementDraft(text, autoUnpinAfter, format: draft.format),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showAppToast(context, '$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 취소·Esc·뒤로 가기 — 쓰던 내용이 있으면 한 번 묻는다.
  Future<void> _requestClose() async {
    // "지정" 달력 판이 펼쳐져 있으면 그것만 닫는다(예약 메시지 편집기와 같다).
    if (ScheduleDateTimeField.hidePopupOf(_customField)) return;
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

  /// "지정" — 칩 아래에 날짜+시각 한 칸을 펼친다. 처음 고르면 내일 이맘때(15분 단위로 올림)부터.
  void _pickCustom() {
    setState(() {
      _isCustom = true;
      _customAt ??= ceilToScheduleSlot(
        DateTime.now().add(const Duration(days: 1)),
      );
    });
  }

  /// "3일 4시간 뒤에 내려갑니다" — 지정 칸 옆(좁으면 아래) 안내. 분 단위는 올림.
  static String _untilText(DateTime at, DateTime now) {
    final total = (at.difference(now).inSeconds / 60).ceil();
    if (total <= 0) return '이미 지난 시각입니다. 다시 골라 주세요.';
    final days = total ~/ (24 * 60);
    final hours = total % (24 * 60) ~/ 60;
    final minutes = total % 60;
    final String span;
    if (days > 0) {
      span = hours > 0 ? '$days일 $hours시간' : '$days일';
    } else if (hours > 0) {
      span = minutes > 0 ? '$hours시간 $minutes분' : '$hours시간';
    } else {
      span = '$minutes분';
    }
    return '$span 뒤에 자동으로 내려갑니다';
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

  /// 여러 줄 본문 — 게시글 작성창의 본문 칸과 같은 테두리·글꼴. 맨 위에는 프로젝트 "새 노트" 편집기와 같은 서식
  /// 도구모음(글자색·제목 1~3 | 굵게·기울임·밑줄·취소선 | 링크·코드·인용 | 번호·글머리 목록 | 구분선)이 늘 붙어
  /// 있고, 고른 서식은 공지와 함께 저장돼 상세·목록·공지바에서 그대로 보인다(Ctrl+B/I/U도 된다).
  Widget _buildBodyField(BuildContext context, {bool expand = true}) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final focused = _focus.hasFocus;
    final hasError = _error != null;
    const radius = BorderRadius.all(Radius.circular(8));
    final field = RichFieldWrapper(
      controller: _controller,
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
    );
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
            Container(
              key: const ValueKey('announcement-format-toolbar'),
              color: dark
                  ? Colors.white.withValues(alpha: 0.04)
                  : const Color(0xFFF7F8FA),
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: RichFormatToolbar(
                controller: _controller,
                focusNode: _focus,
                showColor: true,
                showHeadings: true,
                showRule: true,
              ),
            ),
            Divider(height: 1, color: theme.dividerColor),
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

  /// "공지 자동 내리기" 빠른 선택 — 새 공지에서만(서버가 수정에서는 글만 바꾼다). "지정"을 고르면 칩 아래에
  /// 투표 마감 시각과 같은 날짜+시각 한 칸(`10월 5일 (월) 오후 3:30`, 누르면 달력과 그 밑 시간 목록)이 펼쳐진다 —
  /// 지금 이후~1년 안에서 15분 단위.
  Widget _buildAutoUnpin(BuildContext context) {
    final theme = Theme.of(context);
    final customAt = _customAt;
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
              key: const ValueKey('announcement-auto-unpin-custom'),
              label: const Text('지정'),
              selected: _isCustom,
              onSelected: _submitting ? null : (_) => _pickCustom(),
            ),
          ],
        ),
        if (_isCustom && customAt != null) ...[
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final passed = !customAt.isAfter(DateTime.now());
              final field = ScheduleDateTimeField(
                key: _customField,
                value: customAt,
                enabled: !_submitting,
                maxDaysAhead: announcementAutoUnpinMaxDays,
                onChanged: (v) => setState(() => _customAt = v),
              );
              final hint = Text(
                _untilText(customAt, DateTime.now()),
                key: const ValueKey('announcement-auto-unpin-hint'),
                style: TextStyle(
                  fontSize: 12,
                  color: passed ? theme.colorScheme.error : theme.hintColor,
                ),
              );
              // 좁은 화면(휴대폰)은 칸을 꽉 채우고 안내를 아래에, 넓으면 칸 옆에.
              if (constraints.maxWidth < 480) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    field,
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                      child: hint,
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  SizedBox(width: 280, child: field),
                  const SizedBox(width: 12),
                  Expanded(child: hint),
                ],
              );
            },
          ),
        ],
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
