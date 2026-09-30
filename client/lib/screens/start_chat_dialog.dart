import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/session.dart';
import 'home_screen.dart' show wideBreakpoint;
import 'new_chat_screen.dart';

/// 채팅 시작하기 — 넓은 화면(PC)은 떠 있는 창, 좁은 화면(모바일)은 전체 화면으로 띄우고, 만들어진
/// 대화방(1:1·그룹·비밀 대화, 또는 바로 연 나와의 대화)을 [onOpenRoom]으로 연다. 사이드바·모바일
/// 목록이 같이 쓰는 진입점. 화면은 new_chat_screen.dart.
Future<Room?> showStartChatDialog(
  BuildContext context,
  Session session, {
  required void Function(Room) onOpenRoom,
}) async {
  final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
  final room = wide
      ? await showDialog<Room>(
          context: context,
          builder: (_) => NewChatScreen(session: session, asDialog: true),
        )
      : await Navigator.of(context).push<Room>(
          MaterialPageRoute(builder: (_) => NewChatScreen(session: session)),
        );
  if (room != null) onOpenRoom(room);
  return room;
}
