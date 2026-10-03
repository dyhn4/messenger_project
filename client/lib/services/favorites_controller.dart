import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/favorite.dart';
import 'favorites_api.dart';

/// 즐겨찾기 목록 하나(탭 하나)의 상태 — 서버에서 쪽 단위로 받아 이어 붙인다.
class FavoriteFeed {
  final List<FavoriteItem> items = [];
  bool loaded = false;
  bool loading = false;
  bool hasMore = false;
  String? error;

  /// 비우거나 새로 받을 때마다 올라간다 — 그 전에 나간 요청의 늦은 응답을 버리려고.
  int epoch = 0;

  void reset() {
    items.clear();
    loaded = false;
    loading = false;
    hasMore = false;
    error = null;
    epoch++;
  }
}

/// 통합 즐겨찾기(메시지·파일·댓글·투표·대화방·멤버)의 상태: 내가 담은 메시지·댓글·멤버 id(메뉴의 "즐겨찾기 / 해제"와
/// 별 표시), 탭별 목록(무한 스크롤), 소켓 `favorite:changed`(내 다른 기기에서 바꿈) 반영.
///
/// Session이 하나만 들고 있고(`session.favorites`) 로그아웃하면 [reset]이 비운다. 서버 호출은 [FavoritesApi]로만
/// 해서 테스트가 가짜를 끼운다. 대화방·투표·파일 즐겨찾기를 켜고 끄는 일은 예전부터 있던 경로(Session.toggleFavorite,
/// Session.setPollFavorite, FileActions.toggleFavorite)가 그대로 하고, 여기는 목록만 받아 보여준다.
class FavoritesController extends ChangeNotifier {
  FavoritesController({
    required this.apiProvider,
    required this.teamIdProvider,
    Stream<Map<String, dynamic>>? changed,
    Stream<void>? reconnected,
  }) {
    _changedSub = changed?.listen(handleChanged);
    _reconnectSub = reconnected?.listen((_) {
      unawaited(loadIds());
      invalidate();
    });
  }

  final FavoritesApi Function() apiProvider;

  /// 지금 보고 있는 팀 — 목록은 팀 단위다.
  final String? Function() teamIdProvider;

  StreamSubscription<Map<String, dynamic>>? _changedSub;
  StreamSubscription<void>? _reconnectSub;
  bool _disposed = false;

  /// 로그아웃·다른 계정 로그인 때 올라간다 — 이전 계정 요청의 늦은 응답을 버리려고.
  int _epoch = 0;

  // ---- 내가 담은 id ----

  FavoriteIds _ids = const FavoriteIds();

  bool isMessageFavorite(String messageId) => _ids.messages.contains(messageId);
  bool isCommentFavorite(String commentId) => _ids.comments.contains(commentId);
  bool isMemberFavorite(String teamId, String userId) =>
      _ids.members.contains(FavoriteIds.memberKey(teamId, userId));

  /// 로그인·재연결 때 한 번 받는다. 실패해도(별 표시일 뿐) 조용히 넘어간다.
  Future<void> loadIds() async {
    final epoch = _epoch;
    try {
      final ids = await apiProvider().fetchIds();
      if (epoch != _epoch) return;
      _ids = ids;
      _notify();
    } catch (_) {}
  }

  /// 메시지·댓글·멤버를 즐겨찾기에 넣거나 뺀다 — 서버가 확정한 값을 반영하고 돌려준다. 멤버는 [teamId]가 필요하다.
  /// 규칙에 어긋나면(비밀 대화 등) 서버 문구 그대로 예외가 난다. 빼면 열려 있는 목록에서도 바로 사라진다.
  Future<bool> setFavorite(
    FavoriteKind kind,
    String id,
    bool favorite, {
    String? teamId,
  }) async {
    final api = apiProvider();
    final bool result;
    switch (kind) {
      case FavoriteKind.message:
        result = await api.setMessageFavorite(id, favorite);
      case FavoriteKind.comment:
        result = await api.setCommentFavorite(id, favorite);
      case FavoriteKind.member:
        if (teamId == null) {
          throw ArgumentError('멤버 즐겨찾기는 teamId가 필요합니다.');
        }
        result = await api.setMemberFavorite(teamId, id, favorite);
      default:
        throw ArgumentError('이 종류는 여기서 바꾸지 않습니다: $kind');
    }
    _apply(kind, id, result, teamId: teamId);
    return result;
  }

  /// 소켓 `favorite:changed` — 내 다른 기기에서 바꿨다. `{kind: 'message'|'comment'|'member', id, favorite, teamId?}`.
  void handleChanged(Map<String, dynamic> event) {
    final kind = FavoriteKindInfo.fromApi(event['kind'] as String?);
    final id = event['id'] as String?;
    if (kind == null || id == null) return;
    _apply(
      kind,
      id,
      event['favorite'] as bool? ?? false,
      teamId: event['teamId'] as String?,
    );
  }

  void _apply(FavoriteKind kind, String id, bool favorite, {String? teamId}) {
    final next = FavoriteIds(
      messages: {..._ids.messages},
      comments: {..._ids.comments},
      members: {..._ids.members},
    );
    final Set<String> set;
    final String key;
    switch (kind) {
      case FavoriteKind.message:
        set = next.messages;
        key = id;
      case FavoriteKind.comment:
        set = next.comments;
        key = id;
      case FavoriteKind.member:
        if (teamId == null) return;
        set = next.members;
        key = FavoriteIds.memberKey(teamId, id);
      default:
        return;
    }
    favorite ? set.add(key) : set.remove(key);
    _ids = next;
    if (favorite) {
      // 새로 담은 것은 목록에 어디 끼는지 서버가 알아야 해서 열려 있던 목록을 다시 받게 한다.
      invalidate();
    } else {
      removeWhere(
        (i) => switch (kind) {
          FavoriteKind.message =>
            i.kind == FavoriteKind.message && i.message?.id == id,
          FavoriteKind.comment =>
            i.kind == FavoriteKind.comment && i.comment?.id == id,
          _ =>
            i.kind == FavoriteKind.member &&
                i.user?.id == id &&
                (teamId == null || i.teamId == teamId),
        },
      );
    }
    _notify();
  }

  // ---- 탭별 목록 ----

  final Map<FavoriteKind?, FavoriteFeed> _feeds = {};

  /// 탭([kind]가 null이면 '전체')의 목록 상태.
  FavoriteFeed feed(FavoriteKind? kind) =>
      _feeds.putIfAbsent(kind, FavoriteFeed.new);

  /// 모든 탭의 목록을 비운다(다음에 보일 때 다시 받는다) — 화면을 열 때, 팀을 바꿀 때, 새로 담았을 때.
  void invalidate() {
    for (final f in _feeds.values) {
      f.reset();
    }
    _notify();
  }

  /// [kind] 탭의 첫 쪽을 받는다(이미 받았거나 받는 중이면 [refresh]가 아닌 한 그대로).
  Future<void> load(FavoriteKind? kind, {bool refresh = false}) async {
    final f = feed(kind);
    if (f.loading || (f.loaded && !refresh)) return;
    final teamId = teamIdProvider();
    if (teamId == null) return;
    final epoch = ++f.epoch;
    final globalEpoch = _epoch;
    f.loading = true;
    f.error = null;
    _notify();
    try {
      final page = await apiProvider().fetchFavorites(
        teamId: teamId,
        kind: kind,
      );
      if (epoch != f.epoch || globalEpoch != _epoch) return;
      f.items
        ..clear()
        ..addAll(page.items);
      f.hasMore = page.hasMore;
      f.loaded = true;
    } catch (e) {
      if (epoch != f.epoch || globalEpoch != _epoch) return;
      f.error = '$e';
      f.loaded = true;
    } finally {
      if (epoch == f.epoch && globalEpoch == _epoch) {
        f.loading = false;
        _notify();
      }
    }
  }

  /// 다음 쪽 — 마지막 항목을 담은 시각 이전 것만 이어 붙인다.
  Future<void> loadMore(FavoriteKind? kind) async {
    final f = feed(kind);
    if (f.loading || !f.loaded || !f.hasMore) return;
    final teamId = teamIdProvider();
    if (teamId == null) return;
    int? before;
    for (final item in f.items.reversed) {
      final at = item.favoritedAt;
      if (at != null) {
        before = at.millisecondsSinceEpoch;
        break;
      }
    }
    if (before == null) return;
    final epoch = f.epoch;
    final globalEpoch = _epoch;
    f.loading = true;
    _notify();
    try {
      final page = await apiProvider().fetchFavorites(
        teamId: teamId,
        kind: kind,
        before: before,
      );
      if (epoch != f.epoch || globalEpoch != _epoch) return;
      final have = {for (final i in f.items) i.key};
      f.items.addAll(page.items.where((i) => !have.contains(i.key)));
      f.hasMore = page.hasMore;
    } catch (e) {
      if (epoch != f.epoch || globalEpoch != _epoch) return;
      f.error = '$e';
    } finally {
      if (epoch == f.epoch && globalEpoch == _epoch) {
        f.loading = false;
        _notify();
      }
    }
  }

  /// 조건에 맞는 항목을 모든 탭 목록에서 뺀다 — 즐겨찾기를 풀었거나 글이 지워졌을 때.
  void removeWhere(bool Function(FavoriteItem item) test) {
    var changed = false;
    for (final f in _feeds.values) {
      final before = f.items.length;
      f.items.removeWhere(test);
      if (f.items.length != before) changed = true;
    }
    if (changed) _notify();
  }

  /// 목록 항목을 키로 뺀다(투표·파일·대화방처럼 다른 경로로 풀었을 때).
  void removeItem(FavoriteItem item) => removeWhere((i) => i.key == item.key);

  /// 로그아웃 — 이전 계정의 것이 다음 사람에게 남지 않게.
  void reset() {
    _epoch++;
    _ids = const FavoriteIds();
    for (final f in _feeds.values) {
      f.reset();
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _changedSub?.cancel();
    _reconnectSub?.cancel();
    super.dispose();
  }
}
