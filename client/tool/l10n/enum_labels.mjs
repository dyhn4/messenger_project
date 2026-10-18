// enum 값의 한국어 이름(enum 인자는 const여야 해서 tr()로 감쌀 수 없다)을 읽는 자리에서 옮기게 바꾼다 —
// `node tool/l10n/enum_labels.mjs 파일…`.
//   enum ApprovalKind { leave('leave', '휴가'); final String wire; final String label; const ApprovalKind(this.wire, this.label); }
//   → final String _labelKo; … const ApprovalKind(this.wire, this._labelKo); String get label => tr(_labelKo);
// 한국어 글이 들어가는 위치 매개변수(this.x)만 바꾼다. 이름 붙은 매개변수는 손으로.
import fs from 'node:fs';
import { hasHangul, tokenize } from './dart_lexer.mjs';

function matchClose(toks, i) {
  const open = toks[i].value;
  const close = { '(': ')', '[': ']', '{': '}' }[open];
  let depth = 0;
  for (let j = i; j < toks.length; j += 1) {
    if (toks[j].value === open) depth += 1;
    else if (toks[j].value === close && --depth === 0) return j;
  }
  return toks.length - 1;
}

/** 괄호 안 인자들을 맨 바깥 쉼표로 나눈다 — 낱말 범위 목록. */
function splitArgs(toks, open, close) {
  const args = [];
  let start = open + 1;
  let depth = 0;
  for (let k = open + 1; k < close; k += 1) {
    const v = toks[k].value;
    if (['(', '[', '{'].includes(v)) depth += 1;
    else if ([')', ']', '}'].includes(v)) depth -= 1;
    else if (v === ',' && depth === 0) {
      args.push([start, k - 1]);
      start = k + 1;
    }
  }
  if (start <= close - 1) args.push([start, close - 1]);
  return args;
}

export function fixEnums(src) {
  const toks = tokenize(src).filter((t) => t.type !== 'comment');
  const edits = [];
  for (let i = 0; i < toks.length; i += 1) {
    if (toks[i].value !== 'enum' || toks[i + 1]?.type !== 'ident') continue;
    const name = toks[i + 1].value;
    let b = i + 2;
    while (toks[b] && toks[b].value !== '{') b += 1;
    const end = matchClose(toks, b);
    // 값 목록: { 이름(인자…), …; 나머지 }
    const hangulIdx = new Set();
    let k = b + 1;
    while (k < end && toks[k].value !== ';') {
      if (toks[k].type === 'ident' && toks[k + 1]?.value === '(') {
        const close = matchClose(toks, k + 1);
        splitArgs(toks, k + 1, close).forEach(([s, e], idx) => {
          for (let q = s; q <= e; q += 1) {
            if (toks[q].type === 'string' && hasHangul(src.slice(toks[q].start, toks[q].end))) hangulIdx.add(idx);
          }
        });
        k = close + 1;
        continue;
      }
      k += 1;
    }
    if (hangulIdx.size === 0) continue;
    // 생성자: const Name( … )
    let ctor = -1;
    for (let q = k; q < end; q += 1) {
      if (toks[q].value === 'const' && toks[q + 1]?.value === name && toks[q + 2]?.value === '(') {
        ctor = q + 2;
        break;
      }
    }
    if (ctor < 0) continue;
    const ctorClose = matchClose(toks, ctor);
    const params = splitArgs(toks, ctor, ctorClose);
    for (const idx of hangulIdx) {
      const p = params[idx];
      if (!p) continue;
      // this.label
      if (!(toks[p[0]].value === 'this' && toks[p[0] + 1]?.value === '.' && toks[p[0] + 2]?.type === 'ident')) continue;
      const field = toks[p[0] + 2].value;
      const priv = `${field.startsWith('_') ? field : `_${field}`}Ko`;
      edits.push({ start: toks[p[0] + 2].start, end: toks[p[0] + 2].end, text: priv });
      // final String label;
      for (let q = k; q < end; q += 1) {
        if (toks[q].value === 'final' && toks[q + 2]?.value === field && toks[q + 3]?.value === ';') {
          const semi = toks[q + 3];
          edits.push({ start: toks[q + 2].start, end: semi.end, text: `${priv};\n\n  /// 화면에 보일 이름(지금 언어 — l10n/tr.dart).\n  String get ${field} => tr(${priv});` });
          break;
        }
      }
    }
  }
  let out = src;
  for (const e of edits.sort((a, b) => b.start - a.start)) out = out.slice(0, e.start) + e.text + out.slice(e.end);
  return out;
}

for (const file of process.argv.slice(2)) {
  const src = fs.readFileSync(file, 'utf8');
  const out = fixEnums(src);
  if (out !== src) {
    fs.writeFileSync(file, out.replace(/\r?\n/g, src.includes('\r\n') ? '\r\n' : '\n'));
    console.log('고침', file);
  }
}
