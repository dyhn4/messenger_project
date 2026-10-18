// 방 "웹훅·앱" 창 — 들어오는 웹훅의 단추 응답 주소(처음 정하면 서명 비밀은 이번에만), 나가는 웹훅(목록·만들기(받을 일 고르기) → 서명
// 비밀은 이번에만·꺼진 것 표시와 다시 켜기·보내 보기·보내기 기록), 앱(추가한 앱 목록·추가 고르기(이미 있는 앱은 빼고)·빼기). 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/room_webhooks_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
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

Room _room() => Room.fromJson({
  'id': 'r1',
  'teamId': 't1',
  'type': 'group',
  'name': '프로젝트방',
  'members': [_member('me', '나'), _member('u2', '김철수')],
  'createdAt': 1000,
  'isSecret': false,
  'viewMode': 'chat',
  'adminIds': const <String>[],
});

Session _session(List<http.Request> requests, _Routes routes) {
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
  session.accountRole = AccountRole.member;
  final team = Team(id: 't1', name: '개발팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.add(_room());
  return session;
}

Map<String, dynamic> _webhook(String id, String name, {String? interaction}) =>
    {
      'id': id,
      'kind': 'webhook',
      'teamId': 't1',
      'roomId': 'r1',
      'name': name,
      'emoji': '🚨',
      'tokenPrefix': 'ttw_AbCd',
      'interactionUrl': interaction,
      'hasSigningSecret': interaction != null,
      'createdAt': 1000,
      'lastUsedAt': null,
      'useCount': 0,
    };

Map<String, dynamic> _outgoing(
  String id,
  String name, {
  List<String> events = const ['message.created'],
  bool enabled = true,
  int failureCount = 0,
}) => {
  'id': id,
  'kind': 'outgoing',
  'teamId': 't1',
  'roomId': 'r1',
  'name': name,
  'emoji': '📤',
  'url': 'https://erp.company.com/hooks/$id',
  'events': events,
  'enabled': enabled,
  'failureCount': failureCount,
  'hasSigningSecret': true,
  'createdAt': 1000,
  'lastUsedAt': null,
  'useCount': 0,
};

Map<String, dynamic> _app(String id, String name, {String? addedBy}) => {
  'id': id,
  'name': name,
  'emoji': '🤖',
  'description': '$name 설명',
  'enabled': true,
  'addedByName': addedBy,
  'addedAt': addedBy == null
      ? null
      : DateTime(2026, 10, 1, 9).millisecondsSinceEpoch,
};

Map<String, dynamic> _bodyOf(http.Request r) =>
    jsonDecode(r.body) as Map<String, dynamic>;

Future<void> _open(WidgetTester tester, Session session) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showRoomWebhooksDialog(
                context,
                session,
                session.rooms.single,
              ),
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

/// [scroll]이면 먼저 보이게 굴린다 — 창 안의 세로 목록(받을 일 고르기)에만. 탭 본문은 가로 PageView 안이라 굴리면 탭이 밀린다.
Future<void> _tapKey(
  WidgetTester tester,
  String key, {
  bool scroll = false,
}) async {
  if (scroll) {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

Future<void> _menu(WidgetTester tester, String menuKey, String item) async {
  await _tapKey(tester, menuKey);
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

String _secretShown(WidgetTester tester) => tester
    .widget<SelectableText>(find.byKey(const ValueKey('integration-secret')))
    .data!;

void main() {
  testWidgets('창 제목·탭 셋 — 처음에는 들어오는 웹훅만 받는다', (tester) async {
    final requests = <http.Request>[];
    final session = _session(requests, {
      'GET /api/rooms/r1/webhooks': (_) => _json([_webhook('w1', '서버 모니터링')]),
    });
    await _open(tester, session);
    expect(find.text('웹훅·앱'), findsOneWidget);
    expect(find.text('들어오는 웹훅'), findsOneWidget);
    expect(find.text('나가는 웹훅'), findsOneWidget);
    expect(find.text('앱'), findsOneWidget);
    expect(find.byKey(const ValueKey('webhook-w1')), findsOneWidget);
    expect(find.byKey(const ValueKey('webhook-create')), findsOneWidget);
    expect(requests.map((r) => r.url.path), [
      '/api/rooms/r1/webhooks',
    ], reason: '다른 탭은 열 때 받는다');
  });

  testWidgets('들어오는 웹훅 "단추 응답 주소": 정하면 PATCH, 처음 생긴 서명 비밀은 이번에만', (
    tester,
  ) async {
    final requests = <http.Request>[];
    var hook = _webhook('w1', '서버 모니터링');
    final session = _session(requests, {
      'GET /api/rooms/r1/webhooks': (_) => _json([hook]),
      'PATCH /api/integrations/w1': (r) {
        final url = _bodyOf(r)['interactionUrl'] as String?;
        hook = _webhook('w1', '서버 모니터링', interaction: url);
        return _json({...hook, 'secret': 'a' * 64});
      },
    });
    await _open(tester, session);
    await _menu(tester, 'webhook-menu-w1', '단추 응답 주소');
    expect(find.textContaining('사내 주소·다른 포트는 서버 관리자만'), findsOneWidget);
    // http(s)가 아니면 창에서 막는다.
    await tester.enterText(
      find.byKey(const ValueKey('webhook-interaction-url')),
      'ftp://nope',
    );
    await _tapKey(tester, 'webhook-interaction-confirm');
    expect(find.textContaining('http:// 또는 https://'), findsOneWidget);
    expect(requests.where((r) => r.method == 'PATCH'), isEmpty);

    await tester.enterText(
      find.byKey(const ValueKey('webhook-interaction-url')),
      ' https://ops.company.com/actions ',
    );
    await _tapKey(tester, 'webhook-interaction-confirm');
    final patch = requests.singleWhere((r) => r.method == 'PATCH');
    expect(_bodyOf(patch), {
      'interactionUrl': 'https://ops.company.com/actions',
    });
    expect(_secretShown(tester), 'a' * 64);
    expect(find.textContaining('block_actions'), findsOneWidget);
    await _tapKey(tester, 'integration-secret-done');
    expect(
      find.textContaining('단추 응답: https://ops.company.com/actions'),
      findsOneWidget,
    );

    // 서명 비밀이 생겼으니 "새 서명 비밀"이 메뉴에 보인다.
    await _tapKey(tester, 'webhook-menu-w1');
    expect(find.text('새 서명 비밀'), findsOneWidget);
  });

  testWidgets('들어오는 웹훅 응답 주소를 비우면 null로 뺀다 — 비밀이 안 오면 창도 없다', (tester) async {
    final requests = <http.Request>[];
    final session = _session(requests, {
      'GET /api/rooms/r1/webhooks': (_) => _json([
        _webhook('w1', '서버 모니터링', interaction: 'https://ops.company.com/a'),
      ]),
      'PATCH /api/integrations/w1': (_) => _json(_webhook('w1', '서버 모니터링')),
    });
    await _open(tester, session);
    await _menu(tester, 'webhook-menu-w1', '단추 응답 주소');
    await tester.enterText(
      find.byKey(const ValueKey('webhook-interaction-url')),
      '',
    );
    await _tapKey(tester, 'webhook-interaction-confirm');
    expect(_bodyOf(requests.singleWhere((r) => r.method == 'PATCH')), {
      'interactionUrl': null,
    });
    expect(find.byKey(const ValueKey('integration-secret')), findsNothing);
  });

  testWidgets('나가는 웹훅: 목록 → 만들기(받을 일 고르기) → 서명 비밀은 이번에만', (tester) async {
    final requests = <http.Request>[];
    var hooks = [
      _outgoing('o1', '업무 시스템', events: ['message.created', 'mention']),
    ];
    final session = _session(requests, {
      'GET /api/rooms/r1/webhooks': (_) => _json([]),
      'GET /api/rooms/r1/outgoing-webhooks': (_) => _json(hooks),
      'POST /api/rooms/r1/outgoing-webhooks': (r) {
        final b = _bodyOf(r);
        final made = _outgoing(
          'o2',
          b['name'] as String,
          events: (b['events'] as List).cast<String>(),
        );
        hooks = [...hooks, made];
        return _json({...made, 'secret': 'b' * 64}, status: 201);
      },
    });
    await _open(tester, session);
    await _tapKey(tester, 'webhooks-tab-outgoing');
    expect(find.byKey(const ValueKey('outgoing-o1')), findsOneWidget);
    expect(find.text('업무 시스템'), findsOneWidget);
    expect(find.text('https://erp.company.com/hooks/o1'), findsOneWidget);
    expect(find.text('새 메시지 · 멘션'), findsOneWidget);
    expect(find.byKey(const ValueKey('outgoing-disabled-o1')), findsNothing);

    await _tapKey(tester, 'outgoing-create');
    // 처음에는 새 메시지·멘션이 골라져 있다.
    bool checked(String e) => tester
        .widget<CheckboxListTile>(find.byKey(ValueKey('outgoing-event-$e')))
        .value!;
    expect(checked('message.created'), isTrue);
    expect(checked('mention'), isTrue);
    expect(checked('todo.created'), isFalse);

    // 이름이 없으면 막는다.
    await _tapKey(tester, 'outgoing-confirm');
    expect(find.text('이름을 넣으세요.'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('outgoing-name')), 'CRM');
    await tester.enterText(
      find.byKey(const ValueKey('outgoing-url')),
      'https://crm.company.com/in',
    );
    await tester.enterText(find.byKey(const ValueKey('outgoing-emoji')), '📮');
    // 받을 일을 모두 빼면 막는다.
    await _tapKey(tester, 'outgoing-event-message.created', scroll: true);
    await _tapKey(tester, 'outgoing-event-mention', scroll: true);
    await _tapKey(tester, 'outgoing-confirm');
    expect(find.text('받을 일을 하나 이상 고르세요.'), findsOneWidget);
    expect(requests.where((r) => r.method == 'POST'), isEmpty);

    await _tapKey(tester, 'outgoing-event-todo.created', scroll: true);
    await _tapKey(tester, 'outgoing-event-mention', scroll: true);
    await _tapKey(tester, 'outgoing-confirm');
    final post = requests.singleWhere((r) => r.method == 'POST');
    expect(_bodyOf(post), {
      'name': 'CRM',
      'url': 'https://crm.company.com/in',
      'events': ['mention', 'todo.created'],
      'emoji': '📮',
    });
    expect(_secretShown(tester), 'b' * 64);
    expect(find.textContaining('X-TangoTalk-Signature'), findsOneWidget);
    await _tapKey(tester, 'integration-secret-done');
    expect(find.byKey(const ValueKey('outgoing-o2')), findsOneWidget);
    expect(
      find.textContaining('b' * 64),
      findsNothing,
      reason: '닫으면 다시 볼 수 없다',
    );
  });

  testWidgets('꺼진 나가는 웹훅은 표시가 붙고 "켜기"는 enabled: true', (tester) async {
    final requests = <http.Request>[];
    var hook = _outgoing('o1', '업무 시스템', enabled: false, failureCount: 10);
    final session = _session(requests, {
      'GET /api/rooms/r1/webhooks': (_) => _json([]),
      'GET /api/rooms/r1/outgoing-webhooks': (_) => _json([hook]),
      'PATCH /api/integrations/o1': (r) {
        hook = _outgoing(
          'o1',
          '업무 시스템',
          enabled: _bodyOf(r)['enabled'] as bool,
        );
        return _json(hook);
      },
    });
    await _open(tester, session);
    await _tapKey(tester, 'webhooks-tab-outgoing');
    expect(find.byKey(const ValueKey('outgoing-disabled-o1')), findsOneWidget);
    expect(find.text('꺼짐 — 보내기가 계속 실패했습니다'), findsOneWidget);
    await _menu(tester, 'outgoing-menu-o1', '켜기');
    expect(_bodyOf(requests.singleWhere((r) => r.method == 'PATCH')), {
      'enabled': true,
    });
    expect(find.byKey(const ValueKey('outgoing-disabled-o1')), findsNothing);
    // 켜진 것의 메뉴에는 "켜기"가 없다.
    await _tapKey(tester, 'outgoing-menu-o1');
    expect(find.text('켜기'), findsNothing);
  });

  testWidgets('나가는 웹훅 보내 보기(결과 알림)·보내기 기록', (tester) async {
    final requests = <http.Request>[];
    final session = _session(requests, {
      'GET /api/rooms/r1/webhooks': (_) => _json([]),
      'GET /api/rooms/r1/outgoing-webhooks': (_) =>
          _json([_outgoing('o1', '업무 시스템')]),
      'POST /api/integrations/o1/test': (_) => _json({
        'id': 'd1',
        'event': 'ping',
        'status': 'delivered',
        'attempts': 1,
        'lastStatus': 204,
        'createdAt': 2000,
      }),
      'GET /api/integrations/o1/deliveries': (_) => _json([
        {
          'id': 'd2',
          'event': 'message.created',
          'status': 'failed',
          'attempts': 7,
          'lastStatus': 500,
          'lastError': '받는 서버가 오류를 돌려줬습니다(500).',
          'createdAt': DateTime(2026, 10, 2, 14, 5).millisecondsSinceEpoch,
        },
        {
          'id': 'd1',
          'event': 'ping',
          'status': 'delivered',
          'attempts': 1,
          'lastStatus': 204,
          'createdAt': DateTime(2026, 10, 2, 9).millisecondsSinceEpoch,
        },
      ]),
    });
    await _open(tester, session);
    await _tapKey(tester, 'webhooks-tab-outgoing');
    await _menu(tester, 'outgoing-menu-o1', '보내 보기');
    expect(requests.where((r) => r.url.path.endsWith('/test')), hasLength(1));
    expect(find.text('보냈습니다 (HTTP 204)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await _menu(tester, 'outgoing-menu-o1', '보내기 기록');
    expect(find.byKey(const ValueKey('delivery-d2')), findsOneWidget);
    expect(find.text('2026/10/02 PM 2:05 · 새 메시지'), findsOneWidget);
    expect(find.text('실패 — 받는 서버가 오류를 돌려줬습니다(500). · 7번 시도'), findsOneWidget);
    expect(find.text('보냄 (HTTP 204) · 1번 시도'), findsOneWidget);
    expect(find.textContaining('시험 보내기'), findsOneWidget);
  });

  testWidgets('앱: 추가한 앱 목록 → 추가 고르기는 이미 있는 앱을 빼고 addAppToRoom, 빼기는 확인 뒤', (
    tester,
  ) async {
    final requests = <http.Request>[];
    var installed = [_app('a1', '근태봇', addedBy: '김철수')];
    final session = _session(requests, {
      'GET /api/rooms/r1/webhooks': (_) => _json([]),
      'GET /api/rooms/r1/apps': (_) => _json(installed),
      'GET /api/teams/t1/apps': (_) => _json([
        _app('a1', '근태봇'),
        _app('a2', '배포봇'),
        {..._app('a3', '꺼진봇'), 'enabled': false},
      ]),
      'POST /api/rooms/r1/apps': (r) {
        expect(_bodyOf(r), {'appId': 'a2'});
        installed = [...installed, _app('a2', '배포봇', addedBy: '나')];
        return _json({'ok': true}, status: 201);
      },
      'DELETE /api/rooms/r1/apps/a1': (_) {
        installed = installed.where((a) => a['id'] != 'a1').toList();
        return _json({'ok': true});
      },
    });
    await _open(tester, session);
    await _tapKey(tester, 'webhooks-tab-apps');
    expect(find.byKey(const ValueKey('room-app-a1')), findsOneWidget);
    expect(find.textContaining('근태봇 설명'), findsOneWidget);
    expect(find.textContaining('김철수님이 추가'), findsOneWidget);

    await _tapKey(tester, 'room-app-add');
    expect(find.byKey(const ValueKey('room-app-pick-a1')), findsNothing);
    expect(find.byKey(const ValueKey('room-app-pick-a3')), findsNothing);
    expect(find.byKey(const ValueKey('room-app-pick-a2')), findsOneWidget);
    expect(find.textContaining('이 앱은 이 방의 메시지를 읽고 쓸 수 있습니다'), findsOneWidget);
    final confirm = find.byKey(const ValueKey('room-app-add-confirm'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await _tapKey(tester, 'room-app-pick-a2');
    await _tapKey(tester, 'room-app-add-confirm');
    expect(
      requests.where(
        (r) => r.method == 'POST' && r.url.path == '/api/rooms/r1/apps',
      ),
      hasLength(1),
    );
    expect(find.byKey(const ValueKey('room-app-a2')), findsOneWidget);

    await _tapKey(tester, 'room-app-remove-a1');
    expect(find.textContaining('더 이 방의 메시지를 읽거나 올리지 못하고'), findsOneWidget);
    await _tapKey(tester, 'integration-delete-confirm');
    expect(requests.where((r) => r.method == 'DELETE'), hasLength(1));
    expect(find.byKey(const ValueKey('room-app-a1')), findsNothing);
  });

  testWidgets('폰처럼 좁고 낮은 화면에서도 넘치지 않는다(목록은 스크롤)', (tester) async {
    final session = _session([], {
      'GET /api/rooms/r1/webhooks': (_) =>
          _json([for (var i = 0; i < 8; i++) _webhook('w$i', '웹훅 $i')]),
      'GET /api/rooms/r1/outgoing-webhooks': (_) => _json([
        for (var i = 0; i < 8; i++)
          _outgoing('o$i', '나가는 웹훅 $i', enabled: i.isEven),
      ]),
    });
    await _open(tester, session);
    tester.view.physicalSize = const Size(360, 640);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _tapKey(tester, 'webhooks-tab-outgoing');
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('outgoing-create')), findsOneWidget);
  });

  testWidgets('팀에 앱이 없으면 서버 운영자가 관리자 콘솔에서 만든다는 안내', (tester) async {
    final session = _session([], {
      'GET /api/rooms/r1/webhooks': (_) => _json([]),
      'GET /api/rooms/r1/apps': (_) => _json([]),
      'GET /api/teams/t1/apps': (_) => _json([]),
    });
    await _open(tester, session);
    await _tapKey(tester, 'webhooks-tab-apps');
    expect(find.text('이 방에 추가한 앱이 없습니다.'), findsOneWidget);
    await _tapKey(tester, 'room-app-add');
    expect(find.textContaining('관리자 콘솔 → 연동 앱'), findsOneWidget);
    expect(find.byKey(const ValueKey('room-app-add-confirm')), findsNothing);
  });
}
