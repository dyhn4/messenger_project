import crypto from 'node:crypto';
import { blocksToText, plainFromSlack, sanitizeBlocks } from './botBlocks.js';
import { clipGraphemes, MESSAGE_TEXT_MAX } from './messageLimits.js';

/**
 * 외부 연동(들어오는 웹훅·나가는 웹훅·슬래시 명령·연동 앱·개인 API 토큰)의 **순수 규칙** — 토큰 모양, 바깥 서비스가 보낸 JSON을 글·블록으로
 * 바꾸기, 서명·답 읽기, 나가는 일의 종류·다시 보내기 간격, 누가 만들 수 있는지. DB·네트워크는 integrations.js·webhookDelivery.js·
 * publicApi.js가 한다. `node --test`로 시험한다(test/integrations.test.js).
 */

export const WEBHOOK_TOKEN_PREFIX = 'ttw_';
export const API_TOKEN_PREFIX = 'ttk_';
/** 연동 앱의 봇 토큰 — 공개 API를 봇 이름으로(방에 추가된 곳만). */
export const BOT_TOKEN_PREFIX = 'ttb_';
export const BOT_NAME_MAX = 40;
export const COMMAND_DESCRIPTION_MAX = 100;
export const API_TOKEN_SCOPES = Object.freeze(['read', 'write']);
export const API_TOKEN_MAX_DAYS = 365;
/** 한 사람이 가질 수 있는 API 토큰 수, 한 방의 웹훅 수, 한 팀의 슬래시 명령 수. */
export const API_TOKENS_PER_USER = 20;
export const WEBHOOKS_PER_ROOM = 20;
export const COMMANDS_PER_TEAM = 50;
export const DEFAULT_BOT_EMOJI = '🤖';
/** 슬래시 명령 답을 기다리는 시간 — Slack과 같은 3초보다 조금 넉넉하게. */
export const COMMAND_TIMEOUT_MS = 5000;

/** 메시지 상한에 맞게 자르기 — 잘리면 붙는 …까지 상한 안에 들게 한 글자 덜 남긴다. */
const clipText = (t) => clipGraphemes(t, MESSAGE_TEXT_MAX - 1);

const BASE62 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

/** 비밀 토큰 — [prefix] + 영문·숫자 40자(약 238비트). */
export function generateSecretToken(prefix, randomInt = crypto.randomInt) {
  let s = '';
  for (let i = 0; i < 40; i += 1) s += BASE62[randomInt(BASE62.length)];
  return `${prefix}${s}`;
}

/** 토큰 모양인지(접두어 + 영문·숫자 40자) — 모양이 틀리면 DB를 보지 않는다. */
export function isSecretToken(value, prefix) {
  return typeof value === 'string' && value.length === prefix.length + 40 && value.startsWith(prefix) && /^[A-Za-z0-9]+$/.test(value.slice(prefix.length));
}

/** 화면에 보일 토큰 앞부분(접두어 + 4자). */
export const tokenPrefixOf = (token) => token.slice(0, token.indexOf('_') + 5);

/** 봇 이름 — 앞뒤 공백을 떼고 1~40자. `{ name }` | `{ error }`. */
export function parseBotName(value) {
  if (typeof value !== 'string' || !value.trim()) return { error: '봇 이름을 넣으세요.' };
  const name = value.replace(/[\u0000-\u001f\u007f]/g, '').trim();
  if ([...name].length > BOT_NAME_MAX) return { error: `봇 이름은 ${BOT_NAME_MAX}자까지입니다.` };
  return { name };
}

/** 봇 이모지 — 비우면 🤖, 글자 8개(조합 이모지 포함)까지. */
export function parseBotEmoji(value) {
  if (value === undefined || value === null || value === '') return { emoji: DEFAULT_BOT_EMOJI };
  if (typeof value !== 'string' || [...value.trim()].length > 8 || !value.trim()) return { error: '봇 아이콘은 이모지 하나로 넣으세요.' };
  return { emoji: value.trim() };
}

/** 슬래시 명령 이름 — 앞의 /는 떼고, 영문 소문자·숫자·_·-로 1~32자(영문·숫자로 시작). `{ command }` | `{ error }`. */
export function parseCommandName(value) {
  const c = String(value ?? '')
    .trim()
    .replace(/^\//, '')
    .toLowerCase();
  if (!/^[a-z0-9][a-z0-9_-]{0,31}$/.test(c)) {
    return { error: '명령 이름은 영문 소문자·숫자·_·-로 32자까지 넣으세요(예: deploy).' };
  }
  return { command: c };
}

/** 슬래시 명령을 보낼 주소 — http(s)만, 계정 정보(user:pass@)는 안 된다. `{ url }` | `{ error }`. */
export function parseCommandUrl(value) {
  try {
    const u = new URL(String(value ?? '').trim());
    if (u.protocol !== 'https:' && u.protocol !== 'http:') return { error: '주소는 http:// 또는 https://로 시작해야 합니다.' };
    if (u.username || u.password) return { error: '주소에 계정 정보를 넣지 마세요(서명으로 확인합니다).' };
    if (u.href.length > 1000) return { error: '주소가 너무 깁니다.' };
    return { url: u.href };
  } catch {
    return { error: '주소 모양이 올바르지 않습니다.' };
  }
}

/** 개인 API 토큰 권한 — ['read'] | ['read', 'write'](쓰기는 읽기를 포함). `{ scopes }` | `{ error }`. */
export function parseScopes(value) {
  const list = Array.isArray(value) ? value : [];
  if (list.length === 0 || list.some((s) => !API_TOKEN_SCOPES.includes(s))) return { error: '권한은 read·write 중에서 고르세요.' };
  return { scopes: list.includes('write') ? ['read', 'write'] : ['read'] };
}

/** 만료 날수 — null이면 만료 없음, 1~365일. `{ expiresAt }` | `{ error }`. */
export function parseExpiry(days, now = Date.now()) {
  if (days === undefined || days === null || days === '') return { expiresAt: null };
  const n = Number(days);
  if (!Number.isInteger(n) || n < 1 || n > API_TOKEN_MAX_DAYS) return { error: `만료는 1~${API_TOKEN_MAX_DAYS}일로 정하세요.` };
  return { expiresAt: new Date(now + n * 86_400_000) };
}

const str = (v) => (typeof v === 'string' ? v.trim() : typeof v === 'number' ? String(v) : '');

/** Slack 블록의 글(mrkdwn/plain_text) — section·header·context만(첨부 안의 블록을 글로 붙일 때). */
function blocksText(blocks) {
  const lines = [];
  for (const b of Array.isArray(blocks) ? blocks.slice(0, 50) : []) {
    if (b?.type === 'header' || b?.type === 'section') {
      if (str(b.text?.text)) lines.push(str(b.text.text));
      for (const f of Array.isArray(b.fields) ? b.fields.slice(0, 20) : []) if (str(f?.text)) lines.push(str(f.text));
    } else if (b?.type === 'context') {
      const t = (Array.isArray(b.elements) ? b.elements : []).map((e) => str(e?.text)).filter(Boolean).join(' ');
      if (t) lines.push(t);
    }
  }
  return lines.join('\n');
}

/** Slack 첨부(attachments) — 앞글·제목(링크)·본문·필드·꼬리글. */
function attachmentsText(attachments) {
  const parts = [];
  for (const a of Array.isArray(attachments) ? attachments.slice(0, 20) : []) {
    if (!a || typeof a !== 'object') continue;
    const lines = [];
    if (str(a.pretext)) lines.push(str(a.pretext));
    if (str(a.title)) lines.push(str(a.title_link) ? `${str(a.title)} (${str(a.title_link)})` : str(a.title));
    if (str(a.text)) lines.push(str(a.text));
    for (const f of Array.isArray(a.fields) ? a.fields.slice(0, 20) : []) {
      if (str(f?.title) || str(f?.value)) lines.push(`${str(f.title)}${str(f.title) && str(f.value) ? ': ' : ''}${str(f.value)}`);
    }
    if (blocksText(a.blocks)) lines.push(blocksText(a.blocks));
    if (str(a.footer)) lines.push(str(a.footer));
    if (lines.length === 0 && str(a.fallback)) lines.push(str(a.fallback));
    if (lines.length) parts.push(lines.join('\n'));
  }
  return parts.join('\n\n');
}

/** 한 메시지에 붙일 바깥 그림(Slack 첨부의 image_url·Discord embed 그림 등) 수 — 서버가 받아 업로드 파일로 붙인다. */
export const PAYLOAD_IMAGES_MAX = 4;

/** 본문 곳곳의 그림 주소(블록 밖) — 맨 위 image_url, Slack 첨부의 image_url, Discord embed의 image.url. http(s)만, 같은 주소는 한 번. */
function payloadImageUrls(body) {
  const urls = [str(body.image_url) || str(body.imageUrl)];
  for (const a of Array.isArray(body.attachments) ? body.attachments.slice(0, 20) : []) urls.push(str(a?.image_url));
  for (const e of Array.isArray(body.embeds) ? body.embeds.slice(0, 10) : []) urls.push(str(e?.image?.url));
  return [...new Set(urls.filter((u) => /^https?:\/\//i.test(u) && u.length <= 2000))].slice(0, PAYLOAD_IMAGES_MAX);
}

/**
 * 들어오는 웹훅의 본문 → 올릴 것 `{ text, username?, blocks, imageUrls }` | `{ error }`. 받는 모양:
 *  - 일반 JSON: `{ text }`(또는 message·content·body), 선택으로 `title`·`url`·`image_url`
 *  - Slack 호환(Grafana·Uptime Kuma·Jenkins·GitHub Actions의 Slack 액션 등): `text` + `attachments` / `blocks`(단추·선택지·그림 블록은
 *    그대로 블록으로 — botBlocks.js. text는 블록을 못 그리는 곳에 보일 글로, 없으면 블록에서 만든다)
 *  - Discord 호환: `content` + `embeds`([{ title, description, url, fields, image }])
 *  - 그냥 글(Content-Type: text/plain)
 * 글은 메시지 길이 상한까지 자른다. `username`(Slack·Discord의 보낸 이름)이 있으면 그 이름으로 보인다(봇 표시는 그대로).
 * [imageUrls]는 서버가 받아 그림 첨부로 붙일 바깥 그림 주소. [allowEmpty]면(파일을 함께 올린 multipart) 글이 없어도 된다.
 */
export function webhookPayloadToMessage(body, { allowEmpty = false } = {}) {
  if (typeof body === 'string') {
    const t = body.trim();
    return t || allowEmpty ? { text: clipText(t), blocks: null, imageUrls: [] } : { error: '보낼 글이 없습니다.' };
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { error: 'JSON 객체나 글을 보내세요.' };
  const lines = [];
  if (str(body.title)) lines.push(str(body.title));
  const main = str(body.text) || str(body.message) || str(body.content) || str(body.body);
  if (main) lines.push(main);
  const att = attachmentsText(body.attachments);
  if (att) lines.push(att);
  const blocks = sanitizeBlocks(body.blocks);
  if (blocks && !main) lines.push(blocksToText(blocks));
  for (const e of Array.isArray(body.embeds) ? body.embeds.slice(0, 10) : []) {
    const el = [];
    if (str(e?.title)) el.push(str(e.url) ? `${str(e.title)} (${str(e.url)})` : str(e.title));
    if (str(e?.description)) el.push(str(e.description));
    for (const f of Array.isArray(e?.fields) ? e.fields.slice(0, 20) : []) {
      if (str(f?.name) || str(f?.value)) el.push(`${str(f.name)}${str(f.name) && str(f.value) ? ': ' : ''}${str(f.value)}`);
    }
    if (el.length) lines.push(el.join('\n'));
  }
  if (str(body.url) && !lines.some((l) => l.includes(str(body.url)))) lines.push(str(body.url));
  const text = plainFromSlack(lines.filter(Boolean).join('\n\n')).trim();
  const imageUrls = payloadImageUrls(body);
  if (!text && !blocks && imageUrls.length === 0 && !allowEmpty) return { error: '보낼 글이 없습니다(text 칸을 넣으세요).' };
  const username = str(body.username);
  return {
    text: clipText(text),
    blocks,
    imageUrls,
    ...(username ? { username: clipGraphemes(username.replace(/[\u0000-\u001f\u007f]/g, ''), BOT_NAME_MAX) } : {}),
  };
}

/** 입력한 글이 슬래시 명령이면 `{ command, text }`(명령은 소문자) — `/` 하나로 시작하고 이름이 규칙에 맞아야 한다. 아니면 null. */
export function parseSlashInvocation(input) {
  const m = /^\/([a-zA-Z0-9][a-zA-Z0-9_-]{0,31})(?:\s+([\s\S]*))?$/.exec(String(input ?? '').trim());
  return m ? { command: m[1].toLowerCase(), text: (m[2] ?? '').trim() } : null;
}

/**
 * 슬래시 명령 요청에 붙일 서명 — `v1=` + HMAC-SHA256(서명 비밀, "{timestamp}.{본문}")의 16진수. 받는 쪽은 같은 계산으로 맞춰 보고,
 * 시각이 5분 넘게 차이 나면 버린다(다시 보내기 막기). 헤더: X-TangoTalk-Timestamp, X-TangoTalk-Signature.
 */
export function signCommandRequest(secret, timestamp, body) {
  return `v1=${crypto.createHmac('sha256', secret).update(`${timestamp}.${body}`).digest('hex')}`;
}

/**
 * 슬래시 명령의 답 → `{ text, inChannel }` | `{ empty: true }`(할 말 없음) | `{ error }`. JSON이면 Slack처럼 `{ text, response_type:
 * 'in_channel' | 'ephemeral' }`(기본은 ephemeral — 부른 사람에게만 보임), 그냥 글이면 부른 사람에게만. 2xx가 아니면 실패.
 */
export function parseCommandResponse({ status, contentType = '', bodyText = '' }) {
  if (status < 200 || status >= 300) return { error: `명령을 처리하는 서버가 오류를 돌려줬습니다(${status}).` };
  const raw = String(bodyText ?? '').trim();
  if (!raw) return { empty: true };
  if (String(contentType).includes('json')) {
    let json;
    try {
      json = JSON.parse(raw);
    } catch {
      return { error: '명령을 처리하는 서버의 답이 올바른 JSON이 아닙니다.' };
    }
    const parsed = webhookPayloadToMessage(json);
    if (parsed.error) return { empty: true };
    return { text: parsed.text, blocks: parsed.blocks, inChannel: json.response_type === 'in_channel' };
  }
  return { text: clipText(raw), blocks: null, inChannel: false };
}

/**
 * 단추·선택지를 누른 뒤 받은 답 → 할 일. JSON이면 Slack처럼:
 *  - `{ delete_original: true }` → `{ remove: true }`(그 봇 메시지를 지운다)
 *  - `{ replace_original: true, text?, blocks? }` → `{ replace: { text, blocks } }`(그 메시지를 바꾼다 — 단추를 "승인됨" 글로 바꾸기 등)
 *  - `{ response_type: 'in_channel', text, blocks? }` → `{ post: { text, blocks } }`(방에 새 봇 메시지)
 *  - 그 밖의 글 → `{ ephemeral: 글 }`(누른 사람에게만)
 * 그냥 글이면 누른 사람에게만, 빈 답이면 `{ empty: true }`, 2xx가 아니면 `{ error }`.
 */
export function parseInteractionResponse({ status, contentType = '', bodyText = '' }) {
  if (status < 200 || status >= 300) return { error: `단추를 처리하는 서버가 오류를 돌려줬습니다(${status}).` };
  const raw = String(bodyText ?? '').trim();
  if (!raw) return { empty: true };
  if (!String(contentType).includes('json')) return { ephemeral: clipText(raw) };
  let json;
  try {
    json = JSON.parse(raw);
  } catch {
    return { error: '단추를 처리하는 서버의 답이 올바른 JSON이 아닙니다.' };
  }
  if (!json || typeof json !== 'object' || Array.isArray(json)) return { empty: true };
  if (json.delete_original === true) return { remove: true };
  const parsed = webhookPayloadToMessage(json);
  if (parsed.error) return { empty: true };
  const content = { text: parsed.text || blocksToText(parsed.blocks), blocks: parsed.blocks };
  if (json.replace_original === true) return { replace: content };
  if (json.response_type === 'in_channel') return { post: content };
  return content.text ? { ephemeral: content.text } : { empty: true };
}

// ── 나가는 웹훅·연동 앱 ─────────────────────────────────────────────────

/**
 * 바깥으로 알리는 일의 종류 — 나가는 웹훅과 연동 앱이 고른다. 'mention'은 사람을 멘션한(@이름·@전체) 메시지·댓글. 보내는 모양은
 * publicDtos.js(공개 API와 같은 모양)와 webhookDelivery.js의 봉투.
 */
export const INTEGRATION_EVENTS = Object.freeze([
  'message.created',
  'message.updated',
  'message.deleted',
  'mention',
  'comment.created',
  'todo.created',
  'todo.updated',
  'todo.deleted',
]);
/** 시험 보내기("보내 보기")에만 쓰는 일 — 고를 수 없다. */
export const PING_EVENT = 'ping';
export const OUTGOING_PER_ROOM = 10;
export const APPS_PER_TEAM = 30;

/** 받을 일 목록 — 하나 이상, 아는 종류만, 정해진 순서로. `{ events }` | `{ error }`. */
export function parseEvents(value) {
  const list = Array.isArray(value) ? value : [];
  if (list.length === 0) return { error: '받을 일을 하나 이상 고르세요.' };
  if (list.some((e) => !INTEGRATION_EVENTS.includes(e))) return { error: `알 수 없는 일 종류입니다(${INTEGRATION_EVENTS.join(', ')}).` };
  return { events: INTEGRATION_EVENTS.filter((e) => list.includes(e)) };
}

/** 이 연동이 [event]를 받는지 — 꺼졌거나 보낼 주소가 없으면 받지 않는다. */
export function integrationWantsEvent(row, event) {
  if (!row?.enabled || !row.url) return false;
  if (row.kind !== 'outgoing' && row.kind !== 'app') return false;
  return Array.isArray(row.events) && row.events.includes(event);
}

/** 단추 누름을 보낼 주소 — 슬래시 명령은 명령 주소, 들어오는 웹훅·앱은 따로 정한 응답 주소. 없으면 null. */
export function interactionUrlOf(row) {
  if (!row) return null;
  if (row.kind === 'command') return row.url ?? null;
  if (row.kind === 'webhook' || row.kind === 'app') return row.interactionUrl ?? null;
  return null;
}

/**
 * 이 연동의 주소가 사내 주소(사설망)여도 보내는지 — 서버 운영자만 만드는 슬래시 명령·앱은 늘, 웹훅·나가는 웹훅은 서버 운영자가 주소를 정했을
 * 때만([allowPrivate]). 아니면 공인 주소로만 보낸다(outbound.js).
 */
export const mayReachPrivate = (row) => row?.kind === 'command' || row?.kind === 'app' || !!row?.allowPrivate;

/** 종류의 이름(감사 로그·안내 글). */
export const integrationKindLabel = (kind) =>
  ({ webhook: '웹훅', command: '슬래시 명령', outgoing: '나가는 웹훅', app: '연동 앱' })[kind] ?? '연동';

/** 보내기 다시 시도 간격 — 첫 시도 뒤 10초·1분·5분·30분·2시간·6시간. 그 뒤로는 실패로 끝낸다. */
export const DELIVERY_RETRY_DELAYS_MS = Object.freeze([10_000, 60_000, 300_000, 1_800_000, 7_200_000, 21_600_000]);
export const DELIVERY_MAX_ATTEMPTS = DELIVERY_RETRY_DELAYS_MS.length + 1;
/** 연달아 끝내 못 보낸 일이 이만큼이면 그 연동을 끈다(화면에서 다시 켠다). */
export const DELIVERY_AUTO_DISABLE = 10;
/** 보내기 한 번을 기다리는 시간과 읽을 답의 크기. */
export const DELIVERY_TIMEOUT_MS = 10_000;

/** [attempts]번 시도한 뒤 다음 시도 시각(ms), 더 시도하지 않으면 null. */
export function nextDeliveryAttemptAt(attempts, now = Date.now()) {
  if (attempts < 1 || attempts >= DELIVERY_MAX_ATTEMPTS) return null;
  return now + DELIVERY_RETRY_DELAYS_MS[attempts - 1];
}

/**
 * 보내는 일의 봉투 — `{ id, type, createdAt, teamId, roomId, data }`. [id]는 보내기 기록 id(받는 쪽이 같은 일을 두 번 받으면 이 값으로
 * 거른다 — 다시 보내기는 같은 id). 헤더: X-TangoTalk-Event·X-TangoTalk-Delivery·X-TangoTalk-Timestamp·X-TangoTalk-Signature.
 */
export const eventEnvelope = ({ id, type, teamId = null, roomId = null, data = {}, now = Date.now() }) => ({
  id,
  type,
  createdAt: now,
  teamId,
  roomId,
  data,
});

/** 보내기 기록의 오류 칸에 적을 짧은 글. */
export const deliveryErrorText = (err) => clipGraphemes(String(err?.message ?? err ?? '알 수 없는 오류'), 300);

/** 연동을 붙일 수 있는 방인지 — 토픽·그룹만(1:1·나와의 대화·비밀 대화는 안 됨, 보드 뷰 토픽은 글 메시지를 받지 않음). */
export function roomAcceptsIntegrations(room) {
  if (!room || room.isSecret) return false;
  if (room.type === 'topic') return room.viewMode !== 'board';
  return room.type === 'group';
}

/**
 * 이 방의 웹훅을 만들고 지울 수 있는지 — 토픽은 그 토픽을 관리할 수 있는 사람(토픽 관리자·팀 관리자), 그룹은 그 방 멤버 중 정회원
 * 이상. [access]는 access.js topicAccess의 결과.
 */
export function canManageRoomWebhooks(room, access) {
  if (!roomAcceptsIntegrations(room)) return false;
  if (room.type === 'topic') return !!access.canManage;
  return !!access.isRoomMember && access.role !== 'guest';
}

/** 공개 API(/api/v1)에 [needed] 권한이 있는지. */
export const tokenHasScope = (scopes, needed) => Array.isArray(scopes) && scopes.includes(needed);
