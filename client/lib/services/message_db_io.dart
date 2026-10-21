import 'dart:io';

import 'local_message_store.dart';
import 'message_db.dart';

/// 앱의 메시지 DB — [dir]의 messages.sqlite(LocalMessageStore)를 연다. 폴더가 없거나(저장하지 않는 설정·시험) 못 열면 null.
Future<MessageDb?> openMessageDb(String scope, Directory? dir) async {
  if (dir == null) return null;
  final store = LocalMessageStore.open('${dir.path}/messages.sqlite');
  return store == null ? null : SqliteMessageDb(store);
}

/// LocalMessageStore(동기 — package:sqlite3)를 MessageDb 모양으로.
class SqliteMessageDb implements MessageDb {
  SqliteMessageDb(this.store);

  final LocalMessageStore store;

  @override
  Future<void> upsertAll(
    String roomId,
    List<Map<String, dynamic>> raws,
  ) async => store.upsertAll(roomId, raws);

  @override
  Future<List<Map<String, dynamic>>> latest(
    String roomId, {
    int limit = 50,
  }) async => store.latest(roomId, limit: limit);

  @override
  Future<List<Map<String, dynamic>>> older(
    String roomId,
    DateTime before, {
    int limit = 50,
  }) async => store.older(roomId, before, limit: limit);

  @override
  Future<List<Map<String, dynamic>>> search(
    String query, {
    Iterable<String>? roomIds,
    int limit = 100,
  }) async => store.search(query, roomIds: roomIds, limit: limit);

  @override
  Future<void> update(
    String messageId,
    Map<String, dynamic> Function(Map<String, dynamic>) change,
  ) async => store.update(messageId, change);

  @override
  Future<void> forgetRoom(String roomId) async => store.forgetRoom(roomId);

  @override
  Future<void> forgetBefore(String roomId, DateTime before) async =>
      store.forgetBefore(roomId, before);

  @override
  Future<Map<String, DateTime>> newestByRoom() async => store.newestByRoom();

  @override
  Future<int> count([String? roomId]) async => store.count(roomId);

  // 앱은 팀·방 목록·동기화 자리를 JSON 파일로 둔다(offline_cache.dart).
  @override
  Future<Object?> readValue(String key) async => null;

  @override
  Future<void> writeValue(String key, Object? value) async {}

  @override
  void close() => store.close();

  @override
  Future<void> destroy() async => store.close();
}
