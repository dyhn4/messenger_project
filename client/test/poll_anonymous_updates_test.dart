import 'dart:async';
import 'dart:convert';

import 'package:client/models/poll.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/polls_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 익명 투표의 소켓 `poll:updated`(S18) — 서버는 방 전체에는 집계만(actorId·actorOptionIds null) 보내고,
/// 투표한 사람의 기기(user 룸)에만 본인 선택을 실어 보낸다. 앱이 두 모양을 받아 다른 사람 화면은 표 수만,
/// 내 다른 기기는 내 선택까지 맞추는지, 두 알림을 겹쳐 받아도 표가 두 번 세어지지 않는지(절대값),
/// 옛 서버 모양(방 알림에 남의 actorId)도 그대로 되는지를 모델·세션(방 화면)·투표 목록 패널에서 본다.

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

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json'},
);

class _Server {
  final _routes = <(String, RegExp, _Handler)>[];

  void on(String method, String path, _Handler handler) {
    final pattern = path
        .split('/')
        .map((s) => s.startsWith(':') ? '[^/]+' : RegExp.escape(s))
        .join('/');
    _routes.insert(0, (method, RegExp('^$pattern\$'), handler));
  }

  late final client = MockClient((request) async {
    for (final (method, re, handler) in _routes) {
      if (method == request.method && re.hasMatch(request.url.path)) {
        return handler(request);
      }
    }
    return _json(<Object>[]);
  });
}

Map<String, dynamic> _user(String id, String name) => {
  'id': id,
  'username': id,
  'name': name,
  'role': 'member',
};

Room _topic(String id) => Room.fromJson({
  'id': id,
  'teamId': 't1',
  'type': 'topic',
  'name': '공지방',
  'members': [_user('me', '나'), _user('u2', '김철수'), _user('u3', '이영희')],
  'createdAt': 1000,
});

/// 익명 투표 DTO — 서버 toPollDto처럼 보기에 voters 키가 없다. [counts]는 보기(o1·o2·o3)별 표 수.
Map<String, dynamic> _anonPoll({
  int voterCount = 3,
  List<int> counts = const [2, 1, 0],
  List<String> myOptionIds = const [],
  bool favorite = false,
}) => {
  'id': 'p1',
  'title': '회식 장소',
  'description': null,
  'anonymous': true,
  'multiple': false,
  'closesAt': DateTime.now()
      .add(const Duration(days: 1))
      .millisecondsSinceEpoch,
  'closedAt': null,
  'closed': false,
  'creatorId': 'u2',
  'voterCount': voterCount,
  'options': [
    {'id': 'o1', 'text': '한식', 'voteCount': counts[0]},
    {'id': 'o2', 'text': '중식', 'voteCount': counts[1]},
    {'id': 'o3', 'text': '일식', 'voteCount': counts[2]},
  ],
  'myOptionIds': myOptionIds,
  'favorite': favorite,
};

Map<String, dynamic> _message(Map<String, dynamic> poll) => {
  'id': 'm1',
  'roomId': 'r1',
  'senderId': 'u2',
  'senderName': '김철수',
  'type': 'poll',
  'text': poll['title'],
  'createdAt': 5000,
  'deleted': false,
  'poll': poll,
  'attachments': const <Object>[],
};

/// 서버가 방 전체에 보내는 모양 — actorId·actorOptionIds가 null. [omitKeys]면 키 자체가 없다(그래도 같게 읽어야 한다).
Map<String, dynamic> _roomEvent(
  Map<String, dynamic> poll, {
  bool omitKeys = false,
}) => {
  'roomId': 'r1',
  'messageId': 'm1',
  'pollId': 'p1',
  'poll': poll,
  if (!omitKeys) 'actorId': null,
  if (!omitKeys) 'actorOptionIds': null,
};

/// 서버가 투표한 사람의 기기(user 룸)에만 보내는 모양 — 같은 집계에 본인 id·고른 보기가 붙는다.
/// 옛 서버는 이 모양을 방 전체에 보냈다(남의 actorId가 그대로 왔다).
Map<String, dynamic> _actorEvent(
  Map<String, dynamic> poll,
  String actorId,
  List<String> optionIds,
) => {..._roomEvent(poll), 'actorId': actorId, 'actorOptionIds': optionIds};

PollUpdatedEvent _event(Map<String, dynamic> json) =>
    PollUpdatedEvent.fromJson(json);

Poll _apply(Poll? current, PollUpdatedEvent e) => Poll.applyUpdate(
  current,
  e.poll,
  actorId: e.actorId,
  actorOptionIds: e.actorOptionIds,
  myUserId: 'me',
);

List<int> _counts(Poll p) => [for (final o in p.options) o.voteCount];

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
  session.rooms.add(_topic('r1'));
  return session;
}

Finder _key(String k) => find.byKey(ValueKey(k));

void main() {
  group('Poll.applyUpdate — 익명 투표 알림의 두 모양', () {
    final before = Poll.fromJson(
      _anonPoll(myOptionIds: ['o1'], favorite: true),
    );

    test('방 전체 알림(actor 없음) — 표 수만 바뀌고 내 선택·즐겨찾기는 그대로, 투표자 목록은 없다', () {
      for (final omitKeys in [false, true]) {
        final e = _event(
          _roomEvent(
            _anonPoll(voterCount: 4, counts: [2, 2, 0]),
            omitKeys: omitKeys,
          ),
        );
        expect(e.actorId, isNull);
        expect(e.actorOptionIds, isNull);
        final next = _apply(before, e);
        expect(next.voterCount, 4);
        expect(_counts(next), [2, 2, 0]);
        expect(next.myOptionIds, ['o1']);
        expect(next.favorite, isTrue);
        expect(next.anonymous, isTrue);
        expect(next.options.every((o) => o.voters == null), isTrue);
      }
    });

    test('내 기기로 온 알림(actorId = 나) — 다른 기기에서 고른 보기로 바뀌고, 취소면 비워진다', () {
      final revoted = _apply(
        before,
        _event(_actorEvent(_anonPoll(counts: [1, 2, 0]), 'me', ['o2'])),
      );
      expect(revoted.myOptionIds, ['o2']);
      expect(_counts(revoted), [1, 2, 0]);
      expect(revoted.favorite, isTrue);

      final cancelled = _apply(
        revoted,
        _event(
          _actorEvent(
            _anonPoll(voterCount: 2, counts: [1, 1, 0]),
            'me',
            const [],
          ),
        ),
      );
      expect(cancelled.myOptionIds, isEmpty);
      expect(cancelled.hasVoted, isFalse);
      expect(cancelled.voterCount, 2);
    });

    test('두 알림을 어느 순서로 몇 번 받아도 표 수는 서버가 보낸 절대값 그대로(두 번 세지 않는다)', () {
      final snapshot = _anonPoll(voterCount: 4, counts: [2, 2, 0]);
      final room = _event(_roomEvent(snapshot));
      final mine = _event(_actorEvent(snapshot, 'me', ['o2']));
      final start = Poll.fromJson(_anonPoll(myOptionIds: ['o1']));
      for (final order in [
        [room, mine],
        [mine, room],
        [room, mine, room, mine],
        [mine, mine, room, room],
      ]) {
        final result = order.fold<Poll>(start, _apply);
        expect(result.voterCount, 4, reason: '$order');
        expect(_counts(result), [2, 2, 0]);
        expect(result.myOptionIds, ['o2']);
      }
    });

    test('옛 서버 모양(방 알림에 남의 actorId·actorOptionIds) — 남의 선택을 내 선택으로 쓰지 않는다', () {
      final next = _apply(
        before,
        _event(_actorEvent(_anonPoll(voterCount: 4), 'u3', ['o3'])),
      );
      expect(next.voterCount, 4);
      expect(next.myOptionIds, ['o1']);
      // 아직 투표하지 않은 사람에게도 남의 선택이 내 선택으로 둔갑하지 않는다.
      final fresh = _apply(
        Poll.fromJson(_anonPoll()),
        _event(_actorEvent(_anonPoll(voterCount: 4), 'u3', ['o3'])),
      );
      expect(fresh.myOptionIds, isEmpty);
    });
  });

  test('세션(방 화면) — 남의 투표 알림은 표 수만, 내 다른 기기의 투표 알림은 내 선택까지 바뀐다', () async {
    final server = _Server();
    server.on(
      'GET',
      '/api/rooms/r1/messages',
      (_) => _json([_message(_anonPoll())]),
    );
    final session = _session(server);
    final controller = session.controllerFor(session.rooms.first);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final message = controller.messages.single;
    expect(message.poll!.hasVoted, isFalse);

    // 남(u3)이 투표 — 서버는 방에 actor 없이 보낸다.
    session.handlePollUpdated(
      _event(_roomEvent(_anonPoll(voterCount: 4, counts: [2, 1, 1]))),
    );
    expect(message.poll!.voterCount, 4);
    expect(_counts(message.poll!), [2, 1, 1]);
    expect(message.poll!.myOptionIds, isEmpty);

    // 내 폰에서 투표 — 이 기기(PC)에는 user 룸으로 내 선택이 온다.
    session.handlePollUpdated(
      _event(
        _actorEvent(_anonPoll(voterCount: 5, counts: [2, 2, 1]), 'me', ['o2']),
      ),
    );
    expect(message.poll!.voterCount, 5);
    expect(message.poll!.myOptionIds, ['o2']);

    // 그 뒤 남의 투표 알림이 와도 내 선택은 지워지지 않는다.
    session.handlePollUpdated(
      _event(_roomEvent(_anonPoll(voterCount: 6, counts: [3, 2, 1]))),
    );
    expect(message.poll!.voterCount, 6);
    expect(message.poll!.myOptionIds, ['o2']);
  });

  testWidgets(
    '투표 목록 패널 — 남의 투표 알림은 참여자 수만, 내 다른 기기의 투표 알림은 "다시 투표하기"와 내 선택 표시까지',
    (tester) async {
      final server = _Server();
      server.on(
        'GET',
        '/api/polls',
        (_) => _json({
          'items': [
            {..._message(_anonPoll()), 'roomName': '공지방'},
          ],
          'hasMore': false,
          'total': 1,
          'nextBefore': null,
        }),
      );
      final session = _session(server);
      tester.view.physicalSize = const Size(480, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PollsScreen(session: session)),
        ),
      );
      await tester.pumpAndSettle();

      Finder inCard(Finder f) =>
          find.descendant(of: _key('polls-item-m1'), matching: f);
      expect(inCard(find.text('참여자 3명')), findsOneWidget);
      expect(inCard(_key('poll-vote-button')), findsOneWidget);

      // 남의 투표 — 표 수만 바뀌고 나는 여전히 투표 전이다.
      session.handlePollUpdated(
        _event(_roomEvent(_anonPoll(voterCount: 4, counts: [2, 2, 0]))),
      );
      await tester.pumpAndSettle();
      expect(inCard(find.text('참여자 4명')), findsOneWidget);
      expect(inCard(_key('poll-vote-button')), findsOneWidget);
      expect(inCard(_key('poll-revote-button')), findsNothing);

      // 내 다른 기기에서 o2에 투표 — 이 패널도 "다시 투표하기"와 내 선택(체크) 표시로 바뀐다.
      session.handlePollUpdated(
        _event(
          _actorEvent(_anonPoll(voterCount: 5, counts: [2, 3, 0]), 'me', [
            'o2',
          ]),
        ),
      );
      await tester.pumpAndSettle();
      expect(inCard(find.text('참여자 5명')), findsOneWidget);
      expect(inCard(_key('poll-revote-button')), findsOneWidget);
      expect(
        find.descendant(
          of: _key('poll-option-o2'),
          matching: find.byIcon(Icons.check_circle),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _key('poll-option-o1'),
          matching: find.byIcon(Icons.check_circle),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    },
  );
}
