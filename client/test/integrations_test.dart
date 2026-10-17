// 외부 연동(앱) — 봇 메시지 표시(아이콘·"봇" 표시), 슬래시 입력 읽기·연동을 쓸 수 있는 방, 입력칸의 슬래시 명령(자동 완성·실행·나에게만
// 보이는 답·모르는 명령은 보통 글), 웹훅 관리 창(만들기 → 주소는 한 번만), 개인 API 토큰 창, 관리자 콘솔 "슬래시 명령" 탭. 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/integration.dart';
import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/admin_commands_tab.dart';
import 'package:client/screens/api_tokens_dialog.dart';
import 'package:client/screens/room_webhooks_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/avatar_utils.dart';
import 'package:client/widgets/chat_input_bar.dart';
import 'package:client/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

typedef _Routes = Map<String, http.Response Function(http.Request request)>;

Map<String, dynamic> _member(String id, String name) => {
  'id': id,
  'username': id,
  'name': name,
  'role': 'member',
};

Room _room({
  String type = 'group',
  bool secret = false,
  String viewMode = 'chat',
  List<String> admins = const [],
}) => Room.fromJson({
  'id': 'r1',
  'teamId': 't1',
  'type': type,
  'name': '프로젝트방',
  'members': [_member('me', '나'), _member('u2', '김철수')],
  'createdAt': 1000,
  'isSecret': secret,
  'viewMode': viewMode,
  'adminIds': admins,
});

Session _session(
  List<http.Request> requests,
  _Routes routes, {
  Room? room,
  AccountRole role = AccountRole.member,
}) {
  final session = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: MockClient((request) async {
      requests.add(request);
      final route = routes['${request.method} ${request.url.path}'];
      if (route != null) return route(request);
      return _json({'error': 'no route'}, status: 404);
    }),
  );
  session.userId = 'me';
  session.name = '나';
  session.accountRole = role;
  final team = Team(id: 't1', name: '개발팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.add(room ?? _room());
  return session;
}

Map<String, dynamic> _command(
  String command, {
  String? description,
  String? url,
}) => {
  'id': 'c-$command',
  'kind': 'command',
  'teamId': 't1',
  'roomId': null,
  'name': '배포봇',
  'emoji': '🚀',
  'tokenPrefix': null,
  'command': command,
  'description': description,
  'url': url,
  'createdAt': 1000,
  'lastUsedAt': null,
  'useCount': 0,
};

Map<String, dynamic> _webhook(
  String id,
  String name, {
  int? lastUsedAt,
  int useCount = 0,
}) => {
  'id': id,
  'kind': 'webhook',
  'teamId': 't1',
  'roomId': 'r1',
  'name': name,
  'emoji': '🚨',
  'tokenPrefix': 'ttw_AbCd',
  'createdAt': 1000,
  'lastUsedAt': lastUsedAt,
  'useCount': useCount,
};

Map<String, dynamic> _bodyOf(http.Request r) =>
    jsonDecode(r.body) as Map<String, dynamic>;

Future<void> _openWith(
  WidgetTester tester,
  Session session,
  void Function(BuildContext) open,
) async {
  tester.view.physicalSize = const Size(1400, 1000);
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

void main() {
  group('봇 메시지', () {
    final botJson = {
      'id': 'm1',
      'roomId': 'r1',
      'senderId': null,
      'senderName': 'Uptime',
      'type': 'text',
      'text': '서버 다운: web-1',
      'createdAt': DateTime(2026, 10, 1).millisecondsSinceEpoch,
      'bot': {'integrationId': 'i1', 'emoji': '🚨'},
    };

    test('bot이 붙은 보낸 사람 없는 글은 자동화·봇 메시지, 연동을 지워도(integrationId null) 그대로', () {
      final m = Message.fromJson(botJson);
      expect(m.isAutomation, isTrue);
      expect(m.isBot, isTrue);
      expect(m.bot!.emoji, '🚨');
      final detached = Message.fromJson({
        ...botJson,
        'bot': {'integrationId': null, 'emoji': '🚨'},
      });
      expect(detached.isBot, isTrue);
      // 탈퇴한 사람의 글(bot 없음)은 봇이 아니다.
      final departed = Message.fromJson({...botJson, 'bot': null});
      expect(departed.isAutomation, isFalse);
      expect(departed.isBot, isFalse);
      // 프로젝트 자동화는 자동화지만 "봇" 표시는 붙지 않는다.
      final automation = Message.fromJson({
        ...botJson,
        'senderName': automationSenderName,
        'bot': null,
      });
      expect(automation.isAutomation, isTrue);
      expect(automation.isBot, isFalse);
    });

    testWidgets('말풍선: 고른 이모지 아이콘 · 이름 · "봇" 표시, 프로필 아바타 없음', (tester) async {
      final session = _session([], {});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MessageBubble(
                session: session,
                message: Message.fromJson(botJson),
                resolveUrl: (u) => u,
                isMine: false,
                onOpenThread: (_) {},
                onEdit: (_, _, {format, mentions}) async {},
                onDelete: (_) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('automation-avatar')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('automation-avatar')),
          matching: find.text('🚨'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('bot-badge')), findsOneWidget);
      expect(find.text('Uptime'), findsOneWidget);
      expect(find.byType(AvatarView), findsNothing);
    });
  });

  group('슬래시 입력·연동을 쓸 수 있는 방', () {
    test('parseSlashInvocation · slashCommandQuery', () {
      final inv = parseSlashInvocation('/Deploy  web 1 ')!;
      expect(inv.command, 'deploy');
      expect(inv.text, 'web 1');
      expect(parseSlashInvocation('/status')!.text, '');
      expect(parseSlashInvocation('그냥 글'), isNull);
      expect(parseSlashInvocation('//x'), isNull);
      expect(parseSlashInvocation('/한글'), isNull);
      expect(slashCommandQuery('/'), '');
      expect(slashCommandQuery('/De'), 'de');
      expect(slashCommandQuery('/deploy '), isNull, reason: '띄어쓰면 고르기는 끝');
      expect(slashCommandQuery('글 /de'), isNull);
    });

    test('토픽(챗 뷰·보관 아님)·그룹만, 1:1·비밀 대화·보드 뷰는 안 됨', () {
      expect(roomAcceptsIntegrations(_room()), isTrue);
      expect(roomAcceptsIntegrations(_room(type: 'topic')), isTrue);
      expect(
        roomAcceptsIntegrations(_room(type: 'topic', viewMode: 'board')),
        isFalse,
      );
      expect(roomAcceptsIntegrations(_room(type: 'dm')), isFalse);
      expect(roomAcceptsIntegrations(_room(secret: true)), isFalse);
    });

    test('웹훅 메뉴: 그룹은 정회원 이상, 토픽은 관리할 수 있는 사람', () {
      final group = _room();
      expect(
        canManageRoomWebhooks(_session([], {}, room: group), group),
        isTrue,
      );
      expect(
        canManageRoomWebhooks(
          _session([], {}, room: group, role: AccountRole.guest),
          group,
        ),
        isFalse,
      );
      final topic = _room(type: 'topic');
      expect(
        canManageRoomWebhooks(_session([], {}, room: topic), topic),
        isFalse,
      );
      final mine = _room(type: 'topic', admins: ['me']);
      expect(canManageRoomWebhooks(_session([], {}, room: mine), mine), isTrue);
      final secret = _room(secret: true);
      expect(
        canManageRoomWebhooks(_session([], {}, room: secret), secret),
        isFalse,
      );
    });
  });

  group('입력칸의 슬래시 명령', () {
    late List<http.Request> requests;
    late _Routes routes;
    setUp(() {
      requests = [];
      routes = {
        'GET /api/teams/t1/commands': (_) => _json([
          _command('deploy', description: '서버에 배포합니다'),
          _command('dice', description: '주사위'),
        ]),
        'POST /api/rooms/r1/commands/run': (r) => _bodyOf(r)['text'] == 'boom'
            ? _json({'error': '명령을 처리하는 서버가 오류를 돌려줬습니다(500).'}, status: 502)
            : _json({'ephemeral': '배포 대기열: 2건'}),
      };
    });

    Future<Session> pumpBar(WidgetTester tester) async {
      final session = _session(requests, routes);
      final room = session.rooms.single;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ChatInputBar(
                controller: session.controllerFor(room),
                session: session,
                room: room,
                stickerPickerGroupId: Object(),
                onToggleStickerPicker: () {},
                onStickerConsumed: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return session;
    }

    testWidgets('/를 치면 이 팀의 명령을 고를 수 있고, 누르면 입력칸에 채운다', (tester) async {
      await pumpBar(tester);
      expect(
        requests.where((r) => r.url.path == '/api/teams/t1/commands'),
        hasLength(1),
        reason: '미리 받아 둔다',
      );
      expect(find.byKey(const ValueKey('slash-suggestions')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('chat-input')), '/');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('slash-suggestion-deploy')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('slash-suggestion-dice')),
        findsOneWidget,
      );
      await tester.enterText(find.byKey(const ValueKey('chat-input')), '/de');
      await tester.pump();
      expect(find.byKey(const ValueKey('slash-suggestion-dice')), findsNothing);
      expect(find.text('서버에 배포합니다'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('slash-suggestion-deploy')));
      await tester.pump();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('chat-input')),
      );
      expect(field.controller!.text, '/deploy ');
      expect(find.byKey(const ValueKey('slash-suggestions')), findsNothing);
    });

    testWidgets('명령을 보내면 실행하고 나에게만 보이는 답을 띄운다 — 메시지로 보내지 않는다', (tester) async {
      await pumpBar(tester);
      await tester.enterText(
        find.byKey(const ValueKey('chat-input')),
        '/Deploy web 1',
      );
      await tester.tap(find.byTooltip('보내기'));
      await tester.pumpAndSettle();
      final run = requests.singleWhere(
        (r) => r.url.path == '/api/rooms/r1/commands/run',
      );
      expect(_bodyOf(run), {'command': 'deploy', 'text': 'web 1'});
      expect(find.byKey(const ValueKey('slash-reply-dialog')), findsOneWidget);
      expect(find.text('배포 대기열: 2건'), findsOneWidget);
      expect(find.text('/deploy · 나에게만 보이는 답'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('chat-input')),
      );
      expect(field.controller!.text, isEmpty);
    });

    testWidgets('실패하면 친 글을 되돌린다', (tester) async {
      await pumpBar(tester);
      await tester.enterText(
        find.byKey(const ValueKey('chat-input')),
        '/deploy boom',
      );
      await tester.tap(find.byTooltip('보내기'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('chat-input')),
      );
      expect(field.controller!.text, '/deploy boom');
      expect(find.textContaining('/deploy 실행 실패'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('이 팀에 없는 명령(/로 시작하는 그냥 글)은 실행하지 않는다', (tester) async {
      await pumpBar(tester);
      for (final text in ['/usr/bin 경로 공유', '/unknown x']) {
        await tester.enterText(find.byKey(const ValueKey('chat-input')), text);
        await tester.tap(find.byTooltip('보내기'));
        await tester.pumpAndSettle();
        // 보통 글로 보내려다(시험에는 소켓이 없다) 뜬 "전송 실패" 알림이 보내기 단추를 가리지 않게 걷는다.
        ScaffoldMessenger.of(
          tester.element(find.byType(ChatInputBar)),
        ).removeCurrentSnackBar();
        await tester.pumpAndSettle();
      }
      expect(
        requests.where((r) => r.url.path == '/api/rooms/r1/commands/run'),
        isEmpty,
      );
      expect(
        requests.where((r) => r.url.path == '/api/teams/t1/commands'),
        hasLength(1),
        reason: '받아 둔 명령 목록으로 판단한다',
      );
    });
  });

  group('웹훅 관리 창', () {
    testWidgets('목록 → 만들기(이름·아이콘) → 주소는 이번에만, 웹 앱 주소가 없으면 자체 서명 안내', (
      tester,
    ) async {
      final requests = <http.Request>[];
      var hooks = [
        _webhook(
          'w1',
          '서버 모니터링',
          lastUsedAt: DateTime(2026, 10, 1, 9).millisecondsSinceEpoch,
          useCount: 12,
        ),
      ];
      final session = _session(requests, {
        'GET /api/rooms/r1/webhooks': (_) => _json(hooks),
        'POST /api/rooms/r1/webhooks': (r) {
          final made = _webhook('w2', _bodyOf(r)['name'] as String);
          hooks = [...hooks, made];
          return _json({
            ...made,
            'token': 'ttw_${'x' * 40}',
            'urls': {
              'path': '/hooks/ttw_${'x' * 40}',
              'web': null,
              'direct': 'https://10.0.0.5:3000/hooks/ttw_${'x' * 40}',
            },
          }, status: 201);
        },
      });
      await _openWith(
        tester,
        session,
        (c) => showRoomWebhooksDialog(c, session, session.rooms.single),
      );
      expect(find.text('서버 모니터링'), findsOneWidget);
      expect(find.textContaining('ttw_AbCd…'), findsWidgets);
      expect(find.textContaining('12번'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('webhook-create')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('bot-name-field')),
        'CI',
      );
      await tester.enterText(
        find.byKey(const ValueKey('bot-emoji-field')),
        '🛠️',
      );
      await tester.tap(find.byKey(const ValueKey('bot-name-confirm')));
      await tester.pumpAndSettle();
      final post = requests.singleWhere((r) => r.method == 'POST');
      expect(_bodyOf(post), {'name': 'CI', 'emoji': '🛠️'});
      final secret = tester.widget<SelectableText>(
        find.byKey(const ValueKey('integration-secret')),
      );
      expect(secret.data, 'https://10.0.0.5:3000/hooks/ttw_${'x' * 40}');
      expect(find.textContaining('자체 서명 인증서'), findsWidgets);
      expect(find.textContaining("curl -X POST -k"), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('integration-secret-done')));
      await tester.pumpAndSettle();
      expect(find.text('CI'), findsOneWidget, reason: '목록을 새로 받았다');
      expect(
        find.textContaining('ttw_${'x' * 40}'),
        findsNothing,
        reason: '닫으면 다시 볼 수 없다',
      );
    });

    testWidgets('지우기는 확인 뒤 DELETE', (tester) async {
      final requests = <http.Request>[];
      var hooks = [_webhook('w1', '서버 모니터링')];
      final session = _session(requests, {
        'GET /api/rooms/r1/webhooks': (_) => _json(hooks),
        'DELETE /api/integrations/w1': (_) {
          hooks = [];
          return _json({'ok': true});
        },
      });
      await _openWith(
        tester,
        session,
        (c) => showRoomWebhooksDialog(c, session, session.rooms.single),
      );
      await tester.tap(find.byKey(const ValueKey('webhook-menu-w1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('지우기').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('integration-delete-confirm')),
      );
      await tester.pumpAndSettle();
      expect(requests.where((r) => r.method == 'DELETE'), hasLength(1));
      expect(find.text('아직 웹훅이 없습니다.'), findsOneWidget);
    });
  });

  testWidgets('API 토큰 창: 만들기(이름·권한·만료) → 토큰은 이번에만, 지우기', (tester) async {
    final requests = <http.Request>[];
    var tokens = <Map<String, dynamic>>[];
    final session = _session(requests, {
      'GET /api/users/me/api-tokens': (_) => _json(tokens),
      'POST /api/users/me/api-tokens': (r) {
        final b = _bodyOf(r);
        final row = {
          'id': 'k1',
          'name': b['name'],
          'tokenPrefix': 'ttk_Zz9a',
          'scopes': b['scopes'],
          'createdAt': 1000,
          'lastUsedAt': null,
          'expiresAt': DateTime(2027).millisecondsSinceEpoch,
        };
        tokens = [row];
        return _json({...row, 'token': 'ttk_${'y' * 40}'}, status: 201);
      },
      'DELETE /api/users/me/api-tokens/k1': (_) {
        tokens = [];
        return _json({'ok': true});
      },
    });
    await _openWith(tester, session, (c) => showApiTokensDialog(c, session));
    expect(find.text('아직 만든 토큰이 없습니다.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('api-token-create')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('api-token-name')),
      '배포 스크립트',
    );
    await tester.tap(find.byKey(const ValueKey('api-token-write')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('api-token-confirm')));
    await tester.pumpAndSettle();
    expect(_bodyOf(requests.singleWhere((r) => r.method == 'POST')), {
      'name': '배포 스크립트',
      'scopes': ['read', 'write'],
      'expiresInDays': 90,
    });
    final secret = tester.widget<SelectableText>(
      find.byKey(const ValueKey('integration-secret')),
    );
    expect(secret.data, 'ttk_${'y' * 40}');
    expect(
      find.textContaining('https://test.local/api/v1/teams'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('integration-secret-done')));
    await tester.pumpAndSettle();
    expect(find.text('배포 스크립트'), findsOneWidget);
    expect(find.textContaining('읽기·쓰기'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('api-token-delete-k1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('integration-delete-confirm')));
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.method == 'DELETE'), hasLength(1));
    expect(find.text('아직 만든 토큰이 없습니다.'), findsOneWidget);
  });

  testWidgets('관리자 콘솔 "슬래시 명령": 팀을 골라 명령 만들기 → 서명 비밀은 이번에만', (tester) async {
    final requests = <http.Request>[];
    var commands = <Map<String, dynamic>>[];
    final session = _session(requests, {
      'GET /api/admin/teams': (_) => _json([
        {'id': 't1', 'name': '개발팀', 'memberCount': 3, 'createdAt': 1000},
      ]),
      'GET /api/teams/t1/commands': (_) => _json(commands),
      'POST /api/teams/t1/commands': (r) {
        final b = _bodyOf(r);
        final row = _command(
          b['command'] as String,
          description: b['description'] as String?,
          url: b['url'] as String,
        );
        commands = [row];
        return _json({...row, 'secret': 'f' * 64}, status: 201);
      },
    });
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminCommandsTab(session: session)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('이 팀에는 슬래시 명령이 없습니다.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('admin-command-create')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('command-name')),
      '/Deploy',
    );
    await tester.enterText(
      find.byKey(const ValueKey('command-url')),
      'ftp://nope',
    );
    await tester.tap(find.byKey(const ValueKey('command-confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('http:// 또는 https://'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('command-url')),
      'https://ci.company.com/chat',
    );
    await tester.enterText(
      find.byKey(const ValueKey('command-description')),
      '서버에 배포합니다',
    );
    await tester.tap(find.byKey(const ValueKey('command-confirm')));
    await tester.pumpAndSettle();
    expect(_bodyOf(requests.singleWhere((r) => r.method == 'POST')), {
      'command': 'deploy',
      'name': 'deploy',
      'url': 'https://ci.company.com/chat',
      'description': '서버에 배포합니다',
    });
    final secret = tester.widget<SelectableText>(
      find.byKey(const ValueKey('integration-secret')),
    );
    expect(secret.data, 'f' * 64);
    expect(find.textContaining('X-TangoTalk-Signature'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('integration-secret-done')));
    await tester.pumpAndSettle();
    expect(find.text('/deploy · 배포봇'), findsOneWidget);
    expect(
      session.cachedTeamCommands('t1').single.command,
      'deploy',
      reason: '입력칸 자동 완성도 바로 따라간다',
    );
  });
}
