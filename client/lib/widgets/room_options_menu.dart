import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../screens/announcement_list_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/home_screen.dart' show wideBreakpoint;
import '../screens/invite_members_screen.dart';
import '../screens/member_profile_dialog.dart';
import '../screens/my_profile_dialog.dart';
import '../services/session.dart';
import 'export_chat_dialog.dart';
import 'floating_dialog.dart';
import 'self_destruct_picker_dialog.dart';
import 'user_avatar.dart';

/// RoomOptionsMenu의 자동 삭제 타이머 항목 트레일링 표시용 — self_destruct_picker_dialog.dart의
/// 프리셋(1초/5초/30초/1분/5분/1시간/1일/1주) 라벨과 맞춘 짧은 문구.
String _formatSeconds(int seconds) {
  if (seconds >= 7 * 24 * 60 * 60) return '1주';
  if (seconds >= 24 * 60 * 60) return '1일';
  if (seconds >= 60 * 60) return '1시간';
  if (seconds >= 60) return '${seconds ~/ 60}분';
  return '$seconds초';
}

/// 방 나가기/숨기기 확인 대화상자 + 실행 — 채팅 화면의 "더보기" 메뉴와 방 목록의 길게 누르기
/// 메뉴가 공용으로 쓴다(room_list_screen.dart 참고). 진입 버튼은 평문 DM만 "채팅방 숨기기"로
/// 표시하고(다시 대화를 시작하면 예전 내용이 복원되는 게 기본 동작이라서), 그룹/토픽/비밀
/// 대화는 "나가기"로 표시한다.
///
/// 평문 DM은 대화상자 안에 "나가기" 체크박스가 하나 더 있다 — 체크 안 하면(기본) 지금까지와
/// 동일하게 그냥 숨기기만 하고, 체크하면 진짜 나가기가 되어(서버가 dm_history_floors에 시각을
/// 남김) 나중에 다시 대화해도 그 이전 메시지/파일/검색 결과가 안 보인다. 체크 여부에 따라
/// 대화상자 제목/본문/버튼 문구가 "숨기기"↔"나가기"로 그 자리에서 바뀐다.
Future<void> showLeaveRoomDialog(
  BuildContext context,
  Session session,
  Room room,
) async {
  final isDm = room.type == RoomType.dm;
  final isTopic = room.type == RoomType.topic;
  // 비밀 대화는 "나만 목록에서 숨기기"가 의미가 없다(서버가 내용을 못 보므로) — 항상
  // "나가기"로 표시하고, 상대방도 같이 나가지는지는 아래 체크박스로 고른다.
  final staticLabel = room.isSecret
      ? '채팅방 나가기'
      : (isDm ? '채팅방 숨기기' : (isTopic ? '토픽 나가기' : '채팅방 나가기'));
  var alsoRemoveOther = false;
  // 평문 DM 전용 — 기본(체크 안 함)은 지금처럼 "숨기기"(다시 대화하면 예전 내용이 그대로
  // 복원됨), 체크하면 "진짜 나가기"(다시 대화해도 예전 내용이 안 보임)로 문구/버튼이
  // 전부 바뀐다(room_options_menu.dart 상단 주석, 서버 dm_history_floors 참고).
  final plainDm = !room.isSecret && isDm;
  var realLeave = false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) {
        final label = plainDm && realLeave ? '채팅방 나가기' : staticLabel;
        return AlertDialog(
          title: Text(label),
          // 체크박스 상태에 따라 안내 문구 길이가 달라지는데, 폭을 안 고정해두면 그 자연스러운
          // 한 줄 너비만큼 대화상자 자체가 가로로 커졌다 줄었다 한다 — 고정폭을 줘서 문구는
          // 그 안에서 줄바꿈되게 하고 대화상자 크기는 체크 여부와 무관하게 그대로 둔다.
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  room.isSecret
                      ? '\'${room.displayName(session.userId ?? '')}\' 비밀 대화를 나가시겠습니까?'
                      : plainDm
                      ? (realLeave
                            ? '\'${room.displayName(session.userId ?? '')}\' 방에서 나가시겠습니까? 나중에 다시 대화를 시작해도 예전 내용은 보이지 않습니다.'
                            : '\'${room.displayName(session.userId ?? '')}\' 방을 목록에서 숨기시겠습니까? 나중에 다시 대화를 시작하면 예전 내용이 그대로 보입니다.')
                      : '\'${room.displayName(session.userId ?? '')}\' 방에서 나가시겠습니까?',
                ),
                if (room.isSecret)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: alsoRemoveOther,
                    onChanged: (v) =>
                        setDialogState(() => alsoRemoveOther = v ?? false),
                    title: const Text('상대방도 나가기'),
                    subtitle: const Text('(양쪽 방 폭파)'),
                  ),
                if (plainDm)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: realLeave,
                    onChanged: (v) =>
                        setDialogState(() => realLeave = v ?? false),
                    title: const Text('나가기'),
                    subtitle: const Text('(체크하면 다시 대화해도 예전 내용이 안 보입니다)'),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                plainDm ? (realLeave ? '나가기' : '숨기기') : '나가기',
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          ],
        );
      },
    ),
  );
  if (confirmed != true) return;

  await session.leaveRoom(
    room.id,
    alsoRemoveOther: room.isSecret && alsoRemoveOther,
    realLeave: plainDm && realLeave,
  );
  if (context.mounted) {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }
}

/// 평문 1:1 채팅방을 "체크박스로 나가기까지 고르는" showLeaveRoomDialog 없이, 숨기기 하나만
/// 가볍게 확인하고 싶은 곳(desktop_home_screen.dart의 방 목록 우클릭 메뉴 "숨기기"/호버 X)이
/// 쓴다. 되돌릴 수 있는 동작이라(다시 대화를 시작하면 예전 내용이 그대로 복원됨) 삭제/나가기
/// 같은 빨간 경고색은 쓰지 않는다.
Future<void> showHideDmDialog(
  BuildContext context,
  Session session,
  Room room,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('채팅방 숨기기'),
      content: Text(
        '\'${room.displayName(session.userId ?? '')}\' 방을 목록에서 숨기시겠습니까?'
        ' 나중에 다시 대화를 시작하면 예전 내용이 그대로 보입니다.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('숨기기'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  await session.leaveRoom(room.id);
}

/// 채팅 화면 우측 상단의 "더보기" 메뉴: 멤버 목록/초대(토픽·그룹만) + 나가기(전부).
/// DM은 멤버가 항상 나+상대방 둘뿐이라 멤버 목록/초대는 의미가 없어서 나가기만 보여준다.
class RoomOptionsMenu extends StatelessWidget {
  final Session session;
  final Room room;
  const RoomOptionsMenu({super.key, required this.session, required this.room});

  Future<void> _openMemberProfile(BuildContext context, AppUser member) async {
    if (member.id == session.userId) {
      showDialog(
        context: context,
        builder: (_) => MyProfileDialog(session: session),
      );
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
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(session: session, room: room),
        ),
      );
    }
  }

  void _showMembers(BuildContext context) {
    final sorted = room.members.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
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

  @override
  Widget build(BuildContext context) {
    final isDm = room.type == RoomType.dm;
    final isTopic = room.type == RoomType.topic;
    final leaveLabel = room.isSecret
        ? '채팅방 나가기'
        : (isDm ? '채팅방 숨기기' : (isTopic ? '토픽 나가기' : '채팅방 나가기'));

    return PopupMenuButton<void>(
      icon: const Icon(Icons.more_vert),
      tooltip: '더보기',
      itemBuilder: (context) => [
        PopupMenuItem<void>(
          onTap: () => session.toggleMuted(room),
          child: Row(
            children: [
              Icon(
                room.muted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
              ),
              const SizedBox(width: 8),
              Text(room.muted ? '알림 켜기' : '알림 끄기'),
            ],
          ),
        ),
        // 공지는 읽기가 방 멤버 전원에게 열려 있으므로(채팅방 상단 배너, 히스토리 목록) 이
        // 메뉴 항목 자체는 누구나 본다 — "글쓰기" 버튼만 토픽 생성 권한이 있는 사람에게 보인다
        // (announcement_list_screen.dart의 _canWrite).
        if (isTopic)
          PopupMenuItem<void>(
            onTap: () => showAnnouncementListScreen(context, session, room),
            child: const Row(
              children: [
                Icon(Icons.campaign_outlined),
                SizedBox(width: 8),
                Text('공지'),
              ],
            ),
          ),
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
          // 초대 권한은 팀 설정(초대 권한: 정회원 이상 / 관리자만)과 내 등급에 달려 있다.
          if (session.canInviteToRooms)
            PopupMenuItem<void>(
              onTap: () {
                // home_screen.dart의 wideBreakpoint(700)와 맞춰서, 넓은(PC) 화면에서는
                // "새 대화"처럼 플로팅으로, 좁은(모바일) 화면에서는 전체화면으로 띄운다.
                final isWide = MediaQuery.sizeOf(context).width >= 700;
                if (isWide) {
                  showDialog(
                    context: context,
                    builder: (_) => InviteMembersScreen(
                      session: session,
                      room: room,
                      asDialog: true,
                    ),
                  );
                } else {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          InviteMembersScreen(session: session, room: room),
                    ),
                  );
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
        if (room.isSecret)
          PopupMenuItem<void>(
            onTap: () => showDialog(
              context: context,
              builder: (_) =>
                  SelfDestructPickerDialog(session: session, room: room),
            ),
            child: Row(
              children: [
                const Icon(Icons.timer_outlined),
                const SizedBox(width: 8),
                Text(
                  room.secretSelfDestructSeconds == null
                      ? '자동 삭제 타이머'
                      : '자동 삭제 타이머 (${_formatSeconds(room.secretSelfDestructSeconds!)})',
                ),
              ],
            ),
          ),
        // 비밀 대화는 서버가 평문을 몰라서(종단간 암호화) 지원하지 않는다 — export_chat_dialog.dart 참고.
        if (!room.isSecret)
          PopupMenuItem<void>(
            onTap: () => showExportChatDialog(context, session, room),
            child: const Row(
              children: [
                Icon(Icons.file_download_outlined),
                SizedBox(width: 8),
                Text('대화 내보내기'),
              ],
            ),
          ),
        PopupMenuItem<void>(
          onTap: () => showLeaveRoomDialog(context, session, room),
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
