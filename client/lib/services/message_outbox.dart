import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';
import 'chat_socket.dart' show MessageSendException;
import '../l10n/tr.dart';

/// 대기 중인 메시지 하나의 상태 — 보내는 중 · 연결을 기다림(끊겨서 붙으면 다시 보냄) · 실패(서버가 거절 — 다시 보내기·지우기).
enum OutboxState { sending, waiting, failed }

/// 대기열에 든 일의 종류 — 새 메시지, 내 메시지 고치기·지우기, 공감.
abstract final class OutboxKind {
  static const message = 'message';
  static const edit = 'edit';
  static const delete = 'delete';
  static const reaction = 'reaction';
}

/// 아직 서버에 올리지 못한 첨부 하나 — 이 기기에 복사해 둔 파일([path] — Session이 앱 폴더의 outbox_files에 둔다).
/// 연결되면 올리고 메시지에 붙인다.
class OutboxFile {
  final String path;
  final String name;
  final int size;
  final String? mimeType;
  final bool isImage;
  const OutboxFile({
    required this.path,
    required this.name,
    required this.size,
    this.mimeType,
    required this.isImage,
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'size': size,
    'mimeType': ?mimeType,
    'isImage': isImage,
  };

  static OutboxFile? fromJson(Object? json) {
    if (json is! Map) return null;
    final path = json['path'];
    final name = json['name'];
    if (path is! String || name is! String) return null;
    return OutboxFile(
      path: path,
      name: name,
      size: (json['size'] as num?)?.toInt() ?? 0,
      mimeType: json['mimeType'] as String?,
      isImage: json['isImage'] == true,
    );
  }
}

/// 보내기 대기열의 일 한 건 — 새 메시지면 [payload]는 소켓 message:send 본문 그대로(임시 id [clientId] 포함)라 다시 보낼 때 그대로
/// 쓴다. 고치기·지우기·공감은 [payload]에 `messageId`와 바꿀 값. [files]는 아직 올리지 못한 첨부(올리는 대로 [payload]의
/// attachments로 옮긴다). [secret]이면 비밀 대화 — [payload]의 글이 평문이라 이 기기에 저장하지 않고(메모리에만 — 앱을 끄면 사라짐)
/// 보낼 때 암호화한다.
class OutboxItem {
  final String clientId;
  final String roomId;
  final String kind;
  final Map<String, dynamic> payload;
  List<OutboxFile> files;
  final bool secret;

  /// 말풍선에 보일 글(본문·"사진 2장"·파일 이름·"이모티콘"·"메시지 수정" 등).
  final String preview;
  final DateTime createdAt;
  OutboxState state;
  String? error;

  OutboxItem({
    required this.clientId,
    required this.roomId,
    this.kind = OutboxKind.message,
    required this.payload,
    this.files = const [],
    this.secret = false,
    required this.preview,
    required this.createdAt,
    this.state = OutboxState.waiting,
    this.error,
  });

  bool get isMessage => kind == OutboxKind.message;

  /// 고치기·지우기·공감의 대상 메시지.
  String? get targetId => payload['messageId'] as String?;

  Map<String, dynamic> toJson() => {
    'clientId': clientId,
    'roomId': roomId,
    if (kind != OutboxKind.message) 'kind': kind,
    'payload': payload,
    if (files.isNotEmpty) 'files': [for (final f in files) f.toJson()],
    'preview': preview,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'failed': state == OutboxState.failed,
    'error': ?error,
  };

  static OutboxItem? fromJson(Object? json) {
    if (json is! Map) return null;
    final clientId = json['clientId'];
    final roomId = json['roomId'];
    final payload = json['payload'];
    final createdAt = json['createdAt'];
    if (clientId is! String || roomId is! String || payload is! Map) {
      return null;
    }
    return OutboxItem(
      clientId: clientId,
      roomId: roomId,
      kind: json['kind'] as String? ?? OutboxKind.message,
      payload: Map<String, dynamic>.from(payload),
      files: [
        for (final f in json['files'] as List? ?? const [])
          ?OutboxFile.fromJson(f),
      ],
      preview: json['preview'] as String? ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        createdAt is num ? createdAt.toInt() : 0,
      ),
      // 앱을 다시 켜면 보내던 것도 연결을 기다리는 것으로(붙으면 다시 보낸다 — 서버가 임시 id로 겹치지 않게 한다).
      state: json['failed'] == true ? OutboxState.failed : OutboxState.waiting,
      error: json['error'] as String?,
    );
  }
}

/// 보낼 메시지의 한 줄 미리보기 — [files]는 아직 올리지 못한 첨부(사진·파일 수에 더한다).
String outboxPreviewOf(
  Map<String, dynamic> payload, [
  List<OutboxFile> files = const [],
]) {
  final text = payload['text'];
  final caption = text is String && text.trim().isNotEmpty ? text.trim() : null;
  final attachments = payload['attachments'];
  final uploaded = attachments is List ? attachments.length : 0;
  switch (payload['type']) {
    case 'sticker':
      return tr('이모티콘');
    case 'image':
      final n = attachments is List || files.isNotEmpty
          ? uploaded + files.length
          : 1;
      final label = n > 1 ? tr('사진 {n}장', {'n': n}) : tr('사진');
      return caption == null ? label : '$label · $caption';
    case 'file':
      final n = attachments is List || files.isNotEmpty
          ? uploaded + files.length
          : 1;
      final name = attachments is List && attachments.isNotEmpty
          ? (attachments.first as Map)['fileName'] as String? ?? tr('파일')
          : files.isNotEmpty
          ? files.first.name
          : payload['fileName'] as String? ?? tr('파일');
      final label = n > 1
          ? tr('{name} 외 {p0}개', {'name': name, 'p0': n - 1})
          : name;
      return caption == null ? label : '$label · $caption';
    default:
      return caption ?? '';
  }
}

/// 대기열이 쓰는 임시 id — 서버 outboxRules.js(글자·숫자·_- 8~64자).
String newClientId([Random? random]) {
  final r = random ?? Random.secure();
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final rand = List.generate(16, (_) => chars[r.nextInt(chars.length)]).join();
  return 'c${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$rand';
}

/// 보내기 대기열 — 연결이 끊겨 있거나 응답이 없어도 쓴 메시지와 한 일을 잃지 않는다. 메시지마다 임시 id(clientId)를 붙여 보내고, 연결
/// 문제로 실패하면 기다렸다가 다시 붙을 때([drain]) 차례대로 다시 보낸다(서버는 같은 임시 id면 새로 만들지 않는다 — server/src/sendMessage.js).
/// 서버가 거절한 것(권한·길이·수정 가능 시간 등)은 실패로 남겨 다시 보내기·지우기를 고르게 한다. 앱을 꺼도 남게 이 기기에 사람별로
/// 저장한다(비밀 대화의 글은 빼고 — 평문을 디스크에 남기지 않는다).
///
/// 대기열에 드는 일:
/// - 새 메시지 — 글·이모티콘·이미 올린 첨부는 [send]로 바로. 아직 올리지 못한 첨부([OutboxItem.files])가 있거나 비밀 대화면 [deliver]가
///   올리거나 암호화한 뒤 보낸다.
/// - 내 메시지 고치기·지우기, 공감 — [deliver]가 서버에 반영한다(화면에는 먼저 보인다 — 부르는 쪽). 공감은 같은 메시지의 앞 공감을
///   바꿔 끼운다(마지막 것만 보내면 된다).
class MessageOutbox extends ChangeNotifier {
  MessageOutbox({
    required this.send,
    this.deliver,
    this.isTransient,
    this.onDiscarded,
  });

  /// 본문 하나를 보낸다(연결이 없으면 바로 실패 — ChatSocket.sendPayload의 requireConnection).
  final Future<Message?> Function(Map<String, dynamic> payload) send;

  /// [send]로 바로 보낼 수 없는 일(첨부 올리기·비밀 대화 암호화·고치기·지우기·공감)을 한다 — 없으면 그런 일은 넣지 않는다.
  final Future<void> Function(OutboxItem item)? deliver;

  /// [MessageSendException]이 아닌 오류가 연결 문제인지(다시 하면 될 수 있는지) — 없으면 모두 연결 문제로 본다.
  final bool Function(Object error)? isTransient;

  /// 보내지 않고 지웠을 때(실패한 고치기·지우기를 버리면 화면을 서버 것으로 되돌리는 데).
  final void Function(OutboxItem item)? onDiscarded;

  final List<OutboxItem> _items = [];
  SharedPreferences? _prefs;
  String? _userId;
  bool _draining = false;

  static String prefsKey(String userId) => 'message_outbox_v1.$userId';

  List<OutboxItem> get items => List.unmodifiable(_items);

  /// 이 방에서 기다리는(또는 실패한) 일 — 쓴 순서대로.
  List<OutboxItem> forRoom(String roomId) => [
    for (final i in _items)
      if (i.roomId == roomId) i,
  ];

  bool get hasPending => _items.any((i) => i.state != OutboxState.failed);

  /// 이 메시지에 기다리는 고치기·지우기가 있는지(말풍선에 "반영 대기" 표시).
  OutboxItem? pendingActionFor(String messageId) => _items
      .where(
        (i) =>
            !i.isMessage &&
            i.kind != OutboxKind.reaction &&
            i.targetId == messageId,
      )
      .lastOrNull;

  /// 로그인 직후 — 이 기기에 남아 있던 일을 불러온다(보내기는 연결되면 [drain]).
  Future<void> load(SharedPreferences prefs, String userId) async {
    _prefs = prefs;
    _userId = userId;
    final raw = prefs.getString(prefsKey(userId));
    if (raw == null) return;
    try {
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final j in list) {
        final item = OutboxItem.fromJson(j);
        if (item != null && !_items.any((i) => i.clientId == item.clientId)) {
          _items.add(item);
        }
      }
      _items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      notifyListeners();
    } catch (_) {
      // 망가진 값이면 없는 것으로.
    }
  }

  /// 새 메시지 — 임시 id를 붙여 대기열에 넣고 바로 보내 본다. [files]는 아직 올리지 못한 첨부(이 기기에 복사해 둔 것), [secret]이면
  /// 비밀 대화(글은 평문 — 보낼 때 암호화, 저장하지 않음). [clientId]를 주면 그 임시 id로(파일을 그 이름 폴더에 복사해 둔 경우).
  OutboxItem submit({
    required String roomId,
    required Map<String, dynamic> payload,
    List<OutboxFile> files = const [],
    bool secret = false,
    String? clientId,
  }) {
    final id = clientId ?? newClientId();
    final item = OutboxItem(
      clientId: id,
      roomId: roomId,
      payload: {...payload, 'roomId': roomId, 'clientId': id},
      files: [...files],
      secret: secret,
      preview: outboxPreviewOf(payload, files),
      createdAt: DateTime.now(),
    );
    return _add(item);
  }

  /// 내 메시지 고치기·지우기·공감을 넣는다([kind] — [OutboxKind]). [payload]에는 `messageId`와 바꿀 값. 공감은 같은 메시지에 기다리던
  /// 공감을 바꿔 끼운다. [secret]이면 비밀 대화의 고치기(평문 — 저장하지 않음).
  OutboxItem submitAction({
    required String roomId,
    required String kind,
    required Map<String, dynamic> payload,
    required String preview,
    bool secret = false,
  }) {
    if (kind == OutboxKind.reaction) {
      _items.removeWhere(
        (i) =>
            i.kind == OutboxKind.reaction &&
            i.targetId == payload['messageId'] &&
            i.state != OutboxState.sending,
      );
    }
    final item = OutboxItem(
      clientId: newClientId(),
      roomId: roomId,
      kind: kind,
      payload: payload,
      secret: secret,
      preview: preview,
      createdAt: DateTime.now(),
    );
    return _add(item);
  }

  OutboxItem _add(OutboxItem item) {
    _items.add(item);
    _persist();
    notifyListeners();
    unawaited(drain());
    return item;
  }

  /// 일 하나를 한다 — 보통 메시지는 [send], 그 밖은 [deliver].
  Future<void> _perform(OutboxItem item) async {
    if (item.isMessage && item.files.isEmpty && !item.secret) {
      await send(item.payload);
      return;
    }
    final d = deliver;
    if (d == null) {
      throw const MessageSendException('이 일은 대기열로 보낼 수 없습니다.');
    }
    await d(item);
  }

  /// 기다리는 일을 쓴 순서대로 한다 — 연결 문제로 막히면 거기서 멈추고(붙으면 다시 부른다), 서버가 거절한 것은 실패로 두고
  /// 다음으로 넘어간다. 앞의 것이 기다리는 동안 뒤의 것이 먼저 가지 않는다.
  Future<void> drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (true) {
        final next = _items
            .where((i) => i.state == OutboxState.waiting)
            .firstOrNull;
        if (next == null) break;
        next.state = OutboxState.sending;
        notifyListeners();
        try {
          await _perform(next);
          _items.remove(next);
          _persist();
          notifyListeners();
        } on MessageSendException catch (e) {
          if (!_items.contains(next)) continue; // 그 사이 되돌아온 메시지로 지워졌다.
          if (e.transient) {
            next.state = OutboxState.waiting;
            _persist(); // 올린 첨부가 있으면 그만큼 남긴다.
            notifyListeners();
            break;
          }
          _fail(next, e.message);
        } catch (e) {
          if (!_items.contains(next)) continue;
          if (isTransient?.call(e) ?? true) {
            // 연결 문제(알 수 없는 소켓 내부 오류 포함)는 다음 연결 때 다시.
            next.state = OutboxState.waiting;
            _persist();
            notifyListeners();
            break;
          }
          _fail(next, e.toString());
        }
      }
    } finally {
      _draining = false;
    }
  }

  void _fail(OutboxItem item, String message) {
    item
      ..state = OutboxState.failed
      ..error = message;
    _persist();
    notifyListeners();
  }

  /// 일을 하는 동안 [item]을 바꿨다(첨부를 올려 payload로 옮김 등) — 저장해 둔다.
  void updated(OutboxItem item) {
    if (!_items.contains(item)) return;
    _persist();
    notifyListeners();
  }

  /// 실패한 일을 다시 한다(같은 임시 id — 혹시 들어갔어도 겹치지 않는다).
  void retry(String clientId) {
    final item = _items.where((i) => i.clientId == clientId).firstOrNull;
    if (item == null || item.state != OutboxState.failed) return;
    item
      ..state = OutboxState.waiting
      ..error = null;
    _persist();
    notifyListeners();
    unawaited(drain());
  }

  /// 하지 않고 지운다(하는 중인 것은 못 지운다 — 이미 갔을 수 있다).
  void discard(String clientId) {
    final item = _items
        .where((i) => i.clientId == clientId && i.state != OutboxState.sending)
        .firstOrNull;
    if (item == null) return;
    _items.remove(item);
    _persist();
    notifyListeners();
    onDiscarded?.call(item);
  }

  /// 소켓으로 내가 보낸 메시지가 되돌아왔다 — 그 임시 id의 대기 말풍선을 지운다(응답보다 먼저 올 수 있다).
  void handleIncoming(Message m) {
    final id = m.clientId;
    if (id == null) return;
    final gone = _items.where((i) => i.clientId == id).toList();
    if (gone.isEmpty) return;
    _items.removeWhere((i) => i.clientId == id);
    _persist();
    notifyListeners();
    for (final g in gone) {
      if (g.files.isNotEmpty) onDiscarded?.call(g); // 복사해 둔 파일 치우기.
    }
  }

  /// 방에서 나갔거나 방이 없어졌다 — 그 방의 일을 버린다.
  void dropRoom(String roomId) {
    final gone = [
      for (final i in _items)
        if (i.roomId == roomId && i.state != OutboxState.sending) i,
    ];
    if (gone.isEmpty) return;
    _items.removeWhere(gone.contains);
    _persist();
    notifyListeners();
    for (final g in gone) {
      if (g.files.isNotEmpty) onDiscarded?.call(g);
    }
  }

  void _persist() {
    final prefs = _prefs;
    final userId = _userId;
    if (prefs == null || userId == null) return;
    try {
      // 비밀 대화의 글은 평문이라 저장하지 않는다(메모리에만).
      final stored = [
        for (final i in _items)
          if (!i.secret) i,
      ];
      if (stored.isEmpty) {
        unawaited(prefs.remove(prefsKey(userId)));
      } else {
        unawaited(
          prefs.setString(
            prefsKey(userId),
            jsonEncode([for (final i in stored) i.toJson()]),
          ),
        );
      }
    } catch (_) {
      // 저장소를 못 쓰면 메모리에만.
    }
  }

  /// 로그아웃 — 메모리에서만 비운다(이 기기 저장분은 같은 사람이 다시 로그인하면 돌아와 보낸다 — 비밀 대화 것은 사라진다).
  void reset() {
    _items.clear();
    _prefs = null;
    _userId = null;
    notifyListeners();
  }
}

/// 보낼 본문 — 대기열에서 올린 첨부가 하나뿐이면 예전 모양(파일 칸 — fileUrl·fileName·…)으로 바꾼다(서버는 첨부가 하나면 목록이
/// 아니라 메시지의 파일 칸에 저장한다 — sendUploadedAttachment와 같은 모양).
Map<String, dynamic> sendableOutboxPayload(Map<String, dynamic> payload) {
  final attachments = payload['attachments'];
  if (attachments is! List ||
      attachments.length != 1 ||
      payload['fileUrl'] != null) {
    return payload;
  }
  final a = attachments.first;
  if (a is! Map) return payload;
  return {
    for (final e in payload.entries)
      if (e.key != 'attachments') e.key: e.value,
    'type': a['kind'] == 'image' ? 'image' : 'file',
    'fileUrl': a['fileUrl'],
    'fileName': a['fileName'],
    'fileSize': a['fileSize'],
    'mimeType': ?a['mimeType'],
    'thumbnailUrl': ?a['thumbnailUrl'],
  };
}
