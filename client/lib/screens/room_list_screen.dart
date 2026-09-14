import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;

import '../models/app_user.dart';
import '../models/room.dart';
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/app_toast.dart';
import '../widgets/my_avatar.dart';
import '../widgets/room_avatar.dart';
import '../widgets/room_options_menu.dart' show showLeaveRoomDialog;
import '../widgets/muted_scrollbar.dart';
import '../widgets/team_switcher.dart';
import '../widgets/unread_badge.dart';
import '../widgets/user_avatar.dart';
import 'admin_console_screen.dart';
import 'chat_screen.dart';
import 'invite_link_screen.dart';
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

  /// 넓은 화면에서 좁은 화면으로 막 넘어오면서 곧바로 다시 열어줘야 하는 방(있다면).
  /// initState에서 곧장 push하지 않고 여기 담아두는 이유는 아래 build() 참고.
  Room? _pendingReopenRoom;

  /// "한 번 더 누르면 앱이 종료됩니다" 안내를 띄운 시각. 이 화면(하단 탭 목록)이 이
  /// 좁은 화면 Navigator의 첫 라우트라 뒤로가기를 누르면 바로 앱이 꺼져버리는데, 그러면
  /// 실수로 홈 화면을 나가버리기 쉬우므로 두 번 눌러야 종료되게 한다.
  DateTime? _lastBackPressAt;

  void _handleBackPress() {
    final now = DateTime.now();
    final last = _lastBackPressAt;
    if (last != null && now.difference(last) <= const Duration(seconds: 3)) {
      SystemNavigator.pop();
      return;
    }
    _lastBackPressAt = now;
    showAppToast(
      context,
      '한 번 더 누르면 앱이 종료됩니다',
      duration: const Duration(seconds: 3),
    );
  }

  @override
  void initState() {
    super.initState();
    // 넓은 화면(DesktopHomeScreen)에서 어떤 방을 열어둔 채로 창을 좁혀서 이 화면으로
    // 넘어온 경우 — DesktopHomeScreen의 ChatPanel이 아직 dispose 전이라(같은 프레임 안에서
    // 새 위젯의 initState가 먼저 돌고 옛 dispose가 나중에 돎, session.dart의 clearActiveRoom
    // 주석 참고) session.activeRoomId가 아직 그 방을 그대로 가리키고 있다. 그 방을 곧바로
    // 이어서 열어준다.
    //
    // Navigator.push는 build 중엔 할 수 없어 프레임이 끝난 뒤로 미뤄야 하는데, 그동안
    // build()가 평소처럼 토픽/그룹채팅 탭 목록을 그대로 그리면 그 목록이 한 프레임 반짝
    // 보였다가 채팅방으로 바뀌는 게 눈에 띈다. 그래서 다시 열 방이 있는 동안은 build()가
    // 탭 목록 대신 빈 화면을 그리도록 해서(_pendingReopenRoom) 그 반짝임을 없앤다.
    final activeId = widget.session.activeRoomId;
    if (activeId != null) {
      final matches = widget.session.rooms.where((r) => r.id == activeId);
      if (matches.isNotEmpty) _pendingReopenRoom = matches.first;
    }
    if (_pendingReopenRoom != null) {
      final room = _pendingReopenRoom!;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatScreen(session: widget.session, room: room),
          ),
        );
        if (mounted) setState(() => _pendingReopenRoom = null);
      });
    }
  }

  void _openRoom(Room room) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(session: widget.session, room: room),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_pendingReopenRoom != null) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBackPress();
      },
      child: Scaffold(
        // 어느 탭인지는 아래 NavigationBar가 이미 보여주므로, 좁은 화면에서도 창 왼쪽 위는
        // PC와 똑같이 지금 보고 있는 팀(아이콘+이름+전환 버튼) 자리로 쓴다.
        appBar: AppBar(title: TeamSwitcher(session: widget.session)),
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
        // 준회원은 방을 만들거나 토픽을 찾아 참여할 수 없으므로 + 버튼 자체를 감춘다
        // (서버도 막지만, 눌러봐야 실패하는 버튼을 보여주지 않는다).
        floatingActionButton: !widget.session.canCreateRooms
            ? null
            : switch (_index) {
                0 => FloatingActionButton(
                  tooltip: '토픽방 찾기 / 만들기',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          TopicBrowseScreen(session: widget.session),
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
            NavigationDestination(
              icon: Icon(Icons.people_outline),
              label: '멤버',
            ),
            NavigationDestination(icon: Icon(Icons.more_horiz), label: '더보기'),
          ],
        ),
      ),
    );
  }
}

/// 토픽/그룹채팅/채팅 탭 공통 몸통: 검색창(누르면 SearchScreen으로 이동) + 그 타입의
/// 방 목록. 즐겨찾기한 방을 위로 모으고, 그 안에서는 최근 활동 순으로 정렬한다(PC 사이드바와
/// 동일한 규칙 — Session._bumpRoomActivity 참고).
class _RoomTypeTab extends StatefulWidget {
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

  @override
  State<_RoomTypeTab> createState() => _RoomTypeTabState();
}

class _RoomTypeTabState extends State<_RoomTypeTab> {
  // 5개 탭이 IndexedStack으로 전부 동시에 마운트돼 있다 보니, 컨트롤러 없이(Scrollbar가
  // 알아서 붙는 방식) 쓰면 안드로이드에서 스크롤바가 안 뜨는 경우가 있었다 — 탭마다 컨트롤러를
  // 직접 만들어서 ListView와 MutedScrollbar 양쪽에 명시적으로 물려준다.
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

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
        _SearchBox(session: widget.session),
        Expanded(
          child: ListenableBuilder(
            listenable: widget.session,
            builder: (context, _) {
              // 평문 DM 숨기기/나가기는 멤버십을 안 건드리고 내 hidden 플래그만 켠다
              // (room_options_menu.dart 참고) — session.rooms엔 그대로 남으므로 목록
              // 화면에서만 걸러낸다.
              // session.rooms에는 다른 팀 방까지 들어있으므로 지금 팀 것만 걸러낸다
              // (Session.rooms 주석 참고).
              final teamId = widget.session.currentTeam?.id;
              final rooms = _favoriteFirst(
                widget.session.rooms
                    .where(
                      (r) =>
                          r.type == widget.type &&
                          r.teamId == teamId &&
                          !r.hidden,
                    )
                    .toList(),
              );
              if (rooms.isEmpty) {
                return Center(
                  child: Text(
                    widget.emptyText,
                    style: TextStyle(color: Theme.of(context).hintColor),
                  ),
                );
              }
              return MutedScrollbar(
                controller: _scrollController,
                child: ListView.builder(
                  controller: _scrollController,
                  itemCount: rooms.length,
                  itemBuilder: (context, i) => _RoomRow(
                    session: widget.session,
                    room: rooms[i],
                    onTap: () => widget.onOpenRoom(rooms[i]),
                    showActivityTime: widget.showActivityTime,
                  ),
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
  // _RoomTypeTabState와 동일한 이유 — 컨트롤러를 명시적으로 물려야 안드로이드에서도
  // 스크롤바가 확실히 붙는다.
  final _scrollController = ScrollController();

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
    _scrollController.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final users = await widget.session.fetchTeamMembers();
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
              : MutedScrollbar(
                  controller: _scrollController,
                  child: ListView.separated(
                    controller: _scrollController,
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
      // 부서·직책이 등록돼 있으면 조직도답게 이름 아래 같이 보여준다(PC 조직도와 동일).
      subtitle: user.orgLine == null ? null : Text(user.orgLine!),
      onTap: onTap,
    );
  }
}

/// 더보기 탭: 기존 PC 삼선 메뉴(AccountMenuButton)와 같은 항목(내 프로필/설정/오픈소스
/// 라이선스/로그아웃)을 전체 화면 목록으로 옮겨 놓은 것 — 새 기능은 추가하지 않았다.
class _MoreTab extends StatefulWidget {
  final Session session;
  const _MoreTab({required this.session});

  @override
  State<_MoreTab> createState() => _MoreTabState();
}

class _MoreTabState extends State<_MoreTab> {
  // 다른 탭들과 동일한 이유 — 컨트롤러를 명시적으로 물려야 안드로이드에서도 스크롤바가
  // 확실히 붙는다(지금은 항목이 적어 거의 안 넘치지만, 늘어날 수 있으니 동일하게 맞춘다).
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _logout(BuildContext context) async {
    await widget.session.logout();
    if (context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MutedScrollbar(
      controller: _scrollController,
      child: ListView(
        controller: _scrollController,
        children: [
          ListTile(
            leading: MyAvatar(session: widget.session, radius: 24),
            title: Text(
              widget.session.name ?? widget.session.username ?? '',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showDialog(
              context: context,
              builder: (_) => MyProfileDialog(session: widget.session),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('설정'),
            onTap: () => showDialog(
              context: context,
              builder: (_) => SettingsScreen(session: widget.session),
            ),
          ),
          // PC 삼선 메뉴와 동일한 조건 — 서버 운영자·계정 관리자·팀 소유자에게만 보인다.
          if (widget.session.canCreateInviteLink)
            ListTile(
              leading: const Icon(Icons.add_link),
              title: const Text('초대 링크 생성'),
              onTap: () => showInviteLinkScreen(context, widget.session),
            ),
          // 팀 초대 링크 생성은 팀 설정(팀 정보 탭)으로 옮겼다 — 이미 어느 팀인지 정해진
          // 곳에서 만드는 게 더 자연스러워서(team_settings_dialog.dart).
          // PC 삼선 메뉴와 동일하게, 서버 운영자에게만 보인다.
          if (widget.session.isServerAdmin)
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('서버 관리'),
              onTap: () => showAdminConsole(context, widget.session),
            ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('오픈소스 라이선스'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'TangoTalk',
              applicationVersion: _appVersion,
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.redAccent),
            title: const Text(
              '로그아웃',
              style: TextStyle(color: Colors.redAccent),
            ),
            onTap: () => _logout(context),
          ),
        ],
      ),
    );
  }
}
