// 글자 서식 구간 — 본문은 평문 그대로 두고 어느 구간에 어떤 서식이 걸렸는지만 따로 둔다
// (서버 textFormat.js와 같은 모양). 입력·표시는 widgets/rich_text_format.dart.

/// 서식 비트 — 서버 textFormat.js와 같은 값.
abstract final class Fmt {
  static const bold = 1;
  static const italic = 2;
  static const underline = 4;
  static const strike = 8;
  static const code = 16;

  /// 줄 단위 — 그 줄의 글자들에 같이 걸린다.
  static const quote = 32;
}

/// 서식 구간 하나 — [start, end) 에 [flags] 서식, [href]가 있으면 링크.
class TextFormatRun {
  final int start;
  final int end;
  final int flags;
  final String? href;
  const TextFormatRun(this.start, this.end, this.flags, [this.href]);

  Map<String, dynamic> toJson() => {
    's': start,
    'e': end,
    'f': flags,
    if (href != null) 'h': href,
  };

  static TextFormatRun? fromJson(Object? json) {
    if (json is! Map) return null;
    final s = json['s'], e = json['e'], f = json['f'], h = json['h'];
    if (s is! int || e is! int || e <= s) return null;
    return TextFormatRun(s, e, f is int ? f : 0, h is String ? h : null);
  }
}

/// 서버에서 받은 textFormat(JSON 배열)을 읽는다. 없거나 모양이 틀리면 null.
List<TextFormatRun>? parseTextFormat(Object? json) {
  if (json is! List) return null;
  final runs = [for (final r in json) ?TextFormatRun.fromJson(r)];
  return runs.isEmpty ? null : runs;
}

List<Map<String, dynamic>>? textFormatToJson(List<TextFormatRun>? runs) =>
    runs == null || runs.isEmpty ? null : [for (final r in runs) r.toJson()];
