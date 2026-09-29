import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/app_settings.dart';
import '../../services/notification_service.dart';
import '../../services/pinned_tls.dart';
import '../../services/app_links.dart';
import '../../services/session.dart';
import 'project_dialog.dart';

/// 창 생성 인자(JSON)의 "type" 값 — 지금은 "프로젝트" 창 하나뿐이지만, 나중에 다른 종류의
/// 서브 창이 생기면 이 값으로 구분한다.
const _kProjectWindowType = 'project';

/// 지금 떠 있는 창 중 "프로젝트" 창들만 골라낸다(지금은 최대 하나뿐이지만, 나중에 검색용
/// 둘째 창 등이 생겨도 이 함수만 그대로 재사용할 수 있게 목록으로 돌려준다).
Future<List<WindowController>> _findProjectWindows() async {
  final existing = await WindowController.getAll();
  final result = <WindowController>[];
  for (final controller in existing) {
    if (controller.arguments.isEmpty) continue;
    try {
      final args = jsonDecode(controller.arguments) as Map<String, dynamic>;
      if (args['type'] == _kProjectWindowType) result.add(controller);
    } catch (_) {
      // 무시 — 우리가 만들지 않은 형식이면 프로젝트 창이 아니다.
    }
  }
  return result;
}

/// Windows에서 "프로젝트"를 대화상자가 아니라 독립된 OS 창(별도 작업표시줄 항목)으로 연다.
/// 이미 열려있으면 새로 만들지 않고 그 창을 앞으로 가져온다(최소화돼 있었다면 복원까지).
/// [openLink](노트·업무 링크)를 주면 프로젝트 창에서 그 노트·업무를 연다(링크를 눌렀을 때).
Future<void> openProjectWindow(Session session, {String? openLink}) async {
  final existingProjectWindows = await _findProjectWindows();
  if (existingProjectWindows.isNotEmpty) {
    try {
      await existingProjectWindows.first.invokeMethod('window_focus');
      if (openLink != null) {
        await existingProjectWindows.first.invokeMethod('open_link', {
          'href': openLink,
        });
      }
    } catch (_) {
      // 창이 그 사이 닫혔거나 응답이 없으면 그냥 포기한다 — 다음 클릭에서 getAll()이
      // 이미 정리된 목록을 돌려주므로 새 창이 만들어진다.
    }
    return;
  }

  // 서브 창은 메인 창의 Session을 공유할 수 없는 별도 엔진이라(main.dart 참고) 로그인
  // 정보를 직접 건네야 한다 — SharedPreferences를 다시 읽게 하면 안 된다: "로그인 상태
  // 유지"를 꺼둔 사용자는 토큰을 아예 디스크에 저장하지 않으므로(session.dart의 _auth
  // 참고) 서브 창이 그 값을 못 찾아 "로그인이 필요합니다"만 뜨는 채로 막힌다. 대신 지금
  // 메인 창 Session이 메모리에 들고 있는 값을 그대로 창 생성 인자로 넘긴다(같은 프로세스
  // 안의 네이티브 채널로만 오가고 디스크/네트워크로 나가지 않는다). 이 창이 열려있는 동안
  // 메인 창에서 팀을 바꾸거나 로그아웃해도 실시간으로 따라가지는 않는다 — 다시 열면 그때
  // 최신 상태를 새로 반영한다.
  final token = session.token;
  final serverUrl = session.serverUrl;
  if (token == null || serverUrl == null) return; // 로그인 안 된 상태면 열 수 없다.
  await WindowController.create(
    WindowConfiguration(
      arguments: jsonEncode({
        'type': _kProjectWindowType,
        'teamId': session.currentTeam?.id,
        'serverUrl': serverUrl,
        'token': token,
        'refreshToken': session.refreshToken,
        'userId': session.userId,
        'username': session.username,
        'openLink': ?openLink,
      }),
    ),
  );
}

/// 메인 창의 환경설정에서 테마(라이트/다크/시스템)를 바꿨을 때 부른다(settings_screen.dart).
/// 열려있는 프로젝트 창은 메인 창과 완전히 다른 엔진이라(session.dart 등 다른 상태와
/// 마찬가지로) settings.setThemeMode 한 번으로는 반영되지 않는다 — 창 사이 채널로 직접
/// 알려준다(project_window.dart의 runProjectWindow가 'theme_changed'를 받아 처리한다).
Future<void> broadcastThemeChange(ThemeMode mode) async {
  if (!Platform.isWindows) return;
  for (final controller in await _findProjectWindows()) {
    try {
      await controller.invokeMethod('theme_changed', {'mode': mode.name});
    } catch (_) {
      // 그 사이 닫혔으면 무시 — 다음에 열 때 어차피 최신 테마로 뜬다.
    }
  }
}

/// 메인 창이 잠기거나(자동 잠금) 풀렸을 때 부른다(app_lock.dart) — 열려 있는 프로젝트 창도
/// 같이 가리고 푼다. 이 창은 다른 엔진이라 잠금 화면을 따로 그려야 한다(아래 'lock_changed').
Future<void> broadcastLockChange(bool locked) async {
  if (!Platform.isWindows) return;
  // 창 목록을 못 얻어도(창 플러그인이 없는 환경 등) 잠금·해제 자체는 이미 끝났으니 조용히 넘어간다.
  List<WindowController> windows;
  try {
    windows = await _findProjectWindows();
  } catch (_) {
    return;
  }
  for (final controller in windows) {
    try {
      await controller.invokeMethod('lock_changed', {'locked': locked});
    } catch (_) {
      // 그 사이 닫혔으면 무시 — 다음에 열 때 저장된 잠금 상태(AppSettings.appLocked)를 읽는다.
    }
  }
}

/// desktop_multi_window로 만들어진 서브 창의 엔진에서 실행되는 진입점. main.dart의 main()이
/// 창 인자를 보고 서브 창이라고 판단하면(비어있지 않은 arguments) 이걸 부른다.
Future<void> runProjectWindow(WindowController controller) async {
  await PinnedTls.installGlobalHttpOverrides();
  await windowManager.ensureInitialized();

  Map<String, dynamic> args = const {};
  try {
    args = jsonDecode(controller.arguments) as Map<String, dynamic>;
  } catch (_) {
    // 잘못된 인자로 들어왔으면(있을 수 없지만) 그냥 빈 값으로 진행 — 팀 선택 안내가 뜬다.
  }
  final teamId = args['teamId'] as String?;
  final serverUrl = args['serverUrl'] as String?;
  final token = args['token'] as String?;

  // settings.init()은 SharedPreferences에서 읽으므로("로그인 상태 유지"와 달리 테마 등은
  // 로그인 여부와 무관하게 항상 저장됨) 이 창에서 바로 불러도 된다 — 메인 창에서 고른
  // 라이트/다크 모드를 그대로 따라가게 한다. windowManager.waitUntilReadyToShow보다 먼저
  // 불러야, 거기서 설정하는 이 창 전용 최소 크기(아래)가 settings.init()이 적용하는 기본
  // 최소 크기로 다시 덮어써지지 않는다.
  final appSettings = AppSettings();
  await appSettings.init();

  // 메인 창이 이 창에 뭔가 알려주고 싶을 때 쓰는 채널(README의 WindowControllerExtension
  // 패턴과 동일) — 'window_focus'는 openProjectWindow가, 'theme_changed'는
  // broadcastThemeChange(settings_screen.dart의 환경설정 저장)가 부른다.
  await controller.setWindowMethodHandler((call) async {
    switch (call.method) {
      case 'window_focus':
        await windowManager.show();
        await windowManager.focus();
        return null;
      case 'open_link':
        final href = (call.arguments as Map?)?['href'] as String?;
        if (href != null) AppLinks.requestOpen(href);
        return null;
      case 'lock_changed':
        final locked = (call.arguments as Map?)?['locked'] == true;
        await appSettings.setAppLocked(locked);
        return null;
      case 'theme_changed':
        final modeName = (call.arguments as Map?)?['mode'] as String?;
        await appSettings.setThemeMode(
          modeName == 'dark' ? ThemeMode.dark : ThemeMode.light,
        );
        return null;
      default:
        throw MissingPluginException('Not implemented: ${call.method}');
    }
  });

  // 메인 창과 완전히 독립된 두 번째 Session — openProjectWindow가 넘겨준 로그인 정보로
  // 바로 로그인 상태를 세운다(session.dart의 restoreFromCredentials). suppressNotifications로
  // 새 메시지 로컬 알림이 두 번 뜨는 것만 막는다.
  final session = Session(
    notifications: NotificationService(),
    settings: appSettings,
    suppressNotifications: true,
  );
  if (serverUrl != null && token != null) {
    await session.restoreFromCredentials(
      serverUrl: serverUrl,
      token: token,
      refreshToken: args['refreshToken'] as String?,
      userId: args['userId'] as String?,
      username: args['username'] as String?,
    );
  } else {
    // 있을 수 없는 경우(메인 창이 로그인 안 된 상태로 이 창을 열려고 함)지만, 방어적으로
    // 기존 방식(디스크에서 복원)이라도 시도한다.
    await session.init();
  }
  if (teamId != null) {
    final match = session.teams.where((t) => t.id == teamId);
    if (match.isNotEmpty) session.enterTeam(match.first);
  }

  // window_manager 예제/README가 늘 이 순서(waitUntilReadyToShow를 먼저 걸어두고 그 다음
  // runApp)를 쓴다 — 창이 기본 크기(800×600, 왼쪽 위)로 잠깐 보였다가 크기가 바뀌는 깜빡임을
  // 피하려는 목적이라, 그대로 따른다.
  const windowOptions = WindowOptions(
    size: Size(1080, 760),
    minimumSize: Size(720, 560),
    center: true,
    title: 'TangoTalk 프로젝트',
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  // 이 창 안에서 노트·업무 링크를 누르면 바로 그리로. 링크로 새로 열린 창이면 거기부터.
  AppLinks.handler = AppLinks.requestOpen;
  final openLink = args['openLink'] as String?;
  if (openLink != null) AppLinks.requestOpen(openLink);
  runApp(_ProjectWindowApp(session: session));
}

class _ProjectWindowApp extends StatelessWidget {
  final Session session;
  const _ProjectWindowApp({required this.session});

  @override
  Widget build(BuildContext context) {
    final darkColorScheme = ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: Brightness.dark,
    );
    // session.settings(AppSettings)는 session과 별개의 ChangeNotifier라, 메인 창에서
    // 테마를 바꿔서 'theme_changed'로 여기 settings가 갱신돼도(위 runProjectWindow) 이
    // 바깥쪽도 따로 감싸서 들어야 MaterialApp의 themeMode가 다시 반영된다.
    return ListenableBuilder(
      listenable: session.settings,
      builder: (context, _) => MaterialApp(
        title: 'TangoTalk 프로젝트',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(colorScheme: darkColorScheme, useMaterial3: true),
        themeMode: session.settings.themeMode,
        // 메인 창이 잠겨 있으면(자동 잠금) 이 창도 가린다 — 잠금 해제는 메인 창에서 한다.
        builder: (context, child) {
          final locked = session.settings.appLocked;
          return Stack(
            children: [
              ExcludeFocus(excluding: locked, child: child!),
              if (locked) const Positioned.fill(child: _LockedCover()),
            ],
          );
        },
        home: ListenableBuilder(
          listenable: session,
          builder: (context, _) {
            switch (session.stage) {
              case AuthStage.loadingConfig:
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              case AuthStage.needsServer:
              case AuthStage.needsLogin:
                // 이 창은 로그인 화면이 없다 — 메인 메신저 창에서 이미 로그인된 상태로만
                // 열리는 게 정상이라, 여기서 로그인 폼을 새로 만들지 않고 안내만 한다.
                // (session.error에 원인이 남아있으면 같이 보여준다 — 토큰 만료 등.)
                return Scaffold(
                  body: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.lock_outline,
                            size: 40,
                            color: Theme.of(context).hintColor,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            session.error ?? '로그인이 필요합니다.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '메신저 창에서 로그인한 뒤 "프로젝트"를 다시 열어주세요.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: session.init,
                            child: const Text('다시 시도'),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              case AuthStage.ready:
                return ProjectDialog(session: session, embedInWindow: true);
            }
          },
        ),
      ),
    );
  }
}

/// 메인 창이 잠겨 있는 동안 프로젝트 창을 덮는 화면.
class _LockedCover extends StatelessWidget {
  const _LockedCover();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF5A5A5A),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.lock, size: 90, color: Colors.white),
            SizedBox(height: 16),
            Text(
              '현재 화면 잠금모드입니다.\n메신저 창에서 비밀번호를 입력해 잠금을 해제해주세요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 15, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
