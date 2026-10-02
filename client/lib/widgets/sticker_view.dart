import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../data/stickers.dart';

/// 이모티콘 하나를 그린다 — 기본 이모티콘은 큰 이모지 글자, 서버에 올린 그림 이모티콘은 그림.
/// 그림 주소는 짧게 만료되는 서명 링크라 매번 바뀌므로, 스티커 id로 캐시해서 한 번 받은 그림은
/// 다시 받지 않는다(링크가 만료돼도 그대로 보인다). 서버 목록을 다시 받으면(새 이모티콘) 스스로
/// 다시 그린다.
class StickerView extends StatelessWidget {
  /// 메시지에 실린 id(기본 이모티콘 이름 또는 `srv:` + 서버 id).
  final String stickerId;

  /// 이미 알고 있으면(선택창·보내기 전 카드) — 없으면 [stickerId]로 찾는다.
  final Sticker? sticker;
  final double emojiSize;
  final double imageSize;

  const StickerView({
    super.key,
    required this.stickerId,
    this.sticker,
    required this.emojiSize,
    required this.imageSize,
    this.smooth = false,
  });

  /// 큰 그림을 작은 칸에 줄여 나열하는 목록(이모티콘 선택창·캐릭터 목록)용 — 그리는 크기에 맞춰
  /// 디코딩 단계에서 줄이고 고품질로 보간해서, 화면에서 한 번에 확 줄일 때보다 또렷하다.
  final bool smooth;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: serverStickers,
      builder: (context, _) {
        final s = sticker ?? findStickerById(stickerId);
        if (s == null) {
          // 그림 이모티콘인데 아직 목록에 없으면(방금 새로 올라왔거나 목록을 받는 중) 자리만.
          return stickerId.startsWith(serverStickerPrefix)
              ? _placeholder(context)
              : Text('❔', style: TextStyle(fontSize: emojiSize));
        }
        if (!s.isImage) {
          return Text(s.emoji, style: TextStyle(fontSize: emojiSize));
        }
        return CachedNetworkImage(
          imageUrl: s.imageUrl!,
          cacheKey: 'sticker-${s.id}',
          width: imageSize,
          height: imageSize,
          fit: BoxFit.contain,
          filterQuality: smooth ? FilterQuality.high : FilterQuality.low,
          memCacheWidth: smooth
              ? (imageSize * MediaQuery.devicePixelRatioOf(context)).round()
              : null,
          fadeInDuration: const Duration(milliseconds: 120),
          placeholder: (_, _) => _placeholder(context),
          errorWidget: (_, _, _) => _placeholder(context, broken: true),
        );
      },
    );
  }

  Widget _placeholder(BuildContext context, {bool broken = false}) => SizedBox(
    width: imageSize,
    height: imageSize,
    child: Icon(
      broken ? Icons.broken_image_outlined : Icons.emoji_emotions_outlined,
      size: imageSize * 0.3,
      color: Theme.of(context).hintColor.withValues(alpha: 0.5),
    ),
  );
}
