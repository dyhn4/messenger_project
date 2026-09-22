import 'package:flutter/painting.dart' show Color;

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

/// 업무 유형(Bug/Feature/행사 등) — 프로젝트마다 이름과 색을 직접 관리한다(server task_types).
class TaskType {
  final String id;
  final String projectId;
  final String name;

  /// '#RRGGBB'
  final String color;
  final int position;

  const TaskType({
    required this.id,
    required this.projectId,
    required this.name,
    required this.color,
    this.position = 0,
  });

  factory TaskType.fromJson(Map<String, dynamic> json) => TaskType(
    id: json['id'] as String,
    projectId: json['projectId'] as String,
    name: json['name'] as String,
    color: json['color'] as String? ?? '#607D8B',
    position: (json['position'] as num?)?.toInt() ?? 0,
  );
}

/// 프로젝트별 업무 상태(칸반 열) — 이름/색은 자유, [category]는 진행률·완료 집계용 세 분류.
class TaskStatusDef {
  final String id;
  final String projectId;
  final String name;
  final String color;
  final TaskStatus category;
  final int position;

  const TaskStatusDef({
    required this.id,
    required this.projectId,
    required this.name,
    required this.color,
    required this.category,
    this.position = 0,
  });

  factory TaskStatusDef.fromJson(Map<String, dynamic> json) => TaskStatusDef(
    id: json['id'] as String,
    projectId: json['projectId'] as String,
    name: json['name'] as String,
    color: json['color'] as String? ?? '#94A3B8',
    category: taskStatusFromWire(json['category'] as String?),
    position: (json['position'] as num?)?.toInt() ?? 0,
  );
}

/// 프로젝트별 업무 우선순위 — 이름/색은 자유, [level]은 정렬·통계용 세 단계.
class TaskPriorityDef {
  final String id;
  final String projectId;
  final String name;
  final String color;
  final TaskPriority level;
  final int position;

  const TaskPriorityDef({
    required this.id,
    required this.projectId,
    required this.name,
    required this.color,
    required this.level,
    this.position = 0,
  });

  factory TaskPriorityDef.fromJson(Map<String, dynamic> json) =>
      TaskPriorityDef(
        id: json['id'] as String,
        projectId: json['projectId'] as String,
        name: json['name'] as String,
        color: json['color'] as String? ?? '#94A3B8',
        level: taskPriorityFromWire(json['level'] as String?),
        position: (json['position'] as num?)?.toInt() ?? 0,
      );
}

/// 프로젝트별 사용자 정의 필드 정의.
/// [kind]: text | number | date | select | multiSelect | progress.
class TaskFieldDef {
  final String id;
  final String projectId;
  final String name;
  final String kind;
  final List<String> options;
  final int position;

  const TaskFieldDef({
    required this.id,
    required this.projectId,
    required this.name,
    required this.kind,
    this.options = const [],
    this.position = 0,
  });

  factory TaskFieldDef.fromJson(Map<String, dynamic> json) => TaskFieldDef(
    id: json['id'] as String,
    projectId: json['projectId'] as String,
    name: json['name'] as String,
    kind: json['kind'] as String? ?? 'text',
    options:
        (json['options'] as List?)?.map((e) => e as String).toList() ??
        const [],
    position: (json['position'] as num?)?.toInt() ?? 0,
  );

  /// 선택지를 쓰는 종류인지(단일/다중 선택).
  bool get hasOptions => kind == 'select' || kind == 'multiSelect';

  /// 값을 목록/상세에 보여줄 글자로. 비어 있으면 null.
  String? display(dynamic value) {
    if (value == null) return null;
    if (kind == 'progress' && value is num) return '${value.round()}%';
    if (kind == 'multiSelect') {
      final list = value is List ? value : const [];
      return list.isEmpty ? null : list.join(', ');
    }
    if (kind == 'date' && value is num) {
      final d = DateTime.fromMillisecondsSinceEpoch(value.toInt());
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    }
    if (kind == 'number' && value is num) {
      return value == value.roundToDouble()
          ? value.toInt().toString()
          : value.toString();
    }
    final s = value.toString();
    return s.isEmpty ? null : s;
  }
}

/// '#RRGGBB' → Color(불투명). 형식이 이상하면 회색.
Color parseTypeColor(String? hex) {
  final h = (hex ?? '').replaceFirst('#', '');
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return Color(v ?? 0xFF607D8B);
}

/// 프로젝트 — 토픽(대화방)과 별개로 업무를 모아 관리하는 공간(server/src/projects.js).
class Project {
  final String id;
  final String teamId;
  final String name;
  final String? description;

  /// 업무 번호 앞에 붙는 짧은 식별자(예: 'MKT' → MKT-1001).
  final String identifier;

  /// 사이드바 등에서 프로젝트를 구분해 주는 대표 색('#RRGGBB').
  final String color;

  /// 공개 프로젝트 — 팀의 정회원 이상이 초대 없이 찾아보고 참여할 수 있다.
  final bool isPublic;

  /// 공개 프로젝트 둘러보기 목록(GET /projects/browse)에서만 채워지는 구성원 수.
  final int? memberCount;

  /// 종료(보관)된 프로젝트 — 읽기만 되고 업무를 만들거나 고칠 수 없다.
  final bool archived;

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

  /// 구성원 id → 프로젝트 역할('owner' | 'member'). 상세 조회에서만 채워진다.
  final Map<String, String> memberRoles;

  Project({
    required this.id,
    required this.teamId,
    required this.name,
    this.description,
    required this.identifier,
    this.color = '#5B8DEF',
    this.isPublic = false,
    this.memberCount,
    this.archived = false,
    this.favorite = false,
    this.myRole = 'member',
    this.taskTotal = 0,
    this.taskDone = 0,
    required this.createdAt,
    this.members = const [],
    this.memberRoles = const {},
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
    color: json['color'] as String? ?? '#5B8DEF',
    isPublic: json['isPublic'] as bool? ?? false,
    memberCount: (json['memberCount'] as num?)?.toInt(),
    archived: json['archived'] as bool? ?? false,
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
    memberRoles: {
      for (final m in (json['members'] as List?) ?? const [])
        (m as Map<String, dynamic>)['id'] as String:
            m['projectRole'] as String? ?? 'member',
    },
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

  /// 프로젝트별 상태(칸반 열) — 서버가 항상 채워주지만 예전 데이터를 위해 null이면 [status]로 대신한다.
  final String? statusId;
  final String? statusName;
  final String? statusColor;

  /// 사용자 정의 필드 값 {필드id: 값}.
  final Map<String, dynamic> customValues;
  final TaskPriority priority;

  /// 프로젝트별 우선순위 — 서버가 항상 채워주지만 예전 데이터를 위해 null이면 [priority]로 대신한다.
  final String? priorityId;
  final String? priorityName;
  final String? priorityColor;

  /// 업무 유형(프로젝트별) — 없으면 null.
  final String? typeId;
  final String? typeName;
  final String? typeColor;

  /// 참조자 id들 — "내 업무"에는 담당 업무와 참조된 업무가 같이 뜬다.
  final List<String> referenceIds;

  /// 목록을 받아온 사람 기준 내 역할 — 'assignee'(담당) | 'reference'(참조) | null.
  final String? myRole;

  /// 업무를 만든 사람(목록의 "생성자" 칸).
  final String? creatorId;
  final String? creatorName;
  final String creatorAvatarType;
  final String? creatorAvatarEmoji;
  final String? creatorAvatarColor;
  final String? creatorAvatarUrl;

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
    this.statusId,
    this.statusName,
    this.statusColor,
    this.customValues = const {},
    required this.priority,
    this.priorityId,
    this.priorityName,
    this.priorityColor,
    this.typeId,
    this.typeName,
    this.typeColor,
    this.referenceIds = const [],
    this.myRole,
    this.creatorId,
    this.creatorName,
    this.creatorAvatarType = 'initial',
    this.creatorAvatarEmoji,
    this.creatorAvatarColor,
    this.creatorAvatarUrl,
    this.startDate,
    this.dueDate,
    required this.createdAt,
    this.comments = const [],
  });

  /// 화면에 보이는 상태 이름 — 프로젝트가 정한 이름, 없으면 분류 이름.
  String get statusLabel => statusName ?? taskStatusLabel(status);

  /// 화면에 보이는 우선순위 이름 — 프로젝트가 정한 이름, 없으면 단계 이름.
  String get priorityLabel => priorityName ?? taskPriorityLabel(priority);

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
    statusId: json['statusId'] as String?,
    statusName: json['statusName'] as String?,
    statusColor: json['statusColor'] as String?,
    customValues:
        (json['customValues'] as Map?)?.cast<String, dynamic>() ?? const {},
    priority: taskPriorityFromWire(json['priority'] as String?),
    priorityId: json['priorityId'] as String?,
    priorityName: json['priorityName'] as String?,
    priorityColor: json['priorityColor'] as String?,
    typeId: json['typeId'] as String?,
    typeName: json['typeName'] as String?,
    typeColor: json['typeColor'] as String?,
    referenceIds:
        (json['referenceIds'] as List?)?.map((e) => e as String).toList() ??
        const [],
    myRole: json['myRole'] as String?,
    creatorId: json['creatorId'] as String?,
    creatorName: json['creatorName'] as String?,
    creatorAvatarType: json['creatorAvatarType'] as String? ?? 'initial',
    creatorAvatarEmoji: json['creatorAvatarEmoji'] as String?,
    creatorAvatarColor: json['creatorAvatarColor'] as String?,
    creatorAvatarUrl: json['creatorAvatarUrl'] as String?,
    startDate: (json['startDate'] as num?) != null
        ? DateTime.fromMillisecondsSinceEpoch(
            (json['startDate'] as num).toInt(),
          )
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

/// 프로젝트 노트 — 목록에서는 [body]가 null이고 [preview]만 있다(상세 조회에서 본문이 온다).
class ProjectNote {
  final String id;
  final String projectId;
  final String? projectName;
  final String? projectColor;
  final String title;
  final String? preview;
  final String? body;
  final String? createdBy;
  final String? createdByName;
  final String? updatedByName;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ProjectNote({
    required this.id,
    required this.projectId,
    this.projectName,
    this.projectColor,
    required this.title,
    this.preview,
    this.body,
    this.createdBy,
    this.createdByName,
    this.updatedByName,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ProjectNote.fromJson(Map<String, dynamic> json) => ProjectNote(
    id: json['id'] as String,
    projectId: json['projectId'] as String,
    projectName: json['projectName'] as String?,
    projectColor: json['projectColor'] as String?,
    title: json['title'] as String,
    preview: json['preview'] as String?,
    body: json['body'] as String?,
    createdBy: json['createdBy'] as String?,
    createdByName: json['createdByName'] as String?,
    updatedByName: json['updatedByName'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      (json['updatedAt'] as num).toInt(),
    ),
  );
}

/// 프로젝트 알림함의 한 줄 — [kind]: assigned | referenced | comment | status | due.
class ProjectNotification {
  final String id;
  final String projectId;
  final String? projectName;
  final String? projectColor;
  final String? taskId;
  final String kind;
  final String title;
  final String body;
  final DateTime createdAt;
  final bool read;

  const ProjectNotification({
    required this.id,
    required this.projectId,
    this.projectName,
    this.projectColor,
    this.taskId,
    required this.kind,
    required this.title,
    required this.body,
    required this.createdAt,
    this.read = false,
  });

  factory ProjectNotification.fromJson(Map<String, dynamic> json) =>
      ProjectNotification(
        id: json['id'] as String,
        projectId: json['projectId'] as String,
        projectName: json['projectName'] as String?,
        projectColor: json['projectColor'] as String?,
        taskId: json['taskId'] as String?,
        kind: json['kind'] as String,
        title: json['title'] as String,
        body: json['body'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (json['createdAt'] as num).toInt(),
        ),
        read: json['read'] as bool? ?? false,
      );
}

/// 프로젝트 알림 정책 — 담당자·팀 관리자가 정하고 그 프로젝트의 **모든 멤버**에게 적용된다.
/// 꺼둔 종류는 아무에게도 알림이 가지 않는다.
class ProjectNotificationPolicy {
  final bool status;
  final bool priority;
  final bool assigned;
  final bool referenced;
  final bool dueDate;
  final bool taskType;
  final bool customField;
  final bool created;
  final bool deleted;
  final bool comment;
  final bool due;

  const ProjectNotificationPolicy({
    this.status = true,
    this.priority = true,
    this.assigned = true,
    this.referenced = true,
    this.dueDate = true,
    this.taskType = true,
    this.customField = true,
    this.created = true,
    this.deleted = true,
    this.comment = true,
    this.due = true,
  });

  factory ProjectNotificationPolicy.fromJson(Map<String, dynamic> json) =>
      ProjectNotificationPolicy(
        status: json['status'] as bool? ?? true,
        priority: json['priority'] as bool? ?? true,
        assigned: json['assigned'] as bool? ?? true,
        referenced: json['referenced'] as bool? ?? true,
        dueDate: json['dueDate'] as bool? ?? true,
        taskType: json['taskType'] as bool? ?? true,
        customField: json['customField'] as bool? ?? true,
        created: json['created'] as bool? ?? true,
        deleted: json['deleted'] as bool? ?? true,
        comment: json['comment'] as bool? ?? true,
        due: json['due'] as bool? ?? true,
      );

  bool valueOf(String key) => switch (key) {
    'status' => status,
    'priority' => priority,
    'assigned' => assigned,
    'referenced' => referenced,
    'dueDate' => dueDate,
    'taskType' => taskType,
    'customField' => customField,
    'created' => created,
    'deleted' => deleted,
    'comment' => comment,
    _ => due,
  };
}

/// 이 프로젝트 알림에 대한 내 개인 설정 — 지금은 "전부 끄기" 하나뿐이다.
class ProjectNotificationSettings {
  final bool muted;
  const ProjectNotificationSettings({this.muted = false});

  factory ProjectNotificationSettings.fromJson(Map<String, dynamic> json) =>
      ProjectNotificationSettings(muted: json['muted'] as bool? ?? false);
}

/// 업무 템플릿 — "새 업무"에서 불러와 항목을 미리 채운다.
class TaskTemplate {
  final String id;
  final String projectId;
  final String name;
  final String title;
  final String? description;
  final TaskPriority priority;
  final String? typeId;
  final String? assigneeId;

  /// 등록일로부터 며칠 뒤가 마감인지(없으면 마감일을 안 채움).
  final int? dueOffsetDays;

  const TaskTemplate({
    required this.id,
    required this.projectId,
    required this.name,
    this.title = '',
    this.description,
    this.priority = TaskPriority.normal,
    this.typeId,
    this.assigneeId,
    this.dueOffsetDays,
  });

  factory TaskTemplate.fromJson(Map<String, dynamic> json) => TaskTemplate(
    id: json['id'] as String,
    projectId: json['projectId'] as String,
    name: json['name'] as String,
    title: json['title'] as String? ?? '',
    description: json['description'] as String?,
    priority: taskPriorityFromWire(json['priority'] as String?),
    typeId: json['typeId'] as String?,
    assigneeId: json['assigneeId'] as String?,
    dueOffsetDays: (json['dueOffsetDays'] as num?)?.toInt(),
  );
}

/// 자동화 규칙의 동작 한 개. [kind]: set_assignee | set_status | set_priority |
/// add_reference | add_comment | notify — 종류에 따라 userId/statusId/priority/text 중 하나를 쓴다.
class AutomationAction {
  final String kind;
  final String? userId;
  final String? statusId;
  final String? priority;
  final String? text;

  const AutomationAction(
    this.kind, {
    this.userId,
    this.statusId,
    this.priority,
    this.text,
  });

  factory AutomationAction.fromJson(Map<String, dynamic> json) =>
      AutomationAction(
        json['kind'] as String,
        userId: json['userId'] as String?,
        statusId: json['statusId'] as String?,
        priority: json['priority'] as String?,
        text: json['text'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'userId': ?userId,
    'statusId': ?statusId,
    'priority': ?priority,
    'text': ?text,
  };
}

/// 자동화 규칙 — [trigger]('task_created' | 'status_changed') 때 [condition]이 맞으면 [actions] 실행.
class AutomationRule {
  final String id;
  final String projectId;
  final String name;
  final bool enabled;
  final String trigger;
  final String? triggerStatusId;
  final String? conditionPriority;
  final String? conditionTypeId;
  final List<AutomationAction> actions;

  const AutomationRule({
    required this.id,
    required this.projectId,
    required this.name,
    required this.enabled,
    required this.trigger,
    this.triggerStatusId,
    this.conditionPriority,
    this.conditionTypeId,
    this.actions = const [],
  });

  factory AutomationRule.fromJson(Map<String, dynamic> json) {
    final condition =
        (json['condition'] as Map?)?.cast<String, dynamic>() ?? const {};
    return AutomationRule(
      id: json['id'] as String,
      projectId: json['projectId'] as String,
      name: json['name'] as String,
      enabled: json['enabled'] as bool? ?? true,
      trigger: json['trigger'] as String,
      triggerStatusId: json['triggerStatusId'] as String?,
      conditionPriority: condition['priority'] as String?,
      conditionTypeId: condition['typeId'] as String?,
      actions:
          (json['actions'] as List?)
              ?.map((e) => AutomationAction.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }
}

/// 노트 댓글.
class NoteComment {
  final String id;
  final String noteId;
  final String? senderId;
  final String senderName;
  final String text;
  final DateTime createdAt;

  const NoteComment({
    required this.id,
    required this.noteId,
    this.senderId,
    required this.senderName,
    required this.text,
    required this.createdAt,
  });

  factory NoteComment.fromJson(Map<String, dynamic> json) => NoteComment(
    id: json['id'] as String,
    noteId: json['noteId'] as String,
    senderId: json['senderId'] as String?,
    senderName: json['senderName'] as String? ?? '알 수 없음',
    text: json['text'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
  );
}

/// 노트 수정 이력 한 줄 — 목록에서는 [body]가 null이고, 상세 조회에서 본문이 온다.
class NoteVersion {
  final String id;
  final String title;
  final String? body;
  final String? editedByName;
  final DateTime editedAt;

  const NoteVersion({
    required this.id,
    required this.title,
    this.body,
    this.editedByName,
    required this.editedAt,
  });

  factory NoteVersion.fromJson(Map<String, dynamic> json) => NoteVersion(
    id: json['id'] as String,
    title: json['title'] as String,
    body: json['body'] as String?,
    editedByName: json['editedByName'] as String?,
    editedAt: DateTime.fromMillisecondsSinceEpoch(
      (json['editedAt'] as num).toInt(),
    ),
  );
}

/// 자동화 실행 기록 한 줄.
class AutomationRunLog {
  final String id;
  final String automationName;
  final String? taskId;
  final String? taskKey;
  final String trigger;
  final String summary;
  final bool ok;
  final DateTime createdAt;

  const AutomationRunLog({
    required this.id,
    required this.automationName,
    this.taskId,
    this.taskKey,
    required this.trigger,
    required this.summary,
    required this.ok,
    required this.createdAt,
  });

  factory AutomationRunLog.fromJson(Map<String, dynamic> json) =>
      AutomationRunLog(
        id: json['id'] as String,
        automationName: json['automationName'] as String,
        taskId: json['taskId'] as String?,
        taskKey: json['taskKey'] as String?,
        trigger: json['trigger'] as String,
        summary: json['summary'] as String? ?? '',
        ok: json['ok'] as bool? ?? true,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (json['createdAt'] as num).toInt(),
        ),
      );
}
