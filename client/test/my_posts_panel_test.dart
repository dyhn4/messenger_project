import 'dart:async';
import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/my_posts_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/services/time_format.dart';
import 'package:client/widgets/app_menu_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 내가 쓴 글 패널(MyPostsScreen) — 헤더 · 필터 줄(멤버 필터 없음) · 종류 드롭다운 · 정렬 · 로딩 줄 · 목록(방 이름·시각·본문 2줄·
/// 게시글 제목·댓글 원본·편집됨), 서버로 가는 요청 파라미터, 눌러서 이동, 무한 스크롤, 빈 상태, 폭 360.

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
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
    _routes.insert(0, (method, RegExp('^${RegExp.escape(path)}\$'), handler));
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

  List<http.Request> get calls =>
      requests.where((r) => r.url.path == '/api/my-posts').toList();
  Map<String, String> get lastQuery => calls.last.url.queryParameters;
}

Map<String, dynamic> _user(String id, String name) => {
  'id': id,
  'username': id,
  'name': name,
  'role': 'member',
};

Room _topic(String id, String name) => Room.fromJson({
  'id': id,
  'teamId': 't1',
  'type': 'topic',
  'name': name,
  'members': [_user('me', '나'), _user('u2', '김철수')],
  'createdAt': 1000,
});

final _t0 = DateTime(2026, 10, 1, 15, 44);

Map<String, dynamic> _msg(
  String n, {
  String roomId = 'r1',
  String roomName = '공지방',
  String? text,
  String? title,
  bool edited = false,
}) => {
  'kind': 'message',
  'id': 'm$n',
  'messageId': 'm$n',
  'roomId': roomId,
  'roomName': roomName,
  'roomType': 'topic',
  'teamId': 't1',
  'text': text ?? '내 글 $n',
  'title': title,
  'createdAt': _t0
      .subtract(Duration(hours: int.parse(n)))
      .millisecondsSinceEpoch,
  'editedAt': edited ? _t0.millisecondsSinceEpoch : null,
  'parent': null,
};

Map<String, dynamic> _cmt(
  String n, {
  String roomId = 'r1',
  String roomName = '공지방',
  String parentMessageId = 'orig1',
  String parent = '점심 메뉴 공유드립니다',
}) => {
  'kind': 'comment',
  'id': 'c$n',
  'messageId': parentMessageId,
  'roomId': roomId,
  'roomName': roomName,
  'roomType': 'topic',
  'teamId': 't1',
  'text': '내 댓글 $n',
  'title': null,
  'createdAt': _t0
      .subtract(Duration(hours: int.parse(n)))
      .millisecondsSinceEpoch,
  'editedAt': null,
  'parent': parent,
};

Map<String, dynamic> _page(
  List<Map<String, dynamic>> items, {
  bool hasMore = false,
  String? nextBefore,
}) => {'items': items, 'hasMore': hasMore, 'nextBefore': nextBefore};

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
  Size size = const Size(480, 900),
  void Function(Room room, String messageId)? onOpenRoom,
}) async {
  _size(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MyPostsScreen(session: session, onOpenRoom: onOpenRoom),
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

/// 정렬 줄 왼쪽 끝의 종류 드롭다운을 열고 [name] 종류를 고른다.
Future<void> _pickKind(WidgetTester tester, String name) async {
  await tester.tap(_key('my-posts-kind'));
  await tester.pumpAndSettle();
  await tester.tap(_key('my-posts-tab-$name'));
  await tester.pumpAndSettle();
}

void main() {
  late _Server server;
  setUp(() {
    server = _Server();
    server.on(
      'GET',
      '/api/my-posts',
      (_) => _json(
        _page([
          _msg('1', text: '안녕하세요. 오늘 회의 자료 올립니다.', edited: true),
          _msg(
            '2',
            roomId: 'r2',
            roomName: '영업방',
            title: '10월 영업 계획',
            text: '본문입니다',
          ),
          _cmt('3'),
          _msg('4', text: '긴 글 ' * 60),
        ]),
      ),
    );
  });

  testWidgets('헤더 · 필터 줄(멤버 필터 없음) · 종류 드롭다운 · 로딩 줄 · 목록과 기본 요청(최신순 1년)', (
    tester,
  ) async {
    final session = _session(server);
    await _pump(tester, session);

    final q = server.lastQuery;
    expect(q['teamId'], 't1');
    expect(q['order'], 'desc');
    expect(q['limit'], '30');
    expect(q.containsKey('kind'), isFalse);
    expect(q.containsKey('roomId'), isFalse);
    final since = DateTime.fromMillisecondsSinceEpoch(int.parse(q['since']!));
    expect(DateTime.now().difference(since).inDays, inInclusiveRange(364, 366));

    expect(find.text('내가 쓴 글'), findsOneWidget); // 헤더
    expect(find.byTooltip('닫기'), findsOneWidget);
    expect(find.text('참여 대화방'), findsOneWidget);
    expect(find.text('1년 (기본)'), findsOneWidget);
    expect(find.text('모든 멤버'), findsNothing); // 글쓴이는 늘 나라 멤버 필터가 없다.
    expect(_key('panel-search-field'), findsNothing);
    // 종류는 정렬 줄 왼쪽 끝의 드롭다운 하나(처음엔 '전체') — 정렬 단추와 같은 줄, 같은 글자 크기·색.
    final kind = _key('my-posts-kind');
    final sort = _key('panel-sort');
    final kindText = tester.widget<Text>(
      find.descendant(of: kind, matching: find.text('전체')),
    );
    final sortText = tester.widget<Text>(
      find.descendant(of: sort, matching: find.text('최신순')),
    );
    expect(kindText.style?.fontSize, sortText.style?.fontSize);
    expect(kindText.style?.color, sortText.style?.color);
    expect(tester.getCenter(kind).dy, tester.getCenter(sort).dy);
    expect(tester.getTopLeft(kind).dx, 16);
    expect(tester.getTopLeft(kind).dx, lessThan(tester.getTopLeft(sort).dx));
    expect(find.text('메시지'), findsNothing); // 메뉴를 열기 전에는 다른 종류가 안 보인다.
    await tester.tap(kind);
    await tester.pumpAndSettle();
    for (final (name, label) in [
      ('all', '전체'),
      ('message', '메시지'),
      ('comment', '댓글'),
    ]) {
      final item = _key('my-posts-tab-$name');
      expect(
        find.descendant(of: item, matching: find.text(label)),
        findsOneWidget,
        reason: label,
      );
      expect(
        find.descendant(of: item, matching: find.byIcon(Icons.check)),
        name == 'all' ? findsOneWidget : findsNothing,
        reason: label,
      );
    }
    await tester.tap(_key('my-posts-tab-comment'));
    await tester.pumpAndSettle();
    expect(server.lastQuery['kind'], 'comment');
    expect(
      find.descendant(of: kind, matching: find.text('댓글')),
      findsOneWidget,
    );
    await _pickKind(tester, 'all');
    expect(find.text('최신순'), findsOneWidget);
    expect(find.text('"4"개가 로딩되었습니다.'), findsOneWidget);

    // 행: 방 이름 · 시각(yyyy/MM/dd AM h:mm) · 본문, 편집됨.
    final row1 = _key('my-post-m:m1');
    expect(
      find.descendant(of: row1, matching: find.text('공지방')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row1,
        matching: find.text(
          formatPostDateTime(_t0.subtract(const Duration(hours: 1))),
        ),
      ),
      findsOneWidget,
    );
    expect(
      formatPostDateTime(DateTime(2026, 10, 1, 3, 44)),
      '2026/10/01 AM 3:44',
    );
    expect(
      find.descendant(of: row1, matching: find.text('안녕하세요. 오늘 회의 자료 올립니다.')),
      findsOneWidget,
    );
    expect(_key('my-post-edited-m:m1'), findsOneWidget);
    expect(_key('my-post-edited-m:m2'), findsNothing);

    // 게시글은 제목이 굵게 + 본문.
    final row2 = _key('my-post-m:m2');
    final title = tester.widget<Text>(
      find.descendant(of: row2, matching: find.text('10월 영업 계획')),
    );
    expect(title.style?.fontWeight, FontWeight.w700);
    expect(
      find.descendant(of: row2, matching: find.text('영업방')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row2, matching: find.text('본문입니다')),
      findsOneWidget,
    );

    // 댓글은 "댓글 · 원본: …" 보조줄.
    expect(
      find.descendant(
        of: _key('my-post-c:c3'),
        matching: find.text('댓글 · 원본: 점심 메뉴 공유드립니다'),
      ),
      findsOneWidget,
    );
    expect(find.text('내 댓글 3'), findsOneWidget);

    // 본문 미리보기는 2줄까지.
    final long = tester.widget<Text>(
      find.descendant(
        of: _key('my-post-m:m4'),
        matching: find.textContaining('긴 글'),
      ),
    );
    expect(long.maxLines, 2);
    expect(long.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('종류 · 방 · 기간 · 정렬을 바꿀 때마다 서버로 걸러서 다시 받는다', (tester) async {
    final session = _session(server);
    await _pump(tester, session);
    final before = server.calls.length;

    await _pickKind(tester, 'comment');
    await tester.pumpAndSettle();
    expect(server.calls.length, before + 1);
    expect(server.lastQuery['kind'], 'comment');

    await _pickKind(tester, 'message');
    await tester.pumpAndSettle();
    expect(server.lastQuery['kind'], 'message');

    await _pickKind(tester, 'all');
    await tester.pumpAndSettle();
    expect(server.lastQuery.containsKey('kind'), isFalse);

    await tester.tap(find.text('참여 대화방'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('영업방').last);
    await tester.pumpAndSettle();
    expect(server.lastQuery['roomId'], 'r2');

    await tester.tap(find.text('1년 (기본)'));
    await tester.pumpAndSettle();
    await tester.tap(_key('period-month'));
    await tester.pumpAndSettle();
    final since = DateTime.fromMillisecondsSinceEpoch(
      int.parse(server.lastQuery['since']!),
    );
    expect(DateTime.now().difference(since).inDays, inInclusiveRange(29, 31));
    expect(server.lastQuery['roomId'], 'r2'); // 조합 유지

    await tester.tap(_key('panel-sort'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('과거순').last);
    await tester.pumpAndSettle();
    expect(server.lastQuery['order'], 'asc');
    expect(server.lastQuery['roomId'], 'r2');
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });

  testWidgets('글을 누르면 그 방의 그 메시지로, 댓글을 누르면 원본 메시지로 이동한다', (tester) async {
    final session = _session(server);
    final opened = <(String, String)>[];
    await _pump(
      tester,
      session,
      onOpenRoom: (room, messageId) => opened.add((room.id, messageId)),
    );
    await tester.tap(_key('my-post-m:m2'));
    await tester.pump();
    await tester.tap(_key('my-post-c:c3'));
    await tester.pump();
    expect(opened, [('r2', 'm2'), ('r1', 'orig1')]);
    await _finish(tester);
  });

  testWidgets('무한 스크롤 — 끝에 닿으면 nextBefore로 이어 받고 필터를 유지한다', (tester) async {
    server.on('GET', '/api/my-posts', (r) {
      if (r.url.queryParameters['before'] == 'cur-1') {
        return _json(_page([_msg('31'), _msg('32')]));
      }
      return _json(
        _page(
          [for (var i = 1; i <= 30; i++) _msg('$i')],
          hasMore: true,
          nextBefore: 'cur-1',
        ),
      );
    });
    final session = _session(server);
    await _pump(tester, session, size: const Size(480, 700));
    expect(find.text('"30"개가 로딩되었습니다.'), findsOneWidget);

    await _pickKind(tester, 'message');
    await tester.pumpAndSettle();
    final list = _key('my-posts-list');
    for (var i = 0; i < 40; i++) {
      await tester.drag(list, const Offset(0, -1500));
      await tester.pumpAndSettle();
      if (server.calls.any((r) => r.url.queryParameters['before'] == 'cur-1')) {
        break;
      }
    }
    final more = server.calls.where(
      (r) => r.url.queryParameters['before'] == 'cur-1',
    );
    expect(more, isNotEmpty);
    expect(more.first.url.queryParameters['kind'], 'message');
    await tester.drag(list, const Offset(0, -30000));
    await tester.pumpAndSettle();
    expect(_key('my-post-m:m32'), findsOneWidget);
    expect(find.text('"32"개가 로딩되었습니다.'), findsOneWidget);
    expect(_key('my-posts-more'), findsNothing);
    await _finish(tester);
  });

  testWidgets('빈 상태 문구와 오류 · 다시 시도', (tester) async {
    server.on('GET', '/api/my-posts', (_) => _json(_page([])));
    final session = _session(server);
    await _pump(tester, session);
    expect(find.text('작성한 글이 없습니다.'), findsOneWidget);
    expect(find.text('"0"개가 로딩되었습니다.'), findsOneWidget);

    var fail = true;
    server.on('GET', '/api/my-posts', (_) {
      return fail
          ? _json({'error': '서버가 바쁩니다.'}, 500)
          : _json(_page([_msg('1')]));
    });
    await _pickKind(tester, 'comment');
    await tester.pumpAndSettle();
    expect(_key('my-posts-error'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(_key('my-post-m:m1'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('폭 360 — 넘치지 않고 필터 줄과 종류·정렬 줄, 행이 화면 안에 있다', (tester) async {
    final session = _session(server);
    await _pump(tester, session, size: const Size(360, 780));
    expect(tester.takeException(), isNull);
    for (final f in [
      find.text('참여 대화방'),
      find.text('1년 (기본)'),
      _key('my-posts-kind'),
      find.text('최신순'),
      _key('my-post-m:m1'),
      _key('my-post-c:c3'),
    ]) {
      final rect = tester.getRect(f.first);
      expect(rect.left, greaterThanOrEqualTo(0), reason: '$f');
      expect(rect.right, lessThanOrEqualTo(360), reason: '$f');
    }
    // 필터 줄은 두 칸이 폭을 나눠 쓴다.
    final room = tester.getRect(find.text('참여 대화방'));
    final period = tester.getRect(find.text('1년 (기본)'));
    expect(room.right, lessThan(period.left));
    await _finish(tester);
  });

  testWidgets('모바일: 메뉴의 "내가 쓴 글"은 전체 화면으로 열리고 닫기(X)로 돌아온다', (tester) async {
    final session = _session(server);
    _size(tester, const Size(360, 780));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: [AppMenuButton(session: session)]),
        ),
      ),
    );
    await tester.tap(find.byTooltip('메뉴'));
    await tester.pumpAndSettle();
    expect(find.text('내가 쓴 글'), findsOneWidget); // 메뉴 타일
    await tester.tap(find.text('내가 쓴 글'));
    await tester.pumpAndSettle();
    expect(find.byType(MyPostsScreen), findsOneWidget);
    expect(server.calls, isNotEmpty);
    await tester.tap(find.byTooltip('닫기'));
    await tester.pumpAndSettle();
    expect(find.byType(MyPostsScreen), findsNothing);
    expect(tester.takeException(), isNull);
    await _finish(tester);
  });
}
