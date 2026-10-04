import 'dart:async';
import 'dart:convert';

import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/todo_detail_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/todo_message_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers/fake_todo_api.dart';

/// 할 일을 만들 때 대화방에 올라가는 할 일 카드(todo_message_card.dart) — 스냅샷을 먼저 그리고 할 일을 다시 받아 최신으로,
/// 지워지면 "삭제된 할 일", 누르면 상세. 서버는 가짜 API(helpers/fake_todo_api.dart).

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

Session _session() {
  final session = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: MockClient(
      (request) async => http.Response.bytes(
        utf8.encode(jsonEncode({'items': <Object>[], 'hasMore': false})),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    ),
  );
  session.userId = 'me';
  session.name = '나';
  session.accountRole = AccountRole.member;
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.add(
    Room.fromJson({
      'id': 'r1',
      'teamId': 't1',
      'type': 'topic',
      'name': '영업 토픽',
      'members': [
        {'id': 'me', 'username': 'me', 'name': '나', 'role': 'member'},
        {'id': 'u2', 'username': 'u2', 'name': '김철수', 'role': 'member'},
      ],
      'createdAt': 1000,
    }),
  );
  return session;
}

/// 서버가 내려주는 할 일 카드 메시지(일반 글 + sharedTodo).
Message _cardMessage({String? todoId = 't1', String title = '3월 회의록 정리'}) =>
    Message.fromJson({
      'id': 'm1',
      'roomId': 'r1',
      'senderId': 'u2',
      'senderName': '김철수',
      'type': 'text',
      'text': '[할 일] $title\n담당: @나',
      'mentions': [
        {
          'type': 'user',
          'userId': 'me',
          's': title.length + 10,
          'e': title.length + 12,
        },
      ],
      'createdAt': 1000,
      'sharedTodo': {
        'id': todoId,
        'title': title,
        'description': '- 일정\n- 컨텐츠',
        'dueDate': '2026-03-16',
        'attachments': [
          {'kind': 'file', 'fileName': '3월 회의록.pptx'},
        ],
        'attachmentCount': 1,
        'assigneeNames': ['나'],
      },
    });

Future<void> _pump(
  WidgetTester tester, {
  required Message message,
  required FakeTodoApi api,
  Stream<Map<String, dynamic>>? changed,
}) async {
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: TodoMessageCard(
            session: _session(),
            message: message,
            api: api,
            changed: changed ?? const Stream.empty(),
          ),
        ),
      ),
    ),
  );
}

void main() {
  test('메시지 DTO의 sharedTodo를 읽는다 — 할 일이 지워졌으면 id가 null', () {
    final m = _cardMessage();
    expect(m.sharedTodo!.id, 't1');
    expect(m.sharedTodo!.title, '3월 회의록 정리');
    expect(m.sharedTodo!.attachmentNames, ['3월 회의록.pptx']);
    expect(m.sharedTodo!.periodText, isNotNull);
    expect(_cardMessage(todoId: null).sharedTodo!.deleted, isTrue);
    // 일반 글에는 없다.
    expect(
      Message.fromJson({
        'id': 'x',
        'roomId': 'r1',
        'senderName': 'a',
        'type': 'text',
        'text': 'hi',
        'createdAt': 1,
      }).sharedTodo,
      isNull,
    );
  });

  testWidgets('스냅샷을 먼저 그리고, 다시 받은 할 일로 최신 제목·진행률을 보인다', (tester) async {
    final api = FakeTodoApi(
      me: 'me',
      todos: [
        todoJson(
          id: 't1',
          title: '3월 회의록 정리(수정)',
          creatorId: 'u2',
          creatorName: '김철수',
          assignees: ['me'],
          assigneeProgress: {'me': 50},
        ),
      ],
    );
    await _pump(tester, message: _cardMessage(), api: api);
    // 첫 프레임 — 스냅샷.
    expect(find.text('3월 회의록 정리'), findsOneWidget);
    expect(find.text('- 일정\n- 컨텐츠'), findsOneWidget);
    expect(find.text('3월 회의록.pptx'), findsOneWidget);
    expect(find.text('담당 나'), findsOneWidget);
    await tester.pump();
    expect(api.calls, contains('get t1'));
    expect(find.text('3월 회의록 정리(수정)'), findsOneWidget);
    expect(find.byKey(const ValueKey('todo-card-progress')), findsOneWidget);
    expect(find.text('담당 이름me'), findsOneWidget);
  });

  testWidgets('지워졌다는 소식이 오거나 서버에 없으면 "삭제된 할 일" — 누르면 알림만', (tester) async {
    final changed = StreamController<Map<String, dynamic>>.broadcast();
    final api = FakeTodoApi(
      me: 'me',
      todos: [todoJson(id: 't9')],
    );
    await _pump(
      tester,
      message: _cardMessage(todoId: 't9'),
      api: api,
      changed: changed.stream,
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('todo-card-deleted')), findsNothing);
    changed.add({'todoId': 't9', 'kind': 'deleted'});
    await tester.pump();
    await tester.pump();
    expect(find.text('삭제된 할 일입니다.'), findsOneWidget);
    await tester.tap(find.byType(TodoMessageCard));
    await tester.pump();
    expect(find.byType(TodoDetail), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    await changed.close();

    // 서버에 없는 할 일(다른 기기에서 지움) — 다시 받다가 알게 된다.
    await _pump(
      tester,
      message: _cardMessage(todoId: 'gone'),
      api: FakeTodoApi(me: 'me'),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('todo-card-deleted')), findsOneWidget);
  });

  testWidgets('누르면 할 일 상세가 열린다', (tester) async {
    final api = FakeTodoApi(
      me: 'me',
      todos: [
        todoJson(id: 't2', title: '보고서', assignees: ['me']),
      ],
    );
    await _pump(
      tester,
      message: _cardMessage(todoId: 't2'),
      api: api,
    );
    await tester.pump();
    await tester.tap(find.byType(TodoMessageCard));
    await tester.pumpAndSettle();
    expect(find.byType(TodoDetail), findsOneWidget);
    expect(find.byKey(const ValueKey('todo-detail-title')), findsOneWidget);
  });
}
