import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client/models/comment.dart';
import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/message_forward_screen.dart';
import 'package:client/screens/message_share_screen.dart';
import 'package:client/screens/message_thread_screen.dart';
import 'package:client/screens/post_editor_dialog.dart';
import 'package:client/screens/project/automation_flow_editor.dart';
import 'package:client/screens/project/filter_controls.dart';
import 'package:client/screens/search_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/chat_socket.dart' show RoomRemovedEvent;
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/attachment_widgets.dart' show AllDownloadBar;
import 'package:client/widgets/avatar_utils.dart' show AvatarView;
import 'package:client/widgets/board_view.dart';
import 'package:client/widgets/chat_input_bar.dart';
import 'package:client/widgets/chat_panel.dart';
import 'package:client/widgets/comment_input_bar.dart';
import 'package:client/widgets/message_bubble.dart';
import 'package:desktop_drop/desktop_drop.dart' show DropTarget;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 보드 뷰 토픽(게시글 보드·고정·편집기·상세)과, 보드를 공유·전달 대상에서 빼는 규칙.

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

/// [minutes]분 뒤의 시각(ms) — 게시글 순서를 분 단위로 정한다.
int _at(int minutes) => _base + minutes * 60000;

Map<String, dynamic> _user(String id, String name, {String role = 'member'}) =>
    {'id': id, 'username': id, 'name': name, 'role': role};

Map<String, dynamic> _post(
  String id, {
  String? title,
  String text = '본문입니다.',
  int minutes = 0,
  String senderId = 'u2',
  String senderName = '김철수',
  int? pinnedAt,
  int? editedAt,
  bool deleted = false,
  List<Map<String, dynamic>> attachments = const [],
  List<Map<String, dynamic>> comments = const [],
}) => {
  'id': id,
  'roomId': 'r1',
  'senderId': senderId,
  'senderName': senderName,
  'type': 'post',
  'title': title ?? '$id 제목',
  'text': text,
  'createdAt': _at(minutes),
  'pinnedAt': pinnedAt,
  'editedAt': editedAt,
  'deleted': deleted,
  'attachments': attachments,
  'comments': comments,
};

Map<String, dynamic> _system(String id, String text, {int minutes = 0}) => {
  'id': id,
  'roomId': 'r1',
  'senderId': null,
  'senderName': '시스템',
  'type': 'system',
  'text': text,
  'createdAt': _at(minutes),
};

Map<String, dynamic> _comment(
  String id,
  String messageId,
  String text, {
  int minutes = 0,
  String senderId = 'u2',
  String senderName = '김철수',
}) => {
  'id': id,
  'messageId': messageId,
  'roomId': 'r1',
  'senderId': senderId,
  'senderName': senderName,
  'type': 'text',
  'text': text,
  'createdAt': _at(minutes),
};

Map<String, dynamic> _image(String id) => {
  'id': id,
  'kind': 'image',
  'fileUrl': '/uploads/$id.png',
  'fileName': '$id.png',
  'fileSize': 2048,
  'thumbnailUrl': '/uploads/${id}_t.jpg',
};

Map<String, dynamic> _file(String id, String name) => {
  'id': id,
  'kind': 'file',
  'fileUrl': '/uploads/$name',
  'fileName': name,
  'fileSize': 4096,
};

Room _room(
  String id, {
  String name = '주간 보고',
  String type = 'topic',
  bool board = true,
  bool readOnly = false,
  List<String> admins = const [],
}) => Room.fromJson({
  'id': id,
  'teamId': 't1',
  'type': type,
  'name': name,
  'members': [_user('me', '나'), _user('u2', '김철수'), _user('u3', '이영희')],
  'createdAt': _base,
  'viewMode': board ? 'board' : 'chat',
  'readOnly': readOnly,
  'adminIds': admins,
});

Session _session(
  _Server server, {
  List<Room> rooms = const [],
  bool teamOwner = false,
}) {
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
  final team = Team(
    id: 't1',
    name: '영업팀',
    createdAt: DateTime(2026),
    isOwner: teamOwner,
  );
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.addAll(rooms);
  return session;
}

/// 보드 r1의 서버 — 메시지 목록([history])과 고정 목록([pinned]).
_Server _boardServer({
  List<Map<String, dynamic>> history = const [],
  List<Map<String, dynamic>> pinned = const [],
}) {
  final server = _Server();
  server.routes['GET /api/rooms/r1/messages'] = (_) => _json(history);
  server.routes['GET /api/rooms/r1/pinned-posts'] = (_) => _json(pinned);
  return server;
}

/// 채팅 화면(ChatPanel)에 보드를 올린다 — 실제 앱처럼 ChatPanel이 보드를 고른다.
Future<void> _pumpBoard(
  WidgetTester tester,
  Session session,
  Room room, {
  Size size = const Size(1100, 900),
  void Function(Message post)? onOpenThread,
  String? highlightMessageId,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChatPanel(
          key: ValueKey(room.id),
          session: session,
          room: room,
          highlightMessageId: highlightMessageId,
          onOpenThread: onOpenThread,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _card(String id) => find.byKey(ValueKey('post-$id'));

/// [id] 카드의 ⋯ 메뉴를 연다.
Future<void> _openMenu(WidgetTester tester, String id) async {
  await tester.tap(
    find.descendant(of: _card(id), matching: find.byTooltip('더보기')),
  );
  await tester.pumpAndSettle();
}

/// 파일 읽기·업로드처럼 실제 입출력을 기다리는 일을 [done]이 될 때까지 조금씩 진행시킨다 —
/// 입출력은 실제 시간에 끝나고, 그 뒤 이어지는 일은 테스트의 가짜 시간(pump)에서 돈다.
Future<void> _settleIo(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(done(), isTrue, reason: '기다리던 입출력이 끝나지 않았습니다');
  await tester.pumpAndSettle();
}

/// 떠 있는 알림(토스트)의 타이머가 테스트 끝까지 남지 않게 흘려보낸다.
Future<void> _flushToasts(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

void main() {
  group('보드 목록', () {
    testWidgets('게시글은 최신 글이 위, 시스템 메시지·지운 글은 숨기고 입력창은 없다', (tester) async {
      final room = _room('r1');
      final server = _boardServer(
        history: [
          _system('s1', '김철수 님이 참여했습니다.', minutes: 0),
          _post(
            'p1',
            title: '첫 번째 글',
            minutes: 1,
            text: '첫 줄\n둘째 줄\n셋째 줄\n넷째 줄',
          ),
          _post(
            'p2',
            title: '두 번째 글',
            minutes: 2,
            comments: [
              _comment('c1', 'p2', '확인했습니다', minutes: 3),
              _comment('c2', 'p2', '좋아요', minutes: 4),
            ],
          ),
          _post('p3', title: '지운 글', minutes: 5, deleted: true),
        ],
      );
      final session = _session(server, rooms: [room]);
      await _pumpBoard(tester, session, room);

      expect(find.text('두 번째 글'), findsOneWidget);
      expect(find.text('첫 번째 글'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('두 번째 글')).dy,
        lessThan(tester.getTopLeft(find.text('첫 번째 글')).dy),
      );
      expect(find.text('김철수 님이 참여했습니다.'), findsNothing);
      expect(find.text('지운 글'), findsNothing);
      // 댓글 수, 댓글 합성 항목(채팅의 댓글 카드)은 보드에 안 보인다.
      expect(
        find.descendant(of: _card('p2'), matching: find.text('댓글 2')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _card('p1'), matching: find.text('댓글 0')),
        findsOneWidget,
      );
      expect(find.text('확인했습니다'), findsNothing);
      // 시각은 "yyyy/MM/dd AM h:mm" — "3분 전" 같은 상대 시각이 아니다.
      expect(
        find.descendant(
          of: _card('p1'),
          matching: find.text('2026/09/29 AM 9:01'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _card('p2'),
          matching: find.text('2026/09/29 AM 9:02'),
        ),
        findsOneWidget,
      );
      // 보드 뷰 토픽은 채팅 입력창을 아예 그리지 않는다.
      expect(find.byType(ChatInputBar), findsNothing);
      expect(find.byType(BoardView), findsOneWidget);
      // 고정된 게시글이 없으면 고정 영역도 없다.
      expect(find.byKey(const ValueKey('board-pinned')), findsNothing);
      // 보드를 열면 고정 목록을 한 번 받아 온다.
      expect(server.called('GET', '/api/rooms/r1/pinned-posts'), hasLength(1));
    });

    testWidgets('첨부 미리보기 — 사진 네 장까지(+N)와 파일 N개', (tester) async {
      final room = _room('r1');
      final server = _boardServer(
        history: [
          _post(
            'p1',
            title: '현장 사진',
            attachments: [
              for (var i = 1; i <= 6; i++) _image('img$i'),
              _file('f1', '견적서.pdf'),
              _file('f2', '일정표.xlsx'),
            ],
          ),
        ],
      );
      final session = _session(server, rooms: [room]);
      await _pumpBoard(tester, session, room);

      expect(find.text('+2'), findsOneWidget);
      expect(find.text('파일 2개'), findsOneWidget);
      expect(find.text('견적서.pdf'), findsNothing); // 파일 이름은 상세에서
    });

    testWidgets('고정된 게시글 — 세 개까지 보이고 더 보기/접기', (tester) async {
      final room = _room('r1');
      final server = _boardServer(
        history: [_post('p9', title: '보통 글', minutes: 30)],
        pinned: [
          _post(
            'pin1',
            title: '고정 1',
            minutes: 19,
            pinnedAt: _at(40),
            senderId: 'u3',
            senderName: '이영희',
            comments: [
              _comment('pc1', 'pin1', '확인', minutes: 21),
              _comment('pc2', 'pin1', '좋아요', minutes: 22),
            ],
          ),
          for (var i = 2; i <= 4; i++)
            _post('pin$i', title: '고정 $i', minutes: 20 - i, pinnedAt: _at(40)),
        ],
      );
      final session = _session(server, rooms: [room]);
      await _pumpBoard(tester, session, room);

      expect(find.text('고정된 게시글 4'), findsOneWidget);
      expect(find.byKey(const ValueKey('pinned-pin1')), findsOneWidget);
      expect(find.byKey(const ValueKey('pinned-pin3')), findsOneWidget);
      expect(find.byKey(const ValueKey('pinned-pin4')), findsNothing);

      // 한 줄 — 제목 오른쪽에 댓글 수(댓글이 있을 때만 — 0이면 아이콘·숫자 모두 없다), 그 오른쪽에 작성자 아바타·
      // 이름. 작성 시각은 없다.
      final pin1 = find.byKey(const ValueKey('pinned-pin1'));
      final pin2 = find.byKey(const ValueKey('pinned-pin2'));
      Finder inTile(Finder tile, Finder f) =>
          find.descendant(of: tile, matching: f);
      expect(
        inTile(pin1, find.byKey(const ValueKey('pinned-comments'))),
        findsOneWidget,
      );
      expect(inTile(pin1, find.text('2')), findsOneWidget);
      expect(
        inTile(pin2, find.byKey(const ValueKey('pinned-comments'))),
        findsNothing,
      );
      expect(
        inTile(pin2, find.byIcon(Icons.mode_comment_outlined)),
        findsNothing,
      );
      expect(inTile(pin2, find.text('0')), findsNothing);
      expect(inTile(pin1, find.text('이영희')), findsOneWidget);
      expect(inTile(pin2, find.text('김철수')), findsOneWidget);
      expect(inTile(pin1, find.byType(AvatarView)), findsOneWidget);
      expect(inTile(pin1, find.textContaining('2026/')), findsNothing);
      expect(inTile(pin1, find.textContaining('·')), findsNothing);
      final titleRight = tester.getTopRight(inTile(pin1, find.text('고정 1')));
      final countLeft = tester.getTopLeft(inTile(pin1, find.text('2')));
      final avatarLeft = tester.getTopLeft(
        inTile(pin1, find.byType(AvatarView)),
      );
      final nameLeft = tester.getTopLeft(inTile(pin1, find.text('이영희')));
      expect(titleRight.dx, lessThan(countLeft.dx));
      expect(countLeft.dx, lessThan(avatarLeft.dx));
      expect(avatarLeft.dx, lessThan(nameLeft.dx));
      // 고정 영역이 보통 글보다 위다.
      expect(
        tester.getTopLeft(find.text('고정된 게시글 4')).dy,
        lessThan(tester.getTopLeft(find.text('보통 글')).dy),
      );

      await tester.tap(find.text('더 보기'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pinned-pin4')), findsOneWidget);
      await tester.tap(find.text('접기'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pinned-pin4')), findsNothing);
    });

    testWidgets('아래로 내려가면 과거 글을 더 불러온다(before 커서)', (tester) async {
      final room = _room('r1');
      final server = _Server();
      // 첫 페이지는 50개(더 있음), 두 번째 요청(before)은 과거 글 하나.
      server.routes['GET /api/rooms/r1/messages'] = (r) => _json(
        r.url.queryParameters['before'] == null
            ? [
                for (var i = 0; i < 50; i++)
                  _post('p$i', title: '글 $i', minutes: 100 + i),
              ]
            : [_post('old', title: '아주 오래된 글', minutes: 1)],
      );
      final session = _session(server, rooms: [room]);
      await _pumpBoard(tester, session, room);
      expect(find.text('아주 오래된 글'), findsNothing);

      await tester.dragUntilVisible(
        find.text('아주 오래된 글'),
        find.byKey(const ValueKey('board-list')),
        const Offset(0, -500),
        maxIteration: 60,
      );
      expect(find.text('아주 오래된 글'), findsOneWidget);
      final pages = server.called('GET', '/api/rooms/r1/messages');
      expect(pages.last.url.queryParameters['before'], '${_at(100)}');
    });

    testWidgets('실시간 — 새 글은 맨 위, 수정·고정은 그 자리, 삭제는 사라지고 댓글 수가 는다', (
      tester,
    ) async {
      final room = _room('r1');
      final server = _boardServer(
        history: [_post('p1', title: '원래 글', minutes: 1)],
      );
      final session = _session(server, rooms: [room]);
      await _pumpBoard(tester, session, room);
      final controller = session.controllerFor(room);

      await session.handleSocketMessage(
        Message.fromJson(_post('p2', title: '방금 올라온 글', minutes: 2)),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('방금 올라온 글')).dy,
        lessThan(tester.getTopLeft(find.text('원래 글')).dy),
      );

      controller.applyEdit(
        Message.fromJson(
          _post(
            'p1',
            title: '고친 글',
            minutes: 1,
            editedAt: _at(3),
            pinnedAt: _at(3),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('원래 글'), findsNothing);
      expect(
        find.descendant(of: _card('p1'), matching: find.text('고친 글')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _card('p1'),
          matching: find.textContaining('(수정됨)'),
        ),
        findsOneWidget,
      );
      expect(find.text('고정된 게시글 1'), findsOneWidget);

      controller.addComment(
        Comment.fromJson(_comment('c9', 'p2', '첫 댓글', minutes: 4)),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: _card('p2'), matching: find.text('댓글 1')),
        findsOneWidget,
      );

      controller.applyDelete('p2');
      await tester.pumpAndSettle();
      expect(find.text('방금 올라온 글'), findsNothing);
      expect(_card('p2'), findsNothing);
    });

    testWidgets('검색 결과로 열면 그 게시글 상세를 바로 연다', (tester) async {
      final room = _room('r1');
      final server = _boardServer(
        history: [
          _post('p1', title: '찾던 글', minutes: 1),
          _post('p2', title: '다른 글', minutes: 2),
        ],
      );
      final session = _session(server, rooms: [room]);
      final opened = <Message>[];
      await _pumpBoard(
        tester,
        session,
        room,
        highlightMessageId: 'p1',
        onOpenThread: opened.add,
      );
      expect(opened.map((m) => m.id), ['p1']);

      // 카드를 누르면 같은 통로(데스크톱은 오른쪽 패널, 모바일은 새 화면)로 연다.
      await tester.tap(find.text('다른 글'));
      await tester.pumpAndSettle();
      expect(opened.map((m) => m.id), ['p1', 'p2']);
      await tester.pump(const Duration(seconds: 4)); // 강조 표시 타이머
    });

    testWidgets('360px 휴대폰 폭 — 긴 제목·첨부·고정이 있어도 넘치지 않는다', (tester) async {
      final room = _room('r1', name: '아주 긴 이름의 보드 토픽입니다 정말로 길어요');
      final long = '아주 긴 제목 ' * 12;
      final server = _boardServer(
        history: [
          _post(
            'p1',
            title: long,
            text: '긴 본문 ' * 80,
            senderName: '이름이 아주 긴 사람 김철수철수',
            editedAt: _at(5),
            pinnedAt: _at(5),
            attachments: [
              for (var i = 1; i <= 5; i++) _image('img$i'),
              _file('f1', '${'아주긴파일이름' * 6}.pdf'),
            ],
            comments: [_comment('c1', 'p1', '댓글')],
          ),
        ],
        pinned: [
          _post('p1', title: long, pinnedAt: _at(5)),
          for (var i = 2; i <= 4; i++)
            _post(
              'pin$i',
              title: long,
              pinnedAt: _at(5),
              senderName: '이름이 아주 긴 사람 김철수철수',
              senderId: 'u9',
              comments: [
                if (i == 2) _comment('pc$i', 'pin$i', '확인', minutes: 6),
              ],
            ),
        ],
      );
      final session = _session(server, rooms: [room]);
      await _pumpBoard(tester, session, room, size: const Size(360, 740));
      expect(tester.takeException(), isNull);
      // 고정 줄은 제목부터 말줄임 — 댓글 수·작성자는 그대로 보인다(긴 이름은 그 칸에서 말줄임). 댓글이 없는 줄은
      // 댓글 수 자리 없이 작성자가 붙는다.
      final pin2 = find.byKey(const ValueKey('pinned-pin2'));
      expect(
        find.descendant(of: pin2, matching: find.text('1')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('pinned-pin3')),
          matching: find.byKey(const ValueKey('pinned-comments')),
        ),
        findsNothing,
      );
      final name = tester.renderObject<RenderParagraph>(
        find.descendant(of: pin2, matching: find.text('이름이 아주 긴 사람 김철수철수')),
      );
      expect(name.didExceedMaxLines, isTrue);
      final title = tester.renderObject<RenderParagraph>(
        find.descendant(of: pin2, matching: find.text(long)),
      );
      expect(title.didExceedMaxLines, isTrue);
      expect(
        tester
            .getSize(find.descendant(of: pin2, matching: find.text(long)))
            .width,
        greaterThan(60),
      );
      // 좁은 화면의 글쓰기 버튼은 동그란 연필만.
      expect(find.byTooltip('게시글 작성'), findsOneWidget);
      expect(find.text('게시글 작성'), findsNothing);
    });
  });

  group('권한 — 메뉴와 글쓰기 버튼', () {
    List<Map<String, dynamic>> history() => [
      _post('mine', title: '내 글', senderId: 'me', senderName: '나', minutes: 1),
      _post('other', title: '남의 글', minutes: 2),
    ];

    testWidgets('보통 멤버 — 내 글은 수정·삭제·즐겨찾기, 남의 글은 즐겨찾기만', (tester) async {
      final room = _room('r1');
      final session = _session(_boardServer(history: history()), rooms: [room]);
      await _pumpBoard(tester, session, room);

      // 남의 글 메뉴에는 고정·수정·삭제가 없고 즐겨찾기만 있다(즐겨찾기는 누구나).
      await _openMenu(tester, 'other');
      expect(find.text('즐겨찾기'), findsOneWidget);
      expect(find.text('수정'), findsNothing);
      expect(find.text('삭제'), findsNothing);
      expect(find.text('게시글 고정'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await _openMenu(tester, 'mine');
      expect(find.text('즐겨찾기'), findsOneWidget);
      expect(find.text('수정'), findsOneWidget);
      expect(find.text('삭제'), findsOneWidget);
      expect(find.text('게시글 고정'), findsNothing);
      // 글쓰기 버튼(넓은 화면은 글자까지).
      expect(find.byTooltip('게시글 작성'), findsOneWidget);
    });

    testWidgets('토픽 관리자 — 남의 글도 고정·삭제(수정은 작성자만)', (tester) async {
      final room = _room('r1', admins: ['me']);
      final session = _session(_boardServer(history: history()), rooms: [room]);
      await _pumpBoard(tester, session, room);

      await _openMenu(tester, 'other');
      expect(find.text('게시글 고정'), findsOneWidget);
      expect(find.text('삭제'), findsOneWidget);
      expect(find.text('수정'), findsNothing);
    });

    testWidgets('읽기 전용 토픽의 보통 멤버 — 글쓰기 버튼·수정은 없고 삭제는 된다', (tester) async {
      final room = _room('r1', readOnly: true);
      final session = _session(_boardServer(history: history()), rooms: [room]);
      await _pumpBoard(tester, session, room);

      expect(find.byTooltip('게시글 작성'), findsNothing);
      // 입력칸이 없는 대신 아래에 왜 쓸 수 없는지 알려 준다(채팅 입력칸 안내와 같은 문구).
      expect(find.text('읽기 전용 토픽입니다. 토픽 관리자만 글을 쓸 수 있습니다.'), findsOneWidget);
      await _openMenu(tester, 'mine');
      expect(find.text('수정'), findsNothing);
      expect(find.text('삭제'), findsOneWidget);
    });

    testWidgets('빈 보드 — 쓸 수 있으면 연필 안내까지, 읽기 전용 멤버는 안내 없이', (tester) async {
      final member = _session(
        _boardServer(),
        rooms: [_room('r1', readOnly: true)],
      );
      await _pumpBoard(tester, member, member.rooms.single);
      expect(find.text('아직 게시글이 없습니다.'), findsOneWidget);
      expect(find.text('오른쪽 아래 연필 버튼으로 첫 게시글을 작성해 보세요.'), findsNothing);
      expect(find.byTooltip('게시글 작성'), findsNothing);

      // 팀 관리자(소유자)는 읽기 전용이어도 쓸 수 있다.
      final owner = _session(
        _boardServer(),
        rooms: [_room('r1', readOnly: true)],
        teamOwner: true,
      );
      await _pumpBoard(tester, owner, owner.rooms.single);
      expect(find.text('아직 게시글이 없습니다.'), findsOneWidget);
      expect(find.text('오른쪽 아래 연필 버튼으로 첫 게시글을 작성해 보세요.'), findsOneWidget);
      expect(find.byTooltip('게시글 작성'), findsOneWidget);
      expect(find.text('읽기 전용 토픽입니다. 토픽 관리자만 글을 쓸 수 있습니다.'), findsNothing);
    });

    testWidgets('팀이 메시지 수정/삭제를 꺼두면 작성자도 수정·삭제 메뉴가 없다(즐겨찾기만)', (tester) async {
      final room = _room('r1');
      final session = _session(_boardServer(history: history()), rooms: [room]);
      session.currentTeam!.messageEditDeleteEnabled = false;
      await _pumpBoard(tester, session, room);
      await _openMenu(tester, 'mine');
      expect(find.text('즐겨찾기'), findsOneWidget);
      expect(find.text('수정'), findsNothing);
      expect(find.text('삭제'), findsNothing);
    });
  });

  group('고정·삭제', () {
    testWidgets('고정/해제 요청을 보내고 고정 영역이 바로 바뀐다', (tester) async {
      final room = _room('r1', admins: ['me']);
      final server = _boardServer(history: [_post('p2', title: '공지할 글')]);
      server.routes['POST /api/messages/p2/pin'] = (r) => _json(
        _post(
          'p2',
          title: '공지할 글',
          pinnedAt: _body(r)['pinned'] == true ? _at(9) : null,
        ),
      );
      final session = _session(server, rooms: [room]);
      await _pumpBoard(tester, session, room);

      await _openMenu(tester, 'p2');
      await tester.tap(find.text('게시글 고정'));
      await tester.pumpAndSettle();
      expect(_body(server.called('POST', '/api/messages/p2/pin').single), {
        'pinned': true,
      });
      expect(find.text('고정된 게시글 1'), findsOneWidget);
      expect(find.byKey(const ValueKey('pinned-p2')), findsOneWidget);
      await _flushToasts(tester);

      await _openMenu(tester, 'p2');
      await tester.tap(find.text('게시글 고정 해제'));
      await tester.pumpAndSettle();
      expect(_body(server.called('POST', '/api/messages/p2/pin').last), {
        'pinned': false,
      });
      expect(find.byKey(const ValueKey('board-pinned')), findsNothing);
      await _flushToasts(tester);
    });

    testWidgets('삭제는 한 번 더 묻고, 확인하면 요청 후 목록에서 사라진다', (tester) async {
      final room = _room('r1');
      final server = _boardServer(
        history: [
          _post('mine', title: '지울 글', senderId: 'me', senderName: '나'),
        ],
      );
      server.routes['DELETE /api/messages/mine'] = (_) => _json({'ok': true});
      final session = _session(server, rooms: [room]);
      await _pumpBoard(tester, session, room);

      await _openMenu(tester, 'mine');
      await tester.tap(find.text('삭제'));
      await tester.pumpAndSettle();
      expect(find.text('게시글 삭제'), findsOneWidget);
      expect(find.text("'지울 글' 게시글을 삭제할까요?"), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(server.called('DELETE', '/api/messages/mine'), isEmpty);
      expect(find.text('지울 글'), findsOneWidget);

      await _openMenu(tester, 'mine');
      await tester.tap(find.text('삭제'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('삭제'),
        ),
      );
      await tester.pumpAndSettle();
      expect(server.called('DELETE', '/api/messages/mine'), hasLength(1));
      expect(find.text('지울 글'), findsNothing);
      expect(find.text('아직 게시글이 없습니다.'), findsOneWidget);
      await _flushToasts(tester);
    });
  });

  group('게시글 편집기', () {
    testWidgets('빈 제목·본문은 칸 아래에 알리고 보내지 않는다 · Esc로 닫힌다', (tester) async {
      final room = _room('r1');
      final session = _session(_boardServer(), rooms: [room]);
      var sends = 0;
      session.chatSocket.debugSendOverride = (payload) async {
        sends++;
        return {'ok': true};
      };
      await _pumpBoard(tester, session, room);

      await tester.tap(find.byTooltip('게시글 작성'));
      await tester.pumpAndSettle();
      expect(find.byType(PostEditor), findsOneWidget);
      expect(find.text('0/100'), findsOneWidget); // 제목 글자 수

      await tester.tap(find.byKey(const ValueKey('post-submit')));
      await tester.pumpAndSettle();
      expect(find.text('제목을 입력하세요.'), findsOneWidget);
      expect(find.text('내용을 입력하세요.'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('post-title')), '제목만');
      await tester.pump();
      expect(find.text('제목을 입력하세요.'), findsNothing); // 고치면 바로 사라진다
      await tester.tap(find.byKey(const ValueKey('post-submit')));
      await tester.pumpAndSettle();
      expect(find.text('내용을 입력하세요.'), findsOneWidget);
      expect(sends, 0);

      // 쓰던 게 있으면 Esc는 한 번 묻는다.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('작성 중인 게시글을 버리고 닫을까요?'), findsOneWidget);
      await tester.tap(find.text('계속 쓰기'));
      await tester.pumpAndSettle();
      expect(find.byType(PostEditor), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('post-title')), '');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(PostEditor), findsNothing);
      expect(postEditorsOpen.value, 0);
    });

    testWidgets('첨부를 올리고 게시하면 type post·제목·본문·첨부 목록을 보낸다(Ctrl+Enter)', (
      tester,
    ) async {
      final room = _room('r1');
      final server = _boardServer();
      var uploads = 0;
      server.routes['POST /api/upload'] = (_) {
        uploads++;
        final name = uploads == 1 ? '회의록.txt' : '견적서.pdf';
        return _json({
          'url': '/uploads/u$uploads-$name',
          'fileName': name,
          'size': 5,
          'mimeType': uploads == 1 ? 'text/plain' : 'application/pdf',
        });
      };
      final session = _session(server, rooms: [room]);
      final sent = <Map<String, dynamic>>[];
      session.chatSocket.debugSendOverride = (payload) async {
        sent.add(payload);
        return {'ok': true};
      };
      final dir = Directory.systemTemp.createTempSync('board_view_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final a = File('${dir.path}${Platform.pathSeparator}회의록.txt')
        ..writeAsStringSync('hello');
      final b = File('${dir.path}${Platform.pathSeparator}견적서.pdf')
        ..writeAsStringSync('%PDF-');
      await _pumpBoard(tester, session, room);

      // 보드에 파일을 끌어다 놓은 것처럼 — 그 파일을 붙인 채로 편집기가 열리고 바로 올라간다.
      final board = tester.state<BoardViewState>(find.byType(BoardView));
      unawaited(board.compose(files: [a, b]));
      await tester.pumpAndSettle();
      final editor = tester.state<PostEditorState>(find.byType(PostEditor));
      await _settleIo(tester, () => uploads == 2 && !editor.debugUploading);
      expect(uploads, 2);
      expect(find.text('회의록.txt'), findsOneWidget);
      expect(find.text('견적서.pdf'), findsOneWidget);
      expect(find.text('2/30'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('post-title')),
        '  3분기 회의록 ',
      );
      await tester.enterText(
        find.byKey(const ValueKey('post-body')),
        '정리했습니다.',
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(sent.single, {
        'roomId': 'r1',
        'type': 'post',
        'title': '3분기 회의록',
        'text': '정리했습니다.',
        'attachments': [
          {
            'kind': 'file',
            'fileUrl': '/uploads/u1-회의록.txt',
            'fileName': '회의록.txt',
            'fileSize': 5,
            'mimeType': 'text/plain',
          },
          {
            'kind': 'file',
            'fileUrl': '/uploads/u2-견적서.pdf',
            'fileName': '견적서.pdf',
            'fileSize': 5,
            'mimeType': 'application/pdf',
          },
        ],
      });
      expect(find.byType(PostEditor), findsNothing);
    });

    testWidgets('서버가 거절하면 그 문구를 알리고 편집기는 열린 채로 둔다', (tester) async {
      final room = _room('r1');
      final session = _session(_boardServer(), rooms: [room]);
      session.chatSocket.debugSendOverride = (payload) async => {
        'ok': false,
        'error': '읽기 전용 토픽에서는 토픽 관리자만 글을 쓸 수 있습니다.',
      };
      await _pumpBoard(tester, session, room);
      await tester.tap(find.byTooltip('게시글 작성'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('post-title')), '제목');
      await tester.enterText(find.byKey(const ValueKey('post-body')), '본문');
      await tester.tap(find.byKey(const ValueKey('post-submit')));
      await tester.pump();
      await tester.pump();
      expect(find.text('읽기 전용 토픽에서는 토픽 관리자만 글을 쓸 수 있습니다.'), findsOneWidget);
      expect(find.byType(PostEditor), findsOneWidget);
      await _flushToasts(tester);

      // 열린 편집기 수(postEditorsOpen)는 전역이라 다음 테스트에 남지 않게 닫고 끝낸다.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      expect(find.byType(PostEditor), findsNothing);
    });

    testWidgets('30개를 넘게 붙이면 넘는 만큼 빼고 알린다', (tester) async {
      final room = _room('r1');
      final session = _session(_boardServer(), rooms: [room]);
      // 목록 개수만 본다 — 없는 경로라 업로드는 파일을 열지도 못한 채 멈춰 있다.
      final files = [
        for (var i = 0; i < 32; i++)
          File('${Directory.systemTemp.path}/board_view_none_$i.txt'),
      ];
      await _pumpBoard(tester, session, room);
      await tester.tap(find.byTooltip('게시글 작성'));
      await tester.pumpAndSettle();

      tester.state<PostEditorState>(find.byType(PostEditor)).addFiles(files);
      await tester.pump();
      expect(find.text('30/30'), findsOneWidget);
      expect(find.text('첨부 파일은 30개까지 올릴 수 있습니다.'), findsOneWidget);

      // 붙인 파일이 있으면 닫을 때 한 번 묻고, 닫으면 멈춰 있던 업로드는 버린다. 올리는 중인
      // 첨부의 진행 막대가 계속 움직여서 pumpAndSettle 대신 시간을 정해 흘린다.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('닫기'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.byType(PostEditor), findsNothing);
      await tester.pump(const Duration(seconds: 21)); // 첫 업로드 요청의 시간 초과
      await _flushToasts(tester);
    });

    testWidgets('수정 — 제목·본문이 채워져 열리고 첨부는 보기만, 저장은 PATCH', (tester) async {
      final room = _room('r1');
      final server = _boardServer(
        history: [
          _post(
            'mine',
            title: '원래 제목',
            text: '원래 본문',
            senderId: 'me',
            senderName: '나',
            attachments: [_file('f1', '자료.pdf')],
          ),
        ],
      );
      server.routes['PATCH /api/messages/mine'] = (r) => _json(
        _post(
          'mine',
          title: _body(r)['title'] as String,
          text: _body(r)['text'] as String,
          senderId: 'me',
          senderName: '나',
          editedAt: _at(10),
          attachments: [_file('f1', '자료.pdf')],
        ),
      );
      final session = _session(server, rooms: [room]);
      await _pumpBoard(tester, session, room);

      await _openMenu(tester, 'mine');
      await tester.tap(find.text('수정'));
      await tester.pumpAndSettle();
      expect(find.text('게시글 수정'), findsOneWidget);
      final title = tester.widget<TextField>(
        find.byKey(const ValueKey('post-title')),
      );
      expect(title.controller!.text, '원래 제목');
      final body = tester.widget<TextField>(
        find.byKey(const ValueKey('post-body')),
      );
      expect(body.controller!.text, '원래 본문');
      expect(find.text('첨부 파일 1개'), findsOneWidget);
      expect(find.text('첨부 파일은 수정할 수 없습니다.'), findsOneWidget);
      expect(find.byKey(const ValueKey('post-attach')), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('post-title')), '고친 제목');
      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();
      expect(_body(server.called('PATCH', '/api/messages/mine').single), {
        'title': '고친 제목',
        'text': '원래 본문',
        // 수정은 멘션 집합을 통째로 보낸다(멘션이 없으면 빈 목록).
        'mentions': <Object>[],
      });
      expect(find.byType(PostEditor), findsNothing);
      expect(find.text('고친 제목'), findsOneWidget);
      expect(find.textContaining('(수정됨)'), findsOneWidget);
    });

    testWidgets('좁은 화면은 전체 화면 편집기 — 360px에서도 넘치지 않는다', (tester) async {
      final room = _room('r1', name: '아주 긴 이름의 보드 토픽입니다 정말로 길어요');
      final session = _session(_boardServer(), rooms: [room]);
      await _pumpBoard(tester, session, room, size: const Size(360, 740));
      await tester.tap(find.byTooltip('게시글 작성'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.widgetWithText(AppBar, '게시글 작성'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('취소'));
      await tester.pumpAndSettle();
      expect(find.byType(PostEditor), findsNothing);
    });
  });

  group('게시글 상세', () {
    testWidgets('제목·본문·첨부와 댓글, 댓글 입력칸을 보여준다', (tester) async {
      final room = _room('r1');
      final server = _boardServer();
      final session = _session(server, rooms: [room]);
      final post = Message.fromJson(
        _post(
          'p1',
          title: '9월 행사 안내',
          text: '행사는 금요일입니다.',
          editedAt: _at(5),
          pinnedAt: _at(5),
          attachments: [_file('f1', '행사안내.pdf')],
          comments: [
            _comment('c1', 'p1', '참석합니다', minutes: 6),
            _comment('c2', 'p1', '저도요', minutes: 7, senderId: 'u3'),
          ],
        ),
      );
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: MessageThreadScreen(
            session: session,
            room: room,
            message: post,
            controller: session.controllerFor(room),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, '게시글'), findsOneWidget);
      expect(find.byType(PostDetailHead), findsOneWidget);
      expect(find.byType(MessageBubble), findsNothing);
      expect(find.text('9월 행사 안내'), findsOneWidget);
      expect(find.text('행사는 금요일입니다.'), findsOneWidget);
      expect(find.text('행사안내.pdf'), findsOneWidget);
      expect(find.byType(PinnedPostTag), findsOneWidget);
      expect(find.textContaining('(수정됨)'), findsOneWidget);
      expect(find.text('댓글 2'), findsOneWidget);
      // 게시글·댓글 시각도 같은 형식(게시글은 작성 시각 + 수정됨).
      expect(find.text('2026/09/29 AM 9:00 (수정됨)'), findsOneWidget);
      expect(find.text('2026/09/29 AM 9:06'), findsOneWidget);
      expect(find.text('2026/09/29 AM 9:07'), findsOneWidget);
      expect(find.text('참석합니다'), findsOneWidget);
      expect(find.text('저도요'), findsOneWidget);
      expect(find.byType(CommentInputBar), findsOneWidget);
    });

    testWidgets('말풍선에 게시글이 오면 게시글 카드로 그린다', (tester) async {
      final session = _session(_Server());
      final post = Message.fromJson(
        _post('p1', title: '말풍선 속 게시글', text: '본문 내용'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              session: session,
              message: post,
              resolveUrl: (u) => u,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('post-bubble')), findsOneWidget);
      expect(find.text('게시글'), findsOneWidget);
      expect(find.text('말풍선 속 게시글'), findsOneWidget);
      expect(find.text('본문 내용'), findsOneWidget);
    });
  });

  group('공유·전달·자동화 대상', () {
    List<Room> rooms({List<String> readOnlyAdmins = const []}) => [
      _room('chat', name: '일반 토픽', board: false),
      _room('board', name: '공지 보드'),
      _room(
        'ro',
        name: '읽기 전용 토픽',
        board: false,
        readOnly: true,
        admins: readOnlyAdmins,
      ),
      _room('g1', name: '프로젝트 그룹', type: 'group', board: false),
    ];

    Message message() => Message(
      id: 'm1',
      roomId: 'chat',
      senderId: 'u2',
      senderName: '김철수',
      type: MessageType.text,
      text: '전달할 글',
      createdAt: DateTime(2026, 9, 29),
    );

    Future<void> openPicker(WidgetTester tester, Widget screen) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => screen)),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('대화방 선택'));
      await tester.pumpAndSettle();
    }

    testWidgets('메시지 전달 — 보드 뷰 토픽과 내가 쓸 수 없는 토픽은 목록에 없다', (tester) async {
      final session = _session(_Server(), rooms: rooms());
      await openPicker(
        tester,
        MessageForwardScreen(
          session: session,
          message: message(),
          senderDisplayName: '김철수',
        ),
      );
      expect(find.text('일반 토픽'), findsOneWidget);
      expect(find.text('공지 보드'), findsNothing);
      expect(find.text('읽기 전용 토픽'), findsNothing);
    });

    testWidgets('메시지 공유 — 읽기 전용 토픽도 관리자면 보이지만 보드는 여전히 없다', (tester) async {
      final session = _session(_Server(), rooms: rooms(readOnlyAdmins: ['me']));
      await openPicker(
        tester,
        MessageShareScreen(
          session: session,
          message: message(),
          senderDisplayName: '김철수',
        ),
      );
      expect(find.text('일반 토픽'), findsOneWidget);
      expect(find.text('읽기 전용 토픽'), findsOneWidget);
      expect(find.text('공지 보드'), findsNothing);
      expect(canForwardTo(session, session.roomById('board')!), isFalse);
      expect(canForwardTo(session, session.roomById('g1')!), isTrue);
    });

    testWidgets('게시글 전달 — 제목을 첫 줄로 본문과 함께, 첨부는 목록으로', (tester) async {
      final session = _session(_Server(), rooms: rooms());
      final sent = <Map<String, dynamic>>[];
      session.chatSocket.debugSendOverride = (payload) async {
        sent.add(payload);
        return {'ok': true};
      };
      final post = Message.fromJson({
        ..._post('p1', title: '안내', text: '본문', attachments: [_image('i1')]),
        'roomId': 'board',
      });
      await openPicker(
        tester,
        MessageForwardScreen(
          session: session,
          message: post,
          senderDisplayName: '김철수',
        ),
      );
      await tester.tap(find.text('일반 토픽'));
      await tester.pumpAndSettle();
      expect(find.text('안내\n\n본문'), findsOneWidget);
      expect(find.text('사진 1장'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '전달'));
      await tester.pumpAndSettle();
      expect(sent.single['roomId'], 'chat');
      expect(sent.single['type'], 'image');
      expect(sent.single['text'], '안내\n\n본문');
      expect((sent.single['attachments'] as List).single['kind'], 'image');
    });
  });

  testWidgets('자동화 "채팅방 알림" — 보드 뷰 토픽과 내가 쓸 수 없는 토픽은 고를 수 없다', (tester) async {
    final server = _Server();
    server.routes['GET /api/projects/p1'] = (_) => _json({
      'id': 'p1',
      'teamId': 't1',
      'name': '마케팅',
      'identifier': 'MKT',
      'createdAt': 0,
      'members': [_user('me', '나')],
    });
    server.routes['GET /api/projects/p1/task-statuses'] = (_) => _json([
      {
        'id': 's1',
        'projectId': 'p1',
        'name': '할 일',
        'color': '#94A3B8',
        'category': 'todo',
      },
    ]);
    final session = _session(
      server,
      rooms: [
        _room('chat', name: '일반 토픽', board: false),
        _room('board', name: '공지 보드'),
        _room('ro', name: '읽기 전용 토픽', board: false, readOnly: true),
        _room(
          'ro-admin',
          name: '관리하는 읽기 전용 토픽',
          board: false,
          readOnly: true,
          admins: ['me'],
        ),
      ],
    );
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showAutomationFlowEditor(
                context,
                session: session,
                projectId: 'p1',
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    // 팔레트의 "채팅방 알림"을 캔버스로 끌어다 놓는다(데스크톱 마우스처럼).
    final from = tester.getCenter(
      find.byKey(const ValueKey('palette-action-chat_message')),
    );
    final to =
        tester.getTopLeft(find.byKey(const ValueKey('automation-canvas'))) +
        const Offset(300, 120);
    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(12, 0));
    await tester.pump();
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await gesture.removePointer();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('pick-room')));
    await tester.pumpAndSettle();
    final popup = find.byType(FilterPopupCard);
    expect(
      find.descendant(of: popup, matching: find.text('일반 토픽')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: popup, matching: find.text('공지 보드')),
      findsNothing,
    );
    // 서버도 읽기 전용 토픽 알림은 그 토픽을 관리할 수 있는 사람이 저장한 규칙만 받는다.
    expect(
      find.descendant(of: popup, matching: find.text('읽기 전용 토픽')),
      findsNothing,
    );
    expect(
      find.descendant(of: popup, matching: find.text('관리하는 읽기 전용 토픽')),
      findsOneWidget,
    );
    await tester.tap(find.descendant(of: popup, matching: find.text('일반 토픽')));
    await tester.pumpAndSettle();
  });

  testWidgets('검색 결과 — 게시글은 "게시글" 표시와 제목을 보여준다', (tester) async {
    final server = _Server();
    server.routes['GET /api/search'] = (_) => _json([
      {
        'id': 'p1',
        'roomId': 'r1',
        'roomName': '주간 보고',
        'senderId': 'u2',
        'senderName': '김철수',
        'type': 'post',
        'title': '3분기 실적 정리',
        'text': '실적 요약입니다.',
        'createdAt': _at(1),
      },
    ]);
    final session = _session(server, rooms: [_room('r1')]);
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: SearchScreen(session: session)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '실적');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('게시글'), findsOneWidget);
    // 검색어가 칠해진 RichText라 글자 전체로 찾는다.
    expect(find.textContaining('3분기', findRichText: true), findsOneWidget);
    expect(find.textContaining('요약입니다', findRichText: true), findsOneWidget);
  });

  group('정리·오류·글자 수', () {
    testWidgets('내보내진 방의 채팅·보드 화면을 닫아도 그 방 컨트롤러를 다시 만들지 않는다', (tester) async {
      for (final board in [false, true]) {
        final room = _room('r1', board: board);
        final server = _boardServer(history: [_post('p1')]);
        final session = _session(server, rooms: [room]);
        await _pumpBoard(tester, session, room);
        final loads = server.called('GET', '/api/rooms/r1/messages').length;

        session.handleRoomRemoved(
          const RoomRemovedEvent(roomId: 'r1', reason: 'kicked'),
        );
        await tester.pump();
        // 홈 화면이 그 방을 닫는다.
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        expect(session.existingControllerFor('r1'), isNull);
        expect(
          server.called('GET', '/api/rooms/r1/messages'),
          hasLength(loads),
        );
      }
    });

    testWidgets('사라진 보드가 닫히기 전에 한 번 더 그려져도 오류가 나지 않는다', (tester) async {
      final room = _room('r1');
      final session = _session(
        _boardServer(history: [_post('p1')]),
        rooms: [room],
      );
      await _pumpBoard(tester, session, room);
      session.handleRoomRemoved(
        const RoomRemovedEvent(roomId: 'r1', reason: 'deleted'),
      );
      await tester.pump();
      // 모바일이 목록으로 돌아가는 동안처럼 같은 화면이 다시 그려진다.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPanel(
              key: ValueKey(room.id),
              session: session,
              room: room,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(session.existingControllerFor('r1'), isNull);
    });

    testWidgets('게시글을 못 불러오면 계속 도는 대신 알리고 다시 시도할 수 있다', (tester) async {
      final room = _room('r1');
      final server = _Server();
      var fail = true;
      server.routes['GET /api/rooms/r1/messages'] = (_) => fail
          ? _json({'error': '잠시 후 다시 시도하세요.'}, 500)
          : _json([_post('p1', title: '다시 받은 글')]);
      final session = _session(server, rooms: [room]);
      await _pumpBoard(tester, session, room);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('게시글을 불러오지 못했습니다.'), findsOneWidget);
      expect(find.text('아직 게시글이 없습니다.'), findsNothing);

      fail = false;
      await tester.tap(find.text('다시 시도'));
      await tester.pumpAndSettle();
      expect(find.text('다시 받은 글'), findsOneWidget);
      expect(find.text('게시글을 불러오지 못했습니다.'), findsNothing);
    });

    testWidgets('게시글 상세의 댓글 수도 카드처럼 지운 댓글은 세지 않는다', (tester) async {
      final room = _room('r1');
      final session = _session(_boardServer(), rooms: [room]);
      final post = Message.fromJson(
        _post(
          'p1',
          comments: [
            _comment('c1', 'p1', '남은 댓글', minutes: 1),
            {..._comment('c2', 'p1', '', minutes: 2), 'deleted': true},
          ],
        ),
      );
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: MessageThreadScreen(
            session: session,
            room: room,
            message: post,
            controller: session.controllerFor(room),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('댓글 1'), findsOneWidget);
      expect(find.text('남은 댓글'), findsOneWidget);
    });

    testWidgets('"전체 다운로드" 글자는 앱 테마 글꼴(대체 글꼴 포함)을 그대로 쓴다', (tester) async {
      final session = _session(_Server());
      final base = ThemeData(useMaterial3: true);
      await tester.pumpWidget(
        MaterialApp(
          theme: base.copyWith(
            textTheme: base.textTheme.apply(
              fontFamilyFallback: const ['KoreanFallback'],
            ),
          ),
          home: Scaffold(
            body: AllDownloadBar(
              session: session,
              items: const [
                (url: 'https://test.local/a.png', fileName: 'a.png'),
                (url: 'https://test.local/b.png', fileName: 'b.png'),
              ],
            ),
          ),
        ),
      );
      final label = tester.renderObject<RenderParagraph>(
        find.text('전체 다운로드 (2)'),
      );
      expect(label.text.style?.fontFamilyFallback, contains('KoreanFallback'));
      expect(label.text.style?.fontSize, 12);
    });

    testWidgets('제목·본문 글자 수는 서버처럼 글자 단위 — 이모지 제목 100자도 게시된다', (tester) async {
      final room = _room('r1');
      final session = _session(_boardServer(), rooms: [room]);
      final sent = <Map<String, dynamic>>[];
      session.chatSocket.debugSendOverride = (payload) async {
        sent.add(payload);
        return {'ok': true};
      };
      await _pumpBoard(tester, session, room);
      await tester.tap(find.byTooltip('게시글 작성'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('post-title')),
        '🎉' * 100,
      );
      await tester.enterText(
        find.byKey(const ValueKey('post-body')),
        '👍' * 18500,
      );
      await tester.pump();
      expect(find.text('100/100'), findsOneWidget);
      // 본문 글자 수도 이모지 한 덩어리를 한 자로 센다(UTF-16이면 37000).
      expect(find.text('18500/20000'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('post-submit')));
      await tester.pumpAndSettle();
      expect(find.text('제목은 100자까지 쓸 수 있습니다.'), findsNothing);
      expect(sent.single['title'], '🎉' * 100);
      expect(find.byType(PostEditor), findsNothing);
    });

    testWidgets('보드 위에 다른 창이 떠 있으면 보드의 파일 끌어다 놓기를 끈다(Windows)', (tester) async {
      final room = _room('r1');
      final session = _session(_boardServer(), rooms: [room]);
      await _pumpBoard(tester, session, room);
      final boardDrop = find.descendant(
        of: find.byType(ChatPanel),
        matching: find.byType(DropTarget),
      );
      expect(tester.widget<DropTarget>(boardDrop).enable, isTrue);

      // 예: 사진 뷰어·토픽 설정 창 — desktop_drop은 가려진 드롭 영역에도 파일을 준다.
      showDialog<void>(
        context: tester.element(find.byType(BoardView)),
        builder: (_) => const AlertDialog(content: Text('다른 창')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<DropTarget>(boardDrop).enable, isFalse);

      Navigator.of(tester.element(find.text('다른 창'))).pop();
      await tester.pumpAndSettle();
      expect(tester.widget<DropTarget>(boardDrop).enable, isTrue);
    }, skip: !Platform.isWindows);

    testWidgets('휴대폰 편집기는 키보드가 올라와도 본문 칸이 남고 넘치지 않는다', (tester) async {
      final room = _room('r1');
      final server = _boardServer(
        history: [
          _post(
            'mine',
            title: '원래 제목',
            text: '원래 본문',
            senderId: 'me',
            senderName: '나',
            attachments: [
              for (var i = 1; i <= 4; i++) _file('f$i', '자료$i.pdf'),
            ],
          ),
        ],
      );
      final session = _session(server, rooms: [room]);
      await _pumpBoard(tester, session, room, size: const Size(360, 640));
      await _openMenu(tester, 'mine');
      await tester.tap(find.text('수정'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);

      // 키보드가 화면 아래 300을 가린다.
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const ValueKey('post-body'))).height,
        greaterThan(100),
      );
    });

    testWidgets('글을 쓰는 동안 그 보드에서 내보내지면 편집기도 닫힌다', (tester) async {
      final room = _room('r1');
      final session = _session(_boardServer(), rooms: [room]);
      await _pumpBoard(tester, session, room);
      // 앞 테스트가 편집기를 연 채로 끝나면 전역 개수가 남아 있을 수 있어 늘고 준 것만 본다.
      final editorsBefore = postEditorsOpen.value;
      await tester.tap(find.byTooltip('게시글 작성'));
      await tester.pumpAndSettle();
      expect(postEditorsOpen.value, editorsBefore + 1);
      await tester.enterText(find.byKey(const ValueKey('post-title')), '쓰던 글');
      await tester.pump();

      session.handleRoomRemoved(
        const RoomRemovedEvent(roomId: 'r1', reason: 'kicked'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PostEditor), findsNothing);
      expect(postEditorsOpen.value, editorsBefore);
      expect(session.existingControllerFor('r1'), isNull);
    });
  });
}
