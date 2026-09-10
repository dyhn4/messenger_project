import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../services/session.dart';
import '../widgets/account_menu_button.dart';
import '../widgets/chat_panel.dart';
import '../widgets/favorite_star.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/pagination.dart';
import '../widgets/room_avatar.dart';
import '../widgets/room_options_menu.dart';
import '../widgets/team_switcher.dart';
import '../widgets/unread_badge.dart';
import '../widgets/user_avatar.dart';
import 'create_topic_screen.dart';
import 'files_screen.dart';
import 'member_profile_dialog.dart';
import 'message_thread_screen.dart';
import 'my_profile_dialog.dart';
import 'new_chat_screen.dart';
import 'search_screen.dart';
import 'topic_browse_screen.dart';

/// 이 폭 이하로 창이 좁아지면 왼쪽 사이드바(고정 280px)를 항상 펼쳐두는 대신 얇은 화살표
/// 스트립으로 접는다 — HomeScreen이 데스크톱/모바일 레이아웃을 가르는 wideBreakpoint(700)와는
/// 별개로, "데스크톱 레이아웃이긴 한데 사이드바를 나란히 두기엔 좁은" 중간 구간을 다룬다.
const _sidebarCollapseBreakpoint = 950.0;

/// 검색/멤버/댓글 스레드 우측 패널의 폭 — 예전엔 창이 1200px보다 넓으면 480, 아니면 400으로
/// 창 폭에 따라 바뀌었지만, 고정 폭이 낫다는 피드백에 따라 하나의 값으로 고정했다. 500은
/// search_screen.dart의 "참여한 대화방"/"모든 멤버"/"전체 기간" 필터 버튼 세 개가 줄임표 없이
/// 한 줄에 다 들어가는 데 필요한 최소 폭(계산상 약 430~450px)에 여유를 더한 값이다.
const _sidePanelWidth = 420.0;

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
  bool _filesOpen = false;
  String? _highlightMessageId;
  Message? _threadMessage; // 열려있는 댓글 스레드 패널(있으면 그 메시지).

  /// 창 폭이 [_sidebarCollapseBreakpoint] 이하로 좁아지면 왼쪽 사이드바(토픽/그룹채팅/채팅
  /// 목록)가 고정 280px 칸에 억지로 눌려서(글자가 세로로 한 글자씩 줄바꿈되는 등) 깨지는
  /// 문제가 있었다 — 그 대신 얇은 화살표 스트립으로 접어두고, 눌렀을 때만 채팅 위로 겹쳐서
  /// 뜨는 오버레이로 보여준다. true면 지금 그 오버레이가 펼쳐진 상태.
  bool _sidebarOverlayOpen = false;

  /// 방을 바꿀 때마다 쓴다 — 이전 방 메시지의 스레드 패널은 더 이상 의미가 없으므로 같이 닫는다.
  /// _highlightMessageId도 같이 지운다 — 검색 결과 클릭(onOpenRoom, 아래 참고)이 아닌 다른
  /// 경로로 방을 열 때 예전 검색 하이라이트가 남아있으면, 나중에(예: 알림을 눌러) 이 방을
  /// 다시 열 때 맨 아래 대신 그 옛 메시지 위치로 스크롤되는 문제가 있었다. 사이드바가 겹침
  /// 오버레이로 펼쳐진 채로 방을 골랐으면(좁은 창) 그 오버레이도 같이 접는다.
  void _selectRoom(Room room) {
    setState(() {
      _selectedRoom = room;
      _threadMessage = null;
      _highlightMessageId = null;
      _sidebarOverlayOpen = false;
    });
  }

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);

    // 팀 선택 화면(또는 다른 팀)에서 알림/토스트를 눌러 특정 방을 요청했는데, 그 요청이
    // 다른 팀의 방이라 session.requestOpenRoom()이 currentTeam을 먼저 바꾼 경우 — 그 전환
    // 때문에 HomeScreen이 이 화면을 지금 막 새로 만든다. requestOpenRoom()의
    // notifyListeners()는 이 위젯이 생기기 "전"에 이미 불렸으므로, 아래 _onSessionChanged
    // 리스너가 그 요청을 놓친다. 여기서 먼저 소비해줘야 그 방이 열린다.
    final pending = widget.session.consumePendingOpenRoom();
    if (pending != null) {
      _selectedRoom = pending;
      return;
    }

    // 좁은 화면(RoomListScreen)에서 채팅방을 열어둔 채로 창을 넓혀서 이 화면으로 넘어온
    // 경우 — 그 화면의 ChatScreen(ChatPanel)이 아직 dispose 전이라(같은 프레임 안에서 새
    // 위젯의 initState가 먼저 돌고 옛 dispose가 나중에 돎) session.activeRoomId가 아직
    // 그 방을 그대로 가리키고 있다. 그 방을 그대로 이어서 선택해둔다(HomeScreen이 위에
    // 쌓여있던 ChatScreen 스택도 걷어내서 이 화면이 실제로 보이게 한다).
    final activeId = widget.session.activeRoomId;
    if (activeId != null) {
      final matches = widget.session.rooms.where((r) => r.id == activeId);
      if (matches.isNotEmpty) _selectedRoom = matches.first;
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    final pending = widget.session.consumePendingOpenRoom();
    if (pending != null) {
      _selectRoom(pending);
      return;
    }
    // 선택된 방이 목록에서 사라졌거나(예: 그룹/토픽 나가기) 숨겨졌으면(평문 DM 숨기기/나가기 —
    // 멤버십은 그대로 두고 hidden만 켜므로 rooms 목록엔 남아있다) 우측 패널을 비운다.
    final selected = _selectedRoom;
    if (selected != null) {
      final match = widget.session.rooms.where((r) => r.id == selected.id);
      if (match.isEmpty || match.first.hidden) {
        setState(() {
          _selectedRoom = null;
          _threadMessage = null;
        });
      }
    }
  }

  Future<void> _createTopic() async {
    final result = await showDialog<Room>(
      context: context,
      builder: (_) =>
          CreateTopicScreen(session: widget.session, asDialog: true),
    );
    if (result != null) _selectRoom(result);
  }

  Future<void> _browseTopics() async {
    await showDialog(
      context: context,
      builder: (_) =>
          TopicBrowseScreen(session: widget.session, asDialog: true),
    );
  }

  Future<void> _newGroupChat() async {
    final result = await showDialog<Room>(
      context: context,
      builder: (_) => NewChatScreen(session: widget.session, asDialog: true),
    );
    if (result != null) _selectRoom(result);
  }

  Future<void> _openMemberProfile(AppUser user) async {
    // 멤버 목록에서 로그인한 사용자 자신을 클릭하면, 다른 멤버 볼 때 쓰는 카드(DM 시작 등)
    // 대신 삼선 메뉴의 "내 프로필"과 같은 카드(이름/이메일/비밀번호 수정)를 보여준다.
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
    if (room != null) {
      setState(() {
        _selectedRoom = room;
        _threadMessage = null;
        _membersOpen = false;
        _highlightMessageId = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _TopBar(
            session: widget.session,
            onShowMembers: () => setState(() {
              _membersOpen = !_membersOpen;
              if (_membersOpen) {
                _searchOpen = false;
                _filesOpen = false;
                _threadMessage = null;
              }
            }),
            onToggleSearch: () => setState(() {
              _searchOpen = !_searchOpen;
              if (_searchOpen) {
                _membersOpen = false;
                _filesOpen = false;
                _threadMessage = null;
              }
            }),
            onOpenFiles: () => setState(() {
              _filesOpen = !_filesOpen;
              if (_filesOpen) {
                _searchOpen = false;
                _membersOpen = false;
                _threadMessage = null;
              }
            }),
          ),
          const Divider(height: 1),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildSidebarAndChat(context)),
                if (_searchOpen) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: _sidePanelWidth,
                    child: SearchScreen(
                      session: widget.session,
                      asPanel: true,
                      onClose: () => setState(() => _searchOpen = false),
                      onOpenRoom: (room, messageId) => setState(() {
                        _selectedRoom = room;
                        _threadMessage = null;
                        _highlightMessageId = messageId;
                      }),
                    ),
                  ),
                ],
                if (_membersOpen) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: _sidePanelWidth,
                    child: _MembersPanel(
                      session: widget.session,
                      onClose: () => setState(() => _membersOpen = false),
                      onSelectMember: _openMemberProfile,
                    ),
                  ),
                ],
                if (_filesOpen) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: _sidePanelWidth,
                    child: FilesScreen(
                      session: widget.session,
                      initialRoomId: _selectedRoom?.id,
                      onClose: () => setState(() => _filesOpen = false),
                    ),
                  ),
                ],
                if (_threadMessage != null && _selectedRoom != null) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: _sidePanelWidth,
                    child: MessageThreadScreen(
                      session: widget.session,
                      room: _selectedRoom!,
                      message: _threadMessage!,
                      controller: widget.session.controllerFor(_selectedRoom!),
                      asPanel: true,
                      onClose: () => setState(() => _threadMessage = null),
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

  /// 창 폭이 [_sidebarCollapseBreakpoint] 이하일 때 사이드바를 얇은 화살표 스트립으로
  /// 접어두고(고정 280px가 억지로 눌려 글자가 세로로 깨지는 문제를 막는다), 화살표를 누르면
  /// 채팅 위로 겹쳐서 뜨는 오버레이로 보여준다. 창이 그보다 넓으면 기존과 동일하게 사이드바를
  /// 항상 펼쳐서 나란히 보여준다.
  Widget _buildSidebarAndChat(BuildContext context) {
    final sidebar = _Sidebar(
      session: widget.session,
      selectedRoomId: _selectedRoom?.id,
      onSelectRoom: _selectRoom,
      onCreateTopic: _createTopic,
      onBrowseTopics: _browseTopics,
      onNewGroupChat: _newGroupChat,
    );
    final chatArea = _buildChatArea(context);

    if (MediaQuery.of(context).size.width > _sidebarCollapseBreakpoint) {
      return Row(
        children: [
          SizedBox(width: 280, child: sidebar),
          const VerticalDivider(width: 1),
          Expanded(child: chatArea),
        ],
      );
    }

    return Stack(
      children: [
        Row(
          children: [
            _SidebarToggleStrip(
              expanded: _sidebarOverlayOpen,
              onTap: () =>
                  setState(() => _sidebarOverlayOpen = !_sidebarOverlayOpen),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: GestureDetector(
                // 오버레이가 펼쳐진 동안 채팅 부분(가려지지 않은 나머지)을 누르면 그
                // 클릭이 채팅 내부 버튼 등으로 새지 않고 오버레이만 접히게 한다.
                behavior: HitTestBehavior.translucent,
                onTap: _sidebarOverlayOpen
                    ? () => setState(() => _sidebarOverlayOpen = false)
                    : null,
                child: IgnorePointer(
                  ignoring: _sidebarOverlayOpen,
                  child: chatArea,
                ),
              ),
            ),
          ],
        ),
        // 스트립(왼쪽 28px) 바로 옆에서 시작해서 채팅 위로 겹쳐 뜬다 — 스트립 자체는 안
        // 가려서 화살표를 눌러 다시 접을 수 있다.
        if (_sidebarOverlayOpen)
          Positioned(
            left: 28,
            top: 0,
            bottom: 0,
            width: 280,
            child: Material(elevation: 8, child: sidebar),
          ),
      ],
    );
  }

  Widget _buildChatArea(BuildContext context) {
    if (_selectedRoom == null) {
      return const Center(child: Text('왼쪽에서 대화방을 선택하세요.'));
    }
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              FavoriteStar(
                favorite: _selectedRoom!.favorite,
                onTap: () => widget.session.toggleFavorite(_selectedRoom!),
              ),
              const SizedBox(width: 8),
              RoomAvatar(
                room: _selectedRoom!,
                myUserId: widget.session.userId ?? '',
                resolveUrl: widget.session.resolveUrl,
                onlineUserIds: widget.session.onlineUserIds,
              ),
              const SizedBox(width: 10),
              if (_selectedRoom!.isSecret) ...[
                const Icon(Icons.lock, size: 14, color: Colors.green),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  _selectedRoom!.displayName(widget.session.userId ?? ''),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: _selectedRoom!.isSecret ? Colors.green : null,
                  ),
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
            onOpenThread: (m) => setState(() {
              _threadMessage = m;
              _searchOpen = false;
              _membersOpen = false;
            }),
          ),
        ),
      ],
    );
  }
}

/// 사이드바가 접혔을 때(창 폭 <= [_sidebarCollapseBreakpoint]) 대신 보이는 얇은 화살표
/// 스트립. 펼쳐지지 않은 상태(»)를 누르면 사이드바가 겹침 오버레이로 뜨고, 펼쳐진
/// 상태(«, 반대 방향)를 누르면 다시 접힌다 — 같은 자리에서 화살표만 바뀐다.
class _SidebarToggleStrip extends StatelessWidget {
  final bool expanded;
  final VoidCallback onTap;
  const _SidebarToggleStrip({required this.expanded, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: InkWell(
          onTap: onTap,
          child: Center(
            child: Icon(
              expanded
                  ? Icons.keyboard_double_arrow_left
                  : Icons.keyboard_double_arrow_right,
              size: 18,
              color: Theme.of(context).hintColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// 창 전체 폭을 가로지르는 최상단 바: 앱 이름(좌) + 멤버/검색/삼선(햄버거) 메뉴(우측 끝).
class _TopBar extends StatelessWidget {
  final Session session;
  final VoidCallback onShowMembers;
  final VoidCallback onToggleSearch;
  final VoidCallback onOpenFiles;
  const _TopBar({
    required this.session,
    required this.onShowMembers,
    required this.onToggleSearch,
    required this.onOpenFiles,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          // 앱 이름 자리에 지금 보고 있는 팀(아이콘+이름)과 전환 버튼을 둔다.
          // Spacer 대신 Expanded+Align을 쓴다 — Spacer와 나란히 두면 남는 공간을 서로
          // 나눠 가져서 오른쪽 아이콘들이 창 끝에 붙지 않는다.
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: TeamSwitcher(session: session),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.people_outline),
            tooltip: '멤버',
            onPressed: onShowMembers,
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '검색',
            onPressed: onToggleSearch,
          ),
          PopupMenuButton<void>(
            icon: const Icon(Icons.apps),
            tooltip: '메뉴',
            position: PopupMenuPosition.under,
            offset: const Offset(0, 10),
            itemBuilder: (context) => [
              PopupMenuItem(
                onTap: onOpenFiles,
                child: const Row(
                  children: [_FileTypeIcon(), SizedBox(width: 8), Text('파일')],
                ),
              ),
            ],
          ),
          AccountMenuButton(session: session),
        ],
      ),
    );
  }
}

/// "메뉴" 팝업의 "파일" 항목 앞에 붙는 색깔 있는 파일 아이콘 — 민트색 둥근 배경 위에
/// 진한 민트색 문서 아이콘.
class _FileTypeIcon extends StatelessWidget {
  const _FileTypeIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: const Color(0xFFDCF5EB),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: const Icon(
        Icons.description_rounded,
        size: 16,
        color: Color(0xFF1FAE85),
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
  const _MembersPanel({
    required this.session,
    required this.onClose,
    required this.onSelectMember,
  });

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
      final users = await widget.session.fetchTeamMembers();
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
        .where(
          (u) =>
              _filter.isEmpty ||
              u.name.toLowerCase().contains(_filter.toLowerCase()),
        )
        .toList();
    final totalPages = list.isEmpty
        ? 1
        : (list.length / paginationPageSize).ceil();
    final page = _page.clamp(0, totalPages - 1);
    final pageItems = list
        .skip(page * paginationPageSize)
        .take(paginationPageSize)
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
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: widget.onClose,
                ),
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
                              online: widget.session.onlineUserIds.contains(
                                pageItems[i].id,
                              ),
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
  const _MemberRow({
    required this.user,
    required this.resolveUrl,
    required this.online,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            UserAvatar(
              user: user,
              resolveUrl: resolveUrl,
              radius: 20,
              online: online,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  // 부서·직책이 등록돼 있으면 조직도답게 이름 아래 같이 보여준다.
                  if (user.orgLine != null)
                    Text(
                      user.orgLine!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                ],
              ),
            ),
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        // 평문 DM의 "채팅방 숨기기"/"채팅방 나가기"는 멤버십을 안 건드리고 내 hidden
        // 플래그만 켠다(room_options_menu.dart 참고) — 그래서 session.rooms에는 그대로
        // 남아있고, 여기(목록 UI)에서만 걸러낸다. 상대가 새 메시지를 보내면 서버가 자동으로
        // hidden을 다시 꺼줘서 이 필터를 통과해 목록에 돌아온다.
        // session.rooms에는 다른 팀 방까지 전부 들어있다(다른 팀 메시지도 실시간으로 받아야
        // 하므로 — Session.rooms 주석 참고). 화면에는 지금 보고 있는 팀 것만 보여준다.
        final teamId = session.currentTeam?.id;
        bool visible(Room r) => r.teamId == teamId && !r.hidden;
        final topics = _favoriteFirst(
          session.rooms
              .where((r) => r.type == RoomType.topic && visible(r))
              .toList(),
        );
        final groups = _favoriteFirst(
          session.rooms
              .where((r) => r.type == RoomType.group && visible(r))
              .toList(),
        );
        final dms = _favoriteFirst(
          session.rooms
              .where((r) => r.type == RoomType.dm && visible(r))
              .toList(),
        );
        final topicsUnread = topics.fold<int>(
          0,
          (sum, r) => sum + r.unreadCount,
        );
        final groupsUnread = groups.fold<int>(
          0,
          (sum, r) => sum + r.unreadCount,
        );
        final dmsUnread = dms.fold<int>(0, (sum, r) => sum + r.unreadCount);

        // 세 섹션 사이 구분선을 사용자가 드래그해서 각자 몫을 조절할 수 있게 한다.
        // 기본은 1/3씩이고, 자기 영역 안에서만 스크롤되며 목록이 영역보다 길면
        // 스크롤바를 항상 보여준다.
        return _ResizableRoomSections(
          topicsHeader: _SectionHeader(
            title: '토픽 ${topics.length}',
            badgeCount: topicsUnread,
            // 준회원은 방을 만들거나 토픽을 찾아 참여할 수 없다 — 초대받은 방에서만 활동한다.
            action: !session.canCreateRooms
                ? null
                : PopupMenuButton<void>(
                    icon: const Icon(Icons.add, size: 20),
                    tooltip: '토픽 추가',
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        onTap: onCreateTopic,
                        child: const Text('토픽 만들기'),
                      ),
                      PopupMenuItem(
                        onTap: onBrowseTopics,
                        child: const Text('토픽 찾기'),
                      ),
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
                favorite: room.favorite,
                muted: room.muted,
                onToggleFavorite: () => session.toggleFavorite(room),
                onTap: () => onSelectRoom(room),
              ),
          ],
          groupsHeader: _SectionHeader(
            title: '그룹채팅 ${groups.length}',
            badgeCount: groupsUnread,
            action: !session.canCreateRooms
                ? null
                : IconButton(
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
                favorite: room.favorite,
                isSecret: room.isSecret,
                muted: room.muted,
                onToggleFavorite: () => session.toggleFavorite(room),
                onTap: () => onSelectRoom(room),
              ),
          ],
          dmsHeader: _SectionHeader(
            title: '채팅 ${dms.length}',
            badgeCount: dmsUnread,
            action: !session.canCreateRooms
                ? null
                : IconButton(
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
                favorite: room.favorite,
                isSecret: room.isSecret,
                muted: room.muted,
                onToggleFavorite: () => session.toggleFavorite(room),
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
              child: _RoomSection(
                header: widget.topicsHeader,
                children: widget.topicsChildren,
              ),
            ),
            _ResizeDivider(onDrag: (dy) => _onDrag(availableHeight, 0, dy)),
            SizedBox(
              height: heights[1],
              child: _RoomSection(
                header: widget.groupsHeader,
                children: widget.groupsChildren,
              ),
            ),
            _ResizeDivider(onDrag: (dy) => _onDrag(availableHeight, 1, dy)),
            SizedBox(
              height: heights[2],
              child: _RoomSection(
                header: widget.dmsHeader,
                children: widget.dmsChildren,
              ),
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
          child: Center(
            child: Container(height: 1, color: Theme.of(context).dividerColor),
          ),
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
                if (badgeCount > 0) ...[
                  const SizedBox(width: 6),
                  UnreadBadge(count: badgeCount),
                ],
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _RoomTile extends StatefulWidget {
  final Widget leading;
  final String label;
  final bool selected;
  final int unreadCount;
  final bool favorite;
  final bool isSecret;
  final bool muted;
  final VoidCallback onToggleFavorite;
  final VoidCallback onTap;
  const _RoomTile({
    required this.leading,
    required this.label,
    required this.selected,
    this.unreadCount = 0,
    required this.favorite,
    this.isSecret = false,
    this.muted = false,
    required this.onToggleFavorite,
    required this.onTap,
  });

  @override
  State<_RoomTile> createState() => _RoomTileState();
}

class _RoomTileState extends State<_RoomTile> {
  // 즐겨찾기 안 된 회색 별은 평소엔 숨겨두고, 마우스가 이 행 위에 있을 때만 보여준다.
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: ListTile(
        dense: true,
        selected: widget.selected,
        selectedTileColor: Theme.of(
          context,
        ).colorScheme.primaryContainer.withValues(alpha: 0.4),
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Opacity(
              opacity: widget.favorite || _hovering ? 1 : 0,
              child: FavoriteStar(
                favorite: widget.favorite,
                onTap: widget.onToggleFavorite,
              ),
            ),
            const SizedBox(width: 8),
            widget.leading,
          ],
        ),
        title: Row(
          children: [
            if (widget.isSecret) ...[
              const Icon(Icons.lock, size: 14, color: Colors.green),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: widget.isSecret
                    ? const TextStyle(color: Colors.green)
                    : null,
              ),
            ),
            if (widget.muted) ...[
              const SizedBox(width: 4),
              Icon(
                Icons.notifications_off,
                size: 14,
                color: Theme.of(context).hintColor,
              ),
            ],
          ],
        ),
        trailing: widget.unreadCount > 0
            ? UnreadBadge(count: widget.unreadCount)
            : null,
        onTap: widget.onTap,
      ),
    );
  }
}
