import 'dart:convert';

import 'package:client/models/team.dart';
import 'package:client/screens/team_settings_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/floating_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 팀 설정 "팀원 추가"의 후보는 서버의 전용 목록(GET /api/teams/:id/member-candidates — 그 팀을 관리할 수 있는
/// 사람만)에서 받는다. 회원 목록(GET /api/users)은 관리자 이상이 아니면 팀을 같이 쓰는 사람만 주는데(server
/// userDirectory.js), 넣을 사람은 아직 이 팀에 없어서(회원가입만 한 사람은 어느 팀에도 없다) 거기서는 못 찾는다.
///
/// 그 전용 목록도 계정 등급 관리자·서버 운영자에게만 서버 전체('all')이고, 그 밖의 소유자에게는 팀을 같이 쓰는
/// 사람뿐('coTeam')이다 — 팀만 만들면 누구나 소유자가 되므로. 그때 팀 밖 사람은 아이디를 정확히 넣어 한 명씩 찾는다
/// (?username=).

Map<String, dynamic> _user(String id, String name, {String role = 'member'}) =>
    {'id': id, 'username': '$id-login', 'name': name, 'role': role};

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

/// 테스트용 세션 — [handler]가 요청마다 답한다(답하지 않은 요청은 빈 목록). 받은 요청은 [requests]에 쌓인다.
Session _session(
  List<http.Request> requests,
  Future<http.Response?> Function(http.Request request) handler, {
  bool canCreateTeamInviteLink = false,
}) {
  final session = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  session.userId = 'me';
  session.canCreateTeamInviteLink = canCreateTeamInviteLink;
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: MockClient((request) async {
      requests.add(request);
      return await handler(request) ?? _json(<Object>[]);
    }),
  );
  return session;
}

final _team = Team(
  id: 't1',
  name: '개발',
  createdAt: DateTime(2026),
  isOwner: true,
);

/// 팀 설정 → 멤버 탭 → "추가"까지 열어 둔다.
Future<void> _openAddDialog(WidgetTester tester, Session session) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showTeamSettingsDialog(context, session, _team),
            child: const Text('열기'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('멤버'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(TextButton, '추가'));
  await tester.pumpAndSettle();
}

Finder _inAddDialog(Finder f) => find.descendant(
  of: find.ancestor(
    of: find.text('팀원 추가'),
    matching: find.byType(FloatingDialog),
  ),
  matching: f,
);

String _path(http.Request r) =>
    '${r.method} ${r.url.path}${r.url.hasQuery ? '?${r.url.query}' : ''}';

void main() {
  testWidgets('관리자 이상: 서버 전체 후보를 받아 보여 주고, 고른 사람만 팀에 넣는다', (tester) async {
    final me = {..._user('me', '나'), 'isOwner': true};
    final kim = _user('kim', '김철수');
    final park = _user('park', '박민수');
    final choi = _user('choi', '최지우', role: 'guest');
    var members = [me, kim];
    final requests = <http.Request>[];
    final session = _session(requests, (request) async {
      switch ('${request.method} ${request.url.path}') {
        case 'GET /api/teams/t1/members':
          return _json(members);
        case 'GET /api/teams/t1/member-candidates':
          // 서버는 팀원을 빼고 주지만, 화면도 지금 팀원 목록과 한 번 더 맞춘다(김철수는 이미 팀원).
          return _json({
            'scope': 'all',
            'users': [park, choi, kim],
          });
        case 'POST /api/teams/t1/members':
          final ids =
              (jsonDecode(request.body) as Map<String, dynamic>)['userIds']
                  as List;
          members = [
            ...members,
            for (final u in [park, choi])
              if (ids.contains(u['id'])) u,
          ];
          return _json(members);
      }
      return null;
    });
    await _openAddDialog(tester, session);

    final paths = requests.map(_path).toList();
    expect(paths, contains('GET /api/teams/t1/member-candidates'));
    // 서버 전체 회원 목록에 기대지 않는다(관리자 이상이 아니면 팀 밖 사람은 거기 없다).
    expect(paths, isNot(contains('GET /api/users')));

    expect(_inAddDialog(find.text('박민수')), findsOneWidget);
    expect(_inAddDialog(find.text('park-login · 정회원')), findsOneWidget);
    expect(_inAddDialog(find.text('choi-login · 준회원')), findsOneWidget);
    expect(_inAddDialog(find.text('김철수')), findsNothing);
    // 받은 목록이 전부라 아이디로 따로 찾을 일이 없다.
    expect(_inAddDialog(find.text('아이디로 찾기')), findsNothing);

    // 검색 칸은 받은 목록을 이름·아이디로 거른다(서버에 다시 묻지 않는다).
    await tester.enterText(
      _inAddDialog(find.byKey(const ValueKey('add-team-members-search'))),
      'CHOI',
    );
    await tester.pump();
    expect(_inAddDialog(find.text('최지우')), findsOneWidget);
    expect(_inAddDialog(find.text('박민수')), findsNothing);
    await tester.enterText(
      _inAddDialog(find.byKey(const ValueKey('add-team-members-search'))),
      '민수',
    );
    await tester.pump();
    expect(_inAddDialog(find.text('박민수')), findsOneWidget);
    expect(_inAddDialog(find.text('최지우')), findsNothing);
    expect(
      requests.where((r) => r.url.path.endsWith('/member-candidates')).length,
      1,
    );

    await tester.tap(_inAddDialog(find.text('박민수')));
    await tester.pump();
    await tester.tap(_inAddDialog(find.text('추가하기 (1)')));
    await tester.pumpAndSettle();

    final post = requests.singleWhere((r) => r.method == 'POST');
    expect(post.url.path, '/api/teams/t1/members');
    expect(jsonDecode(post.body), {
      'userIds': ['park'],
    });
    expect(find.text('팀원 추가'), findsNothing); // 창이 닫히고
    expect(find.text('박민수'), findsOneWidget); // 멤버 탭에 새 팀원이 보인다.
    expect(find.text('최지우'), findsNothing);
  });

  testWidgets('관리자가 아닌 소유자: 팀을 같이 쓰는 사람만 보이고, 팀 밖 사람은 아이디로 찾아 넣는다', (
    tester,
  ) async {
    final me = {..._user('me', '나'), 'isOwner': true};
    final park = _user('park', '박민수');
    final newbie = _user('newbie', '신입');
    var members = [me];
    final requests = <http.Request>[];
    final session = _session(requests, (request) async {
      if (request.url.path == '/api/teams/t1/member-candidates') {
        final username = request.url.queryParameters['username'];
        if (username == null) {
          return _json({
            'scope': 'coTeam',
            'users': [park],
          });
        }
        // 서버는 아이디가 정확히 같은 사람만 준다.
        return _json({
          'scope': 'username',
          'users': [if (username == 'newbie-login') newbie],
        });
      }
      switch ('${request.method} ${request.url.path}') {
        case 'GET /api/teams/t1/members':
          return _json(members);
        case 'POST /api/teams/t1/members':
          final ids =
              (jsonDecode(request.body) as Map<String, dynamic>)['userIds']
                  as List;
          members = [
            ...members,
            for (final u in [park, newbie])
              if (ids.contains(u['id'])) u,
          ];
          return _json(members);
      }
      return null;
    }, canCreateTeamInviteLink: true);
    await _openAddDialog(tester, session);

    expect(_inAddDialog(find.text('박민수')), findsOneWidget);
    expect(_inAddDialog(find.text('신입')), findsNothing);
    expect(
      _inAddDialog(find.textContaining('팀을 같이 쓰는 사람만 목록에 나옵니다.')),
      findsOneWidget,
    );
    // 팀 초대 링크를 만들 수 있으면 새로 가입할 사람에게 그 길도 알려 준다.
    expect(_inAddDialog(find.textContaining('팀 초대 링크')), findsOneWidget);

    final search = _inAddDialog(
      find.byKey(const ValueKey('add-team-members-search')),
    );
    // 목록을 거르기만 해서는 팀 밖 사람이 안 나온다 — 아이디로 찾기를 눌러야 서버에 묻는다.
    await tester.enterText(search, 'newbie-login');
    await tester.pump();
    expect(_inAddDialog(find.textContaining('목록에 없는 사람입니다.')), findsOneWidget);
    expect(requests.map(_path), isNot(contains(contains('username='))));

    await tester.tap(_inAddDialog(find.text('아이디로 찾기')));
    await tester.pumpAndSettle();
    expect(
      requests.map(_path),
      contains('GET /api/teams/t1/member-candidates?username=newbie-login'),
    );
    expect(_inAddDialog(find.text('신입')), findsOneWidget);
    expect(_inAddDialog(find.text('신입 님을 찾아 선택했습니다.')), findsOneWidget);
    // 찾은 사람은 바로 골라 둔다.
    expect(_inAddDialog(find.text('추가하기 (1)')), findsOneWidget);

    // 검색 칸을 비우면 원래 목록과 찾은 사람이 함께 보인다 — 둘 다 골라 넣는다.
    await tester.enterText(search, '');
    await tester.pump();
    expect(_inAddDialog(find.text('박민수')), findsOneWidget);
    expect(_inAddDialog(find.text('신입')), findsOneWidget);
    await tester.tap(_inAddDialog(find.text('박민수')));
    await tester.pump();
    await tester.tap(_inAddDialog(find.text('추가하기 (2)')));
    await tester.pumpAndSettle();

    final post = requests.singleWhere((r) => r.method == 'POST');
    expect(
      ((jsonDecode(post.body) as Map<String, dynamic>)['userIds'] as List)
          .toSet(),
      {'newbie', 'park'},
    );
    expect(find.text('팀원 추가'), findsNothing);
    expect(find.text('신입'), findsOneWidget);
  });

  testWidgets('아이디로 찾기: 못 찾거나 아이디 길이가 맞지 않으면 안내하고, 서버 안내(횟수 제한 등)도 보여 준다', (
    tester,
  ) async {
    final requests = <http.Request>[];
    var lookups = 0;
    final session = _session(requests, (request) async {
      if (request.url.path == '/api/teams/t1/member-candidates') {
        if (request.url.queryParameters['username'] == null) {
          return _json({'scope': 'coTeam', 'users': <Object>[]});
        }
        lookups += 1;
        if (lookups == 1) {
          return _json({'scope': 'username', 'users': <Object>[]});
        }
        return _json({
          'error': '아이디로 찾기가 너무 많습니다. 10분 후 다시 시도하세요.',
        }, status: 429);
      }
      if (request.url.path == '/api/teams/t1/members') {
        return _json([
          {..._user('me', '나'), 'isOwner': true},
        ]);
      }
      return null;
    });
    await _openAddDialog(tester, session);

    expect(
      _inAddDialog(find.text('팀을 같이 쓰는 사람 중에는 추가할 수 있는 사람이 없습니다.')),
      findsOneWidget,
    );
    // 팀 초대 링크를 만들 수 없는 사람에게는 그 안내를 붙이지 않는다.
    expect(_inAddDialog(find.textContaining('팀 초대 링크')), findsNothing);

    final search = _inAddDialog(
      find.byKey(const ValueKey('add-team-members-search')),
    );
    // 가입 규칙(4~20자)에 안 맞는 값은 서버에 묻지 않는다(찾기 횟수만 깎인다).
    await tester.enterText(search, 'abc');
    await tester.tap(_inAddDialog(find.text('아이디로 찾기')));
    await tester.pumpAndSettle();
    expect(
      _inAddDialog(find.text('찾을 사람의 아이디를 정확히 입력하세요(4~20자).')),
      findsOneWidget,
    );
    expect(lookups, 0);

    // Enter로도 찾는다 — 없는 아이디(또는 이미 팀원·정지·탈퇴한 계정)면 안내한다.
    await tester.enterText(search, '  ghost-user ');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(lookups, 1);
    expect(
      requests.map(_path),
      contains('GET /api/teams/t1/member-candidates?username=ghost-user'),
    );
    expect(
      _inAddDialog(find.textContaining("'ghost-user' 아이디로 추가할 수 있는 사람이 없습니다.")),
      findsOneWidget,
    );

    await tester.tap(_inAddDialog(find.text('아이디로 찾기')));
    await tester.pumpAndSettle();
    expect(lookups, 2);
    expect(
      _inAddDialog(find.text('아이디로 찾기가 너무 많습니다. 10분 후 다시 시도하세요.')),
      findsOneWidget,
    );
    expect(_inAddDialog(find.text('추가하기 (0)')), findsOneWidget);
  });

  testWidgets('후보 목록을 못 받으면(권한 없음 등) 서버가 준 안내를 보여 준다', (tester) async {
    final requests = <http.Request>[];
    final session = _session(requests, (request) async {
      switch ('${request.method} ${request.url.path}') {
        case 'GET /api/teams/t1/members':
          return _json([
            {..._user('me', '나'), 'isOwner': true},
          ]);
        case 'GET /api/teams/t1/member-candidates':
          return _json({'error': '멤버를 추가할 권한이 없습니다.'}, status: 403);
      }
      return null;
    });
    await _openAddDialog(tester, session);

    expect(find.text('멤버를 추가할 권한이 없습니다.'), findsOneWidget);
    // 목록을 못 받았으면 검색 칸도 없다.
    expect(find.byKey(const ValueKey('add-team-members-search')), findsNothing);
  });
}
