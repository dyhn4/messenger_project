import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';

import '../services/room_chat_controller.dart';

class _PendingAttachment {
  final File file;
  final bool isImage;
  final String displayName;
  _PendingAttachment({required this.file, required this.isImage, required this.displayName});
}

class ChatInputBar extends StatefulWidget {
  final RoomChatController controller;
  const ChatInputBar({super.key, required this.controller});

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _attachments = <_PendingAttachment>[];
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // Ctrl+V는 텍스트 붙여넣기용 기본 동작을 그대로 두고(return false), 클립보드에
  // 이미지가 있으면 첨부 목록에 추가하는 걸 별도로 시도한다.
  bool _handleKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyV &&
        HardwareKeyboard.instance.isControlPressed &&
        _focusNode.hasFocus) {
      _pasteImageFromClipboard();
    }
    return false;
  }

  Future<void> _pasteImageFromClipboard() async {
    final bytes = await Pasteboard.image;
    if (bytes == null || bytes.isEmpty || !mounted) return; // 클립보드에 이미지가 없으면 아무 것도 안 함.

    final path =
        '${Directory.systemTemp.path}${Platform.pathSeparator}image_${DateTime.now().microsecondsSinceEpoch}.png';
    final file = File(path);
    await file.writeAsBytes(bytes);
    if (!mounted) return;
    setState(() => _attachments.add(_PendingAttachment(file: file, isImage: true, displayName: 'image.png')));
  }

  Future<void> _pickImage() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;
    setState(() {
      _attachments.add(_PendingAttachment(file: File(picked.path), isImage: true, displayName: picked.name));
    });
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles();
    final picked = result?.files.single;
    if (picked?.path == null) return;
    setState(() {
      _attachments.add(_PendingAttachment(file: File(picked!.path!), isImage: false, displayName: picked.name));
    });
  }

  void _removeAttachment(int index) => setState(() => _attachments.removeAt(index));

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (_attachments.isEmpty && text.isEmpty) return;

    final toSend = List<_PendingAttachment>.from(_attachments);
    setState(() {
      _attachments.clear();
      _sending = true;
    });
    _controller.clear();

    try {
      if (toSend.isEmpty) {
        await widget.controller.sendText(text);
      } else {
        // 첨부와 함께 입력한 메시지는 별도 메시지로 보내지 않고, 첫 번째 첨부의 캡션으로 붙인다.
        for (var i = 0; i < toSend.length; i++) {
          final a = toSend[i];
          await widget.controller.sendFile(a.file, isImage: a.isImage, caption: i == 0 ? text : null);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('전송 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_attachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  height: 64,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: _attachments.length,
                    itemBuilder: (context, i) => _AttachmentPreview(
                      attachment: _attachments[i],
                      onRemove: () => _removeAttachment(i),
                    ),
                  ),
                ),
              ),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.image_outlined),
                  onPressed: _sending ? null : _pickImage,
                  tooltip: '이미지 보내기',
                ),
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  onPressed: _sending ? null : _pickFile,
                  tooltip: '파일 보내기',
                ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    decoration: const InputDecoration(hintText: '메시지 입력', border: OutlineInputBorder()),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                  ),
                ),
                if (_sending)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else
                  IconButton(icon: const Icon(Icons.send), onPressed: _send, tooltip: '보내기'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 보내기 전 첨부 미리보기 한 칸. 이미지는 썸네일, 그 외 파일은 아이콘+이름 칩으로
/// 보여주고, 오른쪽 위 x 버튼으로 뺄 수 있다.
class _AttachmentPreview extends StatelessWidget {
  final _PendingAttachment attachment;
  final VoidCallback onRemove;
  const _AttachmentPreview({required this.attachment, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10, top: 6),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (attachment.isImage)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(attachment.file, width: 56, height: 56, fit: BoxFit.cover),
            )
          else
            Container(
              width: 56,
              height: 56,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.insert_drive_file_outlined, size: 18),
                  const SizedBox(height: 2),
                  Text(
                    attachment.displayName,
                    style: const TextStyle(fontSize: 9),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          Positioned(
            top: -6,
            right: -6,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), shape: BoxShape.circle),
                child: const Icon(Icons.close, size: 12, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
