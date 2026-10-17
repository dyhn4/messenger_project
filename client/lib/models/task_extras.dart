import 'project.dart' show TaskStatus, taskStatusFromWire;

/// 업무 기능 보강(서버 taskExtras.js·taskExtrasRules.js) — 반복 업무 규칙, 선후행 업무 한 줄, 소요 시간 기록·타이머·보고.

/// 반복 업무 규칙 — 완료하면 다음 회차 업무가 생기고 규칙은 새 업무로 옮겨 간다. 캘린더 반복 일정과 같은 모양.
class TaskRecurrence {
  /// 'daily' | 'weekly' | 'monthly' | 'yearly'
  final String freq;
  final int interval;

  /// 매주 반복의 요일(일=0 … 토=6) — 비면 처음 날짜의 요일.
  final List<int> byWeekday;

  /// 반복 종료일 'YYYY-MM-DD'(그 날까지) — 없으면 끝없이.
  final String? until;

  const TaskRecurrence({
    required this.freq,
    this.interval = 1,
    this.byWeekday = const [],
    this.until,
  });

  static TaskRecurrence? fromJson(Object? json) {
    if (json is! Map || json['freq'] is! String) return null;
    return TaskRecurrence(
      freq: json['freq'] as String,
      interval: (json['interval'] as num?)?.toInt() ?? 1,
      byWeekday: [
        for (final d in (json['byWeekday'] as List? ?? const []))
          if (d is num) d.toInt(),
      ],
      until: json['until'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'freq': freq,
    'interval': interval,
    if (freq == 'weekly' && byWeekday.isNotEmpty) 'byWeekday': byWeekday,
    'until': ?until,
  };

  static const weekdayNames = ['일', '월', '화', '수', '목', '금', '토'];

  /// "매주 월·수", "2주마다", "매월 (~2026-12-31)" — 서버 recurrenceLabel과 같은 문구.
  String get label {
    const unit = {'daily': '일', 'weekly': '주', 'monthly': '개월', 'yearly': '년'};
    const every = {
      'daily': '매일',
      'weekly': '매주',
      'monthly': '매월',
      'yearly': '매년',
    };
    var text = interval == 1
        ? (every[freq] ?? freq)
        : '$interval${unit[freq] ?? ''}마다';
    if (freq == 'weekly' && byWeekday.isNotEmpty) {
      text += ' ${byWeekday.map((d) => weekdayNames[d % 7]).join('·')}';
    }
    if (until != null) text += ' (~$until)';
    return text;
  }
}

/// 선후행 목록의 업무 한 줄 — 번호·제목·상태·담당자.
class TaskLink {
  final String id;
  final String key;
  final String title;
  final TaskStatus status;
  final String? statusName;
  final String? statusColor;
  final String? assigneeName;
  final DateTime? dueDate;
  final bool archived;

  const TaskLink({
    required this.id,
    required this.key,
    required this.title,
    required this.status,
    this.statusName,
    this.statusColor,
    this.assigneeName,
    this.dueDate,
    this.archived = false,
  });

  bool get isDone => status == TaskStatus.done;

  factory TaskLink.fromJson(Map<String, dynamic> j) => TaskLink(
    id: j['id'] as String,
    key: j['key'] as String? ?? '',
    title: j['title'] as String? ?? '',
    status: taskStatusFromWire(j['status'] as String?),
    statusName: j['statusName'] as String?,
    statusColor: j['statusColor'] as String?,
    assigneeName: j['assigneeName'] as String?,
    dueDate: (j['dueDate'] as num?) == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((j['dueDate'] as num).toInt()),
    archived: j['archived'] as bool? ?? false,
  );

  static List<TaskLink> listFromJson(Object? json) => [
    for (final e in (json as List? ?? const []))
      if (e is Map) TaskLink.fromJson(Map<String, dynamic>.from(e)),
  ];
}

/// 업무 소요 시간 기록 하나 — 누가 어느 날 몇 분.
class TaskTimeEntry {
  final String id;
  final String taskId;
  final String userId;
  final String? userName;
  final int minutes;

  /// 일한 날 'YYYY-MM-DD'.
  final String workDate;
  final String? note;

  const TaskTimeEntry({
    required this.id,
    required this.taskId,
    required this.userId,
    this.userName,
    required this.minutes,
    required this.workDate,
    this.note,
  });

  factory TaskTimeEntry.fromJson(Map<String, dynamic> j) => TaskTimeEntry(
    id: j['id'] as String,
    taskId: j['taskId'] as String,
    userId: j['userId'] as String,
    userName: j['userName'] as String?,
    minutes: (j['minutes'] as num).toInt(),
    workDate: j['workDate'] as String? ?? '',
    note: j['note'] as String?,
  );

  static List<TaskTimeEntry> listFromJson(Object? json) => [
    for (final e in (json as List? ?? const []))
      if (e is Map) TaskTimeEntry.fromJson(Map<String, dynamic>.from(e)),
  ];
}

/// 돌고 있는 내 타이머(사람마다 하나 — 기기 사이에 같이 보인다).
class TaskTimer {
  final String taskId;
  final String key;
  final String title;
  final String projectId;
  final String? projectName;
  final DateTime startedAt;

  const TaskTimer({
    required this.taskId,
    required this.key,
    required this.title,
    required this.projectId,
    this.projectName,
    required this.startedAt,
  });

  static TaskTimer? fromJson(Object? json) {
    if (json is! Map || json['taskId'] is! String) return null;
    return TaskTimer(
      taskId: json['taskId'] as String,
      key: json['key'] as String? ?? '',
      title: json['title'] as String? ?? '',
      projectId: json['projectId'] as String? ?? '',
      projectName: json['projectName'] as String?,
      startedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['startedAt'] as num).toInt(),
      ),
    );
  }
}

/// 프로젝트 소요 시간 보고(GET /projects/:id/time-report).
class ProjectTimeReport {
  final String from;
  final String to;
  final int totalMinutes;
  final List<({String userId, String name, int minutes})> byMember;
  final List<
    ({String taskId, String key, String title, int minutes, int? estimate})
  >
  byTask;

  const ProjectTimeReport({
    required this.from,
    required this.to,
    required this.totalMinutes,
    required this.byMember,
    required this.byTask,
  });

  factory ProjectTimeReport.fromJson(Map<String, dynamic> j) =>
      ProjectTimeReport(
        from: j['from'] as String? ?? '',
        to: j['to'] as String? ?? '',
        totalMinutes: (j['totalMinutes'] as num?)?.toInt() ?? 0,
        byMember: [
          for (final m in (j['byMember'] as List? ?? const []))
            if (m is Map)
              (
                userId: m['userId'] as String? ?? '',
                name: m['name'] as String? ?? '(알 수 없음)',
                minutes: (m['minutes'] as num?)?.toInt() ?? 0,
              ),
        ],
        byTask: [
          for (final t in (j['byTask'] as List? ?? const []))
            if (t is Map)
              (
                taskId: t['taskId'] as String? ?? '',
                key: t['key'] as String? ?? '',
                title: t['title'] as String? ?? '',
                minutes: (t['minutes'] as num?)?.toInt() ?? 0,
                estimate: (t['estimateMinutes'] as num?)?.toInt(),
              ),
        ],
      );
}

/// 분 → "2시간 30분" · "45분" · "3시간"(서버 minutesLabel과 같다).
String formatMinutes(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '$m분';
  return m == 0 ? '$h시간' : '$h시간 $m분';
}

/// 타이머 경과 "1:05:09"·"12:03".
String formatElapsed(Duration d) {
  final s = d.inSeconds.clamp(0, 359999);
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
}
