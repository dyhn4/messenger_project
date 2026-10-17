import 'dart:async';

import 'package:flutter/material.dart';

import '../models/room.dart';
import '../services/app_platform.dart';
import '../services/room_chat_controller.dart';
import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/chat_panel.dart';
import '../widgets/screen_share_picker.dart';
import 'call/call_control_bar.dart';
import 'call/call_logic.dart';
import 'call/call_participants_panel.dart';
import 'call/call_snapshot.dart';
import 'call/call_stage.dart';
import 'call/call_whiteboard_view.dart';

/// 화상회의 화면 — PC(Windows)와 폰 모두 이 한 화면을 그대로 쓴다. 줌처럼 어두운 화면에 영상
/// 타일(갤러리 보기/스피커 보기), 아래 가운데에 둥근 컨트롤바(마이크·카메라·화면 공유·참가자·채팅·
/// 손들기·보기 전환·나가기)를 두고, 참가자/채팅 패널은 넓으면 오른쪽에 나란히, 좁으면 아래에서
/// 올라오는 시트로 띄운다(같은 자리를 번갈아 쓴다).
/// 미디어 연결 자체는 Session.callController가 들고 있고, 여기서는 그 상태를 그리기만 한다.
///
/// 통화 도중 화면을 나가도(뒤로가기) 통화는 끊기지 않는다 — "나가기" 버튼을 눌러야 끝난다.
/// 그래야 통화 중에 다른 방을 잠깐 보고 돌아올 수 있다.
Future<void> showCallScreen(BuildContext context, Session session, Room room) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => CallScreen(session: session, room: room),
    ),
  );
}

/// 이 폭 이상이면 참가자/채팅 패널을 오른쪽에 나란히 붙인다.
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
  /// 열려 있는 패널. 넓은 화면은 오른쪽에 붙이고 좁은 화면은 시트로 띄운다.
  CallPanel _panel = CallPanel.none;

  /// 사용자가 직접 고른 보기. null이면 자동(다른 사람의 화면 공유가 있으면 스피커, 아니면 갤러리).
  /// 한 번 고르면 통화 중 그대로 유지한다.
  CallViewMode? _chosenMode;

  /// 손들기 토스트("○○님이 손을 들었습니다")와 그 밖의 알림(들어옴·나감 등) — [_toastIsHand]로 아이콘을 고른다.
  String? _toast;
  bool _toastIsHand = true;
  Timer? _toastTimer;
  StreamSubscription<String>? _handSub;

  /// 진행자가 내 마이크를 바꿈·누가 화이트보드를 엶 같은 알림 토스트.
  StreamSubscription<String>? _noticeSub;

  /// 영상 자리에 화이트보드를 띄웠는지(이 화면만 — 다른 사람은 각자 연다).
  bool _whiteboardOpen = false;

  /// 통화 채팅 안읽음 — 채팅 패널을 닫아 둔 동안 남이 보낸 메시지 수.
  late final RoomChatController _chat;
  DateTime? _unreadBaseline;
  int _unread = 0;

  /// 이 화면을 닫는 중인지 — [나가기]와 통화가 밖에서 끝난 것(_onCallChanged)이 화면을 두 번 닫지 않게.
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _handSub = widget.session.callController.handRaisedNames.listen(
      (name) => _showToast('$name님이 손을 들었습니다', hand: true),
    );
    _noticeSub = widget.session.callController.notices.listen(_showToast);
    _chat = widget.session.controllerFor(widget.room);
    _unreadBaseline = latestMessageTime(_chat.messages) ?? DateTime.now();
    _chat.addListener(_onChatChanged);
    widget.session.callController.addListener(_onCallChanged);
    // 화면이 뜨기 직전에 이미 끝났을 수도 있다(참여 직후 서버가 거절 등).
    WidgetsBinding.instance.addPostFrameCallback((_) => _onCallChanged());
  }

  @override
  void dispose() {
    widget.session.callController.removeListener(_onCallChanged);
    _chat.removeListener(_onChatChanged);
    _handSub?.cancel();
    _noticeSub?.cancel();
    _toastTimer?.cancel();
    super.dispose();
  }

  /// 통화가 이 화면 밖에서 끝났으면(서버가 내보냄·회의방이 닫힘·다른 기기에서 참여·연결이 아주 끊김·방에서 나감) 화면을
  /// 닫는다 — 안 그러면 빈 통화 화면이 "연결 중..."으로 남는다. 왜 끝났는지는 Session이 앱 전체 알림으로 띄운다.
  void _onCallChanged() {
    if (_closing || !mounted) return;
    if (widget.session.callController.roomId == widget.room.id) return;
    _closing = true;
    // 알림 도중(다른 위젯이 그리는 중일 수 있다)에 화면을 빼지 않게 한 박자 뒤에.
    Future.microtask(() {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isActive) return;
      final navigator = Navigator.of(context);
      // 위에 떠 있는 참가자·채팅 시트나 화면 공유 선택 창까지 같이 닫는다.
      navigator.popUntil((r) => r == route);
      navigator.pop();
    });
  }

  void _showToast(String message, {bool hand = false}) {
    if (!mounted) return;
    setState(() {
      _toast = message;
      _toastIsHand = hand;
    });
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  void _onChatChanged() {
    if (!mounted) return;
    final messages = _chat.messages;
    // 채팅 패널을 보고 있는 동안 온 메시지는 읽은 것이다.
    if (_panel == CallPanel.chat) {
      _unreadBaseline = latestMessageTime(messages) ?? _unreadBaseline;
    }
    final unread = countUnreadSince(
      messages,
      _unreadBaseline,
      widget.session.userId,
    );
    if (unread != _unread) setState(() => _unread = unread);
  }

  /// 패널이 바뀔 때 안읽음 기준선을 맞춘다 — 채팅을 열면 0, 닫을 때 그 시점까지는 읽은 것.
  void _setPanel(CallPanel panel) {
    final wasChat = _panel == CallPanel.chat;
    setState(() {
      _panel = panel;
      if (panel == CallPanel.chat || wasChat) {
        _unreadBaseline =
            latestMessageTime(_chat.messages) ??
            _unreadBaseline ??
            DateTime.now();
        _unread = 0;
      }
    });
  }

  Future<void> _toggleScreenShare() async {
    final controller = widget.session.callController;
    if (AppPlatform.isWebOnIOS) {
      // 아이폰·아이패드 브라우저에는 화면을 찍어 보내는 기능(getDisplayMedia)이 아예 없다.
      _showToast('아이폰·아이패드 브라우저에서는 화면 공유를 할 수 없습니다.');
      return;
    }
    if (AppPlatform.isIOS) {
      // 아이폰 앱이 화면 전체를 보내려면 방송 확장(Broadcast Upload Extension)이 따로 있어야 하는데, 그건 Apple 개발자
      // 등록(앱 그룹·서명) 뒤에 넣는다 — 그 전에는 이 앱 화면밖에 못 보내서 막아 둔다.
      _showToast('아이폰 앱에서는 아직 화면 공유를 할 수 없습니다.');
      return;
    }
    try {
      // Windows는 어느 창을 공유할지 우리가 직접 고르게 하고(OS가 안 물어봄), Android는
      // MediaProjection 시스템 화면이 알아서 뜬다.
      if (!controller.screenShareEnabled && AppPlatform.isWindows) {
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

  /// 화이트보드를 열고 닫는다 — 열 때는 다른 참가자들에게 알린다(그 사람들 화면은 각자 연다).
  void _toggleWhiteboard() {
    final board = widget.session.callController.whiteboard;
    if (board == null) return;
    setState(() => _whiteboardOpen = !_whiteboardOpen);
    if (_whiteboardOpen) board.announceOpened();
  }

  /// 참가자 패널의 마이크 단추 — 내 줄이면 내 마이크, 다른 사람이면(진행자만) 그 사람의 마이크를 켜고 끈다.
  void _toggleParticipantMic(CallPerson person) {
    final controller = widget.session.callController;
    if (person.isMe) {
      unawaited(controller.toggleMic());
      return;
    }
    if (!controller.isHost) return;
    // 끄기는 바로 꺼지고, 켜기는 그 사람에게 켜 달라는 요청만 간다(본인이 [마이크 켜기]를 눌러야 켜진다).
    widget.session.controlCallMic(person.id, !person.micOn);
    _showToast(
      person.micOn
          ? '${person.name}님의 마이크를 껐습니다'
          : '${person.name}님에게 마이크를 켜 달라고 요청했습니다',
    );
  }

  Future<void> _leave() async {
    _closing = true;
    await widget.session.leaveCall();
    if (mounted) Navigator.of(context).maybePop();
  }

  void _togglePanel(CallPanel target, {required bool wide}) {
    if (wide) {
      _setPanel(_panel == target ? CallPanel.none : target);
      return;
    }
    _openPanelSheet(target);
  }

  void _openPanelSheet(CallPanel panel) {
    _setPanel(panel);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.85,
        child: _panelBody(panel, () => Navigator.of(sheetContext).pop()),
      ),
    ).whenComplete(() {
      if (mounted && _panel == panel) _setPanel(CallPanel.none);
    });
  }

  /// 패널 내용 — 참가자 목록은 통화 상태를 직접 구독하고, 채팅은 이 방의 기존 채팅 패널을 그대로
  /// 붙인다(통화 중에 주고받은 말도 평소 대화 기록에 그대로 남는다).
  Widget _panelBody(CallPanel panel, VoidCallback onClose) {
    final session = widget.session;
    final controller = session.callController;
    if (panel == CallPanel.chat) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          children: [
            CallPanelHeader(title: '채팅', onClose: onClose),
            Expanded(
              child: ChatPanel(
                key: ValueKey('call-chat-${widget.room.id}'),
                session: session,
                room: widget.room,
              ),
            ),
          ],
        ),
      );
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final lkRoom = controller.room;
        final people = lkRoom == null
            ? const <CallPerson>[]
            : buildCallPeople(
                lkRoom,
                controller.raisedHands,
                widget.room.members,
                hostId: controller.hostId,
              );
        return CallParticipantsPanel(
          people: people,
          onClose: onClose,
          resolveUrl: session.resolveUrl,
          canControlOthers: controller.isHost,
          onToggleMic: _toggleParticipantMic,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final controller = session.callController;
    final wide = MediaQuery.sizeOf(context).width >= _sidePanelBreakpoint;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final lkRoom = controller.room;
        final ready = !controller.connecting && lkRoom != null;
        final people = ready
            ? buildCallPeople(
                lkRoom,
                controller.raisedHands,
                widget.room.members,
                hostId: controller.hostId,
              )
            : const <CallPerson>[];
        final whiteboard = controller.whiteboard;
        final showWhiteboard = ready && _whiteboardOpen && whiteboard != null;
        final tiles = ready ? buildCallTiles(lkRoom, people) : <CallTileData>[];
        final mode = effectiveViewMode(
          _chosenMode,
          hasRemoteScreenShare: tiles.any(
            (t) => t.isScreenShare && !t.person.isMe,
          ),
        );
        void setMode(CallViewMode m) => setState(() => _chosenMode = m);

        return Scaffold(
          backgroundColor: callStageColor,
          appBar: AppBar(
            backgroundColor: callStageColor,
            foregroundColor: Colors.white,
            title: Text(widget.room.displayName(session.userId ?? '')),
            actions: [
              PopupMenuButton<CallViewMode>(
                key: const ValueKey('call-view-menu'),
                tooltip: '보기',
                icon: Icon(
                  mode == CallViewMode.speaker
                      ? Icons.person_pin
                      : Icons.grid_view,
                ),
                onSelected: setMode,
                itemBuilder: (_) => [
                  CheckedPopupMenuItem(
                    value: CallViewMode.speaker,
                    checked: mode == CallViewMode.speaker,
                    child: const Text('스피커 보기'),
                  ),
                  CheckedPopupMenuItem(
                    value: CallViewMode.gallery,
                    checked: mode == CallViewMode.gallery,
                    child: const Text('갤러리 보기'),
                  ),
                ],
              ),
            ],
          ),
          body: Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: !ready
                                ? const Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        CircularProgressIndicator(),
                                        SizedBox(height: 12),
                                        Text(
                                          '연결 중...',
                                          style: TextStyle(
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : showWhiteboard
                                ? CallWhiteboardView(
                                    board: whiteboard,
                                    onClose: () =>
                                        setState(() => _whiteboardOpen = false),
                                  )
                                : CallStage(
                                    tiles: tiles,
                                    speakingIds: activeSpeakerIds(lkRoom),
                                    mode: mode,
                                    resolveUrl: session.resolveUrl,
                                  ),
                          ),
                          if (controller.micRequested)
                            Positioned(
                              left: 16,
                              right: 16,
                              top: 12,
                              child: Center(
                                child: CallMicRequestBanner(
                                  onAccept: () =>
                                      controller.answerMicRequest(accept: true),
                                  onDecline: () => controller.answerMicRequest(
                                    accept: false,
                                  ),
                                ),
                              ),
                            ),
                          if (_toast != null)
                            Positioned(
                              left: 16,
                              right: 16,
                              bottom: 12,
                              child: IgnorePointer(
                                child: Center(
                                  child: CallToast(
                                    message: _toast!,
                                    hand: _toastIsHand,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    CallControlBar(
                      micOn: controller.micEnabled,
                      camOn: controller.cameraEnabled,
                      sharing: controller.screenShareEnabled,
                      handRaised: controller.handRaised,
                      whiteboardOpen: showWhiteboard,
                      viewMode: mode,
                      panel: _panel,
                      participantCount: people.length,
                      chatUnread: _panel == CallPanel.chat ? 0 : _unread,
                      onToggleMic: controller.toggleMic,
                      onToggleCamera: controller.toggleCamera,
                      onToggleShare: _toggleScreenShare,
                      onToggleParticipants: () =>
                          _togglePanel(CallPanel.participants, wide: wide),
                      onToggleChat: () =>
                          _togglePanel(CallPanel.chat, wide: wide),
                      onToggleHand: controller.toggleHand,
                      onToggleWhiteboard: _toggleWhiteboard,
                      onToggleView: () => setMode(
                        mode == CallViewMode.speaker
                            ? CallViewMode.gallery
                            : CallViewMode.speaker,
                      ),
                      onLeave: _leave,
                    ),
                  ],
                ),
              ),
              if (wide && _panel != CallPanel.none)
                SizedBox(
                  width: _sidePanelWidth,
                  child: _panelBody(_panel, () => _setPanel(CallPanel.none)),
                ),
            ],
          ),
        );
      },
    );
  }
}
