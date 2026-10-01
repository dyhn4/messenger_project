import 'dart:convert';

import 'package:client/models/announcement.dart';
import 'package:client/models/app_notification.dart' show BoardNotifyLevel;
import 'package:client/models/project.dart' show ProjectNotification;
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/project/project_notifications.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_controller.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/notification_settings_dialog.dart';
import 'package:client/widgets/notifications_panel.dart';
import 'package:client/widgets/unread_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 알림 센터 화면 — 5개 탭(전체·멘션·메시지·보드·공지·프로젝트), 기본 탭 규칙, 탭별 배지, 모두 읽음,
/// 안 읽은 것만, 눌러서 이동+읽음, 무한 스크롤, 설정, 그리고 모바일 폭(360)의 전체 화면·가로 스크롤 탭줄.

class _QuietNotifications extends NotificationService {
  @override
  Future<void> cancelForRoom(String roomId) async {}
}

final _now = DateTime.now();

Map<String, dynamic> _n(
  String id, {
  String kind = 'mention',
  int minutesAgo = 0,
  bool read = false,
  String roomId = 'r1',
  String roomName = '공지방',
  String teamId = 't1',
  String actor = '김철수',
  String preview = '확인 부탁드려요',
  String? messageId,
}) {
  final t = _now.subtract(Duration(minutes: minutesAgo));
  return {
    'id': id,
    'kind': kind,
    'teamId': teamId,
    'teamName': teamId == 't1' ? '영업팀' : '개발팀',
    'roomId': roomId,
    'roomName': roomName,
    'messageId': messageId ?? 'm-$id',
    'commentId': null,
    'actorId': 'u2',
    'actorName': actor,
    'preview': preview,
    'createdAt': t.millisecondsSinceEpoch,
    'readAt': read ? t.millisecondsSinceEpoch : null,
    'roomType': 'topic',
  };
}

Map<String, dynamic> _p(String id, {int minutesAgo = 0, bool read = false}) => {
  'id': id,
  'projectId': 'p1',
  'projectName': '잔디톡',
  'projectColor': '#5B8DEF',
  'taskId': 'task-$id',
  'kind': 'assigned',
  'title': '잔디톡 · TA-$id',
  'body': '업무를 배정했습니다 $id',
  'createdAt': _now
      .subtract(Duration(minutes: minutesAgo))
      .millisecondsSinceEpoch,
  'read': read,
};

/// 가짜 서버 — 알림 목록(kind·before·limit·unreadOnly), 안 읽음 개수, 읽음 처리, 설정, 프로젝트 알림함.
class _Server {
  final items = <Map<String, dynamic>>[];
  final projectItems = <Map<String, dynamic>>[];
  var settings = <String, dynamic>{
    'mentionAll': true,
    'boardLevel': 'important',
  };
  final requests = <http.Request>[];

  bool _isMention(Map<String, dynamic> n) =>
      n['kind'] == 'mention' || n['kind'] == 'mention_all';
  bool _isBoard(Map<String, dynamic> n) =>
      (n['kind'] as String).startsWith('board_');

  Map<String, dynamic> get counts => {
    'mention': items.where((n) => _isMention(n) && n['readAt'] == null).length,
    'board': items.where((n) => _isBoard(n) && n['readAt'] == null).length,
  };

  http.Response _ok(Object? body) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    200,
    headers: const {'content-type': 'application/json'},
  );

  late final client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    final q = request.url.queryParameters;
    if (request.method == 'GET' && path == '/api/notifications') {
      final kind = q['kind'] ?? 'all';
      final before = int.tryParse(q['before'] ?? '');
      final limit = int.tryParse(q['limit'] ?? '') ?? 30;
      final unreadOnly = q['unreadOnly'] == 'true';
      final list =
          [
            for (final n in items)
              if ((kind == 'all' ||
                      (kind == 'mention' && _isMention(n)) ||
                      (kind == 'board' && _isBoard(n))) &&
                  (before == null || (n['createdAt'] as int) < before) &&
                  (!unreadOnly || n['readAt'] == null))
                n,
          ]..sort(
            (a, b) => (b['createdAt'] as int).compareTo(a['createdAt'] as int),
          );
      return _ok({
        'items': list.take(limit).toList(),
        'hasMore': list.length > limit,
      });
    }
    if (request.method == 'GET' && path == '/api/notifications/unread-counts') {
      return _ok(counts);
    }
    if (request.method == 'POST' && path == '/api/notifications/read') {
      final body = jsonDecode(request.body) as Map;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final n in items) {
        final hit =
            (body['ids'] is List && (body['ids'] as List).contains(n['id'])) ||
            (body['kind'] == 'mention' && _isMention(n)) ||
            (body['kind'] == 'board' && _isBoard(n));
        if (hit) n['readAt'] ??= now;
      }
      return _ok({'ok': true});
    }
    if (path == '/api/notification-settings') {
      if (request.method == 'PATCH') {
        settings = {
          ...settings,
          ...jsonDecode(request.body) as Map<String, dynamic>,
        };
      }
      return _ok(settings);
    }
    if (request.method == 'GET' && path == '/api/project-notifications') {
      return _ok({
        'items': projectItems,
        'unreadCount': projectItems.where((n) => n['read'] != true).length,
      });
    }
    if (request.method == 'POST' && path == '/api/project-notifications/read') {
      final body = jsonDecode(request.body) as Map;
      for (final n in projectItems) {
        if (body['ids'] == null || (body['ids'] as List).contains(n['id'])) {
          n['read'] = true;
        }
      }
      return _ok({
        'unreadCount': projectItems.where((n) => n['read'] != true).length,
      });
    }
    return _ok(<Object>[]);
  });

  List<http.Request> called(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();
}

Room _room(
  String id,
  String name, {
  int unread = 0,
  int mentions = 0,
  bool announcement = false,
  String teamId = 't1',
  String? preview,
  String? sender,
  RoomType type = RoomType.topic,
  TopicViewMode viewMode = TopicViewMode.chat,
  int activityMinutesAgo = 0,
}) => Room(
  id: id,
  teamId: teamId,
  type: type,
  viewMode: viewMode,
  name: name,
  members: const [],
  createdAt: DateTime(2026),
  lastRead: {},
  unreadCount: unread,
  unreadMentionCount: mentions,
  lastMessagePreview: preview,
  lastMessageSenderName: sender,
  lastActivityAt: _now.subtract(Duration(minutes: activityMinutesAgo)),
  hasUnreadAnnouncement: announcement,
  unreadAnnouncementCount: announcement ? 1 : 0,
  latestAnnouncement: announcement
      ? Announcement(
          id: 'a-$id',
          roomId: id,
          authorName: '팀장',
          text: '월간 회의 안내',
          createdAt: _now.subtract(Duration(minutes: activityMinutesAgo + 1)),
        )
      : null,
);

Session _session(_Server server, {List<Room>? rooms}) {
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
  final sales = Team(id: 't1', name: '영업팀', createdAt: DateTime(2026));
  final dev = Team(id: 't2', name: '개발팀', createdAt: DateTime(2026));
  session.teams.addAll([sales, dev]);
  session.currentTeam = sales;
  session.rooms.addAll(
    rooms ?? [_room('r1', '공지방'), _room('r2', '개발 잡담', teamId: 't2')],
  );
  return session;
}

class _Opened {
  Room? room;
  String? messageId;
  bool? popup;
  ProjectNotification? project;
}

Widget _host(
  Session session,
  _Opened opened, {
  double width = 420,
  NotificationTab? initialTab,
}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topRight,
      child: SizedBox(
        width: width,
        height: 640,
        child: NotificationsPanel(
          session: session,
          initialTab: initialTab,
          onClose: () {},
          onSelectRoom: (room, {messageId, announcementPopup = true}) {
            opened
              ..room = room
              ..messageId = messageId
              ..popup = announcementPopup;
          },
          onOpenProject: (n) => opened.project = n,
        ),
      ),
    ),
  ),
);

void _size(WidgetTester tester, [Size size = const Size(1000, 800)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 두 번째 줄이 굵은 앞부분 + 본문으로 이어진 Text.rich라서 이어 붙인 글자로 찾는다.
Finder _rich(String text) => find.text(text, findRichText: true);

Finder _tab(NotificationTab t) => find.byKey(ValueKey('notif-tab-${t.name}'));
Finder _badge(String label) => find.byKey(ValueKey('notif-tab-badge-$label'));

Future<void> _pump(
  WidgetTester tester,
  Session session, {
  _Opened? opened,
  double width = 420,
  NotificationTab? initialTab,
  bool loadCounts = true,
}) async {
  _size(tester);
  if (loadCounts) {
    await tester.runAsync(session.notificationCenter.refreshCounts);
  }
  await tester.pumpWidget(
    _host(session, opened ?? _Opened(), width: width, initialTab: initialTab),
  );
  await tester.pumpAndSettle();
}

/// 받은 요청이 모두 끝나도록 실제 비동기 작업을 흘려보낸다(가짜 HTTP는 비동기다).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  group('탭 다섯 개와 기본 탭', () {
    testWidgets('전체 · 멘션 · 메시지 · 보드·공지 · 프로젝트 — 안 읽은 멘션이 있으면 멘션 탭으로 열린다', (
      tester,
    ) async {
      final server = _Server()
        ..items.addAll([
          _n('m1', minutesAgo: 5),
          _n('m2', minutesAgo: 6, read: true),
        ]);
      final session = _session(server);
      await _pump(tester, session);
      await _settle(tester);
      for (final t in NotificationTab.values) {
        expect(_tab(t), findsOneWidget, reason: t.label);
      }
      // 멘션 탭이 선택돼 있고 그 목록이 떠 있다.
      expect(
        tester.widget<TabBar>(find.byType(TabBar)).controller!.index,
        NotificationTab.mention.index,
      );
      expect(_rich('김철수: 확인 부탁드려요'), findsNWidgets(2));
      // 멘션 탭만 요청했다(안 연 탭은 받지 않는다).
      expect(
        server
            .called('GET', '/api/notifications')
            .map((r) => r.url.queryParameters['kind']),
        ['mention'],
      );
    });

    testWidgets('안 읽은 멘션이 없으면 전체 탭으로 열린다', (tester) async {
      final server = _Server()..items.add(_n('m-read', read: true));
      final session = _session(server);
      await _pump(tester, session);
      await _settle(tester);
      expect(
        tester.widget<TabBar>(find.byType(TabBar)).controller!.index,
        NotificationTab.all.index,
      );
    });

    testWidgets('탭마다 안 읽음 배지 — 멘션·보드(+공지)·안 읽은 대화·프로젝트·전체', (tester) async {
      final server = _Server()
        ..items.addAll([
          _n('m1'),
          _n('m2', minutesAgo: 1),
          _n('b1', kind: 'board_post', minutesAgo: 2),
        ]);
      final session = _session(
        server,
        rooms: [
          _room('r1', '공지방', unread: 3, announcement: true),
          _room('r2', '개발 잡담', unread: 1),
        ],
      )..projectUnread = 4;
      await _pump(tester, session);
      await _settle(tester);
      Text badgeText(String label) => tester.widget<Text>(
        find.descendant(of: _badge(label), matching: find.byType(Text)),
      );
      expect(badgeText('멘션').data, '2');
      // 보드 1 + 안 읽은 공지 1.
      expect(badgeText('보드·공지').data, '2');
      expect(badgeText('메시지').data, '2');
      expect(badgeText('프로젝트').data, '4');
      // 전체: 멘션 2 + 보드·공지 2 + 메시지 있는 방 2 + 프로젝트 4.
      expect(badgeText('전체').data, '10');
    });

    testWidgets('initialTab을 주면 그 탭으로 연다(프로젝트 알림함에서 넘어올 때)', (tester) async {
      final server = _Server()..projectItems.add(_p('p1'));
      final session = _session(server);
      await _pump(tester, session, initialTab: NotificationTab.project);
      await _settle(tester);
      expect(
        tester.widget<TabBar>(find.byType(TabBar)).controller!.index,
        NotificationTab.project.index,
      );
      expect(find.text('업무를 배정했습니다 p1'), findsOneWidget);
    });
  });

  group('메시지 탭(예전 "안 읽은 대화") — 예전 알림 센터 그대로', () {
    testWidgets('안 읽은 방(여러 팀)을 마지막 활동순으로 팀 이름과 함께 보여 주고, 누르면 그 방으로', (
      tester,
    ) async {
      final server = _Server();
      final session = _session(
        server,
        rooms: [
          _room(
            'r1',
            '공지방',
            unread: 3,
            preview: '회의 10분 전',
            activityMinutesAgo: 30,
          ),
          _room(
            'r2',
            '개발 잡담',
            unread: 1,
            teamId: 't2',
            preview: '점심 뭐 먹지',
            activityMinutesAgo: 5,
          ),
          _room('r3', '다 읽은 방'),
        ],
      );
      final opened = _Opened();
      await _pump(
        tester,
        session,
        opened: opened,
        initialTab: NotificationTab.unreadChats,
      );
      await _settle(tester);
      expect(find.text('개발 잡담'), findsOneWidget);
      expect(find.text('공지방'), findsOneWidget);
      expect(find.text('다 읽은 방'), findsNothing);
      expect(find.text('점심 뭐 먹지'), findsOneWidget);
      // 최근 활동이 앞.
      expect(
        tester.getTopLeft(find.text('개발 잡담')).dy,
        lessThan(tester.getTopLeft(find.text('공지방')).dy),
      );
      // 팀 칸 — 다른 팀 이름이 보인다.
      expect(find.text('개발팀'), findsOneWidget);
      expect(find.byType(UnreadBadge), findsNWidgets(2));

      await tester.tap(find.text('개발 잡담'));
      await tester.pump();
      expect(opened.room!.id, 'r2');
      expect(opened.messageId, isNull);
      // 공지 팝업은 이 줄이 예전처럼 띄운다.
      expect(opened.popup, isTrue);
      // 서버 알림은 이 탭에서 받지 않는다.
      expect(server.called('GET', '/api/notifications'), isEmpty);
    });

    testWidgets('안 읽은 공지만 있는 방도 뜨고, 없으면 안내 문구', (tester) async {
      final server = _Server();
      final session = _session(
        server,
        rooms: [_room('r1', '공지방', announcement: true)],
      );
      await _pump(tester, session, initialTab: NotificationTab.unreadChats);
      expect(find.text('공지방'), findsOneWidget);
      expect(find.text('월간 회의 안내'), findsOneWidget);

      final empty = _session(_Server(), rooms: [_room('r1', '공지방')]);
      await _pump(tester, empty, initialTab: NotificationTab.unreadChats);
      expect(find.text('안 읽은 메시지가 없습니다.'), findsOneWidget);
    });

    testWidgets('방 줄에 안 읽은 멘션이 있으면 "@" 표시', (tester) async {
      final session = _session(
        _Server(),
        rooms: [_room('r1', '공지방', unread: 2, mentions: 1)],
      );
      await _pump(tester, session, initialTab: NotificationTab.unreadChats);
      expect(find.byType(MentionMarker), findsOneWidget);
    });

    testWidgets('탭 아래에 "안 읽은 것만" 칩은 없고 "모두 읽음"은 확인을 받은 뒤 방을 읽음으로 돌린다', (
      tester,
    ) async {
      final session = _session(
        _Server(),
        rooms: [_room('r1', '공지방', unread: 2, announcement: true)],
      );
      await _pump(tester, session, initialTab: NotificationTab.unreadChats);
      expect(find.byKey(const ValueKey('notif-unread-only')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('notif-read-all')));
      await tester.pumpAndSettle();
      expect(find.text('안 읽은 대화 1개를 읽음으로 표시할까요?'), findsOneWidget);
      await tester.tap(find.text('읽음으로 표시'));
      await tester.pumpAndSettle();
      expect(session.rooms.first.unreadCount, 0);
      expect(session.rooms.first.hasUnreadAnnouncement, isFalse);
      expect(find.text('안 읽은 메시지가 없습니다.'), findsOneWidget);
    });
  });

  group('멘션·보드·공지·전체·프로젝트 탭', () {
    testWidgets('멘션 탭 — 멘션·@all을 보여 주고 누르면 그 방의 그 메시지로 이동하며 읽음 처리', (
      tester,
    ) async {
      final server = _Server()
        ..items.addAll([
          _n('m1', minutesAgo: 1, messageId: 'msg-77', preview: '@나 자료 확인'),
          _n(
            'mall',
            kind: 'mention_all',
            minutesAgo: 2,
            preview: '@all 회의',
            roomId: 'r2',
            roomName: '개발 잡담',
            teamId: 't2',
          ),
        ]);
      final session = _session(server);
      final opened = _Opened();
      await _pump(tester, session, opened: opened);
      await _settle(tester);
      expect(_rich('김철수: @나 자료 확인'), findsOneWidget);
      expect(_rich('김철수: @all 회의'), findsOneWidget);
      expect(find.text('개발팀'), findsOneWidget); // 팀을 가로질러 — 팀 이름이 붙는다.
      // 개인 멘션도 @all도 같은 @ 아이콘이다.
      expect(find.byIcon(Icons.alternate_email), findsNWidgets(2));
      expect(find.byIcon(Icons.groups_outlined), findsNothing);

      await tester.tap(_rich('김철수: @나 자료 확인'));
      await _settle(tester);
      expect(opened.room!.id, 'r1');
      expect(opened.messageId, 'msg-77');
      expect(opened.popup, isFalse);
      expect(
        jsonDecode(
          server.called('POST', '/api/notifications/read').single.body,
        ),
        {
          'ids': ['m1'],
        },
      );
      // 읽은 줄은 안 읽음 점이 사라지고 탭 배지가 줄었다.
      expect(session.notificationCenter.counts.mention, 1);
    });

    testWidgets('이미 볼 수 없는 방의 알림을 누르면 토스트로 알린다(이동은 없다)', (tester) async {
      final server = _Server()..items.add(_n('m1', roomId: 'gone'));
      final session = _session(server);
      final opened = _Opened();
      await _pump(tester, session, opened: opened);
      await _settle(tester);
      await tester.tap(_rich('김철수: 확인 부탁드려요'));
      await _settle(tester);
      expect(opened.room, isNull);
      expect(find.text('더 이상 볼 수 없는 대화입니다.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('보드·공지 탭 — 보드 알림(새 글·수정·댓글)과 안 읽은 공지를 함께', (tester) async {
      final server = _Server()
        ..items.addAll([
          _n('b1', kind: 'board_post', minutesAgo: 10, preview: '9월 주간 보고'),
          _n('b2', kind: 'board_edit', minutesAgo: 20, preview: '8월 주간 보고'),
          _n('b3', kind: 'board_comment', minutesAgo: 30, preview: '확인했습니다'),
          _n('m1', minutesAgo: 1),
        ]);
      final session = _session(
        server,
        rooms: [_room('r1', '공지방', announcement: true, activityMinutesAgo: 15)],
      );
      final opened = _Opened();
      await _pump(
        tester,
        session,
        opened: opened,
        initialTab: NotificationTab.board,
      );
      await _settle(tester);
      expect(_rich('김철수: 9월 주간 보고'), findsOneWidget);
      expect(_rich('김철수 · 수정: 8월 주간 보고'), findsOneWidget);
      expect(_rich('김철수 · 댓글: 확인했습니다'), findsOneWidget);
      expect(find.text('공지 · 월간 회의 안내'), findsOneWidget);
      expect(_rich('김철수: 확인 부탁드려요'), findsNothing);
      // 시간순 — 새 글(10분) → 공지(16분) → 글 수정(20분).
      double y(String t) => tester.getTopLeft(_rich(t)).dy;
      expect(y('김철수: 9월 주간 보고'), lessThan(y('공지 · 월간 회의 안내')));
      expect(y('공지 · 월간 회의 안내'), lessThan(y('김철수 · 수정: 8월 주간 보고')));
      expect(
        server
            .called('GET', '/api/notifications')
            .single
            .url
            .queryParameters['kind'],
        'board',
      );

      // 공지 줄은 공지 팝업을 띄우는 쪽으로 연다.
      await tester.tap(find.text('공지 · 월간 회의 안내'));
      await tester.pump();
      expect(opened.room!.id, 'r1');
      expect(opened.popup, isTrue);
      // 보드 알림 줄은 그 글로 간다.
      await tester.tap(_rich('김철수: 9월 주간 보고'));
      await _settle(tester);
      expect(opened.messageId, 'm-b1');
      expect(opened.popup, isFalse);
    });

    testWidgets('전체 탭 — 안 읽은 대화·멘션·보드·공지·프로젝트를 시간순으로 섞는다', (tester) async {
      final server = _Server()
        ..items.addAll([
          _n('m1', minutesAgo: 50, preview: '멘션 글'),
          _n('b1', kind: 'board_post', minutesAgo: 20, preview: '보드 글'),
        ])
        ..projectItems.add(_p('p1', minutesAgo: 35));
      final session = _session(
        server,
        rooms: [
          _room('r1', '공지방', unread: 2, preview: '대화 글', activityMinutesAgo: 5),
          _room('r2', '개발 잡담', announcement: true, activityMinutesAgo: 40),
        ],
      );
      await _pump(tester, session, initialTab: NotificationTab.all);
      // 프로젝트 알림도 전체 탭에 섞이려면 받아 둔 상태여야 한다 — 프로젝트 탭을 한 번 본 뒤.
      await tester.runAsync(
        () => session.notificationCenter.ensureLoaded(NotificationTab.project),
      );
      await _settle(tester);
      double y(String t) => tester.getTopLeft(_rich(t)).dy;
      final order = [
        '대화 글', // 방 5분 전
        '김철수: 보드 글', // 20분
        '업무를 배정했습니다 p1', // 35분
        '공지 · 월간 회의 안내', // 공지 41분
        '김철수: 멘션 글', // 50분
      ];
      for (var i = 0; i < order.length - 1; i++) {
        expect(_rich(order[i]), findsOneWidget, reason: order[i]);
        expect(
          y(order[i]),
          lessThan(y(order[i + 1])),
          reason: '${order[i]} → ${order[i + 1]}',
        );
      }
      // 공지만 안 읽은 방은 대화 줄 없이 공지 줄로만 나온다.
      expect(find.text('개발 잡담'), findsOneWidget);
    });

    testWidgets('프로젝트 탭 — 기존 프로젝트 알림함을 같은 모양으로, 누르면 읽음 처리하고 그 프로젝트로', (
      tester,
    ) async {
      final server = _Server()
        ..projectItems.addAll([_p('p1'), _p('p2', minutesAgo: 10, read: true)]);
      final session = _session(server);
      final opened = _Opened();
      await _pump(
        tester,
        session,
        opened: opened,
        initialTab: NotificationTab.project,
      );
      await _settle(tester);
      expect(find.byType(ProjectNotificationTile), findsNWidgets(2));
      await tester.tap(find.text('업무를 배정했습니다 p1'));
      await _settle(tester);
      expect(
        jsonDecode(
          server.called('POST', '/api/project-notifications/read').single.body,
        ),
        {
          'ids': ['p1'],
        },
      );
      expect(opened.project!.taskId, 'task-p1');
      expect(server.called('GET', '/api/notifications'), isEmpty);
    });

    testWidgets('빈 탭은 탭마다 안내 문구', (tester) async {
      final session = _session(_Server());
      await _pump(tester, session, initialTab: NotificationTab.mention);
      await _settle(tester);
      expect(find.text('멘션 알림이 없습니다.'), findsOneWidget);
      await tester.tap(_tab(NotificationTab.board));
      await _settle(tester);
      expect(find.text('보드·공지 알림이 없습니다.'), findsOneWidget);
      await tester.tap(_tab(NotificationTab.project));
      await _settle(tester);
      expect(find.text('프로젝트 알림이 없습니다.'), findsOneWidget);
      await tester.tap(_tab(NotificationTab.all));
      await _settle(tester);
      expect(find.text('새 알림이 없습니다.'), findsOneWidget);
    });
  });

  group('메시지 탭 — 보낸 사람 이름과 멘션만 안 읽은 방', () {
    String previewOf(WidgetTester tester, String roomName) {
      final row = find.ancestor(
        of: find.text(roomName),
        matching: find.byType(InkWell),
      );
      final preview = find.descendant(
        of: row.first,
        matching: find.byKey(const ValueKey('notif-row-preview')),
      );
      final w = tester.widget(preview);
      return w is Text ? (w.data ?? w.textSpan!.toPlainText()) : '';
    }

    testWidgets('그룹채팅·토픽 줄은 "보낸 사람: 미리보기", 1:1은 미리보기만', (tester) async {
      final session = _session(
        _Server(),
        rooms: [
          _room(
            'g1',
            '점심 모임',
            type: RoomType.group,
            unread: 1,
            preview: '오늘 한식 어때요?',
            sender: '김철수',
            activityMinutesAgo: 1,
          ),
          _room(
            't1',
            '영업방',
            unread: 1,
            preview: '견적 확인 부탁',
            sender: '이영희',
            activityMinutesAgo: 2,
          ),
          _room(
            'd1',
            '박민수',
            type: RoomType.dm,
            unread: 1,
            preview: '네 알겠습니다',
            sender: '박민수',
            activityMinutesAgo: 3,
          ),
        ],
      );
      await _pump(tester, session, initialTab: NotificationTab.unreadChats);
      await _settle(tester);
      expect(previewOf(tester, '점심 모임'), '김철수: 오늘 한식 어때요?');
      expect(previewOf(tester, '영업방'), '이영희: 견적 확인 부탁');
      expect(previewOf(tester, '박민수'), '네 알겠습니다');
    });

    testWidgets('보드 뷰 토픽은 메시지 탭·전체 탭·배지에 안 뜬다 — 보드 알림(보드·공지 탭)으로 온다', (
      tester,
    ) async {
      final server = _Server()
        ..items.add(
          _n('b1', kind: 'board_post', roomName: '주간 보고', preview: '9월 보고'),
        );
      final session = _session(
        server,
        rooms: [
          _room(
            'board',
            '주간 보고',
            unread: 3,
            viewMode: TopicViewMode.board,
            preview: '게시글: 9월 보고',
            sender: '김철수',
          ),
          _room('chat', '일반 채팅 토픽', unread: 1, preview: '안녕'),
        ],
      );
      await _pump(tester, session, initialTab: NotificationTab.unreadChats);
      await _settle(tester);
      expect(find.text('주간 보고'), findsNothing);
      expect(find.text('일반 채팅 토픽'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.descendant(of: _badge('메시지'), matching: find.byType(Text)),
            )
            .data,
        '1',
      );

      // 전체 탭에는 보드 알림 줄만 있고 보드 방의 안 읽은 대화 줄은 없다.
      await tester.tap(_tab(NotificationTab.all));
      await _settle(tester);
      expect(_rich('김철수: 9월 보고'), findsOneWidget);
      expect(find.text('게시글: 9월 보고'), findsNothing);
    });

    testWidgets('안 읽은 메시지가 전부 멘션인 방은 메시지 탭·전체 탭·배지에서 빠지고, 멘션 말고도 있으면 보인다', (
      tester,
    ) async {
      final server = _Server()..items.add(_n('m1'));
      final session = _session(
        server,
        rooms: [
          _room('only', '멘션만 온 방', unread: 2, mentions: 2, preview: '@나 확인'),
          _room('mixed', '섞인 방', unread: 3, mentions: 1, preview: '일반 메시지'),
          _room('plain', '일반 방', unread: 1, preview: '안녕'),
        ],
      );
      await _pump(tester, session, initialTab: NotificationTab.unreadChats);
      await _settle(tester);
      expect(find.text('멘션만 온 방'), findsNothing);
      expect(find.text('섞인 방'), findsOneWidget);
      expect(find.text('일반 방'), findsOneWidget);
      // 탭 배지도 보이는 방만 센다(2개).
      expect(
        tester
            .widget<Text>(
              find.descendant(of: _badge('메시지'), matching: find.byType(Text)),
            )
            .data,
        '2',
      );

      // 멘션 탭에는 그 알림이 있다 — 안 읽은 방은 멘션 알림 쪽으로 보인다.
      await tester.tap(_tab(NotificationTab.all));
      await _settle(tester);
      expect(find.text('멘션만 온 방'), findsNothing);
    });
  });

  group('모두 읽음 · 안 읽은 것만', () {
    testWidgets('멘션 탭의 모두 읽음 — kind=mention으로 보내고 줄·배지가 읽음으로 바뀐다', (
      tester,
    ) async {
      final server = _Server()
        ..items.addAll([_n('m1'), _n('m2', minutesAgo: 1)]);
      final session = _session(server);
      await _pump(tester, session);
      await _settle(tester);
      expect(_badge('멘션'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('notif-read-all')));
      await _settle(tester);
      expect(
        jsonDecode(
          server.called('POST', '/api/notifications/read').single.body,
        ),
        {'kind': 'mention'},
      );
      expect(_badge('멘션'), findsNothing);
      // 읽을 게 없으면 버튼이 꺼진다.
      final button = tester.widget<TextButton>(
        find.byKey(const ValueKey('notif-read-all')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('제목 줄과 탭 사이에 가로 구분선이 있다', (tester) async {
      final session = _session(_Server());
      await _pump(tester, session);
      await _settle(tester);
      expect(find.byKey(const ValueKey('notif-title-divider')), findsOneWidget);
      // 탭 아래 도구줄에는 "안 읽은 것만" 칩이 더는 없다.
      expect(find.byKey(const ValueKey('notif-unread-only')), findsNothing);
      expect(find.text('안 읽은 것만'), findsNothing);
    });

    testWidgets('알림 설정에서 탭별 "안 읽은 알림만 표시" — 전체·멘션·보드·프로젝트 네 개(안 읽은 대화는 없음)', (
      tester,
    ) async {
      final session = _session(_Server());
      await _pump(tester, session);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('notif-settings')));
      await _settle(tester);
      expect(find.text('안 읽은 알림만 표시'), findsOneWidget);
      for (final name in ['all', 'mention', 'board', 'project']) {
        expect(
          find.byKey(ValueKey('notif-setting-unread-only-$name')),
          findsOneWidget,
        );
      }
      expect(
        find.byKey(const ValueKey('notif-setting-unread-only-unreadChats')),
        findsNothing,
      );
    });

    testWidgets('"안 읽은 알림만 표시" — 설정에서 켜면 unreadOnly=true로 새로 받고, 끄면 전부', (
      tester,
    ) async {
      final server = _Server()
        ..items.addAll([
          _n('unread', minutesAgo: 1, preview: '안 읽은 글'),
          _n('read', minutesAgo: 2, read: true, preview: '읽은 글'),
        ]);
      final session = _session(server);
      await _pump(tester, session, initialTab: NotificationTab.mention);
      await _settle(tester);
      expect(_rich('김철수: 읽은 글'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('notif-settings')));
      await _settle(tester);
      await tester.tap(
        find.byKey(const ValueKey('notif-setting-unread-only-mention')),
      );
      await _settle(tester);
      await tester.tap(find.text('닫기'));
      await _settle(tester);
      expect(
        server
            .called('GET', '/api/notifications')
            .last
            .url
            .queryParameters['unreadOnly'],
        'true',
      );
      expect(_rich('김철수: 읽은 글'), findsNothing);
      expect(_rich('김철수: 안 읽은 글'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('notif-settings')));
      await _settle(tester);
      await tester.tap(
        find.byKey(const ValueKey('notif-setting-unread-only-mention')),
      );
      await _settle(tester);
      await tester.tap(find.text('닫기'));
      await _settle(tester);
      expect(_rich('김철수: 읽은 글'), findsOneWidget);
    });

    testWidgets('프로젝트 탭의 모두 읽음 — 프로젝트 알림함 전체 읽음', (tester) async {
      final server = _Server()
        ..projectItems.addAll([_p('p1'), _p('p2', minutesAgo: 1)]);
      final session = _session(server);
      await _pump(tester, session, initialTab: NotificationTab.project);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('notif-read-all')));
      await _settle(tester);
      expect(
        jsonDecode(
          server.called('POST', '/api/project-notifications/read').single.body,
        ),
        <String, dynamic>{},
      );
    });
  });

  group('무한 스크롤', () {
    testWidgets('끝까지 내리면 before 커서로 다음 페이지를 이어 받는다', (tester) async {
      final server = _Server()
        ..items.addAll([
          for (var i = 0; i < 45; i++)
            _n('m$i', minutesAgo: i, preview: '글 $i'),
        ]);
      final session = _session(server);
      await _pump(tester, session, initialTab: NotificationTab.mention);
      await _settle(tester);
      expect(server.called('GET', '/api/notifications'), hasLength(1));
      expect(
        session.notificationCenter.itemsFor(NotificationTab.mention),
        hasLength(30),
      );
      expect(
        session.notificationCenter.hasMore(NotificationTab.mention),
        isTrue,
      );
      // 끝까지 내린다.
      for (var i = 0; i < 12; i++) {
        await tester.drag(
          find.byKey(const ValueKey('notif-list-mention')),
          const Offset(0, -600),
        );
        await _settle(tester);
      }
      final calls = server.called('GET', '/api/notifications');
      expect(calls.length, greaterThanOrEqualTo(2));
      expect(calls.last.url.queryParameters['before'], isNotNull);
      expect(
        session.notificationCenter.itemsFor(NotificationTab.mention),
        hasLength(45),
      );
      expect(_rich('김철수: 글 44'), findsOneWidget);
    });
  });

  group('알림 설정', () {
    Future<void> openSettings(WidgetTester tester, Session session) async {
      await _pump(tester, session);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('notif-settings')));
      await _settle(tester);
    }

    testWidgets('@all 알림 받기 스위치와 보드 알림 수준 3택 + 설명 문구', (tester) async {
      final server = _Server();
      final session = _session(server);
      await openSettings(tester, session);
      expect(find.byType(NotificationSettingsDialog), findsOneWidget);
      expect(find.text('@all 알림 받기'), findsOneWidget);
      expect(find.text('전체'), findsWidgets);
      expect(find.text('중요 알림'), findsOneWidget);
      expect(find.text('새 글 알림'), findsOneWidget);
      expect(find.text('새 글, 글 수정, 댓글 알림을 모두 받습니다.'), findsOneWidget);
      expect(find.text('새 글과 내가 쓴 글에 달린 댓글 알림을 받습니다.'), findsOneWidget);
      expect(find.text('새 글 알림만 받습니다.'), findsOneWidget);
      // 기본값: @all 켬, 중요 알림.
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('notif-setting-mention-all')),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<RadioGroup<BoardNotifyLevel>>(
              find.byType(RadioGroup<BoardNotifyLevel>),
            )
            .groupValue,
        BoardNotifyLevel.important,
      );
    });

    testWidgets('스위치·라디오를 고르면 바로 PATCH로 저장한다', (tester) async {
      final server = _Server();
      final session = _session(server);
      await openSettings(tester, session);
      await tester.tap(find.byKey(const ValueKey('notif-setting-mention-all')));
      await _settle(tester);
      expect(
        jsonDecode(
          server.called('PATCH', '/api/notification-settings').last.body,
        ),
        {'mentionAll': false},
      );
      await tester.tap(find.byKey(const ValueKey('notif-setting-board-new')));
      await _settle(tester);
      expect(
        jsonDecode(
          server.called('PATCH', '/api/notification-settings').last.body,
        ),
        {'boardLevel': 'new'},
      );
      expect(server.settings, {'mentionAll': false, 'boardLevel': 'new'});
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('notif-setting-mention-all')),
            )
            .value,
        isFalse,
      );
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationSettingsDialog), findsNothing);
    });
  });

  group('종 모양 버튼 · 프로젝트 알림함 연결', () {
    testWidgets('종 점 — 안 읽은 대화 없이 멘션만 있어도, 프로젝트만 있어도 뜬다', (tester) async {
      Future<bool> dotVisible(_Server server, {int projectUnread = 0}) async {
        final session = _session(server, rooms: [_room('r1', '공지방')])
          ..projectUnread = projectUnread;
        await tester.runAsync(session.notificationCenter.refreshCounts);
        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            home: Scaffold(
              body: NotificationBellButton(session: session, onPressed: () {}),
            ),
          ),
        );
        await tester.pump();
        return tester.widget<Badge>(find.byType(Badge)).isLabelVisible;
      }

      expect(await dotVisible(_Server()), isFalse);
      expect(await dotVisible(_Server()..items.add(_n('m1'))), isTrue);
      expect(
        await dotVisible(_Server()..items.add(_n('b1', kind: 'board_post'))),
        isTrue,
      );
      expect(await dotVisible(_Server(), projectUnread: 2), isTrue);
    });

    testWidgets('프로젝트 알림 종 팝업 — onOpenCenter를 주면 "알림 센터에서 보기"가 붙는다', (
      tester,
    ) async {
      final server = _Server()..projectItems.add(_p('p1'));
      final session = _session(server);
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: ProjectNotificationsBell(
                session: session,
                onOpen: (_) {},
                onOpenCenter: () => opened++,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('알림'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('project-bell-open-center')));
      await tester.pumpAndSettle();
      expect(opened, 1);
      // 팝업은 닫힌다.
      expect(
        find.byKey(const ValueKey('project-bell-open-center')),
        findsNothing,
      );
    });
  });

  group('모바일(폭 360)', () {
    testWidgets('전체 화면으로 열리고 탭줄은 가로로 스크롤되어 다섯 탭 모두 닿으며 넘치지 않는다', (
      tester,
    ) async {
      final server = _Server()
        ..items.addAll([
          _n('m1'),
          _n('b1', kind: 'board_post', minutesAgo: 3, preview: '주간 보고'),
        ])
        ..projectItems.add(_p('p1'));
      final session = _session(server, rooms: [_room('r1', '공지방', unread: 2)])
        ..projectUnread = 1;
      _size(tester, const Size(360, 740));
      await tester.runAsync(session.notificationCenter.refreshCounts);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () =>
                      showNotificationsCenterDialog(context, session),
                  child: const Text('열기'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      await _settle(tester);
      // 대화상자가 아니라 전체 화면.
      expect(find.byType(Dialog), findsNothing);
      expect(tester.getSize(find.byType(NotificationsPanel)).width, 360);
      expect(tester.takeException(), isNull);

      // 탭줄은 스크롤이 된다 — 다섯 번째(프로젝트)는 처음엔 화면 밖이고, 밀면 닿는다.
      final tabs = tester.widget<TabBar>(
        find.byKey(const ValueKey('notif-tabs')),
      );
      expect(tabs.isScrollable, isTrue);
      final barRect = tester.getRect(find.byKey(const ValueKey('notif-tabs')));
      expect(
        tester.getRect(_tab(NotificationTab.project)).right,
        greaterThan(barRect.right),
      );
      await tester.drag(
        find.byKey(const ValueKey('notif-tabs')),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(_tab(NotificationTab.project)).right,
        lessThanOrEqualTo(barRect.right + 0.5),
      );
      await tester.tap(_tab(NotificationTab.project));
      await _settle(tester);
      expect(find.text('업무를 배정했습니다 p1'), findsOneWidget);
      // 앞쪽 탭도 다시 닿는다.
      await tester.drag(
        find.byKey(const ValueKey('notif-tabs')),
        const Offset(500, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(_tab(NotificationTab.unreadChats));
      await _settle(tester);
      expect(find.text('공지방'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 닫기.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationsPanel), findsNothing);
    });

    testWidgets('모바일에서 멘션 알림을 누르면 전체 화면이 닫히고 그 방이 그 메시지로 열린다', (tester) async {
      final server = _Server()..items.add(_n('m1', messageId: 'msg-9'));
      final session = _session(server);
      _size(tester, const Size(360, 740));
      await tester.runAsync(session.notificationCenter.refreshCounts);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () =>
                      showNotificationsCenterDialog(context, session),
                  child: const Text('열기'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      await _settle(tester);
      await tester.tap(_rich('김철수: 확인 부탁드려요'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(NotificationsPanel), findsNothing);
    });
  });

  group('방 열기 요청', () {
    test('requestOpenRoom(messageId)는 팀 전환 뒤에도 잃지 않게 한 번만 돌려준다', () {
      final session = _session(_Server());
      final room = session.rooms.last; // 다른 팀(t2)
      session.requestOpenRoom(room, messageId: 'msg-1');
      expect(session.currentTeam!.id, 't2');
      expect(session.consumePendingOpenRoom()!.id, 'r2');
      expect(session.consumePendingOpenMessageId(), 'msg-1');
      expect(session.consumePendingOpenMessageId(), isNull);
      // 메시지 없이 열면 이전 요청의 메시지가 남지 않는다.
      session.requestOpenRoom(room);
      expect(session.consumePendingOpenMessageId(), isNull);
    });
  });
}
