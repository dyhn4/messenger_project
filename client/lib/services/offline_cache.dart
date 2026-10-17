import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 오프라인 보기용 저장소 — 서버에서 받은 팀 목록·방 목록(팀마다)·방마다 최근 메시지([messagesPerRoom]개)를 서버가 준 모양(JSON) 그대로
/// 이 기기에 둔다. 연결이 끊겼거나 서버에 닿지 않을 때 이걸로 목록과 대화를 보여 준다(Session·RoomChatController). 받은 그대로 두었다가
/// 그대로 다시 읽으므로(fromJson) 모델을 따로 저장하는 코드가 없다.
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
    final base = await _baseDir();
    _dir = base == null ? null : Directory('${base.path}/$scope');
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
  Future<List<Map<String, dynamic>>> messages(String roomId) =>
      _list(messagesName(roomId));

  void saveTeams(List<Object?> raw) => write('teams', raw);
  void saveRooms(String teamId, List<Object?> raw) =>
      write(roomsName(teamId), raw);

  /// 방의 최근 메시지(서버가 준 최근 페이지)로 바꾼다 — 끝에서 [messagesPerRoom]개.
  void saveMessages(String roomId, List<Object?> raw) {
    final list = raw.length > messagesPerRoom
        ? raw.sublist(raw.length - messagesPerRoom)
        : raw;
    write(messagesName(roomId), list);
  }

  /// 실시간으로 받은 메시지 하나를 끝에 붙인다(같은 id면 바꾼다). 이 방을 한 번도 저장하지 않았으면 그것만으로 시작한다.
  Future<void> appendMessage(String roomId, Map<String, dynamic> raw) async {
    if (_dir == null) return;
    final list = [...await messages(roomId)];
    final id = raw['id'];
    final i = list.indexWhere((m) => m['id'] == id);
    if (i >= 0) {
      list[i] = raw;
    } else {
      list.add(raw);
    }
    saveMessages(roomId, list);
  }

  /// 그 방의 저장분을 지운다(방에서 나감·비밀 대화로 바뀜 등).
  Future<void> forgetRoom(String roomId) async {
    final name = messagesName(roomId);
    _pending.remove(name)?.cancel();
    _memory.remove(name);
    try {
      await _file(name)?.delete();
    } catch (_) {}
  }

  /// 로그아웃 — 이 사람의 저장분을 모두 지운다(공용 PC에 대화가 남지 않게).
  Future<void> clear() async {
    for (final t in _pending.values) {
      t.cancel();
    }
    _pending.clear();
    _memory.clear();
    final dir = _dir;
    _dir = null;
    _scope = null;
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}
