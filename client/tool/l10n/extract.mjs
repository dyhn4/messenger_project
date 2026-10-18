// 번역할 글 모으기 — `node tool/l10n/extract.mjs`.
//  - 앱(lib/): tr('…') 열쇠, enum 값의 한국어 인자(get label => tr(_labelKo)로 옮긴다), 한국어 기본값·초기화 값(보이는 자리에서 tr(값)),
//    ApiException 무리의 super('…') 문구(toString이 trServer로 옮긴다) → tool/l10n/keys.json
//  - 서버(../server/src): 한국어 문자열·템플릿(오류 문구·시스템 메시지·알림 — 앱이 trServer로 옮긴다). 템플릿의 ${…}는 {0}…으로.
//    console.* 안의 글은 뺀다 → tool/l10n/server_keys.json { exact: [...], templates: [...] }
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { decodeText, hasHangul, stripTripleLead, tokenize } from './dart_lexer.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '../..');
const LIB = path.join(ROOT, 'lib');
const SERVER = path.resolve(ROOT, '../server/src');

const walk = (d, ext) =>
  fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => {
    const p = path.join(d, e.name);
    if (e.isDirectory()) return e.name === 'node_modules' ? [] : walk(p, ext);
    return e.name.endsWith(ext) ? [p] : [];
  });

/** 끼워 넣기가 없는 Dart 문자열 낱말의 값(있으면 null). */
function plainValue(src, tok) {
  const { str } = tok;
  if (str.parts.some((p) => p.type !== 'text')) return null;
  return str.parts
    .map((p, i) => {
      let raw = src.slice(p.start, p.end);
      if (str.triple && i === 0) raw = stripTripleLead(raw);
      return decodeText(raw, str.raw);
    })
    .join('');
}

export function extractDart(src, onKey = () => {}) {
  const toks = tokenize(src).filter((t) => t.type !== 'comment');
  const keys = new Set();
  let enumDepth = -1;
  let depth = 0;
  for (let i = 0; i < toks.length; i += 1) {
    const t = toks[i];
    if (t.type === 'punct') {
      if (t.value === '{') depth += 1;
      else if (t.value === '}') {
        depth -= 1;
        if (depth < enumDepth) enumDepth = -1;
      } else if (t.value === ';' && enumDepth === depth) enumDepth = -2; // 값 목록 끝
      continue;
    }
    if (t.type === 'ident' && t.value === 'enum') {
      enumDepth = depth + 1;
      continue;
    }
    if (t.type !== 'string') continue;
    const prev = toks[i - 1];
    const value = () => plainValue(src, t);
    // tr('열쇠') — 첫 인자.
    if (prev?.value === '(' && toks[i - 2]?.value === 'tr') {
      const v = value();
      if (v !== null) {
        keys.add(v);
        onKey(v, t.start);
      }
      continue;
    }
    const v = value();
    if (v === null || !hasHangul(v)) continue;
    const take = (enumDepth > 0 && depth === enumDepth) || // enum 값 인자
      (prev?.value === '=' && toks[i - 2]?.type === 'ident') || // 기본값·초기화 값
      (prev?.value === '(' && toks[i - 2]?.value === 'super'); // 예외 문구
    if (take) {
      keys.add(v);
      onKey(v, t.start);
    }
  }
  return keys;
}

// ── 서버(자바스크립트) ──────────────────────────────────────────────────

/** JS 원문에서 문자열·템플릿 리터럴 — `{ value, template, console }`(template이면 ${…} 자리가 {0}…). */
export function jsLiterals(src) {
  const out = [];
  let i = 0;
  let lastSig = '';
  const regexAllowedAfter = new Set(['', '(', ',', '=', ':', '[', '!', '&', '|', '?', '{', '}', ';', '+', '-', '*', '%', '<', '>', '~', '^', 'return', 'typeof', 'case', 'do', 'else', '=>']);
  const consoleStack = [];
  let parenDepth = 0;
  const readTemplate = (start) => {
    // start는 ` 다음.
    let j = start;
    let text = '';
    let n = 0;
    while (j < src.length && src[j] !== '`') {
      if (src[j] === '\\') {
        const nx = src[j + 1];
        text += nx === 'n' ? '\n' : nx === 't' ? '\t' : nx;
        j += 2;
        continue;
      }
      if (src[j] === '$' && src[j + 1] === '{') {
        let depth = 0;
        let k = j + 2;
        for (; k < src.length; k += 1) {
          const c = src[k];
          if (c === '`') {
            k = readTemplate(k + 1).end;
            continue;
          }
          if (c === "'" || c === '"') {
            let q = k + 1;
            while (q < src.length && src[q] !== c) q += src[q] === '\\' ? 2 : 1;
            k = q;
            continue;
          }
          if (c === '{') depth += 1;
          else if (c === '}') {
            if (depth === 0) break;
            depth -= 1;
          }
        }
        text += `{${n++}}`;
        j = k + 1;
        continue;
      }
      text += src[j];
      j += 1;
    }
    return { end: j + 1, text, holes: n };
  };
  while (i < src.length) {
    const c = src[i];
    if (c === '/' && src[i + 1] === '/') {
      i = src.indexOf('\n', i);
      if (i < 0) break;
      continue;
    }
    if (c === '/' && src[i + 1] === '*') {
      i = src.indexOf('*/', i + 2) + 2;
      continue;
    }
    if (c === '/' && regexAllowedAfter.has(lastSig)) {
      // 정규식 — 문자 집합 [...] 안의 / 는 끝이 아니다.
      let j = i + 1;
      let inClass = false;
      while (j < src.length && src[j] !== '\n') {
        if (src[j] === '\\') j += 2;
        else if (src[j] === '[') (inClass = true), (j += 1);
        else if (src[j] === ']') (inClass = false), (j += 1);
        else if (src[j] === '/' && !inClass) break;
        else j += 1;
      }
      j += 1;
      while (/[a-z]/.test(src[j] ?? '')) j += 1;
      i = j;
      lastSig = 'regex';
      continue;
    }
    if (c === "'" || c === '"') {
      let j = i + 1;
      let text = '';
      while (j < src.length && src[j] !== c && src[j] !== '\n') {
        if (src[j] === '\\') {
          const nx = src[j + 1];
          text += nx === 'n' ? '\n' : nx === 't' ? '\t' : nx;
          j += 2;
          continue;
        }
        text += src[j];
        j += 1;
      }
      out.push({ value: text, template: false, console: consoleStack.length > 0 });
      i = j + 1;
      lastSig = 'str';
      continue;
    }
    if (c === '`') {
      const t = readTemplate(i + 1);
      out.push({ value: t.text, template: t.holes > 0, console: consoleStack.length > 0 });
      i = t.end;
      lastSig = 'str';
      continue;
    }
    if (/[A-Za-z_$]/.test(c)) {
      let j = i + 1;
      while (/[A-Za-z0-9_$]/.test(src[j] ?? '')) j += 1;
      const word = src.slice(i, j);
      // console.log( … ) 안은 뺀다.
      if (word === 'console' && src[j] === '.') {
        let k = j + 1;
        while (/[A-Za-z]/.test(src[k] ?? '')) k += 1;
        if (src[k] === '(') {
          consoleStack.push(parenDepth);
          parenDepth += 1;
          i = k + 1;
          lastSig = '(';
          continue;
        }
      }
      i = j;
      lastSig = ['return', 'typeof', 'case', 'do', 'else'].includes(word) ? word : 'id';
      continue;
    }
    if (c === '(') parenDepth += 1;
    if (c === ')') {
      parenDepth -= 1;
      if (consoleStack.length && consoleStack[consoleStack.length - 1] === parenDepth) consoleStack.pop();
    }
    if (!/\s/.test(c)) lastSig = c === '=' && src[i + 1] === '>' ? '=>' : c;
    i += 1;
  }
  return out;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const keys = new Set();
  const contexts = new Map();
  for (const f of walk(LIB, '.dart')) {
    if (f.includes(`${path.sep}l10n${path.sep}`)) continue;
    const src = fs.readFileSync(f, 'utf8');
    const rel = path.relative(ROOT, f).split(path.sep).join('/');
    const found = extractDart(src, (k, at) => {
      const list = contexts.get(k) ?? [];
      if (list.length >= 2) return;
      const lineStart = src.lastIndexOf('\n', at) + 1;
      const lineEnd = src.indexOf('\n', at);
      list.push(`${rel}: ${src.slice(lineStart, lineEnd < 0 ? undefined : lineEnd).trim().slice(0, 160)}`);
      contexts.set(k, list);
    });
    for (const k of found) keys.add(k);
  }
  const manualPath = path.join(HERE, 'manual.json');
  if (fs.existsSync(manualPath)) {
    for (const m of JSON.parse(fs.readFileSync(manualPath, 'utf8'))) keys.add(decodeText(m.text.slice(1, -1), false));
  }
  const client = [...keys].filter((k) => hasHangul(k)).sort();
  fs.writeFileSync(path.join(HERE, 'keys.json'), `${JSON.stringify(client, null, 1)}\n`);

  const exact = new Set();
  const templates = new Set();
  if (fs.existsSync(SERVER)) {
    for (const f of walk(SERVER, '.js')) {
      for (const lit of jsLiterals(fs.readFileSync(f, 'utf8'))) {
        // 브라우저가 그리는 HTML(설치 안내 페이지 등)·긴 글은 앱이 옮길 일이 없다.
        if (lit.console || !hasHangul(lit.value) || lit.value.includes('<') || lit.value.length > 400) continue;
        if (lit.template) templates.add(lit.value);
        else exact.add(lit.value);
      }
    }
  }
  const server = { exact: [...exact].filter((k) => !keys.has(k)).sort(), templates: [...templates].sort() };
  fs.writeFileSync(path.join(HERE, 'server_keys.json'), `${JSON.stringify(server, null, 1)}\n`);
  // 아직 번역이 없는 글(앱은 쓰인 자리 한두 줄과 함께) — 번역할 사람·도구가 본다.
  const readJson = (p) => (fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : {});
  const en = readJson(path.join(HERE, 'en.json'));
  const serverEn = readJson(path.join(HERE, 'server_en.json'));
  const pending = {
    client: client.filter((k) => !(k in en)).map((k) => ({ k, ctx: contexts.get(k) ?? [] })),
    server: [...server.exact, ...server.templates].filter((k) => !(k in serverEn) && !(k in en)),
  };
  fs.writeFileSync(path.join(HERE, 'pending.json'), `${JSON.stringify(pending, null, 1)}\n`);
  console.log(`앱 ${client.length}개, 서버 그대로 ${server.exact.length}개 · 틀 ${server.templates.length}개`);
}
