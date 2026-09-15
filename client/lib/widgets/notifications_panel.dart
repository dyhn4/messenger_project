import 'package:flutter/material.dart';

import '../models/room.dart';
import '../screens/chat_screen.dart';
import '../screens/home_screen.dart' show wideBreakpoint;
import '../services/session.dart';
import '../services/time_format.dart';
import 'muted_scrollbar.dart';
import 'room_avatar.dart';
import 'team_avatar.dart';
import 'unread_badge.dart';

/// 상단 툴바의 종 모양 "알림 센터" 버튼 — 안 읽은 방이 하나라도 있으면(Session.unreadRooms)
/// 오른쪽 위에 작은 빨간 점을 얹는다. desktop_home_screen.dart의 넓은 화면 툴바와
/// team_select_screen.dart의 "팀 리스트" 화면이 같이 쓴다.
class NotificationBellButton extends StatelessWidget {
  final Session session;
  final VoidCallback onPressed;
  const NotificationBellButton({
    super.key,
    required this.session,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // session이 바뀔 때마다(새 메시지로 unreadCount 증감 등) 이 아이콘만 다시 그린다 —
    // 호출부가 매번 setState 해주지 않아도 항상 최신 상태를 보여준다.
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => IconButton(
        icon: Badge(
          isLabelVisible: session.unreadRooms.isNotEmpty,
          // 방 목록의 안읽음 숫자 뱃지(UnreadBadge)와 같은 빨강으로 맞춘다.
          backgroundColor: Colors.redAccent,
          smallSize: 7,
          // 기본 위치(topEnd 모서리)에 딱 붙이면 종 모양 테두리와 겹쳐 보여서, 오른쪽
          // 위로 살짝 더 밀어낸다.
          offset: const Offset(4, -4),
          child: const Icon(Icons.notifications_outlined),
        ),
        tooltip: '알림 센터',
        onPressed: onPressed,
      ),
    );
  }
}

/// "알림 센터" 안 읽은 방 패널 — 검색/멤버 패널과 같은 틀(헤더+목록)을 쓰되 필터는 없다.
/// 안 읽은 메시지가 있는 방을 전부(지금 보고 있는 팀 포함, 여러 팀에 걸쳐) 모아 최근
/// 활동순으로 보여준다. Session.unreadRooms 참고. desktop_home_screen.dart는 이걸 우측
/// 사이드 패널로, team_select_screen.dart는 [showNotificationsCenterDialog]로 가운데
/// 뜨는 대화상자로 띄운다 — 헤더/닫기 버튼을 이 위젯이 스스로 그리므로 둘 다 그대로 쓴다.
class NotificationsPanel extends StatefulWidget {
  final Session session;
  final VoidCallback onClose;
  final ValueChanged<Room> onSelectRoom;
  const NotificationsPanel({
    super.key,
    required this.session,
    required this.onClose,
    required this.onSelectRoom,
  });

  @override
  State<NotificationsPanel> createState() => _NotificationsPanelState();
}

class _NotificationsPanelState extends State<NotificationsPanel> {
  @override
  void initState() {
    super.initState();
    // 안읽음 수가 실시간으로 바뀔 때마다(새 메시지 수신, 다른 곳에서 읽음 처리 등) 목록을
    // 다시 그린다 — _MembersPanel의 onlineUserIds 갱신과 같은 이유.
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

  @override
  Widget build(BuildContext context) {
    final rooms = widget.session.unreadRooms.toList()
      ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));

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
                    '알림 센터',
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
          Expanded(
            child: rooms.isEmpty
                ? Center(
                    child: Text(
                      '안 읽은 메시지가 없습니다.',
                      style: TextStyle(color: Theme.of(context).hintColor),
                    ),
                  )
                : MutedScrollbar(
                    child: ListView.separated(
                      itemCount: rooms.length,
                      separatorBuilder: (_, _) => const Padding(
                        padding: EdgeInsets.only(right: 12),
                        child: Divider(height: 1),
                      ),
                      itemBuilder: (context, i) => _NotificationRow(
                        session: widget.session,
                        room: rooms[i],
                        onTap: () => widget.onSelectRoom(rooms[i]),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 알림 센터 한 줄: [팀 아바타(+팀 이름)] [방 아바타] [방 이름 · 시각 / 미리보기 · 안읽음 수].
/// 팀 아바타는 방 아바타와 겹치지 않게 완전히 별도 칸으로 왼쪽에 둔다 — 여러 팀 알림이 한
/// 목록에 섞이므로 어느 팀인지 한눈에 구분돼야 한다(검색 결과 행과 같은 뼈대에 이 칸만 더함).
class _NotificationRow extends StatelessWidget {
  final Session session;
  final Room room;
  final VoidCallback onTap;
  const _NotificationRow({
    required this.session,
    required this.room,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final team = session.teams.where((t) => t.id == room.teamId).firstOrNull;
    const teamColumnWidth = 44.0;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: teamColumnWidth,
              child: team == null
                  ? null
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TeamAvatar(team: team, size: 32),
                        const SizedBox(height: 2),
                        Text(
                          team.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Theme.of(context).hintColor,
                                fontSize: 10,
                              ),
                        ),
                      ],
                    ),
            ),
            const SizedBox(width: 10),
            RoomAvatar(
              room: room,
              myUserId: session.userId ?? '',
              resolveUrl: session.resolveUrl,
              onlineUserIds: session.onlineUserIds,
              size: 32,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          room.displayName(session.userId ?? ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatRoomActivityTime(room.lastActivityAt),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          room.lastMessagePreview ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(width: 8),
                      UnreadBadge(count: room.unreadCount),
                    ],
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

/// team_select_screen.dart("팀 리스트" 화면)에서 알림 센터를 가운데 뜨는 대화상자로 연다 —
/// 그 화면은 desktop_home_screen.dart처럼 옆으로 붙는 사이드 패널 자리가 없어서(아직 팀을
/// 안 고른 상태) 대신 대화상자로 띄운다. 방을 고르면 그 방이 속한 팀으로 전환한 뒤(넓은
/// 화면은 Session.requestOpenRoom으로 DesktopHomeScreen이 이어서 펼쳐 보여줌) 그 방을 연다.
/// 좁은(모바일) 화면은 requestOpenRoom만으로는 안 열린다 — RoomListScreen(좁은 화면의 홈)은
/// message_bubble.dart의 프로필 대화상자 등과 마찬가지로 requestOpenRoom의 "대기 중인 방"을
/// 소비하지 않고 항상 직접 push된 ChatScreen으로만 열리므로, 여기서도 같은 패턴대로 직접
/// push한다.
Future<void> showNotificationsCenterDialog(
  BuildContext context,
  Session session,
) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      // 폭을 고정하면(SizedBox) 좁은 폰 화면에서 Dialog의 기본 insetPadding(좌우 40씩)보다
      // 넓어져 넘친다 — FloatingDialog와 같은 방식으로 최댓값만 주고 좁은 화면에서는
      // 알아서 줄어들게 한다.
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 640),
        child: NotificationsPanel(
          session: session,
          onClose: () => Navigator.of(dialogContext).pop(),
          onSelectRoom: (room) {
            Navigator.of(dialogContext).pop();
            if (MediaQuery.sizeOf(context).width >= wideBreakpoint) {
              session.requestOpenRoom(room);
            } else {
              // 좁은 화면에서도 다른 팀의 방일 수 있으니 팀 전환만 requestOpenRoom에 맡기고
              // (내부적으로 currentTeam만 바꿔줌 — _pendingOpenRoom은 이 경로에서 안 쓰임),
              // 화면 전환 자체는 직접 push한다.
              session.requestOpenRoom(room);
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ChatScreen(session: session, room: room),
                ),
              );
            }
          },
        ),
      ),
    ),
  );
}
