import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';
import 'chat_socket.dart' show MessageSendException;

/// 대기 중인 메시지 하나의 상태 — 보내는 중 · 연결을 기다림(끊겨서 붙으면 다시 보냄) · 실패(서버가 거절 — 다시 보내기·지우기).
enum OutboxState { sending, waiting, failed }

/// 보내기 대기열의 메시지 한 통 — [payload]는 소켓 message:send 본문 그대로(임시 id [clientId] 포함)라 다시 보낼 때 그대로 쓴다.
class OutboxItem {
  final String clientId;
  final String roomId;
  final Map<String, dynamic> payload;

  /// 말풍선에 보일 글(본문·"사진 2장"·파일 이름·"이모티콘").
  final String preview;
  final DateTime createdAt;
  OutboxState state;
  String? error;

  OutboxItem({
    required this.clientId,
    required this.roomId,
    required this.payload,
    required this.preview,
    required this.createdAt,
    this.state = OutboxState.waiting,
    this.error,
  });

  Map<String, dynamic> toJson() => {
    'clientId': clientId,
    'roomId': roomId,
    'payload': payload,
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
      payload: Map<String, dynamic>.from(payload),
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

/// 보낼 메시지의 한 줄 미리보기.
String outboxPreviewOf(Map<String, dynamic> payload) {
  final text = payload['text'];
  final caption = text is String && text.trim().isNotEmpty ? text.trim() : null;
  final attachments = payload['attachments'];
  switch (payload['type']) {
    case 'sticker':
      return '이모티콘';
    case 'image':
      final n = attachments is List ? attachments.length : 1;
      final label = n > 1 ? '사진 $n장' : '사진';
      return caption == null ? label : '$label · $caption';
    case 'file':
      final n = attachments is List ? attachments.length : 1;
      final name = attachments is List && attachments.isNotEmpty
          ? (attachments.first as Map)['fileName'] as String? ?? '파일'
          : payload['fileName'] as String? ?? '파일';
      final label = n > 1 ? '$name 외 ${n - 1}개' : name;
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

/// 보내기 대기열 — 연결이 끊겨 있거나 응답이 없어도 쓴 메시지를 잃지 않는다. 메시지마다 임시 id(clientId)를 붙여 보내고, 연결 문제로
/// 실패하면 기다렸다가 다시 붙을 때([drain]) 차례대로 다시 보낸다(서버는 같은 임시 id면 새로 만들지 않는다 — server/src/sendMessage.js).
/// 서버가 거절한 것(권한·길이 등)은 실패로 남겨 다시 보내기·지우기를 고르게 한다. 앱을 꺼도 남게 이 기기에 사람별로 저장한다.
/// 비밀 대화는 쓰지 않는다(암호화 상태가 보낼 때마다 바뀌어 같은 본문을 나중에 다시 보낼 수 없다 — 예전처럼 바로 실패를 알린다).
class MessageOutbox extends ChangeNotifier {
  MessageOutbox({required this.send});

  /// 본문 하나를 보낸다(연결이 없으면 바로 실패 — ChatSocket.sendPayload의 requireConnection).
  final Future<Message?> Function(Map<String, dynamic> payload) send;

  final List<OutboxItem> _items = [];
  SharedPreferences? _prefs;
  String? _userId;
  bool _draining = false;

  static String prefsKey(String userId) => 'message_outbox_v1.$userId';

  List<OutboxItem> get items => List.unmodifiable(_items);

  /// 이 방에서 기다리는(또는 실패한) 메시지 — 쓴 순서대로.
  List<OutboxItem> forRoom(String roomId) => [
    for (final i in _items)
      if (i.roomId == roomId) i,
  ];

  bool get hasPending => _items.any((i) => i.state != OutboxState.failed);

  /// 로그인 직후 — 이 기기에 남아 있던 메시지를 불러온다(보내기는 연결되면 [drain]).
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

  /// 새 메시지 — 임시 id를 붙여 대기열에 넣고 바로 보내 본다.
  OutboxItem submit({
    required String roomId,
    required Map<String, dynamic> payload,
  }) {
    final clientId = newClientId();
    final item = OutboxItem(
      clientId: clientId,
      roomId: roomId,
      payload: {...payload, 'roomId': roomId, 'clientId': clientId},
      preview: outboxPreviewOf(payload),
      createdAt: DateTime.now(),
    );
    _items.add(item);
    _persist();
    notifyListeners();
    unawaited(drain());
    return item;
  }

  /// 기다리는 메시지를 쓴 순서대로 보낸다 — 연결 문제로 막히면 거기서 멈추고(붙으면 다시 부른다), 서버가 거절한 것은 실패로 두고
  /// 다음으로 넘어간다. 같은 방에서 앞의 것이 기다리는 동안 뒤의 것이 먼저 가지 않는다.
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
          await send(next.payload);
          _items.remove(next);
          _persist();
          notifyListeners();
        } on MessageSendException catch (e) {
          if (!_items.contains(next)) continue; // 그 사이 되돌아온 메시지로 지워졌다.
          if (e.transient) {
            next.state = OutboxState.waiting;
            notifyListeners();
            break;
          }
          next
            ..state = OutboxState.failed
            ..error = e.message;
          _persist();
          notifyListeners();
        } catch (_) {
          // 알 수 없는 오류(소켓 내부 등)는 연결 문제로 보고 다음 연결 때 다시.
          if (!_items.contains(next)) continue;
          next.state = OutboxState.waiting;
          notifyListeners();
          break;
        }
      }
    } finally {
      _draining = false;
    }
  }

  /// 실패한 메시지를 다시 보낸다(같은 임시 id — 혹시 들어갔어도 겹치지 않는다).
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

  /// 보내지 않고 지운다(보내는 중인 것은 못 지운다 — 이미 갔을 수 있다).
  void discard(String clientId) {
    final before = _items.length;
    _items.removeWhere(
      (i) => i.clientId == clientId && i.state != OutboxState.sending,
    );
    if (_items.length == before) return;
    _persist();
    notifyListeners();
  }

  /// 소켓으로 내가 보낸 메시지가 되돌아왔다 — 그 임시 id의 대기 말풍선을 지운다(응답보다 먼저 올 수 있다).
  void handleIncoming(Message m) {
    final id = m.clientId;
    if (id == null) return;
    final before = _items.length;
    _items.removeWhere((i) => i.clientId == id);
    if (_items.length == before) return;
    _persist();
    notifyListeners();
  }

  /// 방에서 나갔거나 방이 없어졌다 — 그 방의 대기 메시지를 버린다.
  void dropRoom(String roomId) {
    final before = _items.length;
    _items.removeWhere(
      (i) => i.roomId == roomId && i.state != OutboxState.sending,
    );
    if (_items.length == before) return;
    _persist();
    notifyListeners();
  }

  void _persist() {
    final prefs = _prefs;
    final userId = _userId;
    if (prefs == null || userId == null) return;
    try {
      if (_items.isEmpty) {
        unawaited(prefs.remove(prefsKey(userId)));
      } else {
        unawaited(
          prefs.setString(
            prefsKey(userId),
            jsonEncode([for (final i in _items) i.toJson()]),
          ),
        );
      }
    } catch (_) {
      // 저장소를 못 쓰면 메모리에만.
    }
  }

  /// 로그아웃 — 메모리에서만 비운다(이 기기 저장분은 같은 사람이 다시 로그인하면 돌아와 보낸다).
  void reset() {
    _items.clear();
    _prefs = null;
    _userId = null;
    notifyListeners();
  }
}
