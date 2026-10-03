import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/chat_screen.dart';
import 'package:client/screens/desktop_home_screen.dart';
import 'package:client/screens/my_profile_dialog.dart';
import 'package:client/screens/room_list_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/services/typing_gate.dart';
import 'package:client/widgets/favorite_star.dart';
import 'package:client/widgets/room_avatar.dart';
import 'package:client/widgets/room_options_menu.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 채팅 개편의 화면 연결(UI-2) — 사이드바·모바일 탭의 진입점(새 그룹채팅 만들기·채팅 시작하기),
/// 채팅 구역 맨 위에 고정된 "나와의 대화"(PC·모바일), 내 프로필의 "나와의 대화" 버튼, ⋮ 메뉴(그룹 "정보
/// 변경"·"나에게만 이름 변경", 나와의 대화는 파일·링크·내보내기만), 대화 헤더의 설명 한 줄과 나와의 대화 헤더.

/// 방을 열 때 부르는 "그 방 알림 지우기"(OS 알림 플러그인)를 조용히 넘긴다.
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

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _user(String id, String name, {String role = 'member'}) =>
    {'id': id, 'username': id, 'name': name, 'role': role};

final _me = _user('me', '나');
final _kim = _user('u2', '김철수');
final _lee = _user('u3', '이영희');

Map<String, dynamic> _roomJson(
  String id, {
  String type = 'dm',
  String? name,
  List<Map<String, dynamic>>? members,
  Map<String, dynamic> extra = const {},
  int minute = 0,
}) => {
  'id': id,
  'teamId': 't1',
  'type': type,
  'name': name,
  'members': members ?? [_me, _kim],
  'createdAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
  'lastActivityAt': DateTime(2026, 9, 29, 9, minute).millisecondsSinceEpoch,
  ...extra,
};

Map<String, dynamic> _selfJson({Map<String, dynamic> extra = const {}}) =>
    _roomJson(
      'self1',
      members: [_me],
      extra: {'isSelf': true, 'lastMessagePreview': '장보기 목록', ...extra},
    );

/// 나와의 대화 · 1:1 둘(김철수·이영희) · 설명 있는 그룹 · 설명 있는 토픽.
List<Room> _rooms({
  int selfUnread = 0,
  bool withSelf = true,
  bool selfFavorite = false,
}) => [
  if (withSelf)
    Room.fromJson(
      _selfJson(extra: {'unreadCount': selfUnread, 'favorite': selfFavorite}),
    ),
  Room.fromJson(_roomJson('dm1', minute: 30, extra: {'unreadCount': 2})),
  Room.fromJson(_roomJson('dm2', members: [_me, _lee], minute: 20)),
  Room.fromJson(
    _roomJson(
      'g1',
      type: 'group',
      name: '점심 모임',
      members: [_me, _kim, _lee],
      extra: {'description': '매일 점심 메뉴 정하기'},
    ),
  ),
  Room.fromJson(
    _roomJson(
      'r1',
      type: 'topic',
      name: '공지',
      members: [_me, _kim, _lee],
      extra: {'description': '회사 공지와 소식', 'isPublic': true},
    ),
  ),
];

/// 가짜 서버 — 요청을 전부 남기고, 나와의 대화 열기(POST /rooms/self)와 팀 멤버 목록에 답한다.
class _Server {
  final requests = <http.Request>[];

  late final client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'POST' && path == '/api/rooms/self') {
      return _json(_selfJson());
    }
    if (request.method == 'GET' && path == '/api/teams/t1/members') {
      return _json([_me, _kim, _lee]);
    }
    // 채팅 시작하기 — 이영희와는 이미 1:1(dm2)이 있어서 서버가 그 방을 그대로 돌려준다.
    if (request.method == 'POST' && path == '/api/rooms/dm') {
      final target = (jsonDecode(request.body) as Map)['targetUserId'];
      return target == 'u3'
          ? _json(_roomJson('dm2', members: [_me, _lee], minute: 20))
          : _json(_roomJson('dm-$target', members: [_me, _kim]), 201);
    }
    // 새 그룹채팅 만들기 — 받은 이름·멤버로 만든 방.
    if (request.method == 'POST' && path == '/api/rooms') {
      final body = jsonDecode(request.body) as Map;
      final ids = (body['memberIds'] as List).cast<String>();
      return _json(
        _roomJson(
          'g-new',
          type: 'group',
          name: body['name'] as String?,
          members: [
            _me,
            for (final u in [_kim, _lee])
              if (ids.contains(u['id'])) u,
          ],
        ),
        201,
      );
    }
    return _json(<Object>[]);
  });

  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
}

Session _session(
  _Server server, {
  AccountRole role = AccountRole.member,
  List<Room>? rooms,
  bool inTeam = true,
}) {
  final session = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: server.client,
  );
  session.userId = 'me';
  session.name = '나대리';
  session.accountRole = role;
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  if (inTeam) session.currentTeam = team;
  session.rooms.addAll(rooms ?? _rooms());
  return session;
}

Finder _byTypeName(String name) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

Finder _inSidebar(Finder f) =>
    find.descendant(of: _byTypeName('_Sidebar'), matching: f);

Finder get _selfRow => find.byKey(const ValueKey('self-room-row'));

Finder _inSelfRow(Finder f) => find.descendant(of: _selfRow, matching: f);

/// PC 대화 패널 위 헤더(⋮ 메뉴가 든 줄의 테두리 상자).
Finder get _desktopHeader => find
    .ancestor(
      of: find.byType(RoomOptionsMenu),
      matching: find.byType(Container),
    )
    .first;

Future<void> _pumpDesktop(WidgetTester tester, Session session) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(home: DesktopHomeScreen(session: session)),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Future<void> _pumpMobile(WidgetTester tester, Session session) async {
  // 휴대폰 폭이되, 테스트 글꼴(네모 글자)로도 대화 화면 입력칸이 넘치지 않을 만큼.
  tester.view.physicalSize = const Size(520, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: RoomListScreen(session: session)));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

/// 하단 탭(토픽·그룹채팅·채팅·멤버·더보기)을 고른다.
Future<void> _mobileTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

/// ⋮ 메뉴만 따로 올린다(모바일 대화 화면의 앱바와 같은 자리).
Future<void> _pumpMenu(WidgetTester tester, Session session, Room room) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          actions: [RoomOptionsMenu(session: session, room: room)],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('더보기'));
  await tester.pumpAndSettle();
}

/// 떠 있는 팝업 메뉴 항목의 글자들(위에서부터).
List<String> _menuLabels(WidgetTester tester) => find
    .descendant(
      of: find.byWidgetPredicate((w) => w is PopupMenuItem<void>),
      matching: find.byType(Text),
    )
    .evaluate()
    .map((e) => (e.widget as Text).data ?? '')
    .toList();

/// 화면을 내리고 남은 토스트 타이머까지 흘려보낸다.
Future<void> _finish(WidgetTester tester) async {
  TypingGate.instance.reset();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  late _Server server;
  setUp(() => server = _Server());

  group('진입점', () {
    testWidgets('PC: 그룹채팅 [+]는 새 그룹채팅 만들기, 채팅 [+]는 채팅 시작하기를 연다', (
      tester,
    ) async {
      final session = _session(server);
      await _pumpDesktop(tester, session);

      await tester.tap(_inSidebar(find.byTooltip('새 그룹채팅')));
      await tester.pumpAndSettle();
      expect(find.text('새 그룹채팅 만들기'), findsWidgets);
      Navigator.of(tester.element(find.text('새 그룹채팅 만들기').first)).pop();
      await tester.pumpAndSettle();
      expect(find.text('새 그룹채팅 만들기'), findsNothing);

      // 채팅 [+] — 예전 '새 대화'가 아니라 '채팅 시작하기'.
      expect(_inSidebar(find.byTooltip('새 대화')), findsNothing);
      await tester.tap(_inSidebar(find.byTooltip('채팅 시작하기')));
      await tester.pumpAndSettle();
      expect(find.text('채팅 시작하기'), findsWidgets);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('모바일: 그룹채팅 탭 + 는 새 그룹채팅 만들기, 채팅 탭 + 는 채팅 시작하기', (tester) async {
      final session = _session(server);
      await _pumpMobile(tester, session);

      await _mobileTab(tester, '그룹채팅');
      final groupFab = tester.widget<FloatingActionButton>(
        find.byType(FloatingActionButton),
      );
      expect(groupFab.tooltip, '새 그룹채팅');
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('새 그룹채팅 만들기'), findsWidgets);
      Navigator.of(tester.element(find.text('새 그룹채팅 만들기').first)).pop();
      await tester.pumpAndSettle();

      await _mobileTab(tester, '채팅');
      final chatFab = tester.widget<FloatingActionButton>(
        find.byType(FloatingActionButton),
      );
      expect(chatFab.tooltip, '채팅 시작하기');
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('채팅 시작하기'), findsWidgets);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('PC: 채팅 시작하기로 고른 1:1(이미 있는 방)과 새 그룹채팅이 오른쪽 패널에 열린다', (
      tester,
    ) async {
      final session = _session(server);
      await _pumpDesktop(tester, session);

      await tester.tap(_inSidebar(find.byTooltip('채팅 시작하기')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('invite-member-u3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('start-chat-submit')));
      await tester.pumpAndSettle();
      // 이미 있는 방이라 목록에 같은 방이 하나만 있고, 그 방이 열린다.
      expect(session.rooms.where((r) => r.id == 'dm2'), hasLength(1));
      expect(session.activeRoomId, 'dm2');
      expect(
        find.descendant(of: _desktopHeader, matching: find.text('이영희')),
        findsOneWidget,
      );

      await tester.tap(_inSidebar(find.byTooltip('새 그룹채팅')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('new-group-pick-members')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('invite-member-u2')));
      await tester.tap(find.byKey(const ValueKey('invite-member-u3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pick-members-confirm')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('new-group-name')),
        '주간 보고',
      );
      await tester.tap(find.byKey(const ValueKey('new-group-submit')));
      await tester.pumpAndSettle();
      expect(session.activeRoomId, 'g-new');
      expect(
        find.descendant(of: _desktopHeader, matching: find.text('주간 보고')),
        findsOneWidget,
      );
      expect(_inSidebar(find.text('그룹채팅 2')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('모바일: 채팅 시작하기로 고른 1:1이 대화 화면으로 열린다', (tester) async {
      final session = _session(server);
      await _pumpMobile(tester, session);
      await _mobileTab(tester, '채팅');

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('invite-member-u3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('start-chat-submit')));
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(session.activeRoomId, 'dm2');
      expect(
        find.descendant(
          of: find.byType(AppBar).last,
          matching: find.text('이영희'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('준회원: 사이드바 그룹채팅·채팅 [+]와 모바일 + 버튼이 없다(방을 만들 수 없어서)', (
      tester,
    ) async {
      final session = _session(server, role: AccountRole.guest);
      await _pumpDesktop(tester, session);
      expect(_inSidebar(find.byTooltip('새 그룹채팅')), findsNothing);
      expect(_inSidebar(find.byTooltip('채팅 시작하기')), findsNothing);
      // 나와의 대화는 준회원에게도 있다.
      expect(_selfRow, findsOneWidget);
      await _finish(tester);

      await _pumpMobile(tester, session);
      await _mobileTab(tester, '그룹채팅');
      expect(find.byType(FloatingActionButton), findsNothing);
      await _mobileTab(tester, '채팅');
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(_selfRow, findsOneWidget);
      await _finish(tester);
    });
  });

  group('나와의 대화 고정 줄', () {
    testWidgets('PC: 채팅 구역 맨 위에 고정되고, 별·✕가 없고, "채팅 N"에서 빠지되 안 읽은 수는 센다', (
      tester,
    ) async {
      // 즐겨찾기가 켜져 와도(서버가 막지 않는다) 고정 줄에는 별이 없다.
      final session = _session(
        server,
        rooms: _rooms(selfUnread: 1, selfFavorite: true),
      );
      await _pumpDesktop(tester, session);

      expect(_selfRow, findsOneWidget);
      expect(_inSelfRow(find.text('나와의 대화')), findsOneWidget);
      expect(
        _inSelfRow(find.byKey(const ValueKey('self-room-me-tag'))),
        findsOneWidget,
      );
      // 1:1 목록(김철수·이영희)보다 위.
      final selfTop = tester.getRect(_selfRow).top;
      expect(
        selfTop,
        lessThan(tester.getRect(_inSidebar(find.text('김철수'))).top),
      );
      expect(
        selfTop,
        lessThan(tester.getRect(_inSidebar(find.text('이영희'))).top),
      );
      // 머리글 수는 1:1 두 개만, 안 읽은 수는 나와의 대화(1) + 김철수(2).
      expect(_inSidebar(find.text('채팅 2')), findsOneWidget);
      final header = find
          .ancestor(of: find.text('채팅 2'), matching: find.byType(Row))
          .first;
      expect(
        find.descendant(of: header, matching: find.text('3')),
        findsOneWidget,
      );
      // 즐겨찾기 별과 숨기기 ✕가 없다(다른 1:1 줄에는 있다).
      expect(_inSelfRow(find.byType(FavoriteStar)), findsNothing);
      expect(_inSelfRow(find.byTooltip('채팅방 숨기기')), findsNothing);
      expect(_inSelfRow(find.byType(IconButton)), findsNothing);
      expect(_inSidebar(find.byTooltip('채팅방 숨기기')), findsNWidgets(2));
      // 안 읽은 수는 줄에도 보인다.
      expect(_inSelfRow(find.text('1')), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('PC: 우클릭 메뉴에는 비밀대화·숨기기·나가기가 없다', (tester) async {
      final session = _session(server);
      await _pumpDesktop(tester, session);
      await tester.tapAt(
        tester.getCenter(_inSelfRow(find.text('나와의 대화'))),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      for (final label in ['대화창 분할하기', '대화방 알림 끄기', '모두 읽음 처리']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      for (final label in ['비밀대화 시작하기', '숨기기', '나가기', '나에게만 이름 변경']) {
        expect(find.text(label), findsNothing, reason: label);
      }
      // 1:1 줄은 그대로 숨기기·나가기가 있다.
      await tester.tapAt(const Offset(700, 990));
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getCenter(_inSidebar(find.text('김철수'))),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('비밀대화 시작하기'), findsOneWidget);
      expect(find.text('숨기기'), findsOneWidget);
      expect(find.text('나가기'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('PC: 누르면 열리고, 헤더는 내 아바타·"나와의 대화"(즐겨찾기 별 없음)', (tester) async {
      final session = _session(server);
      await _pumpDesktop(tester, session);
      await tester.tap(_inSelfRow(find.text('나와의 대화')));
      await tester.pumpAndSettle();

      expect(session.activeRoomId, 'self1');
      expect(
        find.descendant(of: _desktopHeader, matching: find.text('나와의 대화')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _desktopHeader,
          matching: find.byType(SelfRoomAvatar),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _desktopHeader,
          matching: find.byType(FavoriteStar),
        ),
        findsNothing,
      );
      // 나와의 대화엔 멤버·초대 버튼이 없고 알림 켜기/끄기는 있다.
      expect(
        find.descendant(of: _desktopHeader, matching: find.byTooltip('멤버')),
        findsNothing,
      );
      expect(
        find.descendant(of: _desktopHeader, matching: find.byTooltip('알림 끄기')),
        findsOneWidget,
      );
      // 다른 방 헤더에는 별이 그대로 있다.
      await tester.tap(_inSidebar(find.text('이영희')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: _desktopHeader,
          matching: find.byType(FavoriteStar),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('PC: 목록에 아직 없으면 같은 자리의 줄을 누를 때 서버에서 받아 연다', (tester) async {
      final session = _session(server, rooms: _rooms(withSelf: false));
      await _pumpDesktop(tester, session);
      expect(session.selfRoom, isNull);
      expect(_selfRow, findsOneWidget);
      expect(_inSidebar(find.text('채팅 2')), findsOneWidget);
      // 줄을 그리기만 해서는 요청하지 않는다.
      expect(server.called('POST', '/api/rooms/self'), isEmpty);

      await tester.tap(_inSelfRow(find.text('나와의 대화')));
      await tester.pumpAndSettle();
      final posts = server.called('POST', '/api/rooms/self');
      expect(posts, hasLength(1));
      expect(jsonDecode(posts.single.body), {'teamId': 't1'});
      expect(session.selfRoom?.id, 'self1');
      expect(session.activeRoomId, 'self1');
      expect(
        find.descendant(of: _desktopHeader, matching: find.text('나와의 대화')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('모바일: 채팅 탭 맨 위 — 미리보기·안 읽은 수, 즐겨찾기 표시 없음, 길게 누르면 알림만', (
      tester,
    ) async {
      final session = _session(
        server,
        rooms: _rooms(selfUnread: 4, selfFavorite: true),
      );
      await _pumpMobile(tester, session);
      await _mobileTab(tester, '채팅');

      expect(_selfRow, findsOneWidget);
      expect(_inSelfRow(find.text('장보기 목록')), findsOneWidget);
      expect(_inSelfRow(find.text('4')), findsOneWidget);
      expect(_inSelfRow(find.byIcon(Icons.star)), findsNothing);
      expect(
        _inSelfRow(find.byKey(const ValueKey('self-room-me-tag'))),
        findsOneWidget,
      );
      final selfTop = tester.getRect(_selfRow).top;
      expect(selfTop, lessThan(tester.getRect(find.text('김철수')).top));
      expect(selfTop, lessThan(tester.getRect(find.text('이영희')).top));

      await tester.longPress(_inSelfRow(find.text('나와의 대화')));
      await tester.pumpAndSettle();
      expect(find.text('알림 끄기'), findsOneWidget);
      for (final label in ['즐겨찾기', '즐겨찾기 해제', '나가기', '숨기기']) {
        expect(find.text(label), findsNothing, reason: label);
      }
      await tester.tapAt(const Offset(260, 100));
      await tester.pumpAndSettle();

      // 1:1 줄은 그대로 즐겨찾기·숨기기가 있다.
      await tester.longPress(find.text('김철수'));
      await tester.pumpAndSettle();
      expect(find.text('즐겨찾기'), findsOneWidget);
      expect(find.text('숨기기'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('모바일: 누르면 대화 화면이 열리고, 목록에 없으면 서버에서 받아 연다', (tester) async {
      final session = _session(server, rooms: _rooms(withSelf: false));
      await _pumpMobile(tester, session);
      await _mobileTab(tester, '채팅');
      expect(_selfRow, findsOneWidget);
      await tester.tap(_inSelfRow(find.text('나와의 대화')));
      await tester.pumpAndSettle();

      expect(server.called('POST', '/api/rooms/self'), hasLength(1));
      expect(find.byType(ChatScreen), findsOneWidget);
      final appBar = find.byType(AppBar).last;
      expect(
        find.descendant(of: appBar, matching: find.text('나와의 대화')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: appBar, matching: find.byType(SelfRoomAvatar)),
        findsOneWidget,
      );
      // 멤버·초대 버튼 없이 알림·더보기만.
      expect(
        find.descendant(of: appBar, matching: find.byTooltip('멤버')),
        findsNothing,
      );
      expect(
        find.descendant(of: appBar, matching: find.byTooltip('멤버 초대')),
        findsNothing,
      );

      // 이제 목록에 있으니 다시 열 땐 요청 없이 바로.
      Navigator.of(tester.element(find.byType(ChatScreen))).pop();
      await tester.pumpAndSettle();
      await tester.tap(_inSelfRow(find.text('나와의 대화')));
      await tester.pumpAndSettle();
      expect(server.called('POST', '/api/rooms/self'), hasLength(1));
      expect(find.byType(ChatScreen), findsOneWidget);
      await _finish(tester);
    });
  });

  group('내 프로필 "나와의 대화"', () {
    testWidgets('PC: 프로필을 닫고 오른쪽 대화 패널에 연다', (tester) async {
      final session = _session(server);
      await _pumpDesktop(tester, session);
      showDialog<void>(
        context: tester.element(find.byType(DesktopHomeScreen)),
        builder: (_) => MyProfileDialog(session: session),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(MyProfileDialog),
          matching: find.text('나와의 대화'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(MyProfileDialog), findsNothing);
      expect(session.activeRoomId, 'self1');
      expect(
        find.descendant(of: _desktopHeader, matching: find.text('나와의 대화')),
        findsOneWidget,
      );
      await _finish(tester);
    });

    testWidgets('모바일: 더보기 탭 프로필에서 누르면 대화 화면을 띄운다(목록에 없으면 받아서)', (tester) async {
      final session = _session(server, rooms: _rooms(withSelf: false));
      await _pumpMobile(tester, session);
      await _mobileTab(tester, '더보기');
      await tester.tap(find.widgetWithText(ListTile, '나대리'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(MyProfileDialog),
          matching: find.text('나와의 대화'),
        ),
      );
      await tester.pumpAndSettle();

      expect(server.called('POST', '/api/rooms/self'), hasLength(1));
      expect(find.byType(MyProfileDialog), findsNothing);
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(session.activeRoomId, 'self1');
      await _finish(tester);
    });

    testWidgets('팀을 고르기 전(팀 목록 화면)에는 버튼이 없다', (tester) async {
      final session = _session(server, inTeam: false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MyProfileDialog(session: session)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('나와의 대화'), findsNothing);
      expect(find.text('개인정보 설정'), findsOneWidget);
    });
  });

  group('⋮ 메뉴', () {
    testWidgets('그룹: 정보 변경 · 나에게만 이름 변경 · 나가기, "정보 변경"은 채팅 정보 변경 창', (
      tester,
    ) async {
      final session = _session(server);
      await _pumpMenu(tester, session, session.roomById('g1')!);
      expect(_menuLabels(tester), [
        '파일 보기',
        '링크 보기',
        '앨범 보기',
        '대화 내보내기',
        '정보 변경',
        '나에게만 이름 변경',
        '채팅방 나가기',
      ]);
      final item = tester.widget<PopupMenuItem<void>>(
        find.ancestor(
          of: find.text('정보 변경'),
          matching: find.byWidgetPredicate((w) => w is PopupMenuItem<void>),
        ),
      );
      expect(item.enabled, isTrue);
      await tester.tap(find.text('정보 변경'));
      await tester.pumpAndSettle();
      expect(find.text('채팅 정보 변경'), findsWidgets);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('준회원 그룹: 정보 변경은 흐리게 두고, 이유를 툴팁으로 보여 준다', (tester) async {
      final session = _session(server, role: AccountRole.guest);
      await _pumpMenu(tester, session, session.roomById('g1')!);
      final itemFinder = find.ancestor(
        of: find.text('정보 변경'),
        matching: find.byWidgetPredicate((w) => w is PopupMenuItem<void>),
      );
      expect(tester.widget<PopupMenuItem<void>>(itemFinder).enabled, isFalse);
      expect(
        find.descendant(
          of: itemFinder,
          matching: find.byTooltip(groupInfoGuestNotice),
        ),
        findsOneWidget,
      );
      expect(groupInfoGuestNotice, '준회원은 채팅 정보를 바꿀 수 없습니다.');
      // 눌러도 창이 뜨지 않는다(메뉴도 그대로).
      await tester.tap(find.text('정보 변경'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('채팅 정보 변경'), findsNothing);
      expect(find.text('나에게만 이름 변경'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('나와의 대화: 파일 보기 · 링크 보기 · 앨범 보기 · 대화 내보내기만, 멤버·초대 없이 알림은 있다', (
      tester,
    ) async {
      final session = _session(server);
      await _pumpMenu(tester, session, session.roomById('self1')!);
      expect(_menuLabels(tester), ['파일 보기', '링크 보기', '앨범 보기', '대화 내보내기']);
      await tester.tapAt(const Offset(10, 700));
      await tester.pumpAndSettle();
      expect(find.byTooltip('멤버'), findsNothing);
      expect(find.byTooltip('멤버 초대'), findsNothing);
      expect(find.byTooltip('알림 끄기'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('토픽·1:1: 그룹용 "정보 변경"과 "나에게만 이름 변경"이 없다', (tester) async {
      final session = _session(server);
      await _pumpMenu(tester, session, session.roomById('r1')!);
      expect(_menuLabels(tester), [
        '공지',
        '파일 보기',
        '링크 보기',
        '앨범 보기',
        '대화 내보내기',
        '토픽 나가기',
      ]);
      await _finish(tester);

      await _pumpMenu(tester, session, session.roomById('dm1')!);
      expect(_menuLabels(tester), [
        '파일 보기',
        '링크 보기',
        '앨범 보기',
        '대화 내보내기',
        '채팅방 숨기기',
      ]);
      await _finish(tester);
    });
  });

  group('나에게만 이름 변경', () {
    testWidgets('⋮ 메뉴 — 항목과 창 제목이 "나에게만 이름 변경", 별칭이 있으면 원래 이름을 괄호로', (
      tester,
    ) async {
      final session = _session(server);
      final group = session.roomById('g1')!..customName = '밥친구';
      await _pumpMenu(tester, session, group);
      expect(find.text('나에게만 이름 변경(점심 모임)'), findsOneWidget);
      await tester.tap(find.text('나에게만 이름 변경(점심 모임)'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, '나에게만 이름 변경'), findsOneWidget);
      expect(find.text('이름 변경'), findsNothing);
      await _finish(tester);
    });

    testWidgets('원래 이름이 길어도 ⋮ 메뉴 항목은 말줄임표로 자르고 넘치지 않는다', (tester) async {
      final session = _session(server);
      final group = session.roomById('g1')!
        ..name = '아주 긴 그룹채팅 이름 영업 마케팅 디자인 개발 운영 공지 전부 모인 방'
        ..customName = '밥';
      await _pumpMenu(tester, session, group);
      final label = find.textContaining('나에게만 이름 변경(');
      expect(label, findsOneWidget);
      expect(tester.widget<Text>(label).overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('PC 우클릭 메뉴도 "나에게만 이름 변경"', (tester) async {
      final session = _session(server);
      await _pumpDesktop(tester, session);
      await tester.tapAt(
        tester.getCenter(_inSidebar(find.text('점심 모임'))),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('이름 변경'), findsNothing);
      await tester.tap(find.text('나에게만 이름 변경'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, '나에게만 이름 변경'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('모바일 길게 누르기도 "나에게만 이름 변경"', (tester) async {
      final session = _session(server);
      await _pumpMobile(tester, session);
      await _mobileTab(tester, '그룹채팅');
      await tester.longPress(find.text('점심 모임'));
      await tester.pumpAndSettle();
      expect(find.text('이름 변경'), findsNothing);
      await tester.tap(find.text('나에게만 이름 변경'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, '나에게만 이름 변경'), findsOneWidget);
      await _finish(tester);
    });
  });

  group('대화 헤더', () {
    Finder description() =>
        find.byKey(const ValueKey('chat-header-description'));

    String tooltipOf(WidgetTester tester, Finder f) => tester
        .widget<Tooltip>(
          find.ancestor(of: f, matching: find.byType(Tooltip)).first,
        )
        .message!;

    testWidgets('PC: 설명이 있는 그룹·토픽은 이름 아래 한 줄(전체는 툴팁), 1:1은 없다', (tester) async {
      final session = _session(server);
      await _pumpDesktop(tester, session);

      await tester.tap(_inSidebar(find.text('점심 모임')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: _desktopHeader, matching: description()),
        findsOneWidget,
      );
      expect(tester.widget<Text>(description()).data, '매일 점심 메뉴 정하기');
      expect(tester.widget<Text>(description()).maxLines, 1);
      expect(tooltipOf(tester, description()), '매일 점심 메뉴 정하기');
      // 이름 바로 아래 줄.
      final name = find.descendant(
        of: _desktopHeader,
        matching: find.text('점심 모임'),
      );
      expect(
        tester.getRect(description()).top,
        greaterThanOrEqualTo(tester.getRect(name).bottom - 1),
      );
      expect(
        (tester.getRect(description()).left - tester.getRect(name).left).abs(),
        lessThan(1),
      );

      await tester.tap(_inSidebar(find.text('공지')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(description()).data, '회사 공지와 소식');

      // 1:1(안 읽은 방은 ChatPanel의 기존 디버그 단언에 걸려 0인 방으로)은 설명 줄이 없다.
      await tester.tap(_inSidebar(find.text('이영희')));
      await tester.pumpAndSettle();
      expect(description(), findsNothing);

      // 설명이 바뀌면(채팅 정보 변경의 room:created 반영) 바로 보이고, 지우면 줄도 사라진다.
      await tester.tap(_inSidebar(find.text('점심 모임')));
      await tester.pumpAndSettle();
      session.roomById('g1')!.description = '금요일은 외식';
      session.notifyListeners();
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(description()).data, '금요일은 외식');
      session.roomById('g1')!.description = '  ';
      session.notifyListeners();
      await tester.pumpAndSettle();
      expect(description(), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('모바일: 앱바에도 설명 한 줄 — 줄바꿈은 한 줄로 잇고 툴팁엔 원문', (tester) async {
      final session = _session(server);
      const long = '매일 11시 반에 점심 메뉴를 정해요.\n투표는 11시 20분까지, 늦으면 다수결로 정합니다.';
      session.roomById('g1')!.description = long;
      tester.view.physicalSize = const Size(520, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(session: session, room: session.roomById('g1')!),
        ),
      );
      await tester.pumpAndSettle();

      final line = find.descendant(
        of: find.byType(AppBar),
        matching: description(),
      );
      expect(line, findsOneWidget);
      expect(
        tester.widget<Text>(line).data,
        '매일 11시 반에 점심 메뉴를 정해요. 투표는 11시 20분까지, 늦으면 다수결로 정합니다.',
      );
      expect(tester.widget<Text>(line).overflow, TextOverflow.ellipsis);
      expect(tooltipOf(tester, line), long);
      // 이름 아래, 이름과 같은 자리에서 시작한다.
      final name = find.descendant(
        of: find.byType(AppBar),
        matching: find.text('점심 모임'),
      );
      expect(
        tester.getRect(line).top,
        greaterThanOrEqualTo(tester.getRect(name).bottom - 1),
      );
      expect(
        (tester.getRect(line).left - tester.getRect(name).left).abs(),
        lessThan(1),
      );
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('모바일(360px): 좁은 앱바는 상태 배지를 이름 아래로 내리고 설명을 그 옆에 — 넘치지 않는다', (
      tester,
    ) async {
      final session = _session(server);
      final topic = session.roomById('r1')!..archivedAt = DateTime(2026, 9, 1);
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // 실제 앱처럼 목록 위로 띄워 뒤로 가기 버튼까지 앱바에 있게 한다.
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ChatScreen(session: session, room: topic),
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
        matching: find.text('공지'),
      );
      final badge = find.byKey(const ValueKey('chat-header-archived'));
      final line = find.descendant(
        of: find.byType(AppBar),
        matching: description(),
      );
      expect(line, findsOneWidget);
      expect(
        tester.getRect(badge).top,
        greaterThanOrEqualTo(tester.getRect(name).bottom - 1),
      );
      expect(
        tester.getRect(line).left,
        greaterThanOrEqualTo(tester.getRect(badge).right),
      );
      expect(
        (tester.getRect(line).center.dy - tester.getRect(badge).center.dy)
            .abs(),
        lessThan(4),
      );
      await _finish(tester);
    });

    testWidgets('모바일: 나와의 대화 헤더는 내 아바타와 "나와의 대화", 설명 줄은 없다', (tester) async {
      final session = _session(server);
      tester.view.physicalSize = const Size(520, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(session: session, room: session.roomById('self1')!),
        ),
      );
      await tester.pumpAndSettle();
      expect(description(), findsNothing);
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('나와의 대화')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(SelfRoomAvatar),
        ),
        findsOneWidget,
      );
      await _finish(tester);
    });
  });

  testWidgets('RoomAvatar: 나와의 대화는 멤버(나) 아바타에 "나" 꼬리표, 자리 크기는 그대로', (
    tester,
  ) async {
    final self = Room.fromJson(_selfJson());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RoomAvatar(
              room: self,
              myUserId: 'me',
              resolveUrl: (u) => u,
              onlineUserIds: const {'me'},
              size: 28,
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('self-room-me-tag')), findsOneWidget);
    expect(find.text('나'), findsWidgets);
    expect(tester.getSize(find.byType(MeTagAvatar)), const Size(28, 28));
  });
}
