import 'dart:async';
import 'package:flutter/material.dart';

import '../models/message.dart';
import '../models/room.dart';
import '../models/topic_folder.dart';
import '../services/api_client.dart' show PositionOption;
import '../services/chat_socket.dart' show RoomRemovedEvent;
import '../services/session.dart';
import '../widgets/compact_menu.dart';
import '../widgets/account_menu_button.dart';
import '../widgets/app_toast.dart';
import '../widgets/app_menu_button.dart';
import '../widgets/chat_font_scope.dart';
import '../widgets/chat_panel.dart';
import '../widgets/favorite_star.dart';
import '../widgets/notifications_panel.dart';
import '../widgets/position_badge.dart';
import '../widgets/private_topic_lock.dart';
import '../widgets/room_avatar.dart';
import '../widgets/room_options_menu.dart';
import '../widgets/side_panels.dart';
import '../widgets/team_avatar.dart';
import '../widgets/team_name_badge.dart';
import '../services/app_settings.dart' show TeamSwitchStyle;
import '../widgets/team_switcher.dart';
import '../widgets/topic_folder_widgets.dart';
import 'invite_rooms_dialog.dart' show showInviteToMultipleRooms;
import '../widgets/unread_badge.dart';
import 'calendar/calendar_screen.dart';
import 'create_topic_screen.dart';
import 'message_thread_screen.dart';
import 'new_group_dialog.dart';
import 'org_chart_screen.dart' show showOrgChartScreen;
import 'start_chat_dialog.dart';
import 'topic_browse_screen.dart';
import '../widgets/user_status_dialogs.dart';

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
  Room? _selectedRoomValue;

  /// 상단 "캘린더" 버튼으로 사이드바+채팅 자리를 캘린더로 바꿔 보고 있는지. 방을 고르면(어느 경로로든)
  /// 대화 화면으로 돌아오도록 [_selectedRoom]에 방을 넣을 때 같이 끈다.
  bool _calendarOpen = false;

  Room? get _selectedRoom => _selectedRoomValue;
  set _selectedRoom(Room? room) {
    _selectedRoomValue = room;
    if (room != null) _calendarOpen = false;
  }

  // "대화창 분할하기"(방 목록 우클릭 메뉴)로 연 두 번째 채팅 패널 — 오른쪽에 나란히 뜬다.
  // _selectedRoom과 같은 방이면 분할할 의미가 없으므로 _effectiveSplitRoom에서 걸러진다.
  Room? _splitRoom;

  /// 오른쪽에 열려 있는 패널의 키(side_panels.dart의 SidePanelSpec.key — 검색·파일·링크·즐겨찾기·알림 센터·멤버 …).
  /// 한 번에 하나만 열려서 다른 패널을 열면 교체되고, 댓글 스레드·대화창 분할과도 서로 자리를 비킨다. 없으면 null.
  /// 새 패널은 이 파일을 고치지 않고 side_panels.dart의 sidePanelSpecs에 등록한다.
  String? _panelKey;

  /// 방 헤더의 "파일 보기"/"링크 보기"/"멤버"로 연 패널이 가리키는 방. null이면(상단 메뉴로 연 경우) 파일·링크는 지금
  /// 보고 있는 방으로 시작하고 멤버는 팀 전체다. 패널은 [_panelGeneration]을 키로 써서, 이미 열려 있어도 다른 방에서
  /// 누르면 그 방으로 새로 시작한다.
  Room? _panelRoom;
  int _panelGeneration = 0;

  /// 열려 있는 패널이 맡긴 "닫기 전에 물어볼 것"(할 일 패널 안에서 쓰던 할 일)과 맡긴 쪽 — [HomeShellScope.setPanelLeaveGuard].
  PanelLeaveGuard? _leaveGuard;
  Object? _leaveGuardOwner;

  void _setPanelLeaveGuard(Object owner, PanelLeaveGuard? guard) {
    if (guard != null) {
      _leaveGuardOwner = owner;
      _leaveGuard = guard;
    } else if (identical(_leaveGuardOwner, owner)) {
      // 맡긴 쪽이 거둘 때만(먼저 사라진 패널이 새 패널의 것을 지우지 않게).
      _leaveGuardOwner = null;
      _leaveGuard = null;
    }
  }

  /// 열려 있는 패널을 밖에서 닫거나 바꾸는 [action] — 패널이 물어볼 게 있으면(할 일 패널 안에서 쓰던 할 일) 먼저 묻고
  /// [닫기]를 골랐을 때만 한다. 물어볼 게 없으면 바로(같은 프레임에) 한다. 패널 자신의 닫기(✕ — [_closePanel])는 그 패널이
  /// 이미 물었으니 여기를 거치지 않는다.
  void _leavePanelThen(VoidCallback action) {
    final guard = _panelKey == null ? null : _leaveGuard;
    if (guard == null || !guard.needsConfirm()) {
      action();
      return;
    }
    unawaited(
      guard.confirm().then((ok) {
        if (ok && mounted) action();
      }),
    );
  }

  /// [key] 패널을 연다(이미 열려 있는 패널은 새로 시작). 다른 오른쪽 패널과 댓글 스레드·분할 패널은 닫는다.
  void _showPanel(String key, {Room? room}) {
    _leavePanelThen(
      () => setState(() {
        _panelKey = key;
        _panelRoom = room;
        _panelGeneration++;
        _threadMessage = null;
        _threadRoom = null;
        _splitRoom = null;
      }),
    );
  }

  void _closePanel() => setState(() {
    _panelKey = null;
    _panelRoom = null;
  });

  /// 상단 버튼·메뉴 타일로 패널을 토글한다 — 열려 있으면 닫고, 아니면 연다. 단 방 헤더로 연 "참여 멤버" 패널이 열려 있을 때
  /// 상단 "팀 멤버"를 누르면 닫지 않고 팀 전체 멤버로 바꿔서 연다.
  void _togglePanel(String key) {
    final switchToTeam =
        key == 'members' && _panelKey == key && _panelRoom != null;
    if (_panelKey == key && !switchToTeam) {
      _leavePanelThen(_closePanel);
      return;
    }
    _showPanel(key);
  }

  /// 방 헤더의 "파일 보기"/"링크 보기" — 오른쪽 패널을 그 방으로 걸러서 연다.
  void _openRoomPanel(Room room, {required bool links}) =>
      _showPanel(links ? 'links' : 'files', room: room);

  /// 한 방의 것만 보는 패널(토픽 ⋯의 "공지" 등 — side_panels.dart의 `openSidePanel(..., room:)`)을 그 방으로 연다.
  /// 이미 그 방 것이 열려 있으면 닫고(토글), 다른 방 것이 열려 있으면 그 방으로 새로 시작한다.
  void _toggleRoomPanel(String key, Room room) {
    if (_panelKey == key && _panelRoom?.id == room.id) {
      _leavePanelThen(_closePanel);
      return;
    }
    _showPanel(key, room: room);
  }

  /// 방 헤더의 "멤버" — 그 방의 참여 멤버 패널을 연다. 이미 그 방 것이 열려 있으면 닫는다(토글).
  void _openRoomMembers(Room room) {
    if (_panelKey == 'members' && _panelRoom?.id == room.id) {
      _closePanel();
      return;
    }
    _showPanel('members', room: room);
  }

  /// 오른쪽 패널(검색 결과·링크의 "대화방에서 보기"·즐겨찾기 …)에서 방을 누르면 — 가운데 채팅 자리를 그 방으로 바꾼다
  /// ([messageId]가 있으면 그 메시지로 스크롤·강조). 다른 팀의 방이면 팀 전환부터 requestOpenRoom이 한다.
  void _openRoomFromPanel(Room room, {String? messageId}) {
    if (room.teamId != widget.session.currentTeam?.id) {
      widget.session.requestOpenRoom(room, messageId: messageId);
      return;
    }
    setState(() {
      _selectedRoom = room;
      _threadMessage = null;
      _threadRoom = null;
      _highlightMessageId = messageId;
    });
  }

  /// 캘린더 — 사이드바+채팅 자리를 캘린더로 바꾼다. 한 번 더 누르거나 방을 고르면 돌아온다.
  void _toggleCalendar() => setState(() {
    _calendarOpen = !_calendarOpen;
    if (_calendarOpen) {
      _threadMessage = null;
      _threadRoom = null;
      _splitRoom = null;
    }
  });

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

  /// 사이드바 맨 아래 "보관된 토픽" 묶음을 펼쳤는지 — 서버에 저장하지 않는 화면 상태(기본 접힘).
  /// 사이드바는 창 폭에 따라 다른 자리(나란히/겹침)에 다시 만들어지므로 여기 둔다.
  bool _archivedTopicsExpanded = false;

  /// 토픽에서 내보내졌거나 토픽이 삭제됐다는 알림(session.roomRemovedEvents) 구독.
  StreamSubscription<RoomRemovedEvent>? _roomRemovedSub;

  /// 방을 바꿀 때마다 쓴다 — 이전 방 메시지의 스레드 패널은 더 이상 의미가 없으므로 같이 닫는다.
  /// _highlightMessageId도 같이 지운다 — 검색 결과 클릭(onOpenRoom, 아래 참고)이 아닌 다른
  /// 경로로 방을 열 때 예전 검색 하이라이트가 남아있으면, 나중에(예: 알림을 눌러) 이 방을
  /// 다시 열 때 맨 아래 대신 그 옛 메시지 위치로 스크롤되는 문제가 있었다. 사이드바가 겹침
  /// 오버레이로 펼쳐진 채로 방을 골랐으면(좁은 창) 그 오버레이도 같이 접는다.
  /// 사이드바에서 방을 골랐을 때 — "여러 팀 방 모아보기"로 보이는 다른 팀의 방이면 그 팀으로 바꾸며 연다
  /// (Session.requestOpenRoom — 멤버·파일·검색 등이 그 팀 기준이 되게). 분할 패널로 열려 할 때도 같다.
  void _selectRoomFromList(Room room) {
    if (room.teamId != widget.session.currentTeam?.id) {
      widget.session.requestOpenRoom(room);
      return;
    }
    _selectRoom(room);
  }

  void _openSplitRoomFromList(Room room) {
    if (room.teamId != widget.session.currentTeam?.id) {
      widget.session.requestOpenRoom(room);
      return;
    }
    _openSplitRoom(room);
  }

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
  /// (같은 방을 두 번 그릴 이유가 없다). 오른쪽 패널(검색/멤버/파일/링크/즐겨찾기/알림 센터)과는 서로 자리를
  /// 다투므로(한 화면에 다 욱여넣으면 너무 좁아짐) 서로 배타적으로 만든다 —
  /// 분할 패널을 열면 오른쪽 패널을 닫고, 오른쪽 패널을 열면(_showPanel) 분할 패널을 닫는다.
  void _openSplitRoom(Room room) {
    if (room.id == _selectedRoom?.id) return;
    _leavePanelThen(
      () => setState(() {
        _splitRoom = room;
        _panelKey = null;
        _panelRoom = null;
        _threadMessage = null;
        _threadRoom = null;
      }),
    );
  }

  bool _isRoomGone(String roomId) => isRoomGoneFrom(widget.session, roomId);

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
    _roomRemovedSub = widget.session.roomRemovedEvents.listen(_onRoomRemoved);
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
      // 알림 센터에서 멘션을 눌러 온 경우 — 그 메시지로 스크롤·강조.
      _highlightMessageId = widget.session.consumePendingOpenMessageId();
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
    _roomRemovedSub?.cancel();
    super.dispose();
  }

  /// 토픽에서 내보내졌거나 토픽이 삭제됐다 — 안내하고, 그 방을 보고 있던 패널(메인·분할·댓글)을
  /// 비운다. Session이 방을 이미 목록에서 뺐으므로 _onSessionChanged도 같은 일을 하지만, 한글
  /// 입력 중에는 세션 알림이 잠깐 미뤄질 수 있어서(typing_gate.dart) 여기서도 바로 비운다.
  void _onRoomRemoved(RoomRemovedEvent event) {
    if (!mounted) return;
    showAppToast(context, event.toastText);
    final selected = _selectedRoom?.id == event.roomId;
    final split = _splitRoom?.id == event.roomId;
    final thread = _threadRoom?.id == event.roomId;
    if (!selected && !split && !thread) return;
    setState(() {
      if (selected) {
        _selectedRoom = null;
        _highlightMessageId = null;
      }
      if (split) _splitRoom = null;
      if (thread) {
        _threadMessage = null;
        _threadRoom = null;
      }
    });
  }

  void _onSessionChanged() {
    final pending = widget.session.consumePendingOpenRoom();
    if (pending != null) {
      _selectRoom(pending);
      final highlight = widget.session.consumePendingOpenMessageId();
      if (highlight != null) setState(() => _highlightMessageId = highlight);
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

  /// 사이드바 토픽 [+] > 새로운 토픽 생성하기 — 만들어지면 그 토픽을 연다(이어서 멤버 초대 창은
  /// showCreateTopicFlow가 띄운다).
  Future<void> _createTopic() async {
    await showCreateTopicFlow(
      context,
      widget.session,
      onOpenRoom: (room) {
        if (mounted) _selectRoom(room);
      },
    );
  }

  /// 사이드바 토픽 [+] > 참여 가능한 토픽 보기 — 참여하거나 이미 참여 중인 토픽을 열면 그 토픽을 연다.
  Future<void> _browseTopics() async {
    await showTopicBrowse(
      context,
      widget.session,
      onOpenRoom: (room) {
        if (mounted) _selectRoom(room);
      },
    );
  }

  /// 사이드바 그룹채팅 [+] > 새 그룹채팅 만들기 — 만들어지면 그 그룹채팅을 연다.
  Future<void> _newGroupChat() async {
    await showNewGroupDialog(
      context,
      widget.session,
      onOpenRoom: (room) {
        if (mounted) _selectRoom(room);
      },
    );
  }

  /// 사이드바 채팅 [+] > 채팅 시작하기 — 1:1·그룹채팅(또는 나와의 대화)을 열면 그 방을 연다.
  Future<void> _startChat() async {
    await showStartChatDialog(
      context,
      widget.session,
      onOpenRoom: (room) {
        if (mounted) _selectRoom(room);
      },
    );
  }

  /// 채팅 구역 맨 위 "나와의 대화" 줄 — 목록에 아직 없으면(방 목록을 받기 전 등) 서버에서 받아 연다.
  Future<void> _openSelfChat() async {
    final session = widget.session;
    final loaded = session.selfRoom;
    if (loaded != null) {
      _selectRoom(loaded);
      return;
    }
    try {
      final room = await session.openSelfChat();
      if (mounted) _selectRoom(room);
    } catch (e) {
      if (mounted) showAppToast(context, '나와의 대화를 열지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final panelSpec = _panelKey == null ? null : sidePanelSpecFor(_panelKey!);
    // 메뉴·패널이 홈 화면의 일(패널 열기, 캘린더 전환, 방 열기)을 부를 수 있게 손잡이를 내려 준다.
    return HomeShellScope(
      openPanelKey: _panelKey,
      panelRoom: _panelRoom,
      panelGeneration: _panelGeneration,
      currentRoomId: _selectedRoom?.id,
      togglePanel: _togglePanel,
      openRoomPanel: _toggleRoomPanel,
      closePanel: _closePanel,
      toggleCalendar: _toggleCalendar,
      openRoom: _openRoomFromPanel,
      setPanelLeaveGuard: _setPanelLeaveGuard,
      child: Scaffold(
        body: Column(
          children: [
            _TopBar(
              session: widget.session,
              onShowMembers: () => _togglePanel('members'),
              onToggleSearch: () => _togglePanel('search'),
              onToggleNotifications: () => _togglePanel('notifications'),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: _calendarOpen
                        ? CalendarScreen(
                            session: widget.session,
                            embedded: true,
                          )
                        : _buildSidebarAndChat(context),
                  ),
                  // 오른쪽 패널(검색·파일·링크·즐겨찾기·알림 센터·멤버 …) — 등록 목록은 side_panels.dart.
                  if (panelSpec != null) ...[
                    const VerticalDivider(width: 1),
                    SizedBox(
                      key: ValueKey('side-panel-${panelSpec.key}'),
                      width: _sidePanelWidth,
                      child: Builder(
                        builder: (panelContext) => buildSidePanel(
                          panelContext,
                          widget.session,
                          panelSpec,
                          _closePanel,
                        ),
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
      hostContext: context,
      selectedRoomId: _selectedRoom?.id,
      positionOptions: _positionOptions,
      onSelectRoom: _selectRoomFromList,
      onSplitRoom: _openSplitRoomFromList,
      onCreateTopic: _createTopic,
      onBrowseTopics: _browseTopics,
      onNewGroupChat: _newGroupChat,
      onStartChat: _startChat,
      onOpenSelfChat: _openSelfChat,
      archivedExpanded: _archivedTopicsExpanded,
      onToggleArchived: () =>
          setState(() => _archivedTopicsExpanded = !_archivedTopicsExpanded),
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
    return Column(
      children: [
        // 방 이름·읽기 전용·보관은 토픽 정보 변경/보관으로 바뀌어 Session이 이 방 객체에 그 자리에서
        // 반영한다(Room.mergeServerState) — 헤더가 세션 알림마다 다시 그려져야 바로 보인다.
        ListenableBuilder(
          listenable: widget.session,
          builder: (context, _) => _buildRoomHeader(
            context,
            room,
            isSplit: isSplit,
            onClose: onClose,
          ),
        ),
        Expanded(
          child: ChatPanel(
            key: ValueKey('${isSplit ? 'split' : 'main'}-${room.id}'),
            session: widget.session,
            room: room,
            highlightMessageId: isSplit ? null : _highlightMessageId,
            // 오른쪽 패널은 한 번에 하나만 — 댓글을 열면 열려 있던 다른 패널(파일 모아보기
            // 등)은 닫아서 자리를 넘겨준다(반대로 그 패널들을 열면 댓글이 닫힌다, _showPanel).
            // 할 일 패널 안에서 쓰던 할 일이 있으면 먼저 묻는다.
            onOpenThread: (m) => _leavePanelThen(
              () => setState(() {
                _threadMessage = m;
                _threadRoom = room;
                _panelKey = null;
                _panelRoom = null;
              }),
            ),
          ),
        ),
      ],
    );
  }

  /// 채팅 패널 위 방 헤더 — 즐겨찾기·아바타·이름(+1:1이면 직책)·삼점 메뉴. 토픽이면 이름 옆에
  /// 비공개 자물쇠와 상태 칩('보드 뷰'·'읽기 전용'·'보관됨')이 붙고, 설명이 있는 그룹채팅·토픽은
  /// 이름 아래에 설명 한 줄이 붙는다. 나와의 대화는 목록 맨 위에 늘 고정이라 즐겨찾기 별이 없고,
  /// 아바타는 '나' 꼬리표를 단 내 아바타다.
  Widget _buildRoomHeader(
    BuildContext context,
    Room room, {
    required bool isSplit,
    VoidCallback? onClose,
  }) {
    final otherMember = room.type == RoomType.dm
        ? room.members.where((m) => m.id != widget.session.userId).firstOrNull
        : null;
    final chips = topicStatusChips(room);
    final description = roomHeaderDescription(room);
    final nameRow = Row(
      children: [
        Flexible(
          flex: 3,
          child: Text(
            room.displayName(widget.session.userId ?? ''),
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: room.isSecret ? Colors.green : null,
            ),
          ),
        ),
        if (room.isPrivateTopic) const PrivateTopicLock(size: 16),
        // 칩은 한 줄로만 — 대화 칸이 좁으면(오른쪽 패널을 연 좁은 창 등) 안 들어가는 칩은
        // 다음 줄로 넘어가서 잘려 안 보인다(이름을 밀어내거나 넘치지 않게).
        if (chips.isNotEmpty)
          Flexible(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: ClipRect(
                child: SizedBox(
                  height: 20,
                  child: Wrap(spacing: 4, runSpacing: 4, children: chips),
                ),
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
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
          ),
        ],
        // 1:1 대화면 상대의 상태(이모지·글)와 방해 금지 달 — PC 헤더는 자리가 넉넉해 글까지 보인다.
        if (otherMember != null) ...[
          UserStatusBadge(session: widget.session, userId: otherMember.id),
          if (widget.session.statusOf(otherMember.id)?.text case final text?)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ),
            ),
        ],
      ],
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          if (!room.isSelf) ...[
            FavoriteStar(
              favorite: room.favorite,
              onTap: () => widget.session.toggleFavorite(room),
            ),
            const SizedBox(width: 8),
          ],
          if (room.isSelf)
            SelfRoomAvatar(session: widget.session)
          else
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
            child: description == null
                ? nameRow
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      nameRow,
                      const SizedBox(height: 2),
                      RoomDescriptionLine(description),
                    ],
                  ),
          ),
          if (isSplit)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '분할 닫기',
              onPressed: onClose,
            ),
          RoomOptionsMenu(
            session: widget.session,
            room: room,
            onOpenFiles: (r) => _openRoomPanel(r, links: false),
            onOpenLinks: (r) => _openRoomPanel(r, links: true),
            onOpenAlbums: (r) => _showPanel('albums', room: r),
            onOpenMembers: _openRoomMembers,
          ),
        ],
      ),
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

/// 창 전체 폭을 가로지르는 최상단 바: 팀 전환(좌) + 알림/멤버/검색/메뉴(격자)/계정 메뉴(우측 끝).
class _TopBar extends StatelessWidget {
  final Session session;
  final VoidCallback onShowMembers;
  final VoidCallback onToggleSearch;
  final VoidCallback onToggleNotifications;
  const _TopBar({
    required this.session,
    required this.onShowMembers,
    required this.onToggleSearch,
    required this.onToggleNotifications,
  });

  @override
  Widget build(BuildContext context) {
    // 환경설정 "팀 전환 방식" — 드롭다운(기본)이거나 팀을 전부 보여주는 탭. 계정 등급이 바뀌면 조직도 버튼도 다시 본다.
    return ListenableBuilder(
      listenable: Listenable.merge([session.settings, session]),
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
                    // 서버 전체 팀/회원 구조를 보는 기능이라 볼 수 있는 등급(계정 관리자·서버 운영자 —
                    // session.canViewOrgChart, 서버의 GET /org-chart/teams와 같은 규칙)에게만 보인다.
                    if (session.canViewOrgChart) ...[
                      // 이름은 글자 대신 마우스를 올렸을 때의 안내(툴팁)로만 보인다.
                      IconButton(
                        key: const ValueKey('topbar-org-chart'),
                        tooltip: '조직도',
                        icon: const Icon(Icons.account_tree_outlined),
                        onPressed: () => showOrgChartScreen(context, session),
                      ),
                      const SizedBox(
                        height: 20,
                        child: VerticalDivider(width: 17, thickness: 1),
                      ),
                    ],
                    NotificationBellButton(
                      session: session,
                      onPressed: onToggleNotifications,
                    ),
                    IconButton(
                      icon: const Icon(Icons.people_outline),
                      tooltip: '팀 멤버',
                      onPressed: onShowMembers,
                    ),
                    IconButton(
                      icon: const Icon(Icons.search),
                      tooltip: '검색',
                      onPressed: onToggleSearch,
                    ),
                    // 파일·즐겨찾기·링크·캘린더·프로젝트·문의함 …은 이 메뉴 안에 있다(menu_entries.dart).
                    AppMenuButton(session: session),
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

class _Sidebar extends StatelessWidget {
  final Session session;

  /// 폴더 작업(이름 입력 창·실패 토스트)을 띄울 바깥 화면(DesktopHomeScreen)의 context. 좁은 창의
  /// 겹침 사이드바는 방을 고르면 닫혀서, 서버 응답을 기다리는 사이 사라질 수 있다 — 늘 떠 있는
  /// 화면 쪽에서 띄운다.
  final BuildContext hostContext;
  final String? selectedRoomId;
  final List<PositionOption>? positionOptions;
  final ValueChanged<Room> onSelectRoom;
  final ValueChanged<Room> onSplitRoom;
  final VoidCallback onCreateTopic;
  final VoidCallback onBrowseTopics;
  final VoidCallback onNewGroupChat;
  final VoidCallback onStartChat;

  /// 채팅 구역 맨 위 "나와의 대화" 줄 — 목록에 없으면 서버에서 받아서라도 연다.
  final VoidCallback onOpenSelfChat;

  /// 맨 아래 "보관된 토픽" 묶음을 펼쳤는지(서버에 저장하지 않는 화면 상태, 기본 접힘).
  final bool archivedExpanded;
  final VoidCallback onToggleArchived;

  const _Sidebar({
    required this.session,
    required this.hostContext,
    required this.selectedRoomId,
    required this.positionOptions,
    required this.onSelectRoom,
    required this.onSplitRoom,
    required this.onCreateTopic,
    required this.onBrowseTopics,
    required this.onNewGroupChat,
    required this.onStartChat,
    required this.onOpenSelfChat,
    required this.archivedExpanded,
    required this.onToggleArchived,
  });

  PopupMenuItem<void> _plusItem(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) => CompactMenu.item<void>(context, icon: icon, label: label, onTap: onTap);

  /// 토픽 줄 하나. [inFolder]면 폴더(또는 "보관된 토픽") 아래로 들여 쓴다. 보관된 토픽은 그
  /// 묶음에만 보여서 폴더로 옮겨도 달라 보이는 게 없으므로 끌기·폴더 메뉴를 뺀다.
  Widget _topicTile(Room room, {bool inFolder = false, bool archived = false}) {
    // 모아보기로 보이는 다른 팀의 토픽 — 폴더는 지금 팀의 것이라 그 토픽을 넣고 빼지 않는다.
    final otherTeam = room.teamId != session.currentTeam?.id;
    return _RoomTile(
      key: ValueKey('topic-row-${room.id}'),
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
      indent: inFolder || archived,
      draggable: !archived && !otherTeam,
      folderMenu: archived || otherTeam
          ? null
          : _TopicFolderMenu(
              folders: session.topicFolders,
              currentFolderId: session.topicFolderOf(room.id)?.id,
              onMove: (folderId) =>
                  moveTopicToFolderFlow(hostContext, session, room, folderId),
              onNewFolder: () =>
                  createTopicFolderFlow(hostContext, session, moveIn: room),
            ),
      onToggleFavorite: () => session.toggleFavorite(room),
      onTap: () => onSelectRoom(room),
      onSplitPanel: onSplitRoom,
    );
  }

  /// 채팅 구역 맨 위에 고정된 "나와의 대화" 줄 — 즐겨찾기 별·숨기기 ✕ 없이 늘 이 자리다. 방을
  /// 아직 못 받았으면(null) 같은 모양의 자리만 그리고, 누르면 서버에서 받아 연다.
  Widget _selfRoomTile(Room? room) {
    const key = ValueKey('self-room-row');
    final avatar = SelfRoomAvatar(session: session);
    if (room == null) {
      return ListTile(
        key: key,
        dense: true,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          // 다른 줄의 즐겨찾기 별 자리만큼 비워서 아바타 줄을 맞춘다.
          children: [const SizedBox(width: 28), avatar],
        ),
        title: const Text(
          selfRoomName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: onOpenSelfChat,
      );
    }
    return _RoomTile(
      key: key,
      room: room,
      session: session,
      positionOptions: positionOptions,
      leading: avatar,
      label: room.displayName(session.userId ?? ''),
      selected: room.id == selectedRoomId,
      unreadCount: room.unreadCount,
      favorite: false,
      muted: room.muted,
      pinnedSelf: true,
      onToggleFavorite: () {},
      onTap: () => onSelectRoom(room),
      onSplitPanel: onSplitRoom,
    );
  }

  /// 토픽 구역: 내 폴더(순서대로, 안의 토픽은 들여 씀) → 폴더 밖 토픽 → 맨 아래 "보관된 토픽".
  List<Widget> _topicChildren(TopicGroups groups) => [
    for (final group in groups.folders) ...[
      _SidebarFolderHeader(
        key: ValueKey('topic-folder-${group.folder.id}'),
        session: session,
        hostContext: hostContext,
        group: group,
      ),
      TopicFolderBody(
        key: ValueKey('topic-folder-body-${group.folder.id}'),
        expanded: !group.folder.collapsed,
        children: [
          for (final room in group.rooms) _topicTile(room, inFolder: true),
        ],
      ),
    ],
    for (final room in groups.loose) _topicTile(room),
    // 보관된 토픽은 폴더 모양의 묶음 하나에만 보인다(끌어다 놓을 자리는 아니다).
    if (groups.archived.isNotEmpty) ...[
      TopicFolderHeader(
        key: const ValueKey('topic-folder-archived'),
        name: '보관된 토픽',
        count: groups.archived.length,
        unreadCount: groups.archivedUnread,
        collapsed: !archivedExpanded,
        archived: true,
        onToggle: onToggleArchived,
      ),
      TopicFolderBody(
        key: const ValueKey('topic-folder-body-archived'),
        expanded: archivedExpanded,
        children: [
          for (final room in groups.archived) _topicTile(room, archived: true),
        ],
      ),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // 환경설정의 "여러 팀 방 모아보기"를 바꾸면 목록도 바로 다시 그린다.
      listenable: Listenable.merge([session, session.settings]),
      builder: (context, _) {
        // 평문 DM의 "채팅방 숨기기"/"채팅방 나가기"는 멤버십을 안 건드리고 내 hidden
        // 플래그만 켠다(room_options_menu.dart 참고) — 그래서 session.rooms에는 그대로
        // 남아있고, 여기(목록 UI)에서만 걸러낸다. 상대가 새 메시지를 보내면 서버가 자동으로
        // hidden을 다시 꺼줘서 이 필터를 통과해 목록에 돌아온다.
        // session.rooms에는 다른 팀 방까지 전부 들어있다(다른 팀 메시지도 실시간으로 받아야
        // 하므로 — Session.rooms 주석 참고). 화면에는 지금 보고 있는 팀 것만 보여주되, 환경설정 > 메신저 설정의
        // "여러 팀 방 모아보기"에서 켠 종류는 내가 속한 다른 팀의 방도 함께 보인다(팀 이름이 붙는다).
        bool visible(Room r) => session.showsInRoomList(r);
        // 즐겨찾기한 방을 묶음 위쪽에 모으고, 그 안에서는 최근 활동(채팅/댓글을 보냈거나 받음,
        // Room.lastActivityAt) 순이다 — 채팅 중이거나 알림이 온 방이 자기 묶음의 맨 위로 올라온다
        // (Session._bumpRoomActivity 참고). 토픽은 폴더마다 같은 규칙으로 따로 정렬한다.
        final topics = session.rooms
            .where((r) => r.type == RoomType.topic && visible(r))
            .toList();
        final topicGroups = groupTopics(topics, session.topicFolders);
        final groups = favoriteFirst(
          session.rooms.where((r) => r.type == RoomType.group && visible(r)),
        );
        // 나와의 대화는 채팅 구역 맨 위 고정 줄로 따로 그린다(목록 정렬·"채팅 N" 수에서 뺀다).
        final dms = favoriteFirst(
          session.rooms.where(
            (r) => r.type == RoomType.dm && !r.isSelf && visible(r),
          ),
        );
        final selfRoom = session.selfRoom;
        // 머리글의 토픽 수·안 읽은 수는 폴더 안·보관된 토픽까지 전부 센다.
        final topicsUnread = topics.fold<int>(
          0,
          (sum, r) => sum + r.unreadCount,
        );
        final groupsUnread = groups.fold<int>(
          0,
          (sum, r) => sum + r.unreadCount,
        );
        // 안 읽은 수는 구역에 보이는 줄 전부(나와의 대화의 봇 안내 포함)를 센다.
        final dmsUnread = dms.fold<int>(
          selfRoom?.unreadCount ?? 0,
          (sum, r) => sum + r.unreadCount,
        );

        // 세 섹션 사이 구분선을 사용자가 드래그해서 각자 몫을 조절할 수 있게 한다.
        // 기본은 1/3씩이고, 자기 영역 안에서만 스크롤되며 목록이 영역보다 길면
        // 스크롤바를 항상 보여준다.
        return _ResizableRoomSections(
          // '토픽' 머리글 — 폴더 안의 토픽을 여기로 끌어다 놓으면 폴더에서 빠진다.
          topicsHeader: DragTarget<Room>(
            onWillAcceptWithDetails: (d) =>
                session.topicFolderOf(d.data.id) != null,
            onAcceptWithDetails: (d) =>
                moveTopicToFolderFlow(hostContext, session, d.data, null),
            builder: (context, candidates, _) => TopicDropHighlight(
              active: candidates.isNotEmpty,
              child: _SectionHeader(
                title: '토픽 ${topics.length}',
                badgeCount: topicsUnread,
                action: PopupMenuButton<void>(
                  icon: const Icon(Icons.add, size: 20),
                  tooltip: '토픽 추가',
                  // 채팅 목록 우클릭 메뉴와 같은 간결한 모양.
                  color: CompactMenu.color(context),
                  shape: CompactMenu.shape,
                  menuPadding: CompactMenu.menuPadding,
                  constraints: CompactMenu.constraints,
                  itemBuilder: (context) => [
                    // 준회원은 토픽을 만들거나 찾아 참여할 수 없다 — 초대받은 방에서만 활동한다.
                    // 새 토픽 만들기는 팀 설정(토픽 생성 권한)에 따라 정회원 이상/관리자 이상/
                    // 소유자만일 수 있고, 참여 가능한 토픽 보기(이미 있는 공개 토픽 참여)는 이
                    // 설정과 무관하게 정회원이면 늘 된다. 폴더(내 목록 정리)는 누구나 만든다.
                    if (session.canCreateRooms && session.canCreateTopic)
                      _plusItem(
                        context,
                        Icons.add_comment_outlined,
                        '새로운 토픽 생성하기',
                        onCreateTopic,
                      ),
                    if (session.canCreateRooms) ...[
                      _plusItem(
                        context,
                        Icons.explore_outlined,
                        '참여 가능한 토픽 보기',
                        onBrowseTopics,
                      ),
                      // 멤버 여러 명을 내가 참여 중인 토픽·그룹채팅 여러 곳에 한 번에 초대한다(PC 전용 — 이 사이드바는 PC뿐).
                      _plusItem(
                        context,
                        Icons.group_add_outlined,
                        '여러 토픽/그룹채팅에 초대',
                        () => showInviteToMultipleRooms(hostContext, session),
                      ),
                      CompactMenu.divider,
                    ],
                    _plusItem(
                      context,
                      Icons.create_new_folder_outlined,
                      '폴더 생성',
                      () => createTopicFolderFlow(hostContext, session),
                    ),
                  ],
                ),
              ),
            ),
          ),
          topicsChildren: _topicChildren(topicGroups),
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
                    tooltip: '채팅 시작하기',
                    onPressed: onStartChat,
                  ),
          ),
          dmsChildren: [
            _selfRoomTile(selfRoom),
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

/// 사이드바의 폴더 머리글 — 모양·접기·⋯ 메뉴는 [TopicFolderHeader]. 여기서는 마우스 끌어다
/// 놓기를 붙인다: 토픽 줄을 놓으면 이 폴더로 들어오고, 다른 폴더 머리글을 놓으면 그 폴더가 이
/// 자리로 온다(순서 변경). 머리글 자체도 끌 수 있다.
class _SidebarFolderHeader extends StatefulWidget {
  final Session session;
  final BuildContext hostContext;
  final TopicFolderGroup group;
  const _SidebarFolderHeader({
    super.key,
    required this.session,
    required this.hostContext,
    required this.group,
  });

  @override
  State<_SidebarFolderHeader> createState() => _SidebarFolderHeaderState();
}

class _SidebarFolderHeaderState extends State<_SidebarFolderHeader> {
  /// 이 머리글을 끄는 중 — 제자리는 흐리게 남긴다.
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final host = widget.hostContext;
    final group = widget.group;
    final folder = group.folder;
    return DragTarget<TopicFolder>(
      onWillAcceptWithDetails: (d) => d.data.id != folder.id,
      onAcceptWithDetails: (d) => reorderTopicFolderFlow(
        host,
        session,
        draggedId: d.data.id,
        targetId: folder.id,
      ),
      builder: (context, folderCandidates, _) => DragTarget<Room>(
        // 이미 이 폴더에 든 토픽은 받지 않는다(다시 놓아도 아무 요청이 없다).
        onWillAcceptWithDetails: (d) =>
            session.topicFolderOf(d.data.id)?.id != folder.id,
        onAcceptWithDetails: (d) =>
            moveTopicToFolderFlow(host, session, d.data, folder.id),
        builder: (context, roomCandidates, _) =>
            TopicMouseDraggable<TopicFolder>(
              data: folder,
              dragAnchorStrategy: topicDragAnchor,
              feedback: TopicDragFeedback(
                icon: Icons.folder_outlined,
                label: folder.name,
              ),
              onDragStarted: () => setState(() => _dragging = true),
              onDragEnd: (_) {
                if (mounted) setState(() => _dragging = false);
              },
              child: Opacity(
                opacity: _dragging ? 0.4 : 1,
                child: TopicFolderHeader(
                  name: folder.name,
                  count: group.rooms.length,
                  unreadCount: group.unreadCount,
                  collapsed: folder.collapsed,
                  dropActive:
                      folderCandidates.isNotEmpty || roomCandidates.isNotEmpty,
                  onToggle: () => toggleTopicFolderFlow(host, session, folder),
                  onRename: () => renameTopicFolderFlow(host, session, folder),
                  onDelete: () => deleteTopicFolderFlow(host, session, folder),
                ),
              ),
            ),
      ),
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
  moveToFolder,
  removeFromFolder,
  hide,
  leave,
}

/// 폴더 안 토픽 줄을 폴더 머리글보다 이만큼 더 들여 쓴다.
const _kFolderIndent = 14.0;

/// 토픽 줄 우클릭 메뉴의 "폴더로 이동"/"폴더에서 빼기"에 필요한 것 — 내 폴더들, 이 토픽이 든
/// 폴더(없으면 null), 옮기기(null이면 빼기)와 새 폴더 만들어 넣기.
class _TopicFolderMenu {
  final List<TopicFolder> folders;
  final String? currentFolderId;
  final Future<void> Function(String? folderId) onMove;
  final Future<void> Function() onNewFolder;
  const _TopicFolderMenu({
    required this.folders,
    required this.currentFolderId,
    required this.onMove,
    required this.onNewFolder,
  });
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

  /// 폴더(또는 "보관된 토픽") 안의 토픽 — 머리글 아래로 들여 쓴다.
  final bool indent;

  /// 마우스로 끌어서 폴더 머리글(넣기)이나 '토픽' 머리글(빼기)에 놓을 수 있는 토픽 줄.
  final bool draggable;

  /// 있으면 우클릭 메뉴에 "폴더로 이동"(과 폴더 안이면 "폴더에서 빼기")이 붙는다.
  final _TopicFolderMenu? folderMenu;

  /// 채팅 구역 맨 위에 고정된 "나와의 대화" 줄 — 즐겨찾기 별·숨기기 ✕가 없고, 우클릭 메뉴에도
  /// 비밀대화·숨기기·나가기가 없다(서버도 막는다). 다른 줄과 정렬은 맞도록 그 자리는 비워 둔다.
  final bool pinnedSelf;

  const _RoomTile({
    super.key,
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
    this.indent = false,
    this.draggable = false,
    this.folderMenu,
    this.pinnedSelf = false,
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

  /// 이 줄을 마우스로 끄는 중 — 제자리는 흐리게 남긴다.
  bool _dragging = false;

  bool get _isDm => widget.room.type == RoomType.dm;

  /// 우클릭 메뉴 팝업 모양(밝은 테마는 흰 바탕, 어두운 테마는 앱 공통 팝업 색 — main.dart
  /// popupMenuTheme). "폴더로 이동"의 하위 메뉴도 같은 모양으로 띄운다.
  Color? get _menuColor =>
      Theme.of(context).brightness == Brightness.light ? Colors.white : null;

  /// 우클릭 메뉴의 "폴더로 이동 ▸"을 누르면 그 항목([anchor], 오버레이 좌표) 바로 오른쪽에 띄우는
  /// 하위 메뉴 — 내 폴더들(지금 든 폴더는 체크 표시·비활성)과 "새 폴더…". 고른 폴더 id,
  /// "새 폴더…"면 [kNewTopicFolderChoice], 닫으면 null.
  Future<String?> _showFolderSubmenu(
    BuildContext itemContext,
    Rect anchor,
    _TopicFolderMenu menu,
  ) {
    final overlay =
        Overlay.of(itemContext).context.findRenderObject() as RenderBox;
    final hint = Theme.of(context).hintColor;
    PopupMenuItem<String> entry(
      String value,
      IconData icon,
      String label, {
      bool enabled = true,
    }) => PopupMenuItem(
      value: value,
      enabled: enabled,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Icon(icon, size: 16, color: hint),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
    return showMenu<String>(
      context: itemContext,
      // 메뉴 안쪽 여백(6)만큼 올려서 첫 항목이 "폴더로 이동"과 같은 줄에 서게 한다.
      position: RelativeRect.fromRect(
        Rect.fromLTWH(anchor.right, anchor.top - 6, 0, anchor.height),
        Offset.zero & overlay.size,
      ),
      color: _menuColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      constraints: const BoxConstraints(minWidth: 160, maxWidth: 260),
      items: [
        for (final f in menu.folders)
          entry(
            f.id,
            f.id == menu.currentFolderId ? Icons.check : Icons.folder_outlined,
            f.name,
            enabled: f.id != menu.currentFolderId,
          ),
        if (menu.folders.isNotEmpty) const PopupMenuDivider(height: 9),
        entry(kNewTopicFolderChoice, Icons.create_new_folder_outlined, '새 폴더…'),
      ],
    );
  }

  /// 우클릭(오른쪽 버튼) 메뉴 — Flutter 표준 레시피대로 탭다운 위치를 그대로 showMenu의
  /// 기준 사각형으로 넘긴다(이 코드베이스에 우클릭 메뉴 전례가 없어서 새로 만든 패턴).
  Future<void> _showContextMenu(Offset globalPosition) async {
    final room = widget.room;
    final session = widget.session;
    final folderMenu = widget.folderMenu;
    final pinnedSelf = widget.pinnedSelf;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    setState(() => _contextMenuOpen = true);
    // 작은 글씨·좁은 줄 간격의 간결한 메뉴 — 항목 종류(열기 / 이 방 설정 / 폴더 / 떠나기)마다
    // 구분선.
    PopupMenuItem<_RoomContextAction> item(
      _RoomContextAction value,
      String label,
    ) => PopupMenuItem(
      value: value,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text(label, style: const TextStyle(fontSize: 13)),
    );
    const divider = PopupMenuDivider(height: 9);
    // "폴더로 이동"의 하위 메뉴에서 고른 것(폴더 id 또는 새 폴더).
    String? folderChoice;
    final action = await showMenu<_RoomContextAction>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      color: _menuColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 280),
      items: [
        item(_RoomContextAction.split, '대화창 분할하기'),
        // 이미 비밀 대화인 방에서 "또" 비밀대화를 시작하는 건 의미가 없고, 그룹/토픽은
        // 애초에 1:1이 아니라 비밀 대화 개념이 없다(나와의 대화는 상대가 없다).
        if (_isDm && !room.isSecret && !pinnedSelf)
          item(_RoomContextAction.startSecret, '비밀대화 시작하기'),
        divider,
        item(
          _RoomContextAction.toggleMute,
          room.muted ? '대화방 알림 켜기' : '대화방 알림 끄기',
        ),
        // 그룹채팅방만 — 나에게만 다른 이름으로 부르기(다른 멤버에겐 그대로).
        if (room.type == RoomType.group)
          item(
            _RoomContextAction.rename,
            renameRoomMenuLabel(room, session.userId ?? ''),
          ),
        item(_RoomContextAction.markAllRead, '모두 읽음 처리'),
        // 토픽만 — 내 토픽 폴더로 옮기거나 폴더에서 뺀다(끌어다 놓기와 같다).
        if (folderMenu != null) ...[
          divider,
          _SubmenuItem(
            value: _RoomContextAction.moveToFolder,
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            openSubmenu: (itemContext, anchor) async {
              folderChoice = await _showFolderSubmenu(
                itemContext,
                anchor,
                folderMenu,
              );
              return folderChoice != null;
            },
            child: Row(
              children: [
                const Expanded(
                  child: Text('폴더로 이동', style: TextStyle(fontSize: 13)),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 16,
                  color: Theme.of(context).hintColor,
                ),
              ],
            ),
          ),
          if (folderMenu.currentFolderId != null)
            item(_RoomContextAction.removeFromFolder, '폴더에서 빼기'),
        ],
        if (!pinnedSelf) ...[
          divider,
          if (_isDm) item(_RoomContextAction.hide, '숨기기'),
          item(_RoomContextAction.leave, '나가기'),
        ],
      ],
    );
    if (mounted) setState(() => _contextMenuOpen = false);
    // 폴더 작업은 이 줄이 목록에서 자리를 옮기며 사라져도 끝까지 가야 한다(토스트는 바깥
    // 화면이 띄운다) — mounted 검사보다 먼저 처리한다.
    if (action == _RoomContextAction.moveToFolder && folderMenu != null) {
      final choice = folderChoice;
      if (choice == kNewTopicFolderChoice) {
        await folderMenu.onNewFolder();
      } else if (choice != null) {
        await folderMenu.onMove(choice);
      }
      return;
    }
    if (action == _RoomContextAction.removeFromFolder && folderMenu != null) {
      await folderMenu.onMove(null);
      return;
    }
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
      // 폴더 항목은 위에서 먼저 처리했다.
      case _RoomContextAction.moveToFolder:
      case _RoomContextAction.removeFromFolder:
        return;
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
    final tile = MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onSecondaryTapDown: (details) =>
            _showContextMenu(details.globalPosition),
        child: ListTile(
          dense: true,
          // 폴더 안의 토픽은 머리글 아래로 들여 쓴다(오른쪽 여백은 ListTile 기본값 그대로).
          contentPadding: widget.indent
              ? const EdgeInsetsDirectional.only(
                  start: 16 + _kFolderIndent,
                  end: 24,
                )
              : null,
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
              if (widget.pinnedSelf)
                const SizedBox(width: 20)
              else
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
                // 방 이름은 환경설정 > 화면 설정 > 글꼴을 따른다(chat_font_scope.dart).
                child: ChatFont(
                  settings: widget.session.settings,
                  builder: (context, font) => Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: applyChatFont(
                      widget.isSecret
                          ? const TextStyle(color: Colors.green)
                          : null,
                      font,
                    ),
                  ),
                ),
              ),
              if (widget.room.isPrivateTopic) const PrivateTopicLock(),
              if (showPositionBadge) ...[
                const SizedBox(width: 6),
                PositionBadge(label: otherMember.position!),
              ],
              if (widget.session.otherTeamNameOf(widget.room)
                  case final team?) ...[
                const SizedBox(width: 6),
                TeamNameBadge(name: team),
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
              // 안 읽은 멘션이 있으면 안읽음 숫자 옆에 "@"를 붙인다.
              if (widget.room.unreadMentionCount > 0) ...[
                const MentionMarker(),
                const SizedBox(width: 4),
              ],
              if (widget.unreadCount > 0) ...[
                UnreadBadge(count: widget.unreadCount),
                const SizedBox(width: 4),
              ],
              if (widget.pinnedSelf)
                const SizedBox(width: 28, height: 28)
              else
                Opacity(
                  opacity: showHover ? 1 : 0,
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      // ⋮ 메뉴의 문구(room_options_menu.dart)와 맞춘다 — 토픽은 "토픽 나가기".
                      tooltip: _isDm
                          ? '채팅방 숨기기'
                          : (widget.room.type == RoomType.topic
                                ? '토픽 나가기'
                                : '채팅방 나가기'),
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
    if (!widget.draggable) return tile;
    // 토픽 줄은 마우스로 끌어서 폴더 머리글(넣기)·'토픽' 머리글(빼기)에 놓는다 — 문턱(6px)보다
    // 적게 흔들린 클릭은 그대로 방 열기다. 끄는 동안 제자리는 흐리게 남긴다.
    return TopicMouseDraggable<Room>(
      data: widget.room,
      dragAnchorStrategy: topicDragAnchor,
      feedback: TopicDragFeedback(icon: Icons.tag, label: widget.label),
      onDragStarted: () => setState(() => _dragging = true),
      onDragEnd: (_) {
        if (mounted) setState(() => _dragging = false);
      },
      child: Opacity(opacity: _dragging ? 0.4 : 1, child: tile),
    );
  }
}

/// 우클릭 메뉴의 "폴더로 이동 ▸" — PopupMenu는 하위 메뉴가 없어서, 누르면 이 메뉴는 그대로 둔
/// 채 바로 오른쪽에 내 폴더 목록을 한 겹 더 띄운다([openSubmenu]). 거기서 무언가 고르면 원래
/// 메뉴도 [value]로 닫는다(하위 메뉴만 닫으면 원래 메뉴는 남아 다른 항목을 고를 수 있다).
class _SubmenuItem extends PopupMenuItem<_RoomContextAction> {
  /// 이 항목의 자리(오버레이 좌표) 옆에 하위 메뉴를 띄우고, 무언가 골랐으면 true.
  final Future<bool> Function(BuildContext context, Rect anchor) openSubmenu;

  const _SubmenuItem({
    required super.value,
    super.height,
    super.padding,
    required super.child,
    required this.openSubmenu,
  });

  @override
  PopupMenuItemState<_RoomContextAction, _SubmenuItem> createState() =>
      _SubmenuItemState();
}

class _SubmenuItemState
    extends PopupMenuItemState<_RoomContextAction, _SubmenuItem> {
  @override
  void handleTap() => _open();

  Future<void> _open() async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    final picked = await widget.openSubmenu(context, anchor);
    if (picked && mounted) Navigator.of(context).pop(widget.value);
  }
}
