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
import 'package:client/widgets/filter_dropdown.dart';
import 'package:client/widgets/poll_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 투표 목록 패널(PollsScreen) — 할 일 패널과 같은 틀(만들기 단추 · 필터 줄 — 참여한 대화방 / 참여 여부 · 작은 글씨 줄 —
/// 마감된 투표 제외 스위치 / 정렬(생성 순 · 기한 순) · 회색 바탕의 `N개의 투표`와 흰 카드), 서버로 가는 요청 파라미터(기간 없음),
/// 메시지 예약 패널과 같은 MenuAnchor 메뉴, 카드에서 바로 투표, 무한 스크롤,
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

/// `N개의 투표` 건수 줄(숫자만 굵은 Text.rich).
Finder _count(int n) => find.text('$n개의 투표', findRichText: true);

/// 드롭다운·작은 메뉴 단추([button])를 열고 항목([item])을 고른다.
Future<void> _pick(WidgetTester tester, String button, String item) async {
  await tester.tap(_key(button));
  await tester.pumpAndSettle();
  await tester.tap(_key(item));
  await tester.pumpAndSettle();
}

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

  testWidgets(
    '위에서부터 헤더 · 투표 만들기 · 필터 줄(대화방/참여 여부) · 마감 제외 스위치·정렬 줄 · 회색 바탕의 건수 줄 · 흰 카드, 기본 요청은 생성 순 전체 기간',
    (tester) async {
      final session = _session(server);
      await _pump(tester, session);

      final q = server.lastPollQuery;
      expect(q['teamId'], 't1');
      expect(q['order'], 'desc');
      expect(q['limit'], '20');
      expect(q.containsKey('sort'), isFalse); // 생성 순(서버 기본)
      expect(q.containsKey('status'), isFalse);
      expect(q.containsKey('participated'), isFalse);
      expect(q.containsKey('roomId'), isFalse);
      expect(q.containsKey('creatorId'), isFalse);
      // 기간 제한 없음 — 1년 전까지만 받던 since/until을 보내지 않는다.
      expect(q.containsKey('since'), isFalse);
      expect(q.containsKey('until'), isFalse);

      double top(Finder f) => tester.getTopLeft(f).dy;
      final header = find.text('투표').first;
      expect(top(header), lessThan(top(_key('polls-create'))));
      expect(top(_key('polls-create')), lessThan(top(find.text('참여한 대화방'))));
      // 필터 줄 한 줄: 참여한 대화방 · 그 오른쪽 참여 여부(같은 테두리 단추).
      final filterRow = tester.getCenter(find.text('참여한 대화방')).dy;
      expect(tester.getCenter(_key('polls-participated')).dy, filterRow);
      expect(
        tester.getRect(find.text('참여한 대화방')).right,
        lessThan(tester.getRect(_key('polls-participated')).left),
      );
      expect(tester.widget(_key('polls-participated')), isA<OutlinedButton>());
      expect(
        tester.getSize(_key('polls-participated')).height,
        tester
            .getSize(
              find
                  .ancestor(
                    of: find.text('참여한 대화방'),
                    matching: find.byType(OutlinedButton),
                  )
                  .first,
            )
            .height,
      );
      // 그 아래 작은 글씨 줄: 왼쪽 마감된 투표 제외(스위치 · 글자), 오른쪽 끝 정렬.
      expect(filterRow, lessThan(top(_key('polls-exclude-closed'))));
      final optionRow = tester.getCenter(_key('polls-exclude-closed')).dy;
      expect(
        tester.getCenter(find.text('마감된 투표 제외')).dy,
        moreOrLessEquals(optionRow, epsilon: 1),
      );
      expect(
        tester.getCenter(_key('polls-sort')).dy,
        moreOrLessEquals(optionRow, epsilon: 1),
      );
      expect(
        tester.getRect(_key('polls-exclude-closed')).right,
        lessThanOrEqualTo(tester.getRect(find.text('마감된 투표 제외')).left),
      );
      expect(
        tester.getRect(find.text('마감된 투표 제외')).right,
        lessThan(tester.getRect(_key('polls-sort')).left),
      );
      expect(tester.getRect(_key('polls-sort')).right, 480 - 12);
      expect(tester.widget<Switch>(_key('polls-exclude-closed')).value, false);
      expect(
        top(_key('polls-exclude-closed')),
        lessThan(top(_key('panel-loaded-count'))),
      );
      expect(
        top(_key('panel-loaded-count')),
        lessThan(top(_key('polls-item-m1'))),
      );

      expect(find.text('참여한 대화방'), findsOneWidget);
      expect(find.text('참여 여부'), findsOneWidget);
      expect(find.text('생성 순'), findsOneWidget);
      // 없어진 필터 — 작성자(모든 멤버) · 상태(전체 상태) · 기간(1년).
      expect(find.text('모든 멤버'), findsNothing);
      expect(find.text('전체 상태'), findsNothing);
      expect(find.text('1년 (기본)'), findsNothing);
      expect(find.text('최신 순'), findsNothing);
      expect(_key('polls-status'), findsNothing);
      expect(_key('polls-creator'), findsNothing);
      expect(_key('polls-period'), findsNothing);
      // 참여 여부·정렬의 항목은 펼쳐야 보인다.
      expect(find.text('참여 안 함'), findsNothing);
      expect(find.text('기한 순'), findsNothing);
      expect(_count(2), findsOneWidget);

      // 회색 바탕 위의 흰 둥근 카드(할 일 패널과 같은 색).
      final scheme = Theme.of(tester.element(_key('polls-list'))).colorScheme;
      final background = tester.widget<ColoredBox>(
        find
            .ancestor(
              of: _key('panel-loaded-count'),
              matching: find.byType(ColoredBox),
            )
            .first,
      );
      expect(background.color, scheme.surfaceContainer);
      final card = tester.widget<Material>(_key('polls-item-m1'));
      expect(card.color, scheme.surface);
      expect(card.borderRadius, BorderRadius.circular(12));

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
    },
  );

  testWidgets(
    '참여 여부 드롭다운 — 메시지 예약 패널 정렬과 같은 MenuAnchor 메뉴(애니메이션 없이 바로 뜬다), 고르면 단추 글자가 바뀌고 서버로 거른다',
    (tester) async {
      final session = _session(server);
      await _pump(tester, session);
      final before = server.called('GET', '/api/polls').length;

      await tester.tap(_key('polls-participated'));
      await tester.pump(); // 한 프레임 만에 다 떠 있다.
      expect(find.byType(MenuItemButton), findsNWidgets(3));
      for (final p in ['all', 'yes', 'no']) {
        expect(_key('polls-participated-$p'), findsOneWidget, reason: p);
      }
      for (final label in ['전체', '참여함', '참여 안 함']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(
        find.descendant(
          of: _key('polls-participated-all'),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      // 메뉴는 단추 바로 아래.
      expect(
        tester.getTopLeft(_key('polls-participated-all')).dy,
        greaterThan(tester.getRect(_key('polls-participated')).bottom),
      );

      await tester.tap(_key('polls-participated-no'));
      await tester.pumpAndSettle();
      expect(_key('polls-participated-no'), findsNothing); // 닫혔다.
      expect(
        find.descendant(
          of: _key('polls-participated'),
          matching: find.text('참여 안 함'),
        ),
        findsOneWidget,
      );
      expect(find.text('참여 여부'), findsNothing);
      expect(server.called('GET', '/api/polls'), hasLength(before + 1));
      expect(server.lastPollQuery['participated'], 'no');

      await _pick(tester, 'polls-participated', 'polls-participated-yes');
      expect(server.lastPollQuery['participated'], 'yes');

      // 같은 것을 다시 고르면 다시 받지 않는다.
      final count = server.called('GET', '/api/polls').length;
      await _pick(tester, 'polls-participated', 'polls-participated-yes');
      expect(server.called('GET', '/api/polls'), hasLength(count));

      await _pick(tester, 'polls-participated', 'polls-participated-all');
      expect(server.lastPollQuery.containsKey('participated'), isFalse);
      expect(find.text('참여 여부'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    },
  );

  testWidgets('마감된 투표 제외 — 스위치나 글자를 누르면 켜고 끈다, 켜면 진행 중(status=open)만 받는다', (
    tester,
  ) async {
    final session = _session(server);
    await _pump(tester, session);
    final before = server.called('GET', '/api/polls').length;

    await tester.tap(_key('polls-exclude-closed'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(_key('polls-exclude-closed')).value, true);
    expect(server.called('GET', '/api/polls'), hasLength(before + 1));
    expect(server.lastPollQuery['status'], 'open');

    // 다른 필터와 함께 걸린다.
    await _pick(tester, 'polls-participated', 'polls-participated-no');
    expect(server.lastPollQuery['status'], 'open');
    expect(server.lastPollQuery['participated'], 'no');

    // 글자를 눌러도 끈다.
    await tester.tap(find.text('마감된 투표 제외'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(_key('polls-exclude-closed')).value, false);
    expect(server.lastPollQuery.containsKey('status'), isFalse);
    expect(server.lastPollQuery['participated'], 'no');
    expect(server.called('GET', '/api/polls'), hasLength(before + 3));
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets(
    '정렬 생성 순 / 기한 순 — 메시지 예약 패널과 같은 MenuAnchor 메뉴, 기한 순이면 sort=deadline으로 다시 받는다',
    (tester) async {
      final session = _session(server);
      await _pump(tester, session);
      final before = server.called('GET', '/api/polls').length;

      await tester.tap(_key('polls-sort'));
      await tester.pump(); // 한 프레임 만에 다 떠 있다.
      expect(find.byType(MenuItemButton), findsNWidgets(2));
      expect(_key('polls-sort-created'), findsOneWidget);
      expect(_key('polls-sort-deadline'), findsOneWidget);
      expect(find.text('기한 순'), findsOneWidget);
      expect(
        find.descendant(
          of: _key('polls-sort-created'),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      // 메뉴는 화면 안에 있다(오른쪽 끝 단추).
      expect(
        tester.getRect(_key('polls-sort-deadline')).right,
        lessThanOrEqualTo(480),
      );

      await tester.tap(_key('polls-sort-deadline'));
      await tester.pumpAndSettle();
      expect(_key('polls-sort-deadline'), findsNothing); // 닫혔다.
      expect(server.called('GET', '/api/polls'), hasLength(before + 1));
      expect(server.lastPollQuery['sort'], 'deadline');
      expect(
        find.descendant(of: _key('polls-sort'), matching: find.text('기한 순')),
        findsOneWidget,
      );

      // 마감 제외와 함께.
      await tester.tap(_key('polls-exclude-closed'));
      await tester.pumpAndSettle();
      expect(server.lastPollQuery['sort'], 'deadline');
      expect(server.lastPollQuery['status'], 'open');

      // 같은 것을 다시 고르면 다시 받지 않는다.
      final count = server.called('GET', '/api/polls').length;
      await _pick(tester, 'polls-sort', 'polls-sort-deadline');
      expect(server.called('GET', '/api/polls'), hasLength(count));

      await _pick(tester, 'polls-sort', 'polls-sort-created');
      expect(server.lastPollQuery.containsKey('sort'), isFalse);
      expect(server.lastPollQuery['order'], 'desc');
      expect(find.text('생성 순'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    },
  );

  for (final width in [420.0, 360.0]) {
    testWidgets(
      '폭 ${width.toInt()} — 참여한 대화방·참여 여부 단추는 할 일 패널처럼 같은 폭으로 나뉜다(고른 뒤에도)',
      (tester) async {
        final session = _session(server);
        await _pump(tester, session, size: Size(width, 900));
        Rect room() => tester.getRect(
          find
              .ancestor(
                of: find.text('참여한 대화방'),
                matching: find.byType(OutlinedButton),
              )
              .first,
        );
        Rect part() => tester.getRect(_key('polls-participated'));
        expect(part().width, closeTo(room().width, 0.5));
        expect(part().top, closeTo(room().top, 0.5));
        expect(part().left - room().right, closeTo(8, 0.5));
        await _pick(tester, 'polls-participated', 'polls-participated-no');
        expect(part().width, closeTo(room().width, 0.5));
        expect(tester.takeException(), isNull);
        await _finish(tester);
      },
    );
  }

  testWidgets('참여한 대화방을 고르면 그 방만 받고, 다른 필터·정렬은 유지한다', (tester) async {
    final session = _session(server);
    await _pump(tester, session);
    await _pick(tester, 'polls-sort', 'polls-sort-deadline');
    await _pick(tester, 'polls-participated', 'polls-participated-yes');

    await tester.tap(find.text('참여한 대화방'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('영업방').last);
    await tester.pumpAndSettle();
    final q = server.lastPollQuery;
    expect(q['roomId'], 'r2');
    expect(q['sort'], 'deadline');
    expect(q['participated'], 'yes');
    expect(q.containsKey('since'), isFalse);
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
    // 건수는 받은 20장이 아니라 서버가 센 전체 개수.
    expect(_count(22), findsOneWidget);
    expect(server.called('GET', '/api/polls'), hasLength(1));

    await tester.tap(_key('polls-exclude-closed'));
    await tester.pumpAndSettle();
    await _pick(tester, 'polls-sort', 'polls-sort-deadline');
    expect(server.called('GET', '/api/polls'), hasLength(3));

    final list = _key('polls-list');
    for (var i = 0; i < 40; i++) {
      await tester.drag(list, const Offset(0, -1500));
      await tester.pumpAndSettle();
      if (server.called('GET', '/api/polls').length > 3) break;
    }
    final more = server
        .called('GET', '/api/polls')
        .where((r) => r.url.queryParameters['before'] == 'cursor-1')
        .toList();
    expect(more, isNotEmpty);
    expect(more.first.url.queryParameters['status'], 'open');
    expect(more.first.url.queryParameters['sort'], 'deadline');
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
    expect(find.text('등록된 투표가 없습니다.'), findsOneWidget);
    expect(find.textContaining('투표 만들기'), findsNWidgets(2)); // 단추 + 안내
    expect(_count(0), findsOneWidget);

    await tester.tap(_key('polls-exclude-closed'));
    await tester.pumpAndSettle();
    expect(find.text('조건에 맞는 투표가 없습니다.'), findsOneWidget);
    expect(find.text('등록된 투표가 없습니다.'), findsNothing);

    var fail = true;
    server.on('GET', '/api/polls', (_) {
      return fail
          ? _json({'error': '서버가 바쁩니다.'}, 500)
          : _json(_page([_item('1')]));
    });
    await _pick(tester, 'polls-participated', 'polls-participated-yes');
    expect(_key('polls-error'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(_key('polls-item-m1'), findsOneWidget);
    expect(_count(1), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('받기 전에는 건수 자리에 같은 높이의 빈 줄만 둔다', (tester) async {
    final gate = Completer<void>();
    server.on('GET', '/api/polls', (_) async {
      await gate.future;
      return _json(_page([_item('1')]));
    });
    final session = _session(server);
    _size(tester, const Size(480, 1000));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PollsScreen(session: session)),
      ),
    );
    await tester.pump();
    expect(_key('panel-count-pending'), findsOneWidget);
    expect(_key('panel-loaded-count'), findsNothing);
    final pendingHeight = tester.getSize(_key('panel-count-pending')).height;
    gate.complete();
    await tester.pumpAndSettle();
    expect(_count(1), findsOneWidget);
    expect(_key('panel-count-pending'), findsNothing);
    expect(tester.getSize(_key('panel-loaded-count')).height, pendingHeight);
    await _finish(tester);
  });

  for (final width in [360.0, 390.0]) {
    testWidgets(
      '폭 ${width.toInt()} — 넘치지 않고 만들기 · 필터 줄 · 작은 글씨 줄 · 카드가 모두 화면 안에 있다',
      (tester) async {
        final session = _session(server);
        await _pump(tester, session, size: Size(width, 780));
        expect(tester.takeException(), isNull);
        void inside() {
          for (final f in [
            _key('polls-create'),
            find
                .descendant(
                  of: find.byType(RoomFilterButton),
                  matching: find.byType(OutlinedButton),
                )
                .first,
            _key('polls-participated'),
            _key('polls-exclude-closed'),
            find.text('마감된 투표 제외'),
            _key('polls-sort'),
            _key('polls-item-m1'),
          ]) {
            final rect = tester.getRect(f);
            expect(rect.left, greaterThanOrEqualTo(0), reason: '$f');
            expect(rect.right, lessThanOrEqualTo(width), reason: '$f');
          }
        }

        inside();
        // 만들기 단추는 폭을 가득 채운다(좌우 여백 16).
        final create = tester.getRect(_key('polls-create'));
        expect(create.left, 16);
        expect(create.right, width - 16);
        // 필터 줄 두 칸도 좌우 여백 16 안에 꽉 찬다.
        expect(
          tester.getRect(_key('polls-participated')).right,
          moreOrLessEquals(width - 16, epsilon: 0.5),
        );

        // 필터를 걸어 글자가 길어져도 넘치지 않는다.
        await _pick(tester, 'polls-participated', 'polls-participated-no');
        await _pick(tester, 'polls-sort', 'polls-sort-deadline');
        await tester.tap(_key('polls-exclude-closed'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('참여한 대화방'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('영업방').last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        inside();
        await _finish(tester);
      },
    );
  }
}
