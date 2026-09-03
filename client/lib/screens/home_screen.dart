import 'dart:async';

import 'package:flutter/material.dart';

import '../services/session.dart';
import '../widgets/app_toast.dart';
import '../widgets/update_dialog.dart';
import 'chat_screen.dart';
import 'desktop_home_screen.dart';
import 'room_list_screen.dart';

/// 창 너비로 레이아웃을 고른다. 넓으면(PC) 사이드바+채팅패널 분할 화면,
/// 좁으면(폰) 기존 목록 → 채팅화면 전환 방식을 쓴다.
const wideBreakpoint = 700.0;

class HomeScreen extends StatefulWidget {
  final Session session;
  const HomeScreen({super.key, required this.session});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _updateBannerShown = false;
  bool _secretInviteDialogShowing = false;
  StreamSubscription<String>? _toastSub;

  @override
  void initState() {
    super.initState();
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
    widget.session.removeListener(_onSessionChanged);
    _toastSub?.cancel();
    super.dispose();
  }

  void _onSessionChanged() {
    _maybeShowUpdateBanner();
    _maybeShowSecretInvite();
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
  /// 대화상자로 바꿨다(UpdateDialog 참고).
  void _maybeShowUpdateBanner() {
    final version = widget.session.updateAvailableVersion;
    if (version == null || _updateBannerShown) return;
    _updateBannerShown = true;
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
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= wideBreakpoint) {
          return DesktopHomeScreen(session: widget.session);
        }
        return RoomListScreen(session: widget.session);
      },
    );
  }
}
