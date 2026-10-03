import 'dart:convert';

import 'package:client/models/app_user.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/desktop_home_screen.dart';
import 'package:client/screens/invite_members_screen.dart';
import 'package:client/screens/invite_rooms_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/invite_result_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 여러 토픽/그룹채팅에 한 번에 초대(사이드바 토픽 [+] 메뉴) — 멤버 고르기("다음") → 토픽/그룹채팅 선택 →
/// 초대 완료, 그리고 단건 멤버 초대가 같은 '초대 완료' 창을 띄우는지.
class _Quiet extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

void main() {
  const serverUrl = 'https://192.168.0.10:3000';

  Map<String, dynamic> user(String id, String name, [String? position]) => {
    'id': id,
    'username': 'user_$id',
    'name': name,
    'role': 'member',
    'position': ?position,
  };

  final people = {
    'me': user('me', '김하나', '팀장'),
    'u2': user('u2', '이도현', '팀장'),
    'u3': user('u3', '박서연', '사원'),
    'u4': user('u4', '최준호'),
    'u5': user('u5', '정유나', '사원'),
  };

  Map<String, dynamic> roomJson(
    String id, {
    required String type,
    String? name,
    required List<String> members,
    Map<String, dynamic> extra = const {},
  }) => {
    'id': id,
    'teamId': 't1',
    'type': type,
    'name': name,
    'members': [for (final m in members) people[m]],
    'createdAt': 1000,
    ...extra,
  };

  http.Response json(Object? body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );

  late List<http.Request> requests;
  late http.Response Function(http.Request) bulkRoute;

  List<http.Request> called(String path) => [
    for (final r in requests)
      if (r.url.path == path) r,
  ];

  Session buildSession({AccountRole role = AccountRole.member}) {
    final client = MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (path == '/api/teams/t1/members') return json(people.values.toList());
      if (path == '/api/position-options') return json(<Object>[]);
      if (path == '/api/rooms/invite-bulk') return bulkRoute(request);
      if (path == '/api/rooms/r-single/invite') {
        return json(
          roomJson(
            'r-single',
            type: 'topic',
            name: '업무자료',
            members: ['me', 'u3'],
            extra: {'isPublic': false},
          ),
        );
      }
      return json(<Object>[]);
    });
    final session = Session(notifications: _Quiet(), settings: AppSettings());
    session.serverUrl = serverUrl;
    session.api = ApiClient(baseUrl: serverUrl, token: 't', httpClient: client);
    session.userId = 'me';
    session.name = '김하나';
    session.accountRole = role;
    final team = Team(id: 't1', name: '팀', createdAt: DateTime(2026));
    session.teams.add(team);
    session.currentTeam = team;
    session.rooms.addAll([
      // 두 사람(u2,u3)이 모두 참여 중 → 이미 참여중
      Room.fromJson(
        roomJson(
          'tFull',
          type: 'topic',
          name: '전원 참여 토픽',
          members: ['me', 'u2', 'u3'],
        ),
      ),
      // 일부(u2)만 참여 중
      Room.fromJson(
        roomJson(
          'tPart',
          type: 'topic',
          name: '일부 참여 토픽',
          members: ['me', 'u2'],
          extra: {'isPublic': false},
        ),
      ),
      Room.fromJson(
        roomJson('tNone', type: 'topic', name: '마케팅', members: ['me']),
      ),
      Room.fromJson(
        roomJson(
          'tArch',
          type: 'topic',
          name: '지난 프로젝트',
          members: ['me', 'u4'],
          extra: {'archivedAt': 5000},
        ),
      ),
      Room.fromJson(
        roomJson('gA', type: 'group', name: '점심 모임', members: ['me', 'u5']),
      ),
      // 이름 없는 그룹 — 멤버 이름으로 보인다
      Room.fromJson(roomJson('gB', type: 'group', members: ['me', 'u4', 'u5'])),
      // 후보가 아닌 방들
      Room.fromJson(roomJson('dm1', type: 'dm', members: ['me', 'u2'])),
      Room.fromJson(
        roomJson('self1', type: 'dm', members: ['me'], extra: {'isSelf': true}),
      ),
      Room.fromJson(
        roomJson(
          'sec1',
          type: 'dm',
          members: ['me', 'u2'],
          extra: {'isSecret': true},
        ),
      ),
      Room.fromJson(
        roomJson('notMine', type: 'topic', name: '남의 토픽', members: ['u2']),
      ),
      Room.fromJson(
        roomJson(
          'otherTeam',
          type: 'topic',
          name: '다른 팀 토픽',
          members: ['me'],
          extra: {'teamId': 't2'},
        ),
      ),
    ]);
    return session;
  }

  setUp(() {
    requests = [];
    bulkRoute = (r) => json({'results': <Object>[]});
  });

  Future<void> pumpHost(
    WidgetTester tester,
    Session session, {
    Size size = const Size(1280, 900),
    Future<void> Function(BuildContext, Session)? open,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  (open ?? showInviteToMultipleRooms)(context, session),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
  }

  Finder key(String k) => find.byKey(ValueKey(k));
  Finder memberRow(String id) => key('invite-member-$id');

  Future<void> pickMembersAndNext(WidgetTester tester, List<String> ids) async {
    for (final id in ids) {
      await tester.tap(memberRow(id));
    }
    await tester.pumpAndSettle();
    await tester.tap(key('pick-members-confirm'));
    await tester.pumpAndSettle();
  }

  group('사이드바 토픽 [+] 메뉴', () {
    Future<void> pumpDesktop(WidgetTester tester, Session session) async {
      tester.view.physicalSize = const Size(1400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: DesktopHomeScreen(session: session)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('정회원에게는 "여러 토픽/그룹채팅에 초대"가 있고 누르면 멤버 초대하기 창이 뜬다', (
      tester,
    ) async {
      await pumpDesktop(tester, buildSession());
      await tester.tap(find.byTooltip('토픽 추가'));
      await tester.pumpAndSettle();
      expect(find.text('여러 토픽/그룹채팅에 초대'), findsOneWidget);

      await tester.tap(find.text('여러 토픽/그룹채팅에 초대'));
      await tester.pumpAndSettle();
      expect(find.text('멤버 초대하기'), findsOneWidget);
      expect(find.byType(PickMembersScreen), findsOneWidget);
      // 하단 버튼은 "초대하기"가 아니라 "다음".
      expect(find.widgetWithText(FilledButton, '다음'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '초대하기'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('준회원에게는 메뉴 항목이 없다', (tester) async {
      await pumpDesktop(tester, buildSession(role: AccountRole.guest));
      await tester.tap(find.byTooltip('토픽 추가'));
      await tester.pumpAndSettle();
      expect(find.text('폴더 생성'), findsOneWidget);
      expect(find.text('여러 토픽/그룹채팅에 초대'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('초대 3단계 흐름', () {
    testWidgets('1단계: 다음 버튼은 멤버를 1명 이상 골라야 켜진다', (tester) async {
      await pumpHost(tester, buildSession());
      expect(find.text('멤버 초대하기'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '다음'))
            .onPressed,
        isNull,
      );
      // 나는 목록에 없다.
      expect(memberRow('me'), findsNothing);
      await tester.tap(memberRow('u2'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '다음 (1)'))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('2단계: 토픽/그룹 묶음, 이미 참여중·N명 참여중·보관됨, 후보 아닌 방은 빠진다', (
      tester,
    ) async {
      await pumpHost(tester, buildSession());
      await pickMembersAndNext(tester, ['u2', 'u3']);

      expect(find.text('토픽/그룹채팅 선택'), findsOneWidget);
      expect(key('invite-rooms-members-count'), findsOneWidget);
      expect(find.text('2명'), findsWidgets);
      expect(find.text('토픽 4'), findsOneWidget);
      expect(find.text('그룹채팅 2'), findsOneWidget);

      // 후보가 아닌 방
      expect(find.text('남의 토픽'), findsNothing);
      expect(find.text('다른 팀 토픽'), findsNothing);
      expect(key('invite-room-dm1'), findsNothing);
      expect(key('invite-room-self1'), findsNothing);
      expect(key('invite-room-sec1'), findsNothing);

      // 상태 표시
      expect(find.text('이미 참여중'), findsOneWidget);
      expect(find.text('1명 참여중'), findsOneWidget);
      expect(key('invite-room-archived-tArch'), findsOneWidget);
      expect(find.text('보관됨'), findsOneWidget);
      // 이름 없는 그룹은 멤버 이름으로
      expect(find.text('정유나, 최준호'), findsOneWidget);
      // 멤버 수
      expect(find.text('3명'), findsWidgets);

      // 이미 참여중인 방은 비활성 — 눌러도 선택되지 않는다.
      await tester.tap(key('invite-room-tFull'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(key('invite-rooms-submit')).onPressed,
        isNull,
      );
    });

    testWidgets('방을 고르면 초대하기가 켜지고, 묶음 체크박스는 고를 수 있는 방만 한꺼번에 고른다', (
      tester,
    ) async {
      await pumpHost(tester, buildSession());
      await pickMembersAndNext(tester, ['u2', 'u3']);

      await tester.tap(key('invite-room-tNone'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, '초대하기 (1)'), findsOneWidget);

      // 토픽 묶음 전체 선택 — 일부 선택 상태에서 누르면 나머지(고를 수 있는 것)까지 채운다.
      await tester.tap(key('invite-rooms-section-topic'));
      await tester.pumpAndSettle();
      // tNone, tPart, tArch (tFull 제외)
      expect(find.widgetWithText(FilledButton, '초대하기 (3)'), findsOneWidget);
      await tester.tap(key('invite-rooms-section-topic'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, '초대하기'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(key('invite-rooms-submit')).onPressed,
        isNull,
      );
    });

    testWidgets('검색칸은 이름으로 거른다', (tester) async {
      await pumpHost(tester, buildSession());
      await pickMembersAndNext(tester, ['u2']);
      await tester.enterText(key('invite-rooms-search'), '점심');
      await tester.pumpAndSettle();
      expect(find.text('점심 모임'), findsOneWidget);
      expect(find.text('마케팅'), findsNothing);
      expect(find.text('토픽 1'), findsNothing);
      await tester.enterText(key('invite-rooms-search'), '없는이름');
      await tester.pumpAndSettle();
      expect(find.text('검색 결과가 없습니다.'), findsOneWidget);
    });

    testWidgets('이전은 멤버 고르기로 돌아가고 고른 멤버가 유지된다', (tester) async {
      await pumpHost(tester, buildSession());
      await pickMembersAndNext(tester, ['u2', 'u3']);
      await tester.tap(key('invite-room-tNone'));
      await tester.pumpAndSettle();

      await tester.tap(key('invite-rooms-back'));
      await tester.pumpAndSettle();
      expect(find.text('멤버 초대하기'), findsOneWidget);
      expect(find.text('토픽/그룹채팅 선택'), findsNothing);
      expect(key('invite-selected-u2'), findsOneWidget);
      expect(key('invite-selected-u3'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '다음 (2)'), findsOneWidget);
      expect(called('/api/rooms/invite-bulk'), isEmpty);

      // 멤버를 바꾸고 다시 다음으로.
      await tester.tap(memberRow('u3'));
      await tester.pumpAndSettle();
      await tester.tap(key('pick-members-confirm'));
      await tester.pumpAndSettle();
      expect(find.text('1명'), findsWidgets);
    });

    testWidgets('초대하기는 invite-bulk로 요청하고 초대 완료 창에 방별 결과를 보여 준다', (
      tester,
    ) async {
      bulkRoute = (r) => json({
        'results': [
          {
            'roomId': 'tNone',
            'roomName': '마케팅',
            'roomType': 'topic',
            'invited': [
              {'userId': 'u2', 'name': '이도현'},
              {'userId': 'u3', 'name': '박서연'},
            ],
            'alreadyMembers': <Object>[],
            'failed': <Object>[],
          },
          {
            'roomId': 'tPart',
            'roomName': '일부 참여 토픽',
            'roomType': 'topic',
            'invited': [
              {'userId': 'u3', 'name': '박서연'},
            ],
            'alreadyMembers': [
              {'userId': 'u2', 'name': '이도현'},
            ],
            'failed': <Object>[],
          },
          {
            'roomId': 'gA',
            'roomName': '점심 모임',
            'roomType': 'group',
            'invited': <Object>[],
            'alreadyMembers': <Object>[],
            'failed': [
              {'userId': 'u2', 'name': '이도현', 'reason': '이 팀의 멤버가 아닙니다.'},
            ],
          },
        ],
      });
      final session = buildSession();
      await pumpHost(tester, session);
      await pickMembersAndNext(tester, ['u2', 'u3']);
      await tester.tap(key('invite-room-tNone'));
      await tester.tap(key('invite-room-tPart'));
      await tester.tap(key('invite-room-gA'));
      await tester.pumpAndSettle();
      await tester.tap(key('invite-rooms-submit'));
      await tester.pumpAndSettle();

      final post = called('/api/rooms/invite-bulk').single;
      final body = jsonDecode(post.body) as Map<String, dynamic>;
      expect(body['teamId'], 't1');
      expect(body['userIds'], ['u2', 'u3']);
      expect((body['roomIds'] as List).toSet(), {'tNone', 'tPart', 'gA'});

      // 초대 완료 창
      expect(find.text('초대 완료'), findsOneWidget);
      expect(find.text('토픽/그룹채팅 선택'), findsNothing);
      expect(
        tester.widget<Text>(key('invite-result-summary')).data,
        '2개 대화방에 2명을 초대했습니다',
      );
      // 방 전체가 건너뛰어진 게 아니라 사람만 실패한 경우는 "초대하지 못했습니다" 줄이 없다.
      expect(key('invite-result-skipped'), findsNothing);
      expect(find.text('마케팅'), findsOneWidget);
      expect(find.text('일부 참여 토픽'), findsOneWidget);
      expect(find.text('점심 모임'), findsOneWidget);
      expect(find.textContaining('이도현, 박서연'), findsOneWidget);
      expect(find.textContaining('이미 참여중'), findsOneWidget);
      expect(find.textContaining('이도현 — 이 팀의 멤버가 아닙니다.'), findsOneWidget);
      expect(find.text('토픽'), findsWidgets);
      expect(find.text('그룹채팅'), findsWidgets);

      await tester.tap(key('invite-result-confirm'));
      await tester.pumpAndSettle();
      expect(find.text('초대 완료'), findsNothing);
      expect(find.byType(InviteRoomsDialog), findsNothing);
    });

    testWidgets('요청이 실패하면 창 안에 오류 문구가 보이고 창은 그대로다', (tester) async {
      bulkRoute = (r) => json({'error': '멤버를 초대할 권한이 없습니다.'}, 403);
      await pumpHost(tester, buildSession());
      await pickMembersAndNext(tester, ['u2']);
      await tester.tap(key('invite-room-tNone'));
      await tester.pumpAndSettle();
      await tester.tap(key('invite-rooms-submit'));
      await tester.pumpAndSettle();

      expect(find.text('멤버를 초대할 권한이 없습니다.'), findsOneWidget);
      expect(find.text('토픽/그룹채팅 선택'), findsOneWidget);
      expect(find.text('초대 완료'), findsNothing);
      // 다시 시도할 수 있다.
      expect(
        tester.widget<FilledButton>(key('invite-rooms-submit')).onPressed,
        isNotNull,
      );
    });

    testWidgets('좁은 창(420px)에서도 넘치지 않는다', (tester) async {
      await pumpHost(
        tester,
        buildSession(),
        size: const Size(420, 800),
        open: (context, session) => showDialog<void>(
          context: context,
          builder: (_) => InviteRoomsDialog(
            session: session,
            users: [
              for (final id in ['u2', 'u3', 'u4', 'u5'])
                AppUser.fromJson(people[id]!),
            ],
          ),
        ),
      );
      expect(find.text('토픽/그룹채팅 선택'), findsOneWidget);
      expect(find.text('4명'), findsWidgets);
      await tester.tap(key('invite-rooms-section-group'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, '초대하기 (2)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('초대 완료 창', () {
    testWidgets('이름이 길면 "외 N명", 방 전체 실패는 사유를 빨간 글씨로 보여 준다', (tester) async {
      final session = buildSession();
      tester.view.physicalSize = const Size(380, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final invited = [
        for (var i = 1; i <= 5; i++) InvitePerson(userId: 'x$i', name: '멤버$i'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showInviteResultDialog(
                  context,
                  session: session,
                  results: [
                    RoomInviteResult(
                      roomId: 'tNone',
                      roomName: '아주 긴 이름의 토픽이 이렇게 길어서 두 줄이 넘어갈 수도 있습니다 정말로',
                      roomType: RoomType.topic,
                      invited: invited,
                    ),
                    const RoomInviteResult(
                      roomId: 'zzz',
                      roomName: '남의 방',
                      error: 'notMember',
                    ),
                    const RoomInviteResult(
                      roomId: 'gA',
                      roomName: '점심 모임',
                      roomType: RoomType.group,
                      alreadyMembers: [InvitePerson(userId: 'u2', name: '이도현')],
                    ),
                  ],
                ),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();

      expect(find.textContaining('멤버1, 멤버2, 멤버3 외 2명'), findsOneWidget);
      expect(
        tester.widget<Text>(key('invite-result-summary')).data,
        '1개 대화방에 5명을 초대했습니다',
      );
      expect(find.text('내가 참여 중인 대화방이 아니어서 초대하지 못했습니다.'), findsOneWidget);
      expect(find.text('1개 대화방은 초대하지 못했습니다.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('inviteResultSummary / inviteNamesText', () {
      expect(inviteResultSummary(const []), '새로 초대된 멤버가 없습니다');
      expect(
        inviteResultSummary(const [
          RoomInviteResult(
            roomId: 'a',
            alreadyMembers: [InvitePerson(userId: 'u', name: '가')],
          ),
        ]),
        '새로 초대된 멤버가 없습니다',
      );
      // 같은 사람이 여러 방에 초대돼도 사람 수는 한 번만 센다.
      expect(
        inviteResultSummary(const [
          RoomInviteResult(
            roomId: 'a',
            invited: [InvitePerson(userId: 'u', name: '가')],
          ),
          RoomInviteResult(
            roomId: 'b',
            invited: [InvitePerson(userId: 'u', name: '가')],
          ),
        ]),
        '2개 대화방에 1명을 초대했습니다',
      );
      expect(
        inviteNamesText(const [
          InvitePerson(userId: '1', name: 'A'),
          InvitePerson(userId: '2', name: 'B'),
        ]),
        'A, B',
      );
    });
  });

  group('단건 멤버 초대도 초대 완료 창을 쓴다', () {
    testWidgets('토픽 멤버 초대하기 → 초대 완료(방 1개) → 확인하면 두 창이 모두 닫힌다', (tester) async {
      final session = buildSession();
      final room = Room.fromJson(
        roomJson(
          'r-single',
          type: 'topic',
          name: '업무자료',
          members: ['me'],
          extra: {'isPublic': false},
        ),
      );
      await pumpHost(
        tester,
        session,
        open: (context, s) => showInviteMembers(context, s, room),
      );
      await tester.tap(memberRow('u3'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '초대하기 (1)'));
      await tester.pumpAndSettle();

      expect(find.text('초대 완료'), findsOneWidget);
      expect(find.byType(InviteMembersScreen), findsOneWidget); // 아래에 아직 있다
      expect(
        tester.widget<Text>(key('invite-result-summary')).data,
        '1개 대화방에 1명을 초대했습니다',
      );
      expect(find.text('업무자료'), findsOneWidget);
      expect(find.textContaining('박서연'), findsWidgets);

      await tester.tap(key('invite-result-confirm'));
      await tester.pumpAndSettle();
      expect(find.text('초대 완료'), findsNothing);
      expect(find.byType(InviteMembersScreen), findsNothing);
    });
  });
}
