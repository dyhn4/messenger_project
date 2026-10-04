import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/settings_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/app_lock_overlay.dart';
import 'package:client/widgets/chat_input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};

Session _session({String password = 'secret'}) {
  final client = MockClient((request) async {
    if (request.url.path == '/api/users/me/verify-password') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return body['password'] == password
          ? http.Response(jsonEncode({'ok': true}), 200, headers: _json)
          : http.Response(
              jsonEncode({'error': '비밀번호가 올바르지 않습니다.'}),
              401,
              headers: _json,
            );
    }
    return http.Response('[]', 200, headers: _json);
  });
  final s = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  s.serverUrl = 'https://test.local';
  s.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: client,
  );
  s.userId = 'me';
  s.currentTeam = Team(id: 't1', name: '팀', createdAt: DateTime(2026));
  return s;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'TangoTalk',
      packageName: 'client',
      version: '1.1.3',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  // AppSettings.init()이 창 속성(최소 크기·항상 위·불투명도)을 적용하려고 부르는 채널 — 테스트엔
  // 창이 없으니 그냥 받아 준다.
  void mockWindowManager(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (_) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      ),
    );
  }

  testWidgets('환경설정: 왼쪽 사이드바(메신저 설정 / 화면 설정 / 시스템 설정)와 각 항목', (tester) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final s = _session();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsScreen(session: s)),
      ),
    );
    await tester.pump();

    expect(find.text('메신저 설정'), findsWidgets); // 사이드바 + 오른쪽 제목
    expect(find.text('화면 설정'), findsOneWidget);
    expect(find.text('시스템 설정'), findsOneWidget);

    // 메신저 설정 — 팀 전환 방식 · 메시지 내용 미리보기 · 메시지 전송 옵션 설정.
    expect(find.text('팀 전환 방식'), findsOneWidget);
    expect(find.text('메시지 내용 미리보기'), findsOneWidget);
    expect(find.text('메시지 전송 옵션 설정'), findsOneWidget);
    expect(find.text('Enter로 전송'), findsOneWidget);
    expect(find.text('Shift + Enter로 전송'), findsOneWidget);
    // 기본은 Enter로 전송 — 그 카드에 체크.
    Icon checkOf(String title) => tester.widget<Icon>(
      find.descendant(
        of: find.ancestor(of: find.text(title), matching: find.byType(InkWell)),
        matching: find.byType(Icon),
      ),
    );
    expect(checkOf('Enter로 전송').icon, Icons.check_circle);
    await tester.tap(find.text('Shift + Enter로 전송'));
    await tester.pump();
    expect(checkOf('Shift + Enter로 전송').icon, Icons.check_circle);
    expect(checkOf('Enter로 전송').icon, Icons.circle_outlined);
    expect(find.text('화면 테마'), findsNothing);

    // 화면 설정 — 텍스트 크기 · 화면 테마 · 반투명 · 창 깜빡임 · 작업표시줄 깜빡임.
    await tester.tap(find.text('화면 설정'));
    await tester.pump();
    for (final label in [
      '텍스트 크기',
      '화면 테마',
      '반투명',
      '창 깜빡임',
      '작업표시줄 깜빡임',
      '글꼴',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('화이트 (기본)'), findsOneWidget);
    expect(find.text('다크'), findsOneWidget);
    expect(find.text('본인이 선호하는 컬러 테마를 설정할 수 있습니다.'), findsOneWidget);
    expect(find.text('팀 전환 방식'), findsNothing);
    expect(find.text('시작 시 자동 실행'), findsNothing); // 시스템 설정으로 남아 있다.

    Icon radioOf(String label) => tester.widget<Icon>(
      find.descendant(
        of: find.ancestor(of: find.text(label), matching: find.byType(InkWell)),
        matching: find.byType(Icon),
      ),
    );
    expect(radioOf('화이트 (기본)').icon, Icons.radio_button_checked);
    await tester.tap(find.text('다크'));
    await tester.pump();
    expect(radioOf('다크').icon, Icons.radio_button_checked);
    expect(radioOf('화이트 (기본)').icon, Icons.radio_button_off);

    // 시스템 설정 — 시작 시 자동 실행 · 항상 위로 · 파일 다운로드 · 자동 잠금(화면 설정으로
    // 옮긴 화면 테마·반투명·작업표시줄 깜빡임은 여기 없다).
    await tester.tap(find.text('시스템 설정'));
    await tester.pump();
    for (final label in ['시작 시 자동 실행', '항상 위로', '파일 다운로드', '자동 잠금']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('화면 테마'), findsNothing);
    expect(find.text('반투명'), findsNothing);
    expect(find.text('작업표시줄 깜빡임'), findsNothing);
    expect(find.text('창 깜빡임'), findsNothing);
    expect(find.text('절전모드 시 TangoTalk 자동 잠금'), findsOneWidget);
  });

  testWidgets('잠금 화면: 잠겨 있으면 앱 전체를 덮고, 비밀번호가 맞아야 풀린다', (tester) async {
    mockWindowManager(tester);
    final s = _session();
    await s.settings.init();
    await s.settings.setAppLocked(true);
    s.stage = AuthStage.ready;

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppLockGate(session: s, child: child!),
        home: const Scaffold(body: Center(child: Text('대화 내용'))),
      ),
    );
    await tester.pump();
    expect(find.textContaining('현재 화면 잠금모드입니다.'), findsOneWidget);

    // 틀린 비밀번호 — 서버가 알려준 문구를 보여주고 계속 잠겨 있다.
    await tester.enterText(find.byType(TextField), 'wrong');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump();
    expect(find.text('비밀번호가 올바르지 않습니다.'), findsOneWidget);
    expect(s.settings.appLocked, isTrue);

    // 맞는 비밀번호 — 잠금이 풀리고(저장도) 잠금 화면이 사라진다.
    await tester.enterText(find.byType(TextField), 'secret');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump();
    expect(s.settings.appLocked, isFalse);
    expect(find.textContaining('현재 화면 잠금모드입니다.'), findsNothing);
    expect(find.text('대화 내용'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('settings_app_locked'), isFalse);
  });

  testWidgets('잠금 화면: 로그인 전 화면에서는 잠그지 않는다', (tester) async {
    final s = _session();
    s.settings.appLocked = true;
    s.stage = AuthStage.needsLogin;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppLockGate(session: s, child: child!),
        home: const Scaffold(body: Text('로그인')),
      ),
    );
    expect(find.textContaining('현재 화면 잠금모드입니다.'), findsNothing);
  });

  testWidgets(
    '텍스트 크기: -/+ 단추로 10%씩 바뀌고, 가운데 알약을 누르면 100%로 돌아가며, 80~150% 밖으로는 안 간다',
    (tester) async {
      mockWindowManager(tester);
      final s = _session();
      await s.settings.init();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SettingsScreen(session: s)),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('화면 설정'));
      await tester.pump();

      expect(find.text('100% 기본 크기'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(find.text('110% 기본 크기'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(find.text('120% 기본 크기'), findsOneWidget);

      // 가운데 알약을 누르면 100%로 바로 돌아간다.
      await tester.tap(find.text('120% 기본 크기'));
      await tester.pump();
      expect(find.text('100% 기본 크기'), findsOneWidget);

      // 최솟값(80%)에서 더 안 내려간다.
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byIcon(Icons.remove));
        await tester.pump();
      }
      expect(find.text('80% 기본 크기'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.remove));
      await tester.pump();
      expect(find.text('80% 기본 크기'), findsOneWidget); // 더 안 내려감

      // 최댓값(150%)에서 더 안 올라간다.
      for (var i = 0; i < 7; i++) {
        await tester.tap(find.byIcon(Icons.add));
        await tester.pump();
      }
      expect(find.text('150% 기본 크기'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(find.text('150% 기본 크기'), findsOneWidget); // 더 안 올라감
    },
  );

  testWidgets('AppSettings.setTextScale: 저장되고, 범위 밖 값은 80~150%로 붙는다', (
    tester,
  ) async {
    mockWindowManager(tester);
    final settings = AppSettings();
    await settings.init();

    await settings.setTextScale(1.2);
    expect(settings.textScale, 1.2);
    var prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('settings_text_scale'), 1.2);

    await settings.setTextScale(2.0); // 범위 밖 — 최댓값으로 붙는다.
    expect(settings.textScale, maxTextScale);

    await settings.setTextScale(0.1); // 범위 밖 — 최솟값으로 붙는다.
    expect(settings.textScale, minTextScale);
  });

  testWidgets('창 깜빡임: 기본은 깜빡임, 화면 설정에서 "깜빡이지 않음"을 골라 저장하면 저장된다', (
    tester,
  ) async {
    mockWindowManager(tester);
    final s = _session();
    await s.settings.init();
    expect(s.settings.flashWindowFrame, isTrue);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsScreen(session: s)),
      ),
    );
    await tester.tap(find.text('화면 설정'));
    await tester.pump();
    expect(find.text('깜빡임 (기본값)'), findsOneWidget);
    await tester.ensureVisible(find.text('깜빡이지 않음'));
    await tester.tap(find.text('깜빡이지 않음'));
    await tester.pump();
    await tester.tap(find.text('저장하기'));
    await tester.pumpAndSettle();
    expect(s.settings.flashWindowFrame, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('settings_flash_window_frame'), isFalse);
  });

  testWidgets('글꼴: 화면 설정 > 글꼴에서 검색해서 고르고 저장하면 저장된다', (tester) async {
    mockWindowManager(tester);
    final s = _session();
    await s.settings.init();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsScreen(session: s)),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('화면 설정'));
    await tester.pump();

    // 아직 안 고르면 단추 글자가 "시스템 기본".
    expect(find.text('시스템 기본'), findsOneWidget);
    await tester.tap(find.text('시스템 기본'));
    await tester.pumpAndSettle();

    // 검색해서 좁힌다 — 이 PC에 실제로 깔려 있는 "맑은 고딕"을 쓴다(Windows 기본 글꼴).
    await tester.enterText(find.byType(TextField), '맑은');
    await tester.pump();
    expect(find.text('맑은 고딕'), findsOneWidget);
    await tester.tap(find.text('맑은 고딕'));
    await tester.pumpAndSettle();

    // 패널이 닫히고 단추 글자가 바뀐다.
    expect(find.text('맑은 고딕'), findsOneWidget);
    expect(find.text('시스템 기본'), findsNothing);

    await tester.tap(find.text('저장하기'));
    await tester.pump();
    expect(s.settings.fontFamily, '맑은 고딕');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('settings_font_family'), '맑은 고딕');
  });

  testWidgets('글꼴 초기화: 드롭다운 목록의 "시스템 기본"을 고르면 되돌아가고 저장도 된다', (tester) async {
    mockWindowManager(tester);
    final s = _session();
    await s.settings.init();
    await s.settings.setFontFamily('맑은 고딕');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsScreen(session: s)),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('화면 설정'));
    await tester.pump();

    // 이미 글꼴을 고른 상태로 열렸으니 단추 글자가 그 이름이다. 목록을 열면 맨 위에
    // "시스템 기본"이 늘 있다(별도 "초기화" 단추 없이 이걸로 되돌린다).
    expect(find.text('맑은 고딕'), findsOneWidget);
    await tester.tap(find.text('맑은 고딕'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('시스템 기본'));
    await tester.pumpAndSettle();
    expect(find.text('시스템 기본'), findsOneWidget);
    expect(find.text('맑은 고딕'), findsNothing);

    await tester.tap(find.text('저장하기'));
    await tester.pump();
    expect(s.settings.fontFamily, '');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('settings_font_family'), '');
  });

  group('메시지 전송 옵션', () {
    Future<(TextEditingController, Session)> pumpBar(
      WidgetTester tester, {
      required bool shiftToSend,
    }) async {
      final s = _session();
      s.settings.sendWithShiftEnter = shiftToSend;
      final room = Room(
        id: 'r1',
        teamId: 't1',
        type: RoomType.topic,
        name: '토픽',
        members: const [],
        createdAt: DateTime(2026),
        lastRead: const {},
      );
      s.rooms.add(room);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ChatInputBar(
                controller: s.controllerFor(room),
                session: s,
                room: room,
                stickerPickerOpen: false,
                stickerPickerGroupId: Object(),
                onToggleStickerPicker: () {},
                onStickerConsumed: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), '안녕하세요');
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      return (field.controller!, s);
    }

    testWidgets('기본: Enter로 보낸다', (tester) async {
      final (text, _) = await pumpBar(tester, shiftToSend: false);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(text.text, isEmpty); // 보내면서 입력칸을 비운다
    });

    testWidgets('Shift + Enter로 전송: Enter로는 안 보내고, Shift+Enter로 보낸다', (
      tester,
    ) async {
      final (text, _) = await pumpBar(tester, shiftToSend: true);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(text.text, '안녕하세요'); // 그대로(줄바꿈 몫)

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(text.text, isEmpty);
      expect(find.text('Shift + Enter 로 전송'), findsOneWidget);
    });
  });
}
