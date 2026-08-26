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
  _PendingAttachment({
    required this.file,
    required this.isImage,
    required this.displayName,
  });
}

/// 댓글 입력창. ChatInputBar와 같은 이미지/파일 첨부(클립보드로 캡처한 이미지 붙여넣기 포함)를
/// 지원하는 축소판이라, 콜백 대신 controller+messageId를 직접 받아 postComment/postCommentFile을 호출한다.
class CommentInputBar extends StatefulWidget {
  final RoomChatController controller;
  final String messageId;
  const CommentInputBar({
    super.key,
    required this.controller,
    required this.messageId,
  });

  @override
  State<CommentInputBar> createState() => _CommentInputBarState();
}

class _CommentInputBarState extends State<CommentInputBar> {
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
  // 이미지가 있으면 첨부 목록에 추가하는 걸 별도로 시도한다(ChatInputBar와 동일).
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
    if (bytes == null || bytes.isEmpty || !mounted)
      return; // 클립보드에 이미지가 없으면 아무 것도 안 함.

    final path =
        '${Directory.systemTemp.path}${Platform.pathSeparator}image_${DateTime.now().microsecondsSinceEpoch}.png';
    final file = File(path);
    await file.writeAsBytes(bytes);
    if (!mounted) return;
    setState(
      () => _attachments.add(
        _PendingAttachment(file: file, isImage: true, displayName: 'image.png'),
      ),
    );
  }

  Future<void> _pickImage() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (picked == null) return;
    setState(() {
      _attachments.add(
        _PendingAttachment(
          file: File(picked.path),
          isImage: true,
          displayName: picked.name,
        ),
      );
    });
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles();
    final picked = result?.files.single;
    if (picked?.path == null) return;
    setState(() {
      _attachments.add(
        _PendingAttachment(
          file: File(picked!.path!),
          isImage: false,
          displayName: picked.name,
        ),
      );
    });
  }

  void _removeAttachment(int index) =>
      setState(() => _attachments.removeAt(index));

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (_attachments.isEmpty && text.isEmpty) return;

    final toSend = List<_PendingAttachment>.from(_attachments);
    setState(() {
      _attachments.clear();
      _sending = true;
    });
    _controller.clear();
    _focusNode.requestFocus();

    try {
      if (toSend.isEmpty) {
        await widget.controller.postComment(widget.messageId, text);
      } else {
        // 첨부와 함께 입력한 댓글은 별도 댓글로 보내지 않고, 첫 번째 첨부의 캡션으로 붙인다.
        for (var i = 0; i < toSend.length; i++) {
          final a = toSend[i];
          await widget.controller.postCommentFile(
            widget.messageId,
            a.file,
            isImage: a.isImage,
            caption: i == 0 ? text : null,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('댓글 전송 실패: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _focusNode.requestFocus();
      }
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
                    itemBuilder: (context, i) => _CommentAttachmentPreview(
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
                  tooltip: '이미지 첨부',
                ),
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  onPressed: _sending ? null : _pickFile,
                  tooltip: '파일 첨부',
                ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '댓글 입력',
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                  ),
                ),
                if (_sending)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: _send,
                    tooltip: '댓글 보내기',
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 보내기 전 첨부 미리보기 한 칸(ChatInputBar의 _AttachmentPreview와 동일한 모양).
class _CommentAttachmentPreview extends StatelessWidget {
  final _PendingAttachment attachment;
  final VoidCallback onRemove;
  const _CommentAttachmentPreview({
    required this.attachment,
    required this.onRemove,
  });

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
              child: Image.file(
                attachment.file,
                width: 56,
                height: 56,
                fit: BoxFit.cover,
              ),
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
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, size: 12, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
