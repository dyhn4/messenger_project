import 'package:flutter/material.dart';

Color? parseHexColor(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  final v = hex.replaceFirst('#', '');
  final full = v.length == 6 ? 'FF$v' : v;
  return Color(int.parse(full, radix: 16));
}

String colorToHex(Color color) =>
    '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}';

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
