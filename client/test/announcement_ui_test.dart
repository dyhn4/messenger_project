import 'dart:convert';

import 'package:client/models/announcement.dart';
import 'package:client/models/app_user.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/announcement_detail_screen.dart';
import 'package:client/screens/announcement_editor_dialog.dart';
import 'package:client/screens/announcement_list_screen.dart';
import 'package:client/services/api_client.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/notifications_panel.dart'
    show showUnreadAnnouncementPopup;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 토픽 공지의 잔디식 화면 — 상세보기(카드·댓글·입력칸·⋯), 목록(고정된 게시글과 같은 카드), 글쓰기/수정 창(제목칸
/// 없음). 폭 360 휴대폰과 PC 대화상자 둘 다.

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

// 2026/09/30 오후 4:42.
final _at = DateTime(2026, 9, 30, 16, 42).millisecondsSinceEpoch;

Map<String, dynamic> _a(
  String id, {
  String text = '이번 주 금요일 회식',
  String authorId = 'u2',
  bool pinned = true,
  int commentCount = 0,
  String? imageUrl,
  int? createdAt,
}) => {
  'id': id,
  'roomId': 'r1',
  'authorId': authorId,
  'authorName': authorId == 'me' ? '나' : '김철수',
  'text': text,
  'createdAt': createdAt ?? _at,
  'pinned': pinned,
  'commentCount': commentCount,
  'imageUrl': imageUrl,
  'imageThumbnailUrl': imageUrl,
  'imageName': imageUrl == null ? null : '회식장소.png',
};

Map<String, dynamic> _comment(
  String id,
  String text, {
  String authorId = 'u2',
}) => {
  'id': id,
  'announcementId': 'a1',
  'roomId': 'r1',
  'authorId': authorId,
  'authorName': authorId == 'me' ? '나' : '김철수',
  'text': text,
  'createdAt': DateTime(2026, 10, 1, 3, 4).millisecondsSinceEpoch,
};

Room _room({Announcement? announcement}) => Room(
  id: 'r1',
  teamId: 't1',
  type: RoomType.topic,
  name: '영업방',
  members: [_me, _kim],
  createdAt: DateTime(2026),
  lastRead: {},
  latestAnnouncement: announcement,
);

class _Server {
  _Server({this.announcements = const [], this.comments = const []});

  final List<Map<String, dynamic>> announcements;
  final List<Map<String, dynamic>> comments;
  final requests = <http.Request>[];

  late final client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET' && path == '/api/rooms/r1/announcements') {
      return _json(announcements);
    }
    if (request.method == 'GET' && path.endsWith('/comments')) {
      return _json(comments);
    }
    if (request.method == 'POST' && path.endsWith('/comments')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return _json(
        _comment('c-new', body['text'] as String, authorId: 'me'),
        201,
      );
    }
    if (request.method == 'POST' && path == '/api/rooms/r1/announcements') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return _json(
        _a('a-new', text: body['text'] as String, authorId: 'me'),
        201,
      );
    }
    if (request.method == 'PATCH' && path.contains('/comments/')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return _json({
        ..._comment(
          path.split('/').last,
          body['text'] as String,
          authorId: 'me',
        ),
        'editedAt': DateTime(2026, 10, 2).millisecondsSinceEpoch,
      });
    }
    if (request.method == 'PATCH') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return _json({
        ..._a('a1', authorId: 'me', text: body['text'] as String),
        'editedAt': DateTime(2026, 10, 2).millisecondsSinceEpoch,
      });
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
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

/// 화면을 여는 단추가 있는 앱 — 눌러서 [open]이 대화상자/전체 화면을 연다.
Future<void> _pumpHost(
  WidgetTester tester,
  Future<void> Function(BuildContext context) open, {
  Size size = const Size(360, 780),
}) async {
  _size(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
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
  await _settle(tester);
}

String _plain(WidgetTester tester, Key key) {
  final w = tester.widget<Text>(find.byKey(key));
  return w.data ?? w.textSpan?.toPlainText() ?? '';
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('상세보기', () {
    Future<void> openDetail(
      WidgetTester tester,
      _Server server, {
      Map<String, dynamic>? json,
      Size size = const Size(360, 780),
    }) async {
      final a = Announcement.fromJson(json ?? _a('a1'));
      final room = _room(announcement: a);
      final session = _session(server, room);
      await _pumpHost(
        tester,
        (context) => showAnnouncementDetailScreen(context, session, room, a),
        size: size,
      );
    }

    testWidgets(
      '작성자 아바타·이름·시각, 본문(줄바꿈 유지), 구분선, 댓글 N, 댓글 목록, 입력칸 — 읽음/좋아요/★는 없다',
      (tester) async {
        final server = _Server(comments: [_comment('c1', '확인했습니다.\n참석할게요')]);
        await openDetail(
          tester,
          server,
          json: _a('a1', text: '[공지] 회식 안내\n- 일시: 금요일 7시', commentCount: 1),
        );
        expect(
          find.byKey(const ValueKey('announcement-detail-card')),
          findsOneWidget,
        );
        expect(find.text('김철수'), findsNWidgets(2)); // 작성자 + 댓글 작성자
        // 시각 — 잔디처럼 "yyyy/MM/dd AM h:mm".
        expect(find.text('2026/09/30 PM 4:42'), findsOneWidget);
        expect(find.text('2026/10/01 AM 3:04'), findsOneWidget); // 댓글 시각
        expect(find.textContaining('[공지] 회식 안내'), findsOneWidget);
        expect(find.textContaining('- 일시: 금요일 7시'), findsOneWidget);
        expect(
          _plain(tester, const ValueKey('announcement-comment-count')),
          '댓글 1',
        );
        expect(find.textContaining('참석할게요'), findsOneWidget);
        expect(find.text('댓글을 입력하세요....'), findsOneWidget);
        // 이 앱에 없는 기능은 넣지 않는다.
        expect(find.textContaining('읽음'), findsNothing);
        expect(find.text('좋아요'), findsNothing);
        expect(find.byIcon(Icons.star), findsNothing);
        expect(find.byIcon(Icons.star_border), findsNothing);
        // 남이 쓴 공지 — ⋯ 없음.
        expect(
          find.byKey(const ValueKey('announcement-detail-more')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await _finish(tester);
      },
    );

    testWidgets('모바일은 전체 화면(머리 "← 공지"), 폭 360에서 긴 글·긴 이름도 넘치지 않는다', (
      tester,
    ) async {
      final server = _Server(comments: [_comment('c1', '아주 긴 댓글 ' * 30)]);
      await openDetail(
        tester,
        server,
        json: _a(
          'a1',
          text: '긴 공지 내용입니다. ' * 60,
          commentCount: 1,
          imageUrl: '/files/x',
        ),
      );
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('공지'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('announcement-detail-back')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('announcement-detail-close')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('announcement-detail-image-card')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('announcement-image')), findsOneWidget);
      expect(find.text('회식장소.png'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // ←로 닫힌다.
      await tester.tap(find.byKey(const ValueKey('announcement-detail-back')));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('announcement-detail-card')),
        findsNothing,
      );
      expect(find.text('열기'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('PC(폭 ≥ 700)는 대화상자 — 닫기 버튼이 있다', (tester) async {
      await openDetail(tester, _Server(), size: const Size(1000, 800));
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byTooltip('닫기'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('announcement-detail-back')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('announcement-detail-card')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('닫기'));
      await _settle(tester);
      expect(find.byType(Dialog), findsNothing);
      await _finish(tester);
    });

    testWidgets('작성자만 ⋯ — 수정하기·공지 내리기·삭제하기', (tester) async {
      await openDetail(tester, _Server(), json: _a('a1', authorId: 'me'));
      await tester.tap(find.byKey(const ValueKey('announcement-detail-more')));
      await _settle(tester);
      expect(find.text('수정하기'), findsOneWidget);
      expect(find.text('공지 내리기'), findsOneWidget);
      expect(find.text('삭제하기'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('이미 내려간 공지에는 "공지 내리기"가 없다', (tester) async {
      await openDetail(
        tester,
        _Server(),
        json: _a('a1', authorId: 'me', pinned: false),
      );
      await tester.tap(find.byKey(const ValueKey('announcement-detail-more')));
      await _settle(tester);
      expect(find.text('수정하기'), findsOneWidget);
      expect(find.text('공지 내리기'), findsNothing);
      await _finish(tester);
    });

    testWidgets('삭제하기: 확인 뒤 공지를 지우고 상세가 닫힌다', (tester) async {
      final server = _Server();
      await openDetail(tester, server, json: _a('a1', authorId: 'me'));
      await tester.tap(find.byKey(const ValueKey('announcement-detail-more')));
      await _settle(tester);
      await tester.tap(find.text('삭제하기'));
      await _settle(tester);
      expect(find.textContaining('이 공지를 삭제할까요?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '삭제'));
      await _settle(tester);
      expect(server.called('DELETE', '/announcements/a1'), hasLength(1));
      expect(
        find.byKey(const ValueKey('announcement-detail-card')),
        findsNothing,
      );
      await _finish(tester);
    });

    testWidgets('공지 내리기: 확인 뒤 내리고 고정 표시가 사라진다', (tester) async {
      final server = _Server();
      await openDetail(tester, server, json: _a('a1', authorId: 'me'));
      expect(find.text('고정'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('announcement-detail-more')));
      await _settle(tester);
      await tester.tap(find.text('공지 내리기'));
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '내리기'));
      await _settle(tester);
      expect(server.called('POST', '/announcements/a1/unpin'), hasLength(1));
      expect(find.text('고정'), findsNothing);
      await _finish(tester);
    });

    testWidgets('수정하기: 공지 수정 창(제목칸 없음)에 글이 채워져 있고 저장하면 PATCH', (tester) async {
      final server = _Server();
      await openDetail(
        tester,
        server,
        json: _a('a1', authorId: 'me', text: '원래 글'),
      );
      await tester.tap(find.byKey(const ValueKey('announcement-detail-more')));
      await _settle(tester);
      await tester.tap(find.text('수정하기'));
      await _settle(tester);
      expect(find.text('공지 수정'), findsWidgets);
      expect(find.byKey(const ValueKey('post-title')), findsNothing);
      expect(find.text('제목을 입력하세요'), findsNothing);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('announcement-body')),
      );
      expect(field.controller!.text, '원래 글');
      // 수정에는 자동 내리기 선택이 없다.
      expect(find.text('공지 자동 내리기'), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('announcement-body')),
        '고친 글',
      );
      await tester.tap(find.byKey(const ValueKey('announcement-submit')));
      await _settle(tester);
      final patch = server.called('PATCH', '/announcements/a1');
      expect(patch, hasLength(1));
      expect(jsonDecode(patch.single.body), {'text': '고친 글'});
      // 상세에 고친 글과 (수정됨)이 반영된다.
      expect(find.textContaining('고친 글'), findsOneWidget);
      expect(find.textContaining('(수정됨)'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('댓글 입력 — 보내면 목록에 붙고 댓글 수가 오른다', (tester) async {
      final server = _Server();
      await openDetail(tester, server);
      expect(
        _plain(tester, const ValueKey('announcement-comment-count')),
        '댓글 0',
      );
      await tester.enterText(
        find.byKey(const ValueKey('announcement-comment-input')),
        '좋습니다',
      );
      await tester.tap(find.byKey(const ValueKey('announcement-comment-send')));
      await _settle(tester);
      final posted = server.called('POST', '/announcements/a1/comments');
      expect(posted, hasLength(1));
      expect(jsonDecode(posted.single.body), {'text': '좋습니다'});
      expect(find.text('좋습니다'), findsOneWidget);
      expect(
        _plain(tester, const ValueKey('announcement-comment-count')),
        '댓글 1',
      );
      await _finish(tester);
    });

    testWidgets(
      '내 댓글 ⋯ — 수정하기(그 자리에서 고치고 `(수정됨)`) · 삭제하기(묻고 지우면 댓글 수도 준다), 남의 댓글은 ⋯ 없음',
      (tester) async {
        final server = _Server(
          comments: [
            _comment('mine', '고칠 댓글', authorId: 'me'),
            _comment('theirs', '남의 댓글'),
          ],
        );
        await openDetail(tester, server, json: _a('a1', commentCount: 2));
        expect(
          find.byKey(const ValueKey('post-comment-more-theirs')),
          findsNothing,
        );

        await tester.tap(find.byKey(const ValueKey('post-comment-more-mine')));
        await _settle(tester);
        await tester.tap(find.text('수정하기'));
        await _settle(tester);
        await tester.enterText(
          find.byKey(const ValueKey('post-comment-edit-input')),
          '고친 댓글',
        );
        await tester.tap(find.byKey(const ValueKey('post-comment-edit-save')));
        await _settle(tester);
        final patched = server.called(
          'PATCH',
          '/announcements/a1/comments/mine',
        );
        expect(patched, hasLength(1));
        expect(jsonDecode(patched.single.body), {'text': '고친 댓글'});
        expect(find.text('고친 댓글'), findsOneWidget);
        expect(find.textContaining('(수정됨)'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('post-comment-more-mine')));
        await _settle(tester);
        await tester.tap(find.text('삭제하기'));
        await _settle(tester);
        await tester.tap(
          find.byKey(const ValueKey('post-comment-delete-confirm')),
        );
        await _settle(tester);
        expect(
          server.called('DELETE', '/announcements/a1/comments/mine'),
          hasLength(1),
        );
        expect(find.text('고친 댓글'), findsNothing);
        expect(find.text('남의 댓글'), findsOneWidget);
        expect(
          _plain(tester, const ValueKey('announcement-comment-count')),
          '댓글 1',
        );
        await _finish(tester);
      },
    );
  });

  group('공지 목록', () {
    Future<void> openList(
      WidgetTester tester,
      _Server server, {
      Team? team,
      int unreadCount = 0,
      Size size = const Size(360, 780),
    }) async {
      // 안 읽은 공지 수는 열 때의 방 상태로 정한다(알림 센터 배지와 같은 값).
      final room = _room()
        ..hasUnreadAnnouncement = unreadCount > 0
        ..unreadAnnouncementCount = unreadCount;
      final session = _session(server, room, team: team);
      await _pumpHost(
        tester,
        (context) async => openAnnouncementPanel(context, session, room),
        size: size,
      );
    }

    final items = [
      _a(
        'a2',
        text: '[공지] 8월 타운홀 일정 공지\n일정: 8월 1일 오전 9시\n장소 확인 부탁드립니다.\n네 번째 줄',
        commentCount: 3,
        imageUrl: '/files/x',
      ),
      _a('a1', text: '지난 공지', pinned: false, authorId: 'me'),
    ];

    testWidgets('보드의 고정된 게시글 같은 카드 — 작성자·시각·본문 앞부분·고정 표시·썸네일·댓글 수', (
      tester,
    ) async {
      await openList(tester, _Server(announcements: items));
      expect(
        _plain(tester, const ValueKey('announcement-list-count')),
        '2개의 공지',
      );
      // 카드 — 본문은 3줄까지 말줄임.
      final text = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('announcement-tile-a2')),
          matching: find.byKey(const ValueKey('announcement-tile-text')),
        ),
      );
      expect(text.maxLines, 3);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(find.text('김철수 · 2026/09/30 PM 4:42'), findsOneWidget);
      expect(find.text('나 · 2026/09/30 PM 4:42'), findsOneWidget);
      // 고정된 공지(a2)에만 "고정", 썸네일은 사진 공지에만, 댓글 수는 있는 곳에만.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('announcement-tile-a2')),
          matching: find.text('고정'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('announcement-tile-a1')),
          matching: find.text('고정'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('announcement-tile-thumb')),
        findsOneWidget,
      );
      expect(find.text('3'), findsOneWidget);
      // 예전 목록의 "채팅방에 고정됨"/상대 시각("방금 전")은 없다.
      expect(find.text('채팅방에 고정됨'), findsNothing);
      expect(find.textContaining('전 ·'), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('카드를 누르면 상세보기가 열린다', (tester) async {
      final server = _Server(announcements: items);
      await openList(tester, server);
      await tester.tap(find.byKey(const ValueKey('announcement-tile-a1')));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('announcement-detail-card')),
        findsOneWidget,
      );
      expect(find.textContaining('지난 공지'), findsWidgets);
      expect(server.called('GET', '/announcements/a1/comments'), hasLength(1));
      await _finish(tester);
    });

    testWidgets('안 읽은 공지에는 "안 읽음" 표시 — 상세를 열어보면 사라진다', (tester) async {
      await openList(tester, _Server(announcements: items), unreadCount: 1);
      expect(find.text('안 읽음'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('announcement-tile-a2')));
      await _settle(tester);
      Navigator.of(
        tester.element(find.byKey(const ValueKey('announcement-detail-card'))),
      ).pop();
      await _settle(tester);
      expect(find.text('안 읽음'), findsNothing);
      await _finish(tester);
    });

    testWidgets('글쓰기는 권한 있는 사람에게만 — 관리자만 토픽을 만들 수 있는 팀의 일반 멤버는 없다', (
      tester,
    ) async {
      await openList(tester, _Server(announcements: items));
      expect(find.byKey(const ValueKey('announcement-write')), findsOneWidget);
      await _finish(tester);

      await openList(
        tester,
        _Server(announcements: items),
        team: Team(
          id: 't1',
          name: '영업팀',
          createdAt: DateTime(2026),
          topicCreationPolicy: TopicCreationPolicy.admin,
        ),
      );
      expect(find.byKey(const ValueKey('announcement-write')), findsNothing);
      await _finish(tester);
    });

    testWidgets('공지가 없으면 안내 문구', (tester) async {
      await openList(tester, _Server());
      expect(find.text('등록된 공지가 없습니다.'), findsOneWidget);
      expect(
        _plain(tester, const ValueKey('announcement-list-count')),
        '0개의 공지',
      );
      await _finish(tester);
    });

    testWidgets('홈 화면 밖의 넓은 화면(팀 리스트의 알림 센터 등)은 같은 패널을 대화상자로', (tester) async {
      await openList(
        tester,
        _Server(announcements: items),
        size: const Size(1000, 800),
      );
      expect(find.byType(Dialog), findsOneWidget);
      expect(
        find.byKey(const ValueKey('announcement-tile-a2')),
        findsOneWidget,
      );
      await _finish(tester);
    });

    testWidgets('글쓰기 → 공지 쓰기 창(제목칸 없음) → 등록하면 목록 맨 위에 붙는다', (tester) async {
      final server = _Server(announcements: items);
      await openList(tester, server);
      await tester.tap(find.byKey(const ValueKey('announcement-write')));
      await _settle(tester);
      // 모바일은 전체 화면.
      expect(find.text('공지 쓰기'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byKey(const ValueKey('post-title')), findsNothing);
      expect(find.text('제목을 입력하세요'), findsNothing);
      expect(find.text('공지 내용을 입력하세요'), findsOneWidget);
      expect(find.text('공지 자동 내리기'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('announcement-body')),
        '새 공지 글',
      );
      await tester.tap(find.text('7일'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('announcement-submit')));
      await _settle(tester);
      final post = server.called('POST', '/rooms/r1/announcements');
      expect(post, hasLength(1));
      final body = jsonDecode(post.single.body) as Map<String, dynamic>;
      expect(body['text'], '새 공지 글');
      final unpinAt = DateTime.fromMillisecondsSinceEpoch(
        body['autoUnpinAt'] as int,
      );
      expect(unpinAt.difference(DateTime.now()).inDays, anyOf(6, 7));
      // 쓰기 창은 닫히고(패널의 `+ 공지 쓰기` 단추만 남는다) 새 글이 맨 위에 고정으로 붙는다.
      expect(find.byKey(const ValueKey('announcement-body')), findsNothing);
      expect(find.text('공지 내용을 입력하세요'), findsNothing);
      expect(find.text('새 공지 글'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('announcement-tile-a-new')),
          matching: find.text('고정'),
        ),
        findsOneWidget,
      );
      // 새 공지가 고정되면 그전 고정 공지(a2)는 내려간다.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('announcement-tile-a2')),
          matching: find.text('고정'),
        ),
        findsNothing,
      );
      expect(
        _plain(tester, const ValueKey('announcement-list-count')),
        '3개의 공지',
      );
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });
  });

  group('알림 센터에서 열기', () {
    Future<void> openFromNotification(WidgetTester tester, int unread) async {
      final a = Announcement.fromJson(_a('a1'));
      final room = _room(announcement: a)
        ..hasUnreadAnnouncement = true
        ..unreadAnnouncementCount = unread;
      final session = _session(_Server(announcements: [_a('a1')]), room);
      await _pumpHost(
        tester,
        (context) async => showUnreadAnnouncementPopup(
          context,
          session,
          room,
          hadUnreadAnnouncement: true,
        ),
      );
    }

    testWidgets('안 읽은 공지가 하나면 목록을 거치지 않고 상세보기가 바로 열린다', (tester) async {
      await openFromNotification(tester, 1);
      expect(
        find.byKey(const ValueKey('announcement-detail-card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('announcement-list-count')),
        findsNothing,
      );
      await _finish(tester);
    });

    testWidgets('여럿이면 목록(안 읽음 표시)이 열리고, 카드를 누르면 상세보기', (tester) async {
      await openFromNotification(tester, 2);
      expect(
        find.byKey(const ValueKey('announcement-list-count')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('announcement-tile-a1')));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('announcement-detail-card')),
        findsOneWidget,
      );
      await _finish(tester);
    });
  });

  group('공지 쓰기 창', () {
    Future<void> openEditor(
      WidgetTester tester, {
      Size size = const Size(360, 780),
      _Server? server,
      List<AnnouncementDraft>? sink,
      bool failSubmit = false,
    }) async {
      final room = _room();
      final session = _session(server ?? _Server(), room);
      await _pumpHost(
        tester,
        (context) => showAnnouncementEditor(
          context,
          session: session,
          room: room,
          onSubmit: (draft) async {
            if (failSubmit) throw '공지를 등록하지 못했습니다: 권한이 없습니다.';
            sink?.add(draft);
          },
        ),
        size: size,
      );
    }

    testWidgets('PC 대화상자: 헤더(공지 쓰기·토픽 칩·닫기)·서식 도구줄·본문 칸·하단 취소/등록 — 제목칸은 없다', (
      tester,
    ) async {
      await openEditor(tester, size: const Size(1000, 800));
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('공지 쓰기'), findsOneWidget);
      expect(find.text('영업방'), findsOneWidget);
      expect(find.byTooltip('닫기'), findsOneWidget);
      expect(find.byKey(const ValueKey('post-title')), findsNothing);
      expect(find.text('제목을 입력하세요'), findsNothing);
      // 본문 칸 위에 프로젝트 "새 노트"와 같은 서식 도구줄(announcement_editor_test.dart에서 자세히).
      expect(
        find.byKey(const ValueKey('announcement-format-toolbar')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('announcement-body')), findsOneWidget);
      expect(find.widgetWithText(TextButton, '취소'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '등록'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester);
    });

    testWidgets('빈 글은 등록되지 않고 칸 아래에 알린다', (tester) async {
      final sink = <AnnouncementDraft>[];
      await openEditor(tester, sink: sink);
      await tester.tap(find.byKey(const ValueKey('announcement-submit')));
      await tester.pump();
      expect(find.text('내용을 입력하세요.'), findsOneWidget);
      expect(sink, isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('announcement-body')),
        '내용',
      );
      await tester.pump();
      expect(find.text('내용을 입력하세요.'), findsNothing);
      await _finish(tester);
    });

    testWidgets('등록하면 글(앞뒤 공백 제거)과 자동 내리기 기간을 넘기고 닫힌다', (tester) async {
      final sink = <AnnouncementDraft>[];
      await openEditor(tester, sink: sink);
      await tester.enterText(
        find.byKey(const ValueKey('announcement-body')),
        '  회의 안내  ',
      );
      await tester.tap(find.text('4시간'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('announcement-submit')));
      await _settle(tester);
      expect(sink.single.text, '회의 안내');
      expect(sink.single.autoUnpinAfter, const Duration(hours: 4));
      expect(find.text('공지 쓰기'), findsNothing);
      await _finish(tester);
    });

    testWidgets('등록이 실패하면 창과 쓰던 글을 그대로 둔다', (tester) async {
      await openEditor(tester, failSubmit: true);
      await tester.enterText(
        find.byKey(const ValueKey('announcement-body')),
        '남아야 하는 글',
      );
      await tester.tap(find.byKey(const ValueKey('announcement-submit')));
      await _settle(tester);
      expect(find.text('공지 쓰기'), findsOneWidget);
      expect(find.text('남아야 하는 글'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('쓰던 글이 있으면 닫기 전에 묻는다 — 계속 쓰기 / 닫기', (tester) async {
      await openEditor(tester);
      await tester.enterText(
        find.byKey(const ValueKey('announcement-body')),
        '쓰던 글',
      );
      await tester.tap(find.byTooltip('취소'));
      await _settle(tester);
      expect(find.text('작성 취소'), findsOneWidget);
      await tester.tap(find.text('계속 쓰기'));
      await _settle(tester);
      expect(find.text('공지 쓰기'), findsOneWidget);
      await tester.tap(find.byTooltip('취소'));
      await _settle(tester);
      await tester.tap(find.widgetWithText(TextButton, '닫기'));
      await _settle(tester);
      expect(find.text('공지 쓰기'), findsNothing);
      await _finish(tester);
    });

    testWidgets('빈 채로는 바로 닫힌다', (tester) async {
      await openEditor(tester);
      await tester.tap(find.byTooltip('취소'));
      await _settle(tester);
      expect(find.text('공지 쓰기'), findsNothing);
      expect(find.text('작성 취소'), findsNothing);
      await _finish(tester);
    });

    testWidgets('글자 수 한도(2000자)에 가까워지면 n/2000이 보인다', (tester) async {
      await openEditor(tester, size: const Size(1000, 800));
      expect(find.textContaining('/2000'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('announcement-body')),
        '가' * 1850,
      );
      await tester.pump();
      expect(find.text('1850/2000'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('announcement-body')),
        '가' * 2100,
      );
      await tester.pump();
      expect(find.text('2000/2000'), findsOneWidget); // 한도에서 더 못 쓴다.
      await _finish(tester);
    });
  });
}
