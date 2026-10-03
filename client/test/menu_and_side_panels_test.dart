import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/calendar/calendar_screen.dart';
import 'package:client/screens/desktop_home_screen.dart';
import 'package:client/screens/favorites_screen.dart';
import 'package:client/screens/files_screen.dart';
import 'package:client/screens/links_screen.dart';
import 'package:client/screens/my_posts_screen.dart';
import 'package:client/screens/polls_screen.dart';
import 'package:client/screens/room_list_screen.dart';
import 'package:client/screens/search_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/services/typing_gate.dart';
import 'package:client/widgets/app_menu_button.dart';
import 'package:client/widgets/menu_entries.dart';
import 'package:client/widgets/notifications_panel.dart';
import 'package:client/widgets/side_panels.dart';
import 'package:client/widgets/team_members_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

Session _session({AccountRole role = AccountRole.member, List<Room>? rooms}) {
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
      // 묶음 안의 순서(order): 생성 10·30, 리스트 10·20·30·40·50, 툴 10·20·30.
      final create = ['메시지 예약', '투표'];
      final list = ['파일', '즐겨찾기', '북마크', '링크', '내가 쓴 글'];
      final tools = ['캘린더', '프로젝트', '문의함'];
      expect(_readingOrder(tester, [...create].reversed.toList()), create);
      expect(_readingOrder(tester, [...list].reversed.toList()), list);
      expect(_readingOrder(tester, [...tools].reversed.toList()), tools);

      // 묶음이 아래로 이어진다 — 생성 < 리스트 < 툴.
      double y(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(y('투표'), lessThan(y('리스트')));
      expect(y('링크'), lessThan(y('툴')));

      // 기존 키는 그대로다.
      for (final key in [
        'schedule',
        'poll',
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
        expect(keys, ['calendar', 'zz-1', 'zz-2', 'project', 'inquiries']);
      });
    });
  });

  group('패널 등록 구조', () {
    final added = <SidePanelSpec>[];
    tearDown(() {
      sidePanelSpecs.removeWhere(added.contains);
      added.clear();
    });

    test('기본으로 검색·파일·링크·앨범·할 일·즐겨찾기·투표·내가 쓴 글·북마크·알림 센터·멤버가 등록돼 있다', () {
      expect(sidePanelSpecs.map((s) => s.key), [
        'search',
        'files',
        'links',
        'albums',
        'todos',
        'favorites',
        'polls',
        'myposts',
        'bookmarks',
        'notifications',
        'members',
      ]);
      expect(sidePanelSpecFor('nope'), isNull);
    });

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
