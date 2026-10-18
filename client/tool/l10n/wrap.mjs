// 한국어 화면 글을 tr()로 감싼다 — `node tool/l10n/wrap.mjs [파일…]`(파일을 안 주면 lib/ 전체, lib/l10n/은 뺌).
//   'n개 남음'               → tr('n개 남음')
//   '$name님이 참여했습니다' → tr('{name}님이 참여했습니다', {'name': name})
//   '${a.b}개' ' 남음'       → tr('{a.b}개 남음', {'a.b': a.b})   (붙어 있는 문자열은 한 문장으로)
// 같은 한국어라도 화면 글이 아닌 곳(비교 ==, case·switch 무늬, 맵 열쇠, 글자 고르기 '월화수'[i], RegExp·contains·split 같은 처리,
// 키(ValueKey)·로그)은 감싸지 않는다 — 한국어일 때 tr()은 원문 그대로라 동작은 같지만, 영어일 때 글이 바뀌면 안 되는 자리다.
// const 안이라 tr()을 쓸 수 없는 곳은 dart analyze가 알려 주고 fix_const.mjs가 const를 걷어 낸다.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { decodeText, encodeSingle, hasHangul, stripTripleLead, tokenize } from './dart_lexer.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const LIB = path.join(ROOT, 'lib');
const TR_FILE = path.join(LIB, 'l10n', 'tr.dart');

/** 이 이름의 호출에 바로 넘기는 글은 처리용 — 감싸지 않는다. */
const LOGIC_CALLEES = new Set([
  'RegExp', 'contains', 'startsWith', 'endsWith', 'indexOf', 'lastIndexOf', 'split', 'replaceAll', 'replaceFirst',
  'replaceAllMapped', 'replaceFirstMapped', 'hasMatch', 'firstMatch', 'allMatches', 'matchAsPrefix', 'stringMatch',
  'ValueKey', 'Key', 'ObjectKey', 'PageStorageKey', 'GlobalObjectKey', 'LabeledGlobalKey', 'UniqueKey',
  'debugPrint', 'print', 'log', 'assert', 'tr', 'trServer', 'Symbol', 'Uri', 'parse', 'tryParse', 'jsonDecode',
  'containsKey', 'remove', 'compareTo', 'padLeft', 'padRight', 'trimLeft', 'trimRight',
]);
/** 이 이름의 이름 붙은 인자(debugLabel: '…')도 화면 글이 아니다. */
const LOGIC_NAMED = new Set(['debugLabel', 'restorationId', 'key', 'heroTag', 'semanticsIdentifier']);
const PREV_SKIP = new Set(['case', '==', '!=', '||', 'is', 'import', 'export', 'part', 'library']);
const NEXT_SKIP = new Set(['==', '!=', '=>', '||', '[', '.', '?.', 'when', '?[']);
const PATH_EXPR = /^[A-Za-z_]\w*(?:\??\.[A-Za-z_]\w*)*$/;

/**
 * [src](Dart 원문 또는 ${…} 안쪽 식)를 바꾼다 — `{ out, keys }`(keys는 새로 감싼 번역 열쇠들).
 */
export function transform(src) {
  const all = tokenize(src);
  const sig = all.filter((t) => t.type !== 'comment');
  const edits = [];
  const keys = [];
  const stack = [];
  for (let k = 0; k < sig.length; k += 1) {
    const t = sig[k];
    if (t.type === 'punct') {
      const v = t.value;
      if (v === '(' || v === '[' || v === '{' || v === '?[') {
        const prev = sig[k - 1];
        const isIndex = v === '?[' || (v === '[' && prev && (prev.type === 'ident' || prev.type === 'string' || [')', ']', '!'].includes(prev.value)) && !['return', 'in', 'yield', 'await', 'else', 'const', 'final', 'var'].includes(prev.value));
        stack.push({
          ch: v === '?[' ? '[' : v,
          callee: v === '(' && prev?.type === 'ident' ? prev.value : null,
          annotation: v === '(' && prev?.type === 'ident' && sig[k - 2]?.value === '@',
          isIndex,
        });
      } else if (v === ')' || v === ']' || v === '}') {
        stack.pop();
      }
      continue;
    }
    if (t.type !== 'string') continue;
    let m = k;
    while (sig[m + 1]?.type === 'string') m += 1;
    const group = sig.slice(k, m + 1);
    const prev = sig[k - 1];
    const next = sig[m + 1];
    const top = stack[stack.length - 1];
    const result = handleGroup(src, group, { prev, prevPrev: sig[k - 2], next, top });
    if (result.edit) edits.push(result.edit);
    keys.push(...result.keys);
    k = m;
  }
  let out = src;
  for (const e of edits.sort((a, b) => b.start - a.start)) out = out.slice(0, e.start) + e.text + out.slice(e.end);
  return { out, keys };
}

function excluded({ prev, prevPrev, next, top }) {
  if (prev && PREV_SKIP.has(prev.value)) return true;
  if (next && NEXT_SKIP.has(next.value)) return true;
  if (prev?.value === ':' && prevPrev?.type === 'ident' && LOGIC_NAMED.has(prevPrev.value)) return true;
  if (top?.ch === '(' && (top.annotation || (top.callee && LOGIC_CALLEES.has(top.callee)))) return true;
  if (top?.ch === '{' && next?.value === ':' && (prev?.value === '{' || prev?.value === ',')) return true; // 맵 열쇠
  if (top?.ch === '[' && top.isIndex) return true; // map['열쇠']
  return false;
}

function handleGroup(src, group, context) {
  const keys = [];
  const placeholders = []; // { name, value }
  const byExpr = new Map();
  let key = '';
  let hangul = false;
  let changedExpr = false;
  const exprOut = new Map(); // part.start → 바뀐 식
  let auto = 0;
  for (const s of group) {
    const { str } = s;
    str.parts.forEach((part, idx) => {
      if (part.type === 'text') {
        let raw = src.slice(part.start, part.end);
        if (str.triple && idx === 0 && part.start === s.start + (str.raw ? 1 : 0) + 3) raw = stripTripleLead(raw);
        const text = decodeText(raw, str.raw);
        if (hasHangul(text)) hangul = true;
        key += text;
        return;
      }
      const code = src.slice(part.start, part.end);
      let value = code;
      if (part.type === 'expr') {
        const inner = transform(code);
        keys.push(...inner.keys);
        if (inner.out !== code) {
          changedExpr = true;
          exprOut.set(part.start, inner.out);
        }
        value = inner.out.trim();
      }
      let name = byExpr.get(value);
      if (!name) {
        name = part.type === 'ident' ? value : PATH_EXPR.test(value) ? value.replace(/\?\./g, '.') : `p${auto++}`;
        byExpr.set(value, name);
        placeholders.push({ name, value });
      }
      key += `{${name}}`;
    });
  }
  const start = group[0].start;
  const end = group[group.length - 1].end;
  if (!hangul || excluded(context)) {
    if (!changedExpr) return { keys };
    // 감싸지 않는 글이라도 ${…} 안의 화면 글은 바꾼다.
    let text = src.slice(start, end);
    const entries = [...exprOut.entries()].sort((a, b) => b[0] - a[0]);
    for (const [partStart, replacement] of entries) {
      const part = group.flatMap((g) => g.str.parts).find((p) => p.start === partStart);
      text = text.slice(0, part.start - start) + replacement + text.slice(part.end - start);
    }
    return { keys, edit: { start, end, text } };
  }
  keys.push(key);
  const args = placeholders.length
    ? `, {${placeholders.map((p) => `'${encodeSingle(p.name)}': ${p.value}`).join(', ')}}`
    : '';
  return { keys, edit: { start, end, text: `tr('${encodeSingle(key)}'${args})` } };
}

/** 파일 맨 위 import 끝에 tr.dart를 더한다(이미 있으면 그대로). */
export function addImport(src, file) {
  if (/import\s+['"][^'"]*l10n\/tr\.dart['"]/.test(src)) return src;
  const rel = path.relative(path.dirname(file), TR_FILE).split(path.sep).join('/');
  const spec = rel.startsWith('.') ? rel : `./${rel}`.replace(/^\.\//, '');
  const eol = src.includes('\r\n') ? '\r\n' : '\n';
  const tokens = tokenize(src);
  let insertAt = -1;
  for (let i = 0; i < tokens.length; i += 1) {
    const t = tokens[i];
    if (t.type === 'ident' && (t.value === 'import' || t.value === 'export') && (i === 0 || tokens[i - 1].value === ';' || tokens[i - 1].type === 'comment' || tokens[i - 1].value === 'library')) {
      let j = i;
      while (j < tokens.length && tokens[j].value !== ';') j += 1;
      insertAt = tokens[j].end;
      i = j;
    } else if (t.type === 'ident' && !['library'].includes(t.value) && insertAt >= 0) {
      break;
    }
  }
  const line = `import '${rel}';`;
  if (insertAt < 0) {
    // import가 하나도 없으면 library 지시문 뒤에(없으면 맨 위에).
    const lib = tokens.findIndex((t) => t.type === 'ident' && t.value === 'library');
    if (lib >= 0) {
      let j = lib;
      while (j < tokens.length && tokens[j].value !== ';') j += 1;
      return `${src.slice(0, tokens[j].end)}${eol}${eol}${line}${src.slice(tokens[j].end)}`;
    }
    return `${line}${eol}${src}`;
  }
  return `${src.slice(0, insertAt)}${eol}${line}${src.slice(insertAt)}`;
}

function listDart(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (p !== path.join(LIB, 'l10n')) out.push(...listDart(p));
    } else if (e.name.endsWith('.dart') && !e.name.endsWith('.g.dart')) out.push(p);
  }
  return out;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const files = process.argv.length > 2 ? process.argv.slice(2).map((f) => path.resolve(f)) : listDart(LIB);
  let changed = 0;
  let wrapped = 0;
  const report = [];
  for (const file of files) {
    const src = fs.readFileSync(file, 'utf8');
    const { out, keys } = transform(src);
    if (out === src) continue;
    const next = keys.length > 0 ? addImport(out, file) : out;
    fs.writeFileSync(file, next);
    changed += 1;
    wrapped += keys.length;
    report.push({ file: path.relative(ROOT, file), keys: keys.length });
  }
  console.log(`바꾼 파일 ${changed}개, 감싼 글 ${wrapped}개`);
  if (process.env.L10N_REPORT) fs.writeFileSync(process.env.L10N_REPORT, JSON.stringify(report, null, 1));
}
