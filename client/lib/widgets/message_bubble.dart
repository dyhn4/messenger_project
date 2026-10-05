import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_platform.dart';
import 'sticker_view.dart';
import '../models/app_user.dart';
import '../models/mention.dart';
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
import '../services/mention_logic.dart';
import '../services/session.dart';
import 'attachment_widgets.dart';
import 'chat_font_scope.dart';
import 'external_image.dart';
import 'avatar_utils.dart';
import 'hover_toolbar.dart';
import 'mention_autocomplete.dart';
import 'mention_profile.dart';
import 'message_actions.dart';
import 'message_announce.dart';
import 'message_edit_attachments.dart';
import 'poll_card.dart';
import 'rich_text_format.dart';
import 'self_destruct_countdown.dart';
import 'shared_album_card.dart';
import 'todo_message_card.dart';

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
    List<Mention>? mentions,
  })?
  onEdit; // "수정" 저장.

  /// 사진·파일 메시지의 "수정" 저장 — 설명글과 지울 첨부 id를 함께 보낸다(RoomChatController.editMediaMessage).
  /// 없으면 사진·파일 메시지는 수정 항목이 안 뜬다.
  final Future<void> Function(
    String messageId,
    String text, {
    List<TextFormatRun>? format,
    List<Mention>? mentions,
    List<String> removeAttachmentIds,
  })?
  onEditMedia;
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
    this.onEditMedia,
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

  /// 수정 모드에서 X로 "삭제 예정"으로 표시한 첨부 id들 — [저장]을 눌러야 실제로 지워진다.
  final _removedAttachmentIds = <String>{};
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

  /// 자동화 메시지는 보낸 사람이 없어서(senderId null) 누구의 "내 메시지"도 아니다 — 호출부가
  /// senderId == userId로 비교하다 userId까지 null이면 true가 될 수 있어 여기서 한 번 더 막는다.
  /// 그래서 수정·본인 삭제 메뉴도 안 뜬다(관리자 삭제는 남의 메시지와 같은 규칙).
  bool get _isMine => widget.isMine && !widget.message.isAutomation;

  /// 사진·파일 메시지는 설명글 수정과 첨부 삭제가 된다 — 비밀 대화는 서버가 첨부·설명글(키 봉투와 한 덩어리
  /// 암호문)을 못 봐서 고칠 수 없으니 수정 항목을 안 보인다.
  bool get _isEditableMedia {
    final m = widget.message;
    if (m.type != MessageType.image && m.type != MessageType.file) return false;
    return widget.onEditMedia != null &&
        widget.session.roomById(m.roomId)?.isSecret != true;
  }

  /// 본인 메시지의 수정 항목(PC 더보기 메뉴·모바일 길게 누르기 시트)을 보일지. 게시글은 제목까지 함께
  /// 고쳐야 해서 말풍선 안 수정 대신 게시글 편집기로만 고친다.
  bool get _canEditMessage =>
      _isMine &&
      isEditDeleteAllowed(widget.session) &&
      !widget.message.isPost &&
      !widget.message.isPoll &&
      // 할 일 카드는 할 일에서 고친다(글을 고칠 게 없다).
      widget.message.sharedTodo == null &&
      ((widget.message.type == MessageType.text && widget.onEdit != null) ||
          _isEditableMedia);

  /// 투표는 카드 안의 더보기(⋯: 댓글·즐겨찾기·마감·삭제)가 이 툴바를 대신한다 — 공유·전달·수정을
  /// 못 하는 메시지라 툴바 항목이 사실상 겹치기만 한다.
  bool get _canShowToolbar =>
      !widget.message.deleted &&
      !widget.message.decryptFailed &&
      !_editing &&
      !widget.message.isPoll &&
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
    _removedAttachmentIds.clear();
    setState(() => _editing = true);
    // 수정 화면에서도 멘션을 고칠 수 있다 — 지금 멘션 구간을 입력칸에 넘겨 받는다.
    final room = widget.session.roomById(widget.message.roomId);
    _editController.mentionsEnabled = room != null && roomAllowsMention(room);
    _editController.load(
      widget.message.text ?? '',
      widget.message.textFormat,
      mentions: widget.message.mentions,
    );
    _syncToolbarPortal(); // 수정 중에는 툴바를 닫는다.
  }

  void _cancelEdit() {
    setState(() => _editing = false);
    _syncToolbarPortal();
  }

  Future<void> _saveEdit() async {
    final (:text, :format) = _editController.formatted();
    final media = _isEditableMedia;
    // 사진·파일 메시지는 설명글이 비어도 저장할 수 있다(첨부만 남긴다). 글 메시지는 빈 글 저장 불가.
    if (text.isEmpty && !media) return;
    final room = widget.session.roomById(widget.message.roomId);
    final mentions = room == null
        ? const <Mention>[]
        : mentionsToSend(_editController, room, widget.session.userId);
    final removed = _removedAttachmentIds.toList();
    if (media && text.isEmpty) {
      final remaining = widget.message.liveAttachments
          .where((a) => !_removedAttachmentIds.contains(a.id))
          .length;
      if (remaining == 0) {
        // 첨부를 다 지웠는데 설명글도 없으면 남는 게 없다 — 저장 대신 메시지 삭제를 권한다.
        await _offerDeleteWhenEmpty();
        return;
      }
    }
    setState(() => _savingEdit = true);
    try {
      if (media) {
        await widget.onEditMedia!(
          widget.message.id,
          text,
          format: format,
          mentions: mentions,
          removeAttachmentIds: removed,
        );
      } else {
        await widget.onEdit!(
          widget.message.id,
          text,
          format: format,
          mentions: mentions,
        );
      }
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

  /// 사진·파일 메시지에서 첨부를 모두 지우고 설명글도 비웠을 때 — 메시지가 빈 채로 남을 수 없으니 전체
  /// 삭제를 권한다("삭제"를 고르면 그 메시지를 지우고, "계속 수정"이면 수정 모드로 돌아간다).
  Future<void> _offerDeleteWhenEmpty() async {
    final delete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('메시지 삭제'),
        content: const Text('첨부를 모두 지우고 내용도 없으면 남는 메시지가 없습니다.\n메시지를 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('계속 수정'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('삭제', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (delete != true || !mounted || widget.onDelete == null) return;
    try {
      await widget.onDelete!(widget.message.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('삭제 실패: $e')));
    }
  }

  /// 팀의 소유자·관리자는 자기가 들어가 있는 방에서 남의 메시지도 지울 수 있다(콘텐츠 관리 —
  /// 서버 moderation.js와 같은 규칙). 본인 메시지와 마찬가지로 팀이 정한 삭제 가능 시간
  /// 안에서만 가능하고, 비밀 대화(E2EE)는 서버가 내용을 볼 수 없으므로 대상에서 뺀다.
  bool get _canModerate {
    if (_isMine || widget.onDelete == null) return false;
    if (!isEditDeleteAllowed(widget.session)) return false;
    final room = widget.session.rooms.where(
      (r) => r.id == widget.message.roomId,
    );
    // 게시글은 토픽을 관리할 수 있는 사람(토픽 관리자 포함)이 시간 제한 없이 지운다(서버와 같은 규칙).
    if (widget.message.isPost) {
      return room.isNotEmpty && room.first.canManage(widget.session);
    }
    if (!widget.session.canModerateContent) return false;
    if (widget.message.type == MessageType.system) return false;
    if (!isWithinEditDeleteWindow(widget.session, widget.message.createdAt)) {
      return false;
    }
    return room.isNotEmpty && !room.first.isSecret;
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final moderating = !_isMine;
    final isPost = widget.message.isPost;
    final noun = isPost ? '게시글' : '메시지';
    if (!isEditDeleteAllowed(widget.session)) {
      showEditWindowExpiredDialog(context, editDeleteDisabledMessage);
      return;
    }
    // 게시글은 오래 두고 쓰는 글이라 수정/삭제 가능 시간 제한이 없다.
    if (!isPost &&
        !isWithinEditDeleteWindow(widget.session, widget.message.createdAt)) {
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
        title: Text('$noun 삭제'),
        content: Text(
          moderating
              ? '관리자 권한으로 다른 사람의 $noun${isPost ? '을' : '를'} 삭제합니다. 계속할까요?'
              : '이 $noun${isPost ? '을' : '를'} 삭제할까요?',
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

  /// 본문 안 멘션 이름을 눌렀을 때 — 그 멤버의 프로필(mention_profile.dart).
  void _openMention(Mention mention) => openMentionProfile(
    context,
    widget.session,
    roomId: widget.message.roomId,
    mention: mention,
  );

  Future<void> _openProfile(BuildContext context) async {
    if (_isMine) {
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
        (_isMine ? widget.session.name : widget.sender?.name) ??
        message.senderName;
    showMessageActionSheet(
      context,
      session: widget.session,
      message: message,
      senderDisplayName: displayName,
      onOpenThread: widget.onOpenThread,
      // 모바일은 호버 툴바가 없어서 수정도 이 시트로 들어간다. 토픽의 텍스트·이미지 메시지엔 "공지 등록".
      onEdit: _canEditMessage ? _startEdit : null,
      offerAnnouncement: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final isMine = _isMine;
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
    // 남이 나를(또는 @all로 모두를) 멘션한 글 — 말풍선에 강조선을 둘러 눈에 띄게 한다.
    final mentionsMe =
        !isMine &&
        !message.deleted &&
        !message.decryptFailed &&
        mentionsUser(message.mentions, widget.session.userId);

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
                          // 나를 멘션한 글은 말풍선에 얇은 강조선을 두른다.
                          border: mentionsMe
                              ? Border.all(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.7),
                                  width: 1.2,
                                )
                              : null,
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
                            // 지금 이 토픽의 고정 공지로 올라가 있는 메시지면 작은 "공지" 표시.
                            if (!_editing &&
                                isPinnedAnnouncementSource(
                                  widget.session,
                                  message,
                                )) ...[
                              Row(
                                key: const ValueKey('announcement-marker'),
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.campaign_outlined,
                                    size: 13,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    '공지',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                            ],
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
                            if (!_editing &&
                                message.type != MessageType.text &&
                                message.type != MessageType.sticker &&
                                (message.text?.isNotEmpty ?? false)) ...[
                              FormattedText(
                                message.text!,
                                format: message.textFormat,
                                linkColor: Colors.blue,
                                mentions: message.mentions,
                                myUserId: widget.session.userId,
                                onMentionTap: _openMention,
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
                            // "앨범 공유"로 보낸 글 — 구분선, "{팀}에서 공유된 앨범입니다.", 앨범 보기, 앨범 카드.
                            if (!_editing && message.sharedAlbum != null)
                              SharedAlbumSection(
                                session: widget.session,
                                album: message.sharedAlbum!,
                              ),
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
          // 자동화 메시지는 사람이 아니라 열어 볼 프로필이 없다 — 번개 아바타와 이름만 둔다.
          if (widget.showSenderInfo && message.isAutomation) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const AutomationAvatar(
                  key: ValueKey('automation-avatar'),
                  radius: avatarDiameter / 2,
                ),
                const SizedBox(width: 8),
                Text(
                  displayName,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 4),
          ] else if (widget.showSenderInfo) ...[
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
    final isMine = _isMine;
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
              offerAnnouncement: true,
            ),
            // 팀이 메시지 수정/삭제를 꺼두면([메시지 설정]) 본인 메시지도 못 고치고 못 지운다.
            if (isMine &&
                isEditDeleteAllowed(widget.session) &&
                (widget.onEdit != null ||
                    widget.onEditMedia != null ||
                    widget.onDelete != null))
              hoverMenuDivider(),
            // 게시글은 제목까지 함께 고쳐야 해서 말풍선 안 수정 대신 게시글 편집기로만 고친다. 사진·파일
            // 메시지는 설명글 수정과 첨부 삭제가 된다(_canEditMessage).
            if (_canEditMessage)
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

  /// 수정 입력칸에도 "@" 자동완성을 붙인다(방을 모르거나 비밀 대화면 그대로).
  Widget _withMentions(Widget field) {
    final room = widget.session.roomById(widget.message.roomId);
    if (room == null || !roomAllowsMention(room)) return field;
    return MentionAutocomplete(
      controller: _editController,
      focusNode: _editFocus,
      room: room,
      myUserId: widget.session.userId,
      resolveUrl: widget.session.resolveUrl,
      child: field,
    );
  }

  Widget _buildEditor(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 사진·파일 메시지: 첨부마다 X로 지울 것을 표시한다(더할 수는 없다).
        if (_isEditableMedia && widget.message.liveAttachments.isNotEmpty) ...[
          EditAttachmentStrip(
            session: widget.session,
            attachments: widget.message.liveAttachments,
            removedIds: _removedAttachmentIds,
            onToggle: (id) => setState(() {
              if (!_removedAttachmentIds.remove(id)) {
                _removedAttachmentIds.add(id);
              }
            }),
          ),
          const SizedBox(height: 8),
        ],
        RichFormatToolbar(controller: _editController, focusNode: _editFocus),
        _withMentions(
          RichFieldWrapper(
            controller: _editController,
            child: TextField(
              controller: _editController,
              focusNode: _editFocus,
              autofocus: true,
              maxLines: null,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: _isEditableMedia ? '설명 (선택)' : null,
              ),
              onSubmitted: (_) => _saveEdit(),
            ),
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
        // 서버가 첨부를 늘 목록으로 내려준다(예전 메시지는 파일 칸 하나를 목록 하나로) —
        // 뷰어도 같은 목록·번호로 앞뒤 메시지 사진을 이어 붙인다(imageAttachmentsOf).
        final items = imageAttachmentsOf(message);
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
        // 파일 여러 개를 한 말풍선으로 보냈으면 목록 + "전체 다운로드". 지운 파일(파일 삭제)이 하나라도
        // 끼어 있으면(하나뿐이던 파일을 지운 경우 포함) 목록 위젯이 "삭제된 파일입니다" 카드로 그린다.
        if (message.attachments.length > 1 ||
            message.attachments.any((a) => a.deleted)) {
          return ChatFileAttachments(
            session: widget.session,
            attachments: message.attachments,
            message: message,
            attachmentKey: message.attachmentKey,
            attachmentNonce: message.attachmentNonce,
          );
        }
        final url = widget.resolveUrl(message.fileUrl ?? '');
        return DownloadableFile(
          session: widget.session,
          url: url,
          fileName: message.fileName ?? '파일',
          message: message,
          attachmentId: message.attachments.isEmpty
              ? null
              : message.attachments.first.id,
          attachmentKey: message.attachmentKey,
          attachmentNonce: message.attachmentNonce,
        );
      case MessageType.text:
        if (message.isPost) return _buildPostContent(context);
        if (message.isPoll && message.poll != null) {
          return PollCard(
            session: widget.session,
            message: message,
            onOpenThread: widget.onOpenThread,
            onDelete: widget.onDelete,
          );
        }
        // 할 일을 만들 때 올라간 할 일 카드 — 글(`[할 일] 제목` + 담당자 멘션) 대신 카드를 그린다.
        if (message.sharedTodo != null) {
          return TodoMessageCard(session: widget.session, message: message);
        }
        // 안드로이드(터치)에서는 SelectableText였을 때 자체 롱프레스(단어 선택)가 부모
        // GestureDetector의 onLongPress(액션 시트)와 같은 롱프레스 기반이라 제스처 아레나를
        // 먼저 가져가 버려서, 말풍선 여백은 롱프레스가 되는데 글자 위는 안 되는 문제가 있었다
        // — 그래서 안드로이드는 지금도 Text를 쓰고, 선택은 "선택 복사" 메뉴가 전담한다.
        // Windows(마우스)에서는 텍스트 선택이 롱프레스가 아니라 클릭+드래그로 이뤄져서
        // onLongPress와 경합하지 않으므로, 마우스 호버 시 커서가 I-beam으로 바뀌고 드래그로
        // 바로 선택할 수 있도록 SelectableText를 쓴다.
        // 메시지 본문은 환경설정 > 화면 설정 > 글꼴을 따른다(chat_font_scope.dart).
        return ChatFont(
          settings: widget.session.settings,
          builder: (context, font) => FormattedText(
            message.text ?? '',
            format: message.textFormat,
            style: applyChatFont(Theme.of(context).textTheme.bodyMedium, font),
            linkColor: Colors.blue,
            selectable: AppPlatform.isWindows,
            mentions: message.mentions,
            myUserId: widget.session.userId,
            onMentionTap: _openMention,
          ),
        );
      case MessageType.sticker:
        return StickerView(
          stickerId: message.text ?? '',
          emojiSize: 72,
          imageSize: 140,
        );
      case MessageType.system:
      case MessageType.comment:
        // ChatPanel이 system 메시지는 SystemMessageRow로, 댓글 합성 항목은 MessageCommentsCard로
        // 따로 그려서 이 위젯까지 안 옴.
        return const SizedBox.shrink();
    }
  }

  /// 보드 게시글(Message.isPost)을 말풍선에 그릴 때 — "게시글" 표시 + 굵은 제목 + 서식 있는 본문
  /// + 첨부(사진 격자·파일 목록). 보드 화면·게시글 상세는 board_view.dart가 따로 그리고, 여기는
  /// 그 밖의 곳에서 게시글이 말풍선으로 보일 때를 위한 것이다.
  Widget _buildPostContent(BuildContext context) {
    final message = widget.message;
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final images = [
      for (final a in message.liveAttachments)
        if (a.isImage) a,
    ];
    final files = [
      for (final a in message.liveAttachments)
        if (!a.isImage) a,
    ];
    final text = message.text ?? '';
    return Column(
      key: const ValueKey('post-bubble'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dashboard_outlined, size: 13, color: hint),
            const SizedBox(width: 4),
            Text(
              '게시글',
              style: theme.textTheme.labelSmall?.copyWith(color: hint),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          message.title ?? '',
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            height: 1.35,
          ),
        ),
        if (text.isNotEmpty) ...[
          const SizedBox(height: 4),
          FormattedText(
            text,
            format: message.textFormat,
            style: theme.textTheme.bodyMedium,
            linkColor: Colors.blue,
            selectable: AppPlatform.isWindows,
            mentions: message.mentions,
            myUserId: widget.session.userId,
            onMentionTap: _openMention,
          ),
        ],
        if (images.isNotEmpty) ...[
          const SizedBox(height: 8),
          ChatImageAttachments(
            session: widget.session,
            attachments: images,
            message: message,
            room: widget.session.rooms
                .where((r) => r.id == message.roomId)
                .firstOrNull,
          ),
        ],
        if (files.isNotEmpty) ...[
          const SizedBox(height: 8),
          ChatFileAttachments(
            session: widget.session,
            attachments: files,
            message: message,
          ),
        ],
      ],
    );
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
                child: ExternalImage(url: preview.imageUrl!),
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
