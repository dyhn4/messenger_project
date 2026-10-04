import 'package:client/models/call_card.dart';
import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/call_message_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 화상회의 기록 카드 — 통화 한 통에 대화방 카드 한 장(시작·참여·거절·나감을 펼쳐 본다). 서버 callCards.js가 만든
/// call_card를 그대로 받아 그리는지만 본다.

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

Session _session({bool callsEnabled = true}) {
  final s = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  s.userId = 'me';
  s.callsEnabled = callsEnabled;
  return s;
}

final _room = Room.fromJson({
  'id': 'r1',
  'teamId': 't1',
  'type': 'group',
  'name': '영업팀 회의',
  'members': [],
  'createdAt': 1000,
});

int _ms(DateTime t) => t.millisecondsSinceEpoch;

Map<String, dynamic> _event(DateTime at, String id, String name, String kind) =>
    {'at': _ms(at), 'userId': id, 'name': name, 'kind': kind};

Message _message(Map<String, dynamic> card) => Message.fromJson({
  'id': 'm1',
  'roomId': 'r1',
  'senderId': null,
  'senderName': '시스템',
  'type': 'system',
  'text': '화상회의',
  'createdAt': card['startedAt'],
  'callCard': card,
});

Future<void> _pump(WidgetTester tester, Session session, Message m) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CallMessageCard(session: session, room: _room, message: m),
      ),
    ),
  );
}

void main() {
  final t0 = DateTime.now().subtract(const Duration(minutes: 12));

  Map<String, dynamic> activeCard() => {
    'status': 'active',
    'startedAt': _ms(t0),
    'endedAt': null,
    'durationMs': null,
    'answered': false,
    'events': [
      _event(t0, 'a', '김철수', 'start'),
      _event(t0.add(const Duration(minutes: 1)), 'b', '이영희', 'join'),
      _event(t0.add(const Duration(minutes: 1)), 'c', '박민수', 'decline'),
    ],
  };

  testWidgets('진행 중: 요약 한 줄과 [참여], 누르면 시간순 기록이 펼쳐진다', (tester) async {
    await _pump(tester, _session(), _message(activeCard()));
    expect(find.text('화상회의 진행 중 · 12분'), findsOneWidget);
    expect(find.textContaining('김철수 시작 · 참여 2명 · 거절 1명'), findsOneWidget);
    expect(find.byKey(const ValueKey('call-card-join')), findsOneWidget);
    expect(find.text('참여'), findsOneWidget);
    // 접혀 있을 때는 기록이 안 보인다.
    expect(find.text('거절'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('call-card-toggle')));
    await tester.pump();
    expect(find.text('시작'), findsOneWidget);
    expect(find.text('거절'), findsOneWidget);
    expect(find.text('박민수'), findsOneWidget);
    expect(find.text('통화 종료'), findsNothing);
  });

  testWidgets('끝난 통화: 종료 · 길이, [참여] 없음, 기록 끝에 통화 종료', (tester) async {
    final card = activeCard()
      ..['status'] = 'ended'
      ..['answered'] = true
      ..['durationMs'] = const Duration(minutes: 18).inMilliseconds
      ..['endedAt'] = _ms(t0.add(const Duration(minutes: 18)));
    (card['events'] as List).add(
      _event(t0.add(const Duration(minutes: 18)), 'b', '이영희', 'leave'),
    );
    await _pump(tester, _session(), _message(card));
    expect(find.text('화상회의 종료 · 18분'), findsOneWidget);
    expect(find.byKey(const ValueKey('call-card-join')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('call-card-toggle')));
    await tester.pump();
    expect(find.text('나감'), findsOneWidget);
    expect(find.text('통화 종료'), findsOneWidget);
  });

  testWidgets('아무도 안 받았으면 부재중', (tester) async {
    final card = {
      'status': 'ended',
      'startedAt': _ms(t0),
      'endedAt': _ms(t0.add(const Duration(seconds: 40))),
      'durationMs': 40000,
      'answered': false,
      'events': [_event(t0, 'a', '김철수', 'start')],
    };
    await _pump(tester, _session(), _message(card));
    expect(find.text('부재중 화상회의'), findsOneWidget);
    expect(find.byIcon(Icons.missed_video_call), findsOneWidget);
  });

  testWidgets('화상회의를 못 쓰는 서버면 [참여]가 없다', (tester) async {
    await _pump(tester, _session(callsEnabled: false), _message(activeCard()));
    expect(find.byKey(const ValueKey('call-card-join')), findsNothing);
  });

  test('카드 집계 — 같은 사람이 다시 들어와도 한 번', () {
    final card = CallCard.fromJson({
      ...activeCard(),
      'events': [
        ...activeCard()['events'] as List,
        _event(t0, 'b', '이영희', 'leave'),
        _event(t0, 'b', '이영희', 'join'),
        _event(t0, 'c', '박민수', 'decline'),
      ],
    })!;
    expect(card.joinedCount, 2);
    expect(card.declinedCount, 1);
    expect(card.starterName, '김철수');
  });

  test('통화 길이 표시', () {
    expect(formatCallDuration(const Duration(seconds: 42)), '42초');
    expect(formatCallDuration(const Duration(minutes: 5)), '5분');
    expect(formatCallDuration(const Duration(minutes: 63)), '1시간 3분');
    expect(formatCallDuration(const Duration(hours: 2)), '2시간');
  });
}
