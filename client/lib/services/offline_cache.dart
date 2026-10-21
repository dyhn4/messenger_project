import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'message_db.dart';
import 'message_db_io.dart' if (dart.library.js_interop) 'message_db_web.dart';

/// 서버에서 받은 메시지 페이지 하나(서버가 준 JSON 그대로) — [before]보다 먼저 쓴 것 중 최근 [limit]통(없으면 방의 최근 것).
typedef RawMessagePageFetcher =
    Future<List<Map<String, dynamic>>> Function(DateTime? before, int limit);

/// 오프라인 보기용 저장소 — 서버에서 받은 팀 목록·방 목록(팀마다)은 JSON 파일로, **메시지는 이 기기의 메시지 DB**(message_db.dart —
/// 앱은 SQLite local_message_store.dart, 웹은 IndexedDB message_db_web.dart — 받은 페이지·실시간 메시지·수정·공감·삭제를 모두 쌓아
/// 방마다 최근 5000통까지)에 서버가 준 모양(JSON) 그대로 둔다. 연결이 끊겼거나 서버에 닿지 않을 때 이걸로 목록과 대화(방을 열면 최근
/// [messagesPerRoom]개, 위로 넘기면 그보다 오래된 기록 — [olderMessages])를 보여 주고, 찾기도 여기서 한다([searchMessages]). 받은
/// 그대로 두었다가 그대로 다시 읽으므로(fromJson) 모델을 따로 저장하는 코드가 없다.
///
/// 끊긴 동안·앱이 꺼져 있던 동안 온 메시지는 DB에 없어 중간이 빈다 — 끊길 때(그리고 DB를 열 때) 방마다 "여기까지는 빠짐없이 있다"는
/// 자리를 적어 두고([markSyncPoints]), 연결되면 Session이 그 뒤로 활동이 있던 방만 최근 페이지부터 거꾸로 받아 그 자리까지 메운다
/// ([fillGap]).
///
/// 비밀 대화는 넣지 않는다(부르는 쪽이 거른다 — 평문이 화면 밖에 남으면 안 된다). 서버·사람마다 폴더(웹은 IndexedDB DB)를 나누고,
/// 로그아웃하면 그 사람의 것을 지운다(공용 PC). 웹은 폴더가 없어 팀·방 목록도 IndexedDB에 둔다. 쓰기는 잠깐 모았다가(0.5초) 한 번에.
class OfflineCache {
  OfflineCache({
    Future<Directory?> Function()? baseDir,
    Future<MessageDb?> Function(String scope, Directory? dir)? openDb,
  }) : _baseDir = baseDir ?? _defaultBaseDir,
       _openDb = openDb ?? openMessageDb;

  static const messagesPerRoom = 50;
  static const _writeDelay = Duration(milliseconds: 500);

  /// 빠진 구간을 메울 때 한 번에 받는 수와, 한 방에서 받을 수 있는 최대(방마다 남기는 수 — 그보다 많이 빠졌으면 이어 붙일 수 없다).
  static const syncPageSize = 100;
  static const syncMaxMessages = messageDbPerRoomMax;

  static const _syncPointsName = 'sync_points';

  final Future<Directory?> Function() _baseDir;
  final Future<MessageDb?> Function(String scope, Directory? dir) _openDb;
  Directory? _dir;
  String? _scope;
  MessageDb? _db;

  /// 메시지 DB(못 열었거나 저장하지 않으면 null).
  MessageDb? get db => _db;
  final Map<String, Object?> _memory = {};
  final Map<String, Timer> _pending = {};

  static Future<Directory?> _defaultBaseDir() async {
    if (kIsWeb) return null;
    try {
      return Directory(
        '${(await getApplicationSupportDirectory()).path}/offline_cache',
      );
    } catch (_) {
      return null;
    }
  }

  /// 파일 이름에 쓸 수 있게(서버 주소·방 id) — 글자·숫자·-_ 말고는 _로.
  static String safeName(String raw) =>
      raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// 로그인한 서버·사람으로 폴더(웹은 IndexedDB DB)를 정한다. 같은 값이면 그대로.
  Future<void> configure(String serverUrl, String userId) async {
    final scope = '${safeName(serverUrl)}/${safeName(userId)}';
    if (scope == _scope && (_dir != null || _db != null)) return;
    _scope = scope;
    _memory.clear();
    _db?.close();
    _db = null;
    final base = await _baseDir();
    _dir = base == null ? null : Directory('${base.path}/$scope');
    _db = await _openDb(scope, _dir);
  }

  bool get enabled => _dir != null || _db != null;

  File? _file(String name) {
    final dir = _dir;
    return dir == null ? null : File('${dir.path}/${safeName(name)}.json');
  }

  Future<Object?> read(String name) async {
    if (_memory.containsKey(name)) return _memory[name];
    final file = _file(name);
    if (file == null) {
      // 웹 — 폴더가 없어 메시지 DB의 따로 둘 값으로.
      final value = await _db?.readValue(name);
      if (value != null) _memory[name] = value;
      return value;
    }
    try {
      if (!await file.exists()) return null;
      final value = jsonDecode(await file.readAsString());
      _memory[name] = value;
      return value;
    } catch (_) {
      return null; // 망가졌으면 없는 것으로(다음에 받으면 덮어쓴다).
    }
  }

  /// [value]로 바꾼다(쓰기는 잠깐 모아서).
  void write(String name, Object? value) {
    if (!enabled) return;
    _memory[name] = value;
    _pending[name]?.cancel();
    _pending[name] = Timer(_writeDelay, () => unawaited(_flushOne(name)));
  }

  Future<void> _flushOne(String name) async {
    _pending.remove(name)?.cancel();
    final file = _file(name);
    if (file == null) {
      await _db?.writeValue(name, _memory[name]);
      return;
    }
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(_memory[name]), flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // 디스크를 못 쓰면(가득 참 등) 메모리에만 — 오프라인 보기는 부가 기능이다.
    }
  }

  /// 기다리던 쓰기를 지금(앱이 뒤로 갈 때·시험).
  Future<void> flush() async {
    for (final name in _pending.keys.toList()) {
      await _flushOne(name);
    }
  }

  // ── 모양별 ──

  static String roomsName(String teamId) => 'rooms_$teamId';
  static String messagesName(String roomId) => 'messages_$roomId';

  Future<List<Map<String, dynamic>>> _list(String name) async {
    final v = await read(name);
    if (v is! List) return const [];
    return [
      for (final e in v)
        if (e is Map) Map<String, dynamic>.from(e),
    ];
  }

  Future<List<Map<String, dynamic>>> teams() => _list('teams');
  Future<List<Map<String, dynamic>>> rooms(String teamId) =>
      _list(roomsName(teamId));

  /// 방의 가장 최근 메시지 [messagesPerRoom]개(오래된 것부터).
  Future<List<Map<String, dynamic>>> messages(String roomId) async =>
      await _db?.latest(roomId, limit: messagesPerRoom) ?? const [];

  /// [before]보다 오래된 메시지 [limit]개(오래된 것부터) — 오프라인일 때 위로 넘겨 보기.
  Future<List<Map<String, dynamic>>> olderMessages(
    String roomId,
    DateTime before, {
    int limit = messagesPerRoom,
  }) async => await _db?.older(roomId, before, limit: limit) ?? const [];

  /// 이 기기에 저장된 메시지에서 찾기(새것부터) — [roomIds]를 주면 그 방들에서만.
  Future<List<Map<String, dynamic>>> searchMessages(
    String query, {
    Iterable<String>? roomIds,
    int limit = 100,
  }) async =>
      await _db?.search(query, roomIds: roomIds, limit: limit) ?? const [];

  void saveTeams(List<Object?> raw) => write('teams', raw);
  void saveRooms(String teamId, List<Object?> raw) =>
      write(roomsName(teamId), raw);

  /// 서버에서 받은 메시지 페이지(최근 페이지든 더 오래된 페이지든)를 DB에 넣는다(같은 id면 바꾼다).
  Future<void> saveMessages(String roomId, List<Object?> raw) async {
    await _db?.upsertAll(roomId, [
      for (final m in raw)
        if (m is Map) Map<String, dynamic>.from(m),
    ]);
  }

  /// 실시간으로 받은 메시지 하나를 넣는다(같은 id면 바꾼다 — 수정된 메시지도).
  Future<void> appendMessage(String roomId, Map<String, dynamic> raw) async {
    await _db?.upsertAll(roomId, [raw]);
  }

  /// 저장된 메시지 하나를 고친다(공감·삭제 등 — [change]가 고친 JSON을 돌려준다). 없으면 그대로.
  void updateMessage(
    String messageId,
    Map<String, dynamic> Function(Map<String, dynamic> raw) change,
  ) {
    final db = _db;
    if (db != null) unawaited(db.update(messageId, change));
  }

  /// 그 방의 저장분을 지운다(방에서 나감·비밀 대화로 바뀜 등).
  Future<void> forgetRoom(String roomId) async {
    await _db?.forgetRoom(roomId);
    await clearSyncPoint(roomId);
    final name = messagesName(roomId);
    _pending.remove(name)?.cancel();
    _memory.remove(name);
    try {
      await _file(name)?.delete();
    } catch (_) {}
  }

  // ── 빠진 구간 메우기 ──

  /// 방마다 "여기까지는 빠짐없이 저장돼 있다"는 시각(그 방에 저장된 가장 최근 메시지 — 서버 시각)을 적어 둔다. 끊길 때와 DB를 열 때
  /// 부른다 — 그 뒤로 온 것은 끊긴 동안 놓쳤을 수 있다. 이미 적힌 방(아직 다 메우지 못함)은 더 이른 쪽을 남긴다.
  Future<void> markSyncPoints() async {
    final db = _db;
    if (db == null) return;
    final newest = await db.newestByRoom();
    if (newest.isEmpty) return;
    final points = await syncPoints();
    var changed = false;
    for (final MapEntry(key: roomId, value: at) in newest.entries) {
      final known = points[roomId];
      if (known == null || at.isBefore(known)) {
        points[roomId] = at;
        changed = true;
      }
    }
    if (changed) _writeSyncPoints(points);
  }

  /// 아직 메우지 못한 방과 그 자리.
  Future<Map<String, DateTime>> syncPoints() async {
    final v = await read(_syncPointsName);
    if (v is! Map) return {};
    return {
      for (final e in v.entries)
        if (e.key is String && e.value is num)
          e.key as String: DateTime.fromMillisecondsSinceEpoch(
            (e.value as num).toInt(),
          ),
    };
  }

  void _writeSyncPoints(Map<String, DateTime> points) => write(
    _syncPointsName,
    points.isEmpty
        ? null
        : {
            for (final e in points.entries)
              e.key: e.value.millisecondsSinceEpoch,
          },
  );

  /// 그 방은 다 메웠다(또는 더 메울 수 없다).
  Future<void> clearSyncPoint(String roomId) async {
    final points = await syncPoints();
    if (points.remove(roomId) != null) _writeSyncPoints(points);
  }

  /// 한 방의 빠진 구간을 메운다 — [fetch]로 최근 페이지부터 거꾸로([syncPageSize]개씩) 받아 DB에 넣다가, [since](이미 빠짐없이 있던
  /// 자리) 이하에 닿거나 방의 처음에 닿으면 끝. [syncMaxMessages]를 넘게 받아도 닿지 못하면 그보다 오래된 옛 저장분을 지운다(이어지지
  /// 않는 기록이 오프라인 보기에 끼어 중간이 빈 채로 보이지 않게 — 방마다 남기는 수를 어차피 넘는다). 받은 메시지 수. 연결 오류는
  /// 그대로 나간다(자리는 남아 다음 연결 때 이어서 한다 — 받은 만큼은 쌓였다).
  Future<int> fillGap(
    String roomId,
    DateTime since,
    RawMessagePageFetcher fetch, {
    int pageSize = syncPageSize,
    int maxMessages = syncMaxMessages,
  }) async {
    final db = _db;
    if (db == null) return 0;
    final sinceMs = since.millisecondsSinceEpoch;
    DateTime? before;
    var fetched = 0;
    while (true) {
      final page = await fetch(before, pageSize);
      await db.upsertAll(roomId, page);
      // 창 밖 부모(옛 메시지에 새로 달린 댓글의 부모 — outOfWindow)는 페이지 커서·끝 판단에서 뺀다(room_chat_controller.dart와 같다).
      final window = [
        for (final m in page)
          if (m['outOfWindow'] != true) m,
      ];
      fetched += window.length;
      if (window.length < pageSize) return fetched; // 방의 처음까지 받았다.
      var oldest = messageCreatedAtOf(window.first);
      for (final m in window) {
        final at = messageCreatedAtOf(m);
        if (at < oldest) oldest = at;
      }
      if (oldest <= sinceMs) return fetched; // 있던 구간에 닿았다.
      if (fetched >= maxMessages) {
        await db.forgetBefore(
          roomId,
          DateTime.fromMillisecondsSinceEpoch(oldest),
        );
        return fetched;
      }
      before = DateTime.fromMillisecondsSinceEpoch(oldest);
    }
  }

  /// 메시지 DB를 닫는다(지우지 않음 — 앱을 끄거나 시험이 끝날 때).
  void close() {
    _db?.close();
    _db = null;
  }

  /// 로그아웃 — 이 사람의 저장분을 모두 지운다(공용 PC에 대화가 남지 않게).
  Future<void> clear() async {
    for (final t in _pending.values) {
      t.cancel();
    }
    _pending.clear();
    _memory.clear();
    final db = _db;
    _db = null;
    await db?.destroy(); // 웹은 IndexedDB DB째 지운다(앱은 아래에서 폴더째).
    final dir = _dir;
    _dir = null;
    _scope = null;
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // 통째로 못 지우면(Windows에서 다른 곳이 DB를 아직 쥐고 있음 등) 지울 수 있는 파일은 하나씩이라도 — 목록·메시지가 남지 않게.
      try {
        await for (final e in dir.list(recursive: true)) {
          if (e is File) await e.delete().catchError((_) => e);
        }
      } catch (_) {}
    }
  }
}
