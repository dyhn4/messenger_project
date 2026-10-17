import 'dart:convert';
import 'dart:io';

import 'package:client/models/app_user.dart';
import 'package:client/models/message.dart';
import 'package:client/models/message_reaction.dart';
import 'package:client/models/room.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/message_actions.dart';
import 'package:client/widgets/message_bubble.dart';
import 'package:client/widgets/message_reactions.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 메시지 공감(이모지 반응) — 한 사람 하나(같은 것을 다시 누르면 빠짐), 서버 답 전에 먼저 보이고 실패하면 되돌림, PC는 말풍선
/// 툴바의 공감 메뉴, 휴대폰은 길게 누른 시트 맨 위의 고르는 줄. 비밀 대화에는 공감이 없다.
void main() {
  const serverUrl = 'https://192.168.0.10:3000';
  const jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

  group('공감 목록 다루기', () {
    final base = [
      const MessageReaction(emoji: '👍', userIds: ['u2', 'u1']),
      const MessageReaction(emoji: '✅', userIds: ['u3']),
    ];

    test('서버 모양을 읽고, 모양이 틀리거나 비어 있는 항목은 뺀다', () {
      final parsed = parseReactions([
        {
          'emoji': '❤️',
          'userIds': ['u1', 'u2'],
        },
        {'emoji': '😂', 'userIds': []},
        {'emoji': 3},
        'x',
      ]);
      expect(parsed, hasLength(1));
      expect(parsed.single.emoji, '❤️');
      expect(parsed.single.count, 2);
      expect(parseReactions(null), isEmpty);
      expect(
        Message.fromJson({
          'id': 'm',
          'roomId': 'r',
          'senderName': 'a',
          'type': 'text',
          'createdAt': 0,
        }).reactions,
        isEmpty,
        reason: '공감을 싣지 않은 DTO(수정 브로드캐스트 등)는 빈 목록',
      );
    });

    test('내 공감 찾기·바꾸기·빼기 — 한 사람 하나, 정해 둔 순서', () {
      expect(myReaction(base, 'u1'), '👍');
      expect(myReaction(base, 'u9'), isNull);
      expect(myReaction(base, null), isNull);

      final switched = reactionsWith(base, 'u1', '✅');
      expect(switched.map((r) => r.emoji), ['👍', '✅']);
      expect(switched[0].userIds, ['u2']);
      expect(switched[1].userIds, ['u3', 'u1'], reason: '바꾼 사람은 그 이모지의 맨 뒤');

      final removed = reactionsWith(base, 'u3', null);
      expect(removed.map((r) => r.emoji), ['👍'], reason: '아무도 없는 이모지는 빠진다');

      final added = reactionsWith(base, 'u4', '❤️');
      expect(added.map((r) => r.emoji), ['👍', '❤️', '✅']);

      expect(sameReactions(base, reactionsWith(base, 'u9', null)), isTrue);
      expect(sameReactions(base, switched), isFalse);
    });
  });

  late List<http.Request> requests;
  late http.Response Function(http.Request) respond;

  Session buildSession({bool secret = false}) {
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.serverUrl = serverUrl;
    session.api = ApiClient(
      baseUrl: serverUrl,
      token: 't',
      httpClient: MockClient((request) async {
        requests.add(request);
        return respond(request);
      }),
    );
    session.userId = 'u1';
    session.name = 'Riley';
    session.rooms.add(
      Room(
        id: 'r1',
        teamId: 't1',
        type: secret ? RoomType.dm : RoomType.topic,
        name: '마케팅 팀',
        members: [
          AppUser(id: 'u1', username: 'u1', name: 'Riley'),
          AppUser(id: 'u2', username: 'u2', name: 'Sam'),
        ],
        createdAt: DateTime(2026),
        lastRead: const {},
        isSecret: secret,
      ),
    );
    return session;
  }

  Message message({List<MessageReaction> reactions = const []}) => Message(
    id: 'm1',
    roomId: 'r1',
    senderId: 'u2',
    senderName: 'Sam',
    type: MessageType.text,
    text: '배너 시안 올렸습니다',
    createdAt: DateTime(2026, 10, 14, 9),
    reactions: reactions,
  );

  setUp(() {
    requests = [];
    respond = (request) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final emoji = body['emoji'] as String?;
      return http.Response(
        jsonEncode({
          'messageId': 'm1',
          'reactions': [
            {
              'emoji': '👍',
              'userIds': ['u2'],
            },
            if (emoji != null)
              {
                'emoji': emoji,
                'userIds': ['u1'],
              },
          ],
        }),
        200,
        headers: jsonHeaders,
      );
    };
  });

  Future<void> pumpBubble(
    WidgetTester tester,
    Session session,
    Message m,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            // 실제 화면은 방 컨트롤러를 듣고 다시 그린다 — 시험에서는 매 프레임 다시 그려 같은 효과를 낸다.
            builder: (context, setState) => SingleChildScrollView(
              child: MessageBubble(
                key: const ValueKey('bubble'),
                session: session,
                message: m,
                resolveUrl: (u) => u,
                isMine: false,
                onOpenThread: (_) {},
                onEdit: (_, _, {format, mentions}) async {},
                onDelete: (_) async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> lastBody() =>
      jsonDecode(requests.last.body) as Map<String, dynamic>;

  testWidgets('말풍선 아래에 공감 줄 — 내 공감은 다시 누르면 빼고, 남의 공감을 누르면 그것으로 바꾼다', (
    tester,
  ) async {
    final session = buildSession();
    final m = message(
      reactions: const [
        MessageReaction(emoji: '👍', userIds: ['u2']),
        MessageReaction(emoji: '✅', userIds: ['u1']),
      ],
    );
    await pumpBubble(tester, session, m);
    expect(find.byKey(const ValueKey('reaction-👍')), findsOneWidget);
    expect(find.text('👍 1', findRichText: true), findsOneWidget);
    expect(find.text('✅ 1', findRichText: true), findsOneWidget);

    // 내 공감(✅)을 다시 누르면 뺀다.
    await tester.tap(find.byKey(const ValueKey('reaction-✅')));
    await tester.pumpAndSettle();
    expect(requests.single.url.path, '/api/messages/m1/reaction');
    expect(requests.single.method, 'PUT');
    expect(lastBody(), {'emoji': null});
    expect(m.reactions.map((r) => r.emoji), ['👍']);

    // 남의 공감(👍)을 누르면 내 공감이 그것으로.
    respond = (request) => http.Response(
      jsonEncode({
        'messageId': 'm1',
        'reactions': [
          {
            'emoji': '👍',
            'userIds': ['u2', 'u1'],
          },
        ],
      }),
      200,
      headers: jsonHeaders,
    );
    await tester.tap(find.byKey(const ValueKey('reaction-👍')));
    await tester.pumpAndSettle();
    expect(lastBody(), {'emoji': '👍'});
    expect(m.reactions.single.userIds, ['u2', 'u1']);
  });

  testWidgets('서버가 거절하면 원래대로 되돌리고 알린다', (tester) async {
    final session = buildSession();
    final m = message(
      reactions: const [
        MessageReaction(emoji: '👍', userIds: ['u2']),
      ],
    );
    respond = (_) => http.Response(
      jsonEncode({'error': '메시지를 찾을 수 없습니다.'}),
      404,
      headers: jsonHeaders,
    );
    await pumpBubble(tester, session, m);
    await tester.tap(find.byKey(const ValueKey('reaction-👍')));
    await tester.pumpAndSettle();
    expect(m.reactions.single.userIds, ['u2']);
    expect(find.textContaining('공감을 남기지 못했습니다'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('PC: 말풍선에 마우스를 올리면 툴바의 공감 메뉴에서 고른다', (tester) async {
    final session = buildSession();
    final m = message();
    await pumpBubble(tester, session, m);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('배너 시안 올렸습니다')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('toolbar-reaction')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pick-reaction-😂')));
    await tester.pumpAndSettle();
    expect(lastBody(), {'emoji': '😂'});
    expect(m.reactions.map((r) => r.emoji), ['👍', '😂']);
    expect(
      find.byKey(const ValueKey('pick-reaction-😂')),
      findsNothing,
      reason: '고르면 메뉴가 닫힌다',
    );
  });

  testWidgets('휴대폰: 길게 누른 시트 맨 위의 고르는 줄로 공감한다', (tester) async {
    final session = buildSession();
    final m = message();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMessageActionSheet(
                context,
                session: session,
                message: m,
                senderDisplayName: 'Sam',
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sheet-reaction-picker')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pick-reaction-❤️')));
    await tester.pumpAndSettle();
    expect(lastBody(), {'emoji': '❤️'});
    expect(find.text('복사'), findsNothing, reason: '고르면 시트가 닫힌다');
  });

  testWidgets('비밀 대화에는 공감 버튼·고르는 줄이 없다', (tester) async {
    final session = buildSession(secret: true);
    final m = message();
    await pumpBubble(tester, session, m);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('배너 시안 올렸습니다')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.add_reaction_outlined), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMessageActionSheet(
                context,
                session: session,
                message: m,
                senderDisplayName: 'Sam',
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sheet-reaction-picker')), findsNothing);
    expect(requests, isEmpty);
  });

  group('고를 수 있는 공감(48개)', () {
    test('서버 reactionRules.js의 목록과 글자 하나까지·순서까지 같다', () {
      final source = File('../server/src/reactionRules.js').readAsStringSync();
      final block = RegExp(
        r'REACTION_EMOJIS = Object\.freeze\(\[([\s\S]*?)\]\)',
      ).firstMatch(source)!.group(1)!;
      final server = [
        for (final m in RegExp(r"'([^']+)'").allMatches(block)) m.group(1)!,
      ];
      expect(reactionEmojis, server);
      expect(reactionEmojis.toSet(), hasLength(48));
      final quick = RegExp(
        r'QUICK_REACTION_COUNT = (\d+)',
      ).firstMatch(source)!.group(1);
      expect(quickReactionCount, int.parse(quick!));
    });

    testWidgets('고르는 줄은 자주 쓰는 여섯 개 + "+", 누르면 나머지가 펼쳐진다', (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ReactionPicker(selected: null, onPicked: picked.add),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('pick-reaction-👍')), findsOneWidget);
      expect(find.byKey(const ValueKey('pick-reaction-🔥')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('pick-reaction-more')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('reaction-picker-grid')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('pick-reaction-🔥')));
      expect(picked, ['🔥']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('내 공감이 펼친 쪽에 있으면 처음부터 펼쳐 둔다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ReactionPicker(selected: '🚀', onPicked: (_) {}),
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('reaction-picker-grid')),
        findsOneWidget,
      );
    });

    test('펼친 쪽 이모지도 정해 둔 순서로 놓인다', () {
      final next = reactionsWith(
        [
          const MessageReaction(emoji: '🚀', userIds: ['u2']),
        ],
        'u1',
        '👍',
      );
      expect(next.map((r) => r.emoji), ['👍', '🚀']);
    });
  });
}
