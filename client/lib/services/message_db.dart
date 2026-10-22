/// 이 기기 메시지 DB를 쓰는 쪽(offline_cache.dart)이 보는 모양 — 앱은 SQLite(local_message_store.dart — message_db_io.dart가
/// 감싼다), 웹은 IndexedDB(message_db_web.dart)다. 둘 다 서버가 준 메시지 JSON을 그대로 방마다 쌓아 두고(같은 id는 바꿔 씀),
/// 방마다 최근 [messageDbPerRoomMax]통까지만 남긴다. 비밀 대화는 넣지 않는다(부르는 쪽이 거른다).
abstract class MessageDb {
  /// 메시지들을 넣거나 바꾼다(같은 id면 바꿈). 방 id가 다른 것(창 밖 부모 등)은 그 방으로.
  Future<void> upsertAll(String roomId, List<Map<String, dynamic>> raws);

  /// 방의 가장 최근 [limit]통(오래된 것부터).
  Future<List<Map<String, dynamic>>> latest(String roomId, {int limit = 50});

  /// [before]보다 먼저 쓴 메시지 [limit]통(오래된 것부터).
  Future<List<Map<String, dynamic>>> older(
    String roomId,
    DateTime before, {
    int limit = 50,
  });

  /// 찾기 — [query]가 든 메시지(새것부터 [limit]통, 지운 메시지 제외). [roomIds]를 주면 그 방들에서만.
  Future<List<Map<String, dynamic>>> search(
    String query, {
    Iterable<String>? roomIds,
    int limit = 100,
  });

  /// 메시지 하나의 JSON을 고친다([change]가 고친 JSON을 돌려준다). 없으면 그대로.
  Future<void> update(
    String messageId,
    Map<String, dynamic> Function(Map<String, dynamic>) change,
  );

  /// 메시지들을 지운다(서버가 완전히 지운 것 — 아무도 안 읽은 메시지 지우기·보존 기간 파기). 없는 id는 넘어간다.
  Future<void> remove(Iterable<String> messageIds);

  /// 그 방의 메시지를 모두 지운다.
  Future<void> forgetRoom(String roomId);

  /// 그 방에서 [before]보다 먼저 쓴 메시지를 지운다(빠진 구간을 다 메우지 못해 이어지지 않는 옛 저장분 — offline_cache.dart fillGap).
  Future<void> forgetBefore(String roomId, DateTime before);

  /// 방마다 저장된 가장 최근 메시지의 작성 시각(서버 시각).
  Future<Map<String, DateTime>> newestByRoom();

  /// 저장된 메시지 수(시험).
  Future<int> count([String? roomId]);

  /// 메시지 말고 따로 둘 값(JSON — 웹은 파일이 없어 팀·방 목록과 동기화 자리도 여기에). 앱은 파일로 두므로 쓰지 않는다(null).
  Future<Object?> readValue(String key);
  Future<void> writeValue(String key, Object? value);

  /// 닫는다(지우지 않음).
  void close();

  /// 닫고 저장분을 모두 지운다(로그아웃 — 앱은 폴더째 지우므로 닫기만).
  Future<void> destroy();
}

/// 방마다 남기는 메시지 수(LocalMessageStore.perRoomMax와 같다).
const messageDbPerRoomMax = 5000;

/// 메시지 JSON에서 찾기용 글 — 본문·게시글 제목·첨부 파일 이름(이모티콘은 id라 뺀다).
String messageSearchTextOf(Map<String, dynamic> raw) {
  final parts = <String>[];
  void add(Object? v) {
    if (v is String && v.trim().isNotEmpty) parts.add(v.trim());
  }

  add(raw['title']);
  if (raw['type'] != 'sticker') add(raw['text']);
  add(raw['fileName']);
  final attachments = raw['attachments'];
  if (attachments is List) {
    for (final a in attachments) {
      if (a is Map) add(a['fileName']);
    }
  }
  return parts.join('\n');
}

/// 메시지 JSON의 작성 시각(ms) — 서버는 숫자로 주지만 예전 모양(문자열)도 읽는다.
int messageCreatedAtOf(Map<String, dynamic> raw) {
  final v = raw['createdAt'];
  if (v is num) return v.toInt();
  if (v is String) {
    return DateTime.tryParse(v)?.millisecondsSinceEpoch ?? int.tryParse(v) ?? 0;
  }
  return 0;
}
