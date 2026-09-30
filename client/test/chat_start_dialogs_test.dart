import 'dart:async';
import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/group_settings_dialog.dart';
import 'package:client/screens/new_group_dialog.dart';
import 'package:client/screens/start_chat_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/floating_dialog.dart';
import 'package:client/widgets/group_icon_picker.dart';
import 'package:client/widgets/icon_edit_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 채팅 시작하기 · 새 그룹채팅 만들기(멤버 선택 창 포함) · 채팅 정보 변경 — 넓은 화면은 떠 있는 창,
/// 좁은 화면은 전체 화면이고, 고른 값이 그대로 요청에 실린다.
void main() {
  const serverUrl = 'https://192.168.0.10:3000';

  Map<String, dynamic> user(String id, String name, [String? position]) => {
    'id': id,
    'username': 'user_$id',
    'name': name,
    'role': 'member',
    'position': ?position,
  };

  final teamMembers = [
    user('me', '김하나', '팀장'),
    user('u2', '이도현', '팀장'),
    user('u3', '박서연', '사원'),
    user('u4', '최준호'),
    user('u5', '정유나', '사원'),
  ];

  Map<String, dynamic> roomJson(
    String id, {
    required String type,
    String? name,
    List<String> memberIds = const [],
    Map<String, dynamic> extra = const {},
  }) => {
    'id': id,
    'teamId': 't1',
    'type': type,
    'name': name,
    'members': [
      for (final m in teamMembers)
        if (m['id'] == 'me' || memberIds.contains(m['id'])) m,
    ],
    'createdAt': 1000,
    ...extra,
  };

  http.Response json(Object? body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );

  late List<http.Request> requests;

  /// 테스트마다 바꿔 끼우는 응답(`'METHOD /path'` → 응답) — 없으면 아래 기본 응답.
  late Map<String, FutureOr<http.Response> Function(http.Request)> routes;

  List<http.Request> called(String method, String path) => [
    for (final r in requests)
      if (r.method == method && r.url.path == path) r,
  ];
  Map<String, dynamic> bodyOf(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  Session buildSession({AccountRole role = AccountRole.member}) {
    final client = MockClient((request) async {
      requests.add(request);
      final key = '${request.method} ${request.url.path}';
      final route = routes[key];
      if (route != null) return await route(request);
      switch (key) {
        case 'GET /api/teams/t1/members':
          return json(teamMembers);
        case 'GET /api/position-options':
          return json([
            {'id': 'p1', 'label': '팀장'},
            {'id': 'p2', 'label': '사원'},
          ]);
        case 'POST /api/rooms/dm':
          final target = bodyOf(request)['targetUserId'] as String;
          return json(
            roomJson('dm-$target', type: 'dm', memberIds: [target]),
            201,
          );
        case 'POST /api/rooms':
          final body = bodyOf(request);
          return json(
            roomJson(
              'g-new',
              type: 'group',
              name: body['name'] as String?,
              memberIds: (body['memberIds'] as List).cast<String>(),
              extra: {
                'description': body['description'],
                'iconType': body['iconType'],
                'iconEmoji': body['iconEmoji'],
                'iconColor': body['iconColor'],
              },
            ),
            201,
          );
        case 'POST /api/rooms/self':
          return json(roomJson('self-t1', type: 'dm', extra: {'isSelf': true}));
      }
      return json(<Object>[]);
    });
    final session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.serverUrl = serverUrl;
    session.api = ApiClient(baseUrl: serverUrl, token: 't', httpClient: client);
    session.userId = 'me';
    session.name = '김하나';
    session.accountRole = role;
    final team = Team(id: 't1', name: '팀', createdAt: DateTime(2026));
    session.teams.add(team);
    session.currentTeam = team;
    return session;
  }

  setUp(() {
    requests = [];
    routes = {};
  });

  /// 버튼 하나짜리 화면을 띄우고 눌러서 [open]을 부른다. [size]가 700보다 좁으면 전체 화면으로 열린다.
  Future<void> pumpHost(
    WidgetTester tester,
    void Function(BuildContext context) open, {
    Size size = const Size(1280, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => open(context),
                child: const Text('열기'),
              ),
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
  Finder byKey(String key) => find.byKey(ValueKey(key));
  VoidCallback? onPressedOf(WidgetTester tester, String key) =>
      tester.widget<ButtonStyleButton>(byKey(key)).onPressed;

  group('채팅 시작하기', () {
    testWidgets(
      '넓은 화면은 떠 있는 창 — 나와의 대화가 맨 위에 고정되고, 나는 목록에 없고, 모든 멤버 선택하기는 없다',
      (tester) async {
        final session = buildSession();
        await pumpHost(
          tester,
          (c) => showStartChatDialog(c, session, onOpenRoom: (_) {}),
        );

        expect(find.byType(FloatingDialog), findsOneWidget);
        expect(find.text('채팅 시작하기'), findsOneWidget);
        expect(byKey('start-chat-self'), findsOneWidget);
        expect(
          find.descendant(
            of: byKey('start-chat-self'),
            matching: find.text('나와의 대화'),
          ),
          findsOneWidget,
        );
        expect(memberRow('me'), findsNothing);
        expect(memberRow('u2'), findsOneWidget);
        expect(find.text('팀 멤버 4'), findsOneWidget);
        expect(find.text('모든 멤버 선택하기'), findsNothing);
        expect(byKey('invite-select-all'), findsNothing);
        expect(find.text('멤버 검색'), findsOneWidget);
        expect(find.text('직책'), findsOneWidget);
        expect(find.text('대화할 멤버를 선택하세요.'), findsOneWidget);
        expect(find.text('1명은 1:1 채팅, 2명 이상은 그룹채팅으로 만들어요.'), findsOneWidget);
        expect(onPressedOf(tester, 'start-chat-secret'), isNull);
        expect(onPressedOf(tester, 'start-chat-submit'), isNull);
      },
    );

    testWidgets('나와의 대화 줄은 누르면 바로 연다 — 목록에 있으면 요청 없이 그 방', (tester) async {
      final session = buildSession();
      final self = Room.fromJson(
        roomJson('self-t1', type: 'dm', extra: {'isSelf': true}),
      );
      session.rooms.add(self);
      Room? opened;
      await pumpHost(
        tester,
        (c) => showStartChatDialog(c, session, onOpenRoom: (r) => opened = r),
      );

      await tester.tap(byKey('start-chat-self'));
      await tester.pumpAndSettle();

      expect(opened, same(self));
      expect(called('POST', '/api/rooms/self'), isEmpty);
      expect(find.byType(FloatingDialog), findsNothing);
    });

    testWidgets('나와의 대화가 아직 목록에 없으면 서버에서 받아 연다', (tester) async {
      final session = buildSession();
      Room? opened;
      await pumpHost(
        tester,
        (c) => showStartChatDialog(c, session, onOpenRoom: (r) => opened = r),
      );

      await tester.tap(byKey('start-chat-self'));
      await tester.pumpAndSettle();

      final post = called('POST', '/api/rooms/self').single;
      expect(bodyOf(post), {'teamId': 't1'});
      expect(opened?.isSelf, isTrue);
      expect(session.selfRoom, same(opened));
      expect(find.byType(FloatingDialog), findsNothing);
    });

    testWidgets('1명이면 1:1 채팅 — 비밀 대화 시작은 정확히 1명일 때만 켜진다', (tester) async {
      final session = buildSession();
      Room? opened;
      await pumpHost(
        tester,
        (c) => showStartChatDialog(c, session, onOpenRoom: (r) => opened = r),
      );

      await tester.tap(memberRow('u3'));
      await tester.pumpAndSettle();
      expect(selectedRow('u3'), findsOneWidget);
      expect(onPressedOf(tester, 'start-chat-secret'), isNotNull);
      expect(onPressedOf(tester, 'start-chat-submit'), isNotNull);

      await tester.tap(memberRow('u2'));
      await tester.pumpAndSettle();
      expect(onPressedOf(tester, 'start-chat-secret'), isNull);
      await tester.tap(memberRow('u2'));
      await tester.pumpAndSettle();
      expect(onPressedOf(tester, 'start-chat-secret'), isNotNull);

      await tester.tap(byKey('start-chat-submit'));
      await tester.pumpAndSettle();

      final post = called('POST', '/api/rooms/dm').single;
      expect(bodyOf(post), {'teamId': 't1', 'targetUserId': 'u3'});
      expect(called('POST', '/api/rooms'), isEmpty);
      expect(opened?.type, RoomType.dm);
      expect(opened?.id, 'dm-u3');
      expect(find.byType(FloatingDialog), findsNothing);
    });

    testWidgets('2명 이상이면 기본값(이름·아이콘 없음)의 그룹채팅을 고른 순서대로 만든다', (tester) async {
      final session = buildSession();
      Room? opened;
      await pumpHost(
        tester,
        (c) => showStartChatDialog(c, session, onOpenRoom: (r) => opened = r),
      );

      await tester.tap(memberRow('u5'));
      await tester.tap(memberRow('u2'));
      await tester.pumpAndSettle();
      expect(find.text('선택된 멤버 2'), findsOneWidget);

      await tester.tap(byKey('start-chat-submit'));
      await tester.pumpAndSettle();

      final body = bodyOf(called('POST', '/api/rooms').single);
      expect(body['type'], 'group');
      expect(body['memberIds'], ['u5', 'u2']);
      expect(body.containsKey('name'), isFalse);
      expect(body.containsKey('description'), isFalse);
      expect(body.containsKey('iconType'), isFalse);
      expect(called('POST', '/api/rooms/dm'), isEmpty);
      expect(opened?.type, RoomType.group);
    });

    testWidgets('검색·직책 조건으로 좁혀도 나와의 대화 줄은 그대로 남는다', (tester) async {
      final session = buildSession();
      await pumpHost(
        tester,
        (c) => showStartChatDialog(c, session, onOpenRoom: (_) {}),
      );

      await tester.enterText(byKey('invite-search'), '서연');
      await tester.pumpAndSettle();
      expect(find.text('팀 멤버 1'), findsOneWidget);
      expect(memberRow('u3'), findsOneWidget);
      expect(byKey('start-chat-self'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, '검색 조건 초기화'));
      await tester.pumpAndSettle();
      expect(find.text('팀 멤버 4'), findsOneWidget);

      await tester.tap(byKey('invite-position'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('사원').last);
      await tester.pumpAndSettle();
      expect(find.text('팀 멤버 2'), findsOneWidget);
      expect(memberRow('u2'), findsNothing);
      expect(byKey('start-chat-self'), findsOneWidget);
    });

    testWidgets('서버가 거절하면 창을 닫지 않고 이유를 보여준다', (tester) async {
      routes['POST /api/rooms/dm'] = (_) =>
          json({'error': '대화를 시작할 수 없는 멤버입니다.'}, 403);
      final session = buildSession();
      Room? opened;
      await pumpHost(
        tester,
        (c) => showStartChatDialog(c, session, onOpenRoom: (r) => opened = r),
      );

      await tester.tap(memberRow('u2'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('start-chat-submit'));
      await tester.pumpAndSettle();

      expect(opened, isNull);
      expect(find.byType(FloatingDialog), findsOneWidget);
      expect(find.text('대화를 시작할 수 없는 멤버입니다.'), findsOneWidget);
      // 다시 누를 수 있다.
      expect(onPressedOf(tester, 'start-chat-submit'), isNotNull);
    });

    testWidgets('팀 멤버를 못 받아와도 나와의 대화 줄은 남고, 다시 시도하면 목록이 보인다', (tester) async {
      var fail = true;
      routes['GET /api/teams/t1/members'] = (_) =>
          fail ? json({'error': '팀 멤버를 불러오지 못했습니다.'}, 500) : json(teamMembers);
      final session = buildSession();
      await pumpHost(
        tester,
        (c) => showStartChatDialog(c, session, onOpenRoom: (_) {}),
      );

      expect(find.text('팀 멤버를 불러오지 못했습니다.'), findsOneWidget);
      expect(memberRow('u2'), findsNothing);
      expect(byKey('start-chat-self'), findsOneWidget);

      fail = false;
      await tester.tap(byKey('member-picker-retry'));
      await tester.pumpAndSettle();
      expect(memberRow('u2'), findsOneWidget);
      expect(find.text('팀 멤버를 불러오지 못했습니다.'), findsNothing);
      expect(byKey('start-chat-self'), findsOneWidget);
    });

    testWidgets('팀 멤버를 받는 중에도 나와의 대화 줄은 먼저 보인다', (tester) async {
      final session = buildSession();
      final self = Room.fromJson(
        roomJson('self-t1', type: 'dm', extra: {'isSelf': true}),
      );
      session.rooms.add(self);
      final members = Completer<http.Response>();
      routes['GET /api/teams/t1/members'] = (_) => members.future;
      Room? opened;
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => TextButton(
              onPressed: () => showStartChatDialog(
                c,
                session,
                onOpenRoom: (r) => opened = r,
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(byKey('start-chat-self'), findsOneWidget);
      await tester.tap(byKey('start-chat-self'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(opened, same(self));
      members.complete(json(teamMembers));
      await tester.pumpAndSettle();
    });

    testWidgets('준회원은 멤버를 고를 수 없고 나와의 대화만 열 수 있다', (tester) async {
      final session = buildSession(role: AccountRole.guest);
      final self = Room.fromJson(
        roomJson('self-t1', type: 'dm', extra: {'isSelf': true}),
      );
      session.rooms.add(self);
      Room? opened;
      await pumpHost(
        tester,
        (c) => showStartChatDialog(c, session, onOpenRoom: (r) => opened = r),
      );

      expect(find.text('준회원은 대화를 시작할 수 없어요. 나와의 대화만 열 수 있어요.'), findsOneWidget);
      await tester.tap(memberRow('u2'));
      await tester.pumpAndSettle();
      expect(selectedRow('u2'), findsNothing);
      expect(find.text('선택된 멤버 0'), findsOneWidget);
      expect(onPressedOf(tester, 'start-chat-submit'), isNull);
      expect(onPressedOf(tester, 'start-chat-secret'), isNull);

      await tester.tap(byKey('start-chat-self'));
      await tester.pumpAndSettle();
      expect(opened, same(self));
    });

    testWidgets('좁은 화면은 전체 화면 — 360px에서도 넘치지 않고, 만든 방을 연다', (tester) async {
      final session = buildSession();
      Room? opened;
      await pumpHost(
        tester,
        (c) => showStartChatDialog(c, session, onOpenRoom: (r) => opened = r),
        size: const Size(360, 740),
      );

      expect(find.byType(FloatingDialog), findsNothing);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('채팅 시작하기'),
        ),
        findsOneWidget,
      );
      expect(byKey('start-chat-self'), findsOneWidget);

      await tester.tap(memberRow('u2'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(InputChip, '이도현'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(memberRow('u3'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(byKey('start-chat-submit'));
      await tester.pumpAndSettle();
      expect(called('POST', '/api/rooms'), hasLength(1));
      expect(opened?.type, RoomType.group);
      expect(find.byType(AppBar), findsNothing);
    });
  });

  group('새 그룹채팅 만들기', () {
    testWidgets('멤버 없이 생성하면 안내만 하고 요청하지 않는다', (tester) async {
      final session = buildSession();
      await pumpHost(
        tester,
        (c) => showNewGroupDialog(c, session, onOpenRoom: (_) {}),
      );

      expect(find.byType(FloatingDialog), findsOneWidget);
      expect(find.text('새 그룹채팅 만들기'), findsOneWidget);
      expect(find.text('그룹 아이콘'), findsOneWidget);
      expect(find.text('0/60'), findsOneWidget);
      expect(find.text('0/300'), findsOneWidget);
      expect(find.text('비워 두면 멤버 이름으로 표시돼요'), findsOneWidget);
      expect(find.text('멤버를 한 명 이상 선택하세요.'), findsNothing);

      await tester.tap(byKey('new-group-submit'));
      await tester.pumpAndSettle();

      expect(find.text('멤버를 한 명 이상 선택하세요.'), findsOneWidget);
      expect(called('POST', '/api/rooms'), isEmpty);
      expect(find.byType(FloatingDialog), findsOneWidget);
    });

    testWidgets('멤버 선택 창을 오가면 고른 멤버가 미리 선택돼 있고, 취소하면 그대로다', (tester) async {
      final session = buildSession();
      await pumpHost(
        tester,
        (c) => showNewGroupDialog(c, session, onOpenRoom: (_) {}),
      );

      // 안내가 떠 있다가 멤버를 고르면 사라진다.
      await tester.tap(byKey('new-group-submit'));
      await tester.pumpAndSettle();

      await tester.tap(byKey('new-group-pick-members'));
      await tester.pumpAndSettle();
      expect(find.text('멤버 선택'), findsWidgets);
      expect(find.byType(FloatingDialog), findsNWidgets(2));
      expect(memberRow('me'), findsNothing);
      // 멤버 선택은 멤버 초대하기처럼 모든 멤버 선택하기가 있다.
      expect(byKey('invite-select-all'), findsOneWidget);
      await tester.tap(memberRow('u3'));
      await tester.tap(memberRow('u2'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '확인 (2)'));
      await tester.pumpAndSettle();

      expect(find.byType(FloatingDialog), findsOneWidget);
      expect(byKey('new-group-member-u3'), findsOneWidget);
      expect(byKey('new-group-member-u2'), findsOneWidget);
      expect(find.text('멤버를 한 명 이상 선택하세요.'), findsNothing);
      expect(find.text('멤버  2명', findRichText: true), findsOneWidget);

      // 다시 열면 고른 두 명이 미리 선택돼 있다.
      await tester.tap(byKey('new-group-pick-members'));
      await tester.pumpAndSettle();
      expect(find.text('선택된 멤버 2'), findsOneWidget);
      expect(selectedRow('u3'), findsOneWidget);
      expect(selectedRow('u2'), findsOneWidget);
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(
                of: memberRow('u3'),
                matching: find.byType(Checkbox),
              ),
            )
            .value,
        isTrue,
      );
      // 한 명 빼고 한 명 더해서 확인 → 칩이 바뀐다(고른 순서).
      await tester.tap(memberRow('u2'));
      await tester.tap(memberRow('u4'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '확인 (2)'));
      await tester.pumpAndSettle();
      expect(byKey('new-group-member-u2'), findsNothing);
      expect(byKey('new-group-member-u4'), findsOneWidget);
      final chips = tester
          .widgetList<InputChip>(find.byType(InputChip))
          .map((c) => (c.key! as ValueKey<String>).value)
          .toList();
      expect(chips, ['new-group-member-u3', 'new-group-member-u4']);

      // 멤버 선택 창에서 바꿨다가 취소하면 그대로다.
      await tester.tap(byKey('new-group-pick-members'));
      await tester.pumpAndSettle();
      await tester.tap(memberRow('u5'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '취소').last);
      await tester.pumpAndSettle();
      expect(byKey('new-group-member-u5'), findsNothing);
      expect(find.byType(InputChip), findsNWidgets(2));

      // 칩의 ✕로 뺄 수 있다.
      await tester.tap(
        find.descendant(
          of: byKey('new-group-member-u4'),
          matching: find.byIcon(Icons.clear),
        ),
      );
      await tester.pumpAndSettle();
      expect(byKey('new-group-member-u4'), findsNothing);
    });

    testWidgets('생성하면 이름·설명·멤버·이니셜 아이콘을 보내고 만든 방을 연다', (tester) async {
      final session = buildSession();
      Room? opened;
      await pumpHost(
        tester,
        (c) => showNewGroupDialog(c, session, onOpenRoom: (r) => opened = r),
      );

      await tester.tap(byKey('new-group-pick-members'));
      await tester.pumpAndSettle();
      await tester.tap(memberRow('u2'));
      await tester.tap(memberRow('u3'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('pick-members-confirm'));
      await tester.pumpAndSettle();
      await tester.enterText(byKey('new-group-name'), '  신규 캠페인 ');
      await tester.enterText(byKey('new-group-description'), ' 10월 캠페인 준비 ');
      await tester.pumpAndSettle();

      await tester.tap(byKey('new-group-submit'));
      await tester.pumpAndSettle();

      final body = bodyOf(called('POST', '/api/rooms').single);
      expect(body['type'], 'group');
      expect(body['name'], '신규 캠페인');
      expect(body['description'], '10월 캠페인 준비');
      expect(body['memberIds'], ['u2', 'u3']);
      expect(body['iconType'], 'initial');
      expect(body['iconColor'], matches(RegExp(r'^#[0-9A-F]{6}$')));
      expect(body.containsKey('iconEmoji'), isFalse);
      expect(opened?.id, 'g-new');
      expect(opened?.description, '10월 캠페인 준비');
      expect(find.byType(FloatingDialog), findsNothing);
    });

    testWidgets('이름이 없으면 멤버 사진 아이콘, 이모지를 고르면 이모지 아이콘으로 보낸다', (tester) async {
      final session = buildSession();
      await pumpHost(
        tester,
        (c) => showNewGroupDialog(c, session, onOpenRoom: (_) {}),
      );
      await tester.tap(byKey('new-group-pick-members'));
      await tester.pumpAndSettle();
      await tester.tap(memberRow('u4'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('pick-members-confirm'));
      await tester.pumpAndSettle();

      // 그룹 아이콘 편집 → 아이콘 선택하기 → 🎉 → 확인 → 확인.
      await tester.tap(byKey('new-group-icon-edit'));
      await tester.pumpAndSettle();
      expect(find.text('그룹 아이콘 편집'), findsOneWidget);
      await tester.tap(find.text('아이콘 선택하기'));
      await tester.pumpAndSettle();
      expect(find.byType(GroupIconPickerDialog), findsOneWidget);
      await tester.tap(find.text('🎉').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '확인').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '확인').last);
      await tester.pumpAndSettle();
      expect(find.text('그룹 아이콘 편집'), findsNothing);

      await tester.tap(byKey('new-group-submit'));
      await tester.pumpAndSettle();
      final body = bodyOf(called('POST', '/api/rooms').single);
      expect(body.containsKey('name'), isFalse);
      expect(body['memberIds'], ['u4']);
      expect(body['iconType'], 'emoji');
      expect(body['iconEmoji'], '🎉');
      expect(body['iconColor'], matches(RegExp(r'^#[0-9A-F]{6}$')));
    });

    testWidgets('이모지·사진 없이 이름도 없으면 아이콘 값을 보내지 않는다(멤버 사진)', (tester) async {
      final session = buildSession();
      await pumpHost(
        tester,
        (c) => showNewGroupDialog(c, session, onOpenRoom: (_) {}),
      );
      await tester.tap(byKey('new-group-pick-members'));
      await tester.pumpAndSettle();
      await tester.tap(memberRow('u4'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('pick-members-confirm'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('new-group-submit'));
      await tester.pumpAndSettle();

      final body = bodyOf(called('POST', '/api/rooms').single);
      expect(body.containsKey('iconType'), isFalse);
      expect(body.containsKey('iconColor'), isFalse);
      expect(body.containsKey('description'), isFalse);
    });

    testWidgets('서버가 거절하면 창에 이유를 보여준다', (tester) async {
      routes['POST /api/rooms'] = (_) =>
          json({'error': '그룹 채팅 이름은 60자 이내로 입력하세요.'}, 400);
      final session = buildSession();
      await pumpHost(
        tester,
        (c) => showNewGroupDialog(c, session, onOpenRoom: (_) {}),
      );
      await tester.tap(byKey('new-group-pick-members'));
      await tester.pumpAndSettle();
      await tester.tap(memberRow('u4'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('pick-members-confirm'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('new-group-submit'));
      await tester.pumpAndSettle();

      expect(byKey('new-group-error'), findsOneWidget);
      expect(find.text('그룹 채팅 이름은 60자 이내로 입력하세요.'), findsOneWidget);
      expect(find.byType(FloatingDialog), findsOneWidget);
    });

    testWidgets('준회원은 만들 수 없다', (tester) async {
      final session = buildSession(role: AccountRole.guest);
      await pumpHost(
        tester,
        (c) => showNewGroupDialog(c, session, onOpenRoom: (_) {}),
      );
      expect(byKey('new-group-guest-notice'), findsOneWidget);
      expect(onPressedOf(tester, 'new-group-submit'), isNull);
      expect(onPressedOf(tester, 'new-group-pick-members'), isNull);
    });

    testWidgets('좁은 화면은 전체 화면 — 멤버 선택도 전체 화면이고 360px에서도 넘치지 않는다', (
      tester,
    ) async {
      final session = buildSession();
      Room? opened;
      await pumpHost(
        tester,
        (c) => showNewGroupDialog(c, session, onOpenRoom: (r) => opened = r),
        size: const Size(360, 740),
      );

      expect(find.byType(FloatingDialog), findsNothing);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('새 그룹채팅 만들기'),
        ),
        findsOneWidget,
      );

      await tester.tap(byKey('new-group-pick-members'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('멤버 선택')),
        findsOneWidget,
      );
      await tester.tap(memberRow('u2'));
      await tester.tap(memberRow('u3'));
      await tester.tap(memberRow('u5'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(byKey('pick-members-confirm'));
      await tester.pumpAndSettle();

      expect(find.byType(InputChip), findsNWidgets(3));
      await tester.enterText(byKey('new-group-name'), '가' * 60);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(byKey('new-group-submit'));
      await tester.pumpAndSettle();
      expect(opened?.id, 'g-new');
    });
  });

  group('채팅 정보 변경', () {
    Room groupRoom({
      String? name = '캠페인',
      String? description = '캠페인 준비',
      String? iconType = 'initial',
      String? iconEmoji,
      String? iconColor = '#4C6EF5',
      String? customName,
    }) => Room.fromJson(
      roomJson(
        'g1',
        type: 'group',
        name: name,
        memberIds: ['u2', 'u3'],
        extra: {
          'description': description,
          'iconType': iconType,
          'iconEmoji': iconEmoji,
          'iconColor': iconColor,
          'customName': customName,
        },
      ),
    );

    /// PATCH /rooms/g1 — 받은 칸을 지금 값에 합쳐 돌려준다(서버처럼 '' → null, 'members' → 아이콘 지움).
    void patchEchoes(Room room) {
      routes['PATCH /api/rooms/g1'] = (request) {
        final body = bodyOf(request);
        String? blankToNull(Object? v) =>
            v == null || (v as String).isEmpty ? null : v;
        final iconType = body.containsKey('iconType')
            ? body['iconType'] as String?
            : room.iconType;
        return json(
          roomJson(
            'g1',
            type: 'group',
            name: body.containsKey('name')
                ? blankToNull(body['name'])
                : room.name,
            memberIds: ['u2', 'u3'],
            extra: {
              'description': body.containsKey('description')
                  ? blankToNull(body['description'])
                  : room.description,
              'iconType': iconType == 'members' ? null : iconType,
              'iconEmoji': body['iconEmoji'] ?? room.iconEmoji,
              'iconColor': body['iconColor'] ?? room.iconColor,
              'customName': room.customName,
            },
          ),
        );
      };
    }

    Future<Session> openSettings(
      WidgetTester tester,
      Room room, {
      AccountRole role = AccountRole.member,
      Size size = const Size(1280, 900),
    }) async {
      final session = buildSession(role: role);
      session.rooms.add(room);
      patchEchoes(room);
      await pumpHost(
        tester,
        (c) => showGroupSettingsDialog(c, session, room),
        size: size,
      );
      return session;
    }

    testWidgets('바꾼 칸만 보내고, 저장하면 알린 뒤 닫는다', (tester) async {
      final room = groupRoom();
      await openSettings(tester, room);

      expect(find.byType(FloatingDialog), findsOneWidget);
      expect(find.text('채팅 정보 변경'), findsOneWidget);
      expect(find.text('그룹 채팅 이름  (선택)', findRichText: true), findsOneWidget);
      expect(find.text('캠페인'), findsOneWidget);
      expect(find.text('3/60'), findsOneWidget);
      // 아무것도 안 바꾸면 저장할 수 없다.
      expect(onPressedOf(tester, 'group-settings-save'), isNull);

      await tester.enterText(byKey('group-settings-description'), ' 새 설명 ');
      await tester.pumpAndSettle();
      expect(onPressedOf(tester, 'group-settings-save'), isNotNull);
      await tester.tap(byKey('group-settings-save'));
      await tester.pumpAndSettle();

      final patch = called('PATCH', '/api/rooms/g1').single;
      expect(bodyOf(patch), {'description': '새 설명'});
      expect(find.text('채팅 정보를 변경했습니다.'), findsOneWidget);
      expect(find.byType(FloatingDialog), findsNothing);
      // 같은 방 인스턴스에 반영된다.
      expect(room.description, '새 설명');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('이름을 지우면 빈 문자열을 보내고, 이니셜 아이콘은 멤버 사진으로 바뀐다', (tester) async {
      final room = groupRoom();
      await openSettings(tester, room);

      await tester.enterText(byKey('group-settings-name'), '');
      await tester.pumpAndSettle();
      // 비워 두면 보일 이름(나를 뺀 멤버 이름)을 안내한다.
      expect(find.text('박서연, 이도현'), findsOneWidget);
      await tester.tap(byKey('group-settings-save'));
      await tester.pumpAndSettle();

      expect(bodyOf(called('PATCH', '/api/rooms/g1').single), {
        'name': '',
        'iconType': 'members',
      });
      expect(room.name, isNull);
      expect(room.iconType, isNull);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('이름 없는 그룹에 이름을 붙이면 새 그룹채팅처럼 이니셜 아이콘으로 바뀐다', (tester) async {
      final room = groupRoom(name: null, iconType: null, iconColor: null);
      await openSettings(tester, room);

      await tester.enterText(byKey('group-settings-name'), '점심 모임');
      await tester.pumpAndSettle();
      await tester.tap(byKey('group-settings-save'));
      await tester.pumpAndSettle();

      final body = bodyOf(called('PATCH', '/api/rooms/g1').single);
      expect(body['name'], '점심 모임');
      expect(body['iconType'], 'initial');
      expect(body['iconColor'], matches(RegExp(r'^#[0-9A-F]{6}$')));
      expect(body.keys, unorderedEquals(['name', 'iconType', 'iconColor']));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('예전에 만든 이름 있는 멤버 사진 그룹은 설명만 바꾸면 아이콘을 보내지 않는다', (tester) async {
      final room = groupRoom(iconType: null, iconColor: null);
      await openSettings(tester, room);

      await tester.enterText(byKey('group-settings-description'), '바뀐 설명');
      await tester.pumpAndSettle();
      await tester.tap(byKey('group-settings-save'));
      await tester.pumpAndSettle();

      expect(bodyOf(called('PATCH', '/api/rooms/g1').single), {
        'description': '바뀐 설명',
      });
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('아이콘을 바꾸면 그 모양에 필요한 값을 같이 보낸다', (tester) async {
      final room = groupRoom();
      await openSettings(tester, room);

      await tester.tap(byKey('group-settings-icon-edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('아이콘 선택하기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('💬').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '확인').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '확인').last);
      await tester.pumpAndSettle();

      await tester.tap(byKey('group-settings-save'));
      await tester.pumpAndSettle();
      expect(bodyOf(called('PATCH', '/api/rooms/g1').single), {
        'iconType': 'emoji',
        'iconEmoji': '💬',
        'iconColor': '#4C6EF5',
      });
      expect(room.iconType, 'emoji');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('편집 창에서 그대로 확인하면 바뀐 것이 없다', (tester) async {
      final room = groupRoom();
      await openSettings(tester, room);

      await tester.tap(byKey('group-settings-icon-edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '확인').last);
      await tester.pumpAndSettle();
      expect(onPressedOf(tester, 'group-settings-save'), isNull);
    });

    testWidgets('나에게만 보이는 이름이 있으면 어디서 바꾸는지 안내한다', (tester) async {
      await openSettings(tester, groupRoom(customName: '우리방'));
      expect(byKey('group-settings-alias-note'), findsOneWidget);
      expect(
        find.text("내 목록에서는 '우리방'(으)로 보여요 — ⋮ › 나에게만 이름 변경에서 바꿀 수 있어요"),
        findsOneWidget,
      );
    });

    testWidgets('별칭이 없으면 안내하지 않는다', (tester) async {
      await openSettings(tester, groupRoom());
      expect(byKey('group-settings-alias-note'), findsNothing);
    });

    testWidgets('준회원에게는 읽기 전용으로 보인다', (tester) async {
      await openSettings(tester, groupRoom(), role: AccountRole.guest);

      expect(byKey('group-settings-guest-notice'), findsOneWidget);
      expect(find.text(groupInfoGuestNotice), findsOneWidget);
      expect(
        tester.widget<TextField>(byKey('group-settings-name')).enabled,
        isFalse,
      );
      expect(
        tester.widget<TextField>(byKey('group-settings-description')).enabled,
        isFalse,
      );
      expect(byKey('group-settings-icon-edit'), findsNothing);
      expect(find.byType(CameraBadge), findsNothing);
      expect(onPressedOf(tester, 'group-settings-save'), isNull);
      expect(find.widgetWithText(TextButton, '닫기'), findsOneWidget);
    });

    testWidgets('다른 멤버가 바꾸면 손대지 않은 칸만 따라간다', (tester) async {
      final room = groupRoom();
      final session = await openSettings(tester, room);

      await tester.enterText(byKey('group-settings-description'), '내가 쓰던 설명');
      await tester.pumpAndSettle();
      room.mergeServerState(groupRoom(name: '새 이름', description: '다른 사람 설명'));
      session.notifyListeners();
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(byKey('group-settings-name')).controller!.text,
        '새 이름',
      );
      expect(
        tester
            .widget<TextField>(byKey('group-settings-description'))
            .controller!
            .text,
        '내가 쓰던 설명',
      );
    });

    testWidgets('상관없는 변경(설명 등)이 와도 입력 중인 이름 끝의 띄어쓰기는 지워지지 않는다', (tester) async {
      final room = groupRoom();
      final session = await openSettings(tester, room);

      await tester.enterText(byKey('group-settings-name'), '캠페인 ');
      await tester.pumpAndSettle();
      room.mergeServerState(groupRoom(description: '다른 사람 설명'));
      session.notifyListeners();
      await tester.pumpAndSettle();

      TextEditingController controllerOf(String key) =>
          tester.widget<TextField>(byKey(key)).controller!;
      expect(controllerOf('group-settings-name').text, '캠페인 ');
      // 손대지 않은 설명 칸은 따라간다.
      expect(controllerOf('group-settings-description').text, '다른 사람 설명');
    });

    testWidgets('창을 연 채 멤버·나에게만 이름이 바뀌면 이름 안내와 별칭 안내가 따라간다', (tester) async {
      final room = groupRoom(name: null, iconType: null, iconColor: null);
      final session = await openSettings(tester, room);
      expect(find.text('박서연, 이도현'), findsOneWidget);
      expect(byKey('group-settings-alias-note'), findsNothing);

      // 최준호가 초대됐다(room:created로 같은 인스턴스가 갱신된다).
      room.mergeServerState(
        Room.fromJson(
          roomJson(
            'g1',
            type: 'group',
            memberIds: ['u2', 'u3', 'u4'],
            extra: {'description': '캠페인 준비'},
          ),
        ),
      );
      session.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('박서연, 이도현, 최준호'), findsOneWidget);

      // 다른 기기에서 나에게만 이름을 붙였다(room:renamed).
      room.customName = '우리방';
      session.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        find.text("내 목록에서는 '우리방'(으)로 보여요 — ⋮ › 나에게만 이름 변경에서 바꿀 수 있어요"),
        findsOneWidget,
      );
    });

    testWidgets('방이 목록에서 사라지면 창이 닫힌다', (tester) async {
      final room = groupRoom();
      final session = await openSettings(tester, room);
      expect(find.byType(GroupSettingsScreen), findsOneWidget);

      session.rooms.remove(room);
      session.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(GroupSettingsScreen), findsNothing);
    });

    testWidgets('좁은 화면은 전체 화면 — 360px에서도 넘치지 않는다', (tester) async {
      await openSettings(
        tester,
        groupRoom(customName: '아주 긴 나만의 이름으로 부르는 캠페인 준비방'),
        size: const Size(360, 740),
      );
      expect(find.byType(FloatingDialog), findsNothing);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('채팅 정보 변경'),
        ),
        findsOneWidget,
      );
      await tester.enterText(byKey('group-settings-name'), '');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('그룹 아이콘', () {
    test('사진 > 이모지 > 이름이 있으면 이니셜, 없으면 멤버 사진', () {
      expect(groupIconTypeOf(const IconChoice(photoUrl: '/f/1'), ''), 'photo');
      expect(groupIconTypeOf(const IconChoice(emoji: '🎉'), ''), 'emoji');
      expect(groupIconTypeOf(const IconChoice(), '캠페인'), 'initial');
      expect(groupIconTypeOf(const IconChoice(), '   '), 'members');
    });
  });
}
