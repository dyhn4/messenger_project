import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/todo.dart';
import 'todo_api.dart';

/// 할 일 패널의 상태 — 지금 팀의 할 일 목록(탭·필터·정렬), 불러오는 중·실패 표시, 무한 스크롤, 소켓 `todo:changed`(다른
/// 사람이나 내 다른 기기가 바꿈)에 따른 다시 불러오기. 패널이 열릴 때 만들고 닫힐 때 버린다(Session에 두지 않는다).
///
/// 서버 호출은 [TodoApi]로만 해서 테스트가 가짜를 끼운다. 정렬이 복합 키(미완료 먼저·기한 임박순)라 다음 쪽은
/// 커서가 아니라 지금까지 받은 개수([items].length)를 offset으로 보내 이어 받는다.
class TodoController extends ChangeNotifier {
  TodoController({
    required this.api,
    required this.teamId,
    Stream<Map<String, dynamic>>? changed,
    Stream<void>? reconnected,
    this.pageSize = 30,
    this.scope = TodoScope.mine,
    this.roomId,
  }) {
    _changedSub = changed?.listen((e) {
      if (e['teamId'] == teamId) unawaited(load(silent: true));
    });
    _reconnectSub = reconnected?.listen((_) => unawaited(load(silent: true)));
  }

  final TodoApi api;

  /// 이 컨트롤러가 보여 주는 팀 — 팀을 바꾸면 패널이 새 컨트롤러를 만든다.
  final String teamId;
  final int pageSize;

  StreamSubscription<Map<String, dynamic>>? _changedSub;
  StreamSubscription<void>? _reconnectSub;
  bool _disposed = false;

  TodoScope scope;

  /// 참여 대화방 필터 — null이면 전체.
  String? roomId;

  /// "완료 제외" 토글(true면 완료된 할 일을 뺀다).
  bool excludeDone = false;
  TodoSort sort = TodoSort.due;

  List<Todo> _items = const [];
  List<Todo> get items => _items;
  bool hasMore = false;

  /// 처음(또는 필터를 바꾼 뒤) 불러오는 중. 조용한 다시 불러오기에서는 켜지지 않는다.
  bool loading = false;
  bool loadingMore = false;
  bool loaded = false;

  /// 불러오기가 실패했을 때의 문구(목록이 이미 있으면 조용히 넘어간다).
  String? error;

  int _epoch = 0;

  void setScope(TodoScope value) {
    if (value == scope) return;
    scope = value;
    _resetAndLoad();
  }

  void setRoom(String? value) {
    if (value == roomId) return;
    roomId = value;
    _resetAndLoad();
  }

  void setExcludeDone(bool value) {
    if (value == excludeDone) return;
    excludeDone = value;
    _resetAndLoad();
  }

  void setSort(TodoSort value) {
    if (value == sort) return;
    sort = value;
    _resetAndLoad();
  }

  void _resetAndLoad() {
    _items = const [];
    hasMore = false;
    loaded = false;
    _notify();
    unawaited(load());
  }

  /// 목록을 처음부터 받는다. [silent]면 로딩 표시 없이 조용히 맞춘다(소켓 알림·내 변경 뒤) — 이때는 지금까지 보던
  /// 만큼(최대 서버 한도)을 한 번에 다시 받아 스크롤 위치가 줄어들지 않게 한다.
  Future<void> load({bool silent = false}) async {
    final epoch = ++_epoch;
    if (!silent || !loaded) {
      loading = !loaded;
      error = null;
      _notify();
    }
    try {
      final limit = silent && loaded
          ? math.min(math.max(pageSize, _items.length), 100)
          : pageSize;
      final page = await api.list(
        teamId: teamId,
        scope: scope,
        includeDone: !excludeDone,
        roomId: roomId,
        sort: sort,
        offset: 0,
        limit: limit,
      );
      if (epoch != _epoch) return;
      _items = page.items;
      hasMore = page.hasMore;
      loaded = true;
      error = null;
    } catch (e) {
      if (epoch != _epoch) return;
      if (!loaded) error = '$e';
    } finally {
      if (epoch == _epoch) {
        loading = false;
        loadingMore = false;
        _notify();
      }
    }
  }

  /// 다음 쪽 — 이미 받는 중이거나 끝이면 아무것도 안 한다. 중복(같은 id)은 건너뛴다.
  Future<void> loadMore() async {
    if (!loaded || loading || loadingMore || !hasMore) return;
    final epoch = _epoch;
    loadingMore = true;
    _notify();
    try {
      final page = await api.list(
        teamId: teamId,
        scope: scope,
        includeDone: !excludeDone,
        roomId: roomId,
        sort: sort,
        offset: _items.length,
        limit: pageSize,
      );
      if (epoch != _epoch) return;
      final known = {for (final t in _items) t.id};
      _items = [
        ..._items,
        for (final t in page.items)
          if (known.add(t.id)) t,
      ];
      hasMore = page.hasMore;
    } catch (_) {
      // 실패해도 지금 목록은 그대로 — 끝까지 내리면 다시 시도한다.
    } finally {
      if (epoch == _epoch) {
        loadingMore = false;
        _notify();
      }
    }
  }

  /// 서버가 돌려준 할 일 한 건으로 목록의 같은 id를 바꾼다(없으면 그대로).
  void applyTodo(Todo todo) {
    final i = _items.indexWhere((t) => t.id == todo.id);
    if (i < 0) return;
    _items = [..._items]..[i] = todo;
    _notify();
  }

  /// 진척률 바꾸기(빠른 완료 체크 포함) — 서버에 보낸 뒤 그 결과를 목록에 반영한다. 실패하면 던진다.
  Future<Todo> setProgress(Todo todo, int progress) async {
    final updated = await api.update(todo.id, {'progress': progress});
    applyTodo(updated);
    unawaited(load(silent: true));
    return updated;
  }

  Future<void> remove(Todo todo) async {
    await api.delete(todo.id);
    _items = [
      for (final t in _items)
        if (t.id != todo.id) t,
    ];
    _notify();
    unawaited(load(silent: true));
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
