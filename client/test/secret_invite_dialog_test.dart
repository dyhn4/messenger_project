import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/home_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/chat_socket.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 비밀 대화 요청 창(HomeScreen) — 새 규약을 알리지 않은 요청(예전 앱이 걸었거나 서버가 새 규약 표시를 뺌)은 수락할 수
/// 없다는 이유를 보여 주고 거절만 하게 한다(SecretSessionManager.offersCurrentProtocol). 새 앱의 요청은 그대로 수락할 수 있다.
class _Quiet extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

const _serverUrl = 'https://192.168.0.10:3000';

Map<String, dynamic> _user(String id, String name) => {
  'id': id,
  'username': 'user_$id',
  'name': name,
  'role': 'member',
};

/// 앱이 서버로 보낸 요청(경로) — 거절이 서버로 갔는지 본다.
final _requests = <String>[];

Session _session() {
  _requests.clear();
  final client = MockClient((request) async {
    _requests.add('${request.method} ${request.url.path}');
    return http.Response.bytes(
      utf8.encode(jsonEncode(<Object>[])),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  });
  final session = Session(notifications: _Quiet(), settings: AppSettings());
  session.serverUrl = _serverUrl;
  session.api = ApiClient(baseUrl: _serverUrl, token: 't', httpClient: client);
  session.userId = 'me';
  session.name = '김하나';
  final team = Team(id: 't1', name: '팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.add(
    Room.fromJson({
      'id': 'room-s',
      'teamId': 't1',
      'type': 'dm',
      'name': null,
      'members': [_user('me', '김하나'), _user('u2', '이도현')],
      'createdAt': 1000,
      'isSecret': true,
      'secretStatus': 'pending',
      'secretInitiatorUserId': 'u2',
    }),
  );
  return session;
}

SecretInviteEvent _invite({String? contextSignature, int? protocol}) =>
    SecretInviteEvent(
      roomId: 'room-s',
      initiatorUserId: 'u2',
      initiatorDeviceId: 'd-u2',
      initiatorEphemeralPublicKey: base64Encode(List.filled(32, 1)),
      initiatorEphemeralSignature: base64Encode(List.filled(64, 2)),
      initiatorContextSignature: contextSignature,
      initiatorProtocol: protocol,
    );

Future<void> _pumpHome(WidgetTester tester, Session session) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: HomeScreen(session: session)));
  await tester.pumpAndSettle();
}

void main() {
  final contextSignature = base64Encode(List.filled(64, 3));

  for (final (name, invite) in [
    (
      '규약 표시 없음(예전 서버·서버가 뺌·업데이트 전 앱)',
      _invite(contextSignature: contextSignature),
    ),
    ('맥락 서명 없음(예전 앱)', _invite(protocol: 3)),
    ('규약 번호가 3보다 작음', _invite(contextSignature: contextSignature, protocol: 2)),
  ]) {
    testWidgets('새 규약을 알리지 않은 요청 — $name: 수락할 수 없는 이유를 보여 주고 거절하거나 닫을 수만 있다', (
      tester,
    ) async {
      final session = _session()..pendingSecretInvites.add(invite);
      expect(session.secretInviteIsOutdated(invite), isTrue);
      await _pumpHome(tester, session);
      expect(find.text('비밀 대화 요청'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('secret-invite-outdated')),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, '거절'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '닫기'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '수락'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    '수락할 수 없는 요청을 닫으면 서버에 거절하지 않고(내 다른 기기에서 받을 수 있게) 이 기기에서 다시 띄우지 않는다',
    (tester) async {
      final invite = _invite(contextSignature: contextSignature);
      final session = _session()..pendingSecretInvites.add(invite);
      await _pumpHome(tester, session);
      await tester.tap(find.widgetWithText(TextButton, '닫기'));
      await tester.pumpAndSettle();
      expect(find.text('비밀 대화 요청'), findsNothing);
      expect(session.pendingSecretInvites, isEmpty);
      expect(_requests.where((r) => r.contains('/reject')), isEmpty);
      // 같은 방의 요청을 서버에서 다시 가져와도(알림을 누름 등) 다시 띄우지 않는다.
      session.rooms.single.secretStatus = 'pending';
      await session.ensurePendingSecretInvite('room-s');
      expect(session.pendingSecretInvites, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('새 앱의 요청(맥락 서명 + 규약 3)은 그대로 수락할 수 있다', (tester) async {
    final invite = _invite(contextSignature: contextSignature, protocol: 3);
    final session = _session()..pendingSecretInvites.add(invite);
    expect(session.secretInviteIsOutdated(invite), isFalse);
    await _pumpHome(tester, session);
    expect(find.text('비밀 대화 요청'), findsOneWidget);
    expect(find.byKey(const ValueKey('secret-invite-outdated')), findsNothing);
    expect(find.widgetWithText(FilledButton, '수락'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '거절'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
