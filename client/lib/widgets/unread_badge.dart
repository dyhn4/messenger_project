import 'package:flutter/material.dart';

/// 방 목록에서 안 읽은 메시지 수를 보여주는 빨간 원형 뱃지.
/// 그 방에 내가 안 읽은 멘션이 있으면 그 옆에 [MentionMarker]가 붙는다.
class UnreadBadge extends StatelessWidget {
  final int count;
  const UnreadBadge({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      constraints: const BoxConstraints(minWidth: 18),
      decoration: BoxDecoration(
        color: Colors.redAccent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// 방 목록에서 안 읽은 멘션이 있다는 표시 — 안읽음 숫자 뱃지 옆의 작은 "@" 원.
class MentionMarker extends StatelessWidget {
  const MentionMarker({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('mention-marker'),
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: Colors.redAccent,
        shape: BoxShape.circle,
      ),
      child: const Text(
        '@',
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          height: 1,
        ),
      ),
    );
  }
}

/// 방 목록에서 쓰다 만 글(임시 저장 — chat_draft_store.dart)이 있다는 표시 — 방 이름 옆의 작은 연필.
class DraftMarker extends StatelessWidget {
  const DraftMarker({super.key});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '임시 저장된 글',
      child: Icon(
        Icons.edit_outlined,
        key: const ValueKey('draft-marker'),
        size: 14,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}
