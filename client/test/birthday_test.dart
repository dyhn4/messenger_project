import 'dart:convert';

import 'package:client/models/app_user.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/birthday_dialog.dart';
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

/// 프로필의 생일 — 월/일 선택(2월 29일 허용), 삭제, PATCH /users/me payload, 준회원 안내, 서버 오류 표시.

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

/// PATCH /api/users/me 본문을 [bodies]에 모으고, 서버가 저장한 것처럼 그 생일을 돌려주는 가짜 서버.
class _Server {
  final bodies = <Map<String, dynamic>>[];
  String? error;
  late final client = MockClient((request) async {
    if (request.url.path == '/api/users/me' && request.method == 'PATCH') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      bodies.add(body);
      if (error != null) {
        return http.Response.bytes(
          utf8.encode(jsonEncode({'error': error})),
          400,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'username': 'me',
            'name': '나',
            'role': 'member',
            'birthday': body['birthday'],
          }),
        ),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    return http.Response.bytes(utf8.encode('[]'), 200);
  });
}

Session _session(_Server server, {AccountRole role = AccountRole.member}) {
  final session = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: server.client,
  );
  session.userId = 'me';
  session.name = '나';
  session.accountRole = role;
  return session;
}

Future<void> _pumpDialog(WidgetTester tester, Session session) async {
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: BirthdayEditDialog(session: session)),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, Finder dropdown, String label) async {
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  // 일 목록은 길어서 아래 항목은 스크롤해야 그려진다.
  final item = find.text(label);
  if (item.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      item,
      60,
      scrollable: find.byType(Scrollable).last,
    );
  }
  await tester.tap(item.last);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('생일 값 변환', () {
    test('월/일 ↔ MM-DD', () {
      expect(birthdayValue(3, 1), '03-01');
      expect(birthdayValue(12, 31), '12-31');
      expect(parseBirthdayValue('03-01'), (month: 3, day: 1));
      expect(parseBirthdayValue('02-29'), (month: 2, day: 29));
      expect(parseBirthdayValue('02-30'), isNull);
      expect(parseBirthdayValue('13-01'), isNull);
      expect(parseBirthdayValue('3-1'), isNull);
      expect(parseBirthdayValue(null), isNull);
      expect(birthdayText('03-01'), '3월 1일');
      expect(birthdayText(null), isNull);
    });

    test('달별 최대 일수 — 2월은 29일까지', () {
      expect(maxBirthdayDay(2), 29);
      expect(maxBirthdayDay(4), 30);
      expect(maxBirthdayDay(12), 31);
    });

    test('서버 사용자·내 프로필 JSON의 birthday를 읽는다', () {
      final user = AppUser.fromJson({
        'id': 'u',
        'username': 'u',
        'birthday': '07-04',
      });
      expect(user.birthday, '07-04');
      expect(AppUser.fromJson({'id': 'u', 'username': 'u'}).birthday, isNull);
      final me = MyProfile.fromJson({'username': 'u', 'birthday': '02-29'});
      expect(me.birthday, '02-29');
    });
  });

  group('생일 수정 창', () {
    testWidgets('월/일을 고르면 저장이 켜지고 birthday: "MM-DD"를 PATCH한다', (tester) async {
      final server = _Server();
      final session = _session(server);
      await _pumpDialog(tester, session);
      FilledButton save() => tester.widget<FilledButton>(
        find.byKey(const ValueKey('birthday-save')),
      );
      expect(save().onPressed, isNull);
      expect(find.byKey(const ValueKey('birthday-delete')), findsNothing);

      await _pick(tester, find.byKey(const ValueKey('birthday-month')), '3월');
      expect(save().onPressed, isNull); // 일도 골라야 한다.
      await _pick(tester, find.byKey(const ValueKey('birthday-day-3')), '1일');
      expect(save().onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('birthday-save')));
      await tester.pumpAndSettle();

      expect(server.bodies, [
        {'birthday': '03-01'},
      ]);
      // 저장 뒤 세션 값이 갱신된다(프로필 카드가 다시 그려질 때 보인다).
      expect(session.birthday, '03-01');
    });

    testWidgets('2월 29일을 고를 수 있고, 31일에서 2월로 바꾸면 29일로 맞춘다', (tester) async {
      final server = _Server();
      final session = _session(server);
      await _pumpDialog(tester, session);
      await _pick(tester, find.byKey(const ValueKey('birthday-month')), '1월');
      await _pick(tester, find.byKey(const ValueKey('birthday-day-1')), '31일');
      await _pick(tester, find.byKey(const ValueKey('birthday-month')), '2월');
      // 2월에는 31일이 없으니 마지막 날(29일)로 바뀌어 있다.
      await tester.tap(find.byKey(const ValueKey('birthday-save')));
      await tester.pumpAndSettle();
      expect(server.bodies.single, {'birthday': '02-29'});
    });

    testWidgets('이미 있는 생일에서 삭제하면 birthday: null을 보낸다', (tester) async {
      final server = _Server();
      final session = _session(server)..birthday = '05-05';
      await _pumpDialog(tester, session);
      // 저장된 값이 미리 골라져 있고, 안 바꾸면 저장은 꺼져 있다.
      expect(find.text('5월'), findsOneWidget);
      expect(find.text('5일'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('birthday-save')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('birthday-delete')));
      await tester.pumpAndSettle();
      expect(server.bodies.single.containsKey('birthday'), isTrue);
      expect(server.bodies.single['birthday'], isNull);
      expect(session.birthday, isNull);
    });

    testWidgets('설명 문구가 보인다', (tester) async {
      await _pumpDialog(tester, _session(_Server()));
      expect(find.text('생일 캘린더에 팀원들에게 표시됩니다(연도는 저장하지 않아요)'), findsOneWidget);
      expect(find.byKey(const ValueKey('birthday-guest-note')), findsNothing);
    });

    testWidgets('준회원에게는 정회원부터 표시된다는 안내가 붙지만 입력은 그대로 된다', (tester) async {
      final server = _Server();
      await _pumpDialog(tester, _session(server, role: AccountRole.guest));
      expect(find.text('정회원부터 생일 캘린더에 표시돼요.'), findsOneWidget);
      await _pick(tester, find.byKey(const ValueKey('birthday-month')), '12월');
      await _pick(tester, find.byKey(const ValueKey('birthday-day-12')), '7일');
      await tester.tap(find.byKey(const ValueKey('birthday-save')));
      await tester.pumpAndSettle();
      expect(server.bodies.single, {'birthday': '12-07'});
    });

    testWidgets('서버 오류는 창 안에 그대로 보이고 창은 열려 있다', (tester) async {
      final server = _Server()..error = '존재하지 않는 날짜입니다.';
      final session = _session(server);
      await _pumpDialog(tester, session);
      await _pick(tester, find.byKey(const ValueKey('birthday-month')), '4월');
      await _pick(tester, find.byKey(const ValueKey('birthday-day-4')), '9일');
      await tester.tap(find.byKey(const ValueKey('birthday-save')));
      await tester.pumpAndSettle();
      expect(find.text('존재하지 않는 날짜입니다.'), findsOneWidget);
      expect(find.byKey(const ValueKey('birthday-save')), findsOneWidget);
      expect(session.birthday, isNull);
    });
  });

  group('내 프로필 카드', () {
    Future<void> pumpProfile(WidgetTester tester, Session session) async {
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MyProfileDialog(session: session)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('생일 항목: 없으면 "설정 안 함", 있으면 "M월 D일"이고 누르면 수정 창', (tester) async {
      final server = _Server();
      final session = _session(server);
      session.teams.add(Team(id: 't1', name: '영업팀', createdAt: DateTime(2026)));
      await pumpProfile(tester, session);
      expect(find.text('생일'), findsOneWidget);
      expect(find.text('설정 안 함'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('profile-birthday')));
      await tester.pumpAndSettle();
      expect(find.byType(BirthdayEditDialog), findsOneWidget);
      await _pick(tester, find.byKey(const ValueKey('birthday-month')), '3월');
      await _pick(tester, find.byKey(const ValueKey('birthday-day-3')), '1일');
      await tester.tap(find.byKey(const ValueKey('birthday-save')));
      await tester.pumpAndSettle();
      // 저장하면 카드가 바로 갱신된다.
      expect(find.byType(BirthdayEditDialog), findsNothing);
      expect(find.text('3월 1일'), findsOneWidget);
      expect(server.bodies.single, {'birthday': '03-01'});
    });
  });
}
