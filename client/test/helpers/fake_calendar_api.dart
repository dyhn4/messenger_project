import 'package:client/models/calendar.dart';
import 'package:client/services/api_client.dart' show ApiException;
import 'package:client/services/calendar_api.dart';

/// 서버 없이 캘린더 컨트롤러·화면을 시험하는 가짜 API. 호출을 [calls]에 기록하고, 캘린더·일정은 메모리에
/// 들고 있으며, 일정 조회는 [events] 중 요청 구간에 겹치는 것만 돌려준다(진짜 서버처럼).
class FakeCalendarApi implements CalendarApi {
  List<CalendarInfo> mine;
  List<CalendarInfo> subscribed;
  List<EventOccurrence> events;

  /// 호출 기록 — "메서드명 인자…" 문자열.
  final calls = <String>[];

  /// 마지막 요청의 세부(테스트가 본문을 확인한다).
  Map<String, dynamic>? lastEventFields;
  EventInput? lastCreateInput;
  RecurrenceScope? lastScope;
  int? lastOccurrenceStart;

  /// null이 아니면 쓰기 호출이 이 사유로 실패(서버 4xx 에러 흉내).
  String? failWith;

  /// 캘린더 id → 멤버 목록(GET /calendars/:id/members). 관리 화면 시험이 채운다.
  final Map<String, List<CalendarMember>> members = {};

  /// 준회원인 사용자 id — 멤버 추가/권한 변경에서 read가 아니면 서버처럼 400으로 거절한다.
  final Set<String> guestUserIds = {};

  /// 이름 표시용(addMember 응답의 name).
  final Map<String, String> userNames = {};

  /// 구독 검색이 돌려줄 후보(이름에 검색어가 들어간 것). 구독하면 subscribed 표시가 켜진다.
  List<CalendarSearchResult> searchable = [];
  String? lastSearchQuery;

  /// 마지막 createCalendar 요청의 색·공개 여부.
  String? lastCreateColor;
  bool? lastCreateIsPublic;

  /// 제목 검색이 돌려줄 일정 후보(제목에 검색어가 들어간 것, start 내림차순) — [searchPageSize]개씩 끊어 준다.
  List<CalendarSearchItem> searchableEvents = [];
  int searchPageSize = 50;
  String? lastEventSearchQuery;

  /// 일정 조회를 붙잡아 둘 때(늦은 응답 시험) 쓰는 대기.
  Future<void>? fetchGate;

  FakeCalendarApi({
    List<CalendarInfo>? mine,
    List<CalendarInfo>? subscribed,
    List<EventOccurrence>? events,
  }) : mine = mine ?? [personalCalendar()],
       subscribed = subscribed ?? [],
       events = events ?? [];

  int callCount(String prefix) =>
      calls.where((c) => c.startsWith(prefix)).length;

  void _maybeFail() {
    if (failWith != null) throw ApiException(failWith!);
  }

  @override
  Future<({List<CalendarInfo> mine, List<CalendarInfo> subscribed})>
  fetchCalendars(String teamId) async {
    calls.add('fetchCalendars $teamId');
    return (mine: [...mine], subscribed: [...subscribed]);
  }

  @override
  Future<CalendarInfo> createCalendar(
    String teamId, {
    required String name,
    required String color,
    bool? isPublic,
  }) async {
    calls.add('createCalendar $name');
    lastCreateColor = color;
    lastCreateIsPublic = isPublic;
    _maybeFail();
    final c = CalendarInfo(
      id: 'cal-${mine.length + 1}',
      teamId: teamId,
      kind: 'shared',
      name: name,
      color: color,
      role: 'admin',
      isPublic: isPublic ?? true,
      ownerId: 'me',
      ownerName: '나',
      canCreateEvents: true,
      canDelete: true,
      canEditSettings: true,
    );
    members['cal-${mine.length + 1}'] = [
      CalendarMember(userId: 'me', name: '나', role: 'admin', isOwner: true),
    ];
    mine = [...mine, c];
    return c;
  }

  @override
  Future<CalendarInfo> updateCalendar(
    String calendarId, {
    String? name,
    bool? isPublic,
  }) async {
    calls.add('updateCalendar $calendarId');
    _maybeFail();
    final old = mine.firstWhere((c) => c.id == calendarId);
    final updated = old.copyWith(name: name, isPublic: isPublic);
    mine = [for (final c in mine) c.id == calendarId ? updated : c];
    return updated;
  }

  @override
  Future<CalendarInfo> updateMySettings(
    String calendarId, {
    String? color,
    bool? hidden,
  }) async {
    calls.add('updateMySettings $calendarId color=$color hidden=$hidden');
    _maybeFail();
    CalendarInfo apply(CalendarInfo c) =>
        c.id == calendarId ? c.copyWith(color: color, hidden: hidden) : c;
    mine = [for (final c in mine) apply(c)];
    subscribed = [for (final c in subscribed) apply(c)];
    return [...mine, ...subscribed].firstWhere((c) => c.id == calendarId);
  }

  @override
  Future<void> deleteCalendar(String calendarId) async {
    calls.add('deleteCalendar $calendarId');
    _maybeFail();
    mine = [
      for (final c in mine)
        if (c.id != calendarId) c,
    ];
    events = [
      for (final e in events)
        if (e.calendarId != calendarId) e,
    ];
  }

  @override
  Future<void> leaveCalendar(String calendarId) async {
    calls.add('leaveCalendar $calendarId');
    _maybeFail();
    mine = [
      for (final c in mine)
        if (c.id != calendarId) c,
    ];
    subscribed = [
      for (final c in subscribed)
        if (c.id != calendarId) c,
    ];
  }

  @override
  Future<List<CalendarMember>> fetchMembers(String calendarId) async {
    calls.add('fetchMembers $calendarId');
    _maybeFail();
    return [...?members[calendarId]];
  }

  @override
  Future<CalendarMember> addMember(
    String calendarId, {
    required String userId,
    required String role,
  }) async {
    calls.add('addMember $calendarId $userId $role');
    _maybeFail();
    if (guestUserIds.contains(userId) && role != 'read') {
      throw ApiException('준회원은 읽기 권한만 줄 수 있습니다.');
    }
    final list = members.putIfAbsent(calendarId, () => []);
    if (list.any((m) => m.userId == userId)) {
      throw ApiException('이미 이 캘린더의 멤버입니다.');
    }
    final added = CalendarMember(
      userId: userId,
      name: userNames[userId] ?? userId,
      role: role,
    );
    list.add(added);
    return added;
  }

  @override
  Future<void> updateMemberRole(
    String calendarId,
    String userId, {
    required String role,
  }) async {
    calls.add('updateMemberRole $calendarId $userId $role');
    _maybeFail();
    final list = members[calendarId] ?? [];
    final i = list.indexWhere((m) => m.userId == userId);
    if (i < 0) throw ApiException('멤버를 찾을 수 없습니다.');
    if (list[i].isOwner) throw ApiException('소유자의 권한은 바꿀 수 없습니다.');
    if (guestUserIds.contains(userId) && role != 'read') {
      throw ApiException('준회원은 읽기 권한만 줄 수 있습니다.');
    }
    list[i] = CalendarMember(userId: userId, name: list[i].name, role: role);
  }

  @override
  Future<void> removeMember(String calendarId, String userId) async {
    calls.add('removeMember $calendarId $userId');
    _maybeFail();
    final list = members[calendarId] ?? [];
    final i = list.indexWhere((m) => m.userId == userId);
    if (i < 0) throw ApiException('멤버를 찾을 수 없습니다.');
    if (list[i].isOwner) throw ApiException('소유자는 내보낼 수 없습니다.');
    list.removeAt(i);
  }

  @override
  Future<List<CalendarSearchResult>> searchCalendars(
    String teamId,
    String q,
  ) async {
    calls.add('searchCalendars $q');
    lastSearchQuery = q;
    _maybeFail();
    return [
      for (final r in searchable)
        if (r.name.contains(q) || (r.ownerName ?? '').contains(q)) r,
    ];
  }

  @override
  Future<CalendarInfo> subscribe(String calendarId) async {
    calls.add('subscribe $calendarId');
    _maybeFail();
    final found = searchable.where((r) => r.id == calendarId).firstOrNull;
    final c = CalendarInfo(
      id: calendarId,
      kind: found?.kind ?? 'personal',
      name: found?.name ?? '구독한 캘린더',
      color: found?.color ?? '#43A047',
      ownerName: found?.ownerName,
      role: 'subscriber',
    );
    subscribed = [...subscribed, c];
    searchable = [
      for (final r in searchable)
        if (r.id != calendarId) r,
    ];
    return c;
  }

  @override
  Future<List<EventOccurrence>> fetchEvents(
    String teamId, {
    required int fromMs,
    required int toMs,
  }) async {
    calls.add('fetchEvents $teamId $fromMs $toMs');
    final gate = fetchGate;
    if (gate != null) await gate;
    return [
      for (final e in events)
        if (e.end > fromMs && e.start < toMs) e,
    ];
  }

  @override
  Future<EventOccurrence> createEvent(
    String calendarId,
    EventInput input,
  ) async {
    calls.add('createEvent $calendarId');
    lastCreateInput = input;
    _maybeFail();
    final e = EventOccurrence(
      key: 'new-${events.length + 1}:${input.start}',
      eventId: 'new-${events.length + 1}',
      calendarId: calendarId,
      title: input.title,
      description: input.description,
      location: input.location,
      start: input.start,
      end: input.end,
      allDay: input.allDay,
      visibility: input.visibility,
      recurring: input.recurrence != null,
      recurrence: input.recurrence,
      color: input.color ?? '#4285F4',
      canEdit: true,
      canDelete: true,
    );
    events = [...events, e];
    return e;
  }

  @override
  Future<EventOccurrence> fetchEvent(String eventId) async {
    calls.add('fetchEvent $eventId');
    return events.firstWhere((e) => e.eventId == eventId);
  }

  @override
  Future<EventOccurrence> updateEvent(
    String eventId,
    Map<String, dynamic> fields, {
    RecurrenceScope? scope,
    int? occurrenceStart,
  }) async {
    calls.add('updateEvent $eventId ${scope?.wire}');
    lastEventFields = fields;
    lastScope = scope;
    lastOccurrenceStart = occurrenceStart;
    _maybeFail();
    final i = events.indexWhere((e) => e.eventId == eventId);
    // 시각이 오면 서버처럼 저장한다(드래그 이동 시험이 다시 받은 결과를 본다).
    if (fields['start'] is int && fields['end'] is int) {
      events = [
        for (final e in events)
          if (e.eventId == eventId)
            e.copyWith(
              start: fields['start'] as int,
              end: fields['end'] as int,
            )
          else
            e,
      ];
    }
    return events[i];
  }

  @override
  Future<CalendarSearchPage> searchEvents(
    String teamId,
    String q, {
    String? before,
    int limit = 50,
  }) async {
    calls.add('searchEvents $q ${before ?? ''}');
    lastEventSearchQuery = q;
    _maybeFail();
    final all = [
      for (final i in searchableEvents)
        if (i.title.toLowerCase().contains(q.toLowerCase())) i,
    ]..sort((a, b) => b.start.compareTo(a.start));
    final from = before == null ? 0 : int.parse(before);
    final size = searchPageSize < limit ? searchPageSize : limit;
    final end = from + size > all.length ? all.length : from + size;
    return CalendarSearchPage(
      items: all.sublist(from, end),
      nextBefore: end < all.length ? '$end' : null,
    );
  }

  @override
  Future<void> deleteEvent(
    String eventId, {
    RecurrenceScope? scope,
    int? occurrenceStart,
  }) async {
    calls.add('deleteEvent $eventId ${scope?.wire}');
    lastScope = scope;
    lastOccurrenceStart = occurrenceStart;
    _maybeFail();
    events = [
      for (final e in events)
        if (e.eventId != eventId) e,
    ];
  }
}

/// 내 기본 캘린더(쓰기 가능) 한 개.
CalendarInfo personalCalendar({
  String id = 'cal-me',
  String name = '나',
  String color = '#1E88E5',
  bool hidden = false,
}) => CalendarInfo(
  id: id,
  teamId: 't1',
  kind: 'personal',
  name: name,
  color: color,
  isPublic: true,
  ownerId: 'me',
  ownerName: '나',
  role: 'admin',
  hidden: hidden,
  canCreateEvents: true,
  canEditSettings: true,
);

CalendarInfo sharedCalendar({
  String id = 'cal-shared',
  String name = '디자인팀',
  String color = '#8E24AA',
  String role = 'write',
  bool canDelete = false,
  bool hidden = false,
}) => CalendarInfo(
  id: id,
  teamId: 't1',
  kind: 'shared',
  name: name,
  color: color,
  role: role,
  hidden: hidden,
  canCreateEvents: role == 'admin' || role == 'write',
  canDelete: canDelete,
  canEditSettings: role == 'admin',
);

/// 시간 일정 한 회차.
EventOccurrence timedEvent(
  String id,
  DateTime start,
  DateTime end, {
  String title = '회의',
  String calendarId = 'cal-me',
  String color = '#1E88E5',
  bool canEdit = true,
  bool canDelete = true,
  bool restricted = false,
  bool recurring = false,
  Recurrence? recurrence,
  String? location,
  String? description,
  List<Attendee> attendees = const [],
  String visibility = 'public',
}) => EventOccurrence(
  key: '$id:${start.millisecondsSinceEpoch}',
  eventId: id,
  calendarId: calendarId,
  title: title,
  start: start.millisecondsSinceEpoch,
  end: end.millisecondsSinceEpoch,
  color: color,
  canEdit: canEdit,
  canDelete: canDelete,
  restricted: restricted,
  recurring: recurring,
  recurrence: recurrence,
  location: location,
  description: description,
  attendees: attendees,
  visibility: visibility,
  creatorId: 'me',
  creatorName: '나',
);

/// 종일 일정 — [firstDay]부터 [lastDay]까지(둘 다 포함, 날짜만 본다).
EventOccurrence allDayEvent(
  String id,
  DateTime firstDay,
  DateTime lastDay, {
  String title = '워크숍',
  String calendarId = 'cal-me',
  String color = '#43A047',
  bool canEdit = true,
  bool canDelete = true,
}) => EventOccurrence(
  key: '$id:${allDayToMs(firstDay)}',
  eventId: id,
  calendarId: calendarId,
  title: title,
  start: allDayToMs(firstDay),
  end: allDayToMs(DateTime(lastDay.year, lastDay.month, lastDay.day + 1)),
  allDay: true,
  color: color,
  canEdit: canEdit,
  canDelete: canDelete,
  creatorId: 'me',
  creatorName: '나',
);

/// 공휴일 회차(서버가 내려주는 모양).
EventOccurrence holidayEvent(DateTime day, String name) => EventOccurrence(
  key:
      'holiday:${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
  calendarId: kHolidaysCalendarId,
  source: 'holiday',
  title: name,
  start: allDayToMs(day),
  end: allDayToMs(DateTime(day.year, day.month, day.day + 1)),
  allDay: true,
  color: kHolidayColor,
);
