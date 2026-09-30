import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import '../data/stickers.dart';
import '../services/api_client.dart'
    show UploadCancelToken, UploadCancelledException;
import '../services/file_type_utils.dart';
import '../services/image_thumbnail.dart';
import '../services/mention_logic.dart';
import '../services/room_chat_controller.dart';
import '../services/typing_gate.dart';
import 'attachment_widgets.dart';
import 'mention_autocomplete.dart';
import 'muted_scrollbar.dart';
import 'rich_text_format.dart';

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

  /// ChatInputBar.stickerPickerGroupId와 동일 — 이 버튼을 패널(StickerPicker)과 같은
  /// TapRegion 그룹으로 묶어서, 버튼으로 닫을 때 onTapOutside가 먼저 닫고 onPressed가
  /// 다시 여는 깜빡임을 막는다.
  final Object stickerPickerGroupId;
  final VoidCallback onToggleStickerPicker;
  final VoidCallback onStickerConsumed;

  const CommentInputBar({
    super.key,
    required this.controller,
    required this.messageId,
    this.pendingSticker,
    this.stickerPickerOpen = false,
    required this.stickerPickerGroupId,
    required this.onToggleStickerPicker,
    required this.onStickerConsumed,
  });

  @override
  State<CommentInputBar> createState() => CommentInputBarState();
}

/// ChatInputBarState와 같은 이유로 public — message_thread_screen.dart가 GlobalKey로 접근해
/// addDroppedFiles를 호출한다.
class CommentInputBarState extends State<CommentInputBar> {
  final _controller = RichTextEditingController();
  final _focusNode = FocusNode();
  final _mentionKey = GlobalKey<MentionAutocompleteState>();
  final _attachments = <_PendingAttachment>[];
  bool _sending = false;

  /// 서식 도구모음을 펼쳤는지(ChatInputBarState와 동일).
  bool _formatOpen = false;

  bool get _uploading => _attachments.any((a) => a.result == null);

  /// ChatInputBarState.focusInput과 같은 이유 — 이모티콘을 고른 직후 입력칸으로 포커스를
  /// 되돌려서, 곧바로 Enter를 눌러도 보내지도록 한다(message_thread_screen.dart의
  /// _selectSticker 참고).
  void focusInput() => _focusNode.requestFocus();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
    _controller.formattingEnabled = !widget.controller.room.isSecret;
    // ChatInputBarState와 동일 — 포커스를 얻으면 안내 문구를 감춘다.
    _focusNode.addListener(_onFocusChange);
    _controller.addListener(_onTextChanged);
  }

  /// 한글 등을 IME로 조합하는 중이면, 그동안 앱 전체를 다시 그리는 알림을 잠깐 미룬다 — 빠르게
  /// 칠 때 그 다시 그리기가 키 처리를 늦춰서 글자가 빠지거나 뭉개지던 문제(typing_gate.dart).
  void _onTextChanged() {
    final composing = _controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      TypingGate.instance.composing();
    } else {
      TypingGate.instance.committed();
    }
  }

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _focusNode.removeListener(_onFocusChange);
    _controller.removeListener(_onTextChanged);
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
      return false;
    }
    // ChatInputBarState와 동일 — 환경설정 "메시지 전송 옵션"대로(기본: Enter 전송·Shift+Enter 줄바꿈).
    // 멘션 자동완성 목록이 떠 있으면 Enter는 목록에서 고르는 데 쓴다(mention_autocomplete.dart).
    if (_mentionKey.currentState?.isOpen == true) return false;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final sendKey = widget.controller.session.settings.sendWithShiftEnter
        ? shift
        : !shift;
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        _focusNode.hasFocus &&
        sendKey) {
      _send();
      return true;
    }
    return false;
  }

  Future<void> _pasteImageFromClipboard() async {
    final bytes = await Pasteboard.image;
    if (bytes == null || bytes.isEmpty || !mounted) {
      return; // 클립보드에 이미지가 없으면 아무 것도 안 함.
    }

    final path =
        '${Directory.systemTemp.path}${Platform.pathSeparator}image_${DateTime.now().microsecondsSinceEpoch}.png';
    final file = File(path);
    await file.writeAsBytes(bytes);
    if (!mounted) return;
    unawaited(_stageAndUpload(file, true, 'image.png'));
  }

  /// 이미지든 아니든 이 버튼 하나로 고른다 — 이미지인지는 확장자로 판별해서(끌어다 놓기와
  /// 같은 방식) 이미지면 썸네일을 만들어 미리보기로 보여준다. 여러 개도 한 번에 고를 수 있다.
  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    final picked = result?.files ?? const [];
    if (picked.isEmpty || !mounted) return;
    for (final file in picked) {
      final path = file.path;
      if (path == null) continue;
      unawaited(
        _stageAndUpload(File(path), looksLikeImagePath(path), file.name),
      );
    }
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
    final (:text, :format) = _controller.formatted();
    final mentions = mentionsToSend(
      _controller,
      widget.controller.room,
      widget.controller.session.userId,
    );
    final sticker = widget.pendingSticker;
    if (_attachments.isEmpty && text.isEmpty && sticker == null) return;
    if (_uploading) return;

    final toSend = List<_PendingAttachment>.from(_attachments);
    setState(() {
      _attachments.clear();
      _sending = true;
    });
    _controller.clear();
    // 조합하느라 미뤄 둔 화면 갱신을 지금 내보낸다 — 보낸 메시지가 바로 보이게.
    TypingGate.instance.flush();
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
        await widget.controller.postComment(
          widget.messageId,
          text,
          format: format,
          mentions: mentions,
        );
      } else {
        // 첨부와 함께 입력한 댓글은 별도 댓글로 보내지 않고, 첫 번째 첨부의 캡션으로 붙인다.
        // 업로드는 첨부하는 순간 이미 끝나 있으므로(_stageAndUpload) 여기선 그 결과로 댓글만 단다.
        for (var i = 0; i < toSend.length; i++) {
          final a = toSend[i];
          await widget.controller.postUploadedCommentAttachment(
            widget.messageId,
            a.result!,
            caption: i == 0 ? text : null,
            captionFormat: i == 0 ? format : null,
            captionMentions: i == 0 ? mentions : null,
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
          // ChatInputBarState와 동일 — 입력칸이 이 칸 전체 폭을 채우도록 stretch로 둔다.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_attachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  // ChatInputBarState와 동일 — 업로드 중이든 끝났든 같은 카드를 그대로
                  // 쓰므로(UploadingAttachment.completed) 높이를 바꿀 필요가 없다.
                  height: 80,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: _attachments.length,
                    itemBuilder: (context, i) {
                      final a = _attachments[i];
                      return Padding(
                        padding: const EdgeInsets.only(right: 10, top: 6),
                        child: UploadingAttachment(
                          thumbnailBytes: a.thumbnailBytes,
                          displayName: a.displayName,
                          totalBytes: a.totalBytes,
                          sentBytes: a.sentBytes,
                          completed: a.result != null,
                          onCancel: () => _cancelAttachment(a),
                        ),
                      );
                    },
                  ),
                ),
              ),
            // ChatInputBarState와 동일 — 입력칸을 위에 두고, 첨부 아이콘+보내기 버튼은
            // 그 아래 별도 줄에 둔다. TextField(EditableText)는 여러 줄일 때 조상
            // ScrollConfiguration과 무관하게 항상 자체 스크롤바를 강제로 붙이므로, 따로
            // Scrollbar를 얹지 않고 그 자동 스크롤바에 이 테마만 씌운다.
            RichFormatFrame(
              open: _formatOpen,
              focused: _focusNode.hasFocus,
              toolbar: RichFormatToolbar(
                controller: _controller,
                focusNode: _focusNode,
              ),
              child: ScrollbarTheme(
                data: mutedScrollbarThemeData,
                child: MentionAutocomplete(
                  key: _mentionKey,
                  controller: _controller,
                  focusNode: _focusNode,
                  room: widget.controller.room,
                  myUserId: widget.controller.session.userId,
                  resolveUrl: widget.controller.session.resolveUrl,
                  child: RichFieldWrapper(
                    controller: _controller,
                    child: TextField(
                      key: const ValueKey('comment-input'),
                      controller: _controller,
                      focusNode: _focusNode,
                      autofocus: true,
                      decoration: InputDecoration(
                        // 포커스를 얻으면(클릭/터치) 안내 문구 자체를 감춰서 커서만 보이게
                        // 한다(_onFocusChange가 포커스 변화 시 다시 그림).
                        hintText: _focusNode.hasFocus ? null : '댓글 입력',
                        border: _formatOpen
                            ? InputBorder.none
                            : const OutlineInputBorder(),
                        // ChatInputBarState와 동일 — 오른쪽만 줄여서 스크롤바를 테두리에
                        // 가깝게 붙인다.
                        contentPadding: const EdgeInsets.fromLTRB(
                          12,
                          12,
                          2,
                          12,
                        ),
                      ),
                      minLines: 1,
                      maxLines: 6,
                      // ChatInputBarState와 동일 — Windows에서 .send는 Shift 여부와
                      // 무관하게 Enter를 전부 제출로 처리해버려서 .newline으로 두고
                      // _handleKey가 순수 Enter만 직접 가로채 보낸다.
                      textInputAction: Platform.isWindows
                          ? TextInputAction.newline
                          : TextInputAction.send,
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            // ChatInputBarState와 동일 — 검색/멤버/스레드 패널이 열려 있으면 이 입력칸 폭이
            // 좁아질 수 있어서, 남는 폭이 안내 문구까지 담기엔 부족하면 그 문구부터 먼저
            // 숨긴다(오버플로 방지).
            LayoutBuilder(
              builder: (context, constraints) {
                final showHint =
                    Platform.isWindows && constraints.maxWidth > 320;
                return Row(
                  children: [
                    TapRegion(
                      groupId: widget.stickerPickerGroupId,
                      child: IconButton(
                        icon: Icon(
                          Icons.emoji_emotions_outlined,
                          color: widget.stickerPickerOpen
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        onPressed: _sending
                            ? null
                            : widget.onToggleStickerPicker,
                        tooltip: '이모티콘',
                      ),
                    ),
                    if (roomAllowsMention(widget.controller.room))
                      MentionButton(
                        onPressed: _sending
                            ? null
                            : () => _mentionKey.currentState?.insertTrigger(),
                      ),
                    IconButton(
                      icon: const Icon(Icons.attach_file),
                      onPressed: _sending ? null : _pickFile,
                      tooltip: '파일 첨부',
                    ),
                    if (!widget.controller.room.isSecret)
                      RichFormatToggleButton(
                        open: _formatOpen,
                        onPressed: () {
                          setState(() => _formatOpen = !_formatOpen);
                          _focusNode.requestFocus();
                        },
                      ),
                    const Spacer(),
                    if (showHint) ...[
                      Text(
                        widget.controller.session.settings.sendWithShiftEnter
                            ? 'Shift + Enter 로 전송'
                            : 'Shift + Enter 로 줄바꿈',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
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
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
