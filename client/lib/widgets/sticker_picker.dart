import 'package:flutter/material.dart';

import '../data/stickers.dart';

/// 카테고리 탭 + 이모티콘 그리드. 채팅/댓글 입력창의 이모티콘 버튼을 누르면 이 패널이 뜨고,
/// 하나를 탭하면 [onSelected]를 호출하고 스스로 닫는다(선택 즉시 전송되는 카카오톡 방식).
class StickerPicker extends StatefulWidget {
  final void Function(Sticker sticker) onSelected;
  const StickerPicker({super.key, required this.onSelected});

  @override
  State<StickerPicker> createState() => _StickerPickerState();
}

class _StickerPickerState extends State<StickerPicker> {
  int _categoryIndex = 0;

  @override
  Widget build(BuildContext context) {
    final category = stickerCategories[_categoryIndex];
    return SizedBox(
      height: 280,
      child: Column(
        children: [
          SizedBox(
            height: 40,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: stickerCategories.length,
              itemBuilder: (context, i) {
                final selected = i == _categoryIndex;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text(stickerCategories[i].name),
                    selected: selected,
                    onSelected: (_) => setState(() => _categoryIndex = i),
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
              ),
              itemCount: category.stickers.length,
              itemBuilder: (context, i) {
                final sticker = category.stickers[i];
                return Tooltip(
                  message: sticker.label,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => widget.onSelected(sticker),
                    child: Center(
                      child: Text(
                        sticker.emoji,
                        style: const TextStyle(fontSize: 32),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
