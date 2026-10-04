import 'package:client/models/album.dart';
import 'package:client/models/message.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/services/album_controller.dart';
import 'package:client/services/album_media.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/album_actions.dart';
import 'package:client/widgets/album_detail_view.dart';
import 'package:client/widgets/albums_panel.dart';
import 'package:client/widgets/message_bubble.dart';
import 'package:client/widgets/shared_album_card.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_album_api.dart';

// 앨범 카드의 ⋯ 메뉴(전체 다운로드·앨범 공유·앨범 수정·앨범 삭제), "앨범 공유" 창(대화방·메시지 필수),
// 공유된 앨범 메시지의 말풍선(…에서 공유된 앨범입니다 · 앨범 보기 · 카드)과 보기 전용 앨범.

Room room(
  String id,
  RoomType type,
  String name, {
  bool secret = false,
  TopicViewMode viewMode = TopicViewMode.chat,
}) => Room(
  id: id,
  teamId: 't1',
  type: type,
  name: name,
  members: const [],
  createdAt: DateTime(2026),
  lastRead: const {},
  isSecret: secret,
  viewMode: viewMode,
);

Session makeSession(FakeAlbumApi api) {
  final s = Session(
    notifications: NotificationService(),
    settings: AppSettings(),
  );
  s.serverUrl = 'https://test.local';
  s.userId = 'me';
  s.currentTeam = Team(id: 't1', name: '잔디팀', createdAt: DateTime(2026));
  s.rooms.addAll([
    room('r1', RoomType.topic, '잔디톡 팀'),
    room('rb', RoomType.topic, '공지 게시판', viewMode: TopicViewMode.board),
    room('g1', RoomType.group, '디자인 그룹'),
    room('d1', RoomType.dm, '김철수'),
    room('s1', RoomType.dm, '비밀 친구', secret: true),
  ]);
  s.albums = AlbumController(
    apiProvider: () => api,
    teamIdProvider: () => 't1',
    preparer: (file, kind) async => const AlbumImagePrep(),
  );
  return s;
}

void setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> pumpPanel(
  WidgetTester tester,
  Session session, {
  Size size = const Size(1100, 800),
}) async {
  setSize(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 380, child: AlbumsPanel(session: session)),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

/// 마우스를 카드 위에 올린다(PC의 ⋯ 단추는 올렸을 때만 보인다).
Future<TestGesture> hover(WidgetTester tester, Finder target) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(target));
  await tester.pump();
  return mouse;
}

void main() {
  late FakeAlbumApi api;
  late Session session;

  setUp(() {
    api = FakeAlbumApi();
    api.albums.addAll([
      fakeAlbum('a1', title: '제주 여행', createdAt: DateTime(2026, 9, 29)),
      fakeAlbum(
        'a2',
        title: '가을 소풍',
        roomId: 'g1',
        roomName: '디자인 그룹',
        creatorId: 'u2',
        createdAt: DateTime(2026, 9, 1),
      ),
    ]);
    api.items['a1'] = [
      fakeItem('p1', 'a1', minutesAgo: 1),
      fakeItem('p2', 'a1', minutesAgo: 2),
    ];
    session = makeSession(api);
  });

  group('카드 ⋯ 메뉴', () {
    testWidgets('PC는 마우스를 올려야 ⋯ 단추가 보이고, 내 앨범은 네 동작이 다 나온다', (tester) async {
      await pumpPanel(tester, session);
      const more = ValueKey('album-card-more-a1');
      expect(find.byKey(more), findsNothing);
      // 왼쪽 위 개수 표시.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('album-count-a1')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );

      await hover(tester, find.byKey(const ValueKey('album-card-a1')));
      expect(find.byKey(more), findsOneWidget);
      await tester.tap(find.byKey(more));
      await tester.pumpAndSettle();
      for (final label in ['전체 다운로드', '앨범 공유', '앨범 수정', '앨범 삭제']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.byIcon(Icons.file_download_outlined), findsOneWidget);
      expect(find.byIcon(Icons.share_outlined), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      // 메뉴를 고르는 동안 카드가 열리지는 않는다.
      expect(find.byKey(const ValueKey('album-detail-title')), findsNothing);
      await finish(tester);
    });

    testWidgets('남이 만든 앨범은 전체 다운로드·앨범 공유만', (tester) async {
      await pumpPanel(tester, session);
      await hover(tester, find.byKey(const ValueKey('album-card-a2')));
      await tester.tap(find.byKey(const ValueKey('album-card-more-a2')));
      await tester.pumpAndSettle();
      expect(find.text('전체 다운로드'), findsOneWidget);
      expect(find.text('앨범 공유'), findsOneWidget);
      expect(find.text('앨범 수정'), findsNothing);
      expect(find.text('앨범 삭제'), findsNothing);
      await finish(tester);
    });

    testWidgets('모바일(늘 보이기)에서는 마우스 없이도 ⋯ 단추가 있다', (tester) async {
      setSize(tester, const Size(390, 800));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 180,
              height: 190,
              child: AlbumCard(
                album: fakeAlbum('a1'),
                resolveUrl: (u) => u,
                onTap: () {},
                onAction: (_) {},
                alwaysShowMenu: true,
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('album-card-more-a1')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    test('할 수 있는 동작만 — 보기 전용 앨범은 다운로드만', () {
      final mine = Album(
        id: 'x',
        teamId: 't1',
        roomId: 'r1',
        title: 't',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        canEdit: true,
        canDelete: true,
      );
      expect(albumActionsFor(mine), AlbumAction.values);
      final viewer = Album.fromJson({
        'id': 'x',
        'roomId': 'r1',
        'title': 't',
        'canShare': false,
        'viewOnly': true,
      });
      expect(albumActionsFor(viewer), [AlbumAction.download]);
      // 예전 서버(권한 없음) — 공유는 되고 수정·삭제는 안 된다.
      final legacy = Album.fromJson({'id': 'x', 'roomId': 'r1', 'title': 't'});
      expect(albumActionsFor(legacy), [
        AlbumAction.download,
        AlbumAction.share,
      ]);
    });

    testWidgets('앨범 삭제: 확인하면 그 앨범만 지우고 목록에서 뺀다(열지 않은 앨범)', (tester) async {
      await pumpPanel(tester, session);
      await hover(tester, find.byKey(const ValueKey('album-card-a1')));
      await tester.tap(find.byKey(const ValueKey('album-card-more-a1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('앨범 삭제'));
      await tester.pumpAndSettle();
      expect(find.textContaining("'제주 여행' 앨범을 삭제할까요?"), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('album-delete-confirm')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('deleteAlbum a1'));
      expect(find.byKey(const ValueKey('album-card-a1')), findsNothing);
      expect(find.text('앨범을 삭제했습니다.'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('앨범 수정: 열지 않은 앨범도 그 id로 고친다', (tester) async {
      await pumpPanel(tester, session);
      await hover(tester, find.byKey(const ValueKey('album-card-a1')));
      await tester.tap(find.byKey(const ValueKey('album-card-more-a1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('앨범 수정'));
      await tester.pumpAndSettle();
      expect(find.text('앨범 수정'), findsOneWidget); // 창 제목
      await tester.enterText(
        find.byKey(const ValueKey('album-title-field')),
        '제주 여행 2026',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('album-editor-submit')));
      await tester.pumpAndSettle();
      expect(
        api.calls.any((c) => c.startsWith('updateAlbum a1 title=제주 여행 2026')),
        isTrue,
      );
      expect(find.text('제주 여행 2026'), findsOneWidget); // 카드도 바뀐다
      expect(session.albums.album, isNull); // 상세로 넘어가지 않는다
      await finish(tester);
    });

    testWidgets('정렬 기본은 업데이트 순, 목록 보기로 바꿀 수 있다', (tester) async {
      // a2가 더 오래 전에 만들었지만 최근에 고쳤다.
      api.albums[1] = Album(
        id: 'a2',
        teamId: 't1',
        roomId: 'g1',
        roomName: '디자인 그룹',
        creatorId: 'u2',
        title: '가을 소풍',
        createdAt: DateTime(2026, 9, 1),
        updatedAt: DateTime(2026, 10, 1),
      );
      await pumpPanel(tester, session);
      expect(find.text('업데이트 순'), findsOneWidget);
      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      double x(String t) => tester.getTopLeft(find.text(t)).dx;
      expect(
        y('가을 소풍') < y('제주 여행') ||
            (y('가을 소풍') == y('제주 여행') && x('가을 소풍') < x('제주 여행')),
        isTrue,
      );

      await tester.tap(find.byKey(const ValueKey('album-view-list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('album-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('album-row-a1')), findsOneWidget);
      expect(find.textContaining('사진·영상 2개 · 잔디톡 팀'), findsOneWidget);
      expect(y('가을 소풍') < y('제주 여행'), isTrue);
      // 목록 줄도 마우스를 올리면 ⋯.
      await hover(tester, find.byKey(const ValueKey('album-row-a1')));
      expect(find.byKey(const ValueKey('album-card-more-a1')), findsOneWidget);
      await finish(tester);
    });
  });

  group('앨범 공유 창', () {
    Future<void> openShare(WidgetTester tester) async {
      await pumpPanel(tester, session);
      await hover(tester, find.byKey(const ValueKey('album-card-a1')));
      await tester.tap(find.byKey(const ValueKey('album-card-more-a1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('앨범 공유'));
      await tester.pumpAndSettle();
    }

    FilledButton send(WidgetTester tester) => tester.widget<FilledButton>(
      find.byKey(const ValueKey('album-message-share-send')),
    );

    testWidgets('대화방·공유 앨범·메시지(필수, 글자 수) — 둘 다 채워야 공유하기가 켜진다', (tester) async {
      await openShare(tester);
      expect(
        find.byKey(const ValueKey('album-message-share-dialog')),
        findsOneWidget,
      );
      // 칸 이름과 아직 고르지 않은 대화방 칸의 자리 글자.
      expect(find.text('대화방 선택'), findsNWidgets(2));
      expect(find.text('※ 앨범은 채팅 및 챗 뷰 토픽에서만 공유할 수 있습니다.'), findsOneWidget);
      expect(find.text('공유 앨범'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('album-message-share-album')),
          matching: find.text('제주 여행'),
        ),
        findsOneWidget,
      );
      expect(find.text('0 / 5,000'), findsOneWidget);
      expect(find.text('취소'), findsOneWidget);
      expect(find.text('공유하기'), findsOneWidget);
      expect(send(tester).onPressed, isNull);

      await tester.enterText(
        find.byKey(const ValueKey('album-message-share-text')),
        '  가족 여행 사진 올렸어요  ',
      );
      await tester.pump();
      expect(find.text('13 / 5,000'), findsOneWidget); // 앞뒤 공백은 세지 않는다
      expect(send(tester).onPressed, isNull); // 방을 안 골랐다

      // 대화방 고르기 — 보드 뷰 토픽은 없다.
      await tester.tap(find.byKey(const ValueKey('album-message-share-room')));
      await tester.pumpAndSettle();
      expect(find.text('공지 게시판'), findsNothing);
      await tester.tap(find.text('잔디톡 팀').last);
      await tester.pumpAndSettle();
      // 토픽이라 @ 멘션 단추가 있다.
      expect(find.byKey(const ValueKey('mention-button')), findsOneWidget);
      expect(send(tester).onPressed, isNotNull);

      await tester.tap(find.byKey(const ValueKey('album-message-share-send')));
      await tester.pumpAndSettle();
      final sent = api.lastAlbumShare!;
      expect(sent.albumId, 'a1');
      expect(sent.roomId, 'r1');
      expect(sent.text, '가족 여행 사진 올렸어요');
      expect(
        find.byKey(const ValueKey('album-message-share-dialog')),
        findsNothing,
      );
      expect(find.text("'잔디톡 팀'에 앨범을 공유했습니다."), findsOneWidget);
      await finish(tester);
    });

    testWidgets('1:1 채팅은 멘션 단추가 없고, 서버 거절은 창에 그대로 보인다', (tester) async {
      api.rejectShareRooms.add('d1');
      await openShare(tester);
      await tester.tap(find.byKey(const ValueKey('album-message-share-room')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('채팅'));
      await tester.pumpAndSettle();
      expect(find.text('비밀 친구'), findsNothing);
      await tester.tap(find.text('김철수'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mention-button')), findsNothing);
      // T(서식) 단추는 있다.
      expect(find.byIcon(Icons.text_format), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('album-message-share-text')),
        '보세요',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('album-message-share-send')));
      await tester.pumpAndSettle();
      expect(find.text('보드 뷰 토픽에는 앨범을 공유할 수 없습니다.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('album-message-share-dialog')),
        findsOneWidget,
      );
      await finish(tester);
    });

    testWidgets('5,000자를 넘으면 공유하기가 꺼지고 글자 수가 빨갛게', (tester) async {
      await openShare(tester);
      await tester.tap(find.byKey(const ValueKey('album-message-share-room')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('잔디톡 팀').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('album-message-share-text')),
        'a' * 5001,
      );
      await tester.pump();
      expect(find.text('5,001 / 5,000'), findsOneWidget);
      expect(send(tester).onPressed, isNull);
      await finish(tester);
    });

    testWidgets('모바일 폭에서는 전체 화면으로 열린다', (tester) async {
      setSize(tester, const Size(390, 800));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    shareAlbumToRoom(context, session, api.albums.first),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('앨범 공유'), findsOneWidget);
      expect(find.text('공유하기'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  });

  group('공유된 앨범 메시지', () {
    Message shared({String? albumId = 'a1'}) => Message.fromJson({
      'id': 'm1',
      'roomId': 'r1',
      'senderId': 'u2',
      'senderName': '김철수',
      'type': 'text',
      'text': '가족 여행 사진 올렸어요',
      'createdAt': DateTime(2026, 10, 1).millisecondsSinceEpoch,
      'sharedAlbum': {'id': albumId, 'title': '제주 여행', 'teamName': '잔디팀'},
    });

    Future<void> pumpBubble(WidgetTester tester, Message m) async {
      setSize(tester, const Size(1000, 800));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MessageBubble(
                session: session,
                message: m,
                resolveUrl: (u) => u,
                onOpenThread: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    test('메시지 JSON의 sharedAlbum을 읽는다(없으면 null)', () {
      final m = shared();
      expect(m.sharedAlbum?.id, 'a1');
      expect(m.sharedAlbum?.title, '제주 여행');
      expect(m.sharedAlbum?.teamName, '잔디팀');
      expect(m.type, MessageType.text);
      expect(shared(albumId: null).sharedAlbum?.deleted, isTrue);
      final plain = Message.fromJson({
        'id': 'x',
        'roomId': 'r1',
        'senderName': 'a',
        'type': 'text',
        'text': 'hi',
        'createdAt': 1,
      });
      expect(plain.sharedAlbum, isNull);
    });

    testWidgets('본문 · 구분선 · "{팀}에서 공유된 앨범입니다." · 앨범 보기 · 카드, 누르면 그 앨범이 열린다', (
      tester,
    ) async {
      await pumpBubble(tester, shared());
      expect(find.text('가족 여행 사진 올렸어요'), findsOneWidget);
      expect(find.text('잔디팀에서 공유된 앨범입니다.'), findsOneWidget);
      expect(find.text('앨범 보기'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('shared-album-card')),
          matching: find.text('제주 여행'),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.photo_library_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 홈 셸이 없으면(모바일) 앨범 화면을 얹고 그 앨범을 바로 펼친다.
      await tester.tap(find.byKey(const ValueKey('shared-album-open')));
      await tester.pumpAndSettle();
      expect(find.byType(AlbumsPanel), findsOneWidget);
      expect(find.byType(AlbumDetailView), findsOneWidget);
      expect(api.calls, contains('fetchAlbum a1'));
      expect(find.byKey(const ValueKey('album-detail-title')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('카드를 눌러도 열린다', (tester) async {
      await pumpBubble(tester, shared());
      await tester.tap(find.byKey(const ValueKey('shared-album-card')));
      await tester.pumpAndSettle();
      expect(find.byType(AlbumDetailView), findsOneWidget);
      await finish(tester);
    });

    testWidgets('앨범이 지워졌으면 "삭제된 앨범입니다."만 남고 열 수 없다', (tester) async {
      await pumpBubble(tester, shared(albumId: null));
      expect(find.text('삭제된 앨범입니다.'), findsOneWidget);
      expect(find.text('앨범 보기'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('shared-album-card')));
      await tester.pumpAndSettle();
      expect(find.byType(AlbumsPanel), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('지운 메시지에는 카드가 없다', (tester) async {
      final m = Message.fromJson({
        'id': 'm1',
        'roomId': 'r1',
        'senderId': 'u2',
        'senderName': '김철수',
        'type': 'text',
        'text': null,
        'deleted': true,
        'createdAt': 1,
        'sharedAlbum': null,
      });
      await pumpBubble(tester, m);
      expect(find.byType(SharedAlbumSection), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('보기 전용(공유로만 보는 앨범)', () {
    testWidgets('파일 추가·끌어다 놓기·공유·삭제가 없고 안내 문구가 보인다', (tester) async {
      setSize(tester, const Size(1100, 800));
      final viewOnly = Album.fromJson({
        'id': 'a1',
        'teamId': 't1',
        'roomId': 'r9',
        'roomName': '다른 토픽',
        'title': '제주 여행',
        'createdAt': 1,
        'updatedAt': 1,
        'canShare': false,
        'viewOnly': true,
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AlbumDetailView(session: session)),
        ),
      );
      // 컨트롤러 상태를 직접 채운다(서버의 보기 전용 상세 흉내).
      session.albums.album = viewOnly;
      session.albums.items.addAll(api.items['a1']!);
      session.albums.itemsLoaded = true;
      session.albums.startSelecting(); // 알림으로 다시 그린다
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('album-view-only')), findsOneWidget);
      expect(find.byKey(const ValueKey('album-add-files')), findsNothing);
      expect(find.byKey(const ValueKey('album-drop-zone')), findsNothing);
      expect(
        find.byKey(const ValueKey('album-action-download')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('album-action-share')), findsNothing);
      expect(find.byKey(const ValueKey('album-action-delete')), findsNothing);
      session.albums.clearSelection();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('album-more')));
      await tester.pumpAndSettle();
      expect(find.text('전체 다운로드'), findsOneWidget);
      expect(find.text('앨범 공유'), findsNothing);
      await finish(tester);
    });
  });

  group('컨트롤러', () {
    test('열지 않은 앨범 고치기·지우기, 항목 전부 받기, 패널을 열 때 펼칠 앨범', () async {
      api.items['big'] = [
        for (var i = 0; i < 130; i++) fakeItem('b$i', 'big', minutesAgo: i),
      ];
      api.albums.add(fakeAlbum('big', title: '큰 앨범'));
      final c = session.albums;
      await c.loadAlbums();
      final updated = await c.updateAlbum(albumId: 'a2', title: ' 새 제목 ');
      expect(updated?.title, '새 제목');
      expect(c.albums.firstWhere((a) => a.id == 'a2').title, '새 제목');
      expect(c.album, isNull);

      final all = await c.fetchAllItemsOf('big');
      expect(all, hasLength(130));
      expect(all.map((i) => i.id).toSet(), hasLength(130));

      await c.deleteAlbum(albumId: 'a2');
      expect(c.albums.any((a) => a.id == 'a2'), isFalse);

      expect(c.takePendingAlbum(), isNull);
      c.openWhenPanelOpens('a1');
      expect(c.takePendingAlbum(), 'a1');
      expect(c.takePendingAlbum(), isNull); // 한 번만

      await c.shareAlbum('a1', roomId: 'r1', text: '보세요');
      expect(api.lastAlbumShare?.text, '보세요');
    });
  });
}
