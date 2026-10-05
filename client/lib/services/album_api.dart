import 'package:cross_file/cross_file.dart';

import '../models/album.dart';
import 'api_client.dart';

/// 앨범의 REST 호출 — 컨트롤러는 이 추상 클래스만 알아서, 테스트는 가짜 구현을 끼우고 실제 앱은 [RemoteAlbumApi]가
/// [ApiClient]로 서버를 부른다(favorites_api.dart와 같은 방식).
abstract class AlbumApi {
  /// `GET /api/albums?teamId=&roomId=&before=&limit=` — 내가 멤버인 방의 앨범(최신순). [before]는 이 시각(ms)보다
  /// 먼저 만든 것만(이어 받기 커서).
  Future<({List<Album> albums, bool hasMore})> fetchAlbums({
    required String teamId,
    String? roomId,
    int? before,
    int limit = 30,
  });

  /// `GET /api/albums/:id` — 상세(내 권한 플래그 포함).
  Future<Album> fetchAlbum(String albumId);

  /// `GET /api/albums/:id/items?before=&limit=` — 항목(최신순).
  Future<({List<AlbumItem> items, bool hasMore})> fetchItems(
    String albumId, {
    int? before,
    int limit = 60,
  });

  /// `POST /api/rooms/:roomId/albums`.
  Future<Album> createAlbum(
    String roomId, {
    required String title,
    String? description,
  });

  /// `PATCH /api/albums/:id` — 준 값만 바꾼다. [coverItemId]를 `''`로 주면 대표 이미지를 비운다(첫 항목으로 대신).
  Future<Album> updateAlbum(
    String albumId, {
    String? title,
    String? description,
    String? coverItemId,
  });

  /// `DELETE /api/albums/:id`.
  Future<void> deleteAlbum(String albumId);

  /// `POST /api/albums/:id/items` — 이미 올린 파일 최대 100개를 한꺼번에 담는다.
  Future<List<AlbumItem>> addItems(String albumId, List<AlbumItemDraft> items);

  /// `DELETE /api/albums/:id/items` — 권한 있는 것만 지우고 나머지는 [skipped]로 센다.
  Future<({int deleted, int skipped})> deleteItems(
    String albumId,
    List<String> itemIds,
  );

  /// `POST /api/albums/:id/share` — 항목(최대 10개)을 [roomId] 대화방에 이미지/영상 메시지로 보낸다.
  Future<void> share(
    String albumId, {
    required String roomId,
    required List<String> itemIds,
  });

  /// `POST /api/albums/:id/messages` — "앨범 공유": [roomId] 대화방에 [text](필수) 아래 앨범 카드가 붙은 글 메시지를
  /// 보낸다. [textFormat]·[mentions]는 입력칸의 서식·멘션(json 모양).
  Future<void> shareAlbum(
    String albumId, {
    required String roomId,
    required String text,
    List<Map<String, dynamic>>? textFormat,
    List<Map<String, dynamic>>? mentions,
  });

  /// `POST /api/upload` — 앨범에 담을 파일(또는 썸네일) 하나를 올린다.
  Future<UploadResult> uploadFile(
    XFile file, {
    void Function(int sent, int total)? onProgress,
    UploadCancelToken? cancelToken,
  });
}

/// [ApiClient]로 서버를 부르는 실제 구현.
class RemoteAlbumApi implements AlbumApi {
  final ApiClient _api;
  RemoteAlbumApi(this._api);

  Map<String, dynamic> _map(dynamic v) => Map<String, dynamic>.from(v as Map);

  @override
  Future<({List<Album> albums, bool hasMore})> fetchAlbums({
    required String teamId,
    String? roomId,
    int? before,
    int limit = 30,
  }) async {
    final query = <String, String>{
      'teamId': teamId,
      'roomId': ?roomId,
      'before': ?before?.toString(),
      'limit': '$limit',
    };
    final path = Uri(path: '/api/albums', queryParameters: query);
    final body = _map(await _api.requestJson('GET', path.toString()));
    return (
      albums: [
        for (final e in (body['albums'] as List? ?? const []))
          Album.fromJson(_map(e)),
      ],
      hasMore: body['hasMore'] as bool? ?? false,
    );
  }

  @override
  Future<Album> fetchAlbum(String albumId) async => Album.fromJson(
    _map(await _api.requestJson('GET', '/api/albums/$albumId')),
  );

  @override
  Future<({List<AlbumItem> items, bool hasMore})> fetchItems(
    String albumId, {
    int? before,
    int limit = 60,
  }) async {
    final query = <String, String>{
      'before': ?before?.toString(),
      'limit': '$limit',
    };
    final path = Uri(
      path: '/api/albums/$albumId/items',
      queryParameters: query,
    );
    final body = _map(await _api.requestJson('GET', path.toString()));
    return (
      items: [
        for (final e in (body['items'] as List? ?? const []))
          AlbumItem.fromJson(_map(e)),
      ],
      hasMore: body['hasMore'] as bool? ?? false,
    );
  }

  @override
  Future<Album> createAlbum(
    String roomId, {
    required String title,
    String? description,
  }) async => Album.fromJson(
    _map(
      await _api.requestJson(
        'POST',
        '/api/rooms/$roomId/albums',
        body: {'title': title, 'description': description ?? ''},
      ),
    ),
  );

  @override
  Future<Album> updateAlbum(
    String albumId, {
    String? title,
    String? description,
    String? coverItemId,
  }) async => Album.fromJson(
    _map(
      await _api.requestJson(
        'PATCH',
        '/api/albums/$albumId',
        body: {
          'title': ?title,
          'description': ?description,
          if (coverItemId != null)
            'coverItemId': coverItemId.isEmpty ? null : coverItemId,
        },
      ),
    ),
  );

  @override
  Future<void> deleteAlbum(String albumId) async {
    await _api.requestJson('DELETE', '/api/albums/$albumId');
  }

  @override
  Future<List<AlbumItem>> addItems(
    String albumId,
    List<AlbumItemDraft> items,
  ) async {
    final body = _map(
      await _api.requestJson(
        'POST',
        '/api/albums/$albumId/items',
        body: {
          'items': [for (final i in items) i.toJson()],
        },
      ),
    );
    return [
      for (final e in (body['items'] as List? ?? const []))
        AlbumItem.fromJson(_map(e)),
    ];
  }

  @override
  Future<({int deleted, int skipped})> deleteItems(
    String albumId,
    List<String> itemIds,
  ) async {
    final body = _map(
      await _api.requestJson(
        'DELETE',
        '/api/albums/$albumId/items',
        body: {'itemIds': itemIds},
      ),
    );
    return (
      deleted: (body['deleted'] as num?)?.toInt() ?? 0,
      skipped: (body['skipped'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> share(
    String albumId, {
    required String roomId,
    required List<String> itemIds,
  }) async {
    await _api.requestJson(
      'POST',
      '/api/albums/$albumId/share',
      body: {'roomId': roomId, 'itemIds': itemIds},
    );
  }

  @override
  Future<void> shareAlbum(
    String albumId, {
    required String roomId,
    required String text,
    List<Map<String, dynamic>>? textFormat,
    List<Map<String, dynamic>>? mentions,
  }) async {
    await _api.requestJson(
      'POST',
      '/api/albums/$albumId/messages',
      body: {
        'roomId': roomId,
        'text': text,
        'textFormat': ?textFormat,
        'mentions': ?mentions,
      },
    );
  }

  @override
  Future<UploadResult> uploadFile(
    XFile file, {
    void Function(int sent, int total)? onProgress,
    UploadCancelToken? cancelToken,
  }) => _api.uploadFile(file, onProgress: onProgress, cancelToken: cancelToken);
}
