import 'dart:convert';

import 'package:client/models/announcement.dart';
import 'package:client/models/app_user.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/announcement_detail_screen.dart';
import 'package:client/screens/announcement_list_screen.dart';
import 'package:client/screens/desktop_home_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/services/typing_gate.dart';
import 'package:client/widgets/compact_menu.dart';
import 'package:client/widgets/notifications_panel.dart'
    show showUnreadAnnouncementPopup;
import 'package:client/widgets/rich_text_format.dart' show FormattedText;
import 'package:client/widgets/room_options_menu.dart';
import 'package:client/widgets/side_panels.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 토픽 ⋯의 "공지" → 공지 패널(PC 오른쪽 패널 / 모바일 전체 화면). 투표 패널과 같은 틀(머리 `공지`+방 이름+✕, `+ 공지 쓰기`,
/// `내린 공지 제외`, `N개의 공지`와 흰 카드), 카드를 누르면 상세가 PC는 패널 안 화면(←로 목록), 모바일은 전체 화면(←),
/// 상세의 ⋯는 토픽 ⋯와 같은 간결한 메뉴.

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

final _me = AppUser(id: 'me', username: 'me', name: '나');
final _kim = AppUser(id: 'u2', username: 'kim', name: '김철수');

final _at = DateTime(2026, 9, 30, 16, 42).millisecondsSinceEpoch;

Map<String, dynamic> _a(
  String id, {
  String text = '이번 주 금요일 회식',
  String authorId = 'u2',
  bool pinned = true,
  int commentCount = 0,
  int minutesAgo = 0,
}) => {
  'id': id,
  'roomId': 'r1',
  'authorId': authorId,
  'authorName': authorId == 'me' ? '나' : '김철수',
  'text': text,
  'createdAt': _at - minutesAgo * 60000,
  'pinned': pinned,
  'commentCount': commentCount,
};

/// 서버처럼 최신 순(a3 → a2 → a1).
final _items = [
  _a('a3', text: '이번 주 금요일 회식 안내', commentCount: 2),
  _a('a2', text: '지난주 회의록 공유', pinned: false, authorId: 'me', minutesAgo: 60),
  _a('a1', text: '처음 올린 공지', pinned: false, minutesAgo: 120),
];

/// 목록에 보이는 카드 id를 위에서부터.
List<String> _tileOrder(WidgetTester tester) {
  final tiles = find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('announcement-tile-a'),
  );
  final found = tiles.evaluate().map((e) => e.widget.key as ValueKey<String>);
  final ids = found.map((k) => k.value.substring('announcement-tile-'.length));
  final list = ids.toList();
  list.sort(
    (a, b) => tester
        .getTopLeft(find.byKey(ValueKey('announcement-tile-$a')))
        .dy
        .compareTo(
          tester.getTopLeft(find.byKey(ValueKey('announcement-tile-$b'))).dy,
        ),
  );
  return list;
}

Room _room() => Room(
  id: 'r1',
  teamId: 't1',
  type: RoomType.topic,
  name: '영업방',
  members: [_me, _kim],
  createdAt: DateTime(2026),
  lastRead: {},
);

class _Server {
  _Server({this.announcements = const []});

  final List<Map<String, dynamic>> announcements;
  final requests = <http.Request>[];

  late final client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET' && path == '/api/rooms/r1/announcements') {
      return _json(announcements);
    }
    if (request.method == 'DELETE' || path.endsWith('/unpin')) {
      return _json({'ok': true});
    }
    return _json(<Object>[]);
  });

  List<http.Request> called(String method, String suffix) => requests
      .where((r) => r.method == method && r.url.path.endsWith(suffix))
      .toList();
}

Session _session(_Server server, Room room, {Team? team}) {
  final session = Session(
    notifications: _QuietNotifications(),
    settings: AppSettings(),
  );
  session.serverUrl = 'https://test.local';
  session.api = ApiClient(
    baseUrl: 'https://test.local',
    token: 't',
    httpClient: server.client,
  );
  session.userId = 'me';
  session.name = '나';
  session.accountRole = AccountRole.member;
  final t = team ?? Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  session.teams.add(t);
  session.currentTeam = t;
  session.rooms.add(room);
  return session;
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> _finish(WidgetTester tester) async {
  TypingGate.instance.reset();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

String _plain(WidgetTester tester, Key key) {
  final w = tester.widget<Text>(find.byKey(key));
  return w.data ?? w.textSpan?.toPlainText() ?? '';
}

/// 펼친 메뉴의 항목(값의 타입과 상관없이).
final _popupMenuItem = find.byWidgetPredicate((w) => w is PopupMenuItem);

/// 토픽 머리의 ⋯ → "공지".
Future<void> _openFromRoomMenu(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(RoomOptionsMenu),
      matching: find.byTooltip('더보기'),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(
    find.ancestor(of: find.text('공지'), matching: _popupMenuItem),
  );
  await _settle(tester);
}

/// PC 홈 화면에 r1을 열어 둔다.
Future<void> _pumpDesktop(WidgetTester tester, Session session) async {
  _size(tester, const Size(1280, 900));
  await tester.pumpWidget(
    MaterialApp(home: DesktopHomeScreen(session: session)),
  );
  await tester.pumpAndSettle();
  session.requestOpenRoom(session.roomById('r1')!);
  await tester.pumpAndSettle();
}

/// 모바일(폭 390) — 토픽 채팅 머리처럼 앱바에 RoomOptionsMenu.
Future<void> _pumpMobile(WidgetTester tester, Session session) async {
  _size(tester, const Size(390, 844));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('영업방'),
          actions: [
            RoomOptionsMenu(session: session, room: session.roomById('r1')!),
          ],
        ),
        body: const Center(child: Text('채팅 본문')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('열기', () {
    testWidgets('PC: 토픽 ⋯의 "공지"는 오른쪽 공지 패널로 열리고, 한 번 더 누르면 닫힌다', (
      tester,
    ) async {
      final server = _Server(announcements: _items);
      final session = _session(server, _room());
      await _pumpDesktop(tester, session);
      await _openFromRoomMenu(tester);

      expect(find.byType(AnnouncementsPanel), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(
        find.byKey(const ValueKey('side-panel-$announcementPanelKey')),
        findsOneWidget,
      );
      // 오른쪽에 붙는다.
      expect(
        tester.getTopLeft(find.byType(AnnouncementsPanel)).dx,
        greaterThan(800),
      );
      expect(
        find.descendant(
          of: find.byType(AnnouncementsPanel),
          matching: find.text('공지'),
        ),
        findsOneWidget,
      );
      expect(_plain(tester, const ValueKey('announcement-panel-room')), '영업방');
      expect(server.called('GET', '/rooms/r1/announcements'), hasLength(1));

      await _openFromRoomMenu(tester);
      expect(find.byType(AnnouncementsPanel), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('PC: 다른 패널이 열려 있으면 공지 패널로 바뀌고, 패널 ✕로 닫힌다', (tester) async {
      final session = _session(_Server(announcements: _items), _room());
      await _pumpDesktop(tester, session);
      await tester.tap(find.byTooltip('알림 센터'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('side-panel-notifications')), findsOne);

      await _openFromRoomMenu(tester);
      expect(
        find.byKey(const ValueKey('side-panel-notifications')),
        findsNothing,
      );
      expect(find.byType(AnnouncementsPanel), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('announcement-panel-close')));
      await _settle(tester);
      expect(find.byType(AnnouncementsPanel), findsNothing);
      await _finish(tester);
    });

    testWidgets('모바일: 같은 패널이 전체 화면 라우트로 열리고(앱바 없음) ✕로 닫힌다', (tester) async {
      final session = _session(_Server(announcements: _items), _room());
      await _pumpMobile(tester, session);
      await _openFromRoomMenu(tester);

      expect(find.byType(AnnouncementsPanel), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('채팅 본문'), findsNothing);
      expect(tester.getSize(find.byType(AnnouncementsPanel)).width, 390);
      expect(_plain(tester, const ValueKey('announcement-panel-room')), '영업방');

      await tester.tap(find.byKey(const ValueKey('announcement-panel-close')));
      await _settle(tester);
      expect(find.byType(AnnouncementsPanel), findsNothing);
      expect(find.text('채팅 본문'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('PC: 알림 센터의 안 읽은 공지(여럿)도 대화상자가 아니라 같은 공지 패널로 연다', (
      tester,
    ) async {
      final room = _room()
        ..hasUnreadAnnouncement = true
        ..unreadAnnouncementCount = 2;
      final session = _session(_Server(announcements: _items), room);
      await _pumpDesktop(tester, session);
      showUnreadAnnouncementPopup(
        tester.element(find.byType(RoomOptionsMenu)),
        session,
        room,
        hadUnreadAnnouncement: true,
      );
      await _settle(tester);
      expect(find.byType(Dialog), findsNothing);
      expect(
        find.byKey(const ValueKey('side-panel-$announcementPanelKey')),
        findsOneWidget,
      );
      // 내가 쓴 a2는 빼고 최근 것부터 두 개.
      for (final id in ['a3', 'a1']) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('announcement-tile-$id')),
            matching: find.text('안 읽음'),
          ),
          findsOneWidget,
          reason: id,
        );
      }
      expect(find.text('안 읽음'), findsNWidgets(2));
      await _finish(tester);
    });

    testWidgets('패널을 열면 방의 안 읽은 공지 표시를 지우고, 그만큼 "안 읽음"을 붙인다', (tester) async {
      final room = _room()
        ..hasUnreadAnnouncement = true
        ..unreadAnnouncementCount = 1;
      final session = _session(_Server(announcements: _items), room);
      await _pumpMobile(tester, session);
      await _openFromRoomMenu(tester);

      expect(room.hasUnreadAnnouncement, isFalse);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('announcement-tile-a3')),
          matching: find.text('안 읽음'),
        ),
        findsOneWidget,
      );
      expect(find.text('안 읽음'), findsOneWidget);
      await _finish(tester);
    });
  });

  group('목록', () {
    testWidgets('투표 패널과 같은 틀 — 공지 쓰기, 내린 공지 제외, N개의 공지와 흰 카드', (tester) async {
      final session = _session(_Server(announcements: _items), _room());
      await _pumpMobile(tester, session);
      await _openFromRoomMenu(tester);

      final write = find.byKey(const ValueKey('announcement-write'));
      expect(write, findsOneWidget);
      expect(
        find.descendant(of: write, matching: find.text('공지 쓰기')),
        findsOneWidget,
      );
      // 가로 전체(좌우 16 여백).
      expect(tester.getSize(write).width, 390 - 32);
      expect(find.text('내린 공지 제외'), findsOneWidget);
      expect(
        tester
            .widget<Switch>(
              find.byKey(const ValueKey('announcement-exclude-unpinned')),
            )
            .value,
        isFalse,
      );
      expect(
        _plain(tester, const ValueKey('announcement-list-count')),
        '3개의 공지',
      );
      // 카드 — 본문 앞부분(3줄 말줄임), 작성자 · 시각, 고정 표시는 고정된 공지에만, 댓글 수.
      final card = find.byKey(const ValueKey('announcement-tile-a3'));
      expect(
        find.descendant(of: card, matching: find.text('이번 주 금요일 회식 안내')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text('김철수 · 2026/09/30 PM 4:42'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('고정')),
        findsOneWidget,
      );
      expect(find.descendant(of: card, matching: find.text('2')), findsOne);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('announcement-tile-a2')),
          matching: find.text('고정'),
        ),
        findsNothing,
      );
      final text = tester.widget<Text>(
        find.descendant(
          of: card,
          matching: find.byKey(const ValueKey('announcement-tile-text')),
        ),
      );
      expect(text.maxLines, 3);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('"내린 공지 제외" — 스위치나 글자를 누르면 내린 공지가 빠지고 개수도 바뀐다', (tester) async {
      final session = _session(_Server(announcements: _items), _room());
      await _pumpMobile(tester, session);
      await _openFromRoomMenu(tester);

      await tester.tap(
        find.byKey(const ValueKey('announcement-exclude-unpinned-label')),
      );
      await tester.pump();
      expect(
        _plain(tester, const ValueKey('announcement-list-count')),
        '1개의 공지',
      );
      expect(find.byKey(const ValueKey('announcement-tile-a3')), findsOne);
      expect(find.byKey(const ValueKey('announcement-tile-a2')), findsNothing);
      expect(find.byKey(const ValueKey('announcement-tile-a1')), findsNothing);

      // 스위치로 다시 끈다.
      await tester.tap(
        find.byKey(const ValueKey('announcement-exclude-unpinned')),
      );
      await tester.pump();
      expect(
        _plain(tester, const ValueKey('announcement-list-count')),
        '3개의 공지',
      );
      expect(find.byKey(const ValueKey('announcement-tile-a1')), findsOne);
      await _finish(tester);
    });

    testWidgets('고정된 공지가 없으면 "내린 공지 제외"를 켰을 때 안내 문구', (tester) async {
      final session = _session(
        _Server(announcements: [_a('a1', pinned: false)]),
        _room(),
      );
      await _pumpMobile(tester, session);
      await _openFromRoomMenu(tester);
      await tester.tap(
        find.byKey(const ValueKey('announcement-exclude-unpinned-label')),
      );
      await tester.pump();
      expect(
        _plain(tester, const ValueKey('announcement-list-count')),
        '0개의 공지',
      );
      expect(find.text('채팅방에 고정된 공지가 없습니다.'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('공지 쓰기는 쓸 수 있는 사람에게만 — 관리자만 토픽을 만들 수 있는 팀의 일반 멤버는 없다', (
      tester,
    ) async {
      final session = _session(
        _Server(),
        _room(),
        team: Team(
          id: 't1',
          name: '영업팀',
          createdAt: DateTime(2026),
          topicCreationPolicy: TopicCreationPolicy.admin,
        ),
      );
      await _pumpMobile(tester, session);
      await _openFromRoomMenu(tester);
      expect(find.byKey(const ValueKey('announcement-write')), findsNothing);
      expect(find.text('내린 공지 제외'), findsOneWidget);
      expect(find.text('등록된 공지가 없습니다.'), findsOneWidget);
      await _finish(tester);
    });
  });

  group('상세', () {
    testWidgets('공지 쓰기 창에서 서식을 입힌 공지는 카드와 상세에서 서식대로(굵게) 보인다', (tester) async {
      final formatted = {
        ..._a('a9', text: '굵은 공지 본문'),
        // "굵은"(0~2)만 굵게 — Fmt.bold = 1.
        'textFormat': [
          {'s': 0, 'e': 2, 'f': 1},
        ],
      };
      final session = _session(
        _Server(announcements: [formatted, ..._items]),
        _room(),
      );
      await _pumpDesktop(tester, session);
      await _openFromRoomMenu(tester);

      final tileText = find.descendant(
        of: find.byKey(const ValueKey('announcement-tile-a9')),
        matching: find.byKey(const ValueKey('announcement-tile-text')),
      );
      final card = tester.widget<FormattedText>(tileText);
      expect(card.format, hasLength(1));
      expect(card.maxLines, 3);
      // 서식 없는 공지는 예전처럼 평문 Text.
      expect(
        tester.widget(
          find.descendant(
            of: find.byKey(const ValueKey('announcement-tile-a3')),
            matching: find.byKey(const ValueKey('announcement-tile-text')),
          ),
        ),
        isA<Text>(),
      );

      await tester.tap(find.byKey(const ValueKey('announcement-tile-a9')));
      await _settle(tester);
      final detail = tester.widget<FormattedText>(
        find.byKey(const ValueKey('announcement-detail-text')),
      );
      expect(detail.text, '굵은 공지 본문');
      expect(detail.format!.single.flags, 1);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('PC: 카드를 누르면 패널 안에 상세가 열리고 ←로 목록에 돌아온다, ✕는 패널을 닫는다', (
      tester,
    ) async {
      final session = _session(_Server(announcements: _items), _room());
      await _pumpDesktop(tester, session);
      await _openFromRoomMenu(tester);

      await tester.tap(find.byKey(const ValueKey('announcement-tile-a3')));
      await _settle(tester);
      final detail = find.byType(AnnouncementDetailScreen);
      expect(detail, findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      // 패널 안 — 패널 칸과 같은 자리·폭.
      final panelRect = tester.getRect(
        find.byKey(const ValueKey('side-panel-$announcementPanelKey')),
      );
      expect(tester.getRect(detail), panelRect);
      expect(find.byKey(const ValueKey('announcement-detail-back')), findsOne);
      expect(find.byKey(const ValueKey('announcement-detail-close')), findsOne);
      // ←는 왼쪽 위.
      final back = tester.getCenter(
        find.byKey(const ValueKey('announcement-detail-back')),
      );
      expect(back.dx, lessThan(panelRect.left + 40));
      expect(back.dy, lessThan(panelRect.top + 50));

      await tester.tap(find.byKey(const ValueKey('announcement-detail-back')));
      await _settle(tester);
      expect(find.byType(AnnouncementDetailScreen), findsNothing);
      expect(find.byKey(const ValueKey('announcement-tile-a3')), findsOne);

      await tester.tap(find.byKey(const ValueKey('announcement-tile-a2')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('announcement-detail-close')));
      await _settle(tester);
      expect(find.byType(AnnouncementsPanel), findsNothing);
      expect(find.byType(AnnouncementDetailScreen), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('모바일: 상세는 전체 화면(← 공지, ✕ 없음)이고 ←로 목록에 돌아온다', (tester) async {
      final session = _session(_Server(announcements: _items), _room());
      await _pumpMobile(tester, session);
      await _openFromRoomMenu(tester);
      await tester.tap(find.byKey(const ValueKey('announcement-tile-a3')));
      await _settle(tester);

      expect(find.byType(AnnouncementDetailScreen), findsOneWidget);
      expect(find.byType(AnnouncementsPanel), findsNothing); // 아래 라우트(가려짐)
      expect(find.byKey(const ValueKey('announcement-detail-back')), findsOne);
      expect(
        find.byKey(const ValueKey('announcement-detail-close')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('announcement-detail-back')));
      await _settle(tester);
      expect(find.byType(AnnouncementDetailScreen), findsNothing);
      expect(find.byType(AnnouncementsPanel), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('⋯는 토픽 ⋯와 같은 간결한 메뉴 — 아이콘 + 글자, 묶음 사이 구분선', (tester) async {
      final session = _session(_Server(announcements: _items), _room());
      await _pumpDesktop(tester, session);
      await _openFromRoomMenu(tester);
      await tester.tap(
        find.byKey(const ValueKey('announcement-tile-a2')),
      ); // 내 공지
      await _settle(tester);

      final more = find.byKey(const ValueKey('announcement-detail-more'));
      final button = tester.widget(more) as PopupMenuButton;
      expect(button.shape, CompactMenu.shape);
      expect(button.menuPadding, CompactMenu.menuPadding);
      expect(button.constraints, CompactMenu.constraints);
      expect(button.color, Colors.white);
      expect(button.useRootNavigator, isTrue);

      await tester.tap(more);
      await tester.pumpAndSettle();
      for (final (label, icon) in [
        ('수정하기', Icons.edit_outlined),
        ('현재 채팅방에 공유하기', Icons.forward_outlined),
        ('삭제하기', Icons.delete_outline),
      ]) {
        final item = find.ancestor(
          of: find.text(label),
          matching: _popupMenuItem,
        );
        expect(item, findsOneWidget, reason: label);
        expect(
          find.descendant(of: item, matching: find.byIcon(icon)),
          findsOneWidget,
          reason: label,
        );
        expect(
          (tester.widget(item) as PopupMenuItem).height,
          CompactMenu.itemHeight,
        );
        final text = tester.widget<Text>(find.text(label));
        expect(text.style?.fontSize, CompactMenu.textStyle.fontSize);
      }
      // 내린 공지에는 "공지 내리기"가 없다.
      expect(find.text('공지 내리기'), findsNothing);
      expect(find.byType(PopupMenuDivider), findsNWidgets(2));
      await _finish(tester);
    });

    testWidgets('패널 안 상세에서 삭제하면 목록으로 돌아오고 그 카드가 빠진다', (tester) async {
      final server = _Server(announcements: _items);
      final session = _session(server, _room());
      await _pumpDesktop(tester, session);
      await _openFromRoomMenu(tester);
      await tester.tap(find.byKey(const ValueKey('announcement-tile-a2')));
      await _settle(tester);

      await tester.tap(find.byKey(const ValueKey('announcement-detail-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('삭제하기'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '삭제'));
      await _settle(tester);

      expect(server.called('DELETE', '/announcements/a2'), hasLength(1));
      expect(find.byType(AnnouncementDetailScreen), findsNothing);
      expect(find.byType(AnnouncementsPanel), findsOneWidget);
      expect(find.byKey(const ValueKey('announcement-tile-a2')), findsNothing);
      expect(
        _plain(tester, const ValueKey('announcement-list-count')),
        '2개의 공지',
      );
      await _finish(tester);
    });

    testWidgets('패널 안 상세에서 공지를 내리면 ←로 돌아온 목록의 카드도 "고정"이 빠진다', (tester) async {
      final session = _session(
        _Server(announcements: [_a('a9', authorId: 'me')]),
        _room(),
      );
      await _pumpDesktop(tester, session);
      await _openFromRoomMenu(tester);
      await tester.tap(find.byKey(const ValueKey('announcement-tile-a9')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('announcement-detail-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('공지 내리기'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '내리기'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('announcement-detail-back')));
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('announcement-tile-a9')),
          matching: find.text('고정'),
        ),
        findsNothing,
      );
      await _finish(tester);
    });
  });

  group('정렬', () {
    testWidgets('`내린 공지 제외` 줄 오른쪽의 작은 회색 `최신 순` — 메뉴에서 `과거 순`을 고르면 바로 뒤집힌다', (
      tester,
    ) async {
      final session = _session(_Server(announcements: _items), _room());
      await _pumpMobile(tester, session);
      await _openFromRoomMenu(tester);

      final sort = find.byKey(const ValueKey('announcement-sort'));
      expect(sort, findsOneWidget);
      expect(
        find.descendant(of: sort, matching: find.text('최신 순')),
        findsOneWidget,
      );
      // 스위치와 같은 줄, 오른쪽 끝.
      final switchRect = tester.getRect(
        find.byKey(const ValueKey('announcement-exclude-unpinned')),
      );
      final sortRect = tester.getRect(sort);
      expect((sortRect.center.dy - switchRect.center.dy).abs(), lessThan(6));
      expect(sortRect.right, greaterThan(390 - 20));
      // 투표·할 일 패널의 정렬과 같은 작은 회색 글자.
      final label = tester.widget<Text>(
        find.descendant(of: sort, matching: find.text('최신 순')),
      );
      final theme = Theme.of(tester.element(sort));
      expect(label.style?.color, theme.hintColor);
      expect(label.style?.fontSize, theme.textTheme.labelMedium?.fontSize);
      expect(_tileOrder(tester), ['a3', 'a2', 'a1']);

      await tester.tap(find.byKey(const ValueKey('panel-sort')));
      await tester.pump();
      // 바로 뜨는 메뉴(MenuAnchor) — 지금 값에 체크.
      expect(find.byType(MenuItemButton), findsNWidgets(2));
      await tester.tap(find.text('과거 순'));
      await tester.pump();
      await tester.pump(); // 고른 값은 메뉴가 닫힌 다음 프레임에 들어온다(MenuItemButton).
      expect(_tileOrder(tester), ['a1', 'a2', 'a3']);
      expect(
        find.descendant(of: sort, matching: find.text('과거 순')),
        findsOneWidget,
      );
      // 개수와 `내린 공지 제외`는 그대로 함께 걸린다.
      await tester.tap(
        find.byKey(const ValueKey('announcement-exclude-unpinned-label')),
      );
      await tester.pump();
      expect(_tileOrder(tester), ['a3']);
      await tester.tap(
        find.byKey(const ValueKey('announcement-exclude-unpinned-label')),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('panel-sort')));
      await tester.pump();
      await tester.tap(find.text('최신 순').last);
      await tester.pump();
      await tester.pump();
      expect(_tileOrder(tester), ['a3', 'a2', 'a1']);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });
  });

  group('카드 ⋯', () {
    testWidgets('내 공지 카드에만 오른쪽 위 ⋯ — 상세의 ⋯와 같은 메뉴, 눌러도 카드는 안 열린다', (
      tester,
    ) async {
      final session = _session(
        _Server(
          announcements: [
            _a('a9', text: '내가 고정한 공지', authorId: 'me'),
            ..._items.skip(1),
          ],
        ),
        _room(),
      );
      await _pumpDesktop(tester, session);
      await _openFromRoomMenu(tester);

      Finder moreOf(String id) => find.descendant(
        of: find.byKey(ValueKey('announcement-tile-$id')),
        matching: find.byKey(const ValueKey('announcement-tile-more')),
      );
      // 남의 공지(a1)에는 할 수 있는 게 없어 ⋯가 없다.
      expect(moreOf('a1'), findsNothing);
      expect(moreOf('a2'), findsOneWidget);
      expect(moreOf('a9'), findsOneWidget);
      // 오른쪽 위.
      final card = tester.getRect(
        find.byKey(const ValueKey('announcement-tile-a9')),
      );
      final more = tester.getRect(moreOf('a9'));
      expect(card.right - more.right, lessThan(16));
      expect(more.top - card.top, lessThan(16));
      final button = tester.widget<PopupMenuButton>(moreOf('a9'));
      expect(button.shape, CompactMenu.shape);
      expect(button.useRootNavigator, isTrue);

      // 고정된 내 공지 — 수정하기·공지 내리기 / 현재 채팅방에 공유하기 / 삭제하기.
      await tester.tap(moreOf('a9'));
      await tester.pumpAndSettle();
      expect(find.byType(AnnouncementDetailScreen), findsNothing);
      for (final label in ['수정하기', '공지 내리기', '현재 채팅방에 공유하기', '삭제하기']) {
        expect(
          find.ancestor(of: find.text(label), matching: _popupMenuItem),
          findsOneWidget,
          reason: label,
        );
      }
      expect(find.byType(PopupMenuDivider), findsNWidgets(2));
      await tester.tapAt(const Offset(5, 5)); // 메뉴 닫기
      await tester.pumpAndSettle();

      // 내린 내 공지 — "공지 내리기"는 없다(상세와 같다).
      await tester.tap(moreOf('a2'));
      await tester.pumpAndSettle();
      expect(find.text('공지 내리기'), findsNothing);
      expect(find.text('수정하기'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(AnnouncementDetailScreen), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('카드 ⋯로 공지 내리기·삭제 — 상세와 같은 확인 창, 카드에 바로 반영', (tester) async {
      final server = _Server(
        announcements: [
          _a('a9', text: '내가 고정한 공지', authorId: 'me'),
          ..._items.skip(1),
        ],
      );
      final session = _session(server, _room());
      await _pumpDesktop(tester, session);
      await _openFromRoomMenu(tester);
      Finder moreOf(String id) => find.descendant(
        of: find.byKey(ValueKey('announcement-tile-$id')),
        matching: find.byKey(const ValueKey('announcement-tile-more')),
      );

      await tester.tap(moreOf('a9'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('공지 내리기'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '내리기'));
      await _settle(tester);
      expect(server.called('POST', '/announcements/a9/unpin'), hasLength(1));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('announcement-tile-a9')),
          matching: find.text('고정'),
        ),
        findsNothing,
      );

      await tester.tap(moreOf('a2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('삭제하기'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '삭제'));
      await _settle(tester);
      expect(server.called('DELETE', '/announcements/a2'), hasLength(1));
      expect(find.byKey(const ValueKey('announcement-tile-a2')), findsNothing);
      expect(
        _plain(tester, const ValueKey('announcement-list-count')),
        '2개의 공지',
      );
      expect(find.byType(AnnouncementDetailScreen), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });
  });

  group('호버', () {
    for (final dark in [false, true]) {
      testWidgets(
        '${dark ? '어두운' : '밝은'} 테마: 카드에 마우스를 올리면 바탕은 그대로, 둥근 테두리만 옅은 강조색',
        (tester) async {
          final session = _session(_Server(announcements: _items), _room());
          _size(tester, const Size(390, 844));
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
              home: Scaffold(
                body: AnnouncementsPanel(session: session, room: _room()),
              ),
            ),
          );
          await _settle(tester);
          final card = find.byKey(const ValueKey('announcement-tile-a1'));
          final scheme = Theme.of(tester.element(card)).colorScheme;
          Material material() => tester.widget<Material>(
            find.descendant(of: card, matching: find.byType(Material)).first,
          );
          BorderSide side() =>
              (material().shape! as RoundedRectangleBorder).side;
          final ink = tester.widget<InkWell>(
            find.descendant(of: card, matching: find.byType(InkWell)).first,
          );
          // 올렸을 때 덮개 색은 없다(회색·강조색 덮개 모두) — 누를 때만 옅은 강조색.
          expect(ink.hoverColor, Colors.transparent);
          expect(ink.highlightColor, scheme.primary.withValues(alpha: 0.08));
          expect(ink.splashColor, scheme.primary.withValues(alpha: 0.08));
          final base = dark ? scheme.surfaceContainerHigh : scheme.surface;
          expect(material().color, base);
          expect(side(), BorderSide.none);

          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: tester.getCenter(card));
          addTearDown(mouse.removePointer);
          await tester.pump(const Duration(milliseconds: 300));
          // 바탕은 그대로, 테두리만 강조색 0.55 · 1.5.
          expect(material().color, base);
          expect(side().color, scheme.primary.withValues(alpha: 0.55));
          expect(side().width, 1.5);
          // 다른 카드는 그대로.
          final other = tester.widget<Material>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('announcement-tile-a2')),
                  matching: find.byType(Material),
                )
                .first,
          );
          expect(
            (other.shape! as RoundedRectangleBorder).side,
            BorderSide.none,
          );

          // 마우스가 나가면 테두리도 사라진다.
          await mouse.moveTo(const Offset(5, 5));
          await tester.pump(const Duration(milliseconds: 300));
          expect(side(), BorderSide.none);
          expect(tester.takeException(), isNull);
          await _finish(tester);
        },
      );
    }
  });

  group('공지바에서 열기', () {
    Room roomWithBanner() => _room()
      ..latestAnnouncement = Announcement.fromJson(
        _a('a3', text: '이번 주 금요일 회식 안내', commentCount: 2),
      );

    testWidgets('PC: 공지바를 누르면 공지 패널이 열리고 패널 안에 그 공지의 상세 — ←는 목록, 대화상자는 없다', (
      tester,
    ) async {
      final room = roomWithBanner()..hasUnreadAnnouncement = true;
      final server = _Server(announcements: _items);
      final session = _session(server, room);
      await _pumpDesktop(tester, session);

      await tester.tap(find.byKey(const ValueKey('announcement-text')));
      await _settle(tester);
      expect(find.byType(Dialog), findsNothing);
      final panel = find.byKey(
        const ValueKey('side-panel-$announcementPanelKey'),
      );
      expect(panel, findsOneWidget);
      final detail = find.byType(AnnouncementDetailScreen);
      expect(detail, findsOneWidget);
      expect(tester.getRect(detail), tester.getRect(panel));
      expect(
        tester.widget<AnnouncementDetailScreen>(detail).announcement.id,
        'a3',
      );
      expect(room.hasUnreadAnnouncement, isFalse);
      expect(server.called('GET', '/rooms/r1/announcements'), hasLength(1));

      await tester.tap(find.byKey(const ValueKey('announcement-detail-back')));
      await _settle(tester);
      expect(find.byType(AnnouncementDetailScreen), findsNothing);
      expect(find.byKey(const ValueKey('announcement-tile-a3')), findsOne);
      // 상세로 이미 본 공지라 "안 읽음" 표시가 없다.
      expect(find.text('안 읽음'), findsNothing);

      // 패널이 열린 채로 공지바를 또 누르면 — 닫히지 않고 그 안에 상세만 다시 뜬다(목록을 다시 받지도 않는다).
      await tester.tap(find.byKey(const ValueKey('announcement-text')));
      await _settle(tester);
      expect(panel, findsOneWidget);
      expect(find.byType(AnnouncementDetailScreen), findsOneWidget);
      expect(server.called('GET', '/rooms/r1/announcements'), hasLength(1));
      // 이미 상세가 떠 있는 채로 또 눌러도 상세는 하나뿐이다.
      await tester.tap(find.byKey(const ValueKey('announcement-text')));
      await _settle(tester);
      expect(find.byType(AnnouncementDetailScreen), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('announcement-detail-back')));
      await _settle(tester);
      expect(find.byType(AnnouncementDetailScreen), findsNothing);
      expect(find.byType(AnnouncementsPanel), findsOneWidget);

      // 토픽 ⋯의 "공지"는 예전처럼 토글(닫기)이다.
      await _openFromRoomMenu(tester);
      expect(find.byType(AnnouncementsPanel), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('PC: 다른 패널이 열려 있으면 공지 패널로 바뀌며 상세가 뜬다', (tester) async {
      final session = _session(
        _Server(announcements: _items),
        roomWithBanner(),
      );
      await _pumpDesktop(tester, session);
      await tester.tap(find.byTooltip('알림 센터'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('announcement-text')));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('side-panel-notifications')),
        findsNothing,
      );
      expect(find.byType(AnnouncementsPanel), findsOneWidget);
      expect(find.byType(AnnouncementDetailScreen), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('상세에서 단 댓글은 ←로 돌아온 목록 카드의 댓글 수에도 반영된다', (tester) async {
      final room = roomWithBanner();
      final session = _session(_Server(announcements: _items), room);
      await _pumpDesktop(tester, session);
      await tester.tap(find.byKey(const ValueKey('announcement-text')));
      await _settle(tester);
      // 상세가 쓰는 공지바의 공지 객체에 댓글이 하나 늘었다(상세가 댓글을 달면 이렇게 올린다).
      room.latestAnnouncement!.commentCount += 1;
      await tester.tap(find.byKey(const ValueKey('announcement-detail-back')));
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('announcement-tile-a3')),
          matching: find.text('3'),
        ),
        findsOneWidget,
      );
      await _finish(tester);
    });
  });

  test('공지 패널이 등록돼 있다', () {
    expect(sidePanelSpecFor(announcementPanelKey)?.title, '공지');
  });
}
