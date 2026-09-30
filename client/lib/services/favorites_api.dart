import '../models/favorite.dart';
import 'api_client.dart';

/// 통합 즐겨찾기의 REST 호출 — 컨트롤러는 이 추상 클래스만 알아서, 테스트는 가짜 구현을 끼우고 실제 앱은
/// [RemoteFavoritesApi]가 [ApiClient]로 서버를 부른다(notification_api.dart와 같은 방식).
abstract class FavoritesApi {
  /// `GET /api/favorites/ids` — 내가 담은 메시지·댓글·멤버.
  Future<FavoriteIds> fetchIds();

  /// `GET /api/favorites?teamId=&type=&before=&limit=` — [kind]가 null이면 전부 섞어(대화방은 맨 앞).
  /// [before]는 이 시각(ms)보다 먼저 담은 것만(무한 스크롤 커서).
  Future<({List<FavoriteItem> items, bool hasMore})> fetchFavorites({
    required String teamId,
    FavoriteKind? kind,
    int? before,
    int limit = 30,
  });

  /// `PUT /api/messages/:id/favorite`.
  Future<bool> setMessageFavorite(String messageId, bool favorite);

  /// `PUT /api/comments/:id/favorite`.
  Future<bool> setCommentFavorite(String commentId, bool favorite);

  /// `PUT /api/teams/:teamId/members/:userId/favorite`.
  Future<bool> setMemberFavorite(String teamId, String userId, bool favorite);
}

/// [ApiClient]로 서버를 부르는 실제 구현.
class RemoteFavoritesApi implements FavoritesApi {
  final ApiClient _api;
  RemoteFavoritesApi(this._api);

  @override
  Future<FavoriteIds> fetchIds() async => FavoriteIds.fromJson(
    Map<String, dynamic>.from(
      await _api.requestJson('GET', '/api/favorites/ids') as Map,
    ),
  );

  @override
  Future<({List<FavoriteItem> items, bool hasMore})> fetchFavorites({
    required String teamId,
    FavoriteKind? kind,
    int? before,
    int limit = 30,
  }) async {
    final query = <String, String>{
      'teamId': teamId,
      'type': ?kind?.apiValue,
      'before': ?before?.toString(),
      'limit': '$limit',
    };
    final path = Uri(path: '/api/favorites', queryParameters: query);
    final body = Map<String, dynamic>.from(
      await _api.requestJson('GET', path.toString()) as Map,
    );
    return (
      items: [
        for (final e in (body['items'] as List? ?? const []))
          FavoriteItem.fromJson(Map<String, dynamic>.from(e as Map)),
      ],
      hasMore: body['hasMore'] as bool? ?? false,
    );
  }

  Future<bool> _put(String path, bool favorite) async {
    final body = Map<String, dynamic>.from(
      await _api.requestJson('PUT', path, body: {'favorite': favorite}) as Map,
    );
    return body['favorite'] as bool? ?? favorite;
  }

  @override
  Future<bool> setMessageFavorite(String messageId, bool favorite) =>
      _put('/api/messages/$messageId/favorite', favorite);

  @override
  Future<bool> setCommentFavorite(String commentId, bool favorite) =>
      _put('/api/comments/$commentId/favorite', favorite);

  @override
  Future<bool> setMemberFavorite(String teamId, String userId, bool favorite) =>
      _put('/api/teams/$teamId/members/$userId/favorite', favorite);
}
