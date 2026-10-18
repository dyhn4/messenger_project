import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../services/api_client.dart' show PositionOption;
import '../services/session.dart';
import '../l10n/tr.dart';

/// "직책 수정" 다이얼로그. 팀 설정의 멤버 목록과 프로필 카드의 "직책 수정" 연필 버튼이 같이
/// 쓴다. 소유자·관리자만 열 수 있다(호출부에서 버튼 자체를 가리고, 서버도 다시 검사한다).
///
/// 관리자 콘솔 "회원" 탭의 직책 수정처럼 직책 목록(position_options, 서열순)에서 칩으로
/// 고른다 — 자유 입력을 없애서 오탈자/표기 불일치를 막는다. 다만 여기서는 목록 전체가 아니라
/// **내 직책과 같거나 그 아래(서열상 뒤쪽)만** 고를 수 있다 — 남에게 내 직책보다 높은 직책을
/// 못 주게 막는 것과 같은 이유(팀 초대 링크의 "부여할 직책"과 같은 규칙, 서버도 다시 검사).
///
/// 저장을 누르면 새 직책 값을(빈 문자열 = 지우기) 돌려주고, 취소하면 null.
Future<String?> showOrgEditDialog(
  BuildContext context,
  Session session,
  AppUser user,
) {
  return showDialog<String>(
    context: context,
    builder: (_) => _OrgEditDialog(session: session, user: user),
  );
}

class _OrgEditDialog extends StatefulWidget {
  final Session session;
  final AppUser user;
  const _OrgEditDialog({required this.session, required this.user});

  @override
  State<_OrgEditDialog> createState() => _OrgEditDialogState();
}

class _OrgEditDialogState extends State<_OrgEditDialog> {
  List<PositionOption>? _options;
  late String? _selected = widget.user.position?.isNotEmpty == true
      ? widget.user.position
      : null;

  @override
  void initState() {
    super.initState();
    widget.session.fetchPublicPositionOptions().then((list) {
      if (mounted) setState(() => _options = list);
    });
  }

  /// 내 직책과 같거나 그 아래만 — 목록은 서열순으로 오는데, 서열은 sortOrder가 **작을수록
  /// 낮다**(기본 목록이 사원(0)→대표(7) 순으로 들어있는 것과 같은 방향 — 관리자 콘솔의
  /// 화살표는 단지 이웃과 순서를 맞바꿀 뿐이라, 그 순서 자체가 "서열이 낮은 것부터"라는
  /// 약속이다). 그래서 "내 직책 이하"는 목록 맨 앞부터 내 위치(index)까지다. 내 직책이
  /// 목록에 없으면(직책 미등록 등) 고를 수 있는 게 없다.
  List<PositionOption> get _available {
    final options = _options;
    if (options == null) return const [];
    final myIndex = options.indexWhere(
      (o) => o.label == widget.session.myPosition,
    );
    if (myIndex == -1) return const [];
    return options.sublist(0, myIndex + 1);
  }

  /// 이 기능이 생기기 전부터 있던 자유 입력 값이라 서열 제한에 걸려 목록에 안 보일 수 있다 —
  /// 사라진 것처럼 보이지 않도록 "지금 값"을 칩으로 하나 더 보여준다(건드리지 않고 그대로
  /// 저장하는 건 서버도 허용한다).
  bool get _hasLegacyValue =>
      _selected != null && !_available.any((o) => o.label == _selected);

  void _submit() => Navigator.of(context).pop(_selected?.trim() ?? '');

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final options = _options;
    return AlertDialog(
      title: Text(
        tr('{widget.user.name} 님의 직책', {'widget.user.name': widget.user.name}),
      ),
      content: SizedBox(
        width: 340,
        child: options == null
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(child: CircularProgressIndicator()),
              )
            : (_available.isEmpty && !_hasLegacyValue)
            ? Text(tr('선택할 수 있는 직책이 없습니다.'), style: TextStyle(color: hint))
            : Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: Text(tr('(없음)')),
                    selected: _selected == null,
                    onSelected: (_) => setState(() => _selected = null),
                  ),
                  if (_hasLegacyValue)
                    ChoiceChip(
                      label: Text(
                        tr('{_selected}(목록에 없는 기존 값)', {
                          '_selected': _selected,
                        }),
                      ),
                      selected: true,
                      onSelected: (_) {},
                    ),
                  for (final option in _available)
                    ChoiceChip(
                      avatar: option.isDefault
                          ? const Icon(Icons.star, size: 16)
                          : null,
                      label: Text(option.label),
                      selected: _selected == option.label,
                      onSelected: (_) =>
                          setState(() => _selected = option.label),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(onPressed: _submit, child: Text(tr('저장'))),
      ],
    );
  }
}
