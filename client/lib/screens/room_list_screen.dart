import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/session.dart';
import '../widgets/account_menu_button.dart';
import '../widgets/room_avatar.dart';
import '../widgets/unread_badge.dart';
import 'chat_screen.dart';
import 'new_chat_screen.dart';
import 'search_screen.dart';
import 'topic_browse_screen.dart';

class RoomListScreen extends StatelessWidget {
  final Session session;
  const RoomListScreen({super.key, required this.session});

  void _openRoom(BuildContext context, Room room) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(session: session, room: room)));
  }

  void _showAddSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.tag),
              title: const Text('토픽방 찾기 / 만들기'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => TopicBrowseScreen(session: session)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('새 대화 (1:1 / 그룹)'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => NewChatScreen(session: session)));
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('메신저'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '검색',
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => SearchScreen(session: session))),
          ),
          AccountMenuButton(session: session),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddSheet(context),
        child: const Icon(Icons.add),
      ),
      body: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final topics = session.rooms.where((r) => r.type == RoomType.topic).toList();
          final groups = session.rooms.where((r) => r.type == RoomType.group).toList();
          final dms = session.rooms.where((r) => r.type == RoomType.dm).toList();

          if (topics.isEmpty && groups.isEmpty && dms.isEmpty) {
            return const Center(child: Text('참여 중인 방이 없습니다. 오른쪽 아래 + 버튼으로 시작해보세요.'));
          }

          return ListView(
            children: [
              if (topics.isNotEmpty) ..._section(context, '토픽 ${topics.length}', topics),
              if (groups.isNotEmpty) ..._section(context, '그룹채팅 ${groups.length}', groups),
              if (dms.isNotEmpty) ..._section(context, '채팅 ${dms.length}', dms),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _section(BuildContext context, String title, List<Room> items) {
    final unreadSum = items.fold<int>(0, (sum, r) => sum + r.unreadCount);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Row(
          children: [
            Text(title, style: Theme.of(context).textTheme.labelLarge),
            if (unreadSum > 0) ...[const SizedBox(width: 6), UnreadBadge(count: unreadSum)],
          ],
        ),
      ),
      for (final room in items)
        ListTile(
          leading: RoomAvatar(room: room, myUserId: session.userId ?? '', resolveUrl: session.resolveUrl),
          title: Text(room.displayName(session.userId ?? '')),
          subtitle: room.description != null ? Text(room.description!, maxLines: 1, overflow: TextOverflow.ellipsis) : null,
          trailing: room.unreadCount > 0 ? UnreadBadge(count: room.unreadCount) : null,
          onTap: () => _openRoom(context, room),
        ),
    ];
  }
}
