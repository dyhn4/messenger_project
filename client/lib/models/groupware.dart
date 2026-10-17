// 그룹웨어(전자결재·연차·출퇴근)의 데이터 모양 — 서버 API(server/src/groupware.js)를 그대로 옮긴 것.
//
// 휴가 양은 서버처럼 반일 단위 정수(halfDays — 하루 = 2, 반차 = 1)로 다루고, 날짜는 'YYYY-MM-DD' 글자, 시각은 epoch ms다.

/// 결재 종류 — 서버 approvalRules.js APPROVAL_KINDS.
enum ApprovalKind {
  leave('leave', '휴가'),
  expense('expense', '지출'),
  attendance('attendance', '근태 수정');

  final String wire;
  final String label;
  const ApprovalKind(this.wire, this.label);

  static ApprovalKind fromWire(String? value) =>
      values.firstWhere((k) => k.wire == value, orElse: () => leave);
}

/// 결재 상태 — 서버 approvalRules.js APPROVAL_STATUSES.
enum ApprovalStatus {
  pending('pending', '진행 중'),
  approved('approved', '승인'),
  rejected('rejected', '반려'),
  withdrawn('withdrawn', '회수'),
  canceled('canceled', '취소');

  final String wire;
  final String label;
  const ApprovalStatus(this.wire, this.label);

  static ApprovalStatus fromWire(String? value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => pending);
}

/// 결재선 한 칸의 상태.
enum ApprovalStepStatus {
  waiting('waiting', '대기'),
  pending('pending', '결재 차례'),
  approved('approved', '승인'),
  rejected('rejected', '반려');

  final String wire;
  final String label;
  const ApprovalStepStatus(this.wire, this.label);

  static ApprovalStepStatus fromWire(String? value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => waiting);
}

/// 결재함 — 서버 GET /groupware/documents?box=.
enum ApprovalBox {
  inbox('inbox', '결재할 문서'),
  mine('mine', '내가 올린 문서'),
  done('done', '결재한 문서'),
  cc('cc', '참조 문서'),
  all('all', '전체 문서');

  final String wire;
  final String label;
  const ApprovalBox(this.wire, this.label);
}

DateTime? _time(Object? v) =>
    v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;

/// 반일 단위 → "3일" / "2.5일" — 서버 annualLeave.js halfDaysText와 같다.
String halfDaysText(int halfDays) {
  final text = halfDays % 2 == 0
      ? '${halfDays ~/ 2}'
      : (halfDays / 2).toStringAsFixed(1);
  return '$text일';
}

/// 하루 중 분 → 'HH:MM'.
String minutesText(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

/// 시각 → 'HH:MM'(기기 시간대).
String clockText(DateTime? at) =>
    at == null ? '--:--' : minutesText(at.hour * 60 + at.minute);

/// 'YYYY-MM-DD' → "10/19".
String shortDateText(String key) => key.length >= 10
    ? '${int.parse(key.substring(5, 7))}/${int.parse(key.substring(8, 10))}'
    : key;

/// [d]의 'YYYY-MM-DD'(기기 날짜).
String dateKeyOf(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 금액 → "12,000원".
String wonText(int amount) {
  final digits = amount.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return '$buffer원';
}

/// 휴가 종류 — 서버 annualLeave.js LEAVE_TYPES.
class LeaveTypeInfo {
  final String key;
  final String label;
  final bool deducts;
  final bool half;
  const LeaveTypeInfo({
    required this.key,
    required this.label,
    required this.deducts,
    required this.half,
  });

  factory LeaveTypeInfo.fromJson(Map<String, dynamic> json) => LeaveTypeInfo(
    key: json['key'] as String,
    label: json['label'] as String? ?? json['key'] as String,
    deducts: json['deducts'] as bool? ?? false,
    half: json['half'] as bool? ?? false,
  );
}

/// 그룹웨어 화면을 열 때 받는 값 — 범위, 관리자인지, 근무 시간, 고를 것들(휴가 종류·지출 분류), 내가 결재할 문서 수.
class GroupwareContext {
  /// 'team'(팀마다) | 'server'(회사 전체).
  final String scope;

  /// 관리자 콘솔의 설정 값 — 'org' | 'team' | 'server'.
  final String scopeSetting;
  final String? teamId;
  final String? teamName;
  final bool isManager;
  final int workStart;
  final int workEnd;
  final String today;
  final String? hireDate;
  final int pendingForMe;
  final List<LeaveTypeInfo> leaveTypes;
  final List<String> expenseCategories;
  final int approversMax;
  final int ccMax;
  final int attachmentsMax;

  /// 지금 사내 와이파이인지(서버가 본 내 접속 주소).
  final bool inLan;

  const GroupwareContext({
    required this.scope,
    required this.scopeSetting,
    this.teamId,
    this.teamName,
    required this.isManager,
    required this.workStart,
    required this.workEnd,
    required this.today,
    this.hireDate,
    required this.pendingForMe,
    required this.leaveTypes,
    required this.expenseCategories,
    this.approversMax = 5,
    this.ccMax = 10,
    this.attachmentsMax = 5,
    this.inLan = false,
  });

  factory GroupwareContext.fromJson(Map<String, dynamic> json) {
    final limits =
        (json['limits'] as Map?)?.cast<String, dynamic>() ?? const {};
    return GroupwareContext(
      scope: json['scope'] as String? ?? 'team',
      scopeSetting: json['scopeSetting'] as String? ?? 'org',
      teamId: json['teamId'] as String?,
      teamName: json['teamName'] as String?,
      isManager: json['isManager'] as bool? ?? false,
      workStart: (json['workStart'] as num?)?.toInt() ?? 540,
      workEnd: (json['workEnd'] as num?)?.toInt() ?? 1080,
      today: json['today'] as String? ?? dateKeyOf(DateTime.now()),
      hireDate: json['hireDate'] as String?,
      pendingForMe: (json['pendingForMe'] as num?)?.toInt() ?? 0,
      leaveTypes: [
        for (final t in (json['leaveTypes'] as List? ?? const []))
          LeaveTypeInfo.fromJson((t as Map).cast<String, dynamic>()),
      ],
      expenseCategories: (json['expenseCategories'] as List? ?? const [])
          .cast<String>(),
      approversMax: (limits['approversMax'] as num?)?.toInt() ?? 5,
      ccMax: (limits['ccMax'] as num?)?.toInt() ?? 10,
      attachmentsMax: (limits['attachmentsMax'] as num?)?.toInt() ?? 5,
      inLan: json['inLan'] as bool? ?? false,
    );
  }

  LeaveTypeInfo? leaveType(String? key) {
    for (final t in leaveTypes) {
      if (t.key == key) return t;
    }
    return null;
  }

  String get scopeLabel => scope == 'server' ? '회사 전체' : (teamName ?? '팀');
}

/// 결재자·참조자 후보.
class ApprovalCandidate {
  final String id;
  final String name;
  final String username;
  const ApprovalCandidate({
    required this.id,
    required this.name,
    required this.username,
  });

  factory ApprovalCandidate.fromJson(Map<String, dynamic> json) =>
      ApprovalCandidate(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        username: json['username'] as String? ?? '',
      );
}

/// 저장한 결재선.
class ApprovalLine {
  final String id;
  final String name;
  final List<String> approverIds;
  final List<String> ccIds;
  const ApprovalLine({
    required this.id,
    required this.name,
    required this.approverIds,
    required this.ccIds,
  });

  factory ApprovalLine.fromJson(Map<String, dynamic> json) => ApprovalLine(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    approverIds: (json['approverIds'] as List? ?? const []).cast<String>(),
    ccIds: (json['ccIds'] as List? ?? const []).cast<String>(),
  );
}

/// 저장한 결재선들과 새 결재에 미리 채울 결재선(서버 approvalRules.js suggestApprovalLine).
class ApprovalLines {
  final List<ApprovalLine> lines;
  final List<String> suggestedApproverIds;
  final List<String> suggestedCcIds;

  /// 추천이 어디서 왔는지 — 'org'(조직도의 상위자 사슬) | 'saved'(가장 최근에 저장한 결재선) | null(추천 없음).
  final String? suggestedSource;
  const ApprovalLines({
    this.lines = const [],
    this.suggestedApproverIds = const [],
    this.suggestedCcIds = const [],
    this.suggestedSource,
  });

  factory ApprovalLines.fromJson(Map<String, dynamic> json) {
    final suggested = (json['suggested'] as Map?)?.cast<String, dynamic>();
    return ApprovalLines(
      lines: [
        for (final l in (json['lines'] as List? ?? const []))
          ApprovalLine.fromJson((l as Map).cast<String, dynamic>()),
      ],
      suggestedApproverIds: (suggested?['approverIds'] as List? ?? const [])
          .cast<String>(),
      suggestedCcIds: (suggested?['ccIds'] as List? ?? const []).cast<String>(),
      suggestedSource: suggested?['source'] as String?,
    );
  }
}

class ApprovalStep {
  final String id;
  final int order;
  final String? approverId;
  final String approverName;
  final ApprovalStepStatus status;
  final String? comment;
  final DateTime? decidedAt;
  const ApprovalStep({
    required this.id,
    required this.order,
    this.approverId,
    required this.approverName,
    required this.status,
    this.comment,
    this.decidedAt,
  });

  factory ApprovalStep.fromJson(Map<String, dynamic> json) => ApprovalStep(
    id: json['id'] as String,
    order: (json['order'] as num?)?.toInt() ?? 0,
    approverId: json['approverId'] as String?,
    approverName: json['approverName'] as String? ?? '(알 수 없음)',
    status: ApprovalStepStatus.fromWire(json['status'] as String?),
    comment: json['comment'] as String?,
    decidedAt: _time(json['decidedAt']),
  );
}

class ApprovalAttachment {
  final String? fileUrl;
  final String? fileName;
  final int? fileSize;
  final String? mimeType;
  const ApprovalAttachment({
    this.fileUrl,
    this.fileName,
    this.fileSize,
    this.mimeType,
  });

  factory ApprovalAttachment.fromJson(Map<String, dynamic> json) =>
      ApprovalAttachment(
        fileUrl: json['fileUrl'] as String?,
        fileName: json['fileName'] as String?,
        fileSize: (json['fileSize'] as num?)?.toInt(),
        mimeType: json['mimeType'] as String?,
      );
}

/// 결재 문서 하나.
class ApprovalDocument {
  final String id;
  final ApprovalKind kind;
  final String title;
  final String? body;

  /// 종류별 내용 — 휴가 { leaveType, startDate, endDate, halfDays }, 지출 { amount, category, spentOn }, 근태 수정
  /// { workDate, clockIn, clockOut }.
  final Map<String, dynamic> payload;
  final List<ApprovalAttachment> attachments;
  final ApprovalStatus status;
  final String? authorId;
  final String authorName;
  final DateTime? createdAt;
  final DateTime? decidedAt;
  final String? cancelReason;
  final String? canceledByName;
  final List<ApprovalStep> steps;

  /// 참조자(상세에서만).
  final List<({String id, String name})> cc;
  final bool myTurn;
  final bool canWithdraw;
  final bool canCancel;

  const ApprovalDocument({
    required this.id,
    required this.kind,
    required this.title,
    this.body,
    this.payload = const {},
    this.attachments = const [],
    required this.status,
    this.authorId,
    required this.authorName,
    this.createdAt,
    this.decidedAt,
    this.cancelReason,
    this.canceledByName,
    this.steps = const [],
    this.cc = const [],
    this.myTurn = false,
    this.canWithdraw = false,
    this.canCancel = false,
  });

  factory ApprovalDocument.fromJson(Map<String, dynamic> json) =>
      ApprovalDocument(
        id: json['id'] as String,
        kind: ApprovalKind.fromWire(json['kind'] as String?),
        title: json['title'] as String? ?? '',
        body: json['body'] as String?,
        payload: (json['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
        attachments: [
          for (final a in (json['attachments'] as List? ?? const []))
            ApprovalAttachment.fromJson((a as Map).cast<String, dynamic>()),
        ],
        status: ApprovalStatus.fromWire(json['status'] as String?),
        authorId: json['authorId'] as String?,
        authorName: json['authorName'] as String? ?? '(알 수 없음)',
        createdAt: _time(json['createdAt']),
        decidedAt: _time(json['decidedAt']),
        cancelReason: json['cancelReason'] as String?,
        canceledByName: json['canceledByName'] as String?,
        steps: [
          for (final s in (json['steps'] as List? ?? const []))
            ApprovalStep.fromJson((s as Map).cast<String, dynamic>()),
        ],
        cc: [
          for (final c in (json['cc'] as List? ?? const []))
            if (c is Map)
              (id: c['id'] as String? ?? '', name: c['name'] as String? ?? ''),
        ],
        myTurn: json['myTurn'] as bool? ?? false,
        canWithdraw: json['canWithdraw'] as bool? ?? false,
        canCancel: json['canCancel'] as bool? ?? false,
      );

  /// 지금 결재할 차례인 칸(진행 중일 때만).
  ApprovalStep? get currentStep {
    for (final s in steps) {
      if (s.status == ApprovalStepStatus.pending) return s;
    }
    return null;
  }

  /// 목록 한 줄의 요약 — 휴가 기간·양, 지출 금액, 근태 수정 날짜·시각.
  String summary(GroupwareContext? ctx) {
    switch (kind) {
      case ApprovalKind.leave:
        final label =
            ctx?.leaveType(payload['leaveType'] as String?)?.label ?? '휴가';
        final start = payload['startDate'] as String? ?? '';
        final end = payload['endDate'] as String? ?? start;
        final range = start == end
            ? shortDateText(start)
            : '${shortDateText(start)}~${shortDateText(end)}';
        final half = (payload['halfDays'] as num?)?.toInt() ?? 0;
        return '$label · $range · ${halfDaysText(half)}';
      case ApprovalKind.expense:
        final amount = (payload['amount'] as num?)?.toInt() ?? 0;
        return '${payload['category'] ?? ''} · ${wonText(amount)}';
      case ApprovalKind.attendance:
        final out = payload['clockOut'] as String?;
        return '${shortDateText(payload['workDate'] as String? ?? '')} · '
            '출근 ${payload['clockIn'] ?? ''}${out == null ? '' : ' · 퇴근 $out'}';
    }
  }
}

class LeaveAdjustment {
  final String id;
  final int halfDays;
  final String reason;
  final String createdByName;
  final DateTime? createdAt;
  const LeaveAdjustment({
    required this.id,
    required this.halfDays,
    required this.reason,
    required this.createdByName,
    this.createdAt,
  });

  factory LeaveAdjustment.fromJson(Map<String, dynamic> json) =>
      LeaveAdjustment(
        id: json['id'] as String,
        halfDays: (json['halfDays'] as num?)?.toInt() ?? 0,
        reason: json['reason'] as String? ?? '',
        createdByName: json['createdByName'] as String? ?? '',
        createdAt: _time(json['createdAt']),
      );
}

/// 연차 현황 — 입사일이 없으면 granted·remaining이 null(얼마나 남았는지 모름).
class LeaveBalance {
  final String? hireDate;
  final String? periodStart;
  final String? periodEnd;

  /// 근속 연수(0이면 입사 첫해).
  final int? serviceYears;
  final int? statutoryHalfDays;
  final int adjustmentHalfDays;
  final int? grantedHalfDays;
  final int usedHalfDays;
  final int pendingHalfDays;
  final int? remainingHalfDays;
  final List<LeaveAdjustment> adjustments;

  const LeaveBalance({
    this.hireDate,
    this.periodStart,
    this.periodEnd,
    this.serviceYears,
    this.statutoryHalfDays,
    this.adjustmentHalfDays = 0,
    this.grantedHalfDays,
    this.usedHalfDays = 0,
    this.pendingHalfDays = 0,
    this.remainingHalfDays,
    this.adjustments = const [],
  });

  factory LeaveBalance.fromJson(Map<String, dynamic> json) {
    final period = (json['period'] as Map?)?.cast<String, dynamic>();
    int? n(Object? v) => (v as num?)?.toInt();
    return LeaveBalance(
      hireDate: json['hireDate'] as String?,
      periodStart: period?['start'] as String?,
      periodEnd: period?['end'] as String?,
      serviceYears: n(period?['year']),
      statutoryHalfDays: n(json['statutoryHalfDays']),
      adjustmentHalfDays: n(json['adjustmentHalfDays']) ?? 0,
      grantedHalfDays: n(json['grantedHalfDays']),
      usedHalfDays: n(json['usedHalfDays']) ?? 0,
      pendingHalfDays: n(json['pendingHalfDays']) ?? 0,
      remainingHalfDays: n(json['remainingHalfDays']),
      adjustments: [
        for (final a in (json['adjustments'] as List? ?? const []))
          LeaveAdjustment.fromJson((a as Map).cast<String, dynamic>()),
      ],
    );
  }

  bool get known => grantedHalfDays != null;
}

/// 팀 휴가 목록의 한 줄(승인된 휴가).
class TeamLeave {
  final String documentId;
  final String? userId;
  final String name;
  final String leaveType;
  final String startDate;
  final String endDate;
  final int halfDays;
  const TeamLeave({
    required this.documentId,
    this.userId,
    required this.name,
    required this.leaveType,
    required this.startDate,
    required this.endDate,
    required this.halfDays,
  });

  factory TeamLeave.fromJson(Map<String, dynamic> json) => TeamLeave(
    documentId: json['documentId'] as String,
    userId: json['userId'] as String?,
    name: json['name'] as String? ?? '',
    leaveType: json['leaveType'] as String? ?? '',
    startDate: json['startDate'] as String? ?? '',
    endDate: json['endDate'] as String? ?? '',
    halfDays: (json['halfDays'] as num?)?.toInt() ?? 0,
  );
}

/// 출퇴근 기록 하나(지각·조퇴·일한 분은 서버가 계산해 준다).
class AttendanceRecord {
  final String id;
  final String workDate;
  final DateTime? clockInAt;
  final DateTime? clockOutAt;
  final bool? clockInLan;
  final bool? clockOutLan;
  final bool corrected;
  final DateTime? originalClockInAt;
  final DateTime? originalClockOutAt;
  final bool late;
  final bool earlyLeave;
  final int? workedMinutes;
  final bool missingClockOut;

  const AttendanceRecord({
    required this.id,
    required this.workDate,
    this.clockInAt,
    this.clockOutAt,
    this.clockInLan,
    this.clockOutLan,
    this.corrected = false,
    this.originalClockInAt,
    this.originalClockOutAt,
    this.late = false,
    this.earlyLeave = false,
    this.workedMinutes,
    this.missingClockOut = false,
  });

  factory AttendanceRecord.fromJson(Map<String, dynamic> json) =>
      AttendanceRecord(
        id: json['id'] as String,
        workDate: json['workDate'] as String? ?? '',
        clockInAt: _time(json['clockInAt']),
        clockOutAt: _time(json['clockOutAt']),
        clockInLan: json['clockInLan'] as bool?,
        clockOutLan: json['clockOutLan'] as bool?,
        corrected: json['corrected'] as bool? ?? false,
        originalClockInAt: _time(json['originalClockInAt']),
        originalClockOutAt: _time(json['originalClockOutAt']),
        late: json['late'] as bool? ?? false,
        earlyLeave: json['earlyLeave'] as bool? ?? false,
        workedMinutes: (json['workedMinutes'] as num?)?.toInt(),
        missingClockOut: json['missingClockOut'] as bool? ?? false,
      );

  static AttendanceRecord? maybe(Object? json) => json is Map
      ? AttendanceRecord.fromJson(json.cast<String, dynamic>())
      : null;
}

/// 오늘 출퇴근 상태.
class AttendanceToday {
  final String today;
  final AttendanceRecord? record;

  /// 어제 출근하고 아직 안 닫힌 기록(야간 근무 — 퇴근을 누르면 이걸 닫는다).
  final AttendanceRecord? openRecord;
  final bool canClockIn;
  final bool canClockOut;
  final bool inLan;
  final int workStart;
  final int workEnd;

  const AttendanceToday({
    required this.today,
    this.record,
    this.openRecord,
    required this.canClockIn,
    required this.canClockOut,
    required this.inLan,
    required this.workStart,
    required this.workEnd,
  });

  factory AttendanceToday.fromJson(Map<String, dynamic> json) =>
      AttendanceToday(
        today: json['today'] as String? ?? dateKeyOf(DateTime.now()),
        record: AttendanceRecord.maybe(json['record']),
        openRecord: AttendanceRecord.maybe(json['openRecord']),
        canClockIn: json['canClockIn'] as bool? ?? false,
        canClockOut: json['canClockOut'] as bool? ?? false,
        inLan: json['inLan'] as bool? ?? false,
        workStart: (json['workStart'] as num?)?.toInt() ?? 540,
        workEnd: (json['workEnd'] as num?)?.toInt() ?? 1080,
      );
}

/// 한 달 근태 요약 — 서버 attendanceRules.js summarizeMonth.
class AttendanceSummary {
  final int daysWorked;
  final int workedMinutes;
  final int late;
  final int earlyLeave;
  final int missingClockOut;
  final int absent;
  final int leaveHalfDays;
  const AttendanceSummary({
    this.daysWorked = 0,
    this.workedMinutes = 0,
    this.late = 0,
    this.earlyLeave = 0,
    this.missingClockOut = 0,
    this.absent = 0,
    this.leaveHalfDays = 0,
  });

  factory AttendanceSummary.fromJson(Map<String, dynamic> json) {
    int n(String key) => (json[key] as num?)?.toInt() ?? 0;
    return AttendanceSummary(
      daysWorked: n('daysWorked'),
      workedMinutes: n('workedMinutes'),
      late: n('late'),
      earlyLeave: n('earlyLeave'),
      missingClockOut: n('missingClockOut'),
      absent: n('absent'),
      leaveHalfDays: n('leaveHalfDays'),
    );
  }

  /// "152.5시간".
  String get hoursText {
    final hours = workedMinutes / 60;
    return '${hours == hours.roundToDouble() ? hours.toInt() : hours.toStringAsFixed(1)}시간';
  }
}

/// 한 달 근태의 하루.
class AttendanceDay {
  final String date;
  final String? holiday;
  final String? leaveType;
  final int leaveHalfDays;
  final AttendanceRecord? record;
  const AttendanceDay({
    required this.date,
    this.holiday,
    this.leaveType,
    this.leaveHalfDays = 0,
    this.record,
  });

  factory AttendanceDay.fromJson(Map<String, dynamic> json) {
    final leave = (json['leave'] as Map?)?.cast<String, dynamic>();
    return AttendanceDay(
      date: json['date'] as String,
      holiday: json['holiday'] as String?,
      leaveType: leave?['type'] as String?,
      leaveHalfDays: (leave?['halfDays'] as num?)?.toInt() ?? 0,
      record: AttendanceRecord.maybe(json['record']),
    );
  }

  /// 주말인지(토·일).
  bool get weekend {
    final d = DateTime.parse(date);
    return d.weekday == DateTime.saturday || d.weekday == DateTime.sunday;
  }
}

class AttendanceMonth {
  final String month;
  final List<AttendanceDay> days;
  final AttendanceSummary summary;
  const AttendanceMonth({
    required this.month,
    required this.days,
    required this.summary,
  });

  factory AttendanceMonth.fromJson(Map<String, dynamic> json) =>
      AttendanceMonth(
        month: json['month'] as String,
        days: [
          for (final d in (json['days'] as List? ?? const []))
            AttendanceDay.fromJson((d as Map).cast<String, dynamic>()),
        ],
        summary: AttendanceSummary.fromJson(
          (json['summary'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
      );
}

/// 관리자용 구성원별 한 달 근태 요약의 한 줄.
class AttendanceSummaryRow {
  final String userId;
  final String name;
  final AttendanceSummary summary;
  const AttendanceSummaryRow({
    required this.userId,
    required this.name,
    required this.summary,
  });

  factory AttendanceSummaryRow.fromJson(Map<String, dynamic> json) =>
      AttendanceSummaryRow(
        userId: json['userId'] as String,
        name: json['name'] as String? ?? '',
        summary: AttendanceSummary.fromJson(json),
      );
}

/// 관리자용 구성원 한 줄 — 입사일과 연차 현황.
class GroupwareMember {
  final String id;
  final String name;
  final String username;
  final String role;
  final bool suspended;
  final String? hireDate;
  final int? grantedHalfDays;
  final int usedHalfDays;
  final int pendingHalfDays;
  final int? remainingHalfDays;
  const GroupwareMember({
    required this.id,
    required this.name,
    required this.username,
    required this.role,
    this.suspended = false,
    this.hireDate,
    this.grantedHalfDays,
    this.usedHalfDays = 0,
    this.pendingHalfDays = 0,
    this.remainingHalfDays,
  });

  factory GroupwareMember.fromJson(Map<String, dynamic> json) {
    int? n(Object? v) => (v as num?)?.toInt();
    return GroupwareMember(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      username: json['username'] as String? ?? '',
      role: json['role'] as String? ?? 'guest',
      suspended: json['suspended'] as bool? ?? false,
      hireDate: json['hireDate'] as String?,
      grantedHalfDays: n(json['grantedHalfDays']),
      usedHalfDays: n(json['usedHalfDays']) ?? 0,
      pendingHalfDays: n(json['pendingHalfDays']) ?? 0,
      remainingHalfDays: n(json['remainingHalfDays']),
    );
  }
}

/// 결재 알림 종류 — 서버 approvalRules.js APPROVAL_NOTIFICATION_KINDS. 모르는 종류는 [other]로 읽고 그냥 보여 준다.
enum ApprovalNotificationKind {
  request('request'),
  approved('approved'),
  rejected('rejected'),
  withdrawn('withdrawn'),
  canceled('canceled'),
  other('other');

  final String wire;
  const ApprovalNotificationKind(this.wire);

  static ApprovalNotificationKind fromWire(String? value) =>
      values.firstWhere((k) => k.wire == value, orElse: () => other);
}

/// 결재 알림함의 한 건 — 알림 센터 "결재" 탭(서버 GET /groupware/notifications). 결재 요청(내 차례)·승인·반려·회수·취소.
class ApprovalNotification {
  final String id;
  final String documentId;

  /// 문서의 팀(팀 단위 범위) — 회사 전체 범위면 null.
  final String? teamId;
  final String? teamName;
  final ApprovalNotificationKind kind;
  final String title;
  final String body;
  final String? actorName;
  final ApprovalKind? docKind;
  final ApprovalStatus? docStatus;

  /// 지금 내가 결재할 차례인지 — 요청 알림을 받은 뒤 처리했거나 회수됐으면 false.
  final bool actionable;
  final DateTime createdAt;
  final bool read;

  const ApprovalNotification({
    required this.id,
    required this.documentId,
    this.teamId,
    this.teamName,
    required this.kind,
    required this.title,
    required this.body,
    this.actorName,
    this.docKind,
    this.docStatus,
    this.actionable = false,
    required this.createdAt,
    this.read = false,
  });

  factory ApprovalNotification.fromJson(Map<String, dynamic> j) =>
      ApprovalNotification(
        id: j['id'] as String,
        documentId: j['documentId'] as String,
        teamId: j['teamId'] as String?,
        teamName: j['teamName'] as String?,
        kind: ApprovalNotificationKind.fromWire(j['kind'] as String?),
        title: j['title'] as String? ?? '',
        body: j['body'] as String? ?? '',
        actorName: j['actorName'] as String?,
        docKind: j['docKind'] == null
            ? null
            : ApprovalKind.fromWire(j['docKind'] as String?),
        docStatus: j['docStatus'] == null
            ? null
            : ApprovalStatus.fromWire(j['docStatus'] as String?),
        actionable: j['actionable'] == true,
        createdAt: _time(j['createdAt']) ?? DateTime.now(),
        read: j['readAt'] != null,
      );

  ApprovalNotification asRead() => read
      ? this
      : ApprovalNotification(
          id: id,
          documentId: documentId,
          teamId: teamId,
          teamName: teamName,
          kind: kind,
          title: title,
          body: body,
          actorName: actorName,
          docKind: docKind,
          docStatus: docStatus,
          actionable: actionable,
          createdAt: createdAt,
          read: true,
        );
}
