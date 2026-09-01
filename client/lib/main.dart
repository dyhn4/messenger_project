import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'screens/chat_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/server_setup_screen.dart';
import 'services/app_settings.dart';
import 'services/notification_service.dart';
import 'services/pinned_tls.dart';
import 'services/session.dart';

/// 앱이 완전히 종료된 상태에서 FCM이 도착하면 별도의(=Session이 없는) 격리된 isolate에서
/// 이 함수가 새로 불린다 — 로그인 상태/소켓 등 앱의 나머지 상태에 전혀 접근할 수 없어서,
/// push.js가 data payload에 실어 보낸 title/body/roomId만으로 최소한의 알림을 직접
/// 그린다(아바타/자물쇠 배지 같은 풍부한 렌더링은 앱이 켜져 있을 때의 소켓 경로에서만).
/// 탑레벨 함수+이 어노테이션이 꼭 있어야 백그라운드 isolate에서 찾아 호출할 수 있다.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  final data = message.data;
  final roomId = data['roomId'] as String?;
  if (roomId == null) return;
  final notifications = NotificationService();
  await notifications.init(
    onTap: (_) {}, // 이 isolate엔 화면이 없어 탭 이동은 못 한다.
    requestPermission:
        false, // 헤드리스 isolate라 권한 요청 다이얼로그를 못 띄운다(NotificationService 참고).
  );
  await notifications.showMessage(
    title: data['title'] as String? ?? '메신저',
    body: data['body'] as String? ?? '',
    roomId: roomId,
    isSecret: data['isSecret'] == 'true',
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // NetworkImage/CachedNetworkImage처럼 우리 ApiClient/ChatSocket을 거치지 않고 자체
  // HttpClient를 만드는 코드도 전부 서버의 자체 서명 인증서를 신뢰하도록, runApp() 전에
  // 앱 전체 HttpClient 생성을 가로챈다. 이거 없이는 프로필 사진/채팅 이미지가 인증서
  // 신뢰 실패로 안 보인다.
  await PinnedTls.installGlobalHttpOverrides();
  // FCM은 안드로이드에서만 공식 지원한다 — Windows에서 Firebase.initializeApp()을 부르면
  // google-services.json이 없어 그냥 실패한다(session.dart의 _registerFcmToken도 동일하게
  // Platform.isAndroid로 막아둠).
  if (Platform.isAndroid) {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  }
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

  // 앱이 완전히 종료된 상태에서 FCM 알림을 눌러 새로 켜진 경우, 그 방을 아직 session.rooms가
  // 로딩되기 전이라 바로 못 연다 — 로그인/방 목록 로딩이 끝날 때까지 여기 보관해뒀다가
  // session이 바뀔 때마다(=_tryOpenPendingLaunchRoom) 다시 시도한다.
  String? _pendingLaunchRoomId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    appSettings.init();
    notifications
        .init(onTap: _openRoomFromNotification)
        .then((_) => _checkNotificationLaunch());
    session.addListener(_tryOpenPendingLaunchRoom);
    session.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session.removeListener(_tryOpenPendingLaunchRoom);
    session.chatSocket.dispose();
    super.dispose();
  }

  Future<void> _checkNotificationLaunch() async {
    final roomId = await notifications.getLaunchPayload();
    if (roomId == null) return;
    _pendingLaunchRoomId = roomId;
    _tryOpenPendingLaunchRoom();
  }

  void _tryOpenPendingLaunchRoom() {
    final roomId = _pendingLaunchRoomId;
    if (roomId == null || session.stage != AuthStage.ready) return;
    if (session.rooms.every((r) => r.id != roomId)) return;
    _pendingLaunchRoomId = null;
    _openRoomFromNotification(roomId);
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
