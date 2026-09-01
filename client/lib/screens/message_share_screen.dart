import 'package:flutter/material.dart';

import '../models/message.dart';
import '../models/room.dart';
import '../services/message_preview.dart';
import '../services/session.dart';
import '../widgets/room_picker_field.dart';

/// 메시지 롱프레스 메뉴의 "메시지 공유" — 대화방을 골라 새 텍스트를 쓰고, 그 아래 원본
/// 메시지를 인용(quotedSenderName/quotedPreview)으로 붙여서 보낸다. 원본은 공유 당시
/// 내용의 스냅샷이라(server/src/socket.js) 나중에 원본이 수정/삭제돼도 그대로 남는다.
class MessageShareScreen extends StatefulWidget {
  final Session session;
  final Message message;
  final String senderDisplayName;
  const MessageShareScreen({
    super.key,
    required this.session,
    required this.message,
    required this.senderDisplayName,
  });

  @override
  State<MessageShareScreen> createState() => _MessageShareScreenState();
}

class _MessageShareScreenState extends State<MessageShareScreen> {
  Room? _targetRoom;
  final _textController = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  String get _quotedPreview => formatMessagePreview(
    type: widget.message.type,
    text: widget.message.text,
    fileName: widget.message.fileName,
  );

  Future<void> _share() async {
    final room = _targetRoom;
    if (room == null) return;
    setState(() => _sending = true);
    final text = _textController.text.trim();
    try {
      await widget.session.chatSocket.send(
        roomId: room.id,
        type: 'text',
        text: text.isEmpty ? null : text,
        quotedSenderName: widget.senderDisplayName,
        quotedPreview: _quotedPreview,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('공유 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('메시지 공유'),
        actions: [
          TextButton(
            onPressed: (_targetRoom == null || _sending) ? null : _share,
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
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('대화방', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            RoomPickerField(
              session: widget.session,
              value: _targetRoom,
              onChanged: (r) => setState(() => _targetRoom = r),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: TextField(
                controller: _textController,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  hintText: '내용을 입력하세요.',
                  border: InputBorder.none,
                ),
              ),
            ),
            const Divider(height: 24),
            _QuoteCard(
              senderName: widget.senderDisplayName,
              preview: _quotedPreview,
            ),
          ],
        ),
      ),
    );
  }
}

/// 공유할 원본 메시지를 미리 보여주는 인용 카드 — 실제로 보내지는 message_bubble.dart의
/// 인용 카드 렌더링과 같은 모양(작은 아바타 + 보낸사람 + 미리보기)으로 맞췄다.
class _QuoteCard extends StatelessWidget {
  final String senderName;
  final String preview;
  const _QuoteCard({required this.senderName, required this.preview});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: const Icon(Icons.person, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  senderName,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Theme.of(context).hintColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
