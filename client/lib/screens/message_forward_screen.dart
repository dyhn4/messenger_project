import 'package:flutter/material.dart';

import '../data/stickers.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../services/session.dart';
import '../widgets/floating_dialog.dart';
import '../widgets/room_picker_field.dart';

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
/// 원본 발신자/시각이 같이 실려서 받는 쪽에 "OOO에서 전달한 메시지입니다"로 표시된다
/// (message_bubble.dart 렌더링 참고). PC(asDialog:true)는 FloatingDialog로, 모바일은
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
  late final _textController = TextEditingController(
    text: _initialForwardText(widget.message),
  );
  bool _includeAttribution = true;
  bool _sending = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  /// 게시글은 받는 방에 게시글이 아니라 보통 메시지로 간다 — 첨부가 있으면 사진만이면 사진, 아니면
  /// 파일 메시지로.
  String get _wireType {
    final message = widget.message;
    if (!message.isPost || message.attachments.isEmpty) {
      return _typeToWire(message.type);
    }
    return message.attachments.every((a) => a.isImage) ? 'image' : 'file';
  }

  Future<void> _forward() async {
    final room = _targetRoom;
    if (room == null || !canForwardTo(widget.session, room)) return;
    setState(() => _sending = true);
    final message = widget.message;
    final text = message.type == MessageType.sticker
        ? message.text
        : (_textController.text.trim().isEmpty
              ? null
              : _textController.text.trim());
    // 게시글은 첨부가 하나여도 목록으로 넘긴다(게시글 첨부는 목록에만 온전히 있다).
    final sendList =
        message.attachments.length > 1 ||
        (message.isPost && message.attachments.isNotEmpty);
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
                for (final a in message.attachments)
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
        forwardedFromSenderName: _includeAttribution
            ? widget.senderDisplayName
            : null,
        forwardedFromCreatedAt: _includeAttribution
            ? message.createdAt.millisecondsSinceEpoch
            : null,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('전달 실패: $e')));
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
            final n when n == images => (Icons.image_outlined, '사진 $n장'),
            final n => (Icons.attach_file, '첨부 $n개'),
          }
        : switch (message.type) {
            MessageType.image => (Icons.image_outlined, '사진'),
            MessageType.file => (
              Icons.insert_drive_file_outlined,
              message.fileName ?? '파일',
            ),
            MessageType.sticker => (
              Icons.emoji_emotions_outlined,
              findStickerById(message.text ?? '')?.emoji ?? '이모티콘',
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
                  '${widget.senderDisplayName}에서 전달한 메시지입니다',
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
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Column(
          children: [
            const Text('포함', style: TextStyle(fontSize: 12)),
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
        hintText: '내용을 입력하세요.',
        border: widget.asDialog ? const OutlineInputBorder() : InputBorder.none,
      ),
    );

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: widget.asDialog ? MainAxisSize.min : MainAxisSize.max,
      children: [
        Text('대화방', style: Theme.of(context).textTheme.labelLarge),
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
                  child: const Text('취소'),
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
                      : const Text('전달'),
                ),
              ),
            ],
          ),
        ],
      ],
    );

    if (widget.asDialog) {
      return FloatingDialog(title: '메시지 전달', maxWidth: 480, child: body);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('메시지 전달'),
        actions: [
          TextButton(
            onPressed: canForward ? _forward : null,
            child: _sending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('전달'),
          ),
        ],
      ),
      body: Padding(padding: const EdgeInsets.all(16), child: body),
    );
  }
}
