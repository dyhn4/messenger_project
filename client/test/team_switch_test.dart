import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/desktop_home_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/team_switcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const json = {'content-type': 'application/json'};
  final now = DateTime.now().millisecondsSinceEpoch;

  Team team(String id, String name) =>
      Team(id: id, name: name, createdAt: DateTime.now());

  Room room(String id, String teamId, String name) => Room.fromJson({
    'id': id,
    'teamId': teamId,
    'type': 'topic',
    'name': name,
    'members': <Map<String, dynamic>>[],
    'createdAt': now,
  });

  Session buildSession() {
    final client = MockClient((request) async {
      // 화면이 부르는 목록/메시지류는 전부 빈 응답으로 충분하다.
      if (request.url.path.endsWith('/messages')) {
        return http.Response(jsonEncode({'messages': []}), 200, headers: json);
      }
      return http.Response('[]', 200, headers: json);
    });
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: client,
    );
    session.userId = 'u1';
    session.teams.addAll([team('t1', '영업팀'), team('t2', '개발팀')]);
    session.rooms.add(room('r1', 't1', '공지방'));
    session.currentTeam = session.teams.first;
    return session;
  }

  test('팀을 바꾸면 이전 팀 방은 채팅 패널에서 내려간다', () {
    final session = buildSession();
    // 지금 팀(영업팀)의 방은 그대로 둔다.
    expect(isRoomGoneFrom(session, 'r1'), isFalse);

    // 다른 팀으로 전환 — 방은 session.rooms에 그대로 있지만 이 화면에서는 내려가야 한다
    // (그래야 "개발팀입니다" 빈 화면이 나온다).
    session.enterTeam(session.teams.last);
    expect(isRoomGoneFrom(session, 'r1'), isTrue);

    // 돌아오면 다시 보여줄 수 있다.
    session.enterTeam(session.teams.first);
    expect(isRoomGoneFrom(session, 'r1'), isFalse);

    // 목록에 없는 방, 숨긴 방도 마찬가지로 내려간다.
    expect(isRoomGoneFrom(session, '없는방'), isTrue);
    session.rooms.first.hidden = true;
    expect(isRoomGoneFrom(session, 'r1'), isTrue);
  });

  test('분할 패널(anyTeam)은 다른 팀으로 옮겨도 남고, 방이 사라지거나 숨겨질 때만 내려간다', () {
    final session = buildSession();
    session.enterTeam(session.teams.last);
    expect(isRoomGoneFrom(session, 'r1', anyTeam: true), isFalse);
    expect(isRoomGoneFrom(session, '없는방', anyTeam: true), isTrue);
    session.rooms.first.hidden = true;
    expect(isRoomGoneFrom(session, 'r1', anyTeam: true), isTrue);
  });

  testWidgets('팀 전환 탭: 다른 팀 탭을 누르면 그 팀으로 바뀐다', (tester) async {
    final session = buildSession();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: TeamSwitcherTabs(session: session)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 속한 팀이 전부 한 줄에 보인다(드롭다운은 지금 팀만 보인다).
    expect(find.text('영업팀'), findsOneWidget);
    expect(find.text('개발팀'), findsOneWidget);

    // 활성 탭은 밝게(진한 글씨), 비활성 탭은 회색으로 그린다.
    TextStyle styleOf(String name) =>
        tester.widget<Text>(find.text(name)).style!;
    expect(styleOf('영업팀').fontWeight, FontWeight.bold);
    expect(styleOf('개발팀').fontWeight, isNot(FontWeight.bold));
    expect(styleOf('영업팀').color, isNot(styleOf('개발팀').color));

    await tester.tap(find.text('개발팀'));
    await tester.pumpAndSettle();
    expect(session.currentTeam?.id, 't2');
    // 전환하면 밝기도 서로 바뀐다.
    expect(styleOf('개발팀').fontWeight, FontWeight.bold);
    expect(styleOf('영업팀').fontWeight, isNot(FontWeight.bold));
  });

  testWidgets('팀 전환 탭: 안 읽은 메시지가 있는 팀 탭에 빨간 점이 뜬다', (tester) async {
    final session = buildSession();
    // 지금 보고 있지 않은 팀(개발팀)에 안 읽은 방을 하나 둔다.
    session.rooms.add(room('r2', 't2', '잡담방')..unreadCount = 3);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: TeamSwitcherTabs(session: session)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    bool dotOn(String teamName) => tester
        .widget<Badge>(
          find.ancestor(of: find.text(teamName), matching: find.byType(Badge)),
        )
        .isLabelVisible;

    expect(dotOn('개발팀'), isTrue);
    expect(dotOn('영업팀'), isFalse);

    // 읽으면 점이 사라진다(다시 그리면 반영된다).
    session.rooms.last.unreadCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: TeamSwitcherTabs(key: UniqueKey(), session: session),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(dotOn('개발팀'), isFalse);
  });
}
