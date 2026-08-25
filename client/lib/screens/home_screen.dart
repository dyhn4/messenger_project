import 'package:flutter/material.dart';

import '../services/session.dart';
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

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
    _maybeShowUpdateBanner();
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() => _maybeShowUpdateBanner();

  /// session.dart의 _checkForUpdate()가 새 버전을 찾으면 한 번만 배너를 띄운다.
  void _maybeShowUpdateBanner() {
    final version = widget.session.updateAvailableVersion;
    if (version == null || _updateBannerShown) return;
    _updateBannerShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showMaterialBanner(
        MaterialBanner(
          content: Text('새 버전(v$version)이 있습니다.'),
          actions: [
            TextButton(
              onPressed: () {
                ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
                widget.session.openUpdateDownload();
              },
              child: const Text('다운로드'),
            ),
            TextButton(
              onPressed: () => ScaffoldMessenger.of(context).hideCurrentMaterialBanner(),
              child: const Text('나중에'),
            ),
          ],
        ),
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
