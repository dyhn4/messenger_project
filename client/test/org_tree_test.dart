// 조직도 "부서" 탭(앱) — 트리 모양 읽기(하위 부서·부서장 먼저·인원·경로·펼친 순서), 부서·부서장·상위자 그리기, 검색, 고칠 수 있는
// 사람의 부서 만들기·부서장·상위자·지우기, 고칠 수 없는 사람에게는 메뉴 없음, 다른 기기에서 바뀌면 다시 받기. 서버는 가짜 HTTP.
import 'dart:convert';

import 'package:client/models/org_tree.dart';
import 'package:client/models/team.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/org_tree_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object? body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _dept(
  String id,
  String name, {
  String? parent,
  String? head,
  int order = 0,
}) => {
  'id': id,
  'parentId': parent,
  'name': name,
  'headId': head,
  'sortOrder': order,
};

Map<String, dynamic> _member(
  String id,
  String name, {
  String? dept,
  String? manager,
  String? effective,
  String? position,
}) => {
  'id': id,
  'name': name,
  'username': id,
  'role': 'member',
  'avatarType': 'initial',
  'position': position,
  'departmentId': dept,
  'managerId': manager,
  'effectiveManagerId': effective,
};

/// 대표실(boss) ─ 영업본부(kim) ─ 영업1팀(lee: lee·hong) / 영업2팀(부서장 없음: choi) · 부서 없음: new
Map<String, dynamic> _treeJson({bool canEdit = false}) => {
  'scope': 'server',
  'scopeKey': 'server',
  'teamId': null,
  'canEdit': canEdit,
  'departments': [
    _dept('ceo', '대표실', head: 'boss'),
    _dept('sales', '영업본부', parent: 'ceo', head: 'kim'),
    _dept('s1', '영업1팀', parent: 'sales', head: 'lee'),
    _dept('s2', '영업2팀', parent: 'sales', order: 1),
  ],
  'members': [
    _member('boss', '대표', dept: 'ceo'),
    _member('choi', '최영업', dept: 's2', effective: 'kim'),
    _member('hong', '홍길동', dept: 's1', effective: 'lee', position: '대리'),
    _member('kim', '김본부', dept: 'sales', effective: 'boss'),
    _member('lee', '이팀장', dept: 's1', effective: 'kim', position: '팀장'),
    _member('new', '신입', manager: 'lee', effective: 'lee'),
  ],
};

class _Harness {
  final requests = <http.Request>[];
  late Map<String, dynamic> tree;
  late final Session session;

  _Harness({bool canEdit = false, String orgScope = 'account'}) {
    tree = _treeJson(canEdit: canEdit);
    session = Session(
      notifications: NotificationService(),
      settings: AppSettings(),
    );
    session.serverUrl = 'https://test.local';
    session.api = ApiClient(
      baseUrl: 'https://test.local',
      token: 't',
      httpClient: MockClient((request) async {
        requests.add(request);
        final key = '${request.method} ${request.url.path}';
        if (key == 'GET /api/org-tree') return _json(tree);
        if (key == 'POST /api/org-tree/departments') {
          final b = jsonDecode(request.body) as Map<String, dynamic>;
          final made = _dept(
            'new-dept',
            b['name'] as String,
            parent: b['parentId'] as String?,
            order: 9,
          );
          tree = {
            ...tree,
            'departments': [...tree['departments'] as List, made],
          };
          return _json(made, status: 201);
        }
        if (request.method == 'PATCH' ||
            request.method == 'PUT' ||
            request.method == 'DELETE') {
          return _json({'ok': true});
        }
        return _json({'error': 'no route'}, status: 404);
      }),
    );
    session.userId = 'hong';
    session.orgScope = orgScope;
    final team = Team(id: 't1', name: '본사', createdAt: DateTime(2026));
    session.teams.add(team);
    session.currentTeam = team;
  }

  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
  Map<String, dynamic> bodyOf(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;
}

Future<List<String>> _pump(
  WidgetTester tester,
  _Harness h, {
  String filter = '',
}) async {
  tester.view.physicalSize = const Size(700, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final opened = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: OrgTreeView(
          session: h.session,
          filter: filter,
          onOpenMember: (user, _) => opened.add(user.id),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return opened;
}

void main() {
  group('OrgTree 모양', () {
    final tree = OrgTree.fromJson(_treeJson());

    test('하위 부서·사람(부서장 먼저)·인원·경로', () {
      expect(tree.childrenOf(null).map((d) => d.name), ['대표실']);
      expect(tree.childrenOf('sales').map((d) => d.name), ['영업1팀', '영업2팀']);
      expect(tree.membersOf('s1').map((m) => m.id), [
        'lee',
        'hong',
      ], reason: '부서장 먼저');
      expect(tree.membersOf(null).map((m) => m.id), ['new']);
      expect(tree.headcount('sales'), 4);
      expect(tree.headcount('ceo'), 5);
      expect(tree.pathOf('s1'), '대표실 › 영업본부 › 영업1팀');
      expect(tree.descendantsOf('ceo'), {'sales', 's1', 's2'});
      expect(tree.flatten().map((e) => '${e.depth}:${e.department.name}'), [
        '0:대표실',
        '1:영업본부',
        '2:영업1팀',
        '2:영업2팀',
      ]);
    });

    test('위 부서가 없어진 부서는 맨 위로, 없는 부서의 사람은 부서 없음으로 본다', () {
      final broken = OrgTree.fromJson({
        'scope': 'server',
        'scopeKey': 'server',
        'departments': [_dept('orphan', '고아', parent: 'gone')],
        'members': [_member('x', '엑스', dept: 'gone')],
      });
      expect(broken.childrenOf(null).map((d) => d.id), ['orphan']);
      expect(broken.membersOf(null).map((m) => m.id), ['x']);
    });
  });

  testWidgets('부서 트리 — 맨 위 부서가 펼쳐져 있고, 펼치면 부서장 표시·상위자, 사람을 누르면 프로필', (
    tester,
  ) async {
    final h = _Harness();
    final opened = await _pump(tester, h);
    expect(
      h
          .called('GET', '/api/org-tree')
          .single
          .url
          .queryParameters
          .containsKey('teamId'),
      isFalse,
      reason: '회사 하나',
    );
    expect(find.text('대표실'), findsOneWidget);
    expect(find.text('부서장 대표'), findsOneWidget);
    expect(find.text('영업본부'), findsOneWidget, reason: '맨 위 부서는 펼쳐져 있다');
    expect(find.text('영업1팀'), findsNothing, reason: '그 아래는 접혀 있다');
    await tester.tap(find.text('영업본부'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('영업1팀'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('org-head-badge-lee')), findsOneWidget);
    expect(find.text('대리 · 상위자 이팀장'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('org-add-department')),
      findsNothing,
      reason: '고칠 수 없는 사람',
    );
    expect(find.byKey(const ValueKey('org-department-menu-s1')), findsNothing);
    // 부서 없음 묶음 — 따로 정한 상위자는 "(지정)".
    await tester.tap(find.byKey(const ValueKey('org-unassigned')));
    await tester.pumpAndSettle();
    expect(find.text('상위자 이팀장(지정)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('org-member-hong')));
    expect(opened, ['hong']);
  });

  testWidgets('검색 — 부서는 경로·인원, 사람은 부서 경로와 함께', (tester) async {
    final h = _Harness();
    await _pump(tester, h, filter: '영업');
    expect(
      find.byKey(const ValueKey('org-search-department-s1')),
      findsOneWidget,
    );
    expect(find.text('대표실 › 영업본부 › 영업1팀 · 2명'), findsOneWidget);
    expect(find.byKey(const ValueKey('org-member-choi')), findsOneWidget);
    expect(find.text('대표실 › 영업본부 › 영업2팀 · 상위자 김본부'), findsOneWidget);
    expect(find.byKey(const ValueKey('org-member-hong')), findsNothing);
  });

  testWidgets('고치기 — 부서 만들기, 부서장 정하기, 상위자 정하기, 지우기', (tester) async {
    final h = _Harness(canEdit: true);
    await _pump(tester, h);
    await tester.tap(find.byKey(const ValueKey('org-add-department')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('org-department-name')),
      '경영지원실',
    );
    await tester.tap(find.byKey(const ValueKey('org-department-name-confirm')));
    await tester.pumpAndSettle();
    expect(h.bodyOf(h.called('POST', '/api/org-tree/departments').single), {
      'name': '경영지원실',
      'parentId': null,
    });
    expect(find.text('경영지원실'), findsOneWidget);

    // 대표실 부서장 → 김본부.
    await tester.tap(find.byKey(const ValueKey('org-department-menu-ceo')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('부서장 정하기'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('org-person-search')),
      '김',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('org-pick-person-kim')));
    await tester.pumpAndSettle();
    expect(
      h.bodyOf(h.called('PATCH', '/api/org-tree/departments/ceo').single),
      {'headId': 'kim'},
    );

    // 대표의 상위자를 "따로 정하지 않음"으로 — 이미 null이면 보내지 않는다.
    await tester.tap(find.byKey(const ValueKey('org-member-menu-boss')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('상위자 정하기'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('org-pick-person-boss')),
      findsNothing,
      reason: '자기 자신은 목록에 없다',
    );
    await tester.tap(find.byKey(const ValueKey('org-pick-person-none')));
    await tester.pumpAndSettle();
    expect(h.requests.where((r) => r.method == 'PUT'), isEmpty);

    // 김본부의 상위자 → 홍길동(영업본부를 펼쳐야 보인다).
    await tester.tap(find.text('영업본부'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('org-member-menu-kim')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('상위자 정하기'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('org-pick-person-hong')));
    await tester.pumpAndSettle();
    expect(h.bodyOf(h.called('PUT', '/api/org-tree/members/kim').single), {
      'managerId': 'hong',
    });

    // 영업본부 지우기 — 확인 창은 구성원이 대표실로 올라간다고 알린다.
    await tester.tap(find.byKey(const ValueKey('org-department-menu-sales')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('지우기'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"대표실"(으)로 올라갑니다'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('org-delete-confirm')));
    await tester.pumpAndSettle();
    expect(h.called('DELETE', '/api/org-tree/departments/sales'), hasLength(1));
  });

  testWidgets('부서 옮기기 — 자기와 그 아래 부서는 고를 수 없다', (tester) async {
    final h = _Harness(canEdit: true);
    await _pump(tester, h);
    await tester.tap(find.byKey(const ValueKey('org-department-menu-sales')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('다른 부서 아래로 옮기기'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('org-pick-department-sales')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('org-pick-department-s1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('org-pick-department-none')));
    await tester.pumpAndSettle();
    expect(
      h.bodyOf(h.called('PATCH', '/api/org-tree/departments/sales').single),
      {'parentId': null},
    );
  });

  testWidgets('팀 단위 조직도는 지금 팀으로 받고, 팀이 여럿이면 고를 수 있다', (tester) async {
    final h = _Harness(orgScope: 'team');
    h.session.teams.add(Team(id: 't2', name: '지사', createdAt: DateTime(2026)));
    await _pump(tester, h);
    expect(
      h.called('GET', '/api/org-tree').single.url.queryParameters['teamId'],
      't1',
    );
    await tester.tap(find.byKey(const ValueKey('org-tree-team')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('지사').last);
    await tester.pumpAndSettle();
    expect(
      h.called('GET', '/api/org-tree').last.url.queryParameters['teamId'],
      't2',
    );
  });
}
