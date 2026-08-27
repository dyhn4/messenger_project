import 'dart:async';

import 'package:flutter/material.dart';

/// 비밀 대화 메시지/댓글이 자동 삭제되기까지 남은 시간을 1초마다 갱신해서 보여준다. 상대가
/// 읽어서 서버가 expiresAt을 확정한 뒤부터만 쓸 수 있다(읽기 전엔 삭제 시점을 아직 모른다 —
/// message_bubble.dart/message_comments_card.dart에서 expiresAt이 null이 아닐 때만 이 위젯을 둔다).
class SelfDestructCountdown extends StatefulWidget {
  final DateTime expiresAt;
  const SelfDestructCountdown({super.key, required this.expiresAt});

  @override
  State<SelfDestructCountdown> createState() => _SelfDestructCountdownState();
}

class _SelfDestructCountdownState extends State<SelfDestructCountdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _format(Duration d) {
    if (d.isNegative) return '곧 삭제';
    if (d.inDays >= 1) return '${d.inDays}일 후 삭제';
    if (d.inHours >= 1) return '${d.inHours}시간 후 삭제';
    if (d.inMinutes >= 1) return '${d.inMinutes}분 후 삭제';
    return '${d.inSeconds}초 후 삭제';
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.expiresAt.difference(DateTime.now());
    final color = Colors.orange.shade700;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.timer_outlined, size: 11, color: color),
        const SizedBox(width: 2),
        Text(_format(remaining), style: TextStyle(fontSize: 10, color: color)),
      ],
    );
  }
}
