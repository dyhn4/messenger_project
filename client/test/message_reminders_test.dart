import 'dart:convert';

import 'package:client/models/app_user.dart';
import 'package:client/models/message.dart';
import 'package:client/models/message_reminder.dart';
import 'package:client/models/room.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/message_reminders.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 메시지 리마인더("나중에 알림") — 빠른 선택지 시각, 걸기(POST), 울렸을 때의 카드, 걸어 둔 목록과 취소(DELETE).
void main() {
  const jsonHeaders = {'content-type': 'application/json; charset=utf-8'};
  late List<http.Request> requests;
  late List<Map<String, dynamic>> pending;

  Session buildSession() {
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.serverUrl = 'https://192.168.0.10:3000';
    session.api = ApiClient(
      baseUrl: 'https://192.168.0.10:3000',
      token: 't',
      httpClient: MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        if (request.method == 'POST' && path == '/api/messages/m1/reminders') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'id': 'rem-new',
              'messageId': 'm1',
              'roomId': 'r1',
              'remindAt': body['remindAt'],
              'createdAt': 0,
            }),
            201,
            headers: jsonHeaders,
          );
        }
        if (request.method == 'GET' && path == '/api/reminders') {
          return http.Response(jsonEncode(pending), 200, headers: jsonHeaders);
        }
        if (request.method == 'DELETE' && path.startsWith('/api/reminders/')) {
          return http.Response('{"ok":true}', 200, headers: jsonHeaders);
        }
        return http.Response('{}', 404, headers: jsonHeaders);
      }),
    );
    session.userId = 'u1';
    session.rooms.add(
      Room(
        id: 'r1',
        teamId: 't1',
        type: RoomType.topic,
        name: '마케팅 팀',
        members: [AppUser(id: 'u1', username: 'u1', name: 'Riley')],
        createdAt: DateTime(2026),
        lastRead: const {},
      ),
    );
    return session;
  }

  setUp(() {
    requests = [];
    pending = [];
  });

  test('빠른 선택지: 20분·1시간·3시간 뒤, 내일 오전 9시, 다음 주 월요일 오전 9시', () {
    final now = DateTime(2026, 10, 14, 15, 30); // 수요일
    final presets = reminderPresets(now);
    expect(presets.map((p) => p.label), [
      '20분 뒤',
      '1시간 뒤',
      '3시간 뒤',
      '내일 오전 9시',
      '다음 주 월요일 오전 9시',
    ]);
    expect(presets[0].at, DateTime(2026, 10, 14, 15, 50));
    expect(presets[3].at, DateTime(2026, 10, 15, 9));
    expect(presets[4].at, DateTime(2026, 10, 19, 9));
    expect(
      reminderPresets(DateTime(2026, 10, 19, 8))[4].at,
      DateTime(2026, 10, 26, 9),
      reason: '월요일이면 다음 주 월요일',
    );
    expect(reminderTimeLabel(DateTime(2026, 10, 15, 9)), '10/15(목) 09:00');
  });

  test('카드·목록 모양 읽기', () {
    final card = ReminderCard.fromJson({
      'messageId': 'm1',
      'roomId': 'r1',
      'roomName': null,
      'senderName': 'Sam',
      'preview': '배너 시안',
      'sentAt': 0,
      'secret': false,
    })!;
    expect(card.preview, '배너 시안');
    expect(ReminderCard.fromJson({'roomId': 'r1'}), isNull);
    final msg = Message.fromJson({
      'id': 'b1',
      'roomId': 'self',
      'senderName': '탱고톡',
      'type': 'text',
      'text': '⏰ 리마인더 — Sam: 배너 시안',
      'createdAt': 0,
      'reminderCard': {'messageId': 'm1', 'roomId': 'r1'},
    });
    expect(msg.reminderCard?.messageId, 'm1');
  });

  testWidgets('"나중에 알림": 빠른 선택지를 고르면 그 시각으로 리마인더를 건다', (tester) async {
    final session = buildSession();
    final message = Message(
      id: 'm1',
      roomId: 'r1',
      senderId: 'u2',
      senderName: 'Sam',
      type: MessageType.text,
      text: '배너 시안 확인 부탁드려요',
      createdAt: DateTime(2026, 10, 14, 9),
    );
    expect(canRemindMessage(message), isTrue);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showReminderPicker(context, session, message),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    final before = DateTime.now();
    await tester.tap(find.byKey(const ValueKey('reminder-preset-1시간 뒤')));
    await tester.pumpAndSettle();
    final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
    final at = DateTime.fromMillisecondsSinceEpoch(body['remindAt'] as int);
    expect(at.difference(before).inMinutes, inInclusiveRange(59, 60));
    expect(find.textContaining('알려 드릴게요'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('울렸을 때의 카드: 방 이름·보낸 사람·미리보기와 메시지로 이동, 비밀 대화는 내용 없이', (
    tester,
  ) async {
    final session = buildSession();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ReminderCardView(
                session: session,
                card: const ReminderCard(
                  messageId: 'm1',
                  roomId: 'r1',
                  senderName: 'Sam',
                  preview: '배너 시안 확인 부탁드려요',
                ),
              ),
              ReminderCardView(
                session: session,
                card: const ReminderCard(
                  messageId: 'm2',
                  roomId: 'gone',
                  senderName: 'Lee',
                  secret: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.textContaining('마케팅 팀 · Sam'), findsOneWidget);
    expect(find.text('배너 시안 확인 부탁드려요'), findsOneWidget);
    expect(find.text('🔒 비밀 대화 메시지'), findsOneWidget);
    // 더 이상 참여하지 않는 방이면 알린다.
    await tester.tap(find.byKey(const ValueKey('reminder-open')).last);
    await tester.pump();
    expect(find.text('이 대화방에 더 이상 참여하고 있지 않습니다.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('리마인더 목록: 울릴 시각 순으로 보이고, 취소하면 지운다', (tester) async {
    final session = buildSession();
    pending = [
      {
        'id': 'rem-1',
        'messageId': 'm1',
        'roomId': 'r1',
        'remindAt': DateTime(2026, 10, 15, 9).millisecondsSinceEpoch,
        'createdAt': 0,
        'senderName': 'Sam',
        'preview': '배너 시안 확인 부탁드려요',
      },
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showRemindersDialog(context, session),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(find.text('배너 시안 확인 부탁드려요'), findsOneWidget);
    expect(find.textContaining('10/15(목) 09:00 · 마케팅 팀 · Sam'), findsOneWidget);
    await tester.tap(find.byTooltip('취소'));
    await tester.pumpAndSettle();
    expect(requests.last.method, 'DELETE');
    expect(requests.last.url.path, '/api/reminders/rem-1');
    expect(find.text('배너 시안 확인 부탁드려요'), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });
}
