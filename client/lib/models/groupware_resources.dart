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
      );

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
  const ResourceBooking({
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
      );

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
  final int? halfDays;
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
    halfDays: (json['halfDays'] as num?)?.toInt(),
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
  const LeaveMonth({
    required this.month,
    this.holidays = const {},
    this.leaves = const [],
    this.trips = const [],
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
