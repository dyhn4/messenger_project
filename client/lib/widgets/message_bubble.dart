import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:intl/intl.dart';

import '../data/stickers.dart';
import '../models/app_user.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../screens/chat_screen.dart';
import '../screens/home_screen.dart' show wideBreakpoint;
import '../screens/member_profile_dialog.dart';
import '../screens/message_forward_screen.dart';
import '../screens/message_share_screen.dart';
import '../screens/my_profile_dialog.dart';
import '../services/edit_policy.dart';
import '../services/session.dart';
import 'attachment_widgets.dart';
import 'avatar_utils.dart';
import 'hover_toolbar.dart';
import 'self_destruct_countdown.dart';

final _timeFormat = DateFormat('a h:mm');

/// 메시지 한 줄: 아바타 + 보낸사람 이름 + (말풍선 + 시간). 항상 좌측 정렬이지만
/// 내가 보낸 메시지는 말풍선 색을 다르게 해서 구분한다. 아바타/이름을 누르면 내 메시지는
/// 내 프로필 카드, 다른 사람 메시지는 그 사람의 프로필 카드가 뜬다.
class MessageBubble extends StatefulWidget {
  final Session session;
  final Message message;
  final String Function(String relative) resolveUrl;
  final int unreadCount;
  final bool isMine;
  final AppUser? sender;
  final bool showTime;
  final bool showSenderInfo;
  final bool highlighted; // 검색 결과에서 열었을 때 잠깐 노란색으로 표시(chat_panel.dart 참고).
  final void Function(Message message)?
  onOpenThread; // 댓글 아이콘을 눌렀을 때(chat_panel.dart 참고).
  final Future<void> Function(String messageId, String text)?
  onEdit; // "수정" 저장.
  final Future<void> Function(String messageId)? onDelete; // "삭제" 확인.

  const MessageBubble({
    super.key,
    required this.session,
    required this.message,
    required this.resolveUrl,
    this.unreadCount = 0,
    this.isMine = false,
    this.sender,
    this.showTime = true,
    this.showSenderInfo = true,
    this.highlighted = false,
    this.onOpenThread,
    this.onEdit,
    this.onDelete,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  // 댓글/더보기 아이콘은 평소엔 숨겨두고, 마우스가 이 메시지 위에 있을 때만 보여준다(FavoriteStar와
  // 동일한 패턴). 한때 Stack의 Positioned 오버플로나 OverlayPortal 오버레이로 "말풍선 밖으로 살짝
  // 겹쳐 뜨는" 방식을 시도했는데, 전자는 넘친 영역에 호버/클릭 판정이 안정적으로 안 걸리는 문제가,
  // 후자는 Overlay와 CompositedTransformFollower의 레이아웃 타이밍이 어긋나며 렌더 크래시
  // ('debugNeedsLayout' 단언 실패)가 나는 문제가 있었다. 그래서 툴바를 말풍선 바로 아래의 평범한
  // 트리 자식(=일반 레이아웃 흐름)으로 되돌렸다 — 덜 "붕 뜬" 느낌이지만 안 부서진다.
  //
  // 말풍선과 툴바는 서로 다른 MouseRegion이라 각각의 호버 여부를 따로 추적하고, 그중 하나라도
  // 켜져 있으면 보여준다 — 하나만 보고 판단하면 말풍선에서 툴바로 넘어갈 때(먼저 들어간 쪽의
  // enter는 이미 소비돼서 다시 안 불리고, 나중에 나가는 쪽의 exit만 불려서) 마우스가 툴바
  // 위에 계속 있는데도 사라져버리는 경합이 생긴다.
  bool _bubbleHovering = false;
  bool _toolbarHovering = false;
  bool _hovering = false; // 위 둘의 OR에 소멸 유예(디바운스)를 적용한 실제 표시 여부.
  Timer? _hoverExitTimer;
  bool _editing = false;
  bool _savingEdit = false;
  final _editController = TextEditingController();

  void _setBubbleHovering(bool value) {
    _bubbleHovering = value;
    _updateHoverState();
  }

  void _setToolbarHovering(bool value) {
    _toolbarHovering = value;
    _updateHoverState();
  }

  void _updateHoverState() {
    _hoverExitTimer?.cancel();
    if (_bubbleHovering || _toolbarHovering) {
      if (!_hovering) setState(() => _hovering = true);
      return;
    }
    _hoverExitTimer = Timer(const Duration(milliseconds: 100), () {
      if (mounted) setState(() => _hovering = false);
    });
  }

  @override
  void dispose() {
    _hoverExitTimer?.cancel();
    _editController.dispose();
    super.dispose();
  }

  void _startEdit() {
    if (!isWithinEditWindow(widget.message.createdAt)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('작성 후 5분이 지나 수정할 수 없습니다.')));
      return;
    }
    setState(() {
      _editing = true;
      _editController.text = widget.message.text ?? '';
    });
  }

  void _cancelEdit() => setState(() => _editing = false);

  Future<void> _saveEdit() async {
    final text = _editController.text.trim();
    if (text.isEmpty) return;
    setState(() => _savingEdit = true);
    try {
      await widget.onEdit!(widget.message.id, text);
      if (mounted) setState(() => _editing = false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('수정 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _savingEdit = false);
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    if (!isWithinEditWindow(widget.message.createdAt)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('작성 후 5분이 지나 삭제할 수 없습니다.')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('메시지 삭제'),
        content: const Text('이 메시지를 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('삭제', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await widget.onDelete!(widget.message.id);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('삭제 실패: $e')));
    }
  }

  Future<void> _openProfile(BuildContext context) async {
    if (widget.isMine) {
      showDialog(
        context: context,
        builder: (_) => MyProfileDialog(session: widget.session),
      );
      return;
    }
    if (widget.sender != null) {
      // MemberProfileDialog에서 "1:1 메시지"를 누르면 새로 만들어진/기존 DM 방을 반환한다 —
      // 넓은(PC) 화면은 옆 패널만 바꾸고, 좁은(모바일) 화면은 전체화면으로 그 방을 띄운다.
      final room = await showDialog<Room>(
        context: context,
        builder: (_) =>
            MemberProfileDialog(session: widget.session, user: widget.sender!),
      );
      if (room == null || !context.mounted) return;
      if (MediaQuery.sizeOf(context).width >= wideBreakpoint) {
        widget.session.requestOpenRoom(room);
      } else {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatScreen(session: widget.session, room: room),
          ),
        );
      }
    }
  }

  /// 스티커는 이모지를, 텍스트/이미지·파일 캡션은 그 텍스트를 복사 대상으로 쓴다.
  /// 복사할 게 없으면(예: 캡션 없는 이미지) null.
  String? _copyableText() {
    final message = widget.message;
    if (message.type == MessageType.sticker) {
      return findStickerById(message.text ?? '')?.emoji;
    }
    return (message.text?.isNotEmpty ?? false) ? message.text : null;
  }

  Future<void> _copyFull(BuildContext context) async {
    final text = _copyableText();
    if (text == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('복사할 내용이 없습니다.')));
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('복사했습니다.')));
    }
  }

  void _showSelectCopyDialog(BuildContext context) {
    final text = _copyableText();
    if (text == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('복사할 내용이 없습니다.')));
      return;
    }
    showDialog(
      context: context,
      builder: (_) => _SelectCopyDialog(text: text),
    );
  }

  /// 롱프레스로 뜨는 하단 시트: 메시지 공유/댓글/복사/선택 복사/메시지 전달. 공유·전달은
  /// 원본이 비밀 대화(E2EE)면 숨긴다 — 평문 메시지가 다른 방으로 새거나, 암호화 없이 그
  /// 대화에 그대로 쌓이면 안 되기 때문(room_picker_screen.dart도 대상 목록에서 비밀
  /// 대화를 뺀다).
  void _showActionSheet(BuildContext context) {
    final message = widget.message;
    final sourceRoom = widget.session.rooms.where(
      (r) => r.id == message.roomId,
    );
    final isSecretRoom = sourceRoom.isNotEmpty && sourceRoom.first.isSecret;
    final displayName =
        (widget.isMine ? widget.session.name : widget.sender?.name) ??
        message.senderName;

    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isSecretRoom)
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('메시지 공유'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MessageShareScreen(
                        session: widget.session,
                        message: message,
                        senderDisplayName: displayName,
                      ),
                    ),
                  );
                },
              ),
            if (widget.onOpenThread != null)
              ListTile(
                leading: const Icon(Icons.mode_comment_outlined),
                title: const Text('댓글'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  widget.onOpenThread!(message);
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('복사'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _copyFull(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.text_fields),
              title: const Text('선택 복사'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _showSelectCopyDialog(context);
              },
            ),
            if (!isSecretRoom)
              ListTile(
                leading: const Icon(Icons.forward_outlined),
                title: const Text('메시지 전달'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MessageForwardScreen(
                        session: widget.session,
                        message: message,
                        senderDisplayName: displayName,
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final isMine = widget.isMine;
    final highlighted = widget.highlighted;
    // 이름이 바뀌었을 수도 있으니, 메시지에 박제된 senderName보다 지금 알고 있는 이름을
    // 우선한다(나는 session.name, 남은 room.members에서 찾은 sender.name).
    final displayName =
        (isMine ? widget.session.name : widget.sender?.name) ??
        message.senderName;
    const avatarDiameter = 32.0;
    const contentIndent = avatarDiameter + 8; // 아바타 너비 + 아바타-내용 간격.
    final isSticker =
        message.type == MessageType.sticker &&
        !message.deleted &&
        !message.decryptFailed;

    final bubbleRow = MouseRegion(
      onEnter: (_) => _setBubbleHovering(true),
      onExit: (_) => _setBubbleHovering(false),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: GestureDetector(
              onLongPress:
                  (!message.deleted && !message.decryptFailed && !_editing)
                  ? () => _showActionSheet(context)
                  : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOut,
                // 이모티콘은 카카오톡처럼 말풍선 배경 없이 크게만 보여준다(삭제/복호화 실패
                // 상태는 문구를 읽어야 하니 평소 말풍선 그대로 유지).
                padding: isSticker
                    ? EdgeInsets.zero
                    : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: isSticker
                    ? const BoxDecoration()
                    : BoxDecoration(
                        color: highlighted
                            ? const Color(0xFFFFF59D)
                            : (isMine
                                  ? Theme.of(
                                      context,
                                    ).colorScheme.primaryContainer
                                  : Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHighest),
                        borderRadius: BorderRadius.circular(14),
                      ),
                child: message.deleted
                    ? Text(
                        '삭제된 메시지입니다',
                        style: TextStyle(
                          fontStyle: FontStyle.italic,
                          color: Theme.of(context).hintColor,
                        ),
                      )
                    : message.decryptFailed
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.lock_outline,
                            size: 14,
                            color: Theme.of(context).hintColor,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '이 메시지는 복호화할 수 없습니다',
                            style: TextStyle(
                              fontStyle: FontStyle.italic,
                              color: Theme.of(context).hintColor,
                            ),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // "메시지 전달"로 생겼고 "포함" 토글이 켜져 있었으면 원본 발신자 표시.
                          if (message.forwardedFromSenderName != null) ...[
                            Text(
                              '${message.forwardedFromSenderName}에서 전달한 메시지입니다',
                              style: TextStyle(
                                fontSize: 12,
                                fontStyle: FontStyle.italic,
                                color: Theme.of(context).hintColor,
                              ),
                            ),
                            const SizedBox(height: 4),
                          ],
                          // 이미지/파일에 캡션(같이 입력한 메시지)이 붙어 있으면 그 위에 먼저 보여준다.
                          // 이모티콘은 text 필드 자체가 캡션이 아니라 스티커 id라 이 대상이 아니다.
                          if (message.type != MessageType.text &&
                              message.type != MessageType.sticker &&
                              (message.text?.isNotEmpty ?? false)) ...[
                            Text(message.text!),
                            const SizedBox(height: 6),
                          ],
                          if (_editing)
                            _buildEditor(context)
                          else
                            _buildContent(context),
                          // "메시지 공유"로 붙은 원본 인용 — 새로 쓴 내용(위) 아래에 구분선과 함께
                          // 붙는다(첨부 이미지 참고). 공유 당시 스냅샷이라 원본이 나중에 바뀌어도
                          // 그대로 남는다(models/message.dart 참고).
                          if (message.quotedSenderName != null) ...[
                            const SizedBox(height: 8),
                            const Divider(height: 1),
                            const SizedBox(height: 8),
                            Text(
                              '${message.quotedSenderName}에서 공유된 메시지입니다',
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).hintColor,
                              ),
                            ),
                            const SizedBox(height: 6),
                            _QuotedMessageCard(
                              senderName: message.quotedSenderName!,
                              preview: message.quotedPreview ?? '',
                            ),
                          ],
                          if (message.editedAt != null && !_editing) ...[
                            const SizedBox(height: 2),
                            Text(
                              '(수정됨)',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: Theme.of(context).hintColor,
                                  ),
                            ),
                          ],
                        ],
                      ),
              ),
            ),
          ),
          if (widget.unreadCount > 0) ...[
            const SizedBox(width: 4),
            Text(
              '${widget.unreadCount}',
              style: TextStyle(
                color: Colors.orange.shade800,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ],
          if (widget.showTime) ...[
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message.expiresAt != null)
                  SelfDestructCountdown(expiresAt: message.expiresAt!),
                Text(
                  _timeFormat.format(message.createdAt),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ],
            ),
          ],
          // 호버 시 시간 오른쪽에 뜨는 댓글/더보기 툴바. 세로(Column)가 아니라 이 Row 안에 두면
          // 말풍선 쪽 높이가 이미 이 툴바보다 큰 경우가 대부분이라(패딩 포함 한 줄짜리 말풍선도
          // 보통 이 툴바 높이보다 큼) Row 자체의 높이가 안 늘어나서, 아래 다른 메시지들이
          // 밀려나지 않는다.
          if (_hovering &&
              !message.deleted &&
              !message.decryptFailed &&
              !_editing &&
              widget.onOpenThread != null) ...[
            const SizedBox(width: 6),
            MouseRegion(
              onEnter: (_) => _setToolbarHovering(true),
              onExit: (_) => _setToolbarHovering(false),
              child: HoverToolbar(
                children: [
                  HoverToolbarButton(
                    icon: Icons.mode_comment_outlined,
                    tooltip: '댓글',
                    onPressed: () => widget.onOpenThread!(message),
                  ),
                  HoverToolbarButton(
                    icon: Icons.more_vert,
                    tooltip: '더보기',
                    visible:
                        isMine &&
                        (widget.onEdit != null || widget.onDelete != null),
                    menuItems: [
                      if (message.type == MessageType.text &&
                          widget.onEdit != null)
                        PopupMenuItem<void>(
                          onTap: _startEdit,
                          child: const Row(
                            children: [
                              Icon(Icons.edit),
                              SizedBox(width: 8),
                              Text('수정'),
                            ],
                          ),
                        ),
                      if (widget.onDelete != null)
                        PopupMenuItem<void>(
                          onTap: () => _confirmDelete(context),
                          child: const Row(
                            children: [
                              Icon(Icons.delete, color: Colors.redAccent),
                              SizedBox(width: 8),
                              Text(
                                '삭제',
                                style: TextStyle(color: Colors.redAccent),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 같은 사람이 연달아 보낸 메시지는 첫 메시지에만 프로필 사진/이름을 보여준다.
          // 이름은 아바타와 한 줄에서 세로 중앙에 오도록 정렬하고, 말풍선은 그 아래
          // (아바타 하단 높이만큼 들여쓴 채) 별도 줄로 둔다.
          if (widget.showSenderInfo) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => _openProfile(context),
                    child: AvatarView(
                      username: displayName,
                      avatarType: widget.sender?.avatarType ?? 'initial',
                      avatarEmoji: widget.sender?.avatarEmoji,
                      avatarColor: widget.sender?.avatarColor,
                      avatarUrl: widget.sender?.avatarUrl,
                      resolveUrl: widget.resolveUrl,
                      radius: avatarDiameter / 2,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => _openProfile(context),
                    child: Text(
                      displayName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
          Padding(
            padding: const EdgeInsets.only(left: contentIndent),
            child: bubbleRow,
          ),
        ],
      ),
    );
  }

  Widget _buildEditor(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _editController,
          autofocus: true,
          maxLines: null,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _saveEdit(),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _savingEdit ? null : _cancelEdit,
              child: const Text('취소'),
            ),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: _savingEdit ? null : _saveEdit,
              child: _savingEdit
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('저장'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context) {
    final message = widget.message;
    switch (message.type) {
      case MessageType.image:
        final url = widget.resolveUrl(message.fileUrl ?? '');
        return DownloadableImage(
          session: widget.session,
          url: url,
          fileName: message.fileName ?? 'image.png',
          attachmentKey: message.attachmentKey,
          attachmentNonce: message.attachmentNonce,
          thumbnailUrl: message.thumbnailUrl == null
              ? null
              : widget.resolveUrl(message.thumbnailUrl!),
          thumbnailKey: message.thumbnailKey,
          thumbnailNonce: message.thumbnailNonce,
        );
      case MessageType.file:
        final url = widget.resolveUrl(message.fileUrl ?? '');
        return DownloadableFile(
          session: widget.session,
          url: url,
          fileName: message.fileName ?? '파일',
          attachmentKey: message.attachmentKey,
          attachmentNonce: message.attachmentNonce,
        );
      case MessageType.text:
        // Text가 아니라 SelectableText였을 때 자체 롱프레스(글자 선택)가 부모 GestureDetector의
        // onLongPress(액션 시트)보다 제스처 아레나를 먼저 가져가 버려서, 말풍선 여백은 롱프레스가
        // 되는데 글자 위는 안 되는 문제가 있었다 — 인터랙티브 선택을 꺼도 내부적으로 제스처 자체는
        // 계속 가로채서(그냥 아무 반응이 없을 뿐) 해결이 안 됐다. 이제 선택은 "선택 복사" 메뉴가
        // 전담하므로 이 안에서 굳이 SelectableText일 필요가 없다.
        return Text(message.text ?? '');
      case MessageType.sticker:
        final sticker = findStickerById(message.text ?? '');
        return Text(
          sticker?.emoji ?? '❔',
          style: const TextStyle(fontSize: 72),
        );
      case MessageType.system:
      case MessageType.comment:
        // ChatPanel이 system 메시지는 SystemMessageRow로, 댓글 합성 항목은 MessageCommentsCard로
        // 따로 그려서 이 위젯까지 안 옴.
        return const SizedBox.shrink();
    }
  }
}

/// "메시지 공유"로 붙은 원본 인용 카드 — 작은 아바타 + 보낸사람 + 한 줄 미리보기가 든
/// 옅은 배경 카드(첨부 이미지 참고). message_share_screen.dart의 작성 화면 미리보기
/// 카드와 같은 모양으로 맞췄다.
class _QuotedMessageCard extends StatelessWidget {
  final String senderName;
  final String preview;
  const _QuotedMessageCard({required this.senderName, required this.preview});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest,
            child: const Icon(Icons.person, size: 16),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  senderName,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "선택 복사" — 메시지 내용을 읽기 전용 텍스트 필드로 띄우고, 열리자마자 전체를 선택해서
/// 플랫폼 기본 선택 도구(복사 등 팝업 + 드래그 핸들)가 바로 뜨게 한다. 원하는 부분만 다시
/// 골라서 복사하고 싶으면 핸들을 드래그해서 선택 범위를 조절하면 된다.
class _SelectCopyDialog extends StatefulWidget {
  final String text;
  const _SelectCopyDialog({required this.text});

  @override
  State<_SelectCopyDialog> createState() => _SelectCopyDialogState();
}

class _SelectCopyDialogState extends State<_SelectCopyDialog> {
  late final _controller = TextEditingController(text: widget.text);
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // 포커스가 실제로 걸린 다음 프레임에 SelectAllTextIntent를(원인을 toolbar로) 실행해야
    // 선택 범위뿐 아니라 복사 팝업 툴바까지 같이 뜬다 — 생성자에서 controller.selection만
    // 미리 채워두면 텍스트는 선택된 것처럼 보여도 툴바는 안 뜬다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _focusNode.context;
        if (ctx == null) return;
        Actions.maybeInvoke<SelectAllTextIntent>(
          ctx,
          const SelectAllTextIntent(SelectionChangedCause.toolbar),
        );
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 120),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          readOnly: true,
          maxLines: null,
          decoration: const InputDecoration(border: InputBorder.none),
        ),
      ),
    );
  }
}
