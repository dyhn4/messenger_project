/// 웹용 자리 — 웹은 이 기기 메시지 DB를 쓰지 않는다(local_message_store.dart — SQLite는 dart:ffi가 필요하다).
class LocalMessageStore {
  LocalMessageStore._();

  static const perRoomMax = 5000;

  static LocalMessageStore? open(String path) => null;

  static String searchTextOf(Map<String, dynamic> raw) => '';

  String get path => '';
  int upsertAll(String roomId, Iterable<Map<String, dynamic>> raws) => 0;
  List<Map<String, dynamic>> latest(String roomId, {int limit = 50}) =>
      const [];
  List<Map<String, dynamic>> older(
    String roomId,
    DateTime before, {
    int limit = 50,
  }) => const [];
  List<Map<String, dynamic>> search(
    String query, {
    Iterable<String>? roomIds,
    int limit = 100,
  }) => const [];
  void update(
    String messageId,
    Map<String, dynamic> Function(Map<String, dynamic>) change,
  ) {}
  void forgetRoom(String roomId) {}
  int count([String? roomId]) => 0;
  void close() {}
}
