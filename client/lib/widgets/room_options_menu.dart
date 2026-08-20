import 'package:flutter/material.dart';

import '../models/room.dart';
import '../screens/invite_members_screen.dart';
import '../services/session.dart';
import 'floating_dialog.dart';

/// 채팅 화면 우측 상단의 "더보기" 메뉴: 멤버 목록/초대(토픽·그룹만) + 나가기(전부).
/// DM은 멤버가 항상 나+상대방 둘뿐이라 멤버 목록/초대는 의미가 없어서 나가기만 보여준다.
/// DM의 "나가기"는 지금 동작이 실제로는 기록을 지우지 않고 목록에서만 숨기는 것이라
/// (다시 대화를 시작하면 예전 내용이 복원됨) 문구를 "채팅방 숨기기"로 표시한다 — 동작은 동일.
class RoomOptionsMenu extends StatelessWidget {
  final Session session;
  final Room room;
  const RoomOptionsMenu({super.key, required this.session, required this.room});

  void _showMembers(BuildContext context) {
    final sorted = room.members.toList()..sort((a, b) => a.username.compareTo(b.username));
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
                  leading: CircleAvatar(child: Text(m.username.isNotEmpty ? m.username[0] : '?')),
                  title: Text(m.username),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _leave(BuildContext context) async {
    final isDm = room.type == RoomType.dm;
    final label = isDm ? '채팅방 숨기기' : '채팅방 나가기';
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
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => InviteMembersScreen(session: session, room: room))),
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
              Text(isDm ? '채팅방 숨기기' : '채팅방 나가기', style: const TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
      ],
    );
  }
}
