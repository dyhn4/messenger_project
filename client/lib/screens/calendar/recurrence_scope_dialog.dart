import 'package:flutter/material.dart';

import '../../models/calendar.dart';

/// 반복 일정을 고치거나 지울 때 "이 일정만 / 이 일정 및 이후 일정 / 모든 일정" 중 범위를 고르는 대화상자.
/// 고른 범위를 돌려주고, 취소하면 null. 돌려받은 값을 PATCH/DELETE 의 scope 로 그대로 넘긴다.
Future<RecurrenceScope?> showRecurrenceScopeDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
}) {
  return showDialog<RecurrenceScope>(
    context: context,
    builder: (_) =>
        _RecurrenceScopeDialog(title: title, confirmLabel: confirmLabel),
  );
}

class _RecurrenceScopeDialog extends StatefulWidget {
  final String title;
  final String confirmLabel;
  const _RecurrenceScopeDialog({
    required this.title,
    required this.confirmLabel,
  });

  @override
  State<_RecurrenceScopeDialog> createState() => _RecurrenceScopeDialogState();
}

class _RecurrenceScopeDialogState extends State<_RecurrenceScopeDialog> {
  // 가장 좁은 범위(이 일정만)가 기본 — 실수로 반복 전체를 건드리지 않게.
  RecurrenceScope _scope = RecurrenceScope.thisOnly;

  static const _options = [
    (RecurrenceScope.thisOnly, '이 일정만', 'scope-this'),
    (RecurrenceScope.following, '이 일정 및 이후 일정', 'scope-following'),
    (RecurrenceScope.all, '모든 일정', 'scope-all'),
  ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: RadioGroup<RecurrenceScope>(
        groupValue: _scope,
        onChanged: (v) {
          if (v != null) setState(() => _scope = v);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (scope, label, key) in _options)
              RadioListTile<RecurrenceScope>(
                key: ValueKey(key),
                value: scope,
                title: Text(label),
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('scope-confirm'),
          onPressed: () => Navigator.of(context).pop(_scope),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
