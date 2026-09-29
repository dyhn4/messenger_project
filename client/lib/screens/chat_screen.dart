import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/session.dart';
import '../widgets/chat_panel.dart';
import '../widgets/private_topic_lock.dart';
import '../widgets/room_avatar.dart';
import '../widgets/room_options_menu.dart';
import 'message_thread_screen.dart';

/// 모바일(좁은 화면)에서 방을 열 때 전체화면으로 띄우는 화면.
/// 넓은 화면(PC)에서는 DesktopHomeScreen이 이 화면을 쓰지 않고
/// ChatPanel을 우측 패널에 직접 임베드한다.
class ChatScreen extends StatefulWidget {
  final Session session;
  final Room room;
  final String? highlightMessageId;
  const ChatScreen({
    super.key,
    required this.session,
    required this.room,
    this.highlightMessageId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    super.dispose();
  }

  /// 비밀 대화는 나 또는 상대방 누구든 나가면 방 자체가 없어진다(session.dart의
  /// secret:left 처리 참고) — 지금 이 방을 보고 있는 도중에 상대가 나가서 방이 사라지면,
  /// 이미 지워진 컨트롤러를 계속 들고 있는 화면에 남아있지 않도록 목록으로 돌아간다.
  /// 토픽이 삭제되거나 내보내졌을 때(room:removed)도 같다.
  void _onSessionChanged() {
    final stillExists = widget.session.rooms.any((r) => r.id == widget.room.id);
    if (!stillExists && mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  /// 앱바 제목 — 토픽 이름·공개 여부·읽기 전용·보관이 그 자리에서 바뀌므로 세션 변경을 따라
  /// 다시 그린다(대화 목록 본문까지 다시 그리지 않게 제목만).
  Widget _buildTitle(BuildContext context, Room room) {
    final session = widget.session;
    final otherMember = room.type == RoomType.dm
        ? room.members.where((m) => m.id != session.userId).firstOrNull
        : null;
    final isTopic = room.type == RoomType.topic;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 휴대폰 앱바는 오른쪽 버튼들(멤버·알림·초대·더보기) 때문에 제목 자리가 좁다 — 좁으면
        // 상태 배지를 이름 아래 줄로 내려서, 이름 옆에 붙였을 때처럼 토픽 이름이 한두 글자만
        // 남지 않게 한다.
        final compact = constraints.maxWidth < 240;
        final Widget? stateBadge = !isTopic
            ? null
            : room.isArchived
            ? const TopicBadge.archived(key: ValueKey('chat-header-archived'))
            : room.readOnly
            ? const TopicBadge.readOnly(key: ValueKey('chat-header-read-only'))
            : null;
        final nameRow = Row(
          children: [
            RoomAvatar(
              room: room,
              myUserId: session.userId ?? '',
              resolveUrl: session.resolveUrl,
              onlineUserIds: session.onlineUserIds,
              size: 24,
            ),
            const SizedBox(width: 8),
            if (room.isSecret) ...[
              const Icon(Icons.lock, size: 14, color: Colors.green),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                room.displayName(session.userId ?? ''),
                overflow: TextOverflow.ellipsis,
                style: room.isSecret
                    ? const TextStyle(color: Colors.green)
                    : null,
              ),
            ),
            if (room.isPrivateTopic) const PrivateTopicLock(size: 16),
            if (stateBadge != null && !compact) ...[
              const SizedBox(width: 6),
              stateBadge,
            ],
            // 방 목록의 배지와 달리 헤더는 등급(조장 이상)과 무관하게 직책이 있으면
            // 그냥 글자로 보여준다 — desktop_home_screen.dart의 헤더와 동일한 규칙.
            if (otherMember?.position != null &&
                otherMember!.position!.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                otherMember.position!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).hintColor,
                ),
              ),
            ],
          ],
        );
        if (stateBadge == null || !compact) return nameRow;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [nameRow, const SizedBox(height: 2), stateBadge],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final room = widget.room;
    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: session,
          builder: (context, _) =>
              _buildTitle(context, session.roomById(room.id) ?? room),
        ),
        actions: [RoomOptionsMenu(session: session, room: room)],
      ),
      body: ChatPanel(
        key: ValueKey(room.id),
        session: session,
        room: room,
        highlightMessageId: widget.highlightMessageId,
        onOpenThread: (m) => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => MessageThreadScreen(
              session: session,
              room: room,
              message: m,
              controller: session.controllerFor(room),
            ),
          ),
        ),
      ),
    );
  }
}
