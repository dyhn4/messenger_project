// 내 프로필 → 보안 키·패스키 — 목록(아이콘·등록/마지막 사용), 이름 바꾸기(PATCH 본문), 지우기(확인 뒤 DELETE·403이면 서버 문구),
// 서버에 웹 주소가 없으면(available false) 설명만 보이고 추가 단추가 없음, 추가(이름 → 등록 시작 → 결과 묻기 → 등록됨 알림·다시 불러오기),
// 개인정보 설정 창에 "보안 키·패스키" 줄(게스트도). 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/team.dart';
import 'package:client/screens/my_profile_dialog.dart';
import 'package:client/screens/passkeys_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/passkey_flow.dart';
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

Map<String, dynamic> _key(
  String id,
  String name, {
  bool backedUp = false,
  List<String> transports = const ['usb'],
  DateTime? lastUsedAt,
}) => {
  'id': id,
  'name': name,
  'backedUp': backedUp,
  'transports': transports,
  'createdAt': DateTime(2026, 10, 1, 9, 30).millisecondsSinceEpoch,
  'lastUsedAt': lastUsedAt?.millisecondsSinceEpoch,
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
              onPressed: () => showPasskeysDialog(context, session),
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

/// 줄의 메뉴를 열어 [label] 항목을 누른다.
Future<void> _menu(WidgetTester tester, String id, String label) async {
  await tester.tap(find.byKey(ValueKey('passkey-menu-$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => PasskeysDialog.flowFactory = null);

  testWidgets('목록 — 종류별 아이콘, 등록·마지막 사용 시각(안 썼으면 "아직 쓰지 않음")', (tester) async {
    final session = _session([], {
      'GET /auth/passkeys': (_) => _json({
        'available': true,
        'passkeys': [
          _key('k1', 'YubiKey 5', lastUsedAt: DateTime(2026, 10, 15, 14, 5)),
          _key('k2', '아이폰', backedUp: true, transports: ['hybrid']),
          _key('k3', '회사 노트북', transports: ['internal']),
        ],
      }),
    });
    await _open(tester, session);
    expect(find.text('보안 키·패스키'), findsOneWidget);
    expect(find.textContaining('YubiKey 등'), findsOneWidget);
    expect(find.textContaining('가짜 사이트'), findsOneWidget);

    final k1 = find.byKey(const ValueKey('passkey-k1'));
    expect(
      find.descendant(of: k1, matching: find.text('YubiKey 5')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: k1,
        matching: find.text(
          '등록 2026/10/01 AM 9:30 · 마지막 사용 2026/10/15 PM 2:05',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: k1, matching: find.byIcon(Icons.key)),
      findsOneWidget,
    );
    final k2 = find.byKey(const ValueKey('passkey-k2'));
    expect(
      find.descendant(of: k2, matching: find.byIcon(Icons.cloud_sync)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: k2, matching: find.textContaining('아직 쓰지 않음')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('passkey-k3')),
        matching: find.byIcon(Icons.fingerprint),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('passkey-add')), findsOneWidget);
    expect(find.byKey(const ValueKey('passkey-unavailable')), findsNothing);
  });

  testWidgets('키가 없으면 빈 안내', (tester) async {
    final session = _session([], {
      'GET /auth/passkeys': (_) =>
          _json({'available': true, 'passkeys': <Object>[]}),
    });
    await _open(tester, session);
    expect(find.text('아직 등록한 보안 키가 없습니다.'), findsOneWidget);
  });

  testWidgets('이름 바꾸기 — PATCH 본문에 새 이름, 목록을 다시 불러온다', (tester) async {
    final requests = <http.Request>[];
    var name = 'YubiKey';
    final session = _session(requests, {
      'GET /auth/passkeys': (_) => _json({
        'available': true,
        'passkeys': [_key('k1', name)],
      }),
      'PATCH /auth/passkeys/k1': (r) {
        name = _bodyOf(r)['name'] as String;
        return _json(_key('k1', name));
      },
    });
    await _open(tester, session);
    await _menu(tester, 'k1', '이름 바꾸기');
    final field = find.byKey(const ValueKey('passkey-name-field'));
    expect(field, findsOneWidget);
    await tester.enterText(field, '  사무실 키  ');
    await tester.tap(find.byKey(const ValueKey('passkey-name-confirm')));
    await tester.pumpAndSettle();
    final patch = requests.singleWhere((r) => r.method == 'PATCH');
    expect(_bodyOf(patch), {'name': '사무실 키'});
    expect(find.text('사무실 키'), findsOneWidget);
  });

  testWidgets('지우기 — 확인 뒤 DELETE, 취소하면 보내지 않는다', (tester) async {
    final requests = <http.Request>[];
    var keys = [_key('k1', 'YubiKey')];
    final session = _session(requests, {
      'GET /auth/passkeys': (_) => _json({'available': true, 'passkeys': keys}),
      'DELETE /auth/passkeys/k1': (_) {
        keys = [];
        return _json({'ok': true});
      },
    });
    await _open(tester, session);
    await _menu(tester, 'k1', '지우기');
    expect(find.textContaining('"YubiKey" 키를 지울까요?'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.method == 'DELETE'), isEmpty);

    await _menu(tester, 'k1', '지우기');
    await tester.tap(find.byKey(const ValueKey('integration-delete-confirm')));
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.method == 'DELETE'), hasLength(1));
    expect(find.text('아직 등록한 보안 키가 없습니다.'), findsOneWidget);
  });

  testWidgets('지우기 403(마지막 2단계 수단) — 서버 문구를 알리고 목록은 그대로', (tester) async {
    const reason = '관리자가 2단계 인증을 꼭 쓰게 정해서 마지막 보안 키는 지울 수 없습니다.';
    final session = _session([], {
      'GET /auth/passkeys': (_) => _json({
        'available': true,
        'passkeys': [_key('k1', 'YubiKey')],
      }),
      'DELETE /auth/passkeys/k1': (_) => _json({'error': reason}, status: 403),
    });
    await _open(tester, session);
    await _menu(tester, 'k1', '지우기');
    await tester.tap(find.byKey(const ValueKey('integration-delete-confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining(reason), findsOneWidget);
    expect(find.byKey(const ValueKey('passkey-k1')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('서버에 웹 주소가 없으면(available false) 설명만, 추가 단추 없음', (tester) async {
    final session = _session([], {
      'GET /auth/passkeys': (_) =>
          _json({'available': false, 'passkeys': <Object>[]}),
    });
    await _open(tester, session);
    expect(find.byKey(const ValueKey('passkey-unavailable')), findsOneWidget);
    expect(find.textContaining('웹 앱 주소가 설정되어 있지 않아'), findsOneWidget);
    expect(find.byKey(const ValueKey('passkey-add')), findsNothing);
    expect(find.text('아직 등록한 보안 키가 없습니다.'), findsNothing);
  });

  testWidgets('추가 — 이름 → 등록 시작(challenge·name) → 브라우저 → 등록됨 알림, 목록 다시 불러오기', (
    tester,
  ) async {
    final requests = <http.Request>[];
    var keys = <Map<String, dynamic>>[];
    var polls = 0;
    final session = _session(requests, {
      'GET /auth/passkeys': (_) => _json({'available': true, 'passkeys': keys}),
      'POST /auth/passkeys/register/start': (_) => _json({
        'state': 'S1',
        'url': 'https://web.test.local/auth/passkeys/ceremony?state=S1',
      }),
      'POST /auth/passkeys/poll': (_) {
        if (++polls < 2) return _json({'status': 'pending'});
        keys = [_key('k9', 'YubiKey 5')];
        return _json({'status': 'registered', 'passkey': keys.first});
      },
    });
    Uri? opened;
    PasskeysDialog.flowFactory = (api) => PasskeyFlow(
      api: api,
      openUrl: (u) async {
        opened = u;
        return true;
      },
      pollInterval: const Duration(milliseconds: 10),
    );
    await _open(tester, session);
    expect(find.text('아직 등록한 보안 키가 없습니다.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('passkey-add')));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('passkey-new-name'));
    expect(field, findsOneWidget);
    expect(find.text('예: YubiKey 5'), findsOneWidget);
    await tester.enterText(field, 'YubiKey 5');
    await tester.tap(find.byKey(const ValueKey('passkey-name-confirm')));
    // 기다리는 창은 돌아가는 표시가 있어 pumpAndSettle 대신 조금씩.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const ValueKey('passkey-waiting')), findsOneWidget);
    expect(find.textContaining('브라우저에서 보안 키를 등록하세요'), findsOneWidget);
    for (var i = 0; i < 10 && polls < 2; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();

    final start = requests.singleWhere(
      (r) => r.url.path == '/auth/passkeys/register/start',
    );
    expect(_bodyOf(start)['name'], 'YubiKey 5');
    expect(_bodyOf(start)['challenge'], isA<String>());
    expect((_bodyOf(start)['challenge'] as String).isNotEmpty, isTrue);
    expect(opened?.host, 'web.test.local');
    expect(polls, 2);
    expect(find.byKey(const ValueKey('passkey-waiting')), findsNothing);
    expect(find.text('보안 키를 등록했습니다'), findsOneWidget);
    expect(find.byKey(const ValueKey('passkey-k9')), findsOneWidget);
    expect(
      requests.where(
        (r) => r.method == 'GET' && r.url.path == '/auth/passkeys',
      ),
      hasLength(2),
    );
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('추가 중 취소하면 기다리기를 멈추고 알리지 않는다', (tester) async {
    var polls = 0;
    final session = _session([], {
      'GET /auth/passkeys': (_) =>
          _json({'available': true, 'passkeys': <Object>[]}),
      'POST /auth/passkeys/register/start': (_) =>
          _json({'state': 'S1', 'url': 'https://web.test.local/x'}),
      'POST /auth/passkeys/poll': (_) {
        polls++;
        return _json({'status': 'pending'});
      },
    });
    PasskeysDialog.flowFactory = (api) => PasskeyFlow(
      api: api,
      openUrl: (_) async => true,
      pollInterval: const Duration(milliseconds: 10),
    );
    await _open(tester, session);
    await tester.tap(find.byKey(const ValueKey('passkey-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('passkey-name-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.byKey(const ValueKey('passkey-cancel')));
    await tester.pumpAndSettle();
    final after = polls;
    await tester.pump(const Duration(milliseconds: 100));
    expect(polls, after, reason: '취소 뒤에는 더 묻지 않는다');
    expect(find.byKey(const ValueKey('passkey-waiting')), findsNothing);
    expect(find.text('보안 키를 등록했습니다'), findsNothing);
    expect(find.byType(PasskeysDialog), findsOneWidget);
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

    testWidgets('"보안 키·패스키" 줄 — 누르면 보안 키 창', (tester) async {
      final session = _session([], {
        'GET /auth/passkeys': (_) =>
            _json({'available': true, 'passkeys': <Object>[]}),
      });
      await pumpInfo(tester, session);
      final row = find.byKey(const ValueKey('profile-passkeys'));
      expect(row, findsOneWidget);
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byType(PasskeysDialog), findsOneWidget);
      expect(find.text('아직 등록한 보안 키가 없습니다.'), findsOneWidget);
    });

    testWidgets('게스트에게도 "보안 키·패스키" 줄이 있다', (tester) async {
      final session = _session([], {}, role: AccountRole.guest);
      await pumpInfo(tester, session);
      expect(find.byKey(const ValueKey('profile-passkeys')), findsOneWidget);
    });
  });
}
