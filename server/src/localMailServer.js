import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { simpleParser } from 'mailparser';
import { SMTPServer } from 'smtp-server';
import { RateLimiter } from './authGuard.js';
import { certsDir } from './certs.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { listUsersByUsernameIgnoringCase } from './db/queries/users.js';
import { findLocalMailAccount, insertMailAccount, updateMailAccount } from './db/queries/webmail.js';
import { localQuotaUsed } from './db/queries/localMail.js';
import { authRecordOf, checkInboundMail } from './localMailAuth.js';
import {
  LOCAL_IP_MESSAGES_PER_10MIN,
  LOCAL_RCPT_MAX,
  localAddressOf,
  localDomainsOf,
  localMailLimits,
  localMailReady,
  localPartOf,
} from './localMailRules.js';
import { LocalQuotaError, localUnseen, purgeLocalTrash, storeLocalMessage } from './localMailStore.js';
import { mailBackend } from './webmailBackend.js';
import { applyRulesToNew, mailsToNotify, notifyNewMail } from './webmailNotify.js';

/**
 * 자체 메일 서버 — 회사 도메인의 MX를 이 서버로 두면 그 도메인으로 오는 메일을 SMTP(smtp-server)로 받아 사람마다 회사 메일함에 넣는다
 * (localMailStore.js). 관리자 콘솔 "메일" 탭에서 켜고 도메인·포트를 정한다(server_settings.localMail*). 받는 주소는 `아이디@도메인`
 * (localMailRules.js) — 우리 도메인이 아니거나 그런 사람이 없으면 받는 사람 단계에서 거절한다(남의 메일을 넘겨주는 열린 중계가 아니다).
 * 로그인(AUTH)은 받지 않고, 보내는 쪽 TLS(STARTTLS)는 이 서버의 인증서(certs/)로 받는다. 한 통 크기·메일함 크기·한 IP의 10분당 메일
 * 수에 상한이 있다. 스팸 거르기(관리자가 끌 수 있음 — 기본 켬)는 보낸 쪽 확인(SPF·DKIM·DMARC — localMailAuth.js)으로 한다: 보낸
 * 도메인이 거절하라고 한 위조 메일은 받지 않고, 확인에 실패한 메일·우리 도메인을 사칭한 메일은 스팸편지함에 넣는다(받는 규칙·알림 없음).
 *
 * 받는 즉시 받는 규칙을 걸고, 알림을 켠 사람에게 소켓·푸시로 알린다. 회사 메일함에서 우리 도메인 사람에게 보낸 메일도 바깥을 거치지 않고
 * 여기(deliverLocal)로 바로 넣는다.
 */

const ipLimiter = new RateLimiter({ max: LOCAL_IP_MESSAGES_PER_10MIN, windowMs: 10 * 60 * 1000 });
setInterval(() => ipLimiter.prune(), 10 * 60 * 1000).unref();

/** 지금 상태(관리자 콘솔). */
let state = { listening: false, port: null, error: null, startedAt: null, received: 0, rejected: 0, junked: 0 };
let running = null; // { server, key }
/** 소켓 서버(알림) — startLocalMailServer가 넣는다(관리자가 설정을 바꿔 다시 열 때도 같은 것). */
let ioRef = null;

export const localMailStatus = () => ({ ...state });

const smtpError = (code, message) => {
  const e = new Error(message);
  e.responseCode = code;
  return e;
};

/** 받는 사람 아이디 → 쓸 수 있는 계정(탈퇴·정지 아님). 대소문자만 다른 옛 아이디가 여럿이면 글자까지 같은 것. */
export async function findLocalUser(localPart) {
  const rows = (await listUsersByUsernameIgnoringCase(localPart)).filter((u) => !u.deletedAt && !u.suspendedAt);
  return rows.find((u) => u.username === localPart) ?? rows.find((u) => u.username.toLowerCase() === localPart) ?? null;
}

/**
 * 이 사람의 회사 메일함 계정 — 없으면 만든다(주소는 첫 도메인의 `아이디@도메인`). 도메인이 바뀌었으면 주소도 맞춘다. 주소로 쓸 수 없는
 * 아이디면 null. 계정 수 상한(5개)은 보지 않는다(회사가 주는 메일함이라).
 */
export async function ensureLocalAccount(user, settings) {
  const address = localAddressOf(user.username, settings);
  if (!address) return null;
  const existing = await findLocalMailAccount(user.id);
  if (existing) {
    if (existing.email !== address) return (await updateMailAccount(existing.id, { email: address, updatedAt: new Date() })) ?? existing;
    return existing;
  }
  return insertMailAccount(user.id, {
    email: address,
    displayName: user.name ?? null,
    provider: 'local',
    authType: 'local',
    notify: true,
  });
}

/** 새로 들어온 메일의 겉봉(받는 규칙·알림). */
const envelopeOfParsed = (uid, p) => {
  const list = (v) => (v?.value ?? []).map((a) => ({ name: a.name ?? '', address: a.address ?? '' }));
  return { uid, from: list(p.from)[0] ?? { name: '', address: '' }, to: list(p.to), cc: list(p.cc), subject: p.subject ?? '', seen: false };
};

/**
 * 우리 도메인 받는 사람들([recipients] — 주소)의 받은편지함에 [raw]를 넣는다. 받는 규칙을 걸고 알린다. 받는 사람이 겹치면 한 번만.
 * [folder]가 'Junk'(스팸 거르기가 걸렀음)면 스팸편지함에 넣고 규칙·알림은 하지 않는다. [auth]는 보낸 쪽 확인 결과(표에 남김).
 * → `{ delivered: [userId], failed: [{ address, error }] }`.
 */
export async function deliverLocal(io, raw, recipients, { settings = null, parsed = null, folder = 'INBOX', auth = null } = {}) {
  const s = settings ?? (await getServerSettings());
  const domains = localDomainsOf(s);
  const { quotaBytes } = localMailLimits(s);
  const targets = new Map();
  const failed = [];
  for (const address of recipients) {
    const local = localPartOf(address, domains);
    const user = local ? await findLocalUser(local) : null;
    if (!user) {
      failed.push({ address, error: '받는 사람을 찾을 수 없습니다.' });
      continue;
    }
    targets.set(user.id, user);
  }
  const p = parsed ?? (await simpleParser(raw, { skipImageLinks: true }));
  const delivered = [];
  for (const user of targets.values()) {
    const account = await ensureLocalAccount(user, s);
    if (!account) {
      failed.push({ address: user.username, error: '이 아이디로는 회사 메일 주소를 만들 수 없습니다.' });
      continue;
    }
    try {
      const { uid } = await storeLocalMessage(account.id, raw, { folder, quotaBytes, parsed: p, auth });
      delivered.push(user.id);
      if (folder !== 'INBOX') {
        io?.to(`user:${account.userId}`).emit('mail:changed', { accountId: account.id });
        continue;
      }
      const envelopes = [envelopeOfParsed(uid, p)];
      const plan = await applyRulesToNew(account, mailBackend(account), envelopes).catch((err) => {
        console.error('[local-mail] 받는 규칙 실패:', err?.message ?? err);
        return { moves: new Map(), seen: [], flagged: [], quiet: new Set(), matched: 0 };
      });
      const unseen = await localUnseen(account.id);
      if (account.notify) notifyNewMail(io, account, mailsToNotify(envelopes, plan), unseen);
      io?.to(`user:${account.userId}`).emit('mail:changed', { accountId: account.id, unseen });
    } catch (err) {
      failed.push({ address: account.email, error: err instanceof LocalQuotaError ? err.message : '메일함에 넣지 못했습니다.' });
      if (!(err instanceof LocalQuotaError)) console.error('[local-mail] 넣기 실패:', err?.message ?? err);
    }
  }
  return { delivered, failed };
}

/** STARTTLS에 쓸 인증서(certs/의 key.pem·cert.pem — 서버가 처음 켜질 때 만든다). 없으면 null(STARTTLS 숨김). */
function tlsCredentials() {
  try {
    return { key: fs.readFileSync(path.join(certsDir, 'key.pem')), cert: fs.readFileSync(path.join(certsDir, 'cert.pem')) };
  } catch {
    return null;
  }
}

/** 받은 메일 앞에 붙이는 Received 머리(어디서 왔는지 — 받은 쪽의 기록). */
function receivedHeader(session, name) {
  const from = String(session.clientHostname ?? session.hostNameAppearsAs ?? 'unknown').replace(/[\r\n]/g, '').slice(0, 200);
  const ip = String(session.remoteAddress ?? '').replace(/[\r\n]/g, '');
  return `Received: from ${from} ([${ip}]) by ${name} with ${session.transmissionType ?? 'ESMTP'}; ${new Date().toUTCString()}\r\n`;
}

function createServer(io, s) {
  const domains = localDomainsOf(s);
  const name = domains[0] ?? os.hostname();
  const { maxBytes, quotaBytes } = localMailLimits(s);
  const tls = tlsCredentials();
  return new SMTPServer({
    name,
    banner: 'TangoTalk mail',
    authOptional: true,
    disabledCommands: ['AUTH'],
    ...(tls ? { key: tls.key, cert: tls.cert } : { hideSTARTTLS: true }),
    size: maxBytes,
    // 한 통씩 메모리에 모아 넣으므로 동시에 받는 수를 줄여 둔다(20 × 한 통 상한).
    maxClients: 20,
    socketTimeout: 60_000,
    closeTimeout: 30_000,
    logger: false,
    onConnect(session, callback) {
      // 이 IP가 10분 동안 보낸 메일이 이미 많으면 붙자마자 끊는다(세는 것은 메일을 받을 때).
      const entry = ipLimiter.entries.get(session.remoteAddress);
      if (entry && entry.count >= LOCAL_IP_MESSAGES_PER_10MIN && entry.resetAt > Date.now()) {
        return callback(smtpError(421, '4.7.0 Too many messages, try again later'));
      }
      callback();
    },
    onMailFrom(address, session, callback) {
      const declared = Number(address?.args?.SIZE);
      if (Number.isFinite(declared) && declared > maxBytes) return callback(smtpError(552, '5.3.4 Message too big'));
      callback();
    },
    async onRcptTo(address, session, callback) {
      try {
        if (session.envelope.rcptTo.length >= LOCAL_RCPT_MAX) return callback(smtpError(452, '4.5.3 Too many recipients'));
        const local = localPartOf(address.address, domains);
        if (!local) return callback(smtpError(550, '5.7.1 Relaying denied'));
        const user = await findLocalUser(local);
        if (!user) return callback(smtpError(550, '5.1.1 No such user'));
        const account = await findLocalMailAccount(user.id);
        if (account && (await localQuotaUsed(account.id)) >= quotaBytes) return callback(smtpError(452, '4.2.2 Mailbox full'));
        callback();
      } catch (err) {
        console.error('[local-mail] 받는 사람 확인 실패:', err?.message ?? err);
        callback(smtpError(451, '4.3.0 Temporary failure'));
      }
    },
    onData(stream, session, callback) {
      const chunks = [Buffer.from(receivedHeader(session, name))];
      let received = 0;
      stream.on('data', (c) => {
        // 상한을 넘으면 더 모으지 않는다(끝에서 552 — smtp-server는 넘어도 나머지를 계속 흘려보낸다).
        received += c.length;
        if (received <= maxBytes) chunks.push(c);
      });
      stream.on('error', (err) => callback(err));
      stream.on('end', async () => {
        if (stream.sizeExceeded || received > maxBytes) {
          state.rejected += 1;
          return callback(smtpError(552, '5.3.4 Message too big'));
        }
        if (ipLimiter.hit(session.remoteAddress)) {
          state.rejected += 1;
          return callback(smtpError(421, '4.7.0 Too many messages, try again later'));
        }
        try {
          let raw = Buffer.concat(chunks);
          let folder = 'INBOX';
          let auth = null;
          if (s.localMailSpamFilter !== false) {
            const checked = await checkInboundMail(raw, {
              ip: session.remoteAddress,
              helo: session.hostNameAppearsAs,
              mailFrom: session.envelope.mailFrom?.address,
              mta: name,
              localDomains: domains,
            });
            if (checked.verdict === 'reject') {
              state.rejected += 1;
              return callback(smtpError(550, '5.7.1 Message rejected by the sender domain DMARC policy'));
            }
            if (checked.verdict === 'junk') folder = 'Junk';
            auth = authRecordOf(checked);
            // 확인 결과 머리(Authentication-Results·Received-SPF)는 Received 아래, 원래 머리 위에.
            if (checked.headers) raw = Buffer.concat([chunks[0], Buffer.from(checked.headers), ...chunks.slice(1)]);
          }
          const result = await deliverLocal(io, raw, session.envelope.rcptTo.map((r) => r.address), { settings: s, folder, auth });
          if (result.delivered.length === 0) {
            state.rejected += 1;
            return callback(smtpError(450, '4.2.0 Mailbox unavailable'));
          }
          state.received += 1;
          if (folder === 'Junk') state.junked += 1;
          callback(null, 'Message accepted');
        } catch (err) {
          console.error('[local-mail] 받기 실패:', err?.message ?? err);
          callback(smtpError(451, '4.3.0 Temporary failure'));
        }
      });
    },
  });
}

const keyOf = (s) => {
  if (!localMailReady(s)) return null;
  const l = localMailLimits(s);
  return `${l.port}:${l.maxBytes}:${l.quotaBytes}:${localDomainsOf(s).join(',')}`;
};

function stop() {
  if (!running) return;
  const { server } = running;
  running = null;
  server.close(() => {});
  state = { ...state, listening: false, port: null };
}

/**
 * 설정대로 켜고 끈다(서버가 켜질 때·관리자가 바꿨을 때). 포트를 열지 못하면(이미 쓰는 중·권한) 상태에 이유를 남긴다. 던지지 않는다.
 */
export async function applyLocalMailSettings(io = ioRef, { host = undefined } = {}) {
  ioRef = io;
  let s;
  try {
    s = await getServerSettings();
  } catch (err) {
    console.error('[local-mail] 설정을 읽지 못했습니다:', err?.message ?? err);
    return localMailStatus();
  }
  const key = keyOf(s);
  if (running?.key === key && state.listening) return localMailStatus();
  stop();
  if (!key) {
    state = { ...state, error: null };
    return localMailStatus();
  }
  const server = createServer(io, s);
  running = { server, key };
  await new Promise((resolve) => {
    const onError = (err) => {
      const why =
        err?.code === 'EADDRINUSE'
          ? `${localMailLimits(s).port}번 포트를 이미 다른 프로그램이 쓰고 있습니다.`
          : err?.code === 'EACCES'
            ? `${localMailLimits(s).port}번 포트를 열 권한이 없습니다.`
            : `받는 포트를 열지 못했습니다(${err?.code ?? err?.message ?? '알 수 없음'}).`;
      console.error(`[local-mail] ${why}`);
      if (running?.server === server) running = null;
      state = { ...state, listening: false, port: null, error: why };
      resolve();
    };
    server.on('error', (err) => {
      if (!state.listening) return onError(err);
      console.error('[local-mail] 오류:', err?.code ?? '', err?.message ?? err);
    });
    server.listen(localMailLimits(s).port, host, () => {
      state = { ...state, listening: true, port: server.server.address()?.port ?? localMailLimits(s).port, error: null, startedAt: Date.now() };
      console.log(`[local-mail] ${localDomainsOf(s).join(', ')} 메일을 ${state.port}번 포트로 받습니다.`);
      resolve();
    });
  });
  return localMailStatus();
}

/** 서버가 켜질 때 — 설정대로 열고, 휴지통 비우기를 6시간마다. */
export function startLocalMailServer(io) {
  applyLocalMailSettings(io).catch(() => {});
  setInterval(
    () => purgeLocalTrash().catch((err) => console.error('[local-mail] 휴지통 비우기 실패:', err?.message ?? err)),
    6 * 60 * 60 * 1000,
  ).unref();
}

/** 시험용 — 닫기. */
export function __stopLocalMailServer() {
  stop();
}
