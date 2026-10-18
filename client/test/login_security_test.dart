// 로그인 보안(앱) — 2단계 인증 확인 표 읽기, 회사 계정 로그인 흐름(SsoFlow — PKCE 검증값, 기다리기, 같은 이메일 계정 잇기),
// 로그인 화면의 2단계 인증 단계·회사 계정 단추·디렉터리 안내, 관리자 콘솔 "로그인 보안" 탭. 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/admin.dart';
import 'package:client/models/login_security.dart';
import 'package:client/screens/admin_login_security_tab.dart';
import 'package:client/screens/login_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/services/sso_flow.dart';
import 'package:client/widgets/otp_dialogs.dart';
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

ApiClient _api(List<http.Request> requests, _Routes routes, {String? token}) =>
    ApiClient(
      baseUrl: 'https://test.local',
      token: token,
      httpClient: MockClient((request) async {
        requests.add(request);
        final route = routes['${request.method} ${request.url.path}'];
        if (route != null) return route(request);
        return _json({'error': 'no route'}, status: 404);
      }),
    );

Session _session(List<http.Request> requests, _Routes routes) {
  final session = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  session.api = _api(requests, routes);
  return session;
}

Map<String, dynamic> _bodyOf(http.Request r) =>
    jsonDecode(r.body) as Map<String, dynamic>;

Map<String, dynamic> _securityView({
  String otpPolicy = 'optional',
  bool ldapEnabled = false,
  int? ldapTestedAt,
}) => {
  'otpPolicy': otpPolicy,
  'sso': {
    'redirectUri': 'https://chat.company.com/auth/sso/callback',
    'autoCreate': false,
    'defaultRole': 'member',
    'sessionDays': 7,
    'google': {
      'enabled': false,
      'clientId': 'gid',
      'hasClientSecret': true,
      'domains': 'company.com',
      'problem': null,
    },
    'microsoft': {
      'enabled': false,
      'tenantId': '',
      'clientId': '',
      'hasClientSecret': false,
      'problem': '디렉터리(테넌트) ID(GUID)를 넣으세요.',
    },
  },
  'ldap': {
    'enabled': ldapEnabled,
    'url': 'ldaps://dc01.company.local',
    'bindDn': 'CN=svc',
    'hasBindPassword': true,
    'baseDn': 'DC=company,DC=local',
    'userFilter': '(sAMAccountName={username})',
    'nameAttr': 'displayName',
    'emailAttr': 'mail',
    'departmentAttr': 'department',
    'titleAttr': 'title',
    'tlsVerify': true,
    'autoCreate': true,
    'defaultRole': 'member',
    'testedAt': ldapTestedAt,
    'problem': null,
  },
};

void main() {
  group('모델', () {
    test('로그인 방법 — 아는 회사 계정만, 없거나 모양이 틀리면 아이디 로그인만', () {
      final m = LoginMethods.fromJson({
        'sso': ['google', 'facebook', 'microsoft'],
        'ldap': true,
        'otpPolicy': 'all',
      });
      expect(m.sso, ['google', 'microsoft']);
      expect(m.ldap, isTrue);
      expect(LoginMethods.fromJson(null), LoginMethods.none);
      expect(ssoProviderLabel('microsoft'), 'Microsoft');
    });

    test('로그인 응답의 2단계 인증 확인 표 — 403 + 코드일 때만', () {
      final c = otpChallengeOf(403, {
        'code': 'otp_setup_required',
        'otpTicket': 'T',
        'username': 'hong',
      })!;
      expect(c.setupRequired, isTrue);
      expect(c.ticket, 'T');
      expect(otpChallengeOf(403, {'error': '정지된 계정입니다.'}), isNull);
      expect(
        otpChallengeOf(401, {'code': 'otp_required', 'otpTicket': 'T'}),
        isNull,
      );
    });

    test('회사 계정 결과 묻기 응답과 관리자 설정 모양', () {
      expect(ssoPollResultFromJson({'status': 'pending'}), isA<SsoPending>());
      final link = ssoPollResultFromJson({
        'status': 'link_required',
        'email': 'ho***@company.com',
        'canEmail': true,
      });
      expect((link as SsoLinkRequired).canEmail, isTrue);
      expect(
        (ssoPollResultFromJson({'status': 'error', 'error': 'x'}) as SsoFailed)
            .message,
        'x',
      );
      final s = LoginSecuritySettings.fromJson(
        _securityView(ldapTestedAt: 1000),
      );
      expect(s.google.hasClientSecret, isTrue);
      expect(s.microsoft.problem, contains('테넌트'));
      expect(s.ldap.testedAt, DateTime.fromMillisecondsSinceEpoch(1000));
      final user = AdminUser.fromJson({
        'id': 'u',
        'username': 'park',
        'createdAt': 0,
        'authSource': 'ldap',
        'otpEnabled': true,
      });
      expect(user.statusLabel, contains('회사 디렉터리'));
      expect(user.statusLabel, contains('2단계 인증'));
    });
  });

  group('회사 계정 로그인 흐름(SsoFlow)', () {
    test('PKCE S256 — RFC 7636 부록 B의 값과 같고, 검증값은 43자 base64url', () async {
      expect(
        await pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
      expect(randomVerifier(), matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    });

    test('시작 → 브라우저 열기 → 기다리는 동안 pending → 토큰, 검증값 원문은 결과 묻기에만', () async {
      final requests = <http.Request>[];
      var polls = 0;
      final api = _api(requests, {
        'POST /auth/sso/start': (_) => _json({
          'state': 'S',
          'authUrl': 'https://accounts.google.com/o/oauth2/v2/auth?x=1',
          'expiresInSeconds': 600,
        }),
        'POST /auth/sso/poll': (_) => ++polls < 3
            ? _json({'status': 'pending'})
            : _json({
                'status': 'done',
                'accessToken': 'A',
                'refreshToken': 'R',
                'userId': 'u1',
                'username': 'hong',
              }),
      });
      Uri? opened;
      final flow = SsoFlow(
        api: api,
        openUrl: (u) async {
          opened = u;
          return true;
        },
        pollInterval: Duration.zero,
        newVerifier: () => 'v' * 43,
      );
      final result = await flow.run('google');
      expect(result, isA<SsoDone>());
      expect((result as SsoDone).username, 'hong');
      expect(opened!.host, 'accounts.google.com');
      final start = _bodyOf(requests.first);
      expect(start['provider'], 'google');
      expect(start['mode'], 'login');
      expect(start['challenge'], await pkceChallenge('v' * 43));
      expect(
        start.containsKey('verifier'),
        isFalse,
        reason: '원문은 시작할 때 보내지 않는다',
      );
      expect(_bodyOf(requests.last)['verifier'], 'v' * 43);
      expect(polls, 3);
    });

    test('같은 이메일 계정 — 코드 보내고 넣으면 토큰, 취소하면 실패로 끝난다', () async {
      final requests = <http.Request>[];
      final api = _api(requests, {
        'POST /auth/sso/start': (_) =>
            _json({'state': 'S', 'authUrl': 'https://x/'}),
        'POST /auth/sso/poll': (_) => _json({
          'status': 'link_required',
          'email': 'ho***@company.com',
          'canEmail': true,
        }),
        'POST /auth/sso/link/send': (_) => _json({
          'email': 'ho***@company.com',
          'expiresInSeconds': 600,
          'resendInSeconds': 60,
        }),
        'POST /auth/sso/link/verify': (_) => _json({
          'status': 'done',
          'accessToken': 'A',
          'refreshToken': 'R',
          'userId': 'u1',
          'username': 'hong',
        }),
      });
      final flow = SsoFlow(
        api: api,
        openUrl: (_) async => true,
        pollInterval: Duration.zero,
      );
      expect(await flow.run('google'), isA<SsoLinkRequired>());
      await flow.sendLinkCode();
      final auth = await flow.verifyLinkCode('123456');
      expect(auth.userId, 'u1');
      expect(_bodyOf(requests.last)['code'], '123456');

      final waiting = SsoFlow(
        api: _api([], {
          'POST /auth/sso/start': (_) =>
              _json({'state': 'S', 'authUrl': 'https://x/'}),
          'POST /auth/sso/poll': (_) => _json({'status': 'pending'}),
        }),
        openUrl: (_) async => true,
        pollInterval: const Duration(milliseconds: 5),
      );
      final future = waiting.run('microsoft');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      waiting.cancel();
      expect(await future, isA<SsoFailed>());
    });
  });

  group('로그인 화면', () {
    Future<void> open(WidgetTester tester, Session session) async {
      tester.view.physicalSize = const Size(1280, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // 앱(main.dart)처럼 세션이 바뀌면 로그인 화면을 다시 그린다(로그인 방법을 받아 오면 단추가 생긴다).
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: session,
            builder: (_, _) => LoginScreen(session: session),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('2단계 인증을 켠 사람 — 비밀번호 뒤 코드 창, 넣은 코드와 확인 표로 둘째 단계를 부른다', (
      tester,
    ) async {
      final requests = <http.Request>[];
      final session = _session(requests, {
        'GET /server-info': (_) => _json({'mailEnabled': false}),
        'POST /auth/login': (_) => _json({
          'error': '2단계 인증을 쓰는 계정입니다. 앱을 최신 버전으로 업데이트한 뒤 다시 로그인하세요.',
          'code': 'otp_required',
          'otpRequired': true,
          'otpTicket': 'TICKET',
          'username': 'hong',
        }, status: 403),
        'POST /auth/login/otp': (_) =>
            _json({'error': '코드가 맞지 않습니다.'}, status: 400),
      });
      await open(tester, session);
      await tester.enterText(find.widgetWithText(TextField, '아이디'), 'hong');
      await tester.enterText(
        find.widgetWithText(TextField, '비밀번호'),
        'password123',
      );
      await tester.tap(find.widgetWithText(FilledButton, '로그인'));
      await tester.pumpAndSettle();
      expect(find.text('2단계 인증'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('otp-code-field')),
        '123456',
      );
      await tester.pumpAndSettle();
      final otp = requests.lastWhere((r) => r.url.path == '/auth/login/otp');
      expect(_bodyOf(otp), {'ticket': 'TICKET', 'code': '123456'});
      expect(
        find.text('코드가 맞지 않습니다.'),
        findsOneWidget,
        reason: '틀리면 창에 그대로 남아 다시 넣는다',
      );
      // 복구 코드로 바꿔 넣기.
      await tester.tap(find.byKey(const ValueKey('otp-use-recovery')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('otp-recovery-field')), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(find.text('2단계 인증'), findsNothing);
    });

    testWidgets('관리자가 꼭 쓰게 정한 사람 — 그 자리에서 켜기(QR·키 → 코드 → 복구 코드)', (
      tester,
    ) async {
      final requests = <http.Request>[];
      final session = _session(requests, {
        'GET /server-info': (_) => _json({'mailEnabled': false}),
        'POST /auth/login': (_) => _json({
          'error': 'x',
          'code': 'otp_setup_required',
          'otpSetupRequired': true,
          'otpTicket': 'SETUP',
          'username': 'lee',
        }, status: 403),
        'POST /auth/otp/setup': (_) => _json({
          'secret': 'JBSWY3DPEHPK3PXP',
          'uri':
              'otpauth://totp/TangoTalk:lee?secret=JBSWY3DPEHPK3PXP&issuer=TangoTalk',
        }),
        'POST /auth/otp/enable': (_) => _json({
          'recoveryCodes': ['aaaaa-bbbbb', 'ccccc-ddddd'],
          'accessToken': 'A',
          'refreshToken': 'R',
          'userId': 'u',
          'username': 'lee',
        }),
      });
      await open(tester, session);
      await tester.enterText(find.widgetWithText(TextField, '아이디'), 'lee');
      await tester.enterText(
        find.widgetWithText(TextField, '비밀번호'),
        'password123',
      );
      await tester.tap(find.widgetWithText(FilledButton, '로그인'));
      await tester.pumpAndSettle();
      // 먼저 방법을 고른다 — 인증 앱 켜기(보안 키 등록은 passkey_login_test.dart).
      await tester.tap(find.byKey(const ValueKey('otp-setup-totp')));
      await tester.pumpAndSettle();
      expect(find.text('2단계 인증 켜기'), findsOneWidget);
      expect(find.textContaining('관리자가 2단계 인증을 꼭 쓰게'), findsOneWidget);
      expect(find.byKey(const ValueKey('otp-qr')), findsOneWidget);
      expect(
        _bodyOf(
          requests.lastWhere((r) => r.url.path == '/auth/otp/setup'),
        )['ticket'],
        'SETUP',
      );
      await tester.enterText(
        find.byKey(const ValueKey('otp-code-field')),
        '654321',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('otp-recovery-codes')), findsOneWidget);
      expect(find.text('aaaaa-bbbbb'), findsOneWidget);
      final enable = _bodyOf(
        requests.lastWhere((r) => r.url.path == '/auth/otp/enable'),
      );
      expect(enable, {'code': '654321', 'ticket': 'SETUP'});
      // 끝까지(로그인) 가면 실제 앱 진입(네트워크)이 이어지므로 여기서 멈춘다.
    });

    testWidgets('서버가 켠 회사 계정 단추와 디렉터리 안내가 보인다(가입 화면에는 없다)', (tester) async {
      final session = _session([], {
        'GET /server-info': (_) => _json({
          'mailEnabled': false,
          'loginMethods': {
            'sso': ['google', 'microsoft'],
            'ldap': true,
            'otpPolicy': 'optional',
          },
        }),
      });
      await open(tester, session);
      expect(find.byKey(const ValueKey('login-sso-google')), findsOneWidget);
      expect(find.text('Microsoft 회사 계정으로 로그인'), findsOneWidget);
      expect(find.textContaining('회사(Windows) 계정'), findsOneWidget);
      await tester.tap(find.text('계정이 없으신가요? 회원가입'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('login-sso-google')), findsNothing);
    });
  });

  group('관리자 콘솔 "로그인 보안"', () {
    Future<void> open(WidgetTester tester, Session session) async {
      tester.view.physicalSize = const Size(1000, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AdminLoginSecurityTab(session: session)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('2단계 인증 정책을 고르면 바로 저장, 디렉터리는 시험 전에는 못 켠다', (tester) async {
      final requests = <http.Request>[];
      final session = _session(requests, {
        'GET /api/admin/login-security': (_) => _json(_securityView()),
        'PATCH /api/admin/login-security': (r) => _json(
          _securityView(
            otpPolicy: _bodyOf(r)['otpPolicy'] as String? ?? 'optional',
          ),
        ),
        'GET /server-info': (_) => _json({'mailEnabled': false}),
      });
      await open(tester, session);
      expect(
        find.textContaining('chat.company.com/auth/sso/callback'),
        findsOneWidget,
      );
      expect(find.text('보안 비밀: 설정됨'), findsOneWidget);
      await tester.tap(find.text('모두 필수'));
      await tester.pumpAndSettle();
      final patch = requests.lastWhere((r) => r.method == 'PATCH');
      expect(_bodyOf(patch), {'otpPolicy': 'all'});
      final ldapSwitch = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('admin-ldap-enabled')),
      );
      expect(ldapSwitch.onChanged, isNull, reason: '연결 시험 전');
      await tester.pump(const Duration(seconds: 5)); // 토스트가 사라지도록.
    });

    testWidgets('디렉터리 연결 시험 — 찾은 사람을 보여 주고, 통과하면 켤 수 있게 된다', (tester) async {
      final requests = <http.Request>[];
      final session = _session(requests, {
        'GET /api/admin/login-security': (_) => _json(_securityView()),
        'POST /api/admin/login-security/ldap-test': (_) => _json({
          'ok': true,
          'message': '사용자를 찾았습니다: 박영희',
          'profile': {
            'name': '박영희',
            'email': 'park@company.com',
            'department': '영업팀',
            'title': '과장',
          },
          'view': _securityView(
            ldapTestedAt: DateTime(2026, 10, 17).millisecondsSinceEpoch,
          ),
        }),
      });
      await open(tester, session);
      await tester.enterText(
        find.widgetWithText(TextField, '찾아볼 아이디(선택)'),
        'park',
      );
      await tester.tap(find.byKey(const ValueKey('admin-ldap-test')));
      await tester.pumpAndSettle();
      expect(find.textContaining('사용자를 찾았습니다: 박영희'), findsOneWidget);
      expect(find.textContaining('영업팀'), findsOneWidget);
      expect(_bodyOf(requests.last), {'username': 'park'});
      final ldapSwitch = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('admin-ldap-enabled')),
      );
      expect(ldapSwitch.onChanged, isNotNull);
    });
  });

  group('내 프로필 2단계 인증', () {
    testWidgets('상태를 보여 주고 켜기 → QR·코드 → 복구 코드', (tester) async {
      final requests = <http.Request>[];
      var enabled = false;
      final session = Session(
        notifications: NotificationService(),
        settings: AppSettings(),
      );
      session.api = _api(requests, {
        'GET /auth/otp/status': (_) => _json({
          'enabled': enabled,
          'required': false,
          'policy': 'optional',
          'recoveryCodesLeft': enabled ? 10 : 0,
        }),
        'POST /auth/otp/setup': (_) => _json({
          'secret': 'JBSWY3DPEHPK3PXP',
          'uri': 'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP',
        }),
        'POST /auth/otp/enable': (_) {
          enabled = true;
          return _json({
            'recoveryCodes': ['aaaaa-bbbbb'],
          });
        },
      }, token: 't');
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showOtpManageDialog(context, session),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      expect(find.text('꺼져 있습니다'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('otp-start-enable')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('otp-code-field')),
        '111111',
      );
      await tester.pumpAndSettle();
      expect(
        _bodyOf(requests.lastWhere((r) => r.url.path == '/auth/otp/enable')),
        {'code': '111111'},
      );
      await tester.tap(find.byKey(const ValueKey('otp-setup-finish')));
      await tester.pumpAndSettle();
      expect(find.text('켜져 있습니다'), findsOneWidget);
      expect(session.otpEnabled, isTrue);
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
