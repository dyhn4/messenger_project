import 'package:flutter/material.dart';

import '../models/team.dart' show AccountRole;
import '../services/api_client.dart' show ApiException;
import '../services/session.dart';
import '../l10n/tr.dart';

/// 프로필의 "생일" — 월/일만 고른다(연도는 저장하지 않는다). 서버에는 'MM-DD'로 보내고, 팀원들의 캘린더
/// "멤버 생일"에 표시된다.

/// 달별 최대 일수 — 2월은 윤년 생일(29일)도 허용한다.
const _daysInMonth = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

int maxBirthdayDay(int month) => _daysInMonth[(month - 1).clamp(0, 11)];

/// 월/일 → 서버 값 'MM-DD'.
String birthdayValue(int month, int day) =>
    '${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';

/// 서버 값 'MM-DD' → (월, 일). 형식이 다르거나 없는 날짜면 null.
({int month, int day})? parseBirthdayValue(String? value) {
  if (value == null) return null;
  final m = RegExp(r'^(\d{2})-(\d{2})$').firstMatch(value);
  if (m == null) return null;
  final month = int.parse(m.group(1)!);
  final day = int.parse(m.group(2)!);
  if (month < 1 || month > 12 || day < 1 || day > maxBirthdayDay(month)) {
    return null;
  }
  return (month: month, day: day);
}

/// 화면 문구 "3월 1일". 없으면 null.
String? birthdayText(String? value) {
  final b = parseBirthdayValue(value);
  return b == null
      ? null
      : tr('{b.month}월 {b.day}일', {'b.month': b.month, 'b.day': b.day});
}

/// 프로필 카드에서 생일 수정 창을 연다.
Future<void> showBirthdayDialog(BuildContext context, Session session) {
  return showDialog<void>(
    context: context,
    builder: (_) => BirthdayEditDialog(session: session),
  );
}

class BirthdayEditDialog extends StatefulWidget {
  final Session session;
  const BirthdayEditDialog({super.key, required this.session});

  @override
  State<BirthdayEditDialog> createState() => _BirthdayEditDialogState();
}

class _BirthdayEditDialogState extends State<BirthdayEditDialog> {
  late final ({int month, int day})? _initial = parseBirthdayValue(
    widget.session.birthday,
  );
  late int? _month = _initial?.month;
  late int? _day = _initial?.day;
  bool _busy = false;
  String? _error;

  bool get _isGuest => widget.session.accountRole == AccountRole.guest;
  bool get _canSave =>
      _month != null &&
      _day != null &&
      (_month != _initial?.month || _day != _initial?.day);

  Future<void> _save(String? value) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.updateBirthday(value);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is ApiException
              ? e.message
              : tr('생일을 저장하지 못했습니다. 잠시 후 다시 시도하세요.');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final maxDay = _month == null ? 31 : maxBirthdayDay(_month!);
    return AlertDialog(
      title: Text(tr('생일')),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: const ValueKey('birthday-month'),
                    initialValue: _month,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: tr('월'),
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (var m = 1; m <= 12; m++)
                        DropdownMenuItem(
                          value: m,
                          child: Text(tr('{m}월', {'m': m})),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() {
                            _month = v;
                            // 달을 바꿨는데 일이 그 달에 없으면(31일 → 2월 등) 마지막 날로 맞춘다.
                            if (v != null && _day != null) {
                              _day = _day! > maxBirthdayDay(v)
                                  ? maxBirthdayDay(v)
                                  : _day;
                            }
                          }),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    // 달이 바뀌면 항목 수가 달라져 새로 그린다.
                    key: ValueKey('birthday-day-${_month ?? 0}'),
                    initialValue: _day,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: tr('일'),
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (var d = 1; d <= maxDay; d++)
                        DropdownMenuItem(
                          value: d,
                          child: Text(tr('{d}일', {'d': d})),
                        ),
                    ],
                    onChanged: _busy ? null : (v) => setState(() => _day = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(tr('생일 캘린더에 팀원들에게 표시됩니다(연도는 저장하지 않아요)'), style: hint),
            if (_isGuest) ...[
              const SizedBox(height: 6),
              Text(
                tr('정회원부터 생일 캘린더에 표시돼요.'),
                key: const ValueKey('birthday-guest-note'),
                style: hint,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                key: const ValueKey('birthday-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_initial != null)
          TextButton(
            key: const ValueKey('birthday-delete'),
            onPressed: _busy ? null : () => _save(null),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            child: Text(tr('삭제')),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('birthday-save'),
          onPressed: _canSave && !_busy
              ? () => _save(birthdayValue(_month!, _day!))
              : null,
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}
