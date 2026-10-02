import 'package:flutter/foundation.dart';

import '../models/sticker_pack.dart';

/// 카카오톡 스타일의 "큼직하게 탭해서 보내는" 이모티콘. 실제 캐릭터 아트 대신 유니콘드
/// 이모지를 크게 렌더링하는 방식으로 구현했다(별도 이미지 에셋 없이 모든 플랫폼에서 바로
/// 쓸 수 있음) — sticker_picker.dart가 카테고리별 그리드로 보여주고, message_bubble.dart/
/// message_comments_card.dart가 말풍선 배경 없이 크게 그린다.
class Sticker {
  final String id; // 메시지 text 필드에 그대로 실려서 전송된다(암호화 대상은 이 문자열 자체).
  final String emoji;
  final String label; // 접근성/툴팁용.

  /// 서버에 올린 그림 이모티콘이면 그 그림 주소(서명 링크) — 이모지 대신 그림을 그린다
  /// (widgets/sticker_view.dart). 기본 이모지 이모티콘은 null.
  final String? imageUrl;
  const Sticker(this.id, this.emoji, this.label, {this.imageUrl});

  bool get isImage => imageUrl != null;
}

class StickerCategory {
  final String name;
  final List<Sticker> stickers;
  const StickerCategory(this.name, this.stickers);
}

const stickerCategories = <StickerCategory>[
  StickerCategory('표정', [
    Sticker('grin', '😄', '활짝 웃음'),
    Sticker('laugh_cry', '😂', '눈물 나게 웃김'),
    Sticker('heart_eyes', '😍', '사랑스러움'),
    Sticker('wink', '😉', '윙크'),
    Sticker('cool', '😎', '쿨함'),
    Sticker('thinking', '🤔', '생각 중'),
    Sticker('cry', '😭', '펑펑 울음'),
    Sticker('angry', '😡', '화남'),
    Sticker('surprised', '😲', '놀람'),
    Sticker('sleepy', '😴', '졸림'),
    Sticker('sick', '🤢', '메스꺼움'),
    Sticker('party', '🥳', '파티'),
  ]),
  StickerCategory('손동작', [
    Sticker('thumbs_up', '👍', '좋아요'),
    Sticker('thumbs_down', '👎', '별로예요'),
    Sticker('clap', '👏', '박수'),
    Sticker('wave', '👋', '안녕'),
    Sticker('ok', '👌', '오케이'),
    Sticker('pray', '🙏', '부탁/감사'),
    Sticker('fist_bump', '👊', '주먹 인사'),
    Sticker('point_up', '☝️', '집중'),
    Sticker('muscle', '💪', '파이팅'),
    Sticker('victory', '✌️', '브이'),
  ]),
  StickerCategory('동물', [
    Sticker('dog', '🐶', '강아지'),
    Sticker('cat', '🐱', '고양이'),
    Sticker('rabbit', '🐰', '토끼'),
    Sticker('bear', '🐻', '곰'),
    Sticker('panda', '🐼', '판다'),
    Sticker('fox', '🦊', '여우'),
    Sticker('chick', '🐥', '병아리'),
    Sticker('monkey', '🙈', '못 봤어요'),
  ]),
  StickerCategory('기타', [
    Sticker('heart', '❤️', '하트'),
    Sticker('broken_heart', '💔', '상심'),
    Sticker('fire', '🔥', '대박'),
    Sticker('100', '💯', '백점'),
    Sticker('congrats', '🎉', '축하'),
    Sticker('question', '❓', '물음표'),
    Sticker('exclaim', '❗', '느낌표'),
    Sticker('sweat', '💦', '식은땀'),
  ]),
];

/// 서버 그림 이모티콘의 id 앞머리 — 메시지에는 "srv:<서버의 스티커 id>"로 실린다.
const serverStickerPrefix = 'srv:';

/// 서버에 올린 그림 이모티콘 세트들("서버 관리 > 이모티콘" — server/src/stickers.js). 로그인하면
/// Session.loadServerStickers가 채우고, 바뀌면 알린다(선택창·말풍선이 다시 그린다). 새 이모티콘은
/// 앱을 다시 배포하지 않아도 이 목록만 새로 받으면 바로 보인다.
final serverStickers = ServerStickerCatalog();

class ServerStickerCatalog extends ChangeNotifier {
  List<StickerCategory> _visible = const [];
  Map<String, Sticker> _byId = const {};

  /// 이모티콘 선택창에 보일 세트들(숨긴 세트·이모티콘은 빠진다).
  List<StickerCategory> get visibleCategories => _visible;

  /// 숨긴 것까지 포함해 찾는다 — 예전 메시지는 숨긴 뒤에도 그림이 보여야 한다.
  Sticker? byId(String id) => _byId[id];

  /// 목록에 없는 id를 만났을 때(누가 방금 새로 올린 이모티콘을 보낸 경우 등) 부른다 — Session이
  /// 목록을 다시 받는다(너무 자주는 안 받게 스스로 걸러 낸다).
  VoidCallback? onMissing;

  /// [resolveUrl]은 서버의 상대 주소(/files/…)를 실제 주소로 바꾼다.
  void replace(
    List<ServerStickerPack> packs,
    String Function(String) resolveUrl,
  ) {
    final byId = <String, Sticker>{};
    final visible = <StickerCategory>[];
    for (final pack in packs) {
      final shown = <Sticker>[];
      for (final (i, s) in pack.stickers.indexed) {
        final sticker = Sticker(
          '$serverStickerPrefix${s.id}',
          '',
          '${pack.name} ${i + 1}',
          imageUrl: resolveUrl(s.displayUrl),
        );
        byId[sticker.id] = sticker;
        if (!s.hidden) shown.add(sticker);
      }
      if (!pack.hidden && !pack.deleted && shown.isNotEmpty) {
        visible.add(StickerCategory(pack.name, shown));
      }
    }
    _byId = byId;
    _visible = visible;
    notifyListeners();
  }

  void clear() {
    _byId = const {};
    _visible = const [];
    notifyListeners();
  }
}

/// 알림·방 목록 미리보기 문구 — 그림 이모티콘은 이모지가 없으니 문구만.
String stickerPreviewText(String? id) {
  final emoji = findStickerById(id ?? '')?.emoji ?? '';
  return emoji.isEmpty ? '이모티콘을 보냈습니다' : '$emoji 이모티콘을 보냈습니다';
}

/// id로 스티커를 찾는다(수신 측이 이모지/라벨을 다시 그릴 때).
Sticker? findStickerById(String id) {
  if (id.startsWith(serverStickerPrefix)) {
    final found = serverStickers.byId(id);
    if (found == null) serverStickers.onMissing?.call();
    return found;
  }
  for (final category in stickerCategories) {
    for (final sticker in category.stickers) {
      if (sticker.id == id) return sticker;
    }
  }
  return null;
}
