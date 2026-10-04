import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/todo.dart';
import 'todo_api.dart';

/// 할 일 패널의 상태 — 지금 팀의 할 일 목록(탭·필터·정렬), 불러오는 중·실패 표시, 무한 스크롤, 소켓 `todo:changed`(다른
/// 사람이나 내 다른 기기가 바꿈)에 따른 다시 불러오기, 즐겨찾기, 할 일 일정(달력) 한 달 치. 패널이 열릴 때 만들고 닫힐 때
/// 버린다(Session에 두지 않는다).
///
/// 서버 호출은 [TodoApi]로만 해서 테스트가 가짜를 끼운다. 정렬이 복합 키(즐겨찾기 먼저, 그다음 생성 순 — 또는 미완료 먼저·
/// 기한 임박순)라 다음 쪽은 커서가 아니라 지금까지 받은 개수([items].length)를 offset으로 보내 이어 받는다.
class TodoController extends ChangeNotifier {
  TodoController({
    required this.api,
    required this.teamId,
    Stream<Map<String, dynamic>>? changed,
    Stream<void>? reconnected,
    this.pageSize = 30,
    this.scope = TodoScope.mine,
    this.roomId,
    this.assigneeId,
  }) {
    _changedSub = changed?.listen((e) {
      if (e['teamId'] == teamId) _reloadQuietly();
    });
    _reconnectSub = reconnected?.listen((_) => _reloadQuietly());
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

  /// 담당자 필터(잔디 "[부여한 할 일] – [모든 멤버]") — null이면 모든 멤버. 이 사람이 담당인 것만 받고, 완료 제외·정렬과
  /// 카드의 진척률도 이 사람 기준이 된다. 부여한 할 일이 아닌 탭으로 옮기거나 대화방 필터를 바꾸면 비운다.
  String? assigneeId;

  /// "완료된 할 일 제외" 토글(true면 완료된 할 일을 뺀다 — 기준 진척률로 따진다).
  bool excludeDone = false;

  /// 목록 정렬 — 처음은 생성 순(잔디).
  TodoSort sort = TodoSort.created;

  List<Todo> _items = const [];
  List<Todo> get items => _items;
  bool hasMore = false;

  /// 서버가 알려 준 전체 개수 — 예전 서버(응답에 total 없음)면 null.
  int? _total;

  /// 지금 필터에 맞는 할 일의 전체 개수(`N개의 할 일`) — 다음 쪽을 아직 안 받았어도 다 센다. 예전 서버면 지금까지 받은 개수.
  int get total => _total ?? _items.length;

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
    // 담당자 필터는 부여한 할 일에서만 고른다.
    if (value != TodoScope.assignedByMe) assigneeId = null;
    _resetAndLoad();
  }

  void setRoom(String? value) {
    if (value == roomId) return;
    roomId = value;
    // 이전 방 멤버 기준으로 골랐던 담당자는 새 범위에 안 맞을 수 있다(투표 패널의 작성자 필터와 같다).
    assigneeId = null;
    _resetAndLoad();
  }

  void setAssignee(String? value) {
    if (value == assigneeId) return;
    assigneeId = value;
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
    // 달력은 늘 기한 순으로 받으니 다시 받지 않는다.
    _resetAndLoad(calendar: false);
  }

  void _resetAndLoad({bool calendar = true}) {
    _items = const [];
    hasMore = false;
    _total = null;
    loaded = false;
    final month = calendar ? calendarMonth : null;
    if (month != null) {
      _calendarItems = const [];
      calendarLoaded = false;
    }
    _notify();
    unawaited(load());
    if (month != null) unawaited(loadCalendar(month));
  }

  /// 소켓 알림·내 변경 뒤 — 목록과(펼쳐 둔) 달력을 로딩 표시 없이 다시 받는다.
  void _reloadQuietly() {
    if (_disposed) return;
    unawaited(load(silent: true));
    final month = calendarMonth;
    if (month != null) unawaited(loadCalendar(month, silent: true));
  }

  /// 목록이 보는 관점의 진척률 — 담당자 필터가 있으면 그 사람의 것, 나의 할 일이면 내 것(담당자가 아니면 전체), 그 밖은
  /// 전체(집계). 카드의 `진행률 : N%`(숫자와 색)와 지난 기한 판단이 쓴다.
  int perspectiveProgress(Todo t) {
    final who = assigneeId;
    if (who != null) return t.progressOf(who);
    if (scope == TodoScope.mine) return t.myProgress ?? t.progress;
    return t.progress;
  }

  /// 카드의 진척률 문구 — [perspectiveProgress]의 %(`75%` — 잔디 카드 `진행률 : 75%`의 숫자 부분). 모든 할 일·부여한
  /// 할 일처럼 한 사람 기준이 아니어도 완료한 사람 수 대신 집계 %다.
  String perspectiveText(Todo t) => todoPercentText(perspectiveProgress(t));

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
          ? math.min(math.max(pageSize, _items.length), todoListMaxLimit)
          : pageSize;
      final page = await api.list(
        teamId: teamId,
        scope: scope,
        includeDone: !excludeDone,
        roomId: roomId,
        assigneeId: assigneeId,
        sort: sort,
        offset: 0,
        limit: limit,
      );
      if (epoch != _epoch) return;
      _items = page.items;
      hasMore = page.hasMore;
      _total = page.total;
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
        assigneeId: assigneeId,
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
      // 그사이 생기거나 지워진 것까지 센 최신 값.
      _total = page.total;
    } catch (_) {
      // 실패해도 지금 목록은 그대로 — 끝까지 내리면 다시 시도한다.
    } finally {
      if (epoch == _epoch) {
        loadingMore = false;
        _notify();
      }
    }
  }

  // ---- 할 일 일정(달력) ----

  /// 달력으로 보고 있는 달(1일 0시) — null이면 달력을 닫은 것(목록 보기).
  DateTime? calendarMonth;

  List<Todo> _calendarItems = const [];

  /// [calendarMonth]의 달력 칸 범위([todoCalendarRange])에 기간이 걸치는 할 일 — 목록과 같은 필터, 기한순.
  List<Todo> get calendarItems => _calendarItems;

  /// 달을 옮기거나 필터를 바꿔 다시 받는 중. 조용한 다시 받기(소켓 알림·내 변경 뒤)에서는 켜지지 않는다.
  bool calendarLoading = false;

  /// [calendarMonth]의 결과를 받아 두었는지.
  bool calendarLoaded = false;

  /// 달력을 받지 못했을 때의 문구(이미 받은 게 있으면 조용히 넘어간다).
  String? calendarError;

  /// 목록과 따로 — 달을 빨리 넘기면 늦게 온 이전 달 응답을 버린다.
  int _calendarEpoch = 0;

  /// [month]가 있는 달의 할 일을 받는다(같은 필터, 기한순, 한 번에 [todoRangeMaxLimit]개까지). 다른 달로 옮기면
  /// 이전 달 것은 바로 비운다. [silent]면 로딩 표시 없이 조용히 맞춘다.
  Future<void> loadCalendar(DateTime month, {bool silent = false}) async {
    final target = DateTime(month.year, month.month);
    if (calendarMonth != target) {
      _calendarItems = const [];
      calendarLoaded = false;
    }
    calendarMonth = target;
    final epoch = ++_calendarEpoch;
    if (!silent || !calendarLoaded) {
      calendarLoading = true;
      calendarError = null;
      _notify();
    }
    final (from, to) = todoCalendarRange(target);
    try {
      final page = await api.list(
        teamId: teamId,
        scope: scope,
        includeDone: !excludeDone,
        roomId: roomId,
        assigneeId: assigneeId,
        from: from,
        to: to,
        sort: TodoSort.due,
        offset: 0,
        limit: todoRangeMaxLimit,
      );
      if (epoch != _calendarEpoch) return;
      _calendarItems = page.items;
      calendarLoaded = true;
      calendarError = null;
    } catch (e) {
      if (epoch != _calendarEpoch) return;
      if (!calendarLoaded) calendarError = '$e';
    } finally {
      if (epoch == _calendarEpoch) {
        calendarLoading = false;
        _notify();
      }
    }
  }

  /// 달력을 닫는다(목록 보기로) — 받아 둔 달력은 버리고, 오고 있는 응답도 버린다.
  void closeCalendar() {
    if (calendarMonth == null) return;
    calendarMonth = null;
    _calendarEpoch++;
    _calendarItems = const [];
    calendarLoaded = false;
    calendarLoading = false;
    calendarError = null;
    _notify();
  }

  // ---- 바꾸기 ----

  /// 서버가 돌려준 할 일 한 건으로 목록·달력의 같은 id를 바꾼다(없으면 그대로).
  void applyTodo(Todo todo) {
    if (_replace((t) => t.id == todo.id ? todo : t)) _notify();
  }

  /// 목록과 달력의 할 일을 [map]으로 바꾼다(그대로 둘 것은 같은 객체를 돌려준다) — 바뀐 게 있으면 true.
  bool _replace(Todo Function(Todo t) map) {
    var changed = false;
    List<Todo> apply(List<Todo> list) {
      final next = list.map(map).toList();
      for (var i = 0; i < list.length; i++) {
        if (!identical(next[i], list[i])) {
          changed = true;
          return next;
        }
      }
      return list;
    }

    _items = apply(_items);
    _calendarItems = apply(_calendarItems);
    return changed;
  }

  /// 내 진척률 바꾸기 — 서버에 보낸 뒤 그 결과를 목록에 반영한다. 실패하면 던진다.
  Future<Todo> setProgress(Todo todo, int progress) async {
    final updated = await api.update(todo.id, {'progress': progress});
    applyTodo(updated);
    _reloadQuietly();
    return updated;
  }

  /// 즐겨찾기 켜고 끄기 — 목록·달력에서 바로 뒤집어 보이고(낙관적) 서버에 보낸다. 실패하면 되돌리고 던지고, 되면 조용히
  /// 다시 받아 "즐겨찾기 먼저" 순서를 맞춘다.
  Future<void> toggleFavorite(Todo todo) async {
    // 화면이 들고 있던 객체가 낡았어도 지금 목록의 값을 기준으로 뒤집는다.
    final before = _find(todo.id)?.favorite ?? todo.favorite;
    final next = !before;
    _setFavorite(todo.id, next);
    try {
      final result = await api.setFavorite(todo.id, next);
      if (result != next) _setFavorite(todo.id, result);
    } catch (_) {
      _setFavorite(todo.id, before);
      rethrow;
    }
    _reloadQuietly();
  }

  Todo? _find(String id) =>
      _items.where((t) => t.id == id).firstOrNull ??
      _calendarItems.where((t) => t.id == id).firstOrNull;

  void _setFavorite(String id, bool favorite) {
    final changed = _replace(
      (t) => t.id == id && t.favorite != favorite
          ? t.copyWith(favorite: favorite)
          : t,
    );
    if (changed) _notify();
  }

  Future<void> remove(Todo todo) async {
    await api.delete(todo.id);
    final listed = _items.any((t) => t.id == todo.id);
    _items = [
      for (final t in _items)
        if (t.id != todo.id) t,
    ];
    // 다시 받기 전에도 개수 줄이 맞게.
    final total = _total;
    if (listed && total != null) _total = math.max(0, total - 1);
    _calendarItems = [
      for (final t in _calendarItems)
        if (t.id != todo.id) t,
    ];
    _notify();
    _reloadQuietly();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _calendarEpoch++;
    _changedSub?.cancel();
    _reconnectSub?.cancel();
    super.dispose();
  }
}
