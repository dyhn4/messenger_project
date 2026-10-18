import 'package:flutter/material.dart';

import '../l10n/tr.dart';

/// 화면 언어 고르기(환경설정 → 화면 설정, 로그인 화면) — 고르는 즉시 바뀌고 이 기기에 남는다(l10n/tr.dart AppLocale).
/// 언어 이름은 그 언어로 적어(한국어 / English) 지금 언어를 못 읽어도 찾을 수 있게 한다.
class LanguagePicker extends StatelessWidget {
  /// 좁은 자리(로그인 화면 모서리) — 지구본 아이콘과 지금 언어 이름만.
  final bool compact;
  const LanguagePicker({super.key, this.compact = false});

  static List<(String, String)> get _options => [
    for (final l in AppLanguage.values) (l.code, l.nativeName),
    ('system', tr('기기 언어 따르기')),
  ];

  Future<void> _pick(BuildContext context, String value) async {
    if (value == AppLocale.setting) return;
    await AppLocale.save(value);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppLanguage>(
      valueListenable: AppLocale.changes,
      builder: (context, current, _) {
        if (compact) {
          return PopupMenuButton<String>(
            key: const ValueKey('language-picker'),
            tooltip: 'Language / 언어',
            onSelected: (v) => _pick(context, v),
            itemBuilder: (_) => [
              for (final (code, name) in _options)
                CheckedPopupMenuItem(
                  value: code,
                  checked: code == AppLocale.setting,
                  child: Text(name),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.language, size: 18),
                  const SizedBox(width: 6),
                  Text(current.nativeName),
                ],
              ),
            ),
          );
        }
        return DropdownButton<String>(
          key: const ValueKey('language-picker'),
          value: AppLocale.setting,
          onChanged: (v) {
            if (v != null) _pick(context, v);
          },
          items: [
            for (final (code, name) in _options)
              DropdownMenuItem(
                value: code,
                key: ValueKey('language-$code'),
                child: Text(name),
              ),
          ],
        );
      },
    );
  }
}
