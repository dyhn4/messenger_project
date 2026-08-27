import 'package:flutter/material.dart';

/// 방 목록에서 즐겨찾기를 켜고 끄는 작은 별 아이콘. 켜져 있으면 노란 채워진 별,
/// 꺼져 있으면 회색 테두리 별.
class FavoriteStar extends StatelessWidget {
  final bool favorite;
  final VoidCallback onTap;
  final double size;
  const FavoriteStar({
    super.key,
    required this.favorite,
    required this.onTap,
    this.size = 20,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        favorite ? Icons.star : Icons.star_border,
        color: favorite ? Colors.amber : Colors.grey,
        size: size,
      ),
      tooltip: favorite ? '즐겨찾기 해제' : '즐겨찾기',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      onPressed: onTap,
    );
  }
}
