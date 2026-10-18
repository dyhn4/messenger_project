import 'package:flutter/material.dart';
import '../l10n/tr.dart';

Color? parseHexColor(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  final v = hex.replaceFirst('#', '');
  final full = v.length == 6 ? 'FF$v' : v;
  return Color(int.parse(full, radix: 16));
}

String colorToHex(Color color) =>
    '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}';

/// 팀·그룹 이니셜 아이콘의 글자 — 이름에서 공백을 뺀 앞 2글자(이모지 등도 한 글자로 센다).
String initialsOf(String name) {
  final compact = name.replaceAll(RegExp(r'\s+'), '');
  return compact.isEmpty ? '?' : compact.characters.take(2).toString();
}

/// 그룹채팅 이니셜 아이콘 — [color] 배경의 원 안에 [name]의 앞 2글자를 흰 글씨로 그린다.
/// 색이 없으면(예전에 만든 그룹) 테마 기본색을 쓴다.
class InitialsAvatar extends StatelessWidget {
  final String name;
  final Color? color;
  final double radius;
  const InitialsAvatar({
    super.key,
    required this.name,
    this.color,
    this.radius = 16,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: radius,
      backgroundColor: color ?? scheme.primaryContainer,
      child: Text(
        initialsOf(name),
        maxLines: 1,
        style: TextStyle(
          fontSize: radius * 0.7,
          fontWeight: FontWeight.bold,
          color: color != null ? Colors.white : scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

/// 프로젝트 자동화(채팅방 알림) 메시지의 아바타 색 — 사람 아바타와 헷갈리지 않게 남보라 계열로 고정.
const automationAvatarColor = Color(0xFF6366F1);

/// 자동화가 보낸 메시지의 아바타 — 사람이 아니라서 프로필 사진·이니셜 대신 번개 아이콘을 그린다.
class AutomationAvatar extends StatelessWidget {
  final double radius;

  /// 외부 연동 봇의 아이콘(웹훅·슬래시 명령을 만들 때 고른 이모지) — 없으면 번개.
  final String? emoji;
  const AutomationAvatar({super.key, this.radius = 16, this.emoji});

  @override
  Widget build(BuildContext context) {
    final e = emoji;
    return CircleAvatar(
      radius: radius,
      backgroundColor: automationAvatarColor.withValues(alpha: 0.16),
      child: e == null || e.isEmpty
          ? Icon(Icons.bolt, size: radius * 1.2, color: automationAvatarColor)
          : Text(e, style: TextStyle(fontSize: radius * 1.1, height: 1)),
    );
  }
}

/// 봇 메시지 이름 옆의 작은 "봇" 표시 — 사람이 보낸 글과 헷갈리지 않게.
class BotBadge extends StatelessWidget {
  const BotBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('bot-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: automationAvatarColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        tr('봇'),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: automationAvatarColor,
        ),
      ),
    );
  }
}

/// avatarType('initial'/'character'/'photo')에 따라 업로드한 사진, 캐릭터(이모지+배경색),
/// 이니셜 중 하나를 그리는 공용 아바타. `MyAvatar`(나)와 `UserAvatar`(다른 사용자)가 공유한다.
class AvatarView extends StatelessWidget {
  final String username;
  final String avatarType;
  final String? avatarEmoji;
  final String? avatarColor;
  final String? avatarUrl;
  final String Function(String relative)? resolveUrl;
  final double radius;
  const AvatarView({
    super.key,
    required this.username,
    this.avatarType = 'initial',
    this.avatarEmoji,
    this.avatarColor,
    this.avatarUrl,
    this.resolveUrl,
    this.radius = 16,
  });

  @override
  Widget build(BuildContext context) {
    if (avatarType == 'photo' && avatarUrl != null) {
      final url = resolveUrl == null ? avatarUrl! : resolveUrl!(avatarUrl!);
      return CircleAvatar(radius: radius, backgroundImage: NetworkImage(url));
    }
    if (avatarType == 'character' && avatarEmoji != null) {
      return CircleAvatar(
        radius: radius,
        backgroundColor:
            parseHexColor(avatarColor) ??
            Theme.of(context).colorScheme.primaryContainer,
        child: Text(avatarEmoji!, style: TextStyle(fontSize: radius)),
      );
    }
    return CircleAvatar(
      radius: radius,
      child: Text(
        username.isNotEmpty ? username[0] : '?',
        style: TextStyle(fontSize: radius * 0.8),
      ),
    );
  }
}
