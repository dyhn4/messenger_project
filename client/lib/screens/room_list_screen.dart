import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/session.dart';
import '../widgets/account_menu_button.dart';
import '../widgets/favorite_star.dart';
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
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(session: session, room: room),
      ),
    );
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
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TopicBrowseScreen(session: session),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('새 대화 (1:1 / 그룹)'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => NewChatScreen(session: session),
                  ),
                );
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
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SearchScreen(session: session)),
            ),
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
          final topics = _favoriteFirst(
            session.rooms.where((r) => r.type == RoomType.topic).toList(),
          );
          final groups = _favoriteFirst(
            session.rooms.where((r) => r.type == RoomType.group).toList(),
          );
          final dms = _favoriteFirst(
            session.rooms.where((r) => r.type == RoomType.dm).toList(),
          );

          // PC 앱 사이드바와 동일하게, 방이 하나도 없어도 섹션 제목은 "0"과 함께 항상 보여준다.
          return ListView(
            children: [
              ..._section(context, '토픽 ${topics.length}', topics),
              ..._section(context, '그룹채팅 ${groups.length}', groups),
              ..._section(context, '채팅 ${dms.length}', dms),
            ],
          );
        },
      ),
    );
  }

  /// 즐겨찾기한 방을 목록 위쪽에 모으고, 각 묶음 안에서는 최근 활동(채팅/댓글을 보냈거나
  /// 받음, Room.lastActivityAt) 순으로 정렬한다 — 채팅 중이거나 알림이 온 방이 그 방이 속한
  /// 묶음의 맨 위로 올라온다(Session._bumpRoomActivity 참고).
  static List<Room> _favoriteFirst(List<Room> rooms) {
    int byRecent(Room a, Room b) =>
        b.lastActivityAt.compareTo(a.lastActivityAt);
    final favorites = rooms.where((r) => r.favorite).toList()..sort(byRecent);
    final others = rooms.where((r) => !r.favorite).toList()..sort(byRecent);
    return [...favorites, ...others];
  }

  List<Widget> _section(BuildContext context, String title, List<Room> items) {
    final unreadSum = items.fold<int>(0, (sum, r) => sum + r.unreadCount);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Row(
          children: [
            Text(title, style: Theme.of(context).textTheme.labelLarge),
            if (unreadSum > 0) ...[
              const SizedBox(width: 6),
              UnreadBadge(count: unreadSum),
            ],
          ],
        ),
      ),
      for (final room in items)
        ListTile(
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FavoriteStar(
                favorite: room.favorite,
                onTap: () => session.toggleFavorite(room),
              ),
              const SizedBox(width: 8),
              RoomAvatar(
                room: room,
                myUserId: session.userId ?? '',
                resolveUrl: session.resolveUrl,
                onlineUserIds: session.onlineUserIds,
              ),
            ],
          ),
          title: room.isSecret
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock, size: 14, color: Colors.green),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        room.displayName(session.userId ?? ''),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.green),
                      ),
                    ),
                  ],
                )
              : Text(room.displayName(session.userId ?? '')),
          subtitle: room.description != null
              ? Text(
                  room.description!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              : null,
          trailing: room.unreadCount > 0
              ? UnreadBadge(count: room.unreadCount)
              : null,
          onTap: () => _openRoom(context, room),
        ),
    ];
  }
}
