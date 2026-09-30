import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/desktop_home_screen.dart';
import 'package:client/screens/search_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/services/typing_gate.dart';
import 'package:client/widgets/filter_dropdown.dart';
import 'package:client/widgets/read_up_to_here_divider.dart';
import 'package:client/widgets/room_options_menu.dart';
import 'package:client/widgets/room_picker_field.dart';
import 'package:client/widgets/unread_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 채팅 개편 뒤 손본 것들 — 숨겨 둔 1:1을 다시 시작하면 바로 보이기, 방 고르기 목록의 나와의 대화(팀마다
/// 하나라 지금 팀 것만), 검색 결과의 방 이름(나에게만 이름 변경), 안 읽은 방을 PC 패널로 열기.

/// 방을 열 때 부르는 "그 방 알림 지우기"(OS 알림 플러그인)를 조용히 넘긴다.
class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _user(String id, String name) => {
  'id': id,
  'username': id,
  'name': name,
  'role': 'member',
};

final _me = _user('me', '나');
final _kim = _user('u2', '김철수');
final _lee = _user('u3', '이영희');

/// 읽은 지점(내 lastRead) — 김철수와의 1:1은 이 뒤로 두 개를 안 읽었다.
final _readAt = DateTime(2026, 9, 29, 9).millisecondsSinceEpoch;

Map<String, dynamic> _roomJson(
  String id, {
  String teamId = 't1',
  String type = 'dm',
  String? name,
  List<Map<String, dynamic>>? members,
  Map<String, dynamic> extra = const {},
}) => {
  'id': id,
  'teamId': teamId,
  'type': type,
  'name': name,
  'members': members ?? [_me, _kim],
  'createdAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
  'lastActivityAt': DateTime(2026, 9, 29, 10).millisecondsSinceEpoch,
  ...extra,
};

Map<String, dynamic> _messageJson(String id, String text, int createdAt) => {
  'id': id,
  'roomId': 'dm1',
  'senderId': 'u2',
  'senderName': '김철수',
  'type': 'text',
  'text': text,
  'createdAt': createdAt,
};

/// 가짜 서버 — 요청을 남기고, 1:1 시작·팀 멤버·김철수와의 대화 기록·검색에 답한다.
class _Server {
  final requests = <http.Request>[];

  /// 1:1 시작(POST /rooms/dm)이 돌려줄 hidden — 서버는 숨겨 둔 1:1을 다시 시작하면 false로 되돌려 준다.
  bool dmHidden = false;

  /// GET /search가 돌려줄 결과.
  List<Map<String, dynamic>> searchResults = [];

  late final client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'POST' && path == '/api/rooms/dm') {
      final body = jsonDecode(request.body) as Map;
      final target = body['targetUserId'];
      return _json(
        _roomJson(
          target == 'u3' ? 'dm2' : 'dm-$target',
          teamId: body['teamId'] as String,
          members: [_me, target == 'u3' ? _lee : _kim],
          extra: {'hidden': dmHidden},
        ),
      );
    }
    if (request.method == 'GET' && path == '/api/teams/t1/members') {
      return _json([_me, _kim, _lee]);
    }
    if (request.method == 'GET' && path == '/api/rooms/dm1/messages') {
      return _json([
        _messageJson('m1', '어제 보낸 자료 봤어요?', _readAt - 60000),
        _messageJson('m2', '회의 10분 전에 알려 주세요', _readAt + 60000),
        _messageJson('m3', '회의실은 3층이에요', _readAt + 120000),
      ]);
    }
    if (request.method == 'GET' && path == '/api/search') {
      return _json(searchResults);
    }
    return _json(<Object>[]);
  });

  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
}

Session _session(_Server server, List<Room> rooms) {
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
  session.accountRole = AccountRole.member;
  final sales = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  final dev = Team(id: 't2', name: '개발팀', createdAt: DateTime(2026));
  session.teams.addAll([sales, dev]);
  session.currentTeam = sales;
  session.rooms.addAll(rooms);
  return session;
}

Room _self(String teamId) => Room.fromJson(
  _roomJson(
    'self-$teamId',
    teamId: teamId,
    members: [_me],
    extra: {'isSelf': true},
  ),
);

/// 김철수와의 1:1(안 읽은 두 개) · 숨겨 둔 이영희와의 1:1.
List<Room> _dms({int kimUnread = 2}) => [
  Room.fromJson(
    _roomJson(
      'dm1',
      extra: {
        'unreadCount': kimUnread,
        'lastRead': {'me': _readAt},
      },
    ),
  ),
  Room.fromJson(
    _roomJson('dm2', members: [_me, _lee], extra: {'hidden': true}),
  ),
];

Finder _byTypeName(String name) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

Finder _inSidebar(Finder f) =>
    find.descendant(of: _byTypeName('_Sidebar'), matching: f);

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

/// 화면을 내리고 남은 토스트 타이머까지 흘려보낸다.
Future<void> _finish(WidgetTester tester) async {
  TypingGate.instance.reset();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  late _Server server;
  setUp(() => server = _Server());

  group('숨겨 둔 1:1 다시 시작하기', () {
    test('1:1 시작 응답의 hidden을 목록의 그 방에 바로 반영한다(팀을 정해 여는 경로도)', () async {
      final session = _session(server, _dms());
      final hidden = session.roomById('dm2')!;
      expect(hidden.hidden, isTrue);

      final room = await session.startDm('u3');
      expect(room, same(hidden));
      expect(room.hidden, isFalse);

      // 조직도·멤버 카드처럼 팀을 정해 여는 경로도 같다.
      room.hidden = true;
      final again = await session.startDmInTeam('t1', 'u3');
      expect(again, same(hidden));
      expect(again.hidden, isFalse);
      expect(session.consumePendingOpenRoom(), same(hidden));
    });

    testWidgets('PC: 채팅 시작하기로 다시 연 1:1이 목록에 다시 보이고, 패널이 닫히지 않는다', (
      tester,
    ) async {
      final session = _session(server, [_self('t1'), ..._dms(kimUnread: 0)]);
      await _pumpDesktop(tester, session);
      expect(_inSidebar(find.text('이영희')), findsNothing);

      await tester.tap(_inSidebar(find.byTooltip('채팅 시작하기')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('invite-member-u3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('start-chat-submit')));
      await tester.pumpAndSettle();

      expect(server.called('POST', '/api/rooms/dm'), hasLength(1));
      expect(session.activeRoomId, 'dm2');
      expect(
        find.descendant(of: _desktopHeader, matching: find.text('이영희')),
        findsOneWidget,
      );

      // 다른 일로 세션 알림이 와도(접속 상태·다른 방 메시지 등) 방금 연 방은 그대로 떠 있다.
      session.notifyListeners();
      await tester.pumpAndSettle();
      expect(session.activeRoomId, 'dm2');
      expect(
        find.descendant(of: _desktopHeader, matching: find.text('이영희')),
        findsOneWidget,
      );
      expect(session.roomById('dm2')!.hidden, isFalse);
      expect(_inSidebar(find.text('이영희')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });
  });

  group('방 고르기 목록의 나와의 대화', () {
    /// 영업팀(지금 팀)·개발팀 모두에 나와의 대화와 김철수와의 1:1이 있고, 개발팀에는 토픽이 하나 더 있다.
    List<Room> twoTeams() => [
      _self('t1'),
      _self('t2'),
      Room.fromJson(_roomJson('dm1')),
      Room.fromJson(_roomJson('dm-t2', teamId: 't2')),
      Room.fromJson(
        _roomJson(
          'r-t2',
          teamId: 't2',
          type: 'topic',
          name: '개발 공지',
          extra: {'isPublic': true},
        ),
      ),
      Room.fromJson(
        _roomJson(
          'r-t1',
          type: 'topic',
          name: '영업 공지',
          extra: {'isPublic': true},
        ),
      ),
    ];

    testWidgets('공유·전달·예약의 대화방 고르기: 지금 팀의 나와의 대화 하나만(다른 팀 방은 없다)', (
      tester,
    ) async {
      final session = _session(server, twoTeams());
      Room? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: StatefulBuilder(
                builder: (context, setState) => RoomPickerField(
                  session: session,
                  value: picked,
                  onChanged: (r) => setState(() => picked = r),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('대화방 선택'));
      await tester.pumpAndSettle();
      expect(find.text('영업 공지'), findsOneWidget);
      expect(find.text('개발 공지'), findsNothing);

      await tester.tap(find.text('채팅'));
      await tester.pumpAndSettle();
      expect(find.text('나와의 대화'), findsOneWidget);
      expect(find.text('김철수'), findsOneWidget);

      await tester.tap(find.text('나와의 대화'));
      await tester.pumpAndSettle();
      expect(picked?.id, 'self-t1');
    });

    testWidgets('검색·파일·링크의 "참여 대화방": 지금 팀의 나와의 대화 하나만(다른 팀 방은 없다)', (
      tester,
    ) async {
      final session = _session(server, twoTeams());
      String? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => RoomFilterButton(
                session: session,
                selectedRoomId: picked,
                onSelected: (id) => setState(() => picked = id),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('참여 대화방'));
      await tester.pumpAndSettle();
      expect(find.text('영업 공지'), findsOneWidget);
      expect(find.text('개발 공지'), findsNothing);

      await tester.tap(find.text('채팅'));
      await tester.pumpAndSettle();
      expect(find.text('나와의 대화'), findsOneWidget);
      expect(find.text('김철수'), findsOneWidget);

      await tester.tap(find.text('나와의 대화'));
      await tester.pumpAndSettle();
      expect(picked, 'self-t1');
    });
  });

  testWidgets('검색 결과의 방 이름은 사이드바와 같은 이름(나에게만 이름 변경)으로 보인다', (tester) async {
    final session = _session(server, [
      Room.fromJson(
        _roomJson(
          'g1',
          type: 'group',
          name: '점심 모임',
          members: [_me, _kim, _lee],
          extra: {'customName': '우리 점심'},
        ),
      ),
    ]);
    final at = DateTime(2026, 9, 29, 12).millisecondsSinceEpoch;
    server.searchResults = [
      {
        'id': 'm1',
        'roomId': 'g1',
        'roomName': '점심 모임',
        'senderId': 'u2',
        'senderName': '김철수',
        'text': '점심은 국수',
        'createdAt': at,
      },
      // 목록에 없는 방(그 사이 나간 방 등)은 서버가 준 이름 그대로.
      {
        'id': 'm2',
        'roomId': 'g-gone',
        'roomName': '지난 모임',
        'senderId': 'u3',
        'senderName': '이영희',
        'text': '점심 맛있었어요',
        'createdAt': at - 1000,
      },
    ];
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchScreen(
            session: session,
            asPanel: true,
            onClose: () {},
            onOpenRoom: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '점심');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(server.called('GET', '/api/search'), hasLength(1));
    expect(find.text('결과 2건'), findsOneWidget);
    expect(find.text('우리 점심'), findsOneWidget);
    expect(find.text('점심 모임'), findsNothing);
    expect(find.text('지난 모임'), findsOneWidget);
  });

  testWidgets('PC: 안 읽은 메시지가 있는 방을 열어도 오류 없이 뱃지를 지우고, "여기까지 읽었습니다"는 그대로', (
    tester,
  ) async {
    final session = _session(server, [_self('t1'), ..._dms()]);
    await _pumpDesktop(tester, session);
    final kimRow = find.ancestor(
      of: _inSidebar(find.text('김철수')),
      matching: _byTypeName('_RoomTile'),
    );
    expect(
      find.descendant(of: kimRow, matching: find.byType(UnreadBadge)),
      findsOneWidget,
    );

    await tester.tap(_inSidebar(find.text('김철수')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(session.activeRoomId, 'dm1');
    expect(session.roomById('dm1')!.unreadCount, 0);
    expect(
      find.descendant(of: kimRow, matching: find.byType(UnreadBadge)),
      findsNothing,
    );
    // 읽은 지점은 연 순간의 값 그대로 — 안 읽었던 첫 메시지 바로 위에 구분선.
    expect(find.byType(ReadUpToHereDivider), findsOneWidget);
    final divider = tester.getRect(find.byType(ReadUpToHereDivider));
    expect(
      divider.top,
      greaterThan(tester.getRect(find.text('어제 보낸 자료 봤어요?')).top),
    );
    expect(
      divider.bottom,
      lessThanOrEqualTo(tester.getRect(find.text('회의 10분 전에 알려 주세요')).top),
    );
    await _finish(tester);
  });
}
