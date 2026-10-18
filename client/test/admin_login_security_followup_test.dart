// 관리자 콘솔 "로그인 보안" 후속 — SAML 2.0 칸(바꾼 값만 저장·메타데이터로 채우기·IdP에 넣을 값), 디렉터리 그룹 규칙(더하기·지우기),
// 그룹 규칙·보안 키 로그인·로그아웃 연동 스위치. 서버는 가짜 HTTP.
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

/// 서버 설정 보기(GET /admin/login-security) — [patch]로 받은 값을 덮어 써서 PATCH 답으로도 쓴다.
Map<String, dynamic> _view({
  Map<String, dynamic> patch = const {},
  bool withSp = true,
}) => {
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
    'enabled': false,
    'url': '',
    'bindDn': '',
    'hasBindPassword': false,
    'baseDn': '',
    'userFilter': '(sAMAccountName={username})',
  },
  'saml': {
    'enabled': patch['samlEnabled'] ?? false,
    'label': patch['samlLabel'] ?? '',
    'buttonLabel': patch['samlLabel'] ?? '회사 계정(SAML)',
    'entryPoint': patch['samlEntryPoint'] ?? '',
    'idpIssuer': patch['samlIdpIssuer'] ?? '',
    'idpCert': patch['samlIdpCert'] ?? '',
    'logoutUrl': patch['samlLogoutUrl'] ?? '',
    'emailAttr': patch['samlEmailAttr'] ?? 'email',
    'nameAttr': patch['samlNameAttr'] ?? 'displayName',
    'groupsAttr': patch['samlGroupsAttr'] ?? 'groups',
    'sp': withSp
        ? {
            'entityId': 'https://chat.company.com/auth/sso/saml/metadata',
            'metadataUrl': 'https://chat.company.com/auth/sso/saml/metadata',
            'acsUrl': 'https://chat.company.com/auth/sso/saml/acs',
            'sloUrl': 'https://chat.company.com/auth/sso/saml/slo',
          }
        : null,
    'problem': 'IdP 로그인 주소(SSO URL)를 넣으세요.',
  },
  'passkeyLoginEnabled': patch['passkeyLoginEnabled'] ?? true,
  'passkeysAvailable': withSp,
  'groupSync': {
    'enabled': patch['groupSyncEnabled'] ?? false,
    'removeUnmatched': patch['groupSyncRemove'] ?? false,
  },
  'logout': {
    'idpLogout': patch['ssoIdpLogout'] ?? false,
    'frontChannelUrl': withSp
        ? 'https://chat.company.com/auth/sso/microsoft/logout'
        : null,
  },
};

Map<String, dynamic> _mapping(
  String id, {
  String source = 'ldap',
  String group = '영업팀',
  String? teamId = 't1',
  String? teamName = '영업',
  String? accountRole,
}) => {
  'id': id,
  'source': source,
  'group': group,
  'teamId': teamId,
  'teamName': teamName,
  'accountRole': accountRole,
  'createdAt': 0,
};

/// 탭을 띄운다 — 화면을 넉넉히 길게 해서 모든 칸이 한 번에 보이게.
Future<List<http.Request>> _open(
  WidgetTester tester, {
  _Routes extra = const {},
  bool withSp = true,
  List<Map<String, dynamic>> mappings = const [],
}) async {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{
    'GET /api/admin/login-security': (_) => _json(_view(withSp: withSp)),
    'PATCH /api/admin/login-security': (r) =>
        _json(_view(patch: _bodyOf(r), withSp: withSp)),
    'GET /api/admin/group-mappings': (_) => _json(mappings),
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
  tester.view.physicalSize = const Size(1000, 7000);
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

void main() {
  group('SAML 2.0', () {
    testWidgets('IdP에 넣을 값이 보이고, 바꾼 값만 PATCH 키로 저장한다', (tester) async {
      final requests = await _open(tester);
      expect(find.text('https://chat.company.com/auth/sso/saml/acs'), findsOne);
      expect(find.text('https://chat.company.com/auth/sso/saml/slo'), findsOne);
      // entityID와 메타데이터 주소가 같은 값이라 둘 다 보인다.
      expect(
        find.text('https://chat.company.com/auth/sso/saml/metadata'),
        findsNWidgets(2),
      );
      expect(find.byKey(const ValueKey('saml-problem')), findsOneWidget);
      // 저장 전에는 저장 단추가 막혀 있다.
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('saml-save')))
            .onPressed,
        isNull,
      );

      await tester.enterText(find.byKey(const ValueKey('saml-label')), 'Okta');
      await tester.enterText(
        find.byKey(const ValueKey('saml-entry-point')),
        ' https://company.okta.com/app/sso/saml ',
      );
      await tester.enterText(
        find.byKey(const ValueKey('saml-idp-issuer')),
        'http://www.okta.com/exk1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('saml-idp-cert')),
        '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----',
      );
      await tester.enterText(
        find.byKey(const ValueKey('saml-groups-attr')),
        'memberOf',
      );
      await tester.pump();
      // 바꾼 값이 있으면 켜기 스위치는 막힌다(먼저 저장).
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const ValueKey('saml-enabled')))
            .onChanged,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('saml-save')));
      await tester.pumpAndSettle();
      expect(_bodyOf(_patches(requests).last), {
        'samlLabel': 'Okta',
        'samlEntryPoint': 'https://company.okta.com/app/sso/saml',
        'samlIdpIssuer': 'http://www.okta.com/exk1',
        'samlIdpCert':
            '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----',
        'samlGroupsAttr': 'memberOf',
      });
      // 저장 뒤에는 서버 값과 같아 켤 수 있다.
      await tester.tap(find.byKey(const ValueKey('saml-enabled')));
      await tester.pumpAndSettle();
      expect(_bodyOf(_patches(requests).last), {'samlEnabled': true});
      await tester.pump(const Duration(seconds: 5)); // 토스트가 사라지도록.
    });

    testWidgets('메타데이터로 채우기 — 붙여 넣은 XML을 보내고 칸만 채운다(저장은 따로)', (tester) async {
      final requests = await _open(
        tester,
        extra: {
          'POST /api/admin/login-security/saml-metadata': (_) => _json({
            'idpIssuer': 'https://adfs.company.local/adfs/services/trust',
            'entryPoint': 'https://adfs.company.local/adfs/ls/',
            'logoutUrl': 'https://adfs.company.local/adfs/ls/?wa=signout',
            'idpCert':
                '-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----',
          }),
        },
      );
      await tester.tap(find.byKey(const ValueKey('saml-metadata-fill')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('saml-metadata-xml')),
        '<EntityDescriptor entityID="x"/>',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('saml-metadata-read')));
      await tester.pumpAndSettle();
      final post = requests.lastWhere((r) => r.method == 'POST');
      expect(_bodyOf(post), {'xml': '<EntityDescriptor entityID="x"/>'});
      String textOf(String key) =>
          tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;
      expect(textOf('saml-entry-point'), 'https://adfs.company.local/adfs/ls/');
      expect(
        textOf('saml-idp-issuer'),
        'https://adfs.company.local/adfs/services/trust',
      );
      expect(textOf('saml-logout-url'), contains('wa=signout'));
      expect(textOf('saml-idp-cert'), contains('AAAA'));
      expect(_patches(requests), isEmpty, reason: '채우기만 하고 저장하지 않는다');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('메타데이터를 못 읽으면 창 안에 까닭을 보인다', (tester) async {
      await _open(
        tester,
        extra: {
          'POST /api/admin/login-security/saml-metadata': (_) =>
              _json({'error': '메타데이터에 서명 인증서가 없습니다.'}, status: 400),
        },
      );
      await tester.tap(find.byKey(const ValueKey('saml-metadata-fill')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('saml-metadata-xml')),
        '<x/>',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('saml-metadata-read')));
      await tester.pumpAndSettle();
      expect(find.textContaining('서명 인증서가 없습니다'), findsOneWidget);
      expect(find.byKey(const ValueKey('saml-metadata-xml')), findsOneWidget);
    });

    testWidgets('웹 앱 주소가 없으면 IdP 값 대신 안내, 켜기·패스키는 막힘', (tester) async {
      await _open(tester, withSp: false);
      expect(find.textContaining('SAML 로그인을 켤 수 없습니다'), findsOneWidget);
      expect(find.byKey(const ValueKey('saml-sp-acs')), findsNothing);
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const ValueKey('saml-enabled')))
            .onChanged,
        isNull,
      );
      expect(find.byKey(const ValueKey('passkey-unavailable')), findsOneWidget);
      expect(find.byKey(const ValueKey('sso-front-channel-url')), findsNothing);
    });
  });

  group('디렉터리 그룹 규칙', () {
    testWidgets('목록을 보이고, 규칙을 더하면 {source, group, teamId, accountRole}을 보낸다', (
      tester,
    ) async {
      final requests = await _open(
        tester,
        mappings: [_mapping('m1', accountRole: 'member')],
        extra: {
          'GET /api/admin/teams': (_) => _json([
            {'id': 't1', 'name': '영업', 'memberCount': 3, 'createdAt': 0},
            {'id': 't2', 'name': '개발', 'memberCount': 5, 'createdAt': 0},
          ]),
          'POST /api/admin/group-mappings': (r) {
            final b = _bodyOf(r);
            return _json(
              _mapping(
                'm2',
                source: b['source'] as String,
                group: b['group'] as String,
                teamId: b['teamId'] as String?,
                teamName: '개발',
                accountRole: b['accountRole'] as String?,
              ),
              status: 201,
            );
          },
        },
      );
      expect(find.byKey(const ValueKey('group-mapping-m1')), findsOneWidget);
      expect(find.textContaining('팀: 영업'), findsOneWidget);
      expect(find.textContaining('등급: 정회원'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('group-mapping-add')));
      await tester.pumpAndSettle();
      // 그룹 값이 없으면 막는다.
      await tester.tap(find.byKey(const ValueKey('group-mapping-save')));
      await tester.pump();
      expect(find.text('그룹을 넣으세요.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('group-mapping-source')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Microsoft').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('그룹 클레임 추가'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('group-mapping-group')),
        '00000000-0000-0000-0000-000000000001',
      );
      // 팀·등급 둘 다 없으면 막는다.
      await tester.tap(find.byKey(const ValueKey('group-mapping-save')));
      await tester.pump();
      expect(find.textContaining('하나는 고르세요'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('group-mapping-team')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('개발').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('group-mapping-role')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('관리자').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('group-mapping-save')));
      await tester.pumpAndSettle();

      final post = requests.lastWhere(
        (r) => r.method == 'POST' && r.url.path == '/api/admin/group-mappings',
      );
      expect(_bodyOf(post), {
        'source': 'microsoft',
        'group': '00000000-0000-0000-0000-000000000001',
        'teamId': 't2',
        'accountRole': 'admin',
      });
      expect(find.byKey(const ValueKey('group-mapping-m2')), findsOneWidget);
      expect(find.textContaining('등급: 관리자'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('지우기 — 확인하면 DELETE, 취소하면 그대로', (tester) async {
      final requests = await _open(
        tester,
        mappings: [_mapping('m1')],
        extra: {
          'DELETE /api/admin/group-mappings/m1': (_) => _json({'ok': true}),
        },
      );
      await tester.tap(find.byKey(const ValueKey('group-mapping-delete-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(requests.where((r) => r.method == 'DELETE'), isEmpty);

      await tester.tap(find.byKey(const ValueKey('group-mapping-delete-m1')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('integration-delete-confirm')),
      );
      await tester.pumpAndSettle();
      final del = requests.singleWhere((r) => r.method == 'DELETE');
      expect(del.url.path, '/api/admin/group-mappings/m1');
      expect(find.byKey(const ValueKey('group-mapping-m1')), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('목록을 못 불러와도 탭의 다른 칸은 그대로 쓴다', (tester) async {
      await _open(
        tester,
        extra: {
          'GET /api/admin/group-mappings': (_) =>
              _json({'error': '서버 오류'}, status: 500),
        },
      );
      expect(find.textContaining('그룹 규칙을 불러오지 못했습니다'), findsOneWidget);
      expect(find.byKey(const ValueKey('saml-enabled')), findsOneWidget);
    });
  });

  group('스위치', () {
    testWidgets('그룹 규칙·패스키 로그인·로그아웃 연동은 바로 저장한다', (tester) async {
      final requests = await _open(tester);
      // 그룹 규칙이 꺼져 있으면 "빠지면 빼기"는 못 바꾼다.
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('group-sync-remove')),
            )
            .onChanged,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('group-sync-enabled')));
      await tester.pumpAndSettle();
      expect(_bodyOf(_patches(requests).last), {'groupSyncEnabled': true});
      await tester.tap(find.byKey(const ValueKey('group-sync-remove')));
      await tester.pumpAndSettle();
      expect(_bodyOf(_patches(requests).last), {'groupSyncRemove': true});

      await tester.tap(find.byKey(const ValueKey('passkey-login-enabled')));
      await tester.pumpAndSettle();
      expect(_bodyOf(_patches(requests).last), {'passkeyLoginEnabled': false});

      expect(find.byKey(const ValueKey('sso-front-channel-url')), findsOne);
      await tester.tap(find.byKey(const ValueKey('sso-idp-logout')));
      await tester.pumpAndSettle();
      expect(_bodyOf(_patches(requests).last), {'ssoIdpLogout': true});
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
