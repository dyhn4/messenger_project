import 'app_user.dart';

/// 업무 상태 — server/src/projects.js의 TASK_STATUSES와 1:1로 대응한다(칸반보드의 열이 될 값).
enum TaskStatus { todo, doing, done }

TaskStatus taskStatusFromWire(String? s) => switch (s) {
  'doing' => TaskStatus.doing,
  'done' => TaskStatus.done,
  _ => TaskStatus.todo,
};

String taskStatusToWire(TaskStatus s) => switch (s) {
  TaskStatus.todo => 'todo',
  TaskStatus.doing => 'doing',
  TaskStatus.done => 'done',
};

String taskStatusLabel(TaskStatus s) => switch (s) {
  TaskStatus.todo => '할 일',
  TaskStatus.doing => '진행 중',
  TaskStatus.done => '완료',
};

enum TaskPriority { low, normal, high }

TaskPriority taskPriorityFromWire(String? s) => switch (s) {
  'low' => TaskPriority.low,
  'high' => TaskPriority.high,
  _ => TaskPriority.normal,
};

String taskPriorityToWire(TaskPriority p) => switch (p) {
  TaskPriority.low => 'low',
  TaskPriority.normal => 'normal',
  TaskPriority.high => 'high',
};

String taskPriorityLabel(TaskPriority p) => switch (p) {
  TaskPriority.low => '낮음',
  TaskPriority.normal => '보통',
  TaskPriority.high => '높음',
};

/// 프로젝트 — 토픽(대화방)과 별개로 업무를 모아 관리하는 공간(server/src/projects.js).
class Project {
  final String id;
  final String teamId;
  final String name;
  final String? description;

  /// 업무 번호 앞에 붙는 짧은 식별자(예: 'MKT' → MKT-1001).
  final String identifier;

  /// 사이드바 "즐겨찾기" — 사람마다 다른 개인 설정이라 non-final(그 자리에서 토글한다).
  bool favorite;

  /// 이 프로젝트에서 내 역할 — 'owner'(담당자) | 'member'.
  final String myRole;

  /// 진행률 막대에 쓰는 업무 수.
  final int taskTotal;
  final int taskDone;

  final DateTime createdAt;

  /// 상세 조회(GET /projects/:id)로 받아올 때만 채워진다.
  final List<AppUser> members;

  Project({
    required this.id,
    required this.teamId,
    required this.name,
    this.description,
    required this.identifier,
    this.favorite = false,
    this.myRole = 'member',
    this.taskTotal = 0,
    this.taskDone = 0,
    required this.createdAt,
    this.members = const [],
  });

  bool get isOwner => myRole == 'owner';

  /// 0.0~1.0. 업무가 하나도 없으면 0으로 본다.
  double get progress => taskTotal == 0 ? 0 : taskDone / taskTotal;

  factory Project.fromJson(Map<String, dynamic> json) => Project(
    id: json['id'] as String,
    teamId: json['teamId'] as String,
    name: json['name'] as String,
    description: json['description'] as String?,
    identifier: json['identifier'] as String,
    favorite: json['favorite'] as bool? ?? false,
    myRole: json['myRole'] as String? ?? 'member',
    taskTotal: (json['taskTotal'] as num?)?.toInt() ?? 0,
    taskDone: (json['taskDone'] as num?)?.toInt() ?? 0,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
    members:
        (json['members'] as List?)
            ?.map((e) => AppUser.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
  );
}

/// 업무(태스크).
class Task {
  final String id;
  final String projectId;

  /// 화면에 보이는 번호(MKT-1001) — 서버가 만들어서 내려준다.
  final String? key;
  final String? projectName;

  final String title;
  final String? description;
  final String? assigneeId;
  final TaskStatus status;
  final TaskPriority priority;
  final DateTime? startDate;
  final DateTime? dueDate;
  final DateTime createdAt;

  /// 상세 조회(GET /tasks/:id)로 받아올 때만 채워진다.
  final List<TaskComment> comments;

  Task({
    required this.id,
    required this.projectId,
    this.key,
    this.projectName,
    required this.title,
    this.description,
    this.assigneeId,
    required this.status,
    required this.priority,
    this.startDate,
    this.dueDate,
    required this.createdAt,
    this.comments = const [],
  });

  /// 마감일 기준 D-day. 마감일이 없으면 null, 지났으면 양수(D+n).
  int? get daysUntilDue {
    final due = dueDate;
    if (due == null) return null;
    final today = DateTime.now();
    final d0 = DateTime(today.year, today.month, today.day);
    final d1 = DateTime(due.year, due.month, due.day);
    return d1.difference(d0).inDays;
  }

  /// 마감일이 지났는데 아직 완료가 아닌 업무.
  bool get isOverdue =>
      status != TaskStatus.done &&
      dueDate != null &&
      dueDate!.isBefore(DateTime.now());

  factory Task.fromJson(Map<String, dynamic> json) => Task(
    id: json['id'] as String,
    projectId: json['projectId'] as String,
    key: json['key'] as String?,
    projectName: json['projectName'] as String?,
    title: json['title'] as String,
    description: json['description'] as String?,
    assigneeId: json['assigneeId'] as String?,
    status: taskStatusFromWire(json['status'] as String?),
    priority: taskPriorityFromWire(json['priority'] as String?),
    startDate: (json['startDate'] as num?) != null
        ? DateTime.fromMillisecondsSinceEpoch((json['startDate'] as num).toInt())
        : null,
    dueDate: (json['dueDate'] as num?) != null
        ? DateTime.fromMillisecondsSinceEpoch((json['dueDate'] as num).toInt())
        : null,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
    comments:
        (json['comments'] as List?)
            ?.map((e) => TaskComment.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
  );
}

/// 업무 카드에 달린 댓글. [taskTitle]/[taskKey]/[projectName]은 대시보드의 "최근 댓글"
/// 목록으로 받아올 때만 채워진다(어느 업무의 댓글인지 한 줄로 보여주려고).
class TaskComment {
  final String id;
  final String taskId;
  final String projectId;
  final String? senderId;
  final String senderName;
  final String text;
  final DateTime createdAt;
  final String? taskTitle;
  final String? taskKey;
  final String? projectName;

  const TaskComment({
    required this.id,
    required this.taskId,
    required this.projectId,
    this.senderId,
    required this.senderName,
    required this.text,
    required this.createdAt,
    this.taskTitle,
    this.taskKey,
    this.projectName,
  });

  factory TaskComment.fromJson(Map<String, dynamic> json) => TaskComment(
    id: json['id'] as String,
    taskId: json['taskId'] as String,
    projectId: json['projectId'] as String,
    senderId: json['senderId'] as String?,
    senderName: json['senderName'] as String,
    text: json['text'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
    taskTitle: json['taskTitle'] as String?,
    taskKey: json['taskKey'] as String?,
    projectName: json['projectName'] as String?,
  );
}

/// 프로젝트 홈(대시보드)이 한 번에 받아오는 값 — GET /projects/home.
class ProjectHome {
  /// 내가 담당한 업무 기준 통계(전체/완료/진행/지연).
  final int total;
  final int done;
  final int doing;
  final int overdue;

  final List<Project> projects;
  final List<Task> myTasks;
  final List<TaskComment> recentComments;

  const ProjectHome({
    required this.total,
    required this.done,
    required this.doing,
    required this.overdue,
    required this.projects,
    required this.myTasks,
    required this.recentComments,
  });

  /// 이번 주 완료율(%) — 화면의 "이번 주 완료율"에 쓴다. 업무가 없으면 0%.
  int get donePercent => total == 0 ? 0 : ((done / total) * 100).round();

  factory ProjectHome.fromJson(Map<String, dynamic> json) {
    final stats = (json['stats'] as Map<String, dynamic>?) ?? const {};
    return ProjectHome(
      total: (stats['total'] as num?)?.toInt() ?? 0,
      done: (stats['done'] as num?)?.toInt() ?? 0,
      doing: (stats['doing'] as num?)?.toInt() ?? 0,
      overdue: (stats['overdue'] as num?)?.toInt() ?? 0,
      projects: ((json['projects'] as List?) ?? const [])
          .map((e) => Project.fromJson(e as Map<String, dynamic>))
          .toList(),
      myTasks: ((json['myTasks'] as List?) ?? const [])
          .map((e) => Task.fromJson(e as Map<String, dynamic>))
          .toList(),
      recentComments: ((json['recentComments'] as List?) ?? const [])
          .map((e) => TaskComment.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
