import { sanitizeTextFormat } from './textFormat.js';

/**
 * 서식 있는 메일 쓰기 — 앱의 쓰기 창은 채팅·공지와 같은 방식으로 본문을 평문([text])과 서식 구간([format] — textFormat.js의
 * `[{ s, e, f, h? }]`, 공지와 같은 rich 비트: 굵게·기울임·밑줄·취소선·코드·인용·제목·글자색·링크)으로 보낸다. 여기서 그 둘을 메일의
 * HTML 본문으로 바꾼다(글자 본문은 [text] 그대로 함께 보낸다 — multipart/alternative). 목록은 글자("1. "·"• ")로 들어 있어 그대로 둔다.
 *
 * 임시 저장본에는 서식 구간을 숨은 부분(FORMAT_PART_TYPE)으로 같이 넣어 이어 쓸 때 되살린다 — HTML을 다시 구간으로 바꾸면 어긋나서.
 */

/** 임시 저장본에 넣는 서식 구간 부분의 형식 — 보낸 메일에는 넣지 않는다. 읽을 때는 첨부 목록에서 숨긴다. */
export const FORMAT_PART_TYPE = 'application/x-tangotalk-format+json';

const BOLD = 1;
const ITALIC = 2;
const UNDERLINE = 4;
const STRIKE = 8;
const CODE = 16;
const QUOTE = 32;
const H1 = 64;
const H2 = 128;
const H3 = 256;
const COLOR_BIT = 512;
const COLOR_UNIT = 1024;

const escapeHtml = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/**
 * 글자 하나의 HTML — 줄 앞 공백·연달은 공백은 &nbsp;로(HTML에서 하나로 줄지 않게 — 메일 프로그램마다 white-space를 무시하는 곳이
 * 있다), 탭은 &nbsp; 넷.
 */
function charHtml(text, i, lineStart) {
  const ch = text[i];
  if (ch === ' ') return i === lineStart || text[i - 1] === ' ' ? '&nbsp;' : ' ';
  if (ch === '\t') return '&nbsp;&nbsp;&nbsp;&nbsp;';
  return escapeHtml(ch);
}

const colorOf = (f) => (Math.floor(f / COLOR_BIT) % 2 === 1 ? Math.floor(f / COLOR_UNIT) % 0x1000000 : null);
const inlineBits = (f) => f % COLOR_BIT & (BOLD | ITALIC | UNDERLINE | STRIKE | CODE);
const lineBits = (f) => f % COLOR_BIT & (QUOTE | H1 | H2 | H3);

/** 메일로 내보낼 링크 — 앱 안 링크(tangotalk://)는 받는 사람이 못 여니 글자로만 둔다. */
const mailHref = (h) => (typeof h === 'string' && /^(https?:\/\/|mailto:)/i.test(h) ? h : null);

/** 한 줄의 글자들([from, to)) → 서식을 입힌 HTML. */
function inlineHtml(text, flags, hrefs, from, to) {
  let out = '';
  let i = from;
  while (i < to) {
    const f = flags[i];
    const h = hrefs[i];
    let j = i + 1;
    while (j < to && flags[j] === f && hrefs[j] === h) j++;
    let seg = '';
    for (let k = i; k < j; k++) seg += charHtml(text, k, from);
    const bits = inlineBits(f);
    const color = colorOf(f);
    if (bits & CODE) seg = `<code style="font-family:Consolas,'Courier New',monospace;background:#f3f4f6;padding:0 3px;border-radius:3px">${seg}</code>`;
    if (bits & STRIKE) seg = `<s>${seg}</s>`;
    if (bits & UNDERLINE) seg = `<u>${seg}</u>`;
    if (bits & ITALIC) seg = `<i>${seg}</i>`;
    if (bits & BOLD) seg = `<b>${seg}</b>`;
    if (color !== null) seg = `<span style="color:#${color.toString(16).padStart(6, '0')}">${seg}</span>`;
    if (h) seg = `<a href="${escapeHtml(h)}">${seg}</a>`;
    out += seg;
    i = j;
  }
  return out;
}

const HEADING_STYLE = {
  [H1]: 'font-size:1.6em;font-weight:bold;margin:0.5em 0 0.2em',
  [H2]: 'font-size:1.35em;font-weight:bold;margin:0.45em 0 0.2em',
  [H3]: 'font-size:1.15em;font-weight:bold;margin:0.4em 0 0.2em',
};
const QUOTE_STYLE = 'margin:0.2em 0 0.2em 0.4em;padding-left:0.8em;border-left:3px solid #c7cbd1;color:#4b5563';

/**
 * 평문 [text]와 서식 구간 [runs](이미 sanitizeTextFormat을 거친 것) → 메일 HTML 본문(문서 전체). 인용 줄은 이어진 것끼리 한
 * 덩어리, 제목 줄은 제 덩어리, 나머지 줄은 <br>로 잇는다.
 */
export function formatToHtml(text, runs) {
  const n = text.length;
  const flags = new Array(n).fill(0);
  const hrefs = new Array(n).fill(null);
  // 앱이 보내는 구간은 겹치지 않는다(rich_text_format.dart _Chars.toRuns) — 겹치면 뒤의 것.
  for (const r of runs ?? []) {
    const h = mailHref(r.h);
    for (let i = Math.max(0, r.s); i < Math.min(n, r.e); i++) {
      flags[i] = r.f;
      hrefs[i] = h;
    }
  }
  // 줄마다 [시작, 끝)과 줄 서식(줄의 첫 글자 — 앱이 줄 서식을 줄 전체에 건다).
  const lines = [];
  let start = 0;
  for (let i = 0; i <= n; i++) {
    if (i === n || text[i] === '\n') {
      lines.push({ from: start, to: i, kind: i > start ? lineBits(flags[start]) : 0 });
      start = i + 1;
    }
  }
  const blocks = [];
  let plain = [];
  let quote = [];
  const flushPlain = () => {
    if (plain.length) blocks.push(`<div>${plain.join('<br>')}</div>`);
    plain = [];
  };
  const flushQuote = () => {
    if (quote.length) blocks.push(`<blockquote style="${QUOTE_STYLE}">${quote.join('<br>')}</blockquote>`);
    quote = [];
  };
  for (const line of lines) {
    const html = inlineHtml(text, flags, hrefs, line.from, line.to);
    const heading = line.kind & H1 ? H1 : line.kind & H2 ? H2 : line.kind & H3 ? H3 : 0;
    if (heading) {
      flushPlain();
      flushQuote();
      blocks.push(`<div style="${HEADING_STYLE[heading]}">${html || '&nbsp;'}</div>`);
    } else if (line.kind & QUOTE) {
      flushPlain();
      quote.push(html);
    } else {
      flushQuote();
      plain.push(html);
    }
  }
  flushPlain();
  flushQuote();
  return (
    '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>' +
    `<div style="font-family:'Malgun Gothic','Apple SD Gothic Neo',Arial,sans-serif;font-size:14px;line-height:1.6;color:#111827">${blocks.join('')}</div>` +
    '</body></html>'
  );
}

/** 보낼 메일의 서식 구간 — 본문에 맞지 않는 것은 버린다(공지와 같은 rich 비트). 서식이 없으면 null(글자 메일). */
export const composeFormat = (format, text) => sanitizeTextFormat(format, text, { rich: true });

/** 임시 저장본의 숨은 서식 부분(nodemailer 첨부 모양) — 첨부 목록 맨 뒤에 둔다(이어 온 첨부 번호가 앞쪽 그대로이게). */
export const formatPartOf = (runs) => ({
  content: JSON.stringify({ v: 1, runs }),
  // 이름을 비워 둔다 — nodemailer가 "attachment-N.bin"을 붙이면 메일 프로그램들이 첨부로 보여 준다.
  filename: false,
  contentType: FORMAT_PART_TYPE,
  contentDisposition: 'inline',
});

/** 읽은 메일(mailparser)의 숨은 서식 부분 → 본문 [text]에 맞는 서식 구간(없거나 어긋나면 null). */
export function formatFromParsed(parsed, text) {
  const part = (parsed?.attachments ?? []).find((a) => String(a.contentType ?? '').toLowerCase() === FORMAT_PART_TYPE);
  if (!part) return null;
  try {
    const data = JSON.parse(Buffer.from(part.content).toString('utf8'));
    return composeFormat(data?.runs, text);
  } catch {
    return null;
  }
}

/** 첨부 목록에서 숨길 부분인지(서식 부분). */
export const isFormatPart = (a) => String(a?.contentType ?? '').toLowerCase() === FORMAT_PART_TYPE;
