import 'package:flutter/material.dart';

import '../models/team.dart';

/// 팀 아이콘. 팀 설정에서 이모지를 고르면 그 이모지를, 없으면 팀 이름 첫 글자를 보여준다
/// (사용자 아바타의 character/initial 방식과 같은 규칙).
class TeamAvatar extends StatelessWidget {
  final Team team;
  final double size;
  const TeamAvatar({super.key, required this.team, this.size = 40});

  static Color _colorOf(Team team) {
    final hex = team.iconColor;
    if (hex != null && hex.startsWith('#') && hex.length == 7) {
      final value = int.tryParse(hex.substring(1), radix: 16);
      if (value != null) return Color(0xFF000000 | value);
    }
    // 색을 안 정했으면 팀 id로 항상 같은 색이 나오게 고른다(팀마다 구분은 되면서, 다시
    // 켜도 색이 바뀌지 않도록).
    const palette = [
      Color(0xFF9575CD),
      Color(0xFF4C6EF5),
      Color(0xFF15AABF),
      Color(0xFF37B24D),
      Color(0xFFE64980),
      Color(0xFFFF6B35),
    ];
    return palette[team.id.hashCode.abs() % palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final emoji = team.iconEmoji;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _colorOf(team),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      alignment: Alignment.center,
      child: Text(
        emoji != null && emoji.isNotEmpty ? emoji : team.initial,
        style: TextStyle(
          fontSize: size * 0.5,
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
