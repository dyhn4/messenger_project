import dns from 'node:dns/promises';
import net from 'node:net';
import { ImapFlow } from 'imapflow';
import { simpleParser } from 'mailparser';
import nodemailer from 'nodemailer';
import MailComposer from 'nodemailer/lib/mail-composer/index.js';
import { isBlockedAddress, LIST_LIMIT_MAX, MESSAGE_BYTES_MAX, parseFolderName, SEARCH_MAX } from './webmailRules.js';

/**
 * 웹메일의 메일 서버 쪽 — IMAP(imapflow)으로 폴더·목록·읽기·플래그·이동·지우기·임시 저장, SMTP(nodemailer)로 보내기. 계정마다 IMAP 연결
 * 하나를 잠깐 열어 두고(3분 동안 안 쓰면 닫음) 그 계정의 요청을 차례로 처리한다(폴더 선택이 연결 상태라 섞이지 않게). 접속 전에 주소를
 * 풀어 이 PC 자신·링크 로컬 주소면 막는다(webmailRules.js isBlockedAddress). 로그인 값([creds])은 `{ password }`(비밀번호·앱 비밀번호)
 * 또는 `{ accessToken }`(Google·Microsoft OAuth — XOAUTH2, webmailOAuth.js가 갱신해 넘긴다). 시험은 __setWebmailTestHooks로 가짜 IMAP·
 * SMTP·주소 풀이를 끼운다.
 */

const IDLE_CLOSE_MS = 3 * 60 * 1000;

let hooks = {
  imap: (options) => new ImapFlow(options),
  smtp: (options) => nodemailer.createTransport(options),
  resolve: async (host) => (net.isIP(host) ? [host] : (await dns.lookup(host, { all: true })).map((r) => r.address)),
};

/** 시험용 — 가짜 IMAP 만들기·SMTP 만들기·주소 풀이를 바꾼다(넘긴 것만). */
export function __setWebmailTestHooks(next) {
  hooks = { ...hooks, ...next };
  closeAllConnections();
}

/** 접속해도 되는 서버인지 — 주소가 하나라도 막힌 주소면 오류. */
export async function assertAllowedHost(host) {
  let addresses;
  try {
    addresses = await hooks.resolve(host);
  } catch (err) {
    const e = new Error(`메일 서버 주소를 찾지 못했습니다: ${host}`);
    e.code = err?.code ?? 'ENOTFOUND';
    throw e;
  }
  if (!addresses.length || addresses.some(isBlockedAddress)) {
    const e = new Error('이 서버 PC 자신이나 내부 전용 주소로는 메일 서버를 연결할 수 없습니다.');
    e.code = 'EBLOCKED';
    throw e;
  }
}

/** 로그인 값 → imapflow auth(비밀번호 또는 XOAUTH2 접근 토큰). */
const imapAuth = (account, creds) =>
  creds?.accessToken ? { user: account.username ?? account.email, accessToken: creds.accessToken } : { user: account.username, pass: creds?.password ?? '' };

const imapOptions = (account, creds) => ({
  host: account.imapHost,
  port: account.imapPort,
  secure: account.imapSecurity === 'ssl',
  doSTARTTLS: account.imapSecurity === 'starttls' ? true : undefined,
  auth: imapAuth(account, creds),
  logger: false,
  emitLogs: false,
  connectionTimeout: 20_000,
  greetingTimeout: 15_000,
  socketTimeout: 120_000,
  tls: { servername: net.isIP(account.imapHost) ? undefined : account.imapHost },
});

/** IMAP에 새로 붙는다(로그인까지). 실패하면 imapflow 오류를 그대로 던진다. */
export async function connectImap(account, creds) {
  await assertAllowedHost(account.imapHost);
  const client = hooks.imap(imapOptions(account, creds));
  client.on?.('error', () => {});
  await client.connect();
  return client;
}

// ── 계정마다 연결 하나 ──

/** 계정 id → { client, key, timer } */
const connections = new Map();
/** 계정 id → 그 계정의 요청 줄(Promise) */
const queues = new Map();

const connectionKey = (account) =>
  `${account.imapHost}:${account.imapPort}:${account.username}:${account.authType ?? 'password'}:${new Date(account.updatedAt ?? 0).getTime()}`;

function scheduleClose(accountId) {
  const entry = connections.get(accountId);
  if (!entry) return;
  clearTimeout(entry.timer);
  entry.timer = setTimeout(() => closeConnection(accountId), IDLE_CLOSE_MS);
  entry.timer.unref?.();
}

export function closeConnection(accountId) {
  const entry = connections.get(accountId);
  if (!entry) return;
  connections.delete(accountId);
  clearTimeout(entry.timer);
  entry.client.logout?.().catch(() => entry.client.close?.());
}

export function closeAllConnections() {
  for (const id of [...connections.keys()]) closeConnection(id);
}

async function clientFor(account, creds) {
  const key = connectionKey(account);
  const entry = connections.get(account.id);
  if (entry && entry.key === key && entry.client.usable !== false) return entry.client;
  if (entry) closeConnection(account.id);
  const client = await connectImap(account, creds);
  client.on?.('close', () => {
    if (connections.get(account.id)?.client === client) connections.delete(account.id);
  });
  connections.set(account.id, { client, key, timer: null });
  return client;
}

/**
 * [account]의 IMAP 연결로 [fn](client)을 돌린다 — 같은 계정의 요청은 차례로. 연결이 끊겨 실패하면 한 번 새로 붙어 다시 해 본다.
 * [creds]는 로그인 값이거나 그것을 돌려주는 함수(OAuth — 줄을 기다린 뒤 토큰을 받게).
 */
export function withImap(account, creds, fn) {
  const prev = queues.get(account.id) ?? Promise.resolve();
  const run = prev
    .catch(() => {})
    .then(async () => {
      const auth = typeof creds === 'function' ? await creds() : creds;
      let client = await clientFor(account, auth);
      try {
        return await fn(client);
      } catch (err) {
        if (client.usable === false || err?.code === 'NoConnection' || err?.code === 'EPIPE' || err?.code === 'ECONNRESET') {
          closeConnection(account.id);
          client = await clientFor(account, auth);
          return await fn(client);
        }
        throw err;
      } finally {
        scheduleClose(account.id);
      }
    });
  queues.set(account.id, run);
  run.finally(() => {
    if (queues.get(account.id) === run) queues.delete(account.id);
  }).catch(() => {});
  return run;
}

// ── IMAP 일 ──

export const listFolders = (client) => client.list({ statusQuery: { unseen: true, messages: true } });

/** 특수 폴더([use] '\\Sent'·'\\Trash'·'\\Drafts' 등)의 경로 — 없으면 null. */
export async function specialFolder(client, use) {
  const list = await client.list();
  return list.find((m) => m.specialUse === use)?.path ?? null;
}

/** 폴더가 있는지(규칙의 옮길 폴더 확인). */
export async function folderExists(client, path) {
  const list = await client.list();
  return list.some((m) => m.path === path && !m.flags?.has?.('\\Noselect'));
}

/** 폴더 일을 할 수 없을 때(이름이 겹침·특수 폴더·비어 있지 않음 — 화면에 그대로 알린다, webmail.js mailFailed가 400). */
export function folderError(message) {
  const e = new Error(message);
  e.code = 'FOLDER';
  return e;
}

const sameName = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
/** 맨 위 폴더인지 — "INBOX." 아래에 폴더를 두는 서버는 그 바로 아래가 맨 위다. */
const isTopLevel = (m) => !m.parent?.length || (m.parent.length === 1 && m.parent[0].toUpperCase() === 'INBOX');

/** 경로의 폴더 항목(list) — 없으면 FOLDER 오류. */
async function folderEntry(client, path) {
  const entry = (await client.list()).find((m) => m.path === path);
  if (!entry) throw folderError('폴더를 찾을 수 없습니다. 다른 곳에서 바꿨을 수 있습니다.');
  return entry;
}

/** 받은편지함·특수 폴더(보낸편지함·휴지통 등)는 이름을 바꾸거나 지울 수 없다. */
function assertEditable(entry) {
  if (entry.path.toUpperCase() === 'INBOX' || entry.specialUse) throw folderError('기본 폴더는 이름을 바꾸거나 지울 수 없습니다.');
}

/**
 * 폴더 만들기 — [parent](경로)가 있으면 그 아래, 없으면 맨 위(이름공간 앞머리는 imapflow가 붙인다). [raw] 이름은 이 서버의 폴더 구분
 * 글자까지 막아 고른다(webmailRules.js parseFolderName). 같은 자리에 같은 이름(대소문자 무시)이 있으면 FOLDER 오류. 만든 경로.
 */
export async function createFolder(client, raw, parent = null) {
  const list = await client.list();
  const parsed = parseFolderName(raw, { delimiter: list.find((m) => m.delimiter)?.delimiter ?? '/' });
  if (parsed.error) throw folderError(parsed.error);
  const { name } = parsed;
  let path = name;
  if (parent) {
    const p = list.find((m) => m.path === parent);
    if (!p) throw folderError('위 폴더를 찾을 수 없습니다.');
    path = `${p.path}${p.delimiter ?? '/'}${name}`;
    if (list.some((m) => m.parentPath === p.path && sameName(m.name, name))) throw folderError('같은 이름의 폴더가 이미 있습니다.');
  } else if (list.some((m) => isTopLevel(m) && sameName(m.name, name))) {
    throw folderError('같은 이름의 폴더가 이미 있습니다.');
  }
  const created = await client.mailboxCreate(path);
  return created?.path ?? path;
}

/** 폴더 이름 바꾸기 — 같은 위 폴더 안에서 마지막 칸 이름만 바꾼다. → `{ from, to, delimiter }`. */
export async function renameFolder(client, path, raw) {
  const list = await client.list();
  const entry = list.find((m) => m.path === path);
  if (!entry) throw folderError('폴더를 찾을 수 없습니다. 다른 곳에서 바꿨을 수 있습니다.');
  assertEditable(entry);
  const delimiter = entry.delimiter ?? '/';
  const parsed = parseFolderName(raw, { delimiter });
  if (parsed.error) throw folderError(parsed.error);
  const { name } = parsed;
  if (list.some((m) => m.path !== path && m.parentPath === entry.parentPath && sameName(m.name, name))) {
    throw folderError('같은 이름의 폴더가 이미 있습니다.');
  }
  const to = entry.parentPath ? `${entry.parentPath}${delimiter}${name}` : name;
  if (to === path) return { from: path, to, delimiter };
  const res = await client.mailboxRename(path, to);
  return { from: path, to: res?.newPath ?? to, delimiter };
}

/** 폴더 지우기 — 비어 있고 아래 폴더가 없을 때만(메일 서버는 폴더째 메일을 지운다 — 실수로 메일을 잃지 않게). */
export async function deleteFolder(client, path) {
  const entry = await folderEntry(client, path);
  assertEditable(entry);
  const delimiter = entry.delimiter ?? '/';
  if ((await client.list()).some((m) => m.path.startsWith(`${path}${delimiter}`))) throw folderError('아래 폴더가 있는 폴더는 지울 수 없습니다.');
  const status = await client.status(path, { messages: true });
  if ((status?.messages ?? 0) > 0) throw folderError('메일이 들어 있는 폴더는 지울 수 없습니다. 메일을 먼저 옮기거나 지우세요.');
  await client.mailboxDelete(path);
  return { delimiter };
}

async function withLock(client, path, fn, { readOnly = false } = {}) {
  const lock = await client.getMailboxLock(path, { readOnly });
  try {
    return await fn();
  } finally {
    lock.release();
  }
}

// References 머리는 대화로 묶기에 쓴다(봉투에는 Message-ID·In-Reply-To만 있다).
const SUMMARY_QUERY = { uid: true, envelope: true, flags: true, bodyStructure: true, size: true, internalDate: true, headers: ['references'] };

/**
 * [path] 폴더의 메일 — 새것부터 [limit]통, [before](uid)보다 앞의 것. [q]면 제목·보낸 사람·받는 사람·본문으로 찾는다(최근 100통까지).
 * `{ messages: [fetch 결과], nextBefore }`.
 */
export async function listMessages(client, path, { before = null, limit = 30, q = null } = {}) {
  const size = Math.min(Math.max(1, limit), LIST_LIMIT_MAX);
  return withLock(
    client,
    path,
    async () => {
      const found = q
        ? await client.search({ or: [{ subject: q }, { from: q }, { to: q }, { body: q }] }, { uid: true })
        : await client.search({ all: true }, { uid: true });
      let uids = (found || []).filter((u) => !before || u < before).sort((a, b) => b - a);
      if (q) uids = uids.slice(0, SEARCH_MAX);
      const page = uids.slice(0, size);
      if (page.length === 0) return { messages: [], nextBefore: null };
      const fetched = await client.fetchAll(page.join(','), SUMMARY_QUERY, { uid: true });
      return {
        messages: fetched.sort((a, b) => b.uid - a.uid),
        nextBefore: uids.length > size ? page[page.length - 1] : null,
      };
    },
    { readOnly: true },
  );
}

/**
 * 메일 하나를 받아 풀어 본다 — 없으면 null, 너무 크면 `{ tooLarge, size }`. [markSeen]이면 읽음으로. [withSource]면 원문(Buffer)도
 * (`.eml` 내려받기·대화방으로 보내기).
 */
export async function readMessage(client, path, uid, { markSeen = true, withSource = false } = {}) {
  return withLock(client, path, async () => {
    const meta = await client.fetchOne(String(uid), { uid: true, size: true, flags: true }, { uid: true });
    if (!meta) return null;
    if ((meta.size ?? 0) > MESSAGE_BYTES_MAX) return { tooLarge: true, size: meta.size };
    const full = await client.fetchOne(String(uid), { uid: true, source: true }, { uid: true });
    const parsed = await simpleParser(full.source, { skipImageLinks: true });
    if (markSeen && !meta.flags?.has('\\Seen')) await client.messageFlagsAdd(String(uid), ['\\Seen'], { uid: true });
    return { parsed, flags: meta.flags ?? new Set(), source: withSource ? full.source : undefined };
  });
}

export async function setFlags(client, path, uids, { seen, flagged }) {
  const range = uids.join(',');
  return withLock(client, path, async () => {
    for (const [flag, on] of [
      ['\\Seen', seen],
      ['\\Flagged', flagged],
    ]) {
      if (on === true) await client.messageFlagsAdd(range, [flag], { uid: true });
      if (on === false) await client.messageFlagsRemove(range, [flag], { uid: true });
    }
  });
}

/** 답장한 메일에 답장 표시. */
export const markAnswered = (client, path, uid) =>
  withLock(client, path, () => client.messageFlagsAdd(String(uid), ['\\Answered'], { uid: true }));

export const moveMessages = (client, path, uids, to) => withLock(client, path, () => client.messageMove(uids.join(','), to, { uid: true }));

/** 지우기 — 휴지통이 있고 지금 폴더가 휴지통이 아니면 휴지통으로 옮기고, 아니면 아주 지운다. `'trash'` | `'deleted'`. */
export async function deleteMessages(client, path, uids) {
  const trash = await specialFolder(client, '\\Trash');
  if (trash && trash !== path) {
    await moveMessages(client, path, uids, trash);
    return 'trash';
  }
  await withLock(client, path, () => client.messageDelete(uids.join(','), { uid: true }));
  return 'deleted';
}

/** 휴지통을 거치지 않고 아주 지운다(바꿔 쓴 임시 저장본·보낸 뒤의 임시 저장본). */
export const expungeMessages = (client, path, uids) => withLock(client, path, () => client.messageDelete(uids.join(','), { uid: true }));

/** 보낸 메일을 보낸편지함에 넣는다(Gmail은 SMTP가 알아서 넣으니 부르는 쪽이 건너뛴다). 보낸편지함이 없으면 false. */
export async function appendToSent(client, raw) {
  const sent = await specialFolder(client, '\\Sent');
  if (!sent) return false;
  await client.append(sent, raw, ['\\Seen']);
  return true;
}

/**
 * 임시 저장 — 임시보관함에 \Draft로 넣고 `{ folder, uid }`. 메일 서버가 새 uid를 알려 주지 않으면(UIDPLUS 없음) Message-ID로 찾는다.
 * 임시보관함이 없으면 오류(code 'NO_DRAFTS').
 */
export async function appendDraft(client, raw, messageId) {
  const drafts = await specialFolder(client, '\\Drafts');
  if (!drafts) {
    const e = new Error('이 메일 계정에는 임시보관함이 없습니다.');
    e.code = 'NO_DRAFTS';
    throw e;
  }
  const res = await client.append(drafts, raw, ['\\Draft', '\\Seen']);
  let uid = res?.uid ?? null;
  if (!uid && messageId) {
    uid = await withLock(
      client,
      drafts,
      async () => {
        const found = await client.search({ header: { 'message-id': messageId } }, { uid: true });
        return found?.length ? Math.max(...found) : null;
      },
      { readOnly: true },
    );
  }
  return { folder: drafts, uid };
}

/** 받은편지함 상태 `{ uidNext, uidValidity, unseen }`. */
export async function inboxStatus(client) {
  const s = await client.status('INBOX', { uidNext: true, uidValidity: true, unseen: true });
  return { uidNext: s.uidNext, uidValidity: s.uidValidity != null ? String(s.uidValidity) : null, unseen: s.unseen ?? 0 };
}

const envelopeOf = (m) => ({
  uid: m.uid,
  from: { name: m.envelope?.from?.[0]?.name ?? '', address: m.envelope?.from?.[0]?.address ?? '' },
  to: (m.envelope?.to ?? []).map((a) => ({ name: a.name ?? '', address: a.address ?? '' })),
  cc: (m.envelope?.cc ?? []).map((a) => ({ name: a.name ?? '', address: a.address ?? '' })),
  subject: m.envelope?.subject ?? '',
  seen: !!m.flags?.has('\\Seen'),
});

/**
 * 받은편지함에서 [fromUid] 이후(포함)의 메일 겉봉 — 받는 규칙을 걸고 새 메일을 알리는 데. 새것부터 [max]통.
 * `[{ uid, from, to, cc, subject, seen }]`.
 */
export async function newInboxMessages(client, fromUid, max = 200) {
  return withLock(
    client,
    'INBOX',
    async () => {
      const list = await client.fetchAll(`${fromUid}:*`, { uid: true, envelope: true, flags: true }, { uid: true });
      return list
        .filter((m) => m.uid >= fromUid)
        .sort((a, b) => b.uid - a.uid)
        .slice(0, max)
        .map(envelopeOf);
    },
    { readOnly: true },
  );
}

/** [path] 폴더의 최근 [limit]통 겉봉(받는 규칙을 지금 걸기). */
export async function recentMessages(client, path, limit) {
  return withLock(
    client,
    path,
    async () => {
      const uids = ((await client.search({ all: true }, { uid: true })) || []).sort((a, b) => b - a).slice(0, limit);
      if (uids.length === 0) return [];
      const list = await client.fetchAll(uids.join(','), { uid: true, envelope: true, flags: true }, { uid: true });
      return list.map(envelopeOf);
    },
    { readOnly: true },
  );
}

/** 받는 규칙의 할 일(webmailRules.js planRules)을 [path] 폴더에 한다 — 읽음·중요 표시 먼저, 옮기기는 나중. */
export async function applyRulePlan(client, path, plan) {
  if (plan.seen.length) await setFlags(client, path, plan.seen, { seen: true });
  if (plan.flagged.length) await setFlags(client, path, plan.flagged, { flagged: true });
  for (const [to, uids] of plan.moves) {
    if (to !== path && uids.length) await moveMessages(client, path, uids, to);
  }
}

// ── SMTP ──

const smtpOptions = (account, creds) => ({
  host: account.smtpHost,
  port: account.smtpPort,
  secure: account.smtpSecurity === 'ssl',
  requireTLS: account.smtpSecurity === 'starttls',
  auth: creds?.accessToken
    ? { type: 'OAuth2', user: account.username ?? account.email, accessToken: creds.accessToken }
    : { user: account.username, pass: creds?.password ?? '' },
  connectionTimeout: 20_000,
  greetingTimeout: 15_000,
  socketTimeout: 60_000,
});

/** SMTP 로그인까지 되는지(계정 연결 시험). */
export async function verifySmtp(account, creds) {
  await assertAllowedHost(account.smtpHost);
  const transporter = hooks.smtp(smtpOptions(account, creds));
  try {
    await transporter.verify();
  } finally {
    transporter.close?.();
  }
}

/**
 * 메일 원문 만들기 — [mail]은 nodemailer 메일 모양(from·to·cc·bcc·subject·text·attachments·inReplyTo·references·messageId). [keepBcc]면
 * 숨은 참조 머리를 남긴다(임시 저장본 — 이어 쓸 때 다시 채우게). 보내는 원문에는 남기지 않는다.
 */
export async function buildRaw(mail, { keepBcc = false } = {}) {
  const node = new MailComposer(mail).compile();
  if (keepBcc) node.keepBcc = true;
  return node.build();
}

/** [mail]의 받는 사람 전부(봉투) — 숨은 참조 포함. */
export const envelopeRecipients = (mail) =>
  [...(mail.to ?? []), ...(mail.cc ?? []), ...(mail.bcc ?? [])].map((a) => (typeof a === 'string' ? a : a.address));

/**
 * 보내기 — [mail]은 nodemailer 메일 모양. 보낸 원문(숨은 참조 머리 없음)을 돌려준다(보낸편지함에 넣을 것).
 */
export async function sendViaSmtp(account, creds, mail) {
  await assertAllowedHost(account.smtpHost);
  const raw = await buildRaw(mail);
  const transporter = hooks.smtp(smtpOptions(account, creds));
  try {
    await transporter.sendMail({ envelope: { from: account.email, to: envelopeRecipients(mail) }, raw });
  } finally {
    transporter.close?.();
  }
  return raw;
}
