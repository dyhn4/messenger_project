import 'package:flutter/material.dart';

import '../models/app_user.dart';
import 'avatar_utils.dart';

/// 다른 사용자(방 멤버 등)의 아바타. AppUser에 담긴 avatarType/emoji/color/url을 그대로 그린다.
/// [online]이 true면 오른쪽 아래에 초록 점을 겹쳐 보여준다(지금 로그인/접속 중이라는 뜻).
class UserAvatar extends StatelessWidget {
  final AppUser user;
  final String Function(String relative)? resolveUrl;
  final double radius;
  final bool online;
  const UserAvatar({
    super.key,
    required this.user,
    this.resolveUrl,
    this.radius = 16,
    this.online = false,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = AvatarView(
      username: user.name,
      avatarType: user.avatarType,
      avatarEmoji: user.avatarEmoji,
      avatarColor: user.avatarColor,
      avatarUrl: user.avatarUrl,
      resolveUrl: resolveUrl,
      radius: radius,
    );
    if (!online) return avatar;

    final dotSize = radius * 0.55;
    return SizedBox(
      width: radius * 2,
      height: radius * 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: dotSize,
              height: dotSize,
              decoration: BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: dotSize * 0.18,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
