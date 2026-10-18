// 캘린더 기능의 데이터 모양 — 서버 API 규약(캘린더 DTO / EventOccurrence)을 그대로 옮긴 것.
//
// 날짜 처리에서 가장 조심할 점은 **종일 일정**이다. 종일 일정의 start/end는 "그 날짜를 UTC 자정으로
// 본 epoch ms"(끝은 마지막 날 다음 날 자정, 배타)라서, 기기 시간대로 바꿔 읽으면 하루씩 어긋난다.
// 그래서 종일 일정은 항상 allDayFromMs로 UTC의 y/m/d만 읽고, 보낼 때는 allDayToMs로 만든다.

import '../l10n/tr.dart';

/// 내장 구독 캘린더의 id — DB 행이 없어서 서버가 이 고정 문자열을 calendarId로 내려 준다.
const kHolidaysCalendarId = 'holidays';
const kBirthdaysCalendarId = 'birthdays';

/// 그룹웨어에서 승인된 휴가(server/src/calendars.js — 팀 범위면 이 팀의 결재, 회사 전체면 이 팀 사람들의 휴가).
const kLeavesCalendarId = 'leaves';

/// 그룹웨어에서 승인된 출장 신청(server/src/calendars.js — 팀 휴가를 보는 사람들에게, 출장지를 장소로 한 종일 일정). 결재가
/// 승인·취소되면 서버가 calendarId 'trips'로 calendar:changed를 보낸다.
const kTripsCalendarId = 'trips';

/// 그룹웨어에서 바로 잡은 내 회의실·자원 예약(일정에 붙인 예약은 그 일정으로 보인다 — server/src/groupwareResources.js).
const kBookingsCalendarId = 'bookings';

/// 내장 캘린더의 고정 색(서버도 같은 값을 EventOccurrence.color로 내려 준다).
const kHolidayColor = '#E53935';
const kBirthdayColor = '#F06292';
const kLeaveColor = '#12B886';
const kTripColor = '#F08C00';
const kBookingColor = '#7950F2';

/// 내장 캘린더 id들 — DB 행이 없어 서버에 저장·삭제·색 변경을 하지 않는다.
const kBuiltinCalendarIds = {
  kHolidaysCalendarId,
  kBirthdaysCalendarId,
  kLeavesCalendarId,
  kTripsCalendarId,
  kBookingsCalendarId,
};

/// 시각을 뺀 날짜(기기 시간대 기준 자정). 달력 격자·날짜 비교는 전부 이 값으로 한다.
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// [d]에서 [days]일 뒤(음수면 앞) 날짜. Duration을 더하지 않고 y/m/d로 계산해서 일광절약시간 전환일에도
/// 하루가 23/25시간이라 어긋나지 않는다.
DateTime addDays(DateTime d, int days) =>
    DateTime(d.year, d.month, d.day + days);

/// 종일 일정용: 날짜(y/m/d)를 UTC 자정으로 본 epoch ms.
int allDayToMs(DateTime day) =>
    DateTime.utc(day.year, day.month, day.day).millisecondsSinceEpoch;

/// 종일 일정용: epoch ms를 UTC의 y/m/d로만 읽어 기기 시간대의 그 날짜 자정으로 돌려준다.
DateTime allDayFromMs(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  return DateTime(d.year, d.month, d.day);
}

bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

final _weekdayShort = [
  tr('일'),
  tr('월'),
  tr('화'),
  tr('수'),
  tr('목'),
  tr('금'),
  tr('토'),
];

/// 0=일 … 6=토 (서버 recurrence.byWeekday와 같은 번호).
String weekdayShortKo(int index) => _weekdayShort[index % 7];

/// Dart의 DateTime.weekday(월=1 … 일=7)를 서버 byWeekday 번호(일=0 … 토=6)로.
int weekdayIndex(DateTime d) => d.weekday % 7;

/// 시간 일정의 반복 요일을 "기기의 요일"과 "서버가 읽는 요일" 사이에서 옮길 때 더할 일수 — 서버는 시간 일정의
/// 반복(byWeekday 포함)을 Asia/Seoul 달력으로 읽는데(규약), 기기가 한국이 아닌 시간대면 같은 순간이 다른 요일이
/// 될 수 있다(예: UTC-8 일요일 20:00 = 한국 월요일 13:00). 보낼 때는 기기 요일에 이 값을 더하고, 받을 때는
/// 뺀다. 한국 시간대 기기는 항상 0이라 아무것도 달라지지 않는다. 종일 일정은 날짜 자체가 시간대와 무관해서
/// 옮기지 않는다(호출부가 0을 쓴다).
///
/// [localOffset]은 기기 시간대를 흉내 내는 테스트용 — 안 주면 [startMs] 시각의 기기 UTC 오프셋을 쓴다.
int kstWeekdayShift(int startMs, {Duration? localOffset}) {
  const dayMs = 86400000;
  final offset =
      localOffset ??
      DateTime.fromMillisecondsSinceEpoch(startMs).timeZoneOffset;
  final localDay = ((startMs + offset.inMilliseconds) / dayMs).floor();
  final kstDay = ((startMs + 9 * 3600000) / dayMs).floor();
  return kstDay - localDay;
}

DateTime? _parseDateOnly(String? s) {
  if (s == null || s.length < 10) return null;
  final y = int.tryParse(s.substring(0, 4));
  final m = int.tryParse(s.substring(5, 7));
  final d = int.tryParse(s.substring(8, 10));
  if (y == null || m == null || d == null) return null;
  return DateTime(y, m, d);
}

String _dateOnlyString(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 캘린더 한 개(GET /teams/:teamId/calendars 의 항목). 내장 구독 캘린더는 서버 목록에 없어서
/// [CalendarInfo.holidays]/[CalendarInfo.birthdays]로 클라이언트가 만든다.
class CalendarInfo {
  final String id;
  final String teamId;

  /// 'personal'(기본) | 'team' | 'shared' | 'holidays' | 'birthdays'(내장, 클라이언트가 만든 것)
  /// | 'external'(외부 ICS 구독 — id가 `ext:`로 시작하고 나에게만 보인다, 읽기 전용).
  final String kind;
  final String name;

  /// 내가 바꾼 색 ?? 캘린더 기본 색. '#RRGGBB'.
  final String color;
  final String defaultColor;
  final bool isPublic;
  final String? ownerId;
  final String? ownerName;

  /// 'admin' | 'write' | 'read' | 'subscriber'
  final String role;

  /// 내 화면에서 숨김. 내장 캘린더는 서버가 아니라 로컬 저장값이 채운다.
  final bool hidden;
  final bool canCreateEvents;
  final bool canDelete;
  final bool canEditSettings;

  /// 외부 캘린더(kind 'external')만: 구독 주소의 호스트(calendar.google.com 등), 마지막으로 받아 온 때, 마지막 실패 이유.
  final String? host;
  final DateTime? lastSuccessAt;
  final String? lastError;

  const CalendarInfo({
    required this.id,
    this.teamId = '',
    required this.kind,
    required this.name,
    required this.color,
    String? defaultColor,
    this.isPublic = false,
    this.ownerId,
    this.ownerName,
    this.role = 'read',
    this.hidden = false,
    this.canCreateEvents = false,
    this.canDelete = false,
    this.canEditSettings = false,
    this.host,
    this.lastSuccessAt,
    this.lastError,
  }) : defaultColor = defaultColor ?? color;

  factory CalendarInfo.fromJson(Map<String, dynamic> json) {
    final color = (json['color'] as String?) ?? '#4285F4';
    return CalendarInfo(
      id: json['id'] as String,
      teamId: (json['teamId'] as String?) ?? '',
      kind: (json['kind'] as String?) ?? 'shared',
      name: (json['name'] as String?) ?? '',
      color: color,
      defaultColor: (json['defaultColor'] as String?) ?? color,
      isPublic: json['isPublic'] as bool? ?? false,
      ownerId: json['ownerId'] as String?,
      ownerName: json['ownerName'] as String?,
      role: (json['role'] as String?) ?? 'read',
      hidden: json['hidden'] as bool? ?? false,
      canCreateEvents: json['canCreateEvents'] as bool? ?? false,
      canDelete: json['canDelete'] as bool? ?? false,
      canEditSettings: json['canEditSettings'] as bool? ?? false,
      host: json['host'] as String?,
      lastSuccessAt: json['lastSuccessAt'] is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['lastSuccessAt'] as num).toInt(),
            )
          : null,
      lastError: json['lastError'] as String?,
    );
  }

  factory CalendarInfo.holidays({bool hidden = false}) => CalendarInfo(
    id: kHolidaysCalendarId,
    kind: kHolidaysCalendarId,
    name: tr('국가 공휴일'),
    color: kHolidayColor,
    role: 'subscriber',
    hidden: hidden,
  );

  factory CalendarInfo.birthdays({bool hidden = false}) => CalendarInfo(
    id: kBirthdaysCalendarId,
    kind: kBirthdaysCalendarId,
    name: tr('멤버 생일'),
    color: kBirthdayColor,
    role: 'subscriber',
    hidden: hidden,
  );

  factory CalendarInfo.leaves({bool hidden = false}) => CalendarInfo(
    id: kLeavesCalendarId,
    kind: kLeavesCalendarId,
    name: tr('팀 휴가'),
    color: kLeaveColor,
    role: 'subscriber',
    hidden: hidden,
  );

  /// 승인된 출장(그룹웨어 출장 신청) — 팀 휴가처럼 정회원 이상에게만 보인다.
  factory CalendarInfo.trips({bool hidden = false}) => CalendarInfo(
    id: kTripsCalendarId,
    kind: kTripsCalendarId,
    name: tr('출장'),
    color: kTripColor,
    role: 'subscriber',
    hidden: hidden,
  );

  factory CalendarInfo.bookings({bool hidden = false}) => CalendarInfo(
    id: kBookingsCalendarId,
    kind: kBookingsCalendarId,
    name: tr('회의실 예약'),
    color: kBookingColor,
    role: 'subscriber',
    hidden: hidden,
  );

  CalendarInfo copyWith({
    String? name,
    String? color,
    bool? hidden,
    bool? isPublic,
  }) => CalendarInfo(
    id: id,
    teamId: teamId,
    kind: kind,
    name: name ?? this.name,
    color: color ?? this.color,
    defaultColor: defaultColor,
    isPublic: isPublic ?? this.isPublic,
    ownerId: ownerId,
    ownerName: ownerName,
    role: role,
    hidden: hidden ?? this.hidden,
    canCreateEvents: canCreateEvents,
    canDelete: canDelete,
    canEditSettings: canEditSettings,
    host: host,
    lastSuccessAt: lastSuccessAt,
    lastError: lastError,
  );

  /// 국가 공휴일·멤버 생일·팀 휴가·출장·회의실 예약 — DB 행이 없어 서버에 저장·삭제·색 변경을 하지 않는다.
  bool get isBuiltin => kBuiltinCalendarIds.contains(id);

  /// 다른 사람의 캘린더를 구독 중인지(구독 취소로 없앨 수 있다).
  bool get isSubscriber => role == 'subscriber' && !isBuiltin && !isExternal;

  /// 외부 ICS 주소를 구독한 캘린더(Google·Outlook 등) — 나에게만 보이고 일정은 고칠 수 없다.
  bool get isExternal => kind == 'external';

  /// 내가 멤버로 들어 있는 shared 캘린더(소유자가 아니면 "나에게만 삭제"로 나갈 수 있다).
  bool get isSharedMember => kind == 'shared' && role != 'subscriber';
}

/// 외부 캘린더의 id 머리 — 서버가 외부 ICS 구독을 `ext:<id>`로 내려 준다(일정 회차의 calendarId도 같다).
const kExternalCalendarPrefix = 'ext:';

bool isExternalCalendarId(String id) => id.startsWith(kExternalCalendarPrefix);

/// `ext:<id>` → 서버 경로에 넣는 `<id>`.
String externalCalendarKey(String id) => isExternalCalendarId(id)
    ? id.substring(kExternalCalendarPrefix.length)
    : id;

/// 내 일정 내보내기(GET /teams/:teamId/calendar-feed) — [url]이 null이면 아직 만들지 않았다.
/// [publicAddress]는 서버에 공인 인증서가 걸린 웹 주소가 있는지(없으면 Google·Outlook 같은 바깥 서비스가 이 주소를 받지 못할 수 있다).
class CalendarFeed {
  final String? url;
  final bool publicAddress;
  final DateTime? createdAt;
  final DateTime? lastAccessAt;

  const CalendarFeed({
    this.url,
    this.publicAddress = false,
    this.createdAt,
    this.lastAccessAt,
  });

  factory CalendarFeed.fromJson(Map<String, dynamic> json) {
    DateTime? at(Object? v) =>
        v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
    return CalendarFeed(
      url: json['url'] as String?,
      publicAddress: json['publicAddress'] as bool? ?? false,
      createdAt: at(json['createdAt']),
      lastAccessAt: at(json['lastAccessAt']),
    );
  }
}

/// 캘린더 멤버 한 명(GET /calendars/:id/members).
class CalendarMember {
  final String userId;
  final String name;

  /// 'admin' | 'write' | 'read'
  final String role;
  final bool isOwner;
  const CalendarMember({
    required this.userId,
    required this.name,
    required this.role,
    this.isOwner = false,
  });

  factory CalendarMember.fromJson(Map<String, dynamic> json) => CalendarMember(
    userId: json['userId'] as String,
    name: (json['name'] as String?) ?? '',
    role: (json['role'] as String?) ?? 'read',
    isOwner: json['isOwner'] as bool? ?? false,
  );
}

/// 구독할 캘린더 검색 결과 한 줄(GET /teams/:teamId/calendars/search).
class CalendarSearchResult {
  final String id;
  final String kind;
  final String name;
  final String color;
  final String? ownerName;
  final bool subscribed;
  const CalendarSearchResult({
    required this.id,
    required this.kind,
    required this.name,
    required this.color,
    this.ownerName,
    this.subscribed = false,
  });

  factory CalendarSearchResult.fromJson(Map<String, dynamic> json) =>
      CalendarSearchResult(
        id: json['id'] as String,
        kind: (json['kind'] as String?) ?? 'shared',
        name: (json['name'] as String?) ?? '',
        color: (json['color'] as String?) ?? '#4285F4',
        ownerName: json['ownerName'] as String?,
        subscribed: json['subscribed'] as bool? ?? false,
      );
}

/// 일정 참석자.
class Attendee {
  final String userId;
  final String name;
  const Attendee({required this.userId, required this.name});

  factory Attendee.fromJson(Map<String, dynamic> json) => Attendee(
    userId: json['userId'] as String,
    name: (json['name'] as String?) ?? '',
  );

  Map<String, dynamic> toJson() => {'userId': userId, 'name': name};
}

/// 반복 규칙 — `{ freq, interval, byWeekday, until: 'YYYY-MM-DD', count }`.
/// until과 count는 동시에 갖지 못한다(서버가 400). byWeekday는 weekly에서만 쓰고 0=일 … 6=토.
class Recurrence {
  /// 'daily' | 'weekly' | 'monthly' | 'yearly'
  final String freq;
  final int interval;
  final List<int> byWeekday;
  final DateTime? until;
  final int? count;

  const Recurrence({
    required this.freq,
    this.interval = 1,
    this.byWeekday = const [],
    this.until,
    this.count,
  });

  /// [weekdayShift]는 서버 요일을 기기 요일로 옮길 때 각 요일에 더할 일수(-[kstWeekdayShift]) — 시간
  /// 일정만 쓰고, 안 주면 서버 값 그대로다.
  factory Recurrence.fromJson(
    Map<String, dynamic> json, {
    int weekdayShift = 0,
  }) => Recurrence(
    freq: (json['freq'] as String?) ?? 'daily',
    interval: (json['interval'] as num?)?.toInt() ?? 1,
    byWeekday: [
      for (final w in (json['byWeekday'] as List?) ?? const [])
        ((w as num).toInt() + weekdayShift) % 7,
    ],
    until: _parseDateOnly(json['until'] as String?),
    count: (json['count'] as num?)?.toInt(),
  );

  /// [weekdayShift]는 기기 요일을 서버 요일로 옮길 때 각 요일에 더할 일수([kstWeekdayShift]) — 시간 일정만
  /// 쓰고, 안 주면 그대로 보낸다.
  Map<String, dynamic> toJson({int weekdayShift = 0}) => {
    'freq': freq,
    'interval': interval,
    if (freq == 'weekly' && byWeekday.isNotEmpty)
      'byWeekday': ([for (final w in byWeekday) (w + weekdayShift) % 7]
        ..sort()),
    if (until != null) 'until': _dateOnlyString(until!),
    if (count != null) 'count': count,
  };

  /// "매주 월·수요일 반복" 같은 한 줄 요약. byWeekday가 비어 있으면(서버가 시작 요일로 본다) [startDay]의
  /// 요일을 쓰고, 그것도 없으면 요일 없이 "매주 반복"으로 적는다.
  String summary({DateTime? startDay}) {
    final every = interval <= 1;
    String base;
    switch (freq) {
      case 'weekly':
        final days = byWeekday.isNotEmpty
            ? ([...byWeekday]..sort())
            : [if (startDay != null) weekdayIndex(startDay)];
        final dayText = days.isEmpty
            ? ''
            : tr(' {p0}요일', {'p0': days.map(weekdayShortKo).join('·')});
        base = every
            ? tr('매주{dayText} 반복', {'dayText': dayText})
            : tr('{interval}주마다{dayText} 반복', {
                'interval': interval,
                'dayText': dayText,
              });
      case 'monthly':
        final dayText = startDay == null
            ? ''
            : tr(' {startDay.day}일', {'startDay.day': startDay.day});
        base = every
            ? tr('매월{dayText} 반복', {'dayText': dayText})
            : tr('{interval}개월마다{dayText} 반복', {
                'interval': interval,
                'dayText': dayText,
              });
      case 'yearly':
        final dayText = startDay == null
            ? ''
            : tr(' {startDay.month}월 {startDay.day}일', {
                'startDay.month': startDay.month,
                'startDay.day': startDay.day,
              });
        base = every
            ? tr('매년{dayText} 반복', {'dayText': dayText})
            : tr('{interval}년마다{dayText} 반복', {
                'interval': interval,
                'dayText': dayText,
              });
      default:
        base = every
            ? tr('매일 반복')
            : tr('{interval}일마다 반복', {'interval': interval});
    }
    if (until != null) {
      base += tr(' ({p0}년 {p1}월 {p2}일까지)', {
        'p0': until!.year,
        'p1': until!.month,
        'p2': until!.day,
      });
    } else if (count != null) {
      base += tr(' ({count}회)', {'count': count});
    }
    return base;
  }
}

/// 일정에 붙은 회의실·자원 예약(그룹웨어 — 일정 하나에 하나). [kind] 'room' | 'equipment' | 'vehicle'.
class EventResource {
  final String bookingId;
  final String resourceId;
  final String name;
  final String kind;
  const EventResource({
    required this.bookingId,
    required this.resourceId,
    required this.name,
    this.kind = 'room',
  });

  static EventResource? fromJson(Object? json) {
    if (json is! Map) return null;
    return EventResource(
      bookingId: json['bookingId'] as String? ?? '',
      resourceId: json['resourceId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      kind: json['kind'] as String? ?? 'room',
    );
  }
}

/// 조회 구간의 일정 한 회차(GET .../calendar/events 의 항목, GET /events/:id 도 같은 모양).
/// 공휴일·생일도 같은 모양으로 오며 [source]로 구분한다.
class EventOccurrence {
  /// 회차 고유키 — `<eventId>:<occurrenceStartMs>` / `holiday:2026-05-05` / `birthday:<userId>:2026-03-01`.
  final String key;
  final String? eventId;
  final String calendarId;

  /// 'event' | 'holiday' | 'birthday' | 'leave' | 'trip'(승인된 출장 — 장소는 출장지) | 'booking'(그룹웨어에서 잡은 회의실
  /// 예약) | 'external'(외부 ICS — 읽기 전용)
  final String source;
  final String title;
  final String? description;
  final String? location;

  /// 붙은 회의실·자원(일정) 또는 그 예약의 자원(회의실 예약). 없으면 null.
  final EventResource? resource;

  /// 원본 epoch ms. 종일이면 UTC 자정 기준 날짜이므로 직접 쓰지 말고 [firstDay]/[lastDay]를 쓴다.
  final int start;
  final int end;
  final bool allDay;

  /// 'public' | 'private'
  final String visibility;

  /// 비공개라서 자세히 볼 수 없다(title은 "비공개 일정").
  final bool restricted;
  final bool recurring;
  final Recurrence? recurrence;
  final String? creatorId;
  final String? creatorName;
  final List<Attendee> attendees;
  final String color;
  final bool canEdit;
  final bool canDelete;

  const EventOccurrence({
    required this.key,
    this.eventId,
    required this.calendarId,
    this.source = 'event',
    required this.title,
    this.description,
    this.location,
    this.resource,
    required this.start,
    required this.end,
    this.allDay = false,
    this.visibility = 'public',
    this.restricted = false,
    this.recurring = false,
    this.recurrence,
    this.creatorId,
    this.creatorName,
    this.attendees = const [],
    this.color = '#4285F4',
    this.canEdit = false,
    this.canDelete = false,
  });

  factory EventOccurrence.fromJson(Map<String, dynamic> json) {
    final recurrence = json['recurrence'];
    final start = (json['start'] as num).toInt();
    final allDay = json['allDay'] as bool? ?? false;
    return EventOccurrence(
      key: json['key'] as String,
      eventId: json['eventId'] as String?,
      calendarId: (json['calendarId'] as String?) ?? '',
      source: (json['source'] as String?) ?? 'event',
      title: (json['title'] as String?) ?? '',
      description: json['description'] as String?,
      location: json['location'] as String?,
      resource: EventResource.fromJson(json['resource']),
      start: start,
      end: (json['end'] as num).toInt(),
      allDay: allDay,
      visibility: (json['visibility'] as String?) ?? 'public',
      restricted: json['restricted'] as bool? ?? false,
      recurring: json['recurring'] as bool? ?? false,
      // 반복 요일은 한국 달력 기준으로 온다 — 시간 일정이면 기기 요일로 되돌려 둔다(kstWeekdayShift).
      recurrence: recurrence is Map
          ? Recurrence.fromJson(
              Map<String, dynamic>.from(recurrence),
              weekdayShift: allDay ? 0 : -kstWeekdayShift(start),
            )
          : null,
      creatorId: json['creatorId'] as String?,
      creatorName: json['creatorName'] as String?,
      attendees: [
        for (final a in (json['attendees'] as List?) ?? const [])
          Attendee.fromJson(Map<String, dynamic>.from(a as Map)),
      ],
      color: (json['color'] as String?) ?? '#4285F4',
      canEdit: json['canEdit'] as bool? ?? false,
      canDelete: json['canDelete'] as bool? ?? false,
    );
  }

  bool get isHoliday => source == 'holiday';
  bool get isBirthday => source == 'birthday';
  bool get isExternal => source == 'external';
  bool get isBooking => source == 'booking';

  /// 그룹웨어에서 승인된 출장(종일, [location]이 출장지) — 바꾸거나 취소하는 건 그룹웨어 결재에서 한다.
  bool get isTrip => source == 'trip';

  /// 사용자가 만든 일정(수정·삭제·참석자가 있을 수 있는 것) — 공휴일·생일이 아니다.
  bool get isUserEvent => source == 'event';
  bool get isPrivate => visibility == 'private';

  /// 시간 일정의 시작·끝 시각(기기 시간대). 종일 일정에는 의미가 없다.
  DateTime get startTime => DateTime.fromMillisecondsSinceEpoch(start);
  DateTime get endTime => DateTime.fromMillisecondsSinceEpoch(end);

  /// 이 회차가 시작하는 날(기기 시간대 기준 날짜). 종일은 UTC의 y/m/d 그대로.
  DateTime get firstDay => allDay ? allDayFromMs(start) : dateOnly(startTime);

  /// 이 회차의 마지막 날(포함). 종일의 end는 다음 날 자정(배타)이라 하루를 뺀다. 시간 일정이 자정
  /// 정각에 끝나면 그 날은 포함하지 않는다.
  DateTime get lastDay {
    final first = firstDay;
    if (allDay) {
      if (end <= start) return first;
      final last = addDays(allDayFromMs(end), -1);
      return last.isBefore(first) ? first : last;
    }
    if (end <= start) return first;
    final endMinusOne = DateTime.fromMillisecondsSinceEpoch(end - 1);
    final last = dateOnly(endMinusOne);
    return last.isBefore(first) ? first : last;
  }

  /// 며칠에 걸쳐 있는지(1이면 하루).
  int get dayCount => lastDay.difference(firstDay).inDays.abs() + 1;

  bool get isMultiDay => dayCount > 1;

  /// 월간 격자에서 가로 막대로 그릴지 — 종일이거나 여러 날에 걸친 일정.
  bool get isBar => allDay || isMultiDay;

  /// [day](날짜만)가 이 회차에 걸쳐 있는지.
  bool coversDay(DateTime day) {
    final d = dateOnly(day);
    return !d.isBefore(firstDay) && !d.isAfter(lastDay);
  }

  /// 색을 바꾸거나 [start]/[end]로 시각을 옮긴 복사본 — 옮기면 [key]도 새 시작 시각에 맞춰 바뀐다(서버 키와 같은 모양).
  EventOccurrence copyWith({String? color, int? start, int? end}) =>
      EventOccurrence(
        key: start == null || eventId == null ? key : '$eventId:$start',
        eventId: eventId,
        calendarId: calendarId,
        source: source,
        title: title,
        description: description,
        location: location,
        resource: resource,
        start: start ?? this.start,
        end: end ?? this.end,
        allDay: allDay,
        visibility: visibility,
        restricted: restricted,
        recurring: recurring,
        recurrence: recurrence,
        creatorId: creatorId,
        creatorName: creatorName,
        attendees: attendees,
        color: color ?? this.color,
        canEdit: canEdit,
        canDelete: canDelete,
      );
}

/// 일정 제목 검색 결과 한 줄(GET /teams/:teamId/calendar/search) — 일정(반복이면 시리즈) 하나가 한 줄이고,
/// [start]/[end]는 그 일정의 첫 회차다(종일이면 UTC 날짜 표현 그대로).
class CalendarSearchItem {
  final String eventId;
  final String calendarId;
  final String calendarName;
  final String color;
  final String title;
  final int start;
  final int end;
  final bool allDay;
  final bool recurring;
  final Recurrence? recurrence;
  final List<Attendee> attendees;
  final String? creatorName;
  final bool canEdit;

  const CalendarSearchItem({
    required this.eventId,
    required this.calendarId,
    this.calendarName = '',
    this.color = '#4285F4',
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
    this.recurring = false,
    this.recurrence,
    this.attendees = const [],
    this.creatorName,
    this.canEdit = false,
  });

  factory CalendarSearchItem.fromJson(Map<String, dynamic> json) {
    final recurrence = json['recurrence'];
    final start = (json['start'] as num).toInt();
    final allDay = json['allDay'] as bool? ?? false;
    return CalendarSearchItem(
      eventId: json['eventId'] as String,
      calendarId: (json['calendarId'] as String?) ?? '',
      calendarName: (json['calendarName'] as String?) ?? '',
      color: (json['color'] as String?) ?? '#4285F4',
      title: (json['title'] as String?) ?? '',
      start: start,
      end: (json['end'] as num).toInt(),
      allDay: allDay,
      recurring: json['recurring'] as bool? ?? recurrence is Map,
      recurrence: recurrence is Map
          ? Recurrence.fromJson(
              Map<String, dynamic>.from(recurrence),
              weekdayShift: allDay ? 0 : -kstWeekdayShift(start),
            )
          : null,
      attendees: [
        for (final a in (json['attendees'] as List?) ?? const [])
          Attendee.fromJson(Map<String, dynamic>.from(a as Map)),
      ],
      creatorName: json['creatorName'] as String?,
      canEdit: json['canEdit'] as bool? ?? false,
    );
  }

  /// 이 일정이 등록된 첫날(기기 시간대 날짜, 종일은 UTC y/m/d) — "이동" 버튼이 캘린더를 옮겨 갈 날짜.
  DateTime get firstDay => toOccurrence().firstDay;

  /// 기간 문구·상세 열기에 쓰는 첫 회차 모양.
  EventOccurrence toOccurrence() => EventOccurrence(
    key: '$eventId:$start',
    eventId: eventId,
    calendarId: calendarId,
    title: title,
    start: start,
    end: end,
    allDay: allDay,
    recurring: recurring,
    recurrence: recurrence,
    creatorName: creatorName,
    attendees: attendees,
    color: color,
    canEdit: canEdit,
    canDelete: canEdit,
  );
}

/// 검색 결과 한 쪽([nextBefore]가 null이 아니면 이어서 더 있다).
class CalendarSearchPage {
  final List<CalendarSearchItem> items;
  final String? nextBefore;
  const CalendarSearchPage({required this.items, this.nextBefore});
}

/// 일정 만들기 요청 본문(POST /calendars/:id/events). 수정(PATCH)은 바꿀 필드만 담은 Map을 따로 보낸다.
class EventInput {
  final String title;
  final String description;
  final String location;
  final int start;
  final int end;
  final bool allDay;
  final String visibility;
  final List<String> attendeeIds;
  final Recurrence? recurrence;

  /// 내 개인 색('#RRGGBB'). null이면 보내지 않아 캘린더 색을 그대로 따른다.
  final String? color;

  /// 함께 잡을 회의실·자원(그룹웨어) — 반복 없는 일정만. null이면 보내지 않는다.
  final String? resourceId;

  const EventInput({
    required this.title,
    this.description = '',
    this.location = '',
    required this.start,
    required this.end,
    this.allDay = false,
    this.visibility = 'public',
    this.attendeeIds = const [],
    this.recurrence,
    this.color,
    this.resourceId,
  });

  Map<String, dynamic> toJson() => {
    'title': title,
    'description': description,
    'location': location,
    'start': start,
    'end': end,
    'allDay': allDay,
    'visibility': visibility,
    'attendeeIds': attendeeIds,
    // 시간 일정의 반복 요일은 서버가 한국 달력으로 읽는다 — 기기 요일을 그에 맞게 옮긴다(kstWeekdayShift).
    'recurrence': recurrence?.toJson(
      weekdayShift: allDay ? 0 : kstWeekdayShift(start),
    ),
    'color': ?color,
    'resourceId': ?resourceId,
  };
}

/// 반복 일정을 고치거나 지울 때의 적용 범위(PATCH/DELETE 의 scope).
enum RecurrenceScope {
  /// 이 회차만
  thisOnly('this'),

  /// 이 회차와 이후 모든 회차
  following('following'),

  /// 모든 회차
  all('all');

  const RecurrenceScope(this.wire);
  final String wire;
}
