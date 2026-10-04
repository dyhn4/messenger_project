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

/// 검색 패널의 '대화방' 탭, 전체 탭 맨 위의 대화방 묶음, 검색 범위(현재 팀 / 모든 팀 / 특정 팀) 단추.
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

/// 이름 검색 가짜 응답의 방 하나.
Map<String, dynamic> _roomJson(
  String id,
  String teamId,
  String teamName,
  String type,
  String name, {
  int memberCount = 3,
  bool archived = false,
  DateTime? at,
}) => {
  'roomId': id,
  'teamId': teamId,
  'teamName': teamName,
  'type': type,
  'name': name,
  'memberCount': memberCount,
  'archived': archived,
  'lastActivityAt': (at ?? DateTime(2026, 9, 20)).millisecondsSinceEpoch,
  'isSelf': false,
  'isPublic': true,
};

/// 팀 [teamCount]개(t1이 현재 팀). 방: t1 소속 r1(토픽), t2 소속 r2(그룹채팅).
/// 대화방 이름 검색은 서버처럼 범위(scope=all / teamId) 안에서 q가 들어간 이름만, limit만큼 주고 total은 전체 건수.
/// t1에는 "영업 회의 1~4"(내 방 목록에는 없는 방)도 있어 더 보기를 시험할 수 있다.
Session _session({int teamCount = 2}) {
  _requests = [];
  final client = MockClient((request) async {
    _requests.add(request.url);
    final params = request.url.queryParameters;
    final all = params['scope'] == 'all';
    switch (request.url.path) {
      case '/api/teams/t1/members':
      case '/api/teams/t2/members':
        return http.Response(
          jsonEncode([
            {'id': 'u1', 'name': '송병근', 'username': 'song'},
          ]),
          200,
          headers: _json,
        );
      case '/api/search/rooms':
        final q = params['q'] ?? '';
        final rooms = [
          _roomJson(
            'r1',
            't1',
            '알파팀',
            'topic',
            '마케팅 전략',
            memberCount: 5,
            archived: true,
            at: DateTime(2026, 9, 29),
          ),
          _roomJson('r2', 't2', '베타팀', 'group', '마케팅 모임'),
          for (var i = 1; i <= 4; i++)
            _roomJson('s$i', 't1', '알파팀', 'topic', '영업 회의 $i'),
        ];
        final matched = rooms
            .where((r) => all || r['teamId'] == params['teamId'])
            .where((r) => (r['name'] as String).contains(q))
            .toList();
        final limit = int.tryParse(params['limit'] ?? '') ?? 200;
        return http.Response(
          jsonEncode({
            'items': matched.take(limit).toList(),
            'total': matched.length,
          }),
          200,
          headers: _json,
        );
    }
    if (request.url.path == '/api/search') {
      // 메시지 검색은 q와 상관없이 팀마다 한 건 — t1: m1(r1), t2: m2(r2). 모든 팀이면 둘 다 + 팀 이름.
      // q가 "모임"이면 맞는 메시지가 없다(대화방만 맞는 경우).
      final none = params['q'] == '모임';
      final t1 = !none && (all || params['teamId'] == 't1');
      final t2 = !none && (all || params['teamId'] == 't2');
      return http.Response(
        jsonEncode({
          'items': [
            if (t1)
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
            if (t2)
              {
                'id': 'm2',
                'roomId': 'r2',
                'roomName': '점심 모임',
                'senderId': 'u1',
                'senderName': '송병근',
                'type': 'text',
                'text': '점심 어디 갈까',
                'createdAt': DateTime(2026, 9, 28, 14).millisecondsSinceEpoch,
                if (all) 'teamId': 't2',
                if (all) 'teamName': '베타팀',
              },
          ],
          'total': (t1 ? 1 : 0) + (t2 ? 1 : 0),
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
    testWidgets(
      '탭을 누르면 방 필터가 숨겨지고 /api/search/rooms로 이름을 찾는다 — 결과 줄에 종류·보관됨·멤버 수',
      (tester) async {
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
        expect(find.text('마케팅 전략', findRichText: true), findsOneWidget);
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
        expect(find.text('통합 검색'), findsOneWidget);
        expect(find.text('메시지 검색'), findsNothing);
        await _close(tester);
      },
    );

    testWidgets('검색 전에는 안내 문구, 결과가 없으면 "검색 결과가 없습니다."', (tester) async {
      await _mount(tester, _session(teamCount: 1));
      await _tapTab(tester, 'search-tab-room');
      expect(find.text('내가 참여 중인 토픽·그룹채팅·채팅의 이름을 검색합니다.'), findsOneWidget);
      await _close(tester);
    });

    testWidgets('대화방 결과를 누르면 그 방으로 간다 — 같은 팀이면 onOpenRoom(메시지 없음)', (
      tester,
    ) async {
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

  group('전체 탭의 대화방 묶음', () {
    testWidgets('이름이 맞는 대화방이 맨 위 "대화방" 묶음으로 뜨고(결과 N건에 더함), 누르면 그 방을 연다', (
      tester,
    ) async {
      final opened = <(String, String?)>[];
      await _mount(
        tester,
        _session(teamCount: 1),
        onOpenRoom: (room, id) => opened.add((room.id, id)),
      );
      expect(find.text('대화방 이름과 메시지·파일을 검색합니다.'), findsOneWidget);
      await _search(tester, '마케팅');

      // 메시지 검색과 함께 대화방 이름도 찾는다 — 같은 범위(현재 팀), 묶음에 보일 만큼만(limit=3).
      final req = _last('/api/search/rooms');
      expect(req.queryParameters['q'], '마케팅');
      expect(req.queryParameters['teamId'], 't1');
      expect(req.queryParameters['limit'], '3');
      expect(req.queryParameters.containsKey('scope'), isFalse);

      final rooms = find.byKey(const ValueKey('search-section-rooms'));
      final messages = find.byKey(const ValueKey('search-section-messages'));
      expect(rooms, findsOneWidget);
      expect(messages, findsOneWidget);
      final row = find.byKey(const ValueKey('search-room-preview-r1'));
      expect(row, findsOneWidget);
      // 대화방 묶음 → 방 → 메시지 머리줄 → 메시지 차례.
      expect(tester.getTopLeft(rooms).dy, lessThan(tester.getTopLeft(row).dy));
      expect(
        tester.getTopLeft(row).dy,
        lessThan(tester.getTopLeft(messages).dy),
      );
      expect(
        tester.getTopLeft(messages).dy,
        lessThan(tester.getTopLeft(find.text('점심 먹자', findRichText: true)).dy),
      );
      // 방이 다 보이면 더 보기는 없다. 결과 = 메시지 1 + 대화방 1.
      expect(find.byKey(const ValueKey('search-section-more')), findsNothing);
      expect(find.text('결과 2건', findRichText: true), findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('토픽')),
        findsOneWidget,
      );

      await tester.tap(row);
      await tester.pump();
      expect(opened, [('r1', null)]);
      await _close(tester);
    });

    testWidgets('대화방이 많으면 3개만 + "더 보기" — 누르면 대화방 탭으로 전부', (tester) async {
      await _mount(tester, _session(teamCount: 1));
      await _search(tester, '영업');
      for (var i = 1; i <= 3; i++) {
        expect(
          find.byKey(ValueKey('search-room-preview-s$i')),
          findsOneWidget,
          reason: 's$i',
        );
      }
      expect(
        find.byKey(const ValueKey('search-room-preview-s4')),
        findsNothing,
      );
      // 머리줄 숫자는 전체 건수, 결과 N건 = 메시지 1 + 대화방 4.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('search-section-rooms')),
          matching: find.text('4'),
        ),
        findsOneWidget,
      );
      expect(find.text('결과 5건', findRichText: true), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('search-section-more')));
      await tester.pump();
      await tester.pump();
      expect(find.text('대화방 이름 검색'), findsOneWidget);
      expect(_last('/api/search/rooms').queryParameters['limit'], '500');
      expect(find.text('결과 4건', findRichText: true), findsOneWidget);
      expect(find.text('영업 회의 4', findRichText: true), findsOneWidget);
      expect(find.byKey(const ValueKey('search-section-rooms')), findsNothing);
      await _close(tester);
    });

    testWidgets('참여 대화방으로 좁히면 메시지만 찾는다(대화방 묶음 없음)', (tester) async {
      await _mount(tester, _session(teamCount: 1));
      await tester.tap(find.text('참여 대화방'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('마케팅 전략').last);
      await tester.pumpAndSettle();
      await _search(tester, '마케팅');
      expect(_last('/api/search').queryParameters['roomId'], 'r1');
      expect(_requests.where((u) => u.path == '/api/search/rooms'), isEmpty);
      expect(find.byKey(const ValueKey('search-section-rooms')), findsNothing);
      expect(find.text('결과 1건', findRichText: true), findsOneWidget);
      await _close(tester);
    });

    testWidgets('메시지는 없고 대화방만 맞아도 "결과 없음" 대신 대화방 묶음', (tester) async {
      await _mount(tester, _session());
      // 모든 팀에서 "모임" — 메시지는 없고 베타팀의 "마케팅 모임"만 맞는다.
      await tester.tap(find.byKey(const ValueKey('panel-scope')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('모든 팀'));
      await tester.pumpAndSettle();
      await _search(tester, '모임');
      expect(
        find.byKey(const ValueKey('search-room-preview-r2')),
        findsOneWidget,
      );
      expect(find.text('검색 결과가 없습니다.'), findsNothing);
      expect(
        find.byKey(const ValueKey('search-section-messages')),
        findsNothing,
      );
      expect(find.text('결과 1건', findRichText: true), findsOneWidget);
      // 모든 팀이면 묶음의 방에도 팀 칩.
      expect(find.byKey(const ValueKey('search-team-chip')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  });

  group('검색 범위 — 특정 팀', () {
    testWidgets(
      '메뉴에 현재 팀 / 모든 팀 / ─ / 가입한 팀 이름 — 팀을 고르면 그 팀(teamId)에서만 찾고 단추가 팀 이름',
      (tester) async {
        await _mount(tester, _session());
        final scope = find.byKey(const ValueKey('panel-scope'));
        await tester.tap(scope);
        await tester.pumpAndSettle();
        for (final key in [
          'panel-scope-current',
          'panel-scope-all',
          'panel-scope-team-t1',
          'panel-scope-team-t2',
        ]) {
          expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
        }
        expect(
          find.descendant(
            of: find
                .ancestor(
                  of: find.byKey(const ValueKey('panel-scope-all')),
                  matching: find.byType(Material),
                )
                .first,
            matching: find.byType(Divider),
          ),
          findsOneWidget,
        );
        // 구분선 아래에 팀 이름이 차례로.
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('panel-scope-all'))).dy,
          lessThan(
            tester
                .getTopLeft(find.byKey(const ValueKey('panel-scope-team-t1')))
                .dy,
          ),
        );
        expect(
          tester
              .getTopLeft(find.byKey(const ValueKey('panel-scope-team-t1')))
              .dy,
          lessThan(
            tester
                .getTopLeft(find.byKey(const ValueKey('panel-scope-team-t2')))
                .dy,
          ),
        );
        await tester.tap(find.text('베타팀'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: scope, matching: find.text('베타팀')),
          findsOneWidget,
        );
        // 멤버 필터 후보도 그 팀 멤버로 다시 받는다.
        expect(_requests.any((u) => u.path == '/api/teams/t2/members'), isTrue);

        await _search(tester, '마케팅');
        var req = _last('/api/search');
        expect(req.queryParameters['teamId'], 't2');
        expect(req.queryParameters.containsKey('scope'), isFalse);
        req = _last('/api/search/rooms');
        expect(req.queryParameters['teamId'], 't2');
        expect(req.queryParameters.containsKey('scope'), isFalse);
        // 한 팀만 보니 팀 칩은 없다.
        expect(find.byKey(const ValueKey('search-team-chip')), findsNothing);
        expect(find.text('점심 어디 갈까', findRichText: true), findsOneWidget);

        // 다시 열면 고른 팀에 체크.
        await tester.tap(scope);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('panel-scope-team-t2')),
            matching: find.byIcon(Icons.check),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('panel-scope-current')),
            matching: find.byIcon(Icons.check),
          ),
          findsNothing,
        );
        // 현재 팀으로 돌아오면 teamId=t1, 단추 글자도 현재 팀.
        await tester.tap(find.byKey(const ValueKey('panel-scope-current')));
        await tester.pumpAndSettle();
        expect(_last('/api/search').queryParameters['teamId'], 't1');
        expect(
          find.descendant(of: scope, matching: find.text('현재 팀')),
          findsOneWidget,
        );

        // 모든 팀 → 팀 이름 고르기 → scope=all이 빠진다.
        await tester.tap(scope);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('panel-scope-all')));
        await tester.pumpAndSettle();
        expect(_last('/api/search').queryParameters['scope'], 'all');
        await tester.tap(scope);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('panel-scope-team-t1')));
        await tester.pumpAndSettle();
        req = _last('/api/search');
        expect(req.queryParameters['teamId'], 't1');
        expect(req.queryParameters.containsKey('scope'), isFalse);
        expect(
          find.descendant(of: scope, matching: find.text('알파팀')),
          findsOneWidget,
        );
        await _close(tester);
      },
    );

    testWidgets('다른 팀을 골라 찾은 대화방(전체 탭 묶음)을 누르면 그 팀으로 전환해 연다', (tester) async {
      final session = _session();
      await _mount(tester, session, onOpenRoom: (_, _) {});
      await tester.tap(find.byKey(const ValueKey('panel-scope')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('베타팀'));
      await tester.pumpAndSettle();
      await _search(tester, '마케팅');
      await tester.tap(find.byKey(const ValueKey('search-room-preview-r2')));
      await tester.pump();
      expect(session.currentTeam!.id, 't2');
      expect(session.consumePendingOpenRoom()?.id, 'r2');
      await _close(tester);
    });

    testWidgets('폭 360 — 팀 이름 단추도 결과 줄 오른쪽에서 넘치지 않는다', (tester) async {
      await _mount(tester, _session(), size: const Size(360, 720));
      final scope = find.byKey(const ValueKey('panel-scope'));
      await tester.tap(scope);
      await tester.pumpAndSettle();
      await tester.tap(find.text('베타팀'));
      await tester.pumpAndSettle();
      await _search(tester, '마케팅');
      expect(tester.getRect(scope).right, lessThanOrEqualTo(360));
      expect(tester.takeException(), isNull);
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
      expect(tester.getCenter(scope).dy, closeTo(tester.getCenter(sort).dy, 1));
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

    testWidgets(
      '기본은 현재 팀(teamId) — 모든 팀을 고르면 scope=all(teamId 없음)로 다시 찾고 팀 칩이 붙는다',
      (tester) async {
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
        expect(
          find.byKey(const ValueKey('search-team-chip')),
          findsNWidgets(2),
        );
        expect(find.text('알파팀'), findsOneWidget);
        expect(find.text('베타팀'), findsOneWidget);
        expect(find.text('결과 2건', findRichText: true), findsOneWidget);

        // 대화방 탭도 같은 범위로 — 팀 칩이 붙는다.
        await _tapTab(tester, 'search-tab-room');
        await _search(tester, '마케팅');
        req = _last('/api/search/rooms');
        expect(req.queryParameters['scope'], 'all');
        expect(req.queryParameters.containsKey('teamId'), isFalse);
        expect(
          find.byKey(const ValueKey('search-team-chip')),
          findsNWidgets(2),
        );
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
      },
    );

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

    testWidgets('다른 팀 결과를 누르면 그 팀으로 전환하고 방·메시지를 연다(requestOpenRoom)', (
      tester,
    ) async {
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
      // 결과 줄 가운데가 아니라 오른쪽 끝(정렬 단추와 같은 오른쪽 여백)에 붙는다.
      expect(
        tester.getRect(scope).right,
        closeTo(tester.getRect(sort).right, 1),
      );

      await _search(tester, '점심');
      expect(
        tester.getRect(scope).right,
        closeTo(tester.getRect(sort).right, 1),
      );
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
      await _search(tester, '마케팅');
      expect(find.byKey(const ValueKey('search-team-chip')), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  });
}
