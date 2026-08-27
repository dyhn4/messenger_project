import 'package:flutter/material.dart';

import 'screens/chat_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/server_setup_screen.dart';
import 'services/app_settings.dart';
import 'services/notification_service.dart';
import 'services/pinned_tls.dart';
import 'services/session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // NetworkImage/CachedNetworkImage처럼 우리 ApiClient/ChatSocket을 거치지 않고 자체
  // HttpClient를 만드는 코드도 전부 서버의 자체 서명 인증서를 신뢰하도록, runApp() 전에
  // 앱 전체 HttpClient 생성을 가로챈다. 이거 없이는 프로필 사진/채팅 이미지가 인증서
  // 신뢰 실패로 안 보인다.
  await PinnedTls.installGlobalHttpOverrides();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final navigatorKey = GlobalKey<NavigatorState>();
  final notifications = NotificationService();
  final appSettings = AppSettings();
  late final session = Session(
    notifications: notifications,
    settings: appSettings,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    appSettings.init();
    notifications.init(onTap: _openRoomFromNotification);
    session.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session.chatSocket.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    session.setAppInForeground(state == AppLifecycleState.resumed);
  }

  void _openRoomFromNotification(String roomId) {
    final match = session.rooms.where((r) => r.id == roomId);
    if (match.isEmpty) return;
    final room = match.first;

    final width = navigatorKey.currentContext != null
        ? MediaQuery.sizeOf(navigatorKey.currentContext!).width
        : 0.0;
    if (width >= wideBreakpoint) {
      // 넓은(PC) 화면은 이미 사이드바+채팅패널이 떠있으니 새 화면을 덮어씌우지 않고
      // DesktopHomeScreen이 우측 패널만 바꾸도록 요청만 남긴다.
      session.requestOpenRoom(room);
    } else {
      // 알림을 여러 번 눌러서 채팅방 화면이 계속 쌓이지 않도록, 새로 열기 전에 항상
      // 첫 화면(메인)까지 되돌아간다 — 그래야 방 안에서 뒤로가기를 누르면 바로 메인이 나온다.
      navigatorKey.currentState?.popUntil((route) => route.isFirst);
      navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(session: session, room: room),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // themeMode가 바뀌면 MaterialApp 자체가 다시 그려져야(theme/darkTheme 중 뭘 쓸지는
    // MaterialApp 레벨 판단이라) session뿐 아니라 appSettings도 같이 듣는다.
    final darkColorScheme = ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: Brightness.dark,
    );
    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) {
        return MaterialApp(
          navigatorKey: navigatorKey,
          title: '메신저',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: darkColorScheme,
            useMaterial3: true,
            // 다크 모드 기본 팝업 메뉴 배경(surfaceContainer)이 배경색과 너무 비슷해서
            // 삼선 메뉴/각 방의 더보기 메뉴가 잘 안 보인다는 피드백에 따라 한 단계 밝은
            // 톤(surfaceContainerHigh)으로 살짝 밝게 조정한다. 라이트 모드는 원래도 문제
            // 없었다고 해서 안 건드린다.
            popupMenuTheme: PopupMenuThemeData(
              color: darkColorScheme.surfaceContainerHigh,
            ),
          ),
          themeMode: appSettings.themeMode,
          home: ListenableBuilder(
            listenable: session,
            builder: (context, _) {
              return switch (session.stage) {
                AuthStage.loadingConfig => const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                ),
                AuthStage.needsServer => ServerSetupScreen(session: session),
                AuthStage.needsLogin => LoginScreen(session: session),
                AuthStage.ready => HomeScreen(session: session),
              };
            },
          ),
        );
      },
    );
  }
}
