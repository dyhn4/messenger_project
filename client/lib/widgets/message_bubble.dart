import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/stickers.dart';
import '../models/app_user.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../screens/chat_screen.dart';
import '../screens/home_screen.dart' show wideBreakpoint;
import '../screens/inquiry_inbox_screen.dart';
import '../screens/member_profile_dialog.dart';
import '../screens/my_profile_dialog.dart';
import '../services/edit_policy.dart';
import '../models/project.dart' show parseTypeColor;
import '../services/app_links.dart';
import '../services/session.dart';
import 'attachment_widgets.dart';
import 'avatar_utils.dart';
import 'hover_toolbar.dart';
import 'message_actions.dart';
import 'rich_text_format.dart';
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
  final Future<void> Function(
    String messageId,
    String text, {
    List<TextFormatRun>? format,
  })?
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
  // 댓글/더보기 아이콘은 평소엔 숨겨두고, 마우스가 이 메시지 위에 있을 때만 말풍선 아래에
  // 겹쳐 띄운다(FloatingHoverToolbar). 이 "겹쳐 뜨는 툴바"는 두 번 실패한 이력이 있는데,
  // Stack의 Positioned로 넘치게 그리면 넘친 영역에 호버/클릭 판정이 안 걸리고,
  // CompositedTransformFollower로 Overlay에 띄우면 툴바 안 Tooltip이 레이아웃 중에 좌표를
  // 물어보다가 렌더 크래시('debugNeedsLayout' 단언 실패)가 난다. 지금은 둘 다 피해서
  // OverlayPortal.overlayChildLayoutBuilder로 좌표를 직접 받아 놓는다(hover_toolbar.dart 참고).
  //
  // 말풍선과 툴바는 서로 다른 MouseRegion이라 각각의 호버 여부를 따로 추적하고, 그중 하나라도
  // 켜져 있으면 보여준다 — 하나만 보고 판단하면 말풍선에서 툴바로 넘어갈 때(먼저 들어간 쪽의
  // enter는 이미 소비돼서 다시 안 불리고, 나중에 나가는 쪽의 exit만 불려서) 마우스가 툴바
  // 위에 계속 있는데도 사라져버리는 경합이 생긴다.
  bool _bubbleHovering = false;
  bool _toolbarHovering = false;
  bool _menuOpen = false;
  bool _hovering = false; // 위 둘의 OR에 소멸 유예(디바운스)를 적용한 실제 표시 여부.
  Timer? _hoverExitTimer;
  bool _editing = false;
  bool _savingEdit = false;
  final _editController = RichTextEditingController();
  final _editFocus = FocusNode();

  /// 툴바는 말풍선 아래에 Overlay로 띄운다(FloatingHoverToolbar 참고) — 일반 레이아웃
  /// 흐름이 아니라서 툴바가 떠도 아래 메시지들이 안 밀린다.
  final _toolbarPortal = OverlayPortalController();

  void _setBubbleHovering(bool value) {
    _bubbleHovering = value;
    _updateHoverState();
  }

  void _setToolbarHovering(bool value) {
    _toolbarHovering = value;
    _updateHoverState();
  }

  /// 더보기 메뉴가 열려 있는 동안에는 툴바를 붙잡아 둔다 — 마우스가 메뉴로 넘어가면 툴바
  /// 밖으로 나간 것으로 잡혀서, 안 붙잡으면 툴바가 사라지며 메뉴까지 같이 닫힌다.
  void _setMenuOpen(bool value) {
    _menuOpen = value;
    _updateHoverState();
  }

  void _updateHoverState() {
    _hoverExitTimer?.cancel();
    if (_bubbleHovering || _toolbarHovering || _menuOpen) {
      if (!_hovering) setState(() => _hovering = true);
      _syncToolbarPortal();
      return;
    }
    _hoverExitTimer = Timer(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      setState(() => _hovering = false);
      _syncToolbarPortal();
    });
  }

  bool get _canShowToolbar =>
      !widget.message.deleted &&
      !widget.message.decryptFailed &&
      !_editing &&
      widget.onOpenThread != null;

  /// Overlay 툴바를 여닫는다. OverlayPortalController.show/hide는 "빌드 중에는 호출하지
  /// 말라"고 SDK에 적혀 있어서, 빌드 결과(_hovering)로 자동 반영하지 않고 호버 콜백/타이머
  /// 같은 빌드 밖 지점에서만 이 함수를 부른다.
  void _syncToolbarPortal() {
    final show = _hovering && _canShowToolbar;
    if (show == _toolbarPortal.isShowing) return;
    show ? _toolbarPortal.show() : _toolbarPortal.hide();
  }

  @override
  void dispose() {
    _hoverExitTimer?.cancel();
    _editController.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  void _startEdit() {
    if (!isEditDeleteAllowed(widget.session)) {
      showEditWindowExpiredDialog(context, editDeleteDisabledMessage);
      return;
    }
    if (!isWithinEditDeleteWindow(widget.session, widget.message.createdAt)) {
      showEditWindowExpiredDialog(
        context,
        editDeleteWindowExpiredMessage(
          widget.session,
          what: '메시지',
          action: '수정',
        ),
      );
      return;
    }
    setState(() => _editing = true);
    _editController.load(widget.message.text ?? '', widget.message.textFormat);
    _syncToolbarPortal(); // 수정 중에는 툴바를 닫는다.
  }

  void _cancelEdit() {
    setState(() => _editing = false);
    _syncToolbarPortal();
  }

  Future<void> _saveEdit() async {
    final (:text, :format) = _editController.formatted();
    if (text.isEmpty) return;
    setState(() => _savingEdit = true);
    try {
      await widget.onEdit!(widget.message.id, text, format: format);
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

  /// 팀의 소유자·관리자는 자기가 들어가 있는 방에서 남의 메시지도 지울 수 있다(콘텐츠 관리 —
  /// 서버 moderation.js와 같은 규칙). 본인 메시지와 마찬가지로 팀이 정한 삭제 가능 시간
  /// 안에서만 가능하고, 비밀 대화(E2EE)는 서버가 내용을 볼 수 없으므로 대상에서 뺀다.
  bool get _canModerate {
    if (widget.isMine || widget.onDelete == null) return false;
    if (!widget.session.canModerateContent) return false;
    if (!isEditDeleteAllowed(widget.session)) return false;
    if (widget.message.type == MessageType.system) return false;
    if (!isWithinEditDeleteWindow(widget.session, widget.message.createdAt)) {
      return false;
    }
    final room = widget.session.rooms.where(
      (r) => r.id == widget.message.roomId,
    );
    return room.isNotEmpty && !room.first.isSecret;
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final moderating = !widget.isMine;
    if (!isEditDeleteAllowed(widget.session)) {
      showEditWindowExpiredDialog(context, editDeleteDisabledMessage);
      return;
    }
    if (!isWithinEditDeleteWindow(widget.session, widget.message.createdAt)) {
      showEditWindowExpiredDialog(
        context,
        editDeleteWindowExpiredMessage(
          widget.session,
          what: '메시지',
          action: '삭제',
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('메시지 삭제'),
        content: Text(
          moderating ? '관리자 권한으로 다른 사람의 메시지를 삭제합니다. 계속할까요?' : '이 메시지를 삭제할까요?',
        ),
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

  /// 롱프레스로 뜨는 하단 시트(메시지 공유/댓글/복사/선택 복사/메시지 전달) — 실제 내용은
  /// message_actions.dart가 댓글(message_comments_card.dart)과 공용으로 구현한다.
  void _showActionSheet(BuildContext context) {
    final message = widget.message;
    final displayName =
        (widget.isMine ? widget.session.name : widget.sender?.name) ??
        message.senderName;
    showMessageActionSheet(
      context,
      session: widget.session,
      message: message,
      senderDisplayName: displayName,
      onOpenThread: widget.onOpenThread,
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
              child: ConstrainedBox(
                // "메시지 공유"로 인용 카드가 붙은 말풍선은 보라색 말풍선(배경) 자체가
                // 700px을 넘지 않도록 여기서 직접 못박는다 — 안쪽 카드만 좁혀서는(예전 시도)
                // 이 폭까지 정확히 안 맞았다.
                constraints: BoxConstraints(
                  maxWidth: message.quotedSenderName != null
                      ? 700
                      : double.infinity,
                ),
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
                              FormattedText(
                                message.text!,
                                format: message.textFormat,
                                linkColor: Colors.blue,
                              ),
                              const SizedBox(height: 6),
                            ],
                            if (_editing)
                              _buildEditor(context)
                            else
                              _buildContent(context),
                            // 메시지 텍스트에 담긴 링크의 오픈그래프 미리보기 — 전송 직후엔 없다가
                            // 서버가 백그라운드로 가져오면 그 자리에서 나타난다(Message.linkPreview
                            // 참고). 수정 중엔 편집기만 보여주면 되니 숨긴다.
                            if (!_editing && message.linkPreview != null) ...[
                              const SizedBox(height: 6),
                              _LinkPreviewCard(preview: message.linkPreview!),
                            ],
                            // 노트 링크(tangotalk://)가 든 메시지 — 앱 안 링크라 서버가 미리보기를
                            // 긁어올 수 없어서, 여기서 카드를 만들어 붙인다. 누르면 그 노트가 열린다.
                            if (!_editing && _appLinkOf(message) != null) ...[
                              const SizedBox(height: 6),
                              _AppLinkCard(href: _appLinkOf(message)!),
                            ],
                            // "팀장에게 문의하기"로 온 메시지에만 붙는 바로가기 — 누르면 문의함이
                            // 바로 열린다(chat_input_bar.dart의 _showInquiryDialog 참고).
                            if (!_editing && message.isInquiryNotice) ...[
                              const SizedBox(height: 6),
                              InkWell(
                                onTap: () => showInquiryInboxScreen(
                                  context,
                                  widget.session,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.contact_support,
                                      size: 14,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '문의함 바로가기',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                        decoration: TextDecoration.underline,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
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
          // 툴바는 이제 말풍선 아래에 Overlay로 떠서(아래 FloatingHoverToolbar) 이 줄에
          // 그려지지 않지만, 시간 오른쪽의 빈 자리는 그대로 남겨둔다 — 툴바가 여기 있던
          // 시절에 잡아둔 여백이라 없애면 말풍선 폭이 갑자기 넓어진다.
          if (_canShowToolbar) ...[
            const SizedBox(width: 6),
            SizedBox(width: HoverToolbar.widthFor(2)),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                bubbleRow,
                // 말풍선 왼쪽 아래를 가리키는 0크기 앵커 — 툴바는 여기 기준으로 Overlay에
                // 떠서, 아래 메시지들을 밀지 않고 그 위에 겹쳐 보인다.
                FloatingHoverToolbar(
                  controller: _toolbarPortal,
                  toolbarBuilder: (_) => MouseRegion(
                    onEnter: (_) => _setToolbarHovering(true),
                    onExit: (_) => _setToolbarHovering(false),
                    child: _buildToolbar(displayName: displayName),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 툴바 내용. 메뉴 항목이 쓰는 context는 (툴바가 그려지는) Overlay의 context가 아니라
  /// 이 State의 context여야 한다 — Overlay 쪽은 툴바가 닫히는 순간 죽은 context가 돼서,
  /// 그걸로 Navigator/스낵바를 찾으면 "deactivated widget's ancestor" 오류가 난다.
  Widget _buildToolbar({required String displayName}) {
    final message = widget.message;
    final isMine = widget.isMine;
    return HoverToolbar(
      children: [
        HoverToolbarButton(
          icon: Icons.mode_comment_outlined,
          tooltip: '댓글',
          onPressed: () => widget.onOpenThread!(message),
        ),
        HoverToolbarButton(
          icon: Icons.more_vert,
          tooltip: '더보기',
          onMenuOpenChanged: _setMenuOpen,
          menuChildren: [
            ...messageActionMenuItems(
              context,
              session: widget.session,
              message: message,
              senderDisplayName: displayName,
            ),
            // 팀이 메시지 수정/삭제를 꺼두면([메시지 설정]) 본인 메시지도 못 고치고 못 지운다.
            if (isMine &&
                isEditDeleteAllowed(widget.session) &&
                (widget.onEdit != null || widget.onDelete != null))
              hoverMenuDivider(),
            if (isMine &&
                isEditDeleteAllowed(widget.session) &&
                message.type == MessageType.text &&
                widget.onEdit != null)
              hoverMenuItem(
                icon: Icons.edit,
                label: '수정',
                onPressed: _startEdit,
              ),
            if (isMine &&
                widget.onDelete != null &&
                isEditDeleteAllowed(widget.session))
              hoverMenuItem(
                icon: Icons.delete,
                label: '삭제',
                color: Colors.redAccent,
                onPressed: () => _confirmDelete(context),
              ),
            // 소유자·관리자의 콘텐츠 관리 — 남의 메시지도 지울 수 있다(_canModerate 참고).
            if (_canModerate) ...[
              hoverMenuDivider(),
              hoverMenuItem(
                icon: Icons.shield_outlined,
                label: '삭제 (관리자)',
                color: Colors.redAccent,
                onPressed: () => _confirmDelete(context),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildEditor(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RichFormatToolbar(controller: _editController, focusNode: _editFocus),
        RichFieldWrapper(
          controller: _editController,
          child: TextField(
            controller: _editController,
            focusNode: _editFocus,
            autofocus: true,
            maxLines: null,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _saveEdit(),
          ),
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
        // 서버가 첨부를 늘 목록으로 내려준다(예전 메시지는 파일 칸 하나를 목록 하나로).
        // 아주 예전 캐시 등으로 목록이 비어 있으면 메시지의 파일 칸으로 하나 만들어 쓴다.
        final items = message.attachments.isNotEmpty
            ? message.attachments
            : [
                MessageAttachment(
                  id: message.id,
                  kind: 'image',
                  fileUrl: message.fileUrl ?? '',
                  fileName: message.fileName,
                  thumbnailUrl: message.thumbnailUrl,
                ),
              ];
        return ChatImageAttachments(
          session: widget.session,
          attachments: items,
          message: message,
          // 뷰어의 댓글 패널이 이 방의 컨트롤러를 쓴다 — 버블은 방을 따로 안 받으므로
          // 세션의 방 목록에서 찾는다(못 찾으면 댓글 버튼만 안 보인다).
          room: widget.session.rooms
              .where((r) => r.id == message.roomId)
              .firstOrNull,
          attachmentKey: message.attachmentKey,
          attachmentNonce: message.attachmentNonce,
          thumbnailKey: message.thumbnailKey,
          thumbnailNonce: message.thumbnailNonce,
        );
      case MessageType.file:
        final url = widget.resolveUrl(message.fileUrl ?? '');
        return DownloadableFile(
          session: widget.session,
          url: url,
          fileName: message.fileName ?? '파일',
          message: message,
          attachmentKey: message.attachmentKey,
          attachmentNonce: message.attachmentNonce,
        );
      case MessageType.text:
        // 안드로이드(터치)에서는 SelectableText였을 때 자체 롱프레스(단어 선택)가 부모
        // GestureDetector의 onLongPress(액션 시트)와 같은 롱프레스 기반이라 제스처 아레나를
        // 먼저 가져가 버려서, 말풍선 여백은 롱프레스가 되는데 글자 위는 안 되는 문제가 있었다
        // — 그래서 안드로이드는 지금도 Text를 쓰고, 선택은 "선택 복사" 메뉴가 전담한다.
        // Windows(마우스)에서는 텍스트 선택이 롱프레스가 아니라 클릭+드래그로 이뤄져서
        // onLongPress와 경합하지 않으므로, 마우스 호버 시 커서가 I-beam으로 바뀌고 드래그로
        // 바로 선택할 수 있도록 SelectableText를 쓴다.
        return FormattedText(
          message.text ?? '',
          format: message.textFormat,
          style: Theme.of(context).textTheme.bodyMedium,
          linkColor: Colors.blue,
          selectable: Platform.isWindows,
        );
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
    // message_comments_card.dart의 댓글 카드와 같은 규칙(최대 700, 그보다 좁으면 남는
    // 폭만큼)으로 가로 크기를 맞춘다. 말풍선(보라색 배경) 자체의 700 상한은 이 카드가 아니라
    // 말풍선 쪽(message_bubble.dart의 ConstrainedBox)에서 직접 잡아주므로, 여기 constraints는
    // 이미 그 폭(700 - 말풍선 패딩) 이하로 들어온다 — 이 min()은 그 경우를 대비한 안전장치일 뿐.
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth > 700 ? 700.0 : constraints.maxWidth;
        return SizedBox(width: width, child: _buildCard(context));
      },
    );
  }

  Widget _buildCard(BuildContext context) {
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

/// 메시지 텍스트에 담긴 링크의 오픈그래프 미리보기 카드 — 위에 이미지, 아래 제목/설명 일부/
/// 출처(사이트 이름) 순으로 세로로 쌓는다(카카오톡/슬랙 링크 카드와 같은 배치). 탭하면 기본
/// 브라우저로 그 링크를 연다.
class _LinkPreviewCard extends StatelessWidget {
  final LinkPreview preview;
  const _LinkPreviewCard({required this.preview});

  Future<void> _open() async {
    if (AppLinks.open(preview.url)) return;
    try {
      await launchUrl(
        Uri.parse(preview.url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // 브라우저를 못 열어도 조용히 무시한다 — 이 카드는 어차피 정보 표시가 우선 목적이라
      // 실패를 따로 알릴 만큼 중요한 동작은 아니다.
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth > 360 ? 360.0 : constraints.maxWidth;
        return SizedBox(width: width, child: _buildCard(context));
      },
    );
  }

  Widget _buildCard(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _open,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (preview.imageUrl != null)
              AspectRatio(
                aspectRatio: 1.9,
                child: _ExternalImage(url: preview.imageUrl!),
              ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (preview.title != null)
                    Text(
                      preview.title!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  if (preview.description != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      preview.description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ],
                  if (preview.siteName != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      preview.siteName!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 노트·업무 링크 카드 — 프로젝트 색 점 · 프로젝트 이름, 그 아래 "노트"·"업무"와 작성자·
/// 담당자. 값은 링크를 복사할 때 담아 둔 것(AppLinks)이다. 누르면 그 노트·업무가 열린다.
class _AppLinkCard extends StatelessWidget {
  final String href;
  const _AppLinkCard({required this.href});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = AppLinks.parse(href);
    final isTask = link?.kind == 'task';
    final color = link?.color == null
        ? theme.colorScheme.primary
        : parseTypeColor(link!.color);
    final person = link?.person;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth > 360 ? 360.0 : constraints.maxWidth;
        return SizedBox(
          width: width,
          child: Material(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => AppLinks.open(href),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            link?.project ?? 'TangoTalk Project',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      [
                        isTask ? '업무' : '노트',
                        if (person != null && person.isNotEmpty)
                          '${isTask ? '담당자' : '작성자'} $person',
                      ].join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: theme.hintColor),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 메시지 글에 걸린 첫 앱 링크(노트·업무 링크) — 없으면 null.
String? _appLinkOf(Message m) {
  if (m.type != MessageType.text) return null;
  for (final r in m.textFormat ?? const <TextFormatRun>[]) {
    if (AppLinks.isAppLink(r.href)) return r.href;
  }
  return null;
}

/// 링크 미리보기 이미지 전용 — 임의의 외부 웹사이트에서 오는 이미지라 그냥 Image.network를
/// 쓰면 못 불러온다. main.dart가 앱 시작 시 PinnedTls.installGlobalHttpOverrides()로 전역
/// HttpClient를 "우리 서버 자체 서명 인증서 하나만" 신뢰하도록 가로채놓는데(pinned_tls.dart),
/// 이 override는 앱 전체 HttpClient에 다 걸려서 Image.network가 내부적으로 만드는 HttpClient도
/// 똑같이 적용된다 — 그래서 공인 인증서를 쓰는 일반 웹사이트 이미지는 전부 인증서 검증 실패로
/// 조용히(errorBuilder) 안 뜨고 있었다. 이 위젯만 별도 isolate(Isolate.run)에서 이미지를
/// 받아온 뒤 Image.memory로 그린다 — 새 isolate는 main isolate의 HttpOverrides.global을
/// 안 물려받는(격리된 static 상태) 덕분에 거기서 만드는 HttpClient는 평범한(공인 CA 신뢰)
/// 기본 상태다. 우리 서버와의 통신(API/소켓/첨부파일)에 쓰는 핀닝은 그대로 안전하게 유지된다.
///
/// (처음엔 HttpOverrides.runZoned로 "이 fetch만 전역 재정의를 벗어나게" 시도했는데, 그
/// zone의 createHttpClient 콜백 안에서 다시 HttpClient()를 호출하면 그 호출도 같은 zone
/// 안이라 자기 자신을 또 부르는 무한 재귀에 빠져 StackOverflowError가 났다(직접 재현해서
/// 확인함) — zone 기반 접근 자체가 이 용도에는 안 맞는 함정이었다.)
class _ExternalImage extends StatefulWidget {
  final String url;
  const _ExternalImage({required this.url});

  @override
  State<_ExternalImage> createState() => _ExternalImageState();
}

class _ExternalImageState extends State<_ExternalImage> {
  static const _maxBytes = 8 * 1024 * 1024; // 미리보기 이미지치고 과하게 크면 안전하게 포기.

  late final Future<Uint8List> _future = _fetch(widget.url);

  static Future<Uint8List> _fetch(String url) {
    // 새 isolate는 main.dart가 설치해둔 전역 HttpOverrides(우리 서버 인증서만 신뢰)를 안
    // 물려받는다 — isolate마다 static 상태가 완전히 독립돼 있어서, 여기서 만드는 HttpClient는
    // 그 핀닝과 무관하게 평범한(공인 CA 신뢰) 기본 상태로 동작한다.
    return Isolate.run(() async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close().timeout(
          const Duration(seconds: 8),
        );
        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode}');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > _maxBytes) {
            throw Exception('이미지가 너무 큽니다');
          }
        }
        return Uint8List.fromList(bytes);
      } finally {
        client.close(force: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done ||
            !snapshot.hasData) {
          return const SizedBox.shrink();
        }
        // 이미지 링크가 나중에 깨지거나(원본이 지워짐) 디코딩할 수 없는 형식이어도 카드
        // 전체가 에러로 안 보이고 텍스트만 있는 카드로 자연스럽게 떨어진다.
        return Image.memory(
          snapshot.data!,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        );
      },
    );
  }
}
