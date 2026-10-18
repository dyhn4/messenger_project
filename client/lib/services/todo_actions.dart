import '../models/room.dart';
import 'api_client.dart';
import 'session.dart';
import 'todo_api.dart';
import '../l10n/tr.dart';

/// 할 일의 Session 쪽 얇은 조각 — 서버 호출 손잡이와, 소켓 todo:changed / todo:reminder를 앱이 켜져 있는 동안 토스트로
/// 알리는 문구. Session 본체가 이미 커서 새 코드는 확장으로 따로 두고(session.dart가 같이 내보낸다), 목록 상태는
/// 패널이 만드는 TodoController(todo_controller.dart)가 들고 있다.
extension SessionTodos on Session {
  /// 이 로그인의 할 일 API — 연결이 없으면(로그아웃 직후 등) [ApiException].
  TodoApi get todoApi {
    final client = api;
    if (client == null) throw ApiException(tr('연결되어 있지 않습니다.'));
    return RemoteTodoApi(client);
  }

  /// 이 방에 할 일을 만들 수 있는지 — 비밀 대화와 보드 뷰 토픽에서는 못 만든다(서버가 400으로 막는다, 잔디도 챗 뷰
  /// 토픽·채팅에서만). 읽기 전용·보관된 토픽은 토픽 관리자만 글을 쓸 수 있는 것과 같게 할 일도 관리자만 만든다.
  bool canCreateTodoIn(Room room) =>
      !room.isSecret && !room.isBoard && room.canWrite(this);
}

/// 소켓 todo:changed로 "나에게 담당이 지정됐다"는 안내 토스트 문구 — 내가 한 일이거나 나와 무관하면 null.
String? todoAssignedToast(Map<String, dynamic> event, {String? myUserId}) {
  if (myUserId == null) return null;
  final added =
      (event['addedAssigneeIds'] as List?)?.cast<String>() ?? const [];
  if (!added.contains(myUserId) || event['actorId'] == myUserId) return null;
  final title = (event['title'] as String?)?.trim();
  return title == null || title.isEmpty
      ? tr('할 일이 나에게 지정되었습니다.')
      : tr('할 일이 지정되었습니다: {title}', {'title': title});
}

/// 소켓 todo:reminder 토스트 문구 — `할 일 알림: 제목`.
String todoReminderToast(Map<String, dynamic> event) {
  final title = (event['title'] as String?)?.trim() ?? '';
  return title.isEmpty ? tr('할 일 알림') : tr('할 일 알림: {title}', {'title': title});
}
