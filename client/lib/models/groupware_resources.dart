// 그룹웨어 회의실·자원 예약과 휴가 달력의 데이터 모양 — 서버 groupwareResources.js(자원·예약)·groupwareWork.js(GET /groupware/leave/month)를 옮긴 것.

import '../l10n/tr.dart';

/// 자원 종류 — 서버 resourceRules.js RESOURCE_KINDS.
final resourceKindLabels = {
  'room': tr('회의실'),
  'equipment': tr('장비'),
  'vehicle': tr('차량'),
};

/// 회의실·장비·차량 하나. [busy]는 시간을 정해 받았을 때 그 시간에 잡힌 첫 예약(없으면 null).
class GroupwareResource {
  final String id;
  final String kind;
  final String name;
  final String? location;
  final int? capacity;
  final String? description;
  final bool enabled;
  final int sortOrder;
  final ResourceBooking? busy;

  /// 예약 규칙(서버 resourcePolicy.js) — 관리자 승인이 필요한지와 승인할 사람(비면 그룹웨어 관리자), 예약할 수 있는 사람(비면 모두),
  /// 요일(0=일~6=토, null이면 모든 요일)·시간대(하루 중 분 — null이면 언제나), 한 번에 쓸 수 있는 시간(분).
  final bool requiresApproval;
  final List<String> approverIds;
  final List<String> allowedUserIds;
  final List<int>? availableDays;
  final int? availableFrom;
  final int? availableTo;
  final int? maxMinutes;

  /// 회의실 앞 태블릿 화면 — 바로 예약을 허락했는지, 화면 주소(관리자에게만 — 서버 주소 뒤에 붙인다, 꺼졌으면 null).
  final bool displayQuickBook;
  final String? displayPath;

  /// 내가 예약할 수 있는지, 내가 잡으면 승인을 기다려야 하는지.
  final bool canBook;
  final bool needsApproval;

  /// 추천(GET /groupware/resources/suggest)일 때 남는 자리(수용 인원 − 참석자 — 모르면 null).
  final int? spare;
  const GroupwareResource({
    required this.id,
    this.kind = 'room',
    required this.name,
    this.location,
    this.capacity,
    this.description,
    this.enabled = true,
    this.sortOrder = 0,
    this.busy,
    this.requiresApproval = false,
    this.approverIds = const [],
    this.allowedUserIds = const [],
    this.availableDays,
    this.availableFrom,
    this.availableTo,
    this.maxMinutes,
    this.displayQuickBook = false,
    this.displayPath,
    this.canBook = true,
    this.needsApproval = false,
    this.spare,
  });

  factory GroupwareResource.fromJson(Map<String, dynamic> json) =>
      GroupwareResource(
        id: json['id'] as String,
        kind: json['kind'] as String? ?? 'room',
        name: json['name'] as String? ?? '',
        location: json['location'] as String?,
        capacity: (json['capacity'] as num?)?.toInt(),
        description: json['description'] as String?,
        enabled: json['enabled'] != false,
        sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
        busy: json['busy'] is Map
            ? ResourceBooking.fromJson(
                (json['busy'] as Map).cast<String, dynamic>(),
              )
            : null,
        requiresApproval: json['requiresApproval'] == true,
        approverIds: (json['approverIds'] as List? ?? const [])
            .whereType<String>()
            .toList(),
        allowedUserIds: (json['allowedUserIds'] as List? ?? const [])
            .whereType<String>()
            .toList(),
        availableDays: json['availableDays'] is List
            ? (json['availableDays'] as List)
                  .whereType<num>()
                  .map((d) => d.toInt())
                  .toList()
            : null,
        availableFrom: (json['availableFrom'] as num?)?.toInt(),
        availableTo: (json['availableTo'] as num?)?.toInt(),
        maxMinutes: (json['maxMinutes'] as num?)?.toInt(),
        displayQuickBook: json['displayQuickBook'] == true,
        displayPath: json['displayPath'] as String?,
        canBook: json['canBook'] != false,
        needsApproval: json['needsApproval'] == true,
        spare: (json['spare'] as num?)?.toInt(),
      );

  /// 예약 규칙을 하나라도 정했는지(목록에 "규칙" 표시).
  bool get hasPolicy =>
      requiresApproval ||
      allowedUserIds.isNotEmpty ||
      availableDays != null ||
      availableFrom != null ||
      maxMinutes != null;

  String get kindLabel => resourceKindLabels[kind] ?? tr('자원');

  /// "3층 · 12명" — 위치·수용 인원.
  String get detail => [
    if ((location ?? '').isNotEmpty) location!,
    if (capacity != null) tr('{capacity}명', {'capacity': capacity}),
  ].join(' · ');
}

/// 예약 한 건 — 캘린더 일정에 붙은 예약이면 [eventId]가 있고 제목은 그 일정의 것(비공개 일정이면 "비공개 일정").
class ResourceBooking {
  final String id;
  final String resourceId;
  final String resourceName;
  final String resourceKind;
  final String title;
  final String? userId;
  final String userName;
  final int start;
  final int end;
  final String? eventId;
  final bool mine;
  final bool canCancel;

  /// 'confirmed'(잡힘) | 'pending'(관리자 승인을 기다림 — 그 시간은 이미 막혀 있다).
  final String status;

  /// 반복 예약(매주·2주마다)의 묶음 id(반복이 아니면 null).
  final String? seriesId;
  const ResourceBooking({
    this.status = 'confirmed',
    this.seriesId,
    required this.id,
    required this.resourceId,
    this.resourceName = '',
    this.resourceKind = 'room',
    required this.title,
    this.userId,
    this.userName = '',
    required this.start,
    required this.end,
    this.eventId,
    this.mine = false,
    this.canCancel = false,
  });

  factory ResourceBooking.fromJson(Map<String, dynamic> json) =>
      ResourceBooking(
        id: json['id'] as String,
        resourceId: json['resourceId'] as String? ?? '',
        resourceName: json['resourceName'] as String? ?? '',
        resourceKind: json['resourceKind'] as String? ?? 'room',
        title: json['title'] as String? ?? '',
        userId: json['userId'] as String?,
        userName: json['userName'] as String? ?? '',
        start: (json['start'] as num).toInt(),
        end: (json['end'] as num).toInt(),
        eventId: json['eventId'] as String?,
        mine: json['mine'] == true,
        canCancel: json['canCancel'] == true,
        status: json['status'] as String? ?? 'confirmed',
        seriesId: json['seriesId'] as String?,
      );

  /// 승인을 기다리는지.
  bool get pending => status == 'pending';

  DateTime get startTime => DateTime.fromMillisecondsSinceEpoch(start);
  DateTime get endTime => DateTime.fromMillisecondsSinceEpoch(end);
  bool get fromEvent => eventId != null;
}

/// 휴가 달력의 휴가 한 건 — [status] 'approved' | 'pending'(내 것만 옴).
class MonthLeave {
  final String documentId;
  final String userId;
  final String name;
  final String? leaveType;
  final String label;
  final String startDate;
  final String endDate;
  final double? halfDays;
  final String status;
  final bool mine;
  const MonthLeave({
    required this.documentId,
    required this.userId,
    required this.name,
    this.leaveType,
    required this.label,
    required this.startDate,
    required this.endDate,
    this.halfDays,
    this.status = 'approved',
    this.mine = false,
  });

  factory MonthLeave.fromJson(Map<String, dynamic> json) => MonthLeave(
    documentId: json['documentId'] as String,
    userId: json['userId'] as String? ?? '',
    name: json['name'] as String? ?? '',
    leaveType: json['leaveType'] as String?,
    label: json['label'] as String? ?? tr('휴가'),
    startDate: json['startDate'] as String,
    endDate: json['endDate'] as String,
    halfDays: (json['halfDays'] as num?)?.toDouble(),
    status: json['status'] as String? ?? 'approved',
    mine: json['mine'] == true,
  );

  bool get pending => status == 'pending';
  bool covers(String day) =>
      startDate.compareTo(day) <= 0 && endDate.compareTo(day) >= 0;
}

/// 휴가 달력의 출장 한 건.
class MonthTrip {
  final String documentId;
  final String userId;
  final String name;
  final String? destination;
  final String startDate;
  final String endDate;
  const MonthTrip({
    required this.documentId,
    required this.userId,
    required this.name,
    this.destination,
    required this.startDate,
    required this.endDate,
  });

  factory MonthTrip.fromJson(Map<String, dynamic> json) => MonthTrip(
    documentId: json['documentId'] as String,
    userId: json['userId'] as String? ?? '',
    name: json['name'] as String? ?? '',
    destination: json['destination'] as String?,
    startDate: json['startDate'] as String,
    endDate: json['endDate'] as String,
  );

  bool covers(String day) =>
      startDate.compareTo(day) <= 0 && endDate.compareTo(day) >= 0;
}

/// 한 달 휴가 달력(GET /groupware/leave/month).
class LeaveMonth {
  final String month;
  final Map<String, String> holidays;
  final List<MonthLeave> leaves;
  final List<MonthTrip> trips;

  /// 부서 거르기 — 조직도의 부서(트리 순서, [depth] 1이 맨 위)와 이 응답에 적용한 부서(uuid · 'none'(부서 없음) · null(모두)).
  final List<({String id, String name, String? parentId, int depth})>
  departments;
  final String? departmentId;
  const LeaveMonth({
    required this.month,
    this.holidays = const {},
    this.leaves = const [],
    this.trips = const [],
    this.departments = const [],
    this.departmentId,
  });

  factory LeaveMonth.fromJson(Map<String, dynamic> json) => LeaveMonth(
    month: json['month'] as String? ?? '',
    holidays: {
      for (final h in json['holidays'] as List? ?? const [])
        if (h is Map) h['date'] as String: h['name'] as String? ?? tr('공휴일'),
    },
    leaves: [
      for (final l in json['leaves'] as List? ?? const [])
        MonthLeave.fromJson((l as Map).cast<String, dynamic>()),
    ],
    trips: [
      for (final t in json['trips'] as List? ?? const [])
        MonthTrip.fromJson((t as Map).cast<String, dynamic>()),
    ],
    departments: [
      for (final d in json['departments'] as List? ?? const [])
        if (d is Map && d['id'] is String)
          (
            id: d['id'] as String,
            name: d['name'] as String? ?? '',
            parentId: d['parentId'] as String?,
            depth: (d['depth'] as num?)?.toInt() ?? 1,
          ),
    ],
    departmentId: json['departmentId'] as String?,
  );

  List<MonthLeave> leavesOn(String day) => [
    for (final l in leaves)
      if (l.covers(day)) l,
  ];
  List<MonthTrip> tripsOn(String day) => [
    for (final t in trips)
      if (t.covers(day)) t,
  ];
}

/// 반복 예약 결과 — 첫 회차, 잡힌 회차 수, 겹쳐 건너뛴 회차(겹치는 날 빼고 잡았을 때).
typedef SeriesBookingResult = ({
  ResourceBooking first,
  int created,
  List<({int start, int end, String conflict})> skipped,
});

/// 자원 하나의 사용 통계(서버 resourcePolicy.js resourceStats) — 건수, 쓴 시간(분), 쓸 수 있던 시간(분), 이용률(%, 모르면 null), 쓴 사람
/// 수, 많이 쓴 사람(3명), 요일별 건수(0=일).
class ResourceStatsRow {
  final String resourceId;
  final String name;
  final String kind;
  final int count;
  final int minutes;
  final int availableMinutes;
  final double? utilization;
  final int userCount;
  final List<({String name, int count})> topUsers;
  final List<int> byWeekday;
  const ResourceStatsRow({
    required this.resourceId,
    required this.name,
    this.kind = 'room',
    this.count = 0,
    this.minutes = 0,
    this.availableMinutes = 0,
    this.utilization,
    this.userCount = 0,
    this.topUsers = const [],
    this.byWeekday = const [0, 0, 0, 0, 0, 0, 0],
  });

  factory ResourceStatsRow.fromJson(Map<String, dynamic> json) {
    int n(String k) => (json[k] as num?)?.toInt() ?? 0;
    return ResourceStatsRow(
      resourceId: json['resourceId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      kind: json['kind'] as String? ?? 'room',
      count: n('count'),
      minutes: n('minutes'),
      availableMinutes: n('availableMinutes'),
      utilization: (json['utilization'] as num?)?.toDouble(),
      userCount: n('userCount'),
      topUsers: [
        for (final u in json['topUsers'] as List? ?? const [])
          if (u is Map)
            (
              name: u['name'] as String? ?? '',
              count: (u['count'] as num?)?.toInt() ?? 0,
            ),
      ],
      byWeekday: [
        for (final d
            in json['byWeekday'] as List? ?? const [0, 0, 0, 0, 0, 0, 0])
          (d as num).toInt(),
      ],
    );
  }
}
