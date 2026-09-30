import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/post_editor_dialog.dart';
import 'package:client/screens/schedule_message_dialog.dart';
import 'package:client/screens/scheduled_messages_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/room_chat_controller.dart'
    show UploadedAttachment;
import 'package:client/services/session.dart';
import 'package:client/services/time_format.dart';
import 'package:client/widgets/app_menu_button.dart';
import 'package:client/widgets/chat_input_bar.dart';
import 'package:client/widgets/chat_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 메시지 예약 발송 화면(UI-3) — [메뉴]의 목록, 예약 편집기(검사·요청 모양), 입력칸의 시계 단추와
/// "예약된 메시지 N개" 줄, 보드·게시글 편집기의 예약, 발송 결과 토스트, 나와의 대화의 화상회의 숨김.

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

/// 경로 규칙(`:id`는 한 칸)별 응답을 정해 두고, 들어온 요청을 전부 기록하는 가짜 서버. 나중에 등록한
/// 규칙이 먼저 쓰인다.
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

/// 발송 시각 기본값 — 테스트가 도는 시각과 상관없이 늘 앞으로 올 15분 단위.
final _later = defaultScheduleTime().add(const Duration(hours: 2));

Map<String, dynamic> _row(
  String id, {
  String? roomId = 'r1',
  String? roomName = '공지방',
  String? title,
  String text = '예약한 메시지',
  DateTime? sendAt,
  String status = 'scheduled',
  String? failReason,
  List<Map<String, dynamic>> attachments = const [],
}) => {
  'id': id,
  'teamId': 't1',
  'roomId': roomId,
  'roomName': roomName,
  'title': title,
  'text': text,
  'textFormat': null,
  'attachments': attachments,
  'sendAt': (sendAt ?? _later).millisecondsSinceEpoch,
  'status': status,
  'failReason': failReason,
  'createdAt': 1000,
  'updatedAt': 2000,
};

Map<String, dynamic> _fileJson(String name) => {
  'id': 'a-$name',
  'kind': 'file',
  'fileUrl': '/files/$name?sig=x',
  'fileName': name,
  'fileSize': 2048,
  'mimeType': 'application/octet-stream',
};

/// 서버의 예약 목록을 흉내 낸다 — 만들기·고치기·취소·지금 보내기가 실제로 목록을 바꿔서, 다시 받아도
/// 맞는 목록이 온다.
class _Store {
  final rows = <Map<String, dynamic>>[];
  var _seq = 0;

  /// 지금 보내기가 실패할 사유(null이면 성공).
  String? sendNowError;

  void install(_Server server) {
    server.on('GET', '/api/scheduled-messages', (_) {
      final sorted = [...rows]
        ..sort((a, b) {
          final af = a['status'] == 'failed', bf = b['status'] == 'failed';
          if (af != bf) return af ? -1 : 1;
          return (a['sendAt'] as int).compareTo(b['sendAt'] as int);
        });
      return _json(sorted);
    });
    server.on('POST', '/api/scheduled-messages', (r) {
      final b = _body(r);
      final row = _row(
        'new${++_seq}',
        roomId: b['roomId'] as String,
        roomName: null,
        title: b['title'] as String?,
        text: b['text'] as String,
        sendAt: DateTime.fromMillisecondsSinceEpoch(b['sendAt'] as int),
        attachments: [
          for (final a in (b['attachments'] as List? ?? const []))
            Map<String, dynamic>.from(a as Map),
        ],
      );
      rows.add(row);
      return _json(row, 201);
    });
    server.on('PATCH', '/api/scheduled-messages/:id', (r) {
      final row = rows.firstWhere((x) => x['id'] == r.url.pathSegments.last);
      final b = _body(r);
      for (final key in ['roomId', 'text', 'textFormat', 'sendAt']) {
        if (b.containsKey(key)) row[key] = b[key];
      }
      if (b.containsKey('title')) {
        final title = b['title'] as String?;
        row['title'] = title == null || title.isEmpty ? null : title;
      }
      if (b.containsKey('attachments')) row['attachments'] = b['attachments'];
      row['status'] = 'scheduled';
      row['failReason'] = null;
      return _json(row);
    });
    server.on('DELETE', '/api/scheduled-messages/:id', (r) {
      rows.removeWhere((x) => x['id'] == r.url.pathSegments.last);
      return _json({'ok': true});
    });
    server.on('POST', '/api/scheduled-messages/:id/send-now', (r) {
      final segs = r.url.pathSegments;
      final id = segs[segs.length - 2];
      final error = sendNowError;
      if (error != null) {
        final row = rows.firstWhere((x) => x['id'] == id);
        row['status'] = 'failed';
        row['failReason'] = error;
        return _json({'error': error}, 400);
      }
      rows.removeWhere((x) => x['id'] == id);
      return _json({
        'ok': true,
        'messageIds': ['m-$id'],
      });
    });
  }
}

Map<String, dynamic> _user(String id, String name, {String role = 'member'}) =>
    {'id': id, 'username': id, 'name': name, 'role': role};

final _members = [_user('me', '나'), _user('u2', '김철수'), _user('u3', '이영희')];

Room _topic(
  String id,
  String name, {
  bool board = false,
  bool readOnly = false,
  bool archived = false,
  List<String> admins = const [],
  String teamId = 't1',
}) => Room.fromJson({
  'id': id,
  'teamId': teamId,
  'type': 'topic',
  'name': name,
  'members': _members,
  'createdAt': 1000,
  'viewMode': board ? 'board' : 'chat',
  'readOnly': readOnly,
  'archivedAt': archived ? 5000 : null,
  'adminIds': admins,
});

Room _dm(
  String id,
  Map<String, dynamic> other, {
  bool secret = false,
  int activity = 1000,
}) => Room.fromJson({
  'id': id,
  'teamId': 't1',
  'type': 'dm',
  'name': null,
  'members': [_user('me', '나'), other],
  'createdAt': 1000,
  'lastActivityAt': activity,
  'isSecret': secret,
});

final _selfRoom = Room.fromJson({
  'id': 'r-self',
  'teamId': 't1',
  'type': 'dm',
  'name': null,
  'members': [_user('me', '나')],
  'createdAt': 1000,
  'lastActivityAt': 10,
  'isSelf': true,
});

/// 예약할 수 있는 방(공지방·주간 보고(보드)·운영진 공지(읽기 전용이지만 내가 토픽 관리자)·디자인 그룹·
/// 김철수·나와의 대화)과 없는 방(읽기전용방·지난 행사(보관)·다른팀 방·박비밀(비밀 대화)).
List<Room> _rooms() => [
  _topic('r1', '공지방'),
  _topic('r-board', '주간 보고', board: true),
  _topic('r-ro', '읽기전용방', readOnly: true),
  _topic('r-ro-admin', '운영진 공지', readOnly: true, admins: ['me']),
  _topic('r-arch', '지난 행사', archived: true),
  _topic('r-other', '다른팀 방', teamId: 't2'),
  Room.fromJson({
    'id': 'r-group',
    'teamId': 't1',
    'type': 'group',
    'name': '디자인 그룹',
    'members': _members,
    'createdAt': 1000,
  }),
  _dm('r-dm', _user('u2', '김철수'), activity: 9000),
  _dm('r-secret', _user('u4', '박비밀'), secret: true),
  _selfRoom,
];

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
  session.teams.addAll([
    team,
    Team(id: 't2', name: '다른팀', createdAt: DateTime(2026)),
  ]);
  session.currentTeam = team;
  session.rooms.addAll(rooms ?? _rooms());
  return session;
}

/// 가짜 서버 + 예약 목록 + 세션을 한 번에 — [rows]가 처음 서버에 있는 예약.
({_Server server, _Store store, Session session}) _setup([
  List<Map<String, dynamic>> rows = const [],
]) {
  final server = _Server();
  final store = _Store()..rows.addAll(rows);
  store.install(server);
  server.on('GET', '/api/rooms/:id/messages', (_) => _json(<Object>[]));
  server.on('GET', '/api/rooms/:id/pinned-posts', (_) => _json(<Object>[]));
  return (server: server, store: store, session: _session(server));
}

/// 세션이 예약 목록을 한 번 받아 오게 한다(입력칸 위 줄·편집기의 한도 판단용).
Future<void> _loadScheduled(WidgetTester tester, Session session) async {
  unawaited(session.loadScheduledMessages());
  await tester.pump();
  await tester.pump();
  expect(session.scheduledMessagesLoaded, isTrue);
}

void _wide(WidgetTester tester, [Size size = const Size(1280, 900)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 루트 토스트([ScheduledMessageToasts])까지 붙인 앱에 [body]를 올린다.
Future<void> _pumpApp(
  WidgetTester tester,
  Session session,
  Widget Function(BuildContext context) body, {
  Size size = const Size(1280, 900),
}) async {
  _wide(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      // 한 테스트에서 다시 올려도 앞 화면의 대화상자가 남지 않게 늘 새 앱으로.
      key: UniqueKey(),
      home: ScheduledMessageToasts(
        session: session,
        child: Scaffold(body: Builder(builder: body)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// "열기"를 누르면 [open]을 부르는 빈 화면.
Widget Function(BuildContext) _launcher(
  void Function(BuildContext context) open,
) =>
    (context) => Center(
      child: FilledButton(
        onPressed: () => open(context),
        child: const Text('열기'),
      ),
    );

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
}

/// 떠 있는 알림(토스트)의 타이머가 테스트 끝까지 남지 않게 흘려보낸다.
Future<void> _flushToasts(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(seconds: 5));
  }
  await tester.pumpAndSettle();
}

/// 파일 읽기·업로드처럼 실제 입출력을 기다리는 일을 [done]이 될 때까지 조금씩 진행시킨다.
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

Finder get _submit => find.byKey(const ValueKey('schedule-submit'));
Finder get _messageField => find.byKey(const ValueKey('schedule-message'));

Future<void> _pressCtrlEnter(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// 예약 목록 카드의 ⋯ 메뉴에서 [label]을 누른다.
Future<void> _cardMenu(WidgetTester tester, String id, String label) async {
  await tester.tap(find.byKey(ValueKey('scheduled-more-$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

ChatInputBar _inputBar(Session session, Room room) => ChatInputBar(
  controller: session.controllerFor(room),
  session: session,
  room: room,
  stickerPickerGroupId: Object(),
  onToggleStickerPicker: () {},
  onStickerConsumed: () {},
);

void _expectSlot(int ms) {
  expect(ms % (scheduledSlotMinutes * 60 * 1000), 0, reason: '15분 단위');
  expect(ms, greaterThan(DateTime.now().millisecondsSinceEpoch));
}

void main() {
  group('[메뉴] → 예약 목록', () {
    testWidgets('"메시지 예약"을 누르면 예약 목록이 열리고 서버에서 새로 받는다', (tester) async {
      final t = _setup([_row('s1')]);
      _wide(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                AppMenuButton(
                  session: t.session,
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
      // 파일·링크·메시지 예약·문의함 — 같은 아이콘 칸 모양으로 나란히.
      expect(find.text('파일'), findsOneWidget);
      expect(find.text('문의함'), findsOneWidget);
      await tester.tap(find.text('메시지 예약'));
      await tester.pumpAndSettle();

      expect(find.byType(ScheduledMessagesScreen), findsOneWidget);
      expect(find.byType(Dialog), findsOneWidget); // 넓은 화면은 대화상자
      expect(t.server.called('GET', '/api/scheduled-messages'), hasLength(1));
      expect(
        t.server
            .called('GET', '/api/scheduled-messages')
            .single
            .url
            .queryParameters['teamId'],
        't1',
      );
      expect(find.text('예약 1/30', findRichText: true), findsOneWidget);
      expect(find.text('예약한 메시지', findRichText: true), findsOneWidget);
      expect(find.text('메시지 예약 생성'), findsOneWidget);

      // Esc로 닫힌다.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ScheduledMessagesScreen), findsNothing);
    });

    testWidgets('예약이 없으면 비어 있다는 안내, 30건이면 만들기 단추가 막힌다', (tester) async {
      final empty = _setup();
      await _pumpApp(
        tester,
        empty.session,
        _launcher((c) => showScheduledMessages(c, empty.session)),
      );
      await _open(tester);
      expect(find.text('예약된 메시지가 없습니다.'), findsOneWidget);
      expect(find.text('예약 0/30', findRichText: true), findsOneWidget);

      final full = _setup([for (var i = 0; i < 30; i++) _row('s$i')]);
      await _pumpApp(
        tester,
        full.session,
        _launcher((c) => showScheduledMessages(c, full.session)),
      );
      await _open(tester);
      expect(find.text('예약 30/30', findRichText: true), findsOneWidget);
      final create = tester.widget<ButtonStyleButton>(
        find.byKey(const ValueKey('scheduled-create')),
      );
      expect(create.onPressed, isNull);
    });

    testWidgets('처음 불러오기가 실패하면 다시 시도할 수 있고, 받아 둔 목록이 있으면 그대로 둔 채 알린다', (
      tester,
    ) async {
      final t = _setup([_row('s1', text: '첫 예약')]);
      var fail = true;
      t.server.on(
        'GET',
        '/api/scheduled-messages',
        (_) => fail
            ? _json({'error': '잠시 후 다시 시도하세요.'}, 500)
            : _json([_row('s1', text: '첫 예약')]),
      );
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduledMessages(c, t.session)),
      );
      await _open(tester);
      expect(find.text('예약 목록을 불러오지 못했습니다.'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('다시 시도'));
      await tester.pumpAndSettle();
      expect(find.text('첫 예약', findRichText: true), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // 다시 열 때 새로 받기가 실패해도 받아 둔 목록은 보이고 토스트로만 알린다.
      fail = true;
      await _open(tester);
      expect(find.text('첫 예약', findRichText: true), findsOneWidget);
      expect(find.text('예약 목록을 불러오지 못했습니다.'), findsNothing);
      expect(find.text('예약 목록을 새로 받지 못했습니다: 잠시 후 다시 시도하세요.'), findsOneWidget);
      await _flushToasts(tester);
    });
  });

  group('예약 목록', () {
    List<Map<String, dynamic>> rows() => [
      _row(
        's1',
        text: '회의 자료 공유드립니다',
        attachments: [_fileJson('안건.pdf'), _fileJson('예산.xlsx')],
      ),
      _row(
        's2',
        roomId: 'r-board',
        roomName: '주간 보고',
        title: '9월 넷째 주 보고',
        text: '본문',
        sendAt: _later.add(const Duration(days: 1)),
      ),
      _row(
        'f1',
        roomId: 'r-dm',
        roomName: '김철수',
        text: '보내지 못한 메시지',
        sendAt: DateTime.now().subtract(const Duration(hours: 1)),
        status: 'failed',
        failReason: '대화방의 멤버가 아니어서 보내지 못했습니다.',
      ),
      _row(
        'f2',
        roomId: null,
        roomName: '없어진 방',
        text: '방이 사라진 예약',
        sendAt: DateTime.now().subtract(const Duration(hours: 2)),
        status: 'failed',
        failReason: '대화방이 삭제되어 보내지 못했습니다.',
      ),
    ];

    testWidgets('발송 실패(사유)가 먼저, 예약됨은 시각 순 — 방 이름·시각·첨부 수·게시글 제목', (
      tester,
    ) async {
      final t = _setup(rows());
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduledMessages(c, t.session)),
      );
      await _open(tester);

      expect(
        find.byKey(const ValueKey('scheduled-failed-header')),
        findsOneWidget,
      );
      expect(find.text('대화방의 멤버가 아니어서 보내지 못했습니다.'), findsOneWidget);
      expect(find.text('대화방이 삭제되어 보내지 못했습니다.'), findsOneWidget);
      // 방이 지워진 예약은 예약할 때 저장해 둔 이름으로.
      expect(find.text('없어진 방'), findsOneWidget);
      expect(find.text('김철수'), findsOneWidget);
      expect(find.text('공지방'), findsOneWidget);
      expect(find.text(formatScheduleTime(_later)), findsOneWidget);
      expect(find.text('파일 2개'), findsOneWidget);
      // 게시글 예약은 "게시글" 표시 + 제목으로 미리 본다.
      expect(
        find.textContaining('9월 넷째 주 보고', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('게시글'), findsOneWidget);
      // 실패 사유가 예약됨보다 위, 예약됨은 보낼 시각 순.
      final failedY = tester.getTopLeft(find.text('김철수')).dy;
      final firstY = tester.getTopLeft(find.text('공지방')).dy;
      final secondY = tester.getTopLeft(find.text('주간 보고')).dy;
      expect(failedY, lessThan(firstY));
      expect(firstY, lessThan(secondY));
      expect(find.text('예약 4/30', findRichText: true), findsOneWidget);
    });

    testWidgets('지금 보내기 — 묻고 보내면 목록에서 빠지고 루트 토스트가 알린다', (tester) async {
      final t = _setup(rows());
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduledMessages(c, t.session)),
      );
      await _open(tester);

      await _cardMenu(tester, 's1', '지금 보내기');
      expect(find.text("예약 시간을 기다리지 않고 '공지방'에 지금 바로 보낼까요?"), findsOneWidget);
      await tester.tap(find.text('보내기'));
      await tester.pump();
      await tester.pump();
      expect(
        t.server.called('POST', '/api/scheduled-messages/s1/send-now'),
        hasLength(1),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('회의 자료 공유드립니다'), findsNothing);
      expect(find.text('예약 메시지를 보냈습니다 · 공지방'), findsOneWidget);
      await _flushToasts(tester);
    });

    testWidgets('지금 보내기가 실패하면 사유를 알리고 그 예약은 발송 실패로 남는다', (tester) async {
      final t = _setup(rows());
      t.store.sendNowError = '읽기 전용 토픽입니다. 토픽 관리자만 글을 쓸 수 있습니다.';
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduledMessages(c, t.session)),
      );
      await _open(tester);

      await _cardMenu(tester, 's1', '지금 보내기');
      await tester.tap(find.text('보내기'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('읽기 전용 토픽입니다. 토픽 관리자만 글을 쓸 수 있습니다.'),
        findsNWidgets(2), // 토스트 + 카드의 발송 실패 사유
      );
      expect(find.byKey(const ValueKey('scheduled-reason-s1')), findsOneWidget);
      expect(find.text('예약 메시지를 보냈습니다 · 공지방'), findsNothing);
      await _flushToasts(tester);
    });

    testWidgets('지금 보내기를 누른 사이 예약 시각이 되어 서버가 먼저 보냈으면 오류 대신 보냈다고 알린다', (
      tester,
    ) async {
      final t = _setup(rows());
      // 발송 스케줄러가 먼저 보내고 행을 지운 뒤(scheduled:sent) 지금 보내기 요청이 닿으면 404다.
      t.server.on('POST', '/api/scheduled-messages/:id/send-now', (r) {
        t.store.rows.removeWhere((x) => x['id'] == 's1');
        t.session.handleScheduledMessageEvent(
          const ScheduledMessageEvent(
            type: ScheduledMessageEventType.sent,
            id: 's1',
            teamId: 't1',
            roomId: 'r1',
            roomName: '공지방',
            messageIds: ['m-s1'],
          ),
        );
        return _json({'error': '예약 메시지를 찾을 수 없습니다.'}, 404);
      });
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduledMessages(c, t.session)),
      );
      await _open(tester);

      await _cardMenu(tester, 's1', '지금 보내기');
      await tester.tap(find.text('보내기'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('예약 메시지를 보냈습니다 · 공지방'), findsOneWidget);
      expect(find.text('예약 메시지를 찾을 수 없습니다.'), findsNothing);
      expect(find.text('회의 자료 공유드립니다'), findsNothing);
      await _flushToasts(tester);
      expect(find.text('예약 메시지를 찾을 수 없습니다.'), findsNothing);
    });

    testWidgets('묻는 사이 이미 보내졌거나 다른 기기에서 취소된 예약에는 요청을 보내지 않는다', (tester) async {
      final t = _setup(rows());
      t.server.on(
        'POST',
        '/api/scheduled-messages/:id/send-now',
        (_) => _json({'error': '예약 메시지를 찾을 수 없습니다.'}, 404),
      );
      t.server.on(
        'DELETE',
        '/api/scheduled-messages/:id',
        (_) => _json({'error': '예약 메시지를 찾을 수 없습니다.'}, 404),
      );
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduledMessages(c, t.session)),
      );
      await _open(tester);

      // "지금 보내기"를 묻는 사이 예약 시각이 되어 서버가 보냈다.
      await _cardMenu(tester, 's1', '지금 보내기');
      t.store.rows.removeWhere((x) => x['id'] == 's1');
      t.session.handleScheduledMessageEvent(
        const ScheduledMessageEvent(
          type: ScheduledMessageEventType.sent,
          id: 's1',
          teamId: 't1',
          roomId: 'r1',
          roomName: '공지방',
          messageIds: ['m-s1'],
        ),
      );
      await tester.tap(find.text('보내기'));
      await tester.pumpAndSettle();
      expect(
        t.server.called('POST', '/api/scheduled-messages/s1/send-now'),
        isEmpty,
      );
      expect(find.text('예약 메시지를 찾을 수 없습니다.'), findsNothing);
      await _flushToasts(tester);

      // "예약 취소"를 묻는 사이 다른 기기에서 취소했다(변경 알림으로 목록을 다시 받았다).
      await _cardMenu(tester, 's2', '예약 취소');
      t.store.rows.removeWhere((x) => x['id'] == 's2');
      t.session.handleScheduledChanged('t1');
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, '예약 취소'));
      await tester.pumpAndSettle();
      expect(t.server.called('DELETE', '/api/scheduled-messages/s2'), isEmpty);
      expect(find.text('예약 메시지를 찾을 수 없습니다.'), findsNothing);
      await _flushToasts(tester);
    });

    testWidgets('예약 취소·발송 실패 삭제 — 한 번 묻고 DELETE', (tester) async {
      final t = _setup(rows());
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduledMessages(c, t.session)),
      );
      await _open(tester);

      await _cardMenu(tester, 's2', '예약 취소');
      expect(find.textContaining('보낼 예약을 취소할까요?'), findsOneWidget);
      // 닫기를 누르면 아무 일도 없다.
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      expect(t.server.called('DELETE', '/api/scheduled-messages/s2'), isEmpty);

      await _cardMenu(tester, 's2', '예약 취소');
      await tester.tap(find.widgetWithText(TextButton, '예약 취소'));
      await tester.pumpAndSettle();
      expect(
        t.server.called('DELETE', '/api/scheduled-messages/s2'),
        hasLength(1),
      );
      expect(
        find.textContaining('9월 넷째 주 보고', findRichText: true),
        findsNothing,
      );
      expect(find.text('예약을 취소했습니다.'), findsOneWidget);
      await _flushToasts(tester);

      await tester.tap(find.byKey(const ValueKey('scheduled-delete-f2')));
      await tester.pumpAndSettle();
      expect(find.text('보내지 못한 예약 메시지를 삭제할까요?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '삭제').last);
      await tester.pumpAndSettle();
      expect(
        t.server.called('DELETE', '/api/scheduled-messages/f2'),
        hasLength(1),
      );
      expect(find.text('없어진 방'), findsNothing);
      expect(find.text('예약 2/30', findRichText: true), findsOneWidget);
      await _flushToasts(tester);
    });

    testWidgets('수정 — 바뀐 칸과 발송 시간만 PATCH, 발송 실패는 새 시각으로 다시 예약된다', (
      tester,
    ) async {
      final t = _setup(rows());
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduledMessages(c, t.session)),
      );
      await _open(tester);

      await _cardMenu(tester, 's1', '수정');
      expect(find.text('예약 메시지 수정'), findsOneWidget);
      expect(
        tester.widget<TextField>(_messageField).controller!.text,
        '회의 자료 공유드립니다',
      );
      expect(find.text('안건.pdf'), findsOneWidget);
      await tester.enterText(_messageField, '회의 자료 다시 공유드립니다');
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      final patch = _body(
        t.server.called('PATCH', '/api/scheduled-messages/s1').single,
      );
      expect(patch, {
        'text': '회의 자료 다시 공유드립니다',
        'textFormat': null,
        // 글을 바꾸면 멘션도 같이 간다(멘션이 없으면 빈 목록).
        'mentions': <Object>[],
        'sendAt': _later.millisecondsSinceEpoch,
      });
      expect(find.text('예약 메시지 수정'), findsNothing);
      expect(find.text('회의 자료 다시 공유드립니다', findRichText: true), findsOneWidget);
      await _flushToasts(tester);

      // 발송 실패 → 수정: 지난 시각 대신 새 기본 시각으로 열리고, 저장하면 다시 예약됨.
      await tester.tap(find.byKey(const ValueKey('scheduled-edit-f1')));
      await tester.pumpAndSettle();
      expect(
        find.text(formatScheduleDate(defaultScheduleTime())),
        findsOneWidget,
      );
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      final retry = _body(
        t.server.called('PATCH', '/api/scheduled-messages/f1').single,
      );
      expect(retry.keys, ['sendAt']);
      _expectSlot(retry['sendAt'] as int);
      expect(find.text('대화방의 멤버가 아니어서 보내지 못했습니다.'), findsNothing);
      await _flushToasts(tester);
    });

    testWidgets('방이 사라진 발송 실패를 고치면 다른 대화방을 골라야 한다', (tester) async {
      final t = _setup(rows());
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduledMessages(c, t.session)),
      );
      await _open(tester);

      await tester.tap(find.byKey(const ValueKey('scheduled-edit-f2')));
      await tester.pumpAndSettle();
      expect(
        find.text("원래 대화방 '없어진 방'에는 보낼 수 없습니다. 다른 대화방을 선택하세요."),
        findsOneWidget,
      );
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      expect(find.text('대화방을 선택하세요.'), findsOneWidget);
      expect(t.server.called('PATCH', '/api/scheduled-messages/f2'), isEmpty);

      await tester.tap(find.byKey(const ValueKey('schedule-room')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('공지방').last);
      await tester.pumpAndSettle();
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      final patch = _body(
        t.server.called('PATCH', '/api/scheduled-messages/f2').single,
      );
      expect(patch['roomId'], 'r1');
      expect(patch.containsKey('text'), isFalse);
      await _flushToasts(tester);
    });

    testWidgets('이제는 쓸 수 없는 대화방(보관된 토픽)의 발송 실패를 고치면 열자마자 이유를 알린다', (
      tester,
    ) async {
      final t = _setup([
        _row(
          'f-arch',
          roomId: 'r-arch',
          roomName: '지난 행사',
          text: '행사 사진 공유합니다',
          sendAt: DateTime.now().subtract(const Duration(hours: 1)),
          status: 'failed',
          failReason: '토픽이 보관되어 보낼 수 없습니다.',
        ),
      ]);
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduledMessages(c, t.session)),
      );
      await _open(tester);

      await tester.tap(find.byKey(const ValueKey('scheduled-edit-f-arch')));
      await tester.pumpAndSettle();
      const why = '보관된 토픽입니다. 토픽 관리자만 글을 쓸 수 있습니다.';
      expect(find.text(why), findsOneWidget);

      // 창을 열어 둔 사이 보관이 풀리면 안내도 사라지고, 다시 보관되면 다시 알린다.
      final archived = t.session.roomById('r-arch')!;
      archived.archivedAt = null;
      t.session.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text(why), findsNothing);
      archived.archivedAt = DateTime(2026, 9, 1);
      t.session.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text(why), findsOneWidget);

      // 다른 대화방을 고르면 사라지고, 그 방으로 다시 예약된다.
      await tester.tap(find.byKey(const ValueKey('schedule-room')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('공지방').last);
      await tester.pumpAndSettle();
      expect(find.text(why), findsNothing);
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      final patch = _body(
        t.server.called('PATCH', '/api/scheduled-messages/f-arch').single,
      );
      expect(patch['roomId'], 'r1');
      await _flushToasts(tester);
    });
  });

  group('예약 편집기', () {
    testWidgets('채팅 대화방 — 빈 메시지는 칸 아래에 알리고, 예약하면 제목 없이 보낸다(Ctrl+Enter)', (
      tester,
    ) async {
      final t = _setup();
      final room = t.session.roomById('r1')!;
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduleMessageEditor(c, t.session, room: room)),
      );
      await _open(tester);
      expect(find.text('메시지 예약 생성'), findsOneWidget);
      expect(find.byKey(const ValueKey('schedule-title')), findsNothing);
      // 기본 발송 시각 — 지금부터 15분 뒤 이후의 가장 가까운 15분 단위.
      expect(
        find.text(formatScheduleDate(defaultScheduleTime())),
        findsOneWidget,
      );
      expect(
        find.text(formatScheduleClock(defaultScheduleTime())),
        findsOneWidget,
      );
      expect(find.text('0/5000'), findsOneWidget);

      await tester.tap(_submit);
      await tester.pumpAndSettle();
      expect(find.text('메시지를 입력하세요.'), findsOneWidget);
      expect(t.server.called('POST', '/api/scheduled-messages'), isEmpty);

      await tester.enterText(_messageField, '  회의 자료 공유드립니다  ');
      await tester.pump();
      expect(find.text('메시지를 입력하세요.'), findsNothing); // 고치면 바로 사라진다
      expect(find.text('12/5000'), findsOneWidget); // 앞뒤 공백은 세지 않는다
      await _pressCtrlEnter(tester);

      final body = _body(
        t.server.called('POST', '/api/scheduled-messages').single,
      );
      expect(body.keys.toSet(), {'roomId', 'text', 'sendAt'});
      expect(body['roomId'], 'r1');
      expect(body['text'], '회의 자료 공유드립니다');
      _expectSlot(body['sendAt'] as int);
      expect(find.byType(ScheduleMessageEditor), findsNothing);
      final saved = t.session.scheduledMessages.single;
      expect(
        find.text('메시지를 예약했습니다 · ${formatScheduleTime(saved.sendAt)}'),
        findsOneWidget,
      );
      await _flushToasts(tester);
    });

    testWidgets('보드 뷰 토픽 — 제목(0/50)이 필요하고 게시글 제목으로 보낸다', (tester) async {
      final t = _setup();
      final room = t.session.roomById('r-board')!;
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduleMessageEditor(c, t.session, room: room)),
      );
      await _open(tester);
      expect(find.byKey(const ValueKey('schedule-title')), findsOneWidget);
      expect(find.text('0/50'), findsOneWidget);

      await tester.enterText(_messageField, '이번 주 진행 상황입니다.');
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      expect(find.text('제목을 입력하세요.'), findsOneWidget);
      expect(t.server.called('POST', '/api/scheduled-messages'), isEmpty);

      await tester.enterText(
        find.byKey(const ValueKey('schedule-title')),
        ' 9월 넷째 주 보고 ',
      );
      await tester.pump();
      expect(find.text('제목을 입력하세요.'), findsNothing);
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      final body = _body(
        t.server.called('POST', '/api/scheduled-messages').single,
      );
      expect(body['roomId'], 'r-board');
      expect(body['title'], '9월 넷째 주 보고');
      expect(body['text'], '이번 주 진행 상황입니다.');
      await _flushToasts(tester);
    });

    testWidgets('대화방을 안 고르면 알리고, 나와의 대화(채팅 탭 맨 위)를 골라 "내일 오전 9:00"에 예약', (
      tester,
    ) async {
      final t = _setup();
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduleMessageEditor(c, t.session)),
      );
      await _open(tester);
      await tester.enterText(_messageField, '분기 보고서 마감 챙기기');
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      expect(find.text('대화방을 선택하세요.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('schedule-room')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('채팅').last);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('나와의 대화')).dy,
        lessThan(tester.getTopLeft(find.text('김철수')).dy),
      );
      await tester.tap(find.text('나와의 대화'));
      await tester.pumpAndSettle();
      expect(find.text('대화방을 선택하세요.'), findsNothing);
      // 다시 열면 골라 둔 방의 탭(채팅)부터 보인다.
      await tester.tap(find.byKey(const ValueKey('schedule-room')));
      await tester.pumpAndSettle();
      expect(find.text('김철수'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('김철수'), findsNothing);

      await tester.tap(find.widgetWithText(ChoiceChip, '내일 오전 9:00'));
      await tester.pumpAndSettle();
      final now = DateTime.now();
      final tomorrowNine = DateTime(now.year, now.month, now.day + 1, 9);
      expect(find.text(formatScheduleDate(tomorrowNine)), findsOneWidget);
      expect(find.text('오전 9:00'), findsWidgets);
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      final body = _body(
        t.server.called('POST', '/api/scheduled-messages').single,
      );
      expect(body['roomId'], 'r-self');
      expect(body['sendAt'], tomorrowNine.millisecondsSinceEpoch);
      expect(body.containsKey('title'), isFalse);
      await _flushToasts(tester);
    });

    testWidgets('대화방 목록 — 비밀 대화·쓸 수 없는 토픽·다른 팀 방은 없다', (tester) async {
      final t = _setup();
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduleMessageEditor(c, t.session)),
      );
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('schedule-room')));
      await tester.pumpAndSettle();

      // 토픽 — 읽기 전용이어도 내가 토픽 관리자면 보이고, 보드 뷰 토픽도 보인다.
      expect(find.text('공지방'), findsOneWidget);
      expect(find.text('주간 보고'), findsOneWidget);
      expect(find.text('운영진 공지'), findsOneWidget);
      expect(find.text('읽기전용방'), findsNothing);
      expect(find.text('지난 행사'), findsNothing);
      expect(find.text('다른팀 방'), findsNothing);

      await tester.tap(find.text('그룹채팅').last);
      await tester.pumpAndSettle();
      expect(find.text('디자인 그룹'), findsOneWidget);

      await tester.tap(find.text('채팅').last);
      await tester.pumpAndSettle();
      expect(find.text('나와의 대화'), findsOneWidget);
      expect(find.text('김철수'), findsOneWidget);
      expect(find.text('박비밀'), findsNothing);

      // Esc는 목록만 닫는다(편집기는 그대로).
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('김철수'), findsNothing);
      expect(find.byType(ScheduleMessageEditor), findsOneWidget);
      // 포커스가 편집기로 돌아와 있어서, 한 번 더 누르면(쓴 게 없으니) 편집기가 닫힌다.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleMessageEditor), findsNothing);
    });

    testWidgets('글자 수·첨부 수 한도는 칸 아래에 알리고 보내지 않는다', (tester) async {
      final t = _setup();
      final room = t.session.roomById('r1')!;
      await _pumpApp(
        tester,
        t.session,
        _launcher(
          (c) => showScheduleMessageEditor(
            c,
            t.session,
            room: room,
            text: '가' * 5001,
            attachments: [
              for (var i = 0; i < 11; i++)
                ScheduleDraftAttachment(
                  UploadedAttachment(
                    isImage: false,
                    url: '/uploads/f$i.txt',
                    fileName: '자료$i.txt',
                    size: 10,
                  ),
                ),
            ],
          ),
        ),
      );
      await _open(tester);
      expect(find.text('5001/5000'), findsOneWidget);
      expect(find.text('11/10'), findsOneWidget);
      // 이미 10개를 넘었으니 더 붙이는 단추는 막혀 있다.
      expect(
        tester
            .widget<ButtonStyleButton>(
              find.byKey(const ValueKey('schedule-attach')),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(_submit);
      await tester.pumpAndSettle();
      expect(find.text('메시지는 5000자 이내로 입력하세요.'), findsOneWidget);
      expect(find.text('첨부 파일은 10개까지 올릴 수 있습니다.'), findsOneWidget);
      expect(t.server.called('POST', '/api/scheduled-messages'), isEmpty);

      // 첨부 하나를 빼면 첨부 오류는 사라진다.
      await tester.tap(find.byTooltip('첨부 빼기').first);
      await tester.pumpAndSettle();
      expect(find.text('10/10'), findsOneWidget);
      expect(find.text('첨부 파일은 10개까지 올릴 수 있습니다.'), findsNothing);
    });

    testWidgets('첨부 — 올리다 실패하면 다시 시도할 때까지 예약을 막고, 올리는 중에 빼면 결과를 버린다', (
      tester,
    ) async {
      final t = _setup();
      var uploads = 0;
      var failNext = true;
      Completer<void>? gate;
      t.server.on('POST', '/api/upload', (_) async {
        uploads++;
        final g = gate;
        if (g != null) await g.future;
        if (failNext) {
          failNext = false;
          return _json({'error': '저장 공간이 부족합니다.'}, 500);
        }
        return _json({
          'url': '/uploads/u$uploads.txt',
          'fileName': '메모$uploads.txt',
          'size': 5,
          'mimeType': 'text/plain',
        });
      });
      final dir = Directory.systemTemp.createTempSync('scheduled_ui_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File file(String name) =>
          File('${dir.path}${Platform.pathSeparator}$name')
            ..writeAsStringSync('hello');
      final room = t.session.roomById('r1')!;
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduleMessageEditor(c, t.session, room: room)),
      );
      await _open(tester);
      final editor = tester.state<ScheduleMessageEditorState>(
        find.byType(ScheduleMessageEditor),
      );
      await tester.enterText(_messageField, '자료 보내드립니다');

      editor.addFiles([file('메모.txt')]);
      await _settleIo(tester, () => uploads == 1 && !editor.debugUploading);
      expect(find.text('올리지 못함 · 다시 시도'), findsOneWidget);
      await _flushToasts(tester);
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      expect(find.text('올리지 못한 첨부 파일이 있습니다. 다시 시도하거나 빼 주세요.'), findsOneWidget);
      expect(t.server.called('POST', '/api/scheduled-messages'), isEmpty);
      await _flushToasts(tester);

      await tester.tap(find.text('올리지 못함 · 다시 시도'));
      await tester.pump();
      await _settleIo(tester, () => uploads == 2 && !editor.debugUploading);
      expect(find.text('올리지 못함 · 다시 시도'), findsNothing);

      // 두 번째 파일은 올리는 도중에 뺀다 — 늦게 끝난 업로드가 다시 붙지 않는다.
      gate = Completer<void>();
      editor.addFiles([file('초안.txt')]);
      await _settleIo(tester, () => uploads == 3);
      expect(find.text('초안.txt'), findsOneWidget);
      await tester.tap(find.byTooltip('첨부 빼기').last);
      await tester.pumpAndSettle();
      gate.complete();
      await _settleIo(tester, () => !editor.debugUploading);
      expect(find.text('초안.txt'), findsNothing);
      expect(find.text('1/10'), findsOneWidget);

      await tester.tap(_submit);
      await tester.pumpAndSettle();
      final body = _body(
        t.server.called('POST', '/api/scheduled-messages').single,
      );
      expect(body['attachments'], [
        {
          'kind': 'file',
          'fileUrl': '/uploads/u2.txt',
          'fileName': '메모2.txt',
          'fileSize': 5,
          'mimeType': 'text/plain',
        },
      ]);
      await _flushToasts(tester);
    });

    testWidgets('예약이 이미 30건이면 한도 안내가 뜨고 예약 단추가 막힌다', (tester) async {
      final t = _setup([for (var i = 0; i < 30; i++) _row('s$i')]);
      await _loadScheduled(tester, t.session);
      final room = t.session.roomById('r1')!;
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduleMessageEditor(c, t.session, room: room)),
      );
      await _open(tester);
      expect(find.byKey(const ValueKey('schedule-limit')), findsOneWidget);
      expect(tester.widget<FilledButton>(_submit).onPressed, isNull);
    });

    testWidgets('서버가 거절하면 그 문구를 토스트로 알리고 편집기는 열어 둔다', (tester) async {
      final t = _setup();
      t.server.on(
        'POST',
        '/api/scheduled-messages',
        (_) => _json({'error': '이 방의 멤버가 아닙니다.'}, 400),
      );
      final room = t.session.roomById('r1')!;
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduleMessageEditor(c, t.session, room: room)),
      );
      await _open(tester);
      await tester.enterText(_messageField, '안녕하세요');
      await tester.tap(_submit);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('이 방의 멤버가 아닙니다.'), findsOneWidget);
      expect(find.byType(ScheduleMessageEditor), findsOneWidget);
      await _flushToasts(tester);
    });

    testWidgets('쓰던 게 있으면 Esc는 한 번 묻고, 없으면 바로 닫는다', (tester) async {
      final t = _setup();
      final room = t.session.roomById('r1')!;
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduleMessageEditor(c, t.session, room: room)),
      );
      await _open(tester);
      await tester.enterText(_messageField, '쓰는 중');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('작성 중인 예약 메시지를 버리고 닫을까요?'), findsOneWidget);
      await tester.tap(find.text('계속 쓰기'));
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleMessageEditor), findsOneWidget);

      await tester.enterText(_messageField, '');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleMessageEditor), findsNothing);
    });

    testWidgets('날짜는 오늘부터 90일 뒤까지만, 시각은 15분 단위 목록에서 고른다', (tester) async {
      final t = _setup();
      final room = t.session.roomById('r1')!;
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduleMessageEditor(c, t.session, room: room)),
      );
      await _open(tester);

      await tester.tap(find.byKey(const ValueKey('schedule-date')));
      await tester.pumpAndSettle();
      final now = DateTime.now();
      final yesterday = DateTime(now.year, now.month, now.day - 1);
      Finder day(DateTime d) =>
          find.byKey(ValueKey('schedule-day-${d.year}-${d.month}-${d.day}'));
      // 어제는(이번 달에 있으면) 누를 수 없다.
      if (yesterday.month == now.month) {
        expect(tester.widget<InkWell>(day(yesterday)).onTap, isNull);
      }
      // 이전 달로는 못 가고, 90일 뒤가 있는 달까지만 넘긴다.
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.chevron_left),
            )
            .onPressed,
        isNull,
      );
      final last = latestScheduleTime(now);
      for (var i = 0; i < 3; i++) {
        final next = find.widgetWithIcon(IconButton, Icons.chevron_right);
        if (tester.widget<IconButton>(next).onPressed == null) break;
        await tester.tap(next);
        await tester.pumpAndSettle();
      }
      expect(find.text('${last.year}년 ${last.month}월'), findsOneWidget);
      final afterLast = DateTime(last.year, last.month, last.day + 1);
      if (afterLast.month == last.month) {
        expect(tester.widget<InkWell>(day(afterLast)).onTap, isNull);
      }
      // 마지막 날(90일째)은 고를 수 있다.
      await tester.tap(day(last));
      await tester.pumpAndSettle();
      expect(find.text(formatScheduleDate(last)), findsOneWidget);

      // 시각 — "내일 오전 9:00"으로 옮긴 뒤 15분 단위 목록에서 바로 앞 칸(오전 8:45)을 고른다.
      await tester.tap(find.widgetWithText(ChoiceChip, '내일 오전 9:00'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-time')));
      await tester.pumpAndSettle();
      // 목록은 15분 간격 — 9:00 바로 위가 8:45다(8:50 같은 칸은 없다).
      final nine = tester.getCenter(find.text('오전 9:00').last);
      final before = tester.getCenter(find.text('오전 8:45').last);
      expect(before.dy, lessThan(nine.dy));
      expect(find.text('오전 8:50'), findsNothing);
      await tester.tap(find.text('오전 8:45').last);
      await tester.pumpAndSettle();
      await tester.enterText(_messageField, '회의 알림');
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      final sendAt = DateTime.fromMillisecondsSinceEpoch(
        _body(
              t.server.called('POST', '/api/scheduled-messages').single,
            )['sendAt']
            as int,
      );
      final tomorrow = DateTime(now.year, now.month, now.day + 1, 8, 45);
      expect(sendAt, tomorrow);
      await _flushToasts(tester);
    });
  });

  group('채팅 입력칸', () {
    testWidgets('시계 단추 — 쓰던 글과 올려 둔 첨부를 채워 열고, 예약하면 입력칸을 비운다', (tester) async {
      final t = _setup();
      var uploads = 0;
      t.server.on('POST', '/api/upload', (_) {
        uploads++;
        return _json({
          'url': '/uploads/u$uploads-메모.txt',
          'fileName': '메모.txt',
          'size': 5,
          'mimeType': 'text/plain',
        });
      });
      final dir = Directory.systemTemp.createTempSync('scheduled_ui_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}메모.txt')
        ..writeAsStringSync('hello');
      final room = t.session.roomById('r1')!;
      _wide(tester);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: _inputBar(t.session, room))),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('chat-input')),
        '내일 회의 안건입니다',
      );
      tester
          .state<ChatInputBarState>(find.byType(ChatInputBar))
          .addDroppedFiles([file]);
      await _settleIo(
        tester,
        () => uploads == 1 && find.byTooltip('메시지 예약').evaluate().isNotEmpty,
      );

      // 취소하면 쓰던 글·첨부는 그대로 남는다.
      await tester.tap(find.byKey(const ValueKey('chat-schedule')));
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleMessageEditor), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleMessageEditor), findsNothing);
      expect(find.text('내일 회의 안건입니다'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('chat-schedule')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(_messageField).controller!.text,
        '내일 회의 안건입니다',
      );
      expect(
        find.descendant(
          of: find.byType(ScheduleMessageEditor),
          matching: find.text('메모.txt'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('schedule-room')),
          matching: find.text('공지방'),
        ),
        findsOneWidget,
      );
      await tester.tap(_submit);
      await tester.pumpAndSettle();

      final body = _body(
        t.server.called('POST', '/api/scheduled-messages').single,
      );
      expect(body['roomId'], 'r1');
      expect(body['text'], '내일 회의 안건입니다');
      expect(body['attachments'], [
        {
          'kind': 'file',
          'fileUrl': '/uploads/u1-메모.txt',
          'fileName': '메모.txt',
          'fileSize': 5,
          'mimeType': 'text/plain',
        },
      ]);
      expect(uploads, 1); // 입력칸에서 올린 것을 그대로 쓴다(다시 올리지 않는다)
      final input = tester.widget<TextField>(
        find.byKey(const ValueKey('chat-input')),
      );
      expect(input.controller!.text, isEmpty);
      expect(find.text('메모.txt'), findsNothing);
      await _flushToasts(tester);
    });

    testWidgets('예약이 있으면 입력칸 위에 "예약된 메시지 N개 · 보기" — 누르면 이 대화방만 걸러 연다', (
      tester,
    ) async {
      final t = _setup([
        _row('s1', text: '첫 번째 예약'),
        _row(
          's2',
          text: '두 번째 예약',
          sendAt: _later.add(const Duration(hours: 1)),
        ),
        _row(
          'f1',
          text: '실패한 예약',
          status: 'failed',
          failReason: '보내는 중 오류가 발생했습니다. 다시 예약하세요.',
        ),
        _row('d1', roomId: 'r-dm', roomName: '김철수', text: '다른 방 예약'),
      ]);
      await _loadScheduled(tester, t.session);
      final room = t.session.roomById('r1')!;
      _wide(tester);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: _inputBar(t.session, room))),
      );
      await tester.pumpAndSettle();

      final bar = find.byKey(const ValueKey('scheduled-room-bar'));
      expect(bar, findsOneWidget);
      expect(
        find.text('예약된 메시지 2개 · 발송 실패 1개 · 보기', findRichText: true),
        findsOneWidget,
      );

      await tester.tap(bar);
      await tester.pumpAndSettle();
      final chip = tester.widget<FilterChip>(
        find.byKey(const ValueKey('scheduled-only-room')),
      );
      expect(chip.selected, isTrue);
      expect(find.text('첫 번째 예약', findRichText: true), findsOneWidget);
      expect(find.text('두 번째 예약', findRichText: true), findsOneWidget);
      expect(find.text('실패한 예약', findRichText: true), findsOneWidget);
      expect(find.text('다른 방 예약', findRichText: true), findsNothing);
      // 칩을 끄면 팀의 예약이 전부 보인다.
      await tester.tap(find.byKey(const ValueKey('scheduled-only-room')));
      await tester.pumpAndSettle();
      expect(find.text('다른 방 예약', findRichText: true), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // 다른 기기에서 취소하는 등 목록이 바뀌면 줄도 바로 따라간다.
      await t.session.cancelScheduledMessage('s1');
      await tester.pumpAndSettle();
      expect(
        find.text('예약된 메시지 1개 · 발송 실패 1개 · 보기', findRichText: true),
        findsOneWidget,
      );
      await t.session.cancelScheduledMessage('s2');
      await t.session.cancelScheduledMessage('f1');
      await tester.pumpAndSettle();
      expect(bar, findsNothing);
    });

    testWidgets('나와의 대화에는 화상회의 단추가 없고, 비밀 대화에는 예약 단추가 없다', (tester) async {
      final t = _setup();
      t.session.callsEnabled = true;
      _wide(tester);
      Future<void> pumpRoom(String id) async {
        final room = t.session.roomById(id)!;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: _inputBar(t.session, room), key: ValueKey(id)),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pumpRoom('r1');
      expect(find.byTooltip('화상회의 시작'), findsOneWidget);
      expect(find.byTooltip('메시지 예약'), findsOneWidget);

      await pumpRoom('r-self');
      expect(find.byTooltip('화상회의 시작'), findsNothing);
      expect(find.byTooltip('메시지 예약'), findsOneWidget);

      await pumpRoom('r-secret');
      expect(find.byTooltip('메시지 예약'), findsNothing);
    });
  });

  group('보드', () {
    testWidgets('보드에도 "예약된 게시글 N개 · 보기" 줄이 뜬다', (tester) async {
      final t = _setup([
        _row('p1', roomId: 'r-board', roomName: '주간 보고', title: '주간 보고서'),
      ]);
      await _loadScheduled(tester, t.session);
      final room = t.session.roomById('r-board')!;
      _wide(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPanel(
              key: ValueKey(room.id),
              session: t.session,
              room: room,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('예약된 게시글 1개 · 보기', findRichText: true), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('scheduled-room-bar')));
      await tester.pumpAndSettle();
      expect(find.byType(ScheduledMessagesScreen), findsOneWidget);
      expect(find.textContaining('주간 보고서', findRichText: true), findsOneWidget);
    });

    testWidgets('게시글 편집기의 "예약" — 제목·본문·첨부를 채워 예약하고 편집기는 게시 없이 닫힌다', (
      tester,
    ) async {
      final t = _setup();
      var uploads = 0;
      t.server.on('POST', '/api/upload', (_) {
        uploads++;
        return _json({
          'url': '/uploads/u$uploads-회의록.txt',
          'fileName': '회의록.txt',
          'size': 5,
          'mimeType': 'text/plain',
        });
      });
      final room = t.session.roomById('r-board')!;
      var sends = 0;
      t.session.chatSocket.debugSendOverride = (payload) async {
        sends++;
        return {'ok': true};
      };
      final dir = Directory.systemTemp.createTempSync('scheduled_ui_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}회의록.txt')
        ..writeAsStringSync('hello');
      await _pumpApp(
        tester,
        t.session,
        (context) =>
            ChatPanel(key: ValueKey(room.id), session: t.session, room: room),
      );

      await tester.tap(find.byTooltip('게시글 작성'));
      await tester.pumpAndSettle();
      tester.state<PostEditorState>(find.byType(PostEditor)).addFiles([file]);
      final editor = tester.state<PostEditorState>(find.byType(PostEditor));
      await _settleIo(tester, () => uploads == 1 && !editor.debugUploading);
      await tester.enterText(
        find.byKey(const ValueKey('post-title')),
        '9월 넷째 주 보고',
      );
      await tester.enterText(
        find.byKey(const ValueKey('post-body')),
        '진행 상황 정리',
      );
      await tester.tap(find.byKey(const ValueKey('post-schedule')));
      await tester.pumpAndSettle();

      expect(find.byType(ScheduleMessageEditor), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('schedule-title')))
            .controller!
            .text,
        '9월 넷째 주 보고',
      );
      expect(
        tester.widget<TextField>(_messageField).controller!.text,
        '진행 상황 정리',
      );
      await tester.tap(_submit);
      await tester.pumpAndSettle();

      final body = _body(
        t.server.called('POST', '/api/scheduled-messages').single,
      );
      expect(body['roomId'], 'r-board');
      expect(body['title'], '9월 넷째 주 보고');
      expect(body['text'], '진행 상황 정리');
      expect((body['attachments'] as List).single['fileName'], '회의록.txt');
      expect(find.byType(PostEditor), findsNothing);
      expect(find.byType(ScheduleMessageEditor), findsNothing);
      expect(sends, 0); // 게시하지 않았다
      expect(postEditorsOpen.value, 0);
      // 보드 위에 새 예약 줄이 생긴다.
      expect(find.text('예약된 게시글 1개 · 보기', findRichText: true), findsOneWidget);
      await _flushToasts(tester);
    });
  });

  group('발송 결과 토스트', () {
    testWidgets('예약 시각에 보냈으면/못 보냈으면 어느 화면에서든 차례로 알린다', (tester) async {
      final t = _setup([
        _row('s1'),
        _row('s2', roomId: 'r-dm', roomName: '김철수'),
      ]);
      await _loadScheduled(tester, t.session);
      await _pumpApp(tester, t.session, (_) => const SizedBox());

      t.session.handleScheduledMessageEvent(
        const ScheduledMessageEvent(
          type: ScheduledMessageEventType.sent,
          id: 's1',
          teamId: 't1',
          roomId: 'r1',
          roomName: '공지방',
          messageIds: ['m1'],
        ),
      );
      t.session.handleScheduledMessageEvent(
        const ScheduledMessageEvent(
          type: ScheduledMessageEventType.failed,
          id: 's2',
          teamId: 't1',
          roomId: 'r-dm',
          reason: '대화방의 멤버가 아니어서 보내지 못했습니다.',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('예약 메시지를 보냈습니다 · 공지방'), findsOneWidget);
      // 겹치지 않게 앞의 알림이 사라진 뒤에 띄운다.
      expect(find.textContaining('보내지 못했습니다 ('), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('예약 메시지를 보냈습니다 · 공지방'), findsNothing);
      expect(
        find.text('예약 메시지를 보내지 못했습니다 (김철수): 대화방의 멤버가 아니어서 보내지 못했습니다.'),
        findsOneWidget,
      );
      // 목록도 그 자리에서 맞춰진다(보낸 예약은 빠지고 못 보낸 예약은 발송 실패).
      expect(t.session.scheduledMessages.single.isFailed, isTrue);
      await _flushToasts(tester);
    });

    testWidgets('같은 결과가 한꺼번에 여러 건 오면(토픽 보관 등) 한 번에 묶어 알린다', (tester) async {
      final t = _setup([
        for (var i = 0; i < 5; i++)
          _row('a$i', sendAt: _later.add(Duration(minutes: 15 * i))),
        _row('d1', roomId: 'r-dm', roomName: '김철수'),
      ]);
      await _loadScheduled(tester, t.session);
      await _pumpApp(tester, t.session, (_) => const SizedBox());

      // 토픽이 보관되면 서버는 그 방 예약마다 scheduled:failed를 잇달아 보낸다.
      for (var i = 0; i < 5; i++) {
        t.session.handleScheduledMessageEvent(
          ScheduledMessageEvent(
            type: ScheduledMessageEventType.failed,
            id: 'a$i',
            teamId: 't1',
            roomId: 'r1',
            roomName: '공지방',
            reason: '토픽이 보관되어 보낼 수 없습니다.',
          ),
        );
      }
      // 다른 방의 결과는 따로 알린다.
      t.session.handleScheduledMessageEvent(
        const ScheduledMessageEvent(
          type: ScheduledMessageEventType.sent,
          id: 'd1',
          teamId: 't1',
          roomId: 'r-dm',
          roomName: '김철수',
          messageIds: ['m1'],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('예약 메시지 5건을 보내지 못했습니다 (공지방): 토픽이 보관되어 보낼 수 없습니다.'),
        findsOneWidget,
      );
      expect(find.textContaining('예약 메시지를 보내지 못했습니다'), findsNothing);
      // 묶은 알림 하나가 지나가면 바로 다음 결과 — 같은 실패가 다섯 번 이어지지 않는다.
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('예약 메시지를 보냈습니다 · 김철수'), findsOneWidget);
      expect(find.textContaining('보내지 못했습니다'), findsNothing);
      await _flushToasts(tester);
      expect(find.textContaining('보내지 못했습니다'), findsNothing);
      expect(
        t.session.scheduledMessages.where((m) => m.isFailed),
        hasLength(5),
      );
    });

    test('묶은 알림 문구 — 1건이면 원래 문구 그대로', () {
      const sent = ScheduledMessageEvent(
        type: ScheduledMessageEventType.sent,
        id: 's1',
        roomName: '공지방',
      );
      const failed = ScheduledMessageEvent(
        type: ScheduledMessageEventType.failed,
        id: 'f1',
        roomName: ' ',
        reason: '대화방이 삭제되어 보내지 못했습니다.',
      );
      expect(sent.toastTextFor(1), sent.toastText);
      expect(sent.toastTextFor(3), '예약 메시지 3건을 보냈습니다 · 공지방');
      expect(failed.toastTextFor(0), failed.toastText);
      expect(
        failed.toastTextFor(2),
        '예약 메시지 2건을 보내지 못했습니다 (대화방): 대화방이 삭제되어 보내지 못했습니다.',
      );
    });
  });

  group('좁은 화면(360px)', () {
    testWidgets('목록·편집기가 전체 화면으로 열리고 넘치지 않는다', (tester) async {
      final t = _setup([
        _row(
          's1',
          roomId: 'r-board',
          roomName: '주간 보고',
          title: '아주 긴 제목의 게시글 예약입니다 정말 길어요 끝까지 보여주기 어려울 만큼',
          attachments: [_fileJson('a.pdf')],
        ),
        _row(
          'f1',
          status: 'failed',
          failReason: '서버가 다시 시작되어 보냈는지 확인하지 못했습니다. 대화방을 확인한 뒤 다시 예약하세요.',
        ),
      ]);
      final room = t.session.roomById('r-board')!;
      await _pumpApp(
        tester,
        t.session,
        (context) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(
              onPressed: () => showScheduledMessages(context, t.session),
              child: const Text('목록'),
            ),
            FilledButton(
              onPressed: () =>
                  showScheduleMessageEditor(context, t.session, room: room),
              child: const Text('편집기'),
            ),
          ],
        ),
        size: const Size(360, 740),
      );
      await tester.tap(find.text('목록'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.widgetWithText(AppBar, '메시지 예약'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('편집기'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.widgetWithText(AppBar, '메시지 예약 생성'), findsOneWidget);
      await tester.tap(_submit);
      await tester.pumpAndSettle();
      expect(find.text('제목을 입력하세요.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('취소'));
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleMessageEditor), findsNothing);
    });

    testWidgets('메시지를 쓰다가 날짜를 누르면 화상 키보드를 내리고, 달력은 화면 안에 뜬다', (tester) async {
      const screen = Size(390, 844);
      final t = _setup();
      final room = t.session.roomById('r-board')!;
      await _pumpApp(
        tester,
        t.session,
        _launcher((c) => showScheduleMessageEditor(c, t.session, room: room)),
        size: screen,
      );
      await _open(tester);
      await tester.tap(_messageField);
      await tester.enterText(_messageField, '이번 주 진행 상황입니다.');
      expect(tester.testTextInput.isVisible, isTrue);

      // 화상 키보드가 아래 300px을 가린 채로 폼을 끝까지 내려 날짜 칸을 누른다.
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      await tester.drag(
        find
            .descendant(
              of: find.byType(ScheduleMessageEditor),
              matching: find.byType(SingleChildScrollView),
            )
            .first,
        const Offset(0, -1500),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-date')));
      await tester.pumpAndSettle();
      // 입력칸에서 포커스가 빠져 키보드가 내려간다(달력 아래쪽이 키보드에 가리지 않게).
      expect(
        tester.widget<TextField>(_messageField).focusNode!.hasFocus,
        isFalse,
      );
      expect(tester.testTextInput.isVisible, isFalse);

      // 키보드가 내려가며 폼이 다시 자리를 잡아(칸이 아래로 밀린다) 달력도 자리를 다시 잡는다 —
      // 화면 안에, 날짜 칸을 가리지 않게.
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      final calendar = tester.getRect(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_ScheduleCalendar',
        ),
      );
      final field = tester.getRect(find.byKey(const ValueKey('schedule-date')));
      expect(calendar.top, greaterThanOrEqualTo(0));
      expect(calendar.bottom, lessThanOrEqualTo(screen.height));
      // 밀려 내려간 칸 아래로는 6줄짜리 달이 들어갈 자리가 없어서 칸 위로 옮겨 뜬다.
      expect(screen.height - field.bottom, lessThan(330));
      expect(
        calendar.bottom,
        lessThanOrEqualTo(field.top),
        reason: '달력 $calendar 이 날짜 칸 $field 위로 옮겨 가야 한다',
      );
    });
  });
}
