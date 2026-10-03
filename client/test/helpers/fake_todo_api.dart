import 'package:client/models/todo.dart';
import 'package:client/models/uploaded_attachment.dart';
import 'package:client/services/api_client.dart' show ApiException;
import 'package:client/services/todo_api.dart';

/// 서버 없이 할 일 컨트롤러·화면을 시험하는 가짜 API. 호출을 [calls]에 기록하고, 할 일은 서버 DTO 모양의 맵으로 메모리에
/// 들고 있으며, 목록 조회는 진짜 서버(server/src/todos.js)처럼 scope·includeDone·roomId·정렬·offset·limit을 지킨다.
class FakeTodoApi implements TodoApi {
  FakeTodoApi({required this.me, List<Map<String, dynamic>>? todos})
    : todos = todos ?? [];

  /// 보는 사람(mine = 내가 담당, assigned_by_me = 내가 만듦).
  final String me;

  /// 서버에 있는 할 일 DTO들(`todoJson`이 만든 맵).
  final List<Map<String, dynamic>> todos;

  /// 호출 기록 — "메서드명 인자…" 문자열.
  final calls = <String>[];

  /// 마지막 create/update 요청의 세부.
  Map<String, dynamic>? lastCreate;
  Map<String, dynamic>? lastUpdate;
  String? lastCreateRoomId;
  List<UploadedAttachment> lastCreateAttachments = const [];

  /// null이 아니면 쓰기 호출이 이 사유로 실패(서버 4xx 흉내).
  String? failWith;

  /// 목록 조회를 붙잡아 둘 때(늦은 응답 시험) 쓰는 대기.
  Future<void>? listGate;

  int _seq = 0;

  int callCount(String prefix) =>
      calls.where((c) => c.startsWith(prefix)).length;

  void _maybeFail() {
    if (failWith != null) throw ApiException(failWith!);
  }

  static bool _done(Map<String, dynamic> t) => (t['progress'] as int) >= 100;

  @override
  Future<TodoPage> list({
    required String teamId,
    required TodoScope scope,
    bool includeDone = true,
    String? roomId,
    TodoSort sort = TodoSort.due,
    int offset = 0,
    int limit = 30,
  }) async {
    calls.add(
      'list ${scope.wire} done=$includeDone room=$roomId sort=${sort.wire} offset=$offset limit=$limit',
    );
    await listGate;
    final rows = todos.where((t) {
      if (t['teamId'] != teamId) return false;
      if (roomId != null && t['roomId'] != roomId) return false;
      if (!includeDone && _done(t)) return false;
      final assignees = (t['assignees'] as List).cast<Map<String, dynamic>>();
      return switch (scope) {
        TodoScope.mine => assignees.any((a) => a['id'] == me),
        TodoScope.assignedByMe => (t['creator'] as Map?)?['id'] == me,
        TodoScope.team => true,
      };
    }).toList();
    rows.sort((a, b) {
      if (sort == TodoSort.created) {
        return (b['createdAt'] as int).compareTo(a['createdAt'] as int);
      }
      final byDone = (_done(a) ? 1 : 0).compareTo(_done(b) ? 1 : 0);
      if (byDone != 0) return byDone;
      final ad = a['dueDate'] as String?;
      final bd = b['dueDate'] as String?;
      if (ad != bd) {
        if (ad == null) return 1;
        if (bd == null) return -1;
        return ad.compareTo(bd);
      }
      return (b['createdAt'] as int).compareTo(a['createdAt'] as int);
    });
    final page = rows.skip(offset).take(limit + 1).toList();
    return TodoPage(
      items: [for (final t in page.take(limit)) Todo.fromJson(t)],
      hasMore: page.length > limit,
    );
  }

  @override
  Future<Todo> get(String id) async {
    calls.add('get $id');
    final t = todos.where((t) => t['id'] == id).firstOrNull;
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
    List<UploadedAttachment> attachments = const [],
    List<DateTime> reminders = const [],
    String? sourceMessageId,
    String? sourceCommentId,
  }) async {
    calls.add('create $roomId $title');
    _maybeFail();
    lastCreateRoomId = roomId;
    lastCreateAttachments = attachments;
    lastCreate = {
      'title': title,
      'description': description,
      'assigneeIds': assigneeIds,
      'startDate': startDate,
      'dueDate': dueDate,
      'reminders': [for (final r in reminders) r.millisecondsSinceEpoch],
      'sourceMessageId': sourceMessageId,
      'sourceCommentId': sourceCommentId,
    };
    final json = todoJson(
      id: 'new-${++_seq}',
      roomId: roomId,
      title: title,
      description: description,
      startDate: startDate,
      dueDate: dueDate,
      creatorId: me,
      assignees: assigneeIds,
      attachmentCount: attachments.length,
      sourceMessageId: sourceMessageId,
      sourceCommentId: sourceCommentId,
    );
    todos.add(json);
    return Todo.fromJson(json);
  }

  @override
  Future<Todo> update(String id, Map<String, dynamic> fields) async {
    calls.add('update $id ${fields.keys.join(',')}');
    _maybeFail();
    lastUpdate = fields;
    final t = todos.where((t) => t['id'] == id).firstOrNull;
    if (t == null) throw const ApiException('할 일을 찾을 수 없습니다.');
    for (final e in fields.entries) {
      switch (e.key) {
        case 'assigneeIds':
          t['assignees'] = [
            for (final id in e.value as List) {'id': id, 'name': '$id'},
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
        default:
          t[e.key] = e.value;
      }
    }
    return Todo.fromJson(t);
  }

  @override
  Future<void> delete(String id) async {
    calls.add('delete $id');
    _maybeFail();
    todos.removeWhere((t) => t['id'] == id);
  }
}

/// 서버 할 일 DTO 한 건. [role]은 보는 사람 기준(canEdit/canManage는 그에 맞춘다).
Map<String, dynamic> todoJson({
  String id = 't1',
  String teamId = 't1',
  String roomId = 'r1',
  String roomName = '영업 토픽',
  String title = '견적서 보내기',
  String? description,
  String? startDate,
  String? dueDate,
  int progress = 0,
  String creatorId = 'me',
  String creatorName = '나',
  List<String> assignees = const [],
  int attachmentCount = 0,
  List<Map<String, dynamic>> reminders = const [],
  String? sourceMessageId,
  String? sourceCommentId,
  String me = 'me',
  int createdAt = 1000,
}) {
  final isCreator = creatorId == me;
  final isAssignee = assignees.contains(me);
  return {
    'id': id,
    'teamId': teamId,
    'roomId': roomId,
    'roomName': roomName,
    'title': title,
    'description': description,
    'startDate': startDate,
    'dueDate': dueDate,
    'progress': progress,
    'status': progress >= 100
        ? 'done'
        : progress > 0
        ? 'doing'
        : 'todo',
    'completedAt': progress >= 100 ? 5000 : null,
    'creator': {'id': creatorId, 'name': creatorName, 'avatarType': 'initial'},
    'assignees': [
      for (final a in assignees)
        {'id': a, 'name': '이름$a', 'avatarType': 'initial'},
    ],
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
    'myRole': isCreator
        ? 'creator'
        : isAssignee
        ? 'assignee'
        : 'viewer',
    'canEdit': isCreator || isAssignee,
    'canManage': isCreator,
    'createdAt': createdAt,
    'updatedAt': createdAt,
  };
}
