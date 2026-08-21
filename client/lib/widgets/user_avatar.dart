import 'package:flutter/material.dart';

import '../models/app_user.dart';
import 'avatar_utils.dart';

/// 다른 사용자(방 멤버 등)의 아바타. AppUser에 담긴 avatarType/emoji/color/url을 그대로 그린다.
class UserAvatar extends StatelessWidget {
  final AppUser user;
  final String Function(String relative)? resolveUrl;
  final double radius;
  const UserAvatar({super.key, required this.user, this.resolveUrl, this.radius = 16});

  @override
  Widget build(BuildContext context) {
    return AvatarView(
      username: user.name,
      avatarType: user.avatarType,
      avatarEmoji: user.avatarEmoji,
      avatarColor: user.avatarColor,
      avatarUrl: user.avatarUrl,
      resolveUrl: resolveUrl,
      radius: radius,
    );
  }
}
