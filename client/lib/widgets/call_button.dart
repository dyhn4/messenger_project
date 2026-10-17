import 'package:flutter/material.dart';

import '../models/room.dart';
import '../screens/call_screen.dart';
import '../services/session.dart';
import 'app_toast.dart';
import 'compact_menu_anchor.dart';

/// 채팅방 헤더의 화상회의 버튼. 서버에 LiveKit이 없으면(session.callsEnabled) 아예 안 보이고,
/// 비밀 대화에서도 숨긴다(SFU가 미디어를 복호화해 중계하므로 "서버가 내용을 모른다"는 약속과
/// 충돌 — server/src/calls.js 참고).
///
/// 이미 누군가 통화 중이면 초록색 "참여"로 바뀌고 참가자 수를 같이 보여준다. 누르면 **화상으로 / 음성으로(카메라 끔)** 중 하나를
/// 고르는 메뉴가 열리고, 이미 이 방 통화에 들어와 있으면 메뉴 없이 통화 화면을 다시 연다.
class CallButton extends StatelessWidget {
  final Session session;
  final Room room;
  const CallButton({super.key, required this.session, required this.room});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        if (!session.callsEnabled || room.isSecret) {
          return const SizedBox.shrink();
        }
        final state = session.callStates[room.id];
        final ongoing = state?.active ?? false;
        final count = state?.participantIds.length ?? 0;
        final joined = session.callController.roomId == room.id;

        Widget button(VoidCallback onPressed) => IconButton(
          key: const ValueKey('call-button'),
          tooltip: joined
              ? '통화 화면 열기'
              : ongoing
              ? '진행 중인 화상회의 참여 ($count명)'
              : '화상회의 시작',
          icon: Badge(
            isLabelVisible: ongoing && !joined,
            label: Text('$count'),
            child: Icon(
              Icons.videocam_outlined,
              color: ongoing ? Colors.green : null,
            ),
          ),
          onPressed: onPressed,
        );
        if (joined) return button(() => _open(context));
        return CompactMenuAnchor<bool>(
          selected: null,
          onSelected: (camera) => _open(context, camera: camera),
          entries: [
            CompactMenuOption(
              key: const ValueKey('call-with-video'),
              value: true,
              icon: Icons.videocam_outlined,
              label: ongoing ? '화상으로 참여' : '화상으로 시작',
            ),
            CompactMenuOption(
              key: const ValueKey('call-with-voice'),
              value: false,
              icon: Icons.mic_none,
              label: ongoing ? '음성으로 참여(카메라 끔)' : '음성으로 시작(카메라 끔)',
            ),
          ],
          builder: (context, open, toggle) => button(toggle),
        );
      },
    );
  }

  /// [camera]가 false면 카메라를 끈 채 들어간다(통화 화면에서 나중에 켤 수 있다).
  Future<void> _open(BuildContext context, {bool camera = true}) async {
    // 이미 이 방 통화에 들어와 있으면 연결을 새로 하지 않고 화면만 다시 연다.
    if (session.callController.roomId != room.id) {
      try {
        await session.joinCall(room.id, camera: camera);
      } catch (e) {
        if (context.mounted) showAppToast(context, '통화를 시작하지 못했습니다: $e');
        return;
      }
    }
    if (context.mounted) await showCallScreen(context, session, room);
  }
}
