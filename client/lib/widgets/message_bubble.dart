import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/app_user.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../screens/chat_screen.dart';
import '../screens/home_screen.dart' show wideBreakpoint;
import '../screens/member_profile_dialog.dart';
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

    final bubbleRow = MouseRegion(
      onEnter: (_) => _setBubbleHovering(true),
      onExit: (_) => _setBubbleHovering(false),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: highlighted
                    ? const Color(0xFFFFF59D)
                    : (isMine
                          ? Theme.of(context).colorScheme.primaryContainer
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
                        // 이미지/파일에 캡션(같이 입력한 메시지)이 붙어 있으면 그 위에 먼저 보여준다.
                        if (message.type != MessageType.text &&
                            (message.text?.isNotEmpty ?? false)) ...[
                          SelectableText(message.text!),
                          const SizedBox(height: 6),
                        ],
                        if (_editing)
                          _buildEditor(context)
                        else
                          _buildContent(context),
                        if (message.editedAt != null && !_editing) ...[
                          const SizedBox(height: 2),
                          Text(
                            '(수정됨)',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: Theme.of(context).hintColor),
                          ),
                        ],
                      ],
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
        return SelectableText(message.text ?? '');
      case MessageType.system:
      case MessageType.comment:
        // ChatPanel이 system 메시지는 SystemMessageRow로, 댓글 합성 항목은 MessageCommentsCard로
        // 따로 그려서 이 위젯까지 안 옴.
        return const SizedBox.shrink();
    }
  }
}
