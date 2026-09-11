import 'package:flutter/material.dart';

import '../services/api_client.dart' show PositionOption;

/// 관리자 콘솔 "회원" 탭의 "직책 수정" 다이얼로그. 팀·직책 관리 범위에 따라 다르다 — 계정
/// 단위면 서버 운영자가 관리하는 "직책 목록" 중에서 칩으로 고르고(가로로 늘어놔서 한눈에
/// 전부 보이게), 팀 단위면(실제 직책은 팀마다 다를 수 있어 각 팀 설정에서 따로 관리하므로)
/// 자유 입력으로 받는다. 소속 팀은 회원 탭 목록에 이미 칩으로 보이고 여기서 바꿀 수 있는
/// 값도 아니라 이 다이얼로그에는 없다. 저장을 누르면 직책 값을, 취소하면 null을 돌려준다
/// (빈 문자열 = 지우기).
Future<({String position})?> showAdminOrgEditDialog(
  BuildContext context, {
  required String userName,
  required String orgScope,
  required String? position,
  required List<PositionOption> options,
}) {
  return showDialog<({String position})>(
    context: context,
    builder: (_) => _AdminOrgEditDialog(
      userName: userName,
      orgScope: orgScope,
      position: position,
      options: options,
    ),
  );
}

class _AdminOrgEditDialog extends StatefulWidget {
  final String userName;
  final String orgScope;
  final String? position;
  final List<PositionOption> options;
  const _AdminOrgEditDialog({
    required this.userName,
    required this.orgScope,
    required this.position,
    required this.options,
  });

  @override
  State<_AdminOrgEditDialog> createState() => _AdminOrgEditDialogState();
}

class _AdminOrgEditDialogState extends State<_AdminOrgEditDialog> {
  /// 팀 단위일 때만 쓰는 자유 입력 컨트롤러.
  late final _positionText = TextEditingController(text: widget.position ?? '');

  /// 계정 단위일 때만 쓰는 칩 선택값.
  late String? _selected = widget.position?.isNotEmpty == true
      ? widget.position
      : null;

  /// 이 기능이 생기기 전부터 있던 값이라 목록에 없을 수 있다 — 사라진 것처럼 보이지 않도록
  /// 칩 목록 맨 앞에 "지금 값"으로 하나 더 보여준다(그대로 저장하면 서버도 허용한다).
  late final bool _hasLegacyValue =
      widget.orgScope == 'account' &&
      _selected != null &&
      !widget.options.any((o) => o.label == _selected);

  bool get _isAccountScope => widget.orgScope == 'account';

  @override
  void dispose() {
    _positionText.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop((
    position: _isAccountScope ? (_selected?.trim() ?? '') : _positionText.text.trim(),
  ));

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return AlertDialog(
      title: Text('${widget.userName} 님의 직책'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_isAccountScope)
              if (widget.options.isEmpty && !_hasLegacyValue)
                Text(
                  '등록된 직책이 없습니다. "운영 현황"에서 먼저 추가하세요.',
                  style: TextStyle(color: hint),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('(없음)'),
                      selected: _selected == null,
                      onSelected: (_) => setState(() => _selected = null),
                    ),
                    if (_hasLegacyValue)
                      ChoiceChip(
                        label: Text('${widget.position}(목록에 없는 기존 값)'),
                        selected: _selected == widget.position,
                        onSelected: (_) =>
                            setState(() => _selected = widget.position),
                      ),
                    for (final option in widget.options)
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
                )
            else
              TextField(
                controller: _positionText,
                maxLength: 30,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '직책',
                  hintText: '예: 팀장',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submit(),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _submit, child: const Text('저장')),
      ],
    );
  }
}
