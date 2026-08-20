import 'package:flutter/material.dart';

/// 잔디(JANDI)식 가운데 뜨는 작은 생성창. 데스크톱 사이드바의 "+" 동작에서
/// 전체화면 대신 이걸로 감싸서 보여준다 (모바일은 지금처럼 전체화면 유지).
class FloatingDialog extends StatelessWidget {
  final String title;
  final Widget child;
  final double maxWidth;
  final double maxHeight;
  const FloatingDialog({
    super.key,
    required this.title,
    required this.child,
    this.maxWidth = 480,
    this.maxHeight = 640,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(child: child),
            ],
          ),
        ),
      ),
    );
  }
}
