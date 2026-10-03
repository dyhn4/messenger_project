import 'dart:async';
import 'dart:convert';

import 'package:client/models/message.dart';
import 'package:client/models/poll.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/poll_create_dialog.dart';
import 'package:client/screens/polls_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/poll_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 투표 목록 패널(PollsScreen) — 상단 만들기 단추·필터·상태/참여 칩, 서버로 가는 요청 파라미터, 카드에서 바로 투표, 무한 스크롤,
/// 소켓으로 바뀐 투표 반영과 "새 투표" 알림줄, 폭 360. 서버는 요청을 기록하는 가짜 HTTP 클라이언트로 대신한다.

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
  }) async {}
}

typedef _Handler = FutureOr<http.Response> Function(http.Request request);

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json'},
);

class _Server {
  final requests = <http.Request>[];
  final _routes = <(String, RegExp, _Handler)>[];

  void on(String method, String path, _Handler handler) {
    final pattern = path
        .split('/')
        .map((s) => s.startsWith(':') ? '[^/]+' : RegExp.escape(s))
        .join('/');
    _routes.insert(0, (method, RegExp('^$pattern\$'), handler));
  }

  late final client = MockClient((request) async {
    requests.add(request);
    for (final (method, re, handler) in _routes) {
      if (method == request.method && re.hasMatch(request.url.path)) {
        return handler(request);
      }
    }
    return _json(<Object>[]);
  });

  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();

  /// 마지막 `GET /api/polls`의 쿼리.
  Map<String, String> get lastPollQuery =>
      called('GET', '/api/polls').last.url.queryParameters;
}

Map<String, dynamic> _user(String id, String name) => {
  'id': id,
  'username': id,
  'name': name,
  'role': 'member',
};

final _members = [_user('me', '나'), _user('u2', '김철수'), _user('u3', '이영희')];

Room _topic(String id, String name) => Room.fromJson({
  'id': id,
  'teamId': 't1',
  'type': 'topic',
  'name': name,
  'members': _members,
  'createdAt': 1000,
});

Map<String, dynamic> _pollJson({
  String id = 'p1',
  String title = '점심 뭐 먹을까요?',
  bool closed = false,
  int voterCount = 3,
  List<String> myOptionIds = const [],
}) => {
  'id': id,
  'title': title,
  'description': null,
  'anonymous': false,
  'multiple': false,
  'closesAt': DateTime.now()
      .add(const Duration(days: 1))
      .millisecondsSinceEpoch,
  'closedAt': null,
  'closed': closed,
  'creatorId': 'u2',
  'voterCount': voterCount,
  'options': [
    {'id': '$id-o1', 'text': '한식', 'voteCount': 2, 'voters': <Object>[]},
    {'id': '$id-o2', 'text': '중식', 'voteCount': 1, 'voters': <Object>[]},
  ],
  'myOptionIds': myOptionIds,
  'favorite': false,
};

Map<String, dynamic> _item(
  String n, {
  String roomId = 'r1',
  String roomName = '공지방',
  String senderId = 'u2',
  List<String> myOptionIds = const [],
}) => {
  'id': 'm$n',
  'roomId': roomId,
  'roomName': roomName,
  'senderId': senderId,
  'senderName': senderId == 'me' ? '나' : '김철수',
  'type': 'poll',
  'text': '투표 $n',
  'createdAt': 5000,
  'deleted': false,
  'attachments': const <Object>[],
  'poll': _pollJson(id: 'p$n', title: '투표 $n', myOptionIds: myOptionIds),
};

Map<String, dynamic> _page(
  List<Map<String, dynamic>> items, {
  bool hasMore = false,
  int? total,
  String? nextBefore,
}) => {
  'items': items,
  'hasMore': hasMore,
  'total': total ?? items.length,
  'nextBefore': nextBefore,
};

Session _session(_Server server) {
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
  session.rooms.addAll([_topic('r1', '공지방'), _topic('r2', '영업방')]);
  return session;
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pump(
  WidgetTester tester,
  Session session, {
  Size size = const Size(480, 1000),
  void Function(Room room, String messageId)? onOpenRoom,
}) async {
  _size(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PollsScreen(session: session, onOpenRoom: onOpenRoom),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

Finder _key(String k) => find.byKey(ValueKey(k));

void main() {
  late _Server server;
  setUp(() {
    server = _Server();
    server.on(
      'GET',
      '/api/polls',
      (_) =>
          _json(_page([_item('1'), _item('2', roomId: 'r2', roomName: '영업방')])),
    );
  });

  testWidgets('위에서부터 헤더 · 투표 만들기 · 필터 줄 · 상태/참여 칩 · 로딩 줄 · 카드, 기본 요청은 최신순 1년', (
    tester,
  ) async {
    final session = _session(server);
    await _pump(tester, session);

    final q = server.lastPollQuery;
    expect(q['teamId'], 't1');
    expect(q['order'], 'desc');
    expect(q['limit'], '20');
    expect(q.containsKey('status'), isFalse);
    expect(q.containsKey('participated'), isFalse);
    expect(q.containsKey('roomId'), isFalse);
    expect(q.containsKey('creatorId'), isFalse);
    // 기간 기본 1년 — since는 365일 전쯤.
    final since = DateTime.fromMillisecondsSinceEpoch(int.parse(q['since']!));
    expect(DateTime.now().difference(since).inDays, inInclusiveRange(364, 366));

    double top(Finder f) => tester.getTopLeft(f).dy;
    final header = find.text('투표').first;
    expect(top(header), lessThan(top(_key('polls-create'))));
    expect(top(_key('polls-create')), lessThan(top(find.text('참여 대화방'))));
    expect(top(find.text('참여 대화방')), lessThan(top(_key('polls-status'))));
    expect(
      top(_key('polls-status')),
      lessThan(top(_key('polls-participated'))),
    );
    expect(
      top(_key('polls-participated')),
      lessThan(top(_key('panel-loaded-count'))),
    );
    expect(
      top(_key('panel-loaded-count')),
      lessThan(top(_key('polls-item-m1'))),
    );

    // 필터 줄: 참여 대화방 · 멤버 · 기간(1년 (기본)).
    expect(find.text('참여 대화방'), findsOneWidget);
    expect(find.text('모든 멤버'), findsOneWidget);
    expect(find.text('1년 (기본)'), findsOneWidget);
    // 칩: 전체 | 진행 중 | 마감, 참여 여부: 전체 | 참여함 | 참여 안 함.
    for (final label in ['진행 중', '마감', '참여함', '참여 안 함']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('전체'), findsNWidgets(2));
    expect(find.text('참여 여부'), findsOneWidget);
    expect(find.text('최신순'), findsOneWidget);
    expect(find.text('"2"개가 로딩되었습니다.'), findsOneWidget);

    // 카드 두 장 — 방 이름 줄 + 방으로 이동 + 채팅과 같은 투표 카드.
    expect(_key('poll-card-p1'), findsOneWidget);
    expect(_key('poll-card-p2'), findsOneWidget);
    expect(find.text('투표 1'), findsOneWidget);
    expect(find.text('공지방'), findsOneWidget);
    expect(find.text('영업방'), findsOneWidget);
    expect(find.text('방으로 이동'), findsNWidgets(2));
    expect(find.byType(PollCard), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('필터를 바꿀 때마다 서버로 걸러서 다시 받는다 — 상태 · 참여 여부 · 정렬 · 방 · 작성자 · 기간', (
    tester,
  ) async {
    final session = _session(server);
    await _pump(tester, session);
    final before = server.called('GET', '/api/polls').length;

    await tester.tap(_key('polls-status-closed'));
    await tester.pumpAndSettle();
    expect(server.called('GET', '/api/polls').length, before + 1);
    expect(server.lastPollQuery['status'], 'closed');

    await tester.tap(_key('polls-status-open'));
    await tester.pumpAndSettle();
    expect(server.lastPollQuery['status'], 'open');

    await tester.tap(_key('polls-participated-yes'));
    await tester.pumpAndSettle();
    expect(server.lastPollQuery['participated'], 'yes');
    expect(server.lastPollQuery['status'], 'open'); // 조합이 유지된다.

    await tester.tap(_key('polls-participated-no'));
    await tester.pumpAndSettle();
    expect(server.lastPollQuery['participated'], 'no');

    await tester.tap(_key('polls-participated-all'));
    await tester.tap(_key('polls-status-all'));
    await tester.pumpAndSettle();
    expect(server.lastPollQuery.containsKey('status'), isFalse);
    expect(server.lastPollQuery.containsKey('participated'), isFalse);

    // 정렬 — 과거순.
    await tester.tap(_key('panel-sort'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('과거순').last);
    await tester.pumpAndSettle();
    expect(server.lastPollQuery['order'], 'asc');

    // 참여 대화방.
    await tester.tap(find.text('참여 대화방'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('영업방').last);
    await tester.pumpAndSettle();
    expect(server.lastPollQuery['roomId'], 'r2');

    // 작성자(멤버).
    await tester.tap(find.text('모든 멤버'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('김철수').last);
    await tester.pumpAndSettle();
    expect(server.lastPollQuery['creatorId'], 'u2');
    expect(server.lastPollQuery['roomId'], 'r2');
    expect(server.lastPollQuery['order'], 'asc');

    // 기간 — 1주일.
    await tester.tap(find.text('1년 (기본)'));
    await tester.pumpAndSettle();
    await tester.tap(_key('period-week'));
    await tester.pumpAndSettle();
    final since = DateTime.fromMillisecondsSinceEpoch(
      int.parse(server.lastPollQuery['since']!),
    );
    expect(DateTime.now().difference(since).inDays, inInclusiveRange(6, 8));

    // 방을 다시 바꾸면 이전 방 기준으로 골랐던 작성자는 풀린다.
    await tester.tap(find.text('영업방').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('공지방').last);
    await tester.pumpAndSettle();
    expect(server.lastPollQuery['roomId'], 'r1');
    expect(server.lastPollQuery.containsKey('creatorId'), isFalse);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('카드에서 바로 투표한다 — 보기를 고르고 투표하기', (tester) async {
    server.on('PUT', '/api/polls/:pollId/vote', (r) {
      return _json(
        _pollJson(
          id: 'p1',
          title: '투표 1',
          voterCount: 4,
          myOptionIds: ['p1-o2'],
        ),
      );
    });
    final session = _session(server);
    await _pump(tester, session);

    final card = find.descendant(
      of: _key('polls-item-m1'),
      matching: _key('poll-option-p1-o2'),
    );
    await tester.ensureVisible(card);
    await tester.tap(card);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: _key('polls-item-m1'),
        matching: _key('poll-vote-button'),
      ),
    );
    await tester.pumpAndSettle();

    final put = server.called('PUT', '/api/polls/p1/vote');
    expect(put, hasLength(1));
    expect((jsonDecode(put.single.body) as Map)['optionIds'], ['p1-o2']);
    // 응답으로 카드가 바뀐다.
    expect(
      find.descendant(of: _key('polls-item-m1'), matching: find.text('참여자 4명')),
      findsOneWidget,
    );
    // 목록을 다시 받지 않는다(처음 한 번뿐).
    expect(server.called('GET', '/api/polls'), hasLength(1));
    await _finish(tester);
  });

  testWidgets('무한 스크롤 — 끝에 닿으면 nextBefore로 다음 쪽을 이어 붙이고, 같은 필터를 유지한다', (
    tester,
  ) async {
    server.on('GET', '/api/polls', (r) {
      if (r.url.queryParameters['before'] == 'cursor-1') {
        return _json(_page([_item('21'), _item('22')], total: 22));
      }
      return _json(
        _page(
          [for (var i = 1; i <= 20; i++) _item('$i')],
          hasMore: true,
          total: 22,
          nextBefore: 'cursor-1',
        ),
      );
    });
    final session = _session(server);
    await _pump(tester, session, size: const Size(480, 700));
    expect(find.text('"22"개가 로딩되었습니다.'), findsOneWidget);
    expect(server.called('GET', '/api/polls'), hasLength(1));

    await tester.tap(_key('polls-status-open'));
    await tester.pumpAndSettle();
    expect(server.called('GET', '/api/polls'), hasLength(2));

    final list = _key('polls-list');
    for (var i = 0; i < 40; i++) {
      await tester.drag(list, const Offset(0, -1500));
      await tester.pumpAndSettle();
      if (server.called('GET', '/api/polls').length > 2) break;
    }
    final more = server
        .called('GET', '/api/polls')
        .where((r) => r.url.queryParameters['before'] == 'cursor-1')
        .toList();
    expect(more, isNotEmpty);
    expect(more.first.url.queryParameters['status'], 'open');
    // 이어 붙었다 — 22번째 카드까지 있고 더 보기는 없다.
    await tester.drag(list, const Offset(0, -20000));
    await tester.pumpAndSettle();
    expect(_key('polls-item-m22'), findsOneWidget);
    expect(_key('polls-more'), findsNothing);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('열려 있는 동안 다른 사람의 투표가 소켓으로 오면 그 카드만 고쳐진다(내 선택은 유지)', (
    tester,
  ) async {
    server.on(
      'GET',
      '/api/polls',
      (_) => _json(
        _page([
          _item('1', myOptionIds: ['p1-o1']),
          _item('2'),
        ]),
      ),
    );
    final session = _session(server);
    await _pump(tester, session);
    expect(
      find.descendant(of: _key('polls-item-m1'), matching: find.text('참여자 3명')),
      findsOneWidget,
    );

    session.handlePollUpdated(
      PollUpdatedEvent.fromJson({
        'roomId': 'r1',
        'messageId': 'm1',
        'pollId': 'p1',
        'poll': _pollJson(id: 'p1', title: '투표 1', voterCount: 9),
        'actorId': 'u3',
        'actorOptionIds': ['p1-o2'],
      }),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _key('polls-item-m1'), matching: find.text('참여자 9명')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _key('polls-item-m2'), matching: find.text('참여자 3명')),
      findsOneWidget,
    );
    // 내 선택은 이벤트로 덮어쓰지 않는다 — 다시 투표하기 단추가 그대로 있다.
    expect(
      find.descendant(
        of: _key('polls-item-m1'),
        matching: _key('poll-revote-button'),
      ),
      findsOneWidget,
    );

    // 마감 이벤트.
    session.handlePollUpdated(
      PollUpdatedEvent.fromJson({
        'roomId': 'r2',
        'messageId': 'm2',
        'pollId': 'p2',
        'poll': {
          ..._pollJson(id: 'p2', title: '투표 2', closed: true),
          'closedAt': DateTime.now().millisecondsSinceEpoch,
        },
        'actorId': null,
        'actorOptionIds': null,
      }),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _key('polls-item-m2'), matching: find.text('마감됨')),
      findsOneWidget,
    );
    // 모르는 투표의 이벤트는 조용히 무시한다.
    session.handlePollUpdated(
      PollUpdatedEvent.fromJson({
        'roomId': 'r1',
        'messageId': 'zz',
        'pollId': 'zz',
        'poll': _pollJson(id: 'zz'),
        'actorId': null,
        'actorOptionIds': null,
      }),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('새 투표가 올라오면 맨 위에 끼우지 않고 알림줄만 — 누르면 다시 받고, 내가 만든 투표는 바로 다시 받는다', (
    tester,
  ) async {
    final session = _session(server);
    await _pump(tester, session);
    expect(_key('polls-new-notice'), findsNothing);
    expect(server.called('GET', '/api/polls'), hasLength(1));

    Message poll(String id, String senderId, String roomId) => Message.fromJson(
      {..._item('9', roomId: roomId, senderId: senderId), 'id': id},
    );

    // 남이 만든 투표 — 알림줄만.
    await session.handleSocketMessage(poll('m9', 'u2', 'r1'));
    await tester.pumpAndSettle();
    expect(_key('polls-new-notice'), findsOneWidget);
    expect(find.text('새 투표가 있습니다 · 새로고침'), findsOneWidget);
    expect(_key('polls-item-m9'), findsNothing);
    expect(server.called('GET', '/api/polls'), hasLength(1));

    // 알림줄을 누르면 다시 받고 줄이 사라진다.
    await tester.tap(_key('polls-new-notice'));
    await tester.pumpAndSettle();
    expect(server.called('GET', '/api/polls'), hasLength(2));
    expect(_key('polls-new-notice'), findsNothing);

    // 내가 만든 투표 — 알림줄 없이 바로 다시 받는다.
    await session.handleSocketMessage(poll('m10', 'me', 'r1'));
    await tester.pumpAndSettle();
    expect(server.called('GET', '/api/polls'), hasLength(3));
    expect(_key('polls-new-notice'), findsNothing);

    // 내 방이 아닌(모르는) 방의 투표는 무시한다.
    await session.handleSocketMessage(poll('m11', 'u2', 'zz-unknown'));
    await tester.pumpAndSettle();
    expect(_key('polls-new-notice'), findsNothing);
    await _finish(tester);
  });

  testWidgets('"방으로 이동"은 그 방과 투표 메시지로 간다', (tester) async {
    final session = _session(server);
    Room? room;
    String? messageId;
    await _pump(
      tester,
      session,
      onOpenRoom: (r, m) {
        room = r;
        messageId = m;
      },
    );
    await tester.tap(_key('polls-goto-m2'));
    await tester.pumpAndSettle();
    expect(room?.id, 'r2');
    expect(messageId, 'm2');
    await _finish(tester);
  });

  testWidgets('상단 "투표 만들기" 단추가 만들기 창(대화방 선택 칸 포함)을 열고, 만들면 목록을 다시 받는다', (
    tester,
  ) async {
    server.on('POST', '/api/rooms/r2/polls', (r) {
      return _json({..._item('7', roomId: 'r2', senderId: 'me')}, 201);
    });
    final session = _session(server);
    await _pump(tester, session, size: const Size(1280, 900));
    expect(find.byType(PollCreator), findsNothing);

    await tester.tap(_key('polls-create'));
    await tester.pumpAndSettle();
    expect(find.byType(PollCreator), findsOneWidget);
    expect(find.text('대화방 선택'), findsOneWidget);

    await tester.enterText(_key('poll-title-field'), '회식 장소');
    await tester.enterText(_key('poll-option-field-0'), '삼겹살');
    await tester.enterText(_key('poll-option-field-1'), '초밥');
    await tester.tap(find.text('대화방 선택'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('영업방').last);
    await tester.pumpAndSettle();
    await tester.tap(_key('poll-create-submit'));
    await tester.pumpAndSettle();

    expect(server.called('POST', '/api/rooms/r2/polls'), hasLength(1));
    expect(find.byType(PollCreator), findsNothing);
    expect(server.called('GET', '/api/polls'), hasLength(2)); // 만든 뒤 다시 받았다.
    expect(find.text('투표를 만들었습니다.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await _finish(tester);
  });

  testWidgets('빈 목록 · 조건에 맞는 투표 없음 · 오류와 다시 시도', (tester) async {
    server.on('GET', '/api/polls', (_) => _json(_page([])));
    final session = _session(server);
    await _pump(tester, session);
    expect(_key('polls-empty'), findsOneWidget);
    expect(find.textContaining('등록된 투표가 없습니다'), findsOneWidget);
    expect(find.text('"0"개가 로딩되었습니다.'), findsOneWidget);

    await tester.tap(_key('polls-status-closed'));
    await tester.pumpAndSettle();
    expect(find.text('조건에 맞는 투표가 없습니다.'), findsOneWidget);

    var fail = true;
    server.on('GET', '/api/polls', (_) {
      return fail
          ? _json({'error': '서버가 바쁩니다.'}, 500)
          : _json(_page([_item('1')]));
    });
    await tester.tap(_key('polls-status-open'));
    await tester.pumpAndSettle();
    expect(_key('polls-error'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(_key('polls-item-m1'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('폭 360 — 넘치지 않고 필터 줄 · 칩 · 카드가 모두 화면 안에 있다', (tester) async {
    final session = _session(server);
    await _pump(tester, session, size: const Size(360, 780));
    expect(tester.takeException(), isNull);
    for (final f in [
      _key('polls-create'),
      find.text('참여 대화방'),
      find.text('모든 멤버'),
      find.text('1년 (기본)'),
      find.text('진행 중'),
      find.text('최신순'),
      find.text('참여 안 함'),
      _key('polls-item-m1'),
    ]) {
      final rect = tester.getRect(f);
      expect(rect.left, greaterThanOrEqualTo(0), reason: '$f');
      expect(rect.right, lessThanOrEqualTo(360), reason: '$f');
    }
    // 만들기 단추는 폭을 가득 채운다(좌우 여백 16).
    final create = tester.getRect(_key('polls-create'));
    expect(create.left, 16);
    expect(create.right, 344);

    // 필터를 걸어도 넘치지 않는다.
    await tester.tap(_key('polls-participated-no'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });
}
