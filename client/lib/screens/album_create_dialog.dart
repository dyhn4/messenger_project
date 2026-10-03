import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/album.dart';
import '../models/room.dart';
import '../services/session.dart';
import '../widgets/room_picker_field.dart';
import 'home_screen.dart' show wideBreakpoint;

/// 앨범을 만들 수 있는 방인지 — 비밀 대화는 서버가 파일 내용을 못 보므로 제외하고, 읽기 전용·보관된 토픽은 토픽 관리자만
/// 쓸 수 있다(서버 albumRoomDenial/albumWriteDenial과 같은 규칙). 보드 뷰 토픽은 만들 수 있다(공유만 안 된다).
bool canCreateAlbumIn(Session session, Room room) =>
    !room.isSecret && room.canWrite(session);

/// 앨범 만들기 창을 연다 — 넓은 창(PC)은 대화상자, 좁은 창(모바일)은 전체 화면. 만들었으면 그 앨범을 돌려준다.
/// [room]을 주고 [lockRoom]이면 그 방으로 고정되고(방 안에서 연 경우), 아니면 맨 위 "대화방" 칸에서 골라야 한다.
Future<Album?> showAlbumCreator(
  BuildContext context, {
  required Session session,
  Room? room,
  bool lockRoom = false,
}) {
  final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  final editor = AlbumEditor(
    session: session,
    room: room,
    lockRoom: lockRoom,
    asDialog: wide,
  );
  return _show(context, wide, editor);
}

/// 앨범의 제목·설명 고치기 — 만들기 창과 같은 틀(대화방 칸은 없다).
Future<Album?> showAlbumEditor(
  BuildContext context, {
  required Session session,
  required Album album,
}) {
  final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  final editor = AlbumEditor(session: session, editing: album, asDialog: wide);
  return _show(context, wide, editor);
}

Future<Album?> _show(BuildContext context, bool wide, Widget editor) => wide
    ? showDialog<Album>(
        context: context,
        // 바깥을 잘못 눌러 쓰던 내용이 날아가지 않게 — 닫기는 취소·X로만.
        barrierDismissible: false,
        builder: (_) => editor,
      )
    : Navigator.of(context).push<Album>(
        MaterialPageRoute(fullscreenDialog: true, builder: (_) => editor),
      );

/// 앨범 만들기·고치기 폼(대화상자/전체 화면 공용) — 대화방(만들 때만), 제목(1~50자), 설명(0~300자).
class AlbumEditor extends StatefulWidget {
  final Session session;
  final Room? room;
  final bool lockRoom;

  /// 주면 고치기 모드 — 이 앨범의 제목·설명이 채워지고 대화방 칸이 없다.
  final Album? editing;
  final bool asDialog;

  const AlbumEditor({
    super.key,
    required this.session,
    this.room,
    this.lockRoom = false,
    this.editing,
    this.asDialog = true,
  });

  @override
  State<AlbumEditor> createState() => _AlbumEditorState();
}

class _AlbumEditorState extends State<AlbumEditor> {
  late final _title = TextEditingController(text: widget.editing?.title);
  late final _description = TextEditingController(
    text: widget.editing?.description,
  );
  late Room? _room = widget.room;
  bool _submitting = false;
  String? _error;

  bool get _isEdit => widget.editing != null;

  @override
  void initState() {
    super.initState();
    _title.addListener(_rebuild);
    _description.addListener(_rebuild);
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() => _error = null);
  }

  bool get _canSubmit =>
      !_submitting &&
      (_isEdit || _room != null) &&
      _title.text.trim().isNotEmpty &&
      _title.text.characters.length <= albumTitleMaxLength &&
      _description.text.characters.length <= albumDescriptionMaxLength;

  bool get _dirty {
    final e = widget.editing;
    if (e == null) {
      return _title.text.trim().isNotEmpty ||
          _description.text.trim().isNotEmpty;
    }
    return _title.text.trim() != e.title ||
        _description.text.trim() != (e.description ?? '');
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final albums = widget.session.albums;
    try {
      final Album result;
      if (_isEdit) {
        await albums.updateAlbum(
          title: _title.text,
          description: _description.text,
        );
        result = albums.album ?? widget.editing!;
      } else {
        result = await albums.createAlbum(
          _room!.id,
          title: _title.text,
          description: _description.text,
        );
      }
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      // 서버 문구 그대로(비밀 대화·읽기 전용 토픽 등) — 입력은 그대로 두고 알린다.
      if (mounted) setState(() => _error = '$e');
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
          title: const Text('작성 취소'),
          content: Text(_isEdit ? '고친 내용을 버리고 닫을까요?' : '작성 중인 앨범을 버리고 닫을까요?'),
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
    Navigator.of(context).pop();
  }

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

  String get _heading => _isEdit ? '앨범 수정' : '앨범 만들기';

  Widget _submitButton() => FilledButton(
    key: const ValueKey('album-editor-submit'),
    onPressed: _canSubmit ? _submit : null,
    child: _submitting
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(_isEdit ? '저장' : '만들기'),
  );

  Widget _buildDialog(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: math.min(480, screen.width - 48),
        height: math.min(560, screen.height - 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
              child: Row(
                children: [
                  Icon(
                    Icons.photo_library_outlined,
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
                    key: const ValueKey('album-editor-close'),
                    icon: const Icon(Icons.close),
                    tooltip: '닫기',
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
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: _formChildren(context),
        ),
      ),
    );
  }

  List<Widget> _formChildren(BuildContext context) {
    final theme = Theme.of(context);
    final room = _room;
    final myId = widget.session.userId ?? '';
    return [
      if (!_isEdit) ...[
        const _Label('대화방'),
        if (widget.lockRoom && room != null)
          Container(
            key: const ValueKey('album-room-locked'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.5,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              room.displayName(myId),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          )
        else
          KeyedSubtree(
            key: const ValueKey('album-room-field'),
            child: IgnorePointer(
              ignoring: _submitting,
              child: RoomPickerField(
                session: widget.session,
                value: room,
                filter: (r) => canCreateAlbumIn(widget.session, r),
                onChanged: (r) => setState(() {
                  _room = r;
                  _error = null;
                }),
              ),
            ),
          ),
        const SizedBox(height: 16),
      ],
      const _Label('앨범 제목'),
      TextField(
        key: const ValueKey('album-title-field'),
        controller: _title,
        enabled: !_submitting,
        autofocus: _isEdit || widget.lockRoom,
        maxLength: albumTitleMaxLength,
        decoration: const InputDecoration(
          hintText: '앨범 제목을 입력하세요.',
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      const SizedBox(height: 12),
      const _Label('설명 (선택)'),
      TextField(
        key: const ValueKey('album-description-field'),
        controller: _description,
        enabled: !_submitting,
        maxLength: albumDescriptionMaxLength,
        minLines: 3,
        maxLines: 5,
        decoration: const InputDecoration(
          hintText: '앨범에 대한 설명을 입력하세요.',
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            _error!,
            key: const ValueKey('album-editor-error'),
            style: TextStyle(fontSize: 13, color: theme.colorScheme.error),
          ),
        ),
      if (!_isEdit)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            '앨범은 그 대화방의 멤버가 함께 보고 사진·영상을 올릴 수 있습니다. 한 번에 최대 $albumUploadMaxCount개까지 올릴 수 있어요.',
            style: TextStyle(fontSize: 12, color: theme.hintColor),
          ),
        ),
    ];
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
  );
}
