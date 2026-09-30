import 'dart:math' as math;

/// 붙여넣은 표 — 클립보드의 탭(TSV) 텍스트나 HTML `<table>`을 셀 2차원 배열로 읽은 결과. 입력창이 이걸 이미지로
/// 그려서 업로드 미리보기로 보낸다(잔디의 "표 이미지 삽입"). 순수 계산이라 화면·플랫폼 없이 단위 테스트한다.
class PastedTable {
  /// 행마다 같은 길이로 맞춘 셀 글자(빈 칸은 '').
  final List<List<String>> cells;

  /// 첫 행이 머리글(HTML의 `<th>`)이면 굵게 그린다.
  final bool hasHeader;
  const PastedTable(this.cells, {this.hasHeader = false});

  int get rowCount => cells.length;
  int get columnCount => cells.isEmpty ? 0 : cells.first.length;
}

/// 이보다 크면 이미지로 만들지 않고 일반 텍스트로 붙여넣는다(너무 커서 읽을 수도 업로드하기도 어렵다).
const int kPasteTableMaxRows = 100;
const int kPasteTableMaxColumns = 30;

/// 탭으로 나눈 텍스트(엑셀·웹 표를 복사하면 이 모양이다)를 행렬로 읽는다. 엑셀이 줄바꿈·탭을 담은 칸을 큰따옴표로
/// 감싸 주는 규칙(`"a""b"` = `a"b`)을 따른다. 끝의 빈 줄은 버리고, 칸 수가 다른 행은 빈 칸으로 채워 모양을 맞춘다.
List<List<String>> parseTsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var fieldStart = true; // 지금 칸의 첫 글자를 기다리는 중(따옴표는 칸 첫머리에서만 여는 따옴표다).
  void endField() {
    row.add(field.toString());
    field.clear();
    fieldStart = true;
  }

  void endRow() {
    endField();
    rows.add(row);
    row = <String>[];
  }

  final s = text;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < s.length && s[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(c);
      }
      continue;
    }
    if (c == '"' && fieldStart) {
      inQuotes = true;
      fieldStart = false;
    } else if (c == '\t') {
      endField();
    } else if (c == '\n') {
      endRow();
    } else if (c == '\r') {
      // \r\n의 \r — 줄 끝은 \n이 맡는다. 홀로 온 \r도 줄바꿈으로 본다.
      if (i + 1 >= s.length || s[i + 1] != '\n') endRow();
    } else {
      field.write(c);
      fieldStart = false;
    }
  }
  // 마지막 줄이 줄바꿈 없이 끝났으면 그 줄도 넣는다(줄바꿈으로 끝난 뒤의 빈 조각은 넣지 않는다).
  if (field.isNotEmpty || row.isNotEmpty || inQuotes) endRow();
  return _rectangular(rows);
}

/// HTML의 첫 `<table>`을 행렬로 읽는다(`colspan`·`rowspan`은 칸을 늘려 맞추고, 중첩 표는 바깥 표 칸의 글자로만 본다).
/// 표가 없으면 null. 엑셀·워드·브라우저가 클립보드에 올리는 HTML(CF_HTML 머리글이 붙어 있어도 된다)을 받는다.
PastedTable? parseHtmlTable(String html) {
  final start = html.toLowerCase().indexOf('<table');
  if (start < 0) return null;
  final tokens = RegExp(
    r'''<!--[\s\S]*?-->|<![\s\S]*?>|<(/?)([a-zA-Z][a-zA-Z0-9]*)((?:"[^"]*"|'[^']*'|[^>"'])*)>|([^<]+)|<''',
  );
  final rows = <List<String>>[];
  final headerFlags = <List<bool>>[];
  var depth = 0; // <table> 중첩 깊이 — 바깥 표(1)만 구조로 읽는다.
  var finished = false;
  List<String>? row;
  List<bool>? rowHeaders;
  StringBuffer? cell;
  var cellIsHeader = false;
  var cellColSpan = 1;
  var cellRowSpan = 1;
  var skipText = 0; // <style>/<script> 안의 글자는 건너뛴다.
  // 앞 행에서 내려온 rowspan이 차지한 칸 — 열 번호 → 남은 행 수.
  final carried = <int, int>{};

  int nextFreeColumn() {
    var c = row!.length;
    while ((carried[c] ?? 0) > 0) {
      c++;
    }
    return c;
  }

  void fillCarried() {
    // 행 머리에서 rowspan이 내려온 칸을 빈 칸으로 채운다.
    var c = row!.length;
    while ((carried[c] ?? 0) > 0) {
      row!.add('');
      rowHeaders!.add(false);
      c = row!.length;
    }
  }

  void endCell() {
    if (cell == null) return;
    fillCarried();
    final col = nextFreeColumn();
    while (row!.length < col) {
      row!.add('');
      rowHeaders!.add(false);
    }
    final text = _collapse(cell.toString());
    for (var k = 0; k < cellColSpan; k++) {
      row!.add(k == 0 ? text : '');
      rowHeaders!.add(cellIsHeader);
      if (cellRowSpan > 1) carried[col + k] = cellRowSpan; // 이 행 포함이라 끝에서 하나 줄인다.
    }
    cell = null;
    cellIsHeader = false;
    cellColSpan = 1;
    cellRowSpan = 1;
  }

  void endRow() {
    endCell();
    if (row == null) return;
    fillCarried();
    // rowspan이 남은 칸은 이 행에서 한 번 썼다.
    for (final k in carried.keys.toList()) {
      final left = (carried[k] ?? 0) - 1;
      if (left <= 0) {
        carried.remove(k);
      } else {
        carried[k] = left;
      }
    }
    rows.add(row!);
    headerFlags.add(rowHeaders!);
    row = null;
    rowHeaders = null;
  }

  for (final m in tokens.allMatches(html, start)) {
    if (finished) break;
    final text = m.group(4);
    final tag = m.group(2)?.toLowerCase();
    if (text != null) {
      final open = cell;
      if (depth >= 1 && open != null && skipText == 0) {
        // 소스의 줄바꿈은 공백 하나(HTML 규칙) — 진짜 줄바꿈은 <br>이 넣는다.
        open.write(_decode(text.replaceAll(RegExp(r'[\r\n]+'), ' ')));
      }
      continue;
    }
    if (tag == null) continue; // 주석·조건부 주석·홀로 있는 '<'.
    final closing = m.group(1) == '/';
    final attrs = m.group(3) ?? '';
    if (tag == 'style' || tag == 'script') {
      skipText += closing ? -1 : 1;
      if (skipText < 0) skipText = 0;
      continue;
    }
    if (tag == 'table') {
      if (closing) {
        depth--;
        if (depth == 0) {
          endRow();
          finished = true;
        }
      } else {
        depth++;
      }
      continue;
    }
    if (depth != 1) continue; // 중첩 표의 구조 태그는 무시한다(글자는 위에서 바깥 칸에 들어간다).
    switch (tag) {
      case 'tr':
        if (closing) {
          endRow();
        } else {
          endRow();
          row = <String>[];
          rowHeaders = <bool>[];
        }
      case 'td' || 'th':
        if (closing) {
          endCell();
        } else {
          endCell();
          row ??= <String>[];
          rowHeaders ??= <bool>[];
          cell = StringBuffer();
          cellIsHeader = tag == 'th';
          cellColSpan = _spanOf(attrs, 'colspan');
          cellRowSpan = _spanOf(attrs, 'rowspan');
        }
      case 'br':
        cell?.write('\n');
      case 'p' || 'div':
        final open = cell;
        if (open != null && open.isNotEmpty && closing) open.write('\n');
    }
  }
  endRow();
  if (rows.isEmpty) return null;
  final hasHeader =
      headerFlags.isNotEmpty &&
      headerFlags.first.isNotEmpty &&
      headerFlags.first.every((h) => h);
  return PastedTable(_rectangular(rows), hasHeader: hasHeader);
}

int _spanOf(String attrs, String name) {
  final m = RegExp(
    '$name\\s*=\\s*(?:"?\'?)(\\d+)',
    caseSensitive: false,
  ).firstMatch(attrs);
  final n = m == null ? 1 : int.tryParse(m.group(1)!) ?? 1;
  return n.clamp(1, kPasteTableMaxColumns + 1);
}

/// 한 칸 안의 글자 정리 — 줄 끝·공백 덩어리는 한 칸으로 줄이고, <br>이 넣은 줄바꿈은 살린다.
String _collapse(String raw) {
  final lines = raw
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t\r\u00a0]+'), ' ').trim())
      .toList();
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines.join('\n');
}

const _entities = {
  'nbsp': '\u00a0',
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'middot': '·',
  'hellip': '…',
  'ndash': '–',
  'mdash': '—',
  'times': '×',
  'copy': '©',
};

String _decode(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);'), (m) {
    final body = m.group(1)!;
    if (body.startsWith('#x')) {
      final code = int.tryParse(body.substring(2), radix: 16);
      return code == null ? m.group(0)! : String.fromCharCode(code);
    }
    if (body.startsWith('#')) {
      final code = int.tryParse(body.substring(1));
      return code == null ? m.group(0)! : String.fromCharCode(code);
    }
    return _entities[body] ?? m.group(0)!;
  });
}

List<List<String>> _rectangular(List<List<String>> rows) {
  final width = rows.fold<int>(0, (w, r) => math.max(w, r.length));
  return [
    for (final r in rows) [...r, for (var i = r.length; i < width; i++) ''],
  ];
}

/// 행렬이 "표"로 볼 만한지 — 2행 2열 이상이고, 칸이 둘 이상 찬 행이 둘 이상이며 그런 행이 절반 이상이다.
/// (앞에 탭 들여쓰기만 있는 코드·목록이 표로 오인되지 않게 한다.)
bool looksLikeTable(List<List<String>> cells) {
  if (cells.length < 2) return false;
  final width = cells.fold<int>(0, (w, r) => math.max(w, r.length));
  if (width < 2) return false;
  final multi = cells
      .where((r) => r.where((c) => c.trim().isNotEmpty).length >= 2)
      .length;
  return multi >= 2 && multi * 2 >= cells.length;
}

/// 글자(TSV)와 HTML 중 표를 골라 읽는다 — 표가 아니거나 [kPasteTableMaxRows]×[kPasteTableMaxColumns]를 넘으면 null(일반
/// 텍스트로 붙여넣는다). 탭 텍스트가 표로 읽히면 그걸 먼저 쓰고(엑셀·브라우저 공통이고 가장 믿을 만하다), 아니면 HTML
/// `<table>`(머리글 `<th>`·병합 칸을 살린다)을 쓴다.
PastedTable? detectPastedTable({String? text, String? html}) {
  PastedTable? fromText;
  if (text != null && text.contains('\t')) {
    final cells = parseTsv(text);
    if (looksLikeTable(cells)) fromText = PastedTable(cells);
  }
  PastedTable? fromHtml;
  if (html != null && html.toLowerCase().contains('<table')) {
    final t = parseHtmlTable(html);
    if (t != null && looksLikeTable(t.cells)) fromHtml = t;
  }
  // 글자에 머리글 정보가 없으니, 같은 모양이면 HTML의 머리글 표시만 가져온다.
  final table = fromText == null
      ? fromHtml
      : (fromHtml != null &&
                fromHtml.hasHeader &&
                fromHtml.rowCount == fromText.rowCount &&
                fromHtml.columnCount == fromText.columnCount
            ? PastedTable(fromText.cells, hasHeader: true)
            : fromText);
  if (table == null) return null;
  if (table.rowCount > kPasteTableMaxRows ||
      table.columnCount > kPasteTableMaxColumns) {
    return null;
  }
  return table;
}

/// 표처럼 보이는 글자·HTML인지(크기 제한과 무관하게) — 클립보드에 이미지가 함께 있을 때 "엑셀 표의 비트맵"인지 가린다.
bool clipboardLooksTabular({String? text, String? html}) {
  if (html != null && html.toLowerCase().contains('<table')) return true;
  if (text != null && text.contains('\t')) {
    return looksLikeTable(parseTsv(text));
  }
  return false;
}
