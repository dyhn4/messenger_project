import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../models/app_user.dart';
import '../models/comment.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../services/session.dart';
import 'chat_input_bar.dart';
import 'date_divider.dart';
import 'message_bubble.dart';
import 'message_comments_card.dart';
import 'read_up_to_here_divider.dart';
import 'system_message_row.dart';

/// 방 하나의 메시지 목록 + 입력창. ChatScreen(모바일 전체화면)과
/// DesktopHomeScreen(우측 패널)이 이 위젯을 그대로 공유한다.
///
/// 이 방이 화면에 떠있는 동안은 Session에 "지금 보고 있는 방"으로 등록해서,
/// 그 방으로 온 메시지에는 알림이 뜨지 않도록 한다. 호출부에서 반드시
/// `key: ValueKey(room.id)`를 줘야 방이 바뀔 때 State가 새로 생성되어 이 등록이 정확히 갱신된다.
class ChatPanel extends StatefulWidget {
  final Session session;
  final Room room;

  /// 검색 결과에서 열었을 때, 그 메시지로 스크롤하고 잠깐 하이라이트한다.
  final String? highlightMessageId;

  /// 말풍선의 댓글 아이콘이나 댓글 미리보기 카드를 눌렀을 때(스레드 패널 열기).
  final void Function(Message message)? onOpenThread;

  const ChatPanel({
    super.key,
    required this.session,
    required this.room,
    this.highlightMessageId,
    this.onOpenThread,
  });

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final _listKey = GlobalKey();
  final _dividerKeys = <String, GlobalKey>{};
  final _itemScrollController = ItemScrollController();
  DateTime? _floatingDate;
  Timer? _hideTimer;
  String? _highlightedMessageId;
  Timer? _highlightTimer;

  /// 스크롤이 맨 아래(=index 0, reverse 리스트라 시간상 가장 나중 항목)가 아닌 채로 내가
  /// 메시지/댓글을 새로 쓰면 그 항목이 보이도록 맨 아래로 스크롤한다. 다른 사람이 쓴 건
  /// (읽던 위치를 뺏기지 않도록) 건드리지 않는다 — _maybeScrollToNewOwnEntry 참고.
  String? _lastSeenEntryId;

  @override
  void initState() {
    super.initState();
    widget.session.setActiveRoom(widget.room.id);
    // 캐시된 컨트롤러를 다시 열었을 때는 _load()가 재실행되지 않으므로, 방을
    // 다시 열 때마다 명시적으로 한 번 더 읽음 처리한다.
    final controller = widget.session.controllerFor(widget.room);
    controller.markReadNow();
    widget.session.clearUnreadCount(widget.room.id);
    _scrollToHighlight();
    _lastSeenEntryId = controller.messages.isNotEmpty
        ? controller.messages.last.id
        : null;
    controller.addListener(_maybeScrollToNewOwnEntry);
  }

  /// controller.messages의 마지막 항목(시간상 가장 나중 = reverse 리스트의 맨 아래)이 바뀔
  /// 때마다 불린다 — 그게 내가 쓴 메시지거나(m.senderId) 내가 단 댓글(합성 항목의
  /// asComment.senderId)이면 맨 아래로 스크롤한다.
  void _maybeScrollToNewOwnEntry() {
    final msgs = widget.session.controllerFor(widget.room).messages;
    if (msgs.isEmpty) return;
    final last = msgs.last;
    if (last.id == _lastSeenEntryId) return;
    _lastSeenEntryId = last.id;

    final senderId = last.type == MessageType.comment
        ? last.asComment!.senderId
        : last.senderId;
    if (senderId == widget.session.userId) _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScrollController.isAttached) return;
      _itemScrollController.scrollTo(
        index: 0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void didUpdateWidget(covariant ChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 같은 방을 계속 보고 있는 채로(=State가 안 바뀜) 검색 결과를 새로 클릭한 경우.
    if (widget.highlightMessageId != null &&
        widget.highlightMessageId != oldWidget.highlightMessageId) {
      _scrollToHighlight();
    }
  }

  /// widget.highlightMessageId가 가리키는 메시지를 화면 가운데쯤으로 스크롤하고,
  /// 3초간 노란색으로 표시했다가 원래 색으로 되돌린다.
  Future<void> _scrollToHighlight() async {
    final targetId = widget.highlightMessageId;
    if (targetId == null) return;

    final controller = widget.session.controllerFor(widget.room);
    await controller.ensureMessageLoaded(targetId);
    if (!mounted) return;

    final msgs = controller.messages;
    final idx = msgs.indexWhere((m) => m.id == targetId);
    if (idx == -1) return; // 보존기간 파기 등으로 이미 지워졌으면 조용히 무시.
    final itemIndex = msgs.length - 1 - idx; // itemBuilder의 reverse 인덱싱과 맞춤.

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScrollController.isAttached) return;
      _itemScrollController.scrollTo(
        index: itemIndex,
        alignment: 0.4,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    });

    setState(() => _highlightedMessageId = targetId);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
  }

  @override
  void dispose() {
    // 방 A → 방 B로 바로 전환될 때 위젯 재조정 순서에 따라 dispose(A)가
    // initState(B)보다 나중에 불릴 수 있어서, 내가 여전히 활성 방일 때만 지운다.
    if (widget.session.activeRoomId == widget.room.id) {
      widget.session.setActiveRoom(null);
    }
    widget.session
        .controllerFor(widget.room)
        .removeListener(_maybeScrollToNewOwnEntry);
    _hideTimer?.cancel();
    _highlightTimer?.cancel();
    super.dispose();
  }

  AppUser? _senderOf(String? senderId) {
    for (final m in widget.room.members) {
      if (m.id == senderId) return m;
    }
    return null;
  }

  Message? _findMessage(List<Message> msgs, String id) {
    for (final m in msgs) {
      if (m.id == id) return m;
    }
    return null;
  }

  String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  bool _sameMinute(DateTime a, DateTime b) =>
      a.year == b.year &&
      a.month == b.month &&
      a.day == b.day &&
      a.hour == b.hour &&
      a.minute == b.minute;

  void _onScrollUpdate() {
    final listBox = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (listBox == null) return;
    final top = listBox.localToGlobal(Offset.zero).dy;

    DateTime? found;
    var bestDy = double.negativeInfinity;
    for (final entry in _dividerKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) continue;
      final dy = box.localToGlobal(Offset.zero).dy;
      // 뷰포트 상단을 막 지나간(또는 아직 상단 근처에 있는) 가장 최근 구분선을 찾는다.
      if (dy <= top + 40 && dy > bestDy) {
        bestDy = dy;
        final parts = entry.key.split('-');
        found = DateTime(
          int.parse(parts[0]),
          int.parse(parts[1]),
          int.parse(parts[2]),
        );
      }
    }

    if (found != null) {
      setState(() => _floatingDate = found);
      _hideTimer?.cancel();
      _hideTimer = Timer(const Duration(milliseconds: 1200), () {
        if (mounted) setState(() => _floatingDate = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.session.controllerFor(widget.room);
    return Column(
      children: [
        Expanded(
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              if (controller.loading) {
                return const Center(child: CircularProgressIndicator());
              }
              final msgs = controller.messages;
              if (msgs.isEmpty) {
                return const Center(child: Text('아직 메시지가 없습니다.'));
              }

              final boundary = controller.readBoundary;
              final showReadDivider =
                  boundary > 0 &&
                  msgs.any(
                    (m) => m.createdAt.millisecondsSinceEpoch <= boundary,
                  ) &&
                  msgs.any(
                    (m) => m.createdAt.millisecondsSinceEpoch > boundary,
                  );

              return Stack(
                children: [
                  NotificationListener<ScrollUpdateNotification>(
                    onNotification: (notification) {
                      _onScrollUpdate();
                      return false;
                    },
                    child: ScrollablePositionedList.builder(
                      key: _listKey,
                      itemScrollController: _itemScrollController,
                      reverse: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      itemCount: msgs.length,
                      itemBuilder: (context, i) {
                        final m = msgs[msgs.length - 1 - i];
                        final isOldestLoaded = i == msgs.length - 1;
                        final prev = isOldestLoaded
                            ? null
                            : msgs[msgs.length - 2 - i];
                        final showDate =
                            isOldestLoaded ||
                            m.createdAt.year != prev!.createdAt.year ||
                            m.createdAt.month != prev.createdAt.month ||
                            m.createdAt.day != prev.createdAt.day;

                        // 같은 사람이 같은 분(分)에 연달아 보낸 메시지는, 그중 가장 나중(=시간상
                        // 마지막) 메시지에만 시간을 보여준다.
                        final next = i == 0 ? null : msgs[msgs.length - i];
                        final showTime =
                            next == null ||
                            next.senderId != m.senderId ||
                            !_sameMinute(next.createdAt, m.createdAt);

                        // 같은 사람이 연달아 보낸 메시지는 첫 메시지에만 프로필 사진/이름을 보여준다.
                        // 날짜가 바뀌었거나(showDate) 중간에 시스템 메시지(입장/퇴장 알림)나 댓글
                        // 카드가 끼면 그 다음 메시지부터 새로 보여준다.
                        final isFirstInGroup =
                            isOldestLoaded ||
                            showDate ||
                            prev.senderId != m.senderId ||
                            prev.type == MessageType.system ||
                            prev.type == MessageType.comment;

                        Widget row;
                        if (m.type == MessageType.system) {
                          row = SystemMessageRow(message: m);
                        } else if (m.type == MessageType.comment) {
                          final parent = _findMessage(
                            msgs,
                            m.asComment!.messageId,
                          );
                          // 바로 앞 항목이 "같은 원본 메시지"의 댓글이 아니면(=다른 채팅이 끼었거나,
                          // 다른 원본 메시지에 대한 댓글이거나, 여기가 맨 처음이면) 이 댓글이 새 런의
                          // 시작이라 카드를 새로 그린다. 아니면 이미 앞에서 그려진 카드에 흡수되므로
                          // 여기선 아무것도 안 그린다.
                          final isFirstCommentInRun =
                              prev == null ||
                              prev.type != MessageType.comment ||
                              prev.asComment!.messageId !=
                                  m.asComment!.messageId;
                          if (parent == null || !isFirstCommentInRun) {
                            row = const SizedBox.shrink();
                          } else {
                            // 같은 원본 메시지에 대한 댓글이 사이에 다른 채팅 없이 연달아 이어지는
                            // 만큼(런) 전부 모아서, 이 카드 하나 안에서 이어 붙여 보여준다. 런은
                            // 이 댓글부터 뒤로(시간순 정방향) 훑으며 조건이 깨지는 지점에서 끊는다.
                            final ascIdx = msgs.length - 1 - i;
                            final runComments = <Comment>[];
                            var j = ascIdx;
                            while (j < msgs.length &&
                                msgs[j].type == MessageType.comment &&
                                msgs[j].asComment!.messageId ==
                                    m.asComment!.messageId) {
                              runComments.add(msgs[j].asComment!);
                              j++;
                            }
                            row = Padding(
                              padding: const EdgeInsets.only(left: 8, right: 8),
                              child: MessageCommentsCard(
                                session: widget.session,
                                parentMessage: parent,
                                comments: runComments,
                                room: widget.room,
                                currentUserId: widget.session.userId,
                                resolveUrl: widget.session.resolveUrl,
                                onTap: () => widget.onOpenThread?.call(parent),
                                onEditComment: controller.editComment,
                                onDeleteComment: controller.deleteComment,
                              ),
                            );
                          }
                        } else {
                          row = MessageBubble(
                            session: widget.session,
                            message: m,
                            resolveUrl: widget.session.resolveUrl,
                            unreadCount: widget.room.unreadCountFor(m),
                            isMine: m.senderId == widget.session.userId,
                            sender: _senderOf(m.senderId),
                            showTime: showTime,
                            showSenderInfo: isFirstInGroup,
                            highlighted: m.id == _highlightedMessageId,
                            onOpenThread: widget.onOpenThread,
                            onEdit: controller.editMessage,
                            onDelete: controller.deleteMessage,
                          );
                        }

                        Widget? divider;
                        if (showDate) {
                          final key = _dividerKeys.putIfAbsent(
                            _dateKey(m.createdAt),
                            () => GlobalKey(),
                          );
                          divider = DateDivider(key: key, date: m.createdAt);
                        }

                        final isFirstUnread =
                            showReadDivider &&
                            m.createdAt.millisecondsSinceEpoch > boundary &&
                            (isOldestLoaded ||
                                prev!.createdAt.millisecondsSinceEpoch <=
                                    boundary);

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ?divider,
                            if (isFirstUnread) const ReadUpToHereDivider(),
                            row,
                          ],
                        );
                      },
                    ),
                  ),
                  if (_floatingDate != null)
                    Positioned(
                      top: 8,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: FloatingDatePill(date: _floatingDate!),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        const Divider(height: 1),
        ChatInputBar(controller: controller),
      ],
    );
  }
}
