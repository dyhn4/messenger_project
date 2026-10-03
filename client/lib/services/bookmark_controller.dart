import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/bookmark.dart';
import 'bookmark_api.dart';

/// 북마크 패널의 상태 — 지금 팀의 팀 북마크와 내 개인 북마크, 불러오는 중·실패 표시, 소켓 `bookmark:changed`(다른
/// 사람이나 내 다른 기기가 바꿈)에 따른 다시 불러오기. 패널이 열릴 때 만들고 닫힐 때 버린다(Session에 두지 않는다).
///
/// 서버 호출은 [BookmarkApi]로만 해서 테스트가 가짜를 끼운다. 만들기·고치기·지우기는 서버에 보낸 뒤 목록을 다시
/// 받아 맞추고, 순서 변경은 화면이 바로 따라가도록 먼저 바꿔 두었다가 실패하면 되돌린다.
class BookmarkController extends ChangeNotifier {
  BookmarkController({
    required this.api,
    required this.teamId,
    Stream<Map<String, dynamic>>? changed,
    Stream<void>? reconnected,
  }) {
    _changedSub = changed?.listen((e) {
      if (e['teamId'] == teamId) unawaited(load(silent: true));
    });
    _reconnectSub = reconnected?.listen((_) => unawaited(load(silent: true)));
  }

  final BookmarkApi api;

  /// 이 컨트롤러가 보여 주는 팀 — 팀을 바꾸면 패널이 새 컨트롤러를 만든다.
  final String teamId;

  StreamSubscription<Map<String, dynamic>>? _changedSub;
  StreamSubscription<void>? _reconnectSub;
  bool _disposed = false;

  BookmarkLists _lists = const BookmarkLists();
  BookmarkLists get lists => _lists;

  /// 처음 불러오는 중(목록이 아직 없다). 소리 없는 다시 불러오기에서는 켜지지 않는다.
  bool loading = false;
  bool loaded = false;

  /// 처음 불러오기가 실패했을 때의 문구(목록이 이미 있으면 조용히 넘어간다).
  String? error;

  int _epoch = 0;

  List<Bookmark> of(BookmarkKind kind) => _lists.of(kind);

  /// 목록을 받는다. [silent]면 로딩 표시 없이 조용히 맞춘다(소켓 알림·내 변경 뒤).
  Future<void> load({bool silent = false}) async {
    final epoch = ++_epoch;
    if (!silent || !loaded) {
      loading = !loaded;
      error = null;
      _notify();
    }
    try {
      final result = await api.fetch(teamId);
      if (epoch != _epoch) return;
      _lists = result;
      loaded = true;
      error = null;
    } catch (e) {
      if (epoch != _epoch) return;
      if (!loaded) error = '$e';
    } finally {
      if (epoch == _epoch) {
        loading = false;
        _notify();
      }
    }
  }

  Future<Bookmark> create({
    required BookmarkKind kind,
    required String title,
    required String url,
    String? imageUrl,
  }) async {
    final created = await api.create(
      teamId: teamId,
      kind: kind,
      title: title,
      url: url,
      imageUrl: imageUrl,
    );
    await load(silent: true);
    return created;
  }

  Future<Bookmark> update(
    Bookmark bookmark, {
    required String title,
    required String url,
    String? imageUrl,
  }) async {
    final updated = await api.update(
      bookmark.id,
      title: title,
      url: url,
      imageUrl: imageUrl,
    );
    await load(silent: true);
    return updated;
  }

  Future<void> remove(Bookmark bookmark) async {
    await api.delete(bookmark.id);
    await load(silent: true);
  }

  /// [kind] 목록을 [orderedIds] 순서로 바꾼다. 화면이 먼저 따라가고, 서버가 거절하면 원래대로 되돌린 뒤 다시 던진다.
  Future<void> reorder(BookmarkKind kind, List<String> orderedIds) async {
    final before = _lists;
    final byId = {for (final b in before.of(kind)) b.id: b};
    final next = [
      for (final id in orderedIds)
        if (byId[id] != null) byId[id]!,
    ];
    _lists = kind == BookmarkKind.team
        ? BookmarkLists(team: next, personal: before.personal)
        : BookmarkLists(team: before.team, personal: next);
    _notify();
    try {
      await api.reorder(teamId: teamId, kind: kind, ids: orderedIds);
    } catch (_) {
      _lists = before;
      _notify();
      unawaited(load(silent: true));
      rethrow;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _changedSub?.cancel();
    _reconnectSub?.cancel();
    super.dispose();
  }
}
