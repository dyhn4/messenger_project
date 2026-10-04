import 'dart:math' as math;

import 'package:client/models/todo.dart';
import 'package:client/models/uploaded_attachment.dart';
import 'package:client/services/api_client.dart' show ApiException;
import 'package:client/services/todo_api.dart';

/// 서버 없이 할 일 컨트롤러·화면을 시험하는 가짜 API. 호출을 [calls]에 기록하고, 할 일은 서버 DTO 모양의 맵으로 메모리에
/// 들고 있으며, 진짜 서버(server/src/todos.js)와 같은 규칙을 지킨다:
/// - 목록: scope(나의 = 내가 담당 + 내가 만든 담당자 없는 것 / 부여한 = 내가 만들어 다른 사람에게 맡긴 것 / 모든 = 전부)·
///   assigneeId(그 사람이 담당인 것)·from/to(기간이 겹치는 것, 날짜 없는 것은 빠짐)·roomId·offset·limit, 완료 제외와 정렬은
///   "기준 진척률"(assigneeId가 있으면 그 사람 것, 나의 할 일이면 내 것, 그 밖은 전체), 즐겨찾기한 것이 먼저. sort를 빼면
///   기한 순(서버와 같다 — 컨트롤러는 늘 정해서 보낸다), `total`은 같은 필터에 맞는 전체 개수(offset·limit 무관).
/// - 진척률 수정은 "내 진척률" — 담당자는 자기 것, 담당자 없는 할 일은 만든 사람, 그 밖은 [ApiException]. 바뀌면 전체(집계)를
///   다시 계산한다. 담당자 목록 수정은 차이만 반영해 남는 사람의 진척률을 지킨다. 담당자를 모두 빼면 할 일의 진척률은
///   [orphanedTodoProgress](검토 S3)를 이어받고, 같이 보낸 `progress`가 있으면 그 값이 이긴다. 바꿀 칸이 없는 수정(`{}`)은
///   서버처럼 거절한다(`수정할 내용이 없습니다.`).
/// - 기간(시작일·시작 시간·종료일·종료 시간)은 서버처럼 검사한다([fakeTodoPeriodError] — 시간 형식, 날짜 없는 시간, 순서).
///   수정은 안 보낸 쪽을 저장된 값과 합쳐 보고, 날짜를 null로 지우면 그 시간도 지운다.
class FakeTodoApi implements TodoApi {
  FakeTodoApi({required this.me, List<Map<String, dynamic>>? todos})
    : todos = todos ?? [];

  /// 보는 사람(목록의 scope·즐겨찾기·내 진척률이 이 사람 기준).
  final String me;

  /// 서버에 있는 할 일 DTO들(`todoJson`이 만든 맵 — 보는 사람 기준 값은 [me]와 같은 사람으로 만들 것).
  final List<Map<String, dynamic>> todos;

  /// 호출 기록 — "메서드명 인자…" 문자열.
  final calls = <String>[];

  /// 마지막 create/update 요청의 세부.
  Map<String, dynamic>? lastCreate;
  Map<String, dynamic>? lastUpdate;
  String? lastCreateRoomId;
  List<UploadedAttachment> lastCreateAttachments = const [];

  /// 마지막 목록 조회의 인자(scope·includeDone·roomId·assigneeId·from·to('YYYY-MM-DD')·sort·offset·limit).
  Map<String, Object?>? lastList;

  /// null이 아니면 쓰기 호출이 이 사유로 실패(서버 4xx 흉내).
  String? failWith;

  /// 목록 조회를 붙잡아 둘 때(늦은 응답 시험) 쓰는 대기.
  Future<void>? listGate;

  /// 즐겨찾기 요청을 붙잡아 둘 때(낙관적 표시 시험) 쓰는 대기.
  Future<void>? favoriteGate;

  int _seq = 0;

  int callCount(String prefix) =>
      calls.where((c) => c.startsWith(prefix)).length;

  void _maybeFail() {
    if (failWith != null) throw ApiException(failWith!);
  }

  Map<String, dynamic>? _find(String id) =>
      todos.where((t) => t['id'] == id).firstOrNull;

  /// [t]에서 [userId]의 담당자 진척률 — 담당자가 아니면 null.
  static int? _assigneeProgressOf(Map<String, dynamic> t, String userId) {
    for (final a in _assignees(t)) {
      if (a['id'] == userId) {
        return (a['progress'] as num?)?.toInt() ?? (t['progress'] as int);
      }
    }
    return null;
  }

  /// 완료 제외·정렬에 쓰는 기준 진척률(서버와 같다) — assigneeId가 있으면 그 사람, 없고 나의 할 일이면 나의 담당 진척률,
  /// 그 사람이 담당자가 아니거나 그 밖의 탭이면 전체(집계).
  int _referenceProgress(
    Map<String, dynamic> t,
    TodoScope scope,
    String? assigneeId,
  ) {
    final who = assigneeId ?? (scope == TodoScope.mine ? me : null);
    if (who != null) {
      return _assigneeProgressOf(t, who) ?? (t['progress'] as int);
    }
    return t['progress'] as int;
  }

  bool _inScope(Map<String, dynamic> t, TodoScope scope) {
    final ids = [for (final a in _assignees(t)) a['id']];
    final creatorId = (t['creator'] as Map?)?['id'];
    return switch (scope) {
      TodoScope.mine => ids.contains(me) || (creatorId == me && ids.isEmpty),
      TodoScope.assignedByMe => creatorId == me && ids.any((id) => id != me),
      TodoScope.team => true,
    };
  }

  /// 기간(시작일 ?? 종료일 ~ 종료일 ?? 시작일)이 [from]~[to]에 걸치는가 — 'YYYY-MM-DD'는 문자열 비교가 곧 날짜 비교.
  static bool _overlaps(Map<String, dynamic> t, String from, String to) {
    final start = (t['startDate'] ?? t['dueDate']) as String?;
    final end = (t['dueDate'] ?? t['startDate']) as String?;
    if (start == null || end == null) return false;
    return start.compareTo(to) <= 0 && end.compareTo(from) >= 0;
  }

  @override
  Future<TodoPage> list({
    required String teamId,
    required TodoScope scope,
    bool includeDone = true,
    String? roomId,
    String? assigneeId,
    DateTime? from,
    DateTime? to,
    TodoSort sort = TodoSort.due,
    int offset = 0,
    int limit = 30,
  }) async {
    final fromWire = from == null ? null : todoDateWire(from);
    final toWire = to == null ? null : todoDateWire(to);
    calls.add(
      'list ${scope.wire} done=$includeDone room=$roomId sort=${sort.wire} offset=$offset limit=$limit'
      ' assignee=$assigneeId from=$fromWire to=$toWire',
    );
    lastList = {
      'teamId': teamId,
      'scope': scope,
      'includeDone': includeDone,
      'roomId': roomId,
      'assigneeId': assigneeId,
      'from': fromWire,
      'to': toWire,
      'sort': sort,
      'offset': offset,
      'limit': limit,
    };
    // 서버의 쿼리 검사(400)와 같게.
    if ((fromWire == null) != (toWire == null)) {
      throw const ApiException('from과 to는 함께 보내야 합니다.');
    }
    if (fromWire != null && toWire != null) {
      if (fromWire.compareTo(toWire) > 0) {
        throw const ApiException('기간의 시작일은 종료일보다 늦을 수 없습니다.');
      }
      // 양 끝을 포함한 날 수.
      final fromDay = DateTime.utc(from!.year, from.month, from.day);
      final toDay = DateTime.utc(to!.year, to.month, to.day);
      if (toDay.difference(fromDay).inDays + 1 > todoRangeMaxDays) {
        throw const ApiException('기간은 최대 $todoRangeMaxDays일까지 조회할 수 있습니다.');
      }
    }
    final maxLimit = fromWire != null ? todoRangeMaxLimit : todoListMaxLimit;
    final take = math.min(limit, maxLimit);
    await listGate;
    int ref(Map<String, dynamic> t) => _referenceProgress(t, scope, assigneeId);
    bool fav(Map<String, dynamic> t) => t['favorite'] == true;
    final rows = todos.where((t) {
      if (t['teamId'] != teamId) return false;
      if (roomId != null && t['roomId'] != roomId) return false;
      if (!_inScope(t, scope)) return false;
      if (assigneeId != null && _assigneeProgressOf(t, assigneeId) == null) {
        return false;
      }
      if (fromWire != null && !_overlaps(t, fromWire, toWire!)) return false;
      if (!includeDone && ref(t) >= 100) return false;
      return true;
    }).toList();
    rows.sort((a, b) {
      final byFavorite = (fav(a) ? 0 : 1).compareTo(fav(b) ? 0 : 1);
      if (byFavorite != 0) return byFavorite;
      if (sort == TodoSort.due) {
        final byDone = (ref(a) >= 100 ? 1 : 0).compareTo(ref(b) >= 100 ? 1 : 0);
        if (byDone != 0) return byDone;
        final ad = a['dueDate'] as String?;
        final bd = b['dueDate'] as String?;
        if (ad != bd) {
          if (ad == null) return 1;
          if (bd == null) return -1;
          return ad.compareTo(bd);
        }
        // 같은 기한일이면 종료 시간 순(시간이 없으면 뒤 — 서버와 같다).
        final at = a['dueTime'] as String?;
        final bt = b['dueTime'] as String?;
        if (at != bt) {
          if (at == null) return 1;
          if (bt == null) return -1;
          return at.compareTo(bt);
        }
      }
      final byCreated = (b['createdAt'] as int).compareTo(
        a['createdAt'] as int,
      );
      if (byCreated != 0) return byCreated;
      return (a['id'] as String).compareTo(b['id'] as String);
    });
    final page = rows.skip(offset).take(take + 1).toList();
    return TodoPage(
      items: [for (final t in page.take(take)) Todo.fromJson(t)],
      hasMore: page.length > take,
      // 서버처럼 같은 필터에 맞는 전체 개수(offset·limit과 상관없이).
      total: rows.length,
    );
  }

  @override
  Future<Todo> get(String id) async {
    calls.add('get $id');
    final t = _find(id);
    if (t == null) throw const ApiException('할 일을 찾을 수 없습니다.');
    return Todo.fromJson(t);
  }

  @override
  Future<Todo> create(
    String roomId, {
    required String title,
    String? description,
    List<String> assigneeIds = const [],
    String? startDate,
    String? dueDate,
    String? startTime,
    String? dueTime,
    List<UploadedAttachment> attachments = const [],
    List<DateTime> reminders = const [],
    String? downloadPath,
    String? uploadPath,
    bool announce = true,
    String? sourceMessageId,
    String? sourceCommentId,
  }) async {
    calls.add('create $roomId $title');
    _maybeFail();
    // 서버처럼 기간 검사(형식·날짜 없는 시간·순서) — 거절되면 아무것도 만들지 않는다.
    final periodError = fakeTodoPeriodError({
      'startDate': startDate,
      'startTime': startTime,
      'dueDate': dueDate,
      'dueTime': dueTime,
    });
    if (periodError != null) throw ApiException(periodError);
    lastCreateRoomId = roomId;
    lastCreateAttachments = attachments;
    lastCreate = {
      'title': title,
      'description': description,
      'assigneeIds': assigneeIds,
      'startDate': startDate,
      'dueDate': dueDate,
      'startTime': startTime,
      'dueTime': dueTime,
      'reminders': [for (final r in reminders) r.millisecondsSinceEpoch],
      'sourceMessageId': sourceMessageId,
      'sourceCommentId': sourceCommentId,
      'downloadPath': downloadPath,
      'uploadPath': uploadPath,
      'announce': announce,
    };
    final json = todoJson(
      id: 'new-${++_seq}',
      roomId: roomId,
      title: title,
      description: description,
      startDate: startDate,
      dueDate: dueDate,
      startTime: startTime,
      dueTime: dueTime,
      creatorId: me,
      assignees: assigneeIds,
      attachmentCount: attachments.length,
      sourceMessageId: sourceMessageId,
      sourceCommentId: sourceCommentId,
      downloadPath: downloadPath,
      uploadPath: uploadPath,
      me: me,
    );
    todos.add(json);
    return Todo.fromJson(json);
  }

  @override
  Future<Todo> update(String id, Map<String, dynamic> fields) async {
    calls.add('update $id ${fields.keys.join(',')}');
    _maybeFail();
    // 서버처럼 바꿀 칸이 하나도 없으면 거절(parseTodoPatch — 400).
    if (fields.isEmpty) throw const ApiException('수정할 내용이 없습니다.');
    lastUpdate = fields;
    final t = _find(id);
    if (t == null) throw const ApiException('할 일을 찾을 수 없습니다.');

    // 값 검사 → 권한 검사를 먼저 다 하고 바꾼다(서버처럼 거절되면 아무것도 안 바뀐다).
    final progress = fields['progress'];
    if (fields.containsKey('progress') &&
        (progress is! int || !todoProgressSteps.contains(progress))) {
      throw const ApiException('진척률은 0·25·50·75·100 중 하나여야 합니다.');
    }
    final isCreator = (t['creator'] as Map?)?['id'] == me;
    final isAssignee = _assigneeProgressOf(t, me) != null;
    final others = fields.keys.where((k) => k != 'progress');
    if (others.isNotEmpty && !isCreator && !isAssignee) {
      throw const ApiException('이 할 일을 수정할 권한이 없습니다.');
    }
    if (fields.containsKey('assigneeIds') && !isCreator) {
      throw const ApiException('담당자는 담당자 목록을 바꿀 수 없습니다.');
    }
    // 진척률은 역할이 아니라 담당 여부로 — 담당자는 자기 것, 담당자 없는 할 일은 만든 사람. 담당자 목록을 같이 바꾸면
    // 바뀐 뒤의 목록으로 따진다(서버와 같다 — 나를 빼면서 보내면 거절, 모두 빼면서 보내면 할 일의 값).
    final assigneesAfter = fields.containsKey('assigneeIds')
        ? [for (final id in fields['assigneeIds'] as List) id as String]
        : [for (final a in _assignees(t)) a['id'] as String];
    if (fields.containsKey('progress') &&
        !assigneesAfter.contains(me) &&
        !(isCreator && assigneesAfter.isEmpty)) {
      throw const ApiException('담당자만 진척률을 바꿀 수 있습니다.');
    }
    // 기간은 안 보낸 쪽을 저장된 값과 합쳐 본다(서버 mergeTodoPeriod) — 날짜를 지우면 그 시간도 지운다.
    final period = <String, Object?>{};
    for (final (dateKey, timeKey) in const [
      ('startDate', 'startTime'),
      ('dueDate', 'dueTime'),
    ]) {
      period[dateKey] = fields.containsKey(dateKey)
          ? fields[dateKey]
          : t[dateKey];
      period[timeKey] = fields.containsKey(timeKey)
          ? fields[timeKey]
          : fields.containsKey(dateKey) && fields[dateKey] == null
          ? null
          : t[timeKey];
    }
    final periodError = fakeTodoPeriodError(period);
    if (periodError != null) throw ApiException(periodError);

    // 바로 전의 담당자별 진척률 — 이번 수정으로 담당자가 모두 빠지면 할 일이 이어받을 값을 여기서 정한다.
    final progressBefore = {
      for (final a in _assignees(t))
        a['id'] as String:
            (a['progress'] as num?)?.toInt() ?? (t['progress'] as int),
    };
    for (final e in fields.entries) {
      switch (e.key) {
        case 'progress':
          break; // 담당자 목록을 반영한 뒤에 따로.
        case 'assigneeIds':
          // 차이만 반영 — 남는 사람은 진척률 그대로, 새 사람은 0.
          final before = {for (final a in _assignees(t)) a['id']: a};
          t['assignees'] = [
            for (final uid in e.value as List)
              before[uid] ?? _assigneeJson(uid as String, uid, 0),
          ];
        case 'attachments':
          t['attachments'] = [
            for (final (i, a) in (e.value as List).indexed)
              {'id': 'a$i', ...Map<String, dynamic>.from(a as Map)},
          ];
        case 'reminders':
          t['reminders'] = [
            for (final (i, r) in (e.value as List).indexed)
              {
                'id': (r as Map)['id'] ?? 'r-new-$i',
                'remindAt': r['remindAt'],
                'sent': false,
              },
          ];
        case 'startDate' || 'startTime' || 'dueDate' || 'dueTime':
          break; // 합친 기간으로 아래에서 한꺼번에.
        default:
          t[e.key] = e.value;
      }
    }
    t.addAll(period);
    if (progressBefore.isNotEmpty && _assignees(t).isEmpty) {
      t['progress'] = orphanedTodoProgress(
        (t['creator'] as Map?)?['id'] as String?,
        progressBefore,
      );
    }
    if (progress is int) {
      final mine = _assignees(t).where((a) => a['id'] == me).firstOrNull;
      if (mine != null) {
        mine['progress'] = progress;
      } else if (_assignees(t).isEmpty) {
        t['progress'] = progress;
      }
    }
    refreshTodoJson(t, me: me);
    return Todo.fromJson(t);
  }

  @override
  Future<void> delete(String id) async {
    calls.add('delete $id');
    _maybeFail();
    todos.removeWhere((t) => t['id'] == id);
  }

  @override
  Future<bool> setFavorite(String id, bool favorite) async {
    calls.add('setFavorite $id $favorite');
    _maybeFail();
    await favoriteGate;
    final t = _find(id);
    if (t == null) {
      // 끄기는 없어도 그냥 된다(서버는 행만 지운다).
      if (favorite) throw const ApiException('할 일을 찾을 수 없습니다.');
      return false;
    }
    t['favorite'] = favorite;
    return favorite;
  }

  /// 할 일마다 달린 댓글(오래된 것부터).
  final todoComments = <String, List<TodoComment>>{};

  /// 댓글 목록 조회 횟수 — 상세를 열 때마다 부르므로 [calls]에는 남기지 않는다(다른 호출 순서 시험이 흔들리지 않게).
  int commentFetches = 0;

  @override
  Future<List<TodoComment>> comments(String id) async {
    commentFetches++;
    return [...?todoComments[id]];
  }

  @override
  Future<TodoComment> postComment(String id, String text) async {
    calls.add('postComment $id $text');
    _maybeFail();
    final comment = TodoComment(
      id: 'comment-${++_seq}',
      todoId: id,
      authorId: me,
      authorName: me,
      text: text,
      createdAt: DateTime.fromMillisecondsSinceEpoch(9000 + _seq),
    );
    (todoComments[id] ??= []).add(comment);
    return comment;
  }

  @override
  Future<TodoComment> updateComment(
    String id,
    String commentId,
    String text,
  ) async {
    calls.add('updateComment $id $commentId $text');
    _maybeFail();
    final list = todoComments[id] ?? [];
    final i = list.indexWhere((c) => c.id == commentId);
    if (i < 0) throw const ApiException('댓글을 찾을 수 없습니다.');
    final updated = list[i].copyWith(
      text: text,
      editedAt: DateTime.fromMillisecondsSinceEpoch(20000 + ++_seq),
    );
    list[i] = updated;
    return updated;
  }

  @override
  Future<void> deleteComment(String id, String commentId) async {
    calls.add('deleteComment $id $commentId');
    _maybeFail();
    todoComments[id]?.removeWhere((c) => c.id == commentId);
  }
}

List<Map<String, dynamic>> _assignees(Map<String, dynamic> t) =>
    ((t['assignees'] as List?) ?? const []).cast<Map<String, dynamic>>();

String _statusOf(int p) => p >= 100
    ? 'done'
    : p > 0
    ? 'doing'
    : 'todo';

Map<String, dynamic> _assigneeJson(String id, String name, int progress) => {
  'id': id,
  'name': name,
  'avatarType': 'initial',
  'progress': progress,
  'status': _statusOf(progress),
  'completedAt': progress >= 100 ? 5000 : null,
};

/// 기간 검사(서버 parseTime + checkPeriod와 같다) — 시간은 'HH:mm'(00:00~23:59)이고 그 날짜가 있어야 하며, 두 날짜가
/// 다 있으면 (날짜, 시간) 순으로 시작 ≤ 종료(없는 시간은 시작 00:00 / 종료 23:59). 문제가 없으면 null.
String? fakeTodoPeriodError(Map<String, Object?> p) {
  final timeRe = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
  for (final (key, label) in const [
    ('startTime', '시작 시간'),
    ('dueTime', '종료 시간'),
  ]) {
    final v = p[key];
    if (v != null && (v is! String || !timeRe.hasMatch(v))) {
      return '$label이 올바르지 않습니다. (HH:mm)';
    }
  }
  final sd = p['startDate'] as String?;
  final st = p['startTime'] as String?;
  final dd = p['dueDate'] as String?;
  final dt = p['dueTime'] as String?;
  if (st != null && sd == null) return '시작 시간은 시작일과 함께 정해야 합니다.';
  if (dt != null && dd == null) return '종료 시간은 종료일과 함께 정해야 합니다.';
  if (sd != null &&
      dd != null &&
      '${sd}T${st ?? '00:00'}'.compareTo('${dd}T${dt ?? '23:59'}') > 0) {
    return sd.compareTo(dd) > 0
        ? '시작일은 종료일보다 늦을 수 없습니다.'
        : '시작 시간은 종료 시간보다 늦을 수 없습니다.';
  }
  return null;
}

/// 담당자들의 진척률 → 전체(집계) 진척률 — 모두 100이면 100, 모두 0이면 0, 그 밖은 평균을 반올림해 1~99로(서버와 같다).
int aggregateTodoProgress(List<int> values) {
  if (values.every((p) => p >= 100)) return 100;
  if (values.every((p) => p <= 0)) return 0;
  final avg = (values.reduce((a, b) => a + b) / values.length).round();
  return avg.clamp(1, 99);
}

/// 진척률을 가장 가까운 단계(0·25·50·75·100)로 — 두 단계의 한가운데는 큰 쪽으로(반은 올림, 서버 nearestProgressStep).
int nearestTodoProgressStep(int value) {
  var nearest = todoProgressSteps.first;
  for (final step in todoProgressSteps) {
    // 단계가 오름차순이라 거리가 같으면 뒤의 큰 단계가 남는다.
    if ((value - step).abs() <= (value - nearest).abs()) nearest = step;
  }
  return nearest;
}

/// 담당자가 하나도 남지 않게 된 할 일이 이어받을 진척률(서버 orphanedProgress, 검토 S3) — 바로 전([before] = 담당자 id →
/// 진척률)에 만든 사람([creatorId])도 담당자였으면 그 사람의 진척률, 아니면 직전 집계를 가장 가까운 단계로 맞춘 값.
int orphanedTodoProgress(String? creatorId, Map<String, int> before) {
  final creator = before[creatorId];
  if (creator != null) return creator;
  return nearestTodoProgressStep(aggregateTodoProgress(before.values.toList()));
}

/// [t]의 계산되는 값을 다시 맞춘다 — 담당자별 상태·완료 시각, 전체(집계) 진척률·상태·완료 시각(담당자가 있을 때),
/// 보는 사람([me]) 기준 myRole·canEdit·canManage·myProgress·canSetProgress. 시험에서 맵을 직접 고친 뒤에도 부를 수 있다.
Map<String, dynamic> refreshTodoJson(
  Map<String, dynamic> t, {
  required String me,
}) {
  final assignees = _assignees(t);
  for (final a in assignees) {
    final p = (a['progress'] as num?)?.toInt() ?? 0;
    a['progress'] = p;
    a['status'] = _statusOf(p);
    a['completedAt'] = p >= 100 ? (a['completedAt'] ?? 5000) : null;
  }
  if (assignees.isNotEmpty) {
    t['progress'] = aggregateTodoProgress([
      for (final a in assignees) a['progress'] as int,
    ]);
  }
  final progress = t['progress'] as int;
  t['status'] = _statusOf(progress);
  t['completedAt'] = progress >= 100 ? (t['completedAt'] ?? 5000) : null;

  final isCreator = (t['creator'] as Map?)?['id'] == me;
  final mine = assignees.where((a) => a['id'] == me).firstOrNull;
  t['myRole'] = isCreator
      ? 'creator'
      : mine != null
      ? 'assignee'
      : 'viewer';
  t['canEdit'] = isCreator || mine != null;
  t['canManage'] = isCreator;
  final myProgress = mine != null
      ? mine['progress'] as int
      : isCreator && assignees.isEmpty
      ? progress
      : null;
  t['myProgress'] = myProgress;
  t['canSetProgress'] = myProgress != null;
  return t;
}

/// 서버 할 일 DTO 한 건. [me]는 보는 사람(myRole·canEdit·canManage·myProgress·canSetProgress·[favorite]가 그 기준).
/// 담당자별 진척률은 [assigneeProgress](담당자 id → 진척률), 없는 담당자는 [progress]를 받는다(예전 공용 진척률을
/// 나눠 준 마이그레이션과 같다). 담당자가 있으면 `progress`(전체)는 담당자들의 진척률로 다시 계산된다.
Map<String, dynamic> todoJson({
  String id = 't1',
  String teamId = 't1',
  String roomId = 'r1',
  String roomName = '영업 토픽',
  String title = '견적서 보내기',
  String? description,
  String? startDate,
  String? dueDate,
  String? startTime,
  String? dueTime,
  int progress = 0,
  String creatorId = 'me',
  String creatorName = '나',
  List<String> assignees = const [],
  Map<String, int> assigneeProgress = const {},
  bool favorite = false,
  int attachmentCount = 0,
  List<Map<String, dynamic>> reminders = const [],
  String? sourceMessageId,
  String? sourceCommentId,
  String? downloadPath,
  String? uploadPath,
  String me = 'me',
  int createdAt = 1000,
}) {
  final json = <String, dynamic>{
    'id': id,
    'teamId': teamId,
    'roomId': roomId,
    'roomName': roomName,
    'title': title,
    'description': description,
    'startDate': startDate,
    'dueDate': dueDate,
    'startTime': startTime,
    'dueTime': dueTime,
    'progress': progress,
    'creator': {'id': creatorId, 'name': creatorName, 'avatarType': 'initial'},
    'assignees': [
      for (final a in assignees)
        _assigneeJson(a, '이름$a', assigneeProgress[a] ?? progress),
    ],
    'favorite': favorite,
    'attachments': [
      for (var i = 0; i < attachmentCount; i++)
        {
          'id': 'att$i',
          'kind': 'file',
          'fileUrl': '/files/tok$i',
          'fileName': '자료$i.pdf',
          'fileSize': 100,
        },
    ],
    'reminders': reminders,
    'sourceMessageId': sourceMessageId,
    'sourceCommentId': sourceCommentId,
    'downloadPath': downloadPath,
    'uploadPath': uploadPath,
    'createdAt': createdAt,
    'updatedAt': createdAt,
  };
  return refreshTodoJson(json, me: me);
}
