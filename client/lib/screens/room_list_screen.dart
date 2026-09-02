import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/my_avatar.dart';
import '../widgets/room_avatar.dart';
import '../widgets/room_options_menu.dart' show showLeaveRoomDialog;
import '../widgets/unread_badge.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';
import 'member_profile_dialog.dart';
import 'my_profile_dialog.dart';
import 'new_chat_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'topic_browse_screen.dart';

const _appVersion = '1.0.0';

/// 안드로이드/좁은 화면(폰)에서 쓰는 메인 화면: 토픽/그룹채팅/채팅/멤버/더보기 5개 하단 탭.
/// PC(넓은 화면)는 사이드바+분할패널 방식의 DesktopHomeScreen이 따로 담당하므로 이 화면과
/// 완전히 별개다(HomeScreen이 창 너비로 둘 중 하나를 고름).
class RoomListScreen extends StatefulWidget {
  final Session session;
  const RoomListScreen({super.key, required this.session});

  @override
  State<RoomListScreen> createState() => _RoomListScreenState();
}

class _RoomListScreenState extends State<RoomListScreen> {
  int _index = 0;

  static const _titles = ['토픽', '그룹채팅', '채팅', '멤버', '더보기'];

  void _openRoom(Room room) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(session: widget.session, room: room),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_titles[_index])),
      body: IndexedStack(
        index: _index,
        children: [
          _RoomTypeTab(
            session: widget.session,
            type: RoomType.topic,
            emptyText: '토픽방이 없습니다.',
            onOpenRoom: _openRoom,
          ),
          _RoomTypeTab(
            session: widget.session,
            type: RoomType.group,
            emptyText: '그룹채팅이 없습니다.',
            onOpenRoom: _openRoom,
            showActivityTime: true,
          ),
          _RoomTypeTab(
            session: widget.session,
            type: RoomType.dm,
            emptyText: '대화가 없습니다.',
            onOpenRoom: _openRoom,
            showActivityTime: true,
          ),
          _MembersTab(session: widget.session, onOpenRoom: _openRoom),
          _MoreTab(session: widget.session),
        ],
      ),
      floatingActionButton: switch (_index) {
        0 => FloatingActionButton(
          tooltip: '토픽방 찾기 / 만들기',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TopicBrowseScreen(session: widget.session),
            ),
          ),
          child: const Icon(Icons.add),
        ),
        1 || 2 => FloatingActionButton(
          tooltip: '새 대화',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => NewChatScreen(session: widget.session),
            ),
          ),
          child: const Icon(Icons.add),
        ),
        _ => null,
      },
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.tag), label: '토픽'),
          NavigationDestination(
            icon: Icon(Icons.groups_outlined),
            label: '그룹채팅',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            label: '채팅',
          ),
          NavigationDestination(icon: Icon(Icons.people_outline), label: '멤버'),
          NavigationDestination(icon: Icon(Icons.more_horiz), label: '더보기'),
        ],
      ),
    );
  }
}

/// 토픽/그룹채팅/채팅 탭 공통 몸통: 검색창(누르면 SearchScreen으로 이동) + 그 타입의
/// 방 목록. 즐겨찾기한 방을 위로 모으고, 그 안에서는 최근 활동 순으로 정렬한다(PC 사이드바와
/// 동일한 규칙 — Session._bumpRoomActivity 참고).
class _RoomTypeTab extends StatelessWidget {
  final Session session;
  final RoomType type;
  final String emptyText;
  final ValueChanged<Room> onOpenRoom;
  final bool showActivityTime;
  const _RoomTypeTab({
    required this.session,
    required this.type,
    required this.emptyText,
    required this.onOpenRoom,
    this.showActivityTime = false,
  });

  static List<Room> _favoriteFirst(List<Room> rooms) {
    int byRecent(Room a, Room b) =>
        b.lastActivityAt.compareTo(a.lastActivityAt);
    final favorites = rooms.where((r) => r.favorite).toList()..sort(byRecent);
    final others = rooms.where((r) => !r.favorite).toList()..sort(byRecent);
    return [...favorites, ...others];
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _SearchBox(session: session),
        Expanded(
          child: ListenableBuilder(
            listenable: session,
            builder: (context, _) {
              final rooms = _favoriteFirst(
                session.rooms.where((r) => r.type == type).toList(),
              );
              if (rooms.isEmpty) {
                return Center(
                  child: Text(
                    emptyText,
                    style: TextStyle(color: Theme.of(context).hintColor),
                  ),
                );
              }
              return ListView.builder(
                itemCount: rooms.length,
                itemBuilder: (context, i) => _RoomRow(
                  session: session,
                  room: rooms[i],
                  onTap: () => onOpenRoom(rooms[i]),
                  showActivityTime: showActivityTime,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 방 목록 한 줄 — 아바타 + 이름(비밀 대화는 자물쇠+초록색, 즐겨찾기는 이름 옆 노란 별) +
/// 안읽음 뱃지. 즐겨찾기/알림 끄기/나가기는 길게 누르면 뜨는 하단 시트로만 조작한다.
class _RoomRow extends StatelessWidget {
  final Session session;
  final Room room;
  final VoidCallback onTap;
  final bool showActivityTime;
  const _RoomRow({
    required this.session,
    required this.room,
    required this.onTap,
    this.showActivityTime = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: RoomAvatar(
        room: room,
        myUserId: session.userId ?? '',
        resolveUrl: session.resolveUrl,
        onlineUserIds: session.onlineUserIds,
      ),
      title: Row(
        children: [
          if (room.isSecret) ...[
            const Icon(Icons.lock, size: 14, color: Colors.green),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              room.displayName(session.userId ?? ''),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: room.isSecret
                  ? const TextStyle(color: Colors.green)
                  : null,
            ),
          ),
          if (room.favorite) ...[
            const SizedBox(width: 4),
            const Icon(Icons.star, size: 16, color: Colors.amber),
          ],
          if (room.muted) ...[
            const SizedBox(width: 4),
            Icon(
              Icons.notifications_off,
              size: 14,
              color: Theme.of(context).hintColor,
            ),
          ],
        ],
      ),
      subtitle: _buildSubtitle(context),
      trailing: _buildTrailing(context),
      onTap: onTap,
      onLongPress: () => _showRoomActionSheet(context),
    );
  }

  /// 토픽은 방 설명을, 그룹채팅/채팅은 마지막 메시지·댓글·이모티콘 미리보기를 이름 아래에
  /// 보여준다(room.lastMessagePreview — Session이 로그인 시점/실시간 둘 다 채워준다).
  Widget? _buildSubtitle(BuildContext context) {
    final text = room.type == RoomType.topic
        ? room.description
        : room.lastMessagePreview;
    if (text == null || text.isEmpty) return null;
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: Theme.of(context).hintColor),
    );
  }

  /// 오른쪽 위에 마지막 활동 시각(오늘이면 시:분, 아니면 날짜) + 그 아래 안읽음 뱃지.
  /// 그룹채팅/채팅 탭에서만 시각을 보여준다(showActivityTime — 토픽은 표시 안 함).
  Widget? _buildTrailing(BuildContext context) {
    final children = <Widget>[
      if (showActivityTime)
        Text(
          formatRoomActivityTime(room.lastActivityAt),
          style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
        ),
      if (room.unreadCount > 0) ...[
        if (showActivityTime) const SizedBox(height: 4),
        UnreadBadge(count: room.unreadCount),
      ],
    ];
    if (children.isEmpty) return null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: children,
    );
  }

  void _showRoomActionSheet(BuildContext context) {
    final isDm = room.type == RoomType.dm;
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                room.muted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
              ),
              title: Text(room.muted ? '알림 켜기' : '알림 끄기'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                session.toggleMuted(room);
              },
            ),
            ListTile(
              leading: Icon(
                room.favorite ? Icons.star : Icons.star_border,
                color: room.favorite ? Colors.amber : null,
              ),
              title: Text(room.favorite ? '즐겨찾기 해제' : '즐겨찾기'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                session.toggleFavorite(room);
              },
            ),
            ListTile(
              leading: const Icon(Icons.exit_to_app, color: Colors.redAccent),
              title: Text(
                isDm && !room.isSecret ? '숨기기' : '나가기',
                style: const TextStyle(color: Colors.redAccent),
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                showLeaveRoomDialog(context, session, room);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 탭 상단에 항상 붙어있는 검색창. 실제 검색(대화방 이름/메시지 내용)은 기존 SearchScreen이
/// 다 처리하므로, 여기서는 그 화면으로 넘어가는 진입점 역할만 한다(직접 눌러야 하는 버튼이지만
/// TextField처럼 보이게 스타일만 맞춤).
class _SearchBox extends StatelessWidget {
  final Session session;
  const _SearchBox({required this.session});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => SearchScreen(session: session)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  Icons.search,
                  size: 18,
                  color: Theme.of(context).hintColor,
                ),
                const SizedBox(width: 8),
                Text(
                  '대화방, 메시지 검색',
                  style: TextStyle(color: Theme.of(context).hintColor),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 멤버 탭: 전체 사용자 목록 + 이름으로 실시간 필터(PC 사이드바의 "조직도" 패널과 동일한
/// 로직). 카드를 누르면 나 자신이면 내 프로필, 다른 사람이면 프로필 카드(1:1/비밀대화 시작)를
/// 띄운다.
class _MembersTab extends StatefulWidget {
  final Session session;
  final ValueChanged<Room> onOpenRoom;
  const _MembersTab({required this.session, required this.onOpenRoom});

  @override
  State<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends State<_MembersTab> {
  List<AppUser>? _users;
  String? _error;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
    // onlineUserIds가 바뀔 때마다(누가 접속/해제) 초록 점을 다시 그리도록 다시 빌드한다.
    widget.session.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final users = await widget.session.api!.fetchUsers();
      users.sort((a, b) => a.name.compareTo(b.name));
      if (!mounted) return;
      setState(() => _users = users);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _openProfile(AppUser user) async {
    if (user.id == widget.session.userId) {
      await showDialog(
        context: context,
        builder: (_) => MyProfileDialog(session: widget.session),
      );
      return;
    }
    final room = await showDialog<Room>(
      context: context,
      builder: (_) => MemberProfileDialog(session: widget.session, user: user),
    );
    if (room != null) widget.onOpenRoom(room);
  }

  @override
  Widget build(BuildContext context) {
    final list = (_users ?? const <AppUser>[])
        .where(
          (u) =>
              _filter.isEmpty ||
              u.name.toLowerCase().contains(_filter.toLowerCase()),
        )
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            decoration: const InputDecoration(
              hintText: '멤버 검색',
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _filter = v),
          ),
        ),
        Expanded(
          child: _error != null
              ? Center(child: Text(_error!))
              : _users == null
              ? const Center(child: CircularProgressIndicator())
              : list.isEmpty
              ? const Center(child: Text('검색 결과가 없습니다.'))
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) => _MemberRow(
                    user: list[i],
                    resolveUrl: widget.session.resolveUrl,
                    online: widget.session.onlineUserIds.contains(list[i].id),
                    onTap: () => _openProfile(list[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

class _MemberRow extends StatelessWidget {
  final AppUser user;
  final String Function(String relative) resolveUrl;
  final bool online;
  final VoidCallback onTap;
  const _MemberRow({
    required this.user,
    required this.resolveUrl,
    required this.online,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: UserAvatar(
        user: user,
        resolveUrl: resolveUrl,
        radius: 20,
        online: online,
      ),
      title: Text(
        user.name,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      onTap: onTap,
    );
  }
}

/// 더보기 탭: 기존 PC 삼선 메뉴(AccountMenuButton)와 같은 항목(내 프로필/설정/오픈소스
/// 라이선스/로그아웃)을 전체 화면 목록으로 옮겨 놓은 것 — 새 기능은 추가하지 않았다.
class _MoreTab extends StatelessWidget {
  final Session session;
  const _MoreTab({required this.session});

  Future<void> _logout(BuildContext context) async {
    await session.logout();
    if (context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        ListTile(
          leading: MyAvatar(session: session, radius: 24),
          title: Text(
            session.name ?? session.username ?? '',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showDialog(
            context: context,
            builder: (_) => MyProfileDialog(session: session),
          ),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.settings_outlined),
          title: const Text('설정'),
          onTap: () => showDialog(
            context: context,
            builder: (_) => SettingsScreen(session: session),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: const Text('오픈소스 라이선스'),
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'TeamTalk',
            applicationVersion: _appVersion,
          ),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.logout, color: Colors.redAccent),
          title: const Text('로그아웃', style: TextStyle(color: Colors.redAccent)),
          onTap: () => _logout(context),
        ),
      ],
    );
  }
}
