import 'package:flutter/material.dart';

import '../models/room.dart';
import 'user_avatar.dart';

/// 채팅방 제목 왼쪽에 쓰는 작은 아바타. DM은 상대방 아바타 하나, 그룹은 멤버 아바타
/// 두 개를 겹쳐서, 토픽은 # 아이콘을 보여준다.
class RoomAvatar extends StatelessWidget {
  final Room room;
  final String myUserId;
  final String Function(String relative) resolveUrl;
  final double size;
  const RoomAvatar({
    super.key,
    required this.room,
    required this.myUserId,
    required this.resolveUrl,
    this.size = 28,
  });

  @override
  Widget build(BuildContext context) {
    if (room.type == RoomType.topic) {
      return CircleAvatar(radius: size / 2, child: Icon(Icons.tag, size: size * 0.55));
    }

    final others = room.members.where((m) => m.id != myUserId).toList();
    final shown = (others.isEmpty ? room.members : others).take(2).toList();
    if (shown.isEmpty) {
      return CircleAvatar(radius: size / 2, child: const Text('?'));
    }
    if (shown.length == 1) {
      return UserAvatar(user: shown[0], resolveUrl: resolveUrl, radius: size / 2);
    }

    // 그룹: 멤버 아바타 두 개를 살짝 겹쳐서 보여준다.
    return SizedBox(
      width: size * 1.5,
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * size * 0.5,
              child: CircleAvatar(
                radius: size / 2,
                backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                child: UserAvatar(user: shown[i], resolveUrl: resolveUrl, radius: size / 2 - 1.5),
              ),
            ),
        ],
      ),
    );
  }
}
