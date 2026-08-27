/// 카카오톡 스타일의 "큼직하게 탭해서 보내는" 이모티콘. 실제 캐릭터 아트 대신 유니콘드
/// 이모지를 크게 렌더링하는 방식으로 구현했다(별도 이미지 에셋 없이 모든 플랫폼에서 바로
/// 쓸 수 있음) — sticker_picker.dart가 카테고리별 그리드로 보여주고, message_bubble.dart/
/// message_comments_card.dart가 말풍선 배경 없이 크게 그린다.
class Sticker {
  final String id; // 메시지 text 필드에 그대로 실려서 전송된다(암호화 대상은 이 문자열 자체).
  final String emoji;
  final String label; // 접근성/툴팁용.
  const Sticker(this.id, this.emoji, this.label);
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

/// id로 스티커를 찾는다(수신 측이 이모지/라벨을 다시 그릴 때).
Sticker? findStickerById(String id) {
  for (final category in stickerCategories) {
    for (final sticker in category.stickers) {
      if (sticker.id == id) return sticker;
    }
  }
  return null;
}
