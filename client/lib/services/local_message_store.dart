import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'message_db.dart';

/// 이 기기의 메시지 DB(SQLite — package:sqlite3) — 서버에서 받은 메시지를 서버가 준 모양(JSON) 그대로 방마다 쌓아 둔다. 오프라인일 때
/// 방의 최근 메시지([latest])와 그보다 오래된 기록([older]), 찾기([search])를 여기서 한다(offline_cache.dart가 부른다).
///
/// - `messages` 표: id(서버 메시지 id)·방·작성 시각·찾기용 글(본문·게시글 제목·파일 이름)·JSON·지움 표시. 같은 id는 바꿔 쓴다
///   (수정·공감·삭제가 오면 그 메시지의 JSON을 고친다).
/// - `messages_fts`: 찾기용 글의 전문 검색 색인(FTS5 trigram — 한국어도 낱말 중간 글자로 찾는다). 세 글자보다 짧은 말은 LIKE로 찾는다.
/// - 방마다 최근 [perRoomMax]통까지만 남긴다(오래된 것부터 지움).
///
/// 비밀 대화는 넣지 않는다(부르는 쪽이 거른다). 웹은 쓰지 않는다(IndexedDB — message_db_web.dart).
class LocalMessageStore {
  LocalMessageStore._(this._db, this.path);

  /// 방마다 남기는 메시지 수.
  static const perRoomMax = messageDbPerRoomMax;

  final Database _db;
  final String path;
  bool _closed = false;

  /// [path]의 DB를 연다(없으면 만든다). 못 열면 null(오프라인 보기는 부가 기능이다).
  static LocalMessageStore? open(String path) {
    try {
      File(path).parent.createSync(recursive: true);
      final db = sqlite3.open(path);
      db.execute('PRAGMA journal_mode=WAL;');
      db.execute('PRAGMA synchronous=NORMAL;');
      db.execute('''
        CREATE TABLE IF NOT EXISTS messages(
          id TEXT PRIMARY KEY,
          room_id TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          body TEXT NOT NULL DEFAULT '',
          json TEXT NOT NULL,
          deleted INTEGER NOT NULL DEFAULT 0
        );
      ''');
      db.execute(
        'CREATE INDEX IF NOT EXISTS messages_room ON messages(room_id, created_at);',
      );
      db.execute(
        "CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(body, id UNINDEXED, room_id UNINDEXED, tokenize='trigram');",
      );
      return LocalMessageStore._(db, path);
    } catch (_) {
      return null;
    }
  }

  /// 메시지 JSON에서 찾기용 글 — 본문·게시글 제목·첨부 파일 이름(message_db.dart — 웹 DB와 같다).
  static String searchTextOf(Map<String, dynamic> raw) =>
      messageSearchTextOf(raw);

  /// 메시지들을 넣거나 바꾼다(같은 id면 바꿈). 창 밖 부모처럼 방 id가 다른 것은 그 방으로. 넣은 수.
  int upsertAll(String roomId, Iterable<Map<String, dynamic>> raws) {
    if (_closed) return 0;
    var n = 0;
    final touchedRooms = <String>{};
    _db.execute('BEGIN');
    try {
      final upsert = _db.prepare(
        'INSERT INTO messages(id, room_id, created_at, body, json, deleted) VALUES(?,?,?,?,?,?) '
        'ON CONFLICT(id) DO UPDATE SET room_id=excluded.room_id, created_at=excluded.created_at, '
        'body=excluded.body, json=excluded.json, deleted=excluded.deleted',
      );
      final ftsDelete = _db.prepare('DELETE FROM messages_fts WHERE id = ?');
      final ftsInsert = _db.prepare(
        'INSERT INTO messages_fts(body, id, room_id) VALUES(?,?,?)',
      );
      for (final raw in raws) {
        final id = raw['id'];
        if (id is! String || id.isEmpty) continue;
        final room = raw['roomId'] is String ? raw['roomId'] as String : roomId;
        final deleted = raw['deleted'] == true;
        final body = deleted ? '' : searchTextOf(raw);
        upsert.execute([
          id,
          room,
          messageCreatedAtOf(raw),
          body,
          jsonEncode(raw),
          deleted ? 1 : 0,
        ]);
        ftsDelete.execute([id]);
        if (body.isNotEmpty) ftsInsert.execute([body, id, room]);
        touchedRooms.add(room);
        n++;
      }
      upsert.close();
      ftsDelete.close();
      ftsInsert.close();
      for (final room in touchedRooms) {
        _trim(room);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      return 0;
    }
    return n;
  }

  /// 방마다 최근 [perRoomMax]통만 남긴다.
  void _trim(String roomId) {
    final count =
        _db.select('SELECT COUNT(*) AS n FROM messages WHERE room_id = ?', [
              roomId,
            ]).first['n']
            as int;
    if (count <= perRoomMax) return;
    final old = _db.select(
      'SELECT id FROM messages WHERE room_id = ? ORDER BY created_at DESC, rowid DESC LIMIT -1 OFFSET ?',
      [roomId, perRoomMax],
    );
    for (final row in old) {
      _db.execute('DELETE FROM messages WHERE id = ?', [row['id']]);
      _db.execute('DELETE FROM messages_fts WHERE id = ?', [row['id']]);
    }
  }

  List<Map<String, dynamic>> _decode(ResultSet rows) => [
    for (final r in rows)
      if (jsonDecode(r['json'] as String) case final Map m)
        Map<String, dynamic>.from(m),
  ];

  /// 방의 가장 최근 [limit]통(오래된 것부터).
  List<Map<String, dynamic>> latest(String roomId, {int limit = 50}) {
    if (_closed) return const [];
    final rows = _db.select(
      'SELECT json FROM messages WHERE room_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ?',
      [roomId, limit],
    );
    return _decode(rows).reversed.toList();
  }

  /// [before]보다 먼저 쓴 메시지 [limit]통(오래된 것부터) — 오프라인일 때 위로 넘겨 보는 기록.
  List<Map<String, dynamic>> older(
    String roomId,
    DateTime before, {
    int limit = 50,
  }) {
    if (_closed) return const [];
    final rows = _db.select(
      'SELECT json FROM messages WHERE room_id = ? AND created_at < ? ORDER BY created_at DESC, rowid DESC LIMIT ?',
      [roomId, before.millisecondsSinceEpoch, limit],
    );
    return _decode(rows).reversed.toList();
  }

  /// 찾기 — [query]가 든 메시지(새것부터 [limit]통, 지운 메시지 제외). [roomIds]를 주면 그 방들에서만. 세 글자 이상은 전문 검색
  /// 색인(FTS5 trigram), 그보다 짧으면 LIKE.
  List<Map<String, dynamic>> search(
    String query, {
    Iterable<String>? roomIds,
    int limit = 100,
  }) {
    if (_closed) return const [];
    final q = query.trim();
    if (q.isEmpty) return const [];
    final rooms = roomIds?.toList();
    if (rooms != null && rooms.isEmpty) return const [];
    final roomFilter = rooms == null
        ? ''
        : ' AND m.room_id IN (${List.filled(rooms.length, '?').join(',')})';
    final ResultSet rows;
    if (q.runes.length >= 3) {
      rows = _db.select(
        'SELECT m.json FROM messages_fts f JOIN messages m ON m.id = f.id '
        'WHERE messages_fts MATCH ? AND m.deleted = 0$roomFilter '
        'ORDER BY m.created_at DESC LIMIT ?',
        ['"${q.replaceAll('"', '""')}"', ...?rooms, limit],
      );
    } else {
      final like =
          '%${q.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
      rows = _db.select(
        r"SELECT m.json FROM messages m WHERE m.body LIKE ? ESCAPE '\' AND m.deleted = 0"
        '$roomFilter ORDER BY m.created_at DESC LIMIT ?',
        [like, ...?rooms, limit],
      );
    }
    return _decode(rows);
  }

  /// 메시지 하나의 JSON을 고친다(수정·공감 등 — [change]가 고친 JSON을 돌려준다). 없으면 그대로.
  void update(
    String messageId,
    Map<String, dynamic> Function(Map<String, dynamic>) change,
  ) {
    if (_closed) return;
    final rows = _db.select('SELECT room_id, json FROM messages WHERE id = ?', [
      messageId,
    ]);
    if (rows.isEmpty) return;
    final current = jsonDecode(rows.first['json'] as String);
    if (current is! Map) return;
    final next = change(Map<String, dynamic>.from(current));
    upsertAll(rows.first['room_id'] as String, [next]);
  }

  /// 메시지들을 지운다(서버가 완전히 지운 것). 없는 id는 넘어간다.
  void remove(Iterable<String> messageIds) {
    if (_closed) return;
    final ids = messageIds.toList();
    if (ids.isEmpty) return;
    _db.execute('BEGIN');
    try {
      for (final id in ids) {
        _db.execute('DELETE FROM messages WHERE id = ?', [id]);
        _db.execute('DELETE FROM messages_fts WHERE id = ?', [id]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
    }
  }

  /// 그 방의 메시지를 모두 지운다.
  void forgetRoom(String roomId) {
    if (_closed) return;
    _db.execute('DELETE FROM messages WHERE room_id = ?', [roomId]);
    _db.execute('DELETE FROM messages_fts WHERE room_id = ?', [roomId]);
  }

  /// 그 방에서 [before]보다 먼저 쓴 메시지를 지운다(이어지지 않는 옛 저장분 — offline_cache.dart fillGap).
  void forgetBefore(String roomId, DateTime before) {
    if (_closed) return;
    final ms = before.millisecondsSinceEpoch;
    _db.execute(
      'DELETE FROM messages_fts WHERE id IN (SELECT id FROM messages WHERE room_id = ? AND created_at < ?)',
      [roomId, ms],
    );
    _db.execute('DELETE FROM messages WHERE room_id = ? AND created_at < ?', [
      roomId,
      ms,
    ]);
  }

  /// 방마다 저장된 가장 최근 메시지의 작성 시각 — 빠진 구간을 메울 자리(offline_cache.dart markSyncPoints).
  Map<String, DateTime> newestByRoom() {
    if (_closed) return const {};
    final rows = _db.select(
      'SELECT room_id, MAX(created_at) AS t FROM messages GROUP BY room_id',
    );
    return {
      for (final r in rows)
        r['room_id'] as String: DateTime.fromMillisecondsSinceEpoch(
          r['t'] as int,
        ),
    };
  }

  /// 저장된 메시지 수(시험·설정 화면).
  int count([String? roomId]) {
    if (_closed) return 0;
    final rows = roomId == null
        ? _db.select('SELECT COUNT(*) AS n FROM messages')
        : _db.select('SELECT COUNT(*) AS n FROM messages WHERE room_id = ?', [
            roomId,
          ]);
    return rows.first['n'] as int;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _db.close();
    } catch (_) {}
  }
}
