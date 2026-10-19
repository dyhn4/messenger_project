import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'local_message_store.dart'
    if (dart.library.js_interop) 'local_message_store_stub.dart';

/// 오프라인 보기용 저장소 — 서버에서 받은 팀 목록·방 목록(팀마다)은 JSON 파일로, **메시지는 이 기기의 SQLite DB**(local_message_store.dart
/// — 받은 페이지·실시간 메시지·수정·공감·삭제를 모두 쌓아 방마다 최근 5000통까지)에 서버가 준 모양(JSON) 그대로 둔다. 연결이 끊겼거나
/// 서버에 닿지 않을 때 이걸로 목록과 대화(방을 열면 최근 [messagesPerRoom]개, 위로 넘기면 그보다 오래된 기록 — [olderMessages])를
/// 보여 주고, 찾기도 여기서 한다([searchMessages]). 받은 그대로 두었다가 그대로 다시 읽으므로(fromJson) 모델을 따로 저장하는 코드가 없다.
///
/// 비밀 대화는 넣지 않는다(부르는 쪽이 거른다 — 평문이 화면 밖에 남으면 안 된다). 서버·사람마다 폴더를 나누고, 로그아웃하면 그 사람의
/// 것을 지운다(공용 PC). 웹은 쓰지 않는다(파일이 없다 — 늘 서버에서 받는다). 쓰기는 잠깐 모았다가(0.5초) 파일마다 한 번에.
class OfflineCache {
  OfflineCache({Future<Directory?> Function()? baseDir})
    : _baseDir = baseDir ?? _defaultBaseDir;

  static const messagesPerRoom = 50;
  static const _writeDelay = Duration(milliseconds: 500);

  final Future<Directory?> Function() _baseDir;
  Directory? _dir;
  String? _scope;
  LocalMessageStore? _store;

  /// 메시지 DB(못 열었거나 웹이면 null).
  LocalMessageStore? get store => _store;
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

  /// 로그인한 서버·사람으로 폴더를 정한다. 같은 값이면 그대로.
  Future<void> configure(String serverUrl, String userId) async {
    final scope = '${safeName(serverUrl)}/${safeName(userId)}';
    if (scope == _scope && _dir != null) return;
    _scope = scope;
    _memory.clear();
    _store?.close();
    _store = null;
    final base = await _baseDir();
    _dir = base == null ? null : Directory('${base.path}/$scope');
    if (_dir != null) {
      _store = LocalMessageStore.open('${_dir!.path}/messages.sqlite');
    }
  }

  bool get enabled => _dir != null;

  File? _file(String name) {
    final dir = _dir;
    return dir == null ? null : File('${dir.path}/${safeName(name)}.json');
  }

  Future<Object?> read(String name) async {
    if (_memory.containsKey(name)) return _memory[name];
    final file = _file(name);
    if (file == null) return null;
    try {
      if (!await file.exists()) return null;
      final value = jsonDecode(await file.readAsString());
      _memory[name] = value;
      return value;
    } catch (_) {
      return null; // 망가졌으면 없는 것으로(다음에 받으면 덮어쓴다).
    }
  }

  /// [value]로 바꾼다(파일 쓰기는 잠깐 모아서).
  void write(String name, Object? value) {
    if (_dir == null) return;
    _memory[name] = value;
    _pending[name]?.cancel();
    _pending[name] = Timer(_writeDelay, () => unawaited(_flushOne(name)));
  }

  Future<void> _flushOne(String name) async {
    _pending.remove(name)?.cancel();
    final file = _file(name);
    if (file == null) return;
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
      _store?.latest(roomId, limit: messagesPerRoom) ?? const [];

  /// [before]보다 오래된 메시지 [limit]개(오래된 것부터) — 오프라인일 때 위로 넘겨 보기.
  Future<List<Map<String, dynamic>>> olderMessages(
    String roomId,
    DateTime before, {
    int limit = messagesPerRoom,
  }) async => _store?.older(roomId, before, limit: limit) ?? const [];

  /// 이 기기에 저장된 메시지에서 찾기(새것부터) — [roomIds]를 주면 그 방들에서만.
  Future<List<Map<String, dynamic>>> searchMessages(
    String query, {
    Iterable<String>? roomIds,
    int limit = 100,
  }) async => _store?.search(query, roomIds: roomIds, limit: limit) ?? const [];

  void saveTeams(List<Object?> raw) => write('teams', raw);
  void saveRooms(String teamId, List<Object?> raw) =>
      write(roomsName(teamId), raw);

  /// 서버에서 받은 메시지 페이지(최근 페이지든 더 오래된 페이지든)를 DB에 넣는다(같은 id면 바꾼다).
  void saveMessages(String roomId, List<Object?> raw) {
    _store?.upsertAll(roomId, [
      for (final m in raw)
        if (m is Map) Map<String, dynamic>.from(m),
    ]);
  }

  /// 실시간으로 받은 메시지 하나를 넣는다(같은 id면 바꾼다 — 수정된 메시지도).
  Future<void> appendMessage(String roomId, Map<String, dynamic> raw) async {
    _store?.upsertAll(roomId, [raw]);
  }

  /// 저장된 메시지 하나를 고친다(공감·삭제 등 — [change]가 고친 JSON을 돌려준다). 없으면 그대로.
  void updateMessage(
    String messageId,
    Map<String, dynamic> Function(Map<String, dynamic> raw) change,
  ) => _store?.update(messageId, change);

  /// 그 방의 저장분을 지운다(방에서 나감·비밀 대화로 바뀜 등).
  Future<void> forgetRoom(String roomId) async {
    _store?.forgetRoom(roomId);
    final name = messagesName(roomId);
    _pending.remove(name)?.cancel();
    _memory.remove(name);
    try {
      await _file(name)?.delete();
    } catch (_) {}
  }

  /// 메시지 DB를 닫는다(지우지 않음 — 앱을 끄거나 시험이 끝날 때).
  void close() {
    _store?.close();
    _store = null;
  }

  /// 로그아웃 — 이 사람의 저장분을 모두 지운다(공용 PC에 대화가 남지 않게).
  Future<void> clear() async {
    for (final t in _pending.values) {
      t.cancel();
    }
    _pending.clear();
    _memory.clear();
    _store?.close();
    _store = null;
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
