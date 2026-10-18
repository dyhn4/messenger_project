import 'package:flutter/painting.dart' show Color;

import 'app_user.dart';
import 'task_extras.dart';
import 'text_format.dart';
import '../l10n/tr.dart';

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
  TaskStatus.todo => tr('할 일'),
  TaskStatus.doing => tr('진행 중'),
  TaskStatus.done => tr('완료'),
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
  TaskPriority.low => tr('낮음'),
  TaskPriority.normal => tr('보통'),
  TaskPriority.high => tr('높음'),
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

  /// 공개 프로젝트 — 팀의 정회원 이상 모두가 참여 절차 없이 자동으로 멤버가 된다.
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

  /// 노트 수정·삭제 권한 — 'all'(모두) | 'creator_admin'(생성자와 관리자). 값이 없으면 수정은
  /// 'all', 삭제는 예전처럼 작성자·관리자만 지울 수 있게 'creator_admin'으로 본다.
  final String noteEditPermission;
  final String noteDeletePermission;

  /// 이 프로젝트를 만든(또는 이 프로젝트로 저장한) 프로젝트 템플릿 id — 없거나 지워졌으면 null.
  final String? templateId;

  /// [templateId] 템플릿의 카드 내용 — 상세 조회(GET /projects/:id)에서만 서버가 붙여 준다
  /// (설정 > 필드 / 상태의 "업무 템플릿" 칸이 따로 요청하지 않도록). 기준은 [templateId]다.
  final ProjectTemplate? template;

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
    this.noteEditPermission = 'all',
    this.noteDeletePermission = 'creator_admin',
    this.templateId,
    this.template,
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
    noteEditPermission: json['noteEditPermission'] as String? ?? 'all',
    noteDeletePermission:
        json['noteDeletePermission'] as String? ?? 'creator_admin',
    templateId: json['templateId'] as String?,
    template: json['template'] is Map<String, dynamic>
        ? ProjectTemplate.fromJson(json['template'] as Map<String, dynamic>)
        : null,
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

  /// 담당자 이름·사진 — 구성원 목록 없이도(달력 일별 목록 등) 바로 그리려고 서버가 같이 준다.
  final String? assigneeName;
  final String assigneeAvatarType;
  final String? assigneeAvatarEmoji;
  final String? assigneeAvatarColor;
  final String? assigneeAvatarUrl;

  final DateTime? startDate;
  final DateTime? dueDate;
  final DateTime createdAt;

  /// 상세 조회(GET /tasks/:id)로 받아올 때만 채워진다.
  final List<TaskComment> comments;

  /// "기록" 탭 — 최신이 앞. 상세 조회에서만 채워진다.
  final List<TaskActivity> activities;

  /// 하위 업무면 부모 업무의 id. 하위 업무도 자기 번호·상태·담당자를 갖는 온전한 업무다.
  final String? parentTaskId;

  /// 보관한 업무 — 목록에서 빠지고 "보관된 업무"로만 보인다.
  final bool archived;

  /// 체크리스트 진행("2/4")과 하위 업무 개수 — 목록·상세에 숫자로만 쓴다.
  final int checklistDone;
  final int checklistTotal;
  final int subtaskCount;

  /// 댓글 수(답글 포함) — 칸반 카드의 말풍선 숫자.
  final int commentCount;

  /// 칸반 열 안에서의 순서(작을수록 위) — 한 번도 옮기지 않았으면 null.
  final int? boardPosition;

  /// 상세로 받아올 때만 채워진다(GET /api/tasks/:id).
  final List<TaskChecklistItem> checklist;
  final List<Task> subtasks;

  /// 반복 업무인지(목록 배지) — 규칙([recurrence])은 상세에만 온다. 완료하면 다음 회차가 생기고 규칙은 새 업무로 옮겨 간다.
  final bool recurring;
  final TaskRecurrence? recurrence;

  /// 예상 소요 시간(분, 없으면 null)과 지금까지 기록한 시간 합(분).
  final int? estimateMinutes;
  final int spentMinutes;

  /// 아직 안 끝난 선행 업무 수 — 목록·칸반 카드의 "선행 N" 표시.
  final int openPredecessorCount;

  /// 선행 업무(이 업무가 기다리는 것)·후행 업무(이 업무를 기다리는 것), 시간 기록 — 상세에서만 채워진다.
  final List<TaskLink> predecessors;
  final List<TaskLink> successors;
  final List<TaskTimeEntry> timeEntries;

  /// 고치기(PATCH) 응답에만 — 이번에 완료해서 만든 반복 업무 다음 회차의 번호(안내 토스트).
  final String? nextRecurrenceKey;

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
    this.assigneeName,
    this.assigneeAvatarType = 'initial',
    this.assigneeAvatarEmoji,
    this.assigneeAvatarColor,
    this.assigneeAvatarUrl,
    this.startDate,
    this.dueDate,
    required this.createdAt,
    this.comments = const [],
    this.activities = const [],
    this.parentTaskId,
    this.archived = false,
    this.checklistDone = 0,
    this.checklistTotal = 0,
    this.subtaskCount = 0,
    this.commentCount = 0,
    this.boardPosition,
    this.checklist = const [],
    this.subtasks = const [],
    this.recurring = false,
    this.recurrence,
    this.estimateMinutes,
    this.spentMinutes = 0,
    this.openPredecessorCount = 0,
    this.predecessors = const [],
    this.successors = const [],
    this.timeEntries = const [],
    this.nextRecurrenceKey,
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
    assigneeName: json['assigneeName'] as String?,
    assigneeAvatarType: json['assigneeAvatarType'] as String? ?? 'initial',
    assigneeAvatarEmoji: json['assigneeAvatarEmoji'] as String?,
    assigneeAvatarColor: json['assigneeAvatarColor'] as String?,
    assigneeAvatarUrl: json['assigneeAvatarUrl'] as String?,
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
    activities:
        (json['activities'] as List?)
            ?.map((e) => TaskActivity.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
    parentTaskId: json['parentTaskId'] as String?,
    archived: json['archived'] as bool? ?? false,
    checklistDone: (json['checklistDone'] as num?)?.toInt() ?? 0,
    checklistTotal: (json['checklistTotal'] as num?)?.toInt() ?? 0,
    subtaskCount: (json['subtaskCount'] as num?)?.toInt() ?? 0,
    commentCount: (json['commentCount'] as num?)?.toInt() ?? 0,
    boardPosition: (json['boardPosition'] as num?)?.toInt(),
    checklist:
        (json['checklist'] as List?)
            ?.map((e) => TaskChecklistItem.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
    subtasks:
        (json['subtasks'] as List?)
            ?.map((e) => Task.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
    recurring: json['recurring'] as bool? ?? false,
    recurrence: TaskRecurrence.fromJson(json['recurrence']),
    estimateMinutes: (json['estimateMinutes'] as num?)?.toInt(),
    spentMinutes: (json['spentMinutes'] as num?)?.toInt() ?? 0,
    openPredecessorCount: (json['openPredecessorCount'] as num?)?.toInt() ?? 0,
    predecessors: TaskLink.listFromJson(json['predecessors']),
    successors: TaskLink.listFromJson(json['successors']),
    timeEntries: TaskTimeEntry.listFromJson(json['timeEntries']),
    nextRecurrenceKey: (json['nextRecurrence'] as Map?)?['key'] as String?,
  );
}

/// 업무 하나에 딸린 체크리스트 항목. 진행률은 그 업무 상세에만 보여주고 전체·대시보드
/// 집계에는 넣지 않는다(그 업무를 하는 사람의 메모에 가깝다).
class TaskChecklistItem {
  final String id;
  final String taskId;
  final String text;
  final bool done;
  final int position;

  const TaskChecklistItem({
    required this.id,
    required this.taskId,
    required this.text,
    required this.done,
    this.position = 0,
  });

  factory TaskChecklistItem.fromJson(Map<String, dynamic> json) =>
      TaskChecklistItem(
        id: json['id'] as String,
        taskId: json['taskId'] as String,
        text: json['text'] as String,
        done: json['done'] as bool? ?? false,
        position: (json['position'] as num?)?.toInt() ?? 0,
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

  /// [text]에 걸린 글자 서식(굵게 등).
  final List<TextFormatRun>? textFormat;

  /// 답글이면 그 댓글의 id(한 단계까지만).
  final String? parentCommentId;
  final DateTime createdAt;

  /// 수정한 시각 — 있으면 "(수정됨)"을 붙인다.
  final DateTime? editedAt;
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
    this.textFormat,
    this.parentCommentId,
    required this.createdAt,
    this.editedAt,
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
    textFormat: parseTextFormat(json['textFormat']),
    parentCommentId: json['parentCommentId'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
    editedAt: json['editedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (json['editedAt'] as num).toInt(),
          ),
    taskTitle: json['taskTitle'] as String?,
    taskKey: json['taskKey'] as String?,
    projectName: json['projectName'] as String?,
  );
}

/// 업무 기록 한 줄 — 누가 언제 무엇을 했는지(서버가 문장으로 만들어 둔다).
class TaskActivity {
  final String id;
  final String? actorId;
  final String actorName;
  final String text;

  /// 'created' | 'status' | 'title' | 'description' | null(그 밖의 항목).
  final String? kind;

  /// 바뀐 뒤의 값 — 제목·설명은 새 글, 상태·생성은 상태 이름.
  final String? detail;

  /// 바뀌기 전 값 — 제목은 이전 제목, 상태는 이전 상태 이름.
  final String? previous;

  /// 상태·생성 기록의 상태 색(#RRGGBB).
  final String? color;
  final DateTime createdAt;

  const TaskActivity({
    required this.id,
    this.actorId,
    required this.actorName,
    required this.text,
    this.kind,
    this.detail,
    this.previous,
    this.color,
    required this.createdAt,
  });

  /// 상태 구간을 여는 기록인지(기록 탭의 머리줄).
  bool get startsStatus => kind == 'created' || kind == 'status';

  factory TaskActivity.fromJson(Map<String, dynamic> json) => TaskActivity(
    id: json['id'] as String,
    actorId: json['actorId'] as String?,
    actorName: json['actorName'] as String,
    text: json['text'] as String,
    kind: json['kind'] as String?,
    detail: json['detail'] as String?,
    previous: json['previous'] as String?,
    color: json['color'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
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

  /// "MKT-N10" — 프로젝트 키 + N + 노트 번호.
  final String? key;
  final String projectId;
  final String? projectName;
  final String? projectColor;
  final String title;
  final String? preview;
  final String? body;
  final String? createdBy;
  final String? createdByName;
  final String createdByAvatarType;
  final String? createdByAvatarEmoji;
  final String? createdByAvatarColor;
  final String? createdByAvatarUrl;
  final String? updatedByName;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 내가 이 노트를 고치거나 지울 수 있는지 — 프로젝트의 노트 권한 설정에 따라 서버가
  /// 사람마다 계산해서 내려준다(예전 서버처럼 값이 없으면 되는 것으로 본다).
  final bool canEdit;
  final bool canDelete;

  const ProjectNote({
    required this.id,
    this.key,
    required this.projectId,
    this.projectName,
    this.projectColor,
    required this.title,
    this.preview,
    this.body,
    this.createdBy,
    this.createdByName,
    this.createdByAvatarType = 'initial',
    this.createdByAvatarEmoji,
    this.createdByAvatarColor,
    this.createdByAvatarUrl,
    this.updatedByName,
    required this.createdAt,
    required this.updatedAt,
    this.canEdit = true,
    this.canDelete = true,
  });

  factory ProjectNote.fromJson(Map<String, dynamic> json) => ProjectNote(
    id: json['id'] as String,
    key: json['key'] as String?,
    projectId: json['projectId'] as String,
    projectName: json['projectName'] as String?,
    projectColor: json['projectColor'] as String?,
    title: json['title'] as String,
    preview: json['preview'] as String?,
    body: json['body'] as String?,
    createdBy: json['createdBy'] as String?,
    createdByName: json['createdByName'] as String?,
    createdByAvatarType: json['createdByAvatarType'] as String? ?? 'initial',
    createdByAvatarEmoji: json['createdByAvatarEmoji'] as String?,
    createdByAvatarColor: json['createdByAvatarColor'] as String?,
    createdByAvatarUrl: json['createdByAvatarUrl'] as String?,
    updatedByName: json['updatedByName'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      (json['updatedAt'] as num).toInt(),
    ),
    canEdit: json['canEdit'] as bool? ?? true,
    canDelete: json['canDelete'] as bool? ?? true,
  );
}

/// 사이드바의 개인 프로젝트 폴더 — 사람마다 자기 목록을 따로 정리한다(팀별).
/// 한 프로젝트는 내 폴더 중 한 곳에만 들어간다.
class ProjectFolder {
  final String id;
  final String name;
  final int position;

  /// 접어 둔 폴더 — 그 자리에서 토글하고 서버에 저장한다(즐겨찾기처럼 non-final).
  bool collapsed;

  final List<String> projectIds;

  ProjectFolder({
    required this.id,
    required this.name,
    this.position = 0,
    this.collapsed = false,
    this.projectIds = const [],
  });

  factory ProjectFolder.fromJson(Map<String, dynamic> json) => ProjectFolder(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    position: (json['position'] as num?)?.toInt() ?? 0,
    collapsed: json['collapsed'] as bool? ?? false,
    projectIds:
        (json['projectIds'] as List?)?.map((e) => e as String).toList() ??
        const [],
  );
}

/// 프로젝트 알림함의 한 줄 — [kind]: assigned | referenced | comment | status | due |
/// created | deleted | project_created(공개 프로젝트 생성 — [taskId] 없음). 모르는 종류도 그냥 보여준다.
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
        // 서버에 새 종류가 생겨도 목록이 깨지지 않게 빈 값은 빈 글자로 받는다.
        kind: json['kind'] as String? ?? '',
        title: json['title'] as String? ?? '',
        body: json['body'] as String? ?? '',
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

// ── 자동화 v2: 노드 그래프 ─────────────────────────────────────────────
// 규칙 = 트리거 노드 하나 → (IF 조건 노드들, 예/아니오 갈래) → 액션 노드들. 편집기 캔버스에서
// 노드를 놓고 포트끼리 잇는다. 서버가 그래프를 따라 실행한다(설명: 서버 projectAutomation.js).

/// 트리거 종류(언제 실행할지).
final automationTriggerLabels = {
  'field_changed': tr('필드 변경'),
  'task_created': tr('업무 생성'),
  'task_deleted': tr('업무 삭제'),
  'task_archived': tr('업무 보관'),
  'comment_added': tr('댓글 추가'),
  'checklist_completed': tr('체크리스트 완료'),
};

/// 액션 종류(무엇을 할지).
final automationActionLabels = {
  'set_field': tr('필드 변경'),
  'create_task': tr('업무 생성'),
  'archive_task': tr('업무 보관'),
  'chat_message': tr('채팅방 알림'),
};

/// 트리거·조건·액션이 가리키는 업무 필드. 사용자 정의 필드는 `field:<id>`로 쓴다.
final automationFieldLabels = {
  'any': tr('모든 필드'),
  'status': tr('상태'),
  'priority': tr('우선순위'),
  'assignee': tr('담당자'),
  'type': tr('유형'),
  'startDate': tr('시작일'),
  'dueDate': tr('마감일'),
  'title': tr('제목'),
};

/// IF 조건의 비교 방법.
final automationOpLabels = {
  'eq': tr('같음'),
  'neq': tr('같지 않음'),
  'empty': tr('비어 있음'),
  'not_empty': tr('비어 있지 않음'),
};

/// 필드 변경 트리거가 감지할 필드들. 지금은 `{fields: [...]}`로 저장하지만, 예전에 저장한 규칙은
/// `{field: X}` 한 개짜리로 올 수 있어서 둘 다 읽는다. 아무것도 없으면 모든 필드(['any']).
List<String> automationTriggerFields(Map<String, dynamic> config) {
  final fields = config['fields'];
  if (fields is List) {
    return [
      for (final f in fields)
        if (f is String) f,
    ];
  }
  final field = config['field'];
  return field is String ? [field] : ['any'];
}

/// 그래프의 노드 한 개 — [kind]: 'trigger' | 'condition' | 'action'. 편집기가 그대로 고친다.
class AutomationNode {
  final String id;
  final String kind;
  final String type;
  Map<String, dynamic> config;
  double x;
  double y;

  AutomationNode({
    required this.id,
    required this.kind,
    required this.type,
    Map<String, dynamic>? config,
    this.x = 0,
    this.y = 0,
  }) : config = config ?? {};

  factory AutomationNode.fromJson(Map<String, dynamic> json) => AutomationNode(
    id: json['id'] as String,
    kind: json['kind'] as String,
    type: json['type'] as String,
    config: Map<String, dynamic>.from((json['config'] as Map?) ?? const {}),
    x: (json['x'] as num?)?.toDouble() ?? 0,
    y: (json['y'] as num?)?.toDouble() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'type': type,
    'config': config,
    'x': x.roundToDouble(),
    'y': y.roundToDouble(),
  };

  AutomationNode copy() => AutomationNode(
    id: id,
    kind: kind,
    type: type,
    config: Map<String, dynamic>.from(config),
    x: x,
    y: y,
  );
}

/// 노드 사이 연결 — [from]의 [port]('out' | 'yes' | 'no')에서 [to]로.
class AutomationEdge {
  final String from;
  final String port;
  final String to;
  const AutomationEdge({
    required this.from,
    required this.port,
    required this.to,
  });

  factory AutomationEdge.fromJson(Map<String, dynamic> json) => AutomationEdge(
    from: json['from'] as String,
    port: json['port'] as String? ?? 'out',
    to: json['to'] as String,
  );

  Map<String, dynamic> toJson() => {'from': from, 'port': port, 'to': to};

  @override
  bool operator ==(Object other) =>
      other is AutomationEdge &&
      other.from == from &&
      other.port == port &&
      other.to == to;

  @override
  int get hashCode => Object.hash(from, port, to);
}

/// 자동화 규칙의 흐름 — 노드와 연결.
class AutomationGraph {
  final List<AutomationNode> nodes;
  final List<AutomationEdge> edges;
  AutomationGraph({List<AutomationNode>? nodes, List<AutomationEdge>? edges})
    : nodes = nodes ?? [],
      edges = edges ?? [];

  factory AutomationGraph.fromJson(Map<String, dynamic> json) =>
      AutomationGraph(
        nodes: [
          for (final n in (json['nodes'] as List?) ?? const [])
            AutomationNode.fromJson(n as Map<String, dynamic>),
        ],
        edges: [
          for (final e in (json['edges'] as List?) ?? const [])
            AutomationEdge.fromJson(e as Map<String, dynamic>),
        ],
      );

  Map<String, dynamic> toJson() => {
    'nodes': [for (final n in nodes) n.toJson()],
    'edges': [for (final e in edges) e.toJson()],
  };

  AutomationGraph copy() => AutomationGraph(
    nodes: [for (final n in nodes) n.copy()],
    edges: [...edges],
  );

  AutomationNode? get trigger =>
      nodes.where((n) => n.kind == 'trigger').firstOrNull;
}

/// 자동화 규칙. [graph]가 있으면 노드 편집기로 만든 규칙이고, null이면 예전 방식 규칙이다
/// ([trigger]('task_created' | 'status_changed') 때 [condition]이 맞으면 [actions] 실행 — 켜기·끄기·
/// 삭제만 할 수 있다).
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
  final AutomationGraph? graph;

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
    this.graph,
  });

  /// 노드 편집기 이전에 만든 규칙.
  bool get isLegacy => graph == null;

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
      graph: json['graph'] is Map
          ? AutomationGraph.fromJson(
              (json['graph'] as Map).cast<String, dynamic>(),
            )
          : null,
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

  /// [text]에 걸린 글자 서식.
  final List<TextFormatRun>? textFormat;

  /// 답글이면 그 댓글(한 단계까지만).
  final String? parentCommentId;
  final DateTime createdAt;
  final DateTime? editedAt;

  const NoteComment({
    required this.id,
    required this.noteId,
    this.senderId,
    required this.senderName,
    required this.text,
    this.textFormat,
    this.parentCommentId,
    required this.createdAt,
    this.editedAt,
  });

  factory NoteComment.fromJson(Map<String, dynamic> json) => NoteComment(
    id: json['id'] as String,
    noteId: json['noteId'] as String,
    senderId: json['senderId'] as String?,
    senderName: json['senderName'] as String? ?? tr('알 수 없음'),
    text: json['text'] as String,
    textFormat: parseTextFormat(json['textFormat']),
    parentCommentId: json['parentCommentId'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
    editedAt: json['editedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (json['editedAt'] as num).toInt(),
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

// ── 프로젝트 템플릿 ─────────────────────────────────────────────────────

/// 사용자 정의 필드 종류의 화면 이름.
final fieldKindLabels = {
  'text': tr('텍스트'),
  'number': tr('숫자'),
  'date': tr('날짜'),
  'select': tr('단일 선택'),
  'multiSelect': tr('다중 선택'),
  'progress': tr('진행률'),
};

/// 템플릿의 상태 한 개 — [category]가 done이면 "완료"로 집계된다.
class TemplateStatus {
  final String name;
  final String color;
  final TaskStatus category;
  const TemplateStatus({
    required this.name,
    required this.color,
    required this.category,
  });

  factory TemplateStatus.fromJson(Map<String, dynamic> json) => TemplateStatus(
    name: json['name'] as String? ?? '',
    color: json['color'] as String? ?? '#94A3B8',
    category: taskStatusFromWire(json['category'] as String?),
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'color': color,
    'category': taskStatusToWire(category),
  };
}

/// 템플릿의 작업 유형 한 개.
class TemplateType {
  final String name;
  final String color;
  const TemplateType({required this.name, required this.color});

  factory TemplateType.fromJson(Map<String, dynamic> json) => TemplateType(
    name: json['name'] as String? ?? '',
    color: json['color'] as String? ?? '#94A3B8',
  );

  Map<String, dynamic> toJson() => {'name': name, 'color': color};
}

/// 템플릿의 우선순위 한 개 — [level]은 정렬·통계용 큰 묶음(높음/보통/낮음).
class TemplatePriority {
  final String name;
  final String color;
  final TaskPriority level;
  const TemplatePriority({
    required this.name,
    required this.color,
    required this.level,
  });

  factory TemplatePriority.fromJson(Map<String, dynamic> json) =>
      TemplatePriority(
        name: json['name'] as String? ?? '',
        color: json['color'] as String? ?? '#94A3B8',
        level: taskPriorityFromWire(json['level'] as String?),
      );

  Map<String, dynamic> toJson() => {
    'name': name,
    'color': color,
    'level': taskPriorityToWire(level),
  };
}

/// 템플릿의 사용자 정의 필드 한 개 — 선택 필드면 [options]가 선택지.
class TemplateField {
  final String name;
  final String kind;
  final List<String> options;
  const TemplateField({
    required this.name,
    required this.kind,
    this.options = const [],
  });

  bool get hasOptions => kind == 'select' || kind == 'multiSelect';

  factory TemplateField.fromJson(Map<String, dynamic> json) => TemplateField(
    name: json['name'] as String? ?? '',
    kind: json['kind'] as String? ?? 'text',
    options:
        (json['options'] as List?)?.map((e) => e as String).toList() ??
        const [],
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'kind': kind,
    'options': options,
  };
}

/// 프로젝트 템플릿(팀 공유) — 상태·유형·우선순위·사용자 정의 필드 구성. 새 프로젝트를 만들 때
/// 기본값 대신 이 구성으로 채운다(만든 뒤에는 템플릿과 따로 논다).
class ProjectTemplate {
  /// 아직 저장하지 않은 새 템플릿이면 null.
  final String? id;
  final String name;
  final String? description;
  final List<TemplateStatus> statuses;
  final List<TemplateType> types;
  final List<TemplatePriority> priorities;
  final List<TemplateField> fields;
  final String? creatorName;

  /// 내가 고치거나 지울 수 있는지(만든 사람·팀 소유자).
  final bool canEdit;

  /// 프로젝트를 템플릿으로 저장하는 초안이면 그 프로젝트 id — 새로 저장할 때 같이 보내면 서버가
  /// 그 프로젝트를 새 템플릿에 연결한다(Project.templateId). 서버가 내려주는 값은 아니다.
  final String? sourceProjectId;

  const ProjectTemplate({
    this.id,
    required this.name,
    this.description,
    this.statuses = const [],
    this.types = const [],
    this.priorities = const [],
    this.fields = const [],
    this.creatorName,
    this.canEdit = true,
    this.sourceProjectId,
  });

  /// "새 템플릿 만들기"의 처음 모습 — 새 프로젝트의 기본 구성과 같게.
  factory ProjectTemplate.blank() => ProjectTemplate(
    name: '',
    statuses: [
      TemplateStatus(
        name: tr('할 일'),
        color: '#5B8DEF',
        category: TaskStatus.todo,
      ),
      TemplateStatus(
        name: tr('진행 중'),
        color: '#F59E0B',
        category: TaskStatus.doing,
      ),
      TemplateStatus(
        name: tr('완료'),
        color: '#10B981',
        category: TaskStatus.done,
      ),
    ],
    types: [
      TemplateType(name: tr('기능'), color: '#5B8DEF'),
      TemplateType(name: tr('버그'), color: '#EF4444'),
      TemplateType(name: tr('개선'), color: '#10B981'),
    ],
    priorities: [
      TemplatePriority(
        name: tr('긴급'),
        color: '#EF4444',
        level: TaskPriority.high,
      ),
      TemplatePriority(
        name: tr('높음'),
        color: '#F59E0B',
        level: TaskPriority.high,
      ),
      TemplatePriority(
        name: tr('보통'),
        color: '#5B8DEF',
        level: TaskPriority.normal,
      ),
      TemplatePriority(
        name: tr('낮음'),
        color: '#10B981',
        level: TaskPriority.low,
      ),
    ],
  );

  factory ProjectTemplate.fromJson(Map<String, dynamic> json) {
    List<T> list<T>(String key, T Function(Map<String, dynamic>) f) =>
        ((json[key] as List?) ?? const [])
            .map((e) => f(e as Map<String, dynamic>))
            .toList();
    return ProjectTemplate(
      id: json['id'] as String?,
      name: json['name'] as String? ?? '',
      description: json['description'] as String?,
      statuses: list('statuses', TemplateStatus.fromJson),
      types: list('types', TemplateType.fromJson),
      priorities: list('priorities', TemplatePriority.fromJson),
      fields: list('fields', TemplateField.fromJson),
      creatorName: json['creatorName'] as String?,
      canEdit: json['canEdit'] as bool? ?? false,
    );
  }

  /// 저장할 때 보내는 본문(id·만든 사람은 서버가 정한다).
  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'statuses': [for (final s in statuses) s.toJson()],
    'types': [for (final t in types) t.toJson()],
    'priorities': [for (final p in priorities) p.toJson()],
    'fields': [for (final f in fields) f.toJson()],
  };
}
