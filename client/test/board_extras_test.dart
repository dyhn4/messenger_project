import 'dart:async';
import 'dart:convert';

import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/board_categories_dialog.dart';
import 'package:client/screens/message_thread_screen.dart';
import 'package:client/screens/post_editor_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/chat_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 게시판 보강 — 말머리(분류)·필독·읽음 확인(board_view.dart·post_editor_dialog.dart·message_thread_screen.dart·
/// board_categories_dialog.dart, 서버 boardExtras.js·boardRules.js).

/// 테스트 엔진에는 OS 알림 플러그인이 없다 — 방을 열 때의 "그 방 알림 지우기"를 조용히 넘긴다.
class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}

  @override
  Future<void> showMessage({
    required String title,
    required String body,
    required String roomId,
    String? senderName,
    String? conversationTitle,
    String avatarType = 'initial',
    String? avatarEmoji,
    String? avatarColor,
    String? avatarUrl,
    bool isSecret = false,
    bool flashTaskbarUntilRoomOpened = false,
    bool flashWindowFrame = true,
  }) async {}
}

typedef _Handler = FutureOr<http.Response> Function(http.Request request);

/// 경로별 응답을 정해두고, 들어온 요청을 전부 기록하는 가짜 서버.
class _Server {
  final requests = <http.Request>[];
  final routes = <String, _Handler>{};

  late final client = MockClient((request) async {
    requests.add(request);
    final handler = routes['${request.method} ${request.url.path}'];
    if (handler != null) return handler(request);
    return _json(<Object>[]);
  });

  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
}

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json'},
);

Map<String, dynamic> _body(http.Request r) =>
    jsonDecode(r.body) as Map<String, dynamic>;

final _base = DateTime(2026, 9, 29, 9).millisecondsSinceEpoch;
int _at(int minutes) => _base + minutes * 60000;

Map<String, dynamic> _user(String id, String name) => {
  'id': id,
  'username': id,
  'name': name,
  'role': 'member',
};

const _categories = [
  {'id': 'knotice1', 'name': '공지', 'color': '#E53935'},
  {'id': 'kquest01', 'name': '질문', 'color': '#5B8DEF'},
];

Map<String, dynamic> _post(
  String id, {
  String? title,
  int minutes = 0,
  String senderId = 'u2',
  String? categoryId,
  int? mustReadAt,
  bool? readByMe,
}) => {
  'id': id,
  'roomId': 'r1',
  'senderId': senderId,
  'senderName': senderId == 'me' ? '나' : '김철수',
  'type': 'post',
  'title': title ?? '$id 제목',
  'text': '본문입니다.',
  'createdAt': _at(minutes),
  'categoryId': categoryId,
  'mustReadAt': mustReadAt,
  'readByMe': ?readByMe,
  'comments': <Object>[],
};

Map<String, dynamic> _roomJson({
  List<String> admins = const [],
  List<Map<String, dynamic>> categories = _categories,
}) => {
  'id': 'r1',
  'teamId': 't1',
  'type': 'topic',
  'name': '사내 게시판',
  'members': [_user('me', '나'), _user('u2', '김철수'), _user('u3', '이영희')],
  'createdAt': _base,
  'viewMode': 'board',
  'adminIds': admins,
  'boardCategories': categories,
};

Session _session(_Server server, Room room) {
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
  session.accountRole = AccountRole.member;
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.add(room);
  return session;
}

_Server _boardServer({
  List<Map<String, dynamic>> history = const [],
  List<Map<String, dynamic>> mustRead = const [],
}) {
  final server = _Server();
  server.routes['GET /api/rooms/r1/messages'] = (_) => _json(history);
  server.routes['GET /api/rooms/r1/must-read'] = (_) => _json(mustRead);
  return server;
}

Future<void> _pumpBoard(WidgetTester tester, Session session, Room room) async {
  tester.view.physicalSize = const Size(1100, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChatPanel(key: ValueKey(room.id), session: session, room: room),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _card(String id) => find.byKey(ValueKey('post-$id'));

Future<void> _flushToasts(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

void main() {
  test('말머리·필독·읽음 — 방과 게시글 JSON을 읽고, 지운 말머리는 없는 것으로 본다', () {
    final room = Room.fromJson(_roomJson());
    expect(room.boardCategories.map((c) => c.name), ['공지', '질문']);
    expect(room.boardCategoryById('knotice1')?.name, '공지');
    expect(room.boardCategoryById('kgone000'), isNull);
    // 예전 서버(칸 없음)·모양이 틀린 항목은 빈 목록·건너뛴다.
    expect(
      Room.fromJson({..._roomJson(), 'boardCategories': null}).boardCategories,
      isEmpty,
    );
    expect(
      Room.fromJson({
        ..._roomJson(),
        'boardCategories': [
          {'name': 'id 없음'},
          ..._categories,
        ],
      }).boardCategories.length,
      2,
    );
    final post = Message.fromJson(
      _post('p1', categoryId: 'knotice1', mustReadAt: _at(5), readByMe: false),
    );
    expect(post.categoryId, 'knotice1');
    expect(post.isMustRead, isTrue);
    expect(post.isUnreadPost, isTrue);
    // 읽음을 모르면(실시간 새 글·예전 서버) 안 읽은 것으로 치지 않는다.
    expect(Message.fromJson(_post('p2')).isUnreadPost, isFalse);
  });

  testWidgets('카드 — 말머리 알약·필독 표시·안 읽음 점, 말머리로 모아 보기', (tester) async {
    final room = Room.fromJson(_roomJson());
    final server = _boardServer(
      history: [
        _post('p1', title: '휴가 신청 방법', minutes: 1, categoryId: 'kquest01'),
        _post(
          'p2',
          title: '보안 수칙',
          minutes: 2,
          categoryId: 'knotice1',
          mustReadAt: _at(2),
          readByMe: false,
        ),
        _post('p3', title: '점심 메뉴', minutes: 3, readByMe: true),
        // 지운 말머리를 든 글은 말머리 없이 보인다.
        _post('p4', title: '옛 글', minutes: 4, categoryId: 'kgone000'),
      ],
    );
    final session = _session(server, room);
    await _pumpBoard(tester, session, room);

    expect(
      find.descendant(of: _card('p2'), matching: find.text('공지')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _card('p2'), matching: find.text('필독')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _card('p2'),
        matching: find.byKey(const ValueKey('post-unread-dot')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _card('p3'),
        matching: find.byKey(const ValueKey('post-unread-dot')),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: _card('p1'), matching: find.text('질문')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('must-read-tag')), findsOneWidget);
    // 토픽 관리자가 아니면 말머리 관리 단추가 없다.
    expect(find.byTooltip('말머리 관리'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('board-filter-kquest01')));
    await tester.pumpAndSettle();
    expect(_card('p1'), findsOneWidget);
    expect(_card('p2'), findsNothing);
    expect(_card('p3'), findsNothing);
    expect(_card('p4'), findsNothing);

    // 같은 말머리를 다시 누르면 전체로.
    await tester.tap(find.byKey(const ValueKey('board-filter-kquest01')));
    await tester.pumpAndSettle();
    expect(_card('p4'), findsOneWidget);
  });

  testWidgets('필독 안 읽음 — 누르면 게시글이 열리고 읽음이 남아 목록·안 읽음 점에서 빠진다, 읽음 확인 단추', (
    tester,
  ) async {
    final room = Room.fromJson(_roomJson());
    final server = _boardServer(
      history: [
        _post(
          'p2',
          title: '보안 수칙',
          minutes: 2,
          mustReadAt: _at(2),
          readByMe: false,
        ),
      ],
      mustRead: [
        {
          'id': 'p2',
          'title': '보안 수칙',
          'createdAt': _at(2),
          'mustReadAt': _at(2),
        },
      ],
    );
    server.routes['GET /api/messages/p2/readers'] = (_) => _json({
      'read': [
        {'userId': 'u2', 'name': '김철수', 'readAt': _at(2)},
      ],
      'unread': [
        {'userId': 'me', 'name': '나'},
        {'userId': 'u3', 'name': '이영희'},
      ],
    });
    final session = _session(server, room);
    await _pumpBoard(tester, session, room);

    expect(find.byKey(const ValueKey('board-must-read')), findsOneWidget);
    expect(find.text('읽지 않은 필독 1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('must-read-p2')));
    await tester.pumpAndSettle();

    expect(find.byType(MessageThreadScreen), findsOneWidget);
    expect(server.called('POST', '/api/messages/p2/post-read'), hasLength(1));
    // 받은 목록에선 아직 안 읽은 쪽이어도 지금 보고 있는 나는 읽은 쪽.
    expect(find.text('읽음 2 · 안 읽음 1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('post-readers')));
    await tester.pumpAndSettle();
    expect(find.text('게시글 읽음 확인'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('announcement-readers-unread-tab')),
    );
    await tester.pumpAndSettle();
    expect(find.text('이영희'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('board-must-read')), findsNothing);
    expect(find.byKey(const ValueKey('post-unread-dot')), findsNothing);
  });

  testWidgets('실시간 새 글 — 남의 글은 안 읽음, 필독이면 "필독 안 읽음"에, 내 다른 기기에서 읽으면 빠진다', (
    tester,
  ) async {
    final room = Room.fromJson(_roomJson());
    final server = _boardServer();
    final session = _session(server, room);
    await _pumpBoard(tester, session, room);

    final c = session.controllerFor(room);
    c.feed(
      Message.fromJson(
        _post('n1', title: '새 필독', minutes: 9, mustReadAt: _at(9)),
      ),
    );
    c.feed(
      Message.fromJson(_post('n2', title: '내 글', minutes: 10, senderId: 'me')),
    );
    await tester.pumpAndSettle();
    expect(find.text('읽지 않은 필독 1'), findsOneWidget);
    expect(
      find.descendant(
        of: _card('n1'),
        matching: find.byKey(const ValueKey('post-unread-dot')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _card('n2'),
        matching: find.byKey(const ValueKey('post-unread-dot')),
      ),
      findsNothing,
    );

    c.applyPostRead('n1', 'me');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('board-must-read')), findsNothing);
    expect(find.byKey(const ValueKey('post-unread-dot')), findsNothing);
  });

  testWidgets('편집기 — 말머리를 고르고 관리자는 필독으로 올린다, 수정은 바뀐 말머리만 보낸다', (tester) async {
    final room = Room.fromJson(_roomJson(admins: ['me']));
    final server = _boardServer(
      history: [
        _post('mine', title: '원래 제목', senderId: 'me', categoryId: 'knotice1'),
      ],
    );
    // 서버처럼 — categoryId를 안 보내면 말머리는 그대로.
    String? category = 'knotice1';
    server.routes['PATCH /api/messages/mine'] = (r) {
      final body = _body(r);
      if (body.containsKey('categoryId')) {
        category = body['categoryId'] as String?;
      }
      return _json(
        _post('mine', title: '원래 제목', senderId: 'me', categoryId: category),
      );
    };
    final session = _session(server, room);
    final sent = <Map<String, dynamic>>[];
    session.chatSocket.debugSendOverride = (payload) async {
      sent.add(payload);
      return {'ok': true};
    };
    await _pumpBoard(tester, session, room);

    await tester.tap(find.byTooltip('게시글 작성'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('post-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('질문').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('post-must-read')));
    await tester.enterText(find.byKey(const ValueKey('post-title')), '분기 보고');
    await tester.enterText(find.byKey(const ValueKey('post-body')), '내용');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('post-submit')));
    await tester.pumpAndSettle();
    expect(sent.single, {
      'roomId': 'r1',
      'type': 'post',
      'title': '분기 보고',
      'categoryId': 'kquest01',
      'mustRead': true,
      'text': '내용',
    });

    // 수정 — 말머리를 안 건드리면 보내지 않는다.
    await tester.tap(
      find.descendant(of: _card('mine'), matching: find.byTooltip('더보기')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('수정'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('post-must-read')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('post-title')), '원래 제목');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(
      _body(
        server.called('PATCH', '/api/messages/mine').single,
      ).containsKey('categoryId'),
      isFalse,
    );

    // 말머리 빼기 — null로 보낸다.
    await tester.tap(
      find.descendant(of: _card('mine'), matching: find.byTooltip('더보기')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('수정'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('post-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('말머리 없음').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    final last = _body(server.called('PATCH', '/api/messages/mine').last);
    expect(last.containsKey('categoryId'), isTrue);
    expect(last['categoryId'], isNull);
    expect(
      find.descendant(of: _card('mine'), matching: find.text('공지')),
      findsNothing,
    );
    await _flushToasts(tester);
  });

  testWidgets('관리자 — ⋯에서 필독 지정, 말머리 관리 창에서 더하고 저장', (tester) async {
    final room = Room.fromJson(_roomJson(admins: ['me']));
    final server = _boardServer(history: [_post('p1', title: '안내')]);
    server.routes['POST /api/messages/p1/must-read'] = (r) => _json(
      _post(
        'p1',
        title: '안내',
        mustReadAt: _body(r)['mustRead'] == true ? _at(30) : null,
      ),
    );
    server.routes['PATCH /api/rooms/r1'] = (r) {
      final list = (_body(r)['boardCategories'] as List).cast<Map>();
      return _json(
        _roomJson(
          admins: ['me'],
          categories: [
            for (var i = 0; i < list.length; i++)
              {
                'id': list[i]['id'] ?? 'knew000$i',
                'name': list[i]['name'],
                'color': list[i]['color'],
              },
          ],
        ),
      );
    };
    final session = _session(server, room);
    await _pumpBoard(tester, session, room);

    await tester.tap(
      find.descendant(of: _card('p1'), matching: find.byTooltip('더보기')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('필독으로 지정'));
    await tester.pumpAndSettle();
    expect(_body(server.called('POST', '/api/messages/p1/must-read').single), {
      'mustRead': true,
    });
    expect(
      find.descendant(of: _card('p1'), matching: find.text('필독')),
      findsOneWidget,
    );
    await _flushToasts(tester);

    await tester.tap(find.byTooltip('말머리 관리'));
    await tester.pumpAndSettle();
    expect(find.byType(BoardCategoriesDialog), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('board-category-add')));
    await tester.pumpAndSettle();
    // 이름을 비운 채 저장하면 막는다.
    await tester.tap(find.byKey(const ValueKey('board-category-save')));
    await tester.pumpAndSettle();
    expect(find.text('말머리 이름을 입력하세요.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('board-category-name-2')),
      '자료',
    );
    await tester.tap(find.byKey(const ValueKey('board-category-save')));
    await tester.pumpAndSettle();
    final sentList =
        _body(server.called('PATCH', '/api/rooms/r1').single)['boardCategories']
            as List;
    expect(sentList.map((c) => (c as Map)['name']), ['공지', '질문', '자료']);
    expect((sentList[0] as Map)['id'], 'knotice1');
    expect((sentList[2] as Map).containsKey('id'), isFalse);
    expect(find.byType(BoardCategoriesDialog), findsNothing);
    expect(find.byKey(const ValueKey('board-filter-knew0002')), findsOneWidget);
    await _flushToasts(tester);
  });

  testWidgets('게시글 상세 — 열면 읽음을 남기고, 읽음 확인을 못 받으면 단추를 숨긴다', (tester) async {
    final room = Room.fromJson(_roomJson());
    final server = _boardServer(history: [_post('p1')]);
    final session = _session(server, room);
    await _pumpBoard(tester, session, room);
    await tester.tap(_card('p1'));
    await tester.pumpAndSettle();
    expect(server.called('POST', '/api/messages/p1/post-read'), hasLength(1));
    // 읽음 확인을 못 받으면(가짜 서버가 목록을 줌) 단추를 숨긴다.
    expect(find.byKey(const ValueKey('post-readers')), findsNothing);
    expect(find.byType(PostEditor), findsNothing);
  });
}
