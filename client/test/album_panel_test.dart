import 'dart:io';

import 'package:client/models/album.dart';
import 'package:client/models/room.dart';
import 'package:client/models/team.dart';
import 'package:client/screens/album_create_dialog.dart';
import 'package:client/services/album_controller.dart';
import 'package:client/services/album_download.dart';
import 'package:client/services/album_media.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/session.dart';
import 'package:client/widgets/album_detail_view.dart';
import 'package:client/widgets/album_share_dialog.dart';
import 'package:client/widgets/albums_panel.dart';
import 'package:client/widgets/app_menu_button.dart';
import 'package:client/widgets/room_options_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_album_api.dart';

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
  s.currentTeam = Team(id: 't1', name: '팀', createdAt: DateTime(2026));
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

Future<void> pumpPanel(
  WidgetTester tester,
  Session session, {
  String? roomId,
  Size size = const Size(360, 780),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AlbumsPanel(session: session, initialRoomId: roomId),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  late FakeAlbumApi api;
  late Session session;

  setUp(() {
    api = FakeAlbumApi();
    api.albums.addAll([
      fakeAlbum(
        'a1',
        title: '제주 여행',
        description: '가족 여행 사진',
        itemCount: 3,
        createdAt: DateTime(2026, 9, 29),
      ),
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
      fakeItem(
        'g1',
        'a1',
        minutesAgo: 2,
        fileName: 'dance.gif',
        mimeType: 'image/gif',
      ),
      fakeItem(
        'v1',
        'a1',
        kind: AlbumItemKind.video,
        durationMs: 65000,
        minutesAgo: 3,
      ),
      fakeItem('o1', 'a1', uploaderId: 'u2', minutesAgo: 4),
    ];
    session = makeSession(api);
  });

  group('목록', () {
    testWidgets('방에서 열면 그 방으로 걸러 받고, 카드에 제목·개수(왼쪽 위)·방 이름·날짜가 보인다', (
      tester,
    ) async {
      await pumpPanel(tester, session, roomId: 'r1');
      expect(api.calls.first, contains('room=r1'));
      expect(find.text('제주 여행'), findsOneWidget);
      expect(find.text('가을 소풍'), findsNothing); // 다른 방 앨범
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('album-count-a1')),
          matching: find.text('4'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('2026/09/29'), findsOneWidget);
      expect(find.textContaining('잔디톡 팀'), findsWidgets);
      expect(find.text('앨범 생성'), findsOneWidget);
      expect(find.byKey(const ValueKey('album-sort')), findsOneWidget);
      expect(find.text('업데이트 순'), findsOneWidget); // 기본 정렬
      expect(find.byKey(const ValueKey('album-view-grid')), findsOneWidget);
      expect(find.byKey(const ValueKey('album-view-list')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    });

    testWidgets('참여 대화방을 "전체"로 바꾸면 모든 방의 앨범이 보이고, 정렬을 바꿀 수 있다', (tester) async {
      await pumpPanel(tester, session, roomId: 'r1');
      await tester.tap(find.text('잔디톡 팀').first); // 필터 단추
      await tester.pumpAndSettle();
      await tester.tap(find.text('전체'));
      await tester.pumpAndSettle();
      expect(api.calls.last, contains('room=null'));
      expect(find.text('제주 여행'), findsOneWidget);
      expect(find.text('가을 소풍'), findsOneWidget);

      // 업데이트 순(기본): 제주 여행(9/29)이 먼저(두 칸이 같은 줄이면 왼쪽).
      bool before(String x, String y) {
        final p = tester.getTopLeft(find.text(x));
        final q = tester.getTopLeft(find.text(y));
        return p.dy < q.dy || (p.dy == q.dy && p.dx < q.dx);
      }

      expect(before('제주 여행', '가을 소풍'), isTrue);
      await tester.tap(find.byKey(const ValueKey('album-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('제목순'));
      await tester.pumpAndSettle();
      // 가나다순: 가을 소풍이 먼저.
      expect(before('가을 소풍', '제주 여행'), isTrue);
      await finish(tester);
    });

    testWidgets('앨범이 없으면 안내 문구', (tester) async {
      api.albums.clear();
      await pumpPanel(tester, session);
      expect(find.byKey(const ValueKey('album-empty')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('앨범 만들기: 방에서 열었으면 대화방이 고정되고, 만들면 상세로 넘어간다', (tester) async {
      await pumpPanel(tester, session, roomId: 'r1');
      await tester.tap(find.byKey(const ValueKey('album-create-button')));
      await tester.pumpAndSettle();
      // 폭 360 → 전체 화면 창. 대화방은 고정 칸.
      expect(find.byKey(const ValueKey('album-room-locked')), findsOneWidget);
      expect(find.byKey(const ValueKey('album-room-field')), findsNothing);

      FilledButton submit() => tester.widget<FilledButton>(
        find.byKey(const ValueKey('album-editor-submit')),
      );
      expect(submit().onPressed, isNull); // 제목이 비어 있다
      await tester.enterText(
        find.byKey(const ValueKey('album-title-field')),
        '새 앨범',
      );
      await tester.pump();
      expect(submit().onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('album-editor-submit')));
      await tester.pumpAndSettle();

      expect(api.calls.any((c) => c.startsWith('createAlbum r1 새 앨범')), isTrue);
      expect(find.byKey(const ValueKey('album-detail-title')), findsOneWidget);
      expect(find.text('새 앨범'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('앨범 만들기: 방이 정해지지 않았으면 대화방을 골라야 하고, 비밀 대화·읽기 전용은 고를 수 없다', (
      tester,
    ) async {
      expect(canCreateAlbumIn(session, session.rooms[0]), isTrue); // 챗 토픽
      expect(
        canCreateAlbumIn(session, session.rooms[1]),
        isTrue,
      ); // 보드 뷰 토픽도 만들 수 있다
      expect(canCreateAlbumIn(session, session.rooms[4]), isFalse); // 비밀 대화
      session.rooms[0].readOnly = true;
      expect(canCreateAlbumIn(session, session.rooms[0]), isFalse);

      await pumpPanel(tester, session);
      await tester.tap(find.byKey(const ValueKey('album-create-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('album-room-field')), findsOneWidget);
      FilledButton submit() => tester.widget<FilledButton>(
        find.byKey(const ValueKey('album-editor-submit')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('album-title-field')),
        '제목',
      );
      await tester.pump();
      expect(submit().onPressed, isNull); // 방을 안 골랐다
      await finish(tester);
    });
  });

  group('상세', () {
    Future<void> openA1(WidgetTester tester) async {
      await pumpPanel(tester, session, roomId: 'r1');
      await tester.tap(find.byKey(const ValueKey('album-card-a1')));
      await tester.pumpAndSettle();
    }

    testWidgets('제목·설명·메타와 정사각 썸네일 격자, 영상 길이·GIF 표시', (tester) async {
      await openA1(tester);
      expect(find.byKey(const ValueKey('album-detail-title')), findsOneWidget);
      expect(find.text('제주 여행'), findsOneWidget);
      expect(find.text('가족 여행 사진'), findsOneWidget);
      expect(find.byKey(const ValueKey('album-meta')), findsOneWidget);
      expect(find.byKey(const ValueKey('album-add-files')), findsOneWidget);
      expect(find.byKey(const ValueKey('album-select')), findsOneWidget);
      // 드래그 앤 드롭 영역(PC).
      expect(find.byKey(const ValueKey('album-drop-zone')), findsOneWidget);
      for (final id in ['p1', 'g1', 'v1', 'o1']) {
        expect(find.byKey(ValueKey('album-item-$id')), findsOneWidget);
      }
      // 정사각
      final size = tester.getSize(find.byKey(const ValueKey('album-item-p1')));
      expect(size.width, size.height);
      expect(find.text('1:05'), findsOneWidget);
      expect(find.text('GIF'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);

      // ⋯ 메뉴: 내가 만든 앨범이라 전체 다운로드·앨범 공유·앨범 수정·앨범 삭제가 있다.
      await tester.tap(find.byKey(const ValueKey('album-more')));
      await tester.pumpAndSettle();
      expect(find.text('전체 다운로드'), findsOneWidget);
      expect(find.text('앨범 공유'), findsOneWidget);
      expect(find.text('앨범 수정'), findsOneWidget);
      expect(find.text('앨범 삭제'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      // 뒤로가기 → 목록.
      await tester.tap(find.byKey(const ValueKey('album-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('album-grid')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('남이 만든 앨범에서는 수정·삭제 메뉴가 없다', (tester) async {
      await pumpPanel(tester, session);
      await tester.tap(find.byKey(const ValueKey('album-card-a2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('album-more')));
      await tester.pumpAndSettle();
      expect(find.text('앨범 수정'), findsNothing);
      expect(find.text('앨범 삭제'), findsNothing);
      expect(find.text('전체 다운로드'), findsOneWidget);
      expect(find.text('앨범 공유'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('선택 모드: 체크·개수, 권한 없는 항목만이면 삭제 불가', (tester) async {
      // 남이 만든 앨범 — 내 항목만 지울 수 있다.
      api.albums.add(
        fakeAlbum('a3', title: '남의 앨범', creatorId: 'u2', itemCount: 2),
      );
      api.items['a3'] = [
        fakeItem('mine', 'a3', minutesAgo: 1),
        fakeItem('other', 'a3', uploaderId: 'u2', minutesAgo: 2),
      ];
      await pumpPanel(tester, session, roomId: 'r1');
      await tester.tap(find.byKey(const ValueKey('album-card-a3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('album-select')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('album-check-mine')), findsOneWidget);
      expect(find.byKey(const ValueKey('album-selection-bar')), findsOneWidget);
      expect(find.text('0개 선택'), findsOneWidget);

      InkWell action(String name) =>
          tester.widget<InkWell>(find.byKey(ValueKey('album-action-$name')));
      expect(action('download').onTap, isNull); // 아무것도 안 골랐다
      expect(action('delete').onTap, isNull);

      // 남이 올린 항목만 고르면 삭제 비활성(내가 만든 앨범이 아니라 대표로도 없다).
      await tester.tap(find.byKey(const ValueKey('album-item-other')));
      await tester.pump();
      expect(find.text('1개 선택'), findsOneWidget);
      expect(action('download').onTap, isNotNull);
      expect(action('share').onTap, isNotNull);
      expect(action('delete').onTap, isNull);
      expect(find.byKey(const ValueKey('album-action-cover')), findsNothing);

      // 내 항목을 더하면 삭제 가능.
      await tester.tap(find.byKey(const ValueKey('album-item-mine')));
      await tester.pump();
      expect(find.text('2개 선택'), findsOneWidget);
      expect(action('delete').onTap, isNotNull);
      // 섞여 있으면 확인 문구에 개수가 나오고, 권한 있는 것만 지운다.
      await tester.tap(find.byKey(const ValueKey('album-action-delete')));
      await tester.pumpAndSettle();
      expect(
        find.text('선택한 2개 중 내가 지울 수 있는 1개만 삭제됩니다. 계속할까요?'),
        findsOneWidget,
      );
      await tester.tap(find.text('삭제').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('album-item-mine')), findsNothing);
      expect(find.byKey(const ValueKey('album-item-other')), findsOneWidget);
      expect(find.textContaining('권한이 없는 1개는 남겼습니다'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await finish(tester);
    });

    testWidgets('내가 만든 앨범에서 이미지 한 장을 고르면 "대표로"가 보인다', (tester) async {
      await openA1(tester);
      await tester.tap(find.byKey(const ValueKey('album-select')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('album-item-p1')));
      await tester.pump();
      expect(find.byKey(const ValueKey('album-action-cover')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('album-action-cover')));
      await tester.pumpAndSettle();
      expect(
        api.calls.any(
          (c) => c.startsWith('updateAlbum a1') && c.contains('cover=p1'),
        ),
        isTrue,
      );
      await tester.pump(const Duration(seconds: 3));
      await finish(tester);
    });

    testWidgets('권한 있는 것만 지운다 — 섞여 있으면 확인 문구에 개수가 나온다', (tester) async {
      await openA1(tester);
      await tester.tap(find.byKey(const ValueKey('album-select')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('album-select-all')));
      await tester.pump();
      expect(find.text('4개 선택'), findsOneWidget);
      // 내 앨범이라 앨범 만든 사람은 남의 항목도 지울 수 있다(서버 규칙) — 전부 삭제 가능.
      await tester.tap(find.byKey(const ValueKey('album-action-delete')));
      await tester.pumpAndSettle();
      expect(find.text('선택한 4개를 앨범에서 삭제할까요?'), findsOneWidget);
      await tester.tap(find.text('삭제').last);
      await tester.pumpAndSettle();
      expect(api.calls.any((c) => c.startsWith('deleteItems a1')), isTrue);
      expect(find.byKey(const ValueKey('album-item-p1')), findsNothing);
      await finish(tester);
    });

    testWidgets('공유: 10개 넘게 고르면 안내만, 고르면 공유 창에서 방을 골라 보낸다', (tester) async {
      api.items['a1'] = [
        for (var i = 0; i < 12; i++) fakeItem('x$i', 'a1', minutesAgo: i),
      ];
      await openA1(tester);
      await tester.tap(find.byKey(const ValueKey('album-select')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('album-select-all')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('album-action-share')));
      await tester.pump();
      expect(find.text('한 번에 10개까지 공유할 수 있습니다.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));

      await tester.tap(find.byKey(const ValueKey('album-select-all'))); // 해제
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('album-item-x0')));
      await tester.tap(find.byKey(const ValueKey('album-item-x1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('album-action-share')));
      await tester.pumpAndSettle();
      expect(find.text('대화방에 공유'), findsOneWidget);
      FilledButton send() => tester.widget<FilledButton>(
        find.byKey(const ValueKey('album-share-send')),
      );
      expect(send().onPressed, isNull); // 방을 안 골랐다

      await tester.tap(find.byKey(const ValueKey('album-share-room-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('잔디톡 팀'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('album-share-send')));
      await tester.pumpAndSettle();
      expect(api.lastShare?.roomId, 'r1');
      expect(api.lastShare?.itemIds, ['x0', 'x1']);
      expect(find.textContaining('2개를 공유했습니다'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await finish(tester);
    });

    testWidgets('공유 대화방 목록: 챗 뷰 토픽·그룹·1:1만, 보드 뷰 토픽과 비밀 대화는 빠진다', (
      tester,
    ) async {
      final album = api.albums.first;
      expect(canShareAlbumTo(session, session.rooms[0], album), isTrue);
      expect(
        canShareAlbumTo(session, session.rooms[1], album),
        isFalse,
      ); // 보드 뷰
      expect(canShareAlbumTo(session, session.rooms[2], album), isTrue); // 그룹
      expect(canShareAlbumTo(session, session.rooms[3], album), isTrue); // 1:1
      expect(
        canShareAlbumTo(session, session.rooms[4], album),
        isFalse,
      ); // 비밀 대화

      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAlbumShareDialog(
                  context,
                  session: session,
                  album: album,
                  itemIds: const ['p1'],
                ),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('album-share-room-field')));
      await tester.pumpAndSettle();
      // 토픽 탭: 챗 뷰 토픽만.
      expect(find.text('잔디톡 팀'), findsOneWidget);
      expect(find.text('공지 게시판'), findsNothing);
      // 그룹채팅 탭.
      await tester.tap(find.text('그룹채팅'));
      await tester.pumpAndSettle();
      expect(find.text('디자인 그룹'), findsOneWidget);
      // 채팅 탭: 1:1은 있고 비밀 대화는 없다.
      await tester.tap(find.text('채팅'));
      await tester.pumpAndSettle();
      expect(find.text('김철수'), findsOneWidget);
      expect(find.text('비밀 친구'), findsNothing);
      await finish(tester);
    });

    testWidgets('업로드 실패는 카드에 남아 재시도·건너뛰기가 된다', (tester) async {
      api.failOnceNames.add('bad.png');
      await openA1(tester);
      session.albums.addFiles([File('ok.png'), File('bad.png')]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('album-uploads')), findsOneWidget);
      expect(find.text('업로드 1개 실패'), findsOneWidget);
      expect(find.text('bad.png'), findsOneWidget);
      expect(find.text('재시도'), findsOneWidget);

      await tester.tap(find.text('재시도'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('album-uploads')), findsNothing);
      expect(api.callCount('addItems'), 2);
      await finish(tester);
    });

    testWidgets('다른 사람이 앨범을 지우면 안내가 뜬다', (tester) async {
      await openA1(tester);
      session.albums.handleChanged(
        const AlbumChangedEvent(
          teamId: 't1',
          roomId: 'r1',
          albumId: 'a1',
          kind: AlbumChangeKind.deleted,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('album-gone')), findsOneWidget);
      await finish(tester);
    });
  });

  group('메뉴·방 더보기', () {
    testWidgets('"메뉴"의 리스트 묶음에 앨범 타일이 있다', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(actions: [AppMenuButton(session: session)]),
          ),
        ),
      );
      await tester.tap(find.byTooltip('메뉴'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('menu-albums')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('menu-albums')));
      await tester.pumpAndSettle();
      expect(find.byType(AlbumsPanel), findsOneWidget);
      await finish(tester);
    });

    testWidgets('방 더보기 메뉴에 "앨범 보기"가 있고(비밀 대화에는 없다), 누르면 그 방으로 연다', (
      tester,
    ) async {
      Room? opened;
      Future<void> pumpMenu(Room r) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              appBar: AppBar(
                actions: [
                  RoomOptionsMenu(
                    session: session,
                    room: r,
                    onOpenAlbums: (x) => opened = x,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('더보기'));
        await tester.pumpAndSettle();
      }

      await pumpMenu(session.rooms[0]);
      expect(find.text('앨범 보기'), findsOneWidget);
      await tester.tap(find.text('앨범 보기'));
      await tester.pumpAndSettle();
      expect(opened?.id, 'r1');

      await pumpMenu(session.rooms[4]); // 비밀 대화
      expect(find.text('앨범 보기'), findsNothing);
      await finish(tester);
    });
  });

  group('내려받기', () {
    test('폴더에 차례로 저장하고, 이름이 겹치면 번호를 붙이며, 하나가 실패해도 계속한다', () async {
      final dir = await Directory.systemTemp.createTemp('album_dl_test_');
      addTearDown(() => dir.delete(recursive: true));
      final items = [
        fakeItem('a', 'x', fileName: 'photo.png'),
        fakeItem('b', 'x', fileName: 'photo.png'),
        fakeItem('c', 'x', fileName: 'broken.png'),
      ];
      final progress = <int>[];
      final summary = await saveAlbumItemsToFolder(
        items: items,
        folder: dir.path,
        fetch: (item) async {
          if (item.id == 'c') throw Exception('만료');
          return [1, 2, 3];
        },
        onProgress: (done, total) => progress.add(done),
      );
      expect(summary.saved, 2);
      expect(summary.failed, 1);
      expect(progress, [0, 1, 2, 3]);
      final names =
          dir
              .listSync()
              .map((e) => e.path.split(RegExp(r'[\\/]')).last)
              .toList()
            ..sort();
      expect(names, ['photo (1).png', 'photo.png']);
    });

    test('파일 이름이 없으면 종류에 맞는 임시 이름', () {
      final img = AlbumItem.fromJson({
        'id': 'i',
        'albumId': 'a',
        'kind': 'image',
        'fileUrl': '/files/x',
        'mimeType': 'image/jpeg',
        'createdAt': 1,
      });
      expect(albumItemFileName(img, 2), 'album_3.jpg');
    });
  });

  testWidgets('AlbumItemTile 단독: 선택된 칸은 체크 표시', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 100,
            height: 100,
            child: AlbumItemTile(
              item: fakeItem('p1', 'a1'),
              resolveUrl: (u) => 'https://test.local$u',
              selecting: true,
              selected: true,
              onTap: () {},
              onLongPress: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
