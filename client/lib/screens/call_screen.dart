import 'dart:io';

import 'package:flutter/material.dart';
// livekit_client도 Session/Room이라는 이름을 내보내서 우리 것과 부딪힌다 — 접두사로 구분한다.
import 'package:livekit_client/livekit_client.dart' as lk;

import '../models/room.dart';
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/chat_panel.dart';
import '../widgets/screen_share_picker.dart';

/// 화상회의 화면 — PC(Windows)와 폰 모두 이 한 화면을 그대로 쓴다. 넓으면 오른쪽에
/// 참가자/대화 패널을 나란히 두고, 좁으면 같은 패널을 아래에서 올라오는 시트로 띄운다.
/// 미디어 연결 자체는 Session.callController가 들고 있고, 여기서는 그 상태를 그리기만 한다.
///
/// 통화 도중 화면을 나가도(뒤로가기) 통화는 끊기지 않는다 — "종료" 버튼을 눌러야 끝난다.
/// 그래야 통화 중에 다른 방을 잠깐 보고 돌아올 수 있다.
Future<void> showCallScreen(BuildContext context, Session session, Room room) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => CallScreen(session: session, room: room),
    ),
  );
}

/// 이 폭 이상이면 참가자/대화 패널을 오른쪽에 나란히 붙인다.
const _sidePanelBreakpoint = 900.0;
const _sidePanelWidth = 340.0;

class CallScreen extends StatefulWidget {
  final Session session;
  final Room room;
  const CallScreen({super.key, required this.session, required this.room});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  /// 넓은 화면에서 오른쪽 패널을 펼쳐둘지. 좁은 화면에서는 이 값과 무관하게 시트로 띄운다.
  bool _panelOpen = true;

  Future<void> _toggleScreenShare() async {
    final controller = widget.session.callController;
    try {
      // Windows는 어느 창을 공유할지 우리가 직접 고르게 하고(OS가 안 물어봄), Android는
      // MediaProjection 시스템 화면이 알아서 뜬다.
      if (!controller.screenShareEnabled && Platform.isWindows) {
        final sourceId = await showScreenSharePicker(context);
        if (sourceId == null) return;
        await controller.toggleScreenShare(sourceId: sourceId);
        return;
      }
      await controller.toggleScreenShare();
    } catch (e) {
      if (mounted) showAppToast(context, '화면 공유를 시작하지 못했습니다: $e');
    }
  }

  void _openPanelSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.85,
        child: _CallSidePanel(session: widget.session, room: widget.room),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.session.callController;
    final wide = MediaQuery.sizeOf(context).width >= _sidePanelBreakpoint;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final livekitRoom = controller.room;
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text(widget.room.displayName(widget.session.userId ?? '')),
            actions: [
              IconButton(
                tooltip: '참가자 · 대화',
                icon: const Icon(Icons.people_outline),
                onPressed: wide
                    ? () => setState(() => _panelOpen = !_panelOpen)
                    : _openPanelSheet,
              ),
            ],
          ),
          body: Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: controller.connecting || livekitRoom == null
                          ? const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircularProgressIndicator(),
                                  SizedBox(height: 12),
                                  Text(
                                    '연결 중...',
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                ],
                              ),
                            )
                          : _ParticipantGrid(room: livekitRoom),
                    ),
                    _CallControls(
                      session: widget.session,
                      onToggleScreenShare: _toggleScreenShare,
                    ),
                  ],
                ),
              ),
              if (wide && _panelOpen)
                SizedBox(
                  width: _sidePanelWidth,
                  child: _CallSidePanel(
                    session: widget.session,
                    room: widget.room,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 통화 화면 옆(또는 아래)의 참가자 목록 + 대화. 대화는 새로 만들지 않고 이 방의 기존
/// 채팅 패널을 그대로 붙인다 — 통화 중에 주고받은 말도 평소 대화 기록에 그대로 남는다.
class _CallSidePanel extends StatelessWidget {
  final Session session;
  final Room room;
  const _CallSidePanel({required this.session, required this.room});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          children: [
            const TabBar(
              tabs: [
                Tab(text: '참가자'),
                Tab(text: '대화'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _ParticipantList(session: session),
                  ChatPanel(
                    key: ValueKey('call-chat-${room.id}'),
                    session: session,
                    room: room,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ParticipantList extends StatelessWidget {
  final Session session;
  const _ParticipantList({required this.session});

  @override
  Widget build(BuildContext context) {
    final controller = session.callController;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final room = controller.room;
        final participants = <lk.Participant>[
          if (room?.localParticipant != null) room!.localParticipant!,
          ...?room?.remoteParticipants.values,
        ];
        if (participants.isEmpty) {
          return const Center(child: Text('참가자가 없습니다.'));
        }
        return ListView.builder(
          itemCount: participants.length,
          itemBuilder: (context, i) {
            final p = participants[i];
            final isMe = p.sid == room?.localParticipant?.sid;
            final label = p.name.isEmpty ? p.identity : p.name;
            return ListTile(
              dense: true,
              leading: CircleAvatar(child: Text(label.characters.first)),
              title: Text('$label${isMe ? ' (나)' : ''}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (p.isScreenShareEnabled())
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Icon(Icons.screen_share, size: 18),
                    ),
                  Icon(
                    p.isMicrophoneEnabled() ? Icons.mic : Icons.mic_off,
                    size: 18,
                    color: p.isMicrophoneEnabled() ? null : Colors.redAccent,
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    p.isCameraEnabled() ? Icons.videocam : Icons.videocam_off,
                    size: 18,
                    color: p.isCameraEnabled() ? null : Colors.redAccent,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// 한 타일에 대응하는 "참가자 + 그 참가자의 영상 트랙 하나". 화면 공유를 켜면 같은 사람이
/// 카메라 타일과 화면 공유 타일 두 개로 나타난다 — 둘 다 봐야 하는 화면이라 합치지 않는다.
class _Tile {
  final lk.Participant participant;
  final lk.VideoTrack? track;
  final bool isScreenShare;
  const _Tile(this.participant, this.track, {this.isScreenShare = false});
}

class _ParticipantGrid extends StatelessWidget {
  final lk.Room room;
  const _ParticipantGrid({required this.room});

  List<_Tile> _tiles() {
    final participants = <lk.Participant>[
      if (room.localParticipant != null) room.localParticipant!,
      ...room.remoteParticipants.values,
    ];
    final tiles = <_Tile>[];
    for (final p in participants) {
      final videos = p.videoTrackPublications.where(
        (pub) => pub.subscribed && !pub.muted,
      );
      if (videos.isEmpty) {
        tiles.add(_Tile(p, null)); // 카메라를 껐어도 자리는 보여준다.
        continue;
      }
      for (final pub in videos) {
        tiles.add(
          _Tile(
            p,
            pub.track as lk.VideoTrack?,
            isScreenShare: pub.source == lk.TrackSource.screenShareVideo,
          ),
        );
      }
    }
    // 화면 공유가 있으면 맨 앞(가장 큰 자리)으로 올린다 — 발표 중엔 그게 주 화면이다.
    tiles.sort((a, b) {
      if (a.isScreenShare == b.isScreenShare) return 0;
      return a.isScreenShare ? -1 : 1;
    });
    return tiles;
  }

  @override
  Widget build(BuildContext context) {
    final tiles = _tiles();
    final columns = tiles.length <= 1
        ? 1
        : tiles.length <= 4
        ? 2
        : 3;

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        childAspectRatio: 4 / 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: tiles.length,
      itemBuilder: (context, i) => _ParticipantTile(tile: tiles[i]),
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  final _Tile tile;
  const _ParticipantTile({required this.tile});

  @override
  Widget build(BuildContext context) {
    final participant = tile.participant;
    final track = tile.track;
    final label = participant.name.isEmpty
        ? participant.identity
        : participant.name;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: const Color(0xFF1E1E1E),
            child: track != null
                ? lk.VideoTrackRenderer(
                    track,
                    // 화면 공유는 잘리면 안 되니 전체가 보이게(contain), 얼굴은 꽉 차게(cover).
                    fit: tile.isScreenShare
                        ? lk.VideoViewFit.contain
                        : lk.VideoViewFit.cover,
                  )
                : Center(
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 18,
                      ),
                    ),
                  ),
          ),
          Positioned(
            left: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (tile.isScreenShare)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(
                        Icons.screen_share,
                        size: 14,
                        color: Colors.white,
                      ),
                    )
                  else if (!participant.isMicrophoneEnabled())
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(Icons.mic_off, size: 14, color: Colors.white),
                    ),
                  Text(
                    tile.isScreenShare ? '$label · 화면 공유' : label,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CallControls extends StatelessWidget {
  final Session session;
  final VoidCallback onToggleScreenShare;
  const _CallControls({
    required this.session,
    required this.onToggleScreenShare,
  });

  @override
  Widget build(BuildContext context) {
    final controller = session.callController;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 16,
          runSpacing: 8,
          children: [
            _RoundButton(
              icon: controller.micEnabled ? Icons.mic : Icons.mic_off,
              active: controller.micEnabled,
              tooltip: controller.micEnabled ? '마이크 끄기' : '마이크 켜기',
              onPressed: controller.toggleMic,
            ),
            _RoundButton(
              icon: controller.cameraEnabled
                  ? Icons.videocam
                  : Icons.videocam_off,
              active: controller.cameraEnabled,
              tooltip: controller.cameraEnabled ? '카메라 끄기' : '카메라 켜기',
              onPressed: controller.toggleCamera,
            ),
            _RoundButton(
              icon: controller.screenShareEnabled
                  ? Icons.stop_screen_share
                  : Icons.screen_share,
              active: controller.screenShareEnabled,
              tooltip: controller.screenShareEnabled ? '화면 공유 중지' : '화면 공유',
              onPressed: onToggleScreenShare,
            ),
            _RoundButton(
              icon: Icons.call_end,
              active: true,
              danger: true,
              tooltip: '통화 종료',
              onPressed: () async {
                await session.leaveCall();
                if (context.mounted) Navigator.of(context).maybePop();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final bool danger;
  final String tooltip;
  final VoidCallback onPressed;
  const _RoundButton({
    required this.icon,
    required this.active,
    required this.tooltip,
    required this.onPressed,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: danger ? Colors.red : (active ? Colors.white24 : Colors.white10),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
        ),
      ),
    );
  }
}
