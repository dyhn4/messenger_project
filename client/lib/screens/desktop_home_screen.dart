import 'dart:io';

import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../services/api_client.dart' show PositionOption;
import '../services/session.dart';
import '../widgets/account_menu_button.dart';
import '../widgets/app_toast.dart';
import '../widgets/app_menu_button.dart';
import '../widgets/chat_panel.dart';
import '../widgets/favorite_star.dart';
import '../widgets/muted_scrollbar.dart';
import '../widgets/notifications_panel.dart';
import '../widgets/pagination.dart';
import '../widgets/position_badge.dart';
import '../widgets/room_avatar.dart';
import '../widgets/room_options_menu.dart';
import '../widgets/team_avatar.dart';
import '../services/app_settings.dart' show TeamSwitchStyle;
import '../widgets/team_switcher.dart';
import '../widgets/unread_badge.dart';
import '../widgets/user_avatar.dart';
import 'create_topic_screen.dart';
import 'files_screen.dart';
import 'member_profile_dialog.dart';
import 'message_thread_screen.dart';
import 'project/project_dialog.dart';
import 'project/project_window.dart';
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
/// 이 방을 채팅 패널에 계속 띄워둘 수 있는지 — 목록에서 사라졌거나(나가기), 숨겨졌거나
/// (DM 숨기기), **다른 팀으로 전환**했으면 더는 보여줄 대상이 아니다. session.rooms는 모든
/// 팀의 방을 다 들고 있어서 "사라졌는지"만 봐서는 팀 전환을 걸러내지 못한다.
@visibleForTesting
bool isRoomGoneFrom(Session session, String roomId) {
  final match = session.rooms.where((r) => r.id == roomId);
  if (match.isEmpty || match.first.hidden) return true;
  return match.first.teamId != session.currentTeam?.id;
}

class DesktopHomeScreen extends StatefulWidget {
  final Session session;
  const DesktopHomeScreen({super.key, required this.session});

  @override
  State<DesktopHomeScreen> createState() => _DesktopHomeScreenState();
}

class _DesktopHomeScreenState extends State<DesktopHomeScreen> {
  Room? _selectedRoom;
  // "대화창 분할하기"(방 목록 우클릭 메뉴)로 연 두 번째 채팅 패널 — 오른쪽에 나란히 뜬다.
  // _selectedRoom과 같은 방이면 분할할 의미가 없으므로 _effectiveSplitRoom에서 걸러진다.
  Room? _splitRoom;
  bool _searchOpen = false;
  bool _membersOpen = false;
  bool _filesOpen = false;
  bool _notificationsOpen = false;
  String? _highlightMessageId;
  Message? _threadMessage; // 열려있는 댓글 스레드 패널(있으면 그 메시지).
  // 위 _threadMessage가 메인 패널 것인지 분할 패널 것인지 구분해야 그 스레드를 올바른 방의
  // 메시지 목록/컨트롤러로 그릴 수 있다(분할 패널 도입 전엔 항상 _selectedRoom이라고 가정했음).
  Room? _threadRoom;
  // "직책 배지"(1:1 채팅 목록/상단)용 — org_chart_screen.dart와 동일하게 한 번만 불러와 캐싱한다.
  List<PositionOption>? _positionOptions;

  /// _splitRoom이 메인과 같은 방을 가리키면(예: 분할해둔 방을 방금 메인으로도 선택함) 굳이
  /// 같은 방을 두 번 그리지 않는다.
  Room? get _effectiveSplitRoom =>
      _splitRoom != null && _splitRoom!.id != _selectedRoom?.id
      ? _splitRoom
      : null;

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
      _threadRoom = null;
      _highlightMessageId = null;
      _sidebarOverlayOpen = false;
    });
  }

  /// 방 목록 우클릭 메뉴의 "대화창 분할하기" — 이미 메인에 열려 있는 방이면 아무 것도 안 한다
  /// (같은 방을 두 번 그릴 이유가 없다). 검색/멤버/파일/알림 센터 패널과는 서로 자리를
  /// 다투므로(한 화면에 다 욱여넣으면 너무 좁아짐), 그 넷과 똑같이 서로 배타적으로 만든다 —
  /// 분할 패널을 열면 그 넷을 닫고, 그 넷 중 하나를 열면(위 _TopBar 콜백들) 분할 패널을 닫는다.
  void _openSplitRoom(Room room) {
    if (room.id == _selectedRoom?.id) return;
    setState(() {
      _splitRoom = room;
      _searchOpen = false;
      _membersOpen = false;
      _filesOpen = false;
      _notificationsOpen = false;
      _threadMessage = null;
      _threadRoom = null;
    });
  }

  bool _isRoomGone(String roomId) => isRoomGoneFrom(widget.session, roomId);

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
    widget.session.fetchPublicPositionOptions().then((list) {
      if (mounted) setState(() => _positionOptions = list);
    });

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
    // 메인/분할/스레드가 가리키던 방이 목록에서 사라졌거나(예: 그룹/토픽 나가기) 숨겨졌으면
    // (평문 DM 숨기기/나가기 — 멤버십은 그대로 두고 hidden만 켜므로 rooms 목록엔 남아있다)
    // 그 패널을 비운다. 셋은 서로 다른 방일 수 있어(분할 패널 도입) 각자 따로 확인한다.
    final selected = _selectedRoom;
    final split = _splitRoom;
    final thread = _threadRoom;
    final selectedGone = selected != null && _isRoomGone(selected.id);
    final splitGone = split != null && _isRoomGone(split.id);
    final threadGone = thread != null && _isRoomGone(thread.id);
    if (selectedGone || splitGone || threadGone) {
      setState(() {
        if (selectedGone) _selectedRoom = null;
        if (splitGone) _splitRoom = null;
        if (threadGone) {
          _threadMessage = null;
          _threadRoom = null;
        }
      });
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
        _threadRoom = null;
        _membersOpen = false;
        _highlightMessageId = null;
      });
    }
  }

  /// "알림 센터"에서 방을 누르면 — 다른 팀 방일 수 있으므로(그게 이 패널의 핵심 목적이다)
  /// _selectRoom으로 바로 바꾸지 않고 requestOpenRoom을 거친다. 그 방이 지금 보고 있는
  /// 팀이 아니면 currentTeam을 먼저 그 팀으로 바꾸고 "펼쳐서 보여줄 방"을 예약해두는데,
  /// _onSessionChanged가 곧이어 그 예약을 소비해서 _selectRoom을 대신 호출해준다(main.dart의
  /// 알림 클릭 처리, org_chart_screen.dart의 멤버 선택과 같은 패턴).
  void _openNotificationRoom(Room room) {
    final hadUnreadAnnouncement = room.hasUnreadAnnouncement;
    setState(() => _notificationsOpen = false);
    widget.session.requestOpenRoom(room);
    // 안 읽은 공지 때문에 알림 센터에 떠 있던 방이면 공지 내용도 팝업으로 띄운다.
    showUnreadAnnouncementPopup(
      context,
      widget.session,
      room,
      hadUnreadAnnouncement: hadUnreadAnnouncement,
    );
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
                _notificationsOpen = false;
                _threadMessage = null;
                _threadRoom = null;
                _splitRoom = null;
              }
            }),
            onToggleSearch: () => setState(() {
              _searchOpen = !_searchOpen;
              if (_searchOpen) {
                _membersOpen = false;
                _filesOpen = false;
                _notificationsOpen = false;
                _threadMessage = null;
                _threadRoom = null;
                _splitRoom = null;
              }
            }),
            onOpenFiles: () => setState(() {
              _filesOpen = !_filesOpen;
              if (_filesOpen) {
                _searchOpen = false;
                _membersOpen = false;
                _notificationsOpen = false;
                _threadMessage = null;
                _threadRoom = null;
                _splitRoom = null;
              }
            }),
            onToggleNotifications: () => setState(() {
              _notificationsOpen = !_notificationsOpen;
              if (_notificationsOpen) {
                _searchOpen = false;
                _membersOpen = false;
                _filesOpen = false;
                _threadMessage = null;
                _threadRoom = null;
                _splitRoom = null;
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
                if (_notificationsOpen) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: _sidePanelWidth,
                    child: NotificationsPanel(
                      session: widget.session,
                      onClose: () => setState(() => _notificationsOpen = false),
                      onSelectRoom: _openNotificationRoom,
                    ),
                  ),
                ],
                if (_threadMessage != null && _threadRoom != null) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: _sidePanelWidth,
                    child: MessageThreadScreen(
                      session: widget.session,
                      room: _threadRoom!,
                      message: _threadMessage!,
                      controller: widget.session.controllerFor(_threadRoom!),
                      asPanel: true,
                      onClose: () => setState(() {
                        _threadMessage = null;
                        _threadRoom = null;
                      }),
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
      positionOptions: _positionOptions,
      onSelectRoom: _selectRoom,
      onSplitRoom: _openSplitRoom,
      onCreateTopic: _createTopic,
      onBrowseTopics: _browseTopics,
      onNewGroupChat: _newGroupChat,
    );
    final chatArea = _buildChatArea(context, _selectedRoom);
    final splitRoom = _effectiveSplitRoom;

    if (MediaQuery.of(context).size.width > _sidebarCollapseBreakpoint) {
      return Row(
        children: [
          SizedBox(width: 280, child: sidebar),
          const VerticalDivider(width: 1),
          Expanded(child: chatArea),
          // "대화창 분할하기" — 창이 사이드바 접힘 기준보다 넓을 때만 나란히 보여준다(그보다
          // 좁으면 채팅 하나도 겹침 오버레이로 겨우 보는 상황이라 두 개를 나란히 둘 자리가
          // 없다 — 상태는 그대로 유지되고 창을 다시 넓히면 돌아온다).
          if (splitRoom != null) ...[
            const VerticalDivider(width: 1),
            Expanded(
              child: _buildChatArea(
                context,
                splitRoom,
                onClose: () => setState(() => _splitRoom = null),
              ),
            ),
          ],
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

  /// 메인 패널(onClose 없음, room:_selectedRoom)과 분할 패널(onClose 있음, room:_splitRoom)이
  /// 이 하나의 메서드를 같이 쓴다 — 헤더(즐겨찾기/아바타/이름(+1:1이면 직책 배지)/삼점메뉴)와
  /// ChatPanel을 완전히 똑같은 모양으로 그린다. onClose가 있으면(분할 패널) 헤더에 닫기
  /// 버튼이 하나 더 붙는다.
  Widget _buildChatArea(
    BuildContext context,
    Room? room, {
    VoidCallback? onClose,
  }) {
    if (room == null) {
      // 방을 아직 안 골랐을 땐(팀을 막 전환한 직후 포함) 지금 보고 있는 팀을 알려준다.
      final team = widget.session.currentTeam;
      if (team == null) {
        return const Center(child: Text('왼쪽에서 대화방을 선택하세요.'));
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TeamAvatar(
              team: team,
              resolveUrl: widget.session.resolveUrl,
              size: 96,
            ),
            const SizedBox(height: 16),
            Text(
              '${team.name}입니다',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              '왼쪽에서 대화방을 선택하세요.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
          ],
        ),
      );
    }
    final isSplit = onClose != null;
    final otherMember = room.type == RoomType.dm
        ? room.members.where((m) => m.id != widget.session.userId).firstOrNull
        : null;
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
                favorite: room.favorite,
                onTap: () => widget.session.toggleFavorite(room),
              ),
              const SizedBox(width: 8),
              RoomAvatar(
                room: room,
                myUserId: widget.session.userId ?? '',
                resolveUrl: widget.session.resolveUrl,
                onlineUserIds: widget.session.onlineUserIds,
              ),
              const SizedBox(width: 10),
              if (room.isSecret) ...[
                const Icon(Icons.lock, size: 14, color: Colors.green),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        room.displayName(widget.session.userId ?? ''),
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: room.isSecret ? Colors.green : null,
                            ),
                      ),
                    ),
                    // 방 목록의 배지와 달리 헤더는 등급(조장 이상)과 무관하게 직책이 있으면
                    // 그냥 글자로 보여준다 — 배지가 아니라 이름 옆의 작은 보조 텍스트.
                    if (otherMember?.position != null &&
                        otherMember!.position!.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(
                        otherMember.position!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (isSplit)
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '분할 닫기',
                  onPressed: onClose,
                ),
              RoomOptionsMenu(session: widget.session, room: room),
            ],
          ),
        ),
        Expanded(
          child: ChatPanel(
            key: ValueKey('${isSplit ? 'split' : 'main'}-${room.id}'),
            session: widget.session,
            room: room,
            highlightMessageId: isSplit ? null : _highlightMessageId,
            // 오른쪽 패널은 한 번에 하나만 — 댓글을 열면 열려 있던 다른 패널(파일 모아보기
            // 등)은 닫아서 자리를 넘겨준다(반대로 그 패널들을 열면 댓글이 닫힌다).
            onOpenThread: (m) => setState(() {
              _threadMessage = m;
              _threadRoom = room;
              _searchOpen = false;
              _membersOpen = false;
              _filesOpen = false;
              _notificationsOpen = false;
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
  final VoidCallback onToggleNotifications;
  const _TopBar({
    required this.session,
    required this.onShowMembers,
    required this.onToggleSearch,
    required this.onOpenFiles,
    required this.onToggleNotifications,
  });

  @override
  Widget build(BuildContext context) {
    // 환경설정 "팀 전환 방식" — 드롭다운(기본)이거나 팀을 전부 보여주는 탭.
    return ListenableBuilder(
      listenable: session.settings,
      builder: (context, _) {
        final tabs = session.settings.teamSwitchStyle == TeamSwitchStyle.tabs;
        // 탭 모드에서는 탭이 아래 구분선에 딱 닿아야 브라우저 탭처럼 보이므로, 바 자체의
        // 아래 여백을 없애고 그만큼을 오른쪽 아이콘들에게만 준다(아이콘 위치는 그대로).
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 8, tabs ? 0 : 10),
          child: Row(
            crossAxisAlignment: tabs
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.center,
            children: [
              // 앱 이름 자리에 지금 보고 있는 팀(아이콘+이름)과 전환 버튼을 둔다.
              // Spacer 대신 Expanded+Align을 쓴다 — Spacer와 나란히 두면 남는 공간을 서로
              // 나눠 가져서 오른쪽 아이콘들이 창 끝에 붙지 않는다.
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: tabs
                      ? TeamSwitcherTabs(session: session)
                      : TeamSwitcher(session: session),
                ),
              ),
              Padding(
                padding: EdgeInsets.only(bottom: tabs ? 10 : 0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // "프로젝트"는 대화(토픽/방)와 성격이 다른 별도 공간이라, 나머지 아이콘들과
                    // 구분선으로 한 번 끊어서 왼쪽에 둔다(잔디와 같은 배치).
                    if (session.canUseProjects)
                      IconButton(
                        icon: ListenableBuilder(
                          listenable: session,
                          builder: (context, _) => Badge(
                            isLabelVisible: session.projectUnread > 0,
                            backgroundColor: Colors.redAccent,
                            label: Text('${session.projectUnread}'),
                            child: const Icon(Icons.track_changes),
                          ),
                        ),
                        tooltip: '프로젝트',
                        // Windows는 독립된 OS 창(작업표시줄에 따로 뜨고 최소화/최대화/리사이즈가 된다)으로
                        // 열고, 그 외(안드로이드)는 지금처럼 대화상자로 연다.
                        onPressed: () => Platform.isWindows
                            ? openProjectWindow(session)
                            : showProjectDialog(context, session),
                      ),
                    const SizedBox(
                      height: 24,
                      child: VerticalDivider(width: 16, thickness: 1),
                    ),
                    NotificationBellButton(
                      session: session,
                      onPressed: onToggleNotifications,
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
                    AppMenuButton(session: session, onOpenFiles: onOpenFiles),
                    AccountMenuButton(session: session),
                  ],
                ),
              ),
            ],
          ),
        );
      },
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
                    _users == null ? '멤버' : '멤버 총 ${_users!.length}명',
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
  final List<PositionOption>? positionOptions;
  final ValueChanged<Room> onSelectRoom;
  final ValueChanged<Room> onSplitRoom;
  final VoidCallback onCreateTopic;
  final VoidCallback onBrowseTopics;
  final VoidCallback onNewGroupChat;

  const _Sidebar({
    required this.session,
    required this.selectedRoomId,
    required this.positionOptions,
    required this.onSelectRoom,
    required this.onSplitRoom,
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
                      // 새 토픽 만들기는 팀 설정(토픽 생성 권한)에 따라 정회원 이상/관리자
                      // 이상/소유자만 가능할 수 있다 — 토픽 찾기(이미 있는 공개 토픽 참여)는
                      // 이 설정과 무관하게 정회원이면 항상 가능.
                      if (session.canCreateTopic)
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
                room: room,
                session: session,
                positionOptions: positionOptions,
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
                onSplitPanel: onSplitRoom,
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
                room: room,
                session: session,
                positionOptions: positionOptions,
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
                onSplitPanel: onSplitRoom,
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
                room: room,
                session: session,
                positionOptions: positionOptions,
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
                onSplitPanel: onSplitRoom,
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
class _RoomSection extends StatefulWidget {
  final Widget header;
  final List<Widget> children;
  const _RoomSection({required this.header, required this.children});

  @override
  State<_RoomSection> createState() => _RoomSectionState();
}

class _RoomSectionState extends State<_RoomSection> {
  /// 섹션마다 따로 — 데스크톱에서는 ListView가 PrimaryScrollController에 안 붙어서, 컨트롤러
  /// 없이 늘 보이는 스크롤바를 달면 디버그 모드에서 "ScrollPosition이 없다" 오류가 난다.
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.header,
        Expanded(
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: ListView(
              controller: _scroll,
              padding: EdgeInsets.zero,
              children: widget.children,
            ),
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

/// 방 목록 우클릭 메뉴 항목 — _RoomTileState._showContextMenu가 값으로 돌려받는다.
enum _RoomContextAction {
  split,
  startSecret,
  toggleMute,
  rename,
  markAllRead,
  hide,
  leave,
}

class _RoomTile extends StatefulWidget {
  final Room room;
  final Session session;
  final List<PositionOption>? positionOptions;
  final Widget leading;
  final String label;
  final bool selected;
  final int unreadCount;
  final bool favorite;
  final bool isSecret;
  final bool muted;
  final VoidCallback onToggleFavorite;
  final VoidCallback onTap;
  final ValueChanged<Room> onSplitPanel;
  const _RoomTile({
    required this.room,
    required this.session,
    required this.positionOptions,
    required this.leading,
    required this.label,
    required this.selected,
    this.unreadCount = 0,
    required this.favorite,
    this.isSecret = false,
    this.muted = false,
    required this.onToggleFavorite,
    required this.onTap,
    required this.onSplitPanel,
  });

  @override
  State<_RoomTile> createState() => _RoomTileState();
}

class _RoomTileState extends State<_RoomTile> {
  // 즐겨찾기 안 된 회색 별/숨기기·나가기 X는 평소엔 숨겨두고, 마우스가 이 행 위에 있을 때만
  // 보여준다(칸 자체는 Opacity로 항상 자리를 차지해서 hover 때 행 크기가 안 바뀌게 한다).
  bool _hovering = false;

  // showMenu가 뜨면(모달 배리어가 이 자리 전체를 덮어써서) 실제 마우스는 그대로 이 줄
  // 위에 있어도 MouseRegion/ListTile의 자동 hover 판정이 "떠났다"로 리셋돼버린다 — 그래서
  // 회색 표시(호버 배경)가 메뉴가 열려 있는 동안 사라지는 버그가 있었다. 메뉴가 열려 있는
  // 동안은 이 값을 직접 true로 유지해서, 실제 hover 판정과 무관하게 회색 배경을 그대로 둔다.
  bool _contextMenuOpen = false;

  bool get _isDm => widget.room.type == RoomType.dm;

  /// 우클릭(오른쪽 버튼) 메뉴 — Flutter 표준 레시피대로 탭다운 위치를 그대로 showMenu의
  /// 기준 사각형으로 넘긴다(이 코드베이스에 우클릭 메뉴 전례가 없어서 새로 만든 패턴).
  Future<void> _showContextMenu(Offset globalPosition) async {
    final room = widget.room;
    final session = widget.session;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    setState(() => _contextMenuOpen = true);
    final action = await showMenu<_RoomContextAction>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: _RoomContextAction.split,
          child: Text('대화창 분할하기'),
        ),
        // 이미 비밀 대화인 방에서 "또" 비밀대화를 시작하는 건 의미가 없고, 그룹/토픽은
        // 애초에 1:1이 아니라 비밀 대화 개념이 없다.
        if (_isDm && !room.isSecret)
          const PopupMenuItem(
            value: _RoomContextAction.startSecret,
            child: Text('비밀대화 시작하기'),
          ),
        PopupMenuItem(
          value: _RoomContextAction.toggleMute,
          child: Text(room.muted ? '대화방 알림 켜기' : '대화방 알림 끄기'),
        ),
        // 그룹채팅방만 — 나에게만 다른 이름으로 부르기(다른 멤버에겐 그대로).
        if (room.type == RoomType.group)
          PopupMenuItem(
            value: _RoomContextAction.rename,
            child: Text(renameRoomMenuLabel(room, session.userId ?? '')),
          ),
        const PopupMenuItem(
          value: _RoomContextAction.markAllRead,
          child: Text('모두 읽음 처리'),
        ),
        if (_isDm)
          const PopupMenuItem(
            value: _RoomContextAction.hide,
            child: Text('숨기기'),
          ),
        const PopupMenuItem(
          value: _RoomContextAction.leave,
          child: Text('나가기'),
        ),
      ],
    );
    if (mounted) setState(() => _contextMenuOpen = false);
    if (action == null || !mounted) return;
    switch (action) {
      case _RoomContextAction.split:
        widget.onSplitPanel(room);
      case _RoomContextAction.startSecret:
        final other = room.members
            .where((m) => m.id != session.userId)
            .firstOrNull;
        if (other == null) return;
        try {
          await session.startSecretChatInTeam(room.teamId, other.id);
        } catch (e) {
          if (mounted) {
            showAppToast(context, '비밀대화를 시작하지 못했습니다: $e');
          }
        }
      case _RoomContextAction.toggleMute:
        await session.toggleMuted(room);
      case _RoomContextAction.rename:
        await showRenameRoomForMeDialog(context, session, room);
      case _RoomContextAction.markAllRead:
        session.controllerFor(room).markReadNow();
        session.clearUnreadCount(room.id);
      case _RoomContextAction.hide:
        if (mounted) await showHideDmDialog(context, session, room);
      case _RoomContextAction.leave:
        if (mounted) await showLeaveRoomDialog(context, session, room);
    }
  }

  /// 방 목록 두번째 스크린샷의 호버 X — 1:1/그룹·토픽 모두 확인창을 먼저 띄운다(1:1은
  /// showHideDmDialog, 그룹/토픽은 멤버십 자체가 없어지는 showLeaveRoomDialog).
  Future<void> _onCloseX() async {
    if (_isDm) {
      await showHideDmDialog(context, widget.session, widget.room);
    } else {
      await showLeaveRoomDialog(context, widget.session, widget.room);
    }
  }

  @override
  Widget build(BuildContext context) {
    final otherMember = _isDm
        ? widget.room.members
              .where((m) => m.id != widget.session.userId)
              .firstOrNull
        : null;
    final showPositionBadge =
        otherMember != null &&
        hasLeadOrHigherPosition(widget.positionOptions, otherMember.position);
    // 실제 마우스 hover든, 우클릭 메뉴가 떠 있는 동안(_contextMenuOpen)이든 똑같이 "호버된
    // 것처럼" 보여준다 — 아래 tileColor/Opacity 전부 이 값 하나로 판단한다.
    final showHover = _hovering || _contextMenuOpen;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onSecondaryTapDown: (details) =>
            _showContextMenu(details.globalPosition),
        child: ListTile(
          dense: true,
          selected: widget.selected,
          selectedTileColor: Theme.of(
            context,
          ).colorScheme.primaryContainer.withValues(alpha: 0.4),
          // ListTile 자체의 자동 hover 배경 대신 이 값으로 직접 그린다 — showMenu가 뜨면
          // (모달 배리어가 이 자리를 덮어써서) 실제 마우스는 그대로 있어도 자동 hover 판정이
          // "떠났다"로 리셋되는 문제가 있어서(그래서 우클릭 메뉴를 열면 회색 표시가 바로
          // 사라졌었다), 자동 판정에 기대지 않고 showHover로 직접 통제한다.
          hoverColor: Colors.transparent,
          tileColor: showHover && !widget.selected
              ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08)
              : null,
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Opacity(
                opacity: widget.favorite || showHover ? 1 : 0,
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
              if (showPositionBadge) ...[
                const SizedBox(width: 6),
                PositionBadge(label: otherMember.position!),
              ],
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
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.unreadCount > 0) ...[
                UnreadBadge(count: widget.unreadCount),
                const SizedBox(width: 4),
              ],
              Opacity(
                opacity: showHover ? 1 : 0,
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    tooltip: _isDm ? '채팅방 숨기기' : '채팅방 나가기',
                    icon: const Icon(Icons.close),
                    onPressed: showHover ? _onCloseX : null,
                  ),
                ),
              ),
            ],
          ),
          onTap: widget.onTap,
        ),
      ),
    );
  }
}
