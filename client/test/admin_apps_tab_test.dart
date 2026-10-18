// 관리자 콘솔 "연동 앱" 탭 — 팀의 앱 목록(봇 토큰 앞부분·받을 일·OAuth·꺼짐 표시), 만들기(고른 받을 일만, 돌아갈 주소는 한 줄에 하나,
// 빈 주소는 안 보냄 → 봇 토큰·앱 비밀·서명 비밀을 이번에만), 메뉴의 새 봇 토큰(확인 → which: 'bot' → 그 토큰만 보여 줌)과 끄기.
// 서버는 가짜 HTTP(integrations_test.dart와 같은 방식).
import 'dart:convert';

import 'package:client/models/team.dart';
import 'package:client/screens/admin_apps_tab.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

typedef _Routes = Map<String, http.Response Function(http.Request request)>;

Map<String, dynamic> _bodyOf(http.Request r) =>
    jsonDecode(r.body) as Map<String, dynamic>;

Session _session(List<http.Request> requests, _Routes routes) {
  final session = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: MockClient((request) async {
      requests.add(request);
      final route = routes['${request.method} ${request.url.path}'];
      if (route != null) return route(request);
      return _json({'error': 'no route'}, status: 404);
    }),
  );
  session.userId = 'me';
  session.name = '나';
  session.accountRole = AccountRole.admin;
  return session;
}

Map<String, dynamic> _app(
  String id,
  String name, {
  String? url,
  List<String> events = const [],
  List<String> redirectUris = const [],
  bool enabled = true,
  int failureCount = 0,
}) => {
  'id': id,
  'kind': 'app',
  'teamId': 't1',
  'roomId': null,
  'name': name,
  'emoji': '🤖',
  'tokenPrefix': 'ttb_AbCd',
  'description': '배포를 도와줍니다',
  'url': url,
  'interactionUrl': null,
  'events': events,
  'enabled': enabled,
  'failureCount': failureCount,
  'clientId': 'ttc_${'c' * 24}',
  'redirectUris': redirectUris,
  'createdAt': 1000,
  'lastUsedAt': null,
  'useCount': 0,
};

_Routes _base(List<Map<String, dynamic>> Function() apps) => {
  'GET /api/admin/teams': (_) => _json([
    {'id': 't1', 'name': '개발팀', 'memberCount': 3, 'createdAt': 1000},
  ]),
  'GET /api/teams/t1/apps': (_) => _json(apps()),
};

Future<void> _pump(WidgetTester tester, Session session) async {
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: AdminAppsTab(session: session)),
    ),
  );
  await tester.pumpAndSettle();
}

String _secretOf(WidgetTester tester, String key) =>
    tester.widget<SelectableText>(find.byKey(ValueKey(key))).data!;

void main() {
  testWidgets('팀의 앱 목록 — 봇 토큰 앞부분·받을 일·OAuth·꺼짐 표시', (tester) async {
    final requests = <http.Request>[];
    final session = _session(
      requests,
      _base(
        () => [
          _app(
            'a1',
            '배포 도우미',
            url: 'https://bot.example/events',
            events: ['message.created', 'mention'],
            redirectUris: ['https://bot.example/cb'],
          ),
          _app('a2', '알림봇', enabled: false, failureCount: 5),
        ],
      ),
    );
    await _pump(tester, session);
    expect(find.byKey(const ValueKey('app-a1')), findsOneWidget);
    expect(find.text('배포 도우미'), findsOneWidget);
    expect(find.textContaining('ttb_AbCd…'), findsNWidgets(2));
    expect(find.textContaining('새 메시지·멘션'), findsOneWidget);
    expect(find.textContaining('OAuth 켜짐'), findsOneWidget);
    expect(find.textContaining('OAuth 꺼짐'), findsOneWidget);
    expect(find.text('꺼짐 · 연달아 5번 실패'), findsOneWidget);
  });

  testWidgets('만들기 — 고른 받을 일만, 돌아갈 주소는 줄마다, 빈 주소는 빼고 → 비밀 셋을 이번에만', (
    tester,
  ) async {
    final requests = <http.Request>[];
    var apps = <Map<String, dynamic>>[];
    final session = _session(requests, {
      ..._base(() => apps),
      'POST /api/teams/t1/apps': (r) {
        final b = _bodyOf(r);
        final row = _app(
          'a1',
          b['name'] as String,
          url: b['url'] as String?,
          events: (b['events'] as List).cast<String>(),
          redirectUris: (b['redirectUris'] as List).cast<String>(),
        );
        apps = [row];
        return _json({
          ...row,
          'botToken': 'ttb_${'b' * 40}',
          'clientSecret': 'tts_${'s' * 40}',
          'signingSecret': 'f' * 64,
        }, status: 201);
      },
    });
    await _pump(tester, session);
    expect(find.text('이 팀에는 연동 앱이 없습니다.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('app-create')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('app-name')), '배포 도우미');
    await tester.enterText(
      find.byKey(const ValueKey('app-url')),
      'https://bot.example/events',
    );
    for (final e in ['mention', 'message.created']) {
      final box = find.byKey(ValueKey('app-event-$e'));
      await tester.ensureVisible(box);
      await tester.tap(box);
      await tester.pumpAndSettle();
    }
    await tester.enterText(
      find.byKey(const ValueKey('app-redirect-uris')),
      'https://bot.example/cb\n\n  myapp://cb  \n',
    );
    await tester.tap(find.byKey(const ValueKey('app-confirm')));
    await tester.pumpAndSettle();

    expect(_bodyOf(requests.singleWhere((r) => r.method == 'POST')), {
      'name': '배포 도우미',
      'url': 'https://bot.example/events',
      'events': ['message.created', 'mention'],
      'redirectUris': ['https://bot.example/cb', 'myapp://cb'],
    }, reason: '아이콘·설명·단추 응답 주소는 비워서 보내지 않는다, 받을 일은 정해진 순서로');
    expect(_secretOf(tester, 'app-secret-bot'), 'ttb_${'b' * 40}');
    expect(_secretOf(tester, 'app-secret-client'), 'tts_${'s' * 40}');
    expect(_secretOf(tester, 'app-secret-signing'), 'f' * 64);
    expect(_secretOf(tester, 'app-client-id'), 'ttc_${'c' * 24}');
    expect(find.textContaining('https://test.local/api/v1/me'), findsOneWidget);
    expect(find.textContaining('"action_id":"approve"'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app-secrets-done')));
    await tester.pumpAndSettle();
    expect(find.text('배포 도우미'), findsOneWidget, reason: '목록을 새로 받았다');
    expect(find.textContaining('ttb_${'b' * 40}'), findsNothing);
  });

  testWidgets('메뉴 "새 봇 토큰" — 확인 뒤 which: bot, 새 토큰만 보여 준다', (tester) async {
    final requests = <http.Request>[];
    final session = _session(requests, {
      ..._base(() => [_app('a1', '배포 도우미')]),
      'POST /api/integrations/a1/regenerate': (_) =>
          _json({..._app('a1', '배포 도우미'), 'botToken': 'ttb_${'n' * 40}'}),
    });
    await _pump(tester, session);
    await tester.tap(find.byKey(const ValueKey('app-menu-a1')));
    await tester.pumpAndSettle();
    expect(find.text('보내 보기'), findsNothing, reason: '받을 주소가 없으면 보내 볼 곳도 없다');
    await tester.tap(find.text('새 봇 토큰'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('integration-delete-confirm')));
    await tester.pumpAndSettle();
    final post = requests.singleWhere((r) => r.method == 'POST');
    expect(post.url.path, '/api/integrations/a1/regenerate');
    expect(_bodyOf(post), {'which': 'bot'});
    expect(_secretOf(tester, 'app-secret-bot'), 'ttb_${'n' * 40}');
    expect(find.byKey(const ValueKey('app-secret-client')), findsNothing);
    expect(find.byKey(const ValueKey('app-secret-signing')), findsNothing);
    expect(find.byKey(const ValueKey('app-client-id')), findsNothing);
  });

  testWidgets('메뉴 "끄기" — enabled: false로 바꾸고 꺼짐 표시', (tester) async {
    final requests = <http.Request>[];
    var enabled = true;
    final session = _session(requests, {
      ..._base(() => [_app('a1', '배포 도우미', enabled: enabled)]),
      'PATCH /api/integrations/a1': (r) {
        enabled = _bodyOf(r)['enabled'] as bool;
        return _json(_app('a1', '배포 도우미', enabled: enabled));
      },
    });
    await _pump(tester, session);
    await tester.tap(find.byKey(const ValueKey('app-menu-a1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('끄기'));
    await tester.pumpAndSettle();
    final patch = requests.singleWhere((r) => r.method == 'PATCH');
    expect(_bodyOf(patch), {'enabled': false});
    expect(find.text('꺼짐'), findsOneWidget);
  });
}
