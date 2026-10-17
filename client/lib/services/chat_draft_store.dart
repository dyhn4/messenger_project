import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/mention.dart';
import '../models/text_format.dart';

/// 입력칸에 쓰다 만 글 한 벌 — 글, 서식 구간, 멘션 구간(RichTextEditingController.snapshot과 같은 모양).
typedef ChatDraft = ({
  String text,
  List<TextFormatRun>? format,
  List<Mention> mentions,
});

/// 대화방마다 쓰다 만 글(임시 저장) — 다른 방에 갔다 와도, 앱을 껐다 켜도 남는다. 이 기기에 사람별로 저장하고, 내 다른 기기와는
/// [DraftSync](draft_sync.dart — 서버 drafts.js)가 맞춘다: 여기서 고친 글은 [onLocalEdit]로 알리고, 다른 기기에서 고친 글은
/// [applyRemote]로 받는다(더 나중에 고친 것이 이긴다). 오래된 것(30일)·너무 많은 것(200개)은 버린다. 비밀 대화의 글은 화면 밖에
/// 평문으로 남기지 않으려고 메모리에만 두고 서버에도 보내지 않는다(앱을 끄면 사라진다).
///
/// 방 목록의 ✏️ 표시는 [has]로 그리고, 어느 방에 글이 생기거나 없어질 때만 [onChanged]를 부른다(글자마다 앱 전체를 다시 그리지
/// 않게). Session이 하나만 들고 있고(session.chatDrafts) 로그인하면 [load], 로그아웃하면 [reset].
class ChatDraftStore {
  ChatDraftStore({this.onChanged});

  /// 어느 방에 임시 저장 글이 생기거나 없어졌을 때.
  final void Function()? onChanged;

  /// 이 기기에서 글을 고쳤을 때(저장하는 글만 — 비밀 대화는 아님). [DraftSync]가 서버로 보낸다. 지웠으면 draft가 null.
  void Function(String roomId, ChatDraft? draft)? onLocalEdit;

  /// 다른 기기에서 고친 글을 받아 바뀐 방 — 열려 있는 입력칸이 손대지 않은 채면 새 글로 바꾼다(chat_input_bar.dart).
  final _remoteChanges = StreamController<String>.broadcast();
  Stream<String> get remoteChanges => _remoteChanges.stream;

  /// 이 기기에서 지운 시각(앱을 켜 둔 동안만) — 그보다 오래된 다른 기기의 글이 되살아나지 않게.
  final Map<String, DateTime> _deletedAt = {};

  static const maxDrafts = 200;
  static const maxAge = Duration(days: 30);
  static const _saveDelay = Duration(milliseconds: 400);

  static String prefsKey(String userId) => 'chat_drafts_v1.$userId';

  final Map<String, ({ChatDraft draft, DateTime savedAt, bool persist})>
  _drafts = {};
  SharedPreferences? _prefs;
  String? _userId;
  Timer? _saveTimer;

  /// 저장해 둔 글을 불러온다 — 로그인 직후 한 번. 이미 메모리에 있는 글(로그인 전에 쓴 것은 없다)은 그대로 둔다.
  Future<void> load(SharedPreferences prefs, String userId) async {
    _prefs = prefs;
    _userId = userId;
    final raw = prefs.getString(prefsKey(userId));
    if (raw == null) return;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return;
      final now = DateTime.now();
      for (final e in map.entries) {
        final v = e.value;
        if (e.key is! String || v is! Map) continue;
        final text = v['text'];
        final savedAt = v['savedAt'];
        if (text is! String || text.trim().isEmpty || savedAt is! num) continue;
        final at = DateTime.fromMillisecondsSinceEpoch(savedAt.toInt());
        if (now.difference(at) > maxAge) continue;
        _drafts.putIfAbsent(
          e.key as String,
          () => (
            draft: (
              text: text,
              format: parseTextFormat(v['format']),
              mentions: parseMentions(v['mentions']),
            ),
            savedAt: at,
            persist: true,
          ),
        );
      }
    } catch (_) {
      // 망가진 값이면 없는 것으로 — 다음 저장 때 덮어쓴다.
    }
    onChanged?.call();
  }

  ChatDraft? get(String roomId) => _drafts[roomId]?.draft;

  /// 이 방의 글을 마지막으로 고친 시각(없으면 null).
  DateTime? savedAt(String roomId) => _drafts[roomId]?.savedAt;

  /// 저장하는(서버와 맞추는) 글들 — 비밀 대화는 빠진다.
  List<({String roomId, ChatDraft draft, DateTime savedAt})>
  get persistedEntries => [
    for (final e in _drafts.entries)
      if (e.value.persist)
        (roomId: e.key, draft: e.value.draft, savedAt: e.value.savedAt),
  ];

  /// 다른 기기에서 고친 글([draft]가 null이면 지움) — [at](서버가 받은 시각)이 이 기기에서 고치거나 지운 시각보다 나중일 때만 바꾼다.
  /// 바꿨으면 true. 비밀 대화의 방(메모리에만 둔 글)은 건드리지 않는다.
  bool applyRemote(String roomId, ChatDraft? draft, DateTime at) {
    final local = _drafts[roomId];
    if (local != null && !local.persist) return false;
    if (local != null && !local.savedAt.isBefore(at)) return false;
    final deleted = _deletedAt[roomId];
    if (local == null && deleted != null && !deleted.isBefore(at)) return false;
    final empty = draft == null || draft.text.trim().isEmpty;
    if (empty) {
      if (local == null) return false;
      _drafts.remove(roomId);
      _deletedAt[roomId] = at;
    } else {
      if (local != null &&
          local.draft.text == draft.text &&
          _sameFormat(local.draft, draft)) {
        _drafts[roomId] = (draft: local.draft, savedAt: at, persist: true);
        return false;
      }
      _drafts[roomId] = (draft: draft, savedAt: at, persist: true);
    }
    _notifyLater();
    _scheduleSave();
    _remoteChanges.add(roomId);
    return true;
  }

  /// 이 방에 쓰다 만 글이 있는지(방 목록의 ✏️).
  bool has(String roomId) => _drafts.containsKey(roomId);

  /// 이 방의 글을 바꾼다 — [draft]가 null이거나 비었으면 지운다. [persist]가 false면(비밀 대화) 메모리에만 둔다.
  void put(String roomId, ChatDraft? draft, {bool persist = true}) {
    final had = _drafts.containsKey(roomId);
    final empty = draft == null || draft.text.trim().isEmpty;
    if (empty) {
      if (!had) return;
      final wasPersisted = _drafts[roomId]!.persist;
      _drafts.remove(roomId);
      if (wasPersisted) {
        _deletedAt[roomId] = DateTime.now();
        onLocalEdit?.call(roomId, null);
      }
    } else {
      final old = _drafts[roomId];
      if (old != null &&
          old.draft.text == draft.text &&
          old.persist == persist &&
          _sameFormat(old.draft, draft)) {
        return;
      }
      _drafts[roomId] = (
        draft: draft,
        savedAt: DateTime.now(),
        persist: persist,
      );
      if (persist) onLocalEdit?.call(roomId, draft);
    }
    if (had != _drafts.containsKey(roomId)) _notifyLater();
    _scheduleSave();
  }

  /// [onChanged]는 한 박자 뒤에 — 입력칸이 사라지면서(dispose) 맡긴 글로 앱 전체를 다시 그리라고 하면, 화면 트리가 잠긴 때라
  /// 오류가 난다. 같은 순간 여러 방이 바뀌어도 한 번만 부른다.
  void _notifyLater() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      onChanged?.call();
    });
  }

  bool _notifyScheduled = false;

  static bool _sameFormat(ChatDraft a, ChatDraft b) =>
      jsonEncode(textFormatToJson(a.format)) ==
          jsonEncode(textFormatToJson(b.format)) &&
      jsonEncode(mentionsToJson(a.mentions)) ==
          jsonEncode(mentionsToJson(b.mentions));

  void _scheduleSave() {
    if (_prefs == null || _userId == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, () => unawaited(flush()));
  }

  /// 기다리지 않고 지금 저장한다(앱이 뒤로 갈 때 등).
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final prefs = _prefs;
    final userId = _userId;
    if (prefs == null || userId == null) return;
    final kept = [
      for (final e in _drafts.entries)
        if (e.value.persist) e,
    ]..sort((a, b) => b.value.savedAt.compareTo(a.value.savedAt));
    final map = {
      for (final e in kept.take(maxDrafts))
        e.key: {
          'text': e.value.draft.text,
          'format': ?textFormatToJson(e.value.draft.format),
          'mentions': ?mentionsToJson(e.value.draft.mentions),
          'savedAt': e.value.savedAt.millisecondsSinceEpoch,
        },
    };
    try {
      if (map.isEmpty) {
        await prefs.remove(prefsKey(userId));
      } else {
        await prefs.setString(prefsKey(userId), jsonEncode(map));
      }
    } catch (_) {
      // 저장소를 못 쓰면(웹 비공개 창 등) 메모리에만 남는다.
    }
  }

  /// 로그아웃 — 메모리에서만 비운다(저장해 둔 글은 같은 사람이 다시 로그인하면 돌아온다). 늦게 남은 저장은 먼저 마친다.
  Future<void> reset() async {
    if (_saveTimer != null) await flush();
    _drafts.clear();
    _deletedAt.clear();
    _prefs = null;
    _userId = null;
    onChanged?.call();
  }
}
