import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/session.dart';
import '../widgets/chat_panel.dart';
import '../widgets/room_avatar.dart';
import '../widgets/room_options_menu.dart';
import 'message_thread_screen.dart';

/// 모바일(좁은 화면)에서 방을 열 때 전체화면으로 띄우는 화면.
/// 넓은 화면(PC)에서는 DesktopHomeScreen이 이 화면을 쓰지 않고
/// ChatPanel을 우측 패널에 직접 임베드한다.
class ChatScreen extends StatelessWidget {
  final Session session;
  final Room room;
  final String? highlightMessageId;
  const ChatScreen({super.key, required this.session, required this.room, this.highlightMessageId});

  @override
  Widget build(BuildContext context) {
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
            Expanded(child: Text(room.displayName(session.userId ?? ''), overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [RoomOptionsMenu(session: session, room: room)],
      ),
      body: ChatPanel(
        key: ValueKey(room.id),
        session: session,
        room: room,
        highlightMessageId: highlightMessageId,
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
