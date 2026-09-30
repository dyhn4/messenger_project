import '../models/calendar.dart';
import 'api_client.dart';

/// 캘린더 REST 호출 전부(API 규약 B의 1~14번). 컨트롤러·화면은 이 추상 클래스만 알아서, 테스트는
/// 가짜 구현을 끼우고 실제 앱은 [RemoteCalendarApi]가 [ApiClient]로 서버를 부른다.
///
/// 캘린더 관리 화면(새 캘린더·설정·멤버·구독 검색·삭제)도 이 메서드들을 그대로 쓰면 된다 —
/// 보통은 목록을 다시 받아야 하니 [CalendarController]의 같은 이름 메서드를 거치는 편이 낫다.
abstract class CalendarApi {
  /// 1. 내 캘린더(mine)와 구독 캘린더(subscribed). 처음 부르면 서버가 기본·팀 캘린더를 만든다.
  Future<({List<CalendarInfo> mine, List<CalendarInfo> subscribed})>
  fetchCalendars(String teamId);

  /// 2. 새 캘린더(정회원 이상).
  Future<CalendarInfo> createCalendar(
    String teamId, {
    required String name,
    required String color,
    bool? isPublic,
  });

  /// 3. 이름·공개 여부 변경(캘린더 관리자).
  Future<CalendarInfo> updateCalendar(
    String calendarId, {
    String? name,
    bool? isPublic,
  });

  /// 4. 내 개인 설정 — 색, 내 화면에서 숨기기.
  Future<CalendarInfo> updateMySettings(
    String calendarId, {
    String? color,
    bool? hidden,
  });

  /// 5. 캘린더 삭제(shared의 소유자만, 일정도 모두 삭제).
  Future<void> deleteCalendar(String calendarId);

  /// 6. "나에게만 삭제" / 구독 취소.
  Future<void> leaveCalendar(String calendarId);

  /// 7. 멤버 관리(shared, 캘린더 관리자).
  Future<List<CalendarMember>> fetchMembers(String calendarId);
  Future<CalendarMember> addMember(
    String calendarId, {
    required String userId,
    required String role,
  });
  Future<void> updateMemberRole(
    String calendarId,
    String userId, {
    required String role,
  });
  Future<void> removeMember(String calendarId, String userId);

  /// 8. 구독할 캘린더 검색과 구독.
  Future<List<CalendarSearchResult>> searchCalendars(String teamId, String q);
  Future<CalendarInfo> subscribe(String calendarId);

  /// 9. 조회 구간([fromMs], [toMs])의 일정 회차. 구간은 최대 62일.
  Future<List<EventOccurrence>> fetchEvents(
    String teamId, {
    required int fromMs,
    required int toMs,
  });

  /// 10. 일정 만들기 → 첫 회차.
  Future<EventOccurrence> createEvent(String calendarId, EventInput input);

  /// 11. 일정 상세(첫 회차 기준 + recurrence, attendees).
  Future<EventOccurrence> fetchEvent(String eventId);

  /// 12. 일정 수정 → 바뀐 첫 회차. [fields]는 바꿀 필드만(생성 본문과 같은 이름 + `calendarId`).
  /// 반복 일정이면 [scope]와 [occurrenceStart](원래 회차 시작 ms)를 함께 보낸다.
  Future<EventOccurrence> updateEvent(
    String eventId,
    Map<String, dynamic> fields, {
    RecurrenceScope? scope,
    int? occurrenceStart,
  });

  /// 13. 일정 삭제. 반복 일정이면 [scope]와 [occurrenceStart]가 필요하다.
  Future<void> deleteEvent(
    String eventId, {
    RecurrenceScope? scope,
    int? occurrenceStart,
  });
}

/// [ApiClient.requestJson]으로 서버를 부르는 실제 구현.
class RemoteCalendarApi implements CalendarApi {
  final ApiClient _api;
  RemoteCalendarApi(this._api);

  Map<String, dynamic> _map(dynamic v) => Map<String, dynamic>.from(v as Map);

  List<Map<String, dynamic>> _maps(dynamic v) => [
    for (final e in (v as List)) _map(e),
  ];

  @override
  Future<({List<CalendarInfo> mine, List<CalendarInfo> subscribed})>
  fetchCalendars(String teamId) async {
    final body = _map(
      await _api.requestJson('GET', '/api/teams/$teamId/calendars'),
    );
    return (
      mine: [
        for (final j in _maps(body['mine'] ?? const []))
          CalendarInfo.fromJson(j),
      ],
      subscribed: [
        for (final j in _maps(body['subscribed'] ?? const []))
          CalendarInfo.fromJson(j),
      ],
    );
  }

  @override
  Future<CalendarInfo> createCalendar(
    String teamId, {
    required String name,
    required String color,
    bool? isPublic,
  }) async => CalendarInfo.fromJson(
    _map(
      await _api.requestJson(
        'POST',
        '/api/teams/$teamId/calendars',
        body: {'name': name, 'color': color, 'isPublic': ?isPublic},
      ),
    ),
  );

  @override
  Future<CalendarInfo> updateCalendar(
    String calendarId, {
    String? name,
    bool? isPublic,
  }) async => CalendarInfo.fromJson(
    _map(
      await _api.requestJson(
        'PATCH',
        '/api/calendars/$calendarId',
        body: {'name': ?name, 'isPublic': ?isPublic},
      ),
    ),
  );

  @override
  Future<CalendarInfo> updateMySettings(
    String calendarId, {
    String? color,
    bool? hidden,
  }) async => CalendarInfo.fromJson(
    _map(
      await _api.requestJson(
        'PATCH',
        '/api/calendars/$calendarId/me',
        body: {'color': ?color, 'hidden': ?hidden},
      ),
    ),
  );

  @override
  Future<void> deleteCalendar(String calendarId) async {
    await _api.requestJson('DELETE', '/api/calendars/$calendarId');
  }

  @override
  Future<void> leaveCalendar(String calendarId) async {
    await _api.requestJson('DELETE', '/api/calendars/$calendarId/me');
  }

  @override
  Future<List<CalendarMember>> fetchMembers(String calendarId) async => [
    for (final j in _maps(
      await _api.requestJson('GET', '/api/calendars/$calendarId/members'),
    ))
      CalendarMember.fromJson(j),
  ];

  @override
  Future<CalendarMember> addMember(
    String calendarId, {
    required String userId,
    required String role,
  }) async => CalendarMember.fromJson(
    _map(
      await _api.requestJson(
        'POST',
        '/api/calendars/$calendarId/members',
        body: {'userId': userId, 'role': role},
      ),
    ),
  );

  @override
  Future<void> updateMemberRole(
    String calendarId,
    String userId, {
    required String role,
  }) async {
    await _api.requestJson(
      'PATCH',
      '/api/calendars/$calendarId/members/$userId',
      body: {'role': role},
    );
  }

  @override
  Future<void> removeMember(String calendarId, String userId) async {
    await _api.requestJson(
      'DELETE',
      '/api/calendars/$calendarId/members/$userId',
    );
  }

  @override
  Future<List<CalendarSearchResult>> searchCalendars(
    String teamId,
    String q,
  ) async => [
    for (final j in _maps(
      await _api.requestJson(
        'GET',
        '/api/teams/$teamId/calendars/search?q=${Uri.encodeQueryComponent(q)}',
      ),
    ))
      CalendarSearchResult.fromJson(j),
  ];

  @override
  Future<CalendarInfo> subscribe(String calendarId) async =>
      CalendarInfo.fromJson(
        _map(
          await _api.requestJson(
            'POST',
            '/api/calendars/$calendarId/subscribe',
          ),
        ),
      );

  @override
  Future<List<EventOccurrence>> fetchEvents(
    String teamId, {
    required int fromMs,
    required int toMs,
  }) async => [
    for (final j in _maps(
      await _api.requestJson(
        'GET',
        '/api/teams/$teamId/calendar/events?from=$fromMs&to=$toMs',
      ),
    ))
      EventOccurrence.fromJson(j),
  ];

  @override
  Future<EventOccurrence> createEvent(
    String calendarId,
    EventInput input,
  ) async => EventOccurrence.fromJson(
    _map(
      await _api.requestJson(
        'POST',
        '/api/calendars/$calendarId/events',
        body: input.toJson(),
      ),
    ),
  );

  @override
  Future<EventOccurrence> fetchEvent(String eventId) async =>
      EventOccurrence.fromJson(
        _map(await _api.requestJson('GET', '/api/events/$eventId')),
      );

  @override
  Future<EventOccurrence> updateEvent(
    String eventId,
    Map<String, dynamic> fields, {
    RecurrenceScope? scope,
    int? occurrenceStart,
  }) async => EventOccurrence.fromJson(
    _map(
      await _api.requestJson(
        'PATCH',
        '/api/events/$eventId',
        body: {
          ...fields,
          if (scope != null) 'scope': scope.wire,
          'occurrenceStart': ?occurrenceStart,
        },
      ),
    ),
  );

  @override
  Future<void> deleteEvent(
    String eventId, {
    RecurrenceScope? scope,
    int? occurrenceStart,
  }) async {
    final query = [
      if (scope != null) 'scope=${scope.wire}',
      if (occurrenceStart != null) 'occurrenceStart=$occurrenceStart',
    ].join('&');
    await _api.requestJson(
      'DELETE',
      '/api/events/$eventId${query.isEmpty ? '' : '?$query'}',
    );
  }
}
