import 'dart:convert';

import 'package:client/models/app_notification.dart';
import 'package:client/models/mail_settings.dart';
import 'package:client/screens/admin_mail_tab.dart';
import 'package:client/screens/find_id_screen.dart';
import 'package:client/screens/find_password_screen.dart';
import 'package:client/screens/login_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_controller.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/invite_mail_dialog.dart';
import 'package:client/widgets/notification_settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers/fake_notification_api.dart';

/// 메일(SMTP) 기능 — 서버에 메일이 켜져 있을 때만 가입은 이메일 인증 코드로(보안 질문 대신), 아이디는 메일로 받고, 비밀번호는
/// 메일로 받은 코드로 재설정한다. 꺼져 있거나 예전 서버면 지금처럼 보안 질문으로 동작한다(server/src/auth.js·mailer.js).

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

/// [routes]의 키는 "메서드 경로"(예: 'POST /auth/find-id'). 없는 경로는 예전 서버처럼 HTML 404.
Session _session(
  List<http.Request> requests,
  Map<String, http.Response Function(http.Request request)> routes, {
  bool mailEnabled = false,
}) {
  final session = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: MockClient((request) async {
      requests.add(request);
      final key = '${request.method} ${request.url.path}';
      if (key == 'GET /server-info' && !routes.containsKey(key)) {
        return _json({'mailEnabled': mailEnabled, 'internalUrls': []});
      }
      final route = routes[key];
      if (route != null) return route(request);
      return http.Response(
        '<html>Cannot ${request.method}</html>',
        404,
        headers: {'content-type': 'text/html'},
      );
    }),
  );
  session.mailEnabled = mailEnabled;
  return session;
}

Map<String, dynamic> _bodyOf(http.Request request) =>
    jsonDecode(request.body) as Map<String, dynamic>;

Future<void> _pumpDialog(WidgetTester tester, Widget dialog) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Builder(builder: (_) => dialog)),
    ),
  );
  await tester.pumpAndSettle();
}

/// EmailAddressField(로컬 파트 + 도메인 드롭다운, 기본 naver.com)에 아이디 부분을 넣는다.
Future<void> _typeEmailLocal(WidgetTester tester, String local) async {
  await tester.enterText(
    find
        .descendant(
          of: find.byType(Row),
          matching: find.widgetWithText(TextField, '이메일 주소'),
        )
        .first,
    local,
  );
}

void main() {
  group('ApiClient', () {
    test('메일 기능 여부 — 켜짐·꺼짐·못 물어봄(꺼짐으로 본다)', () async {
      final requests = <http.Request>[];
      expect(
        await _session(requests, {}, mailEnabled: true).api!.fetchMailEnabled(),
        isTrue,
      );
      expect(
        await _session(
          requests,
          {},
          mailEnabled: false,
        ).api!.fetchMailEnabled(),
        isFalse,
      );
      final broken = _session(requests, {
        'GET /server-info': (_) => http.Response('nope', 502),
      });
      expect(await broken.api!.fetchMailEnabled(), isFalse);
    });

    test('아이디 찾기 — 메일로 보냈으면 아이디 대신 받은 주소', () async {
      final requests = <http.Request>[];
      final mailed = _session(requests, {
        'POST /auth/find-id': (_) =>
            _json({'sent': true, 'email': 'ab***@naver.com'}),
      });
      final r1 = await mailed.api!.findId('abcde@naver.com');
      expect(r1.sentByMail, isTrue);
      expect(r1.sentTo, 'ab***@naver.com');
      final shown = _session(requests, {
        'POST /auth/find-id': (_) => _json({'username': 'hong'}),
      });
      final r2 = await shown.api!.findId('abcde@naver.com');
      expect(r2.sentByMail, isFalse);
      expect(r2.username, 'hong');
    });

    test('비밀번호 찾기 첫 단계 — 메일 코드·보안 질문, 예전 서버면 보안 질문 조회로', () async {
      final requests = <http.Request>[];
      final byMail = _session(requests, {
        'POST /auth/password-reset/start': (_) => _json({
          'method': 'email',
          'email': 'ho***@naver.com',
          'expiresInSeconds': 600,
          'resendInSeconds': 60,
        }),
      });
      final s1 = await byMail.api!.startPasswordReset(
        username: 'hong',
        email: 'hong@naver.com',
      );
      expect(s1.byEmail, isTrue);
      expect(s1.emailCode!.email, 'ho***@naver.com');
      expect(s1.emailCode!.expiresIn, const Duration(minutes: 10));

      final byQuestion = _session(requests, {
        'POST /auth/password-reset/start': (_) =>
            _json({'method': 'question', 'question': '첫 애완동물 이름은?'}),
      });
      final s2 = await byQuestion.api!.startPasswordReset(
        username: 'hong',
        email: 'hong@naver.com',
      );
      expect(s2.byEmail, isFalse);
      expect(s2.question, '첫 애완동물 이름은?');

      requests.clear();
      final oldServer = _session(requests, {
        'POST /auth/security-question': (_) => _json({'question': '고향은?'}),
      });
      final s3 = await oldServer.api!.startPasswordReset(
        username: 'hong',
        email: 'hong@naver.com',
      );
      expect(s3.question, '고향은?');
      expect(requests.map((r) => r.url.path), [
        '/auth/password-reset/start',
        '/auth/security-question',
      ]);

      // 서버가 "일치하는 계정이 없다"고 404로 답하면 예전 서버로 보지 않고 그 문구를 그대로 올린다.
      final noMatch = _session(requests, {
        'POST /auth/password-reset/start': (_) =>
            _json({'error': '아이디와 이메일이 일치하는 계정이 없습니다.'}, status: 404),
      });
      expect(
        () => noMatch.api!.startPasswordReset(username: 'x', email: 'x@y.z'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('일치하는 계정'),
          ),
        ),
      );
    });

    test('가입 — 메일 서버면 인증 코드를 보내고 보안 질문은 싣지 않는다', () async {
      final requests = <http.Request>[];
      final session = _session(requests, {
        'POST /auth/register': (_) => _json({
          'accessToken': 'a',
          'refreshToken': 'r',
          'userId': 'u1',
          'username': 'hong',
        }, status: 201),
      });
      await session.api!.register(
        'hong',
        'Tango!ride27',
        'hong@naver.com',
        '홍길동',
        emailCode: '012345',
      );
      final body = _bodyOf(requests.last);
      expect(body['emailCode'], '012345');
      expect(body.containsKey('securityQuestion'), isFalse);
      expect(body.containsKey('securityAnswer'), isFalse);
    });
  });

  testWidgets('아이디 찾기 — 메일로 보냈으면 아이디 대신 "메일을 보냈습니다"', (tester) async {
    final requests = <http.Request>[];
    final session = _session(requests, {
      'POST /auth/find-id': (_) =>
          _json({'sent': true, 'email': 'ho***@naver.com'}),
    });
    await _pumpDialog(tester, FindIdScreen(session: session));
    await _typeEmailLocal(tester, 'hong');
    await tester.tap(find.widgetWithText(FilledButton, '아이디 찾기'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('find-id-mail-sent')), findsOneWidget);
    expect(
      find.textContaining('ho***@naver.com(으)로 아이디를 보냈습니다'),
      findsOneWidget,
    );
    expect(find.textContaining('아이디:'), findsNothing);
    expect(_bodyOf(requests.last)['email'], 'hong@naver.com');
  });

  testWidgets('비밀번호 찾기 — 메일 코드 단계를 거쳐 그 코드로 재설정', (tester) async {
    final requests = <http.Request>[];
    final session = _session(requests, {
      'POST /auth/password-reset/start': (_) => _json({
        'method': 'email',
        'email': 'ho***@naver.com',
        'expiresInSeconds': 600,
        'resendInSeconds': 60,
      }),
      'POST /auth/password-reset/verify-code': (_) => _json({'ok': true}),
      'POST /auth/reset-password': (_) => _json({'ok': true}),
    });
    await _pumpDialog(
      tester,
      FindPasswordScreen(
        session: session,
        initialUsername: 'hong',
        initialEmail: 'hong@naver.com',
      ),
    );
    expect(
      find.byKey(const ValueKey('find-password-email-code')),
      findsOneWidget,
    );
    expect(
      find.textContaining('ho***@naver.com(으)로 인증 코드를 보냈습니다'),
      findsOneWidget,
    );
    // 보안 질문 단계는 없다.
    expect(find.textContaining('질문과 답변'), findsNothing);

    // 모양이 아닌 코드는 서버에 묻지 않는다.
    await tester.enterText(
      find.byKey(const ValueKey('email-code-field')),
      '12',
    );
    await tester.tap(find.widgetWithText(FilledButton, '확인'));
    await tester.pumpAndSettle();
    expect(find.text('메일로 받은 6자리 인증 코드를 넣으세요.'), findsOneWidget);
    expect(
      requests.where((r) => r.url.path == '/auth/password-reset/verify-code'),
      isEmpty,
    );

    await tester.enterText(
      find.byKey(const ValueKey('email-code-field')),
      '012345',
    );
    await tester.tap(find.widgetWithText(FilledButton, '확인'));
    await tester.pumpAndSettle();
    expect(_bodyOf(requests.last)['code'], '012345');
    expect(find.text('새 비밀번호를 입력하세요.'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, '새 비밀번호'),
      'Tango!ride27',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '새 비밀번호 확인'),
      'Tango!ride27',
    );
    await tester.tap(find.widgetWithText(FilledButton, '비밀번호 재설정'));
    await tester.pumpAndSettle();
    final reset = _bodyOf(
      requests.lastWhere((r) => r.url.path == '/auth/reset-password'),
    );
    expect(reset['emailCode'], '012345');
    expect(reset.containsKey('securityAnswer'), isFalse);
    expect(reset['newPassword'], 'Tango!ride27');
  });

  group('회원가입 화면', () {
    Future<void> openSignup(WidgetTester tester, Session session) async {
      tester.view.physicalSize = const Size(1280, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: LoginScreen(session: session)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('계정이 없으신가요? 회원가입'));
      await tester.pumpAndSettle();
    }

    testWidgets('메일이 켜진 서버 — 보안 질문 대신 이메일 인증 코드', (tester) async {
      final requests = <http.Request>[];
      final session = _session(requests, {
        'POST /auth/email-code/signup': (_) =>
            _json({'ok': true, 'expiresInSeconds': 600, 'resendInSeconds': 60}),
      }, mailEnabled: true);
      await openSignup(tester, session);
      expect(find.byKey(const ValueKey('signup-email-code')), findsOneWidget);
      expect(find.text('본인 확인용 질문'), findsNothing);

      await _typeEmailLocal(tester, 'hong');
      await tester.ensureVisible(find.byKey(const ValueKey('email-code-send')));
      await tester.tap(find.byKey(const ValueKey('email-code-send')));
      await tester.pumpAndSettle();
      final sent = requests.lastWhere(
        (r) => r.url.path == '/auth/email-code/signup',
      );
      expect(_bodyOf(sent)['email'], 'hong@naver.com');
      expect(find.textContaining('인증 코드를 보냈습니다'), findsOneWidget);
      expect(find.textContaining('다시 보내기'), findsOneWidget);
    });

    testWidgets('메일이 꺼진 서버 — 지금처럼 보안 질문', (tester) async {
      final requests = <http.Request>[];
      final session = _session(requests, {}, mailEnabled: false);
      await openSignup(tester, session);
      expect(find.byKey(const ValueKey('signup-email-code')), findsNothing);
      expect(find.text('본인 확인용 질문'), findsOneWidget);
    });
  });

  test('초대 메일 받는 주소 — 나누기·같은 주소 합치기·틀린 주소 거절', () {
    final ok = parseInviteRecipients('a@x.com, B@x.com\nb@X.com ; c@y.org');
    expect(ok.error, isNull);
    expect(ok.emails, ['a@x.com', 'B@x.com', 'c@y.org']);
    expect(parseInviteRecipients('a@x.com, nope').error, contains('형식'));
    expect(parseInviteRecipients('  ').error, isNotNull);
    final many = List.generate(
      kInviteMailMaxRecipients + 1,
      (i) => 'u$i@x.com',
    ).join(',');
    expect(parseInviteRecipients(many).error, contains('까지'));
  });

  group('관리자 콘솔 메일 탭', () {
    Map<String, dynamic> view({
      bool enabled = false,
      int? testedAt,
      bool complete = true,
    }) => {
      'enabled': enabled,
      'ready': enabled && complete,
      'host': 'smtp.naver.com',
      'port': 465,
      'security': 'ssl',
      'defaultPorts': {'ssl': 465, 'starttls': 587, 'none': 25},
      'username': 'tango@naver.com',
      'passwordConfigured': true,
      'fromAddress': '',
      'fromName': '',
      'effectiveFrom': 'tango@naver.com',
      'complete': complete,
      'testedAt': testedAt,
      'digest': {
        'enabled': true,
        'days': 3,
        'preview': false,
        'daysMin': 1,
        'daysMax': 30,
      },
    };

    Future<void> pumpTab(WidgetTester tester, Session session) async {
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AdminMailTab(session: session)),
        ),
      );
      await tester.pumpAndSettle();
    }

    SwitchListTile enabledSwitch(WidgetTester tester) =>
        tester.widget<SwitchListTile>(
          find.byKey(const ValueKey('admin-mail-enabled')),
        );

    testWidgets('시험 메일이 성공해야 켤 수 있다', (tester) async {
      final requests = <http.Request>[];
      var tested = false;
      final session = _session(requests, {
        'GET /api/admin/mail': (_) => _json(view(testedAt: tested ? 1 : null)),
        'POST /api/admin/mail/test': (_) {
          tested = true;
          return _json(
            view(testedAt: DateTime(2026, 10, 17).millisecondsSinceEpoch),
          );
        },
      });
      session.email = 'admin@naver.com';
      await pumpTab(tester, session);
      expect(find.textContaining('시험 필요'), findsOneWidget);
      expect(enabledSwitch(tester).onChanged, isNull, reason: '시험 전에는 켤 수 없다');

      await tester.tap(find.byKey(const ValueKey('admin-mail-test')));
      await tester.pumpAndSettle();
      final test = requests.lastWhere(
        (r) => r.url.path == '/api/admin/mail/test',
      );
      expect(_bodyOf(test)['to'], 'admin@naver.com');
      expect(
        enabledSwitch(tester).onChanged,
        isNotNull,
        reason: '시험이 성공하면 켤 수 있다',
      );
      // 성공 안내(토스트)가 사라질 때까지 흘려보낸다.
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('값을 바꾸면 저장 전에는 시험·켜기를 막는다', (tester) async {
      final requests = <http.Request>[];
      final session = _session(requests, {
        'GET /api/admin/mail': (_) => _json(view(testedAt: 1)),
      });
      await pumpTab(tester, session);
      expect(enabledSwitch(tester).onChanged, isNotNull);
      await tester.enterText(
        find.widgetWithText(TextField, 'SMTP 서버 주소'),
        'smtp.gmail.com',
      );
      await tester.pump();
      expect(enabledSwitch(tester).onChanged, isNull);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('admin-mail-test')),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('바꾼 값을 먼저 저장하세요.'), findsOneWidget);
    });

    testWidgets('예전 서버(404)면 업데이트하라고 한다', (tester) async {
      final session = _session(<http.Request>[], {});
      await pumpTab(tester, session);
      expect(find.textContaining('서버를 업데이트하세요'), findsOneWidget);
    });

    test('상태 표시 — 켜짐·시험 필요·꺼짐', () {
      final theme = ThemeData();
      expect(
        mailStatusLook(
          MailSettings.fromJson(view(enabled: true, testedAt: 1)),
          theme,
        ).$3,
        '켜짐',
      );
      expect(mailStatusLook(MailSettings.fromJson(view()), theme).$3, '시험 필요');
      expect(
        mailStatusLook(MailSettings.fromJson(view(complete: false)), theme).$3,
        '꺼짐',
      );
      expect(
        mailStatusLook(
          MailSettings.fromJson(view(testedAt: 1)),
          theme,
          dirty: true,
        ).$3,
        '꺼짐',
      );
    });
  });

  group('알림 설정 — 멘션 요약 메일', () {
    Future<NotificationController> pumpDialog(
      WidgetTester tester, {
      required bool mailEnabled,
    }) async {
      final api = FakeNotificationApi();
      final center = NotificationController(apiProvider: () => api);
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotificationSettingsDialog(
              center: center,
              mailEnabled: mailEnabled,
              emailVerified: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return center;
    }

    testWidgets('메일이 켜진 서버에서만 보이고, 끄면 서버에 저장한다', (tester) async {
      final center = await pumpDialog(tester, mailEnabled: true);
      final tile = find.byKey(const ValueKey('notif-setting-email-digest'));
      expect(tile, findsOneWidget);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(center.settings?.emailDigest, isFalse);
    });

    testWidgets('메일이 꺼진 서버에서는 안 보인다', (tester) async {
      await pumpDialog(tester, mailEnabled: false);
      expect(
        find.byKey(const ValueKey('notif-setting-email-digest')),
        findsNothing,
      );
    });

    test('설정 값 — 예전 서버(값 없음)는 켬으로 읽는다', () {
      expect(NotificationSettings.fromJson(const {}).emailDigest, isTrue);
      expect(
        NotificationSettings.fromJson(const {'emailDigest': false}).emailDigest,
        isFalse,
      );
    });
  });
}
