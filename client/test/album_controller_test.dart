import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client/models/album.dart';
import 'package:client/services/album_api.dart';
import 'package:client/services/album_controller.dart';
import 'package:client/services/album_media.dart';
import 'package:client/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers/fake_album_api.dart';

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  remoteApiTests();

  late FakeAlbumApi api;
  late StreamController<AlbumChangedEvent> changes;
  late AlbumController controller;

  setUp(() {
    api = FakeAlbumApi();
    changes = StreamController<AlbumChangedEvent>.broadcast();
    controller = AlbumController(
      apiProvider: () => api,
      teamIdProvider: () => 't1',
      changed: changes.stream,
      preparer: (file, kind) async => const AlbumImagePrep(),
    );
  });

  tearDown(() {
    controller.dispose();
    changes.close();
  });

  group('모델', () {
    test('Album·AlbumItem JSON을 읽는다', () {
      final album = Album.fromJson({
        'id': 'a1',
        'teamId': 't1',
        'roomId': 'r1',
        'roomName': '잔디톡 팀',
        'title': '여행',
        'description': null,
        'itemCount': 3,
        'createdAt': 1000,
        'updatedAt': 2000,
        'canEdit': true,
      });
      expect(album.itemCount, 3);
      expect(album.canEdit, isTrue);
      expect(album.canDelete, isFalse);
      expect(album.description, isNull);

      final video = AlbumItem.fromJson({
        'id': 'i1',
        'albumId': 'a1',
        'kind': 'video',
        'fileUrl': '/files/x',
        'durationMs': 65000,
        'createdAt': 1,
      });
      expect(video.isVideo, isTrue);
      expect(video.isGif, isFalse);
      final gif = AlbumItem.fromJson({
        'id': 'i2',
        'albumId': 'a1',
        'kind': 'image',
        'fileUrl': '/files/y',
        'mimeType': 'image/gif',
        'createdAt': 1,
      });
      expect(gif.isGif, isTrue);
    });

    test('영상 길이는 m:ss(1시간 넘으면 h:mm:ss)', () {
      expect(formatAlbumDuration(65000), '1:05');
      expect(formatAlbumDuration(9000), '0:09');
      expect(formatAlbumDuration(3725000), '1:02:05');
      expect(formatAlbumDuration(null), '');
    });

    test('AlbumItemDraft는 없는 값을 빼고 직렬화한다', () {
      final json = const AlbumItemDraft(
        kind: AlbumItemKind.image,
        fileUrl: '/uploads/a.png',
        fileName: 'a.png',
        fileSize: 10,
        mimeType: 'image/png',
      ).toJson();
      expect(json['kind'], 'image');
      expect(json.containsKey('thumbnailUrl'), isFalse);
      expect(json.containsKey('durationMs'), isFalse);
    });

    test('확장자로 이미지·GIF·영상을 알아본다', () {
      expect(albumMimeForPath(r'C:\a\b.JPG'), 'image/jpeg');
      expect(albumMimeForPath('x.gif'), 'image/gif');
      expect(albumMimeForPath('x.mp4'), 'video/mp4');
      expect(albumMimeForPath('x.pdf'), isNull);
      expect(albumMimeForPath('noext'), isNull);
      expect(albumKindForMime('video/quicktime'), AlbumItemKind.video);
    });
  });

  group('목록', () {
    test('방으로 걸러 받고, 다음 쪽을 이어 붙인다', () async {
      for (var i = 0; i < 35; i++) {
        api.albums.add(
          fakeAlbum(
            'a$i',
            roomId: i.isEven ? 'r1' : 'r2',
            createdAt: DateTime(2026, 1, 1).add(Duration(hours: i)),
          ),
        );
      }
      await controller.loadAlbums();
      expect(controller.albums.length, 30);
      expect(controller.listHasMore, isTrue);
      // 최신순
      expect(controller.albums.first.id, 'a34');
      await controller.loadMoreAlbums();
      expect(controller.albums.length, 35);
      expect(controller.listHasMore, isFalse);

      await controller.loadAlbums(roomId: 'r1');
      expect(controller.albums.length, 18);
      expect(controller.albums.every((a) => a.roomId == 'r1'), isTrue);
      expect(api.calls.any((c) => c.contains('room=r1')), isTrue);
    });

    test('만들면 목록 맨 앞에 들어간다', () async {
      await controller.loadAlbums();
      final created = await controller.createAlbum(
        'r1',
        title: ' 새 앨범 ',
        description: '설명',
      );
      expect(created.title, '새 앨범');
      expect(controller.albums.first.id, created.id);
    });
  });

  group('앨범 열기', () {
    test('항목을 60개씩 이어 받는다', () async {
      api.albums.add(fakeAlbum('a1'));
      api.items['a1'] = [
        for (var i = 0; i < 70; i++) fakeItem('i$i', 'a1', minutesAgo: i),
      ];
      await controller.openAlbum(api.albums.first);
      expect(controller.album?.id, 'a1');
      expect(controller.items.length, 60);
      expect(controller.itemsHasMore, isTrue);
      await controller.loadMoreItems();
      expect(controller.items.length, 70);
      expect(controller.itemsHasMore, isFalse);
      expect(controller.items.first.id, 'i0'); // 최신이 앞
    });

    test('다른 사람이 지운 앨범은 albumGone이 된다', () async {
      api.albums.add(fakeAlbum('a1'));
      await controller.openAlbum(api.albums.first);
      expect(controller.albumGone, isFalse);
      changes.add(
        const AlbumChangedEvent(
          teamId: 't1',
          roomId: 'r1',
          albumId: 'a1',
          kind: AlbumChangeKind.deleted,
        ),
      );
      await settle();
      expect(controller.albumGone, isTrue);
    });

    test('소켓 items 이벤트면 열려 있는 항목을 새로 받고, 다른 팀 이벤트는 무시한다', () async {
      api.albums.add(fakeAlbum('a1'));
      api.items['a1'] = [fakeItem('i1', 'a1')];
      await controller.openAlbum(api.albums.first);
      expect(controller.items.length, 1);

      api.items['a1']!.add(fakeItem('i2', 'a1', minutesAgo: 5));
      changes.add(
        const AlbumChangedEvent(
          teamId: 'other',
          roomId: 'r1',
          albumId: 'a1',
          kind: AlbumChangeKind.items,
        ),
      );
      await settle();
      expect(controller.items.length, 1);

      changes.add(
        const AlbumChangedEvent(
          teamId: 't1',
          roomId: 'r1',
          albumId: 'a1',
          kind: AlbumChangeKind.items,
        ),
      );
      await settle();
      expect(controller.items.length, 2);
      expect(controller.album?.itemCount, 2);
    });

    test('열려 있는 목록도 소켓으로 새로 고친다', () async {
      api.albums.add(fakeAlbum('a1'));
      await controller.loadAlbums();
      expect(controller.albums.length, 1);
      api.albums.add(fakeAlbum('a2', createdAt: DateTime(2026, 10, 1)));
      changes.add(
        const AlbumChangedEvent(
          teamId: 't1',
          roomId: 'r1',
          albumId: 'a2',
          kind: AlbumChangeKind.created,
        ),
      );
      await settle();
      expect(controller.albums.map((a) => a.id), ['a2', 'a1']);
    });
  });

  group('올리기', () {
    List<File> files(int n, {String ext = 'png'}) => [
      for (var i = 0; i < n; i++) File('f$i.$ext'),
    ];

    test('한 번에 100개까지만 올리고 넘는 만큼은 알린다', () async {
      api.albums.add(fakeAlbum('a1'));
      await controller.openAlbum(api.albums.first);
      final result = controller.addFiles(files(130));
      expect(result.accepted, 100);
      expect(result.overLimit, 30);
      expect(result.unsupported, 0);
      await settle();
      // 올라간 100개를 한 번에 앨범에 담는다.
      expect(api.callCount('addItems'), 1);
      expect(api.lastAdded.length, 100);
      expect(controller.uploads, isEmpty);
      expect(controller.items.length, 60); // 첫 쪽
      expect(controller.album?.itemCount, 100);
    });

    test('이미지·영상이 아닌 파일은 뺀다', () async {
      api.albums.add(fakeAlbum('a1'));
      await controller.openAlbum(api.albums.first);
      final result = controller.addFiles([
        File('a.png'),
        File('b.pdf'),
        File('c.mp4'),
        File('d.txt'),
      ]);
      expect(result.accepted, 2);
      expect(result.unsupported, 2);
      await settle();
      expect(api.lastAdded.map((d) => d.kind), [
        AlbumItemKind.image,
        AlbumItemKind.video,
      ]);
      expect(api.lastAdded.last.mimeType, 'video/mp4');
    });

    test('동시에 여러 개를 올리되 3개를 넘기지 않는다', () async {
      api.albums.add(fakeAlbum('a1'));
      api.uploadDelay = const Duration(milliseconds: 5);
      await controller.openAlbum(api.albums.first);
      controller.addFiles(files(10));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await settle();
      expect(api.maxConcurrentUploads, greaterThan(1));
      expect(api.maxConcurrentUploads, lessThanOrEqualTo(3));
      expect(api.uploaded.length, 10);
      expect(controller.album?.itemCount, 10);
    });

    test('실패한 파일은 재시도하거나 건너뛸 수 있다', () async {
      api.albums.add(fakeAlbum('a1'));
      api.failOnceNames.addAll({'f1.png', 'f2.png'});
      await controller.openAlbum(api.albums.first);
      controller.addFiles(files(3));
      await settle();
      // 성공한 1개만 담겼고, 실패한 2개는 목록에 남는다.
      expect(api.lastAdded.length, 1);
      final failed = controller.uploads
          .where((u) => u.status == AlbumUploadStatus.failed)
          .toList();
      expect(failed.length, 2);
      expect(failed.first.error, contains('네트워크 오류'));

      controller.retryUpload(failed.first.id);
      controller.skipUpload(failed.last.id);
      await settle();
      expect(controller.uploads, isEmpty);
      expect(controller.album?.itemCount, 2);
      expect(api.callCount('addItems'), 2);
    });

    test('파일은 올라갔는데 담기에 실패하면 다시 올리지 않고 담기만 재시도한다', () async {
      api.albums.add(fakeAlbum('a1'));
      api.failAddItems = true;
      await controller.openAlbum(api.albums.first);
      controller.addFiles(files(2));
      await settle();
      expect(controller.uploads.length, 2);
      expect(
        controller.uploads.every((u) => u.status == AlbumUploadStatus.failed),
        isTrue,
      );
      expect(controller.uploads.first.error, contains('앨범에 담지 못했습니다'));

      api.failAddItems = false;
      final uploadsBefore = api.callCount('upload');
      for (final u in List.of(controller.uploads)) {
        controller.retryUpload(u.id);
      }
      await settle();
      expect(api.callCount('upload'), uploadsBefore); // 다시 올리지 않았다
      expect(controller.uploads, isEmpty);
      expect(controller.album?.itemCount, 2);
    });
  });

  group('선택·삭제·공유', () {
    setUp(() async {
      api.albums.add(fakeAlbum('a1', creatorId: 'someone'));
      api.items['a1'] = [
        fakeItem('mine1', 'a1', minutesAgo: 1),
        fakeItem('mine2', 'a1', minutesAgo: 2),
        fakeItem('other', 'a1', uploaderId: 'u2', minutesAgo: 3),
      ];
      await controller.openAlbum(api.albums.first);
    });

    test('선택 모드: 토글·전체 선택·해제', () {
      controller.startSelecting();
      controller.toggleSelected('mine1');
      expect(controller.selectedIds, {'mine1'});
      controller.selectAll();
      expect(controller.selectedIds.length, 3);
      controller.deselectAll();
      expect(controller.selecting, isTrue);
      expect(controller.selectedIds, isEmpty);
      controller.clearSelection();
      expect(controller.selecting, isFalse);
    });

    test('남이 올린 항목은 내 canDelete가 false다', () {
      final byId = {for (final i in controller.items) i.id: i};
      expect(byId['mine1']!.canDelete, isTrue);
      expect(byId['other']!.canDelete, isFalse);
    });

    test('권한 있는 것만 지우고 나머지는 skipped로 센다', () async {
      final result = await controller.deleteItems(['mine1', 'other']);
      expect(result.deleted, 1);
      expect(result.skipped, 1);
      expect(controller.items.map((i) => i.id), ['mine2', 'other']);
    });

    test('관리자는 남의 항목도 지운다', () async {
      api.admin = true;
      await controller.reloadAlbum();
      final result = await controller.deleteItems(['other']);
      expect(result.deleted, 1);
      expect(result.skipped, 0);
    });

    test('공유는 선택한 항목 id와 방을 서버에 보낸다', () async {
      await controller.shareItems('r2', ['mine1', 'mine2']);
      expect(api.lastShare?.roomId, 'r2');
      expect(api.lastShare?.itemIds, ['mine1', 'mine2']);
    });

    test('서버가 공유를 거절하면 문구 그대로 예외가 난다', () async {
      api.rejectShareRooms.add('board');
      expect(
        () => controller.shareItems('board', ['mine1']),
        throwsA(predicate((e) => '$e'.contains('보드 뷰'))),
      );
    });

    test('앨범 삭제는 목록에서도 빼고 상세를 닫는다', () async {
      await controller.loadAlbums();
      expect(controller.albums, isNotEmpty);
      api.admin = true;
      await controller.deleteAlbum();
      expect(controller.album, isNull);
      expect(controller.albums, isEmpty);
    });
  });

  group('팀·로그아웃', () {
    test('invalidate는 목록과 열어 둔 앨범을 비운다', () async {
      api.albums.add(fakeAlbum('a1'));
      await controller.loadAlbums();
      await controller.openAlbum(api.albums.first);
      controller.invalidate();
      expect(controller.albums, isEmpty);
      expect(controller.album, isNull);
      expect(controller.listLoaded, isFalse);
    });

    test('reset은 올리던 파일도 취소하고 비운다', () async {
      api.albums.add(fakeAlbum('a1'));
      api.uploadDelay = const Duration(milliseconds: 30);
      await controller.openAlbum(api.albums.first);
      controller.addFiles([File('a.png')]);
      controller.reset();
      expect(controller.uploads, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  });
}

/// RemoteAlbumApi가 서버 REST 규격(경로·메서드·본문)대로 부르는지 — MockClient로 가로채 확인한다.
void remoteApiTests() {
  group('RemoteAlbumApi', () {
    late List<http.Request> requests;
    late RemoteAlbumApi remote;

    setUp(() {
      requests = [];
      final client = MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        Map<String, dynamic> body = {};
        if (path == '/api/albums' && request.method == 'GET') {
          body = {
            'albums': [
              {
                'id': 'a1',
                'teamId': 't1',
                'roomId': 'r1',
                'title': '여행',
                'itemCount': 2,
                'createdAt': 5,
                'updatedAt': 5,
              },
            ],
            'hasMore': true,
          };
        } else if (request.method == 'DELETE' && path.endsWith('/items')) {
          body = {'deleted': 1, 'skipped': 2};
        } else if (path.endsWith('/items') && request.method == 'POST') {
          body = {
            'items': [
              {
                'id': 'i1',
                'albumId': 'a1',
                'kind': 'image',
                'fileUrl': '/files/x',
                'createdAt': 1,
              },
            ],
          };
        } else if (path.endsWith('/albums') || request.method == 'PATCH') {
          body = {
            'id': 'a1',
            'roomId': 'r1',
            'title': '제목',
            'createdAt': 1,
            'updatedAt': 1,
          };
        }
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      remote = RemoteAlbumApi(
        ApiClient(
          baseUrl: 'https://test.local',
          token: 't',
          httpClient: client,
        ),
      );
    });

    test('목록: teamId·roomId·before·limit을 쿼리로 보낸다', () async {
      final page = await remote.fetchAlbums(
        teamId: 't1',
        roomId: 'r1',
        before: 99,
        limit: 10,
      );
      final q = requests.single.url.queryParameters;
      expect(q, {
        'teamId': 't1',
        'roomId': 'r1',
        'before': '99',
        'limit': '10',
      });
      expect(page.albums.single.title, '여행');
      expect(page.hasMore, isTrue);
    });

    test('항목 삭제는 DELETE 본문에 itemIds를 싣고 skipped를 읽는다', () async {
      final result = await remote.deleteItems('a1', ['i1', 'i2', 'i3']);
      final req = requests.single;
      expect(req.method, 'DELETE');
      expect(req.url.path, '/api/albums/a1/items');
      expect(jsonDecode(req.body), {
        'itemIds': ['i1', 'i2', 'i3'],
      });
      expect(result.deleted, 1);
      expect(result.skipped, 2);
    });

    test('항목 추가·만들기·수정·공유의 경로와 본문', () async {
      await remote.addItems('a1', [
        const AlbumItemDraft(
          kind: AlbumItemKind.video,
          fileUrl: '/uploads/v.mp4',
          fileName: 'v.mp4',
          fileSize: 5,
          mimeType: 'video/mp4',
        ),
      ]);
      expect(requests.last.url.path, '/api/albums/a1/items');
      expect(jsonDecode(requests.last.body)['items'][0]['kind'], 'video');

      await remote.createAlbum('r1', title: '제목', description: '설명');
      expect(requests.last.url.path, '/api/rooms/r1/albums');
      expect(jsonDecode(requests.last.body), {
        'title': '제목',
        'description': '설명',
      });

      await remote.updateAlbum('a1', coverItemId: '');
      expect(requests.last.method, 'PATCH');
      expect(jsonDecode(requests.last.body), {'coverItemId': null});

      await remote.share('a1', roomId: 'r2', itemIds: ['i1']);
      expect(requests.last.url.path, '/api/albums/a1/share');
      expect(jsonDecode(requests.last.body), {
        'roomId': 'r2',
        'itemIds': ['i1'],
      });
    });
  });
}
