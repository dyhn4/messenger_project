import 'dart:convert';

import 'package:client/models/app_user.dart';
import 'package:client/models/message.dart';
import 'package:client/models/message_reminder.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/message_reminders.dart';
import 'package:client/widgets/reminders_panel.dart';
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
        if (request.method == 'POST' && path == '/api/reminders') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final created = {
            'id': 'memo-new',
            'messageId': null,
            'roomId': null,
            'teamId': body['teamId'],
            'text': body['text'],
            'remindAt': body['remindAt'],
            'createdAt': 0,
          };
          pending = [...pending, created];
          return http.Response(jsonEncode(created), 201, headers: jsonHeaders);
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
    final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
    session.teams.add(team);
    session.currentTeam = team;
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

  testWidgets('"나중에 알림": 날짜·시간 직접 고르기는 방해 금지 "지정"과 같은 달력·시간 칸을 펼쳐 고른 시각으로 건다', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    expect(find.byKey(const ValueKey('reminder-custom-panel')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('reminder-custom')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reminder-custom-panel')), findsOneWidget);
    expect(find.text('언제 다시 알려 드릴까요?'), findsOneWidget);
    expect(requests, isEmpty, reason: '펼치기만 해서는 걸지 않는다');

    // 내일(다음 달이면 › 로 넘겨서) → 알림 시간 오후 6:00.
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    if (tomorrow.month != now.month) {
      await tester.tap(find.byKey(const ValueKey('reminder-period-next')));
      await tester.pumpAndSettle();
    }
    await tester.tap(
      find.byKey(
        ValueKey(
          'reminder-period-day-${tomorrow.year}-${tomorrow.month}-${tomorrow.day}',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reminder-time-end')));
    await tester.pumpAndSettle();
    final option = find.byKey(const ValueKey('reminder-time-option-1080'));
    final timeList = find.descendant(
      of: find.byKey(const ValueKey('reminder-time-list')),
      matching: find.byType(Scrollable),
    );
    // 목록은 지금 값(1시간 뒤) 자리로 스크롤해 열린다 — 오후 5시 넘어 돌리면 6:00이 그보다 위라 먼저 맨 위로 올린다.
    await tester.drag(timeList, const Offset(0, 10000));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(option, 72, scrollable: timeList);
    await tester.ensureVisible(option);
    await tester.pumpAndSettle();
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(requests, isEmpty);

    final expected = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 18);
    await tester.tap(find.byKey(const ValueKey('reminder-custom-confirm')));
    await tester.pumpAndSettle();
    final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(
      DateTime.fromMillisecondsSinceEpoch(body['remindAt'] as int),
      expected,
    );
    expect(find.text('나중에 알림'), findsNothing, reason: '창이 닫힌다');
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

  /// 리마인더 패널을 화면에 띄운다(모바일처럼 홈 셸 없이).
  Future<void> pumpPanel(WidgetTester tester, Session session) async {
    tester.view.physicalSize = const Size(600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RemindersPanel(session: session)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('리마인더 패널: 직접 만든 것과 메시지 리마인더가 울릴 시각 순으로 카드로 보이고, ✕로 취소한다', (
    tester,
  ) async {
    final session = buildSession();
    pending = [
      {
        'id': 'memo-1',
        'messageId': null,
        'roomId': null,
        'teamId': 't1',
        'text': '15시 회의 자료 보내기',
        'remindAt': DateTime(2026, 10, 15, 8).millisecondsSinceEpoch,
        'createdAt': 0,
      },
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
    await pumpPanel(tester, session);
    expect(find.text('리마인더'), findsOneWidget);
    expect(find.byKey(const ValueKey('reminder-create')), findsOneWidget);
    expect(find.textContaining('2개의 리마인더', findRichText: true), findsOneWidget);

    final memo = find.byKey(const ValueKey('reminder-memo-1'));
    final message = find.byKey(const ValueKey('reminder-rem-1'));
    expect(
      tester.getTopLeft(memo).dy,
      lessThan(tester.getTopLeft(message).dy),
      reason: '울릴 시각 순',
    );
    expect(
      find.descendant(of: memo, matching: find.text('15시 회의 자료 보내기')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: memo, matching: find.text('직접 만든 리마인더')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: memo, matching: find.text('10/15(목) 08:00')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: message, matching: find.text('배너 시안 확인 부탁드려요')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: message, matching: find.text('마케팅 팀')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: message, matching: find.text(' · Sam')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('reminder-cancel-rem-1')));
    await tester.pumpAndSettle();
    expect(requests.last.method, 'DELETE');
    expect(requests.last.url.path, '/api/reminders/rem-1');
    expect(message, findsNothing);
    expect(memo, findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('리마인더 패널: 걸어 둔 것이 없으면 안내를 보인다', (tester) async {
    await pumpPanel(tester, buildSession());
    expect(find.byKey(const ValueKey('reminder-empty')), findsOneWidget);
  });

  testWidgets(
    '리마인더 생성: 글과 언제(기본 1시간 뒤)를 고르고 [생성]하면 지금 팀의 나와의 대화로 거는 리마인더를 만든다',
    (tester) async {
      final session = buildSession();
      await pumpPanel(tester, session);
      await tester.tap(find.byKey(const ValueKey('reminder-create')));
      await tester.pumpAndSettle();

      FilledButton save() => tester.widget<FilledButton>(
        find.byKey(const ValueKey('reminder-new-save')),
      );
      expect(save().onPressed, isNull, reason: '글이 없으면 만들 수 없다');
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('reminder-new-preset-1시간 뒤')),
            )
            .selected,
        isTrue,
      );

      await tester.enterText(
        find.byKey(const ValueKey('reminder-new-text')),
        '  15시 회의 자료 보내기  ',
      );
      await tester.tap(
        find.byKey(const ValueKey('reminder-new-preset-내일 오전 9시')),
      );
      await tester.pump();
      final now = DateTime.now();
      final tomorrow9 = DateTime(now.year, now.month, now.day + 1, 9);
      expect(
        find.text('${reminderTimeLabel(tomorrow9)}에 "나와의 대화"로 알려 드립니다.'),
        findsOneWidget,
      );
      expect(save().onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('reminder-new-save')));
      await tester.pumpAndSettle();

      final post = requests.firstWhere((r) => r.method == 'POST');
      expect(post.url.path, '/api/reminders');
      final body = jsonDecode(post.body) as Map<String, dynamic>;
      expect(body['text'], '15시 회의 자료 보내기');
      expect(body['teamId'], 't1');
      expect(
        DateTime.fromMillisecondsSinceEpoch(body['remindAt'] as int),
        tomorrow9,
      );
      expect(
        find.byKey(const ValueKey('reminder-new-save')),
        findsNothing,
        reason: '창이 닫힌다',
      );
      // 만든 뒤 목록을 다시 받아 새 카드가 보인다.
      expect(find.byKey(const ValueKey('reminder-memo-new')), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets('리마인더 생성: 지정을 고르면 달력·시간 칸이 펼쳐진다', (tester) async {
    final session = buildSession();
    await pumpPanel(tester, session);
    await tester.tap(find.byKey(const ValueKey('reminder-create')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reminder-new-custom-panel')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('reminder-new-custom')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reminder-new-custom-panel')),
      findsOneWidget,
    );
    expect(find.text('알림 시간'), findsOneWidget);
  });
}
