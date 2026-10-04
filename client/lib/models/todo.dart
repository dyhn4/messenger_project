import 'package:flutter/widgets.dart' show StringCharacters;

import 'app_user.dart';
import 'message.dart' show MessageAttachment;

/// 할 일 입력 한도 — 서버 todos 라우트(server/src/todoRules.js)가 같은 값으로 다시 검사한다.
const todoTitleMaxLength = 100;
const todoDescriptionMaxLength = 2000;
const todoAssigneesMaxCount = 30;
const todoAttachmentsMaxCount = 30;
const todoRemindersMaxCount = 5;

/// 기한 기준 알림("기한 하루 전"·"기한 1시간 전")에서 기한일을 몇 시로 칠지 — 기한은 날짜만 있어서, 업무 시간이 끝나는
/// 오후 6시를 기한 시각으로 본다(전날 오후 6시 / 기한일 오후 5시에 울린다).
const todoDueHour = 18;

/// 진척률로 고를 수 있는 값 — 대기 0, 진행 25·50·75, 완료 100(서버가 이 값만 받는다).
const todoProgressSteps = [0, 25, 50, 75, 100];

/// `GET /api/todos` 한 번에 받는 최대 개수 — 기간(from/to)으로 받을 때(달력)는 [todoRangeMaxLimit]까지, 기간은
/// [todoRangeMaxDays]일까지. 서버가 같은 값으로 다시 검사한다.
const todoListMaxLimit = 100;
const todoRangeMaxLimit = 500;
const todoRangeMaxDays = 100;

/// 진척률로 가르는 상태 — 0 대기, 1~99 진행, 100 완료(서버 statusOf와 같다).
enum TodoStatus {
  todo('대기'),
  doing('진행'),
  done('완료');

  final String label;
  const TodoStatus(this.label);

  static TodoStatus of(int progress) => progress >= 100
      ? TodoStatus.done
      : progress > 0
      ? TodoStatus.doing
      : TodoStatus.todo;
}

/// 진척률 상태 문구 — 대기 / 진행 N% / 완료(0 / 1~99 / 100). 화면의 진척률 표시는 % 문구([todoPercentText])와 고르는
/// 메뉴 문구([todoProgressMenuLabel])를 쓴다.
String todoProgressText(int progress) => switch (TodoStatus.of(progress)) {
  TodoStatus.todo => '대기',
  TodoStatus.doing => '진행 $progress%',
  TodoStatus.done => '완료',
};

/// 진척률을 고르는 메뉴와 상세 담당자 줄의 문구(잔디 문구) — 대기(0%) / 진행(25%)·진행(50%)·진행(75%) / 완료(100%).
/// 단계 밖의 값(집계 등)은 `진행(N%)`.
String todoProgressMenuLabel(int progress) => switch (TodoStatus.of(progress)) {
  TodoStatus.todo => '대기(0%)',
  TodoStatus.doing => '진행($progress%)',
  TodoStatus.done => '완료(100%)',
};

/// 진척률 % 문구 — `75%`. 목록 카드의 `진행률 : 75%`, 상세의 `진행률 75%`에서 색을 입히는 숫자 부분이다(잔디는 담당자가
/// 여럿이어도 전체 상태를 집계 %로 보인다).
String todoPercentText(int progress) => '$progress%';

/// 목록 보기 — `GET /api/todos?scope=`. 나의 할 일은 내가 담당인 것과 내가 만든 담당자 없는 것, 부여한 할 일은 내가 만들어
/// 다른 사람에게 맡긴 것, 모든 할 일은 내가 참여한 대화방의 전부다(와이어 값은 예전 그대로). 선언 순서가 보기 드롭다운의
/// 항목 순서([menuOrder])이고, 처음 보기(나의 할 일)는 컨트롤러가 정한다.
enum TodoScope {
  team('team', '모든 할 일'),
  mine('mine', '나의 할 일'),
  assignedByMe('assigned_by_me', '부여한 할 일');

  final String wire;
  final String label;
  const TodoScope(this.wire, this.label);

  /// 보기 드롭다운 항목 순서 — 모든 할 일 / 나의 할 일 / 부여한 할 일(잔디와 같다).
  static const menuOrder = [team, mine, assignedByMe];
}

/// 목록 정렬(잔디 문구) — 생성 순(최근에 만든 것 먼저)과 기한 순(미완료 먼저, 기한 임박순, 기한 없음은 뒤). 선언 순서가
/// 정렬 메뉴의 항목 순서([menuOrder])이고, 목록의 처음 정렬은 생성 순이다(컨트롤러 기본값 — sort를 빼고 부르면 서버와
/// `TodoApi.list`는 기한 순).
enum TodoSort {
  created('created', '생성 순'),
  due('due', '기한 순');

  final String wire;
  final String label;
  const TodoSort(this.wire, this.label);

  /// 정렬 메뉴 항목 순서 — 생성 순 / 기한 순.
  static const menuOrder = [created, due];
}

/// 'YYYY-MM-DD' → 날짜(시간 없음). 못 읽으면 null.
DateTime? parseTodoDate(String? ymd) {
  if (ymd == null) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(ymd);
  if (m == null) return null;
  return DateTime(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
  );
}

/// 날짜 → 서버에 보내는 'YYYY-MM-DD'.
String todoDateWire(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 화면 표기 `yyyy/MM/dd`.
String formatTodoDate(DateTime d) =>
    '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

/// 알림 시각 표기 `yyyy/MM/dd 오전|오후 h:mm`.
String formatTodoDateTime(DateTime t) {
  final hour12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final ampm = t.hour < 12 ? '오전' : '오후';
  return '${formatTodoDate(t)} $ampm $hour12:${t.minute.toString().padLeft(2, '0')}';
}

/// 할 일 일정(달력)이 [month]에 그리는 칸의 범위 — 그 달 1일이 있는 주의 일요일부터 6주(42일). 끝 날도 범위에 든다
/// (`GET /api/todos`의 from/to로 그대로 보낸다).
(DateTime from, DateTime to) todoCalendarRange(DateTime month) {
  final first = DateTime(month.year, month.month);
  // Dart weekday: 월=1..일=7 → 일요일 시작 기준으로 앞 칸 수.
  final from = DateTime(first.year, first.month, 1 - first.weekday % 7);
  return (from, DateTime(from.year, from.month, from.day + 41));
}

/// [t]의 기간(시작일 ?? 종료일 ~ 종료일 ?? 시작일)에 [day]가 드는가 — 달력 칸의 개수·고른 날의 목록. 날짜가 둘 다
/// 없으면 false.
bool todoCoversDate(Todo t, DateTime day) {
  final start = t.start ?? t.due;
  final end = t.due ?? t.start;
  if (start == null || end == null) return false;
  final d = DateTime(day.year, day.month, day.day);
  return !d.isBefore(start) && !d.isAfter(end);
}

/// 할 일의 첨부 한 개 — 메시지 첨부와 같은 모양이라 [MessageAttachment]로도 바꿔 쓴다(열기·미리보기).
class TodoAttachment {
  final String id;

  /// 'image' | 'file'
  final String kind;
  final String fileUrl;
  final String? fileName;
  final int? fileSize;
  final String? mimeType;
  final String? thumbnailUrl;

  const TodoAttachment({
    required this.id,
    required this.kind,
    required this.fileUrl,
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.thumbnailUrl,
  });

  bool get isImage => kind == 'image';

  factory TodoAttachment.fromJson(Map<String, dynamic> json) => TodoAttachment(
    id: json['id'] as String? ?? '',
    kind: json['kind'] as String? ?? 'file',
    fileUrl: json['fileUrl'] as String? ?? '',
    fileName: json['fileName'] as String?,
    fileSize: (json['fileSize'] as num?)?.toInt(),
    mimeType: json['mimeType'] as String?,
    thumbnailUrl: json['thumbnailUrl'] as String?,
  );

  MessageAttachment toMessageAttachment() => MessageAttachment(
    id: id,
    kind: kind,
    fileUrl: fileUrl,
    fileName: fileName,
    fileSize: fileSize,
    mimeType: mimeType,
    thumbnailUrl: thumbnailUrl,
  );
}

/// 알림 일정 한 건. [sent]는 이미 울린 알림.
class TodoReminder {
  final String id;
  final DateTime remindAt;
  final bool sent;
  const TodoReminder({
    required this.id,
    required this.remindAt,
    this.sent = false,
  });

  factory TodoReminder.fromJson(Map<String, dynamic> json) => TodoReminder(
    id: json['id'] as String? ?? '',
    remindAt: DateTime.fromMillisecondsSinceEpoch(
      (json['remindAt'] as num).toInt(),
    ),
    sent: json['sent'] as bool? ?? false,
  );

  /// PATCH 본문의 한 칸 — 기존 알림은 id를 같이 보내야 "그대로"로 알아본다.
  Map<String, dynamic> toPayload() => {
    if (id.isNotEmpty) 'id': id,
    'remindAt': remindAt.millisecondsSinceEpoch,
  };
}

/// 서버 할 일 DTO 한 건(목록·상세 공용).
class Todo {
  final String id;
  final String teamId;
  final String roomId;
  final String? roomName;
  final String title;
  final String? description;

  /// 'YYYY-MM-DD'(날짜만). 없으면 null.
  final String? startDate;
  final String? dueDate;

  /// 전체(집계) 진척률 — 담당자가 있으면 서버가 담당자들의 진척률로 다시 계산한 값(모두 100 → 100, 모두 0 → 0,
  /// 그 밖은 평균을 1~99로), 없으면 만든 사람이 정한 값.
  final int progress;
  final DateTime? completedAt;
  final AppUser? creator;
  final List<AppUser> assignees;

  /// 담당자 id → 그 사람의 진척률(담당자마다 따로 진행한다). 예전 서버 응답이면 비어 있다.
  final Map<String, int> assigneeProgress;

  /// 내 진척률 — 내가 담당자면 내 것, 담당자가 없고 내가 만들었으면 할 일의 것, 아니면 null.
  final int? myProgress;

  /// 내가 진척률을 바꿀 수 있는지(`myProgress != null`) — `update(id, {'progress': p})`는 "내 진척률"을 바꾼다.
  final bool canSetProgress;

  /// 내가 즐겨찾기했는지(사람마다 따로).
  final bool favorite;
  final List<TodoAttachment> attachments;
  final List<TodoReminder> reminders;
  final String? sourceMessageId;
  final String? sourceCommentId;

  /// 'creator' | 'assignee' | 'viewer' — 보는 사람 기준.
  final String myRole;

  /// 제목·설명·파일·기한·알림을 고칠 수 있는지(만든 사람·담당자).
  final bool canEdit;

  /// 담당자 관리와 삭제까지 할 수 있는지(만든 사람).
  final bool canManage;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Todo({
    required this.id,
    required this.teamId,
    required this.roomId,
    this.roomName,
    required this.title,
    this.description,
    this.startDate,
    this.dueDate,
    this.progress = 0,
    this.completedAt,
    this.creator,
    this.assignees = const [],
    this.assigneeProgress = const {},
    this.myProgress,
    this.canSetProgress = false,
    this.favorite = false,
    this.attachments = const [],
    this.reminders = const [],
    this.sourceMessageId,
    this.sourceCommentId,
    this.myRole = 'viewer',
    this.canEdit = false,
    this.canManage = false,
    required this.createdAt,
    required this.updatedAt,
  });

  TodoStatus get status => TodoStatus.of(progress);
  bool get isDone => progress >= 100;

  DateTime? get start => parseTodoDate(startDate);
  DateTime? get due => parseTodoDate(dueDate);

  /// 기한이 오늘보다 앞서고 아직 끝나지 않았는가 — 목록·상세에서 기한을 빨갛게 보여 준다.
  bool isOverdue([DateTime? now]) => isOverdueFor(progress, now);

  /// [isOverdue]를 다른 진척률 기준으로 — 목록이 보는 관점(내 것·고른 담당자의 것)으로 "아직 안 끝남"을 따질 때.
  bool isOverdueFor(int progress, [DateTime? now]) {
    final d = due;
    if (d == null || progress >= 100) return false;
    final base = now ?? DateTime.now();
    return d.isBefore(DateTime(base.year, base.month, base.day));
  }

  /// 담당자 [userId]의 진척률(담당자가 아니거나 모르면 0).
  int progressOf(String userId) => assigneeProgress[userId] ?? 0;

  /// 진척률 100인 담당자 수.
  int get doneCount => assignees.where((a) => progressOf(a.id) >= 100).length;

  /// 전체 상태 문구 — 전체(집계) 진척률 %(`75%`). 담당자가 여럿이어도 완료한 사람 수(`진행 1/3`) 대신 집계 %다(잔디).
  String get summaryText => todoPercentText(progress);

  /// 몇 칸만 바꾼 사본 — 서버 응답 전에 즐겨찾기·진척률을 먼저 그려 둘 때(낙관적 갱신).
  Todo copyWith({
    bool? favorite,
    int? myProgress,
    int? progress,
    Map<String, int>? assigneeProgress,
  }) => Todo(
    id: id,
    teamId: teamId,
    roomId: roomId,
    roomName: roomName,
    title: title,
    description: description,
    startDate: startDate,
    dueDate: dueDate,
    progress: progress ?? this.progress,
    completedAt: completedAt,
    creator: creator,
    assignees: assignees,
    assigneeProgress: assigneeProgress ?? this.assigneeProgress,
    myProgress: myProgress ?? this.myProgress,
    canSetProgress: canSetProgress,
    favorite: favorite ?? this.favorite,
    attachments: attachments,
    reminders: reminders,
    sourceMessageId: sourceMessageId,
    sourceCommentId: sourceCommentId,
    myRole: myRole,
    canEdit: canEdit,
    canManage: canManage,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  /// 카드 한 칸의 기한 문구 — `~ 2026/10/05`(시작일이 있으면 `2026/10/01 ~ 2026/10/05`).
  String? get periodText {
    final s = start;
    final d = due;
    if (s == null && d == null) return null;
    if (s != null && d != null) {
      return '${formatTodoDate(s)} ~ ${formatTodoDate(d)}';
    }
    if (d != null) return '~ ${formatTodoDate(d)}';
    return '${formatTodoDate(s!)} ~';
  }

  /// 전체 진척률의 상태 문구 — 대기 / 진행 40% / 완료([todoProgressText]).
  String get statusText => todoProgressText(progress);

  bool isAssignee(String userId) => assignees.any((a) => a.id == userId);

  factory Todo.fromJson(Map<String, dynamic> json) {
    AppUser? user(Object? raw) {
      if (raw is! Map) return null;
      final m = Map<String, dynamic>.from(raw);
      final name = m['name'] as String? ?? '';
      return AppUser(
        id: m['id'] as String,
        username: name,
        name: name,
        avatarType: m['avatarType'] as String? ?? 'initial',
        avatarEmoji: m['avatarEmoji'] as String?,
        avatarColor: m['avatarColor'] as String?,
        avatarUrl: m['avatarUrl'] as String?,
      );
    }

    DateTime? time(Object? ms) =>
        ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.toInt()) : null;

    final rawAssignees = (json['assignees'] as List?) ?? const [];
    return Todo(
      id: json['id'] as String,
      teamId: json['teamId'] as String? ?? '',
      roomId: json['roomId'] as String? ?? '',
      roomName: json['roomName'] as String?,
      title: json['title'] as String? ?? '',
      description: json['description'] as String?,
      startDate: json['startDate'] as String?,
      dueDate: json['dueDate'] as String?,
      progress: (json['progress'] as num?)?.toInt() ?? 0,
      completedAt: time(json['completedAt']),
      creator: user(json['creator']),
      assignees: [for (final a in rawAssignees) ?user(a)],
      // 담당자별 진척률 — 예전 서버 응답(progress 없음)이면 비워 둔다.
      assigneeProgress: {
        for (final a in rawAssignees)
          if (a is Map && a['id'] is String && a['progress'] is num)
            a['id'] as String: (a['progress'] as num).toInt(),
      },
      myProgress: (json['myProgress'] as num?)?.toInt(),
      canSetProgress: json['canSetProgress'] as bool? ?? false,
      favorite: json['favorite'] as bool? ?? false,
      attachments: [
        for (final a in (json['attachments'] as List?) ?? const [])
          TodoAttachment.fromJson(Map<String, dynamic>.from(a as Map)),
      ],
      reminders: [
        for (final r in (json['reminders'] as List?) ?? const [])
          TodoReminder.fromJson(Map<String, dynamic>.from(r as Map)),
      ],
      sourceMessageId: json['sourceMessageId'] as String?,
      sourceCommentId: json['sourceCommentId'] as String?,
      myRole: json['myRole'] as String? ?? 'viewer',
      canEdit: json['canEdit'] as bool? ?? false,
      canManage: json['canManage'] as bool? ?? false,
      createdAt: time(json['createdAt']) ?? DateTime.now(),
      updatedAt: time(json['updatedAt']) ?? DateTime.now(),
    );
  }
}

/// `GET /api/todos`의 한 쪽.
class TodoPage {
  final List<Todo> items;
  final bool hasMore;

  /// 같은 필터(scope·assigneeId·roomId·includeDone·from/to)에 맞는 전체 개수 — offset·limit과 상관없다(목록의 `N개의 할 일`).
  /// 예전 서버 응답(total 없음)이면 null — 그때 컨트롤러는 받은 개수를 센다.
  final int? total;
  const TodoPage({this.items = const [], this.hasMore = false, this.total});

  factory TodoPage.fromJson(Map<String, dynamic> json) => TodoPage(
    items: [
      for (final i in (json['items'] as List?) ?? const [])
        Todo.fromJson(Map<String, dynamic>.from(i as Map)),
    ],
    hasMore: json['hasMore'] as bool? ?? false,
    total: (json['total'] as num?)?.toInt(),
  );
}

/// 생성·수정 창의 입력 검사 결과 — 필드마다 문구가 있으면 그 칸 아래에 보인다.
class TodoDraftCheck {
  final String? titleError;
  final String? descriptionError;
  final String? periodError;
  final String? attachmentsError;
  final String? assigneesError;
  final String? remindersError;
  const TodoDraftCheck({
    this.titleError,
    this.descriptionError,
    this.periodError,
    this.attachmentsError,
    this.assigneesError,
    this.remindersError,
  });

  bool get ok =>
      titleError == null &&
      descriptionError == null &&
      periodError == null &&
      attachmentsError == null &&
      assigneesError == null &&
      remindersError == null;
}

/// 서버가 받아 줄 입력인지 미리 본다(서버도 같은 값으로 다시 검사한다). 제목은 공백만이면 비어 있는 것으로 본다.
TodoDraftCheck checkTodoDraft({
  required String title,
  String description = '',
  DateTime? start,
  DateTime? due,
  int attachmentCount = 0,
  int assigneeCount = 0,
  int reminderCount = 0,
}) {
  final t = title.trim();
  return TodoDraftCheck(
    titleError: t.isEmpty
        ? '제목을 입력하세요.'
        : t.characters.length > todoTitleMaxLength
        ? '제목은 $todoTitleMaxLength자 이내로 입력하세요.'
        : null,
    descriptionError:
        description.trim().characters.length > todoDescriptionMaxLength
        ? '설명은 $todoDescriptionMaxLength자 이내로 입력하세요.'
        : null,
    periodError: start != null && due != null && start.isAfter(due)
        ? '시작일은 종료일보다 늦을 수 없습니다.'
        : null,
    attachmentsError: attachmentCount > todoAttachmentsMaxCount
        ? '첨부 파일은 $todoAttachmentsMaxCount개까지 올릴 수 있습니다.'
        : null,
    assigneesError: assigneeCount > todoAssigneesMaxCount
        ? '담당자는 $todoAssigneesMaxCount명까지 지정할 수 있습니다.'
        : null,
    remindersError: reminderCount > todoRemindersMaxCount
        ? '알림은 $todoRemindersMaxCount개까지 추가할 수 있습니다.'
        : null,
  );
}

/// 메시지·댓글 본문으로 미리 채울 제목 — 첫 줄(앞뒤 공백 제외), 최대 [todoTitleMaxLength]자. 본문이 없으면 빈 문자열.
String todoTitleFromText(String? text) {
  final first = (text ?? '')
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .firstWhere((l) => l.isNotEmpty, orElse: () => '');
  final chars = first.characters;
  return chars.length > todoTitleMaxLength
      ? chars.take(todoTitleMaxLength).toString()
      : first;
}

/// 기한 기준 알림 시각 — [dueDate]의 [todoDueHour]시를 기한 시각으로 보고 [before]만큼 앞선 때.
DateTime todoReminderBeforeDue(DateTime dueDate, Duration before) => DateTime(
  dueDate.year,
  dueDate.month,
  dueDate.day,
  todoDueHour,
).subtract(before);
