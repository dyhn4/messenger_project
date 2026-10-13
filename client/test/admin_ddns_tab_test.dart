import 'dart:convert';

import 'package:client/screens/admin_ddns_tab.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 관리자 콘솔 "DDNS" 탭 — DuckDNS 자동 갱신 상태를 보여 주고, 도메인·토큰·켜기를 저장하고(토큰은 넣었을 때만 보낸다),
/// "지금 갱신"을 부른다. 이 기능이 없는 예전 서버(404)면 업데이트하라고 안내한다.
void main() {
  const serverUrl = 'https://192.168.0.10:3000';
  const jsonHeaders = {'content-type': 'application/json; charset=utf-8'};
  final success = DateTime(2026, 10, 13, 9, 30);
  final next = DateTime(2026, 10, 13, 9, 35);

  Map<String, dynamic> view({
    bool enabled = true,
    List<String> domains = const ['tangotalk'],
    bool tokenConfigured = true,
    bool? ok = true,
    String? error,
  }) => {
    'enabled': enabled,
    'domains': domains,
    'tokenConfigured': tokenConfigured,
    'status': {
      'enabled': enabled,
      'domains': domains,
      'lastAttemptAt': enabled ? success.millisecondsSinceEpoch : null,
      'lastSuccessAt': ok == true ? success.millisecondsSinceEpoch : null,
      'ok': enabled ? ok : null,
      'ip': ok == true ? '203.0.113.7' : null,
      'changed': false,
      'error': error,
      'nextAttemptAt': enabled ? next.millisecondsSinceEpoch : null,
      'intervalMinutes': 5,
    },
  };

  late List<http.Request> requests;
  late http.Response Function() getResponse;
  late Map<String, dynamic> Function(Map<String, dynamic> body) patchResponse;

  Session buildSession() {
    final client = MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (path == '/api/admin/ddns' && request.method == 'GET') {
        return getResponse();
      }
      if (path == '/api/admin/ddns' && request.method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(patchResponse(body)),
          200,
          headers: jsonHeaders,
        );
      }
      if (path == '/api/admin/ddns/update') {
        return http.Response(jsonEncode(view()), 200, headers: jsonHeaders);
      }
      // 웹 앱 주소 카드 — 이 시험과 무관하니 예전 서버처럼 숨긴다.
      return http.Response('', 404, headers: {'content-type': 'text/html'});
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

  setUp(() {
    requests = [];
    getResponse = () =>
        http.Response(jsonEncode(view()), 200, headers: jsonHeaders);
    patchResponse = (_) => view();
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminDdnsTab(session: buildSession())),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextField, label);
  List<http.Request> patches() =>
      requests.where((r) => r.method == 'PATCH').toList();

  testWidgets('켜져 있고 갱신이 잘 되면 도메인 → IP, 마지막 성공·다음 갱신을 보여 준다', (tester) async {
    await pump(tester);
    expect(find.textContaining('정상'), findsOneWidget);
    expect(find.text('tangotalk.duckdns.org → 203.0.113.7'), findsOneWidget);
    expect(find.text('마지막 성공: 2026/10/13 09:30'), findsOneWidget);
    expect(find.text('다음 갱신: 2026/10/13 09:35 (5분마다)'), findsOneWidget);
    // 도메인은 전체 주소로 채우고, 토큰은 다시 보여주지 않는다.
    expect(
      tester.widget<TextField>(field('DuckDNS 도메인')).controller!.text,
      'tangotalk.duckdns.org',
    );
    expect(
      tester.widget<TextField>(field('새 토큰 (바꿀 때만)')).controller!.text,
      isEmpty,
    );
    expect(find.text('토큰: 설정됨'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('실패하면 이유를 보여 준다', (tester) async {
    getResponse = () => http.Response(
      jsonEncode(view(ok: false, error: 'DuckDNS가 갱신을 거절했습니다')),
      200,
      headers: jsonHeaders,
    );
    await pump(tester);
    expect(find.textContaining('실패'), findsWidgets);
    expect(find.text('실패 이유: DuckDNS가 갱신을 거절했습니다'), findsOneWidget);
  });

  testWidgets('처음 켤 때: 도메인·토큰·켜기를 보내고, 저장한 뒤 토큰 칸을 비운다', (tester) async {
    getResponse = () => http.Response(
      jsonEncode(view(enabled: false, domains: [], tokenConfigured: false)),
      200,
      headers: jsonHeaders,
    );
    await pump(tester);
    expect(find.textContaining('꺼짐'), findsOneWidget);
    expect(find.text('토큰: 설정 안 됨'), findsOneWidget);

    await tester.enterText(field('DuckDNS 도메인'), 'tangotalk');
    await tester.enterText(field('토큰'), 'a7c4d0ad-114e-40ef-ba1d-d217904a50f2');
    await tester.tap(find.text('자동 갱신 사용'));
    await tester.pump();
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    final body = jsonDecode(patches().single.body) as Map<String, dynamic>;
    expect(body, {
      'enabled': true,
      'domains': 'tangotalk',
      'token': 'a7c4d0ad-114e-40ef-ba1d-d217904a50f2',
    });
    expect(
      tester.widget<TextField>(field('새 토큰 (바꿀 때만)')).controller!.text,
      isEmpty,
    );
    expect(find.text('tangotalk.duckdns.org → 203.0.113.7'), findsOneWidget);
    expect(find.textContaining('갱신에 성공했습니다'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('토큰 칸을 비워 두고 저장하면 토큰은 보내지 않는다(저장된 토큰 그대로)', (tester) async {
    await pump(tester);
    await tester.enterText(
      field('DuckDNS 도메인'),
      'tangotalk, tangotalk-dev.duckdns.org',
    );
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    final body = jsonDecode(patches().single.body) as Map<String, dynamic>;
    expect(body.containsKey('token'), isFalse);
    expect(body['domains'], 'tangotalk, tangotalk-dev.duckdns.org');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('도메인이나 토큰 없이 켜려고 하면 보내지 않고 알린다', (tester) async {
    getResponse = () => http.Response(
      jsonEncode(view(enabled: false, domains: [], tokenConfigured: false)),
      200,
      headers: jsonHeaders,
    );
    await pump(tester);
    await tester.tap(find.text('자동 갱신 사용'));
    await tester.pump();
    await tester.tap(find.text('저장'));
    await tester.pump();
    expect(patches(), isEmpty);
    expect(find.text('켜려면 도메인과 토큰을 넣으세요.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('"지금 갱신"은 설정을 건드리지 않고 갱신만 부른다', (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('지금 갱신'));
    await tester.pumpAndSettle();
    expect(
      requests.where((r) => r.url.path == '/api/admin/ddns/update').length,
      1,
    );
    expect(patches(), isEmpty);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('예전 서버(404)면 서버를 업데이트하라고 안내한다', (tester) async {
    getResponse = () =>
        http.Response('', 404, headers: {'content-type': 'text/html'});
    await pump(tester);
    expect(find.textContaining('서버를 업데이트하세요'), findsOneWidget);
    expect(find.text('저장'), findsNothing);
  });
}
