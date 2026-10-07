import 'dart:convert';

import 'package:client/screens/admin_console_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 관리자 콘솔 "운영 현황" 탭의 웹 앱 주소(정식 인증서) 카드 — 서버가 상태를 주면 운영 현황 아래에 보이고, 이 기능이
/// 없는 예전 서버(404)면 카드만 빠지고 나머지 운영 현황은 그대로다.
void main() {
  const serverUrl = 'https://192.168.0.10:3000';
  const jsonHeaders = {'content-type': 'application/json; charset=utf-8'};
  final expires = DateTime(2026, 12, 30, 14, 5);

  Session buildSession(http.Response Function() webCertificate) {
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/api/admin/stats':
          return http.Response(
            jsonEncode({
              'users': 12,
              'teams': 2,
              'rooms': 5,
              'messages': 100,
              'messagesToday': 3,
              'uploadBytes': 2048,
              'serverStartedAt': DateTime(
                2026,
                10,
                7,
                8,
              ).millisecondsSinceEpoch,
              'teamCreation': 'member',
              'teamInviteLinkCreation': 'admin',
              'orgScope': 'team',
              'projectCreation': 'member',
            }),
            200,
            headers: jsonHeaders,
          );
        case '/api/admin/position-options':
          return http.Response('[]', 200, headers: jsonHeaders);
        case '/api/admin/web-certificate':
          return webCertificate();
      }
      return http.Response('[]', 200, headers: jsonHeaders);
    });
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.serverUrl = serverUrl;
    session.api = ApiClient(baseUrl: serverUrl, token: 't', httpClient: client);
    session.userId = 'u1';
    session.isServerAdmin = true;
    return session;
  }

  Future<void> openConsole(WidgetTester tester, Session session) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAdminConsole(context, session),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
  }

  testWidgets('서버가 상태를 주면 운영 현황에 카드가 보인다', (tester) async {
    await openConsole(
      tester,
      buildSession(
        () => http.Response(
          jsonEncode({
            'enabled': true,
            'domain': 'xxx.iptime.org',
            'status': 'valid',
            'staging': false,
            'expiresAt': expires.millisecondsSinceEpoch,
            'lastAttemptAt': null,
            'lastError': null,
            'nextAttemptAt': null,
            'challenges': {'http01': true, 'tlsAlpn01': true},
          }),
          200,
          headers: jsonHeaders,
        ),
      ),
    );
    expect(find.text('12명'), findsOneWidget); // 운영 현황은 그대로
    expect(find.textContaining('웹 앱 주소(정식 인증서)'), findsOneWidget);
    expect(
      find.text('xxx.iptime.org · 2026/12/30 14:05까지 유효 · 만료 전에 자동 갱신합니다.'),
      findsOneWidget,
    );
  });

  testWidgets('이 기능이 없는 예전 서버(404)면 카드만 빠진다', (tester) async {
    await openConsole(
      tester,
      buildSession(
        () => http.Response(
          '<!DOCTYPE html><pre>Cannot GET /api/admin/web-certificate</pre>',
          404,
          headers: {'content-type': 'text/html'},
        ),
      ),
    );
    expect(find.text('12명'), findsOneWidget);
    expect(find.textContaining('서버 시작:'), findsOneWidget);
    expect(find.textContaining('웹 앱 주소(정식 인증서)'), findsNothing);
    expect(find.textContaining('팀 생성 권한'), findsOneWidget);
  });

  testWidgets('꺼져 있으면 켜는 방법을 알려 준다', (tester) async {
    await openConsole(
      tester,
      buildSession(
        () => http.Response(
          jsonEncode({
            'enabled': false,
            'domain': null,
            'status': 'off',
            'staging': false,
            'expiresAt': null,
            'lastAttemptAt': null,
            'lastError': null,
            'nextAttemptAt': null,
            'challenges': {'http01': false, 'tlsAlpn01': false},
          }),
          200,
          headers: jsonHeaders,
        ),
      ),
    );
    expect(find.textContaining('꺼짐'), findsOneWidget);
    expect(find.textContaining('"웹 앱 주소(정식 인증서)"'), findsOneWidget);
  });
}
