import dns from 'node:dns/promises';
import net from 'node:net';
import { ImapFlow } from 'imapflow';
import { simpleParser } from 'mailparser';
import nodemailer from 'nodemailer';
import MailComposer from 'nodemailer/lib/mail-composer/index.js';
import { isBlockedAddress, LIST_LIMIT_MAX, MESSAGE_BYTES_MAX, SEARCH_MAX } from './webmailRules.js';

/**
 * 웹메일의 메일 서버 쪽 — IMAP(imapflow)으로 폴더·목록·읽기·플래그·이동·지우기, SMTP(nodemailer)로 보내기. 사람마다 IMAP 연결 하나를 잠깐
 * 열어 두고(3분 동안 안 쓰면 닫음) 그 사람의 요청을 차례로 처리한다(폴더 선택이 연결 상태라 섞이지 않게). 접속 전에 주소를 풀어 이 PC 자신·
 * 링크 로컬 주소면 막는다(webmailRules.js isBlockedAddress). 시험은 __setWebmailTestHooks로 가짜 IMAP·SMTP·주소 풀이를 끼운다.
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

const imapOptions = (account, password) => ({
  host: account.imapHost,
  port: account.imapPort,
  secure: account.imapSecurity === 'ssl',
  doSTARTTLS: account.imapSecurity === 'starttls' ? true : undefined,
  auth: { user: account.username, pass: password },
  logger: false,
  emitLogs: false,
  connectionTimeout: 20_000,
  greetingTimeout: 15_000,
  socketTimeout: 120_000,
  tls: { servername: net.isIP(account.imapHost) ? undefined : account.imapHost },
});

/** IMAP에 새로 붙는다(로그인까지). 실패하면 imapflow 오류를 그대로 던진다. */
export async function connectImap(account, password) {
  await assertAllowedHost(account.imapHost);
  const client = hooks.imap(imapOptions(account, password));
  client.on?.('error', () => {});
  await client.connect();
  return client;
}

// ── 사람마다 연결 하나 ──

/** userId → { client, key, timer } */
const connections = new Map();
/** userId → 그 사람의 요청 줄(Promise) */
const queues = new Map();

const connectionKey = (account) => `${account.imapHost}:${account.imapPort}:${account.username}:${new Date(account.updatedAt ?? 0).getTime()}`;

function scheduleClose(userId) {
  const entry = connections.get(userId);
  if (!entry) return;
  clearTimeout(entry.timer);
  entry.timer = setTimeout(() => closeConnection(userId), IDLE_CLOSE_MS);
  entry.timer.unref?.();
}

export function closeConnection(userId) {
  const entry = connections.get(userId);
  if (!entry) return;
  connections.delete(userId);
  clearTimeout(entry.timer);
  entry.client.logout?.().catch(() => entry.client.close?.());
}

export function closeAllConnections() {
  for (const userId of [...connections.keys()]) closeConnection(userId);
}

async function clientFor(account, password) {
  const key = connectionKey(account);
  const entry = connections.get(account.userId);
  if (entry && entry.key === key && entry.client.usable !== false) return entry.client;
  if (entry) closeConnection(account.userId);
  const client = await connectImap(account, password);
  client.on?.('close', () => {
    if (connections.get(account.userId)?.client === client) connections.delete(account.userId);
  });
  connections.set(account.userId, { client, key, timer: null });
  return client;
}

/**
 * [account]의 IMAP 연결로 [fn](client)을 돌린다 — 같은 사람의 요청은 차례로. 연결이 끊겨 실패하면 한 번 새로 붙어 다시 해 본다.
 */
export function withImap(account, password, fn) {
  const prev = queues.get(account.userId) ?? Promise.resolve();
  const run = prev
    .catch(() => {})
    .then(async () => {
      let client = await clientFor(account, password);
      try {
        return await fn(client);
      } catch (err) {
        if (client.usable === false || err?.code === 'NoConnection' || err?.code === 'EPIPE' || err?.code === 'ECONNRESET') {
          closeConnection(account.userId);
          client = await clientFor(account, password);
          return await fn(client);
        }
        throw err;
      } finally {
        scheduleClose(account.userId);
      }
    });
  queues.set(account.userId, run);
  run.finally(() => {
    if (queues.get(account.userId) === run) queues.delete(account.userId);
  }).catch(() => {});
  return run;
}

// ── IMAP 일 ──

export const listFolders = (client) => client.list({ statusQuery: { unseen: true, messages: true } });

/** 특수 폴더([use] '\\Sent'·'\\Trash' 등)의 경로 — 없으면 null. */
export async function specialFolder(client, use) {
  const list = await client.list();
  return list.find((m) => m.specialUse === use)?.path ?? null;
}

async function withLock(client, path, fn, { readOnly = false } = {}) {
  const lock = await client.getMailboxLock(path, { readOnly });
  try {
    return await fn();
  } finally {
    lock.release();
  }
}

const SUMMARY_QUERY = { uid: true, envelope: true, flags: true, bodyStructure: true, size: true, internalDate: true };

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

/** 메일 하나를 받아 풀어 본다 — 없으면 null, 너무 크면 `{ tooLarge, size }`. [markSeen]이면 읽음으로. */
export async function readMessage(client, path, uid, { markSeen = true } = {}) {
  return withLock(client, path, async () => {
    const meta = await client.fetchOne(String(uid), { uid: true, size: true, flags: true }, { uid: true });
    if (!meta) return null;
    if ((meta.size ?? 0) > MESSAGE_BYTES_MAX) return { tooLarge: true, size: meta.size };
    const full = await client.fetchOne(String(uid), { uid: true, source: true }, { uid: true });
    const parsed = await simpleParser(full.source, { skipImageLinks: true });
    if (markSeen && !meta.flags?.has('\\Seen')) await client.messageFlagsAdd(String(uid), ['\\Seen'], { uid: true });
    return { parsed, flags: meta.flags ?? new Set() };
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

/** 보낸 메일을 보낸편지함에 넣는다(Gmail은 SMTP가 알아서 넣으니 부르는 쪽이 건너뛴다). 보낸편지함이 없으면 false. */
export async function appendToSent(client, raw) {
  const sent = await specialFolder(client, '\\Sent');
  if (!sent) return false;
  await client.append(sent, raw, ['\\Seen']);
  return true;
}

/** 받은편지함 상태 `{ uidNext, uidValidity, unseen }`. */
export async function inboxStatus(client) {
  const s = await client.status('INBOX', { uidNext: true, uidValidity: true, unseen: true });
  return { uidNext: s.uidNext, uidValidity: s.uidValidity != null ? String(s.uidValidity) : null, unseen: s.unseen ?? 0 };
}

/** 받은편지함에서 [fromUid] 이후의 안 읽은 메일 겉봉(새것부터 [max]통). */
export async function newInboxEnvelopes(client, fromUid, max = 3) {
  return withLock(
    client,
    'INBOX',
    async () => {
      const list = await client.fetchAll(`${fromUid}:*`, { uid: true, envelope: true, flags: true }, { uid: true });
      return list
        .filter((m) => m.uid >= fromUid && !m.flags?.has('\\Seen'))
        .sort((a, b) => b.uid - a.uid)
        .slice(0, max);
    },
    { readOnly: true },
  );
}

// ── SMTP ──

const smtpOptions = (account, password) => ({
  host: account.smtpHost,
  port: account.smtpPort,
  secure: account.smtpSecurity === 'ssl',
  requireTLS: account.smtpSecurity === 'starttls',
  auth: { user: account.username, pass: password },
  connectionTimeout: 20_000,
  greetingTimeout: 15_000,
  socketTimeout: 60_000,
});

/** SMTP 로그인까지 되는지(계정 연결 시험). */
export async function verifySmtp(account, password) {
  await assertAllowedHost(account.smtpHost);
  const transporter = hooks.smtp(smtpOptions(account, password));
  try {
    await transporter.verify();
  } finally {
    transporter.close?.();
  }
}

/**
 * 보내기 — [mail]은 nodemailer 메일 모양(from·to·cc·bcc·subject·text·attachments·inReplyTo·references). 보낸 원문(숨은 참조 머리 없음)을
 * 돌려준다(보낸편지함에 넣을 것).
 */
export async function sendViaSmtp(account, password, mail) {
  await assertAllowedHost(account.smtpHost);
  const raw = await new MailComposer(mail).compile().build();
  const recipients = [...(mail.to ?? []), ...(mail.cc ?? []), ...(mail.bcc ?? [])].map((a) => (typeof a === 'string' ? a : a.address));
  const transporter = hooks.smtp(smtpOptions(account, password));
  try {
    await transporter.sendMail({ envelope: { from: account.email, to: recipients }, raw });
  } finally {
    transporter.close?.();
  }
  return raw;
}
