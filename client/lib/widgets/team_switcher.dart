import 'package:flutter/material.dart';

import '../models/team.dart';
import '../services/session.dart';
import 'team_avatar.dart';

/// 창 왼쪽 위의 팀 표시 겸 전환 버튼: [팀 아이콘] 팀 이름 ▾.
/// 누르면 아래로 팝업이 떠서 내가 속한 다른 팀으로 바로 전환하거나, 팀 목록 화면으로 돌아간다.
class TeamSwitcher extends StatelessWidget {
  final Session session;

  /// 좁은 화면(모바일 AppBar)에서는 글자를 밝게 그려야 해서 색을 넘겨받는다.
  final Color? foregroundColor;
  const TeamSwitcher({super.key, required this.session, this.foregroundColor});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final current = session.currentTeam;
        if (current == null) return const SizedBox.shrink();
        final color =
            foregroundColor ?? Theme.of(context).colorScheme.onSurface;

        return PopupMenuButton<Object>(
          tooltip: '팀 전환',
          position: PopupMenuPosition.under,
          offset: const Offset(0, 10),
          onSelected: (value) {
            if (value is Team) {
              session.enterTeam(value);
            } else {
              session.leaveTeam(); // 팀 목록 화면으로
            }
          },
          itemBuilder: (context) => [
            for (final team in session.teams)
              PopupMenuItem<Object>(
                value: team,
                child: Row(
                  children: [
                    TeamAvatar(team: team, size: 28),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        team.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: team.id == current.id
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                    if (team.id == current.id)
                      Icon(
                        Icons.check,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                  ],
                ),
              ),
            const PopupMenuDivider(),
            const PopupMenuItem<Object>(
              value: 'list',
              child: Row(
                children: [
                  Icon(Icons.grid_view_outlined, size: 20),
                  SizedBox(width: 10),
                  Text('팀 리스트'),
                ],
              ),
            ),
          ],
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TeamAvatar(team: current, size: 28),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  current.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: color,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.expand_more, size: 20, color: color),
            ],
          ),
        );
      },
    );
  }
}

/// [TeamSwitcher]의 다른 모양 — 내가 속한 팀을 브라우저 탭처럼 한 줄로 늘어놓고 눌러서 바로
/// 바꾼다(환경설정 "팀 전환 방식"에서 고른다). 지금 팀 탭만 밝게, 나머지는 회색으로 그린다.
/// 팀이 많아 한 줄에 안 들어가면 가로로 스크롤된다.
class TeamSwitcherTabs extends StatelessWidget {
  final Session session;
  const TeamSwitcherTabs({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final current = session.currentTeam;
        if (current == null) return const SizedBox.shrink();
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final team in session.teams) ...[
                _TeamTab(
                  team: team,
                  selected: team.id == current.id,
                  // 그 팀에 안 읽은 방이 하나라도 있으면 탭 오른쪽 위에 빨간 점을 얹는다
                  // ("알림 센터" 종 버튼과 같은 표시 — notifications_panel.dart 참고).
                  hasUnread: session.unreadRooms.any(
                    (r) => r.teamId == team.id,
                  ),
                  onTap: () => session.enterTeam(team),
                ),
                // 탭끼리 맞붙어 보이도록 아주 얇은 틈만 둔다.
                const SizedBox(width: 2),
              ],
              // 브라우저 탭 줄 끝의 "+" 자리 — 여기서는 팀 목록 화면으로 간다.
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 2),
                child: IconButton(
                  icon: const Icon(Icons.grid_view_outlined, size: 18),
                  tooltip: '팀 리스트',
                  visualDensity: VisualDensity.compact,
                  color: Theme.of(context).hintColor,
                  onPressed: session.leaveTeam,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 팀 탭 한 칸 — 브라우저 탭처럼 위쪽 모서리만 둥글다. 지금 보고 있는 팀은 밝은 배경에
/// 진한 굵은 글씨, 나머지는 회색 배경에 흐린 글씨(아이콘도 함께 흐리게)로 구분하고,
/// 안 읽은 메시지가 있는 팀은 오른쪽 위에 빨간 점을 얹는다.
class _TeamTab extends StatelessWidget {
  final Team team;
  final bool selected;
  final bool hasUnread;
  final VoidCallback onTap;
  const _TeamTab({
    required this.team,
    required this.selected,
    required this.hasUnread,
    required this.onTap,
  });

  static const _radius = BorderRadius.vertical(top: Radius.circular(10));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.surface
          : theme.colorScheme.surfaceContainerHigh,
      borderRadius: _radius,
      child: InkWell(
        borderRadius: _radius,
        onTap: selected ? null : onTap,
        child: Badge(
          isLabelVisible: hasUnread,
          // 방 목록의 안읽음 뱃지·알림 센터 종과 같은 빨강/크기.
          backgroundColor: Colors.redAccent,
          smallSize: 7,
          // 기본 위치(모서리 바깥)면 옆 탭에 걸쳐 보여서 탭 안쪽으로 당겨 얹는다.
          offset: const Offset(-18, 6),
          child: Container(
            height: 34,
            padding: const EdgeInsets.fromLTRB(10, 0, 14, 0),
            decoration: BoxDecoration(
              borderRadius: _radius,
              border: Border.all(
                color: selected ? theme.dividerColor : Colors.transparent,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Opacity(
                  opacity: selected ? 1 : 0.45,
                  child: TeamAvatar(team: team, size: 20),
                ),
                const SizedBox(width: 7),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 130),
                  child: Text(
                    team.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: selected
                          ? theme.colorScheme.onSurface
                          : theme.hintColor,
                      fontWeight: selected ? FontWeight.bold : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
