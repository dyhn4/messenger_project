import 'package:flutter/material.dart';

import '../data/stickers.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../services/session.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/room_picker_field.dart';
import '../l10n/tr.dart';

String _typeToWire(MessageType type) => switch (type) {
  MessageType.image => 'image',
  MessageType.file => 'file',
  MessageType.sticker => 'sticker',
  MessageType.text || MessageType.system || MessageType.comment => 'text',
};

/// 공유·전달로 보낼 수 있는 방인지 — 보드 뷰 토픽은 게시글만 받고(서버가 다른 메시지를 거절한다),
/// 읽기 전용·보관된 토픽은 토픽을 관리할 수 있는 사람만 쓸 수 있어서 목록에서 뺀다.
bool canForwardTo(Session session, Room room) =>
    !room.isBoard && room.canWrite(session);

/// 게시글을 전달할 때 받는 방에 들어갈 글 — 제목을 첫 줄로 본문과 함께(고쳐서 보낼 수 있다).
String _initialForwardText(Message m) {
  if (m.type == MessageType.sticker) return '';
  if (!m.isPost) return m.text ?? '';
  final body = m.text ?? '';
  final title = m.title ?? '';
  return body.isEmpty ? title : '$title\n\n$body';
}

String _formatFullDateTime(DateTime dt) {
  final isPm = dt.hour >= 12;
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final y = dt.year.toString().padLeft(4, '0');
  final mo = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final hh = hour12.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '$y/$mo/$d ${isPm ? 'PM' : 'AM'} $hh:$mm';
}

/// 메시지 롱프레스 메뉴(모바일)/더보기 메뉴(PC)의 "메시지 전달" — 대화방을 골라 원본 내용
/// (텍스트는 편집 가능, 첨부는 그대로) 그 자체를 새 메시지로 보낸다. "포함" 토글을 켜면
/// 원본 id(forwardedFromMessageId — 댓글이면 그 댓글 id)가 같이 실리고, 서버가 그 원본에서 보낸 사람·
/// 시각을 채워 받는 쪽에 "OOO에서 전달한 메시지입니다"로 표시된다(message_bubble.dart 렌더링,
/// server/src/messageAttribution.js 참고). 글을 고치면 원본 표시는 붙지 않는다 — 그 사람이 쓰지 않은 글이
/// 그 사람 것으로 보이면 안 되기 때문이다(서버도 원본 그대로일 때만 붙인다). 비밀 대화의 메시지·파일은
/// 전달하지 않는다(평문이 다른 방으로 샌다). PC(asDialog:true)는 FloatingDialog로, 모바일은
/// 전체화면으로 뜬다(message_actions.dart의 pushMessageForwardScreen이 창 너비로 고른다).
class MessageForwardScreen extends StatefulWidget {
  final Session session;
  final Message message;
  final String senderDisplayName;
  final bool asDialog;
  const MessageForwardScreen({
    super.key,
    required this.session,
    required this.message,
    required this.senderDisplayName,
    this.asDialog = false,
  });

  @override
  State<MessageForwardScreen> createState() => _MessageForwardScreenState();
}

class _MessageForwardScreenState extends State<MessageForwardScreen> {
  Room? _targetRoom;
  late final _initialText = _initialForwardText(widget.message);
  late final _textController = TextEditingController(text: _initialText)
    ..addListener(_onTextChanged);
  bool _includeAttribution = true;
  bool _sending = false;
  bool _edited = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  /// 글을 처음 채워 준 그대로 두었는지 — 고치면 원본 표시를 붙이지 않는다(서버 quoteForwardRules.js
  /// forwardMatchesSource와 같은 기준: 앞뒤 공백만 다른 건 고친 것으로 보지 않는다).
  void _onTextChanged() {
    final edited = _textController.text.trim() != _initialText.trim();
    if (edited != _edited) setState(() => _edited = edited);
  }

  /// 원본이 비밀 대화의 메시지인지 — 파일 뷰어의 "파일 전달"처럼 메뉴 밖에서 열려도 막는다.
  bool get _fromSecretRoom => widget.session.rooms.any(
    (r) => r.id == widget.message.roomId && r.isSecret,
  );

  /// 이번 전달에 원본 표시를 붙이는지 — "포함"을 켰고 글을 고치지 않았을 때.
  bool get _attach => _includeAttribution && !_edited;

  /// 게시글은 받는 방에 게시글이 아니라 보통 메시지로 간다 — 첨부가 있으면 사진만이면 사진, 아니면
  /// 파일 메시지로.
  String get _wireType {
    final message = widget.message;
    if (!message.isPost || message.liveAttachments.isEmpty) {
      return _typeToWire(message.type);
    }
    return message.liveAttachments.every((a) => a.isImage) ? 'image' : 'file';
  }

  Future<void> _forward() async {
    final room = _targetRoom;
    if (room == null || !canForwardTo(widget.session, room)) return;
    final message = widget.message;
    // 비밀 대화의 글·파일은 다른 방으로 보내지 않는다 — 글은 평문으로 새고, 파일은 받는 사람이 풀 수 없는 암호문이다.
    if (_fromSecretRoom) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('비밀 대화의 메시지·파일은 다른 대화방으로 전달할 수 없습니다.'))),
      );
      return;
    }
    // 파일 삭제로 지워진 파일은 전달할 수 없다(메시지 자리와 댓글만 남아 있다).
    final isFileMessage =
        message.type == MessageType.image || message.type == MessageType.file;
    if (isFileMessage &&
        message.attachments.isNotEmpty &&
        message.liveAttachments.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('삭제된 파일은 전달할 수 없습니다.'))));
      return;
    }
    setState(() => _sending = true);
    final text = message.type == MessageType.sticker
        ? message.text
        : (_textController.text.trim().isEmpty
              ? null
              : _textController.text.trim());
    // 게시글은 첨부가 하나여도 목록으로 넘긴다(게시글 첨부는 목록에만 온전히 있다).
    final sendList =
        message.liveAttachments.length > 1 ||
        (message.isPost && message.liveAttachments.isNotEmpty);
    try {
      await widget.session.chatSocket.send(
        roomId: room.id,
        type: _wireType,
        text: text,
        fileUrl: message.fileUrl,
        fileName: message.fileName,
        fileSize: message.fileSize,
        mimeType: message.mimeType,
        thumbnailUrl: message.thumbnailUrl,
        // 사진·파일 여러 개가 딸린 메시지는 전부 같이 넘긴다(없으면 첫 번째만 전달된다).
        attachments: sendList
            ? [
                for (final a in message.liveAttachments)
                  {
                    'kind': a.kind,
                    'fileUrl': a.fileUrl,
                    'fileName': ?a.fileName,
                    'fileSize': ?a.fileSize,
                    'mimeType': ?a.mimeType,
                    'thumbnailUrl': ?a.thumbnailUrl,
                  },
              ]
            : null,
        forwardedFromMessageId: _attach ? message.id : null,
        // 업데이트 전 서버만 이 두 값을 쓴다(지금 서버는 위 id로 원본에서 채운다).
        forwardedFromSenderName: _attach ? widget.senderDisplayName : null,
        forwardedFromCreatedAt: _attach
            ? message.createdAt.millisecondsSinceEpoch
            : null,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('전달 실패: {e}', {'e': e}))));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Widget? _buildAttachmentPreview(BuildContext context) {
    final message = widget.message;
    final images = message.attachments.where((a) => a.isImage).length;
    final (icon, label) = message.isPost
        ? switch (message.attachments.length) {
            0 => (null, null),
            final n when n == images => (
              Icons.image_outlined,
              tr('사진 {n}장', {'n': n}),
            ),
            final n => (Icons.attach_file, tr('첨부 {n}개', {'n': n})),
          }
        : switch (message.type) {
            MessageType.image => (Icons.image_outlined, tr('사진')),
            MessageType.file => (
              Icons.insert_drive_file_outlined,
              message.fileName ?? tr('파일'),
            ),
            MessageType.sticker => (
              Icons.emoji_emotions_outlined,
              switch (findStickerById(message.text ?? '')?.emoji) {
                final String e when e.isNotEmpty => e,
                _ => tr('이모티콘'),
              },
            ),
            MessageType.text ||
            MessageType.system ||
            MessageType.comment => (null, null),
          };
    if (icon == null) return null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Theme.of(context).hintColor),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttributionRow(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('{widget.senderDisplayName}에서 전달한 메시지입니다', {
                    'widget.senderDisplayName': widget.senderDisplayName,
                  }),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  '${widget.senderDisplayName} | ${_formatFullDateTime(widget.message.createdAt)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).hintColor,
                  ),
                ),
                // 고친 글에는 원본 표시를 붙이지 않는다 — 켜 둔 채 고쳤으면 왜 빠지는지 미리 알려 준다.
                if (_includeAttribution && _edited) ...[
                  const SizedBox(height: 6),
                  Text(
                    tr('내용을 고치면 원본 표시는 붙지 않습니다.'),
                    key: const ValueKey('forward-edited-note'),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Column(
          children: [
            Text(tr('포함'), style: TextStyle(fontSize: 12)),
            Switch(
              value: _includeAttribution,
              onChanged: (v) => setState(() => _includeAttribution = v),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final canForward = _targetRoom != null && !_sending;
    final textField = TextField(
      controller: _textController,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      decoration: InputDecoration(
        hintText: tr('내용을 입력하세요.'),
        border: widget.asDialog ? const OutlineInputBorder() : InputBorder.none,
      ),
    );

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: widget.asDialog ? MainAxisSize.min : MainAxisSize.max,
      children: [
        Text(tr('대화방'), style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        RoomPickerField(
          session: widget.session,
          value: _targetRoom,
          filter: (r) => canForwardTo(widget.session, r),
          onChanged: (r) => setState(() => _targetRoom = r),
        ),
        const SizedBox(height: 16),
        _buildAttachmentPreview(context) ?? const SizedBox.shrink(),
        if (widget.message.type != MessageType.sticker)
          widget.asDialog
              ? SizedBox(height: 140, child: textField)
              : Expanded(child: textField)
        else if (!widget.asDialog)
          const Spacer(),
        const Divider(height: 24),
        _buildAttributionRow(context),
        if (widget.asDialog) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _sending
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: Text(tr('취소')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: canForward ? _forward : null,
                  child: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(tr('전달')),
                ),
              ),
            ],
          ),
        ],
      ],
    );

    if (widget.asDialog) {
      return FloatingDialog(title: tr('메시지 전달'), maxWidth: 480, child: body);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('메시지 전달')),
        actions: [
          TextButton(
            onPressed: canForward ? _forward : null,
            child: _sending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(tr('전달')),
          ),
        ],
      ),
      body: Padding(padding: const EdgeInsets.all(16), child: body),
    );
  }
}
