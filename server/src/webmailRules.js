import net from 'node:net';
import { isEmailAddress } from './mailRules.js';
import { htmlToRich } from './webmailHtml.js';

/**
 * 웹메일 규칙 — 메일 서비스 미리 정한 값, 계정 입력 검사, 연결해도 되는 주소인지, 받는 사람 목록·보낼 메일 검사, IMAP 오류 문구, 메일 목록·
 * 폴더 모양(webmail.js·webmailClient.js가 쓴다 — DB·네트워크 없이 시험한다).
 */

/** 연결 보안 — 암호화 없이 비밀번호를 보내는 연결('none')은 받지 않는다. */
export const MAIL_SECURITY = Object.freeze(['ssl', 'starttls']);
/** 연결할 수 있는 포트 — 메일 포트가 아닌 곳으로 서버가 접속하지 않게(사내망 다른 서비스를 두드리는 데 쓰이지 않게). */
export const IMAP_PORTS = Object.freeze([143, 993]);
export const SMTP_PORTS = Object.freeze([25, 465, 587, 2525]);

/**
 * 흔한 메일 서비스의 연결 값 — 앱은 이걸 고르면 주소·포트를 채운다. [hint]는 그 서비스에서 IMAP을 켜는 법(앱 비밀번호 등).
 */
export const MAIL_PRESETS = Object.freeze({
  naver: {
    label: '네이버 메일',
    imap: { host: 'imap.naver.com', port: 993, security: 'ssl' },
    smtp: { host: 'smtp.naver.com', port: 465, security: 'ssl' },
    hint: '네이버 메일 → 환경설정 → POP3/IMAP 설정에서 "IMAP/SMTP 사용"을 켜세요. 2단계 인증을 쓰면 네이버 ID → 보안설정의 "애플리케이션 비밀번호"를 넣으세요.',
  },
  gmail: {
    label: 'Gmail',
    imap: { host: 'imap.gmail.com', port: 993, security: 'ssl' },
    smtp: { host: 'smtp.gmail.com', port: 465, security: 'ssl' },
    hint: 'Google 계정 → 보안 → 2단계 인증을 켠 뒤 "앱 비밀번호"를 만들어 넣으세요(계정 비밀번호로는 로그인되지 않습니다).',
    oauth: 'google',
  },
  daum: {
    label: '다음 메일',
    imap: { host: 'imap.daum.net', port: 993, security: 'ssl' },
    smtp: { host: 'smtp.daum.net', port: 465, security: 'ssl' },
    hint: '다음 메일 → 환경설정 → IMAP/SMTP에서 사용을 켜세요. 2단계 인증이면 앱 비밀번호를 넣으세요.',
  },
  worksmobile: {
    label: '네이버웍스',
    imap: { host: 'imap.worksmobile.com', port: 993, security: 'ssl' },
    smtp: { host: 'smtp.worksmobile.com', port: 465, security: 'ssl' },
    hint: '네이버웍스 메일 → 환경설정 → IMAP/SMTP에서 사용을 켜고, 관리자가 외부 앱 접속을 막았으면 허용을 받으세요(앱 비밀번호가 필요할 수 있습니다).',
  },
  outlook: {
    label: 'Outlook·Microsoft 365',
    imap: { host: 'outlook.office365.com', port: 993, security: 'ssl' },
    smtp: { host: 'smtp.office365.com', port: 587, security: 'starttls' },
    hint: 'Microsoft 365는 관리자가 IMAP·SMTP 인증(기본 인증)을 허용해야 연결됩니다. 막혀 있으면 회사 IT 담당에게 문의하세요.',
    oauth: 'microsoft',
  },
});

export const DISPLAY_NAME_MAX = 50;
export const SUBJECT_MAX = 300;
export const BODY_MAX = 200_000;
export const RECIPIENTS_MAX = 50;
export const SEND_ATTACHMENTS_MAX = 10;
/** 보내는 첨부 합계(바이트). */
export const SEND_ATTACHMENTS_BYTES_MAX = 20 * 1024 * 1024;
/** 열어 볼 메일 크기 상한 — 이보다 크면 원래 메일 프로그램에서 보게 한다. */
export const MESSAGE_BYTES_MAX = 30 * 1024 * 1024;
export const LIST_LIMIT_MAX = 50;
export const SEARCH_MAX = 100;

const HOST_RE = /^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?)*$/;

/** 서버가 접속하면 안 되는 주소(이 PC 자신·링크 로컬·클라우드 메타데이터) — 사내 메일 서버(사설망)는 된다. */
export function isBlockedAddress(ip) {
  if (net.isIPv4(ip)) {
    const [a, b] = ip.split('.').map(Number);
    return a === 127 || a === 0 || (a === 169 && b === 254);
  }
  if (net.isIPv6(ip)) {
    const v = ip.toLowerCase();
    if (v === '::1' || v === '::') return true;
    if (v.startsWith('fe80:')) return true;
    const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(v);
    return mapped ? isBlockedAddress(mapped[1]) : false;
  }
  return true;
}

function parseEndpoint(raw, { label, ports }) {
  const host = typeof raw?.host === 'string' ? raw.host.trim().toLowerCase() : '';
  if (!host || (!HOST_RE.test(host) && !net.isIP(host))) return { error: `${label} 서버 주소가 올바르지 않습니다.` };
  const port = Number(raw?.port);
  if (!ports.includes(port)) return { error: `${label} 포트는 ${ports.join('·')} 중 하나여야 합니다.` };
  const security = raw?.security;
  if (!MAIL_SECURITY.includes(security)) return { error: `${label} 연결 보안은 SSL 또는 STARTTLS여야 합니다(암호화 없는 연결은 쓸 수 없음).` };
  return { host, port, security };
}

/**
 * 계정 입력 `{ email, displayName?, provider?, imap?: { host, port, security }, smtp?: {…}, username?, password? }` → `{ values }` | `{ error }`.
 * [provider]가 미리 정한 서비스면 그 연결 값을 쓴다(imap·smtp는 무시). 아이디를 비우면 이메일. [existing](고치기)이 있으면 비밀번호를 비워도
 * 그대로 둔다(values.password가 null).
 */
export function parseAccountInput(body, { existing = null } = {}) {
  const b = body ?? {};
  const email = typeof b.email === 'string' ? b.email.trim() : '';
  if (!isEmailAddress(email)) return { error: '이메일 주소를 확인하세요.' };
  const displayName = typeof b.displayName === 'string' ? b.displayName.trim() : '';
  if ([...displayName].length > DISPLAY_NAME_MAX) return { error: `보내는 이름은 ${DISPLAY_NAME_MAX}자 이내로 넣으세요.` };
  const provider = b.provider ?? 'custom';
  let imap;
  let smtp;
  if (provider !== 'custom') {
    const preset = MAIL_PRESETS[provider];
    if (!preset) return { error: '메일 서비스를 확인하세요.' };
    imap = preset.imap;
    smtp = preset.smtp;
  } else {
    imap = parseEndpoint(b.imap, { label: '받는 메일(IMAP)', ports: IMAP_PORTS });
    if (imap.error) return imap;
    smtp = parseEndpoint(b.smtp, { label: '보내는 메일(SMTP)', ports: SMTP_PORTS });
    if (smtp.error) return smtp;
  }
  const username = typeof b.username === 'string' && b.username.trim() ? b.username.trim() : email;
  if (username.length > 200) return { error: '아이디가 너무 깁니다.' };
  const password = typeof b.password === 'string' && b.password ? b.password : null;
  if (!password && !existing) return { error: '비밀번호(앱 비밀번호)를 넣으세요.' };
  if (password && password.length > 500) return { error: '비밀번호가 너무 깁니다.' };
  return {
    values: {
      email,
      displayName: displayName || null,
      provider,
      imapHost: imap.host,
      imapPort: imap.port,
      imapSecurity: imap.security,
      smtpHost: smtp.host,
      smtpPort: smtp.port,
      smtpSecurity: smtp.security,
      username,
      password,
    },
  };
}

/** 계정 종류의 이름 — 회사 메일함(이 서버가 받음)·OAuth 로그인·미리 정한 서비스·직접 입력. */
export function providerLabelOf(a) {
  if (a.authType === 'local') return '회사 메일함';
  const base = MAIL_PRESETS[a.provider]?.label ?? '직접 입력';
  return a.authType === 'oauth' ? `${base} (${OAUTH_LABEL[a.oauthProvider] ?? 'OAuth'} 로그인)` : base;
}

/** 계정 → 앱 모양(비밀번호·토큰은 내보내지 않는다). 회사 메일함은 연결 값이 없다(imap·smtp null). */
export const accountDto = (a) =>
  a
    ? {
        id: a.id,
        position: a.position ?? 0,
        email: a.email,
        displayName: a.displayName ?? null,
        provider: a.provider,
        providerLabel: providerLabelOf(a),
        authType: a.authType ?? 'password',
        oauthProvider: a.oauthProvider ?? null,
        imap: a.imapHost ? { host: a.imapHost, port: a.imapPort, security: a.imapSecurity } : null,
        smtp: a.smtpHost ? { host: a.smtpHost, port: a.smtpPort, security: a.smtpSecurity } : null,
        username: a.username ?? a.email,
        notify: a.notify,
        signature: a.signature ?? '',
        signatureOnNew: a.signatureOnNew ?? true,
        signatureOnReply: a.signatureOnReply ?? true,
        trustedSenders: Array.isArray(a.trustedSenders) ? a.trustedSenders : [],
        lastError: a.lastError ?? null,
        lastCheckedAt: a.lastCheckedAt ? new Date(a.lastCheckedAt).getTime() : null,
      }
    : null;

/**
 * 앱에 줄 미리 정한 서비스 목록. [oauth]는 그 서비스를 OAuth 로그인으로 연결할 수 있으면 그 제공자('google'|'microsoft' — 관리자가 켰고
 * 클라이언트 값이 있을 때, webmailOAuth.js mailOAuthProviders).
 */
export const presetList = (oauthProviders = []) =>
  Object.entries(MAIL_PRESETS).map(([key, p]) => ({
    key,
    label: p.label,
    imap: p.imap,
    smtp: p.smtp,
    hint: p.hint,
    oauth: p.oauth && oauthProviders.includes(p.oauth) ? p.oauth : null,
  }));

// ── 계정 여러 개·서명·그림 허용 ──

/** 한 사람이 연결할 수 있는 계정 수(회사 메일함 포함). */
export const ACCOUNTS_MAX = 5;
export const SIGNATURE_MAX = 2000;
export const TRUSTED_SENDERS_MAX = 200;
export const OAUTH_LABEL = Object.freeze({ google: 'Google', microsoft: 'Microsoft' });

/**
 * 계정 설정 고치기 `{ notify?, displayName?, signature?, signatureOnNew?, signatureOnReply? }` → `{ patch }` | `{ error }`(연결 시험
 * 없이 바꾸는 것들). 넘긴 것만.
 */
export function parseAccountPatch(body) {
  const b = body ?? {};
  const patch = {};
  for (const key of ['notify', 'signatureOnNew', 'signatureOnReply']) {
    if (b[key] === undefined) continue;
    if (typeof b[key] !== 'boolean') return { error: '설정 값을 확인하세요.' };
    patch[key] = b[key];
  }
  if (b.displayName !== undefined) {
    const name = typeof b.displayName === 'string' ? b.displayName.trim() : '';
    if ([...name].length > DISPLAY_NAME_MAX) return { error: `보내는 이름은 ${DISPLAY_NAME_MAX}자 이내로 넣으세요.` };
    patch.displayName = name || null;
  }
  if (b.signature !== undefined) {
    if (b.signature !== null && typeof b.signature !== 'string') return { error: '서명을 확인하세요.' };
    const sig = (b.signature ?? '').replace(/\r\n?/g, '\n').replace(/\s+$/, '');
    if ([...sig].length > SIGNATURE_MAX) return { error: `서명은 ${SIGNATURE_MAX}자 이내로 넣으세요.` };
    patch.signature = sig || null;
  }
  if (Object.keys(patch).length === 0) return { error: '바꿀 내용이 없습니다.' };
  return { patch };
}

/** 그림을 늘 보여 줄 보낸 사람 — 'a@b.com' 또는 '@b.com'(그 도메인 전부), 소문자. 모양이 틀리면 null. */
export function normalizeTrustedSender(v) {
  if (typeof v !== 'string') return null;
  const s = v.trim().toLowerCase();
  if (s.startsWith('@')) return HOST_RE.test(s.slice(1)) && s.includes('.') ? s : null;
  return isEmailAddress(s) ? s : null;
}

/** [address]가 그림을 늘 보여 줄 보낸 사람인지(주소가 같거나 '@도메인'이 맞음). */
export function isTrustedSender(list, address) {
  const a = String(address ?? '').trim().toLowerCase();
  if (!a.includes('@') || !Array.isArray(list)) return false;
  const domain = a.slice(a.lastIndexOf('@'));
  return list.some((t) => t === a || t === domain);
}

/** 계정 순서 바꾸기 — [ids]가 내 계정 [existing] id를 빠짐없이 한 번씩 담았는지. */
export function isFullOrder(ids, existing) {
  if (!Array.isArray(ids) || ids.length !== existing.length) return false;
  const set = new Set(existing);
  return new Set(ids).size === ids.length && ids.every((id) => set.has(id));
}

// ── 주소 자동 완성 ──

export const CONTACTS_SUGGEST_MAX = 8;

/** 보낸 메일의 받는 사람(받는 사람·참조·숨은 참조)을 자동 완성에 남길 모양 `[{ address(소문자), name }]` — 같은 주소는 하나, 내 주소는 뺀다. */
export function contactsToRecord(mail, myAddresses = []) {
  const mine = new Set(myAddresses.map((a) => String(a).toLowerCase()));
  const seen = new Set();
  const out = [];
  for (const a of [...(mail.to ?? []), ...(mail.cc ?? []), ...(mail.bcc ?? [])]) {
    const address = String(a.address ?? '').toLowerCase();
    if (!address || mine.has(address) || seen.has(address)) continue;
    seen.add(address);
    out.push({ address, name: a.name ? String(a.name).slice(0, 100) : null });
  }
  return out;
}

/**
 * 자동 완성 후보 — [q]가 이름이나 주소에 든 것. 같은 팀 사람(주소록 — [directory] `{ name, email }`)과 내가 보낸 바깥 주소([contacts] —
 * 자주·최근 순으로 받은 것)를 합쳐 [limit]개. 주소가 [q]로 시작하는 것을 앞에 둔다. `[{ name, address, member }]`.
 */
export function mergeSuggestions({ q, contacts = [], directory = [], limit = CONTACTS_SUGGEST_MAX }) {
  const needle = String(q ?? '').trim().toLowerCase();
  if (!needle) return [];
  const rows = [];
  const seen = new Set();
  const push = (name, address, member) => {
    const key = String(address).toLowerCase();
    if (seen.has(key)) return;
    const hay = `${String(name ?? '').toLowerCase()} ${key}`;
    if (!hay.includes(needle)) return;
    seen.add(key);
    rows.push({ name: name ?? '', address: key, member, starts: key.startsWith(needle) || String(name ?? '').toLowerCase().startsWith(needle) });
  };
  for (const d of directory) push(d.name, d.email, true);
  for (const c of contacts) push(c.name, c.address, false);
  // 앞이 맞는 것을 먼저(그 안에서는 받은 순서 — 주소록, 자주 쓴 것).
  const ordered = [...rows.filter((r) => r.starts), ...rows.filter((r) => !r.starts)];
  return ordered.slice(0, limit).map(({ name, address, member }) => ({ name, address, member }));
}

// ── 받는 규칙 ──

export const RULES_MAX = 50;
export const RULE_CONDITIONS_MAX = 5;
export const RULE_NAME_MAX = 50;
export const RULE_VALUE_MAX = 200;
export const RULE_FIELDS = Object.freeze(['from', 'to', 'subject']);
export const RULE_OPS = Object.freeze(['contains', 'not_contains', 'is']);
/** "지금 받은편지함에 적용"이 볼 최근 메일 수. */
export const RULES_APPLY_MAX = 500;

/**
 * 규칙 입력 `{ name, enabled?, match?, conditions: [{ field, op, value }], actions: { moveTo?, markSeen?, flag?, skipNotify? }, stop? }` →
 * `{ values }` | `{ error }`. 할 일이 하나는 있어야 한다. [moveTo]는 폴더 경로(있는지는 부르는 쪽이 본다).
 */
export function parseRule(body) {
  const b = body ?? {};
  const name = typeof b.name === 'string' ? b.name.trim() : '';
  if (!name) return { error: '규칙 이름을 넣으세요.' };
  if ([...name].length > RULE_NAME_MAX) return { error: `규칙 이름은 ${RULE_NAME_MAX}자 이내로 넣으세요.` };
  const match = b.match ?? 'all';
  if (match !== 'all' && match !== 'any') return { error: '조건 묶는 방법을 확인하세요.' };
  const raw = Array.isArray(b.conditions) ? b.conditions : [];
  if (raw.length === 0) return { error: '조건을 하나 이상 넣으세요.' };
  if (raw.length > RULE_CONDITIONS_MAX) return { error: `조건은 ${RULE_CONDITIONS_MAX}개까지입니다.` };
  const conditions = [];
  for (const c of raw) {
    if (!RULE_FIELDS.includes(c?.field) || !RULE_OPS.includes(c?.op)) return { error: '조건을 확인하세요.' };
    const value = typeof c.value === 'string' ? c.value.trim() : '';
    if (!value) return { error: '조건에 찾을 글을 넣으세요.' };
    if ([...value].length > RULE_VALUE_MAX) return { error: `조건의 글은 ${RULE_VALUE_MAX}자 이내로 넣으세요.` };
    conditions.push({ field: c.field, op: c.op, value });
  }
  const a = b.actions ?? {};
  const moveTo = typeof a.moveTo === 'string' && a.moveTo && a.moveTo.length <= 500 && !/[\r\n\0]/.test(a.moveTo) ? a.moveTo : null;
  const actions = { moveTo, markSeen: a.markSeen === true, flag: a.flag === true, skipNotify: a.skipNotify === true };
  if (!actions.moveTo && !actions.markSeen && !actions.flag && !actions.skipNotify) return { error: '할 일을 하나 이상 고르세요.' };
  return { values: { name, enabled: b.enabled !== false, match, conditions, actions, stop: b.stop === true } };
}

const lower = (v) => String(v ?? '').toLowerCase();
const addressText = (a) => `${lower(a?.name)} <${lower(a?.address)}>`;

/** 조건 하나 — [msg] `{ from: {name,address}, to: [...], cc: [...], subject }`. 받는 사람(to)은 참조까지 본다. */
export function conditionMatches(cond, msg) {
  const needle = lower(cond.value).trim();
  let values;
  if (cond.field === 'from') values = [msg.from].filter(Boolean);
  else if (cond.field === 'to') values = [...(msg.to ?? []), ...(msg.cc ?? [])];
  else values = [msg.subject ?? ''];
  const texts = cond.field === 'subject' ? values.map(lower) : values.map(addressText);
  if (cond.op === 'is') {
    // 주소는 주소가 같을 때, 제목은 글 전체가 같을 때.
    return cond.field === 'subject' ? texts.some((t) => t.trim() === needle) : values.some((a) => lower(a?.address) === needle);
  }
  const has = texts.some((t) => t.includes(needle));
  return cond.op === 'contains' ? has : !has;
}

/** 규칙이 이 메일에 맞는지(꺼진 규칙은 안 맞음). */
export function ruleMatches(rule, msg) {
  if (!rule.enabled || !rule.conditions?.length) return false;
  return rule.match === 'any' ? rule.conditions.some((c) => conditionMatches(c, msg)) : rule.conditions.every((c) => conditionMatches(c, msg));
}

/**
 * 규칙들을 메일들에 걸어 할 일을 모은다 — 메일마다 맞는 규칙의 할 일을 합치고(옮기기는 처음 맞은 것), [stop]이면 거기서 멈춘다.
 * → `{ moves: Map<폴더, uid[]>, seen: uid[], flagged: uid[], quiet: Set<uid>, matched: 맞은 메일 수 }`. [msgs]는 `{ uid, from, to, cc, subject }`.
 */
export function planRules(rules, msgs) {
  const moves = new Map();
  const seen = [];
  const flagged = [];
  const quiet = new Set();
  let matched = 0;
  for (const m of msgs) {
    let moveTo = null;
    let any = false;
    let markSeen = false;
    let flag = false;
    for (const r of rules) {
      if (!ruleMatches(r, m)) continue;
      any = true;
      if (!moveTo && r.actions?.moveTo) moveTo = r.actions.moveTo;
      if (r.actions?.markSeen) markSeen = true;
      if (r.actions?.flag) flag = true;
      if (r.actions?.skipNotify) quiet.add(m.uid);
      if (r.stop) break;
    }
    if (!any) continue;
    matched += 1;
    if (markSeen && !m.seen) seen.push(m.uid);
    if (flag) flagged.push(m.uid);
    if (moveTo) moves.set(moveTo, [...(moves.get(moveTo) ?? []), m.uid]);
  }
  return { moves, seen, flagged, quiet, matched };
}

/**
 * 주소 하나 — "홍길동 <a@b.com>" 또는 "a@b.com" → `{ name, address }` | null.
 */
export function parseAddress(raw) {
  if (typeof raw === 'object' && raw) {
    const address = typeof raw.address === 'string' ? raw.address.trim() : '';
    const name = typeof raw.name === 'string' ? raw.name.trim().slice(0, 100) : '';
    return isEmailAddress(address) ? { name, address } : null;
  }
  if (typeof raw !== 'string') return null;
  const s = raw.trim();
  const m = /^(.*)<([^<>]+)>$/.exec(s);
  const address = (m ? m[2] : s).trim();
  const name = m ? m[1].trim().replace(/^"|"$/g, '').slice(0, 100) : '';
  return isEmailAddress(address) ? { name, address } : null;
}

/** 받는 사람 목록(배열 또는 쉼표·세미콜론으로 이은 글) → `{ list }` | `{ error }`. 같은 주소는 하나로. */
export function parseAddressList(input, label) {
  if (input === undefined || input === null || input === '') return { list: [] };
  const parts = Array.isArray(input) ? input : typeof input === 'string' ? input.split(/[,;\n]/) : null;
  if (!parts) return { error: `${label}을(를) 확인하세요.` };
  const seen = new Set();
  const list = [];
  for (const part of parts) {
    if (typeof part === 'string' && !part.trim()) continue;
    const a = parseAddress(part);
    if (!a) return { error: `${label} 주소가 올바르지 않습니다: ${String(typeof part === 'string' ? part : part?.address ?? '').slice(0, 60)}` };
    const key = a.address.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    list.push(a);
  }
  return { list };
}

const MESSAGE_ID_RE = /^<[^<>\s]{1,300}>$/;

/**
 * 보낼 메일 `{ to, cc?, bcc?, subject, text, attachments?: [{ fileUrl, fileName, mimeType, fileSize }], draftAttachments?: [번호],
 * inReplyTo?, references? }` → `{ values }` | `{ error }`. 받는 사람은 합쳐 50명, 첨부는 올린 파일과 임시 저장본에서 이어 온 첨부
 * ([draftAttachments] — 임시 저장한 메일의 첨부 번호)를 합쳐 10개(합계 20MB — 크기는 부르는 쪽이 다시 잰다). [draft](임시 저장)면
 * 받는 사람·제목·본문이 비어도 된다.
 */
export function parseCompose(body, { draft = false } = {}) {
  const b = body ?? {};
  const lists = {};
  for (const [key, label] of [
    ['to', '받는 사람'],
    ['cc', '참조'],
    ['bcc', '숨은 참조'],
  ]) {
    const r = parseAddressList(b[key], label);
    if (r.error) return r;
    lists[key] = r.list;
  }
  const total = lists.to.length + lists.cc.length + lists.bcc.length;
  if (total === 0 && !draft) return { error: '받는 사람을 넣으세요.' };
  if (total > RECIPIENTS_MAX) return { error: `받는 사람은 모두 합쳐 ${RECIPIENTS_MAX}명까지입니다.` };
  const subject = typeof b.subject === 'string' ? b.subject.replace(/[\r\n]+/g, ' ').trim() : '';
  if ([...subject].length > SUBJECT_MAX) return { error: `제목은 ${SUBJECT_MAX}자 이내로 넣으세요.` };
  const text = typeof b.text === 'string' ? b.text : '';
  if (text.length > BODY_MAX) return { error: '본문이 너무 깁니다.' };
  if (!subject && !text.trim() && !draft) return { error: '제목이나 본문을 넣으세요.' };
  const attachments = b.attachments ?? [];
  const draftAttachments = b.draftAttachments ?? [];
  if (!Array.isArray(attachments) || !Array.isArray(draftAttachments) || attachments.length + draftAttachments.length > SEND_ATTACHMENTS_MAX) {
    return { error: `첨부는 ${SEND_ATTACHMENTS_MAX}개까지입니다.` };
  }
  for (const a of attachments) {
    if (typeof a?.fileUrl !== 'string' || !a.fileUrl) return { error: '첨부 파일을 확인할 수 없습니다.' };
  }
  if (!draftAttachments.every((i) => Number.isInteger(i) && i >= 0 && i < 1000) || new Set(draftAttachments).size !== draftAttachments.length) {
    return { error: '첨부 파일을 확인할 수 없습니다.' };
  }
  const inReplyTo = typeof b.inReplyTo === 'string' && MESSAGE_ID_RE.test(b.inReplyTo.trim()) ? b.inReplyTo.trim() : null;
  const references = (Array.isArray(b.references) ? b.references : [])
    .filter((r) => typeof r === 'string' && MESSAGE_ID_RE.test(r.trim()))
    .map((r) => r.trim())
    .slice(-20);
  return {
    values: {
      ...lists,
      subject: subject || (draft ? '' : '(제목 없음)'),
      text,
      draftAttachments,
      attachments: attachments.map((a) => ({
        fileUrl: a.fileUrl,
        fileName: typeof a.fileName === 'string' && a.fileName.trim() ? a.fileName.trim().slice(0, 200) : '첨부',
        mimeType: typeof a.mimeType === 'string' ? a.mimeType : null,
      })),
      inReplyTo,
      references,
    },
  };
}

/** 보내는 사람 머리 — "보내는 이름 <주소>"(이름이 없으면 주소만). */
export const fromHeaderOf = (account) =>
  account.displayName ? { name: account.displayName, address: account.email } : account.email;

/**
 * IMAP 연결·로그인 실패를 사람이 고칠 수 있는 말로(imapflow 오류의 authenticationFailed·code·responseText를 본다).
 */
export function describeImapError(err) {
  const raw = String(err?.responseText ?? err?.response ?? err?.message ?? '').slice(0, 200);
  const tail = raw ? ` (서버 응답: ${raw})` : '';
  if (err?.authenticationFailed || /AUTHENTICATIONFAILED|Invalid credentials|LOGIN failed|authentication failed/i.test(raw)) {
    return `로그인에 실패했습니다. 아이디와 비밀번호를 확인하세요 — Gmail·네이버 등은 계정 비밀번호가 아니라 "앱 비밀번호"를 넣어야 하고, 메일 설정에서 IMAP 사용을 켜야 합니다.${tail}`;
  }
  const code = err?.code;
  if (code === 'ENOTFOUND' || code === 'EAI_AGAIN') return `메일 서버 주소를 찾지 못했습니다. 서버 주소를 확인하세요.${tail}`;
  if (code === 'ECONNREFUSED' || code === 'ETIMEDOUT' || code === 'ECONNRESET' || code === 'NoConnection' || /timeout/i.test(raw)) {
    return `메일 서버에 연결하지 못했습니다. 주소·포트(IMAP 993은 SSL, 143은 STARTTLS)를 확인하고, 서버 PC의 방화벽이 그 포트로 나가는 연결을 막지 않는지 보세요.${tail}`;
  }
  if (/certificate|TLS|SSL/i.test(raw) || code === 'ERR_TLS_CERT_ALTNAME_INVALID') return `보안 연결(TLS)에 실패했습니다. 연결 보안 방식을 바꿔 보세요.${tail}`;
  return `메일 서버와 통신하지 못했습니다.${tail || ' (알 수 없는 이유)'}`;
}

/** 특수 폴더 순서 — 받은편지함, 보낸편지함, 임시보관함, 스팸, 휴지통, 그 밖(이름순). */
const SPECIAL_ORDER = ['\\Inbox', '\\Sent', '\\Drafts', '\\Junk', '\\Trash', '\\Archive'];
const SPECIAL_LABEL = {
  '\\Inbox': '받은편지함',
  '\\Sent': '보낸편지함',
  '\\Drafts': '임시보관함',
  '\\Junk': '스팸편지함',
  '\\Trash': '휴지통',
  '\\Archive': '보관함',
  '\\All': '전체보관함',
  '\\Flagged': '중요',
};

/** imapflow list() 항목들 → 앱 폴더 목록(고를 수 없는 폴더·Gmail의 [Gmail] 껍데기는 뺀다). */
export function folderList(entries) {
  const rows = [];
  for (const e of entries ?? []) {
    if (e.flags?.has?.('\\Noselect') || e.flags?.has?.('\\NonExistent')) continue;
    const special = e.path?.toUpperCase() === 'INBOX' ? '\\Inbox' : (e.specialUse ?? null);
    rows.push({
      path: e.path,
      name: SPECIAL_LABEL[special] ?? e.name ?? e.path,
      specialUse: special,
      unseen: e.status?.unseen ?? null,
      total: e.status?.messages ?? null,
    });
  }
  const rank = (r) => {
    const i = SPECIAL_ORDER.indexOf(r.specialUse);
    return i < 0 ? SPECIAL_ORDER.length : i;
  };
  return rows.sort((a, b) => rank(a) - rank(b) || a.path.localeCompare(b.path, 'ko'));
}

/** bodyStructure 안에 첨부가 있는지(attachment 표시이거나 이름이 있는 text·multipart가 아닌 부분). */
export function hasAttachment(node) {
  if (!node) return false;
  if (node.disposition === 'attachment') return true;
  const type = String(node.type ?? '').toLowerCase();
  if (!type.startsWith('multipart/') && !type.startsWith('text/') && (node.dispositionParameters?.filename || node.parameters?.name)) return true;
  return (node.childNodes ?? []).some(hasAttachment);
}

const addressOut = (a) => ({ name: a?.name ?? '', address: a?.address ?? '' });

/** imapflow fetch 결과 하나 → 목록 한 줄. */
export function messageSummary(m) {
  const env = m.envelope ?? {};
  const flags = m.flags ?? new Set();
  return {
    uid: m.uid,
    subject: env.subject || '(제목 없음)',
    from: addressOut(env.from?.[0]),
    to: (env.to ?? []).map(addressOut),
    date: env.date ? new Date(env.date).getTime() : m.internalDate ? new Date(m.internalDate).getTime() : null,
    seen: flags.has('\\Seen'),
    flagged: flags.has('\\Flagged'),
    answered: flags.has('\\Answered'),
    draft: flags.has('\\Draft'),
    hasAttachments: hasAttachment(m.bodyStructure),
    size: m.size ?? null,
  };
}

/**
 * mailparser 결과 → 읽기 화면 모양. 본문은 글자([text] — HTML 메일은 mailparser가 글자로 바꾼 것)와, HTML 메일이면 걸러 낸 서식([rich] —
 * webmailHtml.js htmlToRich: 스크립트·양식·추적 픽셀은 빠지고 바깥 그림은 주소만 — 앱이 "그림 보기"를 눌러야 서버를 거쳐 받는다).
 * 본문 안에 그려지는 첨부(cid 그림)는 첨부 목록에서 뺀다. [bcc]는 임시 저장본에만 있다(보낸 메일에는 실리지 않음).
 */
export function messageDetail(uid, parsed, flags = new Set()) {
  const list = (v) => (v?.value ?? []).map(addressOut);
  const refs = parsed.references ? (Array.isArray(parsed.references) ? parsed.references : [parsed.references]) : [];
  const rich = parsed.html ? htmlToRich(parsed.html, { attachments: parsed.attachments ?? [] }) : null;
  const shownInBody = new Set(rich?.cidIndexes ?? []);
  const draft = flags.has('\\Draft');
  return {
    uid,
    // 임시 저장본은 이어 쓸 때 그대로 채우므로 빈 제목을 그대로 둔다.
    subject: draft ? (parsed.subject ?? '') : parsed.subject || '(제목 없음)',
    from: addressOut(parsed.from?.value?.[0]),
    to: list(parsed.to),
    cc: list(parsed.cc),
    bcc: list(parsed.bcc),
    replyTo: list(parsed.replyTo),
    date: parsed.date ? parsed.date.getTime() : null,
    text: (parsed.text ?? '').slice(0, BODY_MAX),
    truncated: (parsed.text ?? '').length > BODY_MAX,
    html: !!parsed.html,
    rich: rich ? { doc: rich.doc, remoteImages: rich.remoteImages, truncated: rich.truncated } : null,
    messageId: parsed.messageId ?? null,
    inReplyTo: typeof parsed.inReplyTo === 'string' ? parsed.inReplyTo : null,
    references: refs,
    attachments: (parsed.attachments ?? [])
      .map((a, index) => ({
        index,
        fileName: a.filename || `첨부${index + 1}`,
        contentType: a.contentType,
        size: a.size ?? a.content?.length ?? 0,
        hidden: (a.contentDisposition === 'inline' && !a.filename) || shownInBody.has(index),
      }))
      .filter((a) => !a.hidden)
      .map(({ hidden, ...a }) => a),
    seen: true,
    flagged: flags.has('\\Flagged'),
    draft,
  };
}

/** 새 메일 알림 — 지난번 UIDNEXT·UIDVALIDITY와 지금 값을 견줘 몇 통 늘었는지(처음 보거나 UIDVALIDITY가 바뀌면 0 — 기준만 새로 잡음). */
export function newMailCount({ lastUidNext, lastUidValidity }, { uidNext, uidValidity }) {
  if (lastUidNext == null || lastUidValidity == null || String(uidValidity) !== String(lastUidValidity)) return 0;
  return Math.max(0, Number(uidNext) - Number(lastUidNext));
}
