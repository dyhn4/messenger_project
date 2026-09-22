import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';

import '../data/stickers.dart';
import '../models/inquiry.dart';
import '../models/room.dart';
import '../services/api_client.dart'
    show UploadCancelToken, UploadCancelledException;
import '../services/file_type_utils.dart';
import '../services/image_thumbnail.dart';
import '../services/room_chat_controller.dart';
import '../services/session.dart';
import '../screens/capture/capture_window.dart';
import 'app_toast.dart';
import 'attachment_widgets.dart';
import 'call_button.dart';
import 'capture_upload_dialog.dart';
import 'muted_scrollbar.dart';

/// 첨부 하나의 클라이언트 쪽 진행 상태. 첨부한 즉시(_ChatInputBarState._stageAndUpload)
/// 업로드가 시작되고, [result]가 채워지면 업로드가 끝난 것 — "보내기"는 이미 끝난 결과만
/// RoomChatController.sendUploadedAttachment에 넘긴다(다시 올리지 않는다).
class _PendingAttachment {
  final File file;
  final bool isImage;
  final String displayName;
  final int totalBytes;
  final Uint8List? thumbnailBytes;
  final UploadCancelToken cancelToken;

  /// 업로드 진행률(바이트) — RoomChatController.uploadAttachment의 onProgress가 갱신한다.
  int sentBytes = 0;

  /// 업로드가 끝나면 채워진다. null인 동안은 아직 업로드 중.
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

class ChatInputBar extends StatefulWidget {
  final RoomChatController controller;

  /// 화상회의 버튼(CallButton)을 이 입력칸 버튼 줄에 그리는 데 필요하다 — 원래 채팅 헤더에
  /// 있었는데, 입력칸 아래 다른 첨부 버튼들과 나란히 있는 게 더 눈에 잘 띄어서 옮겼다.
  final Session session;
  final Room room;

  /// 이모티콘 패널/미리보기는 이제 채팅 화면(chat_panel.dart)이 메시지 목록 위에 떠 있는
  /// 오버레이로 그린다(입력창을 밀어내지 않기 위해) — 그래서 상태 자체도 이 위젯이 아니라
  /// 부모가 들고 있고, 여기는 버튼과 "보낼 때 같이 실어 보내기"만 담당한다.
  final Sticker? pendingSticker;
  final bool stickerPickerOpen;

  /// 이모티콘 토글 버튼을 패널(chat_panel.dart의 StickerPicker)과 같은 TapRegion 그룹으로
  /// 묶는 값 — 안 묶으면 패널이 열린 상태에서 이 버튼을 눌러 닫으려는 탭이 "패널 바깥 탭"으로도
  /// 잡혀서, onTapOutside가 먼저(pointer down) 닫고 이 버튼의 onPressed(pointer up)가 다시
  /// 열어버리는 깜빡임이 생긴다.
  final Object stickerPickerGroupId;
  final VoidCallback onToggleStickerPicker;

  /// 전송 시도 후(성공하든 실패하든 다른 첨부와 동일하게 낙관적으로) 부모가 pendingSticker를
  /// 지우도록 알린다.
  final VoidCallback onStickerConsumed;

  const ChatInputBar({
    super.key,
    required this.controller,
    required this.session,
    required this.room,
    this.pendingSticker,
    this.stickerPickerOpen = false,
    required this.stickerPickerGroupId,
    required this.onToggleStickerPicker,
    required this.onStickerConsumed,
  });

  @override
  State<ChatInputBar> createState() => ChatInputBarState();
}

/// 클릭으로 첨부를 고르는 것과 완전히 같은 스테이징 목록(_attachments)에 드래그앤드롭으로
/// 받은 파일도 추가할 수 있도록, 부모(chat_panel.dart)가 GlobalKey로 이 State에 접근해
/// addDroppedFiles를 호출할 수 있게 public으로 둔다(다른 필드/메서드는 계속 private).
class ChatInputBarState extends State<ChatInputBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _attachments = <_PendingAttachment>[];
  bool _sending = false;

  /// 첨부 중 하나라도 아직 업로드가 안 끝났으면 true — "보내기"를 비활성화하는 데 쓴다
  /// (사용자가 큰 파일을 올리는 동안 텍스트만 먼저 보내는 것도 헷갈릴 수 있어, 업로드가 다
  /// 끝날 때까지 통째로 막는 쪽을 택했다).
  bool get _uploading => _attachments.any((a) => a.result == null);

  /// 이모티콘 패널에서 하나를 고르면(chat_panel.dart의 _selectSticker) 부모가 GlobalKey로
  /// 이걸 불러 입력칸에 포커스를 되돌린다 — 안 그러면 이모티콘을 클릭한 뒤 곧바로 Enter를
  /// 눌러도 _handleKey의 "입력칸이 포커스를 갖고 있을 때만 Enter=보내기" 조건에 걸려 아무
  /// 일도 안 일어난다(이모티콘 그리드 칸을 누른 시점엔 입력칸이 포커스를 안 갖고 있으므로).
  void focusInput() => _focusNode.requestFocus();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
    // 포커스를 얻으면(클릭/터치) 안내 문구(hintText)를 바로 감추고 커서만 보이게 한다 —
    // hintText는 build() 시점 값이라 포커스가 바뀔 때 다시 그려줘야 반영된다.
    _focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _focusNode.removeListener(_onFocusChange);
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
      return false;
    }
    // Enter는 보내기, Shift+Enter만 줄바꿈으로 남긴다 — true를 돌려줘서 TextField의 기본
    // 줄바꿈 삽입을 막아야 한다(안 그러면 Enter를 눌러도 줄바꿈이 먼저 들어가 버린다).
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        _focusNode.hasFocus &&
        !HardwareKeyboard.instance.isShiftPressed) {
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

  bool _capturing = false;

  /// "화면 캡처" — 화면을 찍어 전체 화면 오버레이에서 영역을 고르게 하고(capture_window.dart),
  /// 결과에 따라 업로드 대화상자/바로 보내기/저장을 한다. [hideMessenger]는 찍는 동안 메신저
  /// 창을 숨길지(메신저가 캡처에 안 찍힘) 여부.
  Future<void> _startCapture(bool hideMessenger) async {
    if (_capturing) return;
    setState(() => _capturing = true);
    CaptureOutcome? outcome;
    try {
      outcome = await startScreenCapture(hideMessenger: hideMessenger);
    } catch (e) {
      if (mounted) showAppToast(context, '화면을 캡처하지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
    if (outcome?.error != null && mounted) {
      showAppToast(context, '화면을 캡처하지 못했습니다: ${outcome!.error}');
    }
    final file = outcome?.file;
    if (outcome == null || file == null || !mounted) return;
    switch (outcome.action) {
      case 'send':
        await _uploadCapture(widget.room, file, '');
      case 'dialog':
        final choice = await showCaptureUploadDialog(
          context,
          session: widget.session,
          initialRoom: widget.room,
          file: file,
        );
        if (choice != null) {
          await _uploadCapture(choice.room, file, choice.message);
        }
      case 'save':
        await _saveCapture(file);
    }
  }

  /// [room]에 캡처 이미지를 올려서 바로 보낸다. 다른 방에 올릴 수도 있어서(업로드 대화상자의
  /// 공유 대화방) 그 방의 컨트롤러를 따로 가져온다.
  Future<void> _uploadCapture(Room room, File file, String caption) async {
    final controller = widget.session.controllerFor(room);
    if (mounted) showAppToast(context, '캡처를 업로드하는 중입니다...');
    try {
      final bytes = await file.readAsBytes();
      final thumb = await generateThumbnail(bytes);
      final uploaded = await controller.uploadAttachment(
        file,
        isImage: true,
        originalBytes: bytes,
        thumbBytes: thumb,
      );
      await controller.sendUploadedAttachment(uploaded, caption: caption);
      if (mounted) showAppToast(context, '캡처를 보냈습니다.');
    } catch (e) {
      if (mounted) showAppToast(context, '캡처를 보내지 못했습니다: $e');
    }
  }

  Future<void> _saveCapture(File file) async {
    final name = file.uri.pathSegments.last;
    final path = await FilePicker.saveFile(
      dialogTitle: '캡처 저장',
      fileName: name,
      type: FileType.custom,
      allowedExtensions: ['png'],
    );
    if (path == null) return;
    try {
      await file.copy(path.toLowerCase().endsWith('.png') ? path : '$path.png');
      if (mounted) showAppToast(context, '캡처를 저장했습니다.');
    } catch (e) {
      if (mounted) showAppToast(context, '저장하지 못했습니다: $e');
    }
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

  /// "문의하기" — 분류/제목/내용(+선택 첨부)을 입력받아 서버에 문의(티켓)를 만들고, 팀장이
  /// 대화 목록에서도 바로 볼 수 있도록 같은 내용을 일반 메시지로도 그 방에 보낸다. 티켓 생성이
  /// 실패하면 메시지도 안 보낸다(팀장이 못 찾는 "고아" 메시지가 남는 걸 막는다).
  Future<void> _showInquiryDialog() async {
    final result =
        await showDialog<(String, String, String, UploadedAttachment?)>(
          context: context,
          builder: (_) => _InquiryDialog(controller: widget.controller),
        );
    if (result == null || !mounted) return;
    final (category, title, content, attachment) = result;
    final text = '📩 문의 [$category] $title\n\n$content';
    try {
      final inquiry = await widget.session.api!.createInquiry(
        widget.room.id,
        category: category,
        title: title,
        content: content,
        fileUrl: attachment?.url,
        fileName: attachment?.fileName,
        fileSize: attachment?.size,
        mimeType: attachment?.mimeType,
        thumbnailUrl: attachment?.thumbnailUrl,
      );
      await widget.session.chatSocket.send(
        roomId: widget.room.id,
        type: attachment == null
            ? 'text'
            : (attachment.isImage ? 'image' : 'file'),
        text: text,
        fileUrl: attachment?.url,
        fileName: attachment?.fileName,
        fileSize: attachment?.size,
        mimeType: attachment?.mimeType,
        thumbnailUrl: attachment?.thumbnailUrl,
        inquiryId: inquiry.id,
      );
      if (mounted) showAppToast(context, '문의를 보냈습니다.');
    } catch (e) {
      if (mounted) showAppToast(context, '문의를 보내지 못했습니다: $e');
    }
  }

  /// 파일 탐색기에서 채팅 입력칸(또는 chat_panel.dart 전체)으로 끌어다 놓은 파일들을 추가한다
  /// (chat_panel.dart의 DropTarget.onDragDone에서 호출). 클릭으로 고를 때(_pickImage/_pickFile)와
  /// 완전히 같은 방식으로 즉시 업로드가 시작된다 — 다만 "어느 버튼으로 골랐는지" 신호가 없어서
  /// 이미지 여부는 확장자로 판별한다(looksLikeImagePath).
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

  /// 첨부 하나를 스테이징 목록에 즉시 추가하고(썸네일/용량이 바로 보이도록), 곧바로 서버
  /// 업로드를 시작한다 — "보내기"를 누르기 전부터 진행률이 보이고, 실제로 보내기를 누르는
  /// 시점엔 이미 업로드가 끝나 있어 지연 없이 바로 전송된다.
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
      // 조용히 무시 — X 버튼으로 이미 목록에서 제거됨(_cancelAttachment 참고).
    } catch (e) {
      if (!mounted) return;
      setState(() => _attachments.remove(attachment));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('업로드 실패: $e')));
    }
  }

  /// 업로드 중이든 이미 끝났든 상관없이 첨부를 취소/제거한다. 아직 업로드 중이면
  /// cancelToken으로 네트워크 전송 자체를 중단시킨다(ApiClient.uploadFile 참고).
  void _cancelAttachment(_PendingAttachment a) {
    a.cancelToken.cancel();
    setState(() => _attachments.remove(a));
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    final sticker = widget.pendingSticker;
    if (_attachments.isEmpty && text.isEmpty && sticker == null) return;
    if (_uploading) return; // 버튼 자체도 막지만, 이중 방어.

    final toSend = List<_PendingAttachment>.from(_attachments);
    setState(() {
      _attachments.clear();
      _sending = true;
    });
    _controller.clear();
    widget.onStickerConsumed();
    // 보내기 버튼을 마우스로 눌렀을 때 포커스가 버튼으로 넘어가버리는 걸 막고, 계속
    // 이어서 입력할 수 있도록 입력칸에 커서를 유지한다.
    _focusNode.requestFocus();

    try {
      // 이모티콘과 메시지는 같은 말풍선으로 합치지 않고 각자 메시지로 보내되, 이모티콘이
      // 타임라인에서 메시지보다 먼저(위에) 보이도록 반드시 순서대로(동시 아님) 보낸다.
      if (sticker != null) await widget.controller.sendSticker(sticker.id);

      if (toSend.isEmpty) {
        await widget.controller.sendText(text);
      } else {
        // 첨부와 함께 입력한 메시지는 별도 메시지로 보내지 않고, 첫 번째 첨부의 캡션으로
        // 붙인다. 업로드는 첨부하는 순간 이미 끝나 있으므로(_stageAndUpload) 여기선 그
        // 결과로 메시지만 보낸다.
        for (var i = 0; i < toSend.length; i++) {
          final a = toSend[i];
          await widget.controller.sendUploadedAttachment(
            a.result!,
            caption: i == 0 ? text : null,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('전송 실패: $e')));
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
          // 입력칸(TextField)이 이 칸 전체 폭을 채우도록(예전엔 Row 안 Expanded로
          // 채웠지만, 이제는 입력칸이 직접 자식이라 stretch로 채운다).
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_attachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  // 이미지 카드(200x64)와 파일 카드가 들어갈 수 있는 고정 높이 — 업로드
                  // 중이든 끝났든 같은 카드(UploadingAttachment)를 그대로 쓰므로(완료돼도
                  // 다른 위젯으로 안 바뀜) 높이를 상태에 따라 바꿀 필요가 없다.
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
            // 입력칸을 위에 두고, 첨부 아이콘+보내기 버튼은 그 아래 별도 줄에 둔다(첨부
            // 이미지 참고 — 예전엔 입력칸과 같은 줄 왼쪽/오른쪽에 있었다).
            // TextField(EditableText)는 여러 줄일 때 조상 ScrollConfiguration과 무관하게
            // 항상 자체 스크롤바를 강제로 붙인다(TextField에 그 동작을 끌 방법도 없다) —
            // 그래서 따로 Scrollbar를 얹지 않고, 그 자동 스크롤바가 이 테마를 그대로
            // 입도록(채팅방과 같은 두께 10px, 항상 보임) ScrollbarTheme만 씌운다.
            ScrollbarTheme(
              data: mutedScrollbarThemeData,
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                decoration: InputDecoration(
                  // 포커스를 얻으면(클릭/터치) 안내 문구 자체를 감춰서 커서만 보이게
                  // 한다(_onFocusChange가 포커스 변화 시 다시 그림).
                  hintText: _focusNode.hasFocus ? null : '메시지 입력',
                  border: const OutlineInputBorder(),
                  // 기본 오른쪽 여백(12)이면 스크롤바가 테두리에서 너무 떨어져
                  // 보인다 — 오른쪽만 줄여서 스크롤바를 테두리에 가깝게 붙인다.
                  contentPadding: const EdgeInsets.fromLTRB(12, 12, 2, 12),
                ),
                minLines: 1,
                maxLines: 6,
                // Windows(물리 키보드)에서는 textInputAction이 .send면 Flutter가
                // Shift 여부와 무관하게 Enter를 전부 "제출"로 처리해버려서(줄바꿈이
                // 아예 안 먹힘) .newline으로 둬서 기본 동작은 항상 줄바꿈으로 만들고,
                // 대신 순수 Enter(=Shift 안 눌림)는 _handleKey가 가로채 직접 보낸다.
                // 모바일은 소프트 키보드의 "전송" 액션 버튼이 주 전송 수단이라 .send를
                // 그대로 둔다.
                textInputAction: Platform.isWindows
                    ? TextInputAction.newline
                    : TextInputAction.send,
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(height: 4),
            // 검색/멤버/스레드 패널이 열려 있으면 이 입력칸이 차지하는 폭이 창 크기에 따라
            // 꽤 좁아질 수 있다 — 아이콘 3개+안내 문구+보내기 버튼을 고정 Row로만 두면
            // 특정 폭 구간에서 폭이 모자라 오버플로(노란/검정 줄무늬 경고)가 났다. 남는
            // 폭이 안내 문구까지 담기엔 부족하면 그 문구부터 먼저 숨긴다.
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
                    // 화면 캡처는 Windows 전용 — 누르면 메신저 창을 숨기고 찍을지 포함해서
                    // 찍을지 먼저 고른다.
                    if (Platform.isWindows)
                      PopupMenuButton<bool>(
                        icon: const Icon(Icons.filter_center_focus),
                        tooltip: '화면 캡처',
                        enabled: !_sending && !_capturing,
                        onSelected: _startCapture,
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: true,
                            child: Text('메신저 창 숨기고 캡처'),
                          ),
                          PopupMenuItem(
                            value: false,
                            child: Text('메신저 창 포함하여 캡처'),
                          ),
                        ],
                      ),
                    CallButton(session: widget.session, room: widget.room),
                    // 이 DM 상대가 내 팀의 "팀장"일 때만 보인다(session.canSendInquiryIn).
                    if (widget.session.canSendInquiryIn(widget.room))
                      IconButton(
                        icon: const Icon(Icons.contact_support_outlined),
                        onPressed: _sending ? null : _showInquiryDialog,
                        tooltip: '팀장에게 문의하기',
                      ),
                    const Spacer(),
                    if (showHint) ...[
                      Text(
                        'Shift + Enter 로 줄바꿈',
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
                        tooltip: uploading ? '업로드가 끝나면 보낼 수 있어요' : '보내기',
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

/// "문의하기" 작성 대화상자 — 분류(고정 목록)/제목/내용을 입력받는다. 완료를 누르면
/// (분류, 제목, 내용) 튜플을 돌려준다.
class _InquiryDialog extends StatefulWidget {
  final RoomChatController controller;
  const _InquiryDialog({required this.controller});

  @override
  State<_InquiryDialog> createState() => _InquiryDialogState();
}

class _InquiryDialogState extends State<_InquiryDialog> {
  String _category = inquiryCategories.first;
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();

  /// 첨부 하나(선택) — 고르는 즉시 업로드가 시작된다(_ChatInputBarState._stageAndUpload와
  /// 같은 방식). [result]가 채워지기 전엔 "보내기"를 못 누른다.
  _PendingAttachment? _attachment;

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
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
    setState(() => _attachment = attachment);

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
      if (!mounted || _attachment != attachment) return;
      setState(() => attachment.result = uploaded);
    } on UploadCancelledException {
      // 조용히 무시 — X 버튼으로 이미 비워짐(_removeAttachment 참고).
    } catch (e) {
      if (!mounted) return;
      setState(() => _attachment = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('첨부 업로드 실패: $e')));
    }
  }

  void _removeAttachment() {
    final attachment = _attachment;
    if (attachment == null) return;
    if (attachment.result == null) attachment.cancelToken.cancel();
    setState(() => _attachment = null);
  }

  @override
  Widget build(BuildContext context) {
    final attachment = _attachment;
    final uploading = attachment != null && attachment.result == null;
    // 420은 PC 기준 값 — 좁은 화면(안드로이드)에서는 그대로 두면 대화상자 가용 폭을 넘어서
    // 자식(특히 첨부 미리보기 줄)이 밀려나거나 겹쳐 보일 수 있어 화면 폭에 맞춰 줄인다.
    final dialogWidth = math.min(420.0, MediaQuery.sizeOf(context).width - 64);
    return AlertDialog(
      title: const Text('팀장에게 문의하기'),
      content: SizedBox(
        width: dialogWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _category,
              decoration: const InputDecoration(
                labelText: '분류',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final c in inquiryCategories)
                  DropdownMenuItem(value: c, child: Text(c)),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _category = v);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _titleController,
              autofocus: true,
              maxLength: 100,
              decoration: const InputDecoration(
                labelText: '제목',
                border: OutlineInputBorder(),
              ),
            ),
            TextField(
              controller: _contentController,
              maxLines: 6,
              minLines: 3,
              maxLength: 2000,
              decoration: const InputDecoration(
                labelText: '내용',
                hintText: '문의 내용을 입력하세요',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            // 첨부는 하나만 붙일 수 있어서, 이미 하나 있으면 이 버튼들은 숨기지 않고
            // 그냥 비활성화만 한다 — 버튼이 통째로 사라지면(예전엔 if/else로 바꿔치기했다)
            // 미리보기 칸과 자리가 겹쳐서 파일명이 버튼을 가리는 것처럼 보였다.
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: attachment == null ? _pickImage : null,
                  icon: const Icon(Icons.image_outlined, size: 18),
                  label: const Text('이미지'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: attachment == null ? _pickFile : null,
                  icon: const Icon(Icons.attach_file, size: 18),
                  label: const Text('파일'),
                ),
              ],
            ),
            if (attachment != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      attachment.isImage
                          ? Icons.image_outlined
                          : Icons.insert_drive_file_outlined,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        attachment.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    if (uploading) ...[
                      const SizedBox(width: 8),
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                    IconButton(
                      iconSize: 18,
                      icon: const Icon(Icons.close),
                      onPressed: _removeAttachment,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: uploading
              ? null
              : () {
                  final title = _titleController.text.trim();
                  final content = _contentController.text.trim();
                  if (title.isEmpty || content.isEmpty) return;
                  Navigator.of(
                    context,
                  ).pop((_category, title, content, attachment?.result));
                },
          child: const Text('보내기'),
        ),
      ],
    );
  }
}
