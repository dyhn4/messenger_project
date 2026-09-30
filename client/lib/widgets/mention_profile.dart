import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/mention.dart';
import '../models/room.dart';
import '../screens/chat_screen.dart';
import '../screens/home_screen.dart' show wideBreakpoint;
import '../screens/member_profile_dialog.dart';
import '../screens/my_profile_dialog.dart';
import '../services/session.dart';
import 'app_toast.dart';

/// 말풍선·댓글·게시글 안의 멘션 이름([mention])을 눌렀을 때 — 그 사람의 프로필을 연다. 말풍선의 아바타/이름을
/// 눌렀을 때와 같다(나면 내 프로필, 남이면 멤버 프로필 카드 — 거기서 "1:1 메시지"를 고르면 그 방으로 간다).
/// [roomId]의 멤버 목록에서 찾고, 이미 그 방을 나간 사람이면 안내만 한다. @all은 누르는 대상이 아니다.
Future<void> openMentionProfile(
  BuildContext context,
  Session session, {
  required String roomId,
  required Mention mention,
}) async {
  final userId = mention.userId;
  if (mention.isAll || userId == null) return;
  if (userId == session.userId) {
    await showDialog<void>(
      context: context,
      builder: (_) => MyProfileDialog(session: session),
    );
    return;
  }
  AppUser? user;
  for (final m in session.roomById(roomId)?.members ?? const <AppUser>[]) {
    if (m.id == userId) {
      user = m;
      break;
    }
  }
  if (user == null) {
    showAppToast(context, '이 대화에서 나간 멤버입니다.');
    return;
  }
  final found = user;
  final room = await showDialog<Room>(
    context: context,
    builder: (_) => MemberProfileDialog(session: session, user: found),
  );
  if (room == null || !context.mounted) return;
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
