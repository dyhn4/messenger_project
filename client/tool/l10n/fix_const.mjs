// wrap.mjs가 감싼 tr()이 const 안에 들어가 생긴 분석 오류를 고친다 — `node tool/l10n/fix_const.mjs [반복 수]`.
//  - 감싼 const 식(const Text(…), const [...])의 const를 뺀다.
//  - const 선언(const x = …, static const …)은 final로 바꾼다(한 번만 계산 — 언어를 바꾸면 다시 시작해야 바뀌는 글).
//  - const를 뺄 수 없는 곳(enum 값의 인자, 매개변수 기본값, 주석 @…, const 생성자 초기화)은 tr()을 원래 글로 되돌리고
//    tool/l10n/manual.json에 남긴다 — 그 글은 손으로 옮긴다(예: enum은 label 대신 get label => tr(_label)).
// dart analyze --format=machine을 돌려 오류가 없어질 때까지(또는 [반복 수]만큼) 되풀이한다.
import { execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { encodeSingle, decodeText, tokenize } from './dart_lexer.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const CONST_CODES = new Set([
  'CONST_EVAL_METHOD_INVOCATION',
  'INVALID_CONSTANT',
  'CONST_WITH_NON_CONSTANT_ARGUMENT',
  'NON_CONSTANT_LIST_ELEMENT',
  'NON_CONSTANT_MAP_VALUE',
  'NON_CONSTANT_MAP_KEY',
  'NON_CONSTANT_SET_ELEMENT',
  'CONST_INITIALIZED_WITH_NON_CONSTANT_VALUE',
  'NON_CONSTANT_DEFAULT_VALUE',
  'NON_CONSTANT_CASE_EXPRESSION',
  'CONST_CONSTRUCTOR_WITH_FIELD_INITIALIZED_BY_NON_CONST',
  'CONST_EVAL_TYPE_BOOL_NUM_STRING',
  'CONST_INITIALIZED_WITH_NON_CONSTANT_VALUE_FROM_DEFERRED_LIBRARY',
  'INVALID_ANNOTATION',
  'CONST_CONSTRUCTOR_PARAM_TYPE_MISMATCH',
  'CONST_EVAL_THROWS_EXCEPTION',
]);

function analyze() {
  let out = '';
  try {
    out = execSync('dart analyze --format=machine lib', { cwd: ROOT, encoding: 'utf8', maxBuffer: 1 << 28, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    out = `${e.stdout ?? ''}${e.stderr ?? ''}`;
  }
  const errors = [];
  for (const line of out.split(/\r?\n/)) {
    const f = line.split('|');
    if (f[0] !== 'ERROR') continue;
    errors.push({ code: f[2], file: f[3], line: Number(f[4]), col: Number(f[5]), length: Number(f[6]), message: f.slice(7).join('|') });
  }
  return errors;
}

function offsetOf(src, line, col) {
  let off = 0;
  for (let l = 1; l < line; l += 1) off = src.indexOf('\n', off) + 1;
  return off + col - 1;
}

/** [toks]의 [i]번째(여는 괄호)와 짝인 닫는 괄호 위치. */
function matchClose(toks, i) {
  const open = toks[i].value;
  const close = { '(': ')', '[': ']', '{': '}', '<': '>' }[open];
  let depth = 0;
  for (let j = i; j < toks.length; j += 1) {
    const v = toks[j].value;
    if (v === open || (open === '[' && v === '?[')) depth += 1;
    else if (v === close || (open === '<' && v === '>>')) {
      depth -= v === '>>' ? 2 : 1;
      if (depth <= 0) return j;
    }
  }
  return toks.length - 1;
}

/** const 낱말 [i] 뒤의 범위와 종류 — `{ kind: 'decl'|'expr', end }`. */
function constExtent(toks, i) {
  let j = i + 1;
  const first = toks[j];
  if (!first) return { kind: 'expr', end: toks[i].end };
  if (['[', '{', '('].includes(first.value)) return { kind: 'expr', end: toks[matchClose(toks, j)].end };
  if (first.value === '<') {
    const close = matchClose(toks, j);
    const after = toks[close + 1];
    if (after && ['[', '{'].includes(after.value)) return { kind: 'expr', end: toks[matchClose(toks, close + 1)].end };
  }
  // 이름(점·제네릭 포함) 다음에 ( 이면 생성자 호출, = 이면 선언.
  for (; j < toks.length; j += 1) {
    const v = toks[j].value;
    if (v === '<') {
      j = matchClose(toks, j);
      continue;
    }
    if (v === '(') return { kind: 'expr', end: toks[matchClose(toks, j)].end };
    if (v === '=') {
      let k = j;
      let depth = 0;
      for (; k < toks.length; k += 1) {
        const w = toks[k].value;
        if (['(', '[', '{'].includes(w)) depth += 1;
        else if ([')', ']', '}'].includes(w)) depth -= 1;
        else if (w === ';' && depth <= 0) break;
      }
      return { kind: 'decl', end: toks[Math.min(k, toks.length - 1)].end };
    }
    if (v === ';' || v === ',' || v === ')') break;
  }
  return { kind: 'expr', end: toks[Math.min(j, toks.length - 1)].end };
}

/** tr('…', {…}) 호출 하나를 원래 Dart 문자열로 되돌린다. */
function untr(callSrc) {
  const toks = tokenize(callSrc).filter((t) => t.type !== 'comment');
  // tr ( 'key' [, { 'name': expr, … }] )
  const keyTok = toks[2];
  const key = decodeText(callSrc.slice(keyTok.start + 1, keyTok.end - 1), false);
  const values = new Map();
  if (toks[3]?.value === ',' && toks[4]?.value === '{') {
    const close = matchClose(toks, 4);
    let k = 5;
    while (k < close) {
      const nameTok = toks[k];
      const name = decodeText(callSrc.slice(nameTok.start + 1, nameTok.end - 1), false);
      let e = k + 2;
      let depth = 0;
      const exprStart = toks[e].start;
      for (; e < close; e += 1) {
        const w = toks[e].value;
        if (['(', '[', '{'].includes(w)) depth += 1;
        else if ([')', ']', '}'].includes(w)) depth -= 1;
        else if (w === ',' && depth === 0) break;
      }
      values.set(name, callSrc.slice(exprStart, toks[e - 1].end));
      k = e + 1;
    }
  }
  let out = '';
  let last = 0;
  const re = /\{([^{}\s]+)\}/g;
  let m;
  while ((m = re.exec(key))) {
    if (!values.has(m[1])) continue;
    out += encodeSingle(key.slice(last, m.index)) + `\${${values.get(m[1])}}`;
    last = m.index + m[0].length;
  }
  out += encodeSingle(key.slice(last));
  return `'${out}'`;
}

/** [offset]에 있는 tr( 호출 범위. */
function trCallAt(src, toks, offset) {
  for (let i = toks.length - 1; i >= 0; i -= 1) {
    const t = toks[i];
    if (t.start > offset) continue;
    if (t.value === 'tr' && toks[i + 1]?.value === '(') {
      const close = matchClose(toks, i + 1);
      if (toks[close].end > offset) return { start: t.start, end: toks[close].end };
    }
  }
  return null;
}

const manualPath = path.join(ROOT, 'tool', 'l10n', 'manual.json');
const manual = fs.existsSync(manualPath) ? JSON.parse(fs.readFileSync(manualPath, 'utf8')) : [];

const rounds = Number(process.argv[2] ?? 12);
for (let round = 1; round <= rounds; round += 1) {
  const errors = analyze().filter((e) => CONST_CODES.has(e.code));
  console.log(`[${round}] const 오류 ${errors.length}개`);
  if (errors.length === 0) break;
  const byFile = new Map();
  for (const e of errors) {
    if (!byFile.has(e.file)) byFile.set(e.file, []);
    byFile.get(e.file).push(e);
  }
  let progress = 0;
  for (const [file, list] of byFile) {
    let src = fs.readFileSync(file, 'utf8');
    const toks = tokenize(src).filter((t) => t.type !== 'comment');
    const edits = new Map(); // start → { end, text }
    for (const e of list) {
      const offset = offsetOf(src, e.line, e.col);
      const consts = [];
      for (let i = 0; i < toks.length && toks[i].start <= offset; i += 1) {
        if (toks[i].value !== 'const') continue;
        const ext = constExtent(toks, i);
        if (ext.end > offset) consts.push({ i, ...ext });
      }
      if (consts.length > 0 && e.code !== 'NON_CONSTANT_DEFAULT_VALUE' && e.code !== 'NON_CONSTANT_CASE_EXPRESSION') {
        for (const c of consts) {
          const t = toks[c.i];
          if (c.kind === 'decl') edits.set(t.start, { end: t.end, text: 'final' });
          else edits.set(t.start, { end: src[t.end] === ' ' ? t.end + 1 : t.end, text: '' });
        }
        continue;
      }
      // const를 뺄 수 없는 자리 — tr()을 원래 글로 되돌린다.
      const call = trCallAt(src, toks, offset);
      if (!call) continue;
      const original = untr(src.slice(call.start, call.end));
      edits.set(call.start, { end: call.end, text: original });
      manual.push({ file: path.relative(ROOT, file).split(path.sep).join('/'), line: e.line, code: e.code, text: original });
    }
    if (edits.size === 0) continue;
    const ordered = [...edits.entries()].sort((a, b) => b[0] - a[0]);
    for (const [start, { end, text }] of ordered) src = src.slice(0, start) + text + src.slice(end);
    fs.writeFileSync(file, src);
    progress += edits.size;
  }
  if (progress === 0) {
    console.log('더 고칠 수 있는 것이 없습니다 — 남은 오류는 손으로.');
    for (const e of errors.slice(0, 30)) console.log(`  ${e.code} ${e.file}:${e.line}:${e.col} ${e.message}`);
    break;
  }
}
fs.writeFileSync(manualPath, JSON.stringify(manual, null, 1));
console.log(`손으로 옮길 글 ${manual.length}개 → tool/l10n/manual.json`);
