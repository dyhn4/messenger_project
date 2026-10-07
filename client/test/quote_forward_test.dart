// "메시지 공유"(인용 카드)·"메시지 전달"(전달 표시)·"공지 공유"가 보내는 값 — 앱은 원본 id를 보내고, 인용 카드의 보낸 사람·
// 미리보기와 전달 표시의 이름·시각은 서버가 원본에서 채운다(server/src/messageAttribution.js). 이름·미리보기 글은 업데이트 전
// 서버만 쓰도록 함께 보낸다. 고친 글에는 전달 표시를 붙이지 않고, 비밀 대화의 글·파일은 전달하지 않는다.
import 'dart:convert';

import 'package:client/models/announcement.dart';
import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/announcement_detail_screen.dart';
import 'package:client/screens/message_forward_screen.dart';
import 'package:client/screens/message_share_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/chat_socket.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _base = DateTime(2026, 9, 29, 9).millisecondsSinceEpoch;

Map<String, dynamic> _user(String id, String name) => {
  'id': id,
  'username': id,
  'name': name,
  'role': 'member',
};

Room _room(String id, String name, {String type = 'topic', bool secret = false}) =>
    Room.fromJson({
      'id': id,
      'teamId': 't1',
      'type': type,
      'name': name,
      'members': [_user('me', '나'), _user('u2', '김철수')],
      'createdAt': _base,
      'viewMode': 'chat',
      'isSecret': secret,
    });

Session _session() {
  final session = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: MockClient(
      (_) async => http.Response(
        jsonEncode(<Object>[]),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    ),
  );
  session.userId = 'me';
  session.name = '나';
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.addAll([
    _room('chat', '일반 토픽'),
    _room('target', '받는 토픽'),
    _room('secret', '비밀 대화', type: 'dm', secret: true),
  ]);
  return session;
}

Message _message({String roomId = 'chat', String text = '회의는 3시입니다'}) => Message(
  id: 'm1',
  roomId: roomId,
  senderId: 'u2',
  senderName: '김철수',
  type: MessageType.text,
  text: text,
  createdAt: DateTime(2026, 9, 29, 10),
);

/// 화면을 띄우고 받는 방([roomName])까지 고른다.
Future<void> _openAndPick(
  WidgetTester tester,
  Widget screen,
  String roomName,
) async {
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => screen)),
            child: const Text('열기'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('대화방 선택'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(roomName));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('메시지 공유 — 원본 id를 보낸다(이름·미리보기는 예전 서버용으로만 함께)', (tester) async {
    final session = _session();
    final sent = <Map<String, dynamic>>[];
    session.chatSocket.debugSendOverride = (payload) async {
      sent.add(payload);
      return {'ok': true};
    };
    await _openAndPick(
      tester,
      MessageShareScreen(
        session: session,
        message: _message(),
        senderDisplayName: '김철수',
      ),
      '받는 토픽',
    );
    await tester.enterText(find.byType(TextField), '이거 보세요');
    await tester.tap(find.widgetWithText(TextButton, '공유'));
    await tester.pumpAndSettle();

    expect(sent.single['roomId'], 'target');
    expect(sent.single['quotedMessageId'], 'm1');
    expect(sent.single['quotedSenderName'], '김철수');
    expect(sent.single['quotedPreview'], '회의는 3시입니다');
    expect(sent.single['text'], '이거 보세요');
  });

  testWidgets('메시지 전달 — "포함"이면 원본 id, 글을 고치면 원본 표시를 붙이지 않는다', (tester) async {
    final session = _session();
    final sent = <Map<String, dynamic>>[];
    session.chatSocket.debugSendOverride = (payload) async {
      sent.add(payload);
      return {'ok': true};
    };
    final screen = MessageForwardScreen(
      session: session,
      message: _message(),
      senderDisplayName: '김철수',
    );

    // 그대로 전달 — 원본 id(와 예전 서버용 이름·시각).
    await _openAndPick(tester, screen, '받는 토픽');
    expect(find.byKey(const ValueKey('forward-edited-note')), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, '전달'));
    await tester.pumpAndSettle();
    expect(sent.single['forwardedFromMessageId'], 'm1');
    expect(sent.single['forwardedFromSenderName'], '김철수');
    expect(
      sent.single['forwardedFromCreatedAt'],
      DateTime(2026, 9, 29, 10).millisecondsSinceEpoch,
    );
    expect(sent.single['text'], '회의는 3시입니다');

    // 고쳐서 전달 — 안내가 보이고, 원본 표시는 하나도 싣지 않는다.
    sent.clear();
    await _openAndPick(tester, screen, '받는 토픽');
    await tester.enterText(find.byType(TextField), '대표 지시: 회의는 3시입니다');
    await tester.pump();
    expect(find.byKey(const ValueKey('forward-edited-note')), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '전달'));
    await tester.pumpAndSettle();
    expect(sent.single['text'], '대표 지시: 회의는 3시입니다');
    expect(sent.single.containsKey('forwardedFromMessageId'), isFalse);
    expect(sent.single.containsKey('forwardedFromSenderName'), isFalse);
    expect(sent.single.containsKey('forwardedFromCreatedAt'), isFalse);

    // 앞뒤 공백만 바꾼 것은 고친 것이 아니다.
    sent.clear();
    await _openAndPick(tester, screen, '받는 토픽');
    await tester.enterText(find.byType(TextField), '  회의는 3시입니다\n');
    await tester.pump();
    expect(find.byKey(const ValueKey('forward-edited-note')), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, '전달'));
    await tester.pumpAndSettle();
    expect(sent.single['forwardedFromMessageId'], 'm1');
  });

  testWidgets('메시지 전달 — "포함"을 끄면 원본 표시 없이', (tester) async {
    final session = _session();
    final sent = <Map<String, dynamic>>[];
    session.chatSocket.debugSendOverride = (payload) async {
      sent.add(payload);
      return {'ok': true};
    };
    await _openAndPick(
      tester,
      MessageForwardScreen(
        session: session,
        message: _message(),
        senderDisplayName: '김철수',
      ),
      '받는 토픽',
    );
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, '전달'));
    await tester.pumpAndSettle();
    expect(sent.single.containsKey('forwardedFromMessageId'), isFalse);
    expect(sent.single['text'], '회의는 3시입니다');
  });

  testWidgets('비밀 대화의 메시지·파일은 전달하지 않는다(파일 뷰어의 "파일 전달"로 열려도)', (tester) async {
    final session = _session();
    final sent = <Map<String, dynamic>>[];
    session.chatSocket.debugSendOverride = (payload) async {
      sent.add(payload);
      return {'ok': true};
    };
    await _openAndPick(
      tester,
      MessageForwardScreen(
        session: session,
        message: _message(roomId: 'secret', text: '비밀 평문'),
        senderDisplayName: '김철수',
      ),
      '받는 토픽',
    );
    await tester.tap(find.widgetWithText(TextButton, '전달'));
    await tester.pump();
    expect(sent, isEmpty);
    expect(
      find.text('비밀 대화의 메시지·파일은 다른 대화방으로 전달할 수 없습니다.'),
      findsOneWidget,
    );
  });

  testWidgets('공지 공유 — 공지 id를 보낸다(작성자·글은 예전 서버용으로만 함께)', (tester) async {
    final session = _session();
    final sent = <Map<String, dynamic>>[];
    session.chatSocket.debugSendOverride = (payload) async {
      sent.add(payload);
      return {'ok': true};
    };
    final room = session.rooms.first;
    final announcement = Announcement.fromJson({
      'id': 'a1',
      'roomId': room.id,
      'authorId': 'u2',
      'authorName': '김철수',
      'text': '내일 휴무입니다',
      'createdAt': _base,
    });
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await runAnnouncementMoreAction(
      captured,
      session,
      room,
      announcement,
      AnnouncementMoreAction.share,
    );
    await tester.pump();
    expect(sent.single['roomId'], room.id);
    expect(sent.single['quotedAnnouncementId'], 'a1');
    expect(sent.single['quotedSenderName'], '김철수');
    expect(sent.single['quotedPreview'], '내일 휴무입니다');
    await tester.pump(const Duration(seconds: 5));
  });

  test('너무 큰 message:send는 보내기 전에 거른다(서버는 받지 않고 연결을 끊는다)', () async {
    final session = _session();
    var called = false;
    session.chatSocket.debugSendOverride = (payload) async {
      called = true;
      return {'ok': true};
    };
    expect(
      fitsSocketMessage({'roomId': 'chat', 'type': 'text', 'text': '안녕'}),
      isTrue,
    );
    // 한글은 UTF-8로 3바이트 — 20만 자면 서버가 받는 한 번의 크기(512KiB)를 넘는다.
    final huge = '가' * 200000;
    expect(fitsSocketMessage({'text': huge}), isFalse);
    await expectLater(
      session.chatSocket.send(roomId: 'chat', type: 'text', text: huge),
      throwsA(isA<MessageSendException>()),
    );
    expect(called, isFalse);
    // 상한 안의 큰 글(한글 2만 자 = 6만 바이트)은 그대로 보낸다.
    await session.chatSocket.send(roomId: 'chat', type: 'text', text: '가' * 20000);
    expect(called, isTrue);
  });
}
