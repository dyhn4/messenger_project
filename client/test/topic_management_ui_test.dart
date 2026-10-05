import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client/data/stickers.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/models/topic_folder.dart';
import 'package:client/screens/chat_screen.dart';
import 'package:client/screens/create_topic_screen.dart';
import 'package:client/screens/invite_members_screen.dart';
import 'package:client/screens/topic_browse_screen.dart';
import 'package:client/screens/topic_members_dialog.dart';
import 'package:client/screens/topic_settings_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/chat_socket.dart' show RoomRemovedEvent;
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/capture_upload_dialog.dart';
import 'package:client/widgets/chat_input_bar.dart';
import 'package:client/widgets/room_options_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 토픽 관리 화면(UI-A) — 새로운 토픽 생성하기, 참여 가능한 토픽 보기, 더보기 메뉴, 참여 멤버,
/// 토픽 정보 변경하기(설정·보관·삭제·토픽 관리자 지정·멤버 내보내기), 읽기 전용 입력칸, 마지막
/// 토픽 관리자의 나가기.

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
    bool flashWindowFrame = true,
  }) async {}
}

typedef _Handler = FutureOr<http.Response> Function(http.Request request);

/// 경로별 응답을 정해두고, 들어온 요청을 전부 기록하는 가짜 서버.
class _FakeServer {
  final requests = <http.Request>[];
  final routes = <String, _Handler>{};

  late final client = MockClient((request) async {
    requests.add(request);
    final handler = routes['${request.method} ${request.url.path}'];
    if (handler != null) return handler(request);
    return _json(request.method == 'GET' ? <Object>[] : <String, Object>{});
  });

  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
}

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _body(http.Request r) =>
    jsonDecode(r.body) as Map<String, dynamic>;

Map<String, dynamic> _user(
  String id,
  String name, {
  String role = 'member',
  bool owner = false,
  String? position,
}) => {
  'id': id,
  'username': id,
  'name': name,
  'role': role,
  'isOwner': owner,
  'position': ?position,
};

/// 나(김하나, 정회원·토픽 관리자), 이도현(토픽 관리자), 박서연(팀 소유자·계정 관리자),
/// 최준호(계정 관리자), 정유나·한지민(정회원), 오세훈(준회원).
final _members = [
  _user('me', '김하나'),
  _user('u2', '이도현'),
  _user('u3', '박서연', role: 'admin', owner: true),
  _user('u4', '최준호', role: 'admin'),
  _user('u5', '정유나', position: '사원'),
  _user('u6', '한지민'),
  _user('u7', '오세훈', role: 'guest'),
];

Map<String, dynamic> _roomJson({
  String id = 'r1',
  String name = '마케팅 회의',
  String type = 'topic',
  List<Map<String, dynamic>>? members,
  Map<String, dynamic> extra = const {},
}) => {
  'id': id,
  'teamId': 't1',
  'type': type,
  'name': name,
  'isPublic': true,
  'members': members ?? _members,
  'createdAt': 1000,
  'adminIds': ['me', 'u2'],
  ...extra,
};

Room _room({
  String id = 'r1',
  String name = '마케팅 회의',
  String type = 'topic',
  Map<String, dynamic> extra = const {},
}) => Room.fromJson(_roomJson(id: id, name: name, type: type, extra: extra));

Session _session(
  _FakeServer server, {
  AccountRole role = AccountRole.member,
  bool teamOwner = false,
  List<Room> rooms = const [],
}) {
  final s = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  s.serverUrl = 'https://test.local';
  s.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: server.client,
  );
  s.userId = 'me';
  s.name = '김하나';
  s.accountRole = role;
  final team = Team(
    id: 't1',
    name: '영업팀',
    createdAt: DateTime(2026),
    isOwner: teamOwner,
  );
  s.teams.add(team);
  s.currentTeam = team;
  s.rooms.addAll(rooms);
  return s;
}

const _wide = Size(1280, 900);
const _phone = Size(360, 740);

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// 빈 화면을 띄우고 [open]으로 대화상자/화면을 연다.
Future<void> _open(
  WidgetTester tester,
  Future<void> Function(BuildContext context) open, {
  Size size = _wide,
}) async {
  _setSize(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const ValueKey('host-open'),
              onPressed: () => open(context),
              child: const Text('시작'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('host-open')));
  await tester.pumpAndSettle();
}

/// 스크롤 안쪽에 있어도 보이게 한 뒤 누른다.
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 토스트(2초 뒤 사라짐) 타이머까지 흘려보낸다.
Future<void> _flushToasts(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 3));

Finder _key(String key) => find.byKey(ValueKey(key));

bool _enabled(WidgetTester tester, Finder button) =>
    tester.widget<ButtonStyleButton>(button).onPressed != null;

Checkbox _checkboxIn(WidgetTester tester, Finder row) =>
    tester.widget<Checkbox>(
      find.descendant(of: row, matching: find.byType(Checkbox)),
    );

void main() {
  group('새로운 토픽 생성하기', () {
    testWidgets('빈 이름은 막고, 고른 값으로 만든 뒤 토픽을 열고 멤버 초대하기를 띄운다', (tester) async {
      final server = _FakeServer();
      server.routes['POST /api/rooms'] = (r) => _json(
        _roomJson(
          id: 'r9',
          name: _body(r)['name'] as String,
          members: [_user('me', '김하나')],
          extra: {
            'isPublic': _body(r)['isPublic'],
            'viewMode': _body(r)['viewMode'],
            'readOnly': _body(r)['readOnly'],
            'adminIds': ['me'],
          },
        ),
      );
      final session = _session(server);
      session.topicFolders.addAll([
        TopicFolder(id: 'f1', name: '영업', position: 0),
        TopicFolder(id: 'f2', name: '개발', position: 1),
      ]);
      final opened = <Room>[];
      await _open(
        tester,
        (context) =>
            showCreateTopicFlow(context, session, onOpenRoom: opened.add),
      );

      expect(find.text('새로운 토픽 생성하기'), findsOneWidget);
      for (final label in ['이름', '보기 방식', '공개 여부', '토픽 설명', '폴더 선택']) {
        expect(find.textContaining(label), findsWidgets, reason: label);
      }
      expect(find.text('챗 뷰'), findsOneWidget);
      expect(find.text('제목이 있는 게시글을 올리는 게시판'), findsOneWidget);
      expect(find.text('보기 방식은 만든 뒤에 바꿀 수 없습니다.'), findsOneWidget);
      expect(find.text('0/60'), findsOneWidget);

      // 이름이 비었으면 요청하지 않고 칸 아래에 알린다.
      await _tap(tester, _key('create-topic-submit'));
      expect(find.text('토픽 이름을 입력하세요.'), findsOneWidget);
      expect(server.called('POST', '/api/rooms'), isEmpty);

      // 공개일 때는 자동 초대를 켤 수 있고, 비공개로 바꾸면 꺼지고 막힌다.
      await _tap(tester, _key('create-topic-auto-invite'));
      expect(
        tester.widget<SwitchListTile>(_key('create-topic-auto-invite')).value,
        isTrue,
      );
      await _tap(tester, _key('create-topic-private'));
      final autoInvite = tester.widget<SwitchListTile>(
        _key('create-topic-auto-invite'),
      );
      expect(autoInvite.value, isFalse);
      expect(autoInvite.onChanged, isNull);
      expect(find.text('비공개 토픽은 자동 초대를 쓸 수 없습니다'), findsOneWidget);

      await _tap(tester, _key('create-topic-view-board'));
      await _tap(tester, _key('create-topic-read-only'));
      await tester.enterText(_key('create-topic-description'), ' 매주 올립니다 ');
      await tester.pumpAndSettle();

      // 폴더: "폴더 없음" + 내 폴더들.
      await _tap(tester, _key('create-topic-folder'));
      expect(find.text('폴더 없음'), findsWidgets);
      await tester.tap(find.text('개발').last);
      await tester.pumpAndSettle();

      // 이름 칸에서 Enter로 만든다.
      await tester.enterText(_key('create-topic-name'), '주간 보고');
      await tester.pump();
      expect(find.text('5/60'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(_body(server.called('POST', '/api/rooms').single), {
        'teamId': 't1',
        'type': 'topic',
        'name': '주간 보고',
        'description': '매주 올립니다',
        'isPublic': false,
        'viewMode': 'board',
        'readOnly': true,
        'autoInvite': false,
        'folderId': 'f2',
      });
      expect(find.byType(CreateTopicScreen), findsNothing);
      expect(opened.single.id, 'r9');
      expect(opened.single.isBoard, isTrue);
      // 만든 사람만 멤버라 바로 멤버 초대하기 창을 띄운다.
      expect(find.byType(InviteMembersScreen), findsOneWidget);
      expect(find.text('멤버 초대하기'), findsOneWidget);
      expect(session.topicFolderOf('r9')?.id, 'f2');
    });

    testWidgets('기본값(챗 뷰·공개·자동 초대 끔)으로 만들고, 서버 거절은 창 안에 보여준다', (tester) async {
      final server = _FakeServer();
      var reject = true;
      server.routes['POST /api/rooms'] = (r) => reject
          ? _json({'error': '토픽을 만들 권한이 없습니다.'}, 403)
          : _json(
              _roomJson(
                id: 'r9',
                name: _body(r)['name'] as String,
                members: [_user('me', '김하나')],
              ),
            );
      final session = _session(server);
      final opened = <Room>[];
      await _open(
        tester,
        (context) => showCreateTopicFlow(
          context,
          session,
          onOpenRoom: opened.add,
          initialFolderId: 'gone', // 없는 폴더면 "폴더 없음"으로 본다
        ),
      );
      await tester.enterText(_key('create-topic-name'), '잡담');
      await _tap(tester, _key('create-topic-submit'));
      expect(find.text('토픽을 만들 권한이 없습니다.'), findsOneWidget);
      expect(find.byType(CreateTopicScreen), findsOneWidget);
      expect(opened, isEmpty);

      reject = false;
      await _tap(tester, _key('create-topic-submit'));
      expect(_body(server.called('POST', '/api/rooms').last), {
        'teamId': 't1',
        'type': 'topic',
        'name': '잡담',
        'isPublic': true,
        'viewMode': 'chat',
        'readOnly': false,
        'autoInvite': false,
      });
      expect(opened.single.id, 'r9');
    });

    testWidgets('만드는 중에는 Esc로 닫히지 않고, 끝나면 토픽을 열고 초대 창을 띄운다', (tester) async {
      final server = _FakeServer();
      final reply = Completer<http.Response>();
      server.routes['POST /api/rooms'] = (_) => reply.future;
      final session = _session(server);
      final opened = <Room>[];
      await _open(
        tester,
        (context) =>
            showCreateTopicFlow(context, session, onOpenRoom: opened.add),
      );
      await tester.enterText(_key('create-topic-name'), '급한 토픽');
      await tester.tap(_key('create-topic-submit'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      // 요청이 끝나기 전이라 pumpAndSettle은 못 쓴다(진행 표시가 계속 돈다).
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(CreateTopicScreen), findsOneWidget);

      reply.complete(
        _json(
          _roomJson(id: 'r9', name: '급한 토픽', members: [_user('me', '김하나')]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CreateTopicScreen), findsNothing);
      expect(opened.single.id, 'r9');
      expect(find.byType(InviteMembersScreen), findsOneWidget);
    });

    testWidgets('모바일(360px): 전체 화면으로 만들고, 연 토픽 위에 멤버 초대하기 화면을 띄운다', (
      tester,
    ) async {
      final server = _FakeServer();
      server.routes['POST /api/rooms'] = (r) => _json(
        _roomJson(
          id: 'r9',
          name: _body(r)['name'] as String,
          members: [_user('me', '김하나')],
        ),
      );
      final session = _session(server);
      late NavigatorState navigator;
      await _open(tester, (context) {
        navigator = Navigator.of(context);
        return showCreateTopicFlow(
          context,
          session,
          // 모바일 목록처럼 토픽 화면을 전체 화면으로 연다.
          onOpenRoom: (room) => navigator.push(
            MaterialPageRoute(
              builder: (_) => Scaffold(body: Text('토픽 화면 ${room.id}')),
            ),
          ),
        );
      }, size: _phone);
      expect(find.byType(Dialog), findsNothing);
      expect(find.widgetWithText(AppBar, '새로운 토픽 생성하기'), findsOneWidget);
      // 좁은 화면에서는 보기 방식 카드를 위아래로 쌓는다(넘침 없음).
      expect(tester.takeException(), isNull);
      final chat = tester.getRect(_key('create-topic-view-chat'));
      final board = tester.getRect(_key('create-topic-view-board'));
      expect(board.top, greaterThan(chat.bottom));

      await tester.enterText(_key('create-topic-name'), '현장 공유');
      await _tap(tester, _key('create-topic-submit'));
      expect(find.byType(InviteMembersScreen), findsOneWidget);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.text('토픽 화면 r9'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('참여 가능한 토픽 보기', () {
    final entries = [
      {
        'id': 'b1',
        'name': '사내 동호회',
        'description': '등산 모임 소식',
        'isPublic': true,
        'memberCount': 42,
        'joined': false,
        'adminNames': ['이도현'],
      },
      {
        'id': 'b2',
        'name': '주간 업무 보고',
        'description': '금요일마다 올리는 보고',
        'isPublic': true,
        'memberCount': 18,
        'joined': false,
        'viewMode': 'board',
        'readOnly': true,
        'archived': true,
        'adminNames': ['박서연', '최준호'],
      },
      {
        'id': 'r1',
        'name': '마케팅 회의',
        'isPublic': true,
        'memberCount': 7,
        'joined': true,
        'adminNames': ['김하나'],
      },
      {
        'id': 'p1',
        'name': '임원 보고',
        'isPublic': false,
        'memberCount': 3,
        'joined': true,
      },
    ];

    Session browseSession(_FakeServer server, {AccountRole? role}) {
      server.routes['GET /api/rooms/browse'] = (_) => _json(entries);
      server.routes['POST /api/rooms/b1/join'] = (_) =>
          _json(_roomJson(id: 'b1', name: '사내 동호회'));
      return _session(
        server,
        role: role ?? AccountRole.member,
        rooms: [_room()],
      );
    }

    testWidgets('두 탭·배지·관리자 이름·검색, 참여하기는 참여 후 창을 닫고 토픽을 연다', (tester) async {
      final server = _FakeServer();
      final session = browseSession(server);
      final opened = <Room>[];
      await _open(
        tester,
        (context) => showTopicBrowse(context, session, onOpenRoom: opened.add),
      );

      expect(find.text('참여 가능한 토픽 보기'), findsOneWidget);
      expect(find.text('참여 가능한 토픽 2'), findsOneWidget);
      expect(find.text('참여 중인 토픽 2'), findsOneWidget);
      // 보관된 토픽은 뒤로.
      expect(
        tester.getTopLeft(_key('topic-browse-b1')).dy,
        lessThan(tester.getTopLeft(_key('topic-browse-b2')).dy),
      );
      for (final badge in ['보드 뷰', '읽기 전용', '보관됨']) {
        expect(
          find.descendant(
            of: _key('topic-browse-b2'),
            matching: find.text(badge),
          ),
          findsOneWidget,
          reason: badge,
        );
      }
      expect(find.text('멤버 18명 · 관리자 박서연, 최준호'), findsOneWidget);
      expect(find.text('멤버 42명 · 관리자 이도현'), findsOneWidget);
      expect(find.text('등산 모임 소식'), findsOneWidget);

      // 이름·설명으로 찾는다.
      await tester.enterText(_key('topic-browse-search'), '금요일');
      await tester.pumpAndSettle();
      expect(find.text('참여 가능한 토픽 1'), findsOneWidget);
      expect(_key('topic-browse-b1'), findsNothing);
      await tester.enterText(_key('topic-browse-search'), '없는 토픽');
      await tester.pumpAndSettle();
      expect(find.text("'없는 토픽'에 맞는 토픽이 없습니다."), findsOneWidget);
      await tester.tap(find.byTooltip('검색어 지우기'));
      await tester.pumpAndSettle();
      expect(find.text('참여 가능한 토픽 2'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: _key('topic-browse-b1'),
          matching: find.text('참여하기'),
        ),
      );
      await tester.pumpAndSettle();
      expect(server.called('POST', '/api/rooms/b1/join'), hasLength(1));
      expect(find.byType(TopicBrowseScreen), findsNothing);
      expect(opened.single.id, 'b1');
      expect(session.roomById('b1'), isNotNull);
    });

    testWidgets('참여 중인 토픽은 열기로 바로 열고, 비공개 토픽은 자물쇠를 붙인다', (tester) async {
      final server = _FakeServer();
      final session = browseSession(server);
      final opened = <Room>[];
      await _open(
        tester,
        (context) => showTopicBrowse(context, session, onOpenRoom: opened.add),
      );
      await tester.tap(find.text('참여 중인 토픽 2'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: _key('topic-browse-p1'),
          matching: _key('private-topic-lock'),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(of: _key('topic-browse-r1'), matching: find.text('열기')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TopicBrowseScreen), findsNothing);
      expect(opened.single.id, 'r1');
      expect(server.called('POST', '/api/rooms/r1/join'), isEmpty);
    });

    testWidgets('준회원은 참여하기가 꺼져 있다', (tester) async {
      final server = _FakeServer();
      final session = browseSession(server, role: AccountRole.guest);
      await _open(
        tester,
        (context) => showTopicBrowse(context, session, onOpenRoom: (_) {}),
      );
      final join = find.descendant(
        of: _key('topic-browse-b1'),
        matching: find.byType(FilledButton),
      );
      expect(_enabled(tester, join), isFalse);
      expect(find.byTooltip('준회원은 토픽에 직접 참여할 수 없습니다'), findsWidgets);
    });

    testWidgets('모바일(360px): 전체 화면 + 새 토픽 버튼 — 만들면 목록을 닫고 초대 화면을 띄운다', (
      tester,
    ) async {
      final server = _FakeServer();
      final session = browseSession(server);
      server.routes['POST /api/rooms'] = (r) => _json(
        _roomJson(
          id: 'r9',
          name: _body(r)['name'] as String,
          members: [_user('me', '김하나')],
        ),
      );
      final opened = <Room>[];
      await _open(
        tester,
        (context) => showTopicBrowse(context, session, onOpenRoom: opened.add),
        size: _phone,
      );
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('새로운 토픽 생성하기'));
      await tester.pumpAndSettle();
      await tester.enterText(_key('create-topic-name'), '현장 공유');
      await _tap(tester, _key('create-topic-submit'));

      expect(opened.single.id, 'r9');
      expect(find.byType(TopicBrowseScreen), findsNothing);
      expect(find.byType(InviteMembersScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('채팅 헤더의 더보기 메뉴', () {
    Future<void> pumpMenu(
      WidgetTester tester,
      Session session,
      Room room,
    ) async {
      _setSize(tester, _wide);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [RoomOptionsMenu(session: session, room: room)],
            ),
          ),
        ),
      );
    }

    Future<List<String>> menuLabels(WidgetTester tester) async {
      await tester.tap(find.byTooltip('더보기'));
      await tester.pumpAndSettle();
      const all = ['공지', '파일 보기', '링크 보기', '대화 내보내기', '정보 변경하기', '토픽 나가기'];
      final shown =
          [
            for (final label in all)
              if (find.text(label).evaluate().isNotEmpty) label,
          ]..sort(
            (a, b) => tester
                .getTopLeft(find.text(a))
                .dy
                .compareTo(tester.getTopLeft(find.text(b)).dy),
          );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      return shown;
    }

    testWidgets('정보 변경하기는 토픽을 관리할 수 있는 사람에게만, 토픽 나가기 바로 위에', (tester) async {
      final server = _FakeServer();
      // 토픽 관리자가 아닌 정회원.
      final member = _session(server);
      final room = _room(
        extra: {
          'adminIds': ['u2'],
        },
      );
      member.rooms.add(room);
      await pumpMenu(tester, member, room);
      expect(await menuLabels(tester), [
        '공지',
        '파일 보기',
        '링크 보기',
        '대화 내보내기',
        '토픽 나가기',
      ]);

      // 나를 토픽 관리자로 지정하면 그 자리에서 메뉴가 생긴다.
      room.adminIds = ['me'];
      member.notifyListeners();
      await tester.pump();
      expect(await menuLabels(tester), [
        '공지',
        '파일 보기',
        '링크 보기',
        '대화 내보내기',
        '정보 변경하기',
        '토픽 나가기',
      ]);

      await tester.tap(find.byTooltip('더보기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('정보 변경하기'));
      await tester.pumpAndSettle();
      expect(find.byType(TopicSettingsScreen), findsOneWidget);
    });

    testWidgets('팀 관리자는 토픽 관리자가 아니어도 정보 변경하기가 보이고, 그룹은 예전 메뉴 그대로', (
      tester,
    ) async {
      final server = _FakeServer();
      final owner = _session(server, teamOwner: true);
      final room = _room(
        extra: {
          'adminIds': ['u2'],
        },
      );
      owner.rooms.add(room);
      await pumpMenu(tester, owner, room);
      expect(await menuLabels(tester), contains('정보 변경하기'));

      final group = _room(id: 'g1', name: '디자인 그룹', type: 'group');
      owner.rooms.add(group);
      await pumpMenu(tester, owner, group);
      await tester.tap(find.byTooltip('더보기'));
      await tester.pumpAndSettle();
      expect(find.text('정보 변경하기'), findsNothing);
      expect(find.text('공지'), findsNothing);
      expect(find.text('채팅방 나가기'), findsOneWidget);
    });

    testWidgets('멤버 N 버튼: 토픽은 참여 멤버 창, 수는 바로 따라간다', (tester) async {
      final server = _FakeServer();
      final session = _session(server);
      final room = _room();
      session.rooms.add(room);
      await pumpMenu(tester, session, room);
      expect(
        find.descendant(of: find.byTooltip('멤버'), matching: find.text('7')),
        findsOneWidget,
      );
      room.members = room.members.take(3).toList();
      session.notifyListeners();
      await tester.pump();
      expect(
        find.descendant(of: find.byTooltip('멤버'), matching: find.text('3')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('멤버'));
      await tester.pumpAndSettle();
      expect(find.byType(TopicMembersScreen), findsOneWidget);
      expect(find.text('참여 멤버'), findsOneWidget);
    });
  });

  group('참여 멤버', () {
    testWidgets('본인 > 토픽 소유자 > 토픽 관리자 > 팀 소유자 > 관리자 > 정회원 > 준회원 순서와 배지, 검색, Esc로 닫기', (
      tester,
    ) async {
      final server = _FakeServer();
      // u2가 이 토픽을 만든 사람(토픽 소유자)이면서 토픽 관리자다.
      final room = _room(extra: const {'createdBy': 'u2'});
      final session = _session(server, rooms: [room]);
      await _open(
        tester,
        (context) => showTopicMembersDialog(context, session, room),
      );

      final order = ['me', 'u2', 'u3', 'u4', 'u5', 'u6', 'u7'];
      final tops = [
        for (final id in order) tester.getTopLeft(_key('topic-member-$id')).dy,
      ];
      expect(tops, [...tops]..sort(), reason: '행 순서');

      Finder badge(String id, String label) => find.descendant(
        of: _key('topic-member-$id'),
        matching: find.text(label),
      );
      expect(badge('me', '토픽 관리자'), findsOneWidget);
      expect(badge('me', '토픽 소유자'), findsNothing);
      expect(find.text('김하나 (나)'), findsOneWidget);
      // 배지마다 다른 사실이라 여러 개에 해당하면 다 붙는다.
      expect(badge('u2', '토픽 소유자'), findsOneWidget);
      expect(badge('u2', '토픽 관리자'), findsOneWidget);
      // u3는 팀 소유자이면서 계정 관리자 — 지정된 토픽 관리자가 아니므로 '토픽 관리자'는 없다.
      expect(badge('u3', '팀 소유자'), findsOneWidget);
      expect(badge('u3', '관리자'), findsOneWidget);
      expect(badge('u3', '토픽 관리자'), findsNothing);
      expect(badge('u4', '관리자'), findsOneWidget);
      expect(badge('u4', '토픽 관리자'), findsNothing);
      expect(badge('u5', '사원'), findsOneWidget); // 직책
      expect(badge('u7', '준회원'), findsOneWidget);
      for (final label in ['토픽 관리자', '토픽 소유자', '팀 소유자', '관리자', '준회원']) {
        expect(badge('u6', label), findsNothing, reason: label);
      }

      await tester.enterText(_key('topic-members-search'), '사원');
      await tester.pumpAndSettle();
      expect(_key('topic-member-u5'), findsOneWidget);
      expect(_key('topic-member-u6'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TopicMembersScreen), findsNothing);
    });

    testWidgets('내보내기는 내보낼 수 있는 행에만, 확인 후 요청하고 목록에서 뺀다', (tester) async {
      final server = _FakeServer();
      server.routes['POST /api/rooms/r1/kick'] = (r) {
        final ids = (_body(r)['userIds'] as List).cast<String>();
        return _json(
          _roomJson(
            members: [
              for (final m in _members)
                if (!ids.contains(m['id'])) m,
            ],
          ),
        );
      };
      final room = _room();
      final session = _session(server, rooms: [room]);
      await _open(
        tester,
        (context) => showTopicMembersDialog(context, session, room),
      );

      Finder kickOf(String id) => find.descendant(
        of: _key('topic-member-$id'),
        matching: find.text('내보내기'),
      );
      // 나와 다른 토픽 관리자(나는 팀 관리자가 아니다)는 내보낼 수 없다.
      expect(kickOf('me'), findsNothing);
      expect(kickOf('u2'), findsNothing);
      for (final id in ['u3', 'u4', 'u5', 'u6', 'u7']) {
        expect(kickOf(id), findsOneWidget, reason: id);
      }

      await tester.tap(kickOf('u5'));
      await tester.pumpAndSettle();
      expect(
        find.text("'정유나' 님을 이 토픽에서 내보낼까요? 공개 토픽이면 다시 찾아서 참여할 수 있습니다."),
        findsOneWidget,
      );
      // 취소하면 아무 일도 없다.
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(server.called('POST', '/api/rooms/r1/kick'), isEmpty);

      await tester.tap(kickOf('u5'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, '내보내기'),
        ),
      );
      await tester.pumpAndSettle();
      expect(_body(server.called('POST', '/api/rooms/r1/kick').single), {
        'userIds': ['u5'],
      });
      expect(find.text("'정유나' 님을 내보냈습니다."), findsOneWidget);
      expect(_key('topic-member-u5'), findsNothing);
      await _flushToasts(tester);
    });

    testWidgets('토픽 관리자가 아니면 내보내기가 없고, 토픽이 사라지면 창이 닫힌다', (tester) async {
      final server = _FakeServer();
      final room = _room(
        extra: {
          'adminIds': ['u2'],
        },
      );
      final session = _session(server, rooms: [room]);
      await _open(
        tester,
        (context) => showTopicMembersDialog(context, session, room),
      );
      expect(find.text('내보내기'), findsNothing);

      session.handleRoomRemoved(
        const RoomRemovedEvent(roomId: 'r1', reason: 'kicked'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TopicMembersScreen), findsNothing);
    });
  });

  group('토픽 정보 변경하기', () {
    Session settingsSession(_FakeServer server, Room room) {
      server.routes['PATCH /api/rooms/r1'] = (r) => _json(
        _roomJson(
          name: room.name!,
          extra: {
            'viewMode': 'board',
            'description': room.description,
            ..._body(r),
          },
        ),
      );
      server.routes['POST /api/rooms/r1/archive'] = (r) => _json(
        _roomJson(
          name: room.name!,
          extra: {
            'viewMode': 'board',
            'archivedAt': _body(r)['archived'] == true ? 9000 : null,
          },
        ),
      );
      server.routes['DELETE /api/rooms/r1'] = (_) => _json({'ok': true});
      return _session(server, rooms: [room]);
    }

    testWidgets('바꾼 값만 저장하고, 보기 방식은 글로만 보여준다', (tester) async {
      final server = _FakeServer();
      final room = _room(extra: {'viewMode': 'board', 'description': '분기 계획'});
      final session = settingsSession(server, room);
      await _open(
        tester,
        (context) => showTopicSettingsDialog(context, session, room),
      );

      expect(find.text('토픽 정보 변경하기'), findsOneWidget);
      expect(find.text('토픽 설정'), findsOneWidget);
      expect(find.text('토픽 멤버 관리'), findsOneWidget);
      expect(
        find.descendant(
          of: _key('topic-settings-view-mode'),
          matching: find.textContaining('보드 뷰'),
        ),
        findsOneWidget,
      );
      expect(find.text('만든 뒤에는 바꿀 수 없습니다'), findsOneWidget);
      expect(find.byType(SegmentedButton<TopicViewMode>), findsNothing);
      final save = _key('topic-settings-save');
      expect(_enabled(tester, save), isFalse);

      await tester.enterText(_key('topic-settings-name'), ' 새 이름 ');
      // 입력칸이 커서 쪽으로 스크롤을 되돌리는 것까지 끝낸 뒤 아래 스위치로 내려간다.
      await tester.pumpAndSettle();
      await _tap(tester, _key('topic-settings-read-only'));
      expect(find.text('저장하지 않은 변경 사항이 있습니다.'), findsOneWidget);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(_body(server.called('PATCH', '/api/rooms/r1').single), {
        'name': '새 이름',
        'readOnly': true,
      });
      expect(room.name, '새 이름');
      expect(room.readOnly, isTrue);
      expect(find.text('토픽 정보를 저장했습니다.'), findsOneWidget);
      expect(_enabled(tester, save), isFalse);
      await _flushToasts(tester);
    });

    testWidgets('비공개로 바꾸면 안내가 뜨고 자동 초대가 꺼지며, 이름 칸 Enter로 저장한다', (tester) async {
      final server = _FakeServer();
      final room = _room(extra: {'viewMode': 'board', 'autoInvite': true});
      final session = settingsSession(server, room);
      await _open(
        tester,
        (context) => showTopicSettingsDialog(context, session, room),
      );
      expect(
        tester.widget<SwitchListTile>(_key('topic-settings-auto-invite')).value,
        isTrue,
      );
      await _tap(tester, _key('topic-settings-private'));
      expect(_key('topic-settings-visibility-notice'), findsOneWidget);
      expect(find.textContaining('비공개로 바꾸면 이후에는 초대된 멤버만'), findsOneWidget);
      final autoInvite = tester.widget<SwitchListTile>(
        _key('topic-settings-auto-invite'),
      );
      expect(autoInvite.value, isFalse);
      expect(autoInvite.onChanged, isNull);
      expect(find.text('비공개 토픽은 자동 초대를 쓸 수 없습니다'), findsOneWidget);

      await _tap(tester, _key('topic-settings-quiet-leave'));
      await _tap(tester, _key('topic-settings-name'));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(_body(server.called('PATCH', '/api/rooms/r1').single), {
        'isPublic': false,
        'autoInvite': false,
        'quietLeave': true,
      });
      await _flushToasts(tester);
    });

    testWidgets('이름을 비우면 저장하지 않고 알린다', (tester) async {
      final server = _FakeServer();
      final room = _room();
      final session = settingsSession(server, room);
      await _open(
        tester,
        (context) => showTopicSettingsDialog(context, session, room),
      );
      await tester.enterText(_key('topic-settings-name'), '   ');
      await tester.pump();
      await tester.tap(_key('topic-settings-save'));
      await tester.pumpAndSettle();
      expect(find.text('토픽 이름을 입력하세요.'), findsOneWidget);
      expect(server.called('PATCH', '/api/rooms/r1'), isEmpty);
    });

    testWidgets('토픽 보관은 확인 후 요청하고, 삭제는 이름을 그대로 입력해야 한다', (tester) async {
      final server = _FakeServer();
      final room = _room(extra: {'viewMode': 'board'});
      final session = settingsSession(server, room);
      await _open(
        tester,
        (context) => showTopicSettingsDialog(context, session, room),
      );

      await _tap(tester, _key('topic-settings-archive'));
      final archiveDialog = find.byType(AlertDialog);
      expect(
        find.descendant(
          of: archiveDialog,
          matching: find.textContaining("목록의 '보관된 토픽'으로 옮겨지고"),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: archiveDialog,
          matching: find.widgetWithText(FilledButton, '보관'),
        ),
      );
      await tester.pumpAndSettle();
      expect(_body(server.called('POST', '/api/rooms/r1/archive').single), {
        'archived': true,
      });
      expect(room.isArchived, isTrue);
      expect(find.text('토픽을 보관했습니다.'), findsOneWidget);
      expect(
        find.descendant(
          of: _key('topic-settings-archive'),
          matching: find.text('보관 해제'),
        ),
        findsOneWidget,
      );
      await _flushToasts(tester);

      await _tap(tester, _key('topic-settings-delete'));
      expect(find.text('삭제된 토픽의 메시지와 파일은 복구되지 않습니다.'), findsOneWidget);
      final confirm = _key('topic-delete-confirm');
      expect(_enabled(tester, confirm), isFalse);
      await tester.enterText(_key('topic-delete-confirm-name'), '마케팅');
      await tester.pump();
      expect(_enabled(tester, confirm), isFalse);
      await tester.enterText(_key('topic-delete-confirm-name'), '마케팅 회의');
      await tester.pump();
      expect(_enabled(tester, confirm), isTrue);
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      expect(server.called('DELETE', '/api/rooms/r1'), hasLength(1));
      expect(find.byType(TopicSettingsScreen), findsNothing);
      expect(find.text("'마케팅 회의' 토픽을 삭제했습니다."), findsOneWidget);
      expect(session.roomById('r1'), isNull);
      await _flushToasts(tester);
    });

    testWidgets('토픽 관리자 지정: 정회원 이상만, 한 명 이상 — 나를 빼고 저장하면 창이 닫힌다', (
      tester,
    ) async {
      final server = _FakeServer();
      server.routes['PUT /api/rooms/r1/admins'] = (r) =>
          _json(_roomJson(extra: {'adminIds': _body(r)['userIds']}));
      final room = _room();
      final session = _session(server, rooms: [room]);
      await _open(
        tester,
        (context) => showTopicSettingsDialog(
          context,
          session,
          room,
          initialTab: TopicSettingsTab.members,
        ),
      );

      expect(find.text('토픽 관리자 지정'), findsOneWidget);
      expect(_key('topic-admin-u7'), findsNothing); // 준회원
      expect(_checkboxIn(tester, _key('topic-admin-me')).value, isTrue);
      expect(_checkboxIn(tester, _key('topic-admin-u2')).value, isTrue);
      expect(_checkboxIn(tester, _key('topic-admin-u5')).value, isFalse);
      final save = _key('topic-admins-save');
      expect(_enabled(tester, save), isFalse);

      await tester.tap(_key('topic-admin-me'));
      await tester.pump();
      expect(find.text('나를 빼면 저장한 뒤 이 토픽을 관리할 수 없습니다.'), findsOneWidget);
      expect(_enabled(tester, save), isTrue);

      await tester.tap(_key('topic-admin-u2'));
      await tester.pump();
      expect(find.text('토픽 관리자를 한 명 이상 지정하세요.'), findsOneWidget);
      expect(_enabled(tester, save), isFalse);

      await tester.tap(_key('topic-admin-u5'));
      await tester.pump();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(_body(server.called('PUT', '/api/rooms/r1/admins').single), {
        'userIds': ['u5'],
      });
      expect(room.adminIds, ['u5']);
      // 스스로 관리 권한을 내려놓았으니 창을 닫는다("권한이 없어졌다" 안내 없이).
      expect(find.byType(TopicSettingsScreen), findsNothing);
      expect(find.text('토픽 관리자를 저장했습니다.'), findsOneWidget);
      expect(find.textContaining('권한이 없어져'), findsNothing);
      await _flushToasts(tester);
    });

    testWidgets('다른 사람이 내 관리 권한을 없애면 창을 닫고 알린다', (tester) async {
      final server = _FakeServer();
      final room = _room();
      final session = _session(server, rooms: [room]);
      await _open(
        tester,
        (context) => showTopicSettingsDialog(context, session, room),
      );
      room.adminIds = ['u2'];
      session.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(TopicSettingsScreen), findsNothing);
      expect(find.text('토픽을 관리할 수 있는 권한이 없어져 창을 닫았습니다.'), findsOneWidget);
      await _flushToasts(tester);
    });

    testWidgets('멤버 내보내기: 모든 멤버 선택은 내보낼 수 있는 멤버만 고르고, 확인 후 한 번에 보낸다', (
      tester,
    ) async {
      final server = _FakeServer();
      server.routes['POST /api/rooms/r1/kick'] = (r) {
        final ids = (_body(r)['userIds'] as List).cast<String>();
        return _json(
          _roomJson(
            members: [
              for (final m in _members)
                if (!ids.contains(m['id'])) m,
            ],
          ),
        );
      };
      final room = _room();
      final session = _session(server, rooms: [room]);
      await _open(
        tester,
        (context) => showTopicSettingsDialog(
          context,
          session,
          room,
          initialTab: TopicSettingsTab.members,
        ),
      );
      await tester.tap(find.text('멤버 내보내기'));
      await tester.pumpAndSettle();

      expect(_key('topic-kick-me'), findsNothing);
      final u2 = _checkboxIn(tester, _key('topic-kick-u2'));
      expect(u2.onChanged, isNull); // 다른 토픽 관리자
      expect(find.text('선택한 멤버 0명'), findsOneWidget);
      expect(_enabled(tester, _key('topic-kick-submit')), isFalse);

      await tester.tap(_key('topic-kick-select-all'));
      await tester.pump();
      expect(find.text('선택한 멤버 5명'), findsOneWidget);
      expect(_checkboxIn(tester, _key('topic-kick-u2')).value, isFalse);

      // 한 명 빼면 모든 멤버 선택이 "일부"로 바뀐다.
      await tester.tap(_key('topic-kick-u6'));
      await tester.pump();
      expect(find.text('선택한 멤버 4명'), findsOneWidget);
      expect(_checkboxIn(tester, _key('topic-kick-select-all')).value, isNull);

      await tester.tap(_key('topic-kick-submit'));
      await tester.pumpAndSettle();
      expect(
        find.text('선택한 멤버 4명을 이 토픽에서 내보낼까요? 공개 토픽이면 다시 찾아서 참여할 수 있습니다.'),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, '내보내기'),
        ),
      );
      await tester.pumpAndSettle();
      expect(_body(server.called('POST', '/api/rooms/r1/kick').single), {
        'userIds': ['u3', 'u4', 'u5', 'u7'],
      });
      expect(find.text('멤버 4명을 내보냈습니다.'), findsOneWidget);
      expect(find.text('선택한 멤버 0명'), findsOneWidget);
      expect(_key('topic-kick-u5'), findsNothing);
      expect(_key('topic-kick-u6'), findsOneWidget);
      await _flushToasts(tester);
    });

    testWidgets('팀 관리자는 다른 토픽 관리자도 내보낼 수 있다', (tester) async {
      final server = _FakeServer();
      final room = _room();
      final session = _session(server, teamOwner: true, rooms: [room]);
      await _open(
        tester,
        (context) => showTopicSettingsDialog(
          context,
          session,
          room,
          initialTab: TopicSettingsTab.members,
        ),
      );
      await tester.tap(find.text('멤버 내보내기'));
      await tester.pumpAndSettle();
      expect(_checkboxIn(tester, _key('topic-kick-u2')).onChanged, isNotNull);
      await tester.tap(_key('topic-kick-select-all'));
      await tester.pump();
      expect(find.text('선택한 멤버 6명'), findsOneWidget);
    });

    testWidgets('토픽이 삭제·내보내짐으로 사라지면 창을 닫는다', (tester) async {
      final server = _FakeServer();
      final room = _room();
      final session = _session(server, rooms: [room]);
      await _open(
        tester,
        (context) => showTopicSettingsDialog(context, session, room),
      );
      session.handleRoomRemoved(
        const RoomRemovedEvent(roomId: 'r1', reason: 'deleted', name: '마케팅 회의'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TopicSettingsScreen), findsNothing);
    });

    testWidgets('다른 관리자가 보관·해제하면 보관 칸이 바로 바뀐다', (tester) async {
      final server = _FakeServer();
      final room = _room();
      final session = _session(server, rooms: [room]);
      await _open(
        tester,
        (context) => showTopicSettingsDialog(context, session, room),
      );
      Finder archiveLabel(String label) => find.descendant(
        of: _key('topic-settings-archive'),
        matching: find.text(label),
      );
      expect(archiveLabel('토픽 보관'), findsOneWidget);

      // room:created로 같은 방 객체에 반영된 다른 관리자의 보관(창을 연 뒤 첫 변경).
      room.archivedAt = DateTime(2026);
      session.notifyListeners();
      await tester.pumpAndSettle();
      expect(archiveLabel('보관 해제'), findsOneWidget);

      room.archivedAt = null;
      session.notifyListeners();
      await tester.pumpAndSettle();
      expect(archiveLabel('토픽 보관'), findsOneWidget);
    });

    testWidgets('다른 관리자가 바꾼 이름은 칸이 따라가고, 내 저장이 그 이름을 되돌리지 않는다', (tester) async {
      final server = _FakeServer();
      final room = _room();
      final session = settingsSession(server, room);
      await _open(
        tester,
        (context) => showTopicSettingsDialog(context, session, room),
      );
      // 창을 연 뒤 첫 변경 — 예전엔 비교 기준이 이때 처음 잡혀서 이 변경을 놓쳤다.
      room.name = '다른 관리자가 바꾼 이름';
      session.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(_key('topic-settings-name')).controller!.text,
        '다른 관리자가 바꾼 이름',
      );
      expect(_enabled(tester, _key('topic-settings-save')), isFalse);

      await _tap(tester, _key('topic-settings-read-only'));
      await tester.tap(_key('topic-settings-save'));
      await tester.pumpAndSettle();
      expect(_body(server.called('PATCH', '/api/rooms/r1').single), {
        'readOnly': true,
      });
      await _flushToasts(tester);
    });

    testWidgets('상관없는 변경(읽기 전용 등)이 와도 입력 중인 이름·설명 끝의 띄어쓰기는 지워지지 않는다', (
      tester,
    ) async {
      final server = _FakeServer();
      final room = _room(extra: {'description': '분기 계획'});
      final session = settingsSession(server, room);
      await _open(
        tester,
        (context) => showTopicSettingsDialog(context, session, room),
      );
      await tester.enterText(_key('topic-settings-name'), '마케팅 회의 ');
      await tester.enterText(_key('topic-settings-description'), '분기 계획 ');
      await tester.pumpAndSettle();

      // 다른 관리자가 읽기 전용만 켰다.
      room.readOnly = true;
      session.notifyListeners();
      await tester.pumpAndSettle();

      TextEditingController controllerOf(String key) =>
          tester.widget<TextField>(_key(key)).controller!;
      expect(controllerOf('topic-settings-name').text, '마케팅 회의 ');
      expect(controllerOf('topic-settings-description').text, '분기 계획 ');
      // 손대지 않은 스위치는 따라간다.
      expect(
        tester.widget<SwitchListTile>(_key('topic-settings-read-only')).value,
        isTrue,
      );
    });

    testWidgets('멤버 내보내기: 검색으로 가려진 멤버도 고른 채로 남아 함께 내보낸다', (tester) async {
      final server = _FakeServer();
      server.routes['POST /api/rooms/r1/kick'] = (r) => _json(_roomJson());
      final room = _room();
      final session = _session(server, rooms: [room]);
      await _open(
        tester,
        (context) => showTopicSettingsDialog(
          context,
          session,
          room,
          initialTab: TopicSettingsTab.members,
        ),
      );
      await tester.tap(find.text('멤버 내보내기'));
      await tester.pumpAndSettle();

      await tester.tap(_key('topic-kick-u3'));
      await tester.pump();
      await tester.enterText(_key('topic-manage-search'), '정유나');
      await tester.pumpAndSettle();
      expect(_key('topic-kick-u3'), findsNothing);
      await tester.tap(_key('topic-kick-u5'));
      await tester.pump();
      expect(find.text('선택한 멤버 2명'), findsOneWidget);

      await tester.tap(_key('topic-kick-submit'));
      await tester.pumpAndSettle();
      expect(find.textContaining('선택한 멤버 2명을 이 토픽에서'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, '내보내기'),
        ),
      );
      await tester.pumpAndSettle();
      expect(_body(server.called('POST', '/api/rooms/r1/kick').single), {
        'userIds': ['u3', 'u5'],
      });
      await _flushToasts(tester);
    });
  });

  group('읽기 전용·보관된 토픽의 입력칸', () {
    Future<List<String>> pumpBar(
      WidgetTester tester,
      Session session,
      Room room, {
      Sticker? sticker,
    }) async {
      final calls = <String>[];
      _setSize(tester, const Size(800, 600));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ChatInputBar(
                controller: session.controllerFor(room),
                session: session,
                room: room,
                pendingSticker: sticker,
                stickerPickerOpen: false,
                stickerPickerGroupId: 'group',
                onToggleStickerPicker: () => calls.add('toggle'),
                onStickerConsumed: () => calls.add('consumed'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return calls;
    }

    const readOnlyHint = '읽기 전용 토픽 — 토픽 관리자만 글을 쓸 수 있어요';
    const archivedHint = '보관된 토픽 — 토픽 관리자만 글을 쓸 수 있어요';
    final notice = _key('chat-input-read-only-notice');

    testWidgets('멤버: 읽기 전용이면 입력칸 대신 안내만, 보관되면 보관 안내', (tester) async {
      final server = _FakeServer();
      final room = _room(
        extra: {
          'readOnly': true,
          'adminIds': ['u2'],
        },
      );
      final session = _session(server, rooms: [room]);
      await pumpBar(tester, session, room);
      expect(notice, findsOneWidget);
      expect(find.textContaining('읽기 전용 토픽입니다.'), findsOneWidget);
      expect(find.textContaining('토픽 관리자만 글을 쓸 수 있습니다.'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('보내기'), findsNothing);
      expect(find.byTooltip('이모티콘'), findsNothing);

      room.archivedAt = DateTime(2026);
      session.notifyListeners();
      await tester.pump();
      expect(find.textContaining('보관된 토픽입니다.'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('토픽 관리자·팀 관리자: 입력칸 위에 얇은 안내만 붙는다', (tester) async {
      final server = _FakeServer();
      final room = _room(extra: {'readOnly': true});
      final admin = _session(server, rooms: [room]);
      await pumpBar(tester, admin, room);
      expect(notice, findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text(readOnlyHint), findsOneWidget);

      final archived = _room(
        id: 'r2',
        extra: {
          'archivedAt': 5000,
          'adminIds': ['u2'],
        },
      );
      final owner = _session(server, teamOwner: true, rooms: [archived]);
      await pumpBar(tester, owner, archived);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text(archivedHint), findsOneWidget);
    });

    testWidgets('보통 토픽·그룹은 그대로(안내 없음)', (tester) async {
      final server = _FakeServer();
      final room = _room(
        extra: {
          'adminIds': ['u2'],
        },
      );
      final session = _session(server, rooms: [room]);
      await pumpBar(tester, session, room);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text(readOnlyHint), findsNothing);
      expect(notice, findsNothing);

      // 그룹은 읽기 전용 값이 와도 토픽 규칙과 무관하다.
      final group = _room(
        id: 'g1',
        type: 'group',
        extra: {
          'readOnly': true,
          'adminIds': ['u2'],
        },
      );
      session.rooms.add(group);
      await pumpBar(tester, session, group);
      expect(find.byType(TextField), findsOneWidget);
      expect(notice, findsNothing);
    });

    testWidgets('쓰는 중에 읽기 전용이 되면 입력칸이 사라지고, 이모티콘·끌어다 놓기로도 보내지 않는다', (
      tester,
    ) async {
      final server = _FakeServer();
      final room = _room(
        extra: {
          'adminIds': ['u2'],
        },
      );
      final session = _session(server, rooms: [room]);
      final calls = await pumpBar(
        tester,
        session,
        room,
        sticker: const Sticker('grin', '😄', '활짝 웃음'),
      );
      expect(find.byType(TextField), findsOneWidget);

      room.readOnly = true;
      session.notifyListeners();
      await tester.pump();
      await tester.pump();
      expect(notice, findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      // 부모가 들고 있던 이모티콘 미리보기를 치우게 한다.
      expect(calls, contains('consumed'));

      final bar = tester.state<ChatInputBarState>(find.byType(ChatInputBar));
      final dir = Directory.systemTemp.createTempSync('topic_ui_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}a.txt')
        ..writeAsStringSync('hi');
      const full = '읽기 전용 토픽입니다. 토픽 관리자만 글을 쓸 수 있습니다.';
      expect(find.text(full), findsOneWidget); // 안내 줄
      bar.addDroppedFiles([file]);
      await tester.pump();
      expect(server.called('POST', '/api/upload'), isEmpty);
      expect(find.text(full), findsNWidgets(2)); // 안내 줄 + 토스트
      await _flushToasts(tester);

      // 다시 풀리면 입력칸이 돌아온다.
      room.readOnly = false;
      session.notifyListeners();
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      expect(notice, findsNothing);
    });

    testWidgets('아래 버튼 줄: 좁으면 Enter 안내를 숨겨 넘치지 않고 보내기 버튼이 보인다', (tester) async {
      final server = _FakeServer();
      final room = _room();
      final session = _session(server, rooms: [room]);
      const hint = 'Shift + Enter 로 줄바꿈';
      await pumpBar(tester, session, room);
      // 넓으면(PC 창) 안내가 보내기 버튼 옆에 보인다 — 안내는 Windows에서만 그린다.
      expect(
        find.text(hint),
        Platform.isWindows ? findsOneWidget : findsNothing,
      );

      // 휴대폰 폭 — 예전엔 고정 폭(320) 기준이라 안내가 남아 줄이 넘치고 보내기 버튼이 밀려났다.
      for (final width in [360.0, 393.0, 412.0]) {
        _setSize(tester, Size(width, 600));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$width');
        final send = tester.getRect(find.byTooltip('보내기'));
        expect(send.right, lessThanOrEqualTo(width), reason: '$width');
        final shown = find.text(hint).evaluate().isNotEmpty;
        if (shown) {
          // 보일 때는 통째로, 보내기 버튼 왼쪽에 겹치지 않게.
          expect(
            tester.getRect(find.text(hint)).right,
            lessThanOrEqualTo(send.left),
          );
        }
      }
    });

    testWidgets('화면 캡처 업로드: 보드 뷰·내가 쓸 수 없는 토픽은 공유 대화방에서 뺀다', (tester) async {
      final server = _FakeServer();
      final start = _room(id: 'r1', name: '가 시작 토픽');
      final rooms = [
        start,
        _room(id: 'board', name: '나 보드', extra: {'viewMode': 'board'}),
        _room(
          id: 'ro',
          name: '다 읽기 전용(멤버)',
          extra: {
            'readOnly': true,
            'adminIds': ['u2'],
          },
        ),
        _room(
          id: 'ar',
          name: '라 보관(멤버)',
          extra: {
            'archivedAt': 5000,
            'adminIds': ['u2'],
          },
        ),
        _room(id: 'ro-admin', name: '마 읽기 전용(관리자)', extra: {'readOnly': true}),
        _room(id: 'g1', name: '바 그룹', type: 'group'),
      ];
      final session = _session(server, rooms: rooms);
      final dir = Directory.systemTemp.createTempSync('capture_ui_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}capture.png')
        ..writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
            'YAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
          ),
        );
      await _open(
        tester,
        (context) => showCaptureUploadDialog(
          context,
          session: session,
          initialRoom: start,
          file: file,
        ),
      );
      final dropdown = tester.widget<DropdownButton<Room>>(
        find.byType(DropdownButton<Room>),
      );
      expect(
        [for (final item in dropdown.items!) item.value!.id],
        ['r1', 'ro-admin', 'g1'],
      );
      expect(dropdown.value?.id, 'r1');
    });
  });

  group('휴대폰에서 키보드가 올라와도(검색 중) 넘치지 않는다', () {
    /// 360×640 휴대폰에 키보드(300)가 올라온 상태.
    void keyboardUp(WidgetTester tester) {
      _setSize(tester, const Size(360, 640));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
    }

    testWidgets('멤버 초대하기 — 목록까지 스크롤해서 고를 수 있다', (tester) async {
      final server = _FakeServer();
      server.routes['GET /api/teams/t1/members'] = (_) =>
          _json([for (var i = 0; i < 12; i++) _user('x$i', '팀원$i')]);
      final room = Room.fromJson(_roomJson(members: [_user('me', '김하나')]));
      final session = _session(server, rooms: [room]);
      keyboardUp(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: InviteMembersScreen(session: session, room: room),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final row = _key('invite-member-x0');
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('초대하기 (1)'), findsOneWidget);
      // 선택 칩이 생겨도 넘치지 않는다.
      expect(tester.takeException(), isNull);
      expect(find.widgetWithText(InputChip, '팀원0'), findsOneWidget);
    });

    testWidgets('토픽 정보 변경하기 — 토픽 멤버 관리 두 목록', (tester) async {
      final server = _FakeServer();
      final room = _room();
      final session = _session(server, rooms: [room]);
      keyboardUp(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: TopicSettingsScreen(
            session: session,
            room: room,
            initialTab: TopicSettingsTab.members,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // 목록이 눌려 사라지지 않고, 스크롤해서 고를 수 있다.
      await tester.ensureVisible(_key('topic-admin-u2'));
      await tester.pumpAndSettle();
      await tester.tap(_key('topic-admin-u2'));
      await tester.pump();
      expect(_checkboxIn(tester, _key('topic-admin-u2')).value, isFalse);

      await tester.tap(find.text('멤버 내보내기'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('토픽 설정'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('모바일 대화 화면: 이름·배지가 바로 바뀌고, 토픽이 사라지면 목록으로 돌아간다', (tester) async {
    final server = _FakeServer();
    final room = _room(
      extra: {
        'adminIds': ['u2'],
      },
    );
    final session = _session(server, rooms: [room]);
    _setSize(tester, const Size(600, 800));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(session: session, room: room),
                  ),
                ),
                child: const Text('목록'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('목록'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(_key('chat-header-read-only'), findsNothing);

    room.readOnly = true;
    session.notifyListeners();
    await tester.pump();
    expect(_key('chat-header-read-only'), findsOneWidget);

    room.archivedAt = DateTime(2026);
    room.name = '새 이름';
    session.notifyListeners();
    await tester.pump();
    expect(_key('chat-header-archived'), findsOneWidget);
    expect(_key('chat-header-read-only'), findsNothing);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('새 이름')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    session.handleRoomRemoved(
      const RoomRemovedEvent(roomId: 'r1', reason: 'deleted', name: '새 이름'),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsNothing);
    expect(find.text('목록'), findsOneWidget);
  });

  testWidgets('모바일 대화 화면: 좁은 앱바에서는 상태 배지를 이름 아래 줄로 내려 이름 자리를 지킨다', (
    tester,
  ) async {
    final server = _FakeServer();
    final room = _room(
      name: '주간 보고 모음',
      extra: {
        'isPublic': false,
        'archivedAt': 5000,
        'adminIds': ['u2'],
      },
    );
    final session = _session(server, rooms: [room]);
    _setSize(tester, _phone);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(session: session, room: room),
                  ),
                ),
                child: const Text('목록'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('목록'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final name = find.descendant(
      of: find.byType(AppBar),
      matching: find.text('주간 보고 모음'),
    );
    final badge = _key('chat-header-archived');
    // 배지는 이름 옆이 아니라 아래 줄에, 글자('보관됨')까지 보이게.
    expect(
      tester.getRect(badge).top,
      greaterThanOrEqualTo(tester.getRect(name).bottom - 1),
    );
    expect(
      find.descendant(of: badge, matching: find.text('보관됨')),
      findsOneWidget,
    );
    expect(_key('private-topic-lock'), findsOneWidget);
  });

  testWidgets('마지막 토픽 관리자가 나가려다 막히면, 그 안내와 함께 토픽 관리자 지정으로 안내한다', (
    tester,
  ) async {
    final server = _FakeServer();
    const refusal = '토픽 관리자는 다른 멤버를 토픽 관리자로 지정한 뒤에 나갈 수 있습니다.';
    server.routes['POST /api/rooms/r1/leave'] = (_) =>
        _json({'error': refusal}, 400);
    final room = _room(
      extra: {
        'adminIds': ['me'],
      },
    );
    final session = _session(server, rooms: [room]);
    _setSize(tester, _wide);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [RoomOptionsMenu(session: session, room: room)],
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('더보기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('토픽 나가기'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '나가기'));
    await tester.pumpAndSettle();

    expect(server.called('POST', '/api/rooms/r1/leave'), hasLength(1));
    expect(session.roomById('r1'), isNotNull);
    expect(find.text('토픽을 나갈 수 없습니다'), findsOneWidget);
    expect(find.text(refusal), findsOneWidget);
    await tester.tap(find.text('토픽 관리자 지정하기'));
    await tester.pumpAndSettle();

    expect(find.byType(TopicSettingsScreen), findsOneWidget);
    // "토픽 멤버 관리" 탭의 토픽 관리자 지정이 바로 보인다.
    expect(find.text('토픽 관리자 지정'), findsOneWidget);
    expect(_key('topic-admin-u2'), findsOneWidget);
  });

  testWidgets('휴대폰(360px)에서도 넘치지 않는다 — 참여 멤버·토픽 정보 변경하기 두 탭', (tester) async {
    final server = _FakeServer();
    final room = _room(
      extra: {'viewMode': 'board', 'readOnly': true, 'archivedAt': 5000},
    );
    final session = _session(server, rooms: [room]);
    await _open(
      tester,
      (context) => showTopicMembersDialog(context, session, room),
      size: _phone,
    );
    expect(find.byType(Dialog), findsNothing);
    expect(find.widgetWithText(AppBar, '참여 멤버'), findsOneWidget);
    expect(tester.takeException(), isNull);
    Navigator.of(tester.element(find.byType(TopicMembersScreen))).pop();
    await tester.pumpAndSettle();

    final context = tester.element(find.byKey(const ValueKey('host-open')));
    unawaited(showTopicSettingsDialog(context, session, room));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.widgetWithText(AppBar, '토픽 정보 변경하기'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.drag(
      find
          .descendant(
            of: find.byType(TopicSettingsScreen),
            matching: find.byType(SingleChildScrollView),
          )
          .first,
      const Offset(0, -2000),
    );
    await tester.pumpAndSettle();
    expect(find.text('토픽 삭제'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('토픽 멤버 관리'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('멤버 내보내기'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
