import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../data/stickers.dart';
import '../models/app_user.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../services/app_platform.dart';
import '../services/room_chat_controller.dart';
import '../services/session.dart';
import '../widgets/attachment_widgets.dart';
import '../widgets/board_view.dart' show PostDetailHead;
import '../widgets/comment_input_bar.dart';
import '../widgets/dropped_files.dart';
import '../widgets/hover_toolbar.dart' show kHoverToolbarHeight;
import '../widgets/message_bubble.dart';
import '../widgets/message_comments_card.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/sticker_picker.dart';
import '../widgets/sticker_preview_card.dart';
import 'post_editor_dialog.dart' show postEditorsOpen;

/// 메시지 하나의 댓글 스레드. 데스크톱은 우측 패널(asPanel: true), 모바일은 전체화면으로 쓴다
/// (SearchScreen과 동일한 이중 모드 패턴). [message]는 RoomChatController.messages 안에 있는
/// 바로 그 인스턴스라서, 댓글이 실시간으로 도착하면(controller.addComment) 여기서도 즉시 반영된다.
///
/// 보드 게시글(Message.isPost)이면 "게시글 상세"가 된다 — 맨 위에 말풍선 대신 제목·본문·첨부를
/// 그리고(PostDetailHead), 그 아래 댓글과 댓글 입력칸은 똑같이 쓴다.
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

  /// CommentInputBar에 원래 주던 key: ValueKey(message.id)를 대신한다 — 메시지가 바뀔 때마다
  /// (didUpdateWidget) 새 인스턴스로 교체해서 위젯이 새로 만들어지게 하는 건 똑같이 하면서,
  /// GlobalKey라 addDroppedFiles(드래그앤드롭)를 호출할 수 있는 State 접근 통로도 겸한다.
  GlobalKey<CommentInputBarState> _commentInputBarKey =
      GlobalKey<CommentInputBarState>();
  bool _dragHovering = false;

  /// chat_panel.dart와 동일 — 댓글 목록 위에 떠 있는 오버레이로 그려서 입력창을 밀어내지 않는다.
  Sticker? _pendingSticker;
  bool _stickerPickerOpen = false;

  void _toggleStickerPicker() {
    setState(() => _stickerPickerOpen = !_stickerPickerOpen);
    // chat_panel.dart와 동일 — 내가 열면 owner를 가져와서 다른 화면(채팅방 등)에 열려있던
    // 패널을 닫히게 하고, 내가 닫는 거면(그리고 owner가 나였다면) 놓아준다.
    if (_stickerPickerOpen) {
      widget.session.openStickerPickerOwner.value = this;
    } else if (widget.session.openStickerPickerOwner.value == this) {
      widget.session.openStickerPickerOwner.value = null;
    }
  }

  /// chat_panel.dart의 _closeStickerPicker와 동일 — 패널 바깥 클릭(TapRegion.onTapOutside)
  /// 전용. 이모티콘을 실제로 고른 경우(_selectSticker)는 이미 owner를 놓아주므로 건드리지
  /// 않게 아직 열려 있을 때만 처리한다.
  void _closeStickerPicker() {
    if (!_stickerPickerOpen) return;
    setState(() => _stickerPickerOpen = false);
    if (widget.session.openStickerPickerOwner.value == this) {
      widget.session.openStickerPickerOwner.value = null;
    }
  }

  void _selectSticker(Sticker sticker) {
    setState(() {
      _pendingSticker = sticker;
      _stickerPickerOpen = false;
    });
    if (widget.session.openStickerPickerOwner.value == this) {
      widget.session.openStickerPickerOwner.value = null;
    }
    // chat_panel.dart의 _selectSticker와 같은 이유 — 포커스를 입력칸으로 되돌려서 Enter로
    // 바로 보낼 수 있게 한다.
    _commentInputBarKey.currentState?.focusInput();
  }

  void _removeSticker() => setState(() => _pendingSticker = null);

  void _onStickerPickerOwnerChanged() {
    if (_stickerPickerOpen &&
        widget.session.openStickerPickerOwner.value != this) {
      setState(() => _stickerPickerOpen = false);
    }
  }

  /// 스크롤이 맨 아래가 아닌 채로 내가 댓글을 새로 달면 그 댓글이 보이도록 맨 아래로
  /// 스크롤한다. 남이 단 댓글은 내가 이미 맨 아래를 보고 있을 때만 따라간다
  /// (chat_panel.dart의 같은 패턴 참고) — _isAtBottom 참고.
  String? _lastSeenCommentId;

  /// 지금 맨 아래를 보고 있는지. (드래그 여부로 판단하는 방식은 버렸다 — 마우스 휠
  /// 스크롤은 dragDetails가 안 잡혀서 PC에서 위로 스크롤해도 "맨 아래를 계속 보는
  /// 중"으로 잘못 남아있는 문제가 있었다. chat_panel.dart와 동일한 이유.)
  bool get _isAtBottom {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.pixels >= position.maxScrollExtent - 4.0;
  }

  @override
  void initState() {
    super.initState();
    _lastSeenCommentId = widget.message.comments.isNotEmpty
        ? widget.message.comments.last.id
        : null;
    widget.controller.addListener(_maybeScrollToNewComment);
    widget.session.openStickerPickerOwner.addListener(
      _onStickerPickerOwnerChanged,
    );
    // 모바일(전체화면)에서는 이 스레드가 채팅 화면을 완전히 덮으므로, 그 방 메시지
    // 목록이 실제로는 안 보인다는 걸 Session에 알려서 새 메시지 알림/안읽음 처리가
    // (activeRoomId만 보고 "보고 있다"고 착각해) 잘못 억제되지 않게 한다. 데스크톱은
    // 패널이 옆에 나란히 떠서 목록이 항상 같이 보이므로 필요 없다.
    if (!widget.asPanel) {
      widget.session.setMobileCommentThreadOpen(widget.room.id);
    }
    // 채팅방에서 "N개 댓글 모두 보기"를 눌러 스레드를 열면, 최신 댓글이 바로 보이도록 맨
    // 아래로 스크롤한다. 게시글은 본문부터 읽어야 하니 맨 위에서 시작한다.
    if (!widget.message.isPost) _scrollToBottom();
  }

  @override
  void didUpdateWidget(covariant MessageThreadScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_maybeScrollToNewComment);
      widget.controller.addListener(_maybeScrollToNewComment);
    }
    if (oldWidget.message.id != widget.message.id) {
      // 패널을 안 닫고 다른 메시지의 댓글 아이콘/모두 보기를 연달아 눌러 스레드를 바로 넘긴
      // 경우도 마찬가지로 그 메시지의 최신 댓글이 바로 보이도록 맨 아래로 스크롤한다.
      _lastSeenCommentId = widget.message.comments.isNotEmpty
          ? widget.message.comments.last.id
          : null;
      if (widget.message.isPost) {
        _scrollToTop();
      } else {
        _scrollToBottom();
      }
      // CommentInputBar를 새로 만들어서 autofocus가 다시 걸리게 한다(예전 key: ValueKey와 동일한 효과).
      _commentInputBarKey = GlobalKey<CommentInputBarState>();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_maybeScrollToNewComment);
    widget.session.openStickerPickerOwner.removeListener(
      _onStickerPickerOwnerChanged,
    );
    if (widget.session.openStickerPickerOwner.value == this) {
      widget.session.openStickerPickerOwner.value = null;
    }
    if (!widget.asPanel &&
        widget.session.mobileThreadOpenRoomId == widget.room.id) {
      widget.session.setMobileCommentThreadOpen(null);
    }
    _scrollController.dispose();
    super.dispose();
  }

  void _maybeScrollToNewComment() {
    final comments = widget.message.comments;
    if (comments.isEmpty) return;
    final last = comments.last;
    if (last.id == _lastSeenCommentId) return;
    _lastSeenCommentId = last.id;
    if (last.senderId == widget.session.userId || _isAtBottom) {
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    // 채팅방(ScrollablePositionedList, index 기반)과 달리 여기는 평범한 ListView라 목표
    // 위치를 position.maxScrollExtent로 직접 읽는데, 이미지/파일 첨부는 실제 크기가 네트워크
    // 요청(다운로드)이 끝나야 확정돼서 언제 레이아웃이 완전히 자리잡을지 미리 알 수 없다 —
    // 프레임을 몇 개 더 기다리는 정도로는(텍스트 댓글엔 충분해도) 안 맞을 수 있다. 정확한
    // 시점을 알아내려 하지 않고, 짧은 시간 동안 "맨 아래로"를 몇 번 다시 걸어서 늦게 자리잡는
    // 경우까지 잡아낸다 — 이미 맨 아래면 그냥 제자리에서 끝나는 애니메이션이라 부작용은 없다.
    void attempt() {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) => attempt());
    });
    for (final delay in const [
      Duration(milliseconds: 150),
      Duration(milliseconds: 400),
      Duration(milliseconds: 900),
      Duration(milliseconds: 1500),
    ]) {
      Future.delayed(delay, attempt);
    }
  }

  /// 패널을 닫지 않고 다른 게시글로 넘어갔을 때 — 새 게시글의 제목부터 보이게.
  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) _scrollController.jumpTo(0);
    });
  }

  /// 게시글을 이 화면에서 지웠으면 상세도 닫는다(패널이면 패널을, 전체 화면이면 그 화면을).
  void _closeAfterPostDeleted() {
    if (!mounted) return;
    if (widget.asPanel) {
      widget.onClose?.call();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  String get _title => widget.message.isPost ? '게시글' : '댓글';

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
        final column = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              // 이모티콘 패널/미리보기를 이 Stack 안에 오버레이로 띄운다 — chat_panel.dart와
              // 같은 이유(입력창을 밀어내지 않고, Expanded의 진짜 레이아웃 범위 안이라 클릭도
              // 정상적으로 먹는다).
              //
              // Overlay.wrap은 댓글 줄의 호버 툴바(FloatingHoverToolbar)가 이 영역 안에서만
              // 그려지게 한다 — 앱 전체 Overlay를 쓰면 아래 입력창 위까지 삐져나온다.
              child: Overlay.wrap(
                child: Stack(
                  children: [
                    MutedScrollbar(
                      controller: _scrollController,
                      child: ListView(
                        controller: _scrollController,
                        // 아래쪽은 마지막 댓글에 호버했을 때 그 아래로 뜨는 툴바
                        // (FloatingHoverToolbar)가 입력창을 덮지 않도록 비워둔다.
                        padding: const EdgeInsets.fromLTRB(
                          12,
                          12,
                          12,
                          12 + kHoverToolbarHeight + 4,
                        ),
                        children: [
                          if (widget.message.isPost)
                            PostDetailHead(
                              session: widget.session,
                              room: widget.room,
                              post: widget.message,
                              onDeleted: _closeAfterPostDeleted,
                            )
                          else
                            MessageBubble(
                              session: widget.session,
                              message: widget.message,
                              resolveUrl: widget.session.resolveUrl,
                              isMine:
                                  widget.message.senderId ==
                                  widget.session.userId,
                              sender: _memberOf(widget.message.senderId),
                              onEdit: widget.controller.editMessage,
                              onEditMedia: widget.controller.editMediaMessage,
                              onDelete: widget.controller.deleteMessage,
                            ),
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Divider(height: 1),
                          ),
                          Text(
                            // 게시글은 보드 카드의 "댓글 N"과 같게 지운 댓글은 세지 않는다.
                            '댓글 ${widget.message.isPost ? comments.where((c) => !c.deleted).length : comments.length}',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          // 채팅과 동일하게, 같은 사람이 연달아 단 댓글은 첫 댓글에만 프로필 사진을 보여준다.
                          for (var i = 0; i < comments.length; i++)
                            CommentEntryLine(
                              session: widget.session,
                              comment: comments[i],
                              sender: _memberOf(comments[i].senderId),
                              isMine:
                                  comments[i].senderId == widget.session.userId,
                              resolveUrl: widget.session.resolveUrl,
                              onEdit: widget.controller.editComment,
                              onDelete: widget.controller.deleteComment,
                              fullWidth: true,
                              expiresAt: widget.message.expiresAt,
                              showAvatar:
                                  i == 0 ||
                                  comments[i - 1].senderId !=
                                      comments[i].senderId,
                              showTime: showCommentTimeAt(comments, i),
                            ),
                        ],
                      ),
                    ),
                    if (_stickerPickerOpen)
                      Positioned(
                        left: 8,
                        bottom: 8,
                        // chat_panel.dart와 동일 — 패널 바깥을 클릭하면 닫히게 하되, 토글
                        // 버튼(CommentInputBar)은 같은 groupId로 묶어서 버튼을 눌러 닫을 때
                        // onTapOutside가 먼저 닫고 onPressed가 다시 여는 깜빡임을 막는다.
                        child: TapRegion(
                          groupId: this,
                          onTapOutside: (_) => _closeStickerPicker(),
                          // chat_panel.dart와 같은 이유로 패널을 입력칸 바깥으로 치지 않는다.
                          child: TextFieldTapRegion(
                            child: StickerPicker(
                              onSelected: _selectSticker,
                              settings: widget.session.settings,
                            ),
                          ),
                        ),
                      )
                    else if (_pendingSticker != null)
                      // 입력창의 이모티콘 버튼 바로 위쯤에 오도록 왼쪽으로 붙인다.
                      Positioned(
                        left: 10,
                        bottom: 8,
                        child: StickerPreviewCard(
                          sticker: _pendingSticker!,
                          onRemove: _removeSticker,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            CommentInputBar(
              // 데스크톱에서는 패널을 안 닫고 다른 메시지의 댓글 아이콘을 연달아 눌러도 이
              // 위젯 자체는 그대로 재사용될 수 있어서, key를 메시지별로 다르게 줘서 매번 새로
              // 만들어지게 한다 — 그래야 autofocus가 그때마다 다시 걸린다(didUpdateWidget 참고).
              key: _commentInputBarKey,
              controller: widget.controller,
              messageId: widget.message.id,
              pendingSticker: _pendingSticker,
              stickerPickerOpen: _stickerPickerOpen,
              stickerPickerGroupId: this,
              onToggleStickerPicker: _toggleStickerPicker,
              onStickerConsumed: _removeSticker,
            ),
          ],
        );

        if (!AppPlatform.isWindows && !kIsWeb) return column;

        // chat_panel.dart와 동일 — 댓글 목록 + 입력창 전체를 드롭 영역으로 잡고, 호버 중엔
        // 패널 전체를 덮는 안내 오버레이를 보여준다. 게시글 편집기나 다른 창이 위에 떠 있으면 꺼
        // 둔다(그 창에 놓은 파일이 가려진 댓글 입력칸에도 들어가지 않게).
        return ValueListenableBuilder<int>(
          valueListenable: postEditorsOpen,
          builder: (context, editors, _) => DropTarget(
            enable: editors == 0 && (ModalRoute.isCurrentOf(context) ?? true),
            onDragEntered: (_) => setState(() => _dragHovering = true),
            onDragExited: (_) => setState(() => _dragHovering = false),
            onDragDone: (details) {
              setState(() => _dragHovering = false);
              _commentInputBarKey.currentState?.addDroppedFiles(
                droppedFiles(details),
              );
            },
            child: Stack(
              children: [
                column,
                if (_dragHovering)
                  const Positioned.fill(
                    child: IgnorePointer(child: DropZoneOverlay()),
                  ),
              ],
            ),
          ),
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
                      _title,
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
      appBar: AppBar(title: Text(_title)),
      body: _body(context),
    );
  }
}
