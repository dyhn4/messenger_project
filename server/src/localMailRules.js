import { isEmailAddress } from './mailRules.js';

/**
 * 자체 메일 서버(회사 도메인의 MX로 직접 받기)의 **순수 규칙** — 관리자 설정 검사, 받을 주소인지, 회사 메일함의 폴더, 목록 모양
 * (localMailServer.js·localMailStore.js·admin.js가 쓴다 — DB·네트워크 없이 시험한다).
 *
 * 주소는 `아이디@회사도메인`이다(아이디는 영문·숫자·. _ -, 대소문자 구분 없음 — 가입 아이디 규칙과 같음). 도메인을 여럿 넣으면 어느
 * 도메인으로 와도 같은 사람에게 가고, 보낼 때의 주소는 첫 도메인이다. `아이디+꼬리표@도메인`도 그 사람에게 간다(꼬리표는 받는 규칙에 쓸 수 있다).
 */

/** 회사 메일함의 폴더(경로 — 화면 이름은 webmailRules.js folderList가 특수 용도로 붙인다). */
export const LOCAL_FOLDERS = Object.freeze(['INBOX', 'Sent', 'Drafts', 'Junk', 'Trash', 'Archive']);
export const LOCAL_SPECIAL_USE = Object.freeze({
  INBOX: '\\Inbox',
  Sent: '\\Sent',
  Drafts: '\\Drafts',
  Junk: '\\Junk',
  Trash: '\\Trash',
  Archive: '\\Archive',
});
/** 휴지통의 메일은 이만큼 지나면 아주 지운다. */
export const LOCAL_TRASH_DAYS = 30;
export const LOCAL_DOMAINS_MAX = 10;
export const LOCAL_MESSAGE_MB_MAX = 50;
export const LOCAL_QUOTA_MB_MIN = 100;
export const LOCAL_QUOTA_MB_MAX = 100 * 1024;
/** 한 통의 받는 사람 수 상한(서버가 받는 쪽). */
export const LOCAL_RCPT_MAX = 50;
/** 한 IP가 10분 동안 보낼 수 있는 메일 수(받는 쪽 — 남용 막기). */
export const LOCAL_IP_MESSAGES_PER_10MIN = 60;

const DOMAIN_RE = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;
const LOCAL_PART_RE = /^[a-z0-9._-]{1,64}$/;

/** "a.com, b.co.kr" → 소문자 도메인 목록(같은 것은 하나). 모양이 틀린 것이 있으면 `{ error }`. */
export function parseDomains(raw) {
  const list = [...new Set(String(raw ?? '').split(/[\s,;]+/).map((d) => d.trim().toLowerCase()).filter(Boolean))];
  const bad = list.find((d) => !DOMAIN_RE.test(d));
  if (bad) return { error: `도메인 모양이 올바르지 않습니다: ${bad.slice(0, 60)}` };
  if (list.length > LOCAL_DOMAINS_MAX) return { error: `도메인은 ${LOCAL_DOMAINS_MAX}개까지입니다.` };
  return { list };
}

export const localDomainsOf = (settings) => parseDomains(settings?.localMailDomains).list ?? [];

/** 받는 포트·한 통 크기·메일함 크기(바이트) — 설정 행이 아직 없으면 기본값. */
export const localMailLimits = (settings) => ({
  port: settings?.localMailPort ?? 25,
  maxBytes: (settings?.localMailMaxMessageMb ?? 25) * 1024 * 1024,
  quotaBytes: (settings?.localMailQuotaMb ?? 2048) * 1024 * 1024,
});

/** 자체 메일 서버를 돌릴 수 있는지 — 켜져 있고 도메인이 있음. */
export const localMailReady = (settings) => !!settings?.localMailEnabled && localDomainsOf(settings).length > 0;

/**
 * 관리자 입력 `{ enabled?, domains?, port?, maxMessageMb?, quotaMb? }` → `{ fields }`(server_settings 열) | `{ error }`. 넘긴 것만.
 * 켜려면 도메인이 있어야 한다.
 */
export function parseLocalMailInput(body, current = {}) {
  const b = body ?? {};
  const fields = {};
  if (b.domains !== undefined) {
    const r = parseDomains(b.domains);
    if (r.error) return r;
    fields.localMailDomains = r.list.join(', ') || null;
  }
  if (b.port !== undefined) {
    const port = Number(b.port);
    if (!Number.isInteger(port) || port < 1 || port > 65535) return { error: '받는 포트는 1~65535 사이로 넣으세요.' };
    fields.localMailPort = port;
  }
  if (b.maxMessageMb !== undefined) {
    const n = Number(b.maxMessageMb);
    if (!Number.isInteger(n) || n < 1 || n > LOCAL_MESSAGE_MB_MAX) return { error: `한 통 크기는 1~${LOCAL_MESSAGE_MB_MAX}MB로 넣으세요.` };
    fields.localMailMaxMessageMb = n;
  }
  if (b.quotaMb !== undefined) {
    const n = Number(b.quotaMb);
    if (!Number.isInteger(n) || n < LOCAL_QUOTA_MB_MIN || n > LOCAL_QUOTA_MB_MAX) {
      return { error: `한 사람 메일함 크기는 ${LOCAL_QUOTA_MB_MIN}~${LOCAL_QUOTA_MB_MAX}MB로 넣으세요.` };
    }
    fields.localMailQuotaMb = n;
  }
  if (b.enabled !== undefined) {
    if (typeof b.enabled !== 'boolean') return { error: '켜기 값을 확인하세요.' };
    const domains = 'localMailDomains' in fields ? fields.localMailDomains : current.localMailDomains;
    if (b.enabled && !parseDomains(domains).list?.length) return { error: '받을 회사 도메인을 먼저 넣으세요.' };
    fields.localMailEnabled = b.enabled;
  }
  if (Object.keys(fields).length === 0) return { error: '바꿀 내용이 없습니다.' };
  return { fields };
}

/** 가입 아이디 → 회사 메일 주소(첫 도메인). 주소로 쓸 수 없는 아이디면 null. */
export function localAddressOf(username, settings) {
  const domain = localDomainsOf(settings)[0];
  const local = String(username ?? '').toLowerCase();
  if (!domain || !LOCAL_PART_RE.test(local) || local.startsWith('.') || local.endsWith('.')) return null;
  const address = `${local}@${domain}`;
  return isEmailAddress(address) ? address : null;
}

/**
 * 받을 주소면 그 아이디(소문자, `+꼬리표`는 뗀다) — 우리 도메인이 아니거나 모양이 틀리면 null(그 받는 사람은 거절 — 남의 메일을
 * 대신 넘겨주는 열린 중계가 되지 않게).
 */
export function localPartOf(address, domains) {
  const a = String(address ?? '').trim().toLowerCase();
  const at = a.lastIndexOf('@');
  if (at <= 0) return null;
  const domain = a.slice(at + 1);
  if (!domains.includes(domain)) return null;
  const local = a.slice(0, at).split('+')[0];
  return LOCAL_PART_RE.test(local) ? local : null;
}

/** 주소의 도메인이 우리 것인지(보낼 때 — 우리 사람에게는 바깥으로 보내지 않고 바로 넣는다). */
export const isLocalAddress = (address, domains) => localPartOf(address, domains) !== null;

/** 찾기용 글 — 제목·보낸 사람·받는 사람·본문 앞부분(소문자). */
export function searchTextOf(parsed) {
  const people = (v) => (v?.value ?? []).map((a) => `${a.name ?? ''} ${a.address ?? ''}`).join(' ');
  return [parsed.subject ?? '', people(parsed.from), people(parsed.to), people(parsed.cc), String(parsed.text ?? '').slice(0, 4000)]
    .join('\n')
    .toLowerCase();
}

/** 폴더 목록 모양(imapflow list 항목처럼 — webmailRules.js folderList에 그대로 넣는다). [counts] `{ 폴더: { unseen, total } }`. */
export function localFolderEntries(counts = {}) {
  return LOCAL_FOLDERS.map((path) => ({
    path,
    name: path,
    specialUse: path === 'INBOX' ? null : LOCAL_SPECIAL_USE[path],
    flags: new Set(),
    status: { unseen: counts[path]?.unseen ?? 0, messages: counts[path]?.total ?? 0 },
  }));
}

const addr = (a) => ({ name: a?.name ?? '', address: a?.address ?? '' });

/** 표의 한 줄 → 목록 한 줄(webmailRules.js messageSummary와 같은 모양). */
export function localSummaryOf(row) {
  const to = Array.isArray(row.toList) ? row.toList : [];
  return {
    uid: row.uid,
    subject: row.subject || '(제목 없음)',
    from: addr({ name: row.fromName, address: row.fromAddress }),
    to: to.map(addr),
    date: row.sentAt ? new Date(row.sentAt).getTime() : row.receivedAt ? new Date(row.receivedAt).getTime() : null,
    seen: !!row.seen,
    flagged: !!row.flagged,
    answered: !!row.answered,
    draft: !!row.draft,
    hasAttachments: !!row.hasAttachments,
    size: row.size ?? null,
  };
}

/** 행의 플래그 → IMAP 플래그 모양(Set — messageDetail이 읽는다). */
export function flagSetOf(row) {
  const s = new Set();
  if (row.seen) s.add('\\Seen');
  if (row.flagged) s.add('\\Flagged');
  if (row.answered) s.add('\\Answered');
  if (row.draft) s.add('\\Draft');
  return s;
}

/** 관리자 화면 안내 — 이 서버로 메일이 오게 하려면 할 일(도메인마다 MX). */
export function localMailSetupHints(settings, publicHost) {
  const domains = localDomainsOf(settings);
  const host = publicHost || '(이 서버의 바깥 주소)';
  return domains.map((d) => ({
    domain: d,
    mx: `${d}. MX 10 ${host}.`,
    note: `${d}의 DNS에 MX 레코드로 ${host}를 넣고, 공유기에서 바깥 25번 포트를 이 PC의 ${settings.localMailPort ?? 25}번으로 넘기세요.`,
  }));
}
