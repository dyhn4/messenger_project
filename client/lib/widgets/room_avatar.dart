import 'package:flutter/material.dart';

import '../models/room.dart';
import 'user_avatar.dart';

/// 채팅방 제목 왼쪽에 쓰는 작은 아바타. DM은 상대방 아바타 하나, 그룹은 멤버 아바타
/// 두 개를 겹쳐서 보여준다. 토픽은 방 이름 자체에 의미가 있어서 별도 아바타를 안 보여준다.
/// [onlineUserIds]에 있는 멤버는 초록 점으로 지금 로그인 중임을 표시한다.
class RoomAvatar extends StatelessWidget {
  final Room room;
  final String myUserId;
  final String Function(String relative) resolveUrl;
  final Set<String> onlineUserIds;
  final double size;
  const RoomAvatar({
    super.key,
    required this.room,
    required this.myUserId,
    required this.resolveUrl,
    required this.onlineUserIds,
    this.size = 28,
  });

  @override
  Widget build(BuildContext context) {
    if (room.type == RoomType.topic) {
      return const SizedBox.shrink();
    }

    final others = room.members.where((m) => m.id != myUserId).toList();
    // 비밀 대화에서 상대방이 혼자 나가면(secretDepartedMemberName만 남고 members엔 없음)
    // room.members로 대체하면 내 아바타가 "상대방 아바타"처럼 보이게 된다 — 그 대신 나간
    // 사람 자리에 중립적인 자리표시자를 보여준다.
    if (room.type == RoomType.dm &&
        others.isEmpty &&
        room.secretDepartedMemberName != null) {
      return CircleAvatar(
        radius: size / 2,
        backgroundColor: Colors.grey.shade400,
        child: Icon(
          Icons.person_off_outlined,
          size: size * 0.55,
          color: Colors.white,
        ),
      );
    }
    final shown = (others.isEmpty ? room.members : others).take(2).toList();
    if (shown.isEmpty) {
      return CircleAvatar(radius: size / 2, child: const Text('?'));
    }
    if (shown.length == 1) {
      final avatar = UserAvatar(
        user: shown[0],
        resolveUrl: resolveUrl,
        radius: size / 2,
        online: onlineUserIds.contains(shown[0].id),
      );
      if (!room.isSecret) return avatar;
      // 비밀 대화는 아바타 오른쪽 아래에 작은 초록 자물쇠 배지를 얹는다(채팅 목록의 녹색
      // 이름과 짝을 이루는 시각 표시).
      return SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            avatar,
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                padding: const EdgeInsets.all(1.5),
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.lock, size: size * 0.4, color: Colors.green),
              ),
            ),
          ],
        ),
      );
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
                child: UserAvatar(
                  user: shown[i],
                  resolveUrl: resolveUrl,
                  radius: size / 2 - 1.5,
                  online: onlineUserIds.contains(shown[i].id),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
