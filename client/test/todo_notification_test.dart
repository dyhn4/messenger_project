import 'dart:async';
import 'dart:convert';

import 'package:client/models/app_notification.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/models/todo.dart';
import 'package:client/screens/todo_editor_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_controller.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/services/time_format.dart';
import 'package:client/widgets/compact_menu.dart';
import 'package:client/widgets/notifications_panel.dart';
import 'package:client/widgets/todo_from_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_todo_api.dart';

/// 알림 센터의 "할 일로 등록"(잔디: [알림센터] > [멘션] > 메시지 […] > [할 일]) — 멘션 알림 줄의 ⋯(전체·멘션 탭)가
/// 보이는 조건(할 일을 만들 수 있는 방의 멘션·@all만), ⋯를 눌러도 줄 자체의 탭(방 열기·읽음)은 불리지 않는 것, 메뉴 →
/// 원본(메시지, 댓글 멘션이면 댓글)을 서버에서 받아 채팅의 "할 일로 등록"과 같게 채운 방 고정 생성 창(제목은 첫 줄, 설명은
/// 본문 전체, 첨부까지 — 원본을 못 받으면 미리보기로, 잘린 미리보기면 '…'), 받는 동안 또 눌러도 창은 하나, 저장하면 원본
/// 메시지(댓글 멘션이면 댓글)를 보내는 것, 그리고 PC 패널 폭(420)과 모바일 폭(390)의 배치. 할 일 서버는 가짜
/// API(helpers/fake_todo_api.dart), 알림·원본 조회 서버는 가짜 HTTP로 대신한다.

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

final _now = DateTime.now();

Map<String, dynamic> _user(String id, String name) => {
  'id': id,
  'username': id,
  'name': name,
  'role': 'member',
};

final _members = [_user('me', '나'), _user('u2', '김철수'), _user('u3', '이영희')];

/// 테스트용 방 — 기본은 챗 뷰 토픽. [board]면 보드 뷰 토픽, [secret]이면 비밀 대화, [readOnly]면 읽기 전용 토픽.
Room _room(
  String id, {
  String name = '영업 토픽',
  String teamId = 't1',
  bool board = false,
  bool secret = false,
  bool readOnly = false,
  List<String> adminIds = const [],
}) => Room.fromJson({
  'id': id,
  'teamId': teamId,
  'type': secret ? 'dm' : 'topic',
  'name': secret ? null : name,
  'members': _members,
  'createdAt': 1000,
  'viewMode': board ? 'board' : 'chat',
  'readOnly': readOnly,
  'isSecret': secret,
  'adminIds': adminIds,
});

/// 기본 방들 — 챗 뷰 토픽(r1), 다른 팀의 챗 뷰 토픽(r2), 보드 뷰 토픽, 비밀 대화, 읽기 전용 토픽.
List<Room> _rooms() => [
  _room('r1'),
  _room('r2', name: '개발 토픽', teamId: 't2'),
  _room('board', name: '주간 보고', board: true),
  _room('sec', secret: true),
  _room('ro', name: '공지 토픽', readOnly: true),
];

/// 서버 알림 한 건(DTO) — [minutesAgo]분 전.
Map<String, dynamic> _n(
  String id, {
  String kind = 'mention',
  int minutesAgo = 0,
  bool read = false,
  String roomId = 'r1',
  String roomName = '영업 토픽',
  String teamId = 't1',
  String actor = '김철수',
  String preview = '견적서 확인 부탁드려요',
  String? messageId,
  String? commentId,
}) {
  final t = _now.subtract(Duration(minutes: minutesAgo));
  return {
    'id': id,
    'kind': kind,
    'teamId': teamId,
    'teamName': teamId == 't1' ? '영업팀' : '개발팀',
    'roomId': roomId,
    'roomName': roomName,
    'roomType': 'topic',
    'messageId': messageId ?? 'msg-$id',
    'commentId': commentId,
    'actorId': 'u2',
    'actorName': actor,
    'preview': preview,
    'createdAt': t.millisecondsSinceEpoch,
    'readAt': read ? t.millisecondsSinceEpoch : null,
  };
}

/// 서버 previewOf(notificationRules.js)와 같은 알림 미리보기 — 공백·줄바꿈을 한 칸으로 줄이고 120자(코드 포인트)에서
/// 말줄임표 없이 자른다.
String _previewOf(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final runes = flat.runes.toList();
  return runes.length > notificationPreviewMaxLength
      ? String.fromCharCodes(runes.take(notificationPreviewMaxLength))
      : flat;
}

/// 메시지 한 건 DTO(`GET /api/messages/:id`) — [files]는 (이름, 'image'|'file'), 첨부 주소는 서버처럼 서명된 /files/ 링크.
Map<String, dynamic> _messageDto(
  String id, {
  required String text,
  String roomId = 'r1',
  List<(String, String)> files = const [],
}) => {
  'id': id,
  'roomId': roomId,
  'senderId': 'u2',
  'senderName': '김철수',
  'type': files.isEmpty ? 'text' : files.first.$2,
  'text': text,
  'textFormat': null,
  'mentions': <Object>[],
  'fileUrl': files.isEmpty ? null : '/files/tok-$id-0',
  'fileName': files.isEmpty ? null : files.first.$1,
  'attachments': [
    for (final (i, (name, kind)) in files.indexed)
      {
        'id': 'att-$id-$i',
        'kind': kind,
        'fileUrl': '/files/tok-$id-$i',
        'fileName': name,
        'fileSize': 1024 * (i + 1),
        'mimeType': kind == 'image' ? 'image/png' : 'application/octet-stream',
        'thumbnailUrl': null,
        'deleted': false,
      },
  ],
  'createdAt': _now.millisecondsSinceEpoch,
  'editedAt': null,
  'deleted': false,
};

/// 댓글 한 건 DTO(`GET /api/comments/:id`) — [fileName]을 주면 파일 댓글(서명된 /files/ 링크).
Map<String, dynamic> _commentDto(
  String id, {
  required String messageId,
  required String text,
  String roomId = 'r1',
  String? fileName,
}) => {
  'id': id,
  'messageId': messageId,
  'roomId': roomId,
  'senderId': 'u2',
  'senderName': '김철수',
  'type': fileName == null ? 'text' : 'file',
  'text': text,
  'textFormat': null,
  'mentions': <Object>[],
  'fileUrl': fileName == null ? null : '/files/tok-$id',
  'fileName': fileName,
  'fileSize': fileName == null ? null : 2048,
  'mimeType': fileName == null ? null : 'application/octet-stream',
  'thumbnailUrl': null,
  'createdAt': _now.millisecondsSinceEpoch,
  'editedAt': null,
  'deleted': false,
};

/// 가짜 서버 — 알림 목록(kind·before·limit·unreadOnly)·안 읽음 개수·읽음 처리·설정·프로젝트 알림함, 원본 한 건 조회
/// (`GET /api/messages/:id`·`GET /api/comments/:id` — [messages]·[comments]에 없으면 서버 문구의 404), 그리고
/// `POST /api/rooms/:roomId/todos`(진짜 [RemoteTodoApi]로 만드는 시험용 — 받은 본문을 [createdTodos]에 남긴다).
class _Server {
  final items = <Map<String, dynamic>>[];
  final requests = <http.Request>[];
  final createdTodos = <({String roomId, Map<String, dynamic> body})>[];

  /// 원본 한 건 조회가 돌려줄 DTO(id → DTO).
  final messages = <String, Map<String, dynamic>>{};
  final comments = <String, Map<String, dynamic>>{};

  /// 원본 조회를 붙잡아 둘 때(받는 동안 또 누르기 시험) 쓰는 대기.
  Completer<void>? originalGate;

  /// 옛 서버 — 원본 한 건 조회 길이 없어 Express 기본 404(HTML)를 준다.
  bool legacy = false;

  /// 원본 조회가 연결 실패로 끝난다.
  bool unreachable = false;

  bool _inKind(String kind, Map<String, dynamic> n) {
    final k = n['kind'] as String;
    return switch (kind) {
      'all' => true,
      'mention' => k == 'mention' || k == 'mention_all',
      'mention_personal' => k == 'mention',
      'mention_all' => k == 'mention_all',
      'board' => k.startsWith('board_'),
      _ => false,
    };
  }

  int _unread(String kind) =>
      items.where((n) => _inKind(kind, n) && n['readAt'] == null).length;

  http.Response _ok(Object? body) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    200,
    headers: const {'content-type': 'application/json'},
  );

  http.Response _error(int status, String message) => http.Response.bytes(
    utf8.encode(jsonEncode({'error': message})),
    status,
    headers: const {'content-type': 'application/json'},
  );

  late final client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    final q = request.url.queryParameters;
    final original = RegExp(
      r'^/api/(messages|comments)/([^/]+)$',
    ).firstMatch(path);
    if (request.method == 'GET' && original != null) {
      await originalGate?.future;
      if (unreachable) {
        throw http.ClientException('연결할 수 없습니다.', request.url);
      }
      if (legacy) {
        return http.Response(
          '<pre>Cannot GET $path</pre>',
          404,
          headers: const {'content-type': 'text/html'},
        );
      }
      final comment = original.group(1) == 'comments';
      final dto = (comment ? comments : messages)[original.group(2)];
      if (dto == null) {
        return _error(404, comment ? '댓글을 찾을 수 없습니다.' : '메시지를 찾을 수 없습니다.');
      }
      return _ok(dto);
    }
    if (request.method == 'GET' && path == '/api/notifications') {
      final kind = q['kind'] ?? 'all';
      final before = int.tryParse(q['before'] ?? '');
      final limit = int.tryParse(q['limit'] ?? '') ?? 30;
      final unreadOnly = q['unreadOnly'] == 'true';
      final list =
          [
            for (final n in items)
              if (_inKind(kind, n) &&
                  (before == null || (n['createdAt'] as int) < before) &&
                  (!unreadOnly || n['readAt'] == null))
                n,
          ]..sort(
            (a, b) => (b['createdAt'] as int).compareTo(a['createdAt'] as int),
          );
      return _ok({
        'items': list.take(limit).toList(),
        'hasMore': list.length > limit,
      });
    }
    if (request.method == 'GET' && path == '/api/notifications/unread-counts') {
      return _ok({
        'mention': _unread('mention'),
        'board': _unread('board'),
        'mentionPersonal': _unread('mention_personal'),
        'mentionAll': _unread('mention_all'),
      });
    }
    if (request.method == 'POST' && path == '/api/notifications/read') {
      final body = jsonDecode(request.body) as Map;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final n in items) {
        final hit =
            (body['ids'] is List && (body['ids'] as List).contains(n['id'])) ||
            (body['kind'] is String && _inKind(body['kind'] as String, n));
        if (hit) n['readAt'] ??= now;
      }
      return _ok({'ok': true});
    }
    if (path == '/api/notification-settings') {
      return _ok({'mentionAll': true, 'boardLevel': 'important'});
    }
    if (path == '/api/project-notifications') {
      return _ok({'items': <Object>[], 'unreadCount': 0});
    }
    final todoCreate = RegExp(r'^/api/rooms/([^/]+)/todos$').firstMatch(path);
    if (request.method == 'POST' && todoCreate != null) {
      final roomId = todoCreate.group(1)!;
      final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      createdTodos.add((roomId: roomId, body: body));
      return _ok(
        todoJson(
          id: 'created-${createdTodos.length}',
          roomId: roomId,
          title: body['title'] as String,
          description: body['description'] as String?,
          sourceMessageId: body['sourceMessageId'] as String?,
          sourceCommentId: body['sourceCommentId'] as String?,
        ),
      );
    }
    return _ok(<Object>[]);
  });

  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
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
  final sales = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  final dev = Team(id: 't2', name: '개발팀', createdAt: DateTime(2026));
  session.teams.addAll([sales, dev]);
  session.currentTeam = sales;
  session.rooms.addAll(rooms ?? _rooms());
  return session;
}

/// 패널이 열어 달라고 한 방(줄을 눌렀을 때).
class _Opened {
  Room? room;
  String? messageId;
}

/// [platform]을 주면 그 플랫폼의 테마(PC는 windows — 조밀한 밀도·마우스용 누를 자리)로 그린다.
Widget _host(
  Session session,
  FakeTodoApi api,
  _Opened opened, {
  double width = 420,
  NotificationTab? initialTab,
  TargetPlatform? platform,
}) => MaterialApp(
  theme: platform == null ? null : ThemeData(platform: platform),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topRight,
      child: SizedBox(
        width: width,
        child: NotificationsPanel(
          session: session,
          initialTab: initialTab,
          todoApi: api,
          onClose: () {},
          onSelectRoom: (room, {messageId, announcementPopup = true}) {
            opened
              ..room = room
              ..messageId = messageId;
          },
        ),
      ),
    ),
  ),
);

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 받은 요청이 모두 끝나도록 실제 비동기 작업을 흘려보낸다(가짜 HTTP는 비동기다).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// 패널을 띄운다 — 화면이 [view](기본 PC 창 1000×800)이고 패널 폭은 [width].
Future<void> _pump(
  WidgetTester tester,
  Session session,
  FakeTodoApi api, {
  _Opened? opened,
  Size view = const Size(1000, 800),
  double width = 420,
  NotificationTab? initialTab,
  TargetPlatform? platform,
}) async {
  _size(tester, view);
  await tester.runAsync(session.notificationCenter.refreshCounts);
  await tester.pumpWidget(
    _host(
      session,
      api,
      opened ?? _Opened(),
      width: width,
      initialTab: initialTab,
      platform: platform,
    ),
  );
  await tester.pumpAndSettle();
  await _settle(tester);
}

Finder _key(String k) => find.byKey(ValueKey(k));
Finder _more(String id) => _key('notif-more-$id');
Finder _menuItem(String id) => _key('notif-todo-$id');
Finder _row(String id) => _key('notif-$id');
Finder _tab(NotificationTab t) => _key('notif-tab-${t.name}');

/// 두 번째 줄이 굵은 앞부분 + 본문으로 이어진 Text.rich라서 이어 붙인 글자로 찾는다.
Finder _rich(String text) => find.text(text, findRichText: true);

/// 입력칸(TextField·TextFormField 모두)에 들어 있는 글자.
String _fieldText(WidgetTester tester, String key) => tester
    .widget<EditableText>(
      find.descendant(of: _key(key), matching: find.byType(EditableText)),
    )
    .controller
    .text;

/// ⋯ → "할 일로 등록"을 눌러 생성 창을 연다.
Future<void> _openEditorFrom(WidgetTester tester, String id) async {
  await tester.tap(_more(id));
  await tester.pumpAndSettle();
  await tester.tap(_menuItem(id));
  await tester.pumpAndSettle();
}

/// 생성 창을 저장 없이 닫는다(내용이 바뀌었다고 확인을 물으면 닫기).
Future<void> _closeEditor(WidgetTester tester) async {
  await tester.tap(_key('todo-editor-close'));
  await tester.pumpAndSettle();
  final confirm = find.widgetWithText(TextButton, '닫기');
  if (confirm.evaluate().isNotEmpty) {
    await tester.tap(confirm.last);
    await tester.pumpAndSettle();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('⋯가 보이는 곳 — 할 일을 만들 수 있는 방의 멘션 알림만', () {
    testWidgets('멘션 탭 — 챗 뷰 토픽의 멘션·@all 알림(다른 팀 방 포함) 줄마다 ⋯가 늘 보인다', (
      tester,
    ) async {
      final server = _Server()
        ..items.addAll([
          _n('m1', minutesAgo: 1),
          _n('a1', kind: 'mention_all', minutesAgo: 2, preview: '@all 회의'),
          _n(
            'x1',
            minutesAgo: 3,
            roomId: 'r2',
            roomName: '개발 토픽',
            teamId: 't2',
            preview: '배포 확인',
          ),
        ]);
      final session = _session(server);
      await _pump(tester, session, FakeTodoApi(me: 'me'));
      // 안 읽은 멘션이 있어서 멘션 탭으로 열렸다.
      expect(
        tester.widget<TabBar>(find.byType(TabBar)).controller!.index,
        NotificationTab.mention.index,
      );
      for (final id in ['m1', 'a1', 'x1']) {
        expect(
          find.descendant(of: _row(id), matching: _more(id)),
          findsOneWidget,
          reason: id,
        );
        // 마우스를 올리지 않아도 보이는 아이콘이다.
        expect(
          find.descendant(
            of: _more(id),
            matching: find.byIcon(Icons.more_horiz),
          ),
          findsOneWidget,
        );
      }
      expect(tester.widget<PopupMenuButton<void>>(_more('m1')).tooltip, '더보기');
    });

    testWidgets('전체 탭 — 멘션·@all 줄에만 ⋯가 있고 보드 알림 줄(새 글·수정·댓글)에는 없다', (
      tester,
    ) async {
      final server = _Server()
        ..items.addAll([
          _n('m1', minutesAgo: 1),
          _n('a1', kind: 'mention_all', minutesAgo: 2),
          // 보드 알림이 챗 뷰 토픽(r1)에서 왔다고 쳐도 멘션이 아니면 ⋯는 없다.
          _n('b1', kind: 'board_post', minutesAgo: 3, preview: '9월 보고'),
          _n('b2', kind: 'board_edit', minutesAgo: 4, preview: '8월 보고'),
          _n('b3', kind: 'board_comment', minutesAgo: 5, preview: '확인'),
        ]);
      final session = _session(server);
      await _pump(
        tester,
        session,
        FakeTodoApi(me: 'me'),
        initialTab: NotificationTab.all,
      );
      expect(_more('m1'), findsOneWidget);
      expect(_more('a1'), findsOneWidget);
      for (final id in ['b1', 'b2', 'b3']) {
        expect(_row(id), findsOneWidget, reason: id);
        expect(_more(id), findsNothing, reason: id);
      }
      expect(find.byIcon(Icons.more_horiz), findsNWidgets(2));
    });

    testWidgets('보드 뷰 토픽·비밀 대화·쓰기가 막힌 토픽·내 목록에 없는 방의 멘션에는 ⋯가 없다(멘션·전체 탭)', (
      tester,
    ) async {
      final server = _Server()
        ..items.addAll([
          _n('ok', minutesAgo: 1),
          _n('bd', minutesAgo: 2, roomId: 'board', roomName: '주간 보고'),
          _n('sc', minutesAgo: 3, roomId: 'sec', roomName: '비밀 대화'),
          _n('rd', minutesAgo: 4, roomId: 'ro', roomName: '공지 토픽'),
          _n('gn', minutesAgo: 5, roomId: 'gone', roomName: '나간 토픽'),
        ]);
      final session = _session(server);
      await _pump(tester, session, FakeTodoApi(me: 'me'));
      void expectOnlyOk() {
        expect(_more('ok'), findsOneWidget);
        for (final id in ['bd', 'sc', 'rd', 'gn']) {
          expect(_row(id), findsOneWidget, reason: id);
          expect(_more(id), findsNothing, reason: id);
        }
      }

      expectOnlyOk();
      await tester.tap(_tab(NotificationTab.all));
      await _settle(tester);
      expectOnlyOk();
    });

    testWidgets('읽기 전용 토픽이라도 토픽 관리자에게는 ⋯가 보인다(관리자는 글을 쓸 수 있다)', (tester) async {
      final server = _Server()
        ..items.add(_n('rd', roomId: 'ro', roomName: '공지 토픽'));
      final session = _session(
        server,
        rooms: [
          _room('ro', name: '공지 토픽', readOnly: true, adminIds: const ['me']),
        ],
      );
      await _pump(tester, session, FakeTodoApi(me: 'me'));
      expect(_more('rd'), findsOneWidget);
    });

    test('canRegisterNotificationAsTodo — 멘션 종류와 방 조건', () {
      final session = _session(_Server());
      AppNotification n(NotificationKind kind, {String? roomId = 'r1'}) =>
          AppNotification(
            id: 'n',
            kind: kind,
            teamId: 't1',
            roomId: roomId,
            messageId: 'msg',
            preview: '내용',
            createdAt: _now,
          );
      bool can(AppNotification x) => canRegisterNotificationAsTodo(session, x);

      expect(can(n(NotificationKind.mention)), isTrue);
      expect(can(n(NotificationKind.mentionAll)), isTrue);
      // 다른 팀의 방이어도 내 목록에 있으면 된다.
      expect(can(n(NotificationKind.mention, roomId: 'r2')), isTrue);
      for (final kind in [
        NotificationKind.boardPost,
        NotificationKind.boardEdit,
        NotificationKind.boardComment,
        NotificationKind.other,
      ]) {
        expect(can(n(kind)), isFalse, reason: kind.name);
      }
      for (final roomId in ['board', 'sec', 'ro', 'gone', null]) {
        expect(
          can(n(NotificationKind.mention, roomId: roomId)),
          isFalse,
          reason: '$roomId',
        );
      }
    });
  });

  group('⋯ 메뉴', () {
    testWidgets('⋯를 누르면 간결한 메뉴에 "할 일로 등록" 하나 — 줄 자체의 탭(방 열기·읽음)은 불리지 않는다', (
      tester,
    ) async {
      final server = _Server()
        ..items.addAll([_n('m1', minutesAgo: 1), _n('m2', minutesAgo: 2)]);
      final session = _session(server);
      final opened = _Opened();
      await _pump(tester, session, FakeTodoApi(me: 'me'), opened: opened);
      expect(session.notificationCenter.counts.mention, 2);

      await tester.tap(_more('m1'));
      await tester.pumpAndSettle();
      expect(_menuItem('m1'), findsOneWidget);
      expect(
        find.descendant(of: _menuItem('m1'), matching: find.text('할 일로 등록')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _menuItem('m1'),
          matching: find.byIcon(Icons.checklist_rounded),
        ),
        findsOneWidget,
      );
      // 메뉴는 항목 하나뿐이고, 설정 메뉴와 같은 간결한 모양이다.
      expect(find.byType(PopupMenuItem<void>), findsOneWidget);
      expect(
        tester.widget<PopupMenuItem<void>>(_menuItem('m1')).height,
        CompactMenu.itemHeight,
      );
      // 메뉴는 ⋯ 바로 아래에서 열린다.
      final moreRect = tester.getRect(
        find.descendant(
          of: _more('m1'),
          matching: find.byIcon(Icons.more_horiz),
        ),
      );
      final itemRect = tester.getRect(_menuItem('m1'));
      expect(itemRect.top, greaterThan(moreRect.bottom - 1));
      expect(itemRect.top, lessThan(moreRect.bottom + 40));
      expect(opened.room, isNull);

      // 바깥을 눌러 그냥 닫는다.
      await tester.tapAt(const Offset(20, 780));
      await tester.pumpAndSettle();
      await _settle(tester);
      expect(_menuItem('m1'), findsNothing);
      expect(find.byType(TodoEditor), findsNothing);
      expect(opened.room, isNull);
      expect(server.called('POST', '/api/notifications/read'), isEmpty);
      expect(session.notificationCenter.counts.mention, 2);
    });

    testWidgets('⋯가 있는 줄도 본문을 누르면 예전처럼 그 메시지로 이동하며 읽음 처리', (tester) async {
      final server = _Server()
        ..items.add(_n('m1', messageId: 'msg-77', preview: '@나 자료 확인'));
      final session = _session(server);
      final opened = _Opened();
      await _pump(tester, session, FakeTodoApi(me: 'me'), opened: opened);
      expect(_more('m1'), findsOneWidget);
      await tester.tap(_rich('김철수: @나 자료 확인'));
      await _settle(tester);
      expect(opened.room!.id, 'r1');
      expect(opened.messageId, 'msg-77');
      expect(
        jsonDecode(
          server.called('POST', '/api/notifications/read').single.body,
        ),
        {
          'ids': ['m1'],
        },
      );
      expect(find.byType(TodoEditor), findsNothing);
    });
  });

  group('할 일로 등록 → 대화방 고정 생성 창', () {
    testWidgets(
      '원본 메시지를 받아 채팅의 "할 일로 등록"과 같게 채운다 — 제목은 첫 줄, 설명은 줄바꿈을 살린 본문 전체, 첨부까지(미리보기는 안 씀)',
      (tester) async {
        final text = [
          '@나 견적 요청 정리',
          '1) 고객사 A 견적서 — 단가표 최신본으로 다시 계산하고 할인율은 팀장님 승인 받은 값으로 넣어 주세요.',
          '2) 제안서 — 3장 일정표를 이번 분기 기준으로 고치고 담당자 연락처를 추가해 주세요.',
        ].join('\n');
        // 알림에 남은 것은 서버가 한 줄로 줄이고 120자에서 자른 미리보기다.
        final preview = _previewOf(text);
        expect(preview.runes.length, notificationPreviewMaxLength);
        expect(preview.contains('\n'), isFalse);
        final server = _Server()
          ..items.add(_n('m1', messageId: 'msg-1', preview: preview))
          ..messages['msg-1'] = _messageDto(
            'msg-1',
            text: text,
            files: const [('견적서.pdf', 'file'), ('제안서.pdf', 'file')],
          );
        final session = _session(server);
        final api = FakeTodoApi(me: 'me');
        final opened = _Opened();
        await _pump(tester, session, api, opened: opened);
        await _openEditorFrom(tester, 'm1');
        expect(server.called('GET', '/api/messages/msg-1'), hasLength(1));

        // 넓은 창(PC)은 대화상자로 열린다.
        final editor = tester.widget<TodoEditor>(find.byType(TodoEditor));
        expect(editor.asDialog, isTrue);
        expect(editor.room?.id, 'r1');
        expect(editor.lockRoom, isTrue);
        expect(editor.editing, isNull);
        expect(editor.initialTitle, '@나 견적 요청 정리');
        expect(editor.initialDescription, text);
        expect(
          [for (final a in editor.initialAttachments) a.fileName],
          ['견적서.pdf', '제안서.pdf'],
        );
        expect(editor.sourceMessageId, 'msg-1');
        expect(editor.sourceCommentId, isNull);
        expect(identical(editor.api, api), isTrue);

        // 대화방은 그 알림의 방으로 고정돼 있다.
        expect(_key('todo-room-locked'), findsOneWidget);
        expect(
          find.descendant(
            of: _key('todo-room-locked'),
            matching: find.text('영업 토픽'),
          ),
          findsOneWidget,
        );
        expect(_key('todo-room-field'), findsNothing);
        expect(_fieldText(tester, 'todo-title-field'), '@나 견적 요청 정리');
        expect(_fieldText(tester, 'todo-description-field'), text);
        expect(find.text('견적서.pdf'), findsOneWidget);
        expect(find.text('제안서.pdf'), findsOneWidget);
        // ⋯로 연 것이라 방을 열거나 읽음 처리하지 않았다.
        expect(opened.room, isNull);
        expect(server.called('POST', '/api/notifications/read'), isEmpty);

        await tester.tap(_key('todo-submit'));
        await tester.pumpAndSettle();
        expect(api.lastCreateRoomId, 'r1');
        expect(api.lastCreate!['title'], '@나 견적 요청 정리');
        expect(api.lastCreate!['description'], text);
        // 서명된 첨부 링크를 그대로 보낸다(서버가 원본 경로로 되돌려 저장한다).
        expect(
          [for (final a in api.lastCreateAttachments) a.url],
          ['/files/tok-msg-1-0', '/files/tok-msg-1-1'],
        );
        expect(api.lastCreate!['sourceMessageId'], 'msg-1');
        expect(api.lastCreate!['sourceCommentId'], isNull);
        expect(find.byType(TodoEditor), findsNothing);
        expect(find.text('할 일로 등록했습니다.'), findsOneWidget);
        // 저장한 뒤에도 알림은 그대로(읽음 처리하지 않는다), 알림 센터도 그대로 떠 있다.
        expect(server.called('POST', '/api/notifications/read'), isEmpty);
        expect(opened.room, isNull);
        expect(find.byType(NotificationsPanel), findsOneWidget);
        await tester.pump(const Duration(seconds: 3));
      },
    );

    testWidgets(
      '댓글에서 온 멘션은 그 댓글을 받아 채우고(파일 댓글이면 그 파일도) sourceCommentId로 보낸다(원본 메시지 id는 보내지 않는다)',
      (tester) async {
        const text = '@나 댓글에서 부탁드립니다\n회의록 파일 확인하고 의견 남겨 주세요';
        final server = _Server()
          ..items.add(
            _n(
              'c1',
              messageId: 'msg-9',
              commentId: 'cmt-9',
              preview: _previewOf(text),
            ),
          )
          ..comments['cmt-9'] = _commentDto(
            'cmt-9',
            messageId: 'msg-9',
            text: text,
            fileName: '회의록.docx',
          );
        final session = _session(server);
        final api = FakeTodoApi(me: 'me');
        await _pump(tester, session, api);
        await _openEditorFrom(tester, 'c1');
        expect(server.called('GET', '/api/comments/cmt-9'), hasLength(1));
        expect(
          server.requests.where((r) => r.url.path.startsWith('/api/messages/')),
          isEmpty,
          reason: '댓글 멘션은 댓글만 받는다',
        );
        final editor = tester.widget<TodoEditor>(find.byType(TodoEditor));
        expect(editor.sourceCommentId, 'cmt-9');
        expect(editor.sourceMessageId, isNull);
        expect(editor.lockRoom, isTrue);
        expect(_fieldText(tester, 'todo-title-field'), '@나 댓글에서 부탁드립니다');
        expect(_fieldText(tester, 'todo-description-field'), text);
        expect(find.text('회의록.docx'), findsOneWidget);
        await tester.tap(_key('todo-submit'));
        await tester.pumpAndSettle();
        expect(api.lastCreate!['sourceCommentId'], 'cmt-9');
        expect(api.lastCreate!['sourceMessageId'], isNull);
        expect(api.lastCreate!['title'], '@나 댓글에서 부탁드립니다');
        expect(api.lastCreate!['description'], text);
        expect(api.lastCreateAttachments.single.url, '/files/tok-cmt-9');
        expect(api.lastCreateAttachments.single.fileName, '회의록.docx');
        expect(find.text('할 일로 등록했습니다.'), findsOneWidget);
        await tester.pump(const Duration(seconds: 3));
      },
    );

    testWidgets('전체 탭의 @all 멘션도 같은 흐름 — 다른 팀의 방이면 그 방으로 고정된다', (tester) async {
      final server = _Server()
        ..items.addAll([
          _n(
            'a1',
            kind: 'mention_all',
            roomId: 'r2',
            roomName: '개발 토픽',
            teamId: 't2',
            messageId: 'msg-all',
            preview: '@all 금요일 배포',
          ),
          _n('b1', kind: 'board_post', minutesAgo: 1, preview: '9월 보고'),
        ])
        ..messages['msg-all'] = _messageDto(
          'msg-all',
          roomId: 'r2',
          text: '@all 금요일 배포\n점검 시간은 오후 6시부터입니다.',
        );
      final session = _session(server);
      final api = FakeTodoApi(me: 'me');
      await _pump(tester, session, api, initialTab: NotificationTab.all);
      await _openEditorFrom(tester, 'a1');
      expect(
        find.descendant(
          of: _key('todo-room-locked'),
          matching: find.text('개발 토픽'),
        ),
        findsOneWidget,
      );
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(api.lastCreateRoomId, 'r2');
      expect(api.lastCreate!['sourceMessageId'], 'msg-all');
      expect(api.lastCreate!['title'], '@all 금요일 배포');
      expect(api.lastCreate!['description'], '@all 금요일 배포\n점검 시간은 오후 6시부터입니다.');
      expect(find.text('할 일로 등록했습니다.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets(
      '원본을 못 받으면(지워졌거나 방을 나감 — 404) 미리보기로 채운다 — 제목은 100자까지, 잘린 120자 미리보기면 설명 끝에 …',
      (tester) async {
        final preview = List.filled(12, '가나다라마바사아자차').join();
        expect(preview.runes.length, notificationPreviewMaxLength);
        final server = _Server()
          ..items.add(_n('m1', messageId: 'msg-gone', preview: preview));
        final session = _session(server);
        final api = FakeTodoApi(me: 'me');
        await _pump(tester, session, api);
        await _openEditorFrom(tester, 'm1');
        expect(server.called('GET', '/api/messages/msg-gone'), hasLength(1));
        final editor = tester.widget<TodoEditor>(find.byType(TodoEditor));
        expect(editor.lockRoom, isTrue);
        expect(editor.room?.id, 'r1');
        expect(editor.initialAttachments, isEmpty);
        expect(editor.sourceMessageId, 'msg-gone');
        expect(
          _fieldText(tester, 'todo-title-field'),
          preview.substring(0, todoTitleMaxLength),
        );
        expect(_fieldText(tester, 'todo-description-field'), '$preview…');
        await tester.tap(_key('todo-submit'));
        await tester.pumpAndSettle();
        expect(api.lastCreate!['title'], preview.substring(0, 100));
        expect(api.lastCreate!['description'], '$preview…');
        expect(api.lastCreate!['sourceMessageId'], 'msg-gone');
        await tester.pump(const Duration(seconds: 3));
      },
    );

    testWidgets(
      '옛 서버(단건 조회가 없어 HTML 404)·연결 실패여도 미리보기로 연다 — 짧은 미리보기는 그대로, 댓글은 댓글 id로',
      (tester) async {
        const preview = '@나 내일까지 견적서 보내 주세요';
        final server = _Server()
          ..legacy = true
          ..items.addAll([
            _n('m1', messageId: 'msg-1', preview: preview),
            _n(
              'c1',
              minutesAgo: 1,
              messageId: 'msg-2',
              commentId: 'cmt-2',
              preview: '댓글로 부탁드려요',
            ),
          ])
          // 받을 수만 있었다면 이것으로 채웠을 원본.
          ..messages['msg-1'] = _messageDto('msg-1', text: '쓰이지 않는 원본');
        final session = _session(server);
        final api = FakeTodoApi(me: 'me');
        await _pump(tester, session, api);
        await _openEditorFrom(tester, 'm1');
        expect(server.called('GET', '/api/messages/msg-1'), hasLength(1));
        expect(_fieldText(tester, 'todo-title-field'), preview);
        expect(_fieldText(tester, 'todo-description-field'), preview);
        expect(
          tester.widget<TodoEditor>(find.byType(TodoEditor)).sourceMessageId,
          'msg-1',
        );
        await _closeEditor(tester);

        server
          ..legacy = false
          ..unreachable = true;
        await _openEditorFrom(tester, 'c1');
        expect(server.called('GET', '/api/comments/cmt-2'), hasLength(1));
        final editor = tester.widget<TodoEditor>(find.byType(TodoEditor));
        expect(editor.sourceCommentId, 'cmt-2');
        expect(editor.sourceMessageId, isNull);
        expect(_fieldText(tester, 'todo-description-field'), '댓글로 부탁드려요');
        await tester.tap(_key('todo-submit'));
        await tester.pumpAndSettle();
        expect(api.lastCreate!['sourceCommentId'], 'cmt-2');
        expect(api.lastCreate!['description'], '댓글로 부탁드려요');
        expect(find.text('할 일로 등록했습니다.'), findsOneWidget);
        await tester.pump(const Duration(seconds: 3));
      },
    );

    testWidgets('원본을 받는 동안 ⋯ → 할 일로 등록을 또 눌러도 생성 창은 하나만 — 닫으면 다시 열 수 있다', (
      tester,
    ) async {
      final server = _Server()
        ..items.add(_n('m1', messageId: 'msg-1'))
        ..messages['msg-1'] = _messageDto('msg-1', text: '견적서 확인 부탁드려요')
        ..originalGate = Completer<void>();
      final session = _session(server);
      await _pump(tester, session, FakeTodoApi(me: 'me'));
      await _openEditorFrom(tester, 'm1');
      expect(find.byType(TodoEditor), findsNothing, reason: '아직 원본을 받는 중');
      // 또 누른다.
      await _openEditorFrom(tester, 'm1');
      expect(find.byType(TodoEditor), findsNothing);
      expect(server.called('GET', '/api/messages/msg-1'), hasLength(1));

      server.originalGate!.complete();
      await _settle(tester);
      expect(find.byType(TodoEditor), findsOneWidget);
      expect(_fieldText(tester, 'todo-title-field'), '견적서 확인 부탁드려요');
      expect(server.called('GET', '/api/messages/msg-1'), hasLength(1));

      await _closeEditor(tester);
      expect(find.byType(TodoEditor), findsNothing);
      await _openEditorFrom(tester, 'm1');
      expect(find.byType(TodoEditor), findsOneWidget, reason: '닫은 뒤에는 다시 열린다');
      expect(server.called('GET', '/api/messages/msg-1'), hasLength(2));
    });

    testWidgets('창을 그냥 닫으면 아무것도 만들지 않고 알리지도 않는다', (tester) async {
      final server = _Server()..items.add(_n('m1'));
      final session = _session(server);
      final api = FakeTodoApi(me: 'me');
      final opened = _Opened();
      await _pump(tester, session, api, opened: opened);
      await _openEditorFrom(tester, 'm1');
      expect(find.byType(TodoEditor), findsOneWidget);
      await _closeEditor(tester);
      expect(find.byType(TodoEditor), findsNothing);
      expect(api.callCount('create'), 0);
      expect(find.text('할 일로 등록했습니다.'), findsNothing);
      expect(opened.room, isNull);
      expect(server.called('POST', '/api/notifications/read'), isEmpty);
    });

    testWidgets('저장이 거절되면 창이 남고 등록 알림은 뜨지 않는다', (tester) async {
      final server = _Server()..items.add(_n('m1'));
      final session = _session(server);
      final api = FakeTodoApi(me: 'me')..failWith = '이 대화방에서는 할 일을 만들 수 없습니다.';
      await _pump(tester, session, api);
      await _openEditorFrom(tester, 'm1');
      await tester.tap(_key('todo-submit'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoEditor), findsOneWidget);
      expect(find.text('할 일로 등록했습니다.'), findsNothing);
      await _closeEditor(tester);
      expect(find.byType(TodoEditor), findsNothing);
      expect(find.text('할 일로 등록했습니다.'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('그새 그 방을 나갔으면 원본을 받지도, 생성 창을 열지도 않고 알린다', (tester) async {
      final server = _Server();
      final session = _session(server, rooms: [_room('r1')]);
      final api = FakeTodoApi(me: 'me');
      _size(tester, const Size(1000, 800));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  key: const ValueKey('opener'),
                  onPressed: () => registerNotificationAsTodo(
                    context,
                    session: session,
                    notification: AppNotification.fromJson(
                      _n('gn', roomId: 'gone', roomName: '나간 토픽'),
                    ),
                    api: api,
                  ),
                  child: const Text('열기'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(_key('opener'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoEditor), findsNothing);
      expect(find.text('더 이상 볼 수 없는 대화입니다.'), findsOneWidget);
      expect(api.calls, isEmpty);
      expect(server.requests, isEmpty);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('배치 — PC 패널(420)·모바일(390)', () {
    /// [id] 줄의 ⋯ 아이콘이 첫 줄(방 이름·시각)과 한 줄로 서고 시각과 겹치지 않으며 줄 안에 있는지.
    void expectMoreBesideTime(WidgetTester tester, String id, DateTime time) {
      final row = tester.getRect(_row(id));
      final icon = tester.getRect(
        find.descendant(of: _more(id), matching: find.byIcon(Icons.more_horiz)),
      );
      final timeText = tester.getRect(
        find.descendant(
          of: _row(id),
          matching: find.text(formatRoomActivityTime(time)),
        ),
      );
      final summary = tester.getRect(
        find.descendant(
          of: _row(id),
          matching: find.byKey(const ValueKey('notif-server-summary')),
        ),
      );
      expect(icon.left, greaterThanOrEqualTo(timeText.right + 4), reason: id);
      expect((icon.center.dy - timeText.center.dy).abs(), lessThan(3));
      expect(icon.right, lessThanOrEqualTo(row.right), reason: id);
      expect(icon.top, greaterThanOrEqualTo(row.top), reason: id);
      // ⋯ 아래의 미리보기는 ⋯와 겹치지 않는다(두 번째 줄부터).
      expect(summary.top, greaterThanOrEqualTo(icon.bottom - 4), reason: id);
    }

    for (final width in [420.0, 390.0]) {
      testWidgets('폭 ${width.toInt()} — 긴 미리보기·긴 방 이름에도 넘치지 않고 ⋯가 시각 옆 첫 줄에 선다', (
        tester,
      ) async {
        final long =
            '@나 다음 주 월요일 고객사 미팅 전까지 견적서와 제안서 최종본을 정리해서 공유 드라이브에 올려 주시고, 일정 확인 부탁드립니다.';
        final server = _Server()
          ..items.addAll([
            _n('m1', minutesAgo: 1, preview: long),
            _n(
              'm2',
              minutesAgo: 2,
              read: true,
              roomName: '아주 긴 이름의 영업 전략 회의 토픽(2026 하반기)',
              preview: '짧은 글',
            ),
            _n('a1', kind: 'mention_all', minutesAgo: 3, preview: '@all 회의'),
          ]);
        final session = _session(server);
        final mobile = width < 400;
        // PC 패널은 Windows 테마(조밀한 밀도)로, 모바일은 기본(안드로이드)으로.
        await _pump(
          tester,
          session,
          FakeTodoApi(me: 'me'),
          view: mobile ? Size(width, 844) : const Size(1000, 800),
          width: width,
          platform: mobile ? null : TargetPlatform.windows,
        );
        expect(tester.takeException(), isNull);
        for (final (id, minutes) in [('m1', 1), ('m2', 2), ('a1', 3)]) {
          final time = DateTime.fromMillisecondsSinceEpoch(
            _n(id, minutesAgo: minutes)['createdAt'] as int,
          );
          expectMoreBesideTime(tester, id, time);
        }
        // 긴 미리보기는 두 줄에서 말줄임 — 줄 높이가 지나치게 커지지 않는다.
        expect(tester.getSize(_row('m1')).height, lessThan(100));
        // ⋯를 눌러 고를 수 있다(누를 자리는 PC·모바일 모두 손가락 크기).
        expect(tester.getSize(_more('m1')).width, greaterThanOrEqualTo(40));
        expect(tester.getSize(_more('m1')).height, greaterThanOrEqualTo(40));
        await tester.tap(_more('m1'));
        await tester.pumpAndSettle();
        final item = tester.getRect(_menuItem('m1'));
        expect(item.right, lessThanOrEqualTo(mobile ? width : 1000));
        expect(item.left, greaterThanOrEqualTo(0));
      });
    }

    testWidgets(
      '모바일 — 알림 센터(전체 화면)에서 등록하면 전체 화면 생성 창이 열리고, 저장하면 서버에 원본 메시지(본문·첨부)로 만들고 돌아온다',
      (tester) async {
        const text = '@나 회의록 정리해 주세요\n- 안건 세 가지와 결정 사항';
        final server = _Server()
          ..items.add(_n('m1', messageId: 'msg-5', preview: _previewOf(text)))
          ..messages['msg-5'] = _messageDto(
            'msg-5',
            text: text,
            files: const [('회의록.docx', 'file')],
          );
        final session = _session(server);
        _size(tester, const Size(390, 844));
        await tester.runAsync(session.notificationCenter.refreshCounts);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () =>
                        showNotificationsCenterDialog(context, session),
                    child: const Text('알림'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('알림'));
        await tester.pumpAndSettle();
        await _settle(tester);
        expect(find.byType(Dialog), findsNothing); // 전체 화면 알림 센터.
        await _openEditorFrom(tester, 'm1');
        final editor = tester.widget<TodoEditor>(find.byType(TodoEditor));
        expect(editor.asDialog, isFalse); // 좁은 화면은 전체 화면 생성 창.
        expect(editor.lockRoom, isTrue);
        expect(_fieldText(tester, 'todo-title-field'), '@나 회의록 정리해 주세요');
        expect(_fieldText(tester, 'todo-description-field'), text);
        expect(find.text('회의록.docx'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(_key('todo-submit'));
        await _settle(tester);
        // 진짜 할 일 API(session.todoApi)로 POST /api/rooms/r1/todos — 원본에서 받은 서명된 첨부 링크를 그대로 보낸다.
        expect(server.createdTodos, hasLength(1));
        final created = server.createdTodos.single;
        expect(created.roomId, 'r1');
        expect(created.body['title'], '@나 회의록 정리해 주세요');
        expect(created.body['description'], text);
        expect(created.body['attachments'], [
          {
            'kind': 'file',
            'fileUrl': '/files/tok-msg-5-0',
            'fileName': '회의록.docx',
            'fileSize': 1024,
            'mimeType': 'application/octet-stream',
          },
        ]);
        expect(created.body['sourceMessageId'], 'msg-5');
        expect(created.body.containsKey('sourceCommentId'), isFalse);
        // 생성 창이 닫히고 알림 센터로 돌아와 알린다. 알림은 읽음 처리하지 않았다.
        expect(find.byType(TodoEditor), findsNothing);
        expect(find.byType(NotificationsPanel), findsOneWidget);
        expect(find.text('할 일로 등록했습니다.'), findsOneWidget);
        expect(server.called('POST', '/api/notifications/read'), isEmpty);
        await tester.pump(const Duration(seconds: 3));
      },
    );
  });
}
