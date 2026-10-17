import 'dart:convert';

import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/calendar/calendar_screen.dart';
import 'package:client/screens/desktop_home_screen.dart';
import 'package:client/screens/favorites_screen.dart';
import 'package:client/screens/files_screen.dart';
import 'package:client/screens/links_screen.dart';
import 'package:client/screens/message_thread_screen.dart';
import 'package:client/screens/my_posts_screen.dart';
import 'package:client/screens/polls_screen.dart';
import 'package:client/screens/room_list_screen.dart';
import 'package:client/screens/search_screen.dart';
import 'package:client/screens/todo_editor_dialog.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/services/typing_gate.dart';
import 'package:client/widgets/app_menu_button.dart';
import 'package:client/widgets/chat_panel.dart';
import 'package:client/widgets/menu_entries.dart';
import 'package:client/widgets/notifications_panel.dart';
import 'package:client/widgets/reminders_panel.dart';
import 'package:client/widgets/side_panels.dart';
import 'package:client/widgets/team_members_panel.dart';
import 'package:client/widgets/todo_widgets.dart' show TodoViewMode;
import 'package:client/widgets/todos_panel.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers/fake_todo_api.dart' show todoJson;

/// 메뉴 재구성(생성 · 리스트 · 툴 세 묶음, 등록 목록으로 항목을 더하는 구조)과 오른쪽 패널 인프라
/// (패널 하나만 열리고 서로 교체, 등록 목록으로 패널을 더하는 구조, 모바일은 전체 화면), 그리고 캘린더·프로젝트
/// 버튼이 상단 툴바에서 메뉴 "툴" 묶음으로 옮겨 간 것.

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

http.Response _json(Object? body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

final _requests = <http.Request>[];

/// [todos]는 할 일 목록(`GET /api/todos`)이 돌려줄 DTO들 — 한 건 조회(`GET /api/todos/:id`)도 이 중에서 준다.
Session _session({
  AccountRole role = AccountRole.member,
  List<Room>? rooms,
  List<Map<String, dynamic>> todos = const [],
}) {
  _requests.clear();
  final client = MockClient((request) async {
    _requests.add(request);
    if (request.url.path == '/api/favorites') {
      return _json({'items': <Object>[], 'hasMore': false});
    }
    if (request.url.path == '/api/polls') {
      return _json({'items': <Object>[], 'hasMore': false, 'total': 0});
    }
    if (request.url.path == '/api/my-posts') {
      return _json({'items': <Object>[], 'hasMore': false});
    }
    if (request.url.path == '/api/todos') {
      return _json({'items': todos, 'hasMore': false, 'total': todos.length});
    }
    if (request.url.path.startsWith('/api/todos/')) {
      final id = request.url.pathSegments.last;
      final todo = todos.where((t) => t['id'] == id).firstOrNull;
      if (todo != null) return _json(todo);
    }
    return _json(<Object>[]);
  });
  final session = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: client,
  );
  session.userId = 'me';
  session.name = '나';
  session.accountRole = role;
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.addAll(rooms ?? const []);
  return session;
}

Room _topic(String id, String name) => Room.fromJson({
  'id': id,
  'teamId': 't1',
  'type': 'topic',
  'name': name,
  'members': [
    {'id': 'me', 'username': 'me', 'name': '나', 'role': 'member'},
  ],
  'createdAt': 1000,
});

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpMenu(WidgetTester tester, Session session, Size size) async {
  _size(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(actions: [AppMenuButton(session: session)]),
      ),
    ),
  );
  await tester.tap(find.byTooltip('메뉴'));
  await tester.pumpAndSettle();
}

/// 타일 라벨을 화면의 위→아래, 왼→오른쪽 순서로 정렬한 것.
List<String> _readingOrder(WidgetTester tester, List<String> labels) {
  final sorted = [...labels];
  sorted.sort((a, b) {
    final pa = tester.getTopLeft(find.text(a));
    final pb = tester.getTopLeft(find.text(b));
    final byRow = pa.dy.compareTo(pb.dy);
    return byRow != 0 ? byRow : pa.dx.compareTo(pb.dx);
  });
  return sorted;
}

Future<void> _openMenuTile(WidgetTester tester, String key) async {
  await tester.tap(find.byTooltip('메뉴'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('menu-$key')));
  await tester.pumpAndSettle();
}

Future<void> _pumpDesktop(WidgetTester tester, Session session) async {
  _size(tester, const Size(1400, 1000));
  await tester.pumpWidget(
    MaterialApp(home: DesktopHomeScreen(session: session)),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Future<void> _finish(WidgetTester tester) async {
  TypingGate.instance.reset();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  group('메뉴 — 생성 · 리스트 · 툴', () {
    testWidgets('세 묶음 제목이 이 순서로 있고, 항목이 권장 순서대로 놓인다', (tester) async {
      await _pumpMenu(tester, _session(), const Size(1280, 900));

      expect(_readingOrder(tester, ['생성', '리스트', '툴']), ['생성', '리스트', '툴']);
      for (final title in ['생성', '리스트', '툴']) {
        expect(find.text(title), findsOneWidget);
      }
      // 묶음 안의 순서(order): 생성 10·30·40, 리스트 10·20·30·40·50·70(문의함), 툴 10·20.
      final create = ['메시지 예약', '투표', '리마인더'];
      final list = ['파일', '즐겨찾기', '북마크', '링크', '내가 쓴 글', '문의함'];
      final tools = ['캘린더', '프로젝트'];
      expect(_readingOrder(tester, [...create].reversed.toList()), create);
      expect(_readingOrder(tester, [...list].reversed.toList()), list);
      expect(_readingOrder(tester, [...tools].reversed.toList()), tools);

      // 묶음이 아래로 이어진다 — 생성 < 리스트 < 툴.
      double y(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(y('리마인더'), lessThan(y('리스트')));
      expect(y('링크'), lessThan(y('툴')));
      // 문의함은 리스트 묶음에 있다(툴 제목보다 위).
      expect(y('문의함'), lessThan(y('툴')));

      // 기존 키는 그대로다.
      for (final key in [
        'schedule',
        'poll',
        'reminder',
        'files',
        'favorites',
        'bookmarks',
        'links',
        'myposts',
        'calendar',
        'project',
        'inquiries',
      ]) {
        expect(find.byKey(ValueKey('menu-$key')), findsOneWidget, reason: key);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('프로젝트를 쓸 수 없는 계정(guest)에게는 프로젝트 타일이 숨는다', (tester) async {
      await _pumpMenu(
        tester,
        _session(role: AccountRole.guest),
        const Size(1280, 900),
      );
      expect(find.text('캘린더'), findsOneWidget);
      expect(find.text('문의함'), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-project')), findsNothing);
      expect(find.text('프로젝트'), findsNothing);
    });

    testWidgets('폭 360 — 세 묶음 타일이 모두 보이고 넘치지 않는다', (tester) async {
      await _pumpMenu(tester, _session(), const Size(360, 640));
      expect(tester.takeException(), isNull);
      for (final label in [
        '메시지 예약',
        '투표',
        '파일',
        '즐겨찾기',
        '링크',
        '내가 쓴 글',
        '캘린더',
        '프로젝트',
        '문의함',
      ]) {
        final right = tester.getTopRight(find.text(label)).dx;
        expect(right, lessThanOrEqualTo(360), reason: label);
      }
    });

    group('등록 목록 — 항목 하나를 더하면 보인다', () {
      final added = <MenuEntry>[];
      tearDown(() {
        menuEntries.removeWhere(added.contains);
        added.clear();
      });

      MenuEntry add(MenuEntry e) {
        menuEntries.add(e);
        added.add(e);
        return e;
      }

      testWidgets(
        'order 사이에 끼워 넣고, 누르면 onOpen이 (메뉴 버튼 context, session)으로 불린다',
        (tester) async {
          Session? gotSession;
          BuildContext? gotContext;
          add(
            MenuEntry(
              key: 'zz-extra',
              section: MenuSection.create,
              label: '임시 항목',
              icon: const Icon(Icons.checklist_rounded),
              color: const Color(0xFF2B8A3E),
              order: 15,
              onOpen: (context, session) {
                gotContext = context;
                gotSession = session;
              },
            ),
          );
          final session = _session();
          await _pumpMenu(tester, session, const Size(1280, 900));

          // 생성: 메시지 예약 10 → 임시 항목 15 → 할 일 20 → 투표 30.
          expect(_readingOrder(tester, ['투표', '할 일', '임시 항목', '메시지 예약']), [
            '메시지 예약',
            '임시 항목',
            '할 일',
            '투표',
          ]);
          await tester.tap(find.byKey(const ValueKey('menu-zz-extra')));
          await tester.pumpAndSettle();
          expect(gotSession, same(session));
          expect(gotContext, isNotNull);
          // 팝업이 먼저 닫혔다.
          expect(find.text('리스트'), findsNothing);
        },
      );

      testWidgets(
        'visible이 false인 항목은 숨고, 항목이 없는 묶음은 제목도 안 보이며 새 항목은 order순으로 선다',
        (tester) async {
          final entries = menuEntries.toList();
          menuEntries.clear();
          addTearDown(() => menuEntries.addAll(entries));
          add(
            MenuEntry(
              key: 'zz-b',
              section: MenuSection.list,
              label: '둘째',
              icon: const Icon(Icons.star),
              color: Colors.blue,
              order: 60,
              onOpen: (_, _) {},
            ),
          );
          add(
            MenuEntry(
              key: 'zz-a',
              section: MenuSection.list,
              label: '첫째',
              icon: const Icon(Icons.star),
              color: Colors.red,
              order: 50,
              onOpen: (_, _) {},
            ),
          );
          add(
            MenuEntry(
              key: 'zz-hidden',
              section: MenuSection.tools,
              label: '숨김',
              icon: const Icon(Icons.star),
              color: Colors.red,
              order: 10,
              visible: (_) => false,
              onOpen: (_, _) {},
            ),
          );
          await _pumpMenu(tester, _session(), const Size(1280, 900));
          expect(_readingOrder(tester, ['둘째', '첫째']), ['첫째', '둘째']);
          expect(find.text('숨김'), findsNothing);
          expect(find.text('리스트'), findsOneWidget);
          // 보이는 항목이 없는 생성·툴 묶음은 제목도 없다.
          expect(find.text('생성'), findsNothing);
          expect(find.text('툴'), findsNothing);
        },
      );

      test('menuEntriesFor — 같은 order는 등록한 순서대로', () {
        add(
          MenuEntry(
            key: 'zz-1',
            section: MenuSection.tools,
            label: 'A',
            icon: const SizedBox(),
            color: Colors.red,
            order: 15,
            onOpen: (_, _) {},
          ),
        );
        add(
          MenuEntry(
            key: 'zz-2',
            section: MenuSection.tools,
            label: 'B',
            icon: const SizedBox(),
            color: Colors.red,
            order: 15,
            onOpen: (_, _) {},
          ),
        );
        final keys = menuEntriesFor(
          MenuSection.tools,
          _session(),
        ).map((e) => e.key).toList();
        // 그룹웨어도 order 15라 먼저 등록된 그것이 앞이다.
        expect(keys, [
          'calendar',
          'groupware',
          'zz-1',
          'zz-2',
          'drive',
          'wiki',
          'mail',
          'project',
        ]);
      });
    });
  });

  group('패널 등록 구조', () {
    final added = <SidePanelSpec>[];
    tearDown(() {
      sidePanelSpecs.removeWhere(added.contains);
      added.clear();
    });

    test(
      '기본으로 검색·파일·링크·앨범·할 일·메시지 예약·리마인더·문의함·즐겨찾기·투표·내가 쓴 글·북마크·알림 센터·멤버·공지가 등록돼 있다',
      () {
        expect(sidePanelSpecs.map((s) => s.key), [
          'search',
          'files',
          'links',
          'albums',
          'todos',
          'scheduled',
          'reminders',
          'inquiries',
          'favorites',
          'polls',
          'myposts',
          'bookmarks',
          'notifications',
          'members',
          'announcements',
        ]);
        expect(sidePanelSpecFor('nope'), isNull);
      },
    );

    testWidgets('홈 화면 밖(모바일)에서는 같은 builder가 전체 화면 라우트로 열리고 앱바 제목이 붙는다', (
      tester,
    ) async {
      _size(tester, const Size(360, 780));
      final spec = SidePanelSpec(
        key: 'zz-todos',
        title: '할 일 목록',
        builder: (context, session, onClose) => Center(
          child: TextButton(onPressed: onClose, child: const Text('본문 위젯')),
        ),
      );
      sidePanelSpecs.add(spec);
      added.add(spec);
      final session = _session();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => openSidePanel(context, session, 'zz-todos'),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      expect(find.text('본문 위젯'), findsOneWidget);
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('할 일 목록')),
        findsOneWidget,
      );
      // builder의 onClose는 이 화면을 닫는다.
      await tester.tap(find.text('본문 위젯'));
      await tester.pumpAndSettle();
      expect(find.text('본문 위젯'), findsNothing);
      expect(find.text('열기'), findsOneWidget);
    });

    testWidgets('모바일: 패널이 자기 머리글을 그리는 spec(ownHeader)은 앱바 없이 열린다', (
      tester,
    ) async {
      _size(tester, const Size(360, 780));
      final session = _session();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => openSidePanel(context, session, 'links'),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      expect(find.byType(LinksScreen), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      await _finish(tester);
    });

    testWidgets(
      'PC: 등록만 하면 메뉴 항목의 onOpen 한 줄로 오른쪽 패널로 열리고, 머리글(제목 + 닫기)이 붙는다',
      (tester) async {
        final spec = SidePanelSpec(
          key: 'zz-todos',
          title: '할 일 목록',
          builder: (context, session, onClose) =>
              const Center(child: Text('본문 위젯')),
        );
        sidePanelSpecs.add(spec);
        added.add(spec);
        final entry = MenuEntry(
          key: 'zz-todos',
          section: MenuSection.create,
          label: '할 일',
          icon: const Icon(Icons.checklist_rounded),
          color: const Color(0xFF2B8A3E),
          order: 20,
          onOpen: (context, session) =>
              openSidePanel(context, session, 'zz-todos'),
        );
        menuEntries.add(entry);
        addTearDown(() => menuEntries.remove(entry));

        final session = _session();
        await _pumpDesktop(tester, session);
        await _openMenuTile(tester, 'zz-todos');
        expect(find.text('본문 위젯'), findsOneWidget);
        expect(find.text('할 일 목록'), findsOneWidget); // 패널 머리글
        // 오른쪽에 붙는다(폭 420).
        expect(tester.getTopRight(find.text('본문 위젯')).dx, greaterThan(900));

        // 머리글의 닫기(X).
        await tester.tap(find.byTooltip('닫기'));
        await tester.pumpAndSettle();
        expect(find.text('본문 위젯'), findsNothing);
        await _finish(tester);
      },
    );
  });

  group('PC 홈 화면', () {
    testWidgets('메뉴 생성의 리마인더는 오른쪽 리마인더 패널을 열고, 다시 누르면 닫는다', (tester) async {
      final session = _session();
      await _pumpDesktop(tester, session);
      await _openMenuTile(tester, 'reminder');
      expect(find.byType(RemindersPanel), findsOneWidget);
      expect(find.byKey(const ValueKey('reminder-create')), findsOneWidget);
      expect(find.byKey(const ValueKey('reminder-empty')), findsOneWidget);
      await _openMenuTile(tester, 'reminder');
      expect(find.byType(RemindersPanel), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('대화창 분할은 패널을 여는 동안만 가려졌다가 닫으면 돌아오고, 다른 팀으로 옮겨도 남는다', (
      tester,
    ) async {
      final session = _session(
        rooms: [_topic('r1', '공지방'), _topic('r2', '개발방')],
      );
      session.teams.add(Team(id: 't2', name: '개발팀', createdAt: DateTime(2026)));
      await _pumpDesktop(tester, session);
      session.requestOpenRoom(session.roomById('r1')!);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('topic-row-r2')),
          matching: find.text('개발방'),
        ),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('대화창 분할하기'));
      await tester.pumpAndSettle();
      final split = find.byKey(const ValueKey('split-r2'));
      expect(split, findsOneWidget);

      // 알림 센터 — 분할 자리를 쓰다가 닫으면 분할이 돌아온다.
      await tester.tap(find.byTooltip('알림 센터'));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationsPanel), findsOneWidget);
      expect(split, findsNothing);
      await tester.tap(find.byTooltip('알림 센터'));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationsPanel), findsNothing);
      expect(split, findsOneWidget);

      // 메뉴로 여는 패널도 같다.
      await _openMenuTile(tester, 'favorites');
      expect(find.byType(FavoritesScreen), findsOneWidget);
      expect(split, findsNothing);
      await _openMenuTile(tester, 'favorites');
      expect(split, findsOneWidget);

      // 다른 팀으로 옮기면 메인은 비지만 분할한 방은 남고, 어느 팀 방인지 헤더에 적힌다.
      session.enterTeam(session.teams.last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('main-r1')), findsNothing);
      expect(split, findsOneWidget);
      expect(find.text('영업팀'), findsWidgets);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('상단 툴바에는 캘린더·프로젝트 버튼이 없고 메뉴의 "툴"에 있다', (tester) async {
      final session = _session();
      await _pumpDesktop(tester, session);
      expect(find.byTooltip('캘린더'), findsNothing);
      expect(find.byTooltip('프로젝트'), findsNothing);
      expect(find.byKey(const ValueKey('open-calendar')), findsNothing);
      // 남아 있는 툴바 버튼.
      expect(find.byTooltip('팀 멤버'), findsOneWidget);
      expect(find.byTooltip('검색'), findsOneWidget);
      expect(find.byTooltip('메뉴'), findsOneWidget);

      await tester.tap(find.byTooltip('메뉴'));
      await tester.pumpAndSettle();
      expect(find.text('툴'), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-calendar')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-project')), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('프로젝트를 쓸 수 없는 계정의 메뉴에는 프로젝트 타일이 없다', (tester) async {
      final session = _session(role: AccountRole.guest);
      await _pumpDesktop(tester, session);
      await tester.tap(find.byTooltip('메뉴'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('menu-calendar')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-project')), findsNothing);
      await _finish(tester);
    });

    testWidgets('메뉴 타일마다 오른쪽 패널이 열리고, 다른 패널을 열면 교체되며, 같은 타일을 다시 누르면 닫힌다', (
      tester,
    ) async {
      final session = _session(rooms: [_topic('r1', '공지방')]);
      await _pumpDesktop(tester, session);
      expect(find.byType(FilesScreen), findsNothing);

      await _openMenuTile(tester, 'files');
      expect(find.byType(FilesScreen), findsOneWidget);

      // 링크로 교체 — 파일 패널은 사라진다.
      await _openMenuTile(tester, 'links');
      expect(find.byType(LinksScreen), findsOneWidget);
      expect(find.byType(FilesScreen), findsNothing);

      // 즐겨찾기로 교체.
      await _openMenuTile(tester, 'favorites');
      expect(find.byType(FavoritesScreen), findsOneWidget);
      expect(find.byType(LinksScreen), findsNothing);
      expect(find.byKey(const ValueKey('panel-search-field')), findsOneWidget);

      // 상단 버튼으로 연 패널(검색 · 멤버)과도 서로 교체된다.
      await tester.tap(find.byTooltip('검색'));
      await tester.pumpAndSettle();
      expect(find.byType(SearchScreen), findsOneWidget);
      expect(find.byType(FavoritesScreen), findsNothing);
      await tester.tap(find.byTooltip('팀 멤버'));
      await tester.pumpAndSettle();
      expect(find.byType(TeamMembersPanel), findsOneWidget);
      expect(find.byType(SearchScreen), findsNothing);

      // 같은 버튼을 다시 누르면 닫힌다.
      await tester.tap(find.byTooltip('팀 멤버'));
      await tester.pumpAndSettle();
      expect(find.byType(TeamMembersPanel), findsNothing);

      // 메뉴 타일도 토글이다.
      await _openMenuTile(tester, 'favorites');
      expect(find.byType(FavoritesScreen), findsOneWidget);
      await _openMenuTile(tester, 'favorites');
      expect(find.byType(FavoritesScreen), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('메뉴의 "투표"는 만들기 창이 아니라 투표 목록 패널을 열고, "내가 쓴 글"도 패널로 열린다', (
      tester,
    ) async {
      final session = _session(rooms: [_topic('r1', '공지방')]);
      await _pumpDesktop(tester, session);

      await _openMenuTile(tester, 'poll');
      expect(find.byType(PollsScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('polls-create')), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      final polls = _requests.where((r) => r.url.path == '/api/polls');
      expect(polls, isNotEmpty);
      expect(polls.last.url.queryParameters['teamId'], 't1');

      // 내가 쓴 글로 교체 — 투표 패널은 사라진다. 같은 타일을 다시 누르면 닫힌다.
      await _openMenuTile(tester, 'myposts');
      expect(find.byType(MyPostsScreen), findsOneWidget);
      expect(find.byType(PollsScreen), findsNothing);
      expect(_requests.where((r) => r.url.path == '/api/my-posts'), isNotEmpty);
      await _openMenuTile(tester, 'myposts');
      expect(find.byType(MyPostsScreen), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('알림 센터 패널도 같은 구조로 열리고 교체된다', (tester) async {
      final session = _session();
      await _pumpDesktop(tester, session);
      await tester.tap(find.byTooltip('알림 센터'));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationsPanel), findsOneWidget);

      await _openMenuTile(tester, 'files');
      expect(find.byType(NotificationsPanel), findsNothing);
      expect(find.byType(FilesScreen), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('파일 패널은 지금 보고 있는 방으로 걸러서 시작한다', (tester) async {
      final session = _session(rooms: [_topic('r1', '공지방')]);
      await _pumpDesktop(tester, session);
      session.requestOpenRoom(session.roomById('r1')!);
      await tester.pumpAndSettle();

      await _openMenuTile(tester, 'files');
      final attach = _requests.where((r) => r.url.path == '/api/attachments');
      expect(attach, isNotEmpty);
      expect(attach.last.url.queryParameters['roomId'], 'r1');
      await _finish(tester);
    });

    testWidgets('캘린더 타일은 사이드바+채팅 자리를 캘린더로 바꾸고 한 번 더 누르면 돌아온다', (tester) async {
      final session = _session(rooms: [_topic('r1', '공지방')]);
      await _pumpDesktop(tester, session);
      expect(find.byType(CalendarScreen), findsNothing);
      expect(find.text('공지방'), findsWidgets); // 사이드바

      await _openMenuTile(tester, 'calendar');
      expect(find.byType(CalendarScreen), findsOneWidget);
      expect(find.text('왼쪽에서 대화방을 선택하세요.'), findsNothing);

      await _openMenuTile(tester, 'calendar');
      expect(find.byType(CalendarScreen), findsNothing);
      expect(find.text('공지방'), findsWidgets);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('캘린더와 오른쪽 패널은 함께 열 수 있다(캘린더는 가운데 자리, 패널은 오른쪽)', (tester) async {
      final session = _session();
      await _pumpDesktop(tester, session);
      await _openMenuTile(tester, 'calendar');
      await _openMenuTile(tester, 'favorites');
      expect(find.byType(CalendarScreen), findsOneWidget);
      expect(find.byType(FavoritesScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });
  });

  // 할 일 패널 안 수정 화면(상세 ••• → 할 일 수정)은 홈 화면이 패널을 밖에서 닫거나 바꾸기 전에(같은 메뉴 타일·다른
  // 패널·댓글·대화창 분할) 쓰던 내용을 묻는다 — 패널 자신의 ✕는 그 화면이 이미 물으니 한 번만. 생성은 투표 만들기처럼 패널
  // 밖 대화상자라 여기에 들지 않는다(todo_panel_test.dart).
  group('PC 홈 화면 — 할 일 패널 안에서 쓰던 할 일', () {
    /// 공지방(r1)의 고칠 할 일 한 건이 있는 세션.
    Session todoSession({List<Room>? rooms}) => _session(
      rooms: rooms ?? [_topic('r1', '공지방')],
      todos: [
        todoJson(
          id: 'a',
          roomId: 'r1',
          roomName: '공지방',
          title: '고칠 할 일',
          assignees: ['me'],
        ),
      ],
    );

    /// 할 일 패널을 열고([openPanel]) 그 할 일의 상세 → ••• → 할 일 수정 — 패널 안 수정 화면.
    Future<void> openTodoEditor(
      WidgetTester tester, {
      bool openPanel = true,
    }) async {
      if (openPanel) await _openMenuTile(tester, 'todos');
      expect(find.byType(TodosPanel), findsOneWidget);
      await tester.tap(find.text('고칠 할 일'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('todo-detail-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('todo-menu-edit')));
      await tester.pumpAndSettle();
      expect(find.byType(TodoEditor), findsOneWidget);
      expect(
        tester.widget<TodoEditor>(find.byType(TodoEditor)).mode,
        TodoViewMode.panel,
      );
    }

    Future<void> write(WidgetTester tester) async {
      await tester.enterText(
        find.byKey(const ValueKey('todo-title-field')),
        '쓰던 할 일',
      );
      await tester.pump();
    }

    /// 떠 있는 "작성 취소" 확인에서 [button]을 누른다.
    Future<void> answer(WidgetTester tester, String button) async {
      expect(find.text('작성 취소'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, button));
      await tester.pumpAndSettle();
      expect(find.text('작성 취소'), findsNothing);
    }

    testWidgets(
      '같은 메뉴 타일로 닫거나 다른 패널(상단 검색)로 바꾸면 먼저 묻는다 — [계속 수정]이면 그대로, [닫기]면 진행',
      (tester) async {
        final session = todoSession();
        await _pumpDesktop(tester, session);
        await openTodoEditor(tester);
        await write(tester);

        await _openMenuTile(tester, 'todos');
        await answer(tester, '계속 수정');
        expect(find.byType(TodoEditor), findsOneWidget);
        expect(find.text('쓰던 할 일'), findsOneWidget);

        await tester.tap(find.byTooltip('검색'));
        await tester.pumpAndSettle();
        await answer(tester, '계속 수정');
        expect(find.byType(SearchScreen), findsNothing);
        expect(find.text('쓰던 할 일'), findsOneWidget);

        await tester.tap(find.byTooltip('검색'));
        await tester.pumpAndSettle();
        await answer(tester, '닫기');
        expect(find.byType(SearchScreen), findsOneWidget);
        expect(find.byType(TodosPanel), findsNothing);

        // 다시 열면 새 목록 — 쓰던 할 일이 없으니 같은 타일로 닫을 때 묻지 않는다.
        await _openMenuTile(tester, 'todos');
        expect(find.byType(TodosPanel), findsOneWidget);
        expect(find.byType(TodoEditor), findsNothing);
        await _openMenuTile(tester, 'todos');
        expect(find.text('작성 취소'), findsNothing);
        expect(find.byType(TodosPanel), findsNothing);
        expect(tester.takeException(), isNull);
        await _finish(tester);
      },
    );

    testWidgets('쓰던 게 없으면(열기만 한 수정 화면) 묻지 않고 바로 바꾸거나 닫는다', (tester) async {
      final session = todoSession();
      await _pumpDesktop(tester, session);
      await openTodoEditor(tester);
      await tester.tap(find.byTooltip('검색'));
      await tester.pumpAndSettle();
      expect(find.text('작성 취소'), findsNothing);
      expect(find.byType(SearchScreen), findsOneWidget);
      expect(find.byType(TodosPanel), findsNothing);

      await _openMenuTile(tester, 'todos');
      await openTodoEditor(tester, openPanel: false);
      await _openMenuTile(tester, 'todos');
      expect(find.text('작성 취소'), findsNothing);
      expect(find.byType(TodosPanel), findsNothing);
      await _finish(tester);
    });

    testWidgets('생성 대화상자는 패널 밖이라 홈 화면이 묻지 않는다 — 대화상자는 제 ✕·취소로만 닫힌다', (
      tester,
    ) async {
      final session = todoSession();
      await _pumpDesktop(tester, session);
      await _openMenuTile(tester, 'todos');
      await tester.tap(find.byKey(const ValueKey('todo-create')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TodoEditor>(find.byType(TodoEditor)).mode,
        TodoViewMode.dialog,
      );
      expect(find.byType(Dialog), findsOneWidget);
      await write(tester);
      // 대화상자의 ✕ — 이 화면이 한 번 묻는다.
      await tester.tap(find.byKey(const ValueKey('todo-editor-close')));
      await tester.pumpAndSettle();
      await answer(tester, '닫기');
      expect(find.byType(TodoEditor), findsNothing);
      expect(find.byType(TodosPanel), findsOneWidget, reason: '패널은 그대로');
      // 쓰던 할 일이 패널에 없으니 같은 타일로 닫을 때 묻지 않는다.
      await _openMenuTile(tester, 'todos');
      expect(find.text('작성 취소'), findsNothing);
      expect(find.byType(TodosPanel), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('수정 화면의 ✕(패널 닫기)는 한 번만 묻는다 — 홈 화면은 다시 묻지 않는다', (tester) async {
      final session = todoSession();
      await _pumpDesktop(tester, session);
      await openTodoEditor(tester);
      await write(tester);
      await tester.tap(find.byKey(const ValueKey('todo-page-close')));
      await tester.pumpAndSettle();
      await answer(tester, '닫기');
      expect(find.text('작성 취소'), findsNothing);
      expect(find.byType(TodosPanel), findsNothing);
      await _finish(tester);
    });

    testWidgets('메시지의 댓글을 열면(오른쪽 칸을 댓글로 바꿈) 먼저 묻는다', (tester) async {
      final session = todoSession();
      await _pumpDesktop(tester, session);
      session.requestOpenRoom(session.roomById('r1')!);
      await tester.pumpAndSettle();
      expect(find.byType(ChatPanel), findsOneWidget);
      await openTodoEditor(tester);
      await write(tester);
      final message = Message.fromJson({
        'id': 'm1',
        'roomId': 'r1',
        'senderId': 'me',
        'senderName': '나',
        'type': 'text',
        'text': '댓글을 달 메시지',
        'createdAt': 1,
      });
      void openThread() => tester
          .widget<ChatPanel>(find.byType(ChatPanel))
          .onOpenThread!(message);

      openThread();
      await tester.pumpAndSettle();
      await answer(tester, '계속 수정');
      expect(find.byType(MessageThreadScreen), findsNothing);
      expect(find.text('쓰던 할 일'), findsOneWidget);

      openThread();
      await tester.pumpAndSettle();
      await answer(tester, '닫기');
      expect(find.byType(MessageThreadScreen), findsOneWidget);
      expect(find.byType(TodosPanel), findsNothing);
      // 댓글 패널 자체의 가로 넘침(시험 글꼴에서 입력 줄 단추가 420 칸을 넘는다 — 할 일 패널 없이 댓글만 열어도 난다)은
      // 이 시험과 무관해 비운다. 그 밖의 오류는 그대로 실패한다.
      final error = tester.takeException();
      if (error != null) expect('$error', contains('RenderFlex overflowed'));
      await _finish(tester);
    });

    testWidgets('방 목록 우클릭의 "대화창 분할하기"도 먼저 묻는다', (tester) async {
      final session = todoSession(
        rooms: [_topic('r1', '공지방'), _topic('r2', '개발방')],
      );
      await _pumpDesktop(tester, session);
      session.requestOpenRoom(session.roomById('r1')!);
      await tester.pumpAndSettle();
      await openTodoEditor(tester);
      await write(tester);
      Future<void> split() async {
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('topic-row-r2')),
            matching: find.text('개발방'),
          ),
          buttons: kSecondaryButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('대화창 분할하기'));
        await tester.pumpAndSettle();
      }

      await split();
      await answer(tester, '계속 수정');
      expect(find.byType(ChatPanel), findsOneWidget, reason: '분할하지 않았다');
      expect(find.text('쓰던 할 일'), findsOneWidget);

      await split();
      await answer(tester, '닫기');
      expect(find.byType(ChatPanel), findsNWidgets(2));
      expect(find.byType(TodosPanel), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });
  });

  group('모바일 앱바', () {
    testWidgets('방 목록 화면의 앱바에는 캘린더 버튼이 없고 메뉴 버튼만 남는다', (tester) async {
      final session = _session(rooms: [_topic('r1', '공지방')]);
      _size(tester, const Size(360, 780));
      await tester.pumpWidget(
        MaterialApp(home: RoomListScreen(session: session)),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('캘린더'), findsNothing);
      expect(find.byKey(const ValueKey('open-calendar')), findsNothing);
      expect(find.byTooltip('메뉴'), findsOneWidget);
      await tester.tap(find.byTooltip('메뉴'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('menu-calendar')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-project')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('앱바에 캘린더 버튼이 없고 메뉴의 "툴"에 있다', (tester) async {
      final session = _session();
      _size(tester, const Size(360, 780));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              appBar: AppBar(actions: [AppMenuButton(session: session)]),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('open-calendar')), findsNothing);
      await tester.tap(find.byTooltip('메뉴'));
      await tester.pumpAndSettle();
      // 메뉴의 캘린더는 홈 화면 밖에서는 전체 화면 라우트다.
      await tester.tap(find.byKey(const ValueKey('menu-calendar')));
      await tester.pumpAndSettle();
      expect(find.byType(CalendarScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });
  });
}
