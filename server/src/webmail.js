import { randomUUID } from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { Router } from 'express';
import { RateLimiter, tooMany } from './authGuard.js';
import { decryptField, encryptField } from './crypto.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { findUserById } from './db/queries/users.js';
import {
  deleteMailAccount,
  deleteMailContact,
  deleteMailRule,
  findMailAccount,
  findMailRule,
  insertMailAccount,
  insertMailRule,
  listCheckableMailAccounts,
  listMailAccounts,
  listMailContacts,
  listMailDirectory,
  listMailRules,
  recordMailContacts,
  reorderMailAccounts,
  reorderMailRules,
  updateMailAccount,
  updateMailAccountConnection,
  updateMailRule,
} from './db/queries/webmail.js';
import { isUuid } from './favoritesRules.js';
import { checkFileRefs } from './fileRefs.js';
import { acceptablePreviewResponse, isRemoteImageUrl, sniffImageType } from './linkPreviewImage.js';
import { safeFetch } from './linkPreview.js';
import { deliverLocal, ensureLocalAccount, findLocalUser } from './localMailServer.js';
import { isLocalAddress, localDomainsOf, localMailReady, localPartOf } from './localMailRules.js';
import { LocalQuotaError } from './localMailStore.js';
import { MailError, sendRawMail } from './mailer.js';
import { describeSmtpError, mailReady } from './mailRules.js';
import { recordUploadedBytes, uploadFileNameOf, uploadsDir, uploadsDirHasRoom } from './upload.js';
import { credentialsOf, isLocalAccount, mailBackend } from './webmailBackend.js';
import {
  buildRaw,
  closeConnection,
  connectImap,
  envelopeRecipients,
  inboxStatus,
  newInboxMessages,
  sendViaSmtp,
  verifySmtp,
  withImap,
} from './webmailClient.js';
import { applyRulesToNew, mailsToNotify, notifyNewMail } from './webmailNotify.js';
import {
  mailOAuthProviders,
  oauthEndpointsOf,
  pollMailOAuth,
  setMailOAuthCompleter,
  startMailOAuth,
} from './webmailOAuth.js';
import {
  ACCOUNTS_MAX,
  accountDto,
  contactsToRecord,
  describeImapError,
  fromHeaderOf,
  isFullOrder,
  mergeSuggestions,
  messageDetail,
  newMailCount,
  normalizeTrustedSender,
  parseAccountInput,
  parseAccountPatch,
  parseCompose,
  parseRule,
  planRules,
  presetList,
  RULES_APPLY_MAX,
  RULES_MAX,
  SEND_ATTACHMENTS_BYTES_MAX,
  TRUSTED_SENDERS_MAX,
} from './webmailRules.js';

/**
 * 웹메일 — 사람마다 연결한 메일 계정(5개까지 — IMAP/SMTP, Google·Microsoft OAuth, 자체 메일 서버의 회사 메일함)을 앱에서 읽고 보낸다.
 * 바깥 메일 서버의 메일은 그 서버에 있고 이 서버는 중계만 한다(본문을 DB에 두지 않음). 회사 메일함은 이 서버가 받아 둔다
 * (localMailServer.js·localMailStore.js). 계정 비밀번호·토큰은 암호화해 두고 내보내지 않는다. 요청마다 `account`(계정 id)로 계정을
 * 고르고, 없으면 기본(처음) 계정. 새 메일은 3분마다 받은편지함을 확인해 받는 규칙을 걸고 소켓 `mail:new`와 푸시로 알린다
 * (startMailCheckJob). 연결 규칙·모양은 webmailRules.js, 메일 서버와의 일은 webmailClient.js·webmailBackend.js.
 */

const NO_ACCOUNT = { error: '연결된 메일 계정이 없습니다. 메일 → 계정 연결에서 먼저 연결하세요.', code: 'NO_ACCOUNT' };
const FOLDER_MAX = 500;
const UIDS_MAX = 200;
/** 대화방·할 일로 보낼 때 한 번에 올리는 파일 수·합계. */
const EXPORT_FILES_MAX = 10;
const EXPORT_BYTES_MAX = 50 * 1024 * 1024;
const REMOTE_IMAGE_BYTES_MAX = 5 * 1024 * 1024;
const INLINE_IMAGE_TYPES = /^image\/(png|jpe?g|gif|webp|bmp)$/i;

const connectLimiter = new RateLimiter({ max: 10, windowMs: 10 * 60 * 1000 });
const sendLimiter = new RateLimiter({ max: 30, windowMs: 10 * 60 * 1000 });
const imageLimiter = new RateLimiter({ max: 600, windowMs: 10 * 60 * 1000 });
const exportLimiter = new RateLimiter({ max: 60, windowMs: 10 * 60 * 1000 });
setInterval(() => {
  for (const l of [connectLimiter, sendLimiter, imageLimiter, exportLimiter]) l.prune();
}, 10 * 60 * 1000).unref();

/** Gmail은 SMTP로 보낸 메일을 보낸편지함에 알아서 넣는다 — 또 넣으면 두 번 보인다. */
const autoSavesSent = (account) => /(^|\.)gmail\.com$|(^|\.)googlemail\.com$/i.test(account.smtpHost ?? '');

const folderOf = (v) => (typeof v === 'string' && v && v.length <= FOLDER_MAX && !/[\r\n\0]/.test(v) ? v : null);
const uidOf = (v) => {
  const n = Number(v);
  return Number.isSafeInteger(n) && n > 0 ? n : null;
};
const uidsOf = (v) => {
  const list = (Array.isArray(v) ? v : [v]).map(uidOf);
  return list.length && list.length <= UIDS_MAX && list.every(Boolean) ? [...new Set(list)] : null;
};
/** 임시 저장본 가리키기 `{ folder, uid }` — 모양이 틀리면 null. */
const draftRefOf = (v) => {
  const folder = folderOf(v?.folder);
  const uid = uidOf(v?.uid);
  return folder && uid ? { folder, uid } : null;
};

/** 화면에 알려도 되는 오류(400) — 메일 서버가 아니라 입력·회사 메일함의 사정. */
class MailInputError extends Error {}

/** 업로드 폴더에 쓸 파일 이름의 확장자(짧은 영문·숫자만). */
const safeExt = (name) => {
  const ext = path.extname(String(name ?? '')).toLowerCase();
  return /^\.[a-z0-9]{1,10}$/.test(ext) ? ext : '';
};

/** 메일 서버 쪽 일을 하다 난 오류 → 응답(로그인 실패면 계정에 남겨 화면이 알 수 있게). */
async function mailFailed(res, account, err) {
  if (err instanceof MailInputError || err instanceof LocalQuotaError || ['NO_FOLDER', 'NO_DRAFTS', 'QUOTA'].includes(err?.code)) {
    return res.status(400).json({ error: err.message });
  }
  if (err?.code === 'EBLOCKED') return res.status(502).json({ error: err.message });
  const message = err?.code === 'OAUTH_REFRESH' || err?.code === 'OAUTH_REVOKED' ? err.message : describeImapError(err);
  if (err?.authenticationFailed) {
    await updateMailAccount(account.id, { lastError: message, lastErrorAt: new Date() }).catch(() => {});
  }
  console.error('[webmail] 메일 서버 실패:', err?.code ?? '', err?.message ?? err);
  return res.status(502).json({ error: message });
}

/** 연결 시험 — IMAP 로그인, SMTP 로그인. 실패하면 `{ error }`(어느 쪽이 왜). */
async function testConnection(values, creds) {
  const probe = { ...values, id: `probe-${randomUUID()}` };
  try {
    const client = await connectImap(probe, creds);
    await client.logout().catch(() => {});
  } catch (err) {
    return { error: `받는 메일(IMAP) — ${err?.code === 'EBLOCKED' ? err.message : describeImapError(err)}` };
  }
  try {
    await verifySmtp(probe, creds);
  } catch (err) {
    return { error: `보내는 메일(SMTP) — ${err?.code === 'EBLOCKED' ? err.message : describeSmtpError(err)}` };
  }
  return {};
}

export function createWebmailRouter(io) {
  const router = Router();
  const changed = (userId, extra = {}) => io?.to(`user:${userId}`).emit('mail:changed', { account: true, ...extra });

  /** 고른 계정(요청의 `account` — 없으면 기본). 없으면 응답하고 null. */
  async function accountFor(req, res, id = undefined) {
    const raw = id ?? req.query?.account ?? req.body?.account ?? null;
    if (raw !== null && raw !== '' && !isUuid(raw)) {
      res.status(400).json({ error: '메일 계정을 확인하세요.' });
      return null;
    }
    const account = await findMailAccount(req.user.sub, raw || null);
    if (!account) {
      res.status(404).json(NO_ACCOUNT);
      return null;
    }
    return account;
  }

  /** [handler](req, res, account, backend)를 그 계정으로 — 메일 서버 오류는 mailFailed. */
  const withAccount = (handler) => async (req, res) => {
    const account = await accountFor(req, res);
    if (!account) return;
    try {
      await handler(req, res, account, mailBackend(account));
    } catch (err) {
      if (!res.headersSent) await mailFailed(res, account, err);
    }
  };

  /** 회사 메일함을 쓸 수 있으면 이 사람의 것을 마련한다(목록을 볼 때 — 처음이면 만든다). */
  async function ensureLocalFor(userId) {
    const s = await getServerSettings();
    if (!localMailReady(s)) return;
    const user = await findUserById(userId);
    if (user && !user.deletedAt && !user.suspendedAt) await ensureLocalAccount(user, s);
  }

  // ── 계정 ──

  router.get('/mail/presets', async (req, res) => {
    res.json(presetList(mailOAuthProviders(await getServerSettings())));
  });

  /** 내 계정들(순서대로 — 처음 것이 기본). 회사 메일함이 켜진 서버면 그것도 마련해 넣는다. */
  router.get('/mail/accounts', async (req, res) => {
    await ensureLocalFor(req.user.sub).catch((err) => console.error('[webmail] 회사 메일함 준비 실패:', err?.message ?? err));
    res.json({ accounts: (await listMailAccounts(req.user.sub)).map(accountDto), max: ACCOUNTS_MAX });
  });

  /** 기본 계정 하나(예전 앱). */
  router.get('/mail/account', async (req, res) => {
    res.json({ account: accountDto(await findMailAccount(req.user.sub)) });
  });

  /**
   * 연결하기·바꾸기의 공통 — 저장하기 전에 IMAP 로그인과 SMTP 로그인을 해 본다(실패하면 400, 어느 쪽이 왜 안 되는지). 비밀번호를
   * 비우면(바꾸기) 지금 비밀번호로 시험한다. [existing]이 없으면 새 계정.
   */
  async function saveConnection(req, res, existing) {
    const wait = connectLimiter.hit(req.user.sub);
    if (wait) return tooMany(res, wait, '메일 계정 연결');
    if (existing && isLocalAccount(existing)) return res.status(400).json({ error: '회사 메일함은 연결 값이 없습니다.' });
    const usable = existing && existing.authType === 'password' ? existing : null;
    const parsed = parseAccountInput(req.body, { existing: usable });
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const { password: newPassword, ...values } = parsed.values;
    const accounts = await listMailAccounts(req.user.sub);
    if (accounts.some((a) => a.id !== existing?.id && a.email.toLowerCase() === values.email.toLowerCase())) {
      return res.status(400).json({ error: '이미 연결한 메일 주소입니다.' });
    }
    if (!existing && accounts.length >= ACCOUNTS_MAX) return res.status(400).json({ error: `메일 계정은 ${ACCOUNTS_MAX}개까지 연결할 수 있습니다.` });
    const password = newPassword ?? decryptField(usable?.passwordEnc) ?? '';
    const tested = await testConnection(values, { password });
    if (tested.error) return res.status(400).json({ error: tested.error });
    const stored = {
      ...values,
      authType: 'password',
      passwordEnc: encryptField(password),
      oauthProvider: null,
      oauthAccessEnc: null,
      oauthRefreshEnc: null,
      oauthExpiresAt: null,
    };
    let row;
    if (existing) {
      closeConnection(existing.id);
      row = await updateMailAccountConnection(existing.id, stored);
    } else {
      row = await insertMailAccount(req.user.sub, stored);
    }
    changed(req.user.sub);
    res.status(existing ? 200 : 201).json({ account: accountDto(row) });
  }

  router.post('/mail/accounts', (req, res) => saveConnection(req, res, null));

  router.put('/mail/accounts/:id', async (req, res) => {
    const account = await accountFor(req, res, req.params.id);
    if (account) await saveConnection(req, res, account);
  });

  /** 예전 앱 — 기본 계정을 바꾸거나 없으면 만든다. */
  router.put('/mail/account', async (req, res) => saveConnection(req, res, await findMailAccount(req.user.sub)));

  /** 알림·보내는 이름·서명(연결 시험 없이). */
  const patchAccount = async (req, res, account) => {
    const parsed = parseAccountPatch(req.body);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const row = await updateMailAccount(account.id, parsed.patch);
    if (!row) return res.status(404).json(NO_ACCOUNT);
    res.json({ account: accountDto(row) });
  };
  router.patch('/mail/accounts/:id', async (req, res) => {
    const account = await accountFor(req, res, req.params.id);
    if (account) await patchAccount(req, res, account);
  });
  router.patch('/mail/account', async (req, res) => {
    const account = await accountFor(req, res, null);
    if (account) await patchAccount(req, res, account);
  });

  /** 연결 끊기 — 서버에 둔 연결 값·비밀번호·토큰을 지운다(메일 서버의 메일은 그대로). 회사 메일함은 끊을 수 없다. */
  const removeAccount = async (req, res, account) => {
    if (isLocalAccount(account)) return res.status(400).json({ error: '회사 메일함은 연결을 끊을 수 없습니다.' });
    closeConnection(account.id);
    await deleteMailAccount(req.user.sub, account.id);
    changed(req.user.sub);
    res.json({ ok: true });
  };
  router.delete('/mail/accounts/:id', async (req, res) => {
    const account = await accountFor(req, res, req.params.id);
    if (account) await removeAccount(req, res, account);
  });
  router.delete('/mail/account', async (req, res) => {
    const account = await accountFor(req, res, null);
    if (account) await removeAccount(req, res, account);
  });

  /** 순서 `{ ids }` — 내 계정 전부를 원하는 차례로(처음 것이 기본). */
  router.post('/mail/accounts/order', async (req, res) => {
    const accounts = await listMailAccounts(req.user.sub);
    if (!isFullOrder(req.body?.ids, accounts.map((a) => a.id))) return res.status(400).json({ error: '계정 순서를 확인하세요.' });
    await reorderMailAccounts(req.user.sub, req.body.ids);
    changed(req.user.sub);
    res.json({ accounts: (await listMailAccounts(req.user.sub)).map(accountDto) });
  });

  /** 바깥 그림을 늘 보여 줄 보낸 사람 `{ sender: 'a@b.com' | '@b.com', add: true|false }`. */
  router.post('/mail/accounts/:id/trusted', async (req, res) => {
    const account = await accountFor(req, res, req.params.id);
    if (!account) return;
    const sender = normalizeTrustedSender(req.body?.sender);
    if (!sender) return res.status(400).json({ error: '보낸 사람 주소를 확인하세요.' });
    const list = (Array.isArray(account.trustedSenders) ? account.trustedSenders : []).filter((t) => t !== sender);
    if (req.body?.add !== false) {
      if (list.length >= TRUSTED_SENDERS_MAX) return res.status(400).json({ error: `그림을 늘 볼 보낸 사람은 ${TRUSTED_SENDERS_MAX}명까지입니다.` });
      list.push(sender);
    }
    const row = await updateMailAccount(account.id, { trustedSenders: list });
    res.json({ account: accountDto(row) });
  });

  // ── OAuth(Google·Microsoft 로그인으로 연결) ──

  /** 시작 `{ provider: 'google'|'microsoft', account? }`(account면 그 OAuth 계정을 다시 로그인) → `{ state, authUrl, expiresInSeconds }`. */
  router.post('/mail/oauth/start', async (req, res) => {
    const wait = connectLimiter.hit(req.user.sub);
    if (wait) return tooMany(res, wait, '메일 계정 연결');
    let accountId = null;
    let loginHint = null;
    if (req.body?.account) {
      const account = await accountFor(req, res, req.body.account);
      if (!account) return;
      if (isLocalAccount(account)) return res.status(400).json({ error: '회사 메일함은 연결 값이 없습니다.' });
      accountId = account.id;
      loginHint = account.email;
    } else if ((await listMailAccounts(req.user.sub)).length >= ACCOUNTS_MAX) {
      return res.status(400).json({ error: `메일 계정은 ${ACCOUNTS_MAX}개까지 연결할 수 있습니다.` });
    }
    const started = startMailOAuth({ userId: req.user.sub, provider: req.body?.provider, settings: await getServerSettings(), accountId, loginHint });
    if (started.error) return res.status(started.status ?? 400).json({ error: started.error });
    res.json(started);
  });

  /** 결과 묻기 `?state=` → `{ status: 'pending' }` | `{ status: 'done', account }` | `{ status: 'error', error }`. */
  router.get('/mail/oauth/poll', (req, res) => {
    res.json(pollMailOAuth(req.query.state, req.user.sub));
  });

  // 브라우저 로그인이 끝나면(sso.js 콜백 → webmailOAuth.js) 여기서 연결을 시험하고 계정을 저장한다.
  setMailOAuthCompleter(async ({ userId, provider, accountId, email, name, tokens }) => {
    const values = { email, username: email, ...oauthEndpointsOf(provider) };
    const tested = await testConnection(values, { accessToken: tokens.accessToken });
    if (tested.error) return { error: tested.error };
    const stored = {
      ...values,
      authType: 'oauth',
      oauthProvider: provider,
      passwordEnc: null,
      oauthAccessEnc: encryptField(tokens.accessToken),
      oauthRefreshEnc: encryptField(tokens.refreshToken),
      oauthExpiresAt: tokens.expiresAt,
    };
    const accounts = await listMailAccounts(userId);
    const target = accountId ? accounts.find((a) => a.id === accountId) : accounts.find((a) => !isLocalAccount(a) && a.email.toLowerCase() === email);
    if (accountId && !target) return { error: '다시 로그인할 계정을 찾을 수 없습니다.' };
    if (target && target.email.toLowerCase() !== email && accounts.some((a) => a.id !== target.id && a.email.toLowerCase() === email)) {
      return { error: '이미 연결한 메일 주소입니다.' };
    }
    let row;
    if (target) {
      closeConnection(target.id);
      row = await updateMailAccountConnection(target.id, stored);
    } else {
      if (accounts.length >= ACCOUNTS_MAX) return { error: `메일 계정은 ${ACCOUNTS_MAX}개까지 연결할 수 있습니다.` };
      row = await insertMailAccount(userId, { ...stored, displayName: name });
    }
    changed(userId);
    return { account: accountDto(row) };
  });

  // ── 주소록·자동 완성 ──

  /** 메일 주소록 — 같은 팀에서 메일 계정을 연결한 사람(그 주소). 쓰기 창의 "주소록". */
  router.get('/mail/directory', async (req, res) => {
    res.json(await listMailDirectory(req.user.sub));
  });

  /** 받는 사람 자동 완성 `?q=` → `[{ name, address, member }]` — 같은 팀 주소록 + 내가 보낸 바깥 주소(자주·최근 순). */
  router.get('/mail/contacts', async (req, res) => {
    const q = typeof req.query.q === 'string' ? req.query.q.trim().slice(0, 100) : '';
    if (!q) return res.json([]);
    const [contacts, directory] = await Promise.all([listMailContacts(req.user.sub, q), listMailDirectory(req.user.sub)]);
    res.json(mergeSuggestions({ q, contacts, directory }));
  });

  /** 자동 완성에서 지우기 `{ address }`. */
  router.delete('/mail/contacts', async (req, res) => {
    const address = typeof req.body?.address === 'string' ? req.body.address.trim().toLowerCase() : '';
    if (!address) return res.status(400).json({ error: '주소를 확인하세요.' });
    await deleteMailContact(req.user.sub, address);
    res.json({ ok: true });
  });

  // ── 읽기 ──

  /**
   * 받은편지함 안 읽은 수(메뉴 숫자 — 계정 모두의 합) → `{ connected, unseen, error, accounts: [{ id, email, unseen, error }] }`.
   * 계정이 없으면 `{ connected: false }`.
   */
  router.get('/mail/status', async (req, res) => {
    await ensureLocalFor(req.user.sub).catch(() => {});
    const accounts = await listMailAccounts(req.user.sub);
    if (!accounts.length) return res.json({ connected: false, unseen: 0, accounts: [] });
    const rows = await Promise.all(
      accounts.map(async (a) => {
        try {
          return { id: a.id, email: a.email, unseen: await mailBackend(a).inboxUnseen(), error: null };
        } catch (err) {
          return { id: a.id, email: a.email, unseen: 0, error: err?.code === 'OAUTH_REVOKED' ? err.message : describeImapError(err) };
        }
      }),
    );
    res.json({
      connected: true,
      unseen: rows.reduce((s, r) => s + r.unseen, 0),
      error: rows.find((r) => r.error)?.error ?? null,
      accounts: rows,
    });
  });

  router.get(
    '/mail/folders',
    withAccount(async (req, res, account, backend) => {
      const list = await backend.listFolders();
      if (account.lastError) await updateMailAccount(account.id, { lastError: null, lastErrorAt: null });
      res.json(list);
    }),
  );

  /** 목록 `?account=&folder=&before=&limit=&q=` → `{ messages, nextBefore }`. */
  router.get(
    '/mail/messages',
    withAccount(async (req, res, account, backend) => {
      const folder = folderOf(req.query.folder ?? 'INBOX');
      if (!folder) return res.status(400).json({ error: '폴더를 확인하세요.' });
      const q = typeof req.query.q === 'string' && req.query.q.trim() ? req.query.q.trim().slice(0, 100) : null;
      res.json(await backend.listMessages(folder, { before: uidOf(req.query.before), limit: Number(req.query.limit) || 30, q }));
    }),
  );

  /** 메일 하나 `?account=&folder=&uid=` — 열면 읽음으로. 너무 크면 413. */
  router.get(
    '/mail/message',
    withAccount(async (req, res, account, backend) => {
      const folder = folderOf(req.query.folder);
      const uid = uidOf(req.query.uid);
      if (!folder || !uid) return res.status(400).json({ error: '메일을 확인하세요.' });
      const got = await backend.readMessage(folder, uid);
      if (!got) return res.status(404).json({ error: '메일을 찾을 수 없습니다. 다른 곳에서 옮기거나 지웠을 수 있습니다.' });
      if (got.tooLarge) return res.status(413).json({ error: '메일이 너무 커서 여기서 열 수 없습니다(30MB 넘음). 원래 메일 프로그램에서 보세요.' });
      res.json(messageDetail(uid, got.parsed, got.flags));
    }),
  );

  /** 메일의 첨부 하나 — 없으면 404로 응답하고 null. */
  async function attachmentOf(req, res, backend) {
    const folder = folderOf(req.query.folder);
    const uid = uidOf(req.query.uid);
    const index = Number(req.query.index);
    if (!folder || !uid || !Number.isInteger(index) || index < 0) {
      res.status(400).json({ error: '첨부를 확인하세요.' });
      return null;
    }
    const got = await backend.readMessage(folder, uid, { markSeen: false });
    const attachment = got && !got.tooLarge ? got.parsed.attachments?.[index] : null;
    if (!attachment) {
      res.status(404).json({ error: '첨부를 찾을 수 없습니다.' });
      return null;
    }
    return { attachment, index };
  }

  /** 첨부 내려받기 `?account=&folder=&uid=&index=`. */
  router.get(
    '/mail/attachment',
    withAccount(async (req, res, account, backend) => {
      const found = await attachmentOf(req, res, backend);
      if (!found) return;
      const name = found.attachment.filename || `attachment-${found.index + 1}`;
      res.setHeader('Content-Type', 'application/octet-stream');
      res.setHeader('Content-Disposition', `attachment; filename*=UTF-8''${encodeURIComponent(name)}`);
      res.setHeader('X-Content-Type-Options', 'nosniff');
      res.send(found.attachment.content);
    }),
  );

  /** 본문 안의 그림(cid) `?account=&folder=&uid=&index=` — 그림 형식이고 내용도 그림일 때만. */
  router.get(
    '/mail/inline',
    withAccount(async (req, res, account, backend) => {
      const found = await attachmentOf(req, res, backend);
      if (!found) return;
      const kind = sniffImageType(found.attachment.content);
      if (!INLINE_IMAGE_TYPES.test(found.attachment.contentType ?? '') || !kind) return res.status(404).json({ error: '그림이 아닙니다.' });
      res.setHeader('Content-Type', `image/${kind}`);
      res.setHeader('X-Content-Type-Options', 'nosniff');
      res.setHeader('Cache-Control', 'private, max-age=3600');
      res.send(found.attachment.content);
    }),
  );

  /**
   * 바깥 그림 `?url=` — 사용자가 "그림 보기"를 눌렀을 때만 앱이 부른다. 서버가 대신 받아(앱의 IP가 보낸 쪽에 드러나지 않게) 그림이면
   * 돌려준다. 사설·이 서버 주소·80/443이 아닌 포트는 막는다(linkPreview.js safeFetch — 리다이렉트도 다시 검사). 5MB까지.
   */
  router.get('/mail/remote-image', async (req, res) => {
    const url = typeof req.query.url === 'string' ? req.query.url : '';
    if (!isRemoteImageUrl(url)) return res.status(400).json({ error: '그림 주소를 확인하세요.' });
    const wait = imageLimiter.hit(req.user.sub);
    if (wait) return tooMany(res, wait, '그림 받기');
    let got = null;
    try {
      got = await safeFetch(url, { maxBytes: REMOTE_IMAGE_BYTES_MAX, accept: 'image/*', truncate: false, deadlineMs: 10_000 });
    } catch {
      got = null;
    }
    if (!acceptablePreviewResponse(got)) return res.status(404).json({ error: '그림을 받지 못했습니다.' });
    res.setHeader('Content-Type', `image/${sniffImageType(got.body)}`);
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Content-Security-Policy', "default-src 'none'");
    res.setHeader('Cache-Control', 'private, max-age=86400');
    res.send(got.body);
  });

  // ── 정리 ──

  /** 읽음·중요 `{ account?, folder, uids, seen?, flagged? }`. */
  router.post(
    '/mail/flags',
    withAccount(async (req, res, account, backend) => {
      const folder = folderOf(req.body?.folder);
      const uids = uidsOf(req.body?.uids);
      const { seen, flagged } = req.body ?? {};
      if (!folder || !uids) return res.status(400).json({ error: '메일을 확인하세요.' });
      if (![seen, flagged].some((v) => typeof v === 'boolean')) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
      await backend.setFlags(folder, uids, { seen, flagged });
      res.json({ ok: true });
    }),
  );

  router.post(
    '/mail/move',
    withAccount(async (req, res, account, backend) => {
      const folder = folderOf(req.body?.folder);
      const to = folderOf(req.body?.to);
      const uids = uidsOf(req.body?.uids);
      if (!folder || !to || !uids) return res.status(400).json({ error: '옮길 메일과 폴더를 확인하세요.' });
      if (to === folder) return res.status(400).json({ error: '같은 폴더입니다.' });
      await backend.move(folder, uids, to);
      res.json({ ok: true });
    }),
  );

  /** 지우기 — 휴지통으로(휴지통에서는 아주 지움) → `{ result: 'trash' | 'deleted' }`. */
  router.post(
    '/mail/delete',
    withAccount(async (req, res, account, backend) => {
      const folder = folderOf(req.body?.folder);
      const uids = uidsOf(req.body?.uids);
      if (!folder || !uids) return res.status(400).json({ error: '지울 메일을 확인하세요.' });
      res.json({ result: await backend.remove(folder, uids) });
    }),
  );

  // ── 쓰기(첨부 모으기)·임시 저장·보내기 ──

  /**
   * 보낼(저장할) 첨부 — 앱이 올린 파일(fileRefs.js — 직접 올렸거나 볼 수 있는 대화의 파일)과 임시 저장본에서 이어 온 첨부([draft]의
   * 번호들). 합계 20MB. nodemailer 첨부 모양들.
   */
  async function collectAttachments(userId, mail, backend, draft) {
    const checked = await checkFileRefs(
      mail.attachments.map((a) => a.fileUrl),
      { senderId: userId },
    );
    if (!checked.ok) throw new MailInputError(checked.error);
    const out = [];
    let total = 0;
    for (const a of mail.attachments) {
      const name = uploadFileNameOf(checked.paths.get(a.fileUrl));
      if (!name) throw new MailInputError('첨부 파일을 확인할 수 없습니다.');
      const diskPath = path.join(uploadsDir, path.basename(name));
      const stat = await fs.stat(diskPath).catch(() => null);
      if (!stat) throw new MailInputError(`첨부 파일이 서버에 없습니다: ${a.fileName}`);
      total += stat.size;
      out.push({ filename: a.fileName, path: diskPath, contentType: a.mimeType ?? undefined });
    }
    if (mail.draftAttachments.length) {
      if (!draft) throw new MailInputError('이어 쓸 임시 저장본을 확인하세요.');
      const got = await backend.readMessage(draft.folder, draft.uid, { markSeen: false });
      if (!got || got.tooLarge) throw new MailInputError('임시 저장본을 찾을 수 없습니다. 다른 곳에서 지웠을 수 있습니다.');
      for (const index of mail.draftAttachments) {
        const a = got.parsed.attachments?.[index];
        if (!a) throw new MailInputError('임시 저장본의 첨부를 찾을 수 없습니다.');
        total += a.content?.length ?? 0;
        out.push({ filename: a.filename || `첨부${index + 1}`, content: a.content, contentType: a.contentType ?? undefined });
      }
    }
    if (total > SEND_ATTACHMENTS_BYTES_MAX) throw new MailInputError('첨부는 모두 합쳐 20MB까지입니다.');
    return out;
  }

  const nodemailerMail = (account, mail, attachments, extra = {}) => ({
    from: fromHeaderOf(account),
    to: mail.to,
    cc: mail.cc,
    bcc: mail.bcc,
    subject: mail.subject,
    text: mail.text,
    attachments,
    inReplyTo: mail.inReplyTo ?? undefined,
    references: mail.references.length ? mail.references : undefined,
    ...extra,
  });

  /**
   * 임시 저장 `{ account?, to?, cc?, bcc?, subject?, text?, attachments?, draftAttachments?, draft?: { folder, uid }, inReplyTo?, references? }`
   * → `{ folder, uid }`(201). 임시보관함에 \Draft로 넣고(숨은 참조도 남김), [draft](바꿔 쓸 앞의 저장본)는 아주 지운다.
   */
  router.post(
    '/mail/drafts',
    withAccount(async (req, res, account, backend) => {
      const parsed = parseCompose(req.body, { draft: true });
      if (parsed.error) return res.status(400).json({ error: parsed.error });
      const prev = draftRefOf(req.body?.draft);
      const attachments = await collectAttachments(req.user.sub, parsed.values, backend, prev);
      const domain = account.email.split('@')[1] ?? 'localhost';
      const messageId = `<${randomUUID()}@${domain}>`;
      const raw = await buildRaw(nodemailerMail(account, parsed.values, attachments, { messageId }), { keepBcc: true });
      const saved = await backend.saveDraft(raw, messageId);
      if (prev) await backend.expunge(prev.folder, [prev.uid]).catch((err) => console.error('[webmail] 앞 저장본 지우기 실패:', err?.message ?? err));
      res.status(201).json(saved);
    }),
  );

  /** 임시 저장본 버리기 `{ account?, folder, uid }` — 휴지통을 거치지 않고 지운다. */
  router.post(
    '/mail/drafts/discard',
    withAccount(async (req, res, account, backend) => {
      const draft = draftRefOf(req.body);
      if (!draft) return res.status(400).json({ error: '임시 저장본을 확인하세요.' });
      await backend.expunge(draft.folder, [draft.uid]);
      res.json({ ok: true });
    }),
  );

  /**
   * 회사 메일함에서 보내기 — 우리 도메인 사람에게는 바깥을 거치지 않고 바로 넣고, 바깥 주소는 서버의 SMTP(관리자 콘솔 메일)로 넘긴다.
   * 보낸 원문.
   */
  async function sendFromLocal(account, message) {
    const s = await getServerSettings();
    const domains = localDomainsOf(s);
    const recipients = envelopeRecipients(message);
    const internal = recipients.filter((a) => isLocalAddress(a, domains));
    const external = recipients.filter((a) => !isLocalAddress(a, domains));
    for (const a of internal) {
      if (!(await findLocalUser(localPartOf(a, domains)))) throw new MailInputError(`받는 사람을 찾을 수 없습니다: ${a}`);
    }
    if (external.length && !mailReady(s)) {
      throw new MailInputError('바깥 주소로 보내려면 관리자가 관리자 콘솔 → 메일(SMTP)을 켜야 합니다. 회사 도메인 주소로는 보낼 수 있습니다.');
    }
    const raw = await buildRaw(message);
    if (external.length) {
      try {
        await sendRawMail({ from: account.email, to: external, raw });
      } catch (err) {
        if (err instanceof MailError) throw new MailInputError(err.message);
        throw err;
      }
    }
    if (internal.length) await deliverLocal(io, raw, internal, { settings: s });
    return raw;
  }

  /**
   * 보내기 `{ account?, to, cc?, bcc?, subject, text, attachments?, draftAttachments?, draft?, inReplyTo?, references?, answered?: { folder, uid } }`
   * — 첨부는 collectAttachments. 보낸 뒤 보낸편지함에 넣고(Gmail 제외), 답장이면 원래 메일에 답장 표시, 임시 저장본에서 보냈으면 그것을
   * 지운다. 받는 사람은 자동 완성에 남긴다.
   */
  router.post('/mail/send', async (req, res) => {
    const account = await accountFor(req, res);
    if (!account) return;
    const parsed = parseCompose(req.body);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const mail = parsed.values;
    const backend = mailBackend(account);
    const draft = draftRefOf(req.body?.draft);
    let attachments;
    try {
      attachments = await collectAttachments(req.user.sub, mail, backend, draft);
    } catch (err) {
      return mailFailed(res, account, err);
    }
    const wait = sendLimiter.hit(req.user.sub);
    if (wait) return tooMany(res, wait, '메일 보내기');

    const message = nodemailerMail(account, mail, attachments);
    let raw;
    try {
      raw = isLocalAccount(account) ? await sendFromLocal(account, message) : await sendViaSmtp(account, await credentialsOf(account), message);
    } catch (err) {
      if (err instanceof MailInputError || err?.code?.startsWith?.('OAUTH_')) return mailFailed(res, account, err);
      console.error('[webmail] 보내기 실패:', err?.code ?? '', err?.message ?? err);
      return res.status(502).json({ error: err?.code === 'EBLOCKED' ? err.message : describeSmtpError(err) });
    }
    // 보낸편지함·답장 표시·임시 저장본 지우기는 덧붙이는 일 — 실패해도 보내기는 성공.
    let savedToSent = !isLocalAccount(account) && autoSavesSent(account);
    try {
      if (!savedToSent) savedToSent = await backend.appendSent(raw);
      const answered = req.body?.answered;
      const folder = folderOf(answered?.folder);
      const uid = uidOf(answered?.uid);
      if (folder && uid && mail.inReplyTo) await backend.markAnswered(folder, uid).catch(() => {});
      if (draft) await backend.expunge(draft.folder, [draft.uid]);
    } catch (err) {
      console.error('[webmail] 보낸편지함 저장 실패:', err?.message ?? err);
    }
    const mine = (await listMailAccounts(req.user.sub)).map((a) => a.email);
    recordMailContacts(req.user.sub, contactsToRecord(mail, mine)).catch((err) => console.error('[webmail] 주소 기록 실패:', err?.message ?? err));
    res.status(201).json({ ok: true, savedToSent });
  });

  // ── 대화방·할 일로 보내기 ──

  /**
   * 메일의 첨부(·원문 .eml)를 내 업로드 파일로 옮긴다 `{ account?, folder, uid, attachments: [번호], eml?: true }` →
   * `{ files: [{ url, fileName, size, mimeType }] }` — 앱이 그 파일로 대화방에 보내거나 할 일에 붙인다(내가 올린 파일로 남는다). 10개·합계 50MB.
   */
  router.post(
    '/mail/export',
    withAccount(async (req, res, account, backend) => {
      const folder = folderOf(req.body?.folder);
      const uid = uidOf(req.body?.uid);
      const indexes = Array.isArray(req.body?.attachments) ? [...new Set(req.body.attachments)] : [];
      const eml = req.body?.eml === true;
      if (!folder || !uid || !indexes.every((i) => Number.isInteger(i) && i >= 0)) return res.status(400).json({ error: '메일을 확인하세요.' });
      if (indexes.length + (eml ? 1 : 0) === 0) return res.json({ files: [] });
      if (indexes.length + (eml ? 1 : 0) > EXPORT_FILES_MAX) return res.status(400).json({ error: `파일은 한 번에 ${EXPORT_FILES_MAX}개까지입니다.` });
      const wait = exportLimiter.hit(req.user.sub);
      if (wait) return tooMany(res, wait, '메일 보내기');
      const got = await backend.readMessage(folder, uid, { markSeen: false, withSource: eml });
      if (!got || got.tooLarge) return res.status(404).json({ error: '메일을 찾을 수 없습니다.' });
      const items = [];
      for (const index of indexes) {
        const a = got.parsed.attachments?.[index];
        if (!a) return res.status(404).json({ error: '첨부를 찾을 수 없습니다.' });
        items.push({ name: a.filename || `첨부${index + 1}`, content: a.content, mimeType: a.contentType || 'application/octet-stream' });
      }
      if (eml) {
        const base = String(got.parsed.subject || 'mail').replace(/[\\/:*?"<>|\r\n\t]+/g, ' ').trim().slice(0, 80) || 'mail';
        items.push({ name: `${base}.eml`, content: got.source, mimeType: 'message/rfc822' });
      }
      const total = items.reduce((s, i) => s + (i.content?.length ?? 0), 0);
      if (total > EXPORT_BYTES_MAX) return res.status(400).json({ error: '파일이 모두 합쳐 50MB를 넘습니다. 첨부를 덜 고르세요.' });
      if (!(await uploadsDirHasRoom(total))) return res.status(507).json({ error: '서버 저장 공간이 부족합니다. 관리자에게 알려 주세요.' });
      const { insertUpload } = await import('./db/queries/uploads.js');
      const files = [];
      for (const item of items) {
        const fileName = `${randomUUID()}${safeExt(item.name)}`;
        const diskPath = path.join(uploadsDir, fileName);
        await fs.writeFile(diskPath, item.content);
        try {
          await insertUpload({ fileName, uploaderId: req.user.sub });
        } catch (err) {
          await fs.unlink(diskPath).catch(() => {});
          throw err;
        }
        files.push({ url: `/uploads/${fileName}`, fileName: item.name, size: item.content.length, mimeType: item.mimeType });
      }
      recordUploadedBytes(req.user.sub, total);
      res.json({ files });
    }),
  );

  // ── 받는 규칙 ──

  /** 규칙 → 앱 모양. */
  const ruleDto = (r) => ({
    id: r.id,
    name: r.name,
    enabled: r.enabled,
    match: r.match,
    conditions: r.conditions,
    actions: r.actions,
    stop: r.stop,
  });

  router.get(
    '/mail/rules',
    withAccount(async (req, res, account) => {
      res.json({ rules: (await listMailRules(account.id)).map(ruleDto) });
    }),
  );

  /** 옮길 폴더가 그 계정에 있는지(없으면 400). */
  async function checkMoveTarget(values, backend) {
    if (values.actions.moveTo && !(await backend.folderExists(values.actions.moveTo))) throw new MailInputError('옮길 폴더가 없습니다.');
  }

  router.post(
    '/mail/rules',
    withAccount(async (req, res, account, backend) => {
      const parsed = parseRule(req.body);
      if (parsed.error) return res.status(400).json({ error: parsed.error });
      if ((await listMailRules(account.id)).length >= RULES_MAX) return res.status(400).json({ error: `받는 규칙은 계정마다 ${RULES_MAX}개까지입니다.` });
      await checkMoveTarget(parsed.values, backend);
      const { row } = await insertMailRule(req.user.sub, account.id, parsed.values);
      res.status(201).json({ rule: ruleDto(row) });
    }),
  );

  router.put('/mail/rules/:id', async (req, res) => {
    if (!isUuid(req.params.id)) return res.status(400).json({ error: '규칙을 확인하세요.' });
    const rule = await findMailRule(req.user.sub, req.params.id);
    if (!rule) return res.status(404).json({ error: '규칙을 찾을 수 없습니다.' });
    const account = await accountFor(req, res, rule.accountId);
    if (!account) return;
    const parsed = parseRule(req.body);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    try {
      await checkMoveTarget(parsed.values, mailBackend(account));
    } catch (err) {
      return mailFailed(res, account, err);
    }
    res.json({ rule: ruleDto(await updateMailRule(req.user.sub, rule.id, parsed.values)) });
  });

  router.delete('/mail/rules/:id', async (req, res) => {
    if (!isUuid(req.params.id)) return res.status(400).json({ error: '규칙을 확인하세요.' });
    if (!(await deleteMailRule(req.user.sub, req.params.id))) return res.status(404).json({ error: '규칙을 찾을 수 없습니다.' });
    res.json({ ok: true });
  });

  /** 규칙 차례 `{ account?, ids }` — 그 계정 규칙 전부를 원하는 차례로. */
  router.post(
    '/mail/rules/order',
    withAccount(async (req, res, account) => {
      const rules = await listMailRules(account.id);
      if (!isFullOrder(req.body?.ids, rules.map((r) => r.id))) return res.status(400).json({ error: '규칙 순서를 확인하세요.' });
      await reorderMailRules(account.id, req.body.ids);
      res.json({ rules: (await listMailRules(account.id)).map(ruleDto) });
    }),
  );

  /** 지금 받은편지함에 걸기 `{ account? }` — 최근 500통에. → `{ matched, moved }`. */
  router.post(
    '/mail/rules/apply',
    withAccount(async (req, res, account, backend) => {
      const rules = (await listMailRules(account.id)).filter((r) => r.enabled);
      if (!rules.length) return res.json({ matched: 0, moved: 0 });
      const envelopes = await backend.recent('INBOX', RULES_APPLY_MAX);
      const plan = planRules(rules, envelopes);
      for (const to of [...plan.moves.keys()]) if (to === 'INBOX' || !(await backend.folderExists(to))) plan.moves.delete(to);
      await backend.applyPlan('INBOX', plan);
      const moved = [...plan.moves.values()].reduce((s, l) => s + l.length, 0);
      res.json({ matched: plan.matched, moved });
    }),
  );

  return router;
}

// ── 새 메일 확인 ────────────────────────────────────────────────────────

const CHECK_INTERVAL_MS = 3 * 60 * 1000;
/** 로그인이 실패한 계정은 이만큼 쉬었다 다시 본다(잘못된 비밀번호로 메일 서버를 계속 두드리지 않게). */
const ERROR_BACKOFF_MS = 30 * 60 * 1000;
const CHECK_CONCURRENCY = 3;
/** 한 번 확인에 받는 규칙을 걸 새 메일 수 상한. */
const NEW_MESSAGES_MAX = 200;

/**
 * 바깥 메일 서버 계정 하나 확인 — 새 메일에 받는 규칙을 걸고, 알림을 켰으면 남은 새 메일을 소켓·푸시로 알린다. 알린 수.
 */
export async function checkMailAccount(io, account, now = new Date()) {
  try {
    const { status, envelopes } = await withImap(account, () => credentialsOf(account), async (client) => {
      const status = await inboxStatus(client);
      const count = newMailCount(account, status);
      const envelopes = count > 0 ? await newInboxMessages(client, account.lastUidNext, NEW_MESSAGES_MAX) : [];
      return { status, envelopes };
    });
    await updateMailAccount(account.id, {
      lastUidNext: status.uidNext ?? null,
      lastUidValidity: status.uidValidity,
      lastCheckedAt: now,
      lastError: null,
      lastErrorAt: null,
    });
    if (envelopes.length === 0) return 0;
    const plan = await applyRulesToNew(account, mailBackend(account), envelopes);
    const toNotify = mailsToNotify(envelopes, plan);
    // 규칙이 읽음으로 바꾸거나 옮긴 안 읽은 메일만큼 숫자를 뺀다.
    const touched = new Set([...plan.seen, ...[...plan.moves.values()].flat()]);
    const unseen = Math.max(0, status.unseen - envelopes.filter((m) => !m.seen && touched.has(m.uid)).length);
    if (!account.notify || toNotify.length === 0) {
      io?.to(`user:${account.userId}`).emit('mail:changed', { accountId: account.id, unseen });
      return 0;
    }
    return notifyNewMail(io, account, toNotify, unseen);
  } catch (err) {
    const message = err?.code === 'OAUTH_REVOKED' || err?.code === 'OAUTH_REFRESH' ? err.message : describeImapError(err);
    await updateMailAccount(account.id, { lastError: message, lastErrorAt: now }).catch(() => {});
    return 0;
  }
}

/** 확인할 계정을 모두 확인(오류가 난 지 30분이 안 된 계정은 건너뜀). 알린 수 합. */
export async function runMailChecks(io, now = new Date()) {
  const accounts = (await listCheckableMailAccounts()).filter(
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
