import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../services/room_chat_controller.dart';
import '../services/session.dart';
import '../widgets/comment_input_bar.dart';
import '../widgets/message_bubble.dart';
import '../widgets/message_comments_card.dart';
import '../widgets/muted_scrollbar.dart';

/// 메시지 하나의 댓글 스레드. 데스크톱은 우측 패널(asPanel: true), 모바일은 전체화면으로 쓴다
/// (SearchScreen과 동일한 이중 모드 패턴). [message]는 RoomChatController.messages 안에 있는
/// 바로 그 인스턴스라서, 댓글이 실시간으로 도착하면(controller.addComment) 여기서도 즉시 반영된다.
///
/// 데스크톱 패널은 호출부(desktop_home_screen.dart)가 key 없이 재사용하므로(다른 메시지의 댓글
/// 아이콘을 연달아 눌러도 이 State가 그대로 유지됨), 메시지가 바뀌는 건 didUpdateWidget에서 감지한다.
class MessageThreadScreen extends StatefulWidget {
  final Session session;
  final Room room;
  final Message message;
  final RoomChatController controller;
  final bool asPanel;
  final VoidCallback? onClose;

  const MessageThreadScreen({
    super.key,
    required this.session,
    required this.room,
    required this.message,
    required this.controller,
    this.asPanel = false,
    this.onClose,
  });

  @override
  State<MessageThreadScreen> createState() => _MessageThreadScreenState();
}

class _MessageThreadScreenState extends State<MessageThreadScreen> {
  final _scrollController = ScrollController();

  /// 스크롤이 맨 아래가 아닌 채로 내가 댓글을 새로 달면 그 댓글이 보이도록 맨 아래로
  /// 스크롤한다(chat_panel.dart의 같은 패턴 참고). 다른 사람이 단 댓글은 건드리지 않는다.
  String? _lastSeenCommentId;

  @override
  void initState() {
    super.initState();
    _lastSeenCommentId = widget.message.comments.isNotEmpty
        ? widget.message.comments.last.id
        : null;
    widget.controller.addListener(_maybeScrollToNewOwnComment);
  }

  @override
  void didUpdateWidget(covariant MessageThreadScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_maybeScrollToNewOwnComment);
      widget.controller.addListener(_maybeScrollToNewOwnComment);
    }
    if (oldWidget.message.id != widget.message.id) {
      // 패널을 안 닫고 다른 메시지의 스레드로 바로 넘어간 경우, 이전 스크롤 위치가 그대로
      // 남아있으면 이상해 보이므로 처음으로 되돌린다.
      _lastSeenCommentId = widget.message.comments.isNotEmpty
          ? widget.message.comments.last.id
          : null;
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_maybeScrollToNewOwnComment);
    _scrollController.dispose();
    super.dispose();
  }

  void _maybeScrollToNewOwnComment() {
    final comments = widget.message.comments;
    if (comments.isEmpty) return;
    final last = comments.last;
    if (last.id == _lastSeenCommentId) return;
    _lastSeenCommentId = last.id;
    if (last.senderId == widget.session.userId) _scrollToBottom();
  }

  void _scrollToBottom() {
    // 채팅방(ScrollablePositionedList, index 기반)과 달리 여기는 평범한 ListView라 목표
    // 위치를 position.maxScrollExtent로 직접 읽는데, 새 댓글이 막 추가된 첫 프레임엔 뷰포트가
    // 아직 이전 콘텐츠 크기를 들고 있을 때가 있다(내용 크기 변화를 반영하려면 레이아웃이 한 번
    // 더 필요한 경우) — 그래서 postFrameCallback을 한 번만 쓰면 "한 번에 안 되고 그다음
    // 댓글에서야 밀려서 맞는" 증상이 난다. 프레임을 하나 더 기다렸다가(중첩 postFrameCallback)
    // maxScrollExtent가 새 값으로 안정된 뒤에 스크롤한다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      });
    });
  }

  AppUser? _memberOf(String? userId) {
    for (final m in widget.room.members) {
      if (m.id == userId) return m;
    }
    return null;
  }

  Widget _body(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final comments = widget.message.comments;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: MutedScrollbar(
                controller: _scrollController,
                child: ListView(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  children: [
                    MessageBubble(
                      session: widget.session,
                      message: widget.message,
                      resolveUrl: widget.session.resolveUrl,
                      isMine: widget.message.senderId == widget.session.userId,
                      sender: _memberOf(widget.message.senderId),
                      onEdit: widget.controller.editMessage,
                      onDelete: widget.controller.deleteMessage,
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Divider(height: 1),
                    ),
                    Text(
                      '댓글 ${comments.length}',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    // 채팅과 동일하게, 같은 사람이 연달아 단 댓글은 첫 댓글에만 프로필 사진을 보여준다.
                    for (var i = 0; i < comments.length; i++)
                      CommentEntryLine(
                        session: widget.session,
                        comment: comments[i],
                        sender: _memberOf(comments[i].senderId),
                        isMine: comments[i].senderId == widget.session.userId,
                        resolveUrl: widget.session.resolveUrl,
                        onEdit: widget.controller.editComment,
                        onDelete: widget.controller.deleteComment,
                        fullWidth: true,
                        showAvatar:
                            i == 0 ||
                            comments[i - 1].senderId != comments[i].senderId,
                      ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            CommentInputBar(
              // 데스크톱에서는 패널을 안 닫고 다른 메시지의 댓글 아이콘을 연달아 눌러도 이
              // 위젯 자체는 그대로 재사용될 수 있어서, key를 메시지별로 다르게 줘서 매번 새로
              // 만들어지게 한다 — 그래야 autofocus가 그때마다 다시 걸린다.
              key: ValueKey(widget.message.id),
              controller: widget.controller,
              messageId: widget.message.id,
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.asPanel) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '메시지',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _body(context)),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('메시지')),
      body: _body(context),
    );
  }
}
