import 'package:flutter/material.dart';

import '../models/app_user.dart';

/// 부서/직책 입력창. 팀 설정의 팀원 목록과 프로필 카드의 "수정" 버튼이 같이 쓴다.
/// 소유자·관리자만 열 수 있다(호출부에서 버튼 자체를 가리고, 서버도 다시 검사한다).
/// 저장을 누르면 입력값을, 취소하면 null을 돌려준다(빈 문자열 = 지우기).
Future<({String department, String position})?> showOrgEditDialog(
  BuildContext context,
  AppUser user,
) {
  return showDialog<({String department, String position})>(
    context: context,
    builder: (_) => _OrgEditDialog(user: user),
  );
}

class _OrgEditDialog extends StatefulWidget {
  final AppUser user;
  const _OrgEditDialog({required this.user});

  @override
  State<_OrgEditDialog> createState() => _OrgEditDialogState();
}

class _OrgEditDialogState extends State<_OrgEditDialog> {
  late final _department = TextEditingController(
    text: widget.user.department ?? '',
  );
  late final _position = TextEditingController(
    text: widget.user.position ?? '',
  );

  @override
  void dispose() {
    _department.dispose();
    _position.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(
    context,
  ).pop((department: _department.text.trim(), position: _position.text.trim()));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.user.name} 님의 부서·직책'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _department,
              maxLength: 30,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '부서',
                hintText: '예: 개발팀',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _position,
              maxLength: 30,
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
