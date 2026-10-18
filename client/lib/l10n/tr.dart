/// 화면 글의 다국어(지금은 한국어·영어) — 한국어 원문이 그대로 번역 열쇠다(gettext 방식).
///
/// - 화면 코드의 한국어 글은 모두 `tr('원문')`으로 감싸 있다(넣을 값은 `tr('{name}님이 참여했습니다', {'name': name})`).
///   한국어일 때는 원문을 그대로 돌려주고, 영어일 때는 [stringsEn]에서 찾는다(없으면 원문 — 빠진 번역이 화면을 깨지 않게).
/// - 서버가 보낸 글(오류 문구·시스템 메시지·알림)은 서버를 고치지 않고 앱에서 [trServer]로 옮긴다 — 같은 글이면 바로, 서버가 값을
///   넣어 만든 글이면 [serverTemplatesEn]의 틀(`{0}`·`{name}` 자리)에 맞춰 본다.
/// - 언어는 환경설정 → 화면 설정 → 언어(그리고 로그인 화면)에서 고르고 이 기기에 남는다(SharedPreferences). 고르지 않았으면 한국어.
///   바꾸면 화면을 다시 그리지만, 한 번만 계산해 두는 글(창 제목 등) 일부는 앱을 다시 시작해야 바뀐다.
///
/// 새 글을 더하면 `tool/l10n/check.mjs`가 번역이 빠진 열쇠를 알려 준다(README "다국어").
library;

import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_en.dart';
import 'strings_en.dart';

/// 앱이 지원하는 화면 언어.
enum AppLanguage {
  ko('ko', '한국어'),
  en('en', 'English');

  final String code;

  /// 언어 고르기에 보일 이름 — 그 언어로 적는다(번역하지 않는다).
  final String nativeName;
  const AppLanguage(this.code, this.nativeName);

  Locale get locale => Locale(code);

  static AppLanguage? fromCode(String? code) {
    for (final l in AppLanguage.values) {
      if (l.code == code) return l;
    }
    return null;
  }
}

/// 지금 화면 언어와 설정(이 기기).
class AppLocale {
  AppLocale._();

  static const _prefsKey = 'appLanguage';

  /// 'ko' | 'en' | 'system'(기기 언어 — 한국어가 아니면 영어). 고른 적이 없으면 'ko'.
  static String setting = 'ko';

  static AppLanguage _current = AppLanguage.ko;
  static AppLanguage get current => _current;

  /// 언어가 바뀌었다 — 앱 맨 위(main.dart)가 화면 전체를 다시 그린다.
  static final changes = ValueNotifier<AppLanguage>(AppLanguage.ko);

  static bool get isKorean => _current == AppLanguage.ko;

  /// 설정 값 → 실제 언어.
  static AppLanguage resolve(String value) {
    if (value == 'system') {
      final device = PlatformDispatcher.instance.locale.languageCode;
      return device == 'ko' ? AppLanguage.ko : AppLanguage.en;
    }
    return AppLanguage.fromCode(value) ?? AppLanguage.ko;
  }

  /// 앱을 켤 때(runApp 전에) 한 번 — 저장해 둔 언어를 읽는다.
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      apply(prefs.getString(_prefsKey) ?? 'ko');
    } catch (_) {
      apply('ko');
    }
  }

  /// 언어를 바꾸고 이 기기에 남긴다.
  static Future<void> save(String value) async {
    apply(value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, value);
    } catch (_) {}
  }

  /// 저장하지 않고 바로 바꾼다(테스트·저장한 값 읽기).
  static void apply(String value) {
    setting = (value == 'system' || AppLanguage.fromCode(value) != null)
        ? value
        : 'ko';
    _current = resolve(setting);
    _serverCache.clear();
    changes.value = _current;
  }
}

final _placeholder = RegExp(r'\{([^{}\s]+)\}');

/// [template]의 `{name}` 자리에 [args] 값을 넣는다(없는 이름은 그대로 둔다).
String fillPlaceholders(String template, Map<String, Object?> args) {
  if (args.isEmpty) return template;
  return template.replaceAllMapped(_placeholder, (m) {
    final name = m[1]!;
    return args.containsKey(name) ? '${args[name]}' : m[0]!;
  });
}

/// 화면 글 하나 — [ko]는 한국어 원문(번역 열쇠), [args]는 원문의 `{이름}` 자리에 넣을 값.
String tr(String ko, [Map<String, Object?>? args]) {
  final template = AppLocale.isKorean ? ko : (stringsEn[ko] ?? ko);
  return args == null ? template : fillPlaceholders(template, args);
}

// ── 서버 글 ─────────────────────────────────────────────────────────────

class _ServerTemplate {
  final RegExp pattern;
  final List<String> names;
  final String english;
  _ServerTemplate(this.pattern, this.names, this.english);
}

List<_ServerTemplate>? _templates;
final _serverCache = <String, String>{};

List<_ServerTemplate> _compiledTemplates() {
  return _templates ??= [
    for (final e in serverTemplatesEn.entries) _compile(e.key, e.value),
  ];
}

_ServerTemplate _compile(String korean, String english) {
  final names = <String>[];
  final buf = StringBuffer('^');
  var last = 0;
  for (final m in _placeholder.allMatches(korean)) {
    buf.write(RegExp.escape(korean.substring(last, m.start)));
    buf.write('(.*?)');
    names.add(m[1]!);
    last = m.end;
  }
  buf
    ..write(RegExp.escape(korean.substring(last)))
    ..write(r'$');
  return _ServerTemplate(RegExp(buf.toString(), dotAll: true), names, english);
}

/// 서버가 보낸 한국어 글을 지금 언어로 — 그대로 같은 글이 있으면 그것, 서버가 값을 넣어 만든 글이면 틀에 맞춰 값만 옮겨 넣는다.
/// 모르는 글이면 그대로(한국어).
String trServer(String? message) {
  if (message == null || message.isEmpty || AppLocale.isKorean) {
    return message ?? '';
  }
  final cached = _serverCache[message];
  if (cached != null) return cached;
  var out = stringsEn[message] ?? serverEn[message];
  if (out == null) {
    for (final t in _compiledTemplates()) {
      final m = t.pattern.firstMatch(message);
      if (m == null) continue;
      final args = <String, Object?>{
        for (var i = 0; i < t.names.length; i++) t.names[i]: m[i + 1],
      };
      out = fillPlaceholders(t.english, args);
      break;
    }
  }
  out ??= message;
  if (_serverCache.length > 2000) _serverCache.clear();
  _serverCache[message] = out;
  return out;
}

@visibleForTesting
void debugResetServerTemplates() {
  _templates = null;
  _serverCache.clear();
}
