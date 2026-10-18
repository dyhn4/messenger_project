// 관리자 콘솔 "로그인 보안" — 사내 디렉터리(LDAP) 칸 아래 "조직도 맞추기"(admin_ldap_org_sync.dart). 칸이 서버 값을 보이는지, 바꾼
// 칸만 PATCH 키로 저장하는지, "지금 디렉터리와 맞추기"가 확인 뒤 POST하고 숫자·서버 까닭을 보이는지, 팀 단위 조직도면 막고 안내하는지.
// 서버는 가짜 HTTP(admin_login_security_followup_test.dart와 같은 틀).
import 'dart:convert';

import 'package:client/screens/admin_login_security_tab.dart';
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

/// 서버 설정 보기(GET /admin/login-security) — [ldap]은 디렉터리 칸의 조직도 맞추기 값, [patch]로 받은 값을 덮어 써서 PATCH 답으로도 쓴다.
Map<String, dynamic> _view({
  Map<String, dynamic> patch = const {},
  Map<String, dynamic> ldap = const {},
}) {
  final orgBaseDn = patch.containsKey('ldapOrgBaseDn')
      ? patch['ldapOrgBaseDn']
      : ldap['orgBaseDn'];
  return {
    'otpPolicy': 'optional',
    'sso': {
      'redirectUri': 'https://chat.company.com/auth/sso/callback',
      'autoCreate': false,
      'defaultRole': 'member',
      'sessionDays': 7,
      'google': {'enabled': false, 'clientId': '', 'hasClientSecret': false},
      'microsoft': {
        'enabled': false,
        'tenantId': '',
        'clientId': '',
        'hasClientSecret': false,
      },
    },
    'ldap': {
      'enabled': ldap['enabled'] ?? true,
      'url': 'ldaps://dc01.company.local:636',
      'bindDn': 'CN=tangotalk,OU=Service,DC=company,DC=local',
      'hasBindPassword': true,
      'baseDn': 'DC=company,DC=local',
      'userFilter': '(sAMAccountName={username})',
      'testedAt': 1000,
      'orgSource': patch['ldapOrgSource'] ?? ldap['orgSource'] ?? 'attribute',
      // 서버는 빈 시작 위치를 null로 저장하고 보기에서 ''로 준다.
      'orgBaseDn': (orgBaseDn as String?)?.isEmpty ?? true ? '' : orgBaseDn,
      'managerSync': patch['ldapManagerSync'] ?? ldap['managerSync'] ?? false,
      'managerAttr':
          patch['ldapManagerAttr'] ?? ldap['managerAttr'] ?? 'manager',
      'orgSyncAvailable': ldap['orgSyncAvailable'] ?? true,
    },
    'saml': {'enabled': false},
    'passkeyLoginEnabled': true,
    'passkeysAvailable': true,
    'groupSync': {'enabled': false, 'removeUnmatched': false},
    'logout': {'idpLogout': false, 'frontChannelUrl': null},
  };
}

/// 탭을 띄운다 — 화면을 넉넉히 길게 해서 모든 칸이 한 번에 보이게.
Future<List<http.Request>> _open(
  WidgetTester tester, {
  Map<String, dynamic> ldap = const {},
  _Routes extra = const {},
}) async {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{
    'GET /api/admin/login-security': (_) => _json(_view(ldap: ldap)),
    'PATCH /api/admin/login-security': (r) =>
        _json(_view(patch: _bodyOf(r), ldap: ldap)),
    'GET /api/admin/group-mappings': (_) => _json(const []),
    'GET /server-info': (_) => _json({'mailEnabled': false}),
    ...extra,
  };
  final session = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    httpClient: MockClient((request) async {
      requests.add(request);
      final route = routes['${request.method} ${request.url.path}'];
      if (route != null) return route(request);
      return _json({'error': 'no route'}, status: 404);
    }),
  );
  tester.view.physicalSize = const Size(1000, 8000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: AdminLoginSecurityTab(session: session)),
    ),
  );
  await tester.pumpAndSettle();
  return requests;
}

Iterable<http.Request> _patches(List<http.Request> requests) =>
    requests.where((r) => r.method == 'PATCH');

Iterable<http.Request> _syncPosts(List<http.Request> requests) =>
    requests.where(
      (r) =>
          r.method == 'POST' &&
          r.url.path == '/api/admin/login-security/ldap-org-sync',
    );

const _syncResult = {
  'scanned': 120,
  'linked': 87,
  'moved': 12,
  'managersSet': 30,
  'departmentsCreated': 4,
};

TextField _textField(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key)));

String _textOf(WidgetTester tester, String key) =>
    _textField(tester, key).controller!.text;

bool _enabled(WidgetTester tester, String key) {
  final w = tester.widget(find.byKey(ValueKey(key)));
  return switch (w) {
    TextField() => w.enabled ?? true,
    DropdownButton<String>() => w.onChanged != null,
    SwitchListTile() => w.onChanged != null,
    ButtonStyleButton() => w.onPressed != null,
    _ => throw StateError('모르는 위젯: $w'),
  };
}

void main() {
  testWidgets('서버 값을 칸에 보이고, OU 방식일 때만 시작 위치·상위자를 켤 때만 속성 칸을 쓴다', (
    tester,
  ) async {
    await _open(
      tester,
      ldap: {
        'orgSource': 'ou',
        'orgBaseDn': 'OU=Users,DC=company,DC=local',
        'managerSync': true,
        'managerAttr': 'directReportsOf',
      },
    );
    final dropdown = tester.widget<DropdownButton<String>>(
      find.byKey(const ValueKey('ldap-org-source')),
    );
    expect(dropdown.value, 'ou');
    expect(find.text('OU 경로를 부서 트리로'), findsOneWidget);
    expect(_textOf(tester, 'ldap-org-base-dn'), 'OU=Users,DC=company,DC=local');
    expect(_enabled(tester, 'ldap-org-base-dn'), isTrue);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('ldap-manager-sync')),
          )
          .value,
      isTrue,
    );
    expect(_textOf(tester, 'ldap-manager-attr'), 'directReportsOf');
    expect(_enabled(tester, 'ldap-manager-attr'), isTrue);
    // OU 방식 설명에 보기 DN이 들어간다.
    expect(find.textContaining('OU=1팀,OU=영업본부'), findsOneWidget);
    // 바꾼 값이 없으면 저장은 막히고, 맞출 것이 있으니 "지금 맞추기"는 열린다.
    expect(_enabled(tester, 'ldap-org-save'), isFalse);
    expect(_enabled(tester, 'ldap-org-sync-now'), isTrue);
    expect(find.byKey(const ValueKey('ldap-org-unavailable')), findsNothing);
  });

  testWidgets('예전 방식(부서 속성)·상위자 꺼짐이면 시작 위치·속성 칸이 막히고 맞출 것이 없다', (tester) async {
    await _open(tester);
    expect(
      tester
          .widget<DropdownButton<String>>(
            find.byKey(const ValueKey('ldap-org-source')),
          )
          .value,
      'attribute',
    );
    expect(_enabled(tester, 'ldap-org-base-dn'), isFalse);
    expect(_textOf(tester, 'ldap-manager-attr'), 'manager');
    expect(_enabled(tester, 'ldap-manager-attr'), isFalse);
    expect(_enabled(tester, 'ldap-org-sync-now'), isFalse);
    expect(find.textContaining('맞출 것이 있습니다'), findsOneWidget);
  });

  testWidgets('OU 방식·시작 위치·상위자 맞추기로 바꿔 저장하면 바꾼 키만 보낸다', (tester) async {
    final requests = await _open(tester);
    await tester.tap(find.byKey(const ValueKey('ldap-org-source')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OU 경로를 부서 트리로').last);
    await tester.pumpAndSettle();
    expect(_enabled(tester, 'ldap-org-base-dn'), isTrue);
    await tester.enterText(
      find.byKey(const ValueKey('ldap-org-base-dn')),
      ' OU=Users,DC=company,DC=local ',
    );
    await tester.tap(find.byKey(const ValueKey('ldap-manager-sync')));
    await tester.pump();
    // 저장 전에는 "지금 맞추기"가 막힌다(바꾼 값을 먼저 저장).
    expect(_enabled(tester, 'ldap-org-sync-now'), isFalse);
    expect(find.text('바꾼 값을 먼저 저장하세요.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ldap-org-save')));
    await tester.pumpAndSettle();
    expect(_bodyOf(_patches(requests).last), {
      'ldapOrgSource': 'ou',
      'ldapOrgBaseDn': 'OU=Users,DC=company,DC=local',
      'ldapManagerSync': true,
    });
    // 저장 뒤에는 서버 값과 같아 저장은 막히고, 맞출 것이 생겨 "지금 맞추기"가 열린다.
    expect(_enabled(tester, 'ldap-org-save'), isFalse);
    expect(_enabled(tester, 'ldap-org-sync-now'), isTrue);
    await tester.pump(const Duration(seconds: 5)); // 토스트가 사라지도록.
  });

  testWidgets('상위자 속성은 영문·숫자만 — 틀리면 저장을 막고, 고치면 그 키만 보낸다', (tester) async {
    final requests = await _open(tester, ldap: {'managerSync': true});
    await tester.enterText(
      find.byKey(const ValueKey('ldap-manager-attr')),
      '상위자',
    );
    await tester.pump();
    expect(find.textContaining('속성 이름은 영문·숫자'), findsOneWidget);
    expect(_enabled(tester, 'ldap-org-save'), isFalse);

    await tester.enterText(
      find.byKey(const ValueKey('ldap-manager-attr')),
      'secretary',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ldap-org-save')));
    await tester.pumpAndSettle();
    expect(_bodyOf(_patches(requests).last), {'ldapManagerAttr': 'secretary'});
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('시작 위치를 비워 저장하면 빈 글을 보낸다(서버가 "모든 OU"로)', (tester) async {
    final requests = await _open(
      tester,
      ldap: {'orgSource': 'ou', 'orgBaseDn': 'OU=Users,DC=company,DC=local'},
    );
    await tester.enterText(find.byKey(const ValueKey('ldap-org-base-dn')), '');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ldap-org-save')));
    await tester.pumpAndSettle();
    expect(_bodyOf(_patches(requests).last), {'ldapOrgBaseDn': ''});
    expect(_textOf(tester, 'ldap-org-base-dn'), '');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('지금 맞추기 — 취소하면 그대로, 확인하면 POST하고 숫자를 보인다', (tester) async {
    final requests = await _open(
      tester,
      ldap: {'orgSource': 'ou'},
      extra: {
        'POST /api/admin/login-security/ldap-org-sync': (_) =>
            _json(_syncResult),
      },
    );
    await tester.tap(find.byKey(const ValueKey('ldap-org-sync-now')));
    await tester.pumpAndSettle();
    expect(find.text('지금 디렉터리와 맞출까요?'), findsOneWidget);
    expect(find.textContaining('사내 디렉터리의 모든 사람을 읽어'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(_syncPosts(requests), isEmpty);

    await tester.tap(find.byKey(const ValueKey('ldap-org-sync-now')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ldap-org-sync-confirm')));
    await tester.pumpAndSettle();
    expect(_syncPosts(requests), hasLength(1));
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('ldap-org-sync-result')))
          .data,
      '디렉터리 120명 중 계정 87명 — 부서 옮김 12명, 상위자 30명, 새 부서 4개',
    );
    // 맞추기는 설정을 바꾸지 않는다.
    expect(_patches(requests), isEmpty);
  });

  testWidgets('맞추기가 실패하면 서버가 준 까닭을 보인다', (tester) async {
    await _open(
      tester,
      ldap: {'managerSync': true},
      extra: {
        'POST /api/admin/login-security/ldap-org-sync': (_) =>
            _json({'error': '사내 디렉터리에 연결하지 못했습니다.'}, status: 400),
      },
    );
    await tester.tap(find.byKey(const ValueKey('ldap-org-sync-now')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ldap-org-sync-confirm')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('ldap-org-sync-result')))
          .data,
      contains('사내 디렉터리에 연결하지 못했습니다.'),
    );
    // 다시 누를 수 있다.
    expect(_enabled(tester, 'ldap-org-sync-now'), isTrue);
  });

  testWidgets('디렉터리 로그인이 꺼져 있으면 지금 맞추기를 막는다', (tester) async {
    await _open(tester, ldap: {'enabled': false, 'orgSource': 'ou'});
    expect(_enabled(tester, 'ldap-org-sync-now'), isFalse);
    expect(find.text('디렉터리 로그인을 켜야 맞출 수 있습니다.'), findsOneWidget);
    // 설정 칸은 미리 바꿔 둘 수 있다.
    expect(_enabled(tester, 'ldap-org-source'), isTrue);
  });

  testWidgets('팀 단위 조직도면 안내를 보이고 칸·단추를 모두 막는다', (tester) async {
    await _open(
      tester,
      ldap: {'orgSyncAvailable': false, 'orgSource': 'ou', 'managerSync': true},
    );
    expect(find.byKey(const ValueKey('ldap-org-unavailable')), findsOneWidget);
    expect(find.textContaining('계정 단위'), findsOneWidget);
    for (final key in [
      'ldap-org-source',
      'ldap-org-base-dn',
      'ldap-manager-sync',
      'ldap-manager-attr',
      'ldap-org-save',
      'ldap-org-sync-now',
    ]) {
      expect(_enabled(tester, key), isFalse, reason: key);
    }
  });
}
