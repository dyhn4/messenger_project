import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/mention.dart';
import '../models/text_format.dart';
import '../services/app_links.dart';
import '../services/mention_logic.dart';

export '../models/text_format.dart';
import '../l10n/tr.dart';

// 글자 서식(굵게·기울임·밑줄·취소선·코드·인용·링크).
//
// 본문은 평문 그대로 두고, 어느 구간에 어떤 서식이 걸렸는지만 [TextFormatRun] 목록으로 따로
// 저장한다(서버 textFormat.js와 같은 모양) — 그래서 알림·방 목록 미리보기·검색·답장 인용은
// 지금처럼 평문만 쓰면 되고, 서식 기호("**" 같은)가 글에 섞이지 않는다.
// 목록(번호·글머리)은 "1. ", "• "를 글자로 넣는다 — 미리보기에서도 목록으로 읽히게.

/// 글자마다의 서식 — 구간 목록 ↔ 글자 배열 변환에 쓴다.
class _Chars {
  final List<int> flags;
  final List<String?> hrefs;
  _Chars(this.flags, this.hrefs);

  factory _Chars.fromRuns(int length, List<TextFormatRun>? runs) {
    final flags = List<int>.filled(length, 0, growable: true);
    final hrefs = List<String?>.filled(length, null, growable: true);
    for (final r in runs ?? const <TextFormatRun>[]) {
      final end = math.min(r.end, length);
      for (var i = math.max(0, r.start); i < end; i++) {
        flags[i] |= r.flags;
        if (r.href != null) hrefs[i] = r.href;
      }
    }
    return _Chars(flags, hrefs);
  }

  List<TextFormatRun> toRuns([int from = 0, int? to]) {
    final end = to ?? flags.length;
    final runs = <TextFormatRun>[];
    var i = from;
    while (i < end) {
      final f = flags[i], h = hrefs[i];
      var j = i + 1;
      while (j < end && flags[j] == f && hrefs[j] == h) {
        j++;
      }
      if (f != 0 || h != null) {
        runs.add(TextFormatRun(i - from, j - from, f, h));
      }
      i = j;
    }
    return runs;
  }
}

/// 서식 비트를 글자 모양으로. [linkColor]는 링크 글자색(말풍선 배경에 맞춰 부르는 쪽이 준다).
TextStyle formatStyle(
  BuildContext context,
  TextStyle base,
  int flags,
  String? href, {
  Color? linkColor,
}) {
  final theme = Theme.of(context);
  var s = base;
  if (flags & Fmt.bold != 0) s = s.copyWith(fontWeight: FontWeight.bold);
  if (flags & Fmt.italic != 0) s = s.copyWith(fontStyle: FontStyle.italic);
  final decorations = [
    if (base.decoration != null) base.decoration!,
    if (flags & Fmt.underline != 0 || href != null) TextDecoration.underline,
    if (flags & Fmt.strike != 0) TextDecoration.lineThrough,
  ];
  if (decorations.isNotEmpty) {
    s = s.copyWith(decoration: TextDecoration.combine(decorations));
  }
  if (flags & Fmt.code != 0) {
    s = s.copyWith(
      fontFamily: 'Consolas',
      fontFamilyFallback: const ['monospace'],
      backgroundColor: theme.hintColor.withValues(alpha: 0.15),
    );
  }
  if (flags & Fmt.quote != 0) {
    s = s.copyWith(
      color: (base.color ?? theme.hintColor).withValues(alpha: 0.7),
    );
  }
  if (flags & Fmt.headings != 0) {
    final size = base.fontSize ?? 14;
    final scale = flags & Fmt.h1 != 0
        ? 1.9
        : flags & Fmt.h2 != 0
        ? 1.55
        : 1.3;
    s = s.copyWith(fontSize: size * scale, fontWeight: FontWeight.bold);
  }
  final rgb = Fmt.colorOf(flags);
  if (rgb != null) s = s.copyWith(color: Color(0xFF000000 | rgb));
  if (href != null) {
    s = s.copyWith(color: linkColor ?? theme.colorScheme.primary);
  }
  return s;
}

/// 켜져 있는 서식 도구(와 펼쳐진 "T" 버튼)의 색 — 하늘색.
const richFormatActiveColor = Colors.lightBlue;

// ── 입력 ────────────────────────────────────────────────────────────────

/// 서식을 입력한 그대로 보여주는 입력칸 컨트롤러. 글은 평문으로 들고, 글자마다의 서식을 따로
/// 들고 있다가 [buildTextSpan]에서 입혀 그린다. 글이 바뀌면(타이핑·붙여넣기·지우기) 바뀐 구간만
/// 찾아 서식 배열도 같이 밀고 당긴다.
class RichTextEditingController extends TextEditingController {
  RichTextEditingController({super.text})
    : _chars = _Chars.fromRuns(text?.length ?? 0, null);

  _Chars _chars;

  /// 커서만 있을 때 서식 버튼을 누르면 "다음에 칠 글자"에 줄 서식을 여기 들고 있는다.
  int? _pending;

  /// 서식을 담을지 — 비밀 대화처럼 서식을 못 보내는 곳이면 false(입력은 평문 그대로).
  bool formattingEnabled = true;

  /// 멘션(@이름·@all)을 추적할지 — 채팅·댓글·게시글·예약 입력칸만 켠다(비밀 대화는 끈다).
  bool mentionsEnabled = false;

  /// 글 안에서 지금 멘션으로 잡혀 있는 구간들(시작 위치순). 글이 바뀌면 [remapMentionsForEdit]로 따라가고,
  /// 이름을 고치거나 지워서 어긋나면 그 멘션은 풀린다.
  List<Mention> _mentions = [];
  List<Mention> get mentions => List.unmodifiable(_mentions);

  bool _manual = false;

  /// 한글 등 IME로 글자를 조합하고 있는지 — Windows는 조합 중이 아니어도 조합 영역을
  /// (0,0)처럼 빈 구간으로 보내서, "유효한 구간"만으로 보면 늘 조합 중으로 잘못 본다.
  static bool _composing(TextEditingValue v) =>
      v.composing.isValid && !v.composing.isCollapsed;

  // ── 값이 바뀔 때 서식 배열 따라가기 ──

  @override
  set value(TextEditingValue newValue) {
    if (_manual) {
      super.value = newValue;
      return;
    }
    final old = super.value;
    if (newValue.text != old.text) {
      newValue = _followEdit(old, newValue);
    } else if (newValue.selection != old.selection && !_composing(newValue)) {
      _pending = null;
    }
    super.value = newValue;
  }

  TextEditingValue _followEdit(TextEditingValue old, TextEditingValue next) {
    final o = old.text, n = next.text;
    if (_chars.flags.length != o.length) {
      _chars = _Chars.fromRuns(o.length, null);
    }
    var pre = 0;
    final maxPre = math.min(o.length, n.length);
    while (pre < maxPre && o.codeUnitAt(pre) == n.codeUnitAt(pre)) {
      pre++;
    }
    // 같은 글자가 이어질 때("ㅋㅋ") 어느 자리에 끼웠는지는 커서 위치로 정한다.
    final sel = next.selection;
    if (sel.isValid && sel.isCollapsed && n.length > o.length) {
      pre = math.min(pre, math.max(0, sel.baseOffset - (n.length - o.length)));
    }
    var suf = 0;
    final maxSuf = math.min(o.length, n.length) - pre;
    while (suf < maxSuf &&
        o.codeUnitAt(o.length - 1 - suf) == n.codeUnitAt(n.length - 1 - suf)) {
      suf++;
    }
    final removedEnd = o.length - suf;
    final insertedEnd = n.length - suf;
    final count = insertedEnd - pre;
    if (mentionsEnabled && _mentions.isNotEmpty) {
      _mentions = remapMentionsForEdit(_mentions, pre, removedEnd - pre, count);
    }

    var flags = 0;
    String? href;
    if (!sel.isValid) {
      // 코드에서 글을 통째로 바꾼 경우(controller.text = ...) — 서식 없이.
    } else if (_pending != null) {
      flags = _pending!;
    } else if (removedEnd > pre) {
      flags = _chars.flags[pre];
      href = _chars.hrefs[pre];
    } else if (pre > 0) {
      flags = _chars.flags[pre - 1];
      // 링크는 한가운데에 끼울 때만 이어 붙인다(링크 끝에서 계속 치면 평범한 글자).
      final prevHref = _chars.hrefs[pre - 1];
      if (prevHref != null &&
          removedEnd < o.length &&
          _chars.hrefs[removedEnd] == prevHref) {
        href = prevHref;
      }
    } else if (removedEnd < o.length) {
      flags = _chars.flags[removedEnd] & Fmt.lineMask;
    }
    _chars.flags.replaceRange(pre, removedEnd, List.filled(count, flags));
    _chars.hrefs.replaceRange(pre, removedEnd, List.filled(count, href));
    if (count > 0) _pending = null;

    // 노트 링크(tangotalk://…)를 붙여넣으면 주소 대신 "[MKT-N10] 제목" 링크 글자로 바꾼다.
    if (count > 1 && formattingEnabled && !_composing(next)) {
      final pasted = n.substring(pre, insertedEnd);
      final display = AppLinks.displayText(pasted);
      if (display != null && display.isNotEmpty) {
        _chars.flags.replaceRange(
          pre,
          pre + count,
          List.filled(display.length, flags & ~Fmt.code),
        );
        _chars.hrefs.replaceRange(
          pre,
          pre + count,
          List<String?>.filled(display.length, pasted.trim()),
        );
        _remapMentions(pre, count, display.length);
        return TextEditingValue(
          text: n.replaceRange(pre, insertedEnd, display),
          selection: TextSelection.collapsed(offset: pre + display.length),
        );
      }
    }

    // 목록 줄에서 줄바꿈 → 다음 번호/글머리를 이어 붙인다(빈 항목이면 목록을 끝낸다).
    if (count == 1 &&
        removedEnd == pre &&
        n.codeUnitAt(pre) == 0x0A &&
        !_composing(next)) {
      return _continueList(next, pre);
    }
    return next;
  }

  static final _listPrefix = RegExp(r'^(\d+)\. |^• ');

  TextEditingValue _continueList(TextEditingValue v, int nl) {
    final t = v.text;
    final lineStart = nl == 0 ? 0 : t.lastIndexOf('\n', nl - 1) + 1;
    final line = t.substring(lineStart, nl);
    final m = _listPrefix.firstMatch(line);
    if (m == null) return v;
    if (line.length == m.end) {
      _chars.flags.removeRange(lineStart, nl + 1);
      _chars.hrefs.removeRange(lineStart, nl + 1);
      _remapMentions(lineStart, nl + 1 - lineStart, 0);
      return TextEditingValue(
        text: t.replaceRange(lineStart, nl + 1, ''),
        selection: TextSelection.collapsed(offset: lineStart),
      );
    }
    final prefix = m.group(1) != null
        ? '${int.parse(m.group(1)!) + 1}. '
        : '• ';
    final at = nl + 1;
    final quote = _chars.flags[nl] & Fmt.quote;
    _chars.flags.insertAll(at, List.filled(prefix.length, quote));
    _chars.hrefs.insertAll(at, List<String?>.filled(prefix.length, null));
    _remapMentions(at, 0, prefix.length);
    return TextEditingValue(
      text: t.replaceRange(at, at, prefix),
      selection: TextSelection.collapsed(offset: at + prefix.length),
    );
  }

  void _remapMentions(int at, int removed, int inserted) {
    if (mentionsEnabled && _mentions.isNotEmpty) {
      _mentions = remapMentionsForEdit(_mentions, at, removed, inserted);
    }
  }

  /// 서식 배열을 직접 고친 뒤(글은 그대로) 화면을 다시 그리게 한다.
  void _touch() => notifyListeners();

  /// 글과 서식을 같이 바꾼다 — [ops]는 (위치, 지울 길이, 넣을 글, 넣을 글의 서식) 목록이고
  /// 뒤에서부터 적용한다(앞의 위치가 밀리지 않게).
  void _edit(
    List<(int, int, String, int)> ops,
    TextSelection Function(String text) selection,
  ) {
    var t = text;
    final sorted = [...ops]..sort((a, b) => b.$1.compareTo(a.$1));
    for (final (at, remove, insert, flags) in sorted) {
      _remapMentions(at, remove, insert.length);
      t = t.replaceRange(at, at + remove, insert);
      _chars.flags.replaceRange(
        at,
        at + remove,
        List.filled(insert.length, flags),
      );
      _chars.hrefs.replaceRange(
        at,
        at + remove,
        List<String?>.filled(insert.length, null),
      );
    }
    _manual = true;
    try {
      super.value = TextEditingValue(text: t, selection: selection(t));
    } finally {
      _manual = false;
    }
  }

  // ── 서식 버튼 ──

  TextSelection get _sel => selection.isValid
      ? selection
      : TextSelection.collapsed(offset: text.length);

  int get _cursorFlags {
    final p = _sel.baseOffset;
    if (p > 0 && p <= _chars.flags.length) return _chars.flags[p - 1];
    return 0;
  }

  /// 도구모음이 버튼을 눌린 모양으로 그릴지.
  bool isActive(int flag) {
    final sel = _sel;
    if (sel.isCollapsed) return ((_pending ?? _cursorFlags) & flag) != 0;
    for (var i = sel.start; i < sel.end; i++) {
      if (_chars.flags[i] & flag == 0) return false;
    }
    return true;
  }

  String? get currentHref {
    final sel = _sel;
    final i = sel.isCollapsed ? sel.baseOffset - 1 : sel.start;
    return i >= 0 && i < _chars.hrefs.length ? _chars.hrefs[i] : null;
  }

  /// 굵게·기울임·밑줄·취소선·코드 — 고른 글자에 바로 걸고, 모두 걸려 있으면 푼다. 고른 게
  /// 없으면 다음에 칠 글자부터 적용된다.
  void toggle(int flag) {
    final sel = _sel;
    if (sel.isCollapsed) {
      _pending = (_pending ?? _cursorFlags) ^ flag;
      _touch();
      return;
    }
    final on = !isActive(flag);
    for (var i = sel.start; i < sel.end; i++) {
      _chars.flags[i] = on ? _chars.flags[i] | flag : _chars.flags[i] & ~flag;
    }
    _touch();
  }

  (int, int) _lineRange() {
    final t = text;
    final sel = _sel;
    final start = sel.start == 0 ? 0 : t.lastIndexOf('\n', sel.start - 1) + 1;
    var end = t.indexOf('\n', sel.end);
    if (end < 0) end = t.length;
    return (start, end);
  }

  /// 인용 — 커서가 걸친 줄 전체에 걸거나 푼다.
  void toggleQuote() {
    final (start, end) = _lineRange();
    if (start == end) {
      _pending = (_pending ?? _cursorFlags) ^ Fmt.quote;
      _touch();
      return;
    }
    var all = true;
    for (var i = start; i < end; i++) {
      if (text.codeUnitAt(i) != 0x0A && _chars.flags[i] & Fmt.quote == 0) {
        all = false;
        break;
      }
    }
    for (var i = start; i < end; i++) {
      _chars.flags[i] = all
          ? _chars.flags[i] & ~Fmt.quote
          : _chars.flags[i] | Fmt.quote;
    }
    _touch();
  }

  /// 번호·글머리 목록 — 커서가 걸친 줄마다 "1. "·"• "를 붙이거나(이미 모두 있으면) 뗀다.
  void toggleList({required bool ordered}) {
    final (start, end) = _lineRange();
    final t = text;
    final lines = <int>[start];
    for (var i = start; i < end; i++) {
      if (t.codeUnitAt(i) == 0x0A) lines.add(i + 1);
    }
    final pattern = ordered ? RegExp(r'^\d+\. ') : RegExp(r'^• ');
    String lineAt(int s) {
      final e = t.indexOf('\n', s);
      return t.substring(s, e < 0 ? t.length : e);
    }

    final all = lines.every((s) => pattern.hasMatch(lineAt(s)));
    final ops = <(int, int, String, int)>[];
    for (final (i, s) in lines.indexed) {
      final line = lineAt(s);
      final quote = s < _chars.flags.length ? _chars.flags[s] & Fmt.quote : 0;
      if (all) {
        ops.add((s, pattern.firstMatch(line)!.end, '', 0));
      } else {
        // 다른 종류의 목록 기호가 붙어 있으면 바꿔 단다.
        final other = _listPrefix.firstMatch(line);
        ops.add((s, other?.end ?? 0, ordered ? '${i + 1}. ' : '• ', quote));
      }
    }
    final delta = ops.fold<int>(0, (sum, op) => sum + op.$3.length - op.$2);
    _edit(ops, (_) => TextSelection.collapsed(offset: end + delta));
  }

  /// 링크 — 고른 글자에 주소를 걸거나([href]가 비면 뗀다), 고른 게 없으면 [label]을 링크로 넣는다.
  void applyLink(String? href, {String? label}) {
    final sel = _sel;
    if (sel.isCollapsed) {
      if (href == null || label == null || label.isEmpty) return;
      final at = sel.baseOffset;
      _edit([
        (at, 0, label, _cursorFlags & ~Fmt.code),
      ], (_) => TextSelection.collapsed(offset: at + label.length));
      for (var i = at; i < at + label.length; i++) {
        _chars.hrefs[i] = href;
      }
      _touch();
      return;
    }
    for (var i = sel.start; i < sel.end; i++) {
      _chars.hrefs[i] = href;
    }
    _touch();
  }

  /// 제목(1~3) — 커서가 걸친 줄 전체를 그 크기 제목으로 바꾸거나, 이미 그 제목이면 푼다.
  void toggleHeading(int level) {
    final flag = switch (level) {
      1 => Fmt.h1,
      2 => Fmt.h2,
      _ => Fmt.h3,
    };
    final (start, end) = _lineRange();
    if (start == end) {
      final cur = _pending ?? _cursorFlags;
      _pending = cur & flag != 0
          ? cur & ~Fmt.headings
          : (cur & ~Fmt.headings) | flag;
      _touch();
      return;
    }
    var all = true;
    for (var i = start; i < end; i++) {
      if (text.codeUnitAt(i) != 0x0A && _chars.flags[i] & flag == 0) {
        all = false;
        break;
      }
    }
    for (var i = start; i < end; i++) {
      final f = _chars.flags[i] & ~Fmt.headings;
      _chars.flags[i] = all ? f : f | flag;
    }
    _touch();
  }

  /// 커서(또는 고른 글자 첫 자리)의 글자색 — 없으면 null.
  int? get currentColor {
    final sel = _sel;
    if (sel.isCollapsed) return Fmt.colorOf(_pending ?? _cursorFlags);
    return sel.start < _chars.flags.length
        ? Fmt.colorOf(_chars.flags[sel.start])
        : null;
  }

  /// 글자색 — 고른 글자에 바로, 고른 게 없으면 다음에 칠 글자부터. [rgb]가 null이면 기본색.
  void applyColor(int? rgb) {
    final sel = _sel;
    if (sel.isCollapsed) {
      _pending = Fmt.withColor(_pending ?? _cursorFlags, rgb);
      _touch();
      return;
    }
    for (var i = sel.start; i < sel.end; i++) {
      _chars.flags[i] = Fmt.withColor(_chars.flags[i], rgb);
    }
    _touch();
  }

  /// 줄 단위 내용(표·그림 줄 등)을 커서 자리에 따로 줄을 잡아 넣는다. [href]를 주면 넣은
  /// 글자에 그 주소를 걸어 둔다(그림 줄은 'image:<주소>').
  void insertBlock(String block, {String? href}) {
    final t = text;
    final at = _sel.start;
    final before = at == 0 || t.codeUnitAt(at - 1) == 0x0A ? '' : '\n';
    final after = at < t.length && t.codeUnitAt(at) == 0x0A ? '' : '\n';
    final inserted = '$before$block$after';
    _edit([
      (at, _sel.end - at, inserted, 0),
    ], (_) => TextSelection.collapsed(offset: at + inserted.length));
    if (href != null) {
      final s = at + before.length;
      for (var i = s; i < s + block.length; i++) {
        _chars.hrefs[i] = href;
      }
      _touch();
    }
  }

  /// 구분선 — 커서 자리에 한 줄로 넣는다(평문 미리보기에서도 선으로 보이게 글자로).
  void insertRule() {
    final t = text;
    final at = _sel.start;
    final atLineStart = at == 0 || t.codeUnitAt(at - 1) == 0x0A;
    final inserted = '${atLineStart ? '' : '\n'}──────────\n';
    _edit([
      (at, _sel.end - at, inserted, 0),
    ], (_) => TextSelection.collapsed(offset: at + inserted.length));
  }

  /// 인용 줄 묶음 — 이어진 인용 줄들을 하나로 묶은 [시작, 끝) 목록(줄바꿈은 뺀다).
  /// 입력칸 왼쪽 세로줄(RichFieldWrapper)이 이 구간들의 글자 자리를 물어 그린다.
  List<(int, int)> quoteBlocks() {
    final t = text;
    if (_chars.flags.length != t.length) return const [];
    final blocks = <(int, int)>[];
    var lineStart = 0;
    while (lineStart < t.length) {
      var lineEnd = t.indexOf('\n', lineStart);
      if (lineEnd < 0) lineEnd = t.length;
      final quoted =
          lineEnd > lineStart && _chars.flags[lineStart] & Fmt.quote != 0;
      if (quoted) {
        if (blocks.isNotEmpty && blocks.last.$2 == lineStart - 1) {
          blocks[blocks.length - 1] = (blocks.last.$1, lineEnd);
        } else {
          blocks.add((lineStart, lineEnd));
        }
      }
      lineStart = lineEnd + 1;
    }
    return blocks;
  }

  // ── 불러오기 / 내보내기 ──

  /// 저장된 글과 서식을 입력칸에 채운다(수정할 때).
  void load(
    String text,
    List<TextFormatRun>? format, {
    List<Mention>? mentions,
  }) {
    _chars = _Chars.fromRuns(text.length, format);
    _pending = null;
    _mentions = mentionsEnabled && mentions != null
        ? sanitizeMentions(mentions, text)
        : [];
    _manual = true;
    try {
      super.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    } finally {
      _manual = false;
    }
  }

  /// 보낼 글(앞뒤 공백을 뗀 것)과 그에 맞춘 서식 구간. 서식이 없으면 format은 null.
  ({String text, List<TextFormatRun>? format}) formatted() {
    final t = text;
    final (start, end) = _trimRange(t);
    final body = t.substring(start, end);
    if (!formattingEnabled || _chars.flags.length != t.length) {
      return (text: body, format: null);
    }
    final runs = _chars.toRuns(start, end);
    return (text: body, format: runs.isEmpty ? null : runs);
  }

  /// 입력칸의 글을 앞뒤 공백까지 그대로(서식·멘션 포함) 꺼낸다 — [load]로 그대로 되돌릴 수 있다.
  /// 보낼 때 쓰는 [formatted]와 달리 다듬지 않는다(쓰다 만 글을 잠시 맡겨 둘 때 쓴다).
  ({String text, List<TextFormatRun>? format, List<Mention> mentions})
  snapshot() {
    final t = text;
    final runs = formattingEnabled && _chars.flags.length == t.length
        ? _chars.toRuns()
        : const <TextFormatRun>[];
    return (
      text: t,
      format: runs.isEmpty ? null : runs,
      mentions: List.of(_mentions),
    );
  }

  /// 앞뒤 공백을 뗀 [시작, 끝) — formatted()와 [formattedMentions]가 같은 기준을 쓴다.
  (int, int) _trimRange(String t) {
    var start = 0, end = t.length;
    while (start < end && _isSpace(t.codeUnitAt(start))) {
      start++;
    }
    while (end > start && _isSpace(t.codeUnitAt(end - 1))) {
      end--;
    }
    return (start, end);
  }

  /// 보낼 글([formatted]의 text)에 맞춘 멘션 — 앞뒤 공백을 뗀 만큼 위치를 당기고, 어긋났거나(글자가 '@'가
  /// 아님) 허용 안 되는 것([allowAll] 아니면 @all, 자기 자신, 중복, 50개 초과)은 뺀다. 멘션을 안 쓰는
  /// 입력칸이면 빈 목록.
  List<Mention> formattedMentions({bool allowAll = true, String? selfUserId}) {
    if (!mentionsEnabled || _mentions.isEmpty) return const [];
    final t = text;
    final (start, end) = _trimRange(t);
    return sanitizeMentions(
      sliceMentions(_mentions, start, end),
      t.substring(start, end),
      allowAll: allowAll,
      selfUserId: selfUserId,
    );
  }

  /// 자동완성에서 고른 사람을 입력칸에 넣는다 — [start, end)("@"와 지금까지 친 글자)를 "@이름 "으로
  /// 바꾸고 커서를 그 뒤로 옮기며 그 구간을 멘션으로 잡는다. [userId]가 null이면 @all.
  void insertMention({
    required int start,
    required int end,
    required String label,
    String? userId,
  }) {
    if (!mentionsEnabled) return;
    final insert = '@$label ';
    final hasSpaceAfter = end < text.length && _isSpace(text.codeUnitAt(end));
    // 커서 뒤에 이미 공백이 있으면 하나 더 넣지 않는다.
    final inserted = hasSpaceAfter
        ? insert.substring(0, insert.length - 1)
        : insert;
    final spanEnd = start + 1 + label.length;
    _edit(
      [(start, end - start, inserted, 0)],
      (_) => TextSelection.collapsed(
        offset: start + inserted.length + (hasSpaceAfter ? 1 : 0),
      ),
    );
    final m = userId == null
        ? Mention.all(start: start, end: spanEnd)
        : Mention.user(userId, start: start, end: spanEnd);
    _mentions = [..._mentions, m]..sort((a, b) => a.start.compareTo(b.start));
    _touch();
  }

  static bool _isSpace(int c) =>
      c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x3000;

  @override
  void clear() {
    _pending = null;
    _mentions = [];
    super.clear();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final t = text;
    if (t.isEmpty || _chars.flags.length != t.length) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final base = style ?? const TextStyle();
    final composing = withComposing && value.isComposingRangeValid
        ? value.composing
        : TextRange.empty;
    bool inComposing(int i) =>
        composing.isValid && i >= composing.start && i < composing.end;
    // 멘션으로 잡힌 글자 — 입력하는 중에도 "@이름"이 멘션으로 보이게 강조한다.
    final mentionAt = mentionsEnabled && _mentions.isNotEmpty
        ? _mentionIndex(t.length, _mentions)
        : null;
    final mentionColor = Theme.of(context).colorScheme.primary;
    final children = <TextSpan>[];
    var i = 0;
    while (i < t.length) {
      final f = _chars.flags[i], h = _chars.hrefs[i], c = inComposing(i);
      final mi = mentionAt?[i] ?? -1;
      var j = i + 1;
      while (j < t.length &&
          _chars.flags[j] == f &&
          _chars.hrefs[j] == h &&
          inComposing(j) == c &&
          (mentionAt?[j] ?? -1) == mi) {
        j++;
      }
      var s = formatStyle(context, base, f, h);
      if (mi >= 0) {
        s = s.copyWith(
          color: mentionColor,
          fontWeight: FontWeight.w600,
          backgroundColor: mentionColor.withValues(alpha: 0.12),
        );
      }
      if (c) {
        s = s.copyWith(
          decoration: TextDecoration.combine([
            if (s.decoration != null) s.decoration!,
            TextDecoration.underline,
          ]),
        );
      }
      children.add(TextSpan(text: t.substring(i, j), style: s));
      i = j;
    }
    return TextSpan(style: style, children: children);
  }
}

/// 글자마다 어느 멘션에 속하는지(없으면 -1) — 글 길이 안에 온전히 들어오는 구간만 본다.
List<int> _mentionIndex(int length, List<Mention> mentions) {
  final out = List<int>.filled(length, -1);
  for (var k = 0; k < mentions.length; k++) {
    final m = mentions[k];
    if (m.start < 0 || m.end > length || m.end <= m.start) continue;
    for (var i = m.start; i < m.end; i++) {
      out[i] = k;
    }
  }
  return out;
}

/// 서식 입력칸(TextField)을 감싸는 래퍼 —
/// - Ctrl+B/I/U 단축키로 서식을 켜고 끈다.
/// - 인용 줄 왼쪽에 세로줄을 그린다. 입력칸(EditableText)은 글자 사이에 위젯을 넣을 수
///   없어서, 인용 글자들이 그려진 자리를 입력칸에 물어 그 왼쪽(글자 여백 안)에 선을 덧그린다.
class RichFieldWrapper extends StatefulWidget {
  final RichTextEditingController controller;
  final Widget child;
  const RichFieldWrapper({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  State<RichFieldWrapper> createState() => _RichFieldWrapperState();
}

class _RichFieldWrapperState extends State<RichFieldWrapper> {
  final _hostKey = GlobalKey();

  /// 입력칸 안쪽이 스크롤되면(여러 줄) 세로줄도 따라 움직이게 다시 그린다.
  final _scrolled = ValueNotifier(0);

  @override
  void dispose() {
    _scrolled.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
            c.toggle(Fmt.bold),
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
            c.toggle(Fmt.italic),
        const SingleActivator(LogicalKeyboardKey.keyU, control: true): () =>
            c.toggle(Fmt.underline),
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (_) {
          _scrolled.value++;
          return false;
        },
        child: CustomPaint(
          key: _hostKey,
          foregroundPainter: _QuoteBarPainter(
            controller: c,
            scrolled: _scrolled,
            hostKey: _hostKey,
            color: Theme.of(context).hintColor.withValues(alpha: 0.45),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _QuoteBarPainter extends CustomPainter {
  final RichTextEditingController controller;
  final GlobalKey hostKey;
  final Color color;
  _QuoteBarPainter({
    required this.controller,
    required Listenable scrolled,
    required this.hostKey,
    required this.color,
  }) : super(repaint: Listenable.merge([controller, scrolled]));

  static RenderEditable? _findEditable(RenderObject o) {
    if (o is RenderEditable) return o;
    RenderEditable? found;
    o.visitChildren((child) => found ??= _findEditable(child));
    return found;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final blocks = controller.quoteBlocks();
    if (blocks.isEmpty) return;
    final host = hostKey.currentContext?.findRenderObject();
    if (host is! RenderBox) return;
    final editable = _findEditable(host);
    if (editable == null || !editable.hasSize) return;
    final toHost = editable.getTransformTo(host);
    // 입력칸의 보이는 높이 안에서만(스크롤돼 가려진 줄의 선은 안 보이게).
    final visible = MatrixUtils.transformRect(
      toHost,
      Offset.zero & editable.size,
    );
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, visible.top, size.width, visible.bottom));
    final paint = Paint()..color = color;
    for (final (start, end) in blocks) {
      final boxes = editable.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: end),
      );
      if (boxes.isEmpty) continue;
      var top = boxes.first.top, bottom = boxes.first.bottom;
      for (final b in boxes) {
        top = math.min(top, b.top);
        bottom = math.max(bottom, b.bottom);
      }
      // 글자 시작(x=0) 왼쪽 여백 안에 3px 선.
      final bar = MatrixUtils.transformRect(
        toHost,
        Rect.fromLTRB(-8, top, -5, bottom),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(bar, const Radius.circular(1.5)),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_QuoteBarPainter old) =>
      old.controller != controller || old.color != color;
}

/// 서식 도구모음 — 굵게·기울임·밑줄·취소선 | 링크·코드·인용 | 번호·글머리 목록 (| 구분선).
/// 누르면 고른 글자에 바로 적용되고, 커서 자리의 서식이 켜져 있으면 버튼이 눌린 모양이 된다.
class RichFormatToolbar extends StatelessWidget {
  final RichTextEditingController controller;
  final FocusNode focusNode;
  final bool showRule;

  /// 맨 앞에 글자색(A)과 제목(H1·H2·H3) 버튼을 둘지 — 노트 편집기.
  final bool showColor;
  final bool showHeadings;

  /// 맨 뒤에 덧붙일 버튼들(노트의 표·그림 넣기 등) — 앞에 구분선이 하나 붙는다.
  final List<Widget> trailing;

  const RichFormatToolbar({
    super.key,
    required this.controller,
    required this.focusNode,
    this.showRule = false,
    this.showColor = false,
    this.showHeadings = false,
    this.trailing = const [],
  });

  /// 글자색 고르기에 나오는 색(0xRRGGBB). null은 기본색.
  static const palette = <int?>[
    null,
    0xE53935,
    0xFB8C00,
    0xF9A825,
    0x43A047,
    0x1E88E5,
    0x8E24AA,
    0x757575,
  ];

  Future<void> _link(BuildContext context) async {
    final sel = controller.selection;
    final hasSelection = sel.isValid && !sel.isCollapsed;
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _LinkDialog(
        needsLabel: !hasSelection,
        initialUrl: controller.currentHref ?? '',
      ),
    );
    if (result == null) {
      focusNode.requestFocus();
      return;
    }
    final (label, rawUrl) = result;
    final url = rawUrl.trim();
    final href = url.isEmpty
        ? null
        : (RegExp(r'^(https?://|mailto:)', caseSensitive: false).hasMatch(url)
              ? url
              : 'https://$url');
    controller.applyLink(href, label: hasSelection ? null : label);
    focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 단추를 눌러도 입력칸 "바깥"을 누른 것으로 치지 않는다 — 웹에서 터치하면 포커스를 놓았다가 곧 다시 잡는 사이에
    // 안드로이드 웹 앱 화면 아래에 키보드만큼 빈 공간이 남는다(chat_input_bar.dart의 build 참고).
    return TextFieldTapRegion(
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          Widget button(
            IconData icon,
            String tooltip,
            VoidCallback run, {
            bool active = false,
          }) => IconButton(
            icon: Icon(icon, size: 18),
            tooltip: tooltip,
            isSelected: active,
            color: theme.hintColor,
            selectedIcon: Icon(icon, size: 18, color: richFormatActiveColor),
            style: IconButton.styleFrom(
              backgroundColor: active
                  ? richFormatActiveColor.withValues(alpha: 0.14)
                  : null,
            ),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            padding: EdgeInsets.zero,
            onPressed: () {
              run();
              focusNode.requestFocus();
            },
          );
          Widget gap() => Container(
            width: 1,
            height: 16,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            color: theme.dividerColor,
          );
          final c = controller;
          Widget heading(int level) {
            final flag = switch (level) {
              1 => Fmt.h1,
              2 => Fmt.h2,
              _ => Fmt.h3,
            };
            final on = c.isActive(flag);
            return Tooltip(
              message: tr('제목 {level}', {'level': level}),
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () {
                  c.toggleHeading(level);
                  focusNode.requestFocus();
                },
                child: Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: on
                        ? richFormatActiveColor.withValues(alpha: 0.14)
                        : null,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'H$level',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: on ? richFormatActiveColor : theme.hintColor,
                    ),
                  ),
                ),
              ),
            );
          }

          Widget colorButton() {
            final current = c.currentColor;
            final shown = current == null
                ? Colors.redAccent
                : Color(0xFF000000 | current);
            return MenuAnchor(
              alignmentOffset: const Offset(0, 4),
              menuChildren: [
                // 색 고르기 판은 오버레이에 따로 뜬다 — 도구모음처럼 입력칸 바깥으로 치지 않는다.
                TextFieldTapRegion(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final rgb in palette)
                          Padding(
                            padding: const EdgeInsets.all(3),
                            child: Tooltip(
                              message: rgb == null ? tr('기본색') : '',
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: () {
                                  c.applyColor(rgb);
                                  focusNode.requestFocus();
                                },
                                child: Container(
                                  width: 22,
                                  height: 22,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: rgb == null
                                        ? theme.colorScheme.surface
                                        : Color(0xFF000000 | rgb),
                                    border: Border.all(
                                      color: rgb == current
                                          ? richFormatActiveColor
                                          : theme.dividerColor,
                                      width: rgb == current ? 2 : 1,
                                    ),
                                  ),
                                  child: rgb == null
                                      ? Icon(
                                          Icons.format_color_reset,
                                          size: 14,
                                          color: theme.hintColor,
                                        )
                                      : null,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              builder: (context, menu, _) => Tooltip(
                message: tr('글자색'),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => menu.isOpen ? menu.close() : menu.open(),
                  child: SizedBox(
                    width: 30,
                    height: 30,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'A',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.onSurface,
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Container(width: 14, height: 3, color: shown),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }

          // 도구모음을 눌러도 입력칸 밖을 누른 것으로 치지 않게(데스크톱은 밖을 누르면 포커스가
          // 빠지면서 고른 글자 선택이 사라진다).
          return TextFieldTapRegion(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 2,
                children: [
                  if (showColor) ...[colorButton(), gap()],
                  if (showHeadings) ...[
                    heading(1),
                    heading(2),
                    heading(3),
                    gap(),
                  ],
                  button(
                    Icons.format_bold,
                    tr('굵게 (Ctrl+B)'),
                    () => c.toggle(Fmt.bold),
                    active: c.isActive(Fmt.bold),
                  ),
                  button(
                    Icons.format_italic,
                    tr('기울임 (Ctrl+I)'),
                    () => c.toggle(Fmt.italic),
                    active: c.isActive(Fmt.italic),
                  ),
                  button(
                    Icons.format_underlined,
                    tr('밑줄 (Ctrl+U)'),
                    () => c.toggle(Fmt.underline),
                    active: c.isActive(Fmt.underline),
                  ),
                  button(
                    Icons.format_strikethrough,
                    tr('취소선'),
                    () => c.toggle(Fmt.strike),
                    active: c.isActive(Fmt.strike),
                  ),
                  gap(),
                  button(
                    Icons.link,
                    tr('링크'),
                    () => _link(context),
                    active: c.currentHref != null,
                  ),
                  button(
                    Icons.code,
                    tr('코드'),
                    () => c.toggle(Fmt.code),
                    active: c.isActive(Fmt.code),
                  ),
                  button(
                    Icons.format_quote,
                    tr('인용'),
                    c.toggleQuote,
                    active: c.isActive(Fmt.quote),
                  ),
                  gap(),
                  button(
                    Icons.format_list_numbered,
                    tr('번호 목록'),
                    () => c.toggleList(ordered: true),
                  ),
                  button(
                    Icons.format_list_bulleted,
                    tr('글머리 목록'),
                    () => c.toggleList(ordered: false),
                  ),
                  if (showRule) ...[
                    gap(),
                    button(Icons.horizontal_rule, tr('구분선'), c.insertRule),
                  ],
                  if (trailing.isNotEmpty) ...[gap(), ...trailing],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LinkDialog extends StatefulWidget {
  final bool needsLabel;
  final String initialUrl;
  const _LinkDialog({required this.needsLabel, required this.initialUrl});

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  final _label = TextEditingController();
  late final _url = TextEditingController(text: widget.initialUrl);

  @override
  void dispose() {
    _label.dispose();
    _url.dispose();
    super.dispose();
  }

  void _ok() {
    if (widget.needsLabel &&
        (_label.text.trim().isEmpty || _url.text.trim().isEmpty)) {
      return;
    }
    Navigator.of(context).pop((_label.text.trim(), _url.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('링크')),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.needsLabel) ...[
              TextField(
                controller: _label,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: tr('표시할 글'),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _ok(),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _url,
              autofocus: !widget.needsLabel,
              decoration: InputDecoration(
                labelText: tr('주소'),
                hintText: 'https://',
                helperText: widget.needsLabel ? null : tr('비우면 링크를 뗍니다.'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _ok(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('취소')),
        ),
        FilledButton(onPressed: _ok, child: Text(tr('확인'))),
      ],
    );
  }
}

/// 서식 도구모음이 붙은 여러 줄 입력칸(업무 댓글·답글처럼 넓은 입력칸용).
/// [alwaysShowToolbar]가 false면 입력칸을 누르거나 글이 있을 때만 도구모음을 보여준다.
/// Ctrl+Enter는 [onSubmit], Esc는 [onCancel].
class RichEditorBox extends StatefulWidget {
  final RichTextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final bool alwaysShowToolbar;
  final bool showRule;
  final int minLines;
  final VoidCallback? onSubmit;
  final VoidCallback? onCancel;
  const RichEditorBox({
    super.key,
    required this.controller,
    required this.focusNode,
    this.hintText = '',
    this.alwaysShowToolbar = true,
    this.showRule = true,
    this.minLines = 4,
    this.onSubmit,
    this.onCancel,
  });

  @override
  State<RichEditorBox> createState() => _RichEditorBoxState();
}

class _RichEditorBoxState extends State<RichEditorBox> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_refresh);
    widget.controller.addListener(_refresh);
  }

  @override
  void didUpdateWidget(RichEditorBox old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_refresh);
      widget.focusNode.addListener(_refresh);
    }
    if (old.controller != widget.controller) {
      old.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_refresh);
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final focused = widget.focusNode.hasFocus;
    final showToolbar =
        widget.alwaysShowToolbar ||
        focused ||
        widget.controller.text.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: dark
            ? Colors.white.withValues(alpha: 0.04)
            : const Color(0xFFF8F9FB),
        border: Border.all(
          color: focused
              ? theme.colorScheme.primary
              : (dark ? Colors.white24 : const Color(0xFFD1D5DB)),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showToolbar) ...[
            RichFormatToolbar(
              controller: widget.controller,
              focusNode: widget.focusNode,
              showRule: widget.showRule,
            ),
            Divider(height: 1, color: theme.dividerColor),
          ],
          CallbackShortcuts(
            bindings: {
              if (widget.onSubmit != null)
                const SingleActivator(LogicalKeyboardKey.enter, control: true):
                    widget.onSubmit!,
              if (widget.onCancel != null)
                const SingleActivator(LogicalKeyboardKey.escape):
                    widget.onCancel!,
            },
            child: RichFieldWrapper(
              controller: widget.controller,
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                minLines: widget.minLines,
                maxLines: 12,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.all(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 채팅·댓글 입력칸 아래 줄의 "T" 버튼 — 서식 도구모음을 펼치고 접는다. 펼쳐져 있으면 강조색.
class RichFormatToggleButton extends StatelessWidget {
  final bool open;
  final VoidCallback onPressed;
  const RichFormatToggleButton({
    super.key,
    required this.open,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // 누르면 쓰는 쪽이 입력칸 포커스를 다시 잡는다 — 도구모음과 같은 이유로 입력칸 바깥으로 치지 않는다.
    return TextFieldTapRegion(
      child: IconButton(
        icon: Icon(
          Icons.text_format,
          color: open ? richFormatActiveColor : null,
        ),
        tooltip: open ? tr('서식 도구 닫기') : tr('서식 도구'),
        onPressed: onPressed,
      ),
    );
  }
}

/// 서식 도구모음을 펼쳤을 때 입력칸을 감싸는 테두리 — 맨 위에 옅은 바탕의 도구모음 줄,
/// 그 아래 입력칸. 접혀 있으면 아무것도 두르지 않고 입력칸(자기 테두리)만 그린다.
class RichFormatFrame extends StatelessWidget {
  final bool open;
  final bool focused;
  final Widget toolbar;
  final Widget child;
  const RichFormatFrame({
    super.key,
    required this.open,
    required this.focused,
    required this.toolbar,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    const radius = BorderRadius.all(Radius.circular(4));
    // 테두리는 자식 위에(foreground) 그린다 — 뒤에 그리면 도구모음 줄의 바탕색이 윗선을
    // 덮어서 테두리가 잘려 보였다. 바탕색도 둥근 모서리 밖으로 삐져나오지 않게 자른다.
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: open
          ? BoxDecoration(
              border: Border.all(
                color: focused
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
                width: focused ? 2 : 1,
              ),
              borderRadius: radius,
            )
          : const BoxDecoration(),
      child: ClipRRect(
        borderRadius: open ? radius : BorderRadius.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (open)
              Container(
                color: dark
                    ? Colors.white.withValues(alpha: 0.04)
                    : const Color(0xFFF7F8FA),
                child: toolbar,
              ),
            child,
          ],
        ),
      ),
    );
  }
}

// ── 표시 ────────────────────────────────────────────────────────────────

/// 링크로 바꿀 주소 — 서버 linkPreview.js의 URL_REGEX/끝 문장부호 다듬기 규칙과 같게 맞춰서,
/// 링크 미리보기 카드가 뜨는 링크와 파랗게 표시되는 링크가 항상 일치하게 한다.
final _autoUrlRegex = RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false);
final _trailingPunctuationRegex = RegExp(r'''[.,;:!?)\]}'"]+$''');

/// 서식을 입혀 글을 그린다. 서식이 없는 구간의 http(s) 주소는 자동으로 링크가 된다.
/// 인용 줄은 왼쪽에 세로줄을 두른 블록으로 따로 그린다.
class FormattedText extends StatefulWidget {
  final String text;
  final List<TextFormatRun>? format;
  final TextStyle? style;

  /// 링크 글자색 — 없으면 테마 primary.
  final Color? linkColor;

  /// 마우스로 긁어 선택할 수 있게(SelectableText) 그릴지.
  final bool selectable;

  /// 본문 안의 멘션 구간 — 강조해서 그린다. 나([myUserId])를 멘션한 것(@all 포함)은 더 진하게.
  final List<Mention> mentions;
  final String? myUserId;

  /// 멘션한 사람 이름을 눌렀을 때(@all은 안 불린다) — 멤버 프로필을 여는 쪽이 받는다.
  final void Function(Mention mention)? onMentionTap;

  /// 멘션 글자색 — 없으면 테마 primary.
  final Color? mentionColor;

  /// 미리보기처럼 몇 줄까지만 보일 때(공지 목록·공지바 등) — 주면 인용 줄도 세로줄 블록 없이 한 덩어리 글로 그려
  /// [maxLines]에서 [overflow](기본 말줄임)로 자른다. 없으면 전부 그린다.
  final int? maxLines;
  final TextOverflow? overflow;

  const FormattedText(
    this.text, {
    super.key,
    this.format,
    this.style,
    this.linkColor,
    this.selectable = false,
    this.mentions = const [],
    this.myUserId,
    this.onMentionTap,
    this.mentionColor,
    this.maxLines,
    this.overflow,
  });

  @override
  State<FormattedText> createState() => _FormattedTextState();
}

class _FormattedTextState extends State<FormattedText> {
  /// TextSpan.recognizer는 알아서 정리되지 않아서, 다시 그릴 때마다 이전 것을 직접 치운다.
  final List<TapGestureRecognizer> _recognizers = [];

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
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

  /// 서식 없는 평범한 구간 — 주소만 링크로 바꾼다.
  void _plain(List<InlineSpan> out, String text, TextStyle style) {
    var last = 0;
    for (final m in _autoUrlRegex.allMatches(text)) {
      var url = m.group(0)!;
      var end = m.end;
      final trailing = _trailingPunctuationRegex.firstMatch(url);
      if (trailing != null) {
        url = url.substring(0, trailing.start);
        end -= trailing.group(0)!.length;
      }
      if (url.isEmpty) continue;
      if (m.start > last) {
        out.add(TextSpan(text: text.substring(last, m.start), style: style));
      }
      out.add(
        TextSpan(
          text: url,
          style: formatStyle(
            context,
            style,
            0,
            url,
            linkColor: widget.linkColor,
          ),
          recognizer: _open(url),
        ),
      );
      last = end;
    }
    if (last < text.length) {
      out.add(TextSpan(text: text.substring(last), style: style));
    }
  }

  /// 글자마다 어느 멘션에 속하는지(없으면 -1) — build에서 채운다. 멘션이 없으면 비어 있다.
  List<int> _mentionOf = const [];

  /// 말풍선 안의 멘션 — 연두색 굵은 글씨를 옅은 연두 바탕의 둥근 칩으로 감싼다(잔디 멘션과 같은 모양).
  /// TextSpan의 배경은 모서리를 둥글게 못 그려서 글자 줄 안에 끼우는 WidgetSpan으로 그린다. 나를 멘션한
  /// 것(@all 포함)은 바탕을 조금 더 진하게. 이름을 누르면 [FormattedText.onMentionTap](@all은 안 불린다).
  InlineSpan _mentionSpan(String piece, TextStyle style, Mention m) {
    final mine =
        m.isAll || (widget.myUserId != null && m.userId == widget.myUserId);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent =
        widget.mentionColor ??
        (dark ? const Color(0xFF4ADE9C) : const Color(0xFF02C472));
    final background = dark
        ? const Color(0xFF02C472).withValues(alpha: mine ? 0.34 : 0.22)
        : (mine ? const Color(0xFFBDEFD9) : const Color(0xFFD6F6E9));
    Widget chip = Container(
      key: ValueKey(mine ? 'mention-chip-mine' : 'mention-chip'),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        piece,
        style: style.copyWith(
          color: accent,
          fontWeight: FontWeight.w700,
          decoration: TextDecoration.none,
        ),
      ),
    );
    if (!m.isAll && widget.onMentionTap != null) {
      chip = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onMentionTap!(m),
          child: chip,
        ),
      );
    }
    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: chip,
    );
  }

  List<InlineSpan> _spans(_Chars chars, int from, int to, TextStyle base) {
    final t = widget.text;
    final out = <InlineSpan>[];
    var i = from;
    while (i < to) {
      final f = chars.flags[i] & ~Fmt.quote, h = chars.hrefs[i];
      final mi = _mentionOf.isEmpty ? -1 : _mentionOf[i];
      var j = i + 1;
      if (mi >= 0 && h == null) {
        // 멘션은 글자 서식이 중간에 바뀌어도 칩 하나로 — 같은 멘션 구간(링크 아닌 글자)이 이어지는 데까지.
        while (j < to && _mentionOf[j] == mi && chars.hrefs[j] == null) {
          j++;
        }
      } else {
        while (j < to &&
            (chars.flags[j] & ~Fmt.quote) == f &&
            chars.hrefs[j] == h &&
            (_mentionOf.isEmpty || _mentionOf[j] == mi)) {
          j++;
        }
      }
      final piece = t.substring(i, j);
      final style = formatStyle(
        context,
        base,
        f,
        h,
        linkColor: widget.linkColor,
      );
      if (mi >= 0 && h == null) {
        out.add(_mentionSpan(piece, style, widget.mentions[mi]));
      } else if (h != null) {
        out.add(TextSpan(text: piece, style: style, recognizer: _open(h)));
      } else if (f & Fmt.code != 0) {
        out.add(TextSpan(text: piece, style: style));
      } else {
        _plain(out, piece, style);
      }
      i = j;
    }
    return out;
  }

  Widget _rich(List<InlineSpan> spans) => widget.selectable
      ? SelectableText.rich(TextSpan(children: spans))
      : Text.rich(TextSpan(children: spans));

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final theme = Theme.of(context);
    final base = DefaultTextStyle.of(context).style.merge(widget.style);
    final t = widget.text;
    final chars = _Chars.fromRuns(t.length, widget.format);
    _mentionOf = widget.mentions.isEmpty
        ? const []
        : _mentionIndex(t.length, widget.mentions);
    if (widget.maxLines != null) {
      return Text.rich(
        TextSpan(children: _spans(chars, 0, t.length, base)),
        maxLines: widget.maxLines,
        overflow: widget.overflow ?? TextOverflow.ellipsis,
      );
    }

    // 줄마다 인용인지(그 줄 첫 글자에 인용 서식이 있는지) 보고, 같은 종류끼리 묶어 블록으로.
    final blocks = <(bool, int, int)>[];
    var lineStart = 0;
    while (lineStart <= t.length) {
      var lineEnd = t.indexOf('\n', lineStart);
      if (lineEnd < 0) lineEnd = t.length;
      final quote =
          lineEnd > lineStart && chars.flags[lineStart] & Fmt.quote != 0;
      if (blocks.isNotEmpty && blocks.last.$1 == quote) {
        blocks[blocks.length - 1] = (quote, blocks.last.$2, lineEnd);
      } else {
        blocks.add((quote, lineStart, lineEnd));
      }
      lineStart = lineEnd + 1;
    }
    if (blocks.length == 1 && !blocks.first.$1) {
      return _rich(_spans(chars, 0, t.length, base));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (quote, s, e) in blocks)
          if (quote)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 2),
              padding: const EdgeInsets.only(left: 10),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: (base.color ?? theme.hintColor).withValues(
                      alpha: 0.35,
                    ),
                    width: 3,
                  ),
                ),
              ),
              child: _rich(
                _spans(
                  chars,
                  s,
                  e,
                  base.copyWith(
                    color: (base.color ?? theme.hintColor).withValues(
                      alpha: 0.75,
                    ),
                  ),
                ),
              ),
            )
          else
            _rich(_spans(chars, s, e, base)),
      ],
    );
  }
}
