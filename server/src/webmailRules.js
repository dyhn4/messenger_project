import net from 'node:net';
import { isEmailAddress } from './mailRules.js';

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

/** 계정 → 앱 모양(비밀번호는 내보내지 않는다). */
export const accountDto = (a) =>
  a
    ? {
        email: a.email,
        displayName: a.displayName ?? null,
        provider: a.provider,
        providerLabel: MAIL_PRESETS[a.provider]?.label ?? '직접 입력',
        imap: { host: a.imapHost, port: a.imapPort, security: a.imapSecurity },
        smtp: { host: a.smtpHost, port: a.smtpPort, security: a.smtpSecurity },
        username: a.username,
        notify: a.notify,
        lastError: a.lastError ?? null,
        lastCheckedAt: a.lastCheckedAt ? new Date(a.lastCheckedAt).getTime() : null,
      }
    : null;

/** 앱에 줄 미리 정한 서비스 목록. */
export const presetList = () =>
  Object.entries(MAIL_PRESETS).map(([key, p]) => ({ key, label: p.label, imap: p.imap, smtp: p.smtp, hint: p.hint }));

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
 * 보낼 메일 `{ to, cc?, bcc?, subject, text, attachments?: [{ fileUrl, fileName, mimeType, fileSize }], inReplyTo?, references? }` →
 * `{ values }` | `{ error }`. 받는 사람은 합쳐 50명, 첨부는 10개(합계 20MB — 파일 크기는 부르는 쪽이 디스크에서 다시 잰다).
 */
export function parseCompose(body) {
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
  if (total === 0) return { error: '받는 사람을 넣으세요.' };
  if (total > RECIPIENTS_MAX) return { error: `받는 사람은 모두 합쳐 ${RECIPIENTS_MAX}명까지입니다.` };
  const subject = typeof b.subject === 'string' ? b.subject.replace(/[\r\n]+/g, ' ').trim() : '';
  if ([...subject].length > SUBJECT_MAX) return { error: `제목은 ${SUBJECT_MAX}자 이내로 넣으세요.` };
  const text = typeof b.text === 'string' ? b.text : '';
  if (text.length > BODY_MAX) return { error: '본문이 너무 깁니다.' };
  if (!subject && !text.trim()) return { error: '제목이나 본문을 넣으세요.' };
  const attachments = b.attachments ?? [];
  if (!Array.isArray(attachments) || attachments.length > SEND_ATTACHMENTS_MAX) return { error: `첨부는 ${SEND_ATTACHMENTS_MAX}개까지입니다.` };
  for (const a of attachments) {
    if (typeof a?.fileUrl !== 'string' || !a.fileUrl) return { error: '첨부 파일을 확인할 수 없습니다.' };
  }
  const inReplyTo = typeof b.inReplyTo === 'string' && MESSAGE_ID_RE.test(b.inReplyTo.trim()) ? b.inReplyTo.trim() : null;
  const references = (Array.isArray(b.references) ? b.references : [])
    .filter((r) => typeof r === 'string' && MESSAGE_ID_RE.test(r.trim()))
    .map((r) => r.trim())
    .slice(-20);
  return {
    values: {
      ...lists,
      subject: subject || '(제목 없음)',
      text,
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
    hasAttachments: hasAttachment(m.bodyStructure),
    size: m.size ?? null,
  };
}

/** mailparser 결과 → 읽기 화면 모양(본문은 글자 — HTML 메일은 mailparser가 글자로 바꾼 것. 스크립트·원격 그림은 실리지 않는다). */
export function messageDetail(uid, parsed, flags = new Set()) {
  const list = (v) => (v?.value ?? []).map(addressOut);
  const refs = parsed.references ? (Array.isArray(parsed.references) ? parsed.references : [parsed.references]) : [];
  return {
    uid,
    subject: parsed.subject || '(제목 없음)',
    from: addressOut(parsed.from?.value?.[0]),
    to: list(parsed.to),
    cc: list(parsed.cc),
    replyTo: list(parsed.replyTo),
    date: parsed.date ? parsed.date.getTime() : null,
    text: (parsed.text ?? '').slice(0, BODY_MAX),
    truncated: (parsed.text ?? '').length > BODY_MAX,
    html: !!parsed.html,
    messageId: parsed.messageId ?? null,
    references: refs,
    attachments: (parsed.attachments ?? [])
      .map((a, index) => ({ index, fileName: a.filename || `첨부${index + 1}`, contentType: a.contentType, size: a.size ?? a.content?.length ?? 0, inline: a.contentDisposition === 'inline' && !a.filename }))
      .filter((a) => !a.inline),
    seen: true,
    flagged: flags.has('\\Flagged'),
  };
}

/** 새 메일 알림 — 지난번 UIDNEXT·UIDVALIDITY와 지금 값을 견줘 몇 통 늘었는지(처음 보거나 UIDVALIDITY가 바뀌면 0 — 기준만 새로 잡음). */
export function newMailCount({ lastUidNext, lastUidValidity }, { uidNext, uidValidity }) {
  if (lastUidNext == null || lastUidValidity == null || String(uidValidity) !== String(lastUidValidity)) return 0;
  return Math.max(0, Number(uidNext) - Number(lastUidNext));
}
