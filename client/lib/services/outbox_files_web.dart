import 'dart:js_interop';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:web/web.dart' as web;

import 'idb_web.dart';
import 'message_outbox.dart';

/// 웹 — 올리지 못한 첨부를 브라우저의 IndexedDB(`tangotalk_outbox_files` DB의 `files` 저장소)에 바이트로 담는다(새로 고쳐도 남는다).
/// 경로는 `idb:<임시 id>/<번호>` — 열쇠로 쓴다.
const _dbName = 'tangotalk_outbox_files';
const _store = 'files';
const _prefix = 'idb:';

web.IDBDatabase? _db;

Future<web.IDBDatabase> _open() async =>
    _db ??= await idbOpen(_dbName, 1, (db, oldVersion) {
      if (oldVersion < 1) db.createObjectStore(_store);
    });

String _keyOf(String path) =>
    path.startsWith(_prefix) ? path.substring(_prefix.length) : path;

Future<List<OutboxFile>?> stashFilesForOutbox(
  String clientId,
  List<({List<int> bytes, String name, String? mimeType, bool isImage})> files,
) async {
  try {
    final db = await _open();
    final tx = db.transaction(_store.toJS, 'readwrite');
    final store = tx.objectStore(_store);
    final out = <OutboxFile>[];
    for (final (i, f) in files.indexed) {
      final key = '$clientId/$i';
      final bytes = f.bytes is Uint8List
          ? f.bytes as Uint8List
          : Uint8List.fromList(f.bytes);
      store.put(bytes.toJS, key.toJS);
      out.add(
        OutboxFile(
          path: '$_prefix$key',
          name: f.name,
          size: bytes.length,
          mimeType: f.mimeType,
          isImage: f.isImage,
        ),
      );
    }
    await idbDone(tx);
    return out;
  } catch (_) {
    return null; // IndexedDB를 쓸 수 없거나(사생활 보호 창) 가득 찼다.
  }
}

Future<Uint8List?> _read(String path) async {
  try {
    final db = await _open();
    final result = await idbRequest(
      db.transaction(_store.toJS).objectStore(_store).get(_keyOf(path).toJS),
    );
    if (result == null || !result.isA<JSUint8Array>()) return null;
    return (result as JSUint8Array).toDart;
  } catch (_) {
    return null;
  }
}

Future<bool> outboxFileExists(String path) async => await _read(path) != null;

Future<XFile?> openOutboxFile(OutboxFile f) async {
  final bytes = await _read(f.path);
  return bytes == null
      ? null
      : XFile.fromData(bytes, name: f.name, mimeType: f.mimeType);
}

Future<void> deleteOutboxFile(String path) async {
  try {
    final db = await _open();
    final tx = db.transaction(_store.toJS, 'readwrite');
    tx.objectStore(_store).delete(_keyOf(path).toJS);
    await idbDone(tx);
  } catch (_) {}
}

Future<void> deleteOutboxFiles(String clientId) async {
  try {
    final db = await _open();
    final tx = db.transaction(_store.toJS, 'readwrite');
    // `<임시 id>/` 로 시작하는 열쇠 모두('/' 다음 글자 '0'까지의 범위).
    tx
        .objectStore(_store)
        .delete(
          web.IDBKeyRange.bound(
            '$clientId/'.toJS,
            '${clientId}0'.toJS,
            false,
            true,
          ),
        );
    await idbDone(tx);
  } catch (_) {}
}
