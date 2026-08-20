import 'package:flutter/material.dart';

import '../services/session.dart';
import 'avatar_utils.dart';

export 'avatar_utils.dart' show parseHexColor, colorToHex;

/// 로그인한 나의 아바타.
class MyAvatar extends StatelessWidget {
  final Session session;
  final double radius;
  const MyAvatar({super.key, required this.session, this.radius = 16});

  @override
  Widget build(BuildContext context) {
    return AvatarView(
      username: session.username ?? '',
      avatarType: session.avatarType,
      avatarEmoji: session.avatarEmoji,
      avatarColor: session.avatarColor,
      avatarUrl: session.avatarUrl,
      resolveUrl: session.resolveUrl,
      radius: radius,
    );
  }
}
