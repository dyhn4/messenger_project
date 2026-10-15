import 'dart:convert';

import 'package:client/screens/settings_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 환경설정 > 메신저 설정의 "다른 기기 접속 중에도 휴대폰 알림 받기" — 서버(계정)에 저장되는 알림 설정
/// (notification_settings.pushWhileOnline)이라 창을 열 때 서버 값을 받아 오고, 다른 항목처럼 "저장하기"를 눌러야 보낸다.
void main() {
  const serverUrl = 'https://192.168.0.10:3000';
  const jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

  late List<http.Request> requests;
  late Map<String, dynamic> serverSettings;
  late bool failPatch;

  Session buildSession() {
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/api/notification-settings') {
        if (request.method == 'PATCH') {
          if (failPatch) {
            return http.Response(
              jsonEncode({'error': '서버 오류'}),
              500,
              headers: jsonHeaders,
            );
          }
          serverSettings.addAll(
            jsonDecode(request.body) as Map<String, dynamic>,
          );
        }
        return http.Response(
          jsonEncode(serverSettings),
          200,
          headers: jsonHeaders,
        );
      }
      return http.Response('[]', 200, headers: jsonHeaders);
    });
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.serverUrl = serverUrl;
    session.api = ApiClient(baseUrl: serverUrl, token: 't', httpClient: client);
    session.userId = 'me';
    return session;
  }

  setUp(() {
    requests = [];
    // 이 값이 없는 응답(예전 서버·설정 행 없음)이면 기본값은 켬이다.
    serverSettings = {'mentionAll': true, 'boardLevel': 'important'};
    failPatch = false;
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'TangoTalk',
      packageName: 'client',
      version: '1.1.3',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  Future<Session> pump(WidgetTester tester) async {
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
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = buildSession();
    await session.settings.init();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsScreen(session: session)),
      ),
    );
    await tester.pumpAndSettle();
    return session;
  }

  final checkbox = find.descendant(
    of: find.byKey(const ValueKey('settings-push-while-online')),
    matching: find.byType(Checkbox),
  );
  List<http.Request> patches() => requests
      .where(
        (r) =>
            r.method == 'PATCH' && r.url.path == '/api/notification-settings',
      )
      .toList();

  /// 저장해도 창은 닫히지 않고 "저장했습니다." 알약만 뜬다 — 그 알약이 사라질 때까지 기다린다.
  Future<void> save(WidgetTester tester) async {
    await tester.ensureVisible(find.text('저장하기'));
    await tester.tap(find.text('저장하기'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('메신저 설정에 있고, 서버 값을 받아 와서 기본은 켬이다', (tester) async {
    await pump(tester);
    expect(find.text('휴대폰 알림'), findsOneWidget);
    expect(find.text('다른 기기 접속 중에도 휴대폰 알림 받기'), findsOneWidget);
    expect(tester.widget<Checkbox>(checkbox).value, isTrue);
  });

  testWidgets('끄고 "저장하기"를 눌러야 서버에 보낸다', (tester) async {
    final session = await pump(tester);
    await tester.ensureVisible(find.text('다른 기기 접속 중에도 휴대폰 알림 받기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('다른 기기 접속 중에도 휴대폰 알림 받기'));
    await tester.pump();
    expect(tester.widget<Checkbox>(checkbox).value, isFalse);
    expect(patches(), isEmpty); // 저장하기 전에는 보내지 않는다.

    await save(tester);
    expect(jsonDecode(patches().single.body), {'pushWhileOnline': false});
    expect(session.notificationCenter.settings!.pushWhileOnline, isFalse);
  });

  testWidgets('바꾸지 않고 저장하면 서버에 보내지 않는다', (tester) async {
    await pump(tester);
    await save(tester);
    expect(patches(), isEmpty);
  });

  testWidgets('서버 저장에 실패하면 창을 닫지 않고 알린다', (tester) async {
    failPatch = true;
    await pump(tester);
    await tester.ensureVisible(find.text('다른 기기 접속 중에도 휴대폰 알림 받기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('다른 기기 접속 중에도 휴대폰 알림 받기'));
    await tester.pump();
    await tester.ensureVisible(find.text('저장하기'));
    await tester.tap(find.text('저장하기'));
    await tester.pumpAndSettle();
    expect(find.textContaining('휴대폰 알림 설정을 저장하지 못했습니다'), findsOneWidget);
    expect(find.text('저장했습니다.'), findsNothing);
    expect(find.text('저장하기'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // 알림(토스트)이 사라질 때까지.
  });
}
