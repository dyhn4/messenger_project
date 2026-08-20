import 'dart:async';

import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../services/session.dart';
import 'chat_input_bar.dart';
import 'date_divider.dart';
import 'message_bubble.dart';
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

  const ChatPanel({super.key, required this.session, required this.room});

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final _listKey = GlobalKey();
  final _dividerKeys = <String, GlobalKey>{};
  DateTime? _floatingDate;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    widget.session.setActiveRoom(widget.room.id);
    // 캐시된 컨트롤러를 다시 열었을 때는 _load()가 재실행되지 않으므로, 방을
    // 다시 열 때마다 명시적으로 한 번 더 읽음 처리한다.
    widget.session.controllerFor(widget.room).markReadNow();
    widget.session.clearUnreadCount(widget.room.id);
  }

  @override
  void dispose() {
    // 방 A → 방 B로 바로 전환될 때 위젯 재조정 순서에 따라 dispose(A)가
    // initState(B)보다 나중에 불릴 수 있어서, 내가 여전히 활성 방일 때만 지운다.
    if (widget.session.activeRoomId == widget.room.id) {
      widget.session.setActiveRoom(null);
    }
    _hideTimer?.cancel();
    super.dispose();
  }

  AppUser? _senderOf(String senderId) {
    for (final m in widget.room.members) {
      if (m.id == senderId) return m;
    }
    return null;
  }

  String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

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
        found = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
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
              final showReadDivider = boundary > 0 &&
                  msgs.any((m) => m.createdAt.millisecondsSinceEpoch <= boundary) &&
                  msgs.any((m) => m.createdAt.millisecondsSinceEpoch > boundary);

              return Stack(
                children: [
                  NotificationListener<ScrollUpdateNotification>(
                    onNotification: (notification) {
                      _onScrollUpdate();
                      return false;
                    },
                    child: ListView.builder(
                      key: _listKey,
                      reverse: true,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      itemCount: msgs.length,
                      itemBuilder: (context, i) {
                        final m = msgs[msgs.length - 1 - i];
                        final isOldestLoaded = i == msgs.length - 1;
                        final prev = isOldestLoaded ? null : msgs[msgs.length - 2 - i];
                        final showDate = isOldestLoaded ||
                            m.createdAt.year != prev!.createdAt.year ||
                            m.createdAt.month != prev.createdAt.month ||
                            m.createdAt.day != prev.createdAt.day;

                        final row = m.type == MessageType.system
                            ? SystemMessageRow(message: m)
                            : MessageBubble(
                                session: widget.session,
                                message: m,
                                resolveUrl: widget.session.resolveUrl,
                                unreadCount: widget.room.unreadCountFor(m),
                                isMine: m.senderId == widget.session.userId,
                                sender: _senderOf(m.senderId),
                              );

                        Widget? divider;
                        if (showDate) {
                          final key = _dividerKeys.putIfAbsent(_dateKey(m.createdAt), () => GlobalKey());
                          divider = DateDivider(key: key, date: m.createdAt);
                        }

                        final isFirstUnread = showReadDivider &&
                            m.createdAt.millisecondsSinceEpoch > boundary &&
                            (isOldestLoaded || prev!.createdAt.millisecondsSinceEpoch <= boundary);

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
                      child: Center(child: FloatingDatePill(date: _floatingDate!)),
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
