import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/calendar.dart';
import 'api_client.dart' show ApiException;
import 'calendar_api.dart';

/// 캘린더 화면의 상태: 선택한 팀의 캘린더 목록, 보이는 구간의 일정 캐시, 숨김 토글, 소켓
/// `calendar:changed` 수신 시 새로고침.
///
/// 일정은 "달 단위 덩어리"로 받아 캐시한다(서버 조회 구간이 최대 62일이라, 6주짜리 월간 격자도 두
/// 달에 걸치면 두 덩어리). 화면은 [watch]로 지금 보는 날짜 범위를 알려 주고, [eventsBetween]으로
/// 숨긴 캘린더를 뺀 일정을 읽는다. Session이 하나만 들고 있고(`session.calendar`), 화면이 닫혀도
/// 로그아웃 전까지는 캐시가 남는다 — 화면이 안 떠 있을 때 온 변경 알림은 캐시만 비운다.
class CalendarController extends ChangeNotifier {
  CalendarController({
    required this.apiProvider,
    Stream<String>? calendarChanged,
    Stream<void>? reconnected,
    String? Function()? userId,
    bool Function()? isGuest,
    Future<SharedPreferences> Function()? prefs,
  }) : _userId = userId ?? (() => null),
       _isGuest = isGuest ?? (() => false),
       _prefs = prefs ?? SharedPreferences.getInstance {
    _changedSub = calendarChanged?.listen(handleChanged);
    _reconnectSub = reconnected?.listen((_) => refresh());
  }

  final CalendarApi Function() apiProvider;
  final String? Function() _userId;
  final bool Function() _isGuest;
  final Future<SharedPreferences> Function() _prefs;
  StreamSubscription<String>? _changedSub;
  StreamSubscription<void>? _reconnectSub;
  bool _disposed = false;

  /// 지금 보는 팀. [setTeam]으로 바꾼다.
  String? teamId;

  List<CalendarInfo> mine = const [];
  List<CalendarInfo> subscribed = const [];
  bool calendarsLoaded = false;
  bool loadingCalendars = false;

  /// 캘린더 목록·일정을 마지막으로 불러오다 난 오류 문구(성공하면 null).
  String? error;

  /// 팀·로그인이 바뀌면 올라간다 — 이전 팀 요청의 늦은 응답을 버리려고.
  int _epoch = 0;

  /// 일정 덩어리를 다시 받을 때마다 올라간다 — 새로고침 전에 나간 요청의 늦은 응답을 버리려고.
  int _eventsEpoch = 0;

  final Set<String> _hiddenBuiltin = {};
  bool _hiddenBuiltinLoaded = false;

  /// 달 첫날(자정) → 그 달 덩어리(앞뒤 하루씩 여유를 두고 받은 일정).
  final Map<DateTime, List<EventOccurrence>> _chunks = {};
  final Map<DateTime, Future<void>> _inflight = {};
  List<({DateTime from, DateTime to})> _watched = [];

  // ---- 캘린더 목록 ----

  /// 준회원인지 — 새 캘린더 만들기·구독은 정회원 이상만 할 수 있다(서버도 막는다).
  bool get isGuest => _isGuest();

  /// 국가 공휴일·멤버 생일(서버 목록에 없는 내장 구독 캘린더). 생일은 정회원 이상만.
  List<CalendarInfo> get builtinCalendars => [
    CalendarInfo.holidays(hidden: _hiddenBuiltin.contains(kHolidaysCalendarId)),
    if (!_isGuest())
      CalendarInfo.birthdays(
        hidden: _hiddenBuiltin.contains(kBirthdaysCalendarId),
      ),
  ];

  /// 화면 왼쪽 "구독 캘린더" 묶음 — 내장 캘린더가 먼저, 그다음 내가 구독한 캘린더.
  List<CalendarInfo> get subscribedGroup => [
    ...builtinCalendars,
    ...subscribed,
  ];

  List<CalendarInfo> get allCalendars => [...mine, ...subscribedGroup];

  CalendarInfo? calendarById(String id) {
    for (final c in allCalendars) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 일정을 만들 수 있는 캘린더(일정 폼의 캘린더 선택).
  List<CalendarInfo> get writableCalendars => [
    for (final c in [...mine, ...subscribed])
      if (c.canCreateEvents) c,
  ];

  bool isHidden(String calendarId) {
    if (calendarId == kHolidaysCalendarId ||
        calendarId == kBirthdaysCalendarId) {
      return _hiddenBuiltin.contains(calendarId);
    }
    return calendarById(calendarId)?.hidden ?? false;
  }

  /// 팀을 고른다(팀 전환 포함). 같은 팀이면 아무 것도 안 한다. null이면 비운다.
  Future<void> setTeam(String? id) async {
    if (id != teamId) {
      teamId = id;
      _resetData();
      notifyListeners();
    }
    if (id == null) return;
    // 같은 팀으로 다시 열었을 때도 — 화면이 없는 동안 비워진 목록이 있으면 채운다.
    await Future.wait([
      _loadHiddenBuiltin(),
      if (!calendarsLoaded && !loadingCalendars) loadCalendars(),
    ]);
    await _fetchWatched();
  }

  void _resetData() {
    _epoch++;
    _eventsEpoch++;
    mine = const [];
    subscribed = const [];
    calendarsLoaded = false;
    loadingCalendars = false;
    error = null;
    _chunks.clear();
    _inflight.clear();
  }

  /// 로그아웃 — 캐시와 팀을 비운다(다른 사람이 로그인해도 남지 않게).
  void reset() {
    teamId = null;
    _watched = [];
    _hiddenBuiltinLoaded = false;
    _hiddenBuiltin.clear();
    _resetData();
    notifyListeners();
  }

  Future<void> loadCalendars() async {
    final team = teamId;
    if (team == null) return;
    final epoch = _epoch;
    loadingCalendars = true;
    notifyListeners();
    try {
      final result = await apiProvider().fetchCalendars(team);
      if (epoch != _epoch) return;
      mine = result.mine;
      subscribed = result.subscribed;
      calendarsLoaded = true;
      error = null;
    } catch (e) {
      if (epoch != _epoch) return;
      error = _message(e, '캘린더를 불러오지 못했습니다.');
    } finally {
      if (epoch == _epoch) {
        loadingCalendars = false;
        notifyListeners();
      }
    }
  }

  // ---- 일정 캐시 ----

  /// 화면이 지금 보고 있는 날짜 범위 [from, to)(to는 배타)를 알리고, 아직 없는 구간을 받아 온다. 받아 오는
  /// 동안 [notifyListeners]가 불리고, 반환 Future는 받기가 끝나면 완료된다.
  Future<void> watch(DateTime from, DateTime to) {
    _watched = [(from: dateOnly(from), to: dateOnly(to))];
    return _fetchWatched();
  }

  /// 화면이 닫혔다 — 이제 변경 알림이 와도 다시 받지 않고 캐시만 비운다.
  void unwatch() => _watched = [];

  bool get isWatching => _watched.isNotEmpty;

  /// 일정을 받는 중인 덩어리가 있는지(화면이 로딩 표시를 띄운다).
  bool get loadingEvents => _inflight.isNotEmpty;

  Set<DateTime> _neededChunks() {
    final keys = <DateTime>{};
    for (final range in _watched) {
      var m = DateTime(range.from.year, range.from.month, 1);
      while (m.isBefore(range.to)) {
        keys.add(m);
        m = DateTime(m.year, m.month + 1, 1);
      }
    }
    return keys;
  }

  Future<void> _fetchWatched({bool force = false}) {
    if (teamId == null) return Future.value();
    final futures = <Future<void>>[];
    for (final key in _neededChunks()) {
      if (!force && _chunks.containsKey(key)) continue;
      futures.add(_inflight[key] ?? _startChunk(key, _eventsEpoch));
    }
    return Future.wait(futures);
  }

  Future<void> _startChunk(DateTime key, int epoch) {
    final team = teamId!;
    // 앞뒤 하루씩 넉넉히 — 시간대 경계에 걸친 종일·자정 일정이 빠지지 않게 한다.
    final from = addDays(key, -1).millisecondsSinceEpoch;
    final to = addDays(
      DateTime(key.year, key.month + 1, 1),
      1,
    ).millisecondsSinceEpoch;
    late final Future<void> future;
    future = () async {
      try {
        final list = await apiProvider().fetchEvents(
          team,
          fromMs: from,
          toMs: to,
        );
        if (epoch != _eventsEpoch) return;
        _chunks[key] = list;
        error = null;
      } catch (e) {
        if (epoch != _eventsEpoch) return;
        error = _message(e, '일정을 불러오지 못했습니다.');
      } finally {
        if (epoch == _eventsEpoch) {
          if (identical(_inflight[key], future)) _inflight.remove(key);
          notifyListeners();
        }
      }
    }();
    _inflight[key] = future;
    notifyListeners();
    return future;
  }

  /// [from, to)(날짜, to 배타)에 걸친 일정 — 숨긴 캘린더의 것은 뺀다. 시작 시각순.
  List<EventOccurrence> eventsBetween(DateTime from, DateTime to) {
    final f = dateOnly(from);
    final t = dateOnly(to);
    final byKey = <String, EventOccurrence>{};
    for (final list in _chunks.values) {
      for (final e in list) {
        if (isHidden(e.calendarId)) continue;
        if (e.lastDay.isBefore(f) || !e.firstDay.isBefore(t)) continue;
        byKey[e.key] = e;
      }
    }
    return byKey.values.toList()..sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : a.key.compareTo(b.key);
    });
  }

  /// 캐시를 다시 받는다(변경 알림·재연결·직접 새로고침). 보고 있는 범위는 옛 데이터를 그대로 두고 새로
  /// 받아 오는 대로 바꿔서 화면이 깜빡이지 않는다.
  Future<void> refresh() async {
    if (teamId == null) return;
    if (!isWatching) {
      // 화면이 없으면 받지 않고 비워 두었다가 다음에 열 때 받는다.
      _eventsEpoch++;
      _chunks.clear();
      _inflight.clear();
      calendarsLoaded = false;
      return;
    }
    _eventsEpoch++;
    _inflight.clear();
    final needed = _neededChunks();
    _chunks.removeWhere((key, _) => !needed.contains(key));
    await Future.wait([loadCalendars(), _fetchWatched(force: true)]);
  }

  /// 소켓 calendar:changed — 지금 보는 팀의 변경이면 새로고침한다.
  void handleChanged(String changedTeamId) {
    if (changedTeamId.isNotEmpty && changedTeamId != teamId) return;
    unawaited(refresh());
  }

  // ---- 숨김·색 ----

  Future<void> _loadHiddenBuiltin() async {
    if (_hiddenBuiltinLoaded) return;
    try {
      final prefs = await _prefs();
      _hiddenBuiltin
        ..clear()
        ..addAll(prefs.getStringList(_prefsKey()) ?? const []);
    } catch (_) {
      // 저장소를 못 쓰는 환경(테스트 등)에서는 이 실행 동안만 기억한다.
    }
    _hiddenBuiltinLoaded = true;
    if (!_disposed) notifyListeners();
  }

  String _prefsKey() => 'calendar_hidden_builtin_${_userId() ?? ''}';

  /// 캘린더 앞 체크박스 — 내 화면에서 숨기거나 다시 보인다. 내장 캘린더는 서버에 행이 없어서 이 기기에
  /// 저장하고, 나머지는 PATCH /calendars/:id/me 로 서버에 저장한다(다른 기기에도 이어진다).
  Future<void> setHidden(CalendarInfo calendar, bool hidden) async {
    if (calendar.isBuiltin) {
      if (hidden) {
        _hiddenBuiltin.add(calendar.id);
      } else {
        _hiddenBuiltin.remove(calendar.id);
      }
      notifyListeners();
      try {
        final prefs = await _prefs();
        await prefs.setStringList(_prefsKey(), _hiddenBuiltin.toList());
      } catch (_) {
        // 저장 실패는 이 실행 동안의 화면에는 영향이 없다.
      }
      return;
    }
    final before = (mine, subscribed);
    _replaceCalendar(calendar.copyWith(hidden: hidden));
    notifyListeners();
    try {
      _replaceCalendar(
        await apiProvider().updateMySettings(calendar.id, hidden: hidden),
      );
      notifyListeners();
    } catch (e) {
      // 서버가 거절하면 체크박스를 되돌린다.
      mine = before.$1;
      subscribed = before.$2;
      notifyListeners();
      rethrow;
    }
  }

  /// 내 캘린더 색 변경(개인 설정). 일정 색도 이 색을 따르므로 일정을 다시 받는다.
  Future<void> setColor(CalendarInfo calendar, String color) async {
    final updated = await apiProvider().updateMySettings(
      calendar.id,
      color: color,
    );
    _replaceCalendar(updated);
    notifyListeners();
    unawaited(_reloadEventsOnly());
  }

  void _replaceCalendar(CalendarInfo updated) {
    mine = [for (final c in mine) c.id == updated.id ? updated : c];
    subscribed = [for (final c in subscribed) c.id == updated.id ? updated : c];
  }

  Future<void> _reloadEventsOnly() async {
    if (!isWatching) return;
    _eventsEpoch++;
    _inflight.clear();
    await _fetchWatched(force: true);
  }

  // ---- 일정 만들기·수정·삭제 (성공하면 일정을 다시 받는다) ----

  Future<EventOccurrence> createEvent(
    String calendarId,
    EventInput input,
  ) async {
    final created = await apiProvider().createEvent(calendarId, input);
    await _reloadEventsOnly();
    return created;
  }

  Future<EventOccurrence> updateEvent(
    String eventId,
    Map<String, dynamic> fields, {
    RecurrenceScope? scope,
    int? occurrenceStart,
  }) async {
    final updated = await apiProvider().updateEvent(
      eventId,
      fields,
      scope: scope,
      occurrenceStart: occurrenceStart,
    );
    await _reloadEventsOnly();
    return updated;
  }

  Future<void> deleteEvent(
    String eventId, {
    RecurrenceScope? scope,
    int? occurrenceStart,
  }) async {
    await apiProvider().deleteEvent(
      eventId,
      scope: scope,
      occurrenceStart: occurrenceStart,
    );
    await _reloadEventsOnly();
  }

  Future<EventOccurrence> fetchEvent(String eventId) =>
      apiProvider().fetchEvent(eventId);

  // ---- 캘린더 관리 (관리 대화상자가 쓴다 — 성공하면 목록을 다시 받는다) ----

  Future<CalendarInfo> createCalendar({
    required String name,
    required String color,
    bool? isPublic,
  }) async {
    final created = await apiProvider().createCalendar(
      teamId!,
      name: name,
      color: color,
      isPublic: isPublic,
    );
    await loadCalendars();
    return created;
  }

  Future<CalendarInfo> updateCalendar(
    String calendarId, {
    String? name,
    bool? isPublic,
  }) async {
    final updated = await apiProvider().updateCalendar(
      calendarId,
      name: name,
      isPublic: isPublic,
    );
    _replaceCalendar(updated);
    notifyListeners();
    return updated;
  }

  /// 캘린더 삭제(소유자, 일정도 함께 지워진다).
  Future<void> deleteCalendar(String calendarId) async {
    await apiProvider().deleteCalendar(calendarId);
    await _afterCalendarChange();
  }

  /// "나에게만 삭제" / 구독 취소.
  Future<void> leaveCalendar(String calendarId) async {
    await apiProvider().leaveCalendar(calendarId);
    await _afterCalendarChange();
  }

  /// 캘린더가 없어지거나 늘면 목록은 언제나 다시 받고, 일정은 화면이 열려 있을 때만 다시 받는다.
  Future<void> _afterCalendarChange() async {
    await loadCalendars();
    await _reloadEventsOnly();
  }

  Future<List<CalendarSearchResult>> searchCalendars(String q) =>
      apiProvider().searchCalendars(teamId!, q);

  Future<CalendarInfo> subscribe(String calendarId) async {
    final calendar = await apiProvider().subscribe(calendarId);
    await _afterCalendarChange();
    return calendar;
  }

  Future<List<CalendarMember>> fetchMembers(String calendarId) =>
      apiProvider().fetchMembers(calendarId);

  Future<CalendarMember> addMember(
    String calendarId, {
    required String userId,
    required String role,
  }) => apiProvider().addMember(calendarId, userId: userId, role: role);

  Future<void> updateMemberRole(
    String calendarId,
    String userId, {
    required String role,
  }) => apiProvider().updateMemberRole(calendarId, userId, role: role);

  Future<void> removeMember(String calendarId, String userId) =>
      apiProvider().removeMember(calendarId, userId);

  String _message(Object e, String fallback) =>
      e is ApiException ? e.message : fallback;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _changedSub?.cancel();
    _reconnectSub?.cancel();
    super.dispose();
  }
}
