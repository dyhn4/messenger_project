import fs from 'node:fs/promises';
import path from 'node:path';
import { Router } from 'express';
import { RateLimiter, tooMany } from './authGuard.js';
import { decryptField, encryptField } from './crypto.js';
import {
  deleteMailAccount,
  findMailAccount,
  listMailDirectory,
  listNotifyMailAccounts,
  updateMailAccount,
  upsertMailAccount,
} from './db/queries/webmail.js';
import { checkFileRefs } from './fileRefs.js';
import { describeSmtpError } from './mailRules.js';
import { notifyMailPush } from './push.js';
import { uploadFileNameOf, uploadsDir } from './upload.js';
import {
  appendToSent,
  closeConnection,
  connectImap,
  deleteMessages,
  inboxStatus,
  listFolders,
  listMessages,
  markAnswered,
  moveMessages,
  newInboxEnvelopes,
  readMessage,
  sendViaSmtp,
  setFlags,
  verifySmtp,
  withImap,
} from './webmailClient.js';
import {
  accountDto,
  describeImapError,
  folderList,
  fromHeaderOf,
  messageDetail,
  messageSummary,
  newMailCount,
  parseAccountInput,
  parseCompose,
  presetList,
  SEND_ATTACHMENTS_BYTES_MAX,
} from './webmailRules.js';

/**
 * 웹메일 — 사람마다 연결한 메일 계정(IMAP/SMTP)을 앱에서 읽고 보낸다. 메일은 원래 메일 서버에 있고 서버는 중계만 한다(본문을 DB에 두지
 * 않음). 계정 비밀번호는 암호화해 두고 내보내지 않는다. 새 메일은 3분마다 받은편지함을 확인해 소켓 `mail:new`와 푸시로 알린다
 * (startMailCheckJob). 연결 규칙·모양은 webmailRules.js, 메일 서버와의 일은 webmailClient.js.
 */

const NO_ACCOUNT = { error: '연결된 메일 계정이 없습니다. 메일 → 계정 연결에서 먼저 연결하세요.', code: 'NO_ACCOUNT' };
const FOLDER_MAX = 500;
const UIDS_MAX = 200;

const connectLimiter = new RateLimiter({ max: 10, windowMs: 10 * 60 * 1000 });
const sendLimiter = new RateLimiter({ max: 30, windowMs: 10 * 60 * 1000 });
setInterval(() => {
  connectLimiter.prune();
  sendLimiter.prune();
}, 10 * 60 * 1000).unref();

/** Gmail은 SMTP로 보낸 메일을 보낸편지함에 알아서 넣는다 — 또 넣으면 두 번 보인다. */
const autoSavesSent = (account) => /(^|\.)gmail\.com$|(^|\.)googlemail\.com$/i.test(account.smtpHost);

const folderOf = (v) => (typeof v === 'string' && v && v.length <= FOLDER_MAX && !/[\r\n\0]/.test(v) ? v : null);
const uidOf = (v) => {
  const n = Number(v);
  return Number.isSafeInteger(n) && n > 0 ? n : null;
};
const uidsOf = (v) => {
  const list = (Array.isArray(v) ? v : [v]).map(uidOf);
  return list.length && list.length <= UIDS_MAX && list.every(Boolean) ? [...new Set(list)] : null;
};

export function createWebmailRouter(io) {
  const router = Router();

  /** 계정과 비밀번호 — 없으면 404로 응답하고 null. */
  async function loadAccount(req, res) {
    const account = await findMailAccount(req.user.sub);
    if (!account) {
      res.status(404).json(NO_ACCOUNT);
      return null;
    }
    return { account, password: decryptField(account.passwordEnc) };
  }

  /** 메일 서버 오류 → 502(로그인 실패면 계정에 남겨 화면이 알 수 있게). */
  async function imapFailed(res, account, err) {
    const message = describeImapError(err);
    if (err?.authenticationFailed) {
      await updateMailAccount(account.userId, { lastError: message, lastErrorAt: new Date() }).catch(() => {});
    }
    if (err?.code !== 'EBLOCKED') console.error('[webmail] IMAP 실패:', err?.code ?? '', err?.message ?? err);
    return res.status(502).json({ error: err?.code === 'EBLOCKED' ? err.message : message });
  }

  /** [fn](client)을 그 사람의 IMAP 연결로 — 실패하면 502. */
  const imap = (handler) => async (req, res) => {
    const loaded = await loadAccount(req, res);
    if (!loaded) return;
    try {
      await handler(req, res, loaded, (fn) => withImap(loaded.account, loaded.password, fn));
    } catch (err) {
      if (!res.headersSent) await imapFailed(res, loaded.account, err);
    }
  };

  // ── 계정 ──

  router.get('/mail/presets', (req, res) => res.json(presetList()));

  router.get('/mail/account', async (req, res) => {
    res.json({ account: accountDto(await findMailAccount(req.user.sub)) });
  });

  /**
   * 연결하기·바꾸기 — 저장하기 전에 IMAP 로그인과 SMTP 로그인을 해 본다(실패하면 400, 어느 쪽이 왜 안 되는지). 비밀번호를 비우면(바꾸기)
   * 지금 비밀번호로 시험한다.
   */
  router.put('/mail/account', async (req, res) => {
    const wait = connectLimiter.hit(req.user.sub);
    if (wait) return tooMany(res, wait, '메일 계정 연결');
    const existing = await findMailAccount(req.user.sub);
    const parsed = parseAccountInput(req.body, { existing });
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const { password: newPassword, ...values } = parsed.values;
    const password = newPassword ?? decryptField(existing.passwordEnc);
    const probe = { ...values, userId: req.user.sub };
    try {
      const client = await connectImap(probe, password);
      await client.logout().catch(() => {});
    } catch (err) {
      return res.status(400).json({ error: `받는 메일(IMAP) — ${err?.code === 'EBLOCKED' ? err.message : describeImapError(err)}` });
    }
    try {
      await verifySmtp(probe, password);
    } catch (err) {
      return res.status(400).json({ error: `보내는 메일(SMTP) — ${err?.code === 'EBLOCKED' ? err.message : describeSmtpError(err)}` });
    }
    closeConnection(req.user.sub);
    const row = await upsertMailAccount(req.user.sub, { ...values, passwordEnc: encryptField(password) });
    io.to(`user:${req.user.sub}`).emit('mail:changed', { account: true });
    res.json({ account: accountDto(row) });
  });

  /** 알림 켜고 끄기·보내는 이름(연결 시험 없이). */
  router.patch('/mail/account', async (req, res) => {
    const patch = {};
    if (req.body?.notify !== undefined) {
      if (typeof req.body.notify !== 'boolean') return res.status(400).json({ error: '알림 값을 확인하세요.' });
      patch.notify = req.body.notify;
    }
    if (req.body?.displayName !== undefined) {
      const name = typeof req.body.displayName === 'string' ? req.body.displayName.trim() : '';
      if ([...name].length > 50) return res.status(400).json({ error: '보내는 이름은 50자 이내로 넣으세요.' });
      patch.displayName = name || null;
    }
    if (Object.keys(patch).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
    const row = await updateMailAccount(req.user.sub, { ...patch, updatedAt: new Date() });
    if (!row) return res.status(404).json(NO_ACCOUNT);
    res.json({ account: accountDto(row) });
  });

  router.delete('/mail/account', async (req, res) => {
    closeConnection(req.user.sub);
    await deleteMailAccount(req.user.sub);
    io.to(`user:${req.user.sub}`).emit('mail:changed', { account: true });
    res.json({ ok: true });
  });

  /** 메일 주소록 — 같은 팀에서 메일 계정을 연결한 사람(그 주소). 쓰기 창의 "주소록". */
  router.get('/mail/directory', async (req, res) => {
    res.json(await listMailDirectory(req.user.sub));
  });

  // ── 읽기 ──

  /** 받은편지함 안 읽은 수(메뉴 배지) — 계정이 없으면 `{ connected: false }`. */
  router.get('/mail/status', async (req, res) => {
    const account = await findMailAccount(req.user.sub);
    if (!account) return res.json({ connected: false, unseen: 0 });
    try {
      const status = await withImap(account, decryptField(account.passwordEnc), inboxStatus);
      res.json({ connected: true, unseen: status.unseen, error: null });
    } catch (err) {
      res.json({ connected: true, unseen: 0, error: describeImapError(err) });
    }
  });

  router.get(
    '/mail/folders',
    imap(async (req, res, loaded, run) => {
      const list = await run(listFolders);
      if (loaded.account.lastError) await updateMailAccount(loaded.account.userId, { lastError: null, lastErrorAt: null });
      res.json(folderList(list));
    }),
  );

  /** 목록 `?folder=&before=&limit=&q=` → `{ messages, nextBefore }`. */
  router.get(
    '/mail/messages',
    imap(async (req, res, loaded, run) => {
      const folder = folderOf(req.query.folder ?? 'INBOX');
      if (!folder) return res.status(400).json({ error: '폴더를 확인하세요.' });
      const q = typeof req.query.q === 'string' && req.query.q.trim() ? req.query.q.trim().slice(0, 100) : null;
      const result = await run((client) =>
        listMessages(client, folder, { before: uidOf(req.query.before), limit: Number(req.query.limit) || 30, q }),
      );
      res.json({ messages: result.messages.map(messageSummary), nextBefore: result.nextBefore });
    }),
  );

  /** 메일 하나 `?folder=&uid=` — 열면 읽음으로. 너무 크면 413. */
  router.get(
    '/mail/message',
    imap(async (req, res, loaded, run) => {
      const folder = folderOf(req.query.folder);
      const uid = uidOf(req.query.uid);
      if (!folder || !uid) return res.status(400).json({ error: '메일을 확인하세요.' });
      const got = await run((client) => readMessage(client, folder, uid));
      if (!got) return res.status(404).json({ error: '메일을 찾을 수 없습니다. 다른 곳에서 옮기거나 지웠을 수 있습니다.' });
      if (got.tooLarge) return res.status(413).json({ error: '메일이 너무 커서 여기서 열 수 없습니다(30MB 넘음). 원래 메일 프로그램에서 보세요.' });
      res.json(messageDetail(uid, got.parsed, got.flags));
    }),
  );

  /** 첨부 내려받기 `?folder=&uid=&index=`. */
  router.get(
    '/mail/attachment',
    imap(async (req, res, loaded, run) => {
      const folder = folderOf(req.query.folder);
      const uid = uidOf(req.query.uid);
      const index = Number(req.query.index);
      if (!folder || !uid || !Number.isInteger(index) || index < 0) return res.status(400).json({ error: '첨부를 확인하세요.' });
      const got = await run((client) => readMessage(client, folder, uid, { markSeen: false }));
      const attachment = got && !got.tooLarge ? got.parsed.attachments?.[index] : null;
      if (!attachment) return res.status(404).json({ error: '첨부를 찾을 수 없습니다.' });
      const name = attachment.filename || `attachment-${index + 1}`;
      res.setHeader('Content-Type', 'application/octet-stream');
      res.setHeader('Content-Disposition', `attachment; filename*=UTF-8''${encodeURIComponent(name)}`);
      res.setHeader('X-Content-Type-Options', 'nosniff');
      res.send(attachment.content);
    }),
  );

  // ── 정리 ──

  /** 읽음·중요 `{ folder, uids, seen?, flagged? }`. */
  router.post(
    '/mail/flags',
    imap(async (req, res, loaded, run) => {
      const folder = folderOf(req.body?.folder);
      const uids = uidsOf(req.body?.uids);
      const { seen, flagged } = req.body ?? {};
      if (!folder || !uids) return res.status(400).json({ error: '메일을 확인하세요.' });
      if (![seen, flagged].some((v) => typeof v === 'boolean')) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
      await run((client) => setFlags(client, folder, uids, { seen, flagged }));
      res.json({ ok: true });
    }),
  );

  router.post(
    '/mail/move',
    imap(async (req, res, loaded, run) => {
      const folder = folderOf(req.body?.folder);
      const to = folderOf(req.body?.to);
      const uids = uidsOf(req.body?.uids);
      if (!folder || !to || !uids) return res.status(400).json({ error: '옮길 메일과 폴더를 확인하세요.' });
      if (to === folder) return res.status(400).json({ error: '같은 폴더입니다.' });
      await run((client) => moveMessages(client, folder, uids, to));
      res.json({ ok: true });
    }),
  );

  /** 지우기 — 휴지통으로(휴지통에서는 아주 지움) → `{ result: 'trash' | 'deleted' }`. */
  router.post(
    '/mail/delete',
    imap(async (req, res, loaded, run) => {
      const folder = folderOf(req.body?.folder);
      const uids = uidsOf(req.body?.uids);
      if (!folder || !uids) return res.status(400).json({ error: '지울 메일을 확인하세요.' });
      const result = await run((client) => deleteMessages(client, folder, uids));
      res.json({ result });
    }),
  );

  // ── 보내기 ──

  /**
   * 보내기 `{ to, cc?, bcc?, subject, text, attachments?, inReplyTo?, references?, answered?: { folder, uid } }` — 첨부는 앱이 올린 파일
   * (fileRefs.js — 직접 올렸거나 볼 수 있는 대화의 파일), 합계 20MB. 보낸 뒤 보낸편지함에 넣고(Gmail 제외), 답장이면 원래 메일에 답장 표시.
   */
  router.post('/mail/send', async (req, res) => {
    const loaded = await loadAccount(req, res);
    if (!loaded) return;
    const { account, password } = loaded;
    const parsed = parseCompose(req.body);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const mail = parsed.values;
    const checked = await checkFileRefs(
      mail.attachments.map((a) => a.fileUrl),
      { senderId: req.user.sub },
    );
    if (!checked.ok) return res.status(400).json({ error: checked.error });
    const attachments = [];
    let total = 0;
    for (const a of mail.attachments) {
      const stored = checked.paths.get(a.fileUrl);
      const name = uploadFileNameOf(stored);
      if (!name) return res.status(400).json({ error: '첨부 파일을 확인할 수 없습니다.' });
      const diskPath = path.join(uploadsDir, path.basename(name));
      const stat = await fs.stat(diskPath).catch(() => null);
      if (!stat) return res.status(400).json({ error: `첨부 파일이 서버에 없습니다: ${a.fileName}` });
      total += stat.size;
      attachments.push({ filename: a.fileName, path: diskPath, contentType: a.mimeType ?? undefined });
    }
    if (total > SEND_ATTACHMENTS_BYTES_MAX) return res.status(400).json({ error: '첨부는 모두 합쳐 20MB까지입니다.' });
    const wait = sendLimiter.hit(req.user.sub);
    if (wait) return tooMany(res, wait, '메일 보내기');

    let raw;
    try {
      raw = await sendViaSmtp(account, password, {
        from: fromHeaderOf(account),
        to: mail.to,
        cc: mail.cc,
        bcc: mail.bcc,
        subject: mail.subject,
        text: mail.text,
        attachments,
        inReplyTo: mail.inReplyTo ?? undefined,
        references: mail.references.length ? mail.references : undefined,
      });
    } catch (err) {
      console.error('[webmail] 보내기 실패:', err?.code ?? '', err?.message ?? err);
      return res.status(502).json({ error: err?.code === 'EBLOCKED' ? err.message : describeSmtpError(err) });
    }
    // 보낸편지함·답장 표시는 덧붙이는 일 — 실패해도 보내기는 성공.
    let savedToSent = autoSavesSent(account);
    try {
      await withImap(account, password, async (client) => {
        if (!savedToSent) savedToSent = await appendToSent(client, raw);
        const answered = req.body?.answered;
        const folder = folderOf(answered?.folder);
        const uid = uidOf(answered?.uid);
        if (folder && uid && mail.inReplyTo) await markAnswered(client, folder, uid).catch(() => {});
      });
    } catch (err) {
      console.error('[webmail] 보낸편지함 저장 실패:', err?.message ?? err);
    }
    res.status(201).json({ ok: true, savedToSent });
  });

  return router;
}

// ── 새 메일 확인 ────────────────────────────────────────────────────────

const CHECK_INTERVAL_MS = 3 * 60 * 1000;
/** 로그인이 실패한 계정은 이만큼 쉬었다 다시 본다(잘못된 비밀번호로 메일 서버를 계속 두드리지 않게). */
const ERROR_BACKOFF_MS = 30 * 60 * 1000;
const CHECK_CONCURRENCY = 3;

/** 한 계정 확인 — 늘어난 안 읽은 메일이 있으면 소켓·푸시로 알린다. 알린 수. */
export async function checkMailAccount(io, account, now = new Date()) {
  const password = decryptField(account.passwordEnc);
  try {
    const result = await withImap(account, password, async (client) => {
      const status = await inboxStatus(client);
      const count = newMailCount(account, status);
      const envelopes = count > 0 ? await newInboxEnvelopes(client, account.lastUidNext, 3) : [];
      return { status, envelopes };
    });
    const { status, envelopes } = result;
    await updateMailAccount(account.userId, {
      lastUidNext: status.uidNext ?? null,
      lastUidValidity: status.uidValidity,
      lastCheckedAt: now,
      lastError: null,
      lastErrorAt: null,
    });
    if (envelopes.length === 0) return 0;
    const latest = envelopes.map((m) => ({
      from: m.envelope?.from?.[0]?.name || m.envelope?.from?.[0]?.address || '',
      subject: m.envelope?.subject || '(제목 없음)',
    }));
    io.to(`user:${account.userId}`).emit('mail:new', { count: envelopes.length, unseen: status.unseen, latest });
    const first = latest[0];
    notifyMailPush({
      userId: account.userId,
      title: envelopes.length > 1 ? `새 메일 ${envelopes.length}통` : `새 메일 — ${first.from}`,
      body: envelopes.length > 1 ? `${first.from}: ${first.subject} 외` : first.subject,
    }).catch((err) => console.error('[webmail] 새 메일 알림 실패:', err?.message ?? err));
    return envelopes.length;
  } catch (err) {
    await updateMailAccount(account.userId, { lastError: describeImapError(err), lastErrorAt: now }).catch(() => {});
    return 0;
  }
}

/** 알림을 켠 계정을 모두 확인(오류가 난 지 30분이 안 된 계정은 건너뜀). 알린 수 합. */
export async function runMailChecks(io, now = new Date()) {
  const accounts = (await listNotifyMailAccounts()).filter(
    (a) => !a.lastErrorAt || now.getTime() - new Date(a.lastErrorAt).getTime() >= ERROR_BACKOFF_MS,
  );
  let total = 0;
  for (let i = 0; i < accounts.length; i += CHECK_CONCURRENCY) {
    const counts = await Promise.all(accounts.slice(i, i + CHECK_CONCURRENCY).map((a) => checkMailAccount(io, a, now)));
    total += counts.reduce((s, n) => s + n, 0);
  }
  return total;
}

export function startMailCheckJob(io) {
  let running = false;
  const tick = async () => {
    if (running) return;
    running = true;
    try {
      await runMailChecks(io);
    } catch (err) {
      console.error('[webmail] 새 메일 확인 실패:', err?.message ?? err);
    } finally {
      running = false;
    }
  };
  setInterval(tick, CHECK_INTERVAL_MS).unref();
}
