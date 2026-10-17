import 'dart:async';

import '../models/mention.dart';
import '../models/text_format.dart';
import 'chat_draft_store.dart';

/// 임시 저장을 내 다른 기기와 맞춘다(서버 drafts.js) — 이 기기에서 고친 글은 잠깐 멈추면(1.5초) 서버로 보내고, 로그인·다시 연결될 때
/// 서버의 글을 받아 더 나중에 고친 쪽으로 맞추며(지운 것도 시각과 함께 온다), 다른 기기가 고치면 소켓 `draft:changed`로 받는다.
/// 보내지 못한 방은 기억해 뒀다가 다시 연결될 때 보낸다. 비밀 대화의 글은 [ChatDraftStore]가 알리지 않아 여기 오지 않는다.
class DraftSync {
  DraftSync({
    required this.store,
    required this.push,
    required this.fetchAll,
    required this.deviceId,
    this.delay = const Duration(milliseconds: 1500),
  }) {
    store.onLocalEdit = noteLocal;
  }

  final ChatDraftStore store;

  /// 서버로 보내기 — [draft]가 null이면 지우기. 서버가 받은 시각(ms)을 돌려준다.
  final Future<int?> Function(String roomId, ChatDraft? draft, String? deviceId)
  push;

  /// 서버의 내 임시 저장 전부 — `[{ roomId, text(지웠으면 null), format, mentions, updatedAt }]`.
  final Future<List<Map<String, dynamic>>> Function() fetchAll;

  /// 이 기기 id — 내가 보낸 변경이 소켓으로 되돌아오면 알아보고 무시한다.
  final String? Function() deviceId;
  final Duration delay;

  final _timers = <String, Timer>{};

  /// 서버로 아직 못 보낸 방.
  final _dirty = <String>{};
  bool _started = false;

  /// 아직 못 보낸 방이 있는지(시험·화면용).
  bool get hasPending => _dirty.isNotEmpty;

  /// 이 기기에서 고쳤다 — 잠깐 멈추면 보낸다.
  void noteLocal(String roomId, ChatDraft? draft) {
    _dirty.add(roomId);
    _timers[roomId]?.cancel();
    _timers[roomId] = Timer(delay, () => unawaited(_flush(roomId)));
  }

  Future<void> _flush(String roomId) async {
    _timers.remove(roomId)?.cancel();
    try {
      await push(roomId, store.get(roomId), deviceId());
      _dirty.remove(roomId);
    } catch (_) {
      // 오프라인 등 — 다시 연결될 때(start) 보낸다.
    }
  }

  /// 로그인 직후·다시 연결됐을 때 — 서버의 글로 맞추고(나중에 고친 쪽), 이 기기에서 더 나중에 고쳤거나 못 보낸 글을 보낸다.
  Future<void> start() async {
    final List<Map<String, dynamic>> remote;
    try {
      remote = await fetchAll();
    } catch (_) {
      return; // 오프라인·예전 서버 — 다음에 다시.
    }
    _started = true;
    final remoteAt = <String, DateTime>{};
    for (final r in remote) {
      final roomId = r['roomId'];
      final at = r['updatedAt'];
      if (roomId is! String || at is! num) continue;
      final when = DateTime.fromMillisecondsSinceEpoch(at.toInt());
      remoteAt[roomId] = when;
      if (_dirty.contains(roomId)) continue; // 이 기기에서 고친 게 아직 안 갔다 — 그게 더 나중이다.
      store.applyRemote(roomId, draftFromJson(r), when);
    }
    for (final e in store.persistedEntries) {
      final at = remoteAt[e.roomId];
      if (at == null || e.savedAt.isAfter(at)) _dirty.add(e.roomId);
    }
    for (final roomId in _dirty.toList()) {
      await _flush(roomId);
    }
  }

  /// 소켓 `draft:changed` — 다른 기기에서 고친 글.
  void handleRemote(Map<String, dynamic> data) {
    if (data['deviceId'] != null && data['deviceId'] == deviceId()) return;
    final roomId = data['roomId'];
    final at = data['updatedAt'];
    if (roomId is! String || at is! num) return;
    if (_dirty.contains(roomId)) return;
    store.applyRemote(
      roomId,
      draftFromJson(data),
      DateTime.fromMillisecondsSinceEpoch(at.toInt()),
    );
  }

  /// 로그아웃 — 기다리던 보내기를 버린다.
  void reset() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _dirty.clear();
    _started = false;
  }

  bool get started => _started;

  /// 서버 모양 → 임시 저장 글(text가 없거나 비었으면 null — 지움).
  static ChatDraft? draftFromJson(Map<String, dynamic> json) {
    final text = json['text'];
    if (text is! String || text.trim().isEmpty) return null;
    return (
      text: text,
      format: parseTextFormat(json['format']),
      mentions: parseMentions(json['mentions']),
    );
  }

  /// 임시 저장 글 → 서버에 보낼 모양.
  static Map<String, dynamic> draftToJson(ChatDraft? draft, String? deviceId) =>
      {
        'text': draft?.text ?? '',
        if (draft != null) 'format': textFormatToJson(draft.format),
        if (draft != null) 'mentions': mentionsToJson(draft.mentions),
        'deviceId': ?deviceId,
      };
}
