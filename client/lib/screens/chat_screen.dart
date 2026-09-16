import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/session.dart';
import '../widgets/chat_panel.dart';
import '../widgets/room_avatar.dart';
import '../widgets/call_button.dart';
import '../widgets/room_options_menu.dart';
import 'message_thread_screen.dart';

/// 모바일(좁은 화면)에서 방을 열 때 전체화면으로 띄우는 화면.
/// 넓은 화면(PC)에서는 DesktopHomeScreen이 이 화면을 쓰지 않고
/// ChatPanel을 우측 패널에 직접 임베드한다.
class ChatScreen extends StatefulWidget {
  final Session session;
  final Room room;
  final String? highlightMessageId;
  const ChatScreen({
    super.key,
    required this.session,
    required this.room,
    this.highlightMessageId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    super.dispose();
  }

  /// 비밀 대화는 나 또는 상대방 누구든 나가면 방 자체가 없어진다(session.dart의
  /// secret:left 처리 참고) — 지금 이 방을 보고 있는 도중에 상대가 나가서 방이 사라지면,
  /// 이미 지워진 컨트롤러를 계속 들고 있는 화면에 남아있지 않도록 목록으로 돌아간다.
  void _onSessionChanged() {
    final stillExists = widget.session.rooms.any((r) => r.id == widget.room.id);
    if (!stillExists && mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final room = widget.room;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            RoomAvatar(
              room: room,
              myUserId: session.userId ?? '',
              resolveUrl: session.resolveUrl,
              onlineUserIds: session.onlineUserIds,
              size: 24,
            ),
            const SizedBox(width: 8),
            if (room.isSecret) ...[
              const Icon(Icons.lock, size: 14, color: Colors.green),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text(
                room.displayName(session.userId ?? ''),
                overflow: TextOverflow.ellipsis,
                style: room.isSecret
                    ? const TextStyle(color: Colors.green)
                    : null,
              ),
            ),
          ],
        ),
        actions: [
          CallButton(session: session, room: room),
          RoomOptionsMenu(session: session, room: room),
        ],
      ),
      body: ChatPanel(
        key: ValueKey(room.id),
        session: session,
        room: room,
        highlightMessageId: widget.highlightMessageId,
        onOpenThread: (m) => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => MessageThreadScreen(
              session: session,
              room: room,
              message: m,
              controller: session.controllerFor(room),
            ),
          ),
        ),
      ),
    );
  }
}
