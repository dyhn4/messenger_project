import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:client/widgets/app_menu_button.dart';
import 'package:client/widgets/board_view.dart';
import 'package:client/widgets/chat_input_bar.dart';
import 'package:client/widgets/message_actions.dart';
import 'package:client/widgets/message_bubble.dart';
import 'package:client/widgets/poll_card.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 투표(poll) — 모델·소켓 갱신 규칙·검증, 투표 카드(단일/복수·익명/기명·마감·재투표·더보기 메뉴), 만들기 화면,
/// 입력칸/메뉴 진입점, 즐겨찾기 목록. 서버는 요청을 기록하는 가짜 HTTP 클라이언트로 대신한다.

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
    bool replyable = false,
  }) async {}
}

typedef _Handler = FutureOr<http.Response> Function(http.Request request);

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json'},
);

Map<String, dynamic> _body(http.Request r) =>
    jsonDecode(r.body) as Map<String, dynamic>;

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
}

// ── 데이터 ──────────────────────────────────────────────────────────

Map<String, dynamic> _user(String id, String name, {String role = 'member'}) =>
    {'id': id, 'username': id, 'name': name, 'role': role};

final _members = [_user('me', '나'), _user('u2', '김철수'), _user('u3', '이영희')];

Room _topic(String id, {bool board = false, List<String> admins = const []}) =>
    Room.fromJson({
      'id': id,
      'teamId': 't1',
      'type': 'topic',
      'name': '공지방',
      'members': _members,
      'createdAt': 1000,
      'viewMode': board ? 'board' : 'chat',
      'adminIds': admins,
    });

Room _dm(String id, Map<String, dynamic> other) => Room.fromJson({
  'id': id,
  'teamId': 't1',
  'type': 'dm',
  'name': null,
  'members': [_user('me', '나'), other],
  'createdAt': 1000,
});

Room _secretDm() => Room.fromJson({
  'id': 'r-secret',
  'teamId': 't1',
  'type': 'dm',
  'name': null,
  'members': [_user('me', '나'), _user('u4', '박비밀')],
  'createdAt': 1000,
  'isSecret': true,
});

Map<String, dynamic> _option(
  String id,
  String text, {
  int votes = 0,
  List<Map<String, String>>? voters,
}) => {'id': id, 'text': text, 'voteCount': votes, 'voters': ?voters};

Map<String, dynamic> _pollJson({
  String id = 'p1',
  String title = '점심 뭐 먹을까요?',
  String? description,
  bool anonymous = false,
  bool multiple = false,
  DateTime? closesAt,
  DateTime? closedAt,
  bool closed = false,
  String creatorId = 'u2',
  int? voterCount,
  List<Map<String, dynamic>>? options,
  List<String> myOptionIds = const [],
  bool favorite = false,
}) {
  final opts =
      options ??
      [
        _option(
          'o1',
          '한식',
          votes: 2,
          voters: anonymous
              ? null
              : [
                  {'userId': 'u2', 'name': '김철수'},
                  {'userId': 'u3', 'name': '이영희'},
                ],
        ),
        _option(
          'o2',
          '중식',
          votes: 1,
          voters: anonymous
              ? null
              : [
                  {'userId': 'me', 'name': '나'},
                ],
        ),
        _option('o3', '일식', voters: anonymous ? null : []),
      ];
  return {
    'id': id,
    'title': title,
    'description': description,
    'anonymous': anonymous,
    'multiple': multiple,
    'closesAt': (closesAt ?? DateTime.now().add(const Duration(days: 1)))
        .millisecondsSinceEpoch,
    'closedAt': closedAt?.millisecondsSinceEpoch,
    'closed': closed,
    'creatorId': creatorId,
    'voterCount': voterCount ?? 3,
    'options': opts,
    'myOptionIds': myOptionIds,
    'favorite': favorite,
  };
}

Map<String, dynamic> _messageJson({
  String id = 'm1',
  String roomId = 'r1',
  String senderId = 'u2',
  Map<String, dynamic>? poll,
  bool deleted = false,
}) {
  final p = poll ?? _pollJson();
  return {
    'id': id,
    'roomId': roomId,
    'senderId': senderId,
    'senderName': senderId == 'me' ? '나' : '김철수',
    'type': 'poll',
    'text': p['title'],
    'createdAt': 5000,
    'deleted': deleted,
    'poll': deleted ? null : p,
    'attachments': const <Object>[],
  };
}

Session _session(_Server server, {List<Room>? rooms}) {
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
  session.rooms.addAll(rooms ?? [_topic('r1')]);
  return session;
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpCard(
  WidgetTester tester,
  Session session,
  Message message, {
  Size size = const Size(400, 900),
  void Function(Message)? onOpenThread,
  VoidCallback? onChanged,
}) async {
  _size(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: PollCard(
            session: session,
            message: message,
            onOpenThread: onOpenThread,
            onChanged: onChanged,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _opt(String id) => find.byKey(ValueKey('poll-option-$id'));
Finder get _voteButton => find.byKey(const ValueKey('poll-vote-button'));
Finder get _revoteButton => find.byKey(const ValueKey('poll-revote-button'));

FilledButton _vote(WidgetTester tester) =>
    tester.widget<FilledButton>(_voteButton);

void main() {
  // ────────────────────────── 모델 ──────────────────────────
  group('Poll 모델', () {
    test('fromJson — 기명 투표는 voters가 있고 익명 투표는 voters 키가 없다', () {
      final named = Poll.fromJson(_pollJson(myOptionIds: ['o2']));
      expect(named.title, '점심 뭐 먹을까요?');
      expect(named.options.map((o) => o.text), ['한식', '중식', '일식']);
      expect(named.options.first.voters!.map((v) => v.name), ['김철수', '이영희']);
      expect(named.voterCount, 3);
      expect(named.myOptionIds, ['o2']);
      expect(named.hasVoted, isTrue);
      expect(named.favorite, isFalse);

      final anon = Poll.fromJson(_pollJson(anonymous: true));
      expect(anon.anonymous, isTrue);
      expect(anon.options.every((o) => o.voters == null), isTrue);
    });

    test('비율은 투표한 사람 수 기준(복수 선택이면 합이 100%를 넘을 수 있다)', () {
      final poll = Poll.fromJson(
        _pollJson(
          multiple: true,
          voterCount: 2,
          options: [_option('o1', 'A', votes: 2), _option('o2', 'B', votes: 2)],
        ),
      );
      expect(poll.ratioOf(poll.options[0]), 1.0);
      expect(poll.ratioOf(poll.options[1]), 1.0);
      final empty = Poll.fromJson(_pollJson(voterCount: 0));
      expect(empty.ratioOf(empty.options.first), 0);
    });

    test('마감 — 서버 closed·closedAt에 더해 마감 시각이 지났으면 클라이언트도 마감으로 본다', () {
      expect(Poll.fromJson(_pollJson()).isClosed(), isFalse);
      expect(Poll.fromJson(_pollJson(closed: true)).isClosed(), isTrue);
      expect(
        Poll.fromJson(_pollJson(closedAt: DateTime.now())).isClosed(),
        isTrue,
      );
      final expired = Poll.fromJson(
        _pollJson(
          closesAt: DateTime.now().subtract(const Duration(seconds: 1)),
        ),
      );
      expect(expired.closed, isFalse);
      expect(expired.isClosed(), isTrue);
      // 시각을 넘겨서 미래/과거를 가른다.
      final poll = Poll.fromJson(_pollJson(closesAt: DateTime(2030, 1, 1, 9)));
      expect(poll.isClosed(DateTime(2029, 12, 31)), isFalse);
      expect(poll.isClosed(DateTime(2030, 1, 1, 9)), isTrue);
    });

    test(
      'Message.fromJson — type poll이면 isPoll과 poll이 채워지고, 삭제된 투표는 poll이 null',
      () {
        final m = Message.fromJson(_messageJson());
        expect(m.isPoll, isTrue);
        expect(m.isPost, isFalse);
        expect(m.type, MessageType.text); // 예전 화면에서도 제목이 글로 보인다.
        expect(m.text, '점심 뭐 먹을까요?');
        expect(m.poll!.id, 'p1');

        final deleted = Message.fromJson(_messageJson(deleted: true));
        expect(deleted.isPoll, isTrue);
        expect(deleted.poll, isNull);
        expect(deleted.deleted, isTrue);

        final plain = Message.fromJson({..._messageJson(), 'type': 'text'});
        expect(plain.isPoll, isFalse);
      },
    );

    test('문구 — 미리보기와 마감 시각 표시', () {
      expect(pollPreviewText('점심'), '[투표] 점심');
      final now = DateTime(2026, 5, 1);
      expect(
        formatPollTime(DateTime(2026, 5, 30, 18, 0), now: now),
        '5월 30일 오후 6:00',
      );
      expect(
        formatPollTime(DateTime(2026, 5, 30, 0, 5), now: now),
        '5월 30일 오전 12:05',
      );
      expect(
        formatPollTime(DateTime(2027, 1, 2, 12, 30), now: now),
        '2027년 1월 2일 오후 12:30',
      );
    });
  });

  group('poll:updated 받는 쪽 규칙', () {
    final base = Poll.fromJson(_pollJson(myOptionIds: ['o1'], favorite: true));
    // 서버 이벤트의 poll은 모두에게 같은 중립값이다.
    final neutral = Poll.fromJson(
      _pollJson(
        voterCount: 4,
        options: [
          _option('o1', '한식', votes: 2),
          _option('o2', '중식', votes: 2),
          _option('o3', '일식'),
        ],
      ),
    );

    test('남이 투표한 이벤트 — 표 수는 갈아끼우되 내 선택·즐겨찾기는 직전 값을 유지', () {
      final next = Poll.applyUpdate(
        base,
        neutral,
        actorId: 'u2',
        actorOptionIds: ['o2'],
        myUserId: 'me',
      );
      expect(next.voterCount, 4);
      expect(next.options[1].voteCount, 2);
      expect(next.myOptionIds, ['o1']);
      expect(next.favorite, isTrue);
    });

    test('내가(다른 기기에서) 투표한 이벤트 — 내 선택을 actorOptionIds로 바꾼다', () {
      final next = Poll.applyUpdate(
        base,
        neutral,
        actorId: 'me',
        actorOptionIds: ['o2', 'o3'],
        myUserId: 'me',
      );
      expect(next.myOptionIds, ['o2', 'o3']);
      expect(next.favorite, isTrue);
      // 내 표를 취소한 이벤트는 빈 목록이다.
      final cancelled = Poll.applyUpdate(
        base,
        neutral,
        actorId: 'me',
        actorOptionIds: const [],
        myUserId: 'me',
      );
      expect(cancelled.myOptionIds, isEmpty);
    });

    test('마감 이벤트(actorId null) — 내 선택을 지우지 않고 마감 상태만 반영', () {
      final closed = Poll.fromJson(
        _pollJson(closed: true, closedAt: DateTime.now()),
      );
      final next = Poll.applyUpdate(base, closed, myUserId: 'me');
      expect(next.isClosed(), isTrue);
      expect(next.myOptionIds, ['o1']);
      expect(next.favorite, isTrue);
    });

    test('이벤트 JSON 파싱', () {
      final e = PollUpdatedEvent.fromJson({
        'roomId': 'r1',
        'messageId': 'm1',
        'pollId': 'p1',
        'poll': _pollJson(),
        'actorId': 'u2',
        'actorOptionIds': ['o1'],
      });
      expect(e.actorId, 'u2');
      expect(e.actorOptionIds, ['o1']);
      final close = PollUpdatedEvent.fromJson({
        'roomId': 'r1',
        'messageId': 'm1',
        'pollId': 'p1',
        'poll': _pollJson(),
        'actorId': null,
        'actorOptionIds': null,
      });
      expect(close.actorId, isNull);
      expect(close.actorOptionIds, isNull);
      final fav = PollFavoriteEvent.fromJson({
        'messageId': 'm1',
        'pollId': 'p1',
        'favorite': true,
      });
      expect(fav.favorite, isTrue);
    });

    test('세션 — 소켓 이벤트가 열린 방의 메시지 poll을 규칙대로 바꾼다', () async {
      final server = _Server();
      server.on(
        'GET',
        '/api/rooms/r1/messages',
        (_) => _json([
          _messageJson(poll: _pollJson(myOptionIds: ['o1'])),
        ]),
      );
      final session = _session(server);
      final controller = session.controllerFor(session.rooms.first);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final message = controller.messages.single;
      expect(message.poll!.myOptionIds, ['o1']);

      // 남의 투표.
      session.handlePollUpdated(
        PollUpdatedEvent.fromJson({
          'roomId': 'r1',
          'messageId': 'm1',
          'pollId': 'p1',
          'poll': _pollJson(voterCount: 9),
          'actorId': 'u3',
          'actorOptionIds': ['o3'],
        }),
      );
      expect(message.poll!.voterCount, 9);
      expect(message.poll!.myOptionIds, ['o1']);

      // 내 다른 기기의 재투표.
      session.handlePollUpdated(
        PollUpdatedEvent.fromJson({
          'roomId': 'r1',
          'messageId': 'm1',
          'pollId': 'p1',
          'poll': _pollJson(voterCount: 9),
          'actorId': 'me',
          'actorOptionIds': ['o2'],
        }),
      );
      expect(message.poll!.myOptionIds, ['o2']);

      // 즐겨찾기(내 다른 기기).
      session.handlePollFavorite(
        const PollFavoriteEvent(messageId: 'm1', pollId: 'p1', favorite: true),
      );
      expect(message.poll!.favorite, isTrue);
      // 모르는 방/메시지의 이벤트는 조용히 무시한다.
      session.handlePollUpdated(
        PollUpdatedEvent.fromJson({
          'roomId': 'other',
          'messageId': 'zz',
          'pollId': 'zz',
          'poll': _pollJson(id: 'zz'),
          'actorId': null,
          'actorOptionIds': null,
        }),
      );
      expect(message.poll!.voterCount, 9);
    });
  });

  group('투표 만들기 검증', () {
    final closes = DateTime.now().add(const Duration(days: 1));
    test('제목·보기·마감 시각이 다 맞아야 ok', () {
      expect(
        checkPollDraft(title: ' 제목 ', options: ['가', '나'], closesAt: closes).ok,
        isTrue,
      );
      expect(
        checkPollDraft(
          title: '  ',
          options: ['가', '나'],
          closesAt: closes,
        ).titleError,
        isNotNull,
      );
      expect(
        checkPollDraft(
          title: 'x' * 101,
          options: ['가', '나'],
          closesAt: closes,
        ).titleError,
        isNotNull,
      );
    });

    test('보기는 비지 않은 것이 2개 이상, 공백을 뗀 뒤 중복이면 그 칸에 오류', () {
      expect(
        checkPollDraft(
          title: 't',
          options: ['가', ' '],
          closesAt: closes,
        ).optionsError,
        isNotNull,
      );
      final dup = checkPollDraft(
        title: 't',
        options: ['가', ' 가 ', '나'],
        closesAt: closes,
      );
      expect(dup.ok, isFalse);
      expect(dup.optionErrors, [null, '같은 보기가 있습니다.', null]);
      expect(
        checkPollDraft(
          title: 't',
          options: ['가', 'y' * 101],
          closesAt: closes,
        ).optionErrors.last,
        isNotNull,
      );
    });

    test('마감 시각 — 과거·90일 초과·없음은 오류', () {
      final now = DateTime(2026, 5, 1, 12);
      String? err(DateTime? at) => checkPollDraft(
        title: 't',
        options: ['가', '나'],
        closesAt: at,
        now: now,
      ).closesAtError;
      expect(err(null), isNotNull);
      expect(err(now), isNotNull);
      expect(err(now.subtract(const Duration(minutes: 1))), isNotNull);
      expect(err(now.add(const Duration(days: 90, minutes: 1))), isNotNull);
      expect(err(now.add(const Duration(days: 90))), isNull);
      expect(err(now.add(const Duration(minutes: 15))), isNull);
    });
  });

  // ────────────────────────── 카드 ──────────────────────────
  group('PollCard', () {
    testWidgets('단일 선택 — 고르면 투표하기가 켜지고, 투표하면 PUT 후 결과 화면이 된다', (tester) async {
      final server = _Server();
      server.on('PUT', '/api/polls/p1/vote', (r) {
        expect(_body(r)['optionIds'], ['o2']);
        return _json(_pollJson(myOptionIds: ['o2'], voterCount: 4));
      });
      final session = _session(server);
      final message = Message.fromJson(_messageJson());
      await _pumpCard(tester, session, message);

      expect(find.text('점심 뭐 먹을까요?'), findsOneWidget);
      expect(find.text('참여자 3명'), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(3));
      expect(_vote(tester).onPressed, isNull); // 아직 안 골랐다.
      expect(_revoteButton, findsNothing);

      await tester.tap(_opt('o1'));
      await tester.pump();
      expect(_vote(tester).onPressed, isNotNull);
      // 단일 선택은 다른 보기를 누르면 선택이 옮겨 간다.
      await tester.tap(_opt('o2'));
      await tester.pump();
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);

      await tester.tap(_voteButton);
      await tester.pumpAndSettle();

      expect(server.called('PUT', '/api/polls/p1/vote'), hasLength(1));
      expect(message.poll!.myOptionIds, ['o2']);
      expect(find.text('참여자 4명'), findsOneWidget);
      // 결과 화면 — 라디오 대신 내가 고른 표시, 그리고 "다시 투표하기".
      expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(_revoteButton, findsOneWidget);
      expect(_voteButton, findsNothing);
    });

    testWidgets('복수 선택 — 체크박스로 여러 개를 고르고, 순서대로 보낸다', (tester) async {
      final server = _Server();
      List<dynamic>? sent;
      server.on('PUT', '/api/polls/p1/vote', (r) {
        sent = _body(r)['optionIds'] as List;
        return _json(_pollJson(multiple: true, myOptionIds: ['o1', 'o3']));
      });
      final session = _session(server);
      final message = Message.fromJson(
        _messageJson(poll: _pollJson(multiple: true)),
      );
      await _pumpCard(tester, session, message);

      expect(find.text('복수 선택'), findsOneWidget); // 배지
      expect(find.byIcon(Icons.check_box_outline_blank), findsNWidgets(3));
      await tester.tap(_opt('o3'));
      await tester.pump();
      await tester.tap(_opt('o1'));
      await tester.pump();
      expect(find.byIcon(Icons.check_box), findsNWidgets(2));
      // 눌러서 다시 빼면 선택이 풀린다.
      await tester.tap(_opt('o2'));
      await tester.pump();
      await tester.tap(_opt('o2'));
      await tester.pump();
      expect(find.byIcon(Icons.check_box), findsNWidgets(2));

      await tester.tap(_voteButton);
      await tester.pumpAndSettle();
      expect(sent, ['o1', 'o3']); // 보기 순서대로.
    });

    testWidgets('기명 투표 — 득표 수를 누르면 투표자 이름 목록, 표가 없는 보기는 누를 수 없다', (
      tester,
    ) async {
      final session = _session(_Server());
      final message = Message.fromJson(_messageJson());
      await _pumpCard(tester, session, message);

      expect(find.text('익명 투표'), findsNothing);
      expect(find.text('2표 · 67%'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('poll-count-o1')));
      await tester.pumpAndSettle();
      expect(find.text('한식 · 2표'), findsOneWidget);
      expect(find.text('김철수'), findsOneWidget);
      expect(find.text('이영희'), findsOneWidget);
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('poll-count-o3')), findsNothing);
    });

    testWidgets('익명 투표 — 배지가 붙고 득표 수를 눌러도 투표자를 볼 수 없다', (tester) async {
      final session = _session(_Server());
      final message = Message.fromJson(
        _messageJson(poll: _pollJson(anonymous: true)),
      );
      await _pumpCard(tester, session, message);

      expect(find.text('익명 투표'), findsOneWidget);
      expect(find.text('2표 · 67%'), findsOneWidget);
      expect(find.byKey(const ValueKey('poll-count-o1')), findsNothing);
    });

    testWidgets('마감됨 — 서버 closed이든 마감 시각이 지났든 투표 버튼이 없고 보기를 눌러도 안 고른다', (
      tester,
    ) async {
      for (final poll in [
        _pollJson(closed: true, closedAt: DateTime(2026, 5, 30, 18)),
        _pollJson(closesAt: DateTime.now().subtract(const Duration(hours: 1))),
      ]) {
        final server = _Server();
        final session = _session(server);
        final message = Message.fromJson(_messageJson(poll: poll));
        await _pumpCard(tester, session, message);

        expect(find.text('마감됨'), findsWidgets);
        expect(_voteButton, findsNothing);
        expect(_revoteButton, findsNothing);
        expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);
        await tester.tap(_opt('o1'));
        await tester.pump();
        expect(server.called('PUT', '/api/polls/p1/vote'), isEmpty);
        // 결과(막대·득표 수)는 그대로 보인다.
        expect(find.text('2표 · 67%'), findsOneWidget);
      }
    });

    testWidgets('마감 시각이 화면에 떠 있는 동안 지나면 카드가 마감으로 바뀐다', (tester) async {
      final session = _session(_Server());
      final message = Message.fromJson(
        _messageJson(
          poll: _pollJson(
            closesAt: DateTime.now().add(const Duration(milliseconds: 600)),
          ),
        ),
      );
      await _pumpCard(tester, session, message);
      expect(_voteButton, findsOneWidget);
      // DateTime.now()는 가짜 시계를 따르지 않아서, 실제 시간을 흘려보낸 뒤 타이머를 터뜨린다.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 900)),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(_voteButton, findsNothing);
      expect(find.text('마감됨'), findsWidgets);
    });

    testWidgets('마감 시각 문구 — "~ 5월 30일 오후 6:00 마감"', (tester) async {
      final session = _session(_Server());
      final at = DateTime.now().add(const Duration(days: 3));
      final message = Message.fromJson(
        _messageJson(poll: _pollJson(closesAt: at)),
      );
      await _pumpCard(tester, session, message);
      expect(find.text('~ ${formatPollTime(at)} 마감'), findsOneWidget);
    });

    testWidgets('재투표 — 이미 투표했으면 "다시 투표하기", 바꿔야 투표하기가 켜지고 취소하면 원래대로', (
      tester,
    ) async {
      final server = _Server();
      server.on('PUT', '/api/polls/p1/vote', (r) {
        expect(_body(r)['optionIds'], ['o3']);
        return _json(_pollJson(myOptionIds: ['o3']));
      });
      final session = _session(server);
      final message = Message.fromJson(
        _messageJson(poll: _pollJson(myOptionIds: ['o1'])),
      );
      await _pumpCard(tester, session, message);

      expect(_voteButton, findsNothing);
      await tester.tap(_revoteButton);
      await tester.pump();
      // 지금 내 선택이 미리 체크돼 있고, 그대로면 투표하기는 꺼져 있다.
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
      expect(_vote(tester).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('poll-revote-cancel')));
      await tester.pump();
      expect(_revoteButton, findsOneWidget);

      await tester.tap(_revoteButton);
      await tester.pump();
      await tester.tap(_opt('o3'));
      await tester.pump();
      expect(_vote(tester).onPressed, isNotNull);
      await tester.tap(_voteButton);
      await tester.pumpAndSettle();
      expect(message.poll!.myOptionIds, ['o3']);
      expect(_revoteButton, findsOneWidget);
    });

    testWidgets('투표 실패 — 서버 문구를 카드 안에 보여 주고 선택은 유지한다', (tester) async {
      final server = _Server();
      server.on(
        'PUT',
        '/api/polls/p1/vote',
        (_) => _json({'error': '마감된 투표입니다.'}, 400),
      );
      final session = _session(server);
      final message = Message.fromJson(_messageJson());
      await _pumpCard(tester, session, message);

      await tester.tap(_opt('o1'));
      await tester.pump();
      await tester.tap(_voteButton);
      await tester.pumpAndSettle();
      expect(find.text('마감된 투표입니다.'), findsOneWidget);
      expect(_vote(tester).onPressed, isNotNull);
    });

    testWidgets('설명이 있으면 보이고, 좁은 폭(320)에서도 넘치지 않는다', (tester) async {
      final session = _session(_Server());
      final message = Message.fromJson(
        _messageJson(
          poll: _pollJson(
            description: '자세한 설명입니다',
            anonymous: true,
            multiple: true,
            title: '아주 아주 긴 투표 제목이 여러 줄로 이어지는 경우에도 문제가 없어야 합니다 정말로요',
          ),
        ),
      );
      await _pumpCard(tester, session, message, size: const Size(320, 700));
      expect(find.text('자세한 설명입니다'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('더보기 — 만든 사람은 마감·삭제가 보이고, 남은 즐겨찾기(와 댓글)만', (tester) async {
      final session = _session(_Server());
      // 남이 만든 투표.
      var opened = 0;
      final others = Message.fromJson(_messageJson());
      await _pumpCard(tester, session, others, onOpenThread: (_) => opened++);
      await tester.tap(find.byKey(const ValueKey('poll-more')));
      await tester.pumpAndSettle();
      expect(find.text('댓글'), findsOneWidget);
      expect(find.text('즐겨찾기'), findsOneWidget);
      expect(find.text('투표 마감'), findsNothing);
      expect(find.text('삭제'), findsNothing);
      await tester.tap(find.text('댓글'));
      await tester.pumpAndSettle();
      expect(opened, 1);

      // 내가 만든 투표.
      final mine = Message.fromJson(
        _messageJson(
          senderId: 'me',
          poll: _pollJson(creatorId: 'me'),
        ),
      );
      await _pumpCard(tester, session, mine);
      await tester.tap(find.byKey(const ValueKey('poll-more')));
      await tester.pumpAndSettle();
      expect(find.text('투표 마감'), findsOneWidget);
      expect(find.text('삭제'), findsOneWidget);
      expect(find.text('댓글'), findsNothing); // 댓글 진입이 없는 곳(스레드 안)에서는 뺀다.
    });

    testWidgets('더보기 — 토픽 관리자도 남의 투표를 마감·삭제할 수 있다', (tester) async {
      final session = _session(
        _Server(),
        rooms: [
          _topic('r1', admins: ['me']),
        ],
      );
      await _pumpCard(tester, session, Message.fromJson(_messageJson()));
      await tester.tap(find.byKey(const ValueKey('poll-more')));
      await tester.pumpAndSettle();
      expect(find.text('투표 마감'), findsOneWidget);
      expect(find.text('삭제'), findsOneWidget);
    });

    testWidgets('즐겨찾기 — 켜고 끄면 별 표시와 메뉴 문구가 바뀌고 PUT을 보낸다', (tester) async {
      final server = _Server();
      server.on('PUT', '/api/polls/p1/favorite', (r) {
        return _json({'favorite': _body(r)['favorite']});
      });
      final session = _session(server);
      final message = Message.fromJson(_messageJson());
      var changed = 0;
      await _pumpCard(tester, session, message, onChanged: () => changed++);

      await tester.tap(find.byKey(const ValueKey('poll-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('즐겨찾기'));
      await tester.pumpAndSettle();
      expect(_body(server.called('PUT', '/api/polls/p1/favorite').single), {
        'favorite': true,
      });
      expect(message.poll!.favorite, isTrue);
      expect(find.byKey(const ValueKey('poll-favorite-star')), findsOneWidget);
      expect(changed, 1);
      await tester.pump(const Duration(seconds: 3)); // 토스트

      await tester.tap(find.byKey(const ValueKey('poll-more')));
      await tester.pumpAndSettle();
      expect(find.text('즐겨찾기 해제'), findsOneWidget);
      await tester.tap(find.text('즐겨찾기 해제'));
      await tester.pumpAndSettle();
      expect(message.poll!.favorite, isFalse);
      expect(find.byKey(const ValueKey('poll-favorite-star')), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('투표 마감 — 확인 후 POST, 마감 상태로 바뀐다', (tester) async {
      final server = _Server();
      server.on('POST', '/api/polls/p1/close', (_) {
        return _json(
          _pollJson(creatorId: 'me', closed: true, closedAt: DateTime.now()),
        );
      });
      final session = _session(server);
      final message = Message.fromJson(
        _messageJson(
          senderId: 'me',
          poll: _pollJson(creatorId: 'me'),
        ),
      );
      await _pumpCard(tester, session, message);

      await tester.tap(find.byKey(const ValueKey('poll-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('투표 마감'));
      await tester.pumpAndSettle();
      expect(find.text('투표 마감'), findsOneWidget); // 확인 창 제목
      expect(server.called('POST', '/api/polls/p1/close'), isEmpty);
      await tester.tap(find.text('마감'));
      await tester.pumpAndSettle();
      expect(server.called('POST', '/api/polls/p1/close'), hasLength(1));
      expect(message.poll!.isClosed(), isTrue);
      expect(_voteButton, findsNothing);
    });

    testWidgets('삭제 — 확인 창에서 취소하면 아무 일도 없고, 삭제하면 DELETE를 보낸다', (tester) async {
      final server = _Server();
      server.on('DELETE', '/api/messages/m1', (_) => _json({'ok': true}));
      final session = _session(server);
      final message = Message.fromJson(
        _messageJson(
          senderId: 'me',
          poll: _pollJson(creatorId: 'me'),
        ),
      );
      await _pumpCard(tester, session, message);

      Future<void> openDelete() async {
        await tester.tap(find.byKey(const ValueKey('poll-more')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('삭제'));
        await tester.pumpAndSettle();
      }

      await openDelete();
      expect(find.text('투표 삭제'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(server.called('DELETE', '/api/messages/m1'), isEmpty);

      await openDelete();
      await tester.tap(find.widgetWithText(TextButton, '삭제'));
      await tester.pumpAndSettle();
      expect(server.called('DELETE', '/api/messages/m1'), hasLength(1));
      expect(message.deleted, isTrue);
    });
  });

  // ────────────────────────── 말풍선·메뉴 ──────────────────────────
  group('채팅 말풍선', () {
    testWidgets('투표 메시지는 말풍선 안에 카드로 그려지고 호버 툴바가 없다', (tester) async {
      final session = _session(_Server());
      final message = Message.fromJson(_messageJson());
      _size(tester, const Size(500, 900));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MessageBubble(
                session: session,
                message: message,
                resolveUrl: (u) => u,
                onOpenThread: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PollCard), findsOneWidget);
      expect(find.byTooltip('댓글'), findsNothing);
    });

    testWidgets('롱프레스 메뉴 — 투표는 메시지 공유·전달이 안 나온다(일반 메시지는 나온다)', (tester) async {
      final session = _session(_Server());
      Future<void> openSheet(Message m) async {
        _size(tester, const Size(500, 900));
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showMessageActionSheet(
                    context,
                    session: session,
                    message: m,
                    senderDisplayName: '김철수',
                    onOpenThread: (_) {},
                  ),
                  child: const Text('열기'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('열기'));
        await tester.pumpAndSettle();
      }

      await openSheet(Message.fromJson(_messageJson()));
      expect(find.text('메시지 공유'), findsNothing);
      expect(find.text('메시지 전달'), findsNothing);
      expect(find.text('댓글'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await openSheet(
        Message.fromJson({..._messageJson(), 'type': 'text', 'poll': null}),
      );
      expect(find.text('메시지 공유'), findsOneWidget);
      expect(find.text('메시지 전달'), findsOneWidget);
    });
  });

  // ────────────────────────── 만들기 화면 ──────────────────────────
  group('투표 만들기 화면', () {
    Future<void> openCreator(
      WidgetTester tester,
      Session session,
      Room room, {
      Size size = const Size(1280, 900),
    }) async {
      _size(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () =>
                      showPollCreator(context, session: session, room: room),
                  child: const Text('열기'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
    }

    Finder field(String key) => find.byKey(ValueKey(key));

    /// 폼은 스크롤 목록이라 화면 밖 칸은 아직 만들어지지 않는다 — 보일 때까지 밀어 올린다.
    Future<void> reveal(WidgetTester tester, Finder target) async {
      await tester.scrollUntilVisible(
        target,
        200,
        scrollable: find
            .descendant(
              of: find.byType(PollCreator),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
    }

    FilledButton submit(WidgetTester tester) => tester.widget<FilledButton>(
      find.byKey(const ValueKey('poll-create-submit')),
    );

    testWidgets('필수 항목이 다 찰 때만 만들기가 켜지고, 수정할 수 없다는 안내가 있다', (tester) async {
      final session = _session(_Server());
      await openCreator(tester, session, session.rooms.first);

      expect(find.text('투표 만들기'), findsOneWidget);
      expect(find.textContaining('만든 뒤에 수정할 수 없습니다'), findsOneWidget);
      expect(submit(tester).onPressed, isNull);
      // 보기는 기본 2칸.
      expect(field('poll-option-field-0'), findsOneWidget);
      expect(field('poll-option-field-1'), findsOneWidget);
      expect(field('poll-option-field-2'), findsNothing);

      await tester.enterText(field('poll-title-field'), '점심 뭐 먹을까요?');
      await tester.pump();
      expect(submit(tester).onPressed, isNull);
      await tester.enterText(field('poll-option-field-0'), '한식');
      await tester.pump();
      expect(submit(tester).onPressed, isNull); // 보기 1개
      await tester.enterText(field('poll-option-field-1'), '중식');
      await tester.pump();
      expect(submit(tester).onPressed, isNotNull);

      // 제목을 지우면 다시 꺼진다.
      await tester.enterText(field('poll-title-field'), '   ');
      await tester.pump();
      expect(submit(tester).onPressed, isNull);
    });

    testWidgets('같은 보기가 있으면 그 칸에 오류가 뜨고 만들 수 없다', (tester) async {
      final session = _session(_Server());
      await openCreator(tester, session, session.rooms.first);
      await tester.enterText(field('poll-title-field'), '제목');
      await tester.enterText(field('poll-option-field-0'), '한식');
      await tester.enterText(field('poll-option-field-1'), ' 한식 ');
      await tester.pump();
      expect(find.text('같은 보기가 있습니다.'), findsOneWidget);
      expect(submit(tester).onPressed, isNull);
      await tester.enterText(field('poll-option-field-1'), '중식');
      await tester.pump();
      expect(find.text('같은 보기가 있습니다.'), findsNothing);
      expect(submit(tester).onPressed, isNotNull);
    });

    testWidgets('보기 추가는 20개까지, 3개부터 삭제할 수 있다', (tester) async {
      final session = _session(_Server());
      await openCreator(tester, session, session.rooms.first);
      expect(field('poll-option-remove-0'), findsNothing); // 2개일 때는 삭제 불가
      final add = field('poll-add-option');
      for (var i = 2; i < pollOptionsMaxCount; i++) {
        await tester.ensureVisible(add);
        await tester.tap(add);
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(add);
      expect(
        tester.widget<TextButton>(add).onPressed,
        isNull,
        reason: '20개가 되면 보기 추가가 막힌다',
      );
      expect(field('poll-option-field-19'), findsOneWidget);
      expect(field('poll-option-field-20'), findsNothing);
      await tester.ensureVisible(field('poll-option-remove-19'));
      await tester.tap(field('poll-option-remove-19'));
      await tester.pumpAndSettle();
      expect(field('poll-option-field-19'), findsNothing);
      await tester.ensureVisible(add);
      expect(tester.widget<TextButton>(add).onPressed, isNotNull);
    });

    testWidgets('만들기 — 규약대로 POST하고 성공하면 닫힌다', (tester) async {
      final server = _Server();
      server.on('POST', '/api/rooms/r1/polls', (r) {
        return _json(_messageJson(senderId: 'me'), 201);
      });
      final session = _session(server);
      await openCreator(tester, session, session.rooms.first);

      await tester.enterText(field('poll-title-field'), '  점심 뭐 먹을까요?  ');
      await tester.enterText(field('poll-option-field-0'), '한식');
      await tester.enterText(field('poll-option-field-1'), '중식');
      await reveal(tester, field('poll-anonymous-switch'));
      await tester.tap(field('poll-anonymous-switch'));
      await reveal(tester, field('poll-multiple-switch'));
      await tester.tap(field('poll-multiple-switch'));
      await reveal(tester, field('poll-description-switch'));
      await tester.tap(field('poll-description-switch'));
      await tester.pumpAndSettle();
      await reveal(tester, field('poll-description-field'));
      await tester.enterText(field('poll-description-field'), ' 자세히 ');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('poll-create-submit')));
      await tester.pumpAndSettle();

      final req = server.called('POST', '/api/rooms/r1/polls').single;
      final body = _body(req);
      expect(body['title'], '점심 뭐 먹을까요?');
      expect(body['options'], ['한식', '중식']);
      expect(body['anonymous'], true);
      expect(body['multiple'], true);
      expect(body['description'], '자세히');
      expect(body.containsKey('attachments'), isFalse);
      final closesAt = DateTime.fromMillisecondsSinceEpoch(
        body['closesAt'] as int,
      );
      // 기본 마감은 내일 같은 시각쯤(15분 단위로 올림).
      final diff = closesAt.difference(DateTime.now());
      expect(diff, greaterThan(const Duration(hours: 23)));
      expect(diff, lessThan(const Duration(hours: 25)));
      expect(closesAt.minute % 15, 0);
      expect(find.byType(PollCreator), findsNothing);
    });

    testWidgets(
      '마감 시각 — 한 칸을 누르면 달력과 그 아래 시간 드롭다운이 펼쳐지고, 날짜는 펼친 채로·시간은 고르면 닫힌다',
      (tester) async {
        final server = _Server();
        server.on('POST', '/api/rooms/r1/polls', (r) {
          return _json(_messageJson(senderId: 'me'), 201);
        });
        final session = _session(server);
        await openCreator(tester, session, session.rooms.first);

        // 날짜·시각 두 칸이 아니라 한 칸이다.
        expect(field('schedule-date'), findsNothing);
        expect(field('schedule-time'), findsNothing);
        await reveal(tester, field('schedule-datetime'));
        await tester.tap(field('schedule-datetime'));
        await tester.pumpAndSettle();
        final popup = field('schedule-datetime-popup');
        expect(popup, findsOneWidget);
        expect(find.text('시간'), findsOneWidget);
        // 시간은 버튼 목록이 아니라 드롭다운 — 칸을 누르기 전에는 목록이 없다.
        expect(field('schedule-time-list'), findsNothing);
        expect(field('schedule-time-box'), findsOneWidget);

        // 모레를 누르면 날짜만 바뀌고 판은 그대로 열려 있다(그달이 아니면 다음 달로 넘긴다).
        final now = DateTime.now();
        final day = DateTime(now.year, now.month, now.day + 2);
        if (day.month != now.month) {
          await tester.tap(find.byTooltip('다음 달'));
          await tester.pumpAndSettle();
        }
        await tester.tap(
          field('schedule-day-${day.year}-${day.month}-${day.day}'),
        );
        await tester.pumpAndSettle();
        expect(popup, findsOneWidget);

        // 시간 칸을 눌러 목록을 펼치고 오후 3:30을 고르면 닫히고, 칸에 날짜와 시각이 함께 보인다.
        await tester.tap(field('schedule-time-box'));
        await tester.pumpAndSettle();
        expect(field('schedule-time-list'), findsOneWidget);
        expect(popup, findsOneWidget);
        final slot = field('schedule-slot-${15 * 60 + 30}');
        // 목록은 지금 값 자리로 스크롤해 열린다 — 오후에 돌리면 3:30이 그보다 위라 먼저 맨 위로 올린다.
        await tester.drag(field('schedule-time-list'), const Offset(0, 10000));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          slot,
          150,
          scrollable: find.descendant(
            of: field('schedule-time-list'),
            matching: find.byType(Scrollable),
          ),
        );
        // 목록 끝에 반쯤 걸쳐 있으면 누른 자리가 목록 밖이 된다 — 다 보이게 올린 뒤 누른다.
        await tester.ensureVisible(slot);
        await tester.pumpAndSettle();
        await tester.tap(slot);
        await tester.pumpAndSettle();
        expect(popup, findsNothing);
        expect(
          find.descendant(
            of: field('schedule-datetime'),
            matching: find.textContaining('오후 3:30'),
          ),
          findsOneWidget,
        );

        await tester.enterText(field('poll-title-field'), '점심');
        await tester.enterText(field('poll-option-field-0'), '한식');
        await tester.enterText(field('poll-option-field-1'), '중식');
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('poll-create-submit')));
        await tester.pumpAndSettle();
        final body = _body(server.called('POST', '/api/rooms/r1/polls').single);
        expect(
          DateTime.fromMillisecondsSinceEpoch(body['closesAt'] as int),
          DateTime(day.year, day.month, day.day, 15, 30),
        );
      },
    );

    testWidgets('마감 시각 — 오늘의 지난 시간은 흐리고 누를 수 없다', (tester) async {
      final session = _session(_Server());
      await openCreator(tester, session, session.rooms.first);
      await reveal(tester, field('schedule-datetime'));
      await tester.tap(field('schedule-datetime'));
      await tester.pumpAndSettle();
      final now = DateTime.now();
      await tester.tap(
        field('schedule-day-${now.year}-${now.month}-${now.day}'),
      );
      await tester.pumpAndSettle();
      // 자정(오전 12:00)은 이미 지났다 — 목록을 펼쳐 맨 위로 올려 보면 눌리지 않는다.
      await tester.tap(field('schedule-time-box'));
      await tester.pumpAndSettle();
      await tester.drag(
        find
            .descendant(
              of: field('schedule-datetime-popup'),
              matching: find.byType(Scrollable),
            )
            .last,
        const Offset(0, 5000),
      );
      await tester.pumpAndSettle();
      final midnight = tester.widget<InkWell>(field('schedule-slot-0'));
      expect(midnight.onTap, isNull);
    });

    testWidgets('설명을 켜지 않으면 description을 보내지 않는다', (tester) async {
      final server = _Server();
      server.on(
        'POST',
        '/api/rooms/r1/polls',
        (_) => _json(_messageJson(senderId: 'me'), 201),
      );
      final session = _session(server);
      await openCreator(tester, session, session.rooms.first);
      await tester.enterText(field('poll-title-field'), '제목');
      await tester.enterText(field('poll-option-field-0'), 'A');
      await tester.enterText(field('poll-option-field-1'), 'B');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('poll-create-submit')));
      await tester.pumpAndSettle();
      final body = _body(server.called('POST', '/api/rooms/r1/polls').single);
      expect(body.containsKey('description'), isFalse);
      expect(body['anonymous'], false);
      expect(body['multiple'], false);
    });

    testWidgets('서버가 거절하면 그 문구를 화면에 보이고 입력은 그대로 둔다', (tester) async {
      final server = _Server();
      server.on(
        'POST',
        '/api/rooms/r1/polls',
        (_) => _json({'error': '읽기 전용 토픽입니다.'}, 403),
      );
      final session = _session(server);
      await openCreator(tester, session, session.rooms.first);
      await tester.enterText(field('poll-title-field'), '제목');
      await tester.enterText(field('poll-option-field-0'), 'A');
      await tester.enterText(field('poll-option-field-1'), 'B');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('poll-create-submit')));
      await tester.pumpAndSettle();
      expect(find.text('읽기 전용 토픽입니다.'), findsOneWidget);
      expect(find.byType(PollCreator), findsOneWidget);
      expect(submit(tester).onPressed, isNotNull); // 고쳐서 다시 시도할 수 있다.
    });

    testWidgets('쓰던 내용이 있으면 닫을 때 한 번 묻는다', (tester) async {
      final session = _session(_Server());
      await openCreator(tester, session, session.rooms.first);
      await tester.tap(field('poll-create-close')); // 비어 있으면 그냥 닫힌다.
      await tester.pumpAndSettle();
      expect(find.byType(PollCreator), findsNothing);

      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      await tester.enterText(field('poll-title-field'), '제목');
      await tester.tap(field('poll-create-close'));
      await tester.pumpAndSettle();
      expect(find.text('작성 취소'), findsOneWidget);
      await tester.tap(find.text('계속 쓰기'));
      await tester.pumpAndSettle();
      expect(find.byType(PollCreator), findsOneWidget);
    });

    testWidgets('파일 첨부는 보드 뷰 토픽에서만 보인다', (tester) async {
      final session = _session(
        _Server(),
        rooms: [_topic('r1'), _topic('r-board', board: true)],
      );
      await openCreator(tester, session, session.rooms[0]);
      expect(field('poll-attach'), findsNothing);
      await tester.tap(field('poll-create-close'));
      await tester.pumpAndSettle();

      await openCreator(tester, session, session.rooms[1]);
      await reveal(tester, field('poll-attach'));
      expect(field('poll-attach'), findsOneWidget);
      expect(find.text('0/$pollAttachmentsMaxCount'), findsOneWidget);
    });

    testWidgets('보드 토픽 — 붙인 파일이 올라가고 만들 때 attachments로 실린다(빼면 빠진다)', (
      tester,
    ) async {
      final server = _Server();
      var uploads = 0;
      server.on('POST', '/api/upload', (_) {
        uploads++;
        return _json({
          'url': '/uploads/u$uploads.txt',
          'fileName': '자료$uploads.txt',
          'size': 5,
          'mimeType': 'text/plain',
        });
      });
      server.on(
        'POST',
        '/api/rooms/r-board/polls',
        (_) => _json(_messageJson(roomId: 'r-board', senderId: 'me'), 201),
      );
      final session = _session(
        server,
        rooms: [_topic('r1'), _topic('r-board', board: true)],
      );
      final dir = Directory.systemTemp.createTempSync('poll_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      XFile file(String name) {
        final path = '${dir.path}${Platform.pathSeparator}$name';
        File(path).writeAsStringSync('hello');
        return XFile(path);
      }

      await openCreator(tester, session, session.rooms[1]);
      final creator = tester.state<PollCreatorState>(find.byType(PollCreator));
      await tester.enterText(field('poll-title-field'), '회식 장소');
      await tester.enterText(field('poll-option-field-0'), '고기');
      await tester.enterText(field('poll-option-field-1'), '회');

      creator.addFiles([file('자료1.txt'), file('자료2.txt')]);
      // 실제 파일 입출력이 끝나기를 조금씩 기다린다.
      for (var i = 0; i < 200 && (uploads < 2 || creator.debugUploading); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(uploads, 2);
      await reveal(tester, field('poll-attach'));
      expect(find.text('자료1.txt'), findsOneWidget);
      expect(find.text('2/$pollAttachmentsMaxCount'), findsOneWidget);

      // 첫 파일을 뺀다.
      await tester.tap(find.byTooltip('첨부 빼기').first);
      await tester.pumpAndSettle();
      expect(find.text('자료1.txt'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('poll-create-submit')));
      await tester.pumpAndSettle();
      final body = _body(
        server.called('POST', '/api/rooms/r-board/polls').single,
      );
      final attachments = body['attachments'] as List;
      expect(attachments, hasLength(1));
      expect((attachments.single as Map)['fileUrl'], '/uploads/u2.txt');
      expect((attachments.single as Map)['kind'], 'file');
    });

    testWidgets('모바일 폭(360)에서는 전체 화면으로 열리고 넘치지 않는다', (tester) async {
      final session = _session(_Server());
      await openCreator(
        tester,
        session,
        session.rooms.first,
        size: const Size(360, 740),
      );
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('투표 만들기'), findsOneWidget);
      await tester.enterText(field('poll-title-field'), '제목');
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  // ────────────────────────── 진입점 ──────────────────────────
  group('진입점', () {
    ChatInputBar inputBar(Session session, Room room) => ChatInputBar(
      controller: session.controllerFor(room),
      session: session,
      room: room,
      stickerPickerGroupId: Object(),
      onToggleStickerPicker: () {},
      onStickerConsumed: () {},
    );

    testWidgets('입력칸의 투표 단추 — 일반 방에는 있고 비밀 대화에는 없다', (tester) async {
      final session = _session(_Server(), rooms: [_topic('r1'), _secretDm()]);
      _size(tester, const Size(900, 700));
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: inputBar(session, session.rooms[0]))),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-poll')), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          home: Scaffold(body: inputBar(session, session.rooms[1])),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-poll')), findsNothing);
      expect(canCreatePollIn(session, session.rooms[1]), isFalse);
      expect(canCreatePollIn(session, session.rooms[0]), isTrue);
    });

    testWidgets('보드 뷰 토픽 — 투표가 카드로 보이고, 투표 만들기 단추가 있다', (tester) async {
      final server = _Server();
      server.on(
        'GET',
        '/api/rooms/r-board/messages',
        (_) => _json([_messageJson(id: 'm1', roomId: 'r-board')]),
      );
      final session = _session(server, rooms: [_topic('r-board', board: true)]);
      _size(tester, const Size(1000, 800));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BoardView(session: session, room: session.rooms.first),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PollBoardCard), findsOneWidget);
      expect(find.byType(PollCard), findsOneWidget);
      expect(find.text('점심 뭐 먹을까요?'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('board-poll')));
      await tester.pumpAndSettle();
      expect(find.byType(PollCreator), findsOneWidget);
      // 보드 토픽이라 파일 첨부가 있다.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('poll-attach')),
        200,
        scrollable: find
            .descendant(
              of: find.byType(PollCreator),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.byKey(const ValueKey('poll-attach')), findsOneWidget);
    });

    testWidgets('입력칸의 투표 단추를 누르면 투표 만들기 창이 열린다', (tester) async {
      final session = _session(_Server());
      _size(tester, const Size(900, 700));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: inputBar(session, session.rooms.first)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chat-poll')));
      await tester.pumpAndSettle();
      expect(find.byType(PollCreator), findsOneWidget);
    });

    testWidgets('넉넉한 폭에서는 별도 투표 단추, 파일 단추는 그대로', (tester) async {
      final session = _session(_Server());
      _size(tester, const Size(400, 700));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: inputBar(session, session.rooms.first)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-poll')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-attach-menu')), findsNothing);
      expect(find.byTooltip('파일 보내기'), findsOneWidget);
    });

    // (테스트는 Windows에서도 도는데, 거기엔 화면 캡처 단추가 하나 더 있어서 Android보다 단추 줄이 48 넓다 —
    // 그래서 Android 폭 312/352에 해당하는 360/400으로 확인한다.)
    // 좁은 화면에서는 단추를 하나 더 놓을 자리가 없어서 파일 단추가 (파일 · 투표) 메뉴가 된다 —
    // 어떤 폭에서도 투표 진입점이 있어야 한다.
    for (final scenario in [
      (
        '폭 360 · 화상회의 단추가 있는 토픽',
        const Size(360, 700),
        (Session s) => s.rooms.first,
      ),
      (
        '폭 400 · 화상회의+팀장 문의 단추가 있는 1:1',
        const Size(400, 700),
        (Session s) => s.rooms.last,
      ),
    ]) {
      testWidgets('${scenario.$1} — 투표 단추 대신 파일 메뉴의 "투표"로 만들 수 있고 줄이 넘치지 않는다', (
        tester,
      ) async {
        final lead = _dm('r-lead', _user('u9', '박팀장')..['position'] = '팀장');
        final session = _session(_Server(), rooms: [_topic('r1'), lead]);
        session.callsEnabled = true;
        final room = scenario.$3(session);
        _size(tester, scenario.$2);
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: inputBar(session, room))),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('chat-poll')), findsNothing);
        expect(find.byKey(const ValueKey('chat-attach-menu')), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('chat-attach-menu')));
        await tester.pumpAndSettle();
        expect(find.text('파일 보내기'), findsOneWidget);
        await tester.tap(find.text('투표'));
        await tester.pumpAndSettle();
        expect(find.byType(PollCreator), findsOneWidget);
      });
    }

    testWidgets('비밀 대화는 좁아도 투표 진입점이 없다(일반 파일 단추 그대로)', (tester) async {
      final session = _session(_Server(), rooms: [_secretDm()]);
      session.callsEnabled = true;
      _size(tester, const Size(320, 700));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: inputBar(session, session.rooms.first)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-poll')), findsNothing);
      expect(find.byKey(const ValueKey('chat-attach-menu')), findsNothing);
      expect(find.byTooltip('파일 보내기'), findsOneWidget);
    });

    testWidgets(
      '[메뉴] → 투표 → 투표 만들기 — 투표 목록 패널에서 만들기 창이 뜨고 맨 위 대화방 칸에서 방을 골라야 만들 수 있다',
      (tester) async {
        final server = _Server();
        server.on(
          'GET',
          '/api/polls',
          (_) => _json({'items': [], 'hasMore': false, 'total': 0}),
        );
        server.on('POST', '/api/rooms/r2/polls', (r) {
          return _json(_messageJson(senderId: 'me'), 201);
        });
        final readOnly = Room.fromJson({
          'id': 'r-ro',
          'teamId': 't1',
          'type': 'topic',
          'name': '읽기전용방',
          'members': _members,
          'createdAt': 1000,
          'readOnly': true,
        });
        final session = _session(
          server,
          rooms: [
            _topic('r1'),
            Room.fromJson({
              'id': 'r2',
              'teamId': 't1',
              'type': 'topic',
              'name': '영업방',
              'members': _members,
              'createdAt': 1000,
            }),
            readOnly,
            _secretDm(),
          ],
        );
        _size(tester, const Size(1280, 900));
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              appBar: AppBar(actions: [AppMenuButton(session: session)]),
            ),
          ),
        );
        await tester.tap(find.byTooltip('메뉴'));
        await tester.pumpAndSettle();
        // 예전 "투표 즐겨찾기"는 "투표"로 바뀌었고, 생성 · 리스트 · 툴 세 묶음으로 나뉜다.
        expect(find.text('투표 즐겨찾기'), findsNothing);
        expect(find.text('생성'), findsOneWidget);
        expect(find.text('리스트'), findsOneWidget);
        expect(find.text('툴'), findsOneWidget);
        await tester.tap(find.text('투표'));
        await tester.pumpAndSettle();
        // 메뉴의 "투표"는 만들기 창이 아니라 투표 목록 패널을 연다 — 상단의 "투표 만들기"가 창을 연다.
        expect(find.byType(PollsScreen), findsOneWidget);
        expect(find.byType(PollCreator), findsNothing);
        await tester.tap(find.byKey(const ValueKey('polls-create')));
        await tester.pumpAndSettle();

        expect(find.byType(PollCreator), findsOneWidget);
        // 맨 위 "대화방" 칸은 비어 있어서 방을 고르기 전에는 만들 수 없다.
        expect(find.text('대화방'), findsOneWidget);
        expect(find.text('대화방 선택'), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('poll-title-field')),
          '점심 뭐 먹을까요?',
        );
        await tester.enterText(
          find.byKey(const ValueKey('poll-option-field-0')),
          '한식',
        );
        await tester.enterText(
          find.byKey(const ValueKey('poll-option-field-1')),
          '중식',
        );
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('poll-create-submit')),
              )
              .onPressed,
          isNull,
        );

        // 고를 수 있는 방 — 읽기 전용 토픽과 비밀 대화는 목록에 없다.
        await tester.tap(find.text('대화방 선택'));
        await tester.pumpAndSettle();
        expect(find.text('공지방'), findsOneWidget);
        expect(find.text('영업방'), findsOneWidget);
        expect(find.text('읽기전용방'), findsNothing);
        expect(find.text('박비밀'), findsNothing);
        await tester.tap(find.text('영업방'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('poll-create-submit')),
              )
              .onPressed,
          isNotNull,
        );

        await tester.tap(find.byKey(const ValueKey('poll-create-submit')));
        await tester.pumpAndSettle();
        // 고른 방으로 만들어진다.
        expect(server.called('POST', '/api/rooms/r2/polls'), hasLength(1));
        expect(server.called('POST', '/api/rooms/r1/polls'), isEmpty);
        expect(find.byType(PollCreator), findsNothing);
        await tester.pump(const Duration(seconds: 3));
      },
    );

    testWidgets('입력창 도구모음의 투표로 열면 그 대화방이 미리 채워져 있고 바꿀 수도 있다', (tester) async {
      final server = _Server();
      server.on('POST', '/api/rooms/r2/polls', (r) {
        return _json(_messageJson(senderId: 'me'), 201);
      });
      final session = _session(
        server,
        rooms: [
          _topic('r1'),
          Room.fromJson({
            'id': 'r2',
            'teamId': 't1',
            'type': 'topic',
            'name': '영업방',
            'members': _members,
            'createdAt': 1000,
          }),
        ],
      );
      _size(tester, const Size(1280, 900));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: inputBar(session, session.rooms.first)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chat-poll')));
      await tester.pumpAndSettle();

      expect(find.byType(PollCreator), findsOneWidget);
      // 열린 방(공지방)이 대화방 칸에 들어 있다.
      expect(find.text('대화방 선택'), findsNothing);
      final field = find.byKey(const ValueKey('poll-room-field'));
      expect(
        find.descendant(of: field, matching: find.text('공지방')),
        findsOneWidget,
      );
      // 다른 방으로 바꿀 수 있다.
      await tester.tap(find.descendant(of: field, matching: find.text('공지방')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('영업방'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: field, matching: find.text('영업방')),
        findsOneWidget,
      );
    });

    testWidgets('폭 360 — 메뉴의 투표는 전체 화면 패널로 열리고 만들기 창의 대화방 칸 목록이 화면 안에 뜬다', (
      tester,
    ) async {
      final server = _Server();
      server.on(
        'GET',
        '/api/polls',
        (_) => _json({'items': [], 'hasMore': false, 'total': 0}),
      );
      final session = _session(server, rooms: [_topic('r1')]);
      _size(tester, const Size(360, 700));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(actions: [AppMenuButton(session: session)]),
          ),
        ),
      );
      await tester.tap(find.byTooltip('메뉴'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('투표'));
      await tester.pumpAndSettle();
      expect(find.byType(PollsScreen), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('polls-create')));
      await tester.pumpAndSettle();
      expect(find.byType(PollCreator), findsOneWidget);
      expect(find.byType(Dialog), findsNothing); // 좁은 화면은 전체 화면
      await tester.tap(find.text('대화방 선택'));
      await tester.pumpAndSettle();
      expect(find.text('공지방'), findsOneWidget);
      final list = tester.getRect(find.text('토픽'));
      expect(list.right, lessThanOrEqualTo(360));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('공지방'));
      await tester.pumpAndSettle();
      expect(find.text('대화방 선택'), findsNothing);
    });

    testWidgets('메뉴 드롭다운 — 폭 360에서도 넘치지 않고 타일이 모두 보인다', (tester) async {
      final session = _session(_Server());
      _size(tester, const Size(360, 640));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(actions: [AppMenuButton(session: session)]),
          ),
        ),
      );
      await tester.tap(find.byTooltip('메뉴'));
      await tester.pumpAndSettle();
      for (final label in [
        '메시지 예약',
        '투표',
        '파일',
        '즐겨찾기',
        '링크',
        '캘린더',
        '프로젝트',
        '문의함',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(tester.takeException(), isNull);
      final right = tester
          .getTopRight(find.byKey(const ValueKey('menu-favorites')))
          .dx;
      expect(right, lessThanOrEqualTo(360));
    });
  });
}
