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
import 'package:client/widgets/side_panels.dart';
import 'package:client/widgets/message_actions.dart';
import 'package:client/widgets/panel_filters.dart';
import 'package:client/widgets/poll_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 통합 즐겨찾기 — 모델 파싱, 컨트롤러(담은 id·쪽 나누기·소켓 동기화), 즐겨찾기 패널(탭·이동·해제·빈 상태·필터·검색·정렬·폭 360),
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

/// 테스트 안의 "담은 시각" 기준 — 기본 기간(최근 1년)에 걸러지지 않도록 지금 근처로 잡는다.
final _base = DateTime.now().millisecondsSinceEpoch;

Map<String, dynamic> _messageItem({String id = 'm1', int at = 9000}) => {
  'type': 'message',
  'favoritedAt': _base + at,
  'roomId': 'r1',
  'roomName': '공지방',
  'message': _message(id: id),
};

Map<String, dynamic> _commentItem() => {
  'type': 'comment',
  'favoritedAt': _base + 8000,
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
  'favoritedAt': _base + 7000,
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
  'favoritedAt': _base + 6500,
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
  'favoritedAt': _base + 6000,
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

/// 종류 탭을 누른다 — 탭 줄은 가로 스크롤이라 화면 밖의 탭은 먼저 밀어서 보이게 한다.
Future<void> _tapTab(WidgetTester tester, String name) async {
  final tab = find.byKey(ValueKey('favorites-tab-$name'));
  await tester.scrollUntilVisible(
    tab,
    80,
    scrollable: find.descendant(
      of: find.byKey(const ValueKey('favorites-tabs')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.ensureVisible(tab); // 캐시 범위에 만들어져 있어도 화면 밖일 수 있다
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

/// 패널이 "이 방을 열어라"고 홈 화면에 요청한 것들 — (방 id, 메시지 id).
final _opened = <(String, String?)>[];

/// 패널의 X(닫기)가 눌린 횟수.
var _closed = 0;

/// 즐겨찾기 패널을 연다. 넓은 창은 PC 홈 화면처럼 오른쪽에 폭 420으로 붙이고(홈 셸 손잡이는 기록만 한다),
/// 좁은 창(700 미만)은 메뉴가 쓰는 [openSidePanel]로 전체 화면 라우트를 연다.
Future<void> _openScreen(
  WidgetTester tester,
  Session session, {
  Size size = const Size(1280, 900),
  FavoriteKind? initialKind,
}) async {
  _size(tester, size);
  _opened.clear();
  _closed = 0;
  if (size.width < 700) {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => openSidePanel(context, session, 'favorites'),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    return;
  }
  await tester.pumpWidget(
    MaterialApp(
      home: HomeShellScope(
        openPanelKey: 'favorites',
        panelRoom: null,
        panelGeneration: 0,
        currentRoomId: null,
        togglePanel: (_) {},
        closePanel: () => _closed++,
        toggleCalendar: () {},
        openRoom: (room, {messageId}) => _opened.add((room.id, messageId)),
        child: Scaffold(
          body: Row(
            children: [
              const Expanded(child: SizedBox()),
              const VerticalDivider(width: 1),
              SizedBox(
                width: 420,
                child: FavoritesScreen(
                  session: session,
                  initialKind: initialKind,
                  onClose: () => _closed++,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
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
      expect(
        message.favoritedAt,
        DateTime.fromMillisecondsSinceEpoch(_base + 9000),
      );
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
      expect(api.lastBefore, _base + 9000);
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
      expect(api.lastBefore, _base + 7000);
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
      // 탭 줄은 가로로 스크롤되어 끝 탭은 밀어야 보인다 — 오른쪽 끝까지 밀며 일곱 개를 다 확인한다.
      final tabs = find.byKey(const ValueKey('favorites-tabs'));
      final seen = <String>{};
      for (var i = 0; i < 6; i++) {
        for (final label in ['전체', '메시지', '파일', '댓글', '투표', '대화방', '멤버']) {
          if (find
              .descendant(of: tabs, matching: find.text(label))
              .evaluate()
              .isNotEmpty) {
            seen.add(label);
          }
        }
        await tester.drag(tabs, const Offset(-150, 0));
        await tester.pumpAndSettle();
      }
      expect(seen, {'전체', '메시지', '파일', '댓글', '투표', '대화방', '멤버'});
      await tester.drag(tabs, const Offset(2000, 0)); // 다시 맨 앞으로
      await tester.pumpAndSettle();
      final all = server.called('GET', '/api/favorites').single;
      expect(all.url.queryParameters['teamId'], 't1');
      expect(all.url.queryParameters.containsKey('type'), isFalse);

      expect(find.text('내일 회의 자료 공유드립니다'), findsOneWidget);
      expect(find.text('확인했습니다'), findsOneWidget);
      expect(find.text('보고서.pdf'), findsOneWidget);
      expect(find.byType(PollCard), findsOneWidget);
      // 대화방 항목(토픽)이 맨 앞에 온다.
      expect(find.text('토픽'), findsOneWidget);

      await _tapTab(tester, 'message');
      expect(
        server.called('GET', '/api/favorites').last.url.queryParameters['type'],
        'message',
      );
      expect(find.byType(PollCard), findsNothing);
      expect(find.text('확인했습니다'), findsNothing);
      expect(find.text('내일 회의 자료 공유드립니다'), findsOneWidget);

      await _tapTab(tester, 'member');
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

      await _tapTab(tester, 'comment');
      expect(find.textContaining('즐겨찾기한 댓글이 없습니다'), findsOneWidget);
      await _tapTab(tester, 'poll');
      expect(find.textContaining('즐겨찾기한 투표가 없습니다'), findsOneWidget);
      await _tapTab(tester, 'member');
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

    testWidgets('메시지·댓글·투표를 누르면 홈 화면에 그 방의 그 메시지를 열어 달라고 하고 패널은 그대로다', (
      tester,
    ) async {
      final server = _Server();
      _serveFavorites(server, {
        null: [_messageItem(), _commentItem(), _roomItem()],
      });
      final session = _session(server);
      await _openScreen(tester, session);

      await tester.tap(find.text('내일 회의 자료 공유드립니다'));
      await tester.pumpAndSettle();
      expect(_opened.single, ('r1', 'm1'));
      expect(find.byType(FavoritesScreen), findsOneWidget);

      // 댓글은 원문 메시지로 간다.
      await tester.tap(find.text('확인했습니다'));
      await tester.pumpAndSettle();
      expect(_opened.last, ('r1', 'm1'));

      // 대화방 항목은 메시지 없이 그 방만.
      await tester.tap(find.text('공지방').first);
      await tester.pumpAndSettle();
      expect(_opened.last, ('r1', null));
      expect(_opened, hasLength(3));
    });

    testWidgets('머리글의 닫기(X)는 패널을 닫아 달라고 알린다', (tester) async {
      final server = _Server();
      _serveFavorites(server, {});
      final session = _session(server);
      await _openScreen(tester, session);
      await tester.tap(find.byTooltip('닫기'));
      await tester.pump();
      expect(_closed, 1);
      await tester.pump(const Duration(seconds: 3));
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

    testWidgets('폭 360 — 전체 화면으로 열리고 탭이 가로로 스크롤되며 넘침이 없다', (tester) async {
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
      // 패널이 제목·닫기를 직접 그린다(파일 패널과 같다) — 앱바는 따로 없다.
      expect(find.byType(FavoritesScreen), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byKey(const ValueKey('panel-search-field')), findsOneWidget);
      expect(find.text('참여 대화방'), findsOneWidget);
      expect(find.text('모든 멤버'), findsOneWidget);
      expect(find.text('1년 (기본)'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // 탭 일곱 개가 한 화면에 다 안 들어가므로 끝 탭은 스크롤해야 보인다.
      final tabs = find.byKey(const ValueKey('favorites-tabs'));
      expect(tabs, findsOneWidget);
      expect(find.byKey(const ValueKey('favorites-tab-member')), findsNothing);
      await tester.drag(tabs, const Offset(-400, 0));
      await tester.pumpAndSettle();
      await _tapTab(tester, 'member');
      expect(tester.takeException(), isNull);
      // 닫으면(X) 전체 화면 라우트가 걷힌다.
      await tester.tap(find.byTooltip('닫기'));
      await tester.pumpAndSettle();
      expect(find.byType(FavoritesScreen), findsNothing);
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
        '${_base + 9000}',
      );
      expect(find.byKey(const ValueKey('favorites-more')), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('즐겨찾기 패널 상단 — 필터 · 종류 탭 · 검색 · 정렬', () {
    Future<void> typeQuery(WidgetTester tester, String text) async {
      await tester.enterText(
        find.byKey(const ValueKey('panel-search-field')),
        text,
      );
      await tester.pump(const Duration(milliseconds: 400)); // 입력을 멈춘 뒤 거른다
      await tester.pumpAndSettle();
    }

    final all = <Map<String, dynamic>>[
      _roomItem(),
      _messageItem(),
      _commentItem(),
      _fileItem(),
      _pollItem(),
      _memberItem(),
    ];

    String loaded(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const ValueKey('panel-loaded-count')))
        .data!;

    testWidgets('파일 패널과 같은 구조 — 검색칸 · 필터 줄 · 종류 탭 · 정렬 · "N개가 로딩되었습니다."', (
      tester,
    ) async {
      final server = _Server();
      _serveFavorites(server, {null: all});
      final session = _session(server);
      await _openScreen(tester, session);

      expect(find.byKey(const ValueKey('panel-search-field')), findsOneWidget);
      expect(find.text('즐겨찾기 검색'), findsOneWidget);
      expect(find.text('참여 대화방'), findsOneWidget);
      expect(find.text('모든 멤버'), findsOneWidget);
      expect(find.text('1년 (기본)'), findsOneWidget);
      expect(find.byKey(const ValueKey('panel-sort')), findsOneWidget);
      expect(find.text('최신순'), findsOneWidget);
      expect(loaded(tester), '"6"개가 로딩되었습니다.');
      // 위에서 아래로: 검색칸 → 필터 줄 → 종류 탭 → 건수 줄 → 목록.
      double top(Finder f) => tester.getTopLeft(f).dy;
      final order = [
        top(find.byKey(const ValueKey('panel-search-field'))),
        top(find.text('참여 대화방')),
        top(find.byKey(const ValueKey('favorites-tabs'))),
        top(find.byKey(const ValueKey('panel-loaded-count'))),
        top(find.byKey(const ValueKey('favorite-message:m1'))),
      ];
      expect(order, [...order]..sort());
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('검색 — 본문·파일명·보낸 사람·투표 항목·멤버 이름에서 찾고, 건수가 따라간다', (tester) async {
      final server = _Server();
      _serveFavorites(server, {null: all});
      final session = _session(server);
      await _openScreen(tester, session);

      await typeQuery(tester, '보고서');
      expect(loaded(tester), '"1"개가 로딩되었습니다.');
      expect(find.text('보고서.pdf'), findsOneWidget);
      expect(find.text('내일 회의 자료 공유드립니다'), findsNothing);

      await typeQuery(tester, '라면'); // 투표 선택지
      expect(loaded(tester), '"1"개가 로딩되었습니다.');
      expect(find.byType(PollCard), findsOneWidget);

      await typeQuery(tester, '김철수'); // 보낸 사람 · 멤버 이름
      expect(
        find.byKey(const ValueKey('favorite-member:t1:u2')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('favorite-message:m1')), findsOneWidget);
      expect(find.byKey(const ValueKey('favorite-room:r1')), findsNothing);

      await typeQuery(tester, '없는말');
      expect(loaded(tester), '"0"개가 로딩되었습니다.');
      expect(find.byKey(const ValueKey('favorites-no-match')), findsOneWidget);

      // 지우기(X)로 되돌린다.
      await typeQuery(tester, '');
      expect(loaded(tester), '"6"개가 로딩되었습니다.');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('정렬 — 최신순은 서버 순서(담은 시각 최신 먼저), 과거순은 그 반대(대화방은 맨 뒤)', (
      tester,
    ) async {
      final server = _Server();
      _serveFavorites(server, {
        null: [
          _roomItem(),
          _messageItem(id: 'm1', at: 9000),
          _messageItem(id: 'm2', at: 5000),
          _messageItem(id: 'm3', at: 7000),
        ],
      });
      final session = _session(server);
      await _openScreen(tester, session);

      double y(String key) => tester.getTopLeft(find.byKey(ValueKey(key))).dy;
      List<String> order() {
        final keys = ['room:r1', 'message:m1', 'message:m2', 'message:m3'];
        keys.sort((a, b) => y('favorite-$a').compareTo(y('favorite-$b')));
        return keys;
      }

      // 최신순: 담은 시각이 없는 대화방이 맨 앞, 이어서 9000 → 7000 → 5000.
      expect(order(), ['room:r1', 'message:m1', 'message:m3', 'message:m2']);

      await tester.tap(find.byKey(const ValueKey('panel-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('과거순').last);
      await tester.pumpAndSettle();
      expect(find.text('과거순'), findsOneWidget);
      expect(order(), ['message:m2', 'message:m3', 'message:m1', 'room:r1']);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('기간 — 기본 1년이라 오래된 것은 빠지고, "설정 안 함"으로 바꾸면 보인다', (tester) async {
      final server = _Server();
      final old = DateTime.now()
          .subtract(const Duration(days: 800))
          .millisecondsSinceEpoch;
      _serveFavorites(server, {
        null: [
          _messageItem(id: 'm1', at: 9000),
          {..._messageItem(id: 'm2'), 'favoritedAt': old},
        ],
      });
      final session = _session(server);
      await _openScreen(tester, session);
      expect(loaded(tester), '"1"개가 로딩되었습니다.');
      expect(find.byKey(const ValueKey('favorite-message:m2')), findsNothing);

      await tester.tap(find.text('1년 (기본)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('period-all')));
      await tester.pumpAndSettle();
      expect(loaded(tester), '"2"개가 로딩되었습니다.');
      expect(find.byKey(const ValueKey('favorite-message:m2')), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('대화방 필터 — 그 방의 항목만 남고 방이 없는 멤버 항목은 그대로 둔다', (tester) async {
      final server = _Server();
      _serveFavorites(server, {
        null: [
          _messageItem(id: 'm1', at: 9000),
          {
            ..._messageItem(id: 'm2', at: 8000),
            'roomId': 'r2',
            'roomName': '영업방',
          },
          _memberItem(),
        ],
      });
      final session = _session(server);
      await _openScreen(tester, session);
      expect(loaded(tester), '"3"개가 로딩되었습니다.');

      await tester.tap(find.text('참여 대화방'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('영업방').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('favorite-message:m1')), findsNothing);
      expect(find.byKey(const ValueKey('favorite-message:m2')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('favorite-member:t1:u2')),
        findsOneWidget,
      );
      expect(loaded(tester), '"2"개가 로딩되었습니다.');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('멤버(보낸 사람) 필터 — 메시지는 보낸 사람으로, 멤버 항목은 그 사람으로 거른다', (
      tester,
    ) async {
      final server = _Server();
      _serveFavorites(server, {
        null: [
          _messageItem(id: 'm1', at: 9000), // 김철수가 보냄
          {
            ..._messageItem(id: 'm2', at: 8000),
            'message': {
              ..._message(id: 'm2'),
              'senderId': 'me',
              'senderName': '나',
            },
          },
          _memberItem(), // 김철수
          _roomItem(), // 보낸 사람이 없는 항목은 영향받지 않는다
        ],
      });
      final session = _session(server);
      await _openScreen(tester, session);
      expect(loaded(tester), '"4"개가 로딩되었습니다.');

      await tester.tap(find.text('모든 멤버'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byType(ListTile), matching: find.text('김철수')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('favorite-message:m1')), findsOneWidget);
      expect(find.byKey(const ValueKey('favorite-message:m2')), findsNothing);
      expect(
        find.byKey(const ValueKey('favorite-member:t1:u2')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('favorite-room:r1')), findsOneWidget);
      expect(loaded(tester), '"3"개가 로딩되었습니다.');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('항목에 그 정보가 없는 종류에서는 필터 단추가 막힌다(멤버 탭은 대화방, 대화방 탭은 멤버·기간)', (
      tester,
    ) async {
      final server = _Server();
      _serveFavorites(server, {
        null: all,
        'member': [_memberItem()],
        'room': [_roomItem()],
      });
      final session = _session(server);
      await _openScreen(tester, session);

      Future<void> expectBlocked(String label, bool blocked) async {
        final ignoring = tester
            .widgetList<IgnorePointer>(
              find.ancestor(
                of: find.text(label),
                matching: find.byType(IgnorePointer),
              ),
            )
            .any((w) => w.ignoring);
        expect(ignoring, blocked, reason: label);
      }

      await expectBlocked('참여 대화방', false);
      await expectBlocked('모든 멤버', false);
      await expectBlocked('1년 (기본)', false);

      await _tapTab(tester, 'member');
      await expectBlocked('참여 대화방', true);
      await expectBlocked('모든 멤버', false);
      await expectBlocked('1년 (기본)', false);

      await _tapTab(tester, 'room');
      await expectBlocked('참여 대화방', false);
      await expectBlocked('모든 멤버', true);
      await expectBlocked('1년 (기본)', true);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('필터로 다 걸러져도 서버에 더 있으면 "더 보기"가 남는다', (tester) async {
      final server = _Server();
      server.on('GET', '/api/favorites', (r) {
        return _json({
          'items': [_messageItem(id: 'm1', at: 9000)],
          'hasMore': true,
        });
      });
      final session = _session(server);
      await _openScreen(tester, session);
      await typeQuery(tester, '없는말');
      expect(loaded(tester), '"0"개가 로딩되었습니다.');
      expect(find.byKey(const ValueKey('favorites-more')), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    test('FavoriteFilter — 대화방·보낸 사람·기간·검색을 항목이 가진 정보로만 건다', () {
      final now = DateTime(2026, 10, 3);
      final recent = _item({
        ..._messageItem(),
        'favoritedAt': now
            .subtract(const Duration(days: 10))
            .millisecondsSinceEpoch,
      });
      final old = _item({
        ..._messageItem(id: 'm2'),
        'favoritedAt': now
            .subtract(const Duration(days: 400))
            .millisecondsSinceEpoch,
      });
      final room = _item(_roomItem());
      final member = _item(_memberItem());

      // 기간: 기본 1년이면 400일 전 것이 빠지고, 담은 시각이 없는 대화방은 영향받지 않는다.
      const year = PanelPeriod();
      expect(FavoriteFilter(period: year, now: now).matches(recent), isTrue);
      expect(FavoriteFilter(period: year, now: now).matches(old), isFalse);
      expect(FavoriteFilter(period: year, now: now).matches(room), isTrue);
      expect(
        FavoriteFilter(
          period: const PanelPeriod(PeriodPreset.all),
          now: now,
        ).matches(old),
        isTrue,
      );
      expect(
        FavoriteFilter(
          period: const PanelPeriod(PeriodPreset.week),
          now: now,
        ).matches(recent),
        isFalse,
      );

      // 대화방: 방이 없는 멤버 항목은 영향받지 않는다.
      expect(const FavoriteFilter(roomId: 'r2').matches(recent), isFalse);
      expect(const FavoriteFilter(roomId: 'r1').matches(recent), isTrue);
      expect(const FavoriteFilter(roomId: 'r2').matches(member), isTrue);

      // 보낸 사람: 메시지는 보낸 사람, 멤버는 그 사람, 대화방은 영향받지 않는다.
      expect(const FavoriteFilter(senderId: 'u2').matches(recent), isTrue);
      expect(const FavoriteFilter(senderId: 'me').matches(recent), isFalse);
      expect(const FavoriteFilter(senderId: 'u2').matches(member), isTrue);
      expect(const FavoriteFilter(senderId: 'me').matches(member), isFalse);
      expect(const FavoriteFilter(senderId: 'me').matches(room), isTrue);

      // 검색: 대소문자 무시, 방 이름까지.
      expect(const FavoriteFilter(query: '회의').matches(recent), isTrue);
      expect(const FavoriteFilter(query: '공지방').matches(recent), isTrue);
      expect(const FavoriteFilter(query: '영업').matches(recent), isFalse);
    });
  });

  group('메뉴와 즐겨찾기 켜기', () {
    testWidgets('메뉴의 리스트에 "즐겨찾기" 타일이 있고 누르면 즐겨찾기 패널이 열린다(홈 화면 밖에서는 전체 화면)', (
      tester,
    ) async {
      final server = _Server();
      _serveFavorites(server, {
        null: [_messageItem()],
      });
      final session = _session(server);
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
      // 기존 타일·투표 만들기 진입은 그대로다.
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
