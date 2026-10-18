// 그룹웨어 근태·휴가 관리의 데이터 모양 — 서버 groupwareWork.js(범위 설정·유연근무·주 52시간·연차 사용 촉진)를 옮긴 것.
import 'groupware.dart';
import '../l10n/tr.dart';

/// 범위 설정 — 휴가 종류(꺼진 것 포함)·지출 분류·출근·퇴근 알림.
class GroupwareOptions {
  final List<LeaveTypeInfo> leaveTypes;
  final List<String> expenseCategories;
  final bool clockInReminder;
  final bool clockOutReminder;
  final int reminderDelayMinutes;

  /// 주 52시간 지키기 — 'warn'(알리기만) | 'approval'(48시간 넘으면 연장 결재를 받아야 출근) | 'block'(52시간이면 출근 막음).
  final String overtimeGuard;

  /// 연차 기준 — 'hire'(입사일) | 'fiscal'(회계연도 — [fiscalStartMonth]월 1일 시작), 연차 이월 상한(일 — 0이면 끔).
  final String leaveBasis;
  final int fiscalStartMonth;
  final int carryOverMaxDays;

  /// 가산율(%)과 5명 미만 사업장인지(가산 없음).
  final PayRates payRates;

  /// 사무실 위치(없으면 null — 거리를 재지 않음)·외근은 위치 필수.
  final ({double lat, double lng, int radius})? officeLocation;
  final bool requireFieldLocation;
  const GroupwareOptions({
    this.leaveTypes = const [],
    this.expenseCategories = const [],
    this.clockInReminder = false,
    this.clockOutReminder = false,
    this.reminderDelayMinutes = 10,
    this.overtimeGuard = 'warn',
    this.leaveBasis = 'hire',
    this.fiscalStartMonth = 1,
    this.carryOverMaxDays = 0,
    this.payRates = const PayRates(),
    this.officeLocation,
    this.requireFieldLocation = false,
  });

  factory GroupwareOptions.fromJson(
    Map<String, dynamic> json,
  ) => GroupwareOptions(
    leaveTypes: [
      for (final t in json['leaveTypes'] as List? ?? const [])
        LeaveTypeInfo.fromJson((t as Map).cast<String, dynamic>()),
    ],
    expenseCategories: (json['expenseCategories'] as List? ?? const [])
        .whereType<String>()
        .toList(),
    clockInReminder: json['clockInReminder'] == true,
    clockOutReminder: json['clockOutReminder'] == true,
    reminderDelayMinutes: (json['reminderDelayMinutes'] as num?)?.toInt() ?? 10,
    overtimeGuard: json['overtimeGuard'] as String? ?? 'warn',
    leaveBasis: json['leaveBasis'] as String? ?? 'hire',
    fiscalStartMonth: (json['fiscalStartMonth'] as num?)?.toInt() ?? 1,
    carryOverMaxDays: (json['carryOverMaxDays'] as num?)?.toInt() ?? 0,
    payRates: PayRates.fromJson(json['payRates']),
    officeLocation: json['officeLocation'] is Map
        ? (
            lat: ((json['officeLocation'] as Map)['lat'] as num).toDouble(),
            lng: ((json['officeLocation'] as Map)['lng'] as num).toDouble(),
            radius:
                ((json['officeLocation'] as Map)['radius'] as num?)?.toInt() ??
                200,
          )
        : null,
    requireFieldLocation: json['requireFieldLocation'] == true,
  );
}

/// 가산율(%) — 서버 workPolicy.js. 법정: 연장 50·야간 50·휴일 8시간까지 50·넘는 부분 100. [smallBusiness](상시 5명 미만)면 가산 없음.
class PayRates {
  final int overtime;
  final int night;
  final int holiday;
  final int holidayOver;
  final bool smallBusiness;
  const PayRates({
    this.overtime = 50,
    this.night = 50,
    this.holiday = 50,
    this.holidayOver = 100,
    this.smallBusiness = false,
  });

  factory PayRates.fromJson(Object? json) {
    if (json is! Map) return const PayRates();
    int n(String k, int d) => (json[k] as num?)?.toInt() ?? d;
    return PayRates(
      overtime: n('overtime', 50),
      night: n('night', 50),
      holiday: n('holiday', 50),
      holidayOver: n('holidayOver', 100),
      smallBusiness: json['smallBusiness'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'overtime': overtime,
    'night': night,
    'holiday': holiday,
    'holidayOver': holidayOver,
    'smallBusiness': smallBusiness,
  };
}

/// 연차 이월 결과(서버 POST /groupware/leave/carry-over) — [applied]는 넣은(미리 보기면 넣을) 사람과 양(반일), [skipped]는 건너뛴 까닭.
class CarryOverResult {
  final int capDays;
  final bool dryRun;
  final List<
    ({String userId, String name, double halfDays, String? from, String? to})
  >
  applied;
  final List<({String userId, String name, String reason})> skipped;
  const CarryOverResult({
    this.capDays = 0,
    this.dryRun = false,
    this.applied = const [],
    this.skipped = const [],
  });

  factory CarryOverResult.fromJson(Map<String, dynamic> json) =>
      CarryOverResult(
        capDays: (json['capDays'] as num?)?.toInt() ?? 0,
        dryRun: json['dryRun'] == true,
        applied: [
          for (final a in json['applied'] as List? ?? const [])
            if (a is Map)
              (
                userId: a['userId'] as String? ?? '',
                name: a['name'] as String? ?? '',
                halfDays: (a['halfDays'] as num?)?.toDouble() ?? 0,
                from: a['from'] as String?,
                to: a['to'] as String?,
              ),
        ],
        skipped: [
          for (final s in json['skipped'] as List? ?? const [])
            if (s is Map)
              (
                userId: s['userId'] as String? ?? '',
                name: s['name'] as String? ?? '',
                reason: s['reason'] as String? ?? '',
              ),
        ],
      );
}

/// 구성원 한 사람의 근무 형태(없으면 null — 범위의 근무 시간).
class MemberSchedule {
  final String userId;
  final String name;
  final WorkSchedule? schedule;
  const MemberSchedule({
    required this.userId,
    required this.name,
    this.schedule,
  });

  factory MemberSchedule.fromJson(Map<String, dynamic> json) => MemberSchedule(
    userId: json['userId'] as String,
    name: json['name'] as String? ?? '',
    schedule: WorkSchedule.fromJson(json['schedule']),
  );
}

/// 주 52시간 — 한 주의 구성원별 근로시간.
class WeeklyMember {
  final String userId;
  final String name;
  final WeeklyHours hours;

  /// 이 사람의 주 상한(분 — 탄력 60·64시간, 선택근무는 null), 기간 종류와 그 주가 든 기간의 근로시간.
  final int? weeklyLimitMinutes;
  final String? periodType;
  final WorkPeriodSummary? period;
  const WeeklyMember({
    required this.userId,
    required this.name,
    required this.hours,
    this.weeklyLimitMinutes = 52 * 60,
    this.periodType,
    this.period,
  });

  factory WeeklyMember.fromJson(Map<String, dynamic> json) => WeeklyMember(
    userId: json['userId'] as String,
    name: json['name'] as String? ?? '',
    hours: WeeklyHours.fromJson(json)!,
    weeklyLimitMinutes: json.containsKey('weeklyLimitMinutes')
        ? (json['weeklyLimitMinutes'] as num?)?.toInt()
        : 52 * 60,
    periodType: json['periodType'] as String?,
    period: WorkPeriodSummary.maybe(json['period']),
  );
}

/// 연차 사용 촉진 통지 — [stage] 1(1차: 쓸 날을 내라는 요구) | 2(2차: 회사가 정한 날).
class LeavePromotion {
  final String id;
  final String userId;
  final int stage;
  final String periodStart;
  final String periodEnd;
  final String expiry;
  final double remainingHalfDays;
  final String deadline;
  final String? message;
  final List<String> designatedDates;
  final List<String> planDates;
  final DateTime? plannedAt;
  final String? sentByName;
  final DateTime? sentAt;
  final DateTime? readAt;
  const LeavePromotion({
    required this.id,
    required this.userId,
    required this.stage,
    required this.periodStart,
    required this.periodEnd,
    required this.expiry,
    required this.remainingHalfDays,
    required this.deadline,
    this.message,
    this.designatedDates = const [],
    this.planDates = const [],
    this.plannedAt,
    this.sentByName,
    this.sentAt,
    this.readAt,
  });

  static DateTime? _t(Object? v) => (v as num?) == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch((v as num).toInt());

  factory LeavePromotion.fromJson(Map<String, dynamic> json) => LeavePromotion(
    id: json['id'] as String,
    userId: json['userId'] as String? ?? '',
    stage: (json['stage'] as num?)?.toInt() ?? 1,
    periodStart: json['periodStart'] as String? ?? '',
    periodEnd: json['periodEnd'] as String? ?? '',
    expiry: json['expiry'] as String? ?? '',
    remainingHalfDays: (json['remainingHalfDays'] as num?)?.toDouble() ?? 0,
    deadline: json['deadline'] as String? ?? '',
    message: json['message'] as String?,
    designatedDates: (json['designatedDates'] as List? ?? const [])
        .whereType<String>()
        .toList(),
    planDates: (json['planDates'] as List? ?? const [])
        .whereType<String>()
        .toList(),
    plannedAt: _t(json['plannedAt']),
    sentByName: json['sentByName'] as String?,
    sentAt: _t(json['sentAt']),
    readAt: _t(json['readAt']),
  );

  /// 1차 통지인데 아직 쓸 날을 안 냈고, [today]가 마감 안이면 — 받은 사람이 낼 차례.
  bool awaitingPlan(String today) =>
      stage == 1 && planDates.isEmpty && today.compareTo(deadline) <= 0;
}

/// 촉진 단계(서버 leavePromotion.js promotionStage).
enum PromotionStage {
  first('first', '1차 촉진 기간'),
  awaiting('awaiting', '계획 기다리는 중'),
  second('second', '2차 촉진 필요'),
  done('done', '끝남'),
  missed('missed', '기간을 놓침'),
  upcoming('upcoming', '아직 이름'),
  none('none', '남은 연차 없음');

  final String wire;
  final String _labelKo;

  /// 화면에 보일 이름(지금 언어 — l10n/tr.dart).
  String get label => tr(_labelKo);
  const PromotionStage(this.wire, this._labelKo);

  static PromotionStage fromWire(String? v) =>
      values.firstWhere((s) => s.wire == v, orElse: () => none);
}

/// 관리 탭 연차 촉진 목록의 한 사람.
class PromotionMember {
  final String userId;
  final String name;
  final String expiry;
  final bool firstYear;
  final String firstStart;
  final String firstEnd;
  final String secondDeadline;
  final double remainingHalfDays;
  final PromotionStage stage;
  final List<LeavePromotion> notices;
  const PromotionMember({
    required this.userId,
    required this.name,
    required this.expiry,
    required this.firstYear,
    required this.firstStart,
    required this.firstEnd,
    required this.secondDeadline,
    required this.remainingHalfDays,
    required this.stage,
    this.notices = const [],
  });

  factory PromotionMember.fromJson(Map<String, dynamic> json) =>
      PromotionMember(
        userId: json['userId'] as String,
        name: json['name'] as String? ?? '',
        expiry: json['expiry'] as String? ?? '',
        firstYear: json['firstYear'] == true,
        firstStart: json['firstStart'] as String? ?? '',
        firstEnd: json['firstEnd'] as String? ?? '',
        secondDeadline: json['secondDeadline'] as String? ?? '',
        remainingHalfDays: (json['remainingHalfDays'] as num?)?.toDouble() ?? 0,
        stage: PromotionStage.fromWire(json['stage'] as String?),
        notices: [
          for (final n in json['notices'] as List? ?? const [])
            LeavePromotion.fromJson((n as Map).cast<String, dynamic>()),
        ],
      );
}
