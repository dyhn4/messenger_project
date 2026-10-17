import crypto from 'node:crypto';
import { Router } from 'express';
import { accessPayload, issueTokenPair } from './auth.js';
import { limits, rateLimit } from './authGuard.js';
import { decryptField, encryptField, lookupHash } from './crypto.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import {
  findIdentity,
  linkIdentity,
  listIdentitiesForUser,
  touchIdentity,
  unlinkIdentity,
} from './db/queries/userIdentities.js';
import { findUserByEmailLookup, findUserById } from './db/queries/users.js';
import { checkEmailCode, consumeEmailCode, issueEmailCode } from './emailCodes.js';
import { provisionExternalUser } from './loginSecurity.js';
import { mailReady, maskEmail } from './mailRules.js';
import {
  buildAuthorizeUrl,
  clientIdOf,
  decodeJwtPayload,
  enabledSsoProviders,
  isPkceValue,
  pkceChallenge,
  providerEndpoints,
  randomToken,
  SSO_PROVIDER_LABEL,
  SSO_PROVIDERS,
  validateIdTokenClaims,
} from './ssoRules.js';
import { getWebPublicUrl } from './webAddress.js';

/**
 * 회사 계정 로그인(SSO — Google·Microsoft). 규칙은 ssoRules.js.
 *
 * 앱(PC·안드로이드·아이폰·웹)이 모두 같은 길을 쓴다 — 앱이 고른 무작위 검증값의 해시(challenge)와 함께 시작을 청하면(/auth/sso/start)
 * 서버가 그쪽 로그인 주소를 돌려주고, 앱은 그 주소를 브라우저로 연 채 2초마다 결과를 묻는다(/auth/sso/poll — 검증값 원문을 같이
 * 보내야 해서, 주소를 엿본 다른 사람은 결과를 못 가져간다). 브라우저에서 로그인이 끝나면 그쪽이 서버의 돌아올 주소
 * (웹 앱 주소 WEB_DOMAIN의 /auth/sso/callback — Google·Microsoft는 https 주소만 받는다)로 코드를 보내고, 서버가 코드를 ID 토큰으로
 * 바꿔 확인한 뒤 결과를 기다리던 앱에 넘긴다. 진행 중인 로그인은 서버 메모리에 10분까지만 둔다(서버가 다시 켜지면 처음부터).
 *
 * 계정 고르기: 이미 연결된 회사 계정이면 그 사람. 아니면 회사 계정의 이메일과 같은 이메일의 계정이 있을 때 — 남의 계정을 가로채지
 * 못하게 그 이메일로 확인 코드를 보내 넣어야 연결한다(메일이 꺼진 서버면 아이디로 로그인한 뒤 내 프로필에서 연결). 둘 다 아니면
 * 관리자가 자동 생성을 켰을 때만 계정을 만든다. 회사 계정의 2단계 인증을 쓰므로 이 앱의 2단계 인증은 묻지 않는다.
 */

const STATE_TTL_MS = 10 * 60 * 1000;
const pending = new Map(); // state → { provider, mode, linkUserId, appChallenge, nonce, idpVerifier, createdAt, outcome }

setInterval(() => {
  const now = Date.now();
  for (const [state, entry] of pending) if (now - entry.createdAt > STATE_TTL_MS) pending.delete(state);
}, 60 * 1000).unref();

/** 그쪽이 로그인 뒤 돌아올 이 서버 주소 — 웹 앱 주소(WEB_DOMAIN, 정식 인증서)가 있어야 한다. 없으면 null. */
export function ssoRedirectUri() {
  const base = getWebPublicUrl();
  return base ? `${base.replace(/\/+$/, '')}/auth/sso/callback` : null;
}

const escapeHtml = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

/** 브라우저에 보일 결과 쪽지 — 앱이 알아서 이어 가므로 창만 닫으면 된다. */
function resultPage(res, { ok, title, message, status = 200 }) {
  res
    .status(status)
    .type('html')
    .send(
      `<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">` +
        `<title>TangoTalk</title><style>body{font-family:system-ui,sans-serif;display:flex;min-height:90vh;align-items:center;` +
        `justify-content:center;background:#f5f7fb;color:#222;margin:0}main{max-width:420px;padding:32px;background:#fff;border-radius:16px;` +
        `box-shadow:0 4px 24px #0001;text-align:center}h1{font-size:20px;color:${ok ? '#2b8a3e' : '#c92a2a'}}p{line-height:1.6}</style></head>` +
        `<body><main><h1>${escapeHtml(title)}</h1><p>${escapeHtml(message)}</p></main></body></html>`,
    );
}

/** 코드를 ID 토큰으로 바꾼다 → claims | `{ error }`. */
async function exchangeCode({ provider, settings, code, entry, redirectUri, endpoints, fetchImpl }) {
  const ep = endpoints ?? providerEndpoints(provider, settings);
  const secretEnc = provider === 'google' ? settings.ssoGoogleClientSecretEnc : settings.ssoMicrosoftClientSecretEnc;
  const body = new URLSearchParams({
    grant_type: 'authorization_code',
    code,
    redirect_uri: redirectUri,
    client_id: clientIdOf(provider, settings),
    client_secret: decryptField(secretEnc) ?? '',
    code_verifier: entry.idpVerifier,
  });
  let response;
  try {
    response = await fetchImpl(ep.tokenUrl, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' },
      body: body.toString(),
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    return { error: `${SSO_PROVIDER_LABEL[provider]}에 연결하지 못했습니다. 서버의 인터넷 연결을 확인하세요.` };
  }
  const json = await response.json().catch(() => null);
  if (!response.ok || !json?.id_token) {
    // 흔한 원인 — 클라이언트 보안 비밀이 틀렸거나 만료(invalid_client), 돌아올 주소가 등록과 다름(redirect_uri_mismatch).
    const why = json?.error ? ` (${String(json.error).slice(0, 60)})` : '';
    return { error: `${SSO_PROVIDER_LABEL[provider]} 로그인 확인에 실패했습니다${why}. 관리자에게 설정을 확인해 달라고 하세요.` };
  }
  return { claims: decodeJwtPayload(json.id_token) };
}

/** 로그인 결과 정하기 — 위 "계정 고르기". */
async function resolveLogin({ provider, identity, settings }) {
  const linked = await findIdentity(provider, identity.subject);
  if (linked) {
    await touchIdentity(linked.id);
    return { type: 'login', userId: linked.userId };
  }
  if (identity.email) {
    const existing = await findUserByEmailLookup(lookupHash(identity.email));
    if (existing && !existing.deletedAt) {
      return { type: 'link_required', userId: existing.id, email: identity.email, identity };
    }
  }
  if (!settings.ssoAutoCreate) {
    return {
      type: 'error',
      error:
        '이 회사 계정에 연결된 TangoTalk 계정이 없습니다. 아이디로 로그인한 뒤 내 프로필의 "연결된 회사 계정"에서 연결하거나, 관리자에게 문의하세요.',
    };
  }
  const made = await provisionExternalUser({
    usernameHint: null,
    email: identity.email,
    name: identity.name,
    role: settings.ssoDefaultRole ?? 'member',
    authSource: 'sso',
  });
  if (made.error) return { type: 'error', error: made.error };
  const row = await linkIdentity({
    userId: made.user.id,
    provider,
    subject: identity.subject,
    emailEnc: identity.email ? encryptField(identity.email) : null,
  });
  if (!row) return { type: 'error', error: '이 회사 계정은 이미 다른 계정에 연결되어 있습니다.' };
  return { type: 'login', userId: made.user.id };
}

/** 내 프로필에서 연결하기(로그인한 사람에게 잇기). */
async function resolveLink({ provider, identity, userId }) {
  const linked = await findIdentity(provider, identity.subject);
  if (linked && linked.userId !== userId) {
    return { type: 'error', error: '이 회사 계정은 이미 다른 TangoTalk 계정에 연결되어 있습니다.' };
  }
  const row = await linkIdentity({
    userId,
    provider,
    subject: identity.subject,
    emailEnc: identity.email ? encryptField(identity.email) : null,
  });
  if (!row) return { type: 'error', error: '이 회사 계정은 이미 다른 TangoTalk 계정에 연결되어 있습니다.' };
  return { type: 'linked', provider };
}

/** 쓸 수 있는 계정인지 — 아니면 그 이유. */
const unusableText = (user) =>
  !user ? '계정을 찾을 수 없습니다.' : user.deletedAt ? '탈퇴한 계정입니다.' : user.suspendedAt ? '정지된 계정입니다. 서버 운영자에게 문의하세요.' : null;

/** 진행 중인 로그인 + 앱의 검증값 확인 → entry | null. */
function entryFor(state, verifier) {
  if (typeof state !== 'string' || !isPkceValue(verifier)) return null;
  const entry = pending.get(state);
  if (!entry || Date.now() - entry.createdAt > STATE_TTL_MS) return null;
  const a = Buffer.from(pkceChallenge(verifier));
  const b = Buffer.from(entry.appChallenge);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  return entry;
}

const EXPIRED = '회사 계정 로그인 시간이 지났습니다. 처음부터 다시 하세요.';

/**
 * [options] — 시험용: endpoints(제공자별 { authorizeUrl, tokenUrl, issuers }), fetchImpl, redirectUri(돌아올 주소를 정해 둠).
 */
export function createSsoRouter({ endpoints = null, fetchImpl = fetch, redirectUri = null } = {}) {
  const router = Router();
  const redirectOf = () => redirectUri ?? ssoRedirectUri();

  /** 시작 — `{ provider, challenge, mode?: 'login'|'link' }` → `{ state, authUrl, expiresInSeconds }`. 연결(link)은 로그인한 사람만. */
  router.post('/sso/start', rateLimit(limits.ssoStartIp, '회사 계정 로그인 시도'), async (req, res) => {
    const { provider, challenge, mode = 'login' } = req.body ?? {};
    const settings = await getServerSettings();
    if (!SSO_PROVIDERS.includes(provider) || !enabledSsoProviders(settings).includes(provider)) {
      return res.status(400).json({ error: '이 서버에서 쓸 수 없는 회사 계정 로그인입니다.' });
    }
    const redirect = redirectOf();
    if (!redirect) {
      return res.status(503).json({ error: '서버의 웹 앱 주소(정식 인증서 — WEB_DOMAIN)가 없어 회사 계정 로그인을 쓸 수 없습니다.' });
    }
    if (!isPkceValue(challenge)) return res.status(400).json({ error: '앱을 최신 버전으로 업데이트하세요.' });
    if (mode !== 'login' && mode !== 'link') return res.status(400).json({ error: '알 수 없는 요청입니다.' });
    let linkUserId = null;
    if (mode === 'link') {
      const payload = await accessPayload(req);
      if (!payload) return res.status(401).json({ error: '토큰이 유효하지 않습니다.' });
      linkUserId = payload.sub;
    }
    const state = randomToken();
    const nonce = randomToken();
    const idpVerifier = randomToken(48);
    pending.set(state, { provider, mode, linkUserId, appChallenge: challenge, nonce, idpVerifier, createdAt: Date.now(), outcome: null });
    const authUrl = buildAuthorizeUrl({
      provider,
      settings,
      redirectUri: redirect,
      state,
      nonce,
      codeChallenge: pkceChallenge(idpVerifier),
      endpoints: endpoints?.[provider],
    });
    res.json({ state, authUrl, expiresInSeconds: Math.round(STATE_TTL_MS / 1000) });
  });

  /** 그쪽이 돌려보내는 곳(브라우저) — 코드를 확인해 결과를 정하고, 브라우저에는 "앱으로 돌아가세요" 쪽지. */
  router.get('/sso/callback', async (req, res) => {
    const state = typeof req.query.state === 'string' ? req.query.state : '';
    const entry = pending.get(state);
    if (!entry || Date.now() - entry.createdAt > STATE_TTL_MS || entry.outcome) {
      return resultPage(res, { ok: false, status: 400, title: '로그인을 이어 갈 수 없습니다', message: EXPIRED });
    }
    if (typeof req.query.error === 'string') {
      entry.outcome = { type: 'error', error: '회사 계정 로그인을 취소했거나 허용하지 않았습니다.' };
      return resultPage(res, { ok: false, title: '로그인하지 않았습니다', message: '앱으로 돌아가 다시 시도하세요.' });
    }
    const code = typeof req.query.code === 'string' ? req.query.code : '';
    const settings = await getServerSettings();
    const exchanged = code
      ? await exchangeCode({
          provider: entry.provider,
          settings,
          code,
          entry,
          redirectUri: redirectOf(),
          endpoints: endpoints?.[entry.provider],
          fetchImpl,
        })
      : { error: '회사 계정이 코드를 보내지 않았습니다.' };
    const checked = exchanged.error
      ? exchanged
      : validateIdTokenClaims({
          provider: entry.provider,
          settings,
          claims: exchanged.claims,
          nonce: entry.nonce,
          endpoints: endpoints?.[entry.provider],
        });
    if (checked.error) {
      entry.outcome = { type: 'error', error: checked.error };
      return resultPage(res, { ok: false, title: '로그인하지 못했습니다', message: checked.error });
    }
    entry.outcome =
      entry.mode === 'link'
        ? await resolveLink({ provider: entry.provider, identity: checked.identity, userId: entry.linkUserId })
        : await resolveLogin({ provider: entry.provider, identity: checked.identity, settings });
    if (entry.outcome.type === 'error') {
      return resultPage(res, { ok: false, title: '로그인하지 못했습니다', message: entry.outcome.error });
    }
    return resultPage(res, {
      ok: true,
      title: entry.mode === 'link' ? '회사 계정을 연결했습니다' : '회사 계정을 확인했습니다',
      message:
        entry.outcome.type === 'link_required'
          ? 'TangoTalk 앱으로 돌아가 이메일 확인을 마치세요. 이 창은 닫아도 됩니다.'
          : 'TangoTalk 앱으로 돌아가세요. 이 창은 닫아도 됩니다.',
    });
  });

  /**
   * 결과 묻기 — `{ state, verifier }` → `{ status: 'pending' }` | `{ status: 'done', accessToken, … }` | `{ status: 'linked', provider }` |
   * `{ status: 'link_required', email(일부만), canEmail }` | `{ status: 'error', error }`. 토큰은 한 번만 준다.
   */
  router.post('/sso/poll', rateLimit(limits.ssoPollIp, '회사 계정 로그인 확인'), async (req, res) => {
    const entry = entryFor(req.body?.state, req.body?.verifier);
    if (!entry) return res.status(400).json({ status: 'error', error: EXPIRED });
    const outcome = entry.outcome;
    if (!outcome) return res.json({ status: 'pending' });
    if (outcome.type === 'link_required') {
      const settings = await getServerSettings();
      return res.json({ status: 'link_required', email: maskEmail(outcome.email), canEmail: mailReady(settings) });
    }
    pending.delete(req.body.state);
    if (outcome.type === 'error') return res.json({ status: 'error', error: outcome.error });
    if (outcome.type === 'linked') return res.json({ status: 'linked', provider: outcome.provider });
    const user = await findUserById(outcome.userId);
    const why = unusableText(user);
    if (why) return res.json({ status: 'error', error: why });
    res.json({ status: 'done', ...issueTokenPair(user), userId: user.id, username: user.username });
  });

  /** 연결 확인 코드 보내기 — 같은 이메일의 기존 계정에 잇기 전에 그 이메일로. */
  router.post('/sso/link/send', async (req, res) => {
    const entry = entryFor(req.body?.state, req.body?.verifier);
    if (!entry || entry.outcome?.type !== 'link_required') return res.status(400).json({ error: EXPIRED });
    if (!mailReady(await getServerSettings())) {
      return res.status(503).json({ error: '서버의 메일 기능이 꺼져 있습니다. 아이디로 로그인한 뒤 내 프로필에서 연결하세요.' });
    }
    const { email, userId } = entry.outcome;
    const sent = await issueEmailCode(res, { purpose: 'link', email, userId });
    if (!sent) return;
    res.json({ email: maskEmail(email), ...sent });
  });

  /** 연결 확인 코드 넣기 → 잇고 로그인(토큰). */
  router.post('/sso/link/verify', async (req, res) => {
    const entry = entryFor(req.body?.state, req.body?.verifier);
    if (!entry || entry.outcome?.type !== 'link_required') return res.status(400).json({ error: EXPIRED });
    const { email, userId, identity } = entry.outcome;
    const checked = await checkEmailCode({ purpose: 'link', email, userId, code: req.body?.code });
    if (!checked.ok) return res.status(400).json({ error: checked.error });
    if (!(await consumeEmailCode(checked.row))) {
      return res.status(400).json({ error: '확인 코드가 없거나 만료되었습니다. 코드를 다시 받으세요.' });
    }
    const user = await findUserById(userId);
    const why = unusableText(user);
    if (why) return res.status(403).json({ error: why });
    const row = await linkIdentity({ userId, provider: entry.provider, subject: identity.subject, emailEnc: encryptField(email) });
    if (!row) return res.status(409).json({ error: '이 회사 계정은 이미 다른 TangoTalk 계정에 연결되어 있습니다.' });
    pending.delete(req.body.state);
    res.json({ status: 'done', ...issueTokenPair(user), userId: user.id, username: user.username });
  });

  /** 내 연결된 로그인(회사 계정·디렉터리)과 이 서버에서 쓸 수 있는 회사 계정. */
  router.get('/identities', async (req, res) => {
    const payload = await accessPayload(req);
    if (!payload) return res.status(401).json({ error: '토큰이 유효하지 않습니다.' });
    const settings = await getServerSettings();
    const rows = await listIdentitiesForUser(payload.sub);
    res.json({
      identities: rows.map((r) => ({
        provider: r.provider,
        email: r.emailEnc ? decryptField(r.emailEnc) : null,
        createdAt: new Date(r.createdAt).getTime(),
        lastLoginAt: r.lastLoginAt ? new Date(r.lastLoginAt).getTime() : null,
      })),
      available: redirectOf() ? enabledSsoProviders(settings) : [],
    });
  });

  /** 회사 계정 연결 끊기 — 회사 계정으로만 들어오는 계정의 마지막 연결은 끊을 수 없다(못 들어오게 된다). 디렉터리 연결은 관리자만. */
  router.delete('/identities/:provider', async (req, res) => {
    const payload = await accessPayload(req);
    if (!payload) return res.status(401).json({ error: '토큰이 유효하지 않습니다.' });
    const provider = req.params.provider;
    if (!SSO_PROVIDERS.includes(provider)) return res.status(400).json({ error: '끊을 수 없는 연결입니다.' });
    const user = await findUserById(payload.sub);
    if (!user) return res.status(404).json({ error: '계정을 찾을 수 없습니다.' });
    if (user.authSource === 'sso') {
      const others = (await listIdentitiesForUser(user.id)).filter((r) => r.provider !== provider && SSO_PROVIDERS.includes(r.provider));
      if (others.length === 0) {
        return res.status(400).json({ error: '회사 계정으로만 로그인하는 계정이라 마지막 연결은 끊을 수 없습니다.' });
      }
    }
    await unlinkIdentity(user.id, provider);
    res.json({ ok: true });
  });

  return router;
}
