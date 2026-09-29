import 'dart:convert';

import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/chat_screen.dart';
import 'package:client/screens/desktop_home_screen.dart';
import 'package:client/screens/room_list_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/chat_socket.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/services/typing_gate.dart';
import 'package:client/widgets/topic_folder_widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 토픽 목록 정리(개인 토픽 폴더) 화면 — PC 사이드바(폴더 묶음·접기·⋯ 메뉴·[+] 메뉴·마우스
/// 끌어다 놓기·우클릭 "폴더로 이동"·보관된 토픽·대화 헤더 칩)와 모바일 토픽 탭(묶음·길게 누르기
/// "폴더로 이동"·[+] 시트), 그리고 토픽에서 내보내짐/토픽 삭제 안내(room:removed).

/// 방을 열 때 부르는 "그 방 알림 지우기"(OS 알림 플러그인)를 조용히 넘긴다.
class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}

  @override
  Future<void> showMessage({
    required String title,
    required String body,
    required String roomId,
    String? senderName,
    String? conversationTitle,
    String avatarType = 'initial',
    String? avatarEmoji,
    String? avatarColor,
    String? avatarUrl,
    bool isSecret = false,
  }) async {}
}

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

/// 토픽 폴더 API를 흉내 내는 가짜 서버 — GET이 아닌 요청을 [log]에 "METHOD 경로 본문"으로 남긴다.
class _Server {
  final log = <String>[];
  final gets = <String>[];
  List<Map<String, dynamic>> folders = [];

  /// 토픽 옮기기(PUT /rooms/:id/folder)를 일부러 실패시킨다.
  bool failMove = false;
  var _nextFolder = 1;

  late final client = MockClient((request) async {
    final path = request.url.path;
    final method = request.method;
    final body = request.body.isEmpty ? null : jsonDecode(request.body);
    if (method == 'GET') {
      gets.add(path);
    } else {
      log.add('$method $path ${jsonEncode(body)}');
    }

    if (path == '/api/rooms/folders') {
      if (method == 'POST') {
        final folder = {
          'id': 'n${_nextFolder++}',
          'name': (body as Map)['name'],
          'position': folders.length,
          'collapsed': false,
          'roomIds': <String>[],
        };
        folders.add(folder);
        return _json(folder, 201);
      }
      final sorted = [
        ...folders,
      ]..sort((a, b) => (a['position'] as int).compareTo(b['position'] as int));
      return _json(sorted);
    }
    if (path == '/api/topic-folders/order' && method == 'PUT') {
      final ids = ((body as Map)['folderIds'] as List).cast<String>();
      for (final f in folders) {
        f['position'] = ids.indexOf(f['id'] as String);
      }
      return _json({'ok': true});
    }
    if (path.startsWith('/api/topic-folders/')) {
      final id = path.split('/').last;
      final folder = folders.firstWhere((f) => f['id'] == id);
      if (method == 'DELETE') {
        folders.remove(folder);
        return _json({'ok': true});
      }
      folder.addAll((body as Map).cast<String, dynamic>());
      return _json(folder);
    }
    final move = RegExp(r'^/api/rooms/([\w-]+)/folder$').firstMatch(path);
    if (move != null && method == 'PUT') {
      if (failMove) return _json({'error': '이 방의 멤버가 아닙니다.'}, 403);
      final roomId = move.group(1)!;
      for (final f in folders) {
        (f['roomIds'] as List).remove(roomId);
      }
      final folderId = (body as Map)['folderId'] as String?;
      if (folderId != null) {
        (folders.firstWhere((f) => f['id'] == folderId)['roomIds'] as List).add(
          roomId,
        );
      }
      return _json({'ok': true});
    }
    return _json(<Object>[]);
  });
}

Map<String, dynamic> _folder(
  String id,
  String name,
  int position,
  List<String> roomIds,
) => {
  'id': id,
  'name': name,
  'position': position,
  'collapsed': false,
  'roomIds': [...roomIds],
};

Map<String, dynamic> _user(String id, String name) => {
  'id': id,
  'username': id,
  'name': name,
  'role': 'member',
};

Room _room(
  String id,
  String name, {
  String type = 'topic',
  bool favorite = false,
  int unread = 0,
  int minute = 0,
  bool archived = false,
  bool readOnly = false,
  bool board = false,
  bool isPublic = true,
}) => Room.fromJson({
  'id': id,
  'teamId': 't1',
  'type': type,
  'name': name,
  'isPublic': isPublic,
  'members': [_user('me', '나'), _user('u2', '김철수')],
  'createdAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
  'lastActivityAt': DateTime(2026, 9, 29, 9, minute).millisecondsSinceEpoch,
  'unreadCount': unread,
  'favorite': favorite,
  'readOnly': readOnly,
  'viewMode': board ? 'board' : 'chat',
  if (archived) 'archivedAt': DateTime(2026, 9, 1).millisecondsSinceEpoch,
});

/// 폴더 "영업"(r1·r2, 보관된 r5) · "개발"(r3), 폴더 밖 r4(즐겨찾기)·r6·r8, 보관된 r7, 그룹 g1.
/// 토픽 8개, 안 읽은 수 합계 2+1+5+1 = 9.
List<Room> _rooms() => [
  _room('r1', '고객 문의', unread: 2, minute: 50),
  _room('r2', '견적 요청', favorite: true, unread: 1, minute: 5),
  _room('r3', '서버 점검', unread: 5, minute: 30),
  _room('r4', '잡담', favorite: true, minute: 1),
  _room('r5', '옛 영업', archived: true),
  _room('r6', '공지', minute: 40),
  _room('r7', '지난 행사', archived: true, unread: 1),
  _room('r8', '회의록', minute: 20),
  _room('g1', '점심 모임', type: 'group'),
];

/// 서버가 position 순으로 주지 않아도 화면은 position 순(영업 → 개발)이어야 한다.
List<Map<String, dynamic>> _defaultFolders() => [
  _folder('f2', '개발', 1, ['r3']),
  _folder('f1', '영업', 0, ['r1', 'r2', 'r5']),
];

Future<Session> _session(
  _Server server, {
  AccountRole role = AccountRole.member,
  TopicCreationPolicy? policy,
}) async {
  final session = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: server.client,
  );
  session.userId = 'me';
  session.accountRole = role;
  final team = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  if (policy != null) team.topicCreationPolicy = policy;
  session.teams.add(team);
  session.currentTeam = team;
  session.rooms.addAll(_rooms());
  await session.loadTopicFolders();
  server.gets.clear();
  return session;
}

Finder _byTypeName(String name) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

Finder _inSidebar(Finder f) =>
    find.descendant(of: _byTypeName('_Sidebar'), matching: f);

Finder _folderHeader(String id) => find.byKey(ValueKey('topic-folder-$id'));

Finder _inFolderHeader(String id, Finder f) =>
    find.descendant(of: _folderHeader(id), matching: f);

Finder _folderMenuButton(String id) =>
    _inFolderHeader(id, find.byTooltip('폴더 메뉴'));

/// ⋯ 버튼을 감싼 가장 가까운 Opacity 값 — 0이면 안 보이는 상태다.
double _menuOpacity(WidgetTester tester, Finder button) => tester
    .widget<Opacity>(
      find.ancestor(of: button, matching: find.byType(Opacity)).first,
    )
    .opacity;

Future<void> _pumpDesktop(WidgetTester tester, Session session) async {
  // 토픽 구역(사이드바 높이의 1/3)에 폴더·토픽이 다 보이도록 창을 높게 잡는다.
  tester.view.physicalSize = const Size(1400, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(home: DesktopHomeScreen(session: session)),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Future<void> _pumpMobile(WidgetTester tester, Session session) async {
  // 휴대폰 폭이되, 테스트 글꼴(네모 글자)로도 대화 화면 입력칸이 넘치지 않을 만큼.
  tester.view.physicalSize = const Size(520, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: RoomListScreen(session: session)));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

/// 화면을 내리고 남은 토스트 타이머까지 흘려보낸다.
Future<void> _finish(WidgetTester tester) async {
  TypingGate.instance.reset();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

/// 폴더 이름 입력 창에 [name]을 넣고 [action](생성/변경)을 누른다.
Future<void> _submitFolderName(
  WidgetTester tester,
  String name,
  String action,
) async {
  await tester.enterText(find.byType(TextField).last, name);
  await tester.pump();
  await tester.tap(find.widgetWithText(FilledButton, action));
  await tester.pumpAndSettle();
}

/// 사이드바 줄 [text]를 오른쪽 버튼으로 눌러 우클릭 메뉴를 연다.
Future<void> _rightClick(WidgetTester tester, String text) async {
  await tester.tapAt(
    tester.getCenter(_inSidebar(find.text(text))),
    buttons: kSecondaryMouseButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
}

/// 우클릭 메뉴 바깥(상단 바 왼쪽 빈 곳)을 눌러 닫는다.
Future<void> _closeMenus(WidgetTester tester) async {
  await tester.tapAt(const Offset(700, 1990));
  await tester.pumpAndSettle();
}

void main() {
  late _Server server;
  setUp(() {
    server = _Server()..folders = _defaultFolders();
  });

  group('PC 사이드바', () {
    double y(WidgetTester tester, String text) =>
        tester.getCenter(_inSidebar(find.text(text)).first).dy;

    testWidgets('폴더(순서대로) → 폴더 밖 → 보관된 토픽 — 안은 즐겨찾기 먼저·최근 순이고, 머리글은 전부 센다', (
      tester,
    ) async {
      final session = await _session(server);
      await _pumpDesktop(tester, session);

      // 토픽 머리글의 수·안 읽은 수는 폴더 안·보관된 토픽까지 전부 센다.
      final header = _byTypeName('_SectionHeader').first;
      expect(
        find.descendant(of: header, matching: find.text('토픽 8')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: header, matching: find.text('9')),
        findsOneWidget,
      );

      const order = [
        '영업',
        '견적 요청', // 폴더 안도 즐겨찾기 먼저
        '고객 문의',
        '개발',
        '서버 점검',
        '잡담', // 폴더 밖: 즐겨찾기 먼저, 그다음 최근 활동 순
        '공지',
        '회의록',
        '보관된 토픽',
      ];
      for (var i = 1; i < order.length; i++) {
        expect(
          y(tester, order[i]),
          greaterThan(y(tester, order[i - 1])),
          reason: '${order[i - 1]} 다음에 ${order[i]}',
        );
      }
      // 폴더 머리글의 토픽 수 — 보관된 "옛 영업"은 폴더에 들어 있어도 세지 않는다.
      expect(_inFolderHeader('f1', find.text('2')), findsOneWidget);
      expect(_inFolderHeader('f2', find.text('1')), findsOneWidget);
      // 폴더 안 토픽은 들여 쓴다.
      expect(
        tester.getRect(_inSidebar(find.text('고객 문의'))).left,
        greaterThan(tester.getRect(_inSidebar(find.text('공지'))).left),
      );
      // 그룹채팅은 토픽 폴더와 상관없이 제자리.
      expect(_inSidebar(find.text('점심 모임')), findsOneWidget);

      // 보관된 토픽은 기본으로 접혀 있고, 그 묶음 말고는 어디에도 안 보인다. 접혀 있으면
      // 안 읽은 수 합계(1)를 보여준다.
      expect(_inSidebar(find.text('옛 영업')), findsNothing);
      expect(_inSidebar(find.text('지난 행사')), findsNothing);
      expect(_inFolderHeader('archived', find.text('2')), findsOneWidget);
      expect(_inFolderHeader('archived', find.text('1')), findsOneWidget);
      // 끌어다 놓을 자리가 아니고 ⋯ 메뉴도 없다.
      expect(
        _inFolderHeader('archived', find.byTooltip('폴더 메뉴')),
        findsNothing,
      );

      await tester.tap(_inSidebar(find.text('보관된 토픽')));
      await tester.pumpAndSettle();
      expect(_inSidebar(find.text('옛 영업')), findsOneWidget);
      expect(_inSidebar(find.text('지난 행사')), findsOneWidget);
      expect(y(tester, '옛 영업'), greaterThan(y(tester, '보관된 토픽')));
      expect(y(tester, '지난 행사'), greaterThan(y(tester, '보관된 토픽')));
      // 펼치면 안 읽은 수는 각 줄에만.
      expect(_inFolderHeader('archived', find.text('1')), findsNothing);
      // 보관된 토픽 펼치기는 화면 상태일 뿐 — 서버에 아무것도 안 보낸다.
      expect(server.log, isEmpty);

      // 새로 보관된 토픽은 폴더·폴더 밖에서 빠져 "보관된 토픽"으로 간다.
      session.roomById('r6')!.archivedAt = DateTime(2026, 9, 30);
      session.notifyListeners();
      await tester.pumpAndSettle();
      expect(_inSidebar(find.text('공지')), findsOneWidget);
      expect(y(tester, '공지'), greaterThan(y(tester, '보관된 토픽')));
      expect(_inFolderHeader('archived', find.text('3')), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('폴더 머리글을 누르면 접히고 펴진다 — PATCH 한 번씩, 다시 읽기 없음, 접히면 안 읽은 수 합계', (
      tester,
    ) async {
      final session = await _session(server);
      await _pumpDesktop(tester, session);

      await tester.tap(_inSidebar(find.text('영업')));
      await tester.pumpAndSettle();
      expect(server.log, ['PATCH /api/topic-folders/f1 {"collapsed":true}']);
      expect(server.gets.where((g) => g == '/api/rooms/folders'), isEmpty);
      expect(_inSidebar(find.text('고객 문의')), findsNothing);
      expect(_inSidebar(find.text('견적 요청')), findsNothing);
      // 토픽 수(2)와 안 읽은 수 합계(2+1=3).
      expect(_inFolderHeader('f1', find.text('2')), findsOneWidget);
      expect(_inFolderHeader('f1', find.text('3')), findsOneWidget);

      server.log.clear();
      await tester.tap(_inSidebar(find.text('영업')));
      await tester.pumpAndSettle();
      expect(server.log, ['PATCH /api/topic-folders/f1 {"collapsed":false}']);
      expect(_inSidebar(find.text('고객 문의')), findsOneWidget);
      expect(_inFolderHeader('f1', find.text('3')), findsNothing);
      await _finish(tester);
    });

    testWidgets('[+] 메뉴 — 정회원은 세 항목, 토픽 생성 권한이 없으면 생성만 빠지고, 준회원은 폴더 생성만', (
      tester,
    ) async {
      Future<List<String>> plusItems(Session session) async {
        await _pumpDesktop(tester, session);
        await tester.tap(find.byTooltip('토픽 추가'));
        await tester.pumpAndSettle();
        final items = [
          for (final label in ['새로운 토픽 생성하기', '참여 가능한 토픽 보기', '폴더 생성'])
            if (find.text(label).evaluate().isNotEmpty) label,
        ];
        await tester.tapAt(const Offset(700, 1990));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        return items;
      }

      expect(await plusItems(await _session(server)), [
        '새로운 토픽 생성하기',
        '참여 가능한 토픽 보기',
        '폴더 생성',
      ]);
      expect(
        await plusItems(
          await _session(server, policy: TopicCreationPolicy.owner),
        ),
        ['참여 가능한 토픽 보기', '폴더 생성'],
      );
      expect(await plusItems(await _session(server, role: AccountRole.guest)), [
        '폴더 생성',
      ]);
      await _finish(tester);
    });

    testWidgets('[+] > 폴더 생성 — 이름 창(30자, 비면 잠김)에서 만들면 맨 뒤에 새 폴더가 생긴다', (
      tester,
    ) async {
      final session = await _session(server);
      await _pumpDesktop(tester, session);

      await tester.tap(find.byTooltip('토픽 추가'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('폴더 생성'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, '폴더 생성'), findsOneWidget);
      expect(find.text('폴더 이름'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).maxLength,
        30,
      );
      final create = find.widgetWithText(FilledButton, '생성');
      expect(tester.widget<FilledButton>(create).onPressed, isNull);
      expect(find.widgetWithText(TextButton, '취소'), findsOneWidget);

      await _submitFolderName(tester, '  기획  ', '생성');
      expect(tester.takeException(), isNull);
      expect(server.log, [
        'POST /api/rooms/folders {"teamId":"t1","name":"기획"}',
      ]);
      expect(_folderHeader('n1'), findsOneWidget);
      expect(_inFolderHeader('n1', find.text('0')), findsOneWidget);
      expect(y(tester, '기획'), greaterThan(y(tester, '서버 점검')));
      expect(y(tester, '기획'), lessThan(y(tester, '잡담')));
      await _finish(tester);
    });

    testWidgets('⋯ 는 마우스를 올려야 보이고, 이름 변경·폴더 삭제(확인 문구)를 한다', (tester) async {
      final session = await _session(server);
      await _pumpDesktop(tester, session);
      expect(_menuOpacity(tester, _folderMenuButton('f1')), 0);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: tester.getCenter(_folderHeader('f1')));
      await tester.pumpAndSettle();
      expect(_menuOpacity(tester, _folderMenuButton('f1')), 1);
      expect(_menuOpacity(tester, _folderMenuButton('f2')), 0);

      // ⋯ > 이름 변경.
      await tester.tap(_folderMenuButton('f1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('이름 변경'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, '폴더 이름 변경'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        '영업',
      );
      await _submitFolderName(tester, '영업1팀', '변경');
      expect(server.log, ['PATCH /api/topic-folders/f1 {"name":"영업1팀"}']);
      expect(_inSidebar(find.text('영업1팀')), findsOneWidget);

      // ⋯ > 폴더 삭제 — 확인 문구를 보여주고, 안의 토픽은 폴더 밖 목록으로 돌아온다.
      server.log.clear();
      await tester.tap(_folderMenuButton('f1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('폴더 삭제'));
      await tester.pumpAndSettle();
      expect(find.text("'영업1팀' 폴더 삭제"), findsOneWidget);
      expect(find.text('폴더만 삭제되고 안의 토픽은 목록에 그대로 남습니다.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '삭제'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(server.log, ['DELETE /api/topic-folders/f1 null']);
      expect(_folderHeader('f1'), findsNothing);
      expect(y(tester, '고객 문의'), greaterThan(y(tester, '서버 점검')));
      expect(y(tester, '견적 요청'), greaterThan(y(tester, '서버 점검')));
      await _finish(tester);
    });

    testWidgets('마우스로 끌어 폴더에 넣고, 토픽 머리글로 빼고, 폴더 머리글끼리 순서를 바꾼다', (tester) async {
      final session = await _session(server);
      await _pumpDesktop(tester, session);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);

      Future<void> dragTo(
        Finder from,
        Finder to, {
        Future<void> Function()? whileOver,
      }) async {
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
        if (whileOver != null) await whileOver();
        await mouse.up();
        await tester.pumpAndSettle();
      }

      bool highlighted(Finder of) => tester
          .widget<TopicDropHighlight>(
            find
                .descendant(of: of, matching: find.byType(TopicDropHighlight))
                .first,
          )
          .active;

      // 폴더 밖 "공지" → "영업" 폴더. 끄는 동안 그 폴더 머리글에 강조가 깔린다.
      await dragTo(
        _inSidebar(find.text('공지')),
        _inSidebar(find.text('영업')),
        whileOver: () async {
          expect(highlighted(_folderHeader('f1')), isTrue);
          expect(highlighted(_folderHeader('f2')), isFalse);
        },
      );
      expect(tester.takeException(), isNull);
      expect(server.log, ['PUT /api/rooms/r6/folder {"folderId":"f1"}']);
      expect(highlighted(_folderHeader('f1')), isFalse);
      expect(_inFolderHeader('f1', find.text('3')), findsOneWidget);
      expect(y(tester, '공지'), lessThan(y(tester, '개발')));

      // 이미 그 폴더에 든 토픽을 같은 폴더에 다시 놓으면 아무 요청이 없다.
      server.log.clear();
      await dragTo(_inSidebar(find.text('공지')), _inSidebar(find.text('영업')));
      expect(server.log, isEmpty);

      // 폴더 안 "고객 문의" → '토픽' 머리글이면 폴더에서 빠진다.
      await dragTo(
        _inSidebar(find.text('고객 문의')),
        _inSidebar(find.text('토픽 8')),
        whileOver: () async {
          expect(highlighted(_byTypeName('_Sidebar')), isTrue);
        },
      );
      expect(server.log, ['PUT /api/rooms/r1/folder {"folderId":null}']);
      expect(y(tester, '고객 문의'), greaterThan(y(tester, '서버 점검')));

      // 폴더 밖 토픽을 '토픽' 머리글에 놓으면 받지 않는다(요청 없음).
      server.log.clear();
      await dragTo(_inSidebar(find.text('회의록')), _inSidebar(find.text('토픽 8')));
      expect(server.log, isEmpty);

      // "개발" 머리글 → "영업" 머리글: 개발이 영업 자리(맨 위)로 온다.
      await dragTo(_inSidebar(find.text('개발')), _inSidebar(find.text('영업')));
      expect(server.log, [
        'PUT /api/topic-folders/order {"teamId":"t1","folderIds":["f2","f1"]}',
      ]);
      expect(y(tester, '개발'), lessThan(y(tester, '영업')));
      expect(y(tester, '서버 점검'), lessThan(y(tester, '영업')));

      // 문턱보다 적게 흔들린 클릭은 끌기가 아니다 — 토픽은 열리고, 폴더 머리글은 접힌다.
      server.log.clear();
      Future<void> jiggleClick(Finder target) async {
        final at = tester.getCenter(target);
        await mouse.moveTo(at);
        await tester.pump();
        await mouse.down(at);
        await tester.pump();
        await mouse.moveTo(at + const Offset(3, 0));
        await tester.pump();
        await mouse.up();
        await tester.pumpAndSettle();
      }

      await jiggleClick(_inSidebar(find.text('잡담')));
      expect(server.log, isEmpty);
      expect(find.byKey(const ValueKey('main-r4')), findsOneWidget);
      await jiggleClick(_inSidebar(find.text('개발')));
      expect(server.log, ['PATCH /api/topic-folders/f2 {"collapsed":true}']);
      await _finish(tester);
    });

    testWidgets('끌어 넣기가 서버에서 실패하면 되돌리고 알린다', (tester) async {
      final session = await _session(server);
      await _pumpDesktop(tester, session);
      server.failMove = true;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      final start = tester.getCenter(_inSidebar(find.text('공지')));
      await mouse.addPointer(location: start);
      await mouse.down(start);
      await tester.pump();
      await mouse.moveTo(start + const Offset(0, 12));
      await tester.pump();
      await mouse.moveTo(tester.getCenter(_inSidebar(find.text('영업'))));
      await tester.pump();
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.text('폴더로 옮기지 못했습니다: 이 방의 멤버가 아닙니다.'), findsOneWidget);
      expect(_inFolderHeader('f1', find.text('2')), findsOneWidget);
      expect(y(tester, '공지'), greaterThan(y(tester, '잡담')));
      await _finish(tester);
    });

    testWidgets('우클릭 메뉴 — 폴더로 이동(지금 폴더는 잠김)·새 폴더…·폴더에서 빼기, 기존 항목은 그대로', (
      tester,
    ) async {
      final session = await _session(server);
      await _pumpDesktop(tester, session);

      // 폴더 밖 토픽: 기존 항목 + "폴더로 이동"(빼기는 없음).
      await _rightClick(tester, '공지');
      for (final label in ['대화창 분할하기', '대화방 알림 끄기', '모두 읽음 처리', '나가기']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('폴더로 이동'), findsOneWidget);
      expect(find.text('폴더에서 빼기'), findsNothing);
      await tester.tap(find.text('폴더로 이동'));
      await tester.pumpAndSettle();
      // 원래 메뉴는 그대로 두고 옆에 폴더 목록이 뜬다.
      expect(find.text('대화창 분할하기'), findsOneWidget);
      expect(find.widgetWithText(PopupMenuItem<String>, '영업'), findsOneWidget);
      expect(find.widgetWithText(PopupMenuItem<String>, '개발'), findsOneWidget);
      expect(
        find.widgetWithText(PopupMenuItem<String>, '새 폴더…'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, '개발'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('대화창 분할하기'), findsNothing); // 두 메뉴 다 닫혔다
      expect(server.log, ['PUT /api/rooms/r6/folder {"folderId":"f2"}']);
      expect(_inFolderHeader('f2', find.text('2')), findsOneWidget);

      // 폴더 안 토픽: 지금 폴더는 체크 표시·잠김, "폴더에서 빼기"가 있다.
      server.log.clear();
      await _rightClick(tester, '서버 점검');
      expect(find.text('폴더에서 빼기'), findsOneWidget);
      await tester.tap(find.text('폴더로 이동'));
      await tester.pumpAndSettle();
      final current = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, '개발'),
      );
      expect(current.enabled, isFalse);
      expect(
        find.descendant(
          of: find.widgetWithText(PopupMenuItem<String>, '개발'),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      // 하위 메뉴만 닫으면 원래 메뉴는 남아서 다른 항목을 고를 수 있다.
      await tester.tapAt(const Offset(1300, 1900));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(PopupMenuItem<String>, '개발'), findsNothing);
      await tester.tap(find.text('폴더에서 빼기'));
      await tester.pumpAndSettle();
      expect(server.log, ['PUT /api/rooms/r3/folder {"folderId":null}']);
      expect(_inFolderHeader('f2', find.text('1')), findsOneWidget);

      // 새 폴더… — 이름을 받아 만들고 그 폴더에 바로 넣는다.
      server.log.clear();
      await _rightClick(tester, '회의록');
      await tester.tap(find.text('폴더로 이동'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, '새 폴더…'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, '폴더 생성'), findsOneWidget);
      await _submitFolderName(tester, '기획', '생성');
      expect(server.log, [
        'POST /api/rooms/folders {"teamId":"t1","name":"기획"}',
        'PUT /api/rooms/r8/folder {"folderId":"n1"}',
      ]);
      expect(_inFolderHeader('n1', find.text('1')), findsOneWidget);
      expect(y(tester, '회의록'), greaterThan(y(tester, '기획')));

      // 그룹채팅과 보관된 토픽에는 폴더 항목이 없다.
      await _rightClick(tester, '점심 모임');
      expect(find.text('대화창 분할하기'), findsOneWidget);
      expect(find.text('폴더로 이동'), findsNothing);
      await _closeMenus(tester);
      await tester.tap(_inSidebar(find.text('보관된 토픽')));
      await tester.pumpAndSettle();
      await _rightClick(tester, '옛 영업');
      expect(find.text('대화창 분할하기'), findsOneWidget);
      expect(find.text('폴더로 이동'), findsNothing);
      expect(find.text('폴더에서 빼기'), findsNothing);
      await _closeMenus(tester);
      await _finish(tester);
    });

    testWidgets('새 폴더…에서 옮기기만 실패하면 그렇게 알리고, 새 폴더는 보인다', (tester) async {
      final session = await _session(server);
      await _pumpDesktop(tester, session);
      server.failMove = true;
      await _rightClick(tester, '회의록');
      await tester.tap(find.text('폴더로 이동'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, '새 폴더…'));
      await tester.pumpAndSettle();
      await _submitFolderName(tester, '기획', '생성');
      expect(
        find.text('폴더는 만들었지만 토픽을 옮기지 못했습니다: 이 방의 멤버가 아닙니다.'),
        findsOneWidget,
      );
      expect(_inFolderHeader('n1', find.text('0')), findsOneWidget);
      expect(y(tester, '회의록'), greaterThan(y(tester, '잡담')));
      await _finish(tester);
    });

    testWidgets('대화 헤더 — 토픽 이름 옆 상태 칩(읽기 전용·보관됨·보드 뷰)과 비공개 자물쇠, 바뀌면 바로 보인다', (
      tester,
    ) async {
      final session = await _session(server);
      session.rooms.addAll([
        _room('r9', '운영 공지', readOnly: true, archived: true, isPublic: false),
      ]);
      await _pumpDesktop(tester, session);
      Finder chip(String key) => find.byKey(ValueKey('topic-chip-$key'));

      // 보통 토픽 — 칩 없음.
      await tester.tap(_inSidebar(find.text('공지')));
      await tester.pumpAndSettle();
      expect(find.byType(TopicStatusChip), findsNothing);

      // 읽기 전용이 켜지면(토픽 정보 변경의 room:created 반영) 헤더가 바로 다시 그려진다.
      session.roomById('r6')!.readOnly = true;
      session.notifyListeners();
      await tester.pumpAndSettle();
      expect(chip('read-only'), findsOneWidget);
      expect(chip('archived'), findsNothing);

      // 읽기 전용 + 보관 + 비공개 토픽(보관된 토픽 묶음에서 연다).
      await tester.tap(_inSidebar(find.text('보관된 토픽')));
      await tester.pumpAndSettle();
      await tester.tap(_inSidebar(find.text('운영 공지')));
      await tester.pumpAndSettle();
      expect(chip('read-only'), findsOneWidget);
      expect(chip('archived'), findsOneWidget);
      expect(chip('board'), findsNothing);
      // 비공개 자물쇠는 사이드바 줄과 헤더 양쪽에 있다.
      expect(
        find.byKey(const ValueKey('private-topic-lock')),
        findsNWidgets(2),
      );
      // 칩은 헤더의 이름(사이드바 줄 다음에 그려지는 쪽) 오른쪽에 같은 줄로 선다.
      final nameRect = tester.getRect(find.text('운영 공지').last);
      final chipRect = tester.getRect(chip('read-only'));
      expect(chipRect.left, greaterThan(nameRect.right));
      expect((chipRect.center.dy - nameRect.center.dy).abs(), lessThan(4));
      await _finish(tester);
    });

    testWidgets('긴 폴더·토픽 이름과 큰 안 읽은 수도 사이드바 폭(겹침 사이드바 포함)에서 넘치지 않는다', (
      tester,
    ) async {
      const longFolder = '아주아주 긴 폴더 이름 영업 마케팅 디자인 개발 운영 공지';
      server.folders = [
        _folder('f1', longFolder, 0, ['r1', 'r3']),
      ];
      final session = await _session(server);
      session.roomById('r1')!
        ..name = '이름이 아주 긴 토픽 — 사이드바 폭을 훌쩍 넘어가는 이름'
        ..unreadCount = 999;
      await _pumpDesktop(tester, session);
      expect(tester.takeException(), isNull);
      // 접으면 머리글에 큰 안 읽은 수가 붙어도 넘치지 않는다.
      await tester.tap(_inFolderHeader('f1', find.text(longFolder)));
      await tester.pumpAndSettle();
      expect(_inFolderHeader('f1', find.text('1004')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 좁은 창 — 사이드바는 화살표 스트립을 눌러야 겹쳐 뜨고, 거기서도 폴더 작업이 된다.
      tester.view.physicalSize = const Size(900, 2000);
      await tester.pumpAndSettle();
      expect(_byTypeName('_Sidebar'), findsNothing);
      await tester.tap(find.byIcon(Icons.keyboard_double_arrow_right));
      await tester.pumpAndSettle();
      await tester.tap(_inFolderHeader('f1', find.text(longFolder)));
      await tester.pumpAndSettle();
      expect(
        server.log.last,
        'PATCH /api/topic-folders/f1 {"collapsed":false}',
      );
      expect(tester.takeException(), isNull);
      await _finish(tester);

      // 모바일 목록도 같은 이름으로 넘치지 않는다(가장 좁은 휴대폰 폭).
      tester.view.physicalSize = const Size(320, 1400);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(
        MaterialApp(home: RoomListScreen(session: session)),
      );
      await tester.pumpAndSettle();
      await tester.tap(_inFolderHeader('f1', find.text(longFolder)));
      await tester.pumpAndSettle();
      expect(_inFolderHeader('f1', find.text('1004')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('상태 칩 모양 — 보드 뷰·읽기 전용·보관됨이 같은 모양이고, 그룹·DM엔 없다', (tester) async {
      final board = _room('b1', '주간 보고', board: true, readOnly: true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Row(children: topicStatusChips(board))),
        ),
      );
      expect(find.text('보드 뷰'), findsOneWidget);
      expect(find.text('읽기 전용'), findsOneWidget);
      expect(find.text('보관됨'), findsNothing);
      final chips = tester.widgetList<TopicStatusChip>(
        find.byType(TopicStatusChip),
      );
      expect(chips, hasLength(2));
      expect(tester.getSize(find.byType(TopicStatusChip).first).height, 20);
      expect(tester.getSize(find.byType(TopicStatusChip).last).height, 20);
      final group = _room(
        'g9',
        '그룹',
        type: 'group',
        readOnly: true,
        archived: true,
      );
      expect(topicStatusChips(group), isEmpty);
    });

    testWidgets('토픽에서 내보내지거나 토픽이 삭제되면 알리고, 그 방을 보던 메인·분할 패널을 비운다', (
      tester,
    ) async {
      final session = await _session(server);
      await _pumpDesktop(tester, session);
      await tester.tap(_inSidebar(find.text('공지')));
      await tester.pumpAndSettle();
      // "회의록"은 우클릭 > 대화창 분할하기로 오른쪽에 나란히.
      await _rightClick(tester, '회의록');
      await tester.tap(find.text('대화창 분할하기'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('main-r6')), findsOneWidget);
      expect(find.byKey(const ValueKey('split-r8')), findsOneWidget);

      // 한글 입력 중이라 세션 알림이 미뤄져도(typing_gate.dart) 알림 이벤트만으로 바로 비운다.
      TypingGate.instance.composing();
      session.handleRoomRemoved(
        const RoomRemovedEvent(roomId: 'r6', reason: 'kicked', name: '공지'),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text("'공지' 토픽에서 내보내졌습니다."), findsOneWidget);
      expect(find.byKey(const ValueKey('main-r6')), findsNothing);
      expect(find.text('영업팀입니다'), findsOneWidget);
      expect(find.byKey(const ValueKey('split-r8')), findsOneWidget);
      TypingGate.instance.flush();
      await tester.pumpAndSettle();
      expect(_inSidebar(find.text('공지')), findsNothing);
      expect(tester.takeException(), isNull);

      // 분할 패널에 떠 있던 토픽이 삭제되면 분할 패널이 닫힌다.
      session.handleRoomRemoved(
        const RoomRemovedEvent(roomId: 'r8', reason: 'deleted', name: '회의록'),
      );
      await tester.pumpAndSettle();
      expect(find.text("'회의록' 토픽이 삭제되었습니다."), findsOneWidget);
      expect(find.byKey(const ValueKey('split-r8')), findsNothing);
      expect(_inSidebar(find.text('회의록')), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });
  });

  group('모바일 토픽 탭', () {
    double y(WidgetTester tester, String text) =>
        tester.getCenter(find.text(text).first).dy;

    testWidgets('폴더 → 폴더 밖 → 보관된 토픽으로 묶고, 폴더 ⋯는 늘 보이며, 머리글을 누르면 접힌다', (
      tester,
    ) async {
      final session = await _session(server);
      await _pumpMobile(tester, session);

      const order = [
        '영업',
        '견적 요청',
        '고객 문의',
        '개발',
        '서버 점검',
        '잡담',
        '공지',
        '회의록',
        '보관된 토픽',
      ];
      for (var i = 1; i < order.length; i++) {
        expect(
          y(tester, order[i]),
          greaterThan(y(tester, order[i - 1])),
          reason: '${order[i - 1]} 다음에 ${order[i]}',
        );
      }
      expect(
        tester.getRect(find.text('고객 문의')).left,
        greaterThan(tester.getRect(find.text('공지')).left),
      );
      // 보관된 토픽은 접혀 있고 다른 곳에 안 보인다.
      expect(find.text('옛 영업'), findsNothing);
      expect(find.text('지난 행사'), findsNothing);
      // 터치 화면이라 ⋯가 늘 보인다(마우스를 올린 적이 없어도).
      expect(_menuOpacity(tester, _folderMenuButton('f1')), 1);
      expect(_menuOpacity(tester, _folderMenuButton('f2')), 1);

      // (팀 아이콘에도 '영업' 두 글자가 보여서 폴더 머리글 안에서 찾는다.)
      await tester.tap(_inFolderHeader('f1', find.text('영업')));
      await tester.pumpAndSettle();
      expect(server.log, ['PATCH /api/topic-folders/f1 {"collapsed":true}']);
      expect(find.text('고객 문의'), findsNothing);
      expect(_inFolderHeader('f1', find.text('3')), findsOneWidget);

      await tester.tap(find.text('보관된 토픽'));
      await tester.pumpAndSettle();
      expect(find.text('옛 영업'), findsOneWidget);
      expect(find.text('지난 행사'), findsOneWidget);
      expect(server.log, hasLength(1));

      // 폴더 ⋯ > 이름 변경.
      await tester.tap(_folderMenuButton('f1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('이름 변경'));
      await tester.pumpAndSettle();
      await _submitFolderName(tester, '영업2', '변경');
      expect(server.log.last, 'PATCH /api/topic-folders/f1 {"name":"영업2"}');
      expect(_inFolderHeader('f1', find.text('영업2')), findsOneWidget);

      // 머리글을 길게 눌러도 ⋯와 같은 메뉴가 열린다 > 폴더 삭제.
      await tester.longPress(_inFolderHeader('f2', find.text('개발')));
      await tester.pumpAndSettle();
      expect(find.text('이름 변경'), findsOneWidget);
      await tester.tap(find.text('폴더 삭제'));
      await tester.pumpAndSettle();
      expect(find.text('폴더만 삭제되고 안의 토픽은 목록에 그대로 남습니다.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '삭제'));
      await tester.pumpAndSettle();
      expect(server.log.last, 'DELETE /api/topic-folders/f2 null');
      expect(_folderHeader('f2'), findsNothing);
      expect(find.text('서버 점검'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('길게 누르기 > 폴더로 이동(폴더·새 폴더…) / 폴더에서 빼기', (tester) async {
      final session = await _session(server);
      await _pumpMobile(tester, session);

      // 폴더 밖 토픽 — "폴더로 이동"만(빼기 없음), 기존 항목은 그대로.
      await tester.longPress(find.text('공지'));
      await tester.pumpAndSettle();
      for (final label in ['알림 끄기', '즐겨찾기', '폴더로 이동', '나가기']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('폴더에서 빼기'), findsNothing);
      await tester.tap(find.text('폴더로 이동'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, '영업'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '새 폴더…'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, '개발'));
      await tester.pumpAndSettle();
      expect(server.log, ['PUT /api/rooms/r6/folder {"folderId":"f2"}']);
      expect(_inFolderHeader('f2', find.text('2')), findsOneWidget);

      // 폴더 안 토픽 — 지금 폴더는 잠겨 있고, "폴더에서 빼기"가 있다.
      server.log.clear();
      await tester.longPress(find.text('공지'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('폴더로 이동'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ListTile>(find.widgetWithText(ListTile, '개발')).enabled,
        isFalse,
      );
      await tester.tapAt(const Offset(200, 100));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('공지'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('폴더에서 빼기'));
      await tester.pumpAndSettle();
      expect(server.log, ['PUT /api/rooms/r6/folder {"folderId":null}']);

      // 새 폴더… — 이름을 받아 만들고 바로 넣는다.
      server.log.clear();
      await tester.longPress(find.text('회의록'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('폴더로 이동'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '새 폴더…'));
      await tester.pumpAndSettle();
      await _submitFolderName(tester, '기획', '생성');
      expect(server.log, [
        'POST /api/rooms/folders {"teamId":"t1","name":"기획"}',
        'PUT /api/rooms/r8/folder {"folderId":"n1"}',
      ]);
      expect(_inFolderHeader('n1', find.text('1')), findsOneWidget);

      // 보관된 토픽은 길게 눌러도 폴더 항목이 없다.
      await tester.tap(find.text('보관된 토픽'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('옛 영업'));
      await tester.pumpAndSettle();
      expect(find.text('즐겨찾기'), findsOneWidget);
      expect(find.text('폴더로 이동'), findsNothing);
      await _finish(tester);
    });

    testWidgets('[+] 시트 — 정회원은 세 항목, 준회원은 폴더 만들기만(그룹·채팅 탭의 +는 없음)', (
      tester,
    ) async {
      Future<List<String>> sheetItems(Session session) async {
        await _pumpMobile(tester, session);
        await tester.tap(find.byTooltip('토픽 추가'));
        await tester.pumpAndSettle();
        final items = [
          for (final label in ['새로운 토픽 생성하기', '참여 가능한 토픽 보기', '폴더 만들기'])
            if (find.text(label).evaluate().isNotEmpty) label,
        ];
        await tester.tapAt(const Offset(200, 100));
        await tester.pumpAndSettle();
        return items;
      }

      expect(await sheetItems(await _session(server)), [
        '새로운 토픽 생성하기',
        '참여 가능한 토픽 보기',
        '폴더 만들기',
      ]);
      await tester.pumpWidget(const SizedBox());
      expect(
        await sheetItems(
          await _session(server, policy: TopicCreationPolicy.admin),
        ),
        ['참여 가능한 토픽 보기', '폴더 만들기'],
      );
      await tester.pumpWidget(const SizedBox());
      final guest = await _session(server, role: AccountRole.guest);
      expect(await sheetItems(guest), ['폴더 만들기']);
      // 준회원: 그룹채팅 탭엔 + 버튼이 없다.
      await tester.tap(find.text('그룹채팅'));
      await tester.pumpAndSettle();
      expect(find.byType(FloatingActionButton), findsNothing);
      await tester.tap(find.text('토픽'));
      await tester.pumpAndSettle();

      // 폴더 만들기 → 이름 창 → 새 폴더.
      await tester.tap(find.byTooltip('토픽 추가'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('폴더 만들기'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, '폴더 생성'), findsOneWidget);
      await _submitFolderName(tester, '내 정리', '생성');
      expect(server.log, [
        'POST /api/rooms/folders {"teamId":"t1","name":"내 정리"}',
      ]);
      expect(_folderHeader('n1'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('토픽에서 내보내지면 알리고, 그 토픽 대화 화면을 보고 있었으면 목록으로 돌아온다', (
      tester,
    ) async {
      final session = await _session(server);
      await _pumpMobile(tester, session);
      await tester.tap(find.text('공지'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      final listRoute = ModalRoute.of(
        tester.element(find.byType(RoomListScreen, skipOffstage: false)),
      )!;
      expect(listRoute.isCurrent, isFalse);

      // 다른 토픽이 사라지면 안내만 하고 보던 화면은 그대로다.
      session.handleRoomRemoved(
        const RoomRemovedEvent(roomId: 'r8', reason: 'deleted', name: '회의록'),
      );
      await tester.pumpAndSettle();
      expect(find.text("'회의록' 토픽이 삭제되었습니다."), findsOneWidget);
      expect(find.byType(ChatScreen), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));

      // 보고 있던 토픽 — 한글 입력 중이라 세션 알림이 미뤄져도 바로 목록으로 돌아온다.
      TypingGate.instance.composing();
      session.handleRoomRemoved(
        const RoomRemovedEvent(roomId: 'r6', reason: 'kicked', name: '공지'),
      );
      await tester.pump();
      expect(listRoute.isCurrent, isTrue);
      TypingGate.instance.flush();
      await tester.pumpAndSettle();
      expect(find.text("'공지' 토픽에서 내보내졌습니다."), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);
      expect(find.text('공지'), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });
  });
}
