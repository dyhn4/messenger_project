import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';

import '../data/stickers.dart';
import '../services/api_client.dart' show UploadCancelToken, UploadCancelledException;
import '../services/file_type_utils.dart';
import '../services/image_thumbnail.dart';
import '../services/room_chat_controller.dart';
import 'attachment_widgets.dart';

/// ChatInputBar의 _PendingAttachment와 동일한 목적 — 첨부한 즉시 업로드가 시작되고,
/// [result]가 채워지면 업로드가 끝난 것.
class _PendingAttachment {
  final File file;
  final bool isImage;
  final String displayName;
  final int totalBytes;
  final Uint8List? thumbnailBytes;
  final UploadCancelToken cancelToken;
  int sentBytes = 0;
  UploadedAttachment? result;

  _PendingAttachment({
    required this.file,
    required this.isImage,
    required this.displayName,
    required this.totalBytes,
    required this.thumbnailBytes,
    required this.cancelToken,
  });
}

/// 댓글 입력창. ChatInputBar와 같은 이미지/파일 첨부(클립보드로 캡처한 이미지 붙여넣기 포함)를
/// 지원하는 축소판이라, 콜백 대신 controller+messageId를 직접 받아 postComment/
/// postUploadedCommentAttachment를 호출한다.
class CommentInputBar extends StatefulWidget {
  final RoomChatController controller;
  final String messageId;

  /// ChatInputBar와 동일 — 이모티콘 패널/미리보기는 message_thread_screen.dart가 댓글 목록
  /// 위에 떠 있는 오버레이로 그리므로, 상태는 부모가 들고 여기는 버튼과 전송만 담당한다.
  final Sticker? pendingSticker;
  final bool stickerPickerOpen;
  final VoidCallback onToggleStickerPicker;
  final VoidCallback onStickerConsumed;

  const CommentInputBar({
    super.key,
    required this.controller,
    required this.messageId,
    this.pendingSticker,
    this.stickerPickerOpen = false,
    required this.onToggleStickerPicker,
    required this.onStickerConsumed,
  });

  @override
  State<CommentInputBar> createState() => CommentInputBarState();
}

/// ChatInputBarState와 같은 이유로 public — message_thread_screen.dart가 GlobalKey로 접근해
/// addDroppedFiles를 호출한다.
class CommentInputBarState extends State<CommentInputBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _attachments = <_PendingAttachment>[];
  bool _sending = false;

  bool get _uploading => _attachments.any((a) => a.result == null);

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
    unawaited(_stageAndUpload(file, true, 'image.png'));
  }

  Future<void> _pickImage() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (picked == null) return;
    unawaited(_stageAndUpload(File(picked.path), true, picked.name));
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles();
    final picked = result?.files.single;
    if (picked?.path == null) return;
    unawaited(_stageAndUpload(File(picked!.path!), false, picked.name));
  }

  /// ChatInputBarState.addDroppedFiles와 동일 — message_thread_screen.dart의 DropTarget이 호출.
  void addDroppedFiles(List<File> files) {
    if (files.isEmpty || !mounted) return;
    for (final file in files) {
      unawaited(
        _stageAndUpload(
          file,
          looksLikeImagePath(file.path),
          file.uri.pathSegments.last,
        ),
      );
    }
  }

  /// ChatInputBarState._stageAndUpload와 동일 — 첨부를 즉시 스테이징 목록에 넣고 곧바로
  /// 서버 업로드를 시작한다.
  Future<void> _stageAndUpload(
    File file,
    bool isImage,
    String displayName,
  ) async {
    final bytes = await file.readAsBytes();
    final thumbBytes = isImage ? await generateThumbnail(bytes) : null;
    if (!mounted) return;

    final attachment = _PendingAttachment(
      file: file,
      isImage: isImage,
      displayName: displayName,
      totalBytes: bytes.length,
      thumbnailBytes: thumbBytes,
      cancelToken: UploadCancelToken(),
    );
    setState(() => _attachments.add(attachment));

    try {
      final uploaded = await widget.controller.uploadAttachment(
        file,
        isImage: isImage,
        originalBytes: bytes,
        thumbBytes: thumbBytes,
        onProgress: (sent, total) {
          if (!mounted) return;
          setState(() => attachment.sentBytes = sent);
        },
        cancelToken: attachment.cancelToken,
      );
      if (!mounted) return;
      setState(() => attachment.result = uploaded);
    } on UploadCancelledException {
      // 조용히 무시 — X 버튼으로 이미 목록에서 제거됨.
    } catch (e) {
      if (!mounted) return;
      setState(() => _attachments.remove(attachment));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('업로드 실패: $e')));
    }
  }

  void _cancelAttachment(_PendingAttachment a) {
    a.cancelToken.cancel();
    setState(() => _attachments.remove(a));
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    final sticker = widget.pendingSticker;
    if (_attachments.isEmpty && text.isEmpty && sticker == null) return;
    if (_uploading) return;

    final toSend = List<_PendingAttachment>.from(_attachments);
    setState(() {
      _attachments.clear();
      _sending = true;
    });
    _controller.clear();
    widget.onStickerConsumed();
    _focusNode.requestFocus();

    try {
      // 이모티콘이 타임라인에서 댓글보다 먼저(위에) 보이도록 순서대로 보낸다(동시 아님).
      if (sticker != null) {
        await widget.controller.postCommentSticker(
          widget.messageId,
          sticker.id,
        );
      }

      if (toSend.isEmpty) {
        await widget.controller.postComment(widget.messageId, text);
      } else {
        // 첨부와 함께 입력한 댓글은 별도 댓글로 보내지 않고, 첫 번째 첨부의 캡션으로 붙인다.
        // 업로드는 첨부하는 순간 이미 끝나 있으므로(_stageAndUpload) 여기선 그 결과로 댓글만 단다.
        for (var i = 0; i < toSend.length; i++) {
          final a = toSend[i];
          await widget.controller.postUploadedCommentAttachment(
            widget.messageId,
            a.result!,
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
    final uploading = _uploading;
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
                  height: uploading ? 160 : 64,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: _attachments.length,
                    itemBuilder: (context, i) {
                      final a = _attachments[i];
                      if (a.result == null) {
                        return Padding(
                          padding: const EdgeInsets.only(right: 10, top: 6),
                          child: UploadingAttachment(
                            thumbnailBytes: a.thumbnailBytes,
                            displayName: a.displayName,
                            totalBytes: a.totalBytes,
                            sentBytes: a.sentBytes,
                            onCancel: () => _cancelAttachment(a),
                          ),
                        );
                      }
                      return _ReadyCommentAttachmentChip(
                        attachment: a,
                        onRemove: () => _cancelAttachment(a),
                      );
                    },
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
                  icon: Icon(
                    Icons.emoji_emotions_outlined,
                    color: widget.stickerPickerOpen
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  onPressed: _sending ? null : widget.onToggleStickerPicker,
                  tooltip: '이모티콘',
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
                    onPressed: uploading ? null : _send,
                    tooltip: uploading ? '업로드가 끝나면 보낼 수 있어요' : '댓글 보내기',
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 보내기 전 첨부 미리보기 한 칸(ChatInputBar의 _ReadyAttachmentChip과 동일한 모양).
class _ReadyCommentAttachmentChip extends StatelessWidget {
  final _PendingAttachment attachment;
  final VoidCallback onRemove;
  const _ReadyCommentAttachmentChip({
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
          if (attachment.thumbnailBytes != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                attachment.thumbnailBytes!,
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
