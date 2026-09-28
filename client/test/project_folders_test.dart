import 'dart:convert';

import 'package:client/models/team.dart';
import 'package:client/screens/project/project_home_view.dart';
import 'package:client/screens/project/project_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 사이드바 개인 프로젝트 폴더([+] > 폴더 추가, 접기, ⋯ 메뉴, 끌어다 놓기)와
/// 공개 프로젝트 생성 알림(project_created)을 눌러 프로젝트를 여는 흐름,
/// 그리고 프로젝트 ⋯ > 프로젝트 설정(담당자·팀 관리자에게만, 닫은 뒤 목록·열린 화면 새로 읽기).
void main() {
  const json = {'content-type': 'application/json'};
  final now = DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> project(String id, String name, {bool fav = false}) => {
    'id': id,
    'teamId': 't1',
    'name': name,
    'identifier': id.toUpperCase(),
    'color': '#5B8DEF',
    'isPublic': true,
    'favorite': fav,
    'myRole': 'member',
    'createdAt': now,
    'members': <Map<String, dynamic>>[],
  };

  /// 폴더 API를 흉내 내는 작은 서버 — 받은 요청을 [log]에 남기고 상태를 바꾼다.
  late List<String> log;

  /// 받은 GET(경로?쿼리) — 폴더 작업 뒤 무엇을 다시 읽었는지(열린 화면까지 새로 불렀는지) 본다.
  late List<String> gets;
  late List<Map<String, dynamic>> folders;
  late List<Map<String, dynamic>> projects;
  late bool newProjectVisible;

  /// 폴더 만들기(POST)·프로젝트 옮기기(PUT)를 일부러 실패시킨다.
  late bool failCreate;
  late bool failMove;
  var nextFolder = 1;

  void resetServer() {
    log = [];
    gets = [];
    nextFolder = 1;
    newProjectVisible = false;
    failCreate = false;
    failMove = false;
    projects = [
      project('p1', '잔디톡', fav: true),
      project('p2', '디자인'),
      project('p3', '백엔드'),
    ];
    folders = [];
  }

  void removeFromFolders(String projectId) {
    for (final f in folders) {
      (f['projectIds'] as List).remove(projectId);
    }
  }

  /// [teamOwner]면 팀 소유자, [role]은 계정 등급 — 둘 중 하나면 팀 관리자(canManageCurrentTeam)다.
  Session buildSession({
    bool teamOwner = false,
    AccountRole role = AccountRole.member,
  }) {
    final client = MockClient((request) async {
      final path = request.url.path;
      final method = request.method;
      final body = request.body.isEmpty ? null : jsonDecode(request.body);
      if (method != 'GET') {
        log.add('$method $path ${jsonEncode(body)}');
      } else {
        gets.add(
          request.url.query.isEmpty ? path : '$path?${request.url.query}',
        );
      }

      if (path == '/api/projects/folders') {
        if (method == 'POST') {
          if (failCreate) {
            return http.Response(
              jsonEncode({'error': '폴더는 50개까지 만들 수 있습니다.'}),
              400,
              headers: json,
            );
          }
          final folder = {
            'id': 'f${folders.length + nextFolder++}',
            'name': (body as Map)['name'],
            'position': folders.length,
            'collapsed': false,
            'projectIds': <String>[],
          };
          folders.add(folder);
          return http.Response(jsonEncode(folder), 201, headers: json);
        }
        expect(request.url.queryParameters['teamId'], 't1');
        return http.Response(jsonEncode(folders), 200, headers: json);
      }
      if (path.startsWith('/api/project-folders/')) {
        final id = path.split('/').last;
        final folder = folders.firstWhere((f) => f['id'] == id);
        if (method == 'DELETE') {
          folders.remove(folder);
          return http.Response('{"ok":true}', 200, headers: json);
        }
        folder.addAll((body as Map).cast<String, dynamic>());
        return http.Response(jsonEncode(folder), 200, headers: json);
      }
      final folderMatch = RegExp(
        r'^/api/projects/(\w+)/folder$',
      ).firstMatch(path);
      if (folderMatch != null && method == 'PUT') {
        if (failMove) {
          return http.Response(
            jsonEncode({'error': '프로젝트를 찾을 수 없습니다.'}),
            404,
            headers: json,
          );
        }
        final projectId = folderMatch.group(1)!;
        removeFromFolders(projectId);
        final folderId = (body as Map)['folderId'] as String?;
        if (folderId != null) {
          (folders.firstWhere((f) => f['id'] == folderId)['projectIds'] as List)
              .add(projectId);
        }
        return http.Response('{"ok":true}', 200, headers: json);
      }
      if (path == '/api/projects') {
        final list = [
          ...projects,
          if (newProjectVisible) project('p9', '신규 런칭'),
        ];
        return http.Response(
          request.url.queryParameters['archived'] == '1'
              ? '[]'
              : jsonEncode(list),
          200,
          headers: json,
        );
      }
      if (path == '/api/projects/home') {
        return http.Response(
          jsonEncode({
            'stats': {'total': 0, 'done': 0, 'doing': 0, 'overdue': 0},
            'projects': [],
            'myTasks': [],
            'recentComments': [],
          }),
          200,
          headers: json,
        );
      }
      if (path == '/api/project-notifications/read') {
        return http.Response('{"unreadCount":0}', 200, headers: json);
      }
      if (path == '/api/project-notifications') {
        // 알림을 받은 뒤에야 서버가 새 공개 프로젝트를 내 목록에 넣어 준다고 가정한다
        // (사이드바는 아직 옛 목록 — 알림을 누르면 목록을 다시 읽어야 열 수 있다).
        newProjectVisible = true;
        return http.Response(
          jsonEncode({
            'unreadCount': 1,
            'items': [
              {
                'id': 'n1',
                'projectId': 'p9',
                'projectName': '신규 런칭',
                'projectColor': '#10B981',
                'taskId': null,
                'kind': 'project_created',
                'title': '신규 런칭',
                'body': 'Riley님이 공개 프로젝트를 만들었습니다: 신규 런칭',
                'createdAt': now,
                'read': false,
              },
              // 모르는 종류·빈 제목이 와도 목록이 깨지지 않는다.
              {
                'id': 'n2',
                'projectId': 'p1',
                'projectName': '잔디톡',
                'kind': 'something_new',
                'body': '새로운 알림',
                'createdAt': now,
                'read': true,
              },
            ],
          }),
          200,
          headers: json,
        );
      }
      final detail = RegExp(r'^/api/projects/(\w+)$').firstMatch(path);
      // 프로젝트 설정 > 기본 정보 저장(이름 등)과 > 삭제.
      if (detail != null && method == 'PATCH') {
        final p = projects.firstWhere((p) => p['id'] == detail.group(1));
        p.addAll((body as Map).cast<String, dynamic>());
        return http.Response(jsonEncode(p), 200, headers: json);
      }
      if (detail != null && method == 'DELETE') {
        projects.removeWhere((p) => p['id'] == detail.group(1));
        removeFromFolders(detail.group(1)!);
        return http.Response('{"ok":true}', 200, headers: json);
      }
      if (detail != null) {
        final id = detail.group(1)!;
        final all = [...projects, project('p9', '신규 런칭')];
        final match = all.where((p) => p['id'] == id);
        if (match.isNotEmpty) {
          return http.Response(jsonEncode(match.first), 200, headers: json);
        }
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
    session.currentTeam = Team(
      id: 't1',
      name: '팀',
      createdAt: DateTime.now(),
      isOwner: teamOwner,
    );
    session.accountRole = role;
    return session;
  }

  Future<void> pumpDialog(
    WidgetTester tester, {
    bool teamOwner = false,
    AccountRole role = AccountRole.member,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ProjectDialog(
          session: buildSession(teamOwner: teamOwner, role: role),
          embedInWindow: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  /// 사이드바 안에서만 찾는다(열린 프로젝트의 큰 이름 등과 섞이지 않게).
  Finder inSidebar(Finder f) => find.descendant(
    of: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Sidebar'),
    matching: f,
  );

  /// 프로젝트 화면이 열렸는지 — 프로젝트 머리의 큰 이름(22)으로 본다.
  Finder bigTitle(String name) => find.byWidgetPredicate(
    (w) => w is Text && w.data == name && w.style?.fontSize == 22,
  );

  /// 사이드바 프로젝트 줄 [name](여러 곳에 보이면 첫 줄).
  Finder projectRow(String name) => find
      .ancestor(
        of: inSidebar(find.text(name)).first,
        matching: find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_ProjectItem',
        ),
      )
      .first;

  Finder rowMenuButton(String name) => find.descendant(
    of: projectRow(name),
    matching: find.byTooltip('프로젝트 메뉴'),
  );

  Finder folderMenuButton(String folderId) => find.descendant(
    of: find.byKey(ValueKey('folder-$folderId')),
    matching: find.byTooltip('폴더 메뉴'),
  );

  /// ⋯ 버튼을 감싼 가장 가까운 Opacity 값 — 0이면 안 보이는 상태다.
  double menuOpacity(WidgetTester tester, Finder button) => tester
      .widget<Opacity>(
        find.ancestor(of: button, matching: find.byType(Opacity)).first,
      )
      .opacity;

  /// 프로젝트 [name]의 ⋯ > 폴더로 이동 > [target](폴더 이름 또는 '새 폴더').
  Future<void> moveViaMenu(
    WidgetTester tester,
    String name,
    String target,
  ) async {
    await tester.tap(rowMenuButton(name));
    await tester.pumpAndSettle();
    await tester.tap(find.text('폴더로 이동'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, target).last);
    await tester.pumpAndSettle();
  }

  /// 폴더 이름 입력 창에 [name]을 넣고 [action](추가/변경)을 누른다.
  Future<void> submitFolderName(
    WidgetTester tester,
    String name,
    String action,
  ) async {
    await tester.enterText(find.byType(TextField).last, name);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, action));
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> folder(String id, String name, List<String> ids) => {
    'id': id,
    'name': name,
    'position': 0,
    'collapsed': false,
    'projectIds': ids,
  };

  setUp(resetServer);

  testWidgets('[+] > 폴더 추가 → 폴더 머리글이 생기고, ⋯ > 폴더로 이동/빼기가 된다', (tester) async {
    await pumpDialog(tester);

    await tester.tap(find.byTooltip('추가'));
    await tester.pumpAndSettle();
    expect(find.text('폴더 추가'), findsOneWidget);
    await tester.tap(find.text('폴더 추가'));
    await tester.pumpAndSettle();

    // 이름 입력 창 — 비어 있으면 "추가"가 잠겨 있다.
    expect(find.widgetWithText(AlertDialog, '폴더 추가'), findsOneWidget);
    expect(find.text('폴더 이름'), findsOneWidget);
    final addButton = find.widgetWithText(FilledButton, '추가');
    expect(tester.widget<FilledButton>(addButton).onPressed, isNull);
    final field = tester.widget<TextField>(find.byType(TextField).last);
    expect(field.maxLength, 30);
    await tester.enterText(find.byType(TextField).last, '  마케팅  ');
    await tester.pump();
    await tester.tap(addButton);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      log,
      contains('POST /api/projects/folders {"teamId":"t1","name":"마케팅"}'),
    );
    // 폴더 머리글(이름 + 프로젝트 수 0).
    expect(inSidebar(find.text('마케팅')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('folder-f1')),
        matching: find.text('0'),
      ),
      findsOneWidget,
    );

    // 디자인 ⋯ > 폴더로 이동 > 마케팅.
    Future<void> openRowMenu(String name) async {
      final row = find.ancestor(
        of: inSidebar(find.text(name)).first,
        matching: find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_ProjectItem',
        ),
      );
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('프로젝트 메뉴')),
      );
      await tester.pumpAndSettle();
    }

    await openRowMenu('디자인');
    expect(find.text('폴더에서 빼기'), findsNothing); // 아직 폴더에 없다
    await tester.tap(find.text('폴더로 이동'));
    await tester.pumpAndSettle();
    expect(find.text('새 폴더'), findsOneWidget);
    // (메뉴는 그 줄에 붙어 그려져서 이름만으로 찾으면 폴더 머리글과 헷갈린다 — 메뉴 항목으로 찾는다.)
    await tester.tap(find.widgetWithText(MenuItemButton, '마케팅'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(log.last, 'PUT /api/projects/p2/folder {"folderId":"f1"}');

    // 폴더 아래로 들여 써서 보이고, 맨 아래 목록에서는 빠진다(한 번만 보인다).
    expect(inSidebar(find.text('디자인')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('folder-f1')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    final folderY = tester.getCenter(inSidebar(find.text('마케팅'))).dy;
    final designRect = tester.getRect(inSidebar(find.text('디자인')));
    final backendRect = tester.getRect(inSidebar(find.text('백엔드')));
    expect(designRect.center.dy, greaterThan(folderY));
    expect(backendRect.center.dy, greaterThan(designRect.center.dy));
    expect(designRect.left, greaterThan(backendRect.left)); // 들여쓰기

    // 즐겨찾기 프로젝트도 폴더에 넣으면 즐겨찾기와 폴더 양쪽에 보인다.
    await openRowMenu('잔디톡');
    await tester.tap(find.text('폴더로 이동'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '마케팅'));
    await tester.pumpAndSettle();
    expect(log.last, 'PUT /api/projects/p1/folder {"folderId":"f1"}');
    expect(inSidebar(find.text('잔디톡')), findsNWidgets(2));

    // 폴더 안 프로젝트의 ⋯ — 지금 든 폴더는 잠겨 있고, "폴더에서 빼기"가 있다.
    await openRowMenu('디자인');
    await tester.tap(find.text('폴더로 이동'));
    await tester.pumpAndSettle();
    final current = tester.widget<MenuItemButton>(
      find.widgetWithText(MenuItemButton, '마케팅').last,
    );
    expect(current.onPressed, isNull);
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.tap(find.text('폴더에서 빼기'));
    await tester.pumpAndSettle();
    expect(log.last, 'PUT /api/projects/p2/folder {"folderId":null}');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('folder-f1')),
        matching: find.text('1'),
      ),
      findsOneWidget, // 잔디톡만 남았다
    );

    // 그냥 누르면 여전히 프로젝트가 열린다.
    await tester.tap(inSidebar(find.text('디자인')));
    await tester.pumpAndSettle();
    expect(bigTitle('디자인'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('폴더 접기는 저장되고, 이름 변경·폴더 삭제는 ⋯ 메뉴로 한다', (tester) async {
    folders = [
      {
        'id': 'f1',
        'name': '마케팅',
        'position': 0,
        'collapsed': false,
        'projectIds': ['p2'],
      },
    ];
    await pumpDialog(tester);
    expect(inSidebar(find.text('디자인')), findsOneWidget);

    // 머리글을 누르면 접힌다 — 서버에 저장하고, 안의 프로젝트는 숨는다.
    await tester.tap(inSidebar(find.text('마케팅')));
    await tester.pumpAndSettle();
    expect(log.last, 'PATCH /api/project-folders/f1 {"collapsed":true}');
    expect(inSidebar(find.text('디자인')), findsNothing);
    expect(inSidebar(find.text('백엔드')), findsOneWidget);

    // 창을 다시 열어도(목록을 새로 받아도) 접힌 채다.
    await tester.pumpWidget(const SizedBox());
    await pumpDialog(tester);
    expect(inSidebar(find.text('마케팅')), findsOneWidget);
    expect(inSidebar(find.text('디자인')), findsNothing);

    // 다시 펴기.
    await tester.tap(inSidebar(find.text('마케팅')));
    await tester.pumpAndSettle();
    expect(log.last, 'PATCH /api/project-folders/f1 {"collapsed":false}');
    expect(inSidebar(find.text('디자인')), findsOneWidget);

    // ⋯ > 이름 변경.
    await tester.tap(find.byTooltip('폴더 메뉴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이름 변경'));
    await tester.pumpAndSettle();
    expect(find.text('폴더 이름 변경'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '홍보');
    await tester.tap(find.widgetWithText(FilledButton, '변경'));
    await tester.pumpAndSettle();
    expect(log.last, 'PATCH /api/project-folders/f1 {"name":"홍보"}');
    expect(inSidebar(find.text('홍보')), findsOneWidget);

    // ⋯ > 폴더 삭제 — 확인 문구를 보여주고, 안의 프로젝트는 목록에 남는다.
    await tester.tap(find.byTooltip('폴더 메뉴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('폴더 삭제'));
    await tester.pumpAndSettle();
    expect(find.text('폴더만 삭제되고 안의 프로젝트는 목록에 그대로 남습니다.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '삭제'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(log.last, startsWith('DELETE /api/project-folders/f1'));
    expect(inSidebar(find.text('홍보')), findsNothing);
    expect(inSidebar(find.text('디자인')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('프로젝트를 폴더 머리글로 끌어 넣고, 프로젝트 머리글로 끌어 뺀다', (tester) async {
    folders = [
      {
        'id': 'f1',
        'name': '마케팅',
        'position': 0,
        'collapsed': false,
        'projectIds': <String>[],
      },
    ];
    await pumpDialog(tester);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);

    Future<void> dragTo(Finder from, Finder to) async {
      final start = tester.getCenter(from);
      final end = tester.getCenter(to);
      await mouse.moveTo(start);
      await tester.pump();
      await mouse.down(start);
      await tester.pump();
      await mouse.moveTo(start + const Offset(0, 12));
      await tester.pump();
      await mouse.moveTo(end);
      await tester.pump();
      await mouse.up();
      await tester.pumpAndSettle();
    }

    // 백엔드 → 마케팅 폴더.
    await dragTo(inSidebar(find.text('백엔드')), inSidebar(find.text('마케팅')));
    expect(tester.takeException(), isNull);
    expect(log.last, 'PUT /api/projects/p3/folder {"folderId":"f1"}');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('folder-f1')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );

    // 이미 그 폴더에 든 프로젝트를 같은 폴더에 다시 놓으면 아무 요청도 없다.
    final before = log.length;
    await dragTo(inSidebar(find.text('백엔드')), inSidebar(find.text('마케팅')));
    expect(log.length, before);

    // 폴더 안의 백엔드 → '프로젝트' 머리글이면 폴더에서 빠진다.
    await dragTo(
      inSidebar(find.text('백엔드')),
      inSidebar(find.text('프로젝트')).first,
    );
    expect(log.last, 'PUT /api/projects/p3/folder {"folderId":null}');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('folder-f1')),
        matching: find.text('0'),
      ),
      findsOneWidget,
    );

    // 살짝(문턱보다 적게) 흔들린 클릭은 끌기가 아니라 프로젝트 열기다.
    final before2 = log.length;
    final at = tester.getCenter(inSidebar(find.text('디자인')));
    await mouse.moveTo(at);
    await tester.pump();
    await mouse.down(at);
    await tester.pump();
    await mouse.moveTo(at + const Offset(3, 0));
    await tester.pump();
    await mouse.up();
    await tester.pumpAndSettle();
    expect(log.length, before2);
    expect(bigTitle('디자인'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('공개 프로젝트 생성 알림을 누르면 (목록을 새로 받아) 그 프로젝트가 열린다', (tester) async {
    await pumpDialog(tester);
    expect(inSidebar(find.text('신규 런칭')), findsNothing);

    await tester.tap(find.byTooltip('알림'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Riley님이 공개 프로젝트를 만들었습니다: 신규 런칭'), findsOneWidget);
    expect(find.byIcon(Icons.rocket_launch_outlined), findsOneWidget);
    // 모르는 종류는 기본 종 아이콘, 빈 제목은 프로젝트 이름으로 보인다.
    expect(find.text('새로운 알림'), findsOneWidget);
    expect(find.text('잔디톡'), findsWidgets);

    await tester.tap(find.text('Riley님이 공개 프로젝트를 만들었습니다: 신규 런칭'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      log,
      contains('POST /api/project-notifications/read {"ids":["n1"]}'),
    );
    expect(find.text('더 이상 참여 중이 아닌 프로젝트입니다.'), findsNothing);
    expect(bigTitle('신규 런칭'), findsOneWidget);
    expect(inSidebar(find.text('신규 런칭')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    '터치 기기(안드로이드·iOS)는 프로젝트 줄·폴더 머리글의 ⋯ 가 늘 보이고, 그걸로 폴더 작업을 한다',
    (tester) async {
      folders = [
        folder('f1', '마케팅', ['p2']),
      ];
      await pumpDialog(tester);

      // 마우스를 올린 적이 없어도(터치엔 호버가 없다) 보인다.
      expect(menuOpacity(tester, folderMenuButton('f1')), 1);
      expect(menuOpacity(tester, rowMenuButton('디자인')), 1);
      expect(menuOpacity(tester, rowMenuButton('백엔드')), 1);

      // 보이는 ⋯ 로 폴더 이동과 이름 변경·폴더 삭제에 닿는다(끌기는 마우스 전용).
      await moveViaMenu(tester, '백엔드', '마케팅');
      expect(tester.takeException(), isNull);
      expect(log.last, 'PUT /api/projects/p3/folder {"folderId":"f1"}');
      await tester.tap(folderMenuButton('f1'));
      await tester.pumpAndSettle();
      expect(find.text('이름 변경'), findsOneWidget);
      expect(find.text('폴더 삭제'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    },
    variant: TargetPlatformVariant(const {
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  // 플랫폼을 덮어쓰지 않으면 실제 기기(테스트를 돌리는 데스크톱)로 본다.
  testWidgets('데스크톱은 ⋯ 가 숨어 있다가 마우스를 올린 줄에만 보인다', (tester) async {
    folders = [
      folder('f1', '마케팅', ['p2']),
    ];
    await pumpDialog(tester);
    expect(menuOpacity(tester, folderMenuButton('f1')), 0);
    expect(menuOpacity(tester, rowMenuButton('디자인')), 0);
    expect(menuOpacity(tester, rowMenuButton('백엔드')), 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(inSidebar(find.text('마케팅'))));
    await tester.pumpAndSettle();
    expect(menuOpacity(tester, folderMenuButton('f1')), 1);
    await mouse.moveTo(tester.getCenter(inSidebar(find.text('백엔드'))));
    await tester.pumpAndSettle();
    expect(menuOpacity(tester, rowMenuButton('백엔드')), 1);
    expect(menuOpacity(tester, folderMenuButton('f1')), 0);
    expect(menuOpacity(tester, rowMenuButton('디자인')), 0);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('⋯ > 폴더로 이동 > 새 폴더: 옮기기만 실패하면 그렇게 알리고, 새 폴더는 보인다', (
    tester,
  ) async {
    await pumpDialog(tester);

    failMove = true;
    await moveViaMenu(tester, '디자인', '새 폴더');
    await submitFolderName(tester, '기획', '추가');
    expect(tester.takeException(), isNull);
    expect(log, [
      'POST /api/projects/folders {"teamId":"t1","name":"기획"}',
      'PUT /api/projects/p2/folder {"folderId":"f1"}',
    ]);
    expect(
      find.text('폴더는 만들었지만 프로젝트를 옮기지 못했습니다: 프로젝트를 찾을 수 없습니다.'),
      findsOneWidget,
    );
    expect(find.textContaining('폴더를 만들지 못했습니다'), findsNothing);
    // 만든 폴더는 바로 보이고(비어 있음), 디자인은 폴더 밖 목록에 그대로 있다.
    expect(inSidebar(find.text('기획')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('folder-f1')),
        matching: find.text('0'),
      ),
      findsOneWidget,
    );
    expect(inSidebar(find.text('디자인')), findsOneWidget);
    await tester.pump(const Duration(seconds: 3)); // 토스트가 사라지게

    // 폴더 만들기부터 실패하면 — 못 만들었다고 알리고, 옮기기는 시도하지 않는다.
    failCreate = true;
    log.clear();
    await moveViaMenu(tester, '백엔드', '새 폴더');
    await submitFolderName(tester, '운영', '추가');
    expect(tester.takeException(), isNull);
    expect(log, ['POST /api/projects/folders {"teamId":"t1","name":"운영"}']);
    expect(find.text('폴더를 만들지 못했습니다: 폴더는 50개까지 만들 수 있습니다.'), findsOneWidget);
    expect(inSidebar(find.text('운영')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('폴더 작업은 소켓 알림 없이 폴더만 다시 읽어 사이드바에 보이고, 접기는 PATCH 한 번뿐이다', (
    tester,
  ) async {
    // 이 테스트에는 소켓이 없다 — 서버가 폴더 변경에 project:changed를 보내지 않아도
    // 사이드바가 바뀌어야 하고, 열린 화면(홈)은 다시 불러오지 않아야 한다.
    folders = [
      folder('f1', '마케팅', ['p2']),
    ];
    await pumpDialog(tester);
    expect(gets.any((g) => g.startsWith('/api/projects/home')), isTrue);
    const foldersOnly = ['/api/projects/folders?teamId=t1'];
    void mark() {
      log.clear();
      gets.clear();
    }

    // 접기/펴기 — 그 자리에서 바뀌고, 요청은 PATCH 하나(다시 읽기 없음).
    mark();
    await tester.tap(inSidebar(find.text('마케팅')));
    await tester.pumpAndSettle();
    expect(log, ['PATCH /api/project-folders/f1 {"collapsed":true}']);
    expect(gets, isEmpty);
    expect(inSidebar(find.text('디자인')), findsNothing);
    mark();
    await tester.tap(inSidebar(find.text('마케팅')));
    await tester.pumpAndSettle();
    expect(log, ['PATCH /api/project-folders/f1 {"collapsed":false}']);
    expect(gets, isEmpty);
    expect(inSidebar(find.text('디자인')), findsOneWidget);

    // [+] > 폴더 추가.
    mark();
    await tester.tap(find.byTooltip('추가'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('폴더 추가'));
    await tester.pumpAndSettle();
    await submitFolderName(tester, '기획', '추가');
    expect(gets, foldersOnly);
    expect(inSidebar(find.text('기획')), findsOneWidget);

    // ⋯ > 폴더로 이동.
    mark();
    await moveViaMenu(tester, '백엔드', '기획');
    expect(log, ['PUT /api/projects/p3/folder {"folderId":"f2"}']);
    expect(gets, foldersOnly);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('folder-f2')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );

    // ⋯ > 이름 변경.
    mark();
    await tester.tap(folderMenuButton('f1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이름 변경'));
    await tester.pumpAndSettle();
    await submitFolderName(tester, '홍보', '변경');
    expect(gets, foldersOnly);
    expect(inSidebar(find.text('홍보')), findsOneWidget);
    expect(inSidebar(find.text('마케팅')), findsNothing);

    // ⋯ > 폴더 삭제 — 안의 백엔드는 폴더 밖 목록으로 돌아온다.
    mark();
    await tester.tap(folderMenuButton('f2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('폴더 삭제'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '삭제'));
    await tester.pumpAndSettle();
    expect(gets, foldersOnly);
    expect(inSidebar(find.text('기획')), findsNothing);
    expect(inSidebar(find.text('백엔드')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  // ───────────── 프로젝트 ⋯ > 프로젝트 설정 ─────────────

  Finder inDialog(Finder f) =>
      find.descendant(of: find.byType(Dialog), matching: f);
  final settingsItem = find.widgetWithText(MenuItemButton, '프로젝트 설정');

  /// 데스크톱은 줄에 마우스를 올려 ⋯ 가 나타난 뒤 마우스로 누르고, 터치는 늘 보이는 ⋯ 를 탭한다.
  Future<void> openRowMenuAs(
    WidgetTester tester,
    String name, {
    required bool touch,
  }) async {
    final button = rowMenuButton(name);
    if (touch) {
      expect(menuOpacity(tester, button), 1);
      await tester.tap(button);
    } else {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(projectRow(name)));
      await tester.pumpAndSettle();
      expect(menuOpacity(tester, button), 1);
      await mouse.down(tester.getCenter(button));
      await mouse.up();
      await mouse.removePointer();
    }
    await tester.pumpAndSettle();
  }

  /// 열린 ⋯ 메뉴를 메뉴 바깥(상단 바의 '프로젝트' 글자 — 누를 거리가 없는 곳)을 눌러 닫는다.
  Future<void> closeMenu(WidgetTester tester) async {
    await tester.tapAt(const Offset(60, 28));
    await tester.pumpAndSettle();
    expect(find.text('폴더로 이동'), findsNothing);
  }

  for (final touch in [false, true]) {
    final where = touch ? '터치' : '데스크톱';
    final TestVariant<Object?> variant = touch
        ? TargetPlatformVariant.only(TargetPlatform.android)
        : const DefaultTestVariant();

    testWidgets('$where: ⋯ > 프로젝트 설정은 프로젝트 담당자와 팀 관리자에게만 보인다(폴더 안 줄 포함)', (
      tester,
    ) async {
      folders = [
        folder('f1', '마케팅', ['p2']),
      ];
      projects[1]['myRole'] = 'owner'; // 디자인(마케팅 폴더 안) — 내가 담당자

      Future<bool> hasSettings(String name) async {
        await openRowMenuAs(tester, name, touch: touch);
        expect(find.text('폴더로 이동'), findsOneWidget); // 메뉴는 열렸다
        final found = settingsItem.evaluate().isNotEmpty;
        await closeMenu(tester);
        return found;
      }

      // 팀 관리자가 아닌 정회원 — 내가 담당자인 프로젝트에만.
      await pumpDialog(tester);
      expect(await hasSettings('디자인'), isTrue);
      expect(await hasSettings('백엔드'), isFalse);
      expect(await hasSettings('잔디톡'), isFalse); // 즐겨찾기 줄

      // 팀 소유자 — 모든 프로젝트에.
      await tester.pumpWidget(const SizedBox());
      await pumpDialog(tester, teamOwner: true);
      expect(await hasSettings('백엔드'), isTrue);
      expect(await hasSettings('잔디톡'), isTrue);
      expect(await hasSettings('디자인'), isTrue);

      // 계정 등급 관리자 — 팀 소유자가 아니어도 모든 프로젝트에.
      await tester.pumpWidget(const SizedBox());
      await pumpDialog(tester, role: AccountRole.admin);
      expect(await hasSettings('백엔드'), isTrue);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    }, variant: variant);

    testWidgets('$where: ⋯ > 프로젝트 설정 — 같은 설정 창이 열리고, 닫으면 목록·열린 화면을 다시 읽는다', (
      tester,
    ) async {
      folders = [
        folder('f1', '마케팅', ['p2']),
      ];
      await pumpDialog(tester, teamOwner: true);

      Future<void> openSettings(String name) async {
        await openRowMenuAs(tester, name, touch: touch);
        await tester.tap(settingsItem);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // 프로젝트 화면 오른쪽 위 톱니와 같은 창 — 제목, 왼쪽 메뉴, 기본 정보에 그 프로젝트 이름.
        expect(inDialog(find.text('프로젝트 설정')), findsOneWidget);
        expect(inDialog(find.text('기본 정보')), findsOneWidget);
        final field = tester.widget<TextField>(
          inDialog(find.byType(TextField)).first,
        );
        expect(field.controller?.text, name);
      }

      Future<void> closeSettings() async {
        await tester.tap(inDialog(find.byIcon(Icons.close)));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(tester.takeException(), isNull);
      }

      Future<void> rename(String to) async {
        await tester.enterText(inDialog(find.byType(TextField)).first, to);
        await tester.tap(inDialog(find.widgetWithText(FilledButton, '저장')));
        await tester.pumpAndSettle();
      }

      Future<void> deleteVia(String name, String id) async {
        await openSettings(name);
        await tester.tap(inDialog(find.text('삭제')));
        await tester.pumpAndSettle();
        await tester.enterText(
          inDialog(find.widgetWithText(TextField, '프로젝트 이름 입력')),
          name,
        );
        await tester.pump();
        final button = inDialog(
          find.widgetWithText(FilledButton, '프로젝트 영구 삭제'),
        );
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(Dialog), findsNothing);
        expect(log.last, 'DELETE /api/projects/$id null');
      }

      bool listReloaded() => gets.any((g) => g.startsWith('/api/projects?'));

      // 1) 폴더 안의 (열려 있지 않은) 프로젝트 — 설정만 열고 닫으면 보던 화면(홈) 그대로다.
      await openSettings('디자인');
      await closeSettings();
      expect(bigTitle('디자인'), findsNothing); // 프로젝트로 옮겨 가지 않는다
      expect(find.byType(ProjectHomeView), findsOneWidget);
      expect(inSidebar(find.text('디자인')), findsOneWidget);

      // 2) 이름을 바꾸고 (창의 X로) 닫으면 사이드바 목록과 보고 있는 화면(홈)을 새로 읽는다.
      // (X로 닫으면 설정 창이 "바뀜" 결과를 돌려주지 않아도 목록이 새로 그려져야 한다.)
      await openSettings('디자인');
      await rename('디자인 2팀');
      expect(log.last, startsWith('PATCH /api/projects/p2 '));
      gets.clear();
      await closeSettings();
      expect(listReloaded(), isTrue);
      expect(gets.any((g) => g.startsWith('/api/projects/home')), isTrue);
      expect(inSidebar(find.text('디자인 2팀')), findsOneWidget);
      expect(inSidebar(find.text('디자인')), findsNothing);

      // 3) 열려 있는 프로젝트 — 안 바꾸고 닫아도(필드·상태만 고치면 "바뀜"이 안 온다) 그 화면을
      // 다시 읽는다(프로젝트 화면의 톱니와 같다).
      await tester.tap(inSidebar(find.text('백엔드')));
      await tester.pumpAndSettle();
      expect(bigTitle('백엔드'), findsOneWidget);
      await openSettings('백엔드');
      gets.clear();
      await closeSettings();
      expect(gets, contains('/api/projects/p3'));
      expect(bigTitle('백엔드'), findsOneWidget);

      // 4) 열려 있는 프로젝트의 이름을 바꾸면 머리의 큰 이름과 사이드바가 바로 바뀐다.
      await openSettings('백엔드');
      await rename('백엔드 API');
      await closeSettings();
      expect(bigTitle('백엔드 API'), findsOneWidget);
      expect(inSidebar(find.text('백엔드 API')), findsOneWidget);

      // 5) 열려 있지 않은 프로젝트를 삭제 — 보던 프로젝트는 그대로, 목록에서만 빠진다.
      await deleteVia('디자인 2팀', 'p2');
      expect(bigTitle('백엔드 API'), findsOneWidget);
      expect(inSidebar(find.text('디자인 2팀')), findsNothing);

      // 6) 열려 있는 프로젝트를 삭제 — 홈으로 돌아가고 목록에서도 빠진다.
      await deleteVia('백엔드 API', 'p3');
      expect(bigTitle('백엔드 API'), findsNothing);
      expect(find.byType(ProjectHomeView), findsOneWidget);
      expect(inSidebar(find.text('백엔드 API')), findsNothing);
      expect(inSidebar(find.text('잔디톡')), findsWidgets);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    }, variant: variant);
  }
}
