// 음성으로 참여(카메라 끔) — 대화방 입력줄의 화상회의 단추가 "화상으로 / 음성으로" 메뉴를 열고, 진행 중인 통화 카드에도 음성 참여
// 단추가 있다. 고른 것이 Session.joinCall(camera:)로 그대로 가는지 본다(실제 LiveKit 연결은 하지 않는다).
import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/call_button.dart';
import 'package:client/widgets/call_message_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

/// joinCall이 받은 camera 값을 기록하고, 통화 화면까지 가지 않게 실패로 끝낸다(단추는 토스트만 띄운다).
class _RecordingSession extends Session {
  _RecordingSession()
    : super(notifications: _QuietNotifications(), settings: AppSettings());

  final joins = <bool>[];

  @override
  Future<void> joinCall(String roomId, {bool camera = true}) async {
    joins.add(camera);
    throw Exception('시험');
  }
}

final _room = Room.fromJson({
  'id': 'r1',
  'teamId': 't1',
  'type': 'group',
  'name': '영업팀 회의',
  'members': [],
  'createdAt': 1000,
});

_RecordingSession _session() => _RecordingSession()
  ..userId = 'me'
  ..callsEnabled = true;

void main() {
  testWidgets('화상회의 단추 — 메뉴에서 "음성으로 시작"을 고르면 카메라를 끈 채 들어간다', (tester) async {
    final session = _session();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CallButton(session: session, room: _room),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('call-button')));
    await tester.pumpAndSettle();
    expect(find.text('화상으로 시작'), findsOneWidget);
    expect(find.text('음성으로 시작(카메라 끔)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('call-with-voice')));
    await tester.pumpAndSettle();
    expect(session.joins, [false]);

    await tester.tap(find.byKey(const ValueKey('call-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('call-with-video')));
    await tester.pumpAndSettle();
    expect(session.joins, [false, true]);
    await tester.pump(const Duration(seconds: 5)); // 실패 토스트가 사라지도록.
  });

  testWidgets('진행 중인 통화 카드 — 마이크 단추는 음성으로, [참여]는 화상으로', (tester) async {
    final session = _session();
    final startedAt = DateTime.now().subtract(const Duration(minutes: 3));
    final message = Message.fromJson({
      'id': 'm1',
      'roomId': 'r1',
      'senderId': null,
      'senderName': '시스템',
      'type': 'system',
      'text': '화상회의',
      'createdAt': startedAt.millisecondsSinceEpoch,
      'callCard': {
        'status': 'active',
        'startedAt': startedAt.millisecondsSinceEpoch,
        'endedAt': null,
        'durationMs': null,
        'answered': false,
        'events': [
          {
            'at': startedAt.millisecondsSinceEpoch,
            'userId': 'a',
            'name': '김철수',
            'kind': 'start',
          },
        ],
      },
    });
    expect(message.callCard?.active, isTrue);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CallMessageCard(
            session: session,
            room: _room,
            message: message,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('call-card-join-voice')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('call-card-join')));
    await tester.pumpAndSettle();
    expect(session.joins, [false, true]);
    await tester.pump(const Duration(seconds: 5));
  });
}
