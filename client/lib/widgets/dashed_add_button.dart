import 'package:flutter/material.dart';

/// 아직 아무것도 고르지 않은 자리를 나타내는 점선 테두리의 작은 "추가" 버튼.
class DashedAddButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const DashedAddButton({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: CustomPaint(
        painter: _DashedBorderPainter(color: hint.withValues(alpha: 0.7)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Text(label, style: TextStyle(fontSize: 12, color: hint)),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  final Color color;
  const _DashedBorderPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)),
      );
    // 테두리를 따라가며 3픽셀 긋고 3픽셀 띄우기를 되풀이한다.
    for (final metric in path.computeMetrics()) {
      var start = 0.0;
      while (start < metric.length) {
        final end = start + 3 > metric.length ? metric.length : start + 3;
        canvas.drawPath(metric.extractPath(start, end), paint);
        start += 6;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}
