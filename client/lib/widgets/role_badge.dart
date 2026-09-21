import 'package:flutter/material.dart';

/// 등급/상태 표시용 알약 배지 — 관리자 콘솔 "회원" 탭과 팀 설정 "멤버" 탭이 같은 모양을 쓴다.
class RoleBadge extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  const RoleBadge({
    super.key,
    required this.label,
    required this.bg,
    required this.fg,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// [RoleBadge] 배색 — 라이트/다크 테마 각각에 맞춘 옅은 배경 + 또렷한 글자색 쌍.
/// kind: 'admin' | 'member' | 'guest'(계정 등급) | 'op'(서버 운영자) | 'owner'(팀 소유자) |
/// 'suspended'(정지됨).
({Color bg, Color fg}) roleBadgeColors(BuildContext context, String kind) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  switch (kind) {
    case 'admin':
      return dark
          ? (bg: const Color(0xFF2C2650), fg: const Color(0xFFB3A4F5))
          : (bg: const Color(0xFFECE9FB), fg: const Color(0xFF6A4FD6));
    case 'member':
      return dark
          ? (bg: const Color(0xFF1C3934), fg: const Color(0xFF6BD6BD))
          : (bg: const Color(0xFFE3F6F2), fg: const Color(0xFF0F8A72));
    case 'op':
      return dark
          ? (bg: const Color(0xFF3A251F), fg: const Color(0xFFF0A284))
          : (bg: const Color(0xFFFDECE7), fg: const Color(0xFFC1502E));
    case 'owner':
      return dark
          ? (bg: const Color(0xFF3A331F), fg: const Color(0xFFE0BB74))
          : (bg: const Color(0xFFFDF3E3), fg: const Color(0xFFB8860B));
    case 'suspended':
      return dark
          ? (bg: const Color(0xFF3A1E22), fg: const Color(0xFFF08A9A))
          : (bg: const Color(0xFFFCE8EA), fg: const Color(0xFFC13350));
    case 'guest':
    default:
      return dark
          ? (bg: const Color(0xFF262A3A), fg: const Color(0xFF9AA0B5))
          : (bg: const Color(0xFFEEF0F5), fg: const Color(0xFF6B7385));
  }
}
