import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/room_avatar.dart';

/// "메시지 공유"/"메시지 전달"에서 대화방을 고르는 전체 화면 — 토픽/그룹채팅/채팅 3개 탭으로
/// 나뉘고, 방을 누르면 그 Room을 pop으로 돌려준다. 비밀 대화는 목록에서 뺀다(message_bubble.dart
/// 참고 — 평문 메시지가 E2EE 방 안팎으로 새면 안 됨).
class RoomPickerScreen extends StatefulWidget {
  final Session session;
  const RoomPickerScreen({super.key, required this.session});

  @override
  State<RoomPickerScreen> createState() => _RoomPickerScreenState();
}

class _RoomPickerScreenState extends State<RoomPickerScreen>
    with SingleTickerProviderStateMixin {
  late final _tabController = TabController(length: 3, vsync: this);
  final _searchController = TextEditingController();
  bool _searching = false;
  String _filter = '';

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _searchController.clear();
        _filter = '';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '대화방 검색',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _filter = v),
              )
            : const Text('대화방 선택하기'),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: _toggleSearch,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '토픽'),
            Tab(text: '그룹채팅'),
            Tab(text: '채팅'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _RoomPickerList(
            session: widget.session,
            type: RoomType.topic,
            filter: _filter,
          ),
          _RoomPickerList(
            session: widget.session,
            type: RoomType.group,
            filter: _filter,
          ),
          _RoomPickerList(
            session: widget.session,
            type: RoomType.dm,
            filter: _filter,
          ),
        ],
      ),
    );
  }
}

class _RoomPickerList extends StatelessWidget {
  final Session session;
  final RoomType type;
  final String filter;
  const _RoomPickerList({
    required this.session,
    required this.type,
    required this.filter,
  });

  @override
  Widget build(BuildContext context) {
    final myUserId = session.userId ?? '';
    final lowerFilter = filter.trim().toLowerCase();
    final rooms =
        session.rooms
            .where((r) => r.type == type && !r.isSecret)
            .where(
              (r) =>
                  lowerFilter.isEmpty ||
                  r.displayName(myUserId).toLowerCase().contains(lowerFilter),
            )
            .toList()
          ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));

    if (rooms.isEmpty) {
      return Center(
        child: Text(
          '대화방이 없습니다.',
          style: TextStyle(color: Theme.of(context).hintColor),
        ),
      );
    }
    return ListView.builder(
      itemCount: rooms.length,
      itemBuilder: (context, i) {
        final room = rooms[i];
        return ListTile(
          leading: type == RoomType.topic
              ? const CircleAvatar(child: Icon(Icons.tag))
              : RoomAvatar(
                  room: room,
                  myUserId: myUserId,
                  resolveUrl: session.resolveUrl,
                  onlineUserIds: session.onlineUserIds,
                ),
          title: Text(
            room.displayName(myUserId),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: type == RoomType.topic
              ? null
              : Text(
                  formatRoomActivityTime(room.lastActivityAt),
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).hintColor,
                  ),
                ),
          onTap: () => Navigator.of(context).pop(room),
        );
      },
    );
  }
}
