import 'package:flutter/material.dart';

import '../models/room.dart';
import '../screens/chat_screen.dart';
import '../services/session.dart';

/// PC 홈 화면(desktop_home_screen.dart)이 자기 아래 위젯들에게 건네는 "홈 셸" 손잡이 — 오른쪽 패널을 열고 닫고,
/// 캘린더를 켜고 끄고, 방을 가운데 채팅 자리에 여는 일을 메뉴·패널이 홈 화면의 상태를 몰라도 부를 수 있게 한다.
/// 모바일(RoomListScreen)에는 이게 없다 — [maybeOf]가 null이면 "전체 화면 라우트로 연다"가 기본 동작이다.
/// 사용법은 side_panels.dart(패널)와 menu_entries.dart(메뉴) 맨 위 주석을 보라.
class HomeShellScope extends InheritedWidget {
  /// 지금 오른쪽에 열려 있는 패널의 키(side_panels.dart의 [SidePanelSpec.key]). 없으면 null.
  final String? openPanelKey;

  /// 방 헤더의 "파일 보기"·"링크 보기"·"멤버"·"공지"로 연 패널이 가리키는 방. 상단 메뉴로 연 패널이면 null.
  final Room? panelRoom;

  /// 패널을 열 때마다 올라간다 — 이미 열려 있는 패널을 다른 방으로 "새로 시작"시키는 위젯 키로 쓴다.
  final int panelGeneration;

  /// 지금 가운데 채팅 자리에 열려 있는 방의 id(파일·링크 패널이 대화방 필터의 시작값으로 쓴다).
  final String? currentRoomId;

  /// 패널을 토글한다(열려 있으면 닫고, 아니면 연다).
  final void Function(String key) togglePanel;

  /// 한 방의 것만 보는 패널(공지 등)을 [room]으로 연다 — 이미 그 방으로 열려 있으면 닫고(토글), 다른 방이면 그 방으로
  /// 새로 시작한다. side_panels.dart의 `openSidePanel(..., room: room)`이 부른다. 없으면(시험 하네스 등) [togglePanel]로
  /// 열고, 패널은 [currentRoomId]의 방을 쓴다.
  final void Function(String key, Room room)? openRoomPanel;

  /// 열려 있는 오른쪽 패널을 닫는다.
  final VoidCallback closePanel;

  /// 캘린더(사이드바+채팅 자리를 대체하는 화면)를 켜고 끈다.
  final VoidCallback toggleCalendar;

  /// 방을 가운데 채팅 자리에 연다([messageId]가 있으면 그 메시지로 스크롤·강조). 다른 팀의 방이면 팀을 바꾼다.
  final void Function(Room room, {String? messageId}) openRoom;

  /// 열려 있는 패널이 "닫기 전에 물어볼 것"을 맡긴다([owner]는 맡긴 쪽 — 같은 쪽이 null을 주면 거둔다). 홈 화면은 패널을 밖에서
  /// 닫거나 다른 패널·댓글·대화창 분할로 바꾸기 전에 이것에 묻는다(패널 안에서 쓰던 할 일이 날아가지 않게). 패널 자신의
  /// 닫기([closePanel])는 묻지 않는다 — 그 패널이 이미 물었다. 홈 화면 밖(시험 하네스 등)은 없어도 된다.
  final void Function(Object owner, PanelLeaveGuard? guard)? setPanelLeaveGuard;

  const HomeShellScope({
    super.key,
    required this.openPanelKey,
    required this.panelRoom,
    required this.panelGeneration,
    required this.currentRoomId,
    required this.togglePanel,
    this.openRoomPanel,
    required this.closePanel,
    required this.toggleCalendar,
    required this.openRoom,
    this.setPanelLeaveGuard,
    required super.child,
  });

  /// 가장 가까운 홈 셸. 모바일이나 테스트처럼 홈 화면 밖이면 null.
  static HomeShellScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HomeShellScope>();

  @override
  bool updateShouldNotify(HomeShellScope old) =>
      openPanelKey != old.openPanelKey ||
      panelRoom?.id != old.panelRoom?.id ||
      panelGeneration != old.panelGeneration ||
      currentRoomId != old.currentRoomId;
}

/// 오른쪽 패널을 밖에서 닫거나 바꾸기 전에 물어보는 손잡이([HomeShellScope.setPanelLeaveGuard]) — 할 일 패널 안에서 쓰던
/// 할 일(생성·수정 화면)이 있을 때.
class PanelLeaveGuard {
  /// 지금 물어봐야 하는지 — false면 홈 화면은 묻지 않고 바로(같은 프레임에) 닫거나 바꾼다.
  final bool Function() needsConfirm;

  /// 물어본다 — 닫아도 되면 true(그때만 홈 화면이 이어서 닫거나 바꾼다).
  final Future<bool> Function() confirm;

  const PanelLeaveGuard({required this.needsConfirm, required this.confirm});
}

/// 패널 안에서 방을 누르면 — PC는 홈 셸이 가운데 채팅 자리를 바꾸고, 모바일은 채팅 화면을 위에 얹는다.
/// 다른 팀의 방일 수 있어 팀 전환은 [Session.requestOpenRoom]에 맡긴다(알림·즐겨찾기와 같은 방식).
void openRoomFromPanel(
  BuildContext context,
  Session session,
  Room room, {
  String? messageId,
}) {
  final shell = HomeShellScope.maybeOf(context);
  if (shell != null) {
    shell.openRoom(room, messageId: messageId);
    return;
  }
  // 모바일: requestOpenRoom은 다른 팀이면 팀 전환만 맡고, 화면은 직접 얹는다.
  session.requestOpenRoom(room);
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ChatScreen(
        session: session,
        room: room,
        highlightMessageId: messageId,
      ),
    ),
  );
}
