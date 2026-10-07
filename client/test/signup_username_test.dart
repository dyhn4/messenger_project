import 'dart:convert';

import 'package:client/screens/login_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 회원가입 아이디 규칙 — 영문·숫자와 . _ - 만, 4~20자(서버 server/src/authGuard.js의 USERNAME_PATTERN과 같다).
/// 아이디는 다른 사람이 "이 사람이 맞는지" 확인하는 값이라, 한글·띄어쓰기·비슷하게 생긴 다른 글자로 기존 아이디를
/// 흉내 내지 못하게 한다. 화면은 쓸 수 있는 글자를 미리 보여 주고, 규칙에 안 맞으면 서버에 묻지 않고 바로 알려 준다.

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Session _session(List<http.Request> requests) {
  final session = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    httpClient: MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/auth/username-available') {
        return _json({'available': true});
      }
      return _json(<String, Object?>{});
    }),
  );
  return session;
}

Future<void> _openSignup(WidgetTester tester, Session session) async {
  tester.view.physicalSize = const Size(1280, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: LoginScreen(session: session)));
  await tester.pumpAndSettle();
  await tester.tap(find.text('계정이 없으신가요? 회원가입'));
  await tester.pumpAndSettle();
}

void main() {
  test('signupUsernameError: 앞뒤 공백을 떼고 영문·숫자·. _ - 4~20자만 통과', () {
    for (final ok in [
      'hong.gil-dong_1',
      'Hong123',
      'abcd',
      'a' * 20,
      '  hong123 ',
    ]) {
      expect(signupUsernameError(ok), isNull, reason: ok);
    }
    for (final bad in [
      'abc',
      'a' * 21,
      '',
      '   ',
      '홍길동123',
      'ad min',
      'аdmin', // 첫 글자가 키릴 문자 а
      'ａｄｍｉｎ', // 전각 영문
      'admin@corp',
      'admin​',
    ]) {
      expect(signupUsernameError(bad), kSignupUsernameRule, reason: bad);
    }
    expect(kSignupUsernamePattern.pattern, r'^[A-Za-z0-9._-]{4,20}$');
    expect(kSignupUsernameRule, contains('영문·숫자와 . _ - 만'));
    expect(kSignupUsernameRule, contains('4~20자'));
  });

  testWidgets('가입 화면은 쓸 수 있는 글자를 보여 주고, 규칙에 안 맞으면 서버에 묻지 않는다', (tester) async {
    final requests = <http.Request>[];
    final session = _session(requests);
    await _openSignup(tester, session);

    expect(find.text(kSignupUsernameHelper), findsOneWidget);

    final usernameField = find.byType(TextField).first;
    await tester.enterText(usernameField, '홍길동1');
    await tester.tap(find.text('중복 확인'));
    await tester.pumpAndSettle();
    expect(find.text(kSignupUsernameRule), findsOneWidget);
    expect(
      requests.where((r) => r.url.path == '/auth/username-available'),
      isEmpty,
    );

    // 규칙에 맞는 아이디는 서버에 중복을 묻는다(보내는 값은 앞뒤 공백을 뗀 것).
    await tester.enterText(usernameField, ' hong.gd-1 ');
    await tester.pumpAndSettle();
    expect(find.text(kSignupUsernameRule), findsNothing);
    await tester.tap(find.text('중복 확인'));
    await tester.pumpAndSettle();
    final checks = requests
        .where((r) => r.url.path == '/auth/username-available')
        .toList();
    expect(checks, hasLength(1));
    expect(checks.single.url.queryParameters['username'], 'hong.gd-1');
    expect(find.text('사용 가능한 아이디입니다.'), findsOneWidget);
  });

  testWidgets('중복 확인 뒤 아이디를 규칙에 안 맞게 고치면 가입 버튼이 꺼지고 아무것도 보내지 않는다', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final session = _session(requests);
    await _openSignup(tester, session);

    final usernameField = find.byType(TextField).first;
    await tester.enterText(usernameField, 'hong123');
    await tester.tap(find.text('중복 확인'));
    await tester.pumpAndSettle();
    expect(find.text('사용 가능한 아이디입니다.'), findsOneWidget);

    // 중복 확인 뒤 아이디를 고치면 확인이 풀린다 — 다시 확인하기 전에는 가입 버튼이 꺼져 있다.
    await tester.enterText(usernameField, 'hong 123');
    await tester.pumpAndSettle();
    final submit = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '가입하기'),
    );
    expect(submit.onPressed, isNull);
    expect(requests.where((r) => r.url.path == '/auth/register'), isEmpty);
  });
}
