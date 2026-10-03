import 'package:flutter/material.dart';

import 'call_logic.dart';
import 'call_stage.dart' show callHandColor, callSpeakingColor;

/// 화면 아래 가운데의 줌 스타일 컨트롤바 — 둥근 아이콘 단추 줄(아이콘 + 작은 라벨)과 맨 오른쪽의
/// 빨간 "나가기". 단추가 많아 좁은 폭(폰)에서는 단추 줄만 가로로 스크롤되고 라벨은 숨기며, 나가기는
/// 항상 보인다. 마우스를 올리면 각 단추의 툴팁이 뜬다.
class CallControlBar extends StatelessWidget {
  final bool micOn;
  final bool camOn;
  final bool sharing;
  final bool handRaised;
  final CallViewMode viewMode;
  final CallPanel panel;
  final int participantCount;
  final int chatUnread;
  final VoidCallback onToggleMic;
  final VoidCallback onToggleCamera;
  final VoidCallback onToggleShare;
  final VoidCallback onToggleParticipants;
  final VoidCallback onToggleChat;
  final VoidCallback onToggleHand;
  final VoidCallback onToggleView;
  final VoidCallback onLeave;

  const CallControlBar({
    super.key,
    required this.micOn,
    required this.camOn,
    required this.sharing,
    required this.handRaised,
    required this.viewMode,
    required this.panel,
    required this.participantCount,
    required this.chatUnread,
    required this.onToggleMic,
    required this.onToggleCamera,
    required this.onToggleShare,
    required this.onToggleParticipants,
    required this.onToggleChat,
    required this.onToggleHand,
    required this.onToggleView,
    required this.onLeave,
  });

  /// 이 폭보다 좁으면 라벨을 숨기고 단추만 둔다.
  static const labelBreakpoint = 560.0;

  @override
  Widget build(BuildContext context) {
    final showLabels = MediaQuery.sizeOf(context).width >= labelBreakpoint;
    final speaker = viewMode == CallViewMode.speaker;
    final items = <Widget>[
      CallBarButton(
        key: const ValueKey('call-mic'),
        icon: micOn ? Icons.mic : Icons.mic_off,
        label: micOn ? '음소거' : '음소거 해제',
        tooltip: micOn ? '마이크 끄기' : '마이크 켜기',
        off: !micOn,
        showLabel: showLabels,
        onPressed: onToggleMic,
      ),
      CallBarButton(
        key: const ValueKey('call-camera'),
        icon: camOn ? Icons.videocam : Icons.videocam_off,
        label: camOn ? '비디오 중지' : '비디오 시작',
        tooltip: camOn ? '카메라 끄기' : '카메라 켜기',
        off: !camOn,
        showLabel: showLabels,
        onPressed: onToggleCamera,
      ),
      CallBarButton(
        key: const ValueKey('call-share'),
        icon: sharing ? Icons.stop_screen_share : Icons.screen_share,
        label: sharing ? '공유 중지' : '화면 공유',
        tooltip: sharing ? '화면 공유 중지' : '화면 공유',
        highlight: sharing ? callSpeakingColor : null,
        showLabel: showLabels,
        onPressed: onToggleShare,
      ),
      CallBarButton(
        key: const ValueKey('call-participants'),
        icon: Icons.people,
        label: '참가자',
        tooltip: '참가자 목록',
        badge: participantCount,
        selected: panel == CallPanel.participants,
        showLabel: showLabels,
        onPressed: onToggleParticipants,
      ),
      CallBarButton(
        key: const ValueKey('call-chat'),
        icon: Icons.chat_bubble,
        label: '채팅',
        tooltip: '통화 채팅',
        badge: chatUnread,
        badgeColor: Colors.redAccent,
        selected: panel == CallPanel.chat,
        showLabel: showLabels,
        onPressed: onToggleChat,
      ),
      CallBarButton(
        key: const ValueKey('call-hand'),
        icon: Icons.front_hand,
        label: handRaised ? '손 내리기' : '손들기',
        tooltip: handRaised ? '손 내리기' : '손들기',
        highlight: handRaised ? callHandColor : null,
        showLabel: showLabels,
        onPressed: onToggleHand,
      ),
      CallBarButton(
        key: const ValueKey('call-view'),
        icon: speaker ? Icons.grid_view : Icons.person_pin,
        label: speaker ? '갤러리 보기' : '스피커 보기',
        tooltip: speaker ? '갤러리 보기로 전환' : '스피커 보기로 전환',
        showLabel: showLabels,
        onPressed: onToggleView,
      ),
    ];

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => SingleChildScrollView(
                  key: const ValueKey('call-bar-scroll'),
                  scrollDirection: Axis.horizontal,
                  // 단추가 다 들어가면 가운데, 넘치면 스크롤.
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: box.maxWidth),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < items.length; i++) ...[
                          if (i > 0) SizedBox(width: showLabels ? 10 : 6),
                          items[i],
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: '통화 나가기',
              child: Material(
                key: const ValueKey('call-leave'),
                color: const Color(0xFFE53935),
                borderRadius: BorderRadius.circular(22),
                child: InkWell(
                  borderRadius: BorderRadius.circular(22),
                  onTap: onLeave,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: showLabels ? 20 : 14,
                      vertical: 12,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.call_end,
                          color: Colors.white,
                          size: 20,
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          '나가기',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 컨트롤바의 둥근 단추 하나 — 위에 원형 아이콘, 아래에 작은 라벨, 오른쪽 위에 수 배지.
/// [off]면 꺼진 장치(빨간 아이콘, 마이크/카메라), [highlight]면 켜진 기능(색 원, 화면 공유/손들기),
/// [selected]면 열려 있는 패널(밝은 테두리).
class CallBarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final bool off;
  final bool selected;
  final Color? highlight;
  final int badge;
  final Color badgeColor;
  final bool showLabel;
  final VoidCallback onPressed;
  const CallBarButton({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.off = false,
    this.selected = false,
    this.highlight,
    this.badge = 0,
    this.badgeColor = const Color(0xFF5C6BC0),
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    final bg = highlight ?? (selected ? Colors.white30 : Colors.white12);
    final iconColor = highlight != null
        ? Colors.black87
        : off
        ? const Color(0xFFFF6B6B)
        : Colors.white;
    final circle = SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Material(
            color: bg,
            shape: CircleBorder(
              side: selected
                  ? const BorderSide(color: Colors.white70, width: 1.5)
                  : BorderSide.none,
            ),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(icon, color: iconColor, size: 22),
              ),
            ),
          ),
          if (badge > 0)
            Positioned(
              right: -4,
              top: -4,
              child: IgnorePointer(
                child: Container(
                  constraints: const BoxConstraints(minWidth: 18),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  height: 18,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: badgeColor,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    badge > 99 ? '99+' : '$badge',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    return Tooltip(
      message: tooltip,
      child: showLabel
          ? SizedBox(
              width: 68,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  circle,
                  const SizedBox(height: 4),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: off ? const Color(0xFFFF6B6B) : Colors.white70,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            )
          : circle,
    );
  }
}
