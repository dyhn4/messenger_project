import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../services/session.dart';
import '../widgets/account_menu_button.dart';
import '../widgets/chat_panel.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/pagination.dart';
import '../widgets/room_avatar.dart';
import '../widgets/room_options_menu.dart';
import '../widgets/unread_badge.dart';
import '../widgets/user_avatar.dart';
import 'create_topic_screen.dart';
import 'member_profile_dialog.dart';
import 'my_profile_dialog.dart';
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
  String? _highlightMessageId;

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
    // 멤버 목록에서 로그인한 사용자 자신을 클릭하면, 다른 멤버 볼 때 쓰는 카드(DM 시작 등)
    // 대신 삼선 메뉴의 "내 프로필"과 같은 카드(이름/이메일/비밀번호 수정)를 보여준다.
    if (user.id == widget.session.userId) {
      await showDialog(context: context, builder: (_) => MyProfileDialog(session: widget.session));
      return;
    }
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
                                    onlineUserIds: widget.session.onlineUserIds,
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
                                highlightMessageId: _highlightMessageId,
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
                      onOpenRoom: (room, messageId) => setState(() {
                        _selectedRoom = room;
                        _highlightMessageId = messageId;
                      }),
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
  final _listScrollController = ScrollController();
  List<AppUser>? _users;
  String? _error;
  String _filter = '';
  int _page = 0; // 0-based.

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
    _listScrollController.dispose();
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

  @override
  Widget build(BuildContext context) {
    final list = (_users ?? const <AppUser>[])
        .where((u) => _filter.isEmpty || u.name.toLowerCase().contains(_filter.toLowerCase()))
        .toList();
    final totalPages = list.isEmpty ? 1 : (list.length / paginationPageSize).ceil();
    final page = _page.clamp(0, totalPages - 1);
    final pageItems = list.skip(page * paginationPageSize).take(paginationPageSize).toList();

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
              onChanged: (v) => setState(() {
                _filter = v;
                _page = 0;
              }),
            ),
          ),
          Expanded(
            child: _error != null
                ? Center(child: Text(_error!))
                : _users == null
                    ? const Center(child: CircularProgressIndicator())
                    : list.isEmpty
                        ? const Center(child: Text('검색 결과가 없습니다.'))
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Divider(height: 1),
                              Expanded(
                                child: MutedScrollbar(
                                  controller: _listScrollController,
                                  child: ListView.separated(
                                    controller: _listScrollController,
                                    itemCount: pageItems.length,
                                    // 오른쪽 끝에 겹치는 스크롤바 아래로 선이 파고들지 않도록 그만큼 짧게 그린다.
                                    separatorBuilder: (_, _) => const Padding(
                                      padding: EdgeInsets.only(right: 12),
                                      child: Divider(height: 1),
                                    ),
                                    itemBuilder: (context, i) => _MemberRow(
                                      user: pageItems[i],
                                      resolveUrl: widget.session.resolveUrl,
                                      online: widget.session.onlineUserIds.contains(pageItems[i].id),
                                      onTap: () => widget.onSelectMember(pageItems[i]),
                                    ),
                                  ),
                                ),
                              ),
                              const Divider(height: 1),
                              Pagination(
                                currentPage: page,
                                totalPages: totalPages,
                                onPageSelected: (p) => setState(() => _page = p),
                              ),
                            ],
                          ),
          ),
        ],
      ),
    );
  }
}

/// 멤버 목록 한 줄: 아바타 + 이름. 카드 테두리 없이 ListView.separated의 Divider로만
/// 서로 구분한다(검색 결과 화면과 같은 스타일).
class _MemberRow extends StatelessWidget {
  final AppUser user;
  final String Function(String relative) resolveUrl;
  final bool online;
  final VoidCallback onTap;
  const _MemberRow({required this.user, required this.resolveUrl, required this.online, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            UserAvatar(user: user, resolveUrl: resolveUrl, radius: 20, online: online),
            const SizedBox(width: 12),
            Expanded(child: Text(user.name, style: const TextStyle(fontWeight: FontWeight.bold))),
          ],
        ),
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

              // 세 섹션 사이 구분선을 사용자가 드래그해서 각자 몫을 조절할 수 있게 한다.
              // 기본은 1/3씩이고, 자기 영역 안에서만 스크롤되며 목록이 영역보다 길면
              // 스크롤바를 항상 보여준다.
              return _ResizableRoomSections(
                topicsHeader: _SectionHeader(
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
                topicsChildren: [
                  for (final room in topics)
                    _RoomTile(
                      leading: RoomAvatar(
                        room: room,
                        myUserId: session.userId ?? '',
                        resolveUrl: session.resolveUrl,
                        onlineUserIds: session.onlineUserIds,
                        size: 28,
                      ),
                      label: room.displayName(session.userId ?? ''),
                      selected: room.id == selectedRoomId,
                      unreadCount: room.unreadCount,
                      onTap: () => onSelectRoom(room),
                    ),
                ],
                groupsHeader: _SectionHeader(
                  title: '그룹채팅 ${groups.length}',
                  badgeCount: groupsUnread,
                  action: IconButton(
                    icon: const Icon(Icons.add, size: 20),
                    tooltip: '새 그룹채팅',
                    onPressed: onNewGroupChat,
                  ),
                ),
                groupsChildren: [
                  for (final room in groups)
                    _RoomTile(
                      leading: RoomAvatar(
                        room: room,
                        myUserId: session.userId ?? '',
                        resolveUrl: session.resolveUrl,
                        onlineUserIds: session.onlineUserIds,
                        size: 28,
                      ),
                      label: room.displayName(session.userId ?? ''),
                      selected: room.id == selectedRoomId,
                      unreadCount: room.unreadCount,
                      onTap: () => onSelectRoom(room),
                    ),
                ],
                dmsHeader: _SectionHeader(
                  title: '채팅 ${dms.length}',
                  badgeCount: dmsUnread,
                  action: IconButton(
                    icon: const Icon(Icons.add, size: 20),
                    tooltip: '새 대화',
                    onPressed: onNewGroupChat,
                  ),
                ),
                dmsChildren: [
                  for (final room in dms)
                    _RoomTile(
                      leading: RoomAvatar(
                        room: room,
                        myUserId: session.userId ?? '',
                        resolveUrl: session.resolveUrl,
                        onlineUserIds: session.onlineUserIds,
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

const _kDividerHitHeight = 8.0;
const _kMinSectionHeight = 60.0;

/// 토픽/그룹채팅/채팅 세 구역을 세로로 나누되, 구역 사이 구분선을 드래그해서 각자 몫(비율)을
/// 조절할 수 있게 한다. 비율은 세션 동안만 유지된다(창을 닫으면 초기화).
class _ResizableRoomSections extends StatefulWidget {
  final Widget topicsHeader;
  final List<Widget> topicsChildren;
  final Widget groupsHeader;
  final List<Widget> groupsChildren;
  final Widget dmsHeader;
  final List<Widget> dmsChildren;
  const _ResizableRoomSections({
    required this.topicsHeader,
    required this.topicsChildren,
    required this.groupsHeader,
    required this.groupsChildren,
    required this.dmsHeader,
    required this.dmsChildren,
  });

  @override
  State<_ResizableRoomSections> createState() => _ResizableRoomSectionsState();
}

class _ResizableRoomSectionsState extends State<_ResizableRoomSections> {
  List<double> _ratios = const [1 / 3, 1 / 3, 1 / 3];

  void _onDrag(double availableHeight, int topIndex, double deltaY) {
    if (availableHeight <= 0) return;
    final deltaRatio = deltaY / availableHeight;
    final minRatio = _kMinSectionHeight / availableHeight;
    final next = List<double>.from(_ratios);
    next[topIndex] += deltaRatio;
    next[topIndex + 1] -= deltaRatio;
    if (next[topIndex] < minRatio || next[topIndex + 1] < minRatio) return;
    setState(() => _ratios = next);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = constraints.maxHeight - _kDividerHitHeight * 2;
        final heights = _ratios.map((r) => r * availableHeight).toList();
        return Column(
          children: [
            SizedBox(
              height: heights[0],
              child: _RoomSection(header: widget.topicsHeader, children: widget.topicsChildren),
            ),
            _ResizeDivider(onDrag: (dy) => _onDrag(availableHeight, 0, dy)),
            SizedBox(
              height: heights[1],
              child: _RoomSection(header: widget.groupsHeader, children: widget.groupsChildren),
            ),
            _ResizeDivider(onDrag: (dy) => _onDrag(availableHeight, 1, dy)),
            SizedBox(
              height: heights[2],
              child: _RoomSection(header: widget.dmsHeader, children: widget.dmsChildren),
            ),
          ],
        );
      },
    );
  }
}

/// 구역 사이의 드래그 가능한 구분선. 손잡이 힌트로 살짝 두껍게 잡고, 위아래로 드래그하면
/// 위/아래 구역의 높이 비율이 바뀐다.
class _ResizeDivider extends StatelessWidget {
  final ValueChanged<double> onDrag;
  const _ResizeDivider({required this.onDrag});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragUpdate: (details) => onDrag(details.delta.dy),
        child: SizedBox(
          height: _kDividerHitHeight,
          child: Center(child: Container(height: 1, color: Theme.of(context).dividerColor)),
        ),
      ),
    );
  }
}

/// 사이드바 한 섹션: 고정 높이 헤더 + 그 아래는 이 섹션 영역 안에서만 스크롤되는 목록.
/// 목록이 영역보다 길면 스크롤바를 항상 보여준다.
class _RoomSection extends StatelessWidget {
  final Widget header;
  final List<Widget> children;
  const _RoomSection({required this.header, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Expanded(
          child: Scrollbar(
            thumbVisibility: true,
            child: ListView(padding: EdgeInsets.zero, children: children),
          ),
        ),
      ],
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
