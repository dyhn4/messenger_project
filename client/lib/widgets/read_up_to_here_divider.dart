import 'package:flutter/material.dart';

/// 이 방을 열었을 때 "여기까지는 이미 읽었다"는 지점을 표시하는 구분선.
class ReadUpToHereDivider extends StatelessWidget {
  const ReadUpToHereDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final color = Colors.deepPurple.shade300;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: Colors.deepPurple.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            '여기까지 읽었습니다.',
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
