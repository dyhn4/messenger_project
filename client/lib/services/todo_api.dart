import '../models/todo.dart';
import '../models/uploaded_attachment.dart';
import 'api_client.dart';

/// 할 일의 REST 호출 — 컨트롤러·화면은 이 추상 클래스만 알아서, 테스트는 가짜 구현을 끼우고 실제 앱은
/// [RemoteTodoApi]가 [ApiClient]로 서버(server/src/todos.js)를 부른다(bookmark_api.dart와 같은 방식).
abstract class TodoApi {
  /// `GET /api/todos` — 내가 아직 멤버인 방의 할 일. 정렬이 복합 키라 커서 대신 [offset]으로 이어 받는다.
  /// 내가 즐겨찾기한 것이 먼저 오고, 완료 제외([includeDone] false)·기한순 정렬은 "기준 진척률"([assigneeId]가 있으면
  /// 그 사람의 것, 나의 할 일이면 내 것, 그 밖은 전체)로 따진다. [assigneeId]는 그 사람이 담당인 것만(어느 scope에나),
  /// [from]·[to](둘 다 주거나 둘 다 빼기, 최대 [todoRangeMaxDays]일)는 기간이 그 범위에 걸치는 것만(날짜 없는 할 일은
  /// 빠진다) — 이때 [limit]은 [todoRangeMaxLimit]까지(없으면 [todoListMaxLimit]까지). 응답의 `total`(같은 필터에 맞는
  /// 전체 개수, offset·limit 무관)은 [TodoPage.total]로 — 예전 서버면 null.
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
  });

  /// `GET /api/todos/:id`.
  Future<Todo> get(String id);

  /// `POST /api/rooms/:roomId/todos`. 날짜는 'YYYY-MM-DD', 시간([startTime]·[dueTime])은 그 날짜의 'HH:mm'(날짜 없이
  /// 시간만 보내면 400), [reminders]는 ms 시각들.
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
    String? sourceMessageId,
    String? sourceCommentId,
  });

  /// `PATCH /api/todos/:id` — [fields]에 담긴 것만 바뀐다(키: title·description·assigneeIds·startDate·startTime·
  /// dueDate·dueTime·attachments·reminders·progress — 날짜를 null로 지우면 그 시간도 지워진다). 담당자는 `assigneeIds`를 보내면 403이다. `progress`는 "내 진척률"
  /// ([todoProgressSteps] 중 하나) — 담당자는 자기 것만, 담당자가 없는 할 일은 만든 사람이 바꾸고, 그 밖은 403이다.
  Future<Todo> update(String id, Map<String, dynamic> fields);

  /// `DELETE /api/todos/:id` — 만든 사람만.
  Future<void> delete(String id);

  /// `PUT /api/todos/:id/favorite` — 내 즐겨찾기를 켜고 끈다. 서버가 확정한 값을 돌려준다.
  Future<bool> setFavorite(String id, bool favorite);

  /// `GET /api/todos/:id/comments` — 오래된 것부터.
  Future<List<TodoComment>> comments(String id);

  /// `POST /api/todos/:id/comments` — 그 방 멤버 누구나(1000자까지).
  Future<TodoComment> postComment(String id, String text);

  /// `PATCH /api/todos/:id/comments/:commentId` — 작성자만. 고친 댓글을 돌려준다.
  Future<TodoComment> updateComment(String id, String commentId, String text);

  /// `DELETE /api/todos/:id/comments/:commentId` — 작성자와 관리자.
  Future<void> deleteComment(String id, String commentId);
}

class RemoteTodoApi implements TodoApi {
  final ApiClient _api;
  RemoteTodoApi(this._api);

  Map<String, dynamic> _map(Object? body) =>
      Map<String, dynamic>.from(body as Map);

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
    final query = <String, String>{
      'teamId': teamId,
      'scope': scope.wire,
      'includeDone': '$includeDone',
      'sort': sort.wire,
      'offset': '$offset',
      'limit': '$limit',
      'roomId': ?roomId,
      'assigneeId': ?assigneeId,
      if (from != null) 'from': todoDateWire(from),
      if (to != null) 'to': todoDateWire(to),
    };
    final qs = query.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return TodoPage.fromJson(
      _map(await _api.requestJson('GET', '/api/todos?$qs')),
    );
  }

  @override
  Future<Todo> get(String id) async =>
      Todo.fromJson(_map(await _api.requestJson('GET', '/api/todos/$id')));

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
    String? sourceMessageId,
    String? sourceCommentId,
  }) async => Todo.fromJson(
    _map(
      await _api.requestJson(
        'POST',
        '/api/rooms/$roomId/todos',
        body: {
          'title': title,
          'description': ?description,
          'assigneeIds': assigneeIds,
          'startDate': ?startDate,
          'dueDate': ?dueDate,
          'startTime': ?startTime,
          'dueTime': ?dueTime,
          'attachments': [for (final a in attachments) a.toPayload()],
          'reminders': [for (final r in reminders) r.millisecondsSinceEpoch],
          'sourceMessageId': ?sourceMessageId,
          'sourceCommentId': ?sourceCommentId,
        },
      ),
    ),
  );

  @override
  Future<Todo> update(String id, Map<String, dynamic> fields) async =>
      Todo.fromJson(
        _map(await _api.requestJson('PATCH', '/api/todos/$id', body: fields)),
      );

  @override
  Future<void> delete(String id) async {
    await _api.requestJson('DELETE', '/api/todos/$id');
  }

  @override
  Future<bool> setFavorite(String id, bool favorite) async {
    final body = _map(
      await _api.requestJson(
        'PUT',
        '/api/todos/$id/favorite',
        body: {'favorite': favorite},
      ),
    );
    return body['favorite'] as bool? ?? favorite;
  }

  @override
  Future<List<TodoComment>> comments(String id) async {
    final body = await _api.requestJson('GET', '/api/todos/$id/comments');
    return [for (final c in body as List) TodoComment.fromJson(_map(c))];
  }

  @override
  Future<TodoComment> postComment(String id, String text) async =>
      TodoComment.fromJson(
        _map(
          await _api.requestJson(
            'POST',
            '/api/todos/$id/comments',
            body: {'text': text},
          ),
        ),
      );

  @override
  Future<TodoComment> updateComment(
    String id,
    String commentId,
    String text,
  ) async => TodoComment.fromJson(
    _map(
      await _api.requestJson(
        'PATCH',
        '/api/todos/$id/comments/$commentId',
        body: {'text': text},
      ),
    ),
  );

  @override
  Future<void> deleteComment(String id, String commentId) async {
    await _api.requestJson('DELETE', '/api/todos/$id/comments/$commentId');
  }
}
