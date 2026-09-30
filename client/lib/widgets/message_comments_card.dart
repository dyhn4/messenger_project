import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'sticker_view.dart';
import '../models/app_user.dart';
import '../models/comment.dart';
import '../models/mention.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../services/edit_policy.dart';
import '../services/mention_logic.dart';
import '../services/session.dart';
import 'attachment_widgets.dart';
import 'avatar_utils.dart';
import 'hover_toolbar.dart';
import 'mention_autocomplete.dart';
import 'mention_profile.dart';
import 'message_actions.dart';
import 'rich_text_format.dart';
import 'self_destruct_countdown.dart';

final _timeFormat = DateFormat('a h:mm');
final _dateTimeFormat = DateFormat('yyyy/MM/dd a h:mm');

/// [comments]의 [i]번째 댓글에 시간을 보여줄지 — 같은 사람이 같은 분(分)에 연달아 단 댓글은
/// 그 묶음의 마지막 댓글에만 보여준다(채팅 메시지에서 시간을 묶는 것과 같은 규칙 — 그쪽도
/// 마지막 메시지에만 시간을 보여준다, chat_panel.dart의 showTime 계산 참고). 인라인 댓글
/// 카드와 스레드 패널이 같은 규칙을 쓰도록 두 호출부가 공유한다.
bool showCommentTimeAt(List<Comment> comments, int i) {
  if (i == comments.length - 1) return true;
  final current = comments[i];
  final next = comments[i + 1];
  if (next.senderId != current.senderId) return true;
  final a = current.createdAt;
  final b = next.createdAt;
  return !(a.year == b.year &&
      a.month == b.month &&
      a.day == b.day &&
      a.hour == b.hour &&
      a.minute == b.minute);
}

/// 원본 메시지에 달린, 끊기지 않고 연달아 온 댓글 한 묶음(run)을 채팅 타임라인에 그려 넣는 항목
/// (chat_panel.dart가 MessageType.comment 항목 중 "런의 첫 댓글"에서만 하나씩 그린다 — 같은
/// 런의 나머지 댓글은 이 카드 안의 목록에 흡수되어 별도 항목으로는 안 그려진다. 런은 "이 원본
/// 메시지에 대한 댓글이 사이에 다른 채팅 없이 연달아 온 구간"이라, 채팅방 마지막 항목이 이 카드인
/// 동안 계속 댓글을 주고받으면 새 댓글이 그때마다 이 카드 안에 이어 붙고(런 확장), 중간에 일반
/// 채팅이 한 번 끼면 그다음 댓글부터는 새 카드가 새로 시작된다 — chat_panel.dart의
/// isFirstCommentInRun 판정 참고).
/// 왼쪽엔 작은 댓글 아이콘, 가운데엔 원본 메시지를 인용한 카드(+ "N개 댓글 모두 보기"), 그 아래
/// 이 런에 속한 댓글들이 발신자별 배경색(내 댓글=파랑, 상대=회색 — MessageBubble과 같은 색 규칙)
/// 줄로 하나씩 이어 붙는다. 시간은 MessageBubble처럼 그 색상 말풍선 오른쪽 바깥(일반 텍스트, 배경
/// 없음)에 둔다. "N개 댓글"의 N은 [parentMessage].comments.length(그 원본 메시지에 달린 전체
/// 댓글 수, 이 런에 있는 것만이 아니라)를 그대로 쓴다.
class MessageCommentsCard extends StatelessWidget {
  final Session session;
  final Message parentMessage;
  final List<Comment> comments;
  final Room room;
  final String? currentUserId;
  final String Function(String relative) resolveUrl;
  final VoidCallback onTap;
  final Future<void> Function(
    String commentId,
    String text, {
    List<TextFormatRun>? format,
    List<Mention>? mentions,
  })?
  onEditComment;
  final Future<void> Function(String commentId)? onDeleteComment;

  const MessageCommentsCard({
    super.key,
    required this.session,
    required this.parentMessage,
    required this.comments,
    required this.room,
    required this.currentUserId,
    required this.resolveUrl,
    required this.onTap,
    this.onEditComment,
    this.onDeleteComment,
  });

  AppUser? _memberOf(String? userId) {
    for (final m in room.members) {
      if (m.id == userId) return m;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final originalSender = _memberOf(parentMessage.senderId);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.mode_comment_outlined,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              // Expanded 하나만 쓰면 카드가 항상 남는 폭을 전부 채워서, 창을 넓게 하면 카드도
              // 한없이 넓어진다. LayoutBuilder로 실제 남는 폭을 재서 min(700, 남는 폭)만큼만
              // SizedBox로 못박아 두면, 좁을 땐 기존처럼 꽉 채우고 넓을 땐 700px에서 멈춘다.
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth > 700
                        ? 700.0
                        : constraints.maxWidth;
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: width,
                        child: _buildCard(context, originalSender),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCard(BuildContext context, AppUser? originalSender) {
    // 다크 모드에서는 배경(surface)과 카드 색(surfaceContainerHighest)의 차이가 alpha 0.5로
    // 섞으면 잘 안 보여서, 살짝 더 밝게 보이도록 다크 모드에서만 더 진하게(불투명하게) 낸다.
    // 라이트 모드는 원래도 문제 없었다고 해서 그대로 둔다.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(
        alpha: isDark ? 0.9 : 0.5,
      ),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  // 자동화 메시지에 달린 댓글이면 채팅 말풍선과 같은 번개 아바타.
                  if (parentMessage.isAutomation)
                    const AutomationAvatar(radius: 12)
                  else
                    AvatarView(
                      username:
                          originalSender?.name ?? parentMessage.senderName,
                      avatarType: originalSender?.avatarType ?? 'initial',
                      avatarEmoji: originalSender?.avatarEmoji,
                      avatarColor: originalSender?.avatarColor,
                      avatarUrl: originalSender?.avatarUrl,
                      resolveUrl: resolveUrl,
                      radius: 12,
                    ),
                  const SizedBox(width: 6),
                  Text(
                    originalSender?.name ?? parentMessage.senderName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _timeFormat.format(parentMessage.createdAt),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ),
              if (parentMessage.deleted)
                Text(
                  '삭제된 메시지입니다',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: Theme.of(context).hintColor,
                  ),
                )
              else if (parentMessage.decryptFailed)
                Text(
                  '이 메시지는 복호화할 수 없습니다',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: Theme.of(context).hintColor,
                  ),
                )
              else if (parentMessage.type == MessageType.text &&
                  (parentMessage.text?.isNotEmpty ?? false)) ...[
                const SizedBox(height: 4),
                Text(
                  parentMessage.text!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${parentMessage.comments.length}개 댓글 모두 보기',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.arrow_forward,
                    size: 12,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ),
              // 이 런에 속한 댓글들 — 카드 테두리(Material) 밖으로 나가지 않고 이 안에서 계속
              // 이어 붙어야 "새 채팅이 온 것"이 아니라 "이 카드 안에 댓글이 쌓이는 것"으로 보인다.
              // 채팅과 동일하게, 같은 사람이 연달아 단 댓글은 첫 댓글에만 프로필 사진을 보여준다.
              for (var i = 0; i < comments.length; i++)
                CommentEntryLine(
                  session: session,
                  comment: comments[i],
                  sender: _memberOf(comments[i].senderId),
                  isMine:
                      currentUserId != null &&
                      comments[i].senderId == currentUserId,
                  resolveUrl: resolveUrl,
                  // 댓글 자체는 독립된 자동 삭제 타이머가 없다 — 원본 메시지가 만료되면 서버가
                  // FK cascade로 댓글도 같이 지운다(secretExpiry.js). 그래서 "삭제되기까지 남은
                  // 시간"은 항상 원본 메시지의 expiresAt을 그대로 보여준다.
                  expiresAt: parentMessage.expiresAt,
                  onEdit: onEditComment,
                  onDelete: onDeleteComment,
                  showAvatar:
                      i == 0 ||
                      comments[i - 1].senderId != comments[i].senderId,
                  showTime: showCommentTimeAt(comments, i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 댓글 하나를 나타내는 줄. 두 군데서 같이 쓴다:
/// - 채팅 카드 안(fullWidth: false, 기본값): 말풍선이 내용 길이만큼만 차지(Flexible)하고, 시간은
///   그 옆(오른쪽 바깥)에 일반 텍스트로 붙는다. 호버 시 뜨는 더보기 툴바도 그 옆 남는 공간에 들어간다.
/// - 댓글 스레드 패널(message_thread_screen.dart, fullWidth: true): 말풍선이 패널 가로폭을
///   가득 채우고(Expanded), 이름 아래에 전체 날짜+시간을 보여준다. 이 경우엔 말풍선이 이미 폭을
///   다 쓰므로, 호버 툴바 자리를 오른쪽에 고정 너비로 항상 비워둬서(호버 여부와 무관하게 폭이
///   안 바뀌게) 나타날 때 말풍선이 밀리지 않게 한다.
/// 발신자가 나면 파란(primaryContainer), 남이면 회색(surfaceContainerHighest) 배경으로
/// MessageBubble과 같은 색 규칙을 써서 누구 댓글인지 한눈에 구분되게 한다. 내 댓글 위에 마우스를
/// 올리면(호버) MessageBubble과 같은 흰 상자 툴바(더보기 → 수정/삭제)가 뜬다.
class CommentEntryLine extends StatefulWidget {
  final Session session;
  final Comment comment;
  final AppUser? sender;
  final bool isMine;
  final String Function(String relative) resolveUrl;
  final Future<void> Function(
    String commentId,
    String text, {
    List<TextFormatRun>? format,
    List<Mention>? mentions,
  })?
  onEdit;
  final Future<void> Function(String commentId)? onDelete;
  final bool fullWidth;

  /// 같은 사람이 연달아 단 댓글 중 첫 댓글이 아니면 false — 채팅에서 연속 발신자의 아바타/이름을
  /// 첫 메시지에만 보여주는 것과 동일한 규칙(호출부에서 이전 댓글의 senderId와 비교해서 넘긴다).
  /// 아바타와 이름을 같이 가린다.
  final bool showAvatar;

  /// 같은 사람이 **같은 분(分)에** 연달아 단 댓글 중 첫 댓글이 아니면 false — 그 묶음에서
  /// 시간을 한 번만 보여준다(호출부에서 이전 댓글의 senderId/createdAt과 비교해서 넘긴다).
  /// [showAvatar]와 조건이 달라서(이쪽은 분까지 같아야 함) 따로 받는다.
  final bool showTime;

  /// 원본 메시지의 자동 삭제 예정 시각(비밀 대화, 읽은 뒤부터 확정됨) — 댓글은 독립 타이머가
  /// 없고 원본과 함께 소멸하므로 그 값을 그대로 받아 보여준다(self_destruct_countdown.dart).
  final DateTime? expiresAt;

  const CommentEntryLine({
    super.key,
    required this.session,
    required this.comment,
    required this.sender,
    required this.isMine,
    required this.resolveUrl,
    this.onEdit,
    this.onDelete,
    this.fullWidth = false,
    this.showAvatar = true,
    this.showTime = true,
    this.expiresAt,
  });

  @override
  State<CommentEntryLine> createState() => _CommentEntryLineState();
}

class _CommentEntryLineState extends State<CommentEntryLine> {
  static const _toolbarSlotWidth = 40.0;

  // 툴바는 댓글 줄 아래에 Overlay로 떠 있어서(FloatingHoverToolbar) 이 줄의 MouseRegion
  // 바깥이다 — 말풍선에서 툴바로 마우스를 옮기는 순간 줄 쪽 exit이 먼저 불려서 툴바가
  // 사라져버리므로, MessageBubble과 동일하게 양쪽 호버를 OR로 묶고 짧은 소멸 유예를 둔다.
  bool _rowHovering = false;
  bool _toolbarHovering = false;
  bool _menuOpen = false;
  bool _hovering = false;
  Timer? _hoverExitTimer;
  bool _editing = false;
  bool _savingEdit = false;
  final _editController = RichTextEditingController();
  final _editFocus = FocusNode();

  final _toolbarPortal = OverlayPortalController();

  @override
  void dispose() {
    _hoverExitTimer?.cancel();
    _editController.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  void _setRowHovering(bool value) {
    _rowHovering = value;
    _updateHoverState();
  }

  void _setToolbarHovering(bool value) {
    _toolbarHovering = value;
    _updateHoverState();
  }

  /// 더보기 메뉴가 열려 있는 동안에는 툴바를 붙잡아 둔다(MessageBubble과 같은 이유 —
  /// 마우스가 메뉴로 넘어가면 툴바 밖으로 나간 것으로 잡힌다).
  void _setMenuOpen(bool value) {
    _menuOpen = value;
    _updateHoverState();
  }

  void _updateHoverState() {
    _hoverExitTimer?.cancel();
    if (_rowHovering || _toolbarHovering || _menuOpen) {
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
      !widget.comment.deleted && !widget.comment.decryptFailed && !_editing;

  /// OverlayPortalController.show/hide는 빌드 중에 부르면 안 돼서(SDK 주석) 호버
  /// 콜백/타이머 같은 빌드 밖 지점에서만 호출한다.
  void _syncToolbarPortal() {
    final show = _hovering && _canShowToolbar;
    if (show == _toolbarPortal.isShowing) return;
    show ? _toolbarPortal.show() : _toolbarPortal.hide();
  }

  void _startEdit() {
    if (!isEditDeleteAllowed(widget.session)) {
      showEditWindowExpiredDialog(context, editDeleteDisabledMessage);
      return;
    }
    if (!isWithinEditDeleteWindow(widget.session, widget.comment.createdAt)) {
      showEditWindowExpiredDialog(
        context,
        editDeleteWindowExpiredMessage(
          widget.session,
          what: '댓글',
          action: '수정',
        ),
      );
      return;
    }
    setState(() => _editing = true);
    // 수정 화면에서도 멘션을 고칠 수 있다 — 지금 멘션 구간을 입력칸에 넘겨 받는다.
    final room = widget.session.roomById(widget.comment.roomId);
    _editController.mentionsEnabled = room != null && roomAllowsMention(room);
    _editController.load(
      widget.comment.text ?? '',
      widget.comment.textFormat,
      mentions: widget.comment.mentions,
    );
    _syncToolbarPortal(); // 수정 중에는 툴바를 닫는다.
  }

  void _cancelEdit() {
    setState(() => _editing = false);
    _syncToolbarPortal();
  }

  Future<void> _saveEdit() async {
    final (:text, :format) = _editController.formatted();
    if (text.isEmpty) return;
    final room = widget.session.roomById(widget.comment.roomId);
    final mentions = room == null
        ? const <Mention>[]
        : mentionsToSend(_editController, room, widget.session.userId);
    setState(() => _savingEdit = true);
    try {
      await widget.onEdit!(
        widget.comment.id,
        text,
        format: format,
        mentions: mentions,
      );
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

  /// 메시지 쪽 _canModerate와 같은 규칙 — 팀의 소유자·관리자는 자기가 들어가 있는 방(비밀
  /// 대화 제외)에서 남의 댓글도, 팀이 정한 삭제 가능 시간 안에서 지울 수 있다(서버 moderation.js).
  bool get _canModerate {
    if (widget.isMine || widget.onDelete == null) return false;
    if (!widget.session.canModerateContent) return false;
    if (!isEditDeleteAllowed(widget.session)) return false;
    if (!isWithinEditDeleteWindow(widget.session, widget.comment.createdAt)) {
      return false;
    }
    final room = widget.session.rooms.where(
      (r) => r.id == widget.comment.roomId,
    );
    return room.isNotEmpty && !room.first.isSecret;
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final moderating = !widget.isMine;
    if (!isEditDeleteAllowed(widget.session)) {
      showEditWindowExpiredDialog(context, editDeleteDisabledMessage);
      return;
    }
    if (!isWithinEditDeleteWindow(widget.session, widget.comment.createdAt)) {
      showEditWindowExpiredDialog(
        context,
        editDeleteWindowExpiredMessage(
          widget.session,
          what: '댓글',
          action: '삭제',
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('댓글 삭제'),
        content: Text(
          moderating ? '관리자 권한으로 다른 사람의 댓글을 삭제합니다. 계속할까요?' : '이 댓글을 삭제할까요?',
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
      await widget.onDelete!(widget.comment.id);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('삭제 실패: $e')));
    }
  }

  /// 롱프레스로 뜨는 하단 시트(모바일) — message_bubble.dart의 메시지 롱프레스와 동일한
  /// 항목(메시지 공유/복사/선택 복사/메시지 전달)을 쓴다. 댓글엔 "댓글" 항목(댓글 스레드
  /// 열기)이 의미가 없어 onOpenThread를 안 넘긴다 — 댓글에 또 댓글을 달 수는 없으므로.
  void _showActionSheet(BuildContext context) {
    final comment = widget.comment;
    final displayName = widget.sender?.name ?? comment.senderName;
    showMessageActionSheet(
      context,
      session: widget.session,
      message: messageFromComment(comment),
      senderDisplayName: displayName,
      isComment: true,
    );
  }

  /// 본문 안 멘션 이름을 눌렀을 때 — 그 멤버의 프로필(mention_profile.dart).
  void _openMention(Mention mention) => openMentionProfile(
    context,
    widget.session,
    roomId: widget.comment.roomId,
    mention: mention,
  );

  Widget _buildBubbleContent(BuildContext context) {
    final comment = widget.comment;
    final sender = widget.sender;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 채팅과 동일하게, 같은 사람이 연달아 단 댓글은 첫 댓글에만 이름(과 아바타)을 보여준다.
        if (widget.showAvatar)
          Text(
            sender?.name ?? comment.senderName,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
        if (widget.fullWidth) ...[
          if (widget.expiresAt != null)
            SelfDestructCountdown(expiresAt: widget.expiresAt!),
          if (widget.showTime)
            Text(
              _dateTimeFormat.format(comment.createdAt),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
        ],
        if (comment.deleted)
          Text(
            '삭제된 댓글입니다',
            style: TextStyle(
              fontStyle: FontStyle.italic,
              color: Theme.of(context).hintColor,
            ),
          )
        else if (comment.decryptFailed)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_outline,
                size: 12,
                color: Theme.of(context).hintColor,
              ),
              const SizedBox(width: 4),
              Text(
                '이 댓글은 복호화할 수 없습니다',
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  fontSize: 13,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ],
          )
        else if (_editing)
          _buildEditor(context)
        else ...[
          // 첨부(이미지/파일)에 캡션이 같이 달려 있으면 그 위에 먼저 보여준다(MessageBubble과 동일).
          // 이모티콘은 text가 캡션이 아니라 스티커 id라 이 대상이 아니다.
          if (comment.type != MessageType.text &&
              comment.type != MessageType.sticker &&
              (comment.text?.isNotEmpty ?? false)) ...[
            FormattedText(
              comment.text!,
              format: comment.textFormat,
              style: const TextStyle(fontSize: 13),
              linkColor: Colors.blue,
              mentions: comment.mentions,
              myUserId: widget.session.userId,
              onMentionTap: _openMention,
            ),
            const SizedBox(height: 4),
          ],
          if (comment.type == MessageType.text)
            FormattedText(
              comment.text ?? '',
              format: comment.textFormat,
              style: const TextStyle(fontSize: 13),
              linkColor: Colors.blue,
              mentions: comment.mentions,
              myUserId: widget.session.userId,
              onMentionTap: _openMention,
            )
          else
            _buildAttachment(context),
          if (comment.editedAt != null)
            Text(
              '(수정됨)',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
        ],
      ],
    );
  }

  /// 이미지/파일 댓글의 첨부 내용. MessageBubble의 이미지/파일 렌더링과 같은 위젯을 재사용한다.
  Widget _buildAttachment(BuildContext context) {
    final comment = widget.comment;
    switch (comment.type) {
      case MessageType.image:
        return DownloadableImage(
          session: widget.session,
          url: widget.resolveUrl(comment.fileUrl ?? ''),
          fileName: comment.fileName ?? 'image.png',
          attachmentKey: comment.attachmentKey,
          attachmentNonce: comment.attachmentNonce,
          thumbnailUrl: comment.thumbnailUrl == null
              ? null
              : widget.resolveUrl(comment.thumbnailUrl!),
          thumbnailKey: comment.thumbnailKey,
          thumbnailNonce: comment.thumbnailNonce,
        );
      case MessageType.file:
        return DownloadableFile(
          session: widget.session,
          url: widget.resolveUrl(comment.fileUrl ?? ''),
          fileName: comment.fileName ?? '파일',
          message: messageFromComment(comment),
          attachmentKey: comment.attachmentKey,
          attachmentNonce: comment.attachmentNonce,
        );
      case MessageType.sticker:
        return StickerView(
          stickerId: comment.text ?? '',
          emojiSize: 48,
          imageSize: 100,
        );
      case MessageType.text:
      case MessageType.system:
      case MessageType.comment:
        return const SizedBox.shrink();
    }
  }

  /// 메뉴 항목이 쓰는 context는 툴바가 그려지는 Overlay가 아니라 이 State의 context여야
  /// 한다 — Overlay 쪽은 툴바가 닫히면 죽은 context가 된다(message_bubble.dart와 동일).
  Widget _buildToolbar() {
    final context = this.context;
    final comment = widget.comment;
    final displayName = widget.sender?.name ?? comment.senderName;
    // 팀이 메시지 수정/삭제를 꺼두면([메시지 설정]) 본인 댓글도 못 고치고 못 지운다.
    final allowed = widget.isMine && isEditDeleteAllowed(widget.session);
    final canEdit = allowed && widget.onEdit != null;
    final canDelete = allowed && widget.onDelete != null;
    final canEditDelete = canEdit || canDelete;
    return HoverToolbar(
      children: [
        HoverToolbarButton(
          icon: Icons.more_vert,
          tooltip: '더보기',
          onMenuOpenChanged: _setMenuOpen,
          menuChildren: [
            ...messageActionMenuItems(
              context,
              session: widget.session,
              message: messageFromComment(comment),
              senderDisplayName: displayName,
              isComment: true,
            ),
            if (canEditDelete) hoverMenuDivider(),
            // 메시지 수정과 동일하게, 텍스트 댓글만 수정할 수 있다(서버도 동일하게 막음).
            if (canEdit && comment.type == MessageType.text)
              hoverMenuItem(
                icon: Icons.edit,
                label: '수정',
                onPressed: _startEdit,
              ),
            if (canDelete)
              hoverMenuItem(
                icon: Icons.delete,
                label: '삭제',
                color: Colors.redAccent,
                onPressed: () => _confirmDelete(context),
              ),
            // 소유자·관리자의 콘텐츠 관리 — 남의 댓글도 지울 수 있다(_canModerate 참고).
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

  @override
  Widget build(BuildContext context) {
    final comment = widget.comment;
    final sender = widget.sender;
    // PC 더보기(공유/복사/전달)는 누구 댓글이든 다 보여준다 — 수정/삭제만 그 안에서
    // isMine으로 따로 가린다(_buildToolbar 참고). 모바일 롱프레스 액션 시트도 마찬가지.
    final showToolbar = !comment.deleted && !comment.decryptFailed && !_editing;

    final isSticker =
        comment.type == MessageType.sticker &&
        !comment.deleted &&
        !comment.decryptFailed;
    final bubble = GestureDetector(
      onLongPress: showToolbar ? () => _showActionSheet(context) : null,
      child: Container(
        padding: isSticker
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: isSticker
            ? const BoxDecoration()
            : BoxDecoration(
                color: widget.isMine
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
        child: _buildBubbleContent(context),
      ),
    );

    // 같은 사람이 연달아 단 댓글은 첫 댓글에만 아바타를 보여준다(showAvatar: false면 같은
    // 지름의 빈 자리만 남겨서 말풍선 들여쓰기는 그대로 유지).
    final avatarRadius = widget.fullWidth ? 16.0 : 12.0;
    final avatar = widget.showAvatar
        ? AvatarView(
            username: sender?.name ?? comment.senderName,
            avatarType: sender?.avatarType ?? 'initial',
            avatarEmoji: sender?.avatarEmoji,
            avatarColor: sender?.avatarColor,
            avatarUrl: sender?.avatarUrl,
            resolveUrl: widget.resolveUrl,
            radius: avatarRadius,
          )
        : SizedBox(width: avatarRadius * 2, height: avatarRadius * 2);

    final Widget row;
    if (widget.fullWidth) {
      // 툴바는 이제 이 줄 아래에 Overlay로 뜨지만(아래 FloatingHoverToolbar), 툴바가 여기
      // 있던 시절에 잡아둔 오른쪽 빈 자리는 그대로 남겨둔다 — 없애면 말풍선 폭이 갑자기
      // 넓어진다.
      row = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          avatar,
          const SizedBox(width: 8),
          Expanded(child: bubble),
          const SizedBox(width: 4),
          const SizedBox(width: _toolbarSlotWidth),
        ],
      );
    } else {
      row = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          avatar,
          const SizedBox(width: 6),
          // Expanded(꽉 채움) 대신 Flexible(내용만큼만)을 써서, 말풍선이 카드 가로폭을 전부
          // 채우지 않고 내용 길이만큼만 차지하게 한다.
          Flexible(child: bubble),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.expiresAt != null)
                SelfDestructCountdown(expiresAt: widget.expiresAt!),
              if (widget.showTime)
                Text(
                  _timeFormat.format(comment.createdAt),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 6),
          // fullWidth와 동일하게 툴바가 쓰던 오른쪽 빈 자리를 그대로 남겨둔다.
          const SizedBox(width: _toolbarSlotWidth),
        ],
      );
    }

    return Padding(
      padding: EdgeInsets.only(top: widget.fullWidth ? 10 : 6),
      child: MouseRegion(
        onEnter: (_) => _setRowHovering(true),
        onExit: (_) => _setRowHovering(false),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            row,
            // 말풍선 왼쪽 아래(아바타 폭만큼 들여쓴 자리)를 가리키는 0크기 앵커 — 툴바는
            // 여기 기준으로 Overlay에 떠서 아래 댓글/메시지를 밀지 않는다.
            Padding(
              padding: EdgeInsets.only(
                left: avatarRadius * 2 + (widget.fullWidth ? 8 : 6),
              ),
              child: FloatingHoverToolbar(
                controller: _toolbarPortal,
                toolbarBuilder: (_) => MouseRegion(
                  onEnter: (_) => _setToolbarHovering(true),
                  onExit: (_) => _setToolbarHovering(false),
                  child: _buildToolbar(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 수정 입력칸에도 "@" 자동완성을 붙인다(방을 모르거나 비밀 대화면 그대로).
  Widget _withMentions(Widget field) {
    final room = widget.session.roomById(widget.comment.roomId);
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
        RichFormatToolbar(controller: _editController, focusNode: _editFocus),
        _withMentions(
          RichFieldWrapper(
            controller: _editController,
            child: TextField(
              controller: _editController,
              focusNode: _editFocus,
              autofocus: true,
              maxLines: null,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
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
}
