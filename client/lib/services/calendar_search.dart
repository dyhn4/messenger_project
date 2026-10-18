import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/calendar.dart';
import 'api_client.dart' show ApiException;
import 'calendar_api.dart';
import '../l10n/tr.dart';

/// 캘린더 일정 제목 검색의 상태 — 입력(디바운스 300ms) → 서버 검색 → 결과 목록(최신순, "더 보기"로 이어 받기).
/// [CalendarController.search]가 하나만 들고 있고, PC의 상단 검색창과 모바일의 검색 화면이 같이 쓴다.
///
/// 서버는 숨긴 캘린더를 모르므로 결과에서 빼는 일은 여기서 한다([visibleItems]).
class CalendarSearchController extends ChangeNotifier {
  CalendarSearchController({
    required this.apiProvider,
    required this.teamId,
    required this.isHidden,
    this.debounce = const Duration(milliseconds: 300),
    this.pageSize = 50,
  });

  final CalendarApi Function() apiProvider;
  final String? Function() teamId;
  final bool Function(String calendarId) isHidden;
  final Duration debounce;
  final int pageSize;

  String _query = '';
  Timer? _timer;
  bool _disposed = false;

  /// 새 검색(또는 비움)마다 올라간다 — 이전 검색의 늦은 응답을 버리려고.
  int _epoch = 0;

  List<CalendarSearchItem> _items = const [];
  String? _nextBefore;
  bool loading = false;
  bool loadingMore = false;

  /// 마지막 검색이 실패했을 때의 문구(성공하면 null).
  String? error;

  /// 검색을 한 번이라도 끝낸 입력인지(결과 없음 안내와 "아직 안 쳤음"을 가른다).
  bool searched = false;

  String get query => _query;

  /// 검색어(앞뒤 공백 뺀 것)가 있는지.
  bool get hasQuery => _query.trim().isNotEmpty;

  /// 숨긴 캘린더의 결과를 뺀 목록.
  List<CalendarSearchItem> get visibleItems => [
    for (final i in _items)
      if (!isHidden(i.calendarId)) i,
  ];

  /// 서버에 더 있는지(숨긴 캘린더 결과 때문에 보이는 것이 적어도 더 받을 수는 있다).
  bool get hasMore => _nextBefore != null;

  /// 입력이 바뀔 때마다 부른다 — 300ms 동안 더 안 바뀌면 검색한다. 비면 곧바로 비운다.
  void setQuery(String text) {
    if (text == _query) return;
    _query = text;
    _timer?.cancel();
    if (!hasQuery) {
      _clear();
      return;
    }
    _timer = Timer(debounce, () => unawaited(search()));
    notifyListeners();
  }

  /// 디바운스를 기다리지 않고 지금 검색한다(엔터).
  Future<void> search() async {
    _timer?.cancel();
    final team = teamId();
    final q = _query.trim();
    if (team == null || q.isEmpty) {
      _clear();
      return;
    }
    final epoch = ++_epoch;
    loading = true;
    loadingMore = false;
    error = null;
    notifyListeners();
    try {
      final page = await apiProvider().searchEvents(team, q, limit: pageSize);
      if (epoch != _epoch) return;
      _items = page.items;
      _nextBefore = page.nextBefore;
      searched = true;
    } catch (e) {
      if (epoch != _epoch) return;
      _items = const [];
      _nextBefore = null;
      error = _message(e, tr('검색하지 못했습니다.'));
      searched = true;
    } finally {
      if (epoch == _epoch) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// 다음 쪽을 이어 받는다("더 보기").
  Future<void> loadMore() async {
    final team = teamId();
    final cursor = _nextBefore;
    if (team == null || cursor == null || loading || loadingMore) return;
    final epoch = _epoch;
    loadingMore = true;
    notifyListeners();
    try {
      final page = await apiProvider().searchEvents(
        team,
        _query.trim(),
        before: cursor,
        limit: pageSize,
      );
      if (epoch != _epoch) return;
      final known = {for (final i in _items) i.eventId};
      _items = [
        ..._items,
        for (final i in page.items)
          if (!known.contains(i.eventId)) i,
      ];
      _nextBefore = page.nextBefore;
      error = null;
    } catch (e) {
      if (epoch != _epoch) return;
      error = _message(e, tr('검색하지 못했습니다.'));
    } finally {
      if (epoch == _epoch) {
        loadingMore = false;
        notifyListeners();
      }
    }
  }

  /// 일정이 바뀌었다(변경 알림·직접 수정) — 검색 중이었으면 같은 검색어로 다시 받는다.
  Future<void> refreshIfActive() async {
    if (_disposed || !searched || !hasQuery) return;
    await search();
  }

  /// 검색어와 결과를 비운다(검색 화면을 닫을 때).
  void clear() {
    _timer?.cancel();
    _query = '';
    _clear();
  }

  void _clear() {
    _epoch++;
    _items = const [];
    _nextBefore = null;
    loading = false;
    loadingMore = false;
    error = null;
    searched = false;
    notifyListeners();
  }

  String _message(Object e, String fallback) =>
      e is ApiException ? trServer(e.message) : fallback;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
