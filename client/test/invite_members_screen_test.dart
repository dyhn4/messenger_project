import 'dart:convert';

import 'package:client/models/app_user.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/invite_members_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/private_topic_lock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 토픽 "멤버 초대하기" 창 — 멤버 검색·직책 조건, 모든 멤버 선택하기, 검색 조건 초기화, 선택된
/// 멤버 칸, 초대 요청.
void main() {
  const serverUrl = 'https://192.168.0.10:3000';
  const json = {'content-type': 'application/json'};

  Map<String, dynamic> user(String id, String name, [String? position]) => {
    'id': id,
    'username': 'user_$id',
    'name': name,
    'position': ?position,
  };

  final teamMembers = [
    user('u1', '김하나', '팀장'), // 나 — 이미 방에 있다
    user('u2', '이도현', '팀장'),
    user('u3', '박서연', '사원'),
    user('u4', '최준호'),
    user('u5', '정유나', '사원'),
  ];

  late List<http.Request> requests;

  Session buildSession() {
    final client = MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (path == '/api/teams/t1/members') {
        return http.Response(jsonEncode(teamMembers), 200, headers: json);
      }
      if (path == '/api/position-options') {
        return http.Response(
          jsonEncode([
            {'id': 'p1', 'label': '팀장'},
            {'id': 'p2', 'label': '사원'},
          ]),
          200,
          headers: json,
        );
      }
      if (path == '/api/rooms/r1/invite') {
        final ids = (jsonDecode(request.body)['userIds'] as List)
            .cast<String>();
        return http.Response(
          jsonEncode({
            'id': 'r1',
            'teamId': 't1',
            'type': 'topic',
            'name': '업무자료',
            'isPublic': false,
            'members': [
              for (final m in teamMembers)
                if (m['id'] == 'u1' || ids.contains(m['id'])) m,
            ],
            'createdAt': 0,
          }),
          200,
          headers: json,
        );
      }
      return http.Response('[]', 200, headers: json);
    });
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.serverUrl = serverUrl;
    session.api = ApiClient(baseUrl: serverUrl, token: 't', httpClient: client);
    session.userId = 'u1';
    session.name = '김하나';
    session.currentTeam = Team(id: 't1', name: '팀', createdAt: DateTime.now());
    return session;
  }

  final room = Room(
    id: 'r1',
    teamId: 't1',
    type: RoomType.topic,
    name: '업무자료',
    isPublic: false,
    members: [AppUser.fromJson(teamMembers.first)],
    createdAt: DateTime(2026),
    lastRead: const {},
  );

  setUp(() => requests = []);

  Future<void> pumpDialog(WidgetTester tester, Session session) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog(
                context: context,
                builder: (_) => InviteMembersScreen(
                  session: session,
                  room: room,
                  asDialog: true,
                ),
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
  }

  Finder memberRow(String id) => find.byKey(ValueKey('invite-member-$id'));
  Finder selectedRow(String id) => find.byKey(ValueKey('invite-selected-$id'));

  testWidgets('팀 멤버에 사진·이름·직책이 나오고, 이미 방에 있는 사람은 빠진다', (tester) async {
    await pumpDialog(tester, buildSession());

    expect(find.text('멤버 초대하기'), findsOneWidget);
    expect(find.text('멤버 검색'), findsOneWidget);
    expect(find.text('직책'), findsOneWidget);
    expect(find.text('부서'), findsNothing);
    expect(find.text('직급'), findsNothing);
    expect(find.text('팀 멤버 4'), findsOneWidget);
    expect(find.text('선택된 멤버 0'), findsOneWidget);
    expect(find.text('초대할 멤버를 선택하세요.'), findsOneWidget);
    expect(memberRow('u1'), findsNothing);
    expect(
      find.descendant(of: memberRow('u2'), matching: find.text('팀장')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: memberRow('u3'), matching: find.text('사원')),
      findsOneWidget,
    );
    // 직책이 없는 멤버도 이름만으로 나온다.
    expect(
      find.descendant(of: memberRow('u4'), matching: find.text('최준호')),
      findsOneWidget,
    );
    // 관리자 전용 목록이 아니라 누구나 부를 수 있는 직책 목록을 쓴다.
    expect(requests.map((r) => r.url.path), contains('/api/position-options'));
  });

  testWidgets('고르면 선택된 멤버에 보이고, ✕로 뺄 수 있다', (tester) async {
    await pumpDialog(tester, buildSession());

    await tester.tap(memberRow('u3'));
    await tester.pumpAndSettle();
    expect(find.text('선택된 멤버 1'), findsOneWidget);
    expect(selectedRow('u3'), findsOneWidget);
    expect(find.text('초대하기 (1)'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: selectedRow('u3'),
        matching: find.byIcon(Icons.close),
      ),
    );
    await tester.pumpAndSettle();
    expect(selectedRow('u3'), findsNothing);
    expect(find.text('초대할 멤버를 선택하세요.'), findsOneWidget);
  });

  testWidgets('검색·직책 조건으로 좁히고, 모든 멤버 선택하기는 보이는 멤버만 고른다', (tester) async {
    await pumpDialog(tester, buildSession());

    final reset = find.widgetWithText(OutlinedButton, '검색 조건 초기화');
    expect(tester.widget<OutlinedButton>(reset).onPressed, isNull);

    // 직책: 사원 → 박서연·정유나만.
    await tester.tap(find.byKey(const ValueKey('invite-position')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('사원').last);
    await tester.pumpAndSettle();
    expect(find.text('팀 멤버 2'), findsOneWidget);
    expect(memberRow('u2'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('invite-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('선택된 멤버 2'), findsOneWidget);
    expect(selectedRow('u3'), findsOneWidget);
    expect(selectedRow('u5'), findsOneWidget);

    // 한 번 더 누르면 보이는 멤버를 모두 뺀다.
    await tester.tap(find.byKey(const ValueKey('invite-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('선택된 멤버 0'), findsOneWidget);

    // 이름 검색까지 겹쳐서 아무도 없으면 안내 문구.
    await tester.enterText(find.byKey(const ValueKey('invite-search')), '도현');
    await tester.pumpAndSettle();
    expect(find.text('조회 가능한 멤버가 없습니다.'), findsOneWidget);

    // 초기화 → 조건이 모두 풀리고 드롭다운도 "전체"로.
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(find.text('팀 멤버 4'), findsOneWidget);
    expect(find.text('전체'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('invite-search')))
          .controller!
          .text,
      isEmpty,
    );

    // 직책 없음 항목도 있다(최준호).
    await tester.tap(find.byKey(const ValueKey('invite-position')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('직책 없음').last);
    await tester.pumpAndSettle();
    expect(find.text('팀 멤버 1'), findsOneWidget);
    expect(memberRow('u4'), findsOneWidget);
  });

  testWidgets('초대하기는 선택한 멤버로 요청하고 초대 완료 창을 거쳐 창을 닫는다', (tester) async {
    final session = buildSession();
    await pumpDialog(tester, session);

    final invite = find.widgetWithText(FilledButton, '초대하기');
    expect(tester.widget<FilledButton>(invite).onPressed, isNull);

    await tester.tap(memberRow('u2'));
    await tester.tap(memberRow('u5'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '초대하기 (2)'));
    await tester.pumpAndSettle();

    final post = requests.singleWhere(
      (r) => r.url.path == '/api/rooms/r1/invite',
    );
    expect(jsonDecode(post.body)['userIds'], ['u2', 'u5']);
    // 성공하면 `초대 완료` 창(방 1개짜리 결과)이 뜨고, 확인을 눌러야 두 창이 닫힌다.
    expect(find.text('초대 완료'), findsOneWidget);
    expect(find.text('1개 대화방에 2명을 초대했습니다'), findsOneWidget);
    expect(find.byType(InviteMembersScreen), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '확인'));
    await tester.pumpAndSettle();
    expect(find.text('초대 완료'), findsNothing);
    expect(find.byType(InviteMembersScreen), findsNothing);
  });

  testWidgets('좁은 화면에서는 한 칸 목록과 선택 칩으로 보인다', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: InviteMembersScreen(session: buildSession(), room: room),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('선택된 멤버 0'), findsNothing);
    await tester.tap(memberRow('u3'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, '박서연'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('비공개 토픽만 자물쇠 표시', (tester) async {
    expect(room.isPrivateTopic, isTrue);
    final publicTopic = Room(
      id: 'r2',
      teamId: 't1',
      type: RoomType.topic,
      name: '공지사항',
      members: const [],
      createdAt: DateTime(2026),
      lastRead: const {},
    );
    final privateGroup = Room(
      id: 'r3',
      teamId: 't1',
      type: RoomType.group,
      name: null,
      isPublic: false,
      members: const [],
      createdAt: DateTime(2026),
      lastRead: const {},
    );
    expect(publicTopic.isPrivateTopic, isFalse);
    expect(privateGroup.isPrivateTopic, isFalse);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PrivateTopicLock())),
    );
    expect(find.byKey(const ValueKey('private-topic-lock')), findsOneWidget);
    expect(find.byTooltip('비공개 토픽'), findsOneWidget);
  });
}
