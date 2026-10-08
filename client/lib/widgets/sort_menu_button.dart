import 'package:flutter/material.dart';

import 'compact_menu_anchor.dart';

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

/// [SortMenuButton]의 가로 폭 — 칼럼 제목 줄 맨 오른쪽에 이 버튼이 붙으면 그 줄의 칼럼들이 이만큼 좁아지므로,
/// 아래 목록 줄 끝에도 같은 폭의 칸(빈칸 또는 ⋮ 단추)을 둬야 제목과 내용의 가로 위치가 맞는다. 단추 글자("직책 순" 등)가
/// 기준에 따라 바뀌어도 폭이 흔들리지 않게, 가장 긴 글자("↑ 직책 순")가 들어가는 고정 폭으로 둔다.
const sortMenuButtonWidth = 76.0;

/// 정렬 필드+방향을 고르는 공용 드롭다운 단추 — 팀 설정/조직도의 "멤버" 탭, 관리자 콘솔의 "회원"
/// 탭이 목록 위 칼럼 제목 줄 맨 오른쪽에 같은 모양으로 붙여 쓴다. 메뉴는 검색 패널의 "최신 순" 단추
/// (panel_filters.dart의 PanelSortButton)와 같은 [CompactMenuAnchor] — 단추 오른쪽 끝에 맞춰 바로 뜨고, 지금 정렬
/// 기준에 체크가 붙는다. 단추도 "최신 순" 단추처럼 지금 기준 이름("이름 순")을 흐린 12px 글자로 보이고, 그 왼쪽
/// 화살표(↑ 오름차순 / ↓ 내림차순)로 방향을 알린다. 이미 선택된 필드를 다시 누르면 방향만 뒤집히고, 다른 필드를
/// 누르면 그 필드로 바뀌면서 오름차순부터 시작한다.
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
    return CompactMenuAnchor<T>(
      alignEnd: true,
      selected: selectedField,
      onSelected: (field) =>
          onChanged(field, field == selectedField ? !ascending : true),
      entries: [
        for (final field in fields)
          CompactMenuOption(
            key: ValueKey('sort-menu-$field'),
            value: field,
            label: '${labelOf(field)} 순',
          ),
      ],
      builder: (context, open, toggle) => Semantics(
        expanded: open,
        child: Tooltip(
          message: '정렬',
          child: InkWell(
            key: const ValueKey('sort-menu-button'),
            onTap: toggle,
            child: SizedBox(
              width: sortMenuButtonWidth,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  // 제목 줄 오른쪽 끝에 붙여 둔다(검색 패널의 "최신 순"처럼).
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Icon(
                      ascending ? Icons.arrow_upward : Icons.arrow_downward,
                      key: ValueKey(
                        ascending
                            ? 'sort-menu-ascending'
                            : 'sort-menu-descending',
                      ),
                      size: 16,
                      color: hint,
                    ),
                    const SizedBox(width: 2),
                    Flexible(
                      child: Text(
                        '${labelOf(selectedField)} 순',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.labelMedium?.copyWith(color: hint),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
