import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/convert_to_topic_dialog.dart';
import 'package:client/screens/desktop_home_screen.dart';
import 'package:client/screens/group_settings_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 그룹채팅 → 토픽 전환 — '채팅 정보 변경' 창의 "토픽으로 전환" 단추(정회원 이상), 전환 대화상자(경고·이름 필수),
/// 전환 뒤 방이 같은 인스턴스 그대로 토픽으로 바뀌어 사이드바 '토픽' 묶음으로 옮겨 간다.
class _Quiet extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

void main() {
  const serverUrl = 'https://192.168.0.10:3000';

  Map<String, dynamic> user(String id, String name) => {
    'id': id,
    'username': 'user_$id',
    'name': name,
    'role': 'member',
  };

  Map<String, dynamic> groupJson() => {
    'id': 'g1',
    'teamId': 't1',
    'type': 'group',
    'name': '점심 모임',
    'description': '맛집 공유',
    'isPublic': false,
    'members': [user('me', '김하나'), user('u2', '이도현')],
    'createdAt': 1000,
    'iconType': 'emoji',
    'iconEmoji': '🍜',
    'iconColor': '#FF8800',
    'customName': '나만의 이름',
  };

  Map<String, dynamic> convertedJson(String name, String? description) => {
    'id': 'g1',
    'teamId': 't1',
    'type': 'topic',
    'name': name,
    'description': description,
    'isPublic': false,
    'members': [user('me', '김하나'), user('u2', '이도현')],
    'createdAt': 1000,
    'adminIds': ['me'],
    'viewMode': 'chat',
  };

  http.Response json(Object? body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );

  late List<http.Request> requests;
  late http.Response Function(http.Request) convertRoute;

  List<http.Request> posts() => [
    for (final r in requests)
      if (r.url.path == '/api/rooms/g1/convert-to-topic') r,
  ];

  Session buildSession({
    AccountRole role = AccountRole.member,
    TopicCreationPolicy? policy,
  }) {
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/api/rooms/g1/convert-to-topic') {
        return convertRoute(request);
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
    if (policy != null) team.topicCreationPolicy = policy;
    session.teams.add(team);
    session.currentTeam = team;
    session.rooms.add(Room.fromJson(groupJson()));
    return session;
  }

  setUp(() {
    requests = [];
    convertRoute = (r) {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      return json(
        convertedJson(body['name'] as String, body['description'] as String?),
      );
    };
  });

  Finder key(String k) => find.byKey(ValueKey(k));

  Future<void> openSettings(
    WidgetTester tester,
    Session session, {
    Size size = const Size(1280, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showGroupSettingsDialog(
                context,
                session,
                session.roomById('g1')!,
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

  group('"토픽으로 전환" 단추 노출', () {
    testWidgets('정회원에게는 보인다', (tester) async {
      await openSettings(tester, buildSession());
      expect(key('group-settings-convert'), findsOneWidget);
    });

    testWidgets('준회원에게는 보이지 않는다', (tester) async {
      await openSettings(tester, buildSession(role: AccountRole.guest));
      expect(key('group-settings-guest-notice'), findsOneWidget);
      expect(key('group-settings-convert'), findsNothing);
    });

    testWidgets('팀이 토픽 생성을 관리자 이상으로 제한했으면 정회원에게는 보이지 않는다', (tester) async {
      await openSettings(
        tester,
        buildSession(policy: TopicCreationPolicy.admin),
      );
      expect(key('group-settings-convert'), findsNothing);
    });
  });

  group('전환 대화상자', () {
    Future<Session> openConvert(WidgetTester tester) async {
      final session = buildSession();
      await openSettings(tester, session);
      await tester.ensureVisible(key('group-settings-convert'));
      await tester.tap(key('group-settings-convert'));
      await tester.pumpAndSettle();
      return session;
    }

    testWidgets('경고 문구가 보이고, 이름이 비면 전환 단추가 잠긴다', (tester) async {
      await openConvert(tester);
      expect(find.text('토픽으로 전환'), findsWidgets);
      expect(
        find.text(
          '토픽으로 전환하면 다시 그룹채팅으로 되돌릴 수 없습니다. 비공개 토픽으로 전환되며 전환한 사람이 토픽 관리자가 됩니다. '
          '대화 내용은 그대로 유지됩니다.',
        ),
        findsOneWidget,
      );
      // 그룹 이름이 시작값으로 들어 있다 — 지우면 잠긴다.
      expect(
        tester.widget<TextField>(key('convert-topic-name')).controller!.text,
        '점심 모임',
      );
      await tester.enterText(key('convert-topic-name'), '   ');
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(key('convert-topic-submit')).onPressed,
        isNull,
      );
      await tester.enterText(key('convert-topic-name'), '맛집 토픽');
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(key('convert-topic-submit')).onPressed,
        isNotNull,
      );
    });

    testWidgets('전환하면 요청이 가고, 방이 토픽으로 바뀌고, 창들이 닫힌다', (tester) async {
      final session = await openConvert(tester);
      final room = session.roomById('g1')!;
      await tester.enterText(key('convert-topic-name'), '  맛집 토픽  ');
      await tester.enterText(key('convert-topic-description'), '점심 맛집 모음');
      await tester.pumpAndSettle();
      await tester.tap(key('convert-topic-submit'));
      await tester.pumpAndSettle();

      final body = jsonDecode(posts().single.body) as Map<String, dynamic>;
      expect(body, {'name': '맛집 토픽', 'description': '점심 맛집 모음'});
      // 같은 인스턴스가 그대로 토픽으로 바뀐다 — 열려 있던 대화 화면이 다시 열리지 않는다.
      expect(session.roomById('g1'), same(room));
      expect(room.type, RoomType.topic);
      expect(room.name, '맛집 토픽');
      expect(room.isPublic, isFalse);
      expect(room.isPrivateTopic, isTrue);
      expect(room.adminIds, ['me']);
      expect(room.customName, isNull); // 토픽에선 나만의 별칭을 쓰지 않는다
      // 대화상자와 채팅 정보 변경 창이 모두 닫혔다.
      expect(find.byType(ConvertToTopicDialog), findsNothing);
      expect(find.byType(GroupSettingsScreen), findsNothing);
      expect(find.text('토픽으로 전환했습니다.'), findsOneWidget);
      // 토스트가 사라질 때까지 기다린다.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    });

    testWidgets('서버가 거절하면 대화상자 안에 오류가 보이고 방은 그대로다', (tester) async {
      convertRoute = (r) => json({'error': '이미 토픽입니다.'}, 400);
      final session = await openConvert(tester);
      await tester.tap(key('convert-topic-submit'));
      await tester.pumpAndSettle();
      expect(find.text('이미 토픽입니다.'), findsOneWidget);
      expect(find.byType(ConvertToTopicDialog), findsOneWidget);
      expect(session.roomById('g1')!.type, RoomType.group);
      // 취소하면 설정 창으로 돌아간다.
      await tester.tap(find.widgetWithText(TextButton, '취소').last);
      await tester.pumpAndSettle();
      expect(find.byType(ConvertToTopicDialog), findsNothing);
      expect(find.byType(GroupSettingsScreen), findsOneWidget);
    });

    testWidgets('360px 좁은 화면에서도 넘치지 않는다', (tester) async {
      final session = buildSession();
      await openSettings(tester, session, size: const Size(360, 640));
      await tester.ensureVisible(key('group-settings-convert'));
      await tester.tap(key('group-settings-convert'));
      await tester.pumpAndSettle();
      expect(find.byType(ConvertToTopicDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  test('Room.mergeServerState — 종류가 그룹에서 토픽으로 바뀌면 따라가고 별칭을 버린다', () {
    final room = Room.fromJson(groupJson());
    expect(room.type, RoomType.group);
    expect(room.customName, '나만의 이름');
    room.mergeServerState(Room.fromJson(convertedJson('새 토픽', null)));
    expect(room.type, RoomType.topic);
    expect(room.name, '새 토픽');
    expect(room.customName, isNull);
    expect(room.iconType, isNull);
    // 종류가 같으면 별칭은 그대로(개인 값은 브로드캐스트로 안 지운다).
    final group = Room.fromJson(groupJson());
    group.mergeServerState(Room.fromJson(groupJson()));
    expect(group.customName, '나만의 이름');
  });

  testWidgets('사이드바 — 전환하면 그룹채팅 묶음에서 토픽 묶음으로 옮겨 간다', (tester) async {
    final session = buildSession();
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: DesktopHomeScreen(session: session)),
    );
    await tester.pumpAndSettle();
    expect(find.text('그룹채팅 1'), findsOneWidget);
    expect(find.text('토픽 0'), findsOneWidget);

    await session.convertGroupToTopic(session.roomById('g1')!, name: '맛집 토픽');
    await tester.pumpAndSettle();
    expect(find.text('그룹채팅 0'), findsOneWidget);
    expect(find.text('토픽 1'), findsOneWidget);
    expect(find.text('맛집 토픽'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });
}
