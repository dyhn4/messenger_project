import 'package:flutter/material.dart';

import '../data/stickers.dart';
import 'sticker_view.dart';
import '../l10n/tr.dart';

/// 보내기로 정한(아직 전송 전) 이모티콘을 메시지 목록 위에 떠 있는 큰 카드로 보여준다. 실제
/// 전송은 입력창의 보내기 버튼을 눌러야 이뤄지고, 오른쪽 위 x를 누르면 취소된다. chat_panel.dart/
/// message_thread_screen.dart가 메시지 목록 영역의 Stack 안에 Positioned로 띄운다.
class StickerPreviewCard extends StatelessWidget {
  final Sticker sticker;
  final VoidCallback onRemove;
  const StickerPreviewCard({
    super.key,
    required this.sticker,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            Padding(
              // 오른쪽 위 x 버튼 자리만큼만 안쪽에 여백을 둬서 이모지와 안 겹치게 한다.
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
              child: StickerView(
                stickerId: sticker.id,
                sticker: sticker,
                emojiSize: 96,
                imageSize: 140,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              iconSize: 16,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              onPressed: onRemove,
              tooltip: tr('취소'),
            ),
          ],
        ),
      ),
    );
  }
}
