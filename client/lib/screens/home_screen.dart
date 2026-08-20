import 'package:flutter/material.dart';

import '../services/session.dart';
import 'desktop_home_screen.dart';
import 'room_list_screen.dart';

/// 창 너비로 레이아웃을 고른다. 넓으면(PC) 사이드바+채팅패널 분할 화면,
/// 좁으면(폰) 기존 목록 → 채팅화면 전환 방식을 쓴다.
const wideBreakpoint = 700.0;

class HomeScreen extends StatelessWidget {
  final Session session;
  const HomeScreen({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= wideBreakpoint) {
          return DesktopHomeScreen(session: session);
        }
        return RoomListScreen(session: session);
      },
    );
  }
}
