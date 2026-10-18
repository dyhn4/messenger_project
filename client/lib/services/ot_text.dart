/// 위키 동시 편집의 OT(operational transformation) — 서버 server/src/otText.js와 같은 규칙이다(둘이 같아야 모두의 글이 맞는다).
/// 연산 하나는 구성 요소 목록: 양의 정수 n = 글자 n개 그대로(retain), 문자열 = 넣기(insert), 음의 정수 -n = 글자 n개 지우기.
/// 글자 수는 UTF-16 단위(Dart 문자열 길이 — 서버 자바스크립트와 같다). 같은 자리 동시 넣기는 transform(a, b)의 [a]가 앞이다 —
/// 앱은 확인받지 못한 내 연산을 서버 연산에 대해 transform(내 것, 서버 것)으로 맞춘다.
library;

import '../l10n/tr.dart';

typedef TextOp = List<Object>;

bool _isRetain(Object? c) => c is int && c > 0;
bool _isDelete(Object? c) => c is int && c < 0;
bool _isInsert(Object? c) => c is String;

class _Builder {
  final ops = <Object>[];

  void retain(int n) {
    if (n <= 0) return;
    if (ops.isNotEmpty && _isRetain(ops.last)) {
      ops[ops.length - 1] = (ops.last as int) + n;
    } else {
      ops.add(n);
    }
  }

  void insert(String s) {
    if (s.isEmpty) return;
    if (ops.isNotEmpty && _isInsert(ops.last)) {
      ops[ops.length - 1] = (ops.last as String) + s;
    } else if (ops.isNotEmpty && _isDelete(ops.last)) {
      // 지우기 바로 뒤의 넣기는 지우기 앞으로(서버와 같은 짧은 꼴).
      if (ops.length >= 2 && _isInsert(ops[ops.length - 2])) {
        ops[ops.length - 2] = (ops[ops.length - 2] as String) + s;
      } else {
        ops.insert(ops.length - 1, s);
      }
    } else {
      ops.add(s);
    }
  }

  void delete(int n) {
    if (n <= 0) return;
    if (ops.isNotEmpty && _isDelete(ops.last)) {
      ops[ops.length - 1] = (ops.last as int) - n;
    } else {
      ops.add(-n);
    }
  }
}

/// 서버에서 온 JSON 연산을 읽는다 — 모양이 틀리면 null.
TextOp? opFromJson(Object? json) {
  if (json is! List) return null;
  final out = <Object>[];
  for (final c in json) {
    if (c is num && c == c.toInt() && c != 0) {
      out.add(c.toInt());
    } else if (c is String && c.isNotEmpty) {
      out.add(c);
    } else {
      return null;
    }
  }
  return out;
}

TextOp normalizeOp(TextOp op) {
  final b = _Builder();
  for (final c in op) {
    if (_isRetain(c)) {
      b.retain(c as int);
    } else if (_isInsert(c)) {
      b.insert(c as String);
    } else if (_isDelete(c)) {
      b.delete(-(c as int));
    }
  }
  return b.ops;
}

int baseLength(TextOp op) {
  var n = 0;
  for (final c in op) {
    if (_isRetain(c)) n += c as int;
    if (_isDelete(c)) n -= c as int;
  }
  return n;
}

int targetLength(TextOp op) {
  var n = 0;
  for (final c in op) {
    if (_isRetain(c)) n += c as int;
    if (_isInsert(c)) n += (c as String).length;
  }
  return n;
}

bool isNoopOp(TextOp op) => op.every(_isRetain);

/// [doc]에 [op]를 적용한다 — 길이가 맞지 않으면 [StateError].
String applyOp(String doc, TextOp op) {
  if (baseLength(op) != doc.length) {
    throw StateError(tr('연산의 길이가 글과 맞지 않습니다.'));
  }
  final out = StringBuffer();
  var i = 0;
  for (final c in op) {
    if (_isRetain(c)) {
      out.write(doc.substring(i, i + (c as int)));
      i += c;
    } else if (_isInsert(c)) {
      out.write(c as String);
    } else {
      i -= c as int;
    }
  }
  return out.toString();
}

/// 같은 글에서 갈라진 [a]·[b] → (a', b') — applyOp(applyOp(doc, a), b') == applyOp(applyOp(doc, b), a').
(TextOp, TextOp) transformOps(TextOp a, TextOp b) {
  if (baseLength(a) != baseLength(b)) throw StateError(tr('두 연산의 길이가 다릅니다.'));
  final ap = _Builder();
  final bp = _Builder();
  var i = 0;
  var j = 0;
  Object? next(TextOp op, int k) => k < op.length ? op[k] : null;
  Object? x = next(a, i++);
  Object? y = next(b, j++);
  while (true) {
    if (x == null && y == null) break;
    if (_isInsert(x)) {
      ap.insert(x as String);
      bp.retain(x.length);
      x = next(a, i++);
      continue;
    }
    if (_isInsert(y)) {
      ap.retain((y as String).length);
      bp.insert(y);
      y = next(b, j++);
      continue;
    }
    if (x == null || y == null) throw StateError(tr('연산을 맞출 수 없습니다.'));
    final xi = x as int;
    final yi = y as int;
    if (xi > 0 && yi > 0) {
      final m = xi < yi ? xi : yi;
      ap.retain(m);
      bp.retain(m);
      x = xi > m ? xi - m : next(a, i++);
      y = yi > m ? yi - m : next(b, j++);
    } else if (xi < 0 && yi < 0) {
      final m = -xi < -yi ? -xi : -yi;
      x = -xi > m ? xi + m : next(a, i++);
      y = -yi > m ? yi + m : next(b, j++);
    } else if (xi < 0 && yi > 0) {
      final m = -xi < yi ? -xi : yi;
      ap.delete(m);
      x = -xi > m ? xi + m : next(a, i++);
      y = yi > m ? yi - m : next(b, j++);
    } else {
      final m = xi < -yi ? xi : -yi;
      bp.delete(m);
      x = xi > m ? xi - m : next(a, i++);
      y = -yi > m ? yi + m : next(b, j++);
    }
  }
  return (ap.ops, bp.ops);
}

/// [a] 다음 [b]를 하나로.
TextOp composeOps(TextOp a, TextOp b) {
  if (targetLength(a) != baseLength(b)) {
    throw StateError(tr('이어 붙일 수 없는 연산입니다.'));
  }
  final out = _Builder();
  var i = 0;
  var j = 0;
  Object? next(TextOp op, int k) => k < op.length ? op[k] : null;
  Object? x = next(a, i++);
  Object? y = next(b, j++);
  while (true) {
    if (x == null && y == null) break;
    if (_isDelete(x)) {
      out.delete(-(x as int));
      x = next(a, i++);
      continue;
    }
    if (_isInsert(y)) {
      out.insert(y as String);
      y = next(b, j++);
      continue;
    }
    if (x == null || y == null) throw StateError(tr('이어 붙일 수 없는 연산입니다.'));
    if (_isRetain(x) && _isRetain(y)) {
      final xi = x as int;
      final yi = y as int;
      final m = xi < yi ? xi : yi;
      out.retain(m);
      x = xi > m ? xi - m : next(a, i++);
      y = yi > m ? yi - m : next(b, j++);
    } else if (_isInsert(x) && _isDelete(y)) {
      final xs = x as String;
      final yi = y as int;
      final m = xs.length < -yi ? xs.length : -yi;
      x = xs.length > m ? xs.substring(m) : next(a, i++);
      y = -yi > m ? yi + m : next(b, j++);
    } else if (_isInsert(x) && _isRetain(y)) {
      final xs = x as String;
      final yi = y as int;
      final m = xs.length < yi ? xs.length : yi;
      out.insert(xs.substring(0, m));
      x = xs.length > m ? xs.substring(m) : next(a, i++);
      y = yi > m ? yi - m : next(b, j++);
    } else {
      final xi = x as int;
      final yi = y as int;
      final m = xi < -yi ? xi : -yi;
      out.delete(m);
      x = xi > m ? xi - m : next(a, i++);
      y = -yi > m ? yi + m : next(b, j++);
    }
  }
  return out.ops;
}

/// [from]을 [to]로 바꾸는 연산 — 앞뒤 같은 부분을 빼고 가운데만(입력칸의 한 번 변경).
TextOp diffOp(String from, String to) {
  var start = 0;
  final max = from.length < to.length ? from.length : to.length;
  while (start < max && from.codeUnitAt(start) == to.codeUnitAt(start)) {
    start++;
  }
  var endFrom = from.length;
  var endTo = to.length;
  while (endFrom > start &&
      endTo > start &&
      from.codeUnitAt(endFrom - 1) == to.codeUnitAt(endTo - 1)) {
    endFrom--;
    endTo--;
  }
  final b = _Builder()
    ..retain(start)
    ..insert(to.substring(start, endTo))
    ..delete(endFrom - start)
    ..retain(from.length - endFrom);
  return b.ops;
}

/// 커서 위치를 [op] 뒤로 옮긴다 — 같은 자리 넣기는 커서 뒤에 들어간 것으로 본다(서버 transformIndex와 같다).
int transformIndex(int index, TextOp op) {
  var pos = 0;
  var out = index;
  for (final c in op) {
    if (pos > index) break;
    if (_isRetain(c)) {
      pos += c as int;
    } else if (_isInsert(c)) {
      if (pos < index) out += (c as String).length;
    } else {
      final n = -(c as int);
      final within = index - pos;
      out -= n < within ? n : (within > 0 ? within : 0);
      pos += n;
    }
  }
  return out;
}
