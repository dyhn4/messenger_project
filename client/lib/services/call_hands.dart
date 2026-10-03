import 'dart:convert';

/// 통화 중 상태 공유(손들기)에 쓰는 LiveKit 데이터 채널의 topic.
const callDataTopic = 'call';

/// 내 손 상태를 알리는 데이터 채널 메시지 `{type:'hand', raised: bool}`.
List<int> encodeHandMessage(bool raised) =>
    utf8.encode(jsonEncode({'type': 'hand', 'raised': raised}));

/// 손들기 메시지면 raised 값을, 아니거나 깨진 메시지면 null.
bool? decodeHandMessage(List<int> data) {
  try {
    final json = jsonDecode(utf8.decode(data));
    if (json is Map && json['type'] == 'hand' && json['raised'] is bool) {
      return json['raised'] as bool;
    }
  } catch (_) {}
  return null;
}

/// 누가 손을 들고 있는지 — identity별 든 시각.
class HandRaiseBook {
  final Map<String, DateTime> _raised = {};

  Map<String, DateTime> get raised => Map.unmodifiable(_raised);
  bool isRaised(String id) => _raised.containsKey(id);
  bool get isEmpty => _raised.isEmpty;

  /// 반영하고, "방금 새로 손을 들었으면" true(이미 든 손을 또 알리는 건 false — 토스트 중복 방지).
  bool apply(String id, bool raised, DateTime now) {
    if (raised) {
      if (_raised.containsKey(id)) return false;
      _raised[id] = now;
      return true;
    }
    _raised.remove(id);
    return false;
  }

  void remove(String id) => _raised.remove(id);
  void clear() => _raised.clear();
}
