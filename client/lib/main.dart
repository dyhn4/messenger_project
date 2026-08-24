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
  late final session = Session(notifications: notifications, settings: appSettings);

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

    final width = navigatorKey.currentContext != null ? MediaQuery.sizeOf(navigatorKey.currentContext!).width : 0.0;
    if (width >= wideBreakpoint) {
      // 넓은(PC) 화면은 이미 사이드바+채팅패널이 떠있으니 새 화면을 덮어씌우지 않고
      // DesktopHomeScreen이 우측 패널만 바꾸도록 요청만 남긴다.
      session.requestOpenRoom(room);
    } else {
      navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => ChatScreen(session: session, room: room)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: '메신저',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          return switch (session.stage) {
            AuthStage.loadingConfig => const Scaffold(body: Center(child: CircularProgressIndicator())),
            AuthStage.needsServer => ServerSetupScreen(session: session),
            AuthStage.needsLogin => LoginScreen(session: session),
            AuthStage.ready => HomeScreen(session: session),
          };
        },
      ),
    );
  }
}
