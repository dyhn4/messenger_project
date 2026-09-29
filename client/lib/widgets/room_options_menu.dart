import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/room.dart';
import '../screens/announcement_list_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/files_screen.dart';
import '../screens/home_screen.dart' show wideBreakpoint;
import '../screens/invite_members_screen.dart';
import '../screens/links_screen.dart';
import '../screens/member_profile_dialog.dart';
import '../screens/my_profile_dialog.dart';
import '../screens/topic_members_dialog.dart';
import '../screens/topic_settings_dialog.dart';
import '../services/api_client.dart' show ApiException;
import '../services/session.dart';
import 'app_toast.dart';
import 'export_chat_dialog.dart';
import 'floating_dialog.dart';
import 'self_destruct_picker_dialog.dart';
import 'user_avatar.dart';

/// 토픽 이름 옆에 붙이는 작은 상태 배지(보드 뷰 · 읽기 전용 · 보관됨) — 참여 가능한 토픽 목록과
/// 모바일 대화 헤더(좁으면 이름 아래 줄)가 같이 쓴다.
class TopicBadge extends StatelessWidget {
  final String label;
  final IconData icon;
  const TopicBadge({super.key, required this.label, required this.icon});

  const TopicBadge.board({super.key})
    : label = '보드 뷰',
      icon = Icons.dashboard_outlined;

  const TopicBadge.readOnly({super.key})
    : label = '읽기 전용',
      icon = Icons.edit_off_outlined;

  const TopicBadge.archived({super.key})
    : label = '보관됨',
      icon = Icons.inventory_2_outlined;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

/// [context]가 속한 라우트(대화상자·전체 화면)를 닫는다 — 맨 위가 아니어도 닫고, 이미 닫히는
/// 중이면(다른 화면이 먼저 목록까지 되돌렸으면) 아무것도 안 한다. 엉뚱한 화면을 닫지 않도록
/// Navigator.pop 대신 이걸 쓴다.
void closeOwnRoute(BuildContext context) {
  final route = ModalRoute.of(context);
  if (route == null || !route.isActive) return;
  final navigator = Navigator.of(context);
  if (route.isCurrent) {
    navigator.pop();
  } else {
    navigator.removeRoute(route);
  }
}

/// 한 방을 다루는 대화상자·화면(토픽 정보 변경하기 · 참여 멤버 · 멤버 초대하기)이 그 방이 목록에서
/// 사라지면(토픽 삭제 · 내보내짐 · 나가기) 스스로 닫히게 한다. 열 때 목록에 있던 방만 지켜본다 —
/// 목록 밖 방으로 연 화면(테스트 등)이 엉뚱하게 닫히지 않게.
mixin CloseWhenRoomRemoved<T extends StatefulWidget> on State<T> {
  Session get roomSession;
  String get watchedRoomId;

  bool _roomWasListed = false;

  @override
  void initState() {
    super.initState();
    _roomWasListed = roomSession.roomById(watchedRoomId) != null;
    roomSession.addListener(_closeIfRoomRemoved);
  }

  @override
  void dispose() {
    roomSession.removeListener(_closeIfRoomRemoved);
    super.dispose();
  }

  void _closeIfRoomRemoved() {
    if (!_roomWasListed || !mounted) return;
    if (roomSession.roomById(watchedRoomId) != null) return;
    _roomWasListed = false;
    closeOwnRoute(context);
  }
}

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

  try {
    await session.leaveRoom(
      room.id,
      alsoRemoveOther: room.isSecret && alsoRemoveOther,
      realLeave: plainDm && realLeave,
    );
  } catch (e) {
    if (!context.mounted) return;
    // 마지막 토픽 관리자는 다른 멤버가 남아 있으면 못 나간다(서버가 거절) — 그 안내를 그대로
    // 보여 주고, 바로 토픽 관리자를 지정할 수 있게 "토픽 멤버 관리" 탭으로 안내한다.
    if (isTopic && e is ApiException && e.message.contains('토픽 관리자')) {
      await _showCannotLeaveTopicDialog(context, session, room, e.message);
    } else {
      showAppToast(context, '나가지 못했습니다: $e');
    }
    return;
  }
  if (context.mounted) {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }
}

Future<void> _showCannotLeaveTopicDialog(
  BuildContext context,
  Session session,
  Room room,
  String message,
) async {
  final canManage = room.canManage(session);
  final openMembers = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('토픽을 나갈 수 없습니다'),
      content: SizedBox(width: 340, child: Text(message)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('닫기'),
        ),
        if (canManage)
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('토픽 관리자 지정하기'),
          ),
      ],
    ),
  );
  if (openMembers != true || !context.mounted) return;
  await showTopicSettingsDialog(
    context,
    session,
    room,
    initialTab: TopicSettingsTab.members,
  );
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

/// 채팅 화면 우측 상단 — 자주 쓰는 **멤버(인원 수) · 알림 켜기/끄기 · 멤버 초대**는 "더보기" 왼쪽에
/// 아이콘으로 꺼내 두고, 나머지(공지 · 파일 보기 · 링크 보기 · 자동 삭제 타이머 · 대화 내보내기 ·
/// 나가기)는 "더보기" 메뉴에 둔다. DM은 멤버가 항상 나+상대방 둘뿐이라 멤버/초대 아이콘이 없다.
class RoomOptionsMenu extends StatelessWidget {
  final Session session;
  final Room room;

  /// "파일 보기"/"링크 보기" — PC는 오른쪽 패널을 이 방으로 걸러서 연다(desktop_home_screen.dart).
  /// 안 주면(모바일) 전체화면으로 연다.
  final ValueChanged<Room>? onOpenFiles;
  final ValueChanged<Room>? onOpenLinks;

  const RoomOptionsMenu({
    super.key,
    required this.session,
    required this.room,
    this.onOpenFiles,
    this.onOpenLinks,
  });

  void _openFiles(BuildContext context) {
    final handler = onOpenFiles;
    if (handler != null) return handler(room);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (routeContext) => Scaffold(
          body: SafeArea(
            child: FilesScreen(
              session: session,
              initialRoomId: room.id,
              onClose: () => Navigator.of(routeContext).pop(),
            ),
          ),
        ),
      ),
    );
  }

  /// 모바일의 "링크 보기" — "대화방에서 보기"를 누르면 링크 화면을 닫고, 지금 채팅 화면을 그 방
  /// (해당 메시지로 스크롤한) 화면으로 바꾼다.
  void _openLinks(BuildContext context) {
    final handler = onOpenLinks;
    if (handler != null) return handler(room);
    final navigator = Navigator.of(context);
    navigator.push(
      MaterialPageRoute(
        builder: (routeContext) => Scaffold(
          body: SafeArea(
            child: LinksScreen(
              session: session,
              initialRoomId: room.id,
              onClose: () => Navigator.of(routeContext).pop(),
              onOpenMessage: (target, messageId) {
                Navigator.of(routeContext).pop();
                navigator.pushReplacement(
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(
                      session: session,
                      room: target,
                      highlightMessageId: messageId,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  void _invite(BuildContext context, Room room) {
    showInviteMembers(context, session, room);
  }

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

  void _showMembers(BuildContext context, Room room) {
    // 토픽은 순서·배지·검색·내보내기가 있는 "참여 멤버" 창, 그룹은 지금까지의 간단한 목록.
    if (room.type == RoomType.topic) {
      showTopicMembersDialog(context, session, room);
      return;
    }
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
    // 멤버 수·알림 상태·"정보 변경하기"(토픽 관리자 지정/해제)가 그 자리에서 바뀌므로, 헤더가
    // 다시 그려지지 않아도 이 줄만은 세션 변경을 따라간다.
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) =>
          _buildRow(context, session.roomById(room.id) ?? room),
    );
  }

  Widget _buildRow(BuildContext context, Room room) {
    final isDm = room.type == RoomType.dm;
    final isTopic = room.type == RoomType.topic;
    final leaveLabel = room.isSecret
        ? '채팅방 나가기'
        : (isDm ? '채팅방 숨기기' : (isTopic ? '토픽 나가기' : '채팅방 나가기'));
    final iconColor = IconTheme.of(context).color;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!isDm)
          Tooltip(
            message: '멤버',
            child: TextButton.icon(
              onPressed: () => _showMembers(context, room),
              style: TextButton.styleFrom(
                foregroundColor: iconColor,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(40, 40),
              ),
              icon: const Icon(Icons.people_outline, size: 22),
              label: Text('${room.members.length}'),
            ),
          ),
        IconButton(
          icon: Icon(
            room.muted
                ? Icons.notifications_off_outlined
                : Icons.notifications_none_outlined,
          ),
          tooltip: room.muted ? '알림 켜기' : '알림 끄기',
          onPressed: () => session.toggleMuted(room),
        ),
        // 초대 권한은 팀 설정(초대 권한: 정회원 이상 / 관리자만)과 내 등급에 달려 있다.
        if (!isDm && session.canInviteToRooms)
          IconButton(
            icon: const Icon(Icons.person_add_alt_outlined),
            tooltip: '멤버 초대',
            onPressed: () => _invite(context, room),
          ),
        PopupMenuButton<void>(
          icon: const Icon(Icons.more_vert),
          tooltip: '더보기',
          itemBuilder: (context) => [
            // 공지는 읽기가 방 멤버 전원에게 열려 있으므로(채팅방 상단 배너, 히스토리 목록) 이
            // 메뉴 항목 자체는 누구나 본다 — "글쓰기" 버튼만 토픽 생성 권한이 있는 사람에게
            // 보인다(announcement_list_screen.dart의 _canWrite).
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
            // 비밀 대화는 서버가 내용을 몰라서(종단간 암호화) 파일·링크 모아보기에서 빠진다.
            if (!room.isSecret) ...[
              PopupMenuItem<void>(
                onTap: () => _openFiles(context),
                child: const Row(
                  children: [
                    Icon(Icons.insert_drive_file_outlined),
                    SizedBox(width: 8),
                    Text('파일 보기'),
                  ],
                ),
              ),
              PopupMenuItem<void>(
                onTap: () => _openLinks(context),
                child: const Row(
                  children: [
                    Icon(Icons.link),
                    SizedBox(width: 8),
                    Text('링크 보기'),
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
            // 토픽을 관리할 수 있는 사람(토픽 관리자·팀 관리자)만 — 이름·설정·보관·삭제·멤버 관리.
            if (isTopic && room.canManage(session))
              PopupMenuItem<void>(
                onTap: () => showTopicSettingsDialog(context, session, room),
                child: const Row(
                  children: [
                    Icon(Icons.edit_outlined),
                    SizedBox(width: 8),
                    Text('정보 변경하기'),
                  ],
                ),
              ),
            PopupMenuItem<void>(
              onTap: () => showLeaveRoomDialog(context, session, room),
              child: Row(
                children: [
                  const Icon(Icons.exit_to_app, color: Colors.redAccent),
                  const SizedBox(width: 8),
                  Text(
                    leaveLabel,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 그룹채팅방 이름을 나에게만 바꾼다(다른 멤버에게는 그대로) — 비우고 저장하면 원래 이름으로.
/// 채팅방 더보기 메뉴, 방 목록 우클릭 메뉴(PC), 길게 누르는 하단 시트(모바일)가 같이 쓴다.
Future<void> showRenameRoomForMeDialog(
  BuildContext context,
  Session session,
  Room room,
) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) => _RenameRoomDialog(
      initial: room.customName ?? '',
      originalName: room.originalDisplayName(session.userId ?? ''),
    ),
  );
  if (result == null) return;
  try {
    await session.renameRoomForMe(room, result);
  } catch (e) {
    if (context.mounted) showAppToast(context, '이름을 바꾸지 못했습니다: $e');
  }
}

/// 메뉴 항목에 보여줄 "이름 변경" 문구 — 별칭을 붙여둔 방이면 원래 방 이름을 괄호로 같이 보여준다.
String renameRoomMenuLabel(Room room, String myUserId) =>
    room.customName == null
    ? '이름 변경'
    : '이름 변경(${room.originalDisplayName(myUserId)})';

/// "이름 변경" 입력 대화상자 — 저장하면 입력값(빈 문자열이면 별칭 삭제)을, 취소하면 null을 돌려준다.
class _RenameRoomDialog extends StatefulWidget {
  final String initial;
  final String originalName;
  const _RenameRoomDialog({required this.initial, required this.originalName});

  @override
  State<_RenameRoomDialog> createState() => _RenameRoomDialogState();
}

class _RenameRoomDialogState extends State<_RenameRoomDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('이름 변경'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '나에게만 바뀌어 보이고, 다른 멤버에게는 영향이 없습니다.\n비우고 저장하면 원래 이름으로 돌아갑니다.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLength: 100,
            decoration: InputDecoration(
              hintText: widget.originalName,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('저장'),
        ),
      ],
    );
  }
}
