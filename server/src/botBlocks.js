import { clipGraphemes } from './messageLimits.js';

/**
 * 봇 메시지의 **블록**(대화형 봇 메시지)의 순수 규칙 — 바깥 서비스가 보낸 Slack Block Kit 모양(또는 같은 뜻의 camelCase)을 이 앱이
 * 그릴 수 있는 작은 모양으로 걸러 저장하고(messages.bot_blocks), 같은 내용을 글로도 만든다(검색·알림·예전 앱이 보는 messages.text).
 * 단추를 누르면 무엇을 눌렀는지 저장한 블록에서 찾아 맞춰 본다(앱이 보낸 값은 믿지 않는다). DB·네트워크 없이 시험한다
 * (test/botBlocks.test.js).
 *
 * 저장하는 모양(앱 lib/models/bot_blocks.dart와 같다):
 *   { type: 'header', text }
 *   { type: 'section', text?, fields: [글…], accessory?: 요소 }
 *   { type: 'context', text }
 *   { type: 'divider' }
 *   { type: 'image', file, alt?, title? }        — file은 서버가 받아 둔 업로드 경로(/uploads/…). 받기 전에는 src(바깥 주소)
 *   { type: 'actions', blockId?, elements: [요소…] }
 * 요소:
 *   { type: 'button', actionId, text, value?, url?, style?: 'primary' | 'danger' }   — url이 있으면 링크 단추(누르면 그 주소를 연다)
 *   { type: 'select', actionId, placeholder?, options: [{ text, value }], initial? }
 */

export const BLOCKS_MAX = 50;
export const BLOCK_ELEMENTS_MAX = 10;
export const SECTION_FIELDS_MAX = 10;
export const SELECT_OPTIONS_MAX = 100;
/** 블록에서 받아 둘 바깥 그림 수 — 나머지 그림 블록은 뺀다. */
export const BLOCK_IMAGES_MAX = 4;
/** 저장할 블록 전체(JSON)의 상한 — 넘으면 뒤쪽 블록부터 뺀다. */
export const BLOCKS_JSON_MAX = 32 * 1024;

const LIMITS = { header: 150, section: 3000, field: 2000, context: 2000, button: 75, value: 2000, actionId: 255, url: 3000, option: 75 };

/** Slack 형식의 <url|글>·<url> 링크와 이스케이프(&amp; 등)를 보통 글로. */
export function plainFromSlack(text) {
  return String(text ?? '')
    .replace(/<((?:https?|mailto):[^|>]+)\|([^>]+)>/g, '$2 ($1)')
    .replace(/<((?:https?|mailto):[^>]+)>/g, '$1')
    .replace(/<!(here|channel|everyone)>/g, '@$1')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&');
}

/** 글 칸 하나 — 문자열이거나 Slack 글 객체({ type: 'plain_text' | 'mrkdwn', text }). 제어 문자(줄바꿈·탭 빼고)를 떼고 [max]자까지. */
function textOf(value, max) {
  const raw = typeof value === 'string' ? value : value && typeof value === 'object' && typeof value.text === 'string' ? value.text : '';
  const cleaned = plainFromSlack(raw)
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '')
    .trim();
  return cleaned ? clipGraphemes(cleaned, max) : '';
}

/** 링크 단추·그림의 주소 — http(s)만, 길이 상한. 아니면 null. */
function httpUrlOf(value, max = LIMITS.url) {
  if (typeof value !== 'string' || value.length > max) return null;
  try {
    const u = new URL(value.trim());
    return u.protocol === 'https:' || u.protocol === 'http:' ? u.href : null;
  } catch {
    return null;
  }
}

/** action_id(Slack) / actionId — 비거나 너무 길면 null(그러면 자리 번호로 만든다). */
function actionIdOf(el) {
  const v = el?.action_id ?? el?.actionId;
  if (typeof v !== 'string') return null;
  const t = v.trim();
  return t && t.length <= LIMITS.actionId && !/[\u0000-\u001f\u007f]/.test(t) ? t : null;
}

/** 선택지 하나 — Slack { text: { type, text }, value } / { text, value }. */
function optionOf(o) {
  const text = textOf(o?.text, LIMITS.option);
  const value = typeof o?.value === 'string' ? o.value.slice(0, LIMITS.value) : typeof o?.value === 'number' ? String(o.value) : '';
  return text && value ? { text, value } : null;
}

/**
 * 요소 하나(단추·선택지) → 저장 모양 또는 null. [autoId]는 action_id가 없을 때 쓸 자리 번호. [seen]은 이 메시지에서 이미 쓴
 * actionId들 — 같은 id가 또 오면 자리 번호로 바꾼다(누른 단추를 하나로 찾게).
 */
function elementOf(el, autoId, seen) {
  if (!el || typeof el !== 'object') return null;
  const pickId = () => {
    let id = actionIdOf(el) ?? autoId;
    if (seen.has(id)) id = autoId;
    seen.add(id);
    return id;
  };
  if (el.type === 'button') {
    const text = textOf(el.text, LIMITS.button);
    if (!text) return null;
    const url = httpUrlOf(el.url);
    const value = typeof el.value === 'string' ? el.value.slice(0, LIMITS.value) : null;
    const style = el.style === 'primary' || el.style === 'danger' ? el.style : null;
    return { type: 'button', actionId: pickId(), text, value, url, style };
  }
  if (el.type === 'static_select' || el.type === 'select') {
    const options = (Array.isArray(el.options) ? el.options : [])
      .slice(0, SELECT_OPTIONS_MAX)
      .map(optionOf)
      .filter(Boolean);
    if (options.length === 0) return null;
    const initialValue = el.initial_option?.value ?? el.initial ?? null;
    const initial = options.some((o) => o.value === initialValue) ? initialValue : null;
    return { type: 'select', actionId: pickId(), placeholder: textOf(el.placeholder, LIMITS.option) || null, options, initial };
  }
  return null;
}

/**
 * 받은 블록 목록 → 저장할 블록(그림은 아직 src) 또는 null(그릴 것이 없음). 모르는 블록·요소는 뺀다. 그림 블록은 [BLOCK_IMAGES_MAX]개까지.
 */
export function sanitizeBlocks(input) {
  if (!Array.isArray(input)) return null;
  const out = [];
  const seen = new Set();
  let images = 0;
  input.slice(0, BLOCKS_MAX).forEach((b, i) => {
    if (!b || typeof b !== 'object') return;
    switch (b.type) {
      case 'header': {
        const text = textOf(b.text, LIMITS.header);
        if (text) out.push({ type: 'header', text });
        break;
      }
      case 'section': {
        const text = textOf(b.text, LIMITS.section);
        const fields = (Array.isArray(b.fields) ? b.fields : [])
          .slice(0, SECTION_FIELDS_MAX)
          .map((f) => textOf(f, LIMITS.field))
          .filter(Boolean);
        const accessory = elementOf(b.accessory, `${i}-0`, seen);
        if (text || fields.length || accessory) out.push({ type: 'section', text: text || null, fields, accessory });
        break;
      }
      case 'context': {
        const text = (Array.isArray(b.elements) ? b.elements : [])
          .slice(0, 10)
          .map((e) => (e?.type === 'image' ? '' : textOf(e, LIMITS.context)))
          .filter(Boolean)
          .join('  ');
        if (text) out.push({ type: 'context', text: clipGraphemes(text, LIMITS.context) });
        break;
      }
      case 'divider':
        out.push({ type: 'divider' });
        break;
      case 'image': {
        const src = httpUrlOf(b.image_url ?? b.imageUrl);
        if (src && images < BLOCK_IMAGES_MAX) {
          images += 1;
          out.push({ type: 'image', src, alt: textOf(b.alt_text ?? b.alt, LIMITS.field) || null, title: textOf(b.title, LIMITS.header) || null });
        }
        break;
      }
      case 'actions': {
        const elements = (Array.isArray(b.elements) ? b.elements : [])
          .slice(0, BLOCK_ELEMENTS_MAX)
          .map((el, j) => elementOf(el, `${i}-${j}`, seen))
          .filter(Boolean);
        const blockId = typeof (b.block_id ?? b.blockId) === 'string' ? String(b.block_id ?? b.blockId).slice(0, LIMITS.actionId) : null;
        if (elements.length) out.push({ type: 'actions', blockId, elements });
        break;
      }
      default:
        break;
    }
  });
  // 전체 크기 상한 — 넘으면 뒤에서부터 뺀다.
  while (out.length && JSON.stringify(out).length > BLOCKS_JSON_MAX) out.pop();
  return out.length ? out : null;
}

/** 아직 받지 않은 그림 블록의 바깥 주소들(나온 순서). */
export const blockImageSources = (blocks) => (blocks ?? []).filter((b) => b.type === 'image' && b.src).map((b) => b.src);

/**
 * 그림 블록의 바깥 주소를 받아 둔 업로드 경로로 바꾼다 — [stored]는 주소 → 경로(못 받았으면 없음). 못 받은 그림 블록은 뺀다(그 주소는
 * 글로 남긴다 — 보는 사람의 앱이 바깥 그림을 직접 받지 않게). 블록이 다 빠지면 null.
 */
export function resolveBlockImages(blocks, stored) {
  if (!blocks) return null;
  const out = [];
  for (const b of blocks) {
    if (b.type !== 'image') {
      out.push(b);
      continue;
    }
    const file = b.file ?? stored.get(b.src);
    if (file) out.push({ type: 'image', file, alt: b.alt ?? null, title: b.title ?? null });
    else out.push({ type: 'context', text: clipGraphemes(`${b.title ?? b.alt ?? '그림'}: ${b.src}`, LIMITS.context) });
  }
  return out.length ? out : null;
}

/** 저장한 블록의 그림 경로를 [sign](서명 링크 만들기)으로 바꾼 사본 — 메시지 DTO(앱에 보낼 때)에. */
export function mapBlockImages(blocks, sign) {
  if (!Array.isArray(blocks)) return null;
  return blocks.map((b) => (b.type === 'image' ? { type: 'image', url: b.file ? sign(b.file) : null, alt: b.alt ?? null, title: b.title ?? null } : b));
}

/** 블록을 글로 — 블록을 못 그리는 곳(검색·알림·예전 앱·공개 API의 text)에서 읽힐 내용. 단추는 [이름]으로. */
export function blocksToText(blocks) {
  const lines = [];
  for (const b of blocks ?? []) {
    if (b.type === 'header' || b.type === 'context') lines.push(b.text);
    else if (b.type === 'section') {
      if (b.text) lines.push(b.text);
      lines.push(...(b.fields ?? []));
      if (b.accessory) lines.push(elementLabel(b.accessory));
    } else if (b.type === 'image' && (b.title || b.alt)) lines.push(b.title ?? b.alt);
    else if (b.type === 'actions') lines.push(b.elements.map(elementLabel).join(' '));
  }
  return lines.filter(Boolean).join('\n');
}

const elementLabel = (el) => (el.type === 'select' ? `[${el.placeholder ?? '선택'}]` : `[${el.text}]`);

/** 블록에 단추·선택지(링크 단추 빼고 — 누르면 서버로 오는 것)가 있는지. */
export function blocksHaveActions(blocks) {
  return (blocks ?? []).some((b) =>
    (b.type === 'actions' ? b.elements : b.type === 'section' && b.accessory ? [b.accessory] : []).some((el) => el.type === 'select' || !el.url),
  );
}

/**
 * 누른 것 찾기 — [actionId]의 요소를 저장한 블록에서 찾아 `{ element, blockId, value }`(value는 단추면 저장한 값, 선택지면 고른 [selected]가
 * 보기 중 하나일 때 그 값), 없거나 맞지 않으면 null. 링크 단추는 서버로 오지 않으므로 찾지 않는다.
 */
export function findBlockAction(blocks, actionId, selected) {
  if (typeof actionId !== 'string') return null;
  for (const b of blocks ?? []) {
    const elements = b.type === 'actions' ? b.elements : b.type === 'section' && b.accessory ? [b.accessory] : [];
    for (const el of elements) {
      if (el.actionId !== actionId) continue;
      if (el.type === 'button') return el.url ? null : { element: el, blockId: b.blockId ?? null, value: el.value ?? null };
      if (el.type === 'select') {
        const option = el.options.find((o) => o.value === selected);
        return option ? { element: el, blockId: b.blockId ?? null, value: option.value, optionText: option.text } : null;
      }
    }
  }
  return null;
}
