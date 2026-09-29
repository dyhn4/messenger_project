import 'package:flutter/material.dart';

/// 잔디(JANDI)식 가운데 뜨는 작은 생성창. 데스크톱 사이드바의 "+" 동작에서
/// 전체화면 대신 이걸로 감싸서 보여준다 (모바일은 지금처럼 전체화면 유지).
class FloatingDialog extends StatelessWidget {
  final String title;
  final Widget child;
  final double maxWidth;
  final double maxHeight;

  /// 기본은 사방 20 여백. 스크롤바를 창 오른쪽 끝에 완전히 붙여야 하는 화면(설정 등)처럼
  /// 안쪽 콘텐츠가 스스로 여백을 관리하고 싶을 때만 오른쪽을 0으로 주는 식으로 넘긴다 —
  /// Positioned 오버플로/음수 패딩 같은 트릭은 Stack 밖 영역에 마우스 클릭이 안 먹는
  /// 문제가 있어서(자식이 그려지는 자리와 히트테스트 판정 영역이 다름) 실제 레이아웃 폭
  /// 자체를 넓혀주는 이 방식이 더 안전하다.
  final EdgeInsetsGeometry padding;
  const FloatingDialog({
    super.key,
    required this.title,
    required this.child,
    this.maxWidth = 480,
    this.maxHeight = 640,
    this.padding = const EdgeInsets.all(20),
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: Padding(
          padding: padding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    // maybePop — 안의 PopScope(요청 중에는 닫지 않기, 닫을 때 결과 넘기기)가 Esc·바깥
                    // 클릭과 똑같이 ✕에도 적용되게 한다.
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
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
