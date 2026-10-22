import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'idb_web.dart';
import 'message_db.dart';

/// 웹 앱의 메시지 DB — 브라우저의 IndexedDB에 서버·사람마다 DB 하나([scope]). 웹은 폴더가 없어 [dir]은 쓰지 않는다. IndexedDB를 쓸
/// 수 없으면(사생활 보호 창 등) null — 예전처럼 늘 서버에서 받는다.
Future<MessageDb?> openMessageDb(String scope, Directory? dir) =>
    IndexedDbMessageDb.open(scope);

/// IndexedDB로 만든 [MessageDb] — 앱의 SQLite(local_message_store.dart)와 같은 일을 한다.
///
/// - `messages` 저장소: 열쇠는 서버 메시지 id. 한 칸은 `{ id, roomId, createdAt(ms), body(찾기용 글 — 소문자), deleted(0/1),
///   json(서버가 준 메시지 JSON 문자열) }`. 색인은 방+작성 시각(`room_created` — 최근 것·더 오래된 것), 방(`room`), 작성 시각
///   (`created` — 찾기를 새것부터).
/// - `kv` 저장소: 팀·방 목록과 동기화 자리 같은 따로 둘 값(JSON 문자열 — offline_cache.dart가 앱에서는 파일로 두는 것).
/// - 찾기는 전문 검색 색인이 없어 새것부터 훑으며 찾기용 글에 든 것을 고른다(방마다 최근 5000통까지라 훑을 만하다).
class IndexedDbMessageDb implements MessageDb {
  IndexedDbMessageDb._(this._db, this.name);

  static const _version = 1;
  static const _messages = 'messages';
  static const _kv = 'kv';

  final web.IDBDatabase _db;
  final String name;
  bool _closed = false;

  /// 서버·사람마다 DB 하나 — 이름에 쓸 수 없는 글자는 _로.
  static String dbNameOf(String scope) =>
      'tangotalk_messages_${scope.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}';

  static Future<IndexedDbMessageDb?> open(String scope) async {
    final name = dbNameOf(scope);
    try {
      final db = await idbOpen(name, _version, (db, oldVersion) {
        if (oldVersion < 1) {
          final store = db.createObjectStore(
            _messages,
            web.IDBObjectStoreParameters(keyPath: 'id'.toJS),
          );
          store.createIndex(
            'room_created',
            ['roomId'.toJS, 'createdAt'.toJS].toJS,
          );
          store.createIndex('room', 'roomId'.toJS);
          store.createIndex('created', 'createdAt'.toJS);
          db.createObjectStore(_kv);
        }
      });
      return IndexedDbMessageDb._(db, name);
    } catch (_) {
      return null;
    }
  }

  /// 방 하나의 [from]~[to] 작성 시각 범위(방+시각 색인의 열쇠 범위).
  static web.IDBKeyRange _roomRange(
    String roomId, {
    double from = double.negativeInfinity,
    double to = double.infinity,
    bool toOpen = false,
  }) => web.IDBKeyRange.bound(
    [roomId.toJS, from.toJS].toJS,
    [roomId.toJS, to.toJS].toJS,
    false,
    toOpen,
  );

  static JSObject _record(String fallbackRoomId, Map<String, dynamic> raw) {
    final id = raw['id'] as String;
    final room = raw['roomId'] is String
        ? raw['roomId'] as String
        : fallbackRoomId;
    final deleted = raw['deleted'] == true;
    return {
          'id': id,
          'roomId': room,
          'createdAt': messageCreatedAtOf(raw),
          'body': deleted ? '' : messageSearchTextOf(raw).toLowerCase(),
          'deleted': deleted ? 1 : 0,
          'json': jsonEncode(raw),
        }.jsify()
        as JSObject;
  }

  static String? _field(JSAny? value, String key) {
    if (value == null) return null;
    final v = (value as JSObject)[key];
    return v.isA<JSString>() ? (v as JSString).toDart : null;
  }

  static Map<String, dynamic>? _decode(JSAny? value) {
    final json = _field(value, 'json');
    if (json == null) return null;
    try {
      final m = jsonDecode(json);
      return m is Map ? Map<String, dynamic>.from(m) : null;
    } catch (_) {
      return null;
    }
  }

  web.IDBTransaction _tx(String store, {bool write = false}) =>
      _db.transaction(store.toJS, write ? 'readwrite' : 'readonly');

  /// 방마다 최근 [messageDbPerRoomMax]통만 남긴다 — 같은 트랜잭션 안에서(넣은 뒤 세어 넘친 만큼 오래된 것부터 지움).
  static void _trim(web.IDBObjectStore store, String roomId) {
    final countReq = store.index('room').count(roomId.toJS);
    countReq.onsuccess = ((web.Event _) {
      final n = (countReq.result as JSNumber).toDartInt;
      var extra = n - messageDbPerRoomMax;
      if (extra <= 0) return;
      unawaited(
        idbEachCursor(
          store.index('room_created').openCursor(_roomRange(roomId), 'next'),
          (c) {
            c.delete();
            return --extra > 0;
          },
        ).catchError((_) {}),
      );
    }).toJS;
  }

  @override
  Future<void> upsertAll(String roomId, List<Map<String, dynamic>> raws) async {
    if (_closed) return;
    final rows = [
      for (final raw in raws)
        if (raw['id'] is String && (raw['id'] as String).isNotEmpty) raw,
    ];
    if (rows.isEmpty) return;
    try {
      final tx = _tx(_messages, write: true);
      final store = tx.objectStore(_messages);
      final rooms = <String>{};
      for (final raw in rows) {
        final record = _record(roomId, raw);
        store.put(record);
        rooms.add(_field(record, 'roomId')!);
      }
      for (final r in rooms) {
        _trim(store, r);
      }
      await idbDone(tx);
    } catch (_) {
      // 저장소가 가득 찼거나 막혔으면 넘어간다 — 오프라인 보기는 부가 기능이다.
    }
  }

  Future<List<Map<String, dynamic>>> _collect(
    web.IDBRequest Function(web.IDBObjectStore store) open, {
    required int limit,
    bool Function(JSAny? value)? where,
  }) async {
    if (_closed || limit <= 0) return const [];
    final out = <Map<String, dynamic>>[];
    try {
      final store = _tx(_messages).objectStore(_messages);
      await idbEachCursor(open(store), (c) {
        final value = c.value;
        if (where == null || where(value)) {
          final m = _decode(value);
          if (m != null) out.add(m);
        }
        return out.length < limit;
      });
    } catch (_) {
      return const [];
    }
    return out;
  }

  @override
  Future<List<Map<String, dynamic>>> latest(
    String roomId, {
    int limit = 50,
  }) async => (await _collect(
    (s) => s.index('room_created').openCursor(_roomRange(roomId), 'prev'),
    limit: limit,
  )).reversed.toList();

  @override
  Future<List<Map<String, dynamic>>> older(
    String roomId,
    DateTime before, {
    int limit = 50,
  }) async => (await _collect(
    (s) => s
        .index('room_created')
        .openCursor(
          _roomRange(
            roomId,
            to: before.millisecondsSinceEpoch.toDouble(),
            toOpen: true,
          ),
          'prev',
        ),
    limit: limit,
  )).reversed.toList();

  @override
  Future<List<Map<String, dynamic>>> search(
    String query, {
    Iterable<String>? roomIds,
    int limit = 100,
  }) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final rooms = roomIds?.toSet();
    if (rooms != null && rooms.isEmpty) return const [];
    return _collect(
      (s) => s.index('created').openCursor(null, 'prev'),
      limit: limit,
      where: (value) {
        final v = value as JSObject;
        if ((v['deleted'] as JSNumber?)?.toDartInt == 1) return false;
        if (rooms != null && !rooms.contains(_field(v, 'roomId'))) {
          return false;
        }
        return _field(v, 'body')?.contains(q) ?? false;
      },
    );
  }

  @override
  Future<void> update(
    String messageId,
    Map<String, dynamic> Function(Map<String, dynamic>) change,
  ) async {
    if (_closed) return;
    try {
      final tx = _tx(_messages, write: true);
      final store = tx.objectStore(_messages);
      final req = store.get(messageId.toJS);
      // 읽은 그 자리(같은 이벤트 안)에서 고쳐 쓴다 — 트랜잭션이 닫히기 전에.
      req.onsuccess = ((web.Event _) {
        final current = _decode(req.result);
        if (current == null) return;
        final roomId = _field(req.result, 'roomId') ?? '';
        store.put(_record(roomId, change(current)));
      }).toJS;
      await idbDone(tx);
    } catch (_) {}
  }

  Future<void> _deleteWhere(
    web.IDBRequest Function(web.IDBObjectStore store) open,
  ) async {
    if (_closed) return;
    try {
      final tx = _tx(_messages, write: true);
      unawaited(
        idbEachCursor(open(tx.objectStore(_messages)), (c) {
          c.delete();
          return true;
        }).catchError((_) {}),
      );
      await idbDone(tx);
    } catch (_) {}
  }

  @override
  Future<void> remove(Iterable<String> messageIds) async {
    if (_closed) return;
    final ids = messageIds.toList();
    if (ids.isEmpty) return;
    try {
      final tx = _tx(_messages, write: true);
      final store = tx.objectStore(_messages);
      for (final id in ids) {
        store.delete(id.toJS);
      }
      await idbDone(tx);
    } catch (_) {}
  }

  @override
  Future<void> forgetRoom(String roomId) => _deleteWhere(
    (s) => s.index('room').openCursor(web.IDBKeyRange.only(roomId.toJS)),
  );

  @override
  Future<void> forgetBefore(String roomId, DateTime before) => _deleteWhere(
    (s) => s
        .index('room_created')
        .openCursor(
          _roomRange(
            roomId,
            to: before.millisecondsSinceEpoch.toDouble(),
            toOpen: true,
          ),
        ),
  );

  @override
  Future<Map<String, DateTime>> newestByRoom() async {
    if (_closed) return const {};
    final out = <String, DateTime>{};
    try {
      final store = _tx(_messages).objectStore(_messages);
      // 방 id들(색인에서 한 번씩) → 방마다 가장 최근 한 칸.
      final roomIds = <String>[];
      await idbEachCursor(
        store.index('room').openKeyCursor(null, 'nextunique'),
        (c) {
          final key = c.key;
          if (key.isA<JSString>()) roomIds.add((key as JSString).toDart);
          return true;
        },
      );
      // 한 트랜잭션에서 한꺼번에 연다 — 하나씩 기다리면 그 사이 트랜잭션이 끝나 다음 요청을 못 낸다.
      final store2 = _tx(_messages).objectStore(_messages);
      await Future.wait([
        for (final roomId in roomIds)
          idbEachCursor(
            store2.index('room_created').openCursor(_roomRange(roomId), 'prev'),
            (c) {
              final at =
                  ((c.value as JSObject)['createdAt'] as JSNumber?)?.toDartInt;
              if (at != null) {
                out[roomId] = DateTime.fromMillisecondsSinceEpoch(at);
              }
              return false;
            },
          ),
      ]);
    } catch (_) {}
    return out;
  }

  @override
  Future<int> count([String? roomId]) async {
    if (_closed) return 0;
    try {
      final store = _tx(_messages).objectStore(_messages);
      final result = await idbRequest(
        roomId == null ? store.count() : store.index('room').count(roomId.toJS),
      );
      return (result as JSNumber).toDartInt;
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<Object?> readValue(String key) async {
    if (_closed) return null;
    try {
      final result = await idbRequest(_tx(_kv).objectStore(_kv).get(key.toJS));
      if (result == null || !result.isA<JSString>()) return null;
      return jsonDecode((result as JSString).toDart);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeValue(String key, Object? value) async {
    if (_closed) return;
    try {
      final tx = _tx(_kv, write: true);
      final store = tx.objectStore(_kv);
      if (value == null) {
        store.delete(key.toJS);
      } else {
        store.put(jsonEncode(value).toJS, key.toJS);
      }
      await idbDone(tx);
    } catch (_) {}
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _db.close();
    } catch (_) {}
  }

  @override
  Future<void> destroy() async {
    close();
    await idbDeleteDatabase(name);
  }
}
