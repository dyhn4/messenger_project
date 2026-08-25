import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../screens/chat_screen.dart';
import '../screens/home_screen.dart' show wideBreakpoint;
import '../screens/invite_members_screen.dart';
import '../screens/member_profile_dialog.dart';
import '../screens/my_profile_dialog.dart';
import '../services/session.dart';
import 'floating_dialog.dart';
import 'user_avatar.dart';

/// 채팅 화면 우측 상단의 "더보기" 메뉴: 멤버 목록/초대(토픽·그룹만) + 나가기(전부).
/// DM은 멤버가 항상 나+상대방 둘뿐이라 멤버 목록/초대는 의미가 없어서 나가기만 보여준다.
/// DM의 "나가기"는 지금 동작이 실제로는 기록을 지우지 않고 목록에서만 숨기는 것이라
/// (다시 대화를 시작하면 예전 내용이 복원됨) 문구를 "채팅방 숨기기"로 표시한다 — 동작은 동일.
class RoomOptionsMenu extends StatelessWidget {
  final Session session;
  final Room room;
  const RoomOptionsMenu({super.key, required this.session, required this.room});

  Future<void> _openMemberProfile(BuildContext context, AppUser member) async {
    if (member.id == session.userId) {
      showDialog(context: context, builder: (_) => MyProfileDialog(session: session));
      return;
    }
    // MemberProfileDialog에서 "1:1 메시지"를 누르면 새로 만들어진/기존 DM 방을 반환한다 —
    // 넓은(PC) 화면은 옆 패널만 바꾸고, 좁은(모바일) 화면은 전체화면으로 그 방을 띄운다.
    final room = await showDialog<Room>(
      context: context,
      builder: (_) => MemberProfileDialog(session: session, user: member),
    );
    if (room == null || !context.mounted) return;
    Navigator.of(context).pop(); // 멤버 목록 다이얼로그도 같이 닫는다.
    if (MediaQuery.sizeOf(context).width >= wideBreakpoint) {
      session.requestOpenRoom(room);
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(session: session, room: room)));
    }
  }

  void _showMembers(BuildContext context) {
    final sorted = room.members.toList()..sort((a, b) => a.name.compareTo(b.name));
    showDialog(
      context: context,
      builder: (_) => FloatingDialog(
        title: '멤버 (${sorted.length})',
        child: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final m in sorted)
                ListTile(
                  leading: UserAvatar(user: m, resolveUrl: session.resolveUrl),
                  title: Text(m.name),
                  onTap: () => _openMemberProfile(context, m),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _leave(BuildContext context) async {
    final isDm = room.type == RoomType.dm;
    final isTopic = room.type == RoomType.topic;
    final label = isDm ? '채팅방 숨기기' : (isTopic ? '토픽 나가기' : '채팅방 나가기');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(label),
        content: Text(
          isDm
              ? '\'${room.displayName(session.userId ?? '')}\' 방을 목록에서 숨기시겠습니까? 나중에 다시 대화를 시작하면 예전 내용이 그대로 보입니다.'
              : '\'${room.displayName(session.userId ?? '')}\' 방에서 나가시겠습니까?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(isDm ? '숨기기' : '나가기', style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await session.leaveRoom(room.id);
    if (context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDm = room.type == RoomType.dm;
    final isTopic = room.type == RoomType.topic;
    final leaveLabel = isDm ? '채팅방 숨기기' : (isTopic ? '토픽 나가기' : '채팅방 나가기');

    return PopupMenuButton<void>(
      icon: const Icon(Icons.more_vert),
      tooltip: '더보기',
      itemBuilder: (context) => [
        if (!isDm) ...[
          PopupMenuItem<void>(
            onTap: () => _showMembers(context),
            child: Row(
              children: [
                const Icon(Icons.people_outline),
                const SizedBox(width: 8),
                Text('멤버 (${room.members.length})'),
              ],
            ),
          ),
          PopupMenuItem<void>(
            onTap: () {
              // home_screen.dart의 wideBreakpoint(700)와 맞춰서, 넓은(PC) 화면에서는
              // "새 대화"처럼 플로팅으로, 좁은(모바일) 화면에서는 전체화면으로 띄운다.
              final isWide = MediaQuery.sizeOf(context).width >= 700;
              if (isWide) {
                showDialog(
                  context: context,
                  builder: (_) => InviteMembersScreen(session: session, room: room, asDialog: true),
                );
              } else {
                Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => InviteMembersScreen(session: session, room: room)));
              }
            },
            child: const Row(
              children: [
                Icon(Icons.person_add_alt_outlined),
                SizedBox(width: 8),
                Text('멤버 초대'),
              ],
            ),
          ),
        ],
        PopupMenuItem<void>(
          onTap: () => _leave(context),
          child: Row(
            children: [
              const Icon(Icons.exit_to_app, color: Colors.redAccent),
              const SizedBox(width: 8),
              Text(leaveLabel, style: const TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
      ],
    );
  }
}
