import 'package:flutter/material.dart';

import '../../../models/calendar.dart';
import '../../../services/calendar_controller.dart';
import '../../../services/session.dart';
import '../calendar_common.dart';
import 'calendar_management_common.dart';
import 'calendar_settings.dart';
import '../../../l10n/tr.dart';

/// 새 캘린더 이름의 최대 글자 수(서버 규약과 같다).
const kCalendarNameMax = 30;

/// 캘린더 이름 검사 — 앞뒤 공백을 뺀 1~30자(글자 단위). 통과하면 null, 아니면 사유.
String? validateCalendarName(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return tr('캘린더 이름을 입력하세요.');
  if (v.characters.length > kCalendarNameMax) {
    return tr('캘린더 이름은 {kCalendarNameMax}자 이내로 입력하세요.', {
      'kCalendarNameMax': kCalendarNameMax,
    });
  }
  return null;
}

/// "나의 캘린더" 옆 + — 이름과 색을 골라 만들고, 만들면 바로 그 캘린더의 설정(멤버 추가 등)으로 이어 간다.
Future<void> createCalendarFlow(
  BuildContext context,
  Session session,
  CalendarController controller,
) async {
  final created = await showCalendarSheet<CalendarInfo>(
    context,
    title: tr('새 캘린더 만들기'),
    maxWidth: 440,
    child: CalendarCreateForm(controller: controller),
  );
  if (created == null || !context.mounted) return;
  // 목록을 다시 받은 뒤의 값(권한 플래그가 서버 계산값)을 쓰고, 못 찾으면 만들기 응답 그대로.
  await showCalendarSettings(
    context,
    session,
    controller,
    controller.calendarById(created.id) ?? created,
  );
}

/// 새 캘린더 폼 — 만들기에 성공하면 만든 [CalendarInfo]를 담아 스스로 닫힌다. 서버 오류(`{error}`)는
/// 폼 안에 그대로 보여 주고 열어 둔다.
class CalendarCreateForm extends StatefulWidget {
  final CalendarController controller;
  const CalendarCreateForm({super.key, required this.controller});

  @override
  State<CalendarCreateForm> createState() => _CalendarCreateFormState();
}

class _CalendarCreateFormState extends State<CalendarCreateForm> {
  final _name = TextEditingController();
  late String _color = _defaultColor();
  bool _busy = false;
  String? _error;

  /// 이미 쓰고 있는 색을 피해 팔레트에서 처음 남는 색 — 새 캘린더가 목록에서 구별되게.
  String _defaultColor() {
    final used = {
      for (final c in widget.controller.mine) c.color.toUpperCase(),
    };
    return calendarPalette.firstWhere(
      (hex) => !used.contains(hex),
      orElse: () => calendarPalette.first,
    );
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _valid => validateCalendarName(_name.text) == null;

  Future<void> _submit() async {
    if (_busy || !_valid) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final created = await widget.controller.createCalendar(
        name: _name.text.trim(),
        color: _color,
      );
      if (mounted) Navigator.of(context).pop(created);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = calendarErrorText(e, tr('캘린더를 만들지 못했습니다. 잠시 후 다시 시도하세요.'));
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nameError = _name.text.isEmpty
        ? null
        : validateCalendarName(_name.text);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr('캘린더 이름'), style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          TextField(
            key: const ValueKey('cal-create-name'),
            controller: _name,
            autofocus: true,
            enabled: !_busy,
            maxLength: kCalendarNameMax,
            decoration: InputDecoration(
              hintText: tr('예: 디자인팀 일정'),
              border: const OutlineInputBorder(),
              isDense: true,
              errorText: nameError,
            ),
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          Text(tr('색'), style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          CalendarColorGrid(
            selected: _color,
            onSelected: (hex) {
              if (!_busy) setState(() => _color = hex);
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              key: const ValueKey('cal-create-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text(tr('취소')),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('cal-create-submit'),
                onPressed: _valid && !_busy ? _submit : null,
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(tr('만들기')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
