import 'package:flutter/material.dart';

/// 방 목록에서 다른 팀의 방 이름 옆에 붙이는 팀 이름 표시 — "여러 팀 방 모아보기"(환경설정 > 메신저 설정)를 켰을 때
/// 지금 팀이 아닌 방이 어느 팀 것인지 알려 준다(Session.otherTeamNameOf). 이름이 길면 줄여서 보인다.
class TeamNameBadge extends StatelessWidget {
  final String name;
  const TeamNameBadge({super.key, required this.name});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('team-name-badge'),
      constraints: const BoxConstraints(maxWidth: 96),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          height: 1.3,
          color: scheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
