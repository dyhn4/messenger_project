import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/album.dart';
import '../models/mention.dart';
import '../models/message.dart' show postTextLength;
import '../models/room.dart';
import '../screens/home_screen.dart' show wideBreakpoint;
import '../services/mention_logic.dart';
import '../services/session.dart';
import 'app_toast.dart';
import 'floating_dialog.dart';
import 'mention_autocomplete.dart';
import 'rich_text_format.dart';
import 'room_picker_field.dart';
import 'shared_album_card.dart';

/// 앨범 항목을 보낼 수 있는 대화방인지 — 내가 멤버인 채팅·그룹·1:1·챗 뷰 토픽만 되고, 보드 뷰 토픽과 비밀 대화는 뺀다.
/// 읽기 전용·보관된 토픽은 관리자만 글을 쓰므로 내가 쓸 수 없으면 뺀다. 앨범과 같은 팀의 방이어야 한다(서버 규칙).
bool canShareAlbumTo(Session session, Room room, Album album) =>
    !room.isSecret &&
    !room.isBoard &&
    room.teamId == album.teamId &&
    room.canWrite(session);

/// "대화방에 공유" 창 — 대상 대화방을 고르면(검색 가능) 선택한 [itemIds]를 이미지/영상 메시지로 보낸다. 보냈으면 true.
Future<bool> showAlbumShareDialog(
  BuildContext context, {
  required Session session,
  required Album album,
  required List<String> itemIds,
}) async {
  final shared = await showDialog<bool>(
    context: context,
    builder: (_) =>
        AlbumShareDialog(session: session, album: album, itemIds: itemIds),
  );
  return shared ?? false;
}

class AlbumShareDialog extends StatefulWidget {
  final Session session;
  final Album album;
  final List<String> itemIds;
  const AlbumShareDialog({
    super.key,
    required this.session,
    required this.album,
    required this.itemIds,
  });

  @override
  State<AlbumShareDialog> createState() => _AlbumShareDialogState();
}

class _AlbumShareDialogState extends State<AlbumShareDialog> {
  Room? _room;
  bool _sending = false;
  String? _error;

  Future<void> _send() async {
    final room = _room;
    if (room == null || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final overlay = Overlay.of(context);
    final myId = widget.session.userId ?? '';
    try {
      await widget.session.albums.shareItems(room.id, widget.itemIds);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      showAppToastOnOverlay(
        overlay,
        "'${room.displayName(myId)}'에 ${widget.itemIds.length}개를 공유했습니다.",
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FloatingDialog(
      title: '대화방에 공유',
      maxWidth: 420,
      maxHeight: 460,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '선택한 ${widget.itemIds.length}개를 이미지·영상 메시지로 보냅니다. 파일은 복사되지 않고 같은 파일을 가리킵니다.',
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
            const SizedBox(height: 12),
            const Text(
              '대화방',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            KeyedSubtree(
              key: const ValueKey('album-share-room-field'),
              child: IgnorePointer(
                ignoring: _sending,
                child: RoomPickerField(
                  session: widget.session,
                  value: _room,
                  filter: (r) =>
                      canShareAlbumTo(widget.session, r, widget.album),
                  onChanged: (r) => setState(() {
                    _room = r;
                    _error = null;
                  }),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  key: const ValueKey('album-share-error'),
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _sending
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: const Text('취소'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('album-share-send'),
                  onPressed: _room == null || _sending ? null : _send,
                  child: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('공유'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── 앨범 공유(앨범 카드 메시지) ──────────────────────────────────────────

final _countFormat = NumberFormat.decimalPattern('en_US');

/// "앨범 공유" 창을 연다 — 대화방(챗 뷰 토픽·채팅만)과 메시지(필수, @멘션·서식)를 받아, 메시지 아래 앨범 카드가 붙은
/// 글을 그 방에 보낸다. 넓은 창(PC)은 대화상자, 좁은 창(모바일)은 전체 화면. 보냈으면 true.
Future<bool> showAlbumMessageShareDialog(
  BuildContext context, {
  required Session session,
  required Album album,
}) async {
  final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  final form = AlbumMessageShareDialog(
    session: session,
    album: album,
    asDialog: wide,
  );
  final shared = wide
      ? await showDialog<bool>(
          context: context,
          // 쓰던 메시지가 바깥을 잘못 눌러 날아가지 않게 — 닫기는 취소·✕로만.
          barrierDismissible: false,
          builder: (_) => form,
        )
      : await Navigator.of(context).push<bool>(
          MaterialPageRoute(fullscreenDialog: true, builder: (_) => form),
        );
  return shared ?? false;
}

class AlbumMessageShareDialog extends StatefulWidget {
  final Session session;
  final Album album;
  final bool asDialog;
  const AlbumMessageShareDialog({
    super.key,
    required this.session,
    required this.album,
    this.asDialog = true,
  });

  @override
  State<AlbumMessageShareDialog> createState() =>
      _AlbumMessageShareDialogState();
}

class _AlbumMessageShareDialogState extends State<AlbumMessageShareDialog> {
  final _message = RichTextEditingController()..mentionsEnabled = true;
  final _messageFocus = FocusNode(debugLabel: 'album-share-message');
  final _mentionKey = GlobalKey<MentionAutocompleteState>();
  Room? _room;
  bool _formatOpen = false;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _message.addListener(_onChanged);
    _messageFocus.addListener(_onChanged);
  }

  @override
  void dispose() {
    _message.dispose();
    _messageFocus.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() => _error = null);
  }

  int get _length => postTextLength(_message.text.trim());

  bool get _canSend =>
      !_sending &&
      _room != null &&
      _message.text.trim().isNotEmpty &&
      _length <= albumShareTextMaxLength;

  Future<void> _send() async {
    final room = _room;
    if (room == null || !_canSend) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final overlay = Overlay.of(context);
    final myId = widget.session.userId ?? '';
    final body = _message.formatted();
    final List<Mention> mentions = mentionsToSend(
      _message,
      room,
      widget.session.userId,
    );
    try {
      await widget.session.albums.shareAlbum(
        widget.album.id,
        roomId: room.id,
        text: body.text,
        textFormat: textFormatToJson(body.format),
        mentions: mentionsToJson(mentions),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      showAppToastOnOverlay(
        overlay,
        "'${room.displayName(myId)}'에 앨범을 공유했습니다.",
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_sending,
      child: widget.asDialog ? _buildDialog(context) : _buildPage(context),
    );
  }

  Widget _buildDialog(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final theme = Theme.of(context);
    return Dialog(
      key: const ValueKey('album-message-share-dialog'),
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: math.min(520, screen.width - 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 10, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '앨범 공유',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: '닫기',
                    onPressed: _sending
                        ? null
                        : () => Navigator.of(context).pop(false),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 6, 24, 8),
                child: _buildForm(context),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    key: const ValueKey('album-message-share-cancel'),
                    onPressed: _sending
                        ? null
                        : () => Navigator.of(context).pop(false),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(88, 42),
                    ),
                    child: const Text('취소'),
                  ),
                  const SizedBox(width: 8),
                  _sendButton(context),
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
      key: const ValueKey('album-message-share-dialog'),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '취소',
          onPressed: _sending ? null : () => Navigator.of(context).pop(false),
        ),
        title: const Text('앨범 공유'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _sendButton(context, compact: true),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: _buildForm(context),
        ),
      ),
    );
  }

  /// 어두운 "공유하기" — 밝은 테마는 거의 검정 바탕, 어두운 테마는 밝은 바탕.
  Widget _sendButton(BuildContext context, {bool compact = false}) {
    final scheme = Theme.of(context).colorScheme;
    final light = scheme.brightness == Brightness.light;
    return FilledButton(
      key: const ValueKey('album-message-share-send'),
      onPressed: _canSend ? _send : null,
      style: FilledButton.styleFrom(
        backgroundColor: light ? const Color(0xFF2B2D31) : scheme.onSurface,
        foregroundColor: light ? Colors.white : scheme.surface,
        minimumSize: compact ? const Size(64, 36) : const Size(96, 42),
      ),
      child: _sending
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('공유하기'),
    );
  }

  Widget _buildForm(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final album = widget.album;
    final room = _room;
    final cover = album.coverUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _FieldLabel('대화방 선택'),
        KeyedSubtree(
          key: const ValueKey('album-message-share-room'),
          child: IgnorePointer(
            ignoring: _sending,
            child: RoomPickerField(
              session: widget.session,
              value: room,
              filter: (r) => canShareAlbumTo(widget.session, r, album),
              onChanged: (r) => setState(() {
                _room = r;
                _error = null;
              }),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '※ 앨범은 채팅 및 챗 뷰 토픽에서만 공유할 수 있습니다.',
          key: const ValueKey('album-message-share-note'),
          style: TextStyle(fontSize: 12, color: hint),
        ),
        const SizedBox(height: 18),
        const _FieldLabel('공유 앨범'),
        AlbumShareCard(
          key: const ValueKey('album-message-share-album'),
          title: album.title,
          subtitle: '사진·영상 ${album.itemCount}개',
          coverUrl: cover == null ? null : widget.session.resolveUrl(cover),
          maxWidth: double.infinity,
        ),
        const SizedBox(height: 18),
        _FieldLabel(
          '메시지',
          required: true,
          trailing: SizedBox(
            height: 28,
            child: Theme(
              data: theme.copyWith(visualDensity: VisualDensity.compact),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (room != null && roomAllowsMention(room))
                    MentionButton(
                      onPressed: _sending
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
        _buildFooter(context),
      ],
    );
  }

  Widget _buildMessageField(BuildContext context) {
    final room = _room;
    final field = RichFieldWrapper(
      controller: _message,
      child: TextField(
        key: const ValueKey('album-message-share-text'),
        controller: _message,
        focusNode: _messageFocus,
        enabled: !_sending,
        minLines: 4,
        maxLines: 8,
        keyboardType: TextInputType.multiline,
        textAlignVertical: TextAlignVertical.top,
        decoration: InputDecoration(
          hintText: '앨범과 함께 보낼 메시지를 입력하세요.',
          isDense: true,
          contentPadding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
          border: _formatOpen ? InputBorder.none : const OutlineInputBorder(),
          enabledBorder: _formatOpen ? InputBorder.none : null,
          focusedBorder: _formatOpen ? InputBorder.none : null,
        ),
      ),
    );
    return RichFormatFrame(
      open: _formatOpen,
      focused: _messageFocus.hasFocus,
      toolbar: RichFormatToolbar(
        controller: _message,
        focusNode: _messageFocus,
      ),
      child: room == null
          ? field
          : MentionAutocomplete(
              key: _mentionKey,
              controller: _message,
              focusNode: _messageFocus,
              room: room,
              myUserId: widget.session.userId,
              resolveUrl: widget.session.resolveUrl,
              child: field,
            ),
    );
  }

  /// 입력칸 아래 — 왼쪽은 오류, 오른쪽은 `21 / 5,000`(앞뒤 공백을 뺀 글자 단위, 서버와 같다).
  Widget _buildFooter(BuildContext context) {
    final theme = Theme.of(context);
    final length = _length;
    final over = length > albumShareTextMaxLength;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              _error ?? '',
              key: const ValueKey('album-message-share-error'),
              style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
            ),
          ),
          Text(
            '${_countFormat.format(length)} / ${_countFormat.format(albumShareTextMaxLength)}',
            key: const ValueKey('album-message-share-counter'),
            style: TextStyle(
              fontSize: 12,
              fontWeight: over ? FontWeight.w700 : FontWeight.normal,
              color: over ? theme.colorScheme.error : theme.hintColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  final bool required;
  final Widget? trailing;
  const _FieldLabel(this.text, {this.required = false, this.trailing});

  @override
  Widget build(BuildContext context) {
    final label = Text.rich(
      TextSpan(
        text: text,
        children: [
          if (required)
            TextSpan(
              text: ' *',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: trailing == null
          ? label
          : Row(
              children: [
                Expanded(child: label),
                trailing!,
              ],
            ),
    );
  }
}
