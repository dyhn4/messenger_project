import 'dart:async';
import 'dart:convert';

import 'package:client/models/favorite.dart';
import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/favorites_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/favorites_api.dart';
import 'package:client/services/favorites_controller.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/app_menu_button.dart';
import 'package:client/widgets/message_actions.dart';
import 'package:client/widgets/poll_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 통합 즐겨찾기 — 모델 파싱, 컨트롤러(담은 id·쪽 나누기·소켓 동기화), 즐겨찾기 화면(탭·이동·해제·빈 상태·폭 360),
/// 메뉴 타일, 메시지·댓글 메뉴의 "즐겨찾기". 서버는 요청을 기록하는 가짜 HTTP 클라이언트로 대신한다.

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

Map<String, dynamic> _user(String id, String name) => {
  'id': id,
  'username': id,
  'name': name,
  'role': 'member',
  'department': '개발팀',
  'position': '팀장',
};

final _members = [_user('me', '나'), _user('u2', '김철수')];

Room _topic(String id, String name) => Room.fromJson({
  'id': id,
  'teamId': 't1',
  'type': 'topic',
  'name': name,
  'members': _members,
  'createdAt': 1000,
  'favorite': id == 'r1',
});

Map<String, dynamic> _message({
  String id = 'm1',
  String text = '내일 회의 자료 공유드립니다',
  String type = 'text',
}) => {
  'id': id,
  'roomId': 'r1',
  'senderId': 'u2',
  'senderName': '김철수',
  'type': type,
  'text': text,
  'createdAt': 5000,
  'deleted': false,
  'attachments': const <Object>[],
};

Map<String, dynamic> _pollMessage() => {
  ..._message(id: 'mp', text: '점심 뭐 먹을까요?', type: 'poll'),
  'poll': {
    'id': 'p1',
    'title': '점심 뭐 먹을까요?',
    'anonymous': false,
    'multiple': false,
    'closesAt': DateTime.now()
        .add(const Duration(days: 1))
        .millisecondsSinceEpoch,
    'closed': false,
    'creatorId': 'u2',
    'voterCount': 0,
    'options': [
      {'id': 'o1', 'text': '김밥', 'voteCount': 0, 'voters': <Object>[]},
      {'id': 'o2', 'text': '라면', 'voteCount': 0, 'voters': <Object>[]},
    ],
    'myOptionIds': <String>[],
    'favorite': true,
  },
};

Map<String, dynamic> _messageItem({String id = 'm1', int at = 9000}) => {
  'type': 'message',
  'favoritedAt': at,
  'roomId': 'r1',
  'roomName': '공지방',
  'message': _message(id: id),
};

Map<String, dynamic> _commentItem() => {
  'type': 'comment',
  'favoritedAt': 8000,
  'roomId': 'r1',
  'roomName': '공지방',
  'comment': {
    'id': 'c1',
    'messageId': 'm1',
    'roomId': 'r1',
    'senderId': 'u2',
    'senderName': '김철수',
    'type': 'text',
    'text': '확인했습니다',
    'createdAt': 5500,
    'deleted': false,
  },
  'parentMessage': {
    'id': 'm1',
    'senderName': '김철수',
    'type': 'text',
    'text': '내일 회의 자료',
  },
};

Map<String, dynamic> _fileItem() => {
  'type': 'file',
  'favoritedAt': 7000,
  'roomId': 'r1',
  'roomName': '공지방',
  'messageId': 'mf',
  'fileUrl': '/files/abc',
  'fileName': '보고서.pdf',
  'message': {
    ..._message(id: 'mf', text: '', type: 'file'),
    'fileUrl': '/files/abc',
    'fileName': '보고서.pdf',
  },
};

Map<String, dynamic> _pollItem() => {
  'type': 'poll',
  'favoritedAt': 6500,
  'roomId': 'r1',
  'roomName': '공지방',
  'message': _pollMessage(),
};

Map<String, dynamic> _roomItem() => {
  'type': 'room',
  'favoritedAt': null,
  'roomId': 'r1',
  'roomName': '공지방',
  'roomType': 'topic',
  'isSecret': false,
  'isSelf': false,
};

Map<String, dynamic> _memberItem() => {
  'type': 'member',
  'favoritedAt': 6000,
  'teamId': 't1',
  'user': _user('u2', '김철수'),
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

/// `GET /api/favorites`를 type별로 받아 주는 가짜 — [byType]에 없는 type은 빈 목록.
void _serveFavorites(
  _Server server,
  Map<String?, List<Map<String, dynamic>>> byType,
) {
  server.on('GET', '/api/favorites', (r) {
    final type = r.url.queryParameters['type'];
    final items = byType[type] ?? const [];
    return _json({'items': items, 'hasMore': false});
  });
}

Future<void> _openScreen(
  WidgetTester tester,
  Session session, {
  Size size = const Size(1280, 900),
  FavoriteKind? initialKind,
}) async {
  _size(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () =>
                showFavorites(context, session, initialKind: initialKind),
            child: const Text('열기'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
}

/// 컨트롤러 단위 테스트용 가짜 API.
class _FakeApi implements FavoritesApi {
  FavoriteIds ids = const FavoriteIds();
  final pages = <List<FavoriteItem>>[];
  final calls = <String>[];
  int? lastBefore;

  @override
  Future<FavoriteIds> fetchIds() async => ids;

  @override
  Future<({List<FavoriteItem> items, bool hasMore})> fetchFavorites({
    required String teamId,
    FavoriteKind? kind,
    int? before,
    int limit = 30,
  }) async {
    calls.add('GET ${kind?.name ?? 'all'} before=$before');
    lastBefore = before;
    final page = pages.isEmpty ? <FavoriteItem>[] : pages.removeAt(0);
    return (items: page, hasMore: pages.isNotEmpty);
  }

  @override
  Future<bool> setMessageFavorite(String messageId, bool favorite) async {
    calls.add('message $messageId $favorite');
    return favorite;
  }

  @override
  Future<bool> setCommentFavorite(String commentId, bool favorite) async {
    calls.add('comment $commentId $favorite');
    return favorite;
  }

  @override
  Future<bool> setMemberFavorite(
    String teamId,
    String userId,
    bool favorite,
  ) async {
    calls.add('member $teamId $userId $favorite');
    return favorite;
  }
}

FavoriteItem _item(Map<String, dynamic> json) => FavoriteItem.fromJson(json);

void main() {
  group('모델', () {
    test('FavoriteItem.fromJson — 종류마다 필요한 필드를 읽는다', () {
      final message = _item(_messageItem());
      expect(message.kind, FavoriteKind.message);
      expect(message.message!.text, '내일 회의 자료 공유드립니다');
      expect(message.roomName, '공지방');
      expect(message.favoritedAt, DateTime.fromMillisecondsSinceEpoch(9000));
      expect(message.key, 'message:m1');

      final comment = _item(_commentItem());
      expect(comment.comment!.text, '확인했습니다');
      expect(comment.comment!.messageId, 'm1');
      expect(comment.parentSender, '김철수');
      expect(comment.parentText, '내일 회의 자료');

      final file = _item(_fileItem());
      expect(file.fileName, '보고서.pdf');
      expect(file.message!.id, 'mf');
      expect(file.key, 'file:mf:보고서.pdf');

      final poll = _item(_pollItem());
      expect(poll.message!.poll!.favorite, isTrue);

      final room = _item(_roomItem());
      expect(room.favoritedAt, isNull);
      expect(room.roomType, 'topic');

      final member = _item(_memberItem());
      expect(member.user!.name, '김철수');
      expect(member.key, 'member:t1:u2');
    });

    test('FavoriteItem.fromJson — 모르는 종류는 오류', () {
      expect(
        () => FavoriteItem.fromJson({'type': 'zzz'}),
        throwsFormatException,
      );
    });

    test('FavoriteIds.fromJson — 멤버는 팀:사용자 키', () {
      final ids = FavoriteIds.fromJson({
        'messages': ['a', 'b'],
        'comments': ['c'],
        'members': [
          {'teamId': 't1', 'userId': 'u2'},
        ],
      });
      expect(ids.messages, {'a', 'b'});
      expect(ids.comments, {'c'});
      expect(ids.members, {FavoriteIds.memberKey('t1', 'u2')});
    });

    test('탭 문구와 type 값', () {
      expect(FavoriteKind.values.map((k) => k.label), [
        '메시지',
        '파일',
        '댓글',
        '투표',
        '대화방',
        '멤버',
      ]);
      expect(FavoriteKindInfo.fromApi('poll'), FavoriteKind.poll);
      expect(FavoriteKindInfo.fromApi('x'), isNull);
    });
  });

  group('컨트롤러', () {
    late _FakeApi api;
    late StreamController<Map<String, dynamic>> socket;
    late FavoritesController controller;

    setUp(() {
      api = _FakeApi();
      socket = StreamController<Map<String, dynamic>>.broadcast();
      controller = FavoritesController(
        apiProvider: () => api,
        teamIdProvider: () => 't1',
        changed: socket.stream,
      );
    });
    tearDown(() async {
      controller.dispose();
      await socket.close();
    });

    test('loadIds — 담은 id를 받아 두고 isXxxFavorite로 본다', () async {
      api.ids = const FavoriteIds(
        messages: {'m1'},
        comments: {'c1'},
        members: {'t1:u2'},
      );
      await controller.loadIds();
      expect(controller.isMessageFavorite('m1'), isTrue);
      expect(controller.isMessageFavorite('m2'), isFalse);
      expect(controller.isCommentFavorite('c1'), isTrue);
      expect(controller.isMemberFavorite('t1', 'u2'), isTrue);
      expect(controller.isMemberFavorite('t2', 'u2'), isFalse);
    });

    test('setFavorite — 서버 결과를 반영하고, 빼면 열려 있는 목록에서도 사라진다', () async {
      api.pages.add([_item(_messageItem()), _item(_messageItem(id: 'm2'))]);
      await controller.load(FavoriteKind.message);
      expect(controller.feed(FavoriteKind.message).items, hasLength(2));

      expect(
        await controller.setFavorite(FavoriteKind.message, 'm1', false),
        isFalse,
      );
      expect(controller.isMessageFavorite('m1'), isFalse);
      expect(
        controller.feed(FavoriteKind.message).items.map((i) => i.message!.id),
        ['m2'],
      );

      await controller.setFavorite(FavoriteKind.comment, 'c1', true);
      expect(controller.isCommentFavorite('c1'), isTrue);
      await controller.setFavorite(
        FavoriteKind.member,
        'u2',
        true,
        teamId: 't1',
      );
      expect(controller.isMemberFavorite('t1', 'u2'), isTrue);
      expect(
        () => controller.setFavorite(FavoriteKind.member, 'u2', true),
        throwsArgumentError,
      );
      expect(
        api.calls,
        containsAll([
          'message m1 false',
          'comment c1 true',
          'member t1 u2 true',
        ]),
      );
    });

    test('새로 담으면 열려 있던 목록을 비워 다시 받게 한다', () async {
      api.pages.add([_item(_messageItem())]);
      await controller.load(null);
      expect(controller.feed(null).loaded, isTrue);
      await controller.setFavorite(FavoriteKind.message, 'm9', true);
      expect(controller.feed(null).loaded, isFalse);
      expect(controller.feed(null).items, isEmpty);
    });

    test('소켓 favorite:changed — 내 다른 기기의 변경을 그대로 반영한다', () async {
      socket.add({'kind': 'message', 'id': 'm1', 'favorite': true});
      socket.add({
        'kind': 'member',
        'id': 'u2',
        'teamId': 't1',
        'favorite': true,
      });
      await Future<void>.delayed(Duration.zero);
      expect(controller.isMessageFavorite('m1'), isTrue);
      expect(controller.isMemberFavorite('t1', 'u2'), isTrue);

      socket.add({'kind': 'message', 'id': 'm1', 'favorite': false});
      await Future<void>.delayed(Duration.zero);
      expect(controller.isMessageFavorite('m1'), isFalse);
    });

    test('쪽 나누기 — 마지막으로 담은 시각 이전 것을 이어 붙이고 중복은 버린다', () async {
      api.pages
        ..add([_item(_messageItem(id: 'm1', at: 9000))])
        ..add([
          _item(_messageItem(id: 'm1', at: 9000)),
          _item(_messageItem(id: 'm2', at: 8000)),
        ]);
      await controller.load(FavoriteKind.message);
      expect(controller.feed(FavoriteKind.message).hasMore, isTrue);
      await controller.loadMore(FavoriteKind.message);
      expect(api.lastBefore, 9000);
      expect(
        controller.feed(FavoriteKind.message).items.map((i) => i.message!.id),
        ['m1', 'm2'],
      );
      expect(controller.feed(FavoriteKind.message).hasMore, isFalse);
    });

    test('전체 탭은 담은 시각이 없는 대화방을 건너뛰고 커서를 잡는다', () async {
      api.pages
        ..add([_item(_roomItem()), _item(_messageItem(at: 7000))])
        ..add(const []);
      await controller.load(null);
      await controller.loadMore(null);
      expect(api.lastBefore, 7000);
    });

    test('reset — 로그아웃하면 id와 목록을 비운다', () async {
      api.ids = const FavoriteIds(messages: {'m1'});
      await controller.loadIds();
      api.pages.add([_item(_messageItem())]);
      await controller.load(null);
      controller.reset();
      expect(controller.isMessageFavorite('m1'), isFalse);
      expect(controller.feed(null).items, isEmpty);
      expect(controller.feed(null).loaded, isFalse);
    });
  });

  group('즐겨찾기 화면', () {
    testWidgets('전체 탭 — 모든 종류가 한 목록에, 종류별 탭으로 다시 받는다', (tester) async {
      final server = _Server();
      _serveFavorites(server, {
        null: [
          _roomItem(),
          _messageItem(),
          _commentItem(),
          _fileItem(),
          _pollItem(),
          _memberItem(),
        ],
        'message': [_messageItem()],
        'member': [_memberItem()],
      });
      final session = _session(server);
      await _openScreen(tester, session);

      // 머리글과 탭 일곱 개.
      expect(find.text('즐겨찾기'), findsWidgets);
      for (final label in ['전체', '메시지', '파일', '댓글', '투표', '대화방', '멤버']) {
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('favorites-tabs')),
            matching: find.text(label),
          ),
          findsOneWidget,
          reason: label,
        );
      }
      final all = server.called('GET', '/api/favorites').single;
      expect(all.url.queryParameters['teamId'], 't1');
      expect(all.url.queryParameters.containsKey('type'), isFalse);

      expect(find.text('내일 회의 자료 공유드립니다'), findsOneWidget);
      expect(find.text('확인했습니다'), findsOneWidget);
      expect(find.text('보고서.pdf'), findsOneWidget);
      expect(find.byType(PollCard), findsOneWidget);
      // 대화방 항목(토픽)이 맨 앞에 온다.
      expect(find.text('토픽'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('favorites-tab-message')));
      await tester.pumpAndSettle();
      expect(
        server.called('GET', '/api/favorites').last.url.queryParameters['type'],
        'message',
      );
      expect(find.byType(PollCard), findsNothing);
      expect(find.text('확인했습니다'), findsNothing);
      expect(find.text('내일 회의 자료 공유드립니다'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('favorites-tab-member')));
      await tester.pumpAndSettle();
      expect(find.text('김철수'), findsOneWidget);
      expect(find.text('개발팀 · 팀장'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('종류마다 비면 안내 문구가 다르다', (tester) async {
      final server = _Server();
      _serveFavorites(server, {});
      final session = _session(server);
      await _openScreen(tester, session);
      expect(find.byKey(const ValueKey('favorites-empty')), findsOneWidget);
      expect(find.textContaining('즐겨찾기한 항목이 없습니다'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('favorites-tab-comment')));
      await tester.pumpAndSettle();
      expect(find.textContaining('즐겨찾기한 댓글이 없습니다'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('favorites-tab-poll')));
      await tester.pumpAndSettle();
      expect(find.textContaining('즐겨찾기한 투표가 없습니다'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('favorites-tab-member')));
      await tester.pumpAndSettle();
      expect(find.textContaining('즐겨찾기한 멤버가 없습니다'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('사진 메시지는 설명글이 있으면 "사진을 보냈습니다 · 설명글"로 보인다', (tester) async {
      final server = _Server();
      _serveFavorites(server, {
        null: [
          {
            ..._messageItem(id: 'mi'),
            'message': {
              ..._message(id: 'mi', text: '회식 사진', type: 'image'),
              'fileUrl': '/files/img',
              'fileName': 'a.png',
            },
          },
          {
            ..._messageItem(id: 'mj', at: 8500),
            'message': {
              ..._message(id: 'mj', text: '', type: 'image'),
              'fileUrl': '/files/img2',
              'fileName': 'b.png',
            },
          },
        ],
      });
      final session = _session(server);
      await _openScreen(tester, session);
      expect(find.text('사진을 보냈습니다 · 회식 사진'), findsOneWidget);
      // 설명글이 없으면 예전 그대로.
      expect(find.text('사진을 보냈습니다'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('별을 누르면 해제 요청을 보내고 목록에서 빠진다', (tester) async {
      final server = _Server();
      var items = [_messageItem(), _commentItem(), _memberItem()];
      server.on('GET', '/api/favorites', (_) {
        return _json({'items': items, 'hasMore': false});
      });
      server.on('PUT', '/api/messages/m1/favorite', (r) {
        items = items.where((i) => i['type'] != 'message').toList();
        return _json({'favorite': _body(r)['favorite']});
      });
      server.on('PUT', '/api/comments/c1/favorite', (r) {
        return _json({'favorite': _body(r)['favorite']});
      });
      server.on('PUT', '/api/teams/t1/members/u2/favorite', (r) {
        return _json({'favorite': _body(r)['favorite']});
      });
      final session = _session(server);
      await _openScreen(tester, session);

      await tester.tap(
        find.byKey(const ValueKey('favorite-unstar-message:m1')),
      );
      await tester.pumpAndSettle();
      expect(_body(server.called('PUT', '/api/messages/m1/favorite').single), {
        'favorite': false,
      });
      expect(find.text('내일 회의 자료 공유드립니다'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('favorite-unstar-comment:c1')),
      );
      await tester.pumpAndSettle();
      expect(_body(server.called('PUT', '/api/comments/c1/favorite').single), {
        'favorite': false,
      });
      expect(find.text('확인했습니다'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('favorite-unstar-member:t1:u2')),
      );
      await tester.pumpAndSettle();
      expect(
        _body(server.called('PUT', '/api/teams/t1/members/u2/favorite').single),
        {'favorite': false},
      );
      expect(find.byKey(const ValueKey('favorites-empty')), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('대화방·투표는 기존 경로로 해제한다(투표 카드 ⋯ 메뉴도 된다)', (tester) async {
      final server = _Server();
      _serveFavorites(server, {
        null: [_roomItem(), _pollItem()],
      });
      server.on(
        'POST',
        '/api/rooms/r1/favorite',
        (_) => _json(<String, Object?>{}),
      );
      server.on('PUT', '/api/polls/p1/favorite', (r) {
        return _json({'favorite': _body(r)['favorite']});
      });
      final session = _session(server);
      await _openScreen(tester, session);
      expect(session.roomById('r1')!.favorite, isTrue);

      await tester.tap(find.byKey(const ValueKey('favorite-unstar-room:r1')));
      await tester.pumpAndSettle();
      expect(_body(server.called('POST', '/api/rooms/r1/favorite').single), {
        'favorite': false,
      });
      expect(session.roomById('r1')!.favorite, isFalse);
      expect(find.text('토픽'), findsNothing);

      // 투표 카드 ⋯ 메뉴의 "즐겨찾기 해제" — 카드가 목록에서 빠진다.
      await tester.tap(find.byKey(const ValueKey('poll-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('즐겨찾기 해제'));
      await tester.pumpAndSettle();
      expect(find.byType(PollCard), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('메시지·댓글·투표를 누르면 대화상자가 닫히고 그 방의 그 메시지로 이동을 요청한다', (
      tester,
    ) async {
      final server = _Server();
      _serveFavorites(server, {
        null: [_messageItem(), _commentItem()],
      });
      final session = _session(server);
      await _openScreen(tester, session);

      await tester.tap(find.text('내일 회의 자료 공유드립니다'));
      await tester.pumpAndSettle();
      expect(find.byType(FavoritesScreen), findsNothing);
      expect(session.consumePendingOpenRoom()?.id, 'r1');
      expect(session.consumePendingOpenMessageId(), 'm1');

      await tester.pumpWidget(const SizedBox());
      await _openScreen(tester, session);
      // 댓글은 원문 메시지로 간다.
      await tester.tap(find.text('확인했습니다'));
      await tester.pumpAndSettle();
      expect(session.consumePendingOpenRoom()?.id, 'r1');
      expect(session.consumePendingOpenMessageId(), 'm1');
    });

    testWidgets('멤버를 누르면 프로필 카드가 열리고 별이 켜져 있다', (tester) async {
      final server = _Server();
      _serveFavorites(server, {
        null: [_memberItem()],
      });
      server.on('GET', '/api/favorites/ids', (_) {
        return _json({
          'messages': <String>[],
          'comments': <String>[],
          'members': [
            {'teamId': 't1', 'userId': 'u2'},
          ],
        });
      });
      server.on('PUT', '/api/teams/t1/members/u2/favorite', (r) {
        return _json({'favorite': _body(r)['favorite']});
      });
      final session = _session(server);
      await session.favorites.loadIds();
      await _openScreen(tester, session);

      await tester.tap(find.text('김철수'));
      await tester.pumpAndSettle();
      final star = find.byKey(const ValueKey('member-favorite-star'));
      expect(star, findsOneWidget);
      expect(
        tester.widget<IconButton>(star).icon,
        isA<Icon>().having((i) => i.icon, 'icon', Icons.star),
      );

      await tester.tap(star);
      await tester.pumpAndSettle();
      expect(
        _body(server.called('PUT', '/api/teams/t1/members/u2/favorite').single),
        {'favorite': false},
      );
      expect(session.favorites.isMemberFavorite('t1', 'u2'), isFalse);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('폭 360 — 탭이 가로로 스크롤되고 넘침 없이 전체 화면으로 열린다', (tester) async {
      final server = _Server();
      _serveFavorites(server, {
        null: [
          _roomItem(),
          _messageItem(),
          _commentItem(),
          _fileItem(),
          _pollItem(),
          _memberItem(),
        ],
      });
      final session = _session(server);
      await _openScreen(tester, session, size: const Size(360, 780));
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
      // 탭 일곱 개가 한 화면에 다 안 들어가므로 끝 탭은 스크롤해야 보인다.
      final tabs = find.byKey(const ValueKey('favorites-tabs'));
      expect(tabs, findsOneWidget);
      expect(find.byKey(const ValueKey('favorites-tab-member')), findsNothing);
      await tester.drag(tabs, const Offset(-400, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('favorites-tab-member')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('쪽 나누기 — "더 보기"로 다음 쪽을 이어 붙인다', (tester) async {
      final server = _Server();
      server.on('GET', '/api/favorites', (r) {
        final before = r.url.queryParameters['before'];
        if (before == null) {
          return _json({
            'items': [_messageItem(id: 'm1', at: 9000)],
            'hasMore': true,
          });
        }
        return _json({
          'items': [_messageItem(id: 'm2', at: 8000)],
          'hasMore': false,
        });
      });
      final session = _session(server);
      await _openScreen(tester, session, initialKind: FavoriteKind.message);
      expect(find.byKey(const ValueKey('favorite-message:m1')), findsOneWidget);
      expect(find.byKey(const ValueKey('favorite-message:m2')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('favorites-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('favorite-message:m2')), findsOneWidget);
      expect(
        server
            .called('GET', '/api/favorites')
            .last
            .url
            .queryParameters['before'],
        '9000',
      );
      expect(find.byKey(const ValueKey('favorites-more')), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('메뉴와 즐겨찾기 켜기', () {
    testWidgets('메뉴의 리스트에 "즐겨찾기" 타일이 있고 누르면 즐겨찾기 화면이 열린다', (tester) async {
      final server = _Server();
      _serveFavorites(server, {
        null: [_messageItem()],
      });
      final session = _session(server);
      _size(tester, const Size(1280, 900));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                AppMenuButton(
                  session: session,
                  onOpenFiles: () {},
                  onOpenLinks: () {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('메뉴'));
      await tester.pumpAndSettle();
      // 기존 타일·투표 만들기 진입은 그대로다.
      for (final label in ['메시지 예약', '투표', '파일', '링크', '문의함', '즐겨찾기']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await tester.tap(find.byKey(const ValueKey('menu-favorites')));
      await tester.pumpAndSettle();
      expect(find.byType(FavoritesScreen), findsOneWidget);
      expect(find.text('내일 회의 자료 공유드립니다'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    Future<void> openSheet(
      WidgetTester tester,
      Session session,
      Message m, {
      bool isComment = false,
    }) async {
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
                  isComment: isComment,
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

    testWidgets('롱프레스 시트 — 메시지 즐겨찾기를 켜고, 다시 열면 "즐겨찾기 해제"', (tester) async {
      final server = _Server();
      server.on('PUT', '/api/messages/m1/favorite', (r) {
        return _json({'favorite': _body(r)['favorite']});
      });
      final session = _session(server);
      final message = Message.fromJson(_message());
      await openSheet(tester, session, message);
      expect(find.text('즐겨찾기'), findsOneWidget);
      await tester.tap(find.text('즐겨찾기'));
      await tester.pumpAndSettle();
      expect(_body(server.called('PUT', '/api/messages/m1/favorite').single), {
        'favorite': true,
      });
      expect(session.favorites.isMessageFavorite('m1'), isTrue);

      await tester.pumpWidget(const SizedBox());
      await openSheet(tester, session, message);
      expect(find.text('즐겨찾기 해제'), findsOneWidget);
      await tester.tap(find.text('즐겨찾기 해제'));
      await tester.pumpAndSettle();
      expect(session.favorites.isMessageFavorite('m1'), isFalse);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('댓글은 댓글 즐겨찾기 API로, 투표·시스템 메시지·비밀 대화에는 항목이 없다', (tester) async {
      final server = _Server();
      server.on('PUT', '/api/comments/c1/favorite', (r) {
        return _json({'favorite': _body(r)['favorite']});
      });
      final session = _session(server);
      await openSheet(
        tester,
        session,
        Message.fromJson({..._message(id: 'c1')}),
        isComment: true,
      );
      await tester.tap(find.text('즐겨찾기'));
      await tester.pumpAndSettle();
      expect(server.called('PUT', '/api/comments/c1/favorite'), hasLength(1));
      expect(server.called('PUT', '/api/messages/c1/favorite'), isEmpty);
      expect(session.favorites.isCommentFavorite('c1'), isTrue);

      await tester.pumpWidget(const SizedBox());
      await openSheet(tester, session, Message.fromJson(_pollMessage()));
      expect(find.text('즐겨찾기'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await openSheet(
        tester,
        session,
        Message.fromJson({..._message(id: 'ms', type: 'system')}),
      );
      expect(find.text('즐겨찾기'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      session.rooms.add(
        Room.fromJson({
          'id': 'r-secret',
          'teamId': 't1',
          'type': 'dm',
          'name': null,
          'members': _members,
          'createdAt': 1000,
          'isSecret': true,
        }),
      );
      await openSheet(
        tester,
        session,
        Message.fromJson({..._message(id: 'mx'), 'roomId': 'r-secret'}),
      );
      expect(find.text('즐겨찾기'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
