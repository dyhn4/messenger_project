import '../models/todo.dart';
import '../models/uploaded_attachment.dart';
import 'api_client.dart';

/// 할 일의 REST 호출 — 컨트롤러·화면은 이 추상 클래스만 알아서, 테스트는 가짜 구현을 끼우고 실제 앱은
/// [RemoteTodoApi]가 [ApiClient]로 서버(server/src/todos.js)를 부른다(bookmark_api.dart와 같은 방식).
abstract class TodoApi {
  /// `GET /api/todos` — 내가 아직 멤버인 방의 할 일. 정렬이 복합 키라 커서 대신 [offset]으로 이어 받는다.
  Future<TodoPage> list({
    required String teamId,
    required TodoScope scope,
    bool includeDone = true,
    String? roomId,
    TodoSort sort = TodoSort.due,
    int offset = 0,
    int limit = 30,
  });

  /// `GET /api/todos/:id`.
  Future<Todo> get(String id);

  /// `POST /api/rooms/:roomId/todos`. 날짜는 'YYYY-MM-DD', [reminders]는 ms 시각들.
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
  });

  /// `PATCH /api/todos/:id` — [fields]에 담긴 것만 바뀐다(키: title·description·assigneeIds·startDate·dueDate·
  /// attachments·reminders·progress). 담당자는 `assigneeIds`를 보내면 403이다.
  Future<Todo> update(String id, Map<String, dynamic> fields);

  /// `DELETE /api/todos/:id` — 만든 사람만.
  Future<void> delete(String id);
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
}
