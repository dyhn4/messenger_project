import 'package:flutter/material.dart';

/// 회원/멤버 목록 정렬 기준 — 팀 설정 "멤버" 탭, 조직도 "멤버" 탭, 관리자 콘솔 "회원" 탭이
/// 공통으로 쓴다. 팀 설정·조직도의 "멤버" 탭은 팀 칼럼이 없어서 [SortMenuButton.fields]에
/// [team]을 안 넣는다.
enum MemberSortField { name, role, team, position }

extension MemberSortFieldLabel on MemberSortField {
  String get label => switch (this) {
    MemberSortField.name => '이름',
    MemberSortField.role => '등급',
    MemberSortField.team => '팀',
    MemberSortField.position => '직책',
  };
}

/// 정렬 필드+방향을 고르는 공용 팝업 버튼 — 팀 설정/조직도의 "멤버" 탭, 관리자 콘솔의 "회원"
/// 탭이 목록 위 칼럼 제목 줄 맨 오른쪽에 같은 모양으로 붙여 쓴다. 이미 선택된 필드를 다시
/// 누르면 방향(오름차순/내림차순)만 뒤집히고, 다른 필드를 누르면 그 필드로 바뀌면서 오름차순
/// 부터 시작한다 — 지금 무엇으로 정렬 중인지는 버튼 자체의 화살표 방향과, 메뉴를 열었을 때
/// 선택된 항목 옆 화살표로 알 수 있다.
class SortMenuButton<T> extends StatelessWidget {
  final List<T> fields;
  final String Function(T field) labelOf;
  final T selectedField;
  final bool ascending;
  final void Function(T field, bool ascending) onChanged;

  const SortMenuButton({
    super.key,
    required this.fields,
    required this.labelOf,
    required this.selectedField,
    required this.ascending,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return PopupMenuButton<T>(
      tooltip: '정렬',
      position: PopupMenuPosition.under,
      onSelected: (field) =>
          onChanged(field, field == selectedField ? !ascending : true),
      itemBuilder: (context) => [
        for (final field in fields)
          PopupMenuItem<T>(
            value: field,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${labelOf(field)} 순'),
                if (field == selectedField) ...[
                  const SizedBox(width: 8),
                  Icon(
                    ascending ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 16,
                  ),
                ],
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sort, size: 18, color: hint),
            const SizedBox(width: 2),
            Icon(
              ascending ? Icons.arrow_upward : Icons.arrow_downward,
              size: 14,
              color: hint,
            ),
          ],
        ),
      ),
    );
  }
}
