import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_android/shared_preferences_android.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'screens/chat_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/server_setup_screen.dart';
import 'services/app_settings.dart';
import 'services/deep_link_service.dart';
import 'services/notification_service.dart';
import 'services/pinned_tls.dart';
import 'services/session.dart';

/// 앱이 완전히 종료된 상태에서 FCM이 도착하면 별도의(=Session이 없는) 격리된 isolate에서
/// 이 함수가 새로 불린다 — 로그인 상태/소켓 등 앱의 나머지 상태에 전혀 접근할 수 없어서,
/// push.js가 data payload에 실어 보낸 정보만으로 알림을 직접 그린다. 발신자 아바타(큰
/// 프로필 아이콘)도 이 payload에 포함돼 있어 여기서도 그려지고, 서버 접속 주소/인증서
/// 신뢰 설정은 세션 없이 SharedPreferences/PinnedTls에서 직접 읽어온다.
/// 탑레벨 함수+이 어노테이션이 꼭 있어야 백그라운드 isolate에서 찾아 호출할 수 있다.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  final data = message.data;
  final roomId = data['roomId'] as String?;
  if (roomId == null) return;

  // SharedPreferences(레거시 싱글턴)는 같은 isolate 안에서 값을 캐싱해두고 재사용한다 —
  // Firebase는 이 백그라운드 isolate를 메시지마다 새로 만들지 않고 재사용할 수 있어서,
  // 캐싱된 인스턴스를 쓰면 그 사이 메인 엔진이 저장한 최신 값을 못 보고 예전 값을 계속
  // 읽게 된다. SharedPreferencesAsync는 매번 네이티브에서 직접 읽어와 이 문제가 없다.
  // 안드로이드 기본 백엔드는(DataStore) Session이 쓰는 레거시 SharedPreferences(XML)와
  // 완전히 다른 저장소라 — 명시적으로 SharedPreferences 백엔드를 지정해야 같은 값을 본다.
  final prefs = SharedPreferencesAsync(
    options: SharedPreferencesAsyncAndroidOptions(
      backend: SharedPreferencesAndroidBackendLibrary.SharedPreferences,
      // 파일명을 안 주면 안드로이드 기본 preferences 파일(PreferenceManager)을 열어서
      // 레거시 SharedPreferences 플러그인이 쓰는 "FlutterSharedPreferences" 파일과
      // 전혀 다른 곳을 보게 된다 — 명시적으로 같은 파일명을 지정해야 한다.
      originalSharedPreferencesOptions: const AndroidSharedPreferencesStoreOptions(
        fileName: 'FlutterSharedPreferences',
      ),
    ),
  );
  // 메인 엔진(Session._persistForegroundState)이 남겨둔 값 — 지금 그 방을 보고 있는
  // 중이면(=소켓 경로였다면 isViewingNow로 걸러졌을 상황) 이 격리된 백그라운드 경로에서도
  // 똑같이 건너뛴다. 알림을 탭해서 막 방을 연 직후, 소켓/프레즌스가 아직 못 따라잡아
  // 서버가 FCM도 같이 보낸 경우가 바로 이 경로로 온다.
  // Session이 쓰는 레거시 SharedPreferences는 모든 키 앞에 자동으로 "flutter."를 붙이는데,
  // SharedPreferencesAsync는 그 프리픽스를 대신 붙여주지 않는다 — 직접 붙여야 같은 값을 찾는다.
  final fg = await prefs.getBool('flutter.${Session.kAppInForegroundPrefsKey}');
  final active = await prefs.getString(
    'flutter.${Session.kActiveRoomIdPrefsKey}',
  );
  final isViewingNow = fg == true && active == roomId;
  if (isViewingNow) return;

  final notifications = NotificationService();
  await notifications.init(
    onTap: (_) {}, // 이 isolate엔 화면이 없어 탭 이동은 못 한다.
    requestPermission:
        false, // 헤드리스 isolate라 권한 요청 다이얼로그를 못 띄운다(NotificationService 참고).
  );

  // push.js가 sender의 아바타 정보를 data payload에 실어 보낸다(avatarUrl은 서버가 이미
  // 서명해서 상대경로로 보냄) — 프로필 사진을 받아오려면 이 isolate에도 자체 서명 인증서
  // 신뢰 설정과 서버 주소가 필요하다(둘 다 세션 없이 SharedPreferences에서 직접 읽는다).
  await PinnedTls.installGlobalHttpOverrides();
  final serverUrl = await prefs.getString('flutter.server_base_url');
  final avatarUrlRaw = data['avatarUrl'] as String?;
  final avatarUrl = avatarUrlRaw == null
      ? null
      : (avatarUrlRaw.startsWith('http') || serverUrl == null
            ? avatarUrlRaw
            : '$serverUrl$avatarUrlRaw');

  await notifications.showMessage(
    title: data['title'] as String? ?? 'TangoTalk',
    body: data['body'] as String? ?? '',
    roomId: roomId,
    senderName: data['senderName'] as String?,
    conversationTitle: data['conversationTitle'] as String?,
    avatarType: data['avatarType'] as String? ?? 'initial',
    avatarEmoji: data['avatarEmoji'] as String?,
    avatarColor: data['avatarColor'] as String?,
    avatarUrl: avatarUrl,
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
  // 창 닫기(X)를 눌러도 앱이 종료되지 않고 시스템 트레이로 내려가도록(백그라운드에서 계속
  // 알림을 받게) — setPreventClose로 OS의 기본 닫기 동작을 막고, 실제 처리는
  // _MyAppState.onWindowClose(WindowListener)가 한다.
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
  }
  runApp(const MyApp());
}

/// 옛한글(고어) 자모 조합 글리프 — 기본 폰트(Roboto)에는 없어서 채팅에 옛한글을 쓰면
/// 네모(tofu)로 보인다. pubspec.yaml에 번들된 폰트(SIL OFL 1.1, assets/fonts/OFL.txt 참고).
const _oldHangulFontFamily = 'NanumBarunGothicYetHangul';

/// 기존 테마의 폰트/글자 크기는 그대로 두고, 기본 폰트에 없는 글리프만 [_oldHangulFontFamily]로
/// 대체되도록 fontFamilyFallback만 얹는다 — 그래서 채팅 내용뿐 아니라 입력창, 방 제목 등
/// 텍스트가 나오는 모든 곳에서 옛한글이 깨지지 않고 보인다.
ThemeData _withOldHangulFallback(ThemeData theme) {
  const fallback = [_oldHangulFontFamily];
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamilyFallback: fallback),
    primaryTextTheme: theme.primaryTextTheme.apply(fontFamilyFallback: fallback),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp>
    with WidgetsBindingObserver, WindowListener, TrayListener {
  final navigatorKey = GlobalKey<NavigatorState>();
  final notifications = NotificationService();
  final appSettings = AppSettings();
  final deepLinks = DeepLinkService();
  late final session = Session(
    notifications: notifications,
    settings: appSettings,
  );
  StreamSubscription<PairRequest>? _pairRequestSub;

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
    deepLinks.getInitialPairRequest().then((req) {
      if (req != null) _onPairRequest(req);
    });
    _pairRequestSub = deepLinks.pairRequestStream.listen(_onPairRequest);
    // session.toasts는 HomeScreen이 자기 자신의 context로 구독해서 보여준다(main.dart의
    // navigatorKey.currentContext는 Navigator 위젯 자체의 context라 SnackBar/Overlay가
    // 화면에 그려지지 않는다 — home_screen.dart 참고).
    if (Platform.isWindows) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _initTray();
    }
  }

  /// 초대 링크로 받은 서버 주소/코드를 세션에 넘기고, PC는 창을 앞으로 가져온다
  /// (Windows는 SendAppLinkToInstance가 이미 그렇게 해주지만, 콜드 스타트로 막 켜진
  /// 경우까지 포함해 한 번 더 확실히 해둔다 — 안드로이드는 OS가 알아서 앱을 앞으로 보낸다).
  void _onPairRequest(PairRequest request) {
    if (Platform.isWindows) {
      windowManager.show();
      windowManager.focus();
    }
    session.setPendingPairRequest(request);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session.removeListener(_tryOpenPendingLaunchRoom);
    _pairRequestSub?.cancel();
    session.chatSocket.dispose();
    if (Platform.isWindows) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }

  /// 창 닫기(X)를 눌러도 종료되지 않고 트레이 아이콘으로 내려가게 하는 대신, 사용자가
  /// 완전히 종료할 방법을 트레이 메뉴로 제공해야 한다("작업 관리자로만 끌 수 있는 앱"이
  /// 되지 않도록).
  Future<void> _initTray() async {
    await trayManager.setIcon('assets/tray_icon.ico');
    await trayManager.setToolTip('TangoTalk');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show_window', label: '창 열기'),
          MenuItem.separator(),
          MenuItem(key: 'exit_app', label: '완전히 종료'),
        ],
      ),
    );
  }

  @override
  void onWindowClose() async {
    // setPreventClose(true) 때문에 X를 눌러도 OS가 창을 실제로 닫지 않고 이 콜백만 부른다 —
    // 여기서 직접 hide()해서 "종료된 것처럼 보이지만 트레이에 남아 알림을 계속 받는" 상태로
    // 만든다. 트레이 메뉴의 "완전히 종료"만 실제로 프로세스를 끝낸다.
    if (await windowManager.isPreventClose()) {
      await windowManager.hide();
    }
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    // tray_manager는 우클릭을 감지만 해줄 뿐 메뉴를 직접 띄워주지는 않는다 —
    // popUpContextMenu()를 호출해야 setContextMenu로 등록해둔 메뉴가 실제로 보인다.
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show_window':
        await windowManager.show();
        await windowManager.focus();
      case 'exit_app':
        // 여기서만 preventClose를 풀어야 close()가 진짜로 창을 닫고 프로세스가 끝난다.
        await windowManager.setPreventClose(false);
        await windowManager.close();
    }
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

  Future<void> _openRoomFromNotification(String roomId) async {
    final match = session.rooms.where((r) => r.id == roomId);
    if (match.isEmpty) return;
    final room = match.first;

    // 비밀 대화 요청인데 내가 아직 응답 안 한 쪽이면, 방을 바로 열지 않고 수락/거절
    // 다이얼로그부터 띄운다. 온라인이었다면 secret:invite 소켓 이벤트로 이미
    // pendingSecretInvites에 들어있겠지만, 앱이 꺼져있어서 FCM 알림만 받았을 때는 그
    // 이벤트를 놓쳤으므로 여기서 서버에 다시 물어봐야 한다(ensurePendingSecretInvite).
    if (room.isSecret &&
        room.secretStatus == 'pending' &&
        room.secretInitiatorUserId != session.userId) {
      await session.ensurePendingSecretInvite(roomId);
      return; // HomeScreen이 pendingSecretInvites를 보고 다이얼로그를 띄운다.
    }

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
          title: 'TangoTalk',
          theme: _withOldHangulFallback(
            ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
              useMaterial3: true,
            ),
          ),
          darkTheme: _withOldHangulFallback(
            ThemeData(
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
