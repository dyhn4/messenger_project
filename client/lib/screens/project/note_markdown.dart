import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/app_links.dart';
import '../../widgets/rich_text_format.dart';

// 노트 본문 ↔ 편집기(서식을 입힌 평문) 변환, 그리고 본문 그리기.
//
// 노트는 서버에 마크다운 글로 저장한다 — 미리보기·수정 이력·검색이 글을 그대로 쓰고, 예전
// 노트와도 호환된다. 편집기는 기호 없이 서식이 바로 보이는 입력칸이라, 열 때 마크다운 →
// (평문 + 서식), 저장할 때 (평문 + 서식) → 마크다운으로 바꾼다.
//
// 줄:  "# "·"## "·"### " 제목, "> " 인용, "- " 글머리(편집기 "• "), "- [ ] "·"- [x] " 체크
//      (편집기 "☐ "·"☑ "), "1. " 번호, "---" 구분선(편집기 "──────────"), "|"로 시작하는 표 줄
//      (그대로), "![이름](주소)" 그림 줄(편집기 "🖼 이름", 주소는 'image:<주소>' 링크로 숨겨 둔다).
// 글자: "**굵게**"·"<b>", "<i>기울임</i>"·"*기울임*", "<u>밑줄</u>", "~~취소선~~", "`코드`",
//      "[글](주소)" 링크, "<span style="color:#RRGGBB">글</span>" 글자색.

/// 편집기에서 구분선 줄.
const noteRule = '──────────';

/// 편집기에서 그림 줄의 앞머리.
const noteImagePrefix = '🖼 ';

/// 그림 줄에 숨겨 두는 링크 주소의 앞머리.
const noteImageHref = 'image:';

final _inlinePattern = RegExp(
  r'<span style="color:#([0-9a-fA-F]{6})">(.+?)</span>' // 1, 2
  r'|\*\*(.+?)\*\*' // 3
  r'|<b>(.+?)</b>' // 4
  r'|<i>(.+?)</i>' // 5
  r'|<u>(.+?)</u>' // 6
  r'|~~(.+?)~~' // 7
  r'|`([^`]+)`' // 8
  r'|\[([^\]]+)\]\(([^)\s]+)\)' // 9, 10
  r'|(?<![\w*])\*([^*\s](?:[^*]*[^*\s])?)\*(?![\w*])', // 11 (예전 기울임)
);

final _checkLine = RegExp(r'^(\s*)[-*] \[( |x|X)\] ');
final _bulletLine = RegExp(r'^(\s*)[-*] ');
final _imageLine = RegExp(r'^!\[([^\]]*)\]\(([^)\s]+)\)\s*$');

class _Builder {
  final buf = StringBuffer();
  final flags = <int>[];
  final hrefs = <String?>[];

  void add(String s, int f, [String? href]) {
    buf.write(s);
    for (var i = 0; i < s.length; i++) {
      flags.add(f);
      hrefs.add(href);
    }
  }
}

void _inlineInto(_Builder b, String s, int f, String? href) {
  var last = 0;
  for (final m in _inlinePattern.allMatches(s)) {
    if (m.start > last) b.add(s.substring(last, m.start), f, href);
    if (m.group(1) != null) {
      _inlineInto(
        b,
        m.group(2)!,
        Fmt.withColor(f, int.parse(m.group(1)!, radix: 16)),
        href,
      );
    } else if (m.group(3) != null) {
      _inlineInto(b, m.group(3)!, f | Fmt.bold, href);
    } else if (m.group(4) != null) {
      _inlineInto(b, m.group(4)!, f | Fmt.bold, href);
    } else if (m.group(5) != null) {
      _inlineInto(b, m.group(5)!, f | Fmt.italic, href);
    } else if (m.group(6) != null) {
      _inlineInto(b, m.group(6)!, f | Fmt.underline, href);
    } else if (m.group(7) != null) {
      _inlineInto(b, m.group(7)!, f | Fmt.strike, href);
    } else if (m.group(8) != null) {
      b.add(m.group(8)!, f | Fmt.code, href);
    } else if (m.group(9) != null) {
      _inlineInto(b, m.group(9)!, f, m.group(10));
    } else {
      _inlineInto(b, m.group(11)!, f | Fmt.italic, href);
    }
    last = m.end;
  }
  if (last < s.length) b.add(s.substring(last), f, href);
}

List<TextFormatRun> _toRuns(List<int> flags, List<String?> hrefs) {
  final runs = <TextFormatRun>[];
  var i = 0;
  while (i < flags.length) {
    final f = flags[i], h = hrefs[i];
    var j = i + 1;
    while (j < flags.length && flags[j] == f && hrefs[j] == h) {
      j++;
    }
    if (f != 0 || h != null) runs.add(TextFormatRun(i, j, f, h));
    i = j;
  }
  return runs;
}

/// 마크다운 → 편집기용 평문 + 서식.
({String text, List<TextFormatRun> runs}) noteMarkdownToRich(String md) {
  final b = _Builder();
  final lines = md.replaceAll('\r', '').split('\n');
  for (var li = 0; li < lines.length; li++) {
    var line = lines[li];
    var lf = 0;
    if (line.startsWith('### ')) {
      lf = Fmt.h3;
      line = line.substring(4);
    } else if (line.startsWith('## ')) {
      lf = Fmt.h2;
      line = line.substring(3);
    } else if (line.startsWith('# ')) {
      lf = Fmt.h1;
      line = line.substring(2);
    } else if (line.startsWith('> ') || line == '>') {
      lf = Fmt.quote;
      line = line.length > 2 ? line.substring(2) : '';
    }
    final image = _imageLine.firstMatch(line.trim());
    if (image != null) {
      final name = image.group(1)!.isEmpty ? '그림' : image.group(1)!;
      b.add('$noteImagePrefix$name', lf, '$noteImageHref${image.group(2)}');
    } else if (line.trim() == '---' || line.trim() == '***') {
      b.add(noteRule, lf);
    } else if (line.trimLeft().startsWith('|')) {
      b.add(line, lf);
    } else {
      final check = _checkLine.firstMatch(line);
      final bullet = check == null ? _bulletLine.firstMatch(line) : null;
      if (check != null) {
        b.add('${check.group(1)}${check.group(2) == ' ' ? '☐' : '☑'} ', lf);
        line = line.substring(check.end);
      } else if (bullet != null) {
        b.add('${bullet.group(1)}• ', lf);
        line = line.substring(bullet.end);
      }
      _inlineInto(b, line, lf, null);
    }
    if (li < lines.length - 1) b.add('\n', lf);
  }
  return (text: b.buf.toString(), runs: _toRuns(b.flags, b.hrefs));
}

/// 편집기 평문 + 서식 → 마크다운(저장용).
String noteRichToMarkdown(String text, List<TextFormatRun>? runs) {
  final flags = List<int>.filled(text.length, 0);
  final hrefs = List<String?>.filled(text.length, null);
  for (final r in runs ?? const <TextFormatRun>[]) {
    for (var i = r.start; i < r.end && i < text.length; i++) {
      flags[i] |= r.flags;
      if (r.href != null) hrefs[i] = r.href;
    }
  }
  final out = <String>[];
  var start = 0;
  for (final line in text.split('\n')) {
    final end = start + line.length;
    out.add(_lineToMd(text, flags, hrefs, start, end));
    start = end + 1;
  }
  return out.join('\n');
}

String _lineToMd(
  String text,
  List<int> flags,
  List<String?> hrefs,
  int s,
  int e,
) {
  final line = text.substring(s, e);
  if (line.isEmpty) return '';
  final lf = flags[s] & Fmt.lineMask;
  var prefix = lf & Fmt.h1 != 0
      ? '# '
      : lf & Fmt.h2 != 0
      ? '## '
      : lf & Fmt.h3 != 0
      ? '### '
      : lf & Fmt.quote != 0
      ? '> '
      : '';
  if (line == noteRule) return '---';
  final href = hrefs[s];
  if (href != null &&
      href.startsWith(noteImageHref) &&
      line.startsWith(noteImagePrefix)) {
    return '![${line.substring(noteImagePrefix.length)}]'
        '(${href.substring(noteImageHref.length)})';
  }
  if (line.trimLeft().startsWith('|')) return '$prefix$line';
  var i = s;
  final m = RegExp(r'^(\s*)(☐|☑|•) ').firstMatch(line);
  if (m != null) {
    prefix +=
        '${m.group(1)}${switch (m.group(2)) {
          '•' => '- ',
          '☐' => '- [ ] ',
          _ => '- [x] ',
        }}';
    i = s + m.end;
  }
  return prefix + _inlineToMd(text, flags, hrefs, i, e);
}

String _inlineToMd(
  String text,
  List<int> flags,
  List<String?> hrefs,
  int s,
  int e,
) {
  final sb = StringBuffer();
  var i = s;
  while (i < e) {
    final f = flags[i] & ~Fmt.lineMask;
    final h = hrefs[i];
    var j = i + 1;
    while (j < e && (flags[j] & ~Fmt.lineMask) == f && hrefs[j] == h) {
      j++;
    }
    var seg = text.substring(i, j);
    if (f & Fmt.code != 0) seg = '`$seg`';
    if (f & Fmt.strike != 0) seg = '~~$seg~~';
    if (f & Fmt.underline != 0) seg = '<u>$seg</u>';
    if (f & Fmt.italic != 0) seg = '<i>$seg</i>';
    if (f & Fmt.bold != 0) seg = '**$seg**';
    if (h != null && !h.startsWith(noteImageHref)) seg = '[$seg]($h)';
    final rgb = Fmt.colorOf(f);
    if (rgb != null) {
      final hex = rgb.toRadixString(16).padLeft(6, '0').toUpperCase();
      seg = '<span style="color:#$hex">$seg</span>';
    }
    sb.write(seg);
    i = j;
  }
  return sb.toString();
}

/// 목록에 보일 한 줄 미리보기 — 서식 기호를 걷어 낸 평문.
String notePlainPreview(String? preview) {
  if (preview == null || preview.trim().isEmpty) return '';
  return noteMarkdownToRich(
    preview,
  ).text.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 노트 본문 — 마크다운을 서식·제목·목록·체크·인용·구분선·표·그림으로 그린다.
class NoteBody extends StatefulWidget {
  final String text;

  /// 그림 주소(서버 상대 경로)를 받을 수 있는 주소로. 없으면 그림 줄은 이름만 보인다.
  final String Function(String relative)? resolveUrl;

  const NoteBody(this.text, {super.key, this.resolveUrl});

  @override
  State<NoteBody> createState() => _NoteBodyState();
}

class _NoteBodyState extends State<NoteBody> {
  final List<TapGestureRecognizer> _recognizers = [];

  void _clearRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  TapGestureRecognizer _open(String url) {
    final uri = Uri.tryParse(url);
    final r = TapGestureRecognizer()
      ..onTap = () {
        if (AppLinks.open(url)) return;
        if (uri != null &&
            const {'http', 'https', 'mailto'}.contains(uri.scheme)) {
          launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      };
    _recognizers.add(r);
    return r;
  }

  Widget _rich(
    String text,
    List<int> flags,
    List<String?> hrefs,
    int s,
    int e,
    TextStyle base,
  ) {
    final spans = <InlineSpan>[];
    var i = s;
    while (i < e) {
      final f = flags[i] & ~Fmt.quote;
      final h = hrefs[i];
      var j = i + 1;
      while (j < e && (flags[j] & ~Fmt.quote) == f && hrefs[j] == h) {
        j++;
      }
      final style = formatStyle(context, base, f, h);
      spans.add(
        TextSpan(
          text: text.substring(i, j),
          style: style,
          recognizer: h != null ? _open(h) : null,
        ),
      );
      i = j;
    }
    return Text.rich(TextSpan(children: spans));
  }

  Widget _table(ThemeData theme, List<String> lines) {
    List<String> cells(String line) {
      var t = line.trim();
      if (t.startsWith('|')) t = t.substring(1);
      if (t.endsWith('|')) t = t.substring(0, t.length - 1);
      return [for (final c in t.split('|')) c.trim()];
    }

    final separator = RegExp(r'^:?-{3,}:?$');
    final rows = <(List<String>, bool)>[];
    for (final l in lines) {
      final c = cells(l);
      if (c.every((x) => separator.hasMatch(x))) {
        if (rows.isNotEmpty) rows[rows.length - 1] = (rows.last.$1, true);
        continue;
      }
      rows.add((c, false));
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    final cols = rows.map((r) => r.$1.length).reduce((a, b) => a > b ? a : b);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.all(color: theme.dividerColor),
          children: [
            for (final (r, header) in rows)
              TableRow(
                decoration: header
                    ? BoxDecoration(
                        color: theme.colorScheme.surfaceContainerLow,
                      )
                    : null,
                children: [
                  for (var c = 0; c < cols; c++)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Text(
                        c < r.length ? r[c] : '',
                        style: header
                            ? const TextStyle(fontWeight: FontWeight.w600)
                            : null,
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _clearRecognizers();
    final theme = Theme.of(context);
    final hint = theme.hintColor;
    final base = DefaultTextStyle.of(
      context,
    ).style.copyWith(fontSize: 14, height: 1.5);
    final (:text, :runs) = noteMarkdownToRich(widget.text);
    final flags = List<int>.filled(text.length, 0);
    final hrefs = List<String?>.filled(text.length, null);
    for (final r in runs) {
      for (var i = r.start; i < r.end; i++) {
        flags[i] |= r.flags;
        if (r.href != null) hrefs[i] = r.href;
      }
    }
    // 줄 위치.
    final lines = <(int, int)>[];
    var s = 0;
    for (final l in text.split('\n')) {
      lines.add((s, s + l.length));
      s += l.length + 1;
    }

    final widgets = <Widget>[];
    var li = 0;
    while (li < lines.length) {
      final (ls, le) = lines[li];
      final line = text.substring(ls, le);
      if (line.trim().isEmpty) {
        widgets.add(const SizedBox(height: 10));
        li++;
        continue;
      }
      if (line.trimLeft().startsWith('|')) {
        final block = <String>[];
        while (li < lines.length) {
          final (a, b) = lines[li];
          final l = text.substring(a, b);
          if (!l.trimLeft().startsWith('|')) break;
          block.add(l);
          li++;
        }
        widgets.add(_table(theme, block));
        continue;
      }
      li++;
      final lf = flags[ls] & Fmt.lineMask;
      final href = hrefs[ls];
      if (line == noteRule) {
        widgets.add(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(height: 1),
          ),
        );
      } else if (href != null && href.startsWith(noteImageHref)) {
        final url = href.substring(noteImageHref.length);
        final resolve = widget.resolveUrl;
        final name = line.substring(
          line.startsWith(noteImagePrefix) ? noteImagePrefix.length : 0,
        );
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: resolve == null
                ? Text('🖼 $name', style: TextStyle(color: hint))
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 420),
                    child: Image.network(
                      resolve(url),
                      fit: BoxFit.contain,
                      alignment: Alignment.centerLeft,
                      errorBuilder: (_, _, _) =>
                          Text('🖼 $name', style: TextStyle(color: hint)),
                    ),
                  ),
          ),
        );
      } else {
        final check = RegExp(r'^(\s*)(☐|☑) ').firstMatch(line);
        final bullet = RegExp(r'^(\s*)• ').firstMatch(line);
        Widget content;
        if (check != null) {
          final checked = check.group(2) == '☑';
          content = Padding(
            padding: EdgeInsets.only(left: check.group(1)!.length * 6.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    checked ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 18,
                    color: checked ? theme.colorScheme.primary : hint,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _rich(
                    text,
                    flags,
                    hrefs,
                    ls + check.end,
                    le,
                    checked
                        ? base.copyWith(
                            color: hint,
                            decoration: TextDecoration.lineThrough,
                          )
                        : base,
                  ),
                ),
              ],
            ),
          );
        } else if (bullet != null) {
          content = Padding(
            padding: EdgeInsets.only(left: 4.0 + bullet.group(1)!.length * 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: base),
                Expanded(
                  child: _rich(text, flags, hrefs, ls + bullet.end, le, base),
                ),
              ],
            ),
          );
        } else {
          content = _rich(text, flags, hrefs, ls, le, base);
        }
        if (lf & Fmt.quote != 0) {
          content = Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.only(left: 10),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: hint, width: 3)),
            ),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: hint),
              child: content,
            ),
          );
        }
        final top = lf & Fmt.h1 != 0
            ? 12.0
            : lf & Fmt.h2 != 0
            ? 10.0
            : lf & Fmt.h3 != 0
            ? 6.0
            : 2.0;
        widgets.add(
          Padding(
            padding: EdgeInsets.only(top: top, bottom: 2),
            child: content,
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: widgets,
    );
  }
}
