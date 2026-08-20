import 'package:flutter/material.dart';

/// 방 목록에서 안 읽은 메시지 수를 보여주는 빨간 원형 뱃지.
class UnreadBadge extends StatelessWidget {
  final int count;
  const UnreadBadge({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      constraints: const BoxConstraints(minWidth: 18),
      decoration: BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.circular(10)),
      child: Text(
        '$count',
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
      ),
    );
  }
}
