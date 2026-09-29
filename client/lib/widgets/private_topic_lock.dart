import 'package:flutter/material.dart';

/// 비공개 토픽 이름 옆에 붙이는 작은 회색 자물쇠(잔디처럼 이름 뒤에). 초록 자물쇠는 비밀
/// 대화(E2EE) 표시라 헷갈리지 않게 색을 흐리게 둔다.
class PrivateTopicLock extends StatelessWidget {
  final double size;
  const PrivateTopicLock({super.key, this.size = 14});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Tooltip(
        message: '비공개 토픽',
        child: Icon(
          Icons.lock,
          key: const ValueKey('private-topic-lock'),
          size: size,
          color: Theme.of(context).hintColor,
        ),
      ),
    );
  }
}
