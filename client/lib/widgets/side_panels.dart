import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../screens/announcement_list_screen.dart'
    show
        AnnouncementsPanel,
        AnnouncementsPanelNoRoom,
        announcementPanelKey,
        takeInitialAnnouncementFor;
import '../screens/favorites_screen.dart';
import '../screens/files_screen.dart';
import '../screens/links_screen.dart';
import '../screens/member_profile_dialog.dart';
import '../screens/my_posts_screen.dart';
import '../screens/my_profile_dialog.dart';
import '../screens/polls_screen.dart';
import '../screens/search_screen.dart';
import '../screens/topic_members_dialog.dart' show TopicMembersScreen;
import '../services/session.dart';
import 'albums_panel.dart';
import 'bookmarks_panel.dart';
import 'home_shell_scope.dart';
import 'inquiries_panel.dart';
import 'notifications_panel.dart';
import 'reminders_panel.dart';
import 'scheduled_panel.dart';
import 'side_panel_header.dart';
import 'team_members_panel.dart';
import 'todos_panel.dart';

export 'home_shell_scope.dart'
    show HomeShellScope, PanelLeaveGuard, openRoomFromPanel;
export 'side_panel_header.dart';
import '../l10n/tr.dart';

// ──────────────────────────────────────────────────────────────────────────
// "패널" 등록 구조 — 새 패널을 만들 때 읽을 것
//
// 패널은 PC에서는 홈 화면 오른쪽에 붙는 칸(한 번에 하나, 서로 자리를 바꾼다), 모바일에서는 전체 화면
// 라우트로 열리는 화면이다. 같은 위젯 하나를 두 곳에서 쓰므로 "패널 본문 위젯" 하나만 만들면 된다.
//
// 새 패널 추가 = 아래 [sidePanelSpecs] 목록에 [SidePanelSpec] 한 줄 더하기:
//
//   SidePanelSpec(
//     key: 'todos',                       // 패널을 가리키는 이름(메뉴 키와 같게 두면 편하다)
//     title: '할 일',                      // 모바일 앱바 제목 / PC 패널 머리글
//     builder: (context, session, onClose) => TodosPanel(session: session),
//   ),
//
// - builder의 [onClose]는 "이 패널을 닫아라"다(PC는 오른쪽 칸을 비우고, 모바일은 화면을 닫는다).
// - 머리글(제목 + 닫기 X)은 기본으로 이 파일이 그려 준다(PC는 본문 위에, 모바일은 앱바로). 파일·링크 패널처럼
//   위젯이 자기 머리글을 직접 그리면 `ownHeader: true`를 준다([SidePanelHeader]를 쓰면 같은 모양이다).
// - 방을 열어야 하면(항목을 눌러 그 방·메시지로 이동) `openRoomFromPanel(context, session, room, messageId: id)`을
//   부른다 — PC는 가운데 채팅이 바뀌고(다른 팀이면 팀 전환까지), 모바일은 채팅 화면이 위에 얹힌다.
// - 방 헤더에서 열린 경우의 방 필터는 `HomeShellScope.maybeOf(context)?.panelRoom` / `.currentRoomId`로 읽는다
//   (파일·링크 패널의 builder가 예시).
// - 한 방의 것만 보는 패널(공지)은 `openSidePanel(context, session, key, room: room)`으로 열고 builder에서
//   [sidePanelRoomOf]로 그 방을 읽는다(PC는 홈 셸의 panelRoom, 모바일은 라우트에 얹은 방).
//
// 패널 열기: 메뉴 항목의 onOpen이나 어디서든 `openSidePanel(context, session, 'todos')` 한 줄.
//   - PC: 오른쪽 패널로 토글(이미 열려 있으면 닫고, 다른 패널이 열려 있으면 교체한다. 댓글 스레드·대화창
//     분할과도 서로 자리를 비켜 준다).
//   - 모바일: 같은 builder를 전체 화면 라우트로 연다.
//   - 이때 [context]는 홈 화면 아래의 것이어야 PC 패널로 열린다(메뉴 타일의 onOpen이 받는 context가 그렇다).
//     팝업·대화상자 안의 context를 넘기면 홈 화면을 못 찾아 전체 화면으로 열린다.
//
// 메뉴에 타일을 달려면 menu_entries.dart의 [menuEntries]에 [MenuEntry] 한 줄(onOpen에서 위 함수 호출).
// ──────────────────────────────────────────────────────────────────────────

/// 패널 본문을 만든다. [context]는 홈 화면 아래(PC) 또는 새 라우트(모바일)의 것이다.
typedef SidePanelBuilder =
    Widget Function(
      BuildContext context,
      Session session,
      VoidCallback onClose,
    );

class SidePanelSpec {
  /// 패널을 가리키는 이름 — [openSidePanel]에 넘기는 값. 목록 안에서 하나뿐이어야 한다.
  final String key;

  /// 모바일 앱바 제목, PC 패널 머리글(ownHeader가 아닐 때).
  final String title;
  final SidePanelBuilder builder;

  /// true면 [builder]가 만든 위젯이 제목·닫기 버튼 머리글을 직접 그린다 — 이 파일은 머리글을 더하지 않는다.
  final bool ownHeader;

  const SidePanelSpec({
    required this.key,
    required this.title,
    required this.builder,
    this.ownHeader = false,
  });
}

/// 등록된 패널들. 새 패널은 여기에 [SidePanelSpec] 하나를 더한다.
final sidePanelSpecs = <SidePanelSpec>[
  SidePanelSpec(
    key: 'search',
    title: tr('검색'),
    ownHeader: true,
    builder: (context, session, onClose) => SearchScreen(
      session: session,
      asPanel: true,
      onClose: onClose,
      onOpenRoom: (room, messageId) =>
          openRoomFromPanel(context, session, room, messageId: messageId),
    ),
  ),
  SidePanelSpec(
    key: 'files',
    title: tr('파일'),
    ownHeader: true,
    builder: (context, session, onClose) {
      final shell = HomeShellScope.maybeOf(context);
      return FilesScreen(
        // 방 헤더의 "파일 보기"를 다른 방에서 다시 누르면 그 방으로 새로 시작한다.
        key: ValueKey('files-${shell?.panelGeneration ?? 0}'),
        session: session,
        initialRoomId: shell?.panelRoom?.id ?? shell?.currentRoomId,
        onClose: onClose,
      );
    },
  ),
  SidePanelSpec(
    key: 'links',
    title: tr('링크'),
    ownHeader: true,
    builder: (context, session, onClose) {
      final shell = HomeShellScope.maybeOf(context);
      return LinksScreen(
        key: ValueKey('links-${shell?.panelGeneration ?? 0}'),
        session: session,
        initialRoomId: shell?.panelRoom?.id ?? shell?.currentRoomId,
        onClose: onClose,
        // "대화방에서 보기" — 검색 결과를 눌렀을 때처럼 그 방을 열고 메시지로 스크롤.
        onOpenMessage: (room, messageId) =>
            openRoomFromPanel(context, session, room, messageId: messageId),
      );
    },
  ),
  SidePanelSpec(
    key: 'albums',
    title: tr('앨범'),
    ownHeader: true,
    builder: (context, session, onClose) {
      final shell = HomeShellScope.maybeOf(context);
      return AlbumsPanel(
        // 방 헤더의 "앨범 보기"를 다른 방에서 다시 누르면 그 방으로 새로 시작한다.
        key: ValueKey('albums-${shell?.panelGeneration ?? 0}'),
        session: session,
        initialRoomId: shell?.panelRoom?.id ?? shell?.currentRoomId,
        onClose: onClose,
      );
    },
  ),
  SidePanelSpec(
    key: 'todos',
    title: tr('할 일'),
    ownHeader: true,
    builder: (context, session, onClose) =>
        TodosPanel(session: session, onClose: onClose),
  ),
  SidePanelSpec(
    key: 'scheduled',
    title: tr('메시지 예약'),
    ownHeader: true,
    builder: (context, session, onClose) =>
        ScheduledPanel(session: session, onClose: onClose),
  ),
  SidePanelSpec(
    key: 'reminders',
    title: tr('리마인더'),
    ownHeader: true,
    builder: (context, session, onClose) =>
        RemindersPanel(session: session, onClose: onClose),
  ),
  SidePanelSpec(
    key: 'inquiries',
    title: tr('문의함'),
    ownHeader: true,
    builder: (context, session, onClose) => InquiriesPanel(
      session: session,
      onClose: onClose,
      initialBox: takeInitialInquiryBox(),
    ),
  ),
  SidePanelSpec(
    key: 'favorites',
    title: tr('즐겨찾기'),
    ownHeader: true,
    builder: (context, session, onClose) =>
        FavoritesScreen(session: session, onClose: onClose),
  ),
  SidePanelSpec(
    key: 'polls',
    title: tr('투표'),
    ownHeader: true,
    builder: (context, session, onClose) =>
        PollsScreen(session: session, onClose: onClose),
  ),
  SidePanelSpec(
    key: 'myposts',
    title: tr('내가 쓴 글'),
    ownHeader: true,
    builder: (context, session, onClose) =>
        MyPostsScreen(session: session, onClose: onClose),
  ),
  SidePanelSpec(
    key: 'bookmarks',
    title: tr('북마크'),
    ownHeader: true,
    builder: (context, session, onClose) =>
        BookmarksPanel(session: session, onClose: onClose),
  ),
  SidePanelSpec(
    key: 'notifications',
    title: tr('알림 센터'),
    ownHeader: true,
    builder: (context, session, onClose) => NotificationsPanel(
      session: session,
      onClose: onClose,
      onSelectRoom: (room, {messageId, announcementPopup = true}) {
        final hadUnreadAnnouncement = room.hasUnreadAnnouncement;
        // 패널(모바일은 이 화면)부터 닫고 방을 연다 — 모바일은 닫기가 pop이라 순서가 바뀌면 채팅 화면이 닫힌다.
        final shell = HomeShellScope.maybeOf(context);
        onClose();
        // 다른 팀의 방일 수 있다(이 패널의 핵심 목적) — 팀 전환은 requestOpenRoom이 한다.
        if (shell != null) {
          session.requestOpenRoom(room, messageId: messageId);
        } else {
          openRoomFromPanel(context, session, room, messageId: messageId);
        }
        // 안 읽은 공지 때문에 알림 센터에 떠 있던 방이면 공지 내용도 팝업으로 띄운다.
        if (announcementPopup) {
          showUnreadAnnouncementPopup(
            context,
            session,
            room,
            hadUnreadAnnouncement: hadUnreadAnnouncement,
          );
        }
      },
    ),
  ),
  SidePanelSpec(
    key: 'members',
    title: tr('팀 멤버'),
    ownHeader: true,
    builder: (context, session, onClose) {
      // 방 헤더의 "멤버" 버튼으로 열면 그 방의 참여 멤버, 상단 "팀 멤버"로 열면 팀 전체.
      final room = HomeShellScope.maybeOf(context)?.panelRoom;
      if (room != null) {
        return TopicMembersScreen(
          key: ValueKey('room-members-${room.id}'),
          session: session,
          room: room,
          asPanel: true,
          onClose: onClose,
        );
      }
      return TeamMembersPanel(
        session: session,
        onClose: onClose,
        onSelectMember: (user) async {
          final dm = await _showMemberCard(context, session, user);
          if (dm == null || !context.mounted) return;
          onClose();
          openRoomFromPanel(context, session, dm);
        },
      );
    },
  ),
  SidePanelSpec(
    key: announcementPanelKey,
    title: tr('공지'),
    ownHeader: true,
    builder: (context, session, onClose) {
      // 토픽 ⋯의 "공지"·알림 센터의 안 읽은 공지로 연 방. 방 없이 열렸으면(시험 하네스 등) 지금 보고 있는 토픽.
      final shell = HomeShellScope.maybeOf(context);
      final current = shell?.currentRoomId;
      final room =
          sidePanelRoomOf(context) ??
          (current == null ? null : session.roomById(current));
      if (room == null || room.type != RoomType.topic) {
        return AnnouncementsPanelNoRoom(onClose: onClose);
      }
      return AnnouncementsPanel(
        // 다른 방에서 다시 열면 그 방으로 새로 시작한다(패널 안에 띄운 상세도 닫힌다).
        key: ValueKey(
          'announcements-${room.id}-${shell?.panelGeneration ?? 0}',
        ),
        session: session,
        room: session.roomById(room.id) ?? room,
        onClose: onClose,
        // 공지바를 눌러 열었으면 그 공지의 상세를 목록 위에 바로 띄운다(openAnnouncementPanel이 맡겨 둔 것 — 한 번만).
        initialAnnouncement: takeInitialAnnouncementFor(room.id),
      );
    },
  ),
];

/// [openSidePanel]의 `room:`으로 연 패널이 가리키는 방 — PC는 홈 셸의 [HomeShellScope.panelRoom], 모바일(전체 화면
/// 라우트)은 그 라우트에 얹어 둔 방. 방 없이 열었으면 null.
Room? sidePanelRoomOf(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_SidePanelRoomScope>()?.room ??
    HomeShellScope.maybeOf(context)?.panelRoom;

/// 모바일에서 `room:`으로 연 패널 라우트에 그 방을 얹어 둔다([sidePanelRoomOf]가 읽는다).
class _SidePanelRoomScope extends InheritedWidget {
  final Room room;
  const _SidePanelRoomScope({required this.room, required super.child});

  @override
  bool updateShouldNotify(_SidePanelRoomScope old) => room.id != old.room.id;
}

/// 멤버 카드 — 로그인한 본인이면 "내 프로필", 다른 멤버면 프로필 카드(DM 시작 등). DM을 열었으면 그 방을 돌려준다.
Future<Room?> _showMemberCard(
  BuildContext context,
  Session session,
  AppUser user,
) async {
  if (user.id == session.userId) {
    await showDialog<void>(
      context: context,
      builder: (_) => MyProfileDialog(session: session),
    );
    return null;
  }
  return showDialog<Room>(
    context: context,
    builder: (_) => MemberProfileDialog(session: session, user: user),
  );
}

SidePanelSpec? sidePanelSpecFor(String key) {
  for (final spec in sidePanelSpecs) {
    if (spec.key == key) return spec;
  }
  return null;
}

/// [key] 패널을 연다 — PC는 오른쪽 패널로 토글(열려 있으면 닫고, 다른 패널이면 교체), 모바일은 전체 화면.
/// [context]는 홈 화면 아래의 것이어야 PC 패널로 열린다(위 주석 참고).
///
/// [room]을 주면 그 방의 패널로 연다(builder는 [sidePanelRoomOf]로 읽는다) — PC는 같은 방 것이 열려 있을 때만 닫고,
/// 다른 방 것이 열려 있으면 그 방으로 새로 시작한다.
void openSidePanel(
  BuildContext context,
  Session session,
  String key, {
  Room? room,
}) {
  final spec = sidePanelSpecFor(key);
  assert(
    spec != null,
    '등록되지 않은 패널: $key (side_panels.dart의 sidePanelSpecs에 추가하세요)',
  );
  if (spec == null) return;
  final shell = HomeShellScope.maybeOf(context);
  if (shell != null) {
    final openRoomPanel = shell.openRoomPanel;
    if (room != null && openRoomPanel != null) {
      openRoomPanel(key, room);
    } else {
      shell.togglePanel(key);
    }
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (routeContext) {
        void close() => Navigator.of(routeContext).pop();
        final body = room == null
            ? spec.builder(routeContext, session, close)
            : _SidePanelRoomScope(
                room: room,
                child: Builder(
                  builder: (bodyContext) =>
                      spec.builder(bodyContext, session, close),
                ),
              );
        return Scaffold(
          appBar: spec.ownHeader ? null : AppBar(title: Text(spec.title)),
          body: SafeArea(top: spec.ownHeader, child: body),
        );
      },
    ),
  );
}

/// PC 오른쪽 칸에 들어갈 패널 위젯 — [SidePanelSpec.ownHeader]가 아니면 머리글(제목 + 닫기)을 위에 붙인다.
Widget buildSidePanel(
  BuildContext context,
  Session session,
  SidePanelSpec spec,
  VoidCallback onClose,
) {
  final body = spec.builder(context, session, onClose);
  if (spec.ownHeader) return body;
  return ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SidePanelHeader(title: spec.title, onClose: onClose),
        const Divider(height: 1),
        Expanded(child: body),
      ],
    ),
  );
}
