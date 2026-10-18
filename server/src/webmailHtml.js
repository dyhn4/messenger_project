import { parseDocument } from 'htmlparser2';

/**
 * HTML 메일을 **걸러 낸 서식 문서**로 바꾼다(webmailRules.js messageDetail이 부른다 — DB·네트워크 없이 시험한다). 앱은 HTML을 그대로
 * 그리지 않고(웹뷰 없음) 이 문서만 그린다(client lib/screens/mail/mail_rich_view.dart) — 그래서 스크립트·양식·스타일시트·iframe은 애초에
 * 실을 자리가 없다. 남기는 것은 문단·제목·목록·인용·표·가로줄·그림과 글자 모양(굵게·기울임·밑줄·취소선·고정폭·색·배경·크기)·정렬·링크
 * (http·https·mailto만)뿐이다.
 *
 * 문서 모양 — 블록 `{ b: 'div'|'p'|'h1'…'h6'|'quote'|'pre'|'ul'|'ol'|'li'|'table'|'tr'|'td'|'hr'|'img', c: [자식], al?, bg?, … }`와 글 조각
 * `{ x: 글, s?: { b, i, u, st, m, c, bg, z }, h?: 링크 }`·줄바꿈 `{ br: 1 }`. 블록의 자식 중 이어진 글 조각들이 한 문단이다.
 *  - 그림 `{ b: 'img', src: { cid: 첨부 번호 } | { url } | { data, mime }, alt?, w?, h?, h(링크)? }` — 바깥 그림(url)은 앱이 바로 받지 않고
 *    사용자가 "그림 보기"를 누르면 서버(/mail/remote-image — 사설 주소 막음)를 거쳐 받는다(받는 순간 보낸 쪽이 열어 봤음을 알 수 있어서).
 *    가로나 세로가 2px 이하인 그림(추적 픽셀)은 버린다.
 *  - 숨긴 글(display:none·visibility:hidden·글자 크기 0 등 — 미리보기 줄 꼼수)은 버린다.
 *  - 표는 칸이 하나뿐인 줄만 있으면 그냥 블록으로 풀고(배치용 표가 대부분이라), 칸이 여럿이면 표로 둔다(td의 너비 `wp`(%)·`wx`(px)).
 *  - 노드 수·글 길이·깊이에 상한이 있다(넘으면 [truncated] — 앱은 "글자로 보기"를 권한다).
 */

export const RICH_NODES_MAX = 12_000;
export const RICH_TEXT_MAX = 300_000;
const DEPTH_MAX = 60;
const DATA_IMAGE_MAX = 700_000;
const URL_MAX = 2000;
const IMAGE_SIDE_MAX = 2000;

/** 내용째 버리는 요소. */
const SKIP = new Set([
  'script', 'style', 'head', 'title', 'meta', 'link', 'base', 'iframe', 'frame', 'frameset', 'object', 'embed', 'applet', 'param',
  'input', 'button', 'select', 'option', 'optgroup', 'textarea', 'datalist', 'output', 'svg', 'math', 'template', 'noscript',
  'audio', 'video', 'source', 'track', 'canvas', 'map', 'area', 'picture', 'dialog', 'portal', 'slot',
]);

/** 블록 요소 → 문서의 블록 종류. 나머지(span·font·a·b…·모르는 요소)는 글 조각을 감싸는 것으로 본다. */
const BLOCK = {
  html: 'div', body: 'div', div: 'div', section: 'div', article: 'div', header: 'div', footer: 'div', main: 'div', nav: 'div',
  aside: 'div', address: 'div', figure: 'div', figcaption: 'div', details: 'div', summary: 'div', form: 'div', fieldset: 'div',
  legend: 'div', caption: 'div', center: 'div', dl: 'div', dt: 'div', dd: 'quote', p: 'p', h1: 'h1', h2: 'h2', h3: 'h3', h4: 'h4',
  h5: 'h5', h6: 'h6', blockquote: 'quote', pre: 'pre', listing: 'pre', xmp: 'pre', plaintext: 'pre', ul: 'ul', ol: 'ol', menu: 'ul',
  li: 'li', table: 'table', tr: 'tr', td: 'td', th: 'td', hr: 'hr',
};
/** 표 안에서 줄을 감싸기만 하는 요소 — 블록을 만들지 않고 자식을 그대로 표에 넣는다. */
const TABLE_SECTIONS = new Set(['thead', 'tbody', 'tfoot', 'colgroup']);

const NAMED_COLORS = {
  black: '#000000', white: '#ffffff', red: '#ff0000', green: '#008000', blue: '#0000ff', gray: '#808080', grey: '#808080',
  silver: '#c0c0c0', maroon: '#800000', navy: '#000080', purple: '#800080', teal: '#008080', olive: '#808000', orange: '#ffa500',
  yellow: '#ffff00', lime: '#00ff00', aqua: '#00ffff', cyan: '#00ffff', fuchsia: '#ff00ff', magenta: '#ff00ff',
  darkgray: '#a9a9a9', darkgrey: '#a9a9a9', lightgray: '#d3d3d3', lightgrey: '#d3d3d3', darkblue: '#00008b', darkred: '#8b0000',
  darkgreen: '#006400', brown: '#a52a2a', pink: '#ffc0cb', gold: '#ffd700', whitesmoke: '#f5f5f5', gainsboro: '#dcdcdc',
  dimgray: '#696969', dimgrey: '#696969', royalblue: '#4169e1', steelblue: '#4682b4', crimson: '#dc143c', tomato: '#ff6347',
};

const hex2 = (n) => Math.max(0, Math.min(255, Math.round(n))).toString(16).padStart(2, '0');

/** CSS 색 → '#rrggbb'(투명·모르는 값은 null). */
export function parseColor(raw) {
  const v = String(raw ?? '').trim().toLowerCase().replace(/\s*!important$/, '');
  if (!v) return null;
  if (NAMED_COLORS[v]) return NAMED_COLORS[v];
  let m = /^#([0-9a-f]{3})$/.exec(v);
  if (m) return `#${[...m[1]].map((c) => c + c).join('')}`;
  m = /^#([0-9a-f]{6})(?:[0-9a-f]{2})?$/.exec(v);
  if (m) return `#${m[1]}`;
  m = /^rgba?\(\s*([\d.]+)%?\s*[,\s]\s*([\d.]+)%?\s*[,\s]\s*([\d.]+)%?\s*(?:[,/]\s*([\d.]+)(%?)\s*)?\)$/.exec(v);
  if (m) {
    if (m[4] !== undefined) {
      const alpha = Number(m[4]) / (m[5] ? 100 : 1);
      if (!(alpha >= 0.1)) return null;
    }
    return `#${hex2(m[1])}${hex2(m[2])}${hex2(m[3])}`;
  }
  return null;
}

const FONT_KEYWORDS = { 'xx-small': 0.6, 'x-small': 0.7, small: 0.85, medium: 1, large: 1.15, 'x-large': 1.4, 'xx-large': 1.7, smaller: 0.85, larger: 1.15 };
const FONT_TAG_SIZE = { 1: 0.7, 2: 0.85, 3: 1, 4: 1.15, 5: 1.4, 6: 1.7, 7: 2.2 };

/** 글자 크기 → 기본(14px)에 대한 배율(모르면 null). 0에 가까우면 0(숨긴 글). */
export function parseFontScale(raw) {
  const v = String(raw ?? '').trim().toLowerCase().replace(/\s*!important$/, '');
  if (FONT_KEYWORDS[v]) return FONT_KEYWORDS[v];
  const m = /^([\d.]+)(px|pt|em|rem|%)?$/.exec(v);
  if (!m) return null;
  const n = Number(m[1]);
  if (!Number.isFinite(n)) return null;
  const unit = m[2] ?? 'px';
  const px = unit === 'px' ? n : unit === 'pt' ? (n * 4) / 3 : unit === '%' ? (n / 100) * 14 : n * 14;
  return Math.round((px / 14) * 100) / 100;
}

/** style 속성 → { 속성: 값 }(소문자 이름). */
export function parseStyle(raw) {
  const out = {};
  for (const part of String(raw ?? '').split(';')) {
    const i = part.indexOf(':');
    if (i <= 0) continue;
    const key = part.slice(0, i).trim().toLowerCase();
    const value = part.slice(i + 1).trim();
    if (key && value) out[key] = value;
  }
  return out;
}

const clean = (v) => String(v ?? '').trim().toLowerCase().replace(/\s*!important$/, '');

/** 이 요소를 숨기는 스타일·속성인지(미리보기 줄 꼼수·Outlook 숨김). */
function isHidden(el, css) {
  if (el.attribs?.hidden !== undefined) return true;
  const display = clean(css.display);
  if (display === 'none') return true;
  if (clean(css.visibility) === 'hidden') return true;
  if (clean(css['mso-hide']) === 'all') return true;
  if (css.opacity !== undefined && Number(clean(css.opacity)) === 0) return true;
  const maxH = clean(css['max-height']);
  if ((maxH === '0' || maxH === '0px') && clean(css.overflow) === 'hidden') return true;
  if (css['font-size'] !== undefined) {
    const z = parseFontScale(css['font-size']);
    if (z !== null && z < 0.35) return true;
  }
  return false;
}

/** 링크 — http·https·mailto만(그 밖은 글만 남긴다). */
export function safeHref(raw) {
  const v = String(raw ?? '').trim();
  if (!v || v.length > URL_MAX) return null;
  if (/^https?:\/\//i.test(v)) {
    try {
      return new URL(v).toString();
    } catch {
      return null;
    }
  }
  if (/^mailto:[^\s<>"]+$/i.test(v)) return v;
  return null;
}

/** px 크기 속성(가로·세로) — 숫자 px만, 상한까지. */
function pxOf(raw) {
  const m = /^\s*(\d+(?:\.\d+)?)\s*(px)?\s*$/i.exec(String(raw ?? ''));
  if (!m) return null;
  return Math.min(IMAGE_SIDE_MAX, Math.round(Number(m[1])));
}

/** 첨부의 cid → 첨부 번호. */
function cidMapOf(attachments) {
  const map = new Map();
  attachments.forEach((a, i) => {
    for (const raw of [a?.cid, a?.contentId]) {
      if (typeof raw !== 'string' || !raw) continue;
      map.set(raw.replace(/^<|>$/g, '').trim().toLowerCase(), i);
    }
  });
  return map;
}

const sameStyle = (a, b) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
const isRun = (n) => typeof n?.x === 'string';
const isBreak = (n) => n?.br === 1;
const isInline = (n) => isRun(n) || isBreak(n);

/**
 * HTML → `{ doc, remoteImages, truncated, cidIndexes }`. [attachments]는 mailparser 첨부(cid 그림을 찾는 데). 실패하지 않는다(망가진 HTML도
 * 할 수 있는 만큼).
 */
export function htmlToRich(html, { attachments = [] } = {}) {
  const dom = parseDocument(String(html ?? ''), { decodeEntities: true, lowerCaseTags: true, lowerCaseAttributeNames: true });
  const cids = cidMapOf(attachments);
  const state = { nodes: 0, text: 0, truncated: false, remoteImages: 0, cidIndexes: new Set() };
  const root = { b: 'div', c: [] };

  const budget = () => {
    if (state.nodes >= RICH_NODES_MAX || state.text >= RICH_TEXT_MAX) {
      state.truncated = true;
      return false;
    }
    return true;
  };

  /** 표·줄에 맞는 자리로 넣는다 — 표에는 줄만, 줄에는 칸만(아니면 감추어진 줄·칸을 만들어 그 안에). */
  function append(parent, child) {
    if (parent.b === 'table' && child.b !== 'tr') {
      let row = parent.c[parent.c.length - 1];
      if (!row?.implicit) {
        row = { b: 'tr', c: [], implicit: true };
        parent.c.push(row);
      }
      return append(row, child);
    }
    if (parent.b === 'tr' && child.b !== 'td') {
      let cell = parent.c[parent.c.length - 1];
      if (!cell?.implicit) {
        cell = { b: 'td', c: [], implicit: true };
        parent.c.push(cell);
      }
      return append(cell, child);
    }
    parent.c.push(child);
  }

  function pushText(parent, raw, ctx) {
    let text = raw;
    if (!ctx.pre) text = text.replace(/[\t\n\r\f ]+/g, ' ');
    text = text.replace(/ /g, ' ').replace(/[​‌‍⁠﻿͏­]/g, '');
    if (!text) return;
    if ((parent.b === 'table' || parent.b === 'tr') && !text.trim()) return;
    if (!budget()) return;
    const room = RICH_TEXT_MAX - state.text;
    if (text.length > room) {
      text = text.slice(0, room);
      state.truncated = true;
    }
    state.text += text.length;
    state.nodes += 1;
    const run = { x: text };
    if (ctx.s && Object.keys(ctx.s).length) run.s = ctx.s;
    if (ctx.href) run.h = ctx.href;
    append(parent, run);
  }

  function pushImage(parent, el, css, ctx) {
    const a = el.attribs ?? {};
    const w = pxOf(a.width) ?? pxOf(css.width);
    const h = pxOf(a.height) ?? pxOf(css.height);
    if ((w !== null && w <= 2) || (h !== null && h <= 2)) return; // 추적 픽셀
    const srcRaw = String(a.src ?? '').trim();
    let src = null;
    if (/^cid:/i.test(srcRaw)) {
      let key = srcRaw.slice(4);
      try {
        key = decodeURIComponent(key);
      } catch {
        /* 그대로 */
      }
      const index = cids.get(key.replace(/^<|>$/g, '').trim().toLowerCase());
      if (index !== undefined) {
        src = { cid: index };
        state.cidIndexes.add(index);
      }
    } else if (/^https?:\/\//i.test(srcRaw) && srcRaw.length <= URL_MAX) {
      const href = safeHref(srcRaw);
      if (href) {
        src = { url: href };
        state.remoteImages += 1;
      }
    } else {
      const m = /^data:(image\/(?:png|jpeg|jpg|gif|webp));base64,([A-Za-z0-9+/=\s]+)$/i.exec(srcRaw);
      if (m && srcRaw.length <= DATA_IMAGE_MAX) src = { data: m[2].replace(/\s+/g, ''), mime: m[1].toLowerCase().replace('jpg', 'jpeg') };
    }
    if (!src || !budget()) return;
    state.nodes += 1;
    const node = { b: 'img', src };
    const alt = typeof a.alt === 'string' ? a.alt.replace(/\s+/g, ' ').trim().slice(0, 200) : '';
    if (alt) node.alt = alt;
    if (w) node.w = w;
    if (h) node.ht = h;
    if (ctx.href) node.h = ctx.href;
    append(parent, node);
  }

  /** 요소의 글 모양을 물려받은 모양에 더한다. */
  function inlineStyle(tag, el, css, inherited, { block }) {
    const s = { ...inherited };
    if (tag === 'b' || tag === 'strong' || tag === 'th') s.b = 1;
    if (tag === 'i' || tag === 'em' || tag === 'cite' || tag === 'var' || tag === 'dfn') s.i = 1;
    if (tag === 'u' || tag === 'ins') s.u = 1;
    if (tag === 's' || tag === 'strike' || tag === 'del') s.st = 1;
    if (tag === 'code' || tag === 'tt' || tag === 'kbd' || tag === 'samp' || tag === 'pre') s.m = 1;
    if (tag === 'small' || tag === 'sub' || tag === 'sup') s.z = Math.round((s.z ?? 1) * 0.85 * 100) / 100;
    if (tag === 'big') s.z = Math.round((s.z ?? 1) * 1.2 * 100) / 100;
    if (tag === 'mark') s.bg = '#ffff00';
    if (tag === 'font') {
      const c = parseColor(el.attribs?.color);
      if (c) s.c = c;
      const size = FONT_TAG_SIZE[String(el.attribs?.size ?? '').trim()];
      if (size) s.z = size;
    }
    const weight = clean(css['font-weight']);
    if (weight === 'bold' || weight === 'bolder' || Number(weight) >= 600) s.b = 1;
    else if (weight === 'normal' || (Number(weight) > 0 && Number(weight) < 600)) delete s.b;
    const fontStyle = clean(css['font-style']);
    if (fontStyle === 'italic' || fontStyle === 'oblique') s.i = 1;
    else if (fontStyle === 'normal') delete s.i;
    const deco = clean(css['text-decoration'] ?? css['text-decoration-line']);
    if (deco.includes('underline')) s.u = 1;
    if (deco.includes('line-through')) s.st = 1;
    if (deco === 'none') delete s.u;
    if (/monospace|courier|consolas/i.test(css['font-family'] ?? '')) s.m = 1;
    const color = parseColor(css.color);
    if (color) s.c = color;
    // 글 조각의 배경은 글을 감싼 요소(span·mark·font)에서만 — 블록의 배경은 블록에 둔다.
    if (!block) {
      const bg = parseColor(css['background-color'] ?? (css.background && !/url\(/i.test(css.background) ? css.background.split(/\s+/)[0] : null));
      if (bg) s.bg = bg;
    }
    if (css['font-size'] !== undefined) {
      const z = parseFontScale(css['font-size']);
      if (z !== null) s.z = Math.min(2.4, Math.max(0.7, z));
    }
    if (s.z !== undefined && Math.abs(s.z - 1) < 0.05) delete s.z;
    return s;
  }

  function walk(node, parent, ctx) {
    if (state.truncated && !budget()) return;
    if (node.type === 'text') return pushText(parent, node.data ?? '', ctx);
    if (node.type !== 'tag' && node.type !== 'root') return; // 주석·doctype·CDATA·스크립트·스타일 노드
    if (node.type === 'root') {
      for (const child of node.children ?? []) walk(child, parent, ctx);
      return;
    }
    const tag = node.name;
    if (SKIP.has(tag)) return;
    const css = parseStyle(node.attribs?.style);
    if (isHidden(node, css)) return;
    if (tag === 'br') {
      if (!budget()) return;
      state.nodes += 1;
      return append(parent, { br: 1 });
    }
    if (tag === 'img') return pushImage(parent, node, css, ctx);
    if (tag === 'wbr') return;
    if (TABLE_SECTIONS.has(tag) && (parent.b === 'table' || parent.b === 'tr')) {
      for (const child of node.children ?? []) walk(child, parent, ctx);
      return;
    }
    let kind = BLOCK[tag];
    // 너무 깊으면 블록을 더 만들지 않는다(글만 이어 붙인다).
    if (kind && ctx.depth >= DEPTH_MAX) kind = null;
    const next = { ...ctx, s: inlineStyle(tag, node, css, ctx.s, { block: !!kind }) };
    if (tag === 'a') {
      const href = safeHref(node.attribs?.href);
      if (href) next.href = href;
    }
    if (!kind) {
      for (const child of node.children ?? []) walk(child, parent, next);
      return;
    }
    if (!budget()) return;
    state.nodes += 1;
    const block = { b: kind, c: [] };
    const align = clean(css['text-align'] ?? node.attribs?.align);
    if (tag === 'center') block.al = 'center';
    else if (['center', 'right', 'left', 'justify'].includes(align) && kind !== 'table') block.al = align;
    const bg = parseColor(css['background-color'] ?? node.attribs?.bgcolor ?? (css.background && !/url\(/i.test(css.background) ? css.background.split(/\s+/)[0] : null));
    if (bg && kind !== 'tr') block.bg = bg;
    if (kind === 'tr' && bg) next.rowBg = bg;
    if (kind === 'td') {
      const width = String(node.attribs?.width ?? css.width ?? '').trim();
      const pct = /^(\d+(?:\.\d+)?)%$/.exec(width);
      if (pct) block.wp = Math.min(100, Math.round(Number(pct[1])));
      else if (pxOf(width)) block.wx = pxOf(width);
      if (!block.bg && ctx.rowBg) block.bg = ctx.rowBg;
    }
    if (kind === 'ol') {
      const start = Number(node.attribs?.start);
      if (Number.isInteger(start) && start !== 1 && Math.abs(start) < 100_000) block.n = start;
    }
    if (kind === 'pre') next.pre = true;
    next.depth = ctx.depth + 1;
    if (kind !== 'td' && kind !== 'tr') delete next.rowBg;
    append(parent, block);
    for (const child of node.children ?? []) walk(child, block, next);
  }

  walk(dom, root, { s: {}, href: null, pre: false, depth: 0 });
  const doc = simplify(root) ?? { b: 'div', c: [] };
  return { doc, remoteImages: state.remoteImages, truncated: state.truncated, cidIndexes: [...state.cidIndexes] };
}

/** 문단(이어진 글 조각) 정리 — 같은 모양 조각 합치기, 문단 앞뒤·줄바꿈 둘레의 빈칸 지우기, 문단 끝 줄바꿈 지우기. */
function tidyInline(runs, pre) {
  const merged = [];
  for (const r of runs) {
    const last = merged[merged.length - 1];
    if (isRun(r) && isRun(last) && sameStyle(last.s, r.s) && last.h === r.h) {
      merged[merged.length - 1] = { ...last, x: last.x + r.x };
    } else {
      merged.push(isRun(r) ? { ...r } : r);
    }
  }
  if (!pre) {
    for (let i = 0; i < merged.length; i++) {
      const r = merged[i];
      if (!isRun(r)) continue;
      const prev = merged[i - 1];
      const next = merged[i + 1];
      if (!prev || isBreak(prev)) r.x = r.x.replace(/^ +/, '');
      if (!next || isBreak(next)) r.x = r.x.replace(/ +$/, '');
      // 앞 조각이 빈칸으로 끝나면 이 조각 앞 빈칸은 하나만.
      if (isRun(prev) && / $/.test(prev.x)) r.x = r.x.replace(/^ +/, '');
    }
  }
  const kept = merged.filter((r) => !isRun(r) || r.x !== '');
  while (kept.length && isBreak(kept[kept.length - 1])) kept.pop();
  while (kept.length && isBreak(kept[0]) && kept.length > 1 && isBreak(kept[1])) kept.shift();
  return kept;
}

/** 블록 다듬기 — 빈 블록·빈 줄 빼기, 칸 하나짜리 표 풀기, 속성 없는 div 걷어 내기. 남길 게 없으면 null. */
function simplify(node) {
  if (isInline(node)) return node;
  if (node.b === 'img' || node.b === 'hr') return node;
  // 자식 먼저.
  let children = [];
  for (const child of node.c ?? []) {
    const s = simplify(child);
    if (s) children.push(s);
  }
  // 문단마다 정리.
  const out = [];
  let group = [];
  const flush = () => {
    if (group.length) out.push(...tidyInline(group, node.b === 'pre'));
    group = [];
  };
  for (const child of children) {
    if (isInline(child)) group.push(child);
    else {
      flush();
      out.push(child);
    }
  }
  flush();
  children = out;

  if (node.b === 'table') {
    const rows = children.filter((r) => r.b === 'tr' && r.c.length);
    if (rows.length === 0) return null;
    // 칸 하나짜리 줄만 있으면 표가 아니라 차례로 쌓인 블록이다.
    if (rows.every((r) => r.c.length === 1)) {
      const blocks = rows.map((r) => {
        const cell = r.c[0];
        const div = { b: 'div', c: cell.c };
        if (cell.al) div.al = cell.al;
        if (cell.bg) div.bg = cell.bg;
        return simplify(div);
      }).filter(Boolean);
      return simplify({ b: 'div', c: blocks, ...(node.bg ? { bg: node.bg } : {}) });
    }
    return { b: 'table', c: rows, ...(node.bg ? { bg: node.bg } : {}) };
  }
  if (node.b === 'tr') {
    const cells = children.filter((c) => c.b === 'td');
    if (cells.every((c) => c.c.length === 0)) return null;
    return { b: 'tr', c: cells };
  }
  if (node.b === 'td') {
    const { implicit, ...rest } = node;
    return { ...rest, c: children };
  }
  if (children.length === 0) return null;
  // 속성 없는 div 안의 블록만 든 속성 없는 div는 걷어 낸다(배치용 겹겹 div).
  const flat = [];
  for (const child of children) {
    if (child.b === 'div' && !child.al && !child.bg && child.c.every((c) => !isInline(c))) flat.push(...child.c);
    else flat.push(child);
  }
  const { implicit, ...rest } = node;
  const result = { ...rest, c: flat };
  if (result.b === 'div' && !result.al && !result.bg && flat.length === 1 && !isInline(flat[0])) return flat[0];
  return result;
}
