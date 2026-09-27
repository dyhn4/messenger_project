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

  /// 제목(노트 편집기) — 줄 단위. 채팅·댓글에서는 쓰지 않는다(서버도 받지 않는다).
  static const h1 = 64;
  static const h2 = 128;
  static const h3 = 256;
  static const headings = h1 | h2 | h3;

  /// 줄 단위 서식 전부 — 줄 맨 앞에서 글을 칠 때 이어받는다.
  static const lineMask = quote | headings;

  /// 글자색(노트 편집기) — 서식 비트 안에 "색 있음" 비트 + RGB 24비트로 함께 담는다. 이렇게
  /// 두면 글을 치고 지울 때 서식을 따라가는 처리를 색도 그대로 탄다.
  static const _colorBit = 1 << 9;
  static const _colorShift = 10;
  static const _colorMask = _colorBit | (0xFFFFFF << _colorShift);

  /// 글자색(0xRRGGBB) — 없으면 null.
  static int? colorOf(int flags) =>
      flags & _colorBit == 0 ? null : (flags >> _colorShift) & 0xFFFFFF;

  /// [flags]의 글자색을 [rgb](0xRRGGBB, null이면 기본색)로 바꾼 값.
  static int withColor(int flags, int? rgb) => rgb == null
      ? flags & ~_colorMask
      : (flags & ~_colorMask) | _colorBit | ((rgb & 0xFFFFFF) << _colorShift);
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
