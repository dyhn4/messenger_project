import 'dart:async';

import 'package:flutter/material.dart';

import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/update_dialog.dart';
import 'call_screen.dart';
import 'chat_screen.dart';
import 'desktop_home_screen.dart';
import 'room_list_screen.dart';
import 'team_select_screen.dart';

/// 창 너비로 레이아웃을 고른다. 넓으면(PC) 사이드바+채팅패널 분할 화면,
/// 좁으면(폰) 기존 목록 → 채팅화면 전환 방식을 쓴다.
const wideBreakpoint = 700.0;

class HomeScreen extends StatefulWidget {
  final Session session;
  const HomeScreen({super.key, required this.session});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _secretInviteDialogShowing = false;
  bool _incomingCallDialogShowing = false;
  StreamSubscription<String>? _toastSub;

  /// 직전에 넓은 레이아웃이었는지. 좁은 화면에서 방을 열면 RoomListScreen이 ChatScreen을
  /// Navigator에 push하는데, 그 상태로 창을 넓히면 DesktopHomeScreen이 그 방을 이어서
  /// 인라인으로 보여줄 준비가 되어도(initState에서 activeRoomId로 미리 선택) 위에 쌓인
  /// ChatScreen이 여전히 화면을 덮고 있어 안 보인다 — 좁음→넓음으로 바뀌는 순간 그 push
  /// 스택을 루트까지 걷어낸다.
  ///
  /// build()의 LayoutBuilder가 아니라 [didChangeMetrics]로 감지하는 이유: ChatScreen이
  /// 위에 떠 있는 동안은 HomeScreen이 화면에 안 보이는 라우트라서, Navigator/Overlay가
  /// 불투명한 라우트에 덮인 아래쪽은 리레이아웃을 건너뛴다 — LayoutBuilder의 builder가
  /// 아예 다시 안 불려서 그 안에서 창 크기 변화를 감지할 수 없었다. didChangeMetrics는
  /// 위젯 트리의 가시성과 무관하게 창 크기가 바뀔 때마다 항상 불린다.
  late bool _wasWide = _currentWidth >= wideBreakpoint;

  /// currentTeam이 null인 상태가 "방금 시작됐을 때"만(매 리빌드마다가 아니라) 팀 화면 위에
  /// 쌓여있던 라우트를 걷어낸다. 이 값 없이 매번 canPop()을 다시 확인하면, 팀 선택 화면에서
  /// 연 다이얼로그(예: 팀 생성하기)가 떠 있는 동안 session이 다른 이유로(온라인 상태 변경
  /// 등, notifyListeners는 session.dart 곳곳에서 자주 불림) 갱신되기만 해도 그 다이얼로그가
  /// popUntil에 의해 강제로 닫혀버렸다 — 사용자가 직접 닫는 pop과 겹치면서 프레임워크의
  /// "_dependents.isEmpty" 단언 실패로 이어졌다.
  late bool _hadTeam = widget.session.currentTeam != null;

  double get _currentWidth {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return view.physicalSize.width / view.devicePixelRatio;
  }

  @override
  void didChangeMetrics() {
    final isWide = _currentWidth >= wideBreakpoint;
    if (!_wasWide && isWide) {
      // build 도중이 아니라도(라우트 전환이 이 콜백 도중 안전하지 않을 수 있어) 프레임이
      // 끝난 뒤로 미룬다.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
      });
    }
    _wasWide = isWide;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(_onSessionChanged);
    _maybeShowUpdateBanner();
    _maybeShowSecretInvite();
    // navigatorKey.currentContext(Navigator 위젯 자체의 context)로는 SnackBar/Overlay가
    // 화면에 안 그려진다 — 이 화면(HomeScreen) 자신의, 실제로 마운트된 context를 써야 한다.
    // HomeScreen은 항상 최상위(main.dart의 루트 라우트)에 떠 있으므로 어느 화면에 있든
    // (다른 화면이 그 위에 덮여 있어도) session.toasts를 여기서 구독하면 된다.
    _toastSub = widget.session.toasts.listen((message) {
      if (!mounted) return;
      showAppToast(context, message);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.session.removeListener(_onSessionChanged);
    _toastSub?.cancel();
    super.dispose();
  }

  void _onSessionChanged() {
    _maybeShowUpdateBanner();
    _maybeShowSecretInvite();
    _maybeShowIncomingCall();
  }

  /// 걸려온 화상회의(session.incomingCallRoomId)가 있으면 수신 화면을 띄운다. 비밀 대화
  /// 초대와 같은 방식 — HomeScreen은 어느 화면에 있든 항상 떠 있는 최상위 라우트라 여기서
  /// 띄우면 채팅방 안에 있든 목록에 있든 똑같이 보인다.
  ///
  /// 앱이 완전히 꺼져 있을 때는 이 경로가 아예 안 돌아간다(소켓이 없으므로) — 그건 3단계에서
  /// FCM 고우선순위 푸시 + 전체화면 수신 알림으로 따로 처리한다.
  void _maybeShowIncomingCall() {
    final roomId = widget.session.incomingCallRoomId;
    if (roomId == null || _incomingCallDialogShowing) return;
    final matches = widget.session.rooms.where((r) => r.id == roomId);
    if (matches.isEmpty) return;
    final room = matches.first;

    _incomingCallDialogShowing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _incomingCallDialogShowing = false;
        return;
      }
      final accept = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.videocam, color: Colors.green),
              SizedBox(width: 8),
              Text('화상회의 요청'),
            ],
          ),
          content: Text(
            '${room.displayName(widget.session.userId ?? '')}에서 화상회의가 시작됐습니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('거절'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('참여'),
            ),
          ],
        ),
      );
      _incomingCallDialogShowing = false;
      if (!mounted) return;
      if (accept == true) {
        try {
          await widget.session.joinCall(room.id);
          if (mounted) await showCallScreen(context, widget.session, room);
        } catch (e) {
          if (mounted) showAppToast(context, '통화에 참여하지 못했습니다: $e');
        }
      } else {
        widget.session.declineIncomingCall();
      }
    });
  }

  /// 비밀 대화 초대(secret:invite)가 도착하면 수락/거절 다이얼로그를 하나씩 순서대로 띄운다.
  void _maybeShowSecretInvite() {
    if (_secretInviteDialogShowing) return;
    if (widget.session.pendingSecretInvites.isEmpty) return;
    final invite = widget.session.pendingSecretInvites.first;
    _secretInviteDialogShowing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _secretInviteDialogShowing = false;
        return;
      }
      final accept = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.lock_outline, color: Colors.green),
              SizedBox(width: 8),
              Text('비밀 대화 요청'),
            ],
          ),
          content: const Text(
            '상대방이 비밀 대화(종단간 암호화)를 시작하려고 합니다. 이 대화는 이 기기에서만 열람할 수 있고, 다른 기기와 동기화되지 않습니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('거절'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('수락'),
            ),
          ],
        ),
      );
      _secretInviteDialogShowing = false;
      if (accept == true) {
        await widget.session.acceptSecretInvite(invite);
        // 수락하자마자 바로 그 대화방을 연다 — 이미 초대 시점에 room:created로 목록에
        // 들어와 있으므로(secretStatus: 'pending') 여기선 찾기만 하면 된다.
        final matches = widget.session.rooms.where(
          (r) => r.id == invite.roomId,
        );
        final room = matches.isEmpty ? null : matches.first;
        if (room != null && mounted) {
          if (MediaQuery.sizeOf(context).width >= wideBreakpoint) {
            widget.session.requestOpenRoom(room);
          } else {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ChatScreen(session: widget.session, room: room),
              ),
            );
          }
        }
      } else {
        await widget.session.rejectSecretInvite(invite);
      }
      if (mounted) _maybeShowSecretInvite();
    });
  }

  /// session.dart의 _checkForUpdate()가 새 버전을 찾으면 한 번만 대화상자를 띄운다.
  /// 예전엔 화면 위쪽 얇은 MaterialBanner라 놓치기 쉬웠는데, 눈에 잘 띄도록 모달
  /// 대화상자로 바꿨다(UpdateDialog 참고). "이미 띄웠는지"는 session에 두고 로그인 화면
  /// (LoginScreen)과 공유한다 — 로그인 전에 이미 봤으면 로그인 직후 또 뜨지 않게.
  void _maybeShowUpdateBanner() {
    final version = widget.session.updateAvailableVersion;
    if (version == null || widget.session.updateBannerShown) return;
    widget.session.updateBannerShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (_) => UpdateDialog(session: widget.session, version: version),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        // 팀을 아직 고르지 않은 상태(로그인 직후, 로그인 유지로 앱을 새로 켰을 때, 전환
        // 팝업에서 "팀 목록"으로 돌아왔을 때)에는 채팅 화면 대신 팀 선택 화면을 보여준다.
        final hasTeam = widget.session.currentTeam != null;
        if (!hasTeam) {
          // 좁은 화면에서 방을 열어둔 채 팀에서 빠진 경우처럼, 위에 쌓여 있는 ChatScreen이
          // 팀 선택 화면을 덮고 있으면 걷어낸다(좁음→넓음 전환과 같은 이유) — 다만 방금
          // "팀이 있다가 없어진" 순간에만 한다. 팀 선택 화면에 이미 있는 상태에서 매
          // 리빌드마다 다시 확인하면, 그 화면에서 연 다이얼로그(팀 생성하기 등)가 떠 있는
          // 동안 session이 다른 이유로 갱신되기만 해도 popUntil이 그 다이얼로그까지
          // 걷어내 버린다(_hadTeam 주석 참고).
          if (_hadTeam && Navigator.of(context).canPop()) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
            });
          }
          _hadTeam = false;
          return TeamSelectScreen(session: widget.session);
        }
        _hadTeam = true;
        return _buildTeamHome(context);
      },
    );
  }

  Widget _buildTeamHome(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= wideBreakpoint;
        if (_wasWide == false && isWide) {
          // 좁음 → 넓음으로 막 바뀌었다 — 좁은 화면에서 push해둔 ChatScreen 등이 있으면
          // 걷어내서, DesktopHomeScreen이 이어서 보여주는 방이 실제로 화면에 드러나게
          // 한다(위 _wasWide 주석 참고). build 도중에는 Navigator를 건드릴 수 없어서
          // 프레임이 끝난 뒤로 미룬다.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Navigator.of(context).popUntil((route) => route.isFirst);
            }
          });
        }
        _wasWide = isWide;
        if (isWide) {
          return DesktopHomeScreen(session: widget.session);
        }
        return RoomListScreen(session: widget.session);
      },
    );
  }
}
