import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/message.dart';

final _timeFormat = DateFormat('a h:mm');

/// "OOO 님이 참여했습니다." 같은 참여/초대/퇴장 안내를 가운데 정렬된 회색 pill로 보여준다.
class SystemMessageRow extends StatelessWidget {
  final Message message;
  const SystemMessageRow({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              message.text ?? '',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _timeFormat.format(message.createdAt),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).hintColor,
            ),
          ),
        ],
      ),
    );
  }
}
