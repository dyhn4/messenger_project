// 로그인 쪽 보안 키·패스키와 로그아웃 연동(앱) — 로그인 화면의 "보안 키·패스키로 로그인"(비밀번호 없이), 2단계 인증의 "보안 키로
// 확인"(인증 앱과 함께·보안 키만), 관리자가 꼭 쓰게 정한 사람의 보안 키 등록, SAML 단추 글, 로그아웃할 때 서버에 알리고 회사 계정
// 로그아웃 주소를 여는 것. 서버는 가짜 HTTP, 브라우저 열기는 가로챈다(passkeyFlowFactory·Session.openIdpLogoutUrl).
import 'dart:convert';

import 'package:client/screens/login_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/passkey_flow.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/passkey_dialogs.dart';
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

/// 보안 키 확인이 끝난 답 — 토큰.
http.Response _done(_) => _json({
  'status': 'done',
  'accessToken': 'A',
  'refreshToken': 'R',
  'userId': 'u1',
  'username': 'hong',
});

/// 시작하면 브라우저로 열 페이지 주소.
http.Response _started(_) =>
    _json({'state': 'S', 'url': 'https://chat.company.com/passkey?s=S'});

void main() {
  /// 브라우저로 연 페이지 주소들 — 보안 키 흐름은 기다리지 않고(간격 0) 바로 묻는다.
  late List<Uri> opened;
  late PasskeyFlow Function(ApiClient api) originalFactory;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    opened = [];
    originalFactory = passkeyFlowFactory;
    passkeyFlowFactory = (api) => PasskeyFlow(
      api: api,
      openUrl: (u) async {
        opened.add(u);
        return true;
      },
      pollInterval: Duration.zero,
    );
  });
  tearDown(() => passkeyFlowFactory = originalFactory);

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

  Future<void> loginWithPassword(WidgetTester tester) async {
    await tester.enterText(find.widgetWithText(TextField, '아이디'), 'hong');
    await tester.enterText(
      find.widgetWithText(TextField, '비밀번호'),
      'password123',
    );
    await tester.tap(find.widgetWithText(FilledButton, '로그인'));
    await tester.pumpAndSettle();
  }

  /// 비밀번호는 맞았고 둘째 단계가 남았다는 서버 답.
  http.Response otpRequired(List<String> methods) => _json({
    'error': 'x',
    'code': 'otp_required',
    'otpRequired': true,
    'otpTicket': 'TICKET',
    'methods': methods,
    'username': 'hong',
  }, status: 403);

  group('비밀번호 없이 보안 키·패스키로 로그인', () {
    testWidgets('서버가 꺼 두면 단추가 없다', (tester) async {
      final session = _session([], {
        'GET /server-info': (_) => _json({
          'mailEnabled': false,
          'loginMethods': {
            'sso': ['google'],
            'passkey': false,
          },
        }),
      });
      await open(tester, session);
      expect(find.byKey(const ValueKey('login-sso-google')), findsOneWidget);
      expect(find.byKey(const ValueKey('login-passkey')), findsNothing);
    });

    testWidgets('켜져 있으면 단추 → 시작·브라우저·결과 묻기 → 받은 토큰으로 들어간다(가입 화면에는 없다)', (
      tester,
    ) async {
      final requests = <http.Request>[];
      var polls = 0;
      final session = _session(requests, {
        'GET /server-info': (_) => _json({
          'mailEnabled': false,
          'loginMethods': {'sso': <String>[], 'passkey': true},
        }),
        'POST /auth/passkeys/login/start': _started,
        'POST /auth/passkeys/poll': (r) =>
            ++polls < 2 ? _json({'status': 'pending'}) : _done(r),
      });
      await open(tester, session);
      expect(find.text('보안 키·패스키로 로그인'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('login-passkey')));
      await tester.pumpAndSettle();
      final start = requests.singleWhere(
        (r) => r.url.path == '/auth/passkeys/login/start',
      );
      expect(_bodyOf(start).keys, ['challenge'], reason: '아이디는 묻지 않는다');
      expect(opened.single.path, '/passkey');
      expect(polls, 2);
      // 받은 토큰을 회사 계정 로그인과 같은 길(signInWith)로 넘겼다 — 앱 진입(네트워크)은 시험하지 않는다.
      expect(session.token, 'A');
      expect(session.refreshToken, 'R');
      expect(session.username, 'hong');
      expect(find.byKey(const ValueKey('passkey-waiting')), findsNothing);

      await tester.tap(find.text('계정이 없으신가요? 회원가입'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('login-passkey')), findsNothing);
    });

    testWidgets('실패하면 까닭을 보이고 다시 시도할 수 있다', (tester) async {
      final requests = <http.Request>[];
      var polls = 0;
      final session = _session(requests, {
        'GET /server-info': (_) => _json({
          'mailEnabled': false,
          'loginMethods': {'passkey': true},
        }),
        'POST /auth/passkeys/login/start': _started,
        'POST /auth/passkeys/poll': (r) => ++polls == 1
            ? _json({'status': 'failed', 'error': '등록되지 않은 보안 키입니다.'})
            : _done(r),
      });
      await open(tester, session);
      await tester.tap(find.byKey(const ValueKey('login-passkey')));
      await tester.pumpAndSettle();
      expect(find.text('등록되지 않은 보안 키입니다.'), findsOneWidget);
      expect(session.token, isNull);
      await tester.tap(find.byKey(const ValueKey('passkey-retry')));
      await tester.pumpAndSettle();
      expect(
        requests.where((r) => r.url.path == '/auth/passkeys/login/start'),
        hasLength(2),
      );
      expect(session.token, 'A');
    });
  });

  group('2단계 인증의 보안 키', () {
    testWidgets('인증 앱과 보안 키 둘 다 — 코드 창에 "보안 키로 확인", 확인 표로 둘째 단계를 시작한다', (
      tester,
    ) async {
      final requests = <http.Request>[];
      final session = _session(requests, {
        'GET /server-info': (_) => _json({'mailEnabled': false}),
        'POST /auth/login': (_) => otpRequired(['totp', 'webauthn']),
        'POST /auth/passkeys/second/start': _started,
        'POST /auth/passkeys/poll': _done,
      });
      await open(tester, session);
      await loginWithPassword(tester);
      expect(find.byKey(const ValueKey('otp-code-field')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('otp-use-passkey')));
      await tester.pumpAndSettle();
      final start = requests.singleWhere(
        (r) => r.url.path == '/auth/passkeys/second/start',
      );
      expect(_bodyOf(start)['ticket'], 'TICKET');
      expect(
        requests.where((r) => r.url.path == '/auth/login/otp'),
        isEmpty,
        reason: '코드는 넣지 않았다',
      );
      expect(find.text('2단계 인증'), findsNothing, reason: '보안 키로 마치면 코드 창도 닫힌다');
      expect(session.token, 'A');
    });

    testWidgets('인증 앱만 — "보안 키로 확인"은 없다', (tester) async {
      final session = _session([], {
        'GET /server-info': (_) => _json({'mailEnabled': false}),
        'POST /auth/login': (_) => otpRequired(['totp']),
      });
      await open(tester, session);
      await loginWithPassword(tester);
      expect(find.byKey(const ValueKey('otp-code-field')), findsOneWidget);
      expect(find.byKey(const ValueKey('otp-use-passkey')), findsNothing);
    });

    testWidgets('보안 키만 — 코드 창 없이 바로 보안 키 확인, 취소하면 로그인 화면에 남는다', (tester) async {
      final requests = <http.Request>[];
      final session = _session(requests, {
        'GET /server-info': (_) => _json({'mailEnabled': false}),
        'POST /auth/login': (_) => otpRequired(['webauthn']),
        'POST /auth/passkeys/second/start': _started,
        'POST /auth/passkeys/poll': (_) => _json({'status': 'pending'}),
      });
      // 결과 묻기가 계속 pending이다 — 간격 0이면 끝없이 묻으니 이 시험만 1초 간격으로, 그 안에 화면을 본다.
      passkeyFlowFactory = (api) => PasskeyFlow(
        api: api,
        openUrl: (u) async {
          opened.add(u);
          return true;
        },
        pollInterval: const Duration(seconds: 1),
      );
      await open(tester, session);
      await tester.enterText(find.widgetWithText(TextField, '아이디'), 'hong');
      await tester.enterText(
        find.widgetWithText(TextField, '비밀번호'),
        'password123',
      );
      await tester.tap(find.widgetWithText(FilledButton, '로그인'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(find.byKey(const ValueKey('otp-code-field')), findsNothing);
      expect(find.text('보안 키로 확인'), findsOneWidget);
      expect(find.byKey(const ValueKey('passkey-waiting')), findsOneWidget);
      expect(
        _bodyOf(
          requests.singleWhere(
            (r) => r.url.path == '/auth/passkeys/second/start',
          ),
        )['ticket'],
        'TICKET',
      );
      await tester.tap(find.byKey(const ValueKey('passkey-cancel')));
      await tester.pumpAndSettle();
      expect(find.text('보안 키로 확인'), findsNothing);
      expect(session.token, isNull);
      expect(find.widgetWithText(FilledButton, '로그인'), findsOneWidget);
      // 기다리던 차례가 돌아와도 취소했으니 더 묻지 않는다.
      final polls = requests.where((r) => r.url.path == '/auth/passkeys/poll');
      final before = polls.length;
      await tester.pump(const Duration(seconds: 3));
      expect(polls.length, before);
    });

    testWidgets('관리자가 꼭 쓰게 정한 사람 — 인증 앱 켜기와 보안 키 등록 중에 고르고, 등록하면 들어간다', (
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
          'username': 'hong',
        }, status: 403),
        'POST /auth/passkeys/register/start': _started,
        'POST /auth/passkeys/poll': _done,
      });
      await open(tester, session);
      await loginWithPassword(tester);
      expect(find.text('2단계 인증 방법 고르기'), findsOneWidget);
      expect(find.byKey(const ValueKey('otp-setup-totp')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('otp-setup-passkey')));
      await tester.pumpAndSettle();
      final start = requests.singleWhere(
        (r) => r.url.path == '/auth/passkeys/register/start',
      );
      expect(_bodyOf(start)['ticket'], 'SETUP');
      expect(opened, hasLength(1));
      expect(session.token, 'A');
      expect(find.text('2단계 인증 방법 고르기'), findsNothing);
    });
  });

  group('SAML 단추', () {
    testWidgets('관리자가 정한 IdP 이름으로 보이고, 안 정했으면 기본 이름', (tester) async {
      final session = _session([], {
        'GET /server-info': (_) => _json({
          'mailEnabled': false,
          'loginMethods': {
            'sso': ['microsoft', 'saml'],
            'samlLabel': 'Okta',
          },
        }),
      });
      await open(tester, session);
      expect(find.byKey(const ValueKey('login-sso-saml')), findsOneWidget);
      expect(find.text('Okta 로그인'), findsOneWidget);
      expect(find.text('Microsoft 회사 계정으로 로그인'), findsOneWidget);
    });

    testWidgets('IdP 이름이 없으면 "회사 계정(SAML)"', (tester) async {
      final session = _session([], {
        'GET /server-info': (_) => _json({
          'mailEnabled': false,
          'loginMethods': {
            'sso': ['saml'],
          },
        }),
      });
      await open(tester, session);
      expect(find.text('회사 계정(SAML) 로그인'), findsOneWidget);
    });
  });

  group('로그아웃 연동', () {
    late List<Uri> idpOpened;
    late Future<bool> Function(Uri url) originalOpen;

    setUp(() {
      idpOpened = [];
      originalOpen = Session.openIdpLogoutUrl;
      Session.openIdpLogoutUrl = (u) async {
        idpOpened.add(u);
        return true;
      };
    });
    tearDown(() => Session.openIdpLogoutUrl = originalOpen);

    Future<Session> signedIn(
      List<http.Request> requests,
      http.Response Function(http.Request) logout,
    ) async {
      final session = Session(
        notifications: NotificationService(),
        settings: AppSettings(),
      );
      await session.init();
      session.serverUrl = null; // 소켓은 붙이지 않는다.
      session.token = 'access';
      session.refreshToken = 'refresh';
      session.api = _api(requests, {
        'POST /auth/logout': logout,
      }, token: 'access');
      return session;
    }

    test('토큰을 지우기 전에 서버에 알리고(갱신 토큰도), 받은 회사 계정 로그아웃 주소를 브라우저로 연다', () async {
      final requests = <http.Request>[];
      String? authHeader;
      final session = await signedIn(requests, (r) {
        authHeader = r.headers['authorization'] ?? r.headers['Authorization'];
        return _json({
          'ok': true,
          'idpLogoutUrl':
              'https://login.microsoftonline.com/t/oauth2/v2.0/logout?post_logout_redirect_uri=x',
        });
      });
      await session.logout();
      final call = requests.singleWhere((r) => r.url.path == '/auth/logout');
      expect(_bodyOf(call), {'refreshToken': 'refresh'});
      expect(authHeader, 'Bearer access', reason: '아직 토큰이 살아 있을 때 알린다');
      expect(idpOpened.single.host, 'login.microsoftonline.com');
      expect(session.token, isNull);
      expect(session.refreshToken, isNull);
      expect(session.stage, AuthStage.needsLogin);
    });

    test('회사 계정 로그아웃 주소가 없으면 브라우저를 열지 않는다', () async {
      final requests = <http.Request>[];
      final session = await signedIn(requests, (_) => _json({'ok': true}));
      await session.logout();
      expect(requests.where((r) => r.url.path == '/auth/logout'), hasLength(1));
      expect(idpOpened, isEmpty);
      expect(session.token, isNull);
    });

    test('서버가 안 되면(오프라인·오류) 알리기는 건너뛰고 로그아웃은 그대로', () async {
      final session = await signedIn(
        [],
        (_) => _json({'error': 'down'}, status: 500),
      );
      await session.logout();
      expect(idpOpened, isEmpty);
      expect(session.token, isNull);
      expect(session.stage, AuthStage.needsLogin);
    });

    test('서버가 이미 세션을 끝낸 로그아웃(notifyServer: false)은 알리지 않는다', () async {
      final requests = <http.Request>[];
      final session = await signedIn(requests, (_) => _json({'ok': true}));
      await session.logout(notifyServer: false);
      expect(requests, isEmpty);
      expect(session.token, isNull);
    });
  });
}
