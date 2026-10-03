import 'package:flutter/material.dart';

/// 패널 머리글 — 제목 한 줄과 오른쪽 닫기(X). 파일 패널의 머리글과 같은 모양이라, 패널 위젯이 자기 머리글을
/// 직접 그릴 때([SidePanelSpec.ownHeader]) 이걸 쓰면 다른 패널과 어긋나지 않는다.
class SidePanelHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onClose;
  final List<Widget> actions;
  const SidePanelHeader({
    super.key,
    required this.title,
    this.onClose,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
          ...actions,
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: '닫기',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
