import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 토픽 상단 공지 배너의 "숨기기"와 "접어두기" 상태 — 사람마다·토픽마다 **이 기기에** 저장한다(서버에는 두지
/// 않는다). 둘 다 "지금 고정된 그 공지 하나"에만 걸려서, 새 공지가 올라와 id가 달라지면 저절로 풀린다(다시 펼쳐진
/// 채로 보인다). 그래서 토픽마다 마지막으로 숨긴/접은 공지 id 하나씩만 들고 있으면 되고 예전 것이 쌓이지 않는다.
/// 여러 기기 동기화는 하지 않는다 — 배너를 어떻게 볼지는 기기별 취향에 가깝고, 서버 표·이벤트를 더할 만큼의
/// 값이 아니라고 봤다(README 참고).
class AnnouncementViewState {
  final String? hiddenId;
  final String? collapsedId;
  const AnnouncementViewState({this.hiddenId, this.collapsedId});
}

class AnnouncementViewPrefs {
  static String _key(String? userId, String roomId) =>
      'announcement_view:${userId ?? '-'}:$roomId';

  /// 저장된 값 — 없거나 읽지 못하면(저장소를 못 쓰는 환경 등) 둘 다 null.
  static Future<AnnouncementViewState> load(
    String? userId,
    String roomId,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(userId, roomId));
      if (raw == null) return const AnnouncementViewState();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return AnnouncementViewState(
        hiddenId: json['hidden'] as String?,
        collapsedId: json['collapsed'] as String?,
      );
    } catch (_) {
      return const AnnouncementViewState();
    }
  }

  /// 저장한다 — 실패해도(저장소 오류) 화면 동작엔 영향이 없어 조용히 넘긴다.
  static Future<void> save(
    String? userId,
    String roomId, {
    String? hiddenId,
    String? collapsedId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _key(userId, roomId);
      if (hiddenId == null && collapsedId == null) {
        await prefs.remove(key);
        return;
      }
      await prefs.setString(
        key,
        jsonEncode({'hidden': ?hiddenId, 'collapsed': ?collapsedId}),
      );
    } catch (_) {}
  }
}
