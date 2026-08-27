import 'package:flutter/material.dart';

const paginationPageSize = 50;

/// 목록 하단 페이지 번호. « < [숫자들] > » — 검색 결과/멤버 목록 등에서 공통으로 쓴다.
/// 항상 최대 10개 페이지 번호만 보여주고 현재 페이지가 그 창의 가운데쯤 오도록 창을 옮긴다.
class Pagination extends StatelessWidget {
  final int currentPage; // 0-based.
  final int totalPages;
  final ValueChanged<int> onPageSelected;
  const Pagination({
    super.key,
    required this.currentPage,
    required this.totalPages,
    required this.onPageSelected,
  });

  static const _windowSize = 10;

  @override
  Widget build(BuildContext context) {
    final maxStart = (totalPages - _windowSize).clamp(0, totalPages);
    final start = (currentPage - _windowSize ~/ 2).clamp(0, maxStart);
    final end = (start + _windowSize).clamp(0, totalPages);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _arrow(
            context,
            Icons.first_page,
            currentPage > 0,
            () => onPageSelected(0),
          ),
          _arrow(
            context,
            Icons.chevron_left,
            currentPage > 0,
            () => onPageSelected(currentPage - 1),
          ),
          for (var i = start; i < end; i++) _pageNumber(context, i),
          _arrow(
            context,
            Icons.chevron_right,
            currentPage < totalPages - 1,
            () => onPageSelected(currentPage + 1),
          ),
          _arrow(
            context,
            Icons.last_page,
            currentPage < totalPages - 1,
            () => onPageSelected(totalPages - 1),
          ),
        ],
      ),
    );
  }

  Widget _arrow(
    BuildContext context,
    IconData icon,
    bool enabled,
    VoidCallback onTap,
  ) {
    return IconButton(
      icon: Icon(icon, size: 18),
      onPressed: enabled ? onTap : null,
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _pageNumber(BuildContext context, int i) {
    final selected = i == currentPage;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: selected ? null : () => onPageSelected(i),
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? Theme.of(context).colorScheme.primary : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            '${i + 1}',
            style: TextStyle(
              color: selected ? Theme.of(context).colorScheme.onPrimary : null,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}
