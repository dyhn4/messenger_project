import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 토픽 상단 공지 배너의 "숨기기"(X 버튼) 상태 — 사람마다·토픽마다 **이 기기에** 저장한다(서버에는 두지 않는다).
/// "지금 고정된 그 공지 하나"에만 걸려서, 새 공지가 올라와 id가 달라지면 저절로 풀린다(다시 보인다). 그래서
/// 토픽마다 마지막으로 숨긴 공지 id 하나만 들고 있으면 되고 예전 것이 쌓이지 않는다. 여러 기기 동기화는 하지
/// 않는다 — 배너를 어떻게 볼지는 기기별 취향에 가깝고, 서버 표·이벤트를 더할 만큼의 값이 아니라고 봤다(README
/// 참고). (예전에 있던 "접어두기" 값이 같은 키에 남아 있어도 읽을 때 무시한다.)
class AnnouncementViewPrefs {
  static String _key(String? userId, String roomId) =>
      'announcement_view:${userId ?? '-'}:$roomId';

  /// 저장된 숨긴 공지 id — 없거나 읽지 못하면(저장소를 못 쓰는 환경 등) null.
  static Future<String?> loadHiddenId(String? userId, String roomId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(userId, roomId));
      if (raw == null) return null;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return json['hidden'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// 저장한다 — 실패해도(저장소 오류) 화면 동작엔 영향이 없어 조용히 넘긴다.
  static Future<void> saveHiddenId(
    String? userId,
    String roomId,
    String? hiddenId,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _key(userId, roomId);
      if (hiddenId == null) {
        await prefs.remove(key);
        return;
      }
      await prefs.setString(key, jsonEncode({'hidden': hiddenId}));
    } catch (_) {}
  }
}
