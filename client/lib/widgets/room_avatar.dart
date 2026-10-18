import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../services/session.dart';
import 'avatar_utils.dart';
import 'my_avatar.dart';
import 'user_avatar.dart';
import '../l10n/tr.dart';

/// 아바타 오른쪽 아래에 작은 '나' 꼬리표를 붙인다 — 나와의 대화 표시. 비밀 대화 자물쇠 배지처럼
/// 아바타 자리([size])는 그대로 두고 꼬리표만 살짝 밖으로 걸쳐 그린다(목록 줄 정렬이 안 흔들리게).
class MeTagAvatar extends StatelessWidget {
  final Widget avatar;
  final double size;
  const MeTagAvatar({super.key, required this.avatar, required this.size});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fontSize = (size * 0.34).clamp(8.0, 14.0);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: -size * 0.12,
            bottom: -size * 0.08,
            child: Container(
              key: const ValueKey('self-room-me-tag'),
              padding: EdgeInsets.symmetric(horizontal: fontSize * 0.32),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(fontSize),
                border: Border.all(
                  color: theme.scaffoldBackgroundColor,
                  width: 1.5,
                ),
              ),
              child: Text(
                tr('나'),
                style: TextStyle(
                  fontSize: fontSize,
                  height: 1.25,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 나와의 대화 아바타(목록의 고정 줄·대화 헤더) — 방 멤버 정보는 내 사진을 바꿔도 바로 안 바뀌어서,
/// 지금 세션의 내 아바타에 '나' 꼬리표를 붙여 그린다.
class SelfRoomAvatar extends StatelessWidget {
  final Session session;
  final double size;
  const SelfRoomAvatar({super.key, required this.session, this.size = 28});

  @override
  Widget build(BuildContext context) => MeTagAvatar(
    size: size,
    avatar: MyAvatar(session: session, radius: size / 2),
  );
}

/// 채팅방 제목 왼쪽에 쓰는 작은 아바타. DM은 상대방 아바타 하나, 그룹은 멤버 아바타
/// 두 개를 겹쳐서 보여준다. 토픽은 방 이름 자체에 의미가 있어서 별도 아바타를 안 보여준다.
/// 나와의 대화는 내 아바타에 '나' 꼬리표([MeTagAvatar]).
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

    // 나와의 대화는 멤버가 나 하나라 내 아바타 — 내 접속 표시(초록 점)는 뜻이 없어 뺀다.
    if (room.isSelf) {
      AppUser? me;
      for (final m in room.members) {
        if (m.id == myUserId) me = m;
      }
      me ??= room.members.firstOrNull;
      return MeTagAvatar(
        size: size,
        avatar: me == null
            ? CircleAvatar(radius: size / 2, child: const Text('?'))
            : UserAvatar(user: me, resolveUrl: resolveUrl, radius: size / 2),
      );
    }

    // 그룹채팅 아이콘 — 새 그룹채팅 만들기·채팅 정보 변경에서 골랐으면(group_icon_picker.dart) 멤버
    // 아바타 대신 이걸 보여준다.
    // null/'members'는 기존처럼 아래로 내려가 멤버 아바타를 겹쳐 보여준다.
    if (room.type == RoomType.group &&
        room.iconType != null &&
        room.iconType != 'members') {
      final name = room.displayName(myUserId);
      if (room.iconType == 'photo' && room.iconUrl != null) {
        return CircleAvatar(
          radius: size / 2,
          backgroundImage: NetworkImage(resolveUrl(room.iconUrl!)),
        );
      }
      if (room.iconType == 'emoji' && room.iconEmoji != null) {
        return AvatarView(
          username: name,
          avatarType: 'character',
          avatarEmoji: room.iconEmoji,
          avatarColor: room.iconColor,
          radius: size / 2,
        );
      }
      if (room.iconType == 'initial') {
        return InitialsAvatar(
          name: name,
          color: parseHexColor(room.iconColor),
          radius: size / 2,
        );
      }
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
