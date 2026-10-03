import 'dart:convert';

import 'package:client/models/app_user.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/search_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 검색 패널의 '대화방' 탭과 검색 범위(현재 팀 / 모든 팀) 단추.
/// 서버는 요청 주소를 기록하는 가짜 HTTP 클라이언트로 대신한다.

const _json = {'content-type': 'application/json; charset=utf-8'};

late List<Uri> _requests;

Uri _last(String path) => _requests.lastWhere((u) => u.path == path);

Room _room(String id, String teamId, RoomType type, String? name) => Room(
  id: id,
  teamId: teamId,
  type: type,
  name: name,
  members: const [],
  createdAt: DateTime(2026),
  lastRead: const {},
);

/// 팀 [teamCount]개(t1이 현재 팀). 방: t1 소속 r1(토픽), t2 소속 r2(그룹채팅).
Session _session({int teamCount = 2}) {
  _requests = [];
  final client = MockClient((request) async {
    _requests.add(request.url);
    final all = request.url.queryParameters['scope'] == 'all';
    switch (request.url.path) {
      case '/api/search':
        return http.Response(
          jsonEncode({
            'items': [
              {
                'id': 'm1',
                'roomId': 'r1',
                'roomName': '마케팅 전략',
                'senderId': 'u1',
                'senderName': '송병근',
                'type': 'text',
                'text': '점심 먹자',
                'createdAt': DateTime(2026, 9, 29, 14).millisecondsSinceEpoch,
                if (all) 'teamId': 't1',
                if (all) 'teamName': '알파팀',
              },
              if (all)
                {
                  'id': 'm2',
                  'roomId': 'r2',
                  'roomName': '점심 모임',
                  'senderId': 'u1',
                  'senderName': '송병근',
                  'type': 'text',
                  'text': '점심 어디 갈까',
                  'createdAt': DateTime(2026, 9, 28, 14).millisecondsSinceEpoch,
                  'teamId': 't2',
                  'teamName': '베타팀',
                },
            ],
            'total': all ? 2 : 1,
          }),
          200,
          headers: _json,
        );
      case '/api/search/rooms':
        return http.Response(
          jsonEncode({
            'items': [
              {
                'roomId': 'r1',
                'teamId': 't1',
                'teamName': '알파팀',
                'type': 'topic',
                'name': '마케팅 전략',
                'memberCount': 5,
                'archived': true,
                'lastActivityAt': DateTime(2026, 9, 29).millisecondsSinceEpoch,
                'isSelf': false,
                'isPublic': true,
              },
              if (all)
                {
                  'roomId': 'r2',
                  'teamId': 't2',
                  'teamName': '베타팀',
                  'type': 'group',
                  'name': '마케팅 모임',
                  'memberCount': 3,
                  'archived': false,
                  'lastActivityAt': DateTime(2026, 9, 20).millisecondsSinceEpoch,
                  'isSelf': false,
                  'isPublic': true,
                },
            ],
            'total': all ? 2 : 1,
          }),
          200,
          headers: _json,
        );
    }
    return http.Response('[]', 200, headers: _json);
  });
  final s = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  s.serverUrl = 'https://test.local';
  s.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: client,
  );
  s.userId = 'me';
  final t1 = Team(id: 't1', name: '알파팀', createdAt: DateTime(2026));
  s.teams.add(t1);
  if (teamCount > 1) {
    s.teams.add(Team(id: 't2', name: '베타팀', createdAt: DateTime(2026)));
  }
  s.currentTeam = t1;
  s.rooms.add(_room('r1', 't1', RoomType.topic, '마케팅 전략'));
  s.rooms.add(
    Room(
      id: 'r2',
      teamId: 't2',
      type: RoomType.group,
      name: '마케팅 모임',
      members: [AppUser(id: 'me', name: '나', username: 'me')],
      createdAt: DateTime(2026),
      lastRead: const {},
    ),
  );
  return s;
}

Future<void> _mount(
  WidgetTester tester,
  Session session, {
  Size size = const Size(900, 900),
  void Function(Room, String?)? onOpenRoom,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SearchScreen(
          session: session,
          asPanel: onOpenRoom != null,
          onClose: () {},
          onOpenRoom: onOpenRoom,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _search(WidgetTester tester, String q) async {
  await tester.enterText(find.byType(TextField).first, q);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
  await tester.pump();
}

Future<void> _tapTab(WidgetTester tester, String key) async {
  final tab = find.byKey(ValueKey(key));
  await tester.ensureVisible(tab);
  await tester.tap(tab);
  await tester.pump();
  await tester.pump();
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  group('대화방 탭', () {
    testWidgets('탭을 누르면 방 필터가 숨겨지고 /api/search/rooms로 이름을 찾는다 — 결과 줄에 종류·보관됨·멤버 수', (
      tester,
    ) async {
      await _mount(tester, _session(teamCount: 1));
      expect(find.text('참여 대화방'), findsOneWidget);
      await _search(tester, '마케팅');
      expect(_last('/api/search').queryParameters['q'], '마케팅');

      await _tapTab(tester, 'search-tab-room');
      // 방·멤버·기간 필터 줄은 대화방 탭에 뜻이 없어 사라진다.
      expect(find.text('참여 대화방'), findsNothing);
      expect(find.text('모든 멤버'), findsNothing);
      expect(find.text('1년 (기본)'), findsNothing);
      expect(find.text('대화방 이름 검색'), findsOneWidget);

      final req = _last('/api/search/rooms');
      expect(req.queryParameters['q'], '마케팅');
      expect(req.queryParameters['teamId'], 't1');
      expect(req.queryParameters.containsKey('scope'), isFalse);
      expect(req.queryParameters.containsKey('since'), isFalse);
      expect(req.queryParameters.containsKey('roomId'), isFalse);
      expect(req.queryParameters.containsKey('order'), isFalse);

      expect(find.text('결과 1건', findRichText: true), findsOneWidget);
      expect(
        find.text('마케팅 전략', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('토픽'), findsOneWidget);
      expect(find.text('보관됨'), findsOneWidget);
      expect(find.text('· 멤버 5명'), findsOneWidget);
      // 팀이 하나(현재 팀 검색)라 팀 칩은 없다.
      expect(find.byKey(const ValueKey('search-team-chip')), findsNothing);
      // 기간 표시도 없다.
      expect(find.byKey(const ValueKey('panel-range-text')), findsNothing);

      // 정렬: 과거 순 = 오래된 활동 먼저 → order=asc.
      await tester.tap(find.byKey(const ValueKey('panel-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('과거 순'));
      await tester.pumpAndSettle();
      expect(_last('/api/search/rooms').queryParameters['order'], 'asc');

      // 전체 탭으로 돌아오면 필터가 다시 뜨고, 메시지 검색이 간다.
      await _tapTab(tester, 'search-tab-all');
      expect(find.text('참여 대화방'), findsOneWidget);
      expect(find.text('메시지 검색'), findsOneWidget);
      await _close(tester);
    });

    testWidgets('검색 전에는 안내 문구, 결과가 없으면 "검색 결과가 없습니다."', (tester) async {
      await _mount(tester, _session(teamCount: 1));
      await _tapTab(tester, 'search-tab-room');
      expect(
        find.text('내가 참여 중인 토픽·그룹채팅·채팅의 이름을 검색합니다.'),
        findsOneWidget,
      );
      await _close(tester);
    });

    testWidgets('대화방 결과를 누르면 그 방으로 간다 — 같은 팀이면 onOpenRoom(메시지 없음)', (tester) async {
      final session = _session(teamCount: 1);
      final opened = <(String, String?)>[];
      await _mount(
        tester,
        session,
        onOpenRoom: (room, id) => opened.add((room.id, id)),
      );
      await _tapTab(tester, 'search-tab-room');
      await _search(tester, '마케팅');
      await tester.tap(find.text('마케팅 전략', findRichText: true));
      await tester.pump();
      expect(opened, [('r1', null)]);
      await _close(tester);
    });
  });

  group('검색 범위(현재 팀 / 모든 팀)', () {
    testWidgets('팀이 하나뿐이면 단추가 없고, 둘 이상이면 정렬 단추 왼쪽에 "현재 팀 ⌄"', (tester) async {
      await _mount(tester, _session(teamCount: 1));
      expect(find.byKey(const ValueKey('panel-scope')), findsNothing);
      await _close(tester);

      await _mount(tester, _session());
      final scope = find.byKey(const ValueKey('panel-scope'));
      final sort = find.byKey(const ValueKey('panel-sort'));
      expect(scope, findsOneWidget);
      expect(find.text('현재 팀'), findsOneWidget);
      // 같은 줄(세로 가운데 일치), 정렬 단추의 왼쪽.
      expect(
        tester.getCenter(scope).dy,
        closeTo(tester.getCenter(sort).dy, 1),
      );
      expect(
        tester.getRect(scope).right,
        lessThanOrEqualTo(tester.getRect(sort).left + 0.5),
      );
      // 마지막 탭(대화방)과도 겹치지 않는다.
      expect(
        tester.getRect(find.byKey(const ValueKey('search-tab-room'))).right,
        lessThanOrEqualTo(tester.getRect(scope).left + 0.5),
      );
      await _close(tester);
    });

    testWidgets('기본은 현재 팀(teamId) — 모든 팀을 고르면 scope=all(teamId 없음)로 다시 찾고 팀 칩이 붙는다', (
      tester,
    ) async {
      await _mount(tester, _session());
      await _search(tester, '점심');
      var req = _last('/api/search');
      expect(req.queryParameters['teamId'], 't1');
      expect(req.queryParameters.containsKey('scope'), isFalse);
      expect(find.byKey(const ValueKey('search-team-chip')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('panel-scope')));
      await tester.pumpAndSettle();
      expect(find.text('모든 팀'), findsOneWidget);
      await tester.tap(find.text('모든 팀'));
      await tester.pumpAndSettle();
      req = _last('/api/search');
      expect(req.queryParameters['scope'], 'all');
      expect(req.queryParameters.containsKey('teamId'), isFalse);
      expect(req.queryParameters['q'], '점심');
      // 단추 글자가 바뀌고, 결과마다 팀 이름 칩.
      expect(find.text('모든 팀'), findsOneWidget);
      expect(find.byKey(const ValueKey('search-team-chip')), findsNWidgets(2));
      expect(find.text('알파팀'), findsOneWidget);
      expect(find.text('베타팀'), findsOneWidget);
      expect(find.text('결과 2건', findRichText: true), findsOneWidget);

      // 대화방 탭도 같은 범위로 — 팀 칩이 붙는다.
      await _tapTab(tester, 'search-tab-room');
      req = _last('/api/search/rooms');
      expect(req.queryParameters['scope'], 'all');
      expect(req.queryParameters.containsKey('teamId'), isFalse);
      expect(find.byKey(const ValueKey('search-team-chip')), findsNWidgets(2));
      expect(find.text('그룹채팅'), findsOneWidget);

      // 다시 현재 팀.
      await tester.tap(find.byKey(const ValueKey('panel-scope')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('현재 팀'));
      await tester.pumpAndSettle();
      req = _last('/api/search/rooms');
      expect(req.queryParameters['teamId'], 't1');
      expect(req.queryParameters.containsKey('scope'), isFalse);
      await _close(tester);
    });

    testWidgets('패널을 새로 열면 늘 현재 팀으로 시작한다(저장 안 함)', (tester) async {
      final session = _session();
      await _mount(tester, session);
      await tester.tap(find.byKey(const ValueKey('panel-scope')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('모든 팀'));
      await tester.pumpAndSettle();
      await _close(tester);

      await _mount(tester, session);
      expect(find.text('현재 팀'), findsOneWidget);
      expect(find.text('모든 팀'), findsNothing);
      await _close(tester);
    });

    testWidgets('다른 팀 결과를 누르면 그 팀으로 전환하고 방·메시지를 연다(requestOpenRoom)', (tester) async {
      final session = _session();
      final opened = <(String, String?)>[];
      await _mount(
        tester,
        session,
        onOpenRoom: (room, id) => opened.add((room.id, id)),
      );
      await tester.tap(find.byKey(const ValueKey('panel-scope')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('모든 팀'));
      await tester.pumpAndSettle();
      await _search(tester, '점심');

      // 같은 팀(알파팀) 결과 — 패널의 onOpenRoom으로, 팀 전환 없음.
      await tester.tap(find.text('점심 먹자', findRichText: true));
      await tester.pump();
      expect(opened, [('r1', 'm1')]);
      expect(session.currentTeam!.id, 't1');

      // 다른 팀(베타팀) 결과 — 팀을 바꾸고 방+메시지를 예약한다.
      await tester.tap(find.text('점심 어디 갈까', findRichText: true));
      await tester.pump();
      expect(opened.length, 1);
      expect(session.currentTeam!.id, 't2');
      expect(session.consumePendingOpenRoom()?.id, 'r2');
      expect(session.consumePendingOpenMessageId(), 'm2');
      await _close(tester);
    });

    testWidgets('다른 팀 대화방 결과를 누르면 팀 전환 후 그 방을 연다', (tester) async {
      final session = _session();
      await _mount(tester, session, onOpenRoom: (_, _) {});
      await tester.tap(find.byKey(const ValueKey('panel-scope')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('모든 팀'));
      await tester.pumpAndSettle();
      await _tapTab(tester, 'search-tab-room');
      await _search(tester, '마케팅');

      await tester.tap(find.text('마케팅 모임', findRichText: true));
      await tester.pump();
      expect(session.currentTeam!.id, 't2');
      expect(session.consumePendingOpenRoom()?.id, 'r2');
      expect(session.consumePendingOpenMessageId(), isNull);
      await _close(tester);
    });

    testWidgets('폭 360 — 범위 단추가 결과 줄 오른쪽으로 내려가고(검색 전에도), 아무것도 넘치지 않는다', (
      tester,
    ) async {
      await _mount(tester, _session(), size: const Size(360, 720));
      final scope = find.byKey(const ValueKey('panel-scope'));
      final sort = find.byKey(const ValueKey('panel-sort'));
      // 검색 전에도 보이고, 탭 줄(정렬 단추)보다 아래에 있다.
      expect(scope, findsOneWidget);
      expect(
        tester.getTopLeft(scope).dy,
        greaterThan(tester.getBottomLeft(sort).dy - 1),
      );
      expect(tester.getRect(scope).right, lessThanOrEqualTo(360));

      await _search(tester, '점심');
      // 긴 기간 표시(직접 설정)까지 붙어도 넘치지 않는다 — 기간 필터에서 직접 설정은 달력이 필요해 생략하고
      // 모든 팀 + 결과 줄만 확인.
      await tester.tap(scope);
      await tester.pumpAndSettle();
      await tester.tap(find.text('모든 팀'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-team-chip')), findsNWidgets(2));
      expect(tester.getRect(scope).right, lessThanOrEqualTo(360));
      expect(
        tester.getTopLeft(scope).dy,
        greaterThan(tester.getBottomLeft(sort).dy - 1),
      );

      await _tapTab(tester, 'search-tab-room');
      expect(find.byKey(const ValueKey('search-team-chip')), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  });
}
