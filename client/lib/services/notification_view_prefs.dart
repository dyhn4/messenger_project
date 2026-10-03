import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 알림 센터의 "안 읽은 알림만 표시" 선택 — 탭마다 켜고 끄고, 이 기기에 사용자별로 저장한다. 멘션 탭의 드롭다운
/// 필터(전체 멘션 / @나를 멘션 / @all 멘션) 선택도 같은 방식으로 따로 저장한다.
///
/// 서버에 두지 않는 이유: 목록을 어떻게 보고 싶은지는 기기별 취향에 가깝고(announcement_view_prefs.dart와
/// 같은 판단), 서버의 알림 설정(@all 받기·보드 알림 수준)처럼 "무엇을 받을지"를 바꾸는 값이 아니기 때문이다.
/// 키는 탭 이름(`all`·`mention`·`board`·`project`)이다.
class NotificationViewPrefs {
  static String _key(String? userId) =>
      'notification_unread_only:${userId ?? '-'}';

  /// 저장된 값 — 없거나 읽지 못하면(저장소를 못 쓰는 환경 등) 빈 맵(모두 꺼짐).
  static Future<Map<String, bool>> load(String? userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(userId));
      if (raw == null) return const {};
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in json.entries)
          if (e.value == true) e.key: true,
      };
    } catch (_) {
      return const {};
    }
  }

  static String _filterKey(String? userId) =>
      'notification_mention_filter:${userId ?? '-'}';

  /// 저장해 둔 멘션 탭 필터 이름(`MentionFilter.name`) — 없거나 읽지 못하면 null(= 전체 멘션).
  static Future<String?> loadMentionFilter(String? userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_filterKey(userId));
    } catch (_) {
      return null;
    }
  }

  /// 멘션 탭 필터를 저장한다. 기본값(`all`)이면 키를 지운다.
  static Future<void> saveMentionFilter(String? userId, String filter) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (filter == 'all') {
        await prefs.remove(_filterKey(userId));
      } else {
        await prefs.setString(_filterKey(userId), filter);
      }
    } catch (_) {}
  }

  /// 저장한다 — 켠 탭 이름만 남기고, 전부 꺼졌으면 키를 지운다. 실패해도 화면 동작엔 영향이 없어 조용히 넘긴다.
  static Future<void> save(String? userId, Map<String, bool> unreadOnly) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final on = {
        for (final e in unreadOnly.entries)
          if (e.value) e.key: true,
      };
      if (on.isEmpty) {
        await prefs.remove(_key(userId));
        return;
      }
      await prefs.setString(_key(userId), jsonEncode(on));
    } catch (_) {}
  }
}
