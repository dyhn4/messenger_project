import 'package:cross_file/cross_file.dart';

import '../models/bookmark.dart';
import 'api_client.dart';

/// 북마크의 REST 호출 — 컨트롤러·화면은 이 추상 클래스만 알아서, 테스트는 가짜 구현을 끼우고 실제 앱은
/// [RemoteBookmarkApi]가 [ApiClient]로 서버를 부른다(album_api.dart와 같은 방식).
abstract class BookmarkApi {
  /// `GET /api/bookmarks?teamId=` — 팀 북마크 + 내 개인 북마크(각각 순서대로).
  Future<BookmarkLists> fetch(String teamId);

  /// `POST /api/bookmarks` — 새 북마크는 맨 끝에 붙는다. 종류는 만든 뒤 못 바꾼다.
  Future<Bookmark> create({
    required String teamId,
    required BookmarkKind kind,
    required String title,
    required String url,
    String? imageUrl,
  });

  /// `PATCH /api/bookmarks/:id` — 제목·주소·이미지를 통째로 보낸다([imageUrl]이 null이면 이미지를 지운다).
  Future<Bookmark> update(
    String id, {
    required String title,
    required String url,
    String? imageUrl,
  });

  /// `DELETE /api/bookmarks/:id`.
  Future<void> delete(String id);

  /// `POST /api/bookmarks/reorder` — [ids]는 그 종류의 지금 전체 id를 새 순서로.
  Future<void> reorder({
    required String teamId,
    required BookmarkKind kind,
    required List<String> ids,
  });

  /// `POST /api/bookmarks/preview` — 주소의 제목·대표 이미지(실패하면 빈 값).
  Future<BookmarkPreview> preview(String url);

  /// `POST /api/upload` — 북마크 이미지 직접 올리기. 저장에는 [UploadResult.url], 미리보기에는 [UploadResult.signedUrl].
  Future<UploadResult> uploadImage(XFile file);
}

class RemoteBookmarkApi implements BookmarkApi {
  final ApiClient _api;
  RemoteBookmarkApi(this._api);

  Map<String, dynamic> _map(Object? body) =>
      Map<String, dynamic>.from(body as Map);

  @override
  Future<BookmarkLists> fetch(String teamId) async => BookmarkLists.fromJson(
    _map(
      await _api.requestJson(
        'GET',
        '/api/bookmarks?teamId=${Uri.encodeQueryComponent(teamId)}',
      ),
    ),
  );

  @override
  Future<Bookmark> create({
    required String teamId,
    required BookmarkKind kind,
    required String title,
    required String url,
    String? imageUrl,
  }) async => Bookmark.fromJson(
    _map(
      await _api.requestJson(
        'POST',
        '/api/bookmarks',
        body: {
          'teamId': teamId,
          'kind': kind.wire,
          'title': title,
          'url': url,
          'imageUrl': imageUrl,
        },
      ),
    ),
  );

  @override
  Future<Bookmark> update(
    String id, {
    required String title,
    required String url,
    String? imageUrl,
  }) async => Bookmark.fromJson(
    _map(
      await _api.requestJson(
        'PATCH',
        '/api/bookmarks/$id',
        body: {'title': title, 'url': url, 'imageUrl': imageUrl},
      ),
    ),
  );

  @override
  Future<void> delete(String id) async {
    await _api.requestJson('DELETE', '/api/bookmarks/$id');
  }

  @override
  Future<void> reorder({
    required String teamId,
    required BookmarkKind kind,
    required List<String> ids,
  }) async {
    await _api.requestJson(
      'POST',
      '/api/bookmarks/reorder',
      body: {'teamId': teamId, 'kind': kind.wire, 'ids': ids},
    );
  }

  @override
  Future<BookmarkPreview> preview(String url) async => BookmarkPreview.fromJson(
    _map(
      await _api.requestJson(
        'POST',
        '/api/bookmarks/preview',
        body: {'url': url},
      ),
    ),
  );

  @override
  Future<UploadResult> uploadImage(XFile file) => _api.uploadFile(file);
}
