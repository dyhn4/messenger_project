// 내 프로필 → 연결된 앱 — 승인한 OAuth 앱 목록·연결 끊기(확인 뒤 DELETE), "코드로 승인"(코드 넣기 → 요청 찾기 → 앱·권한 확인 →
// 승인·거절 보내기), 틀린 코드면 서버 문구 알림, 개인정보 설정 창에 "연결된 앱" 줄(게스트는 없음). 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/team.dart';
import 'package:client/screens/connected_apps_dialog.dart';
import 'package:client/screens/my_profile_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

typedef _Routes = Map<String, http.Response Function(http.Request request)>;

Session _session(
  List<http.Request> requests,
  _Routes routes, {
  AccountRole role = AccountRole.member,
}) {
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
      // 모르는 GET(개인정보 설정 창이 여는 다른 목록)은 빈 목록.
      if (request.method == 'GET') return _json(<Object>[]);
      return _json({'error': 'no route'}, status: 404);
    }),
  );
  session.userId = 'me';
  session.name = '나';
  session.accountRole = role;
  return session;
}

Map<String, dynamic> _bodyOf(http.Request r) =>
    jsonDecode(r.body) as Map<String, dynamic>;

Map<String, dynamic> _grant(String id, String name, {bool write = false}) => {
  'id': id,
  'app': {'id': 'a-$id', 'name': name, 'emoji': '📊', 'description': null},
  'teamName': '개발팀',
  'scopes': write ? ['read', 'write'] : ['read'],
  'createdAt': DateTime(2026, 10, 1).millisecondsSinceEpoch,
  'lastUsedAt': null,
};

Map<String, dynamic> _request() => {
  'id': 'req1',
  'app': {
    'id': 'a1',
    'name': '주간 보고 도우미',
    'emoji': '📝',
    'description': '매주 할 일을 모아 보고서를 만듭니다',
  },
  'teamName': '개발팀',
  'scopes': ['read', 'write'],
  'redirectHost': 'report.example.com',
  'expiresAt': DateTime.now()
      .add(const Duration(minutes: 10))
      .millisecondsSinceEpoch,
};

Future<void> _open(WidgetTester tester, Session session) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showConnectedAppsDialog(context, session),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
}

/// "코드로 승인" → 코드 넣기 → 확인.
Future<void> _enterCode(WidgetTester tester, String code) async {
  await tester.tap(find.byKey(const ValueKey('connected-app-approve')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('oauth-code-field')), code);
  await tester.tap(find.byKey(const ValueKey('oauth-code-confirm')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('연결된 앱 목록 → 연결 끊기는 확인 뒤 DELETE, 목록을 다시 불러온다', (tester) async {
    final requests = <http.Request>[];
    var grants = [_grant('g1', '대시보드', write: true)];
    final session = _session(requests, {
      'GET /api/users/me/connected-apps': (_) => _json(grants),
      'DELETE /api/users/me/connected-apps/g1': (_) {
        grants = [];
        return _json({'ok': true});
      },
    });
    await _open(tester, session);
    expect(find.text('대시보드'), findsOneWidget);
    expect(find.textContaining('개발팀 · 읽기·쓰기 · 승인 '), findsOneWidget);

    // 취소하면 아무것도 보내지 않는다.
    await tester.tap(find.byKey(const ValueKey('connected-app-remove-g1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('대시보드 연결을 끊을까요?'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.method == 'DELETE'), isEmpty);

    await tester.tap(find.byKey(const ValueKey('connected-app-remove-g1')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('connected-app-remove-confirm')),
    );
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.method == 'DELETE'), hasLength(1));
    expect(find.text('연결된 앱이 없습니다.'), findsOneWidget);
  });

  testWidgets('코드로 승인 — 코드로 요청을 찾아 앱·쓰기 권한을 보여 주고, 승인하면 approve로 보낸다', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final session = _session(requests, {
      'GET /api/users/me/connected-apps': (_) => _json(<Object>[]),
      'POST /api/oauth/requests/lookup': (_) => _json(_request()),
      'POST /api/oauth/requests/req1/approve': (_) => _json({'ok': true}),
    });
    await _open(tester, session);
    expect(find.text('연결된 앱이 없습니다.'), findsOneWidget);

    // 소문자·앞뒤 공백으로 쳐도 대문자 코드로 찾는다.
    await _enterCode(tester, ' bcdf-2345 ');
    final lookup = requests.singleWhere(
      (r) => r.url.path == '/api/oauth/requests/lookup',
    );
    expect(_bodyOf(lookup), {'code': 'BCDF-2345'});

    expect(find.text('주간 보고 도우미'), findsOneWidget);
    expect(find.text('매주 할 일을 모아 보고서를 만듭니다'), findsOneWidget);
    expect(find.text('주간 보고 도우미이(가) 내 이름으로 다음을 하려고 합니다'), findsOneWidget);
    expect(find.text('쓰기 — 내 이름으로 메시지·댓글·할 일·일정 만들기·고치기'), findsOneWidget);
    expect(find.text('읽기 — 내 팀·대화방·메시지·할 일·일정 보기'), findsOneWidget);
    expect(find.text('승인하면 report.example.com(으)로 돌아갑니다.'), findsOneWidget);
    expect(find.textContaining('남이 알려 준 코드는 승인하지 마세요'), findsOneWidget);

    final listLoads = requests.where((r) => r.method == 'GET').length;
    await tester.tap(find.byKey(const ValueKey('oauth-approve')));
    await tester.pumpAndSettle();
    final answer = requests.singleWhere(
      (r) => r.url.path == '/api/oauth/requests/req1/approve',
    );
    expect(_bodyOf(answer), {'code': 'BCDF-2345'});
    expect(find.text('승인했습니다. 브라우저로 돌아가세요.'), findsOneWidget);
    expect(find.byKey(const ValueKey('connected-app-pending')), findsOneWidget);
    // 승인 뒤 목록을 다시 불러온다.
    expect(requests.where((r) => r.method == 'GET').length, listLoads + 1);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('코드로 승인 — 거절하면 deny로 보낸다', (tester) async {
    final requests = <http.Request>[];
    final session = _session(requests, {
      'GET /api/users/me/connected-apps': (_) => _json(<Object>[]),
      'POST /api/oauth/requests/lookup': (_) => _json(_request()),
      'POST /api/oauth/requests/req1/deny': (_) => _json({'ok': true}),
    });
    await _open(tester, session);
    await _enterCode(tester, 'BCDF-2345');
    await tester.tap(find.byKey(const ValueKey('oauth-deny')));
    await tester.pumpAndSettle();
    final answer = requests.singleWhere(
      (r) => r.url.path == '/api/oauth/requests/req1/deny',
    );
    expect(_bodyOf(answer), {'code': 'BCDF-2345'});
    expect(requests.where((r) => r.url.path.endsWith('/approve')), isEmpty);
    expect(find.text('거절했습니다.'), findsOneWidget);
    expect(find.byKey(const ValueKey('connected-app-pending')), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('틀린·만료된 코드면 서버 문구를 알리고 확인 창을 띄우지 않는다', (tester) async {
    final requests = <http.Request>[];
    final session = _session(requests, {
      'GET /api/users/me/connected-apps': (_) => _json(<Object>[]),
      'POST /api/oauth/requests/lookup': (_) =>
          _json({'error': '코드가 맞지 않거나 만료되었습니다.'}, status: 404),
    });
    await _open(tester, session);
    await _enterCode(tester, 'ZZZZ-9999');
    expect(
      find.textContaining('승인 요청을 찾지 못했습니다: 코드가 맞지 않거나 만료되었습니다.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('oauth-approve')), findsNothing);
    expect(
      requests.where((r) => r.url.path.startsWith('/api/oauth/requests/req')),
      isEmpty,
    );
    await tester.pump(const Duration(seconds: 3));
  });

  group('개인정보 설정 창', () {
    Future<void> pumpInfo(WidgetTester tester, Session session) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PersonalInfoDialog(session: session, verifiedPassword: 'pw'),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('정회원이면 API 토큰 아래 "연결된 앱" 줄 — 누르면 연결된 앱 창', (tester) async {
      final session = _session([], {
        'GET /api/users/me/connected-apps': (_) => _json(<Object>[]),
      });
      await pumpInfo(tester, session);
      final row = find.byKey(const ValueKey('profile-connected-apps'));
      expect(row, findsOneWidget);
      expect(
        tester.getTopLeft(row).dy,
        greaterThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('profile-api-tokens')))
              .dy,
        ),
      );
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byType(ConnectedAppsDialog), findsOneWidget);
      expect(find.text('연결된 앱이 없습니다.'), findsOneWidget);
    });

    testWidgets('게스트에게는 "연결된 앱" 줄이 없다', (tester) async {
      final session = _session([], {}, role: AccountRole.guest);
      await pumpInfo(tester, session);
      expect(
        find.byKey(const ValueKey('profile-connected-apps')),
        findsNothing,
      );
    });
  });
}
