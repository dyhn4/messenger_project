import 'package:flutter/material.dart';

import 'call_logic.dart';
import 'call_stage.dart' show callHandColor, callSpeakingColor;
import '../../l10n/tr.dart';

/// 화면 아래 가운데의 줌 스타일 컨트롤바 — 둥근 아이콘 단추 줄(아이콘 + 작은 라벨)과 맨 오른쪽의
/// 빨간 "나가기". 마우스를 올리면 각 단추의 툴팁이 뜬다.
///
/// 좁은 폭(폰·좁은 창, [labelBreakpoint] 미만)에서는 단추 8개가 한 줄에 다 안 들어가서, 예전에는
/// 단추 줄을 가로 스크롤로 넘겼더니 끝의 단추가 나가기 옆에서 반쯤 잘려 겹쳐 보였다. 그래서 줌·미트
/// 모바일처럼 자주 쓰는 것(마이크·카메라·참가자·채팅)만 고르게 늘어놓고, 나머지(화면 공유·손들기·
/// 화이트보드·보기 전환)는 [더보기] 단추가 아래에서 올리는 메뉴로 옮긴다. 그중 켜져 있는 것(공유 중,
/// 손 든 상태, 화이트보드 열림)이 있으면 더보기 단추에 점을 찍어 알린다.
class CallControlBar extends StatelessWidget {
  final bool micOn;
  final bool camOn;
  final bool sharing;
  final bool handRaised;
  final bool whiteboardOpen;
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
  final VoidCallback onToggleWhiteboard;
  final VoidCallback onToggleView;
  final VoidCallback onLeave;

  const CallControlBar({
    super.key,
    required this.micOn,
    required this.camOn,
    required this.sharing,
    required this.handRaised,
    this.whiteboardOpen = false,
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
    required this.onToggleWhiteboard,
    required this.onToggleView,
    required this.onLeave,
  });

  /// 이 폭보다 좁으면 라벨 달린 한 줄 대신 [좁은 배치](주요 단추 + 더보기)로 바꾼다 — 라벨 달린
  /// 단추 8개(68씩)와 사이 간격, 나가기 알약, 여백을 합친 폭이 대략 이만큼이다.
  static const labelBreakpoint = 780.0;

  @override
  Widget build(BuildContext context) {
    final showLabels = MediaQuery.sizeOf(context).width >= labelBreakpoint;
    if (!showLabels) return _buildCompact(context);
    final speaker = viewMode == CallViewMode.speaker;
    final items = <Widget>[
      CallBarButton(
        key: const ValueKey('call-mic'),
        icon: micOn ? Icons.mic : Icons.mic_off,
        label: micOn ? tr('음소거') : tr('음소거 해제'),
        tooltip: micOn ? tr('마이크 끄기') : tr('마이크 켜기'),
        off: !micOn,
        showLabel: showLabels,
        onPressed: onToggleMic,
      ),
      CallBarButton(
        key: const ValueKey('call-camera'),
        icon: camOn ? Icons.videocam : Icons.videocam_off,
        label: camOn ? tr('비디오 중지') : tr('비디오 시작'),
        tooltip: camOn ? tr('카메라 끄기') : tr('카메라 켜기'),
        off: !camOn,
        showLabel: showLabels,
        onPressed: onToggleCamera,
      ),
      CallBarButton(
        key: const ValueKey('call-share'),
        icon: sharing ? Icons.stop_screen_share : Icons.screen_share,
        label: sharing ? tr('공유 중지') : tr('화면 공유'),
        tooltip: sharing ? tr('화면 공유 중지') : tr('화면 공유'),
        highlight: sharing ? callSpeakingColor : null,
        showLabel: showLabels,
        onPressed: onToggleShare,
      ),
      CallBarButton(
        key: const ValueKey('call-participants'),
        icon: Icons.people,
        label: tr('참가자'),
        tooltip: tr('참가자 목록'),
        badge: participantCount,
        selected: panel == CallPanel.participants,
        showLabel: showLabels,
        onPressed: onToggleParticipants,
      ),
      CallBarButton(
        key: const ValueKey('call-chat'),
        icon: Icons.chat_bubble,
        label: tr('채팅'),
        tooltip: tr('통화 채팅'),
        badge: chatUnread,
        badgeColor: Colors.redAccent,
        selected: panel == CallPanel.chat,
        showLabel: showLabels,
        onPressed: onToggleChat,
      ),
      CallBarButton(
        key: const ValueKey('call-hand'),
        icon: Icons.front_hand,
        label: handRaised ? tr('손 내리기') : tr('손들기'),
        tooltip: handRaised ? tr('손 내리기') : tr('손들기'),
        highlight: handRaised ? callHandColor : null,
        showLabel: showLabels,
        onPressed: onToggleHand,
      ),
      CallBarButton(
        key: const ValueKey('call-whiteboard'),
        icon: Icons.draw,
        label: tr('화이트보드'),
        tooltip: whiteboardOpen ? tr('화이트보드 닫기') : tr('화이트보드 열기'),
        selected: whiteboardOpen,
        showLabel: showLabels,
        onPressed: onToggleWhiteboard,
      ),
      CallBarButton(
        key: const ValueKey('call-view'),
        icon: speaker ? Icons.grid_view : Icons.person_pin,
        label: speaker ? tr('갤러리 보기') : tr('스피커 보기'),
        tooltip: speaker ? tr('갤러리 보기로 전환') : tr('스피커 보기로 전환'),
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
              message: tr('통화 나가기'),
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
                        Text(
                          tr('나가기'),
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

  /// 좁은 배치 — 마이크·카메라·참가자·채팅·더보기·나가기(원형)를 한 줄에 고르게 놓는다. 360 폭
  /// 폰에서도 단추 6개(44)와 간격이 다 들어가서 스크롤도 잘림도 없다.
  Widget _buildCompact(BuildContext context) {
    final moreActive = sharing || handRaised || whiteboardOpen;
    final items = <Widget>[
      CallBarButton(
        key: const ValueKey('call-mic'),
        icon: micOn ? Icons.mic : Icons.mic_off,
        label: micOn ? tr('음소거') : tr('음소거 해제'),
        tooltip: micOn ? tr('마이크 끄기') : tr('마이크 켜기'),
        off: !micOn,
        showLabel: false,
        onPressed: onToggleMic,
      ),
      CallBarButton(
        key: const ValueKey('call-camera'),
        icon: camOn ? Icons.videocam : Icons.videocam_off,
        label: camOn ? tr('비디오 중지') : tr('비디오 시작'),
        tooltip: camOn ? tr('카메라 끄기') : tr('카메라 켜기'),
        off: !camOn,
        showLabel: false,
        onPressed: onToggleCamera,
      ),
      CallBarButton(
        key: const ValueKey('call-participants'),
        icon: Icons.people,
        label: tr('참가자'),
        tooltip: tr('참가자 목록'),
        badge: participantCount,
        selected: panel == CallPanel.participants,
        showLabel: false,
        onPressed: onToggleParticipants,
      ),
      CallBarButton(
        key: const ValueKey('call-chat'),
        icon: Icons.chat_bubble,
        label: tr('채팅'),
        tooltip: tr('통화 채팅'),
        badge: chatUnread,
        badgeColor: Colors.redAccent,
        selected: panel == CallPanel.chat,
        showLabel: false,
        onPressed: onToggleChat,
      ),
      CallBarButton(
        key: const ValueKey('call-more'),
        icon: Icons.more_horiz,
        label: tr('더보기'),
        tooltip: tr('더보기(화면 공유·손들기·화이트보드·보기 전환)'),
        dot: moreActive,
        showLabel: false,
        onPressed: () => _openMoreSheet(context),
      ),
      Tooltip(
        message: tr('통화 나가기'),
        child: Material(
          key: const ValueKey('call-leave'),
          color: const Color(0xFFE53935),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onLeave,
            child: const SizedBox(
              width: 44,
              height: 44,
              child: Icon(Icons.call_end, color: Colors.white, size: 22),
            ),
          ),
        ),
      ),
    ];
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
        child: Row(
          key: const ValueKey('call-bar-compact'),
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: items,
        ),
      ),
    );
  }

  /// 더보기 메뉴 — 좁은 배치에서 빠진 기능들. 항목을 누르면 메뉴를 먼저 닫고 실행한다(화면 공유는
  /// 안드로이드 시스템 확인 창이 뜨므로 그 위에 메뉴가 남아 있으면 어색하다).
  Future<void> _openMoreSheet(BuildContext context) {
    final speaker = viewMode == CallViewMode.speaker;
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF242424),
      showDragHandle: true,
      builder: (sheetContext) {
        Widget item({
          required Key key,
          required IconData icon,
          required String label,
          required VoidCallback onTap,
          Color? activeColor,
        }) {
          return ListTile(
            key: key,
            leading: CircleAvatar(
              radius: 20,
              backgroundColor: activeColor ?? Colors.white12,
              child: Icon(
                icon,
                color: activeColor != null ? Colors.black87 : Colors.white,
                size: 22,
              ),
            ),
            title: Text(label, style: const TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.of(sheetContext).pop();
              onTap();
            },
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              item(
                key: const ValueKey('call-share'),
                icon: sharing ? Icons.stop_screen_share : Icons.screen_share,
                label: sharing ? tr('화면 공유 중지') : tr('화면 공유'),
                activeColor: sharing ? callSpeakingColor : null,
                onTap: onToggleShare,
              ),
              item(
                key: const ValueKey('call-hand'),
                icon: Icons.front_hand,
                label: handRaised ? tr('손 내리기') : tr('손들기'),
                activeColor: handRaised ? callHandColor : null,
                onTap: onToggleHand,
              ),
              item(
                key: const ValueKey('call-whiteboard'),
                icon: Icons.draw,
                label: whiteboardOpen ? tr('화이트보드 닫기') : tr('화이트보드 열기'),
                activeColor: whiteboardOpen ? Colors.white70 : null,
                onTap: onToggleWhiteboard,
              ),
              item(
                key: const ValueKey('call-view'),
                icon: speaker ? Icons.grid_view : Icons.person_pin,
                label: speaker ? tr('갤러리 보기로 전환') : tr('스피커 보기로 전환'),
                onTap: onToggleView,
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

/// 컨트롤바의 둥근 단추 하나 — 위에 원형 아이콘, 아래에 작은 라벨, 오른쪽 위에 수 배지.
/// [off]면 꺼진 장치(빨간 아이콘, 마이크/카메라), [highlight]면 켜진 기능(색 원, 화면 공유/손들기),
/// [selected]면 열려 있는 패널(밝은 테두리), [dot]이면 오른쪽 위의 작은 점(더보기 안에 켜진 기능이 있음).
class CallBarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final bool off;
  final bool selected;
  final Color? highlight;
  final int badge;
  final Color badgeColor;
  final bool dot;
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
    this.dot = false,
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
          if (dot && badge == 0)
            Positioned(
              right: 0,
              top: 0,
              child: IgnorePointer(
                child: Container(
                  key: const ValueKey('call-bar-dot'),
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: callSpeakingColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.black54, width: 1.5),
                  ),
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
