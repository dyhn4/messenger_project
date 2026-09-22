import 'package:flutter/material.dart';

import '../models/team.dart';

/// 팀 아이콘. 사진을 올렸으면 그 사진을, 이모지를 고르면 그 이모지를, 둘 다 없으면 팀 이름
/// 앞 2글자를 보여준다.
class TeamAvatar extends StatelessWidget {
  final Team team;
  final double size;

  /// 사진(team.iconUrl, 서버 기준 상대경로)을 절대 주소로 바꾼다 — 보통 session.resolveUrl.
  final String Function(String relative) resolveUrl;
  const TeamAvatar({
    super.key,
    required this.team,
    required this.resolveUrl,
    this.size = 40,
  });

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
    final photo = team.iconUrl;
    if (photo != null && photo.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.28),
        child: Image.network(
          resolveUrl(photo),
          width: size,
          height: size,
          fit: BoxFit.cover,
          // 링크가 만료됐거나 파일이 없으면 이모지·이니셜로 대신 그린다.
          errorBuilder: (context, _, _) => _fallback(),
        ),
      );
    }
    return _fallback();
  }

  Widget _fallback() {
    final emoji = team.iconEmoji;
    final hasEmoji = emoji != null && emoji.isNotEmpty;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _colorOf(team),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      alignment: Alignment.center,
      child: Text(
        hasEmoji ? emoji : team.initial,
        maxLines: 1,
        style: TextStyle(
          // 이니셜은 2글자라 이모지보다 작게 해야 칸 안에 들어간다.
          fontSize: size * (hasEmoji ? 0.5 : 0.36),
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
