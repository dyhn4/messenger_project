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
