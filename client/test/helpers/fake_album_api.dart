import 'package:client/models/album.dart';
import 'package:client/services/album_api.dart';
import 'package:client/services/api_client.dart'
    show ApiException, UploadCancelToken, UploadResult;
import 'package:cross_file/cross_file.dart';

/// 서버 없이 앨범 컨트롤러·화면을 시험하는 가짜 API. 앨범과 항목은 메모리에 들고 있고, 목록·항목 조회는 진짜 서버처럼
/// roomId·before·limit을 지켜 최신순으로 돌려준다. 항목의 `canDelete`는 서버와 같은 규칙(올린 사람·앨범 만든 사람·
/// 관리자)으로 보는 사람([me]) 기준으로 채운다.
class FakeAlbumApi implements AlbumApi {
  FakeAlbumApi({
    this.me = 'me',
    this.admin = false,
    List<Album>? albums,
    Map<String, List<AlbumItem>>? items,
  }) : albums = albums ?? [],
       items = items ?? {};

  final String me;

  /// 내가 팀 관리자인지(남의 항목·앨범도 지울 수 있다).
  bool admin;
  final List<Album> albums;

  /// 앨범 id → 항목(순서 상관 없음 — 조회할 때 최신순으로 정렬한다).
  final Map<String, List<AlbumItem>> items;

  /// 호출 기록 — "메서드명 인자…" 문자열.
  final calls = <String>[];

  /// 마지막 addItems 요청 내용 / 올린 파일 이름들 / 마지막 공유 요청.
  List<AlbumItemDraft> lastAdded = [];
  final uploaded = <String>[];
  ({String roomId, List<String> itemIds})? lastShare;

  /// 이 이름의 파일은 처음 한 번 올리기에 실패한다(재시도하면 성공).
  final failOnceNames = <String>{};

  /// true면 addItems가 실패한다.
  bool failAddItems = false;

  /// 이 방으로의 공유는 거절한다(서버의 보드 뷰·비밀 대화 거절 흉내).
  final rejectShareRooms = <String>{};

  /// 동시에 진행 중이던 업로드의 최대치 — 동시성 시험용. [uploadDelay]가 있어야 의미가 있다.
  int maxConcurrentUploads = 0;
  int _running = 0;
  Duration? uploadDelay;

  int _seq = 0;

  int callCount(String prefix) =>
      calls.where((c) => c.startsWith(prefix)).length;

  Album _withPerms(Album a) => Album(
    id: a.id,
    teamId: a.teamId,
    roomId: a.roomId,
    roomName: a.roomName,
    creatorId: a.creatorId,
    creatorName: a.creatorName,
    title: a.title,
    description: a.description,
    coverItemId: a.coverItemId,
    coverUrl: a.coverUrl,
    itemCount: (items[a.id] ?? const []).length,
    createdAt: a.createdAt,
    updatedAt: a.updatedAt,
    canEdit: a.creatorId == me || admin,
    canDelete: a.creatorId == me || admin,
    canDeleteAnyItem: a.creatorId == me || admin,
  );

  bool _canDeleteItem(Album a, AlbumItem i) =>
      i.uploaderId == me || a.creatorId == me || admin;

  AlbumItem _forViewer(Album a, AlbumItem i) => AlbumItem(
    id: i.id,
    albumId: i.albumId,
    uploaderId: i.uploaderId,
    uploaderName: i.uploaderName,
    kind: i.kind,
    fileUrl: i.fileUrl,
    fileName: i.fileName,
    fileSize: i.fileSize,
    mimeType: i.mimeType,
    thumbnailUrl: i.thumbnailUrl,
    width: i.width,
    height: i.height,
    durationMs: i.durationMs,
    createdAt: i.createdAt,
    canDelete: _canDeleteItem(a, i),
  );

  Album _album(String id) {
    final a = albums.where((a) => a.id == id).firstOrNull;
    if (a == null) throw const ApiException('앨범을 찾을 수 없습니다.');
    return a;
  }

  @override
  Future<({List<Album> albums, bool hasMore})> fetchAlbums({
    required String teamId,
    String? roomId,
    int? before,
    int limit = 30,
  }) async {
    calls.add('fetchAlbums room=$roomId before=$before limit=$limit');
    final matching =
        [
          for (final a in albums)
            if (a.teamId == teamId &&
                (roomId == null || a.roomId == roomId) &&
                (before == null || a.createdAt.millisecondsSinceEpoch < before))
              _withPerms(a),
        ]..sort((a, b) {
          final byTime = b.createdAt.compareTo(a.createdAt);
          return byTime != 0 ? byTime : b.id.compareTo(a.id);
        });
    return (
      albums: matching.take(limit).toList(),
      hasMore: matching.length > limit,
    );
  }

  @override
  Future<Album> fetchAlbum(String albumId) async {
    calls.add('fetchAlbum $albumId');
    return _withPerms(_album(albumId));
  }

  @override
  Future<({List<AlbumItem> items, bool hasMore})> fetchItems(
    String albumId, {
    int? before,
    int limit = 60,
  }) async {
    calls.add('fetchItems $albumId before=$before limit=$limit');
    final album = _album(albumId);
    final matching =
        [
          for (final i in items[albumId] ?? const <AlbumItem>[])
            if (before == null || i.createdAt.millisecondsSinceEpoch < before)
              _forViewer(album, i),
        ]..sort((a, b) {
          final byTime = b.createdAt.compareTo(a.createdAt);
          return byTime != 0 ? byTime : b.id.compareTo(a.id);
        });
    return (
      items: matching.take(limit).toList(),
      hasMore: matching.length > limit,
    );
  }

  @override
  Future<Album> createAlbum(
    String roomId, {
    required String title,
    String? description,
  }) async {
    calls.add('createAlbum $roomId $title');
    final created = Album(
      id: 'new-${++_seq}',
      teamId: 't1',
      roomId: roomId,
      roomName: '방',
      creatorId: me,
      creatorName: '나',
      title: title,
      description: description == null || description.isEmpty
          ? null
          : description,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    albums.add(created);
    return _withPerms(created);
  }

  @override
  Future<Album> updateAlbum(
    String albumId, {
    String? title,
    String? description,
    String? coverItemId,
  }) async {
    calls.add('updateAlbum $albumId title=$title cover=$coverItemId');
    final i = albums.indexWhere((a) => a.id == albumId);
    final a = _album(albumId);
    albums[i] = Album(
      id: a.id,
      teamId: a.teamId,
      roomId: a.roomId,
      roomName: a.roomName,
      creatorId: a.creatorId,
      creatorName: a.creatorName,
      title: title ?? a.title,
      description: description ?? a.description,
      coverItemId: coverItemId == null
          ? a.coverItemId
          : (coverItemId.isEmpty ? null : coverItemId),
      coverUrl: a.coverUrl,
      createdAt: a.createdAt,
      updatedAt: DateTime.now(),
    );
    return _withPerms(albums[i]);
  }

  @override
  Future<void> deleteAlbum(String albumId) async {
    calls.add('deleteAlbum $albumId');
    albums.removeWhere((a) => a.id == albumId);
    items.remove(albumId);
  }

  @override
  Future<List<AlbumItem>> addItems(
    String albumId,
    List<AlbumItemDraft> drafts,
  ) async {
    calls.add('addItems $albumId n=${drafts.length}');
    if (failAddItems) throw const ApiException('서버 오류');
    if (drafts.length > albumUploadMaxCount) {
      throw const ApiException('한 번에 100개까지 올릴 수 있습니다.');
    }
    lastAdded = drafts;
    final list = items.putIfAbsent(albumId, () => []);
    final base = DateTime.now().millisecondsSinceEpoch;
    final added = <AlbumItem>[];
    for (var i = 0; i < drafts.length; i++) {
      final d = drafts[i];
      final item = AlbumItem(
        id: 'item-${++_seq}',
        albumId: albumId,
        uploaderId: me,
        uploaderName: '나',
        kind: d.kind,
        fileUrl: d.fileUrl,
        fileName: d.fileName,
        fileSize: d.fileSize,
        mimeType: d.mimeType,
        thumbnailUrl: d.thumbnailUrl,
        width: d.width,
        height: d.height,
        durationMs: d.durationMs,
        // 서버처럼 앞에 고른 파일이 더 최근 시각이 되게.
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          base + (drafts.length - 1 - i),
        ),
      );
      list.add(item);
      added.add(item);
    }
    return added;
  }

  @override
  Future<({int deleted, int skipped})> deleteItems(
    String albumId,
    List<String> itemIds,
  ) async {
    calls.add('deleteItems $albumId ${itemIds.join(",")}');
    final album = _album(albumId);
    final list = items[albumId] ?? [];
    var deleted = 0;
    var skipped = 0;
    for (final id in itemIds) {
      final item = list.where((i) => i.id == id).firstOrNull;
      if (item == null) continue;
      if (_canDeleteItem(album, item)) {
        list.remove(item);
        deleted++;
      } else {
        skipped++;
      }
    }
    return (deleted: deleted, skipped: skipped);
  }

  @override
  Future<void> share(
    String albumId, {
    required String roomId,
    required List<String> itemIds,
  }) async {
    calls.add('share $albumId $roomId ${itemIds.length}');
    if (rejectShareRooms.contains(roomId)) {
      throw const ApiException('보드 뷰 토픽에는 앨범을 공유할 수 없습니다.');
    }
    if (itemIds.length > albumShareMaxCount) {
      throw const ApiException('한 번에 10개까지 공유할 수 있습니다.');
    }
    lastShare = (roomId: roomId, itemIds: itemIds);
  }

  /// 마지막 "앨범 공유"(앨범 카드 메시지) 요청.
  ({
    String albumId,
    String roomId,
    String text,
    List<Map<String, dynamic>>? textFormat,
    List<Map<String, dynamic>>? mentions,
  })?
  lastAlbumShare;

  @override
  Future<void> shareAlbum(
    String albumId, {
    required String roomId,
    required String text,
    List<Map<String, dynamic>>? textFormat,
    List<Map<String, dynamic>>? mentions,
  }) async {
    calls.add('shareAlbum $albumId $roomId');
    _album(albumId);
    if (rejectShareRooms.contains(roomId)) {
      throw const ApiException('보드 뷰 토픽에는 앨범을 공유할 수 없습니다.');
    }
    if (text.trim().isEmpty) throw const ApiException('메시지를 입력하세요.');
    lastAlbumShare = (
      albumId: albumId,
      roomId: roomId,
      text: text,
      textFormat: textFormat,
      mentions: mentions,
    );
  }

  @override
  Future<UploadResult> uploadFile(
    XFile file, {
    void Function(int sent, int total)? onProgress,
    UploadCancelToken? cancelToken,
  }) async {
    final name = file.path.split(RegExp(r'[\\/]')).last;
    calls.add('upload $name');
    _running++;
    if (_running > maxConcurrentUploads) maxConcurrentUploads = _running;
    try {
      final delay = uploadDelay;
      if (delay != null) await Future<void>.delayed(delay);
      if (failOnceNames.remove(name)) {
        throw const ApiException('네트워크 오류');
      }
      uploaded.add(name);
      onProgress?.call(10, 10);
      return UploadResult(
        url: '/uploads/$name',
        fileName: name,
        size: 10,
        mimeType: 'image/png',
      );
    } finally {
      _running--;
    }
  }
}

/// 시험용 앨범 한 건.
Album fakeAlbum(
  String id, {
  String roomId = 'r1',
  String roomName = '잔디톡 팀',
  String title = '여행',
  String? description,
  String? creatorId = 'me',
  int itemCount = 0,
  String? coverUrl,
  DateTime? createdAt,
}) => Album(
  id: id,
  teamId: 't1',
  roomId: roomId,
  roomName: roomName,
  creatorId: creatorId,
  creatorName: creatorId == 'me' ? '나' : '김철수',
  title: title,
  description: description,
  coverUrl: coverUrl,
  itemCount: itemCount,
  createdAt: createdAt ?? DateTime(2026, 9, 29, 14),
  updatedAt: createdAt ?? DateTime(2026, 9, 29, 14),
);

/// 시험용 항목 한 건 — [minutesAgo]가 클수록 오래된 것.
AlbumItem fakeItem(
  String id,
  String albumId, {
  AlbumItemKind kind = AlbumItemKind.image,
  String uploaderId = 'me',
  String? fileName,
  String? mimeType,
  int? durationMs,
  int minutesAgo = 0,
}) => AlbumItem(
  id: id,
  albumId: albumId,
  uploaderId: uploaderId,
  uploaderName: uploaderId == 'me' ? '나' : '김철수',
  kind: kind,
  fileUrl: '/files/$id',
  fileName: fileName ?? (kind == AlbumItemKind.video ? '$id.mp4' : '$id.png'),
  fileSize: 100,
  mimeType:
      mimeType ?? (kind == AlbumItemKind.video ? 'video/mp4' : 'image/png'),
  durationMs: durationMs,
  createdAt: DateTime(2026, 9, 29, 14).subtract(Duration(minutes: minutesAgo)),
);
