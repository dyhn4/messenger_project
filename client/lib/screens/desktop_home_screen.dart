import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../services/session.dart';
import '../widgets/account_menu_button.dart';
import '../widgets/chat_panel.dart';
import '../widgets/room_avatar.dart';
import '../widgets/room_options_menu.dart';
import '../widgets/unread_badge.dart';
import '../widgets/user_avatar.dart';
import 'create_topic_screen.dart';
import 'member_profile_dialog.dart';
import 'new_chat_screen.dart';
import 'search_screen.dart';
import 'topic_browse_screen.dart';

/// 잔디(JANDI)식 넓은 화면 레이아웃: 좌측 사이드바(토픽/그룹채팅/유저목록) + 우측 채팅 패널.
/// HomeScreen이 창 너비를 보고 이 화면을 쓸지 RoomListScreen(모바일)을 쓸지 고른다.
class DesktopHomeScreen extends StatefulWidget {
  final Session session;
  const DesktopHomeScreen({super.key, required this.session});

  @override
  State<DesktopHomeScreen> createState() => _DesktopHomeScreenState();
}

class _DesktopHomeScreenState extends State<DesktopHomeScreen> {
  Room? _selectedRoom;
  bool _searchOpen = false;
  bool _membersOpen = false;

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

  void _onSessionChanged() {
    final pending = widget.session.consumePendingOpenRoom();
    if (pending != null) {
      setState(() => _selectedRoom = pending);
      return;
    }
    // 선택된 방이 목록에서 사라졌으면(예: 채팅방 나가기) 우측 패널을 비운다.
    final selected = _selectedRoom;
    if (selected != null && !widget.session.rooms.any((r) => r.id == selected.id)) {
      setState(() => _selectedRoom = null);
    }
  }

  Future<void> _createTopic() async {
    final result = await showDialog<Room>(
      context: context,
      builder: (_) => CreateTopicScreen(session: widget.session, asDialog: true),
    );
    if (result != null) setState(() => _selectedRoom = result);
  }

  Future<void> _browseTopics() async {
    await showDialog(
      context: context,
      builder: (_) => TopicBrowseScreen(session: widget.session, asDialog: true),
    );
  }

  Future<void> _newGroupChat() async {
    final result = await showDialog<Room>(
      context: context,
      builder: (_) => NewChatScreen(session: widget.session, asDialog: true),
    );
    if (result != null) setState(() => _selectedRoom = result);
  }

  Future<void> _openMemberProfile(AppUser user) async {
    final room = await showDialog<Room>(
      context: context,
      builder: (_) => MemberProfileDialog(session: widget.session, user: user),
    );
    if (room != null) {
      setState(() {
        _selectedRoom = room;
        _membersOpen = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 창이 넓을 때(1200px 초과)는 검색/멤버 패널도 넓혀서 필터 라벨이 줄임표 없이
    // 다 보이게 하고, 좁을 때는 400으로 유지한다.
    final sidePanelWidth = MediaQuery.of(context).size.width > 1200 ? 480.0 : 400.0;
    return Scaffold(
      body: Column(
        children: [
          _TopBar(
            session: widget.session,
            onShowMembers: () => setState(() {
              _membersOpen = !_membersOpen;
              if (_membersOpen) _searchOpen = false;
            }),
            onToggleSearch: () => setState(() {
              _searchOpen = !_searchOpen;
              if (_searchOpen) _membersOpen = false;
            }),
          ),
          const Divider(height: 1),
          Expanded(
            child: Row(
              children: [
                SizedBox(width: 280, child: _Sidebar(
                  session: widget.session,
                  selectedRoomId: _selectedRoom?.id,
                  onSelectRoom: (room) => setState(() => _selectedRoom = room),
                  onCreateTopic: _createTopic,
                  onBrowseTopics: _browseTopics,
                  onNewGroupChat: _newGroupChat,
                )),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _selectedRoom == null
                      ? const Center(child: Text('왼쪽에서 대화방을 선택하세요.'))
                      : Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
                              ),
                              child: Row(
                                children: [
                                  RoomAvatar(
                                    room: _selectedRoom!,
                                    myUserId: widget.session.userId ?? '',
                                    resolveUrl: widget.session.resolveUrl,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      _selectedRoom!.displayName(widget.session.userId ?? ''),
                                      style: Theme.of(context).textTheme.titleMedium,
                                    ),
                                  ),
                                  RoomOptionsMenu(session: widget.session, room: _selectedRoom!),
                                ],
                              ),
                            ),
                            Expanded(
                              child: ChatPanel(
                                key: ValueKey(_selectedRoom!.id),
                                session: widget.session,
                                room: _selectedRoom!,
                              ),
                            ),
                          ],
                        ),
                ),
                if (_searchOpen) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: sidePanelWidth,
                    child: SearchScreen(
                      session: widget.session,
                      asPanel: true,
                      onClose: () => setState(() => _searchOpen = false),
                      onOpenRoom: (room) => setState(() => _selectedRoom = room),
                    ),
                  ),
                ],
                if (_membersOpen) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: sidePanelWidth,
                    child: _MembersPanel(
                      session: widget.session,
                      onClose: () => setState(() => _membersOpen = false),
                      onSelectMember: _openMemberProfile,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 창 전체 폭을 가로지르는 최상단 바: 앱 이름(좌) + 멤버/검색/삼선(햄버거) 메뉴(우측 끝).
class _TopBar extends StatelessWidget {
  final Session session;
  final VoidCallback onShowMembers;
  final VoidCallback onToggleSearch;
  const _TopBar({required this.session, required this.onShowMembers, required this.onToggleSearch});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          const Text('메신저', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const Spacer(),
          IconButton(icon: const Icon(Icons.people_outline), tooltip: '멤버', onPressed: onShowMembers),
          IconButton(icon: const Icon(Icons.search), tooltip: '검색', onPressed: onToggleSearch),
          AccountMenuButton(session: session),
        ],
      ),
    );
  }
}

/// "멤버" 버튼으로 여는 우측 패널. 검색 패널과 같은 틀(헤더+검색창+목록)을 쓰고,
/// 각 멤버를 카드로 보여준다. 카드를 누르면 프로필 플로팅 다이얼로그가 뜬다.
class _MembersPanel extends StatefulWidget {
  final Session session;
  final VoidCallback onClose;
  final ValueChanged<AppUser> onSelectMember;
  const _MembersPanel({required this.session, required this.onClose, required this.onSelectMember});

  @override
  State<_MembersPanel> createState() => _MembersPanelState();
}

class _MembersPanelState extends State<_MembersPanel> {
  List<AppUser>? _users;
  String? _error;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final users = await widget.session.api!.fetchUsers();
      users.sort((a, b) => a.username.compareTo(b.username));
      if (!mounted) return;
      setState(() => _users = users);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = (_users ?? const <AppUser>[])
        .where((u) => _filter.isEmpty || u.username.toLowerCase().contains(_filter.toLowerCase()))
        .toList();

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
                    _users == null ? '조직도' : '조직도 총 ${_users!.length}명',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(icon: const Icon(Icons.close), onPressed: widget.onClose),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
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
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        children: [
                          for (final u in list)
                            _MemberCard(
                              user: u,
                              resolveUrl: widget.session.resolveUrl,
                              onTap: () => widget.onSelectMember(u),
                            ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}

class _MemberCard extends StatelessWidget {
  final AppUser user;
  final String Function(String relative) resolveUrl;
  final VoidCallback onTap;
  const _MemberCard({required this.user, required this.resolveUrl, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Theme.of(context).dividerColor),
      ),
      child: ListTile(
        leading: UserAvatar(user: user, resolveUrl: resolveUrl, radius: 20),
        title: Text(user.username, style: const TextStyle(fontWeight: FontWeight.bold)),
        onTap: onTap,
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  final Session session;
  final String? selectedRoomId;
  final ValueChanged<Room> onSelectRoom;
  final VoidCallback onCreateTopic;
  final VoidCallback onBrowseTopics;
  final VoidCallback onNewGroupChat;

  const _Sidebar({
    required this.session,
    required this.selectedRoomId,
    required this.onSelectRoom,
    required this.onCreateTopic,
    required this.onBrowseTopics,
    required this.onNewGroupChat,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
              final topics = session.rooms.where((r) => r.type == RoomType.topic).toList();
              final groups = session.rooms.where((r) => r.type == RoomType.group).toList();
              final dms = session.rooms.where((r) => r.type == RoomType.dm).toList();
              final topicsUnread = topics.fold<int>(0, (sum, r) => sum + r.unreadCount);
              final groupsUnread = groups.fold<int>(0, (sum, r) => sum + r.unreadCount);
              final dmsUnread = dms.fold<int>(0, (sum, r) => sum + r.unreadCount);

              return ListView(
                children: [
                  _SectionHeader(
                    title: '토픽 ${topics.length}',
                    badgeCount: topicsUnread,
                    action: PopupMenuButton<void>(
                      icon: const Icon(Icons.add, size: 20),
                      tooltip: '토픽 추가',
                      itemBuilder: (context) => [
                        PopupMenuItem(onTap: onCreateTopic, child: const Text('토픽 만들기')),
                        PopupMenuItem(onTap: onBrowseTopics, child: const Text('토픽 찾기')),
                      ],
                    ),
                  ),
                  for (final room in topics)
                    _RoomTile(
                      leading: RoomAvatar(
                        room: room,
                        myUserId: session.userId ?? '',
                        resolveUrl: session.resolveUrl,
                        size: 28,
                      ),
                      label: room.displayName(session.userId ?? ''),
                      selected: room.id == selectedRoomId,
                      unreadCount: room.unreadCount,
                      onTap: () => onSelectRoom(room),
                    ),
                  const Divider(height: 24),
                  _SectionHeader(
                    title: '그룹채팅 ${groups.length}',
                    badgeCount: groupsUnread,
                    action: IconButton(
                      icon: const Icon(Icons.add, size: 20),
                      tooltip: '새 그룹채팅',
                      onPressed: onNewGroupChat,
                    ),
                  ),
                  for (final room in groups)
                    _RoomTile(
                      leading: RoomAvatar(
                        room: room,
                        myUserId: session.userId ?? '',
                        resolveUrl: session.resolveUrl,
                        size: 28,
                      ),
                      label: room.displayName(session.userId ?? ''),
                      selected: room.id == selectedRoomId,
                      unreadCount: room.unreadCount,
                      onTap: () => onSelectRoom(room),
                    ),
                  const Divider(height: 24),
                  _SectionHeader(
                    title: '채팅 ${dms.length}',
                    badgeCount: dmsUnread,
                    action: IconButton(
                      icon: const Icon(Icons.add, size: 20),
                      tooltip: '새 대화',
                      onPressed: onNewGroupChat,
                    ),
                  ),
                  for (final room in dms)
                    _RoomTile(
                      leading: RoomAvatar(
                        room: room,
                        myUserId: session.userId ?? '',
                        resolveUrl: session.resolveUrl,
                        size: 28,
                      ),
                      label: room.displayName(session.userId ?? ''),
                      selected: room.id == selectedRoomId,
                      unreadCount: room.unreadCount,
                      onTap: () => onSelectRoom(room),
                    ),
                ],
              );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int badgeCount;
  final Widget? action;
  const _SectionHeader({required this.title, this.badgeCount = 0, this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Text(title, style: Theme.of(context).textTheme.labelLarge),
                if (badgeCount > 0) ...[const SizedBox(width: 6), UnreadBadge(count: badgeCount)],
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _RoomTile extends StatelessWidget {
  final Widget leading;
  final String label;
  final bool selected;
  final int unreadCount;
  final VoidCallback onTap;
  const _RoomTile({
    required this.leading,
    required this.label,
    required this.selected,
    this.unreadCount = 0,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
      leading: leading,
      title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: unreadCount > 0 ? UnreadBadge(count: unreadCount) : null,
      onTap: onTap,
    );
  }
}
