import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;

import '../models/app_user.dart';
import '../models/room.dart';
import '../services/api_client.dart' show PositionOption;
import '../services/chat_socket.dart' show RoomRemovedEvent;
import '../services/session.dart';
import '../services/time_format.dart';
import '../widgets/account_menu_button.dart';
import '../widgets/app_menu_button.dart';
import '../widgets/app_toast.dart';
import '../widgets/chat_font_scope.dart';
import '../widgets/my_avatar.dart';
import '../widgets/position_badge.dart';
import '../widgets/private_topic_lock.dart';
import '../widgets/room_avatar.dart';
import '../widgets/room_options_menu.dart'
    show renameRoomMenuLabel, showLeaveRoomDialog, showRenameRoomForMeDialog;
import '../widgets/muted_scrollbar.dart';
import '../widgets/notifications_panel.dart';
import '../widgets/team_switcher.dart';
import '../widgets/topic_folder_widgets.dart';
import '../widgets/team_name_badge.dart';
import '../widgets/outbox_strip.dart' show ConnectionLostBanner;
import '../widgets/unread_badge.dart';
import '../widgets/user_avatar.dart';
import 'admin_console_screen.dart';
import 'chat_screen.dart';
import 'create_topic_screen.dart';
import 'invite_link_screen.dart';
import 'member_profile_dialog.dart';
import 'my_profile_dialog.dart';
import 'new_group_dialog.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'start_chat_dialog.dart';
import 'topic_browse_screen.dart';
import '../l10n/tr.dart';

const _appVersion = '1.0.0';

/// 토픽 탭 [+] 버튼 시트의 항목.
enum _TopicFabAction { create, browse, folder }

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

  /// 1:1 채팅 목록에 직책 배지를 보여줄지 판단하는 기준(desktop_home_screen.dart와 동일).
  List<PositionOption>? _positionOptions;

  /// 토픽에서 내보내졌거나 토픽이 삭제됐다는 알림(session.roomRemovedEvents) 구독.
  StreamSubscription<RoomRemovedEvent>? _roomRemovedSub;

  /// 이 화면이 띄운 대화 화면(방 id와 라우트) — 그 방이 사라지면 목록으로 돌아오려고 기억해 둔다.
  final _chatRoutes = <({String roomId, Route<void> route})>[];

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
      tr('한 번 더 누르면 앱이 종료됩니다'),
      duration: const Duration(seconds: 3),
    );
  }

  @override
  void initState() {
    super.initState();
    _roomRemovedSub = widget.session.roomRemovedEvents.listen(_onRoomRemoved);
    widget.session.fetchPublicPositionOptions().then((list) {
      if (mounted) setState(() => _positionOptions = list);
    });
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
      if (matches.isNotEmpty) {
        final room = matches.first;
        _pendingReopenRoom = room;
        // 이 화면이 만들어지는 시점에 이미 열려 있는 방이 있으면, 그 방이 있는 탭에서
        // 시작한다 — 알림을 눌러 앱이 켜진 경로(main.dart의 _openRoomFromNotification)에서는
        // 채팅방이 먼저 열리고 이 화면이 그 아래에 뒤늦게 만들어지는데, 기본값(토픽 탭)
        // 그대로 두면 방에서 뒤로 나왔을 때 엉뚱한 탭이 보인다.
        _index = _tabIndexFor(room.type);
      }
    }
    if (_pendingReopenRoom != null) {
      final room = _pendingReopenRoom!;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        // 알림으로 켜진 경우엔 그 방의 ChatScreen이 이미 이 화면 위에 push돼 있다 — 그때
        // 여기서 또 열면 같은 방이 두 번 쌓여서, 방에서 뒤로가기를 눌러도 같은 방이 다시
        // 나온다. 우리 라우트가 이미 덮여 있으면(=위에 뭔가 떠 있으면) 다시 열지 않는다.
        // (넓은 화면에서 좁은 화면으로 넘어온 경우엔 HomeScreen이 먼저 스택을 루트까지
        // 걷어내므로 이 조건에 걸리지 않는다 — home_screen.dart의 didChangeMetrics 참고.)
        final route = ModalRoute.of(context);
        if (route != null && !route.isCurrent) {
          setState(() => _pendingReopenRoom = null);
          return;
        }
        await _pushChat(room);
        if (mounted) setState(() => _pendingReopenRoom = null);
      });
    }
  }

  @override
  void dispose() {
    _roomRemovedSub?.cancel();
    super.dispose();
  }

  /// 토픽에서 내보내졌거나 토픽이 삭제됐다 — 안내하고, 그 방 대화 화면을 이 화면이 띄워 둔
  /// 채면 목록으로 돌아온다. ChatScreen도 방이 사라지면 스스로 닫히지만, 한글 입력 중에는 세션
  /// 알림이 잠깐 미뤄질 수 있어서(typing_gate.dart) 여기서도 바로 닫는다.
  void _onRoomRemoved(RoomRemovedEvent event) {
    if (!mounted) return;
    showAppToast(context, event.toastText);
    final open = _chatRoutes.any(
      (e) => e.roomId == event.roomId && e.route.isActive,
    );
    if (open) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// 대화 화면을 띄우고, 닫힐 때까지 [_chatRoutes]에 기억해 둔다.
  Future<void> _pushChat(Room room, {String? highlightMessageId}) async {
    final route = MaterialPageRoute<void>(
      builder: (_) => ChatScreen(
        session: widget.session,
        room: room,
        highlightMessageId: highlightMessageId,
      ),
    );
    final entry = (roomId: room.id, route: route);
    _chatRoutes.add(entry);
    try {
      await Navigator.of(context).push(route);
    } finally {
      _chatRoutes.remove(entry);
    }
  }

  /// 방 종류 → 아래 NavigationBar 탭 번호(토픽 0 / 그룹채팅 1 / 대화 2).
  static int _tabIndexFor(RoomType type) => switch (type) {
    RoomType.topic => 0,
    RoomType.group => 1,
    RoomType.dm => 2,
  };

  /// 방을 연다 — "여러 팀 방 모아보기"로 보이는 다른 팀의 방이면 그 팀으로 먼저 바꾼다(Session.enterTeamOf —
  /// 멤버·파일·검색 등이 그 팀 기준이 되게). 화면은 바로 띄운다(팀을 바꿔 이 목록이 다시 그려져도 대화 화면은 그대로다).
  void _openRoom(Room room) {
    if (!mounted) return;
    widget.session.enterTeamOf(room);
    _pushChat(room);
  }

  /// 채팅 탭 맨 위 "나와의 대화" 줄 — 목록에 아직 없으면(방 목록을 받기 전 등) 서버에서 받아 연다.
  Future<void> _openSelfChat() async {
    final session = widget.session;
    final loaded = session.selfRoom;
    if (loaded != null) {
      _openRoom(loaded);
      return;
    }
    try {
      final room = await session.openSelfChat();
      _openRoom(room);
    } catch (e) {
      if (mounted) showAppToast(context, tr('나와의 대화를 열지 못했습니다: {e}', {'e': e}));
    }
  }

  /// 토픽 탭의 [+] — 새로운 토픽 생성하기 / 참여 가능한 토픽 보기 / 폴더 만들기를 아래 시트로
  /// 고른다. 준회원은 토픽을 만들거나 찾아 참여할 수 없지만(초대받은 방에서만 활동) 자기 목록을
  /// 정리하는 폴더는 누구나 만든다. 새 토픽 만들기는 팀 설정(토픽 생성 권한)에 따라 더 좁을 수 있다.
  Future<void> _showTopicActions() async {
    final session = widget.session;
    final action = await showModalBottomSheet<_TopicFabAction>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (session.canCreateRooms && session.canCreateTopic)
              ListTile(
                leading: const Icon(Icons.add_comment_outlined),
                title: Text(tr('새로운 토픽 생성하기')),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_TopicFabAction.create),
              ),
            if (session.canCreateRooms)
              ListTile(
                leading: const Icon(Icons.explore_outlined),
                title: Text(tr('참여 가능한 토픽 보기')),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_TopicFabAction.browse),
              ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: Text(tr('폴더 만들기')),
              onTap: () =>
                  Navigator.of(sheetContext).pop(_TopicFabAction.folder),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _TopicFabAction.create:
        await showCreateTopicFlow(context, session, onOpenRoom: _openRoom);
      case _TopicFabAction.browse:
        await showTopicBrowse(context, session, onOpenRoom: _openRoom);
      case _TopicFabAction.folder:
        await createTopicFolderFlow(context, session);
    }
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
        appBar: AppBar(
          title: TeamSwitcher(session: widget.session),
          actions: [
            NotificationBellButton(
              session: widget.session,
              onPressed: () =>
                  showNotificationsCenterDialog(context, widget.session),
            ),
            // 캘린더·파일·즐겨찾기·링크·프로젝트·문의함 …은 이 메뉴 안에 있다(menu_entries.dart).
            AppMenuButton(session: widget.session),
            AccountMenuButton(session: widget.session),
          ],
        ),
        body: IndexedStack(
          index: _index,
          children: [
            _RoomTypeTab(
              session: widget.session,
              type: RoomType.topic,
              emptyText: tr('토픽방이 없습니다.'),
              onOpenRoom: _openRoom,
            ),
            _RoomTypeTab(
              session: widget.session,
              type: RoomType.group,
              emptyText: tr('그룹채팅이 없습니다.'),
              onOpenRoom: _openRoom,
              showActivityTime: true,
            ),
            _RoomTypeTab(
              session: widget.session,
              type: RoomType.dm,
              emptyText: tr('대화가 없습니다.'),
              onOpenRoom: _openRoom,
              onOpenSelfChat: _openSelfChat,
              showActivityTime: true,
              positionOptions: _positionOptions,
            ),
            _MembersTab(session: widget.session, onOpenRoom: _openRoom),
            _MoreTab(session: widget.session),
          ],
        ),
        // 토픽 탭의 + 는 누구나(폴더 만들기는 준회원도 된다 — 시트 안에서 항목을 가린다).
        // 그룹채팅/채팅 탭의 + 는 준회원에게 감춘다 — 방을 만들 수 없어서(서버도 막지만,
        // 눌러봐야 실패하는 버튼을 보여주지 않는다).
        floatingActionButton: switch (_index) {
          0 => FloatingActionButton(
            tooltip: tr('토픽 추가'),
            onPressed: _showTopicActions,
            child: const Icon(Icons.add),
          ),
          1 when widget.session.canCreateRooms => FloatingActionButton(
            tooltip: tr('새 그룹채팅'),
            onPressed: () => showNewGroupDialog(
              context,
              widget.session,
              onOpenRoom: _openRoom,
            ),
            child: const Icon(Icons.add),
          ),
          2 when widget.session.canCreateRooms => FloatingActionButton(
            tooltip: tr('채팅 시작하기'),
            onPressed: () => showStartChatDialog(
              context,
              widget.session,
              onOpenRoom: _openRoom,
            ),
            child: const Icon(Icons.add),
          ),
          _ => null,
        },
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: [
            NavigationDestination(icon: Icon(Icons.tag), label: tr('토픽')),
            NavigationDestination(
              icon: Icon(Icons.groups_outlined),
              label: tr('그룹채팅'),
            ),
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              label: tr('채팅'),
            ),
            NavigationDestination(
              icon: Icon(Icons.people_outline),
              label: tr('멤버'),
            ),
            NavigationDestination(
              icon: Icon(Icons.more_horiz),
              label: tr('더보기'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 토픽/그룹채팅/채팅 탭 공통 몸통: 검색창(누르면 SearchScreen으로 이동) + 그 타입의
/// 방 목록. 즐겨찾기한 방을 위로 모으고, 그 안에서는 최근 활동 순으로 정렬한다(PC 사이드바와
/// 동일한 규칙 — Session._bumpRoomActivity 참고). 토픽 탭은 PC 사이드바처럼 내 폴더 →
/// 폴더 밖 토픽 → "보관된 토픽"으로 묶는다(폴더마다 같은 정렬 규칙). 채팅 탭은 맨 위에
/// "나와의 대화"가 늘 고정이다.
class _RoomTypeTab extends StatefulWidget {
  final Session session;
  final RoomType type;
  final String emptyText;
  final ValueChanged<Room> onOpenRoom;

  /// 채팅 탭의 "나와의 대화" 고정 줄 — 목록에 없으면 서버에서 받아서라도 연다. null이면 그 줄이 없다.
  final VoidCallback? onOpenSelfChat;
  final bool showActivityTime;
  final List<PositionOption>? positionOptions;
  const _RoomTypeTab({
    required this.session,
    required this.type,
    required this.emptyText,
    required this.onOpenRoom,
    this.onOpenSelfChat,
    this.showActivityTime = false,
    this.positionOptions,
  });

  @override
  State<_RoomTypeTab> createState() => _RoomTypeTabState();
}

class _RoomTypeTabState extends State<_RoomTypeTab> {
  // 5개 탭이 IndexedStack으로 전부 동시에 마운트돼 있다 보니, 컨트롤러 없이(Scrollbar가
  // 알아서 붙는 방식) 쓰면 안드로이드에서 스크롤바가 안 뜨는 경우가 있었다 — 탭마다 컨트롤러를
  // 직접 만들어서 ListView와 MutedScrollbar 양쪽에 명시적으로 물려준다.
  final _scrollController = ScrollController();

  /// 토픽 탭 맨 아래 "보관된 토픽" 묶음을 펼쳤는지 — 서버에 저장하지 않는 화면 상태(기본 접힘).
  bool _archivedExpanded = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 길게 누른 토픽의 "폴더로 이동" — 내 폴더 목록 시트에서 고르거나 새 폴더를 만들어 넣는다.
  /// 폴더 작업은 목록을 먼저 바꿔서 누른 줄이 곧 사라질 수 있으므로, 늘 떠 있는 이 탭의
  /// context로 시트·이름 입력 창·실패 토스트를 띄운다.
  Future<void> _pickFolderFor(Room room) async {
    final session = widget.session;
    final choice = await showTopicFolderPickerSheet(context, session, room);
    if (choice == null || !mounted) return;
    if (choice == kNewTopicFolderChoice) {
      await createTopicFolderFlow(context, session, moveIn: room);
    } else {
      await moveTopicToFolderFlow(context, session, room, choice);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ConnectionLostBanner(session: widget.session),
        _SearchBox(session: widget.session),
        Expanded(
          child: ListenableBuilder(
            // 환경설정의 "여러 팀 방 모아보기"를 바꾸면 목록도 바로 다시 그린다.
            listenable: Listenable.merge([
              widget.session,
              widget.session.settings,
            ]),
            builder: (context, _) {
              // 평문 DM 숨기기/나가기는 멤버십을 안 건드리고 내 hidden 플래그만 켠다
              // (room_options_menu.dart 참고) — session.rooms엔 그대로 남으므로 목록
              // 화면에서만 걸러낸다.
              // session.rooms에는 다른 팀 방까지 들어있으므로 지금 팀 것만 걸러내되, 환경설정 > 메신저 설정의
              // "여러 팀 방 모아보기"에서 켠 종류는 내가 속한 다른 팀의 방도 함께 보인다(Session.showsInRoomList).
              // 나와의 대화는 채팅 탭 맨 위 고정 줄로 따로 그린다(목록 정렬에서 뺀다).
              final rooms = widget.session.rooms
                  .where(
                    (r) =>
                        r.type == widget.type &&
                        widget.session.showsInRoomList(r) &&
                        !r.isSelf,
                  )
                  .toList();
              if (widget.type == RoomType.topic) {
                return _buildTopicList(context, rooms);
              }
              final sorted = favoriteFirst(rooms);
              final onOpenSelf = widget.onOpenSelfChat;
              final pinned = onOpenSelf == null ? 0 : 1;
              if (sorted.isEmpty && pinned == 0) return _buildEmpty(context);
              return MutedScrollbar(
                controller: _scrollController,
                child: ListView.builder(
                  controller: _scrollController,
                  itemCount: pinned + sorted.length,
                  itemBuilder: (context, i) {
                    if (i < pinned) return _buildSelfRow(onOpenSelf!);
                    final room = sorted[i - pinned];
                    return _RoomRow(
                      session: widget.session,
                      room: room,
                      onTap: () => widget.onOpenRoom(room),
                      showActivityTime: widget.showActivityTime,
                      positionOptions: widget.positionOptions,
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildEmpty(BuildContext context) => Center(
    child: Text(
      widget.emptyText,
      style: TextStyle(color: Theme.of(context).hintColor),
    ),
  );

  /// 채팅 탭 맨 위 "나와의 대화" — 방을 아직 못 받았으면(null) 이름만 있는 같은 모양의 줄을 그리고,
  /// 누르면 서버에서 받아 연다.
  Widget _buildSelfRow(VoidCallback onOpenSelf) {
    const key = ValueKey('self-room-row');
    final session = widget.session;
    final room = session.selfRoom;
    if (room == null) {
      return ListTile(
        key: key,
        leading: SelfRoomAvatar(session: session),
        title: Text(selfRoomName),
        onTap: onOpenSelf,
      );
    }
    return _RoomRow(
      key: key,
      session: session,
      room: room,
      onTap: () => widget.onOpenRoom(room),
      showActivityTime: widget.showActivityTime,
      pinnedSelf: true,
    );
  }

  /// 토픽 탭: 내 폴더(접기·⋯ 메뉴) → 폴더 밖 토픽 → "보관된 토픽". 폴더가 있으면 토픽이
  /// 하나도 없어도 빈 폴더를 보여준다.
  Widget _buildTopicList(BuildContext context, List<Room> topics) {
    final session = widget.session;
    final groups = groupTopics(topics, session.topicFolders);
    if (topics.isEmpty && groups.folders.isEmpty) return _buildEmpty(context);

    Widget row(Room room, {bool inFolder = false, bool archived = false}) =>
        _RoomRow(
          key: ValueKey('topic-row-${room.id}'),
          session: session,
          room: room,
          onTap: () => widget.onOpenRoom(room),
          showActivityTime: widget.showActivityTime,
          positionOptions: widget.positionOptions,
          indent: inFolder || archived,
          // 보관된 토픽은 "보관된 토픽"에만 보여서 폴더로 옮겨도 달라 보이는 게 없다. 모아보기로 보이는 다른 팀의
          // 토픽도 폴더(지금 팀의 것)에 넣고 빼지 않는다.
          folderActions: archived || room.teamId != session.currentTeam?.id
              ? null
              : _RowFolderActions(
                  inFolder: session.topicFolderOf(room.id) != null,
                  onPick: () => _pickFolderFor(room),
                  onRemove: () =>
                      moveTopicToFolderFlow(context, session, room, null),
                ),
        );

    return MutedScrollbar(
      controller: _scrollController,
      child: ListView(
        controller: _scrollController,
        // 오른쪽 아래 [+] 버튼이 마지막 줄을 가리지 않게.
        padding: const EdgeInsets.only(bottom: 88),
        children: [
          for (final group in groups.folders) ...[
            TopicFolderHeader(
              key: ValueKey('topic-folder-${group.folder.id}'),
              mobile: true,
              name: group.folder.name,
              count: group.rooms.length,
              unreadCount: group.unreadCount,
              collapsed: group.folder.collapsed,
              onToggle: () =>
                  toggleTopicFolderFlow(context, session, group.folder),
              onRename: () =>
                  renameTopicFolderFlow(context, session, group.folder),
              onDelete: () =>
                  deleteTopicFolderFlow(context, session, group.folder),
            ),
            TopicFolderBody(
              key: ValueKey('topic-folder-body-${group.folder.id}'),
              expanded: !group.folder.collapsed,
              children: [
                for (final room in group.rooms) row(room, inFolder: true),
              ],
            ),
          ],
          for (final room in groups.loose) row(room),
          if (groups.archived.isNotEmpty) ...[
            TopicFolderHeader(
              key: const ValueKey('topic-folder-archived'),
              mobile: true,
              archived: true,
              name: tr('보관된 토픽'),
              count: groups.archived.length,
              unreadCount: groups.archivedUnread,
              collapsed: !_archivedExpanded,
              onToggle: () =>
                  setState(() => _archivedExpanded = !_archivedExpanded),
            ),
            TopicFolderBody(
              key: const ValueKey('topic-folder-body-archived'),
              expanded: _archivedExpanded,
              children: [
                for (final room in groups.archived) row(room, archived: true),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 토픽 줄 길게 누르기 시트의 "폴더로 이동"/"폴더에서 빼기".
class _RowFolderActions {
  /// 지금 내 폴더 중 하나에 들어 있는지("폴더에서 빼기"를 보여줄지).
  final bool inFolder;
  final VoidCallback onPick;
  final VoidCallback onRemove;
  const _RowFolderActions({
    required this.inFolder,
    required this.onPick,
    required this.onRemove,
  });
}

/// 방 목록 한 줄 — 아바타 + 이름(비밀 대화는 자물쇠+초록색, 즐겨찾기는 이름 옆 노란 별) +
/// 안읽음 뱃지. 즐겨찾기/알림 끄기/나가기(토픽은 폴더로 이동도)는 길게 누르면 뜨는 하단
/// 시트로만 조작한다.
class _RoomRow extends StatelessWidget {
  final Session session;
  final Room room;
  final VoidCallback onTap;
  final bool showActivityTime;
  final List<PositionOption>? positionOptions;

  /// 폴더(또는 "보관된 토픽") 안의 토픽 — 머리글 아래로 들여 쓴다.
  final bool indent;

  /// 있으면 길게 누르기 시트에 "폴더로 이동"(과 폴더 안이면 "폴더에서 빼기")이 붙는다.
  final _RowFolderActions? folderActions;

  /// 채팅 탭 맨 위에 고정된 "나와의 대화" — 늘 맨 위라 즐겨찾기 표시가 없고, 길게 누르기 시트엔
  /// 알림 켜기/끄기만 있다(나가기·숨기기는 서버도 막는다).
  final bool pinnedSelf;

  const _RoomRow({
    super.key,
    required this.session,
    required this.room,
    required this.onTap,
    this.showActivityTime = false,
    this.positionOptions,
    this.indent = false,
    this.folderActions,
    this.pinnedSelf = false,
  });

  @override
  Widget build(BuildContext context) {
    final otherMember = room.type == RoomType.dm
        ? room.members.where((m) => m.id != session.userId).firstOrNull
        : null;
    final showPositionBadge =
        otherMember != null &&
        hasLeadOrHigherPosition(positionOptions, otherMember.position);
    return ListTile(
      contentPadding: indent
          ? const EdgeInsetsDirectional.only(start: 32, end: 24)
          : null,
      leading: pinnedSelf
          ? SelfRoomAvatar(session: session)
          : RoomAvatar(
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
            // 방 이름은 환경설정 > 화면 설정 > 글꼴을 따른다(chat_font_scope.dart).
            child: ChatFont(
              settings: session.settings,
              builder: (context, font) => Text(
                room.displayName(session.userId ?? ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: applyChatFont(
                  room.isSecret ? const TextStyle(color: Colors.green) : null,
                  font,
                ),
              ),
            ),
          ),
          if (room.isPrivateTopic) const PrivateTopicLock(),
          if (showPositionBadge) ...[
            const SizedBox(width: 6),
            PositionBadge(label: otherMember.position!),
          ],
          if (session.otherTeamNameOf(room) case final team?) ...[
            const SizedBox(width: 6),
            TeamNameBadge(name: team),
          ],
          if (room.favorite && !pinnedSelf) ...[
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
          if (session.chatDrafts.has(room.id)) ...[
            const SizedBox(width: 4),
            const DraftMarker(),
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
      if (room.unreadCount > 0 || room.unreadMentionCount > 0) ...[
        if (showActivityTime) const SizedBox(height: 4),
        // 안 읽은 멘션이 있으면 안읽음 숫자 옆에 "@"를 붙인다.
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (room.unreadMentionCount > 0) ...[
              const MentionMarker(),
              if (room.unreadCount > 0) const SizedBox(width: 4),
            ],
            if (room.unreadCount > 0) UnreadBadge(count: room.unreadCount),
          ],
        ),
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
    final folder = folderActions;
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
              title: Text(room.muted ? tr('알림 켜기') : tr('알림 끄기')),
              onTap: () {
                Navigator.of(sheetContext).pop();
                session.toggleMuted(room);
              },
            ),
            if (room.type == RoomType.group)
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: Text(renameRoomMenuLabel(room, session.userId ?? '')),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  showRenameRoomForMeDialog(context, session, room);
                },
              ),
            if (!pinnedSelf)
              ListTile(
                leading: Icon(
                  room.favorite ? Icons.star : Icons.star_border,
                  color: room.favorite ? Colors.amber : null,
                ),
                title: Text(room.favorite ? tr('즐겨찾기 해제') : tr('즐겨찾기')),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  session.toggleFavorite(room);
                },
              ),
            // 토픽만 — 내 토픽 폴더로 옮기거나 폴더에서 뺀다(PC 사이드바의 끌어다 놓기와 같다).
            if (folder != null) ...[
              ListTile(
                leading: const Icon(Icons.drive_file_move_outline),
                title: Text(tr('폴더로 이동')),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  folder.onPick();
                },
              ),
              if (folder.inFolder)
                ListTile(
                  leading: const Icon(Icons.folder_off_outlined),
                  title: Text(tr('폴더에서 빼기')),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    folder.onRemove();
                  },
                ),
            ],
            if (!pinnedSelf)
              ListTile(
                leading: const Icon(Icons.exit_to_app, color: Colors.redAccent),
                title: Text(
                  isDm && !room.isSecret ? tr('숨기기') : tr('나가기'),
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
                  tr('대화방, 메시지 검색'),
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
            decoration: InputDecoration(
              hintText: tr('멤버 검색'),
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
              ? Center(child: Text(tr('검색 결과가 없습니다.')))
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
            title: Text(tr('환경설정')),
            onTap: () => showDialog(
              context: context,
              builder: (_) => SettingsScreen(session: widget.session),
            ),
          ),
          // PC 삼선 메뉴와 동일한 조건 — 서버 운영자·계정 관리자·팀 소유자에게만 보인다.
          if (widget.session.canCreateInviteLink)
            ListTile(
              leading: const Icon(Icons.add_link),
              title: Text(tr('초대 링크 생성')),
              onTap: () => showInviteLinkScreen(context, widget.session),
            ),
          // 팀 초대 링크 생성은 팀 설정(팀 정보 탭)으로 옮겼다 — 이미 어느 팀인지 정해진
          // 곳에서 만드는 게 더 자연스러워서(team_settings_dialog.dart).
          // PC 삼선 메뉴와 동일하게, 서버 운영자에게만 보인다.
          if (widget.session.isServerAdmin)
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: Text(tr('서버 관리')),
              onTap: () => showAdminConsole(context, widget.session),
            ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: Text(tr('오픈소스 라이선스')),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'TangoTalk',
              applicationVersion: _appVersion,
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.redAccent),
            title: Text(tr('로그아웃'), style: TextStyle(color: Colors.redAccent)),
            onTap: () => _logout(context),
          ),
        ],
      ),
    );
  }
}
