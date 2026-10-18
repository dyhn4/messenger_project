// 다국어 도구가 쓰는 작은 Dart 어휘 분석기 — 주석·문자열(따옴표 세 개·raw·끼워 넣기 ${…}/$name)·이름·기호를 위치와 함께 나눈다.
// 문법 전체를 알 필요는 없고, "어느 문자열이 어디에 있고 앞뒤에 무엇이 오는지"만 정확하면 된다(wrap.mjs·extract.mjs).

const ID_START = /[A-Za-z_$]/;
const ID_CHAR = /[A-Za-z0-9_$]/;
const HANGUL = /[가-힣]/;

export const hasHangul = (s) => HANGUL.test(s);

const PUNCT3 = ['...', '>>>', '??=', '>>=', '<<=', '~/='];
const PUNCT2 = ['==', '!=', '=>', '||', '&&', '?.', '??', '..', '<=', '>=', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '++', '--', '<<', '?[', '!.'];

/** 주석 끝 위치(주석이 아니면 -1). Dart의 블록 주석은 겹쳐 쓸 수 있다. */
function skipComment(src, i) {
  if (src[i] !== '/') return -1;
  if (src[i + 1] === '/') {
    const nl = src.indexOf('\n', i);
    return nl < 0 ? src.length : nl;
  }
  if (src[i + 1] === '*') {
    let depth = 1;
    let j = i + 2;
    while (j < src.length && depth > 0) {
      if (src[j] === '/' && src[j + 1] === '*') {
        depth += 1;
        j += 2;
      } else if (src[j] === '*' && src[j + 1] === '/') {
        depth -= 1;
        j += 2;
      } else {
        j += 1;
      }
    }
    return j;
  }
  return -1;
}

/** [i]에서 문자열이 시작하는지(따옴표, 또는 이름의 일부가 아닌 r + 따옴표). */
export function stringStartsAt(src, i) {
  const c = src[i];
  if (c === "'" || c === '"') return true;
  if (c === 'r' && (src[i + 1] === "'" || src[i + 1] === '"')) return i === 0 || !ID_CHAR.test(src[i - 1]);
  return false;
}

/**
 * [i]에서 시작하는 문자열 하나 — `{ start, end, raw, quote, triple, parts }`. parts는
 * `{ type: 'text', start, end }` | `{ type: 'ident', start, end }`($name) | `{ type: 'expr', start, end }`(${…} 안쪽).
 */
export function lexString(src, i) {
  const start = i;
  let raw = false;
  if (src[i] === 'r') {
    raw = true;
    i += 1;
  }
  const quote = src[i];
  const triple = src.startsWith(quote.repeat(3), i);
  const open = triple ? 3 : 1;
  i += open;
  const parts = [];
  let textStart = i;
  const pushText = (end) => {
    if (end > textStart) parts.push({ type: 'text', start: textStart, end });
  };
  for (;;) {
    if (i >= src.length) {
      pushText(i);
      break;
    }
    if (triple ? src.startsWith(quote.repeat(3), i) : src[i] === quote) {
      pushText(i);
      i += open;
      break;
    }
    if (!triple && src[i] === '\n') {
      // 닫히지 않은 문자열 — 줄 끝에서 멈춘다(정상 코드에는 없다).
      pushText(i);
      break;
    }
    if (!raw && src[i] === '\\') {
      i += 2;
      continue;
    }
    if (!raw && src[i] === '$') {
      if (src[i + 1] === '{') {
        pushText(i);
        const exprStart = i + 2;
        const close = skipExpr(src, exprStart);
        parts.push({ type: 'expr', start: exprStart, end: close });
        i = close + 1;
        textStart = i;
        continue;
      }
      if (/[A-Za-z_]/.test(src[i + 1] ?? '')) {
        pushText(i);
        let j = i + 1;
        while (j < src.length && /[A-Za-z0-9_]/.test(src[j])) j += 1;
        parts.push({ type: 'ident', start: i + 1, end: j });
        i = j;
        textStart = i;
        continue;
      }
    }
    i += 1;
  }
  return { start, end: i, raw, quote, triple, parts };
}

/** ${ 안쪽 식의 끝(짝이 맞는 } 위치). */
function skipExpr(src, i) {
  let depth = 0;
  while (i < src.length) {
    const end = skipComment(src, i);
    if (end >= 0) {
      i = end;
      continue;
    }
    if (stringStartsAt(src, i)) {
      i = lexString(src, i).end;
      continue;
    }
    const c = src[i];
    if (c === '{') depth += 1;
    else if (c === '}') {
      if (depth === 0) return i;
      depth -= 1;
    }
    i += 1;
  }
  return i;
}

/** 전체를 낱말로 — `{ type: 'comment'|'string'|'ident'|'number'|'punct', start, end, value?, str? }`. 빈칸은 뺀다. */
export function tokenize(src) {
  const tokens = [];
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (c === ' ' || c === '\t' || c === '\n' || c === '\r') {
      i += 1;
      continue;
    }
    const cEnd = skipComment(src, i);
    if (cEnd >= 0) {
      tokens.push({ type: 'comment', start: i, end: cEnd });
      i = cEnd;
      continue;
    }
    if (stringStartsAt(src, i)) {
      const str = lexString(src, i);
      tokens.push({ type: 'string', start: i, end: str.end, str });
      i = str.end;
      continue;
    }
    if (ID_START.test(c)) {
      let j = i + 1;
      while (j < src.length && ID_CHAR.test(src[j])) j += 1;
      tokens.push({ type: 'ident', start: i, end: j, value: src.slice(i, j) });
      i = j;
      continue;
    }
    if (/[0-9]/.test(c) || (c === '.' && /[0-9]/.test(src[i + 1] ?? ''))) {
      let j = i + 1;
      while (j < src.length && /[0-9A-Za-z_.]/.test(src[j])) {
        if (src[j] === '.' && !/[0-9]/.test(src[j + 1] ?? '')) break;
        j += 1;
      }
      tokens.push({ type: 'number', start: i, end: j, value: src.slice(i, j) });
      i = j;
      continue;
    }
    const three = src.slice(i, i + 3);
    const two = src.slice(i, i + 2);
    const p = PUNCT3.includes(three) ? three : PUNCT2.includes(two) ? two : c;
    tokens.push({ type: 'punct', start: i, end: i + p.length, value: p });
    i += p.length;
  }
  return tokens;
}

/** Dart 문자열 조각(따옴표 안 원문)의 실제 값 — raw면 그대로, 아니면 이스케이프를 푼다. 줄바꿈은 \n 하나로. */
export function decodeText(raw, isRaw) {
  const text = raw.replace(/\r\n/g, '\n');
  if (isRaw) return text;
  let out = '';
  for (let i = 0; i < text.length; i += 1) {
    const c = text[i];
    if (c !== '\\') {
      out += c;
      continue;
    }
    const n = text[i + 1];
    i += 1;
    if (n === 'n') out += '\n';
    else if (n === 'r') out += '\r';
    else if (n === 't') out += '\t';
    else if (n === 'b') out += '\b';
    else if (n === 'f') out += '\f';
    else if (n === 'v') out += '\v';
    else if (n === 'x') {
      out += String.fromCharCode(parseInt(text.slice(i + 1, i + 3), 16));
      i += 2;
    } else if (n === 'u') {
      if (text[i + 1] === '{') {
        const close = text.indexOf('}', i);
        out += String.fromCodePoint(parseInt(text.slice(i + 2, close), 16));
        i = close;
      } else {
        out += String.fromCharCode(parseInt(text.slice(i + 1, i + 5), 16));
        i += 4;
      }
    } else if (n === '\n') {
      // 줄 끝 \ — Dart에서는 이스케이프가 아니지만 안전하게 그대로 둔다.
      out += '\n';
    } else out += n ?? '';
  }
  return out;
}

/** 값 → 작은따옴표 Dart 문자열 안쪽(끼워 넣기 없음). */
export function encodeSingle(value) {
  let out = '';
  for (const ch of value) {
    const code = ch.codePointAt(0);
    if (ch === '\\') out += '\\\\';
    else if (ch === "'") out += "\\'";
    else if (ch === '$') out += '\\$';
    else if (ch === '\n') out += '\\n';
    else if (ch === '\r') out += '\\r';
    else if (ch === '\t') out += '\\t';
    else if (code < 0x20 || code === 0x7f) out += `\\u{${code.toString(16)}}`;
    else out += ch;
  }
  return out;
}

/** 따옴표 세 개 문자열은 여는 따옴표 바로 뒤가 빈칸뿐인 줄이면 그 줄바꿈까지 버린다(Dart 규칙). */
export function stripTripleLead(text) {
  const m = /^[ \t]*\r?\n/.exec(text);
  return m ? text.slice(m[0].length) : text;
}
