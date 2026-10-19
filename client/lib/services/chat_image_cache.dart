import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// 대화의 사진 미리보기를 오래 보관하는 캐시 — 오프라인일 때도 받아 둔 사진이 보이게.
///
/// 말풍선의 사진 주소는 서버가 한 시간마다 새로 서명하는 링크(/files/<토큰>)라 그대로 캐시 열쇠로 쓰면 한 시간만 지나도 다른 주소가
/// 되어 오프라인에서는 못 찾는다. 그래서 첨부 id로 만든 변하지 않는 열쇠([chatImageCacheKey])로 이 캐시에 둔다. 기본 캐시(200개·30일)보다
/// 넉넉하게 [maxObjects]개·[stalePeriod] 동안 두고, 로그아웃하면 비운다(Session — 공용 PC에 남지 않게).
const chatImageCacheName = 'tangotalk_chat_images';

class ChatImageCache {
  static const maxObjects = 1500;
  static const stalePeriod = Duration(days: 60);

  static CacheManager? _instance;

  /// 처음 쓸 때 만든다(시험처럼 그림을 그리지 않으면 저장소를 건드리지 않게).
  static CacheManager get instance => _instance ??= CacheManager(
    Config(
      chatImageCacheName,
      stalePeriod: stalePeriod,
      maxNrOfCacheObjects: maxObjects,
    ),
  );

  /// 로그아웃 — 받아 둔 사진을 지운다.
  static Future<void> clear() async {
    final c = _instance;
    if (c == null) return;
    try {
      await c.emptyCache();
    } catch (_) {}
  }
}

/// 첨부 사진의 변하지 않는 캐시 열쇠 — [thumbnail]이면 미리보기용 축소본.
String chatImageCacheKey(String attachmentId, {bool thumbnail = true}) =>
    'chat-image:$attachmentId:${thumbnail ? 't' : 'o'}';
