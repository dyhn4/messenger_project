// 대화형 봇 메시지 — 블록 읽기(모르는 것 건너뛰기), 말풍선이 글 대신 블록을 그리기(머리글·칸·문맥·단추·선택지), 단추·선택지를 누르면
// 서버에 알리고 나에게만 보일 답은 창으로, 링크 단추는 서버 없이 그 주소를 열기, 실패하면 안내, 수정 소식(message:edited)으로 블록 바꾸기.
// 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/bot_blocks.dart';
import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/bot_blocks_view.dart';
import 'package:client/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Session _session(
  List<http.Request> requests,
  http.Response Function(http.Request) handler,
) {
  final session = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: MockClient((request) async {
      requests.add(request);
      return handler(request);
    }),
  );
  session.userId = 'me';
  session.name = '나';
  final team = Team(id: 't1', name: '개발팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.add(
    Room.fromJson({
      'id': 'r1',
      'teamId': 't1',
      'type': 'group',
      'name': '운영',
      'members': [
        {'id': 'me', 'username': 'me', 'name': '나', 'role': 'member'},
      ],
      'createdAt': 1000,
    }),
  );
  return session;
}

final _blocks = [
  {'type': 'header', 'text': '휴가 승인 요청'},
  {
    'type': 'section',
    'text': '홍길동 님의 연차',
    'fields': ['기간: 3/2~3/4', '사유: 가족 행사'],
    'accessory': null,
  },
  {'type': 'divider'},
  {
    'type': 'actions',
    'blockId': 'b1',
    'elements': [
      {
        'type': 'button',
        'actionId': 'approve',
        'text': '승인',
        'value': 'r1',
        'url': null,
        'style': 'primary',
      },
      {
        'type': 'button',
        'actionId': 'reject',
        'text': '반려',
        'value': 'r1',
        'url': null,
        'style': 'danger',
      },
      {
        'type': 'button',
        'actionId': 'open',
        'text': '신청서',
        'value': null,
        'url': 'https://hr.example/r/1',
        'style': null,
      },
      {
        'type': 'select',
        'actionId': 'delegate',
        'placeholder': '대결자',
        'options': [
          {'text': '김가', 'value': 'u1'},
          {'text': '이나', 'value': 'u2'},
        ],
        'initial': null,
      },
    ],
  },
  {'type': 'context', 'text': '인사팀 봇'},
  {'type': 'video', 'url': 'x'},
];

Map<String, dynamic> _botJson({List<Object?>? blocks}) => {
  'id': 'm1',
  'roomId': 'r1',
  'senderId': null,
  'senderName': '인사봇',
  'type': 'text',
  'text': '휴가 승인 요청 [승인] [반려]',
  'createdAt': DateTime(2026, 10, 1).millisecondsSinceEpoch,
  'bot': {'integrationId': 'i1', 'emoji': '🗓️'},
  'blocks': blocks ?? _blocks,
};

Future<void> _pumpBubble(
  WidgetTester tester,
  Session session,
  Message m,
) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MessageBubble(
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
  );
  await tester.pumpAndSettle();
}

void main() {
  test('블록 읽기 — 아는 블록·요소만, 비면 null', () {
    final m = Message.fromJson(_botJson());
    final blocks = m.blocks!;
    expect(blocks.length, 5, reason: '모르는 video 블록은 건너뛴다');
    expect(blocks.first, isA<BotHeaderBlock>());
    final actions = blocks[3] as BotActionsBlock;
    expect(actions.elements.length, 4);
    final open = actions.elements[2] as BotButton;
    expect(open.isLink, isTrue);
    expect((actions.elements[0] as BotButton).style, BotButtonStyle.primary);
    expect((actions.elements[3] as BotSelect).options.map((o) => o.value), [
      'u1',
      'u2',
    ]);
    expect(BotBlock.listFromJson(const []), isNull);
    expect(BotBlock.listFromJson(null), isNull);
    expect(Message.fromJson(_botJson(blocks: [])).blocks, isNull);
  });

  testWidgets('말풍선은 글 대신 블록을 그리고, 단추를 누르면 서버에 알리고 나에게만 보일 답을 창으로', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final session = _session(
      requests,
      (_) => _json({'ephemeral': '이미 처리된 요청입니다.'}),
    );
    await _pumpBubble(tester, session, Message.fromJson(_botJson()));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('bot-blocks')), findsOneWidget);
    expect(find.text('휴가 승인 요청'), findsOneWidget);
    expect(find.text('기간: 3/2~3/4'), findsOneWidget);
    expect(find.text('인사팀 봇'), findsOneWidget);
    expect(
      find.text('휴가 승인 요청 [승인] [반려]'),
      findsNothing,
      reason: '대체 글은 그리지 않는다',
    );

    await tester.tap(find.byKey(const ValueKey('bot-action-approve')));
    await tester.pumpAndSettle();
    expect(requests.single.url.path, '/api/messages/m1/actions');
    expect(jsonDecode(requests.single.body), {'actionId': 'approve'});
    expect(find.byKey(const ValueKey('bot-reply-dialog')), findsOneWidget);
    expect(find.text('이미 처리된 요청입니다.'), findsOneWidget);
  });

  testWidgets('선택지는 고른 값과 함께, 링크 단추는 서버 없이 주소를 연다', (tester) async {
    final requests = <http.Request>[];
    final opened = <String>[];
    final previous = BotBlocksView.openLink;
    BotBlocksView.openLink = (url) async => opened.add(url);
    addTearDown(() => BotBlocksView.openLink = previous);
    final session = _session(requests, (_) => _json({'updated': true}));
    await _pumpBubble(tester, session, Message.fromJson(_botJson()));

    await tester.tap(find.byKey(const ValueKey('bot-action-open')));
    await tester.pumpAndSettle();
    expect(opened, ['https://hr.example/r/1']);
    expect(requests, isEmpty);

    await tester.tap(find.byKey(const ValueKey('bot-action-delegate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bot-option-delegate-u2')));
    await tester.pumpAndSettle();
    expect(jsonDecode(requests.single.body), {
      'actionId': 'delegate',
      'value': 'u2',
    });
    expect(find.text('이나'), findsOneWidget, reason: '고른 것을 보여 준다');
    expect(find.byKey(const ValueKey('bot-reply-dialog')), findsNothing);
  });

  testWidgets('서버가 거절하면 안내하고, 다시 누를 수 있다', (tester) async {
    final requests = <http.Request>[];
    final session = _session(
      requests,
      (_) => _json({
        'error': '이 메시지의 단추를 받을 곳이 없습니다(연동에 응답 주소가 없습니다).',
      }, status: 400),
    );
    await _pumpBubble(tester, session, Message.fromJson(_botJson()));
    await tester.tap(find.byKey(const ValueKey('bot-action-reject')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('단추를 처리하지 못했습니다'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    final button = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('bot-action-reject')),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('블록이 없는 봇 메시지는 예전처럼 글을, 블록이 바뀌면 새 블록을', (tester) async {
    final session = _session([], (_) => _json({}));
    final plain = Message.fromJson({..._botJson(), 'blocks': null});
    await _pumpBubble(tester, session, plain);
    expect(find.byKey(const ValueKey('bot-blocks')), findsNothing);
    expect(find.text('휴가 승인 요청 [승인] [반려]'), findsOneWidget);

    final m = Message.fromJson(_botJson());
    await _pumpBubble(tester, session, m);
    expect(find.byKey(const ValueKey('bot-action-approve')), findsOneWidget);
    // 단추를 누른 뒤 봇이 "승인됨"으로 바꾼 것(message:edited)과 같다.
    m.blocks = BotBlock.listFromJson([
      {'type': 'section', 'text': '✅ 김가 님이 승인했습니다', 'fields': []},
    ]);
    await _pumpBubble(tester, session, m);
    expect(find.text('✅ 김가 님이 승인했습니다'), findsOneWidget);
    expect(find.byKey(const ValueKey('bot-action-approve')), findsNothing);
  });
}
