import { decryptField } from './crypto.js';
import { decodeJwtPayload, isTenantId, pkceChallenge, randomToken } from './ssoRules.js';
import { getWebPublicUrl } from './webAddress.js';
import { MAIL_PRESETS } from './webmailRules.js';

/**
 * 웹메일 OAuth 연결 — Gmail·Microsoft 365 계정을 앱 비밀번호 대신 그쪽 로그인으로 연결한다(IMAP·SMTP는 XOAUTH2 접근 토큰으로).
 * 클라이언트는 관리자 콘솔 "로그인 보안"의 Google·Microsoft 클라이언트(회사 계정 로그인과 같은 것)를 같이 쓰고, 관리자가 웹메일 쪽에서
 * 따로 켠다(server_settings.mailOauthGoogle·mailOauthMicrosoft). 그 클라이언트에 메일 권한을 더해야 한다 — Google은 범위
 * https://mail.google.com/(Gmail API 사용 설정), Microsoft는 Office 365 Exchange Online의 IMAP.AccessAsUser.All·SMTP.Send(위임).
 *
 * 흐름: 앱이 로그인한 채로 시작을 청하면(/api/mail/oauth/start) 그쪽 로그인 주소를 돌려주고, 앱은 그 주소를 브라우저로 열고 2초마다
 * 결과를 묻는다(/api/mail/oauth/poll — 시작한 사람만). 로그인이 끝나면 그쪽이 회사 계정 로그인과 **같은 돌아올 주소**(WEB_DOMAIN의
 * /auth/sso/callback — 관리자가 새 주소를 등록하지 않아도 되게)로 코드를 보내고, sso.js가 state를 보고 여기로 넘긴다(mailOAuthCallback).
 * 서버는 코드를 토큰(접근·갱신·ID 토큰)으로 바꾸고, ID 토큰의 이메일로 IMAP·SMTP 로그인을 해 본 뒤 계정을 저장한다(webmail.js가 넘긴
 * 완료 처리 — setMailOAuthCompleter). 진행 중인 연결은 서버 메모리에 10분까지만 둔다.
 *
 * 접근 토큰은 한 시간쯤이면 끝나므로 쓰기 전에 남은 시간이 2분 아래면 갱신 토큰으로 새로 받는다(oauthCredentials — 같은 계정의 갱신은
 * 한 번에 하나). 갱신 토큰이 막혔으면(비밀번호 변경·권한 취소 — invalid_grant) 계정에 "다시 로그인" 오류를 남긴다.
 */

export const MAIL_OAUTH_PROVIDERS = Object.freeze(['google', 'microsoft']);
const STATE_TTL_MS = 10 * 60 * 1000;
const REFRESH_EARLY_MS = 2 * 60 * 1000;

export const MAIL_OAUTH_SCOPES = Object.freeze({
  google: 'openid email profile https://mail.google.com/',
  microsoft: 'openid email profile offline_access https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send',
});

/** 제공자 → 미리 정한 메일 서비스(연결 값). */
export const MAIL_OAUTH_PRESET = Object.freeze({ google: 'gmail', microsoft: 'outlook' });

const LABEL = { google: 'Google', microsoft: 'Microsoft' };

let testHooks = { fetch: null, endpoints: null, redirectUri: null };
/** 시험용 — 가짜 fetch·그쪽 주소·돌아올 주소. */
export function __setMailOAuthTestHooks(next) {
  testHooks = { ...testHooks, ...next };
}
const fetchImpl = (...args) => (testHooks.fetch ?? fetch)(...args);

/** 그쪽 주소(로그인·토큰·발급자). */
export function mailOAuthEndpoints(provider, settings) {
  if (testHooks.endpoints?.[provider]) return testHooks.endpoints[provider];
  if (provider === 'google') {
    return {
      authorizeUrl: 'https://accounts.google.com/o/oauth2/v2/auth',
      tokenUrl: 'https://oauth2.googleapis.com/token',
      issuers: ['https://accounts.google.com', 'accounts.google.com'],
    };
  }
  const tenant = String(settings.ssoMicrosoftTenantId ?? '').trim().toLowerCase();
  return {
    authorizeUrl: `https://login.microsoftonline.com/${tenant}/oauth2/v2.0/authorize`,
    tokenUrl: `https://login.microsoftonline.com/${tenant}/oauth2/v2.0/token`,
    issuers: [`https://login.microsoftonline.com/${tenant}/v2.0`],
  };
}

const clientIdOf = (provider, s) => (provider === 'google' ? s.ssoGoogleClientId : s.ssoMicrosoftClientId);
const clientSecretOf = (provider, s) => decryptField(provider === 'google' ? s.ssoGoogleClientSecretEnc : s.ssoMicrosoftClientSecretEnc) ?? '';

/** 이 제공자로 메일을 연결할 수 없는 이유(관리자에게 보일 글) — 쓸 수 있으면 null. */
export function mailOAuthProblem(provider, s) {
  if (provider === 'google') {
    if (!s.mailOauthGoogle) return 'Google 로그인으로 메일 연결이 꺼져 있습니다.';
    if (!s.ssoGoogleClientId || !s.ssoGoogleClientSecretEnc) return '로그인 보안 탭에 Google 클라이언트 ID·보안 비밀을 먼저 넣으세요.';
    return null;
  }
  if (provider === 'microsoft') {
    if (!s.mailOauthMicrosoft) return 'Microsoft 로그인으로 메일 연결이 꺼져 있습니다.';
    if (!isTenantId(s.ssoMicrosoftTenantId) || !s.ssoMicrosoftClientId || !s.ssoMicrosoftClientSecretEnc) {
      return '로그인 보안 탭에 Microsoft 테넌트 ID·클라이언트 ID·클라이언트 암호를 먼저 넣으세요.';
    }
    return null;
  }
  return '알 수 없는 로그인입니다.';
}

/** 지금 메일 연결에 쓸 수 있는 제공자들(돌아올 주소도 있어야 함). */
export function mailOAuthProviders(s) {
  if (!mailOAuthRedirectUri()) return [];
  return MAIL_OAUTH_PROVIDERS.filter((p) => !mailOAuthProblem(p, s));
}

/** 돌아올 주소 — 회사 계정 로그인과 같은 곳(sso.js ssoRedirectUri). WEB_DOMAIN이 없으면 null. */
export function mailOAuthRedirectUri() {
  if (testHooks.redirectUri) return testHooks.redirectUri;
  const base = getWebPublicUrl();
  return base ? `${base.replace(/\/+$/, '')}/auth/sso/callback` : null;
}

/** 그쪽 로그인 주소. Google은 갱신 토큰을 받으려고 offline·consent. [loginHint]는 다시 로그인할 계정 주소. */
export function buildMailAuthorizeUrl({ provider, settings, redirectUri, state, nonce, codeChallenge, loginHint = null }) {
  const ep = mailOAuthEndpoints(provider, settings);
  const params = new URLSearchParams({
    client_id: clientIdOf(provider, settings),
    redirect_uri: redirectUri,
    response_type: 'code',
    scope: MAIL_OAUTH_SCOPES[provider],
    state,
    nonce,
    code_challenge: codeChallenge,
    code_challenge_method: 'S256',
  });
  if (provider === 'google') {
    params.set('access_type', 'offline');
    params.set('prompt', 'consent');
  } else {
    params.set('prompt', 'select_account');
  }
  if (loginHint) params.set('login_hint', loginHint);
  return `${ep.authorizeUrl}?${params.toString()}`;
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * 받은 ID 토큰 확인 → `{ email, name }` | `{ error }` — 대상(클라이언트 ID)·발급자·만료(5분 여유)·nonce. 토큰 주소에서 TLS로 바로
 * 받았으므로 서명 대신 TLS로 출처를 믿는다(ssoRules.js와 같은 이유). Google은 확인된 이메일만, Microsoft는 email이 없으면 로그인 이름.
 */
export function checkMailIdToken({ provider, settings, claims, nonce, nowMs = Date.now() }) {
  const ep = mailOAuthEndpoints(provider, settings);
  if (!claims) return { error: '로그인 결과를 읽지 못했습니다.' };
  const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!aud.includes(clientIdOf(provider, settings))) return { error: '다른 앱의 로그인 결과입니다.' };
  if (!ep.issuers.includes(claims.iss)) return { error: '로그인한 곳이 이 회사가 아닙니다.' };
  if (!(Number(claims.exp) * 1000 > nowMs - 5 * 60 * 1000)) return { error: '로그인 결과가 만료되었습니다. 다시 하세요.' };
  if (claims.nonce !== nonce) return { error: '로그인 확인 값이 맞지 않습니다. 다시 하세요.' };
  const email = String((provider === 'google' ? claims.email : (claims.email ?? claims.preferred_username)) ?? '').trim().toLowerCase();
  if (!EMAIL_RE.test(email)) return { error: '로그인한 계정의 메일 주소를 알 수 없습니다.' };
  if (provider === 'google' && claims.email_verified === false) return { error: '확인되지 않은 Google 메일 주소입니다.' };
  return { email, name: typeof claims.name === 'string' ? claims.name.slice(0, 50) : null };
}

/** 토큰 주소에 POST → `{ json, ok }` | `{ error }`. */
async function postToken(provider, settings, params) {
  const ep = mailOAuthEndpoints(provider, settings);
  let response;
  try {
    response = await fetchImpl(ep.tokenUrl, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' },
      body: new URLSearchParams({
        client_id: clientIdOf(provider, settings),
        client_secret: clientSecretOf(provider, settings),
        ...params,
      }).toString(),
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    return { error: `${LABEL[provider]}에 연결하지 못했습니다. 서버의 인터넷 연결을 확인하세요.` };
  }
  const json = await response.json().catch(() => null);
  return { ok: response.ok, json };
}

/** 토큰 응답 → 저장할 값 `{ accessToken, refreshToken, expiresAt }`. */
const tokensOf = (json, now) => ({
  accessToken: json.access_token,
  refreshToken: json.refresh_token ?? null,
  expiresAt: new Date(now + Math.max(60, Number(json.expires_in) || 3600) * 1000),
});

/** 코드 → 토큰 + ID 토큰 내용. `{ tokens, claims }` | `{ error }`. */
export async function exchangeMailCode({ provider, settings, code, verifier, redirectUri, now = Date.now() }) {
  const got = await postToken(provider, settings, { grant_type: 'authorization_code', code, redirect_uri: redirectUri, code_verifier: verifier });
  if (got.error) return got;
  if (!got.ok || !got.json?.access_token) {
    const why = got.json?.error ? ` (${String(got.json.error).slice(0, 60)})` : '';
    return { error: `${LABEL[provider]} 로그인 확인에 실패했습니다${why}. 관리자에게 메일 권한 설정을 확인해 달라고 하세요.` };
  }
  if (!got.json.refresh_token) {
    return { error: `${LABEL[provider]}가 갱신 토큰을 주지 않았습니다. 다시 시도하세요(Microsoft는 offline_access 권한이 필요합니다).` };
  }
  return { tokens: tokensOf(got.json, now), claims: decodeJwtPayload(got.json.id_token) };
}

/** 갱신 토큰 → 새 토큰. `{ tokens }` | `{ error, revoked }`(revoked — 다시 로그인해야 함). */
export async function refreshMailToken({ provider, settings, refreshToken, now = Date.now() }) {
  const got = await postToken(provider, settings, {
    grant_type: 'refresh_token',
    refresh_token: refreshToken,
    ...(provider === 'microsoft' ? { scope: MAIL_OAUTH_SCOPES.microsoft } : {}),
  });
  if (got.error) return got;
  if (!got.ok || !got.json?.access_token) {
    const revoked = got.json?.error === 'invalid_grant';
    return {
      revoked,
      error: revoked
        ? `${LABEL[provider]} 로그인이 끝났거나 권한이 취소되었습니다. 메일 → 계정 바꾸기에서 다시 로그인하세요.`
        : `${LABEL[provider]}에서 새 접근 토큰을 받지 못했습니다.`,
    };
  }
  return { tokens: tokensOf(got.json, now) };
}

// ── 접근 토큰 ──

/** 계정 id → 진행 중인 갱신(같은 계정의 갱신은 한 번에 하나). */
const refreshing = new Map();

/**
 * OAuth 계정의 로그인 값 `{ accessToken }` — 저장된 접근 토큰이 2분 넘게 남았으면 그것, 아니면 갱신해 [save](patch)로 남기고 새 것.
 * 갱신하지 못하면 오류(authenticationFailed — 화면이 "계정 바꾸기"를 띄운다).
 */
export async function oauthCredentials(account, { settings, save, now = Date.now() }) {
  const expires = account.oauthExpiresAt ? new Date(account.oauthExpiresAt).getTime() : 0;
  const access = decryptField(account.oauthAccessEnc);
  if (access && expires - now > REFRESH_EARLY_MS) return { accessToken: access };
  let job = refreshing.get(account.id);
  if (!job) {
    job = (async () => {
      const refreshToken = decryptField(account.oauthRefreshEnc);
      if (!refreshToken) return { error: '다시 로그인해야 합니다.', revoked: true };
      return refreshMailToken({ provider: account.oauthProvider, settings, refreshToken, now });
    })();
    refreshing.set(account.id, job);
    job.finally(() => refreshing.delete(account.id)).catch(() => {});
  }
  const result = await job;
  if (result.error) {
    const err = new Error(result.error);
    err.authenticationFailed = !!result.revoked;
    err.responseText = result.error;
    err.code = result.revoked ? 'OAUTH_REVOKED' : 'OAUTH_REFRESH';
    throw err;
  }
  await save(result.tokens);
  return { accessToken: result.tokens.accessToken };
}

// ── 연결 흐름 ──

/** state → { userId, provider, accountId, nonce, verifier, createdAt, outcome } */
const pending = new Map();
setInterval(() => {
  const now = Date.now();
  for (const [state, entry] of pending) if (now - entry.createdAt > STATE_TTL_MS) pending.delete(state);
}, 60 * 1000).unref();

/** 완료 처리 — webmail.js가 넣는다: ({ userId, provider, accountId, email, name, tokens }) → `{ account }` | `{ error }`. */
let completer = async () => ({ error: '서버가 아직 준비되지 않았습니다.' });
export function setMailOAuthCompleter(fn) {
  completer = fn;
}

/**
 * 시작 → `{ state, authUrl, expiresInSeconds }` | `{ error, status }`. [accountId]면 그 OAuth 계정을 다시 로그인(토큰만 바꿈).
 */
export function startMailOAuth({ userId, provider, settings, accountId = null, loginHint = null }) {
  if (!MAIL_OAUTH_PROVIDERS.includes(provider)) return { status: 400, error: '알 수 없는 로그인입니다.' };
  const redirectUri = mailOAuthRedirectUri();
  if (!redirectUri) return { status: 503, error: '서버의 웹 앱 주소(정식 인증서 — WEB_DOMAIN)가 없어 OAuth로 연결할 수 없습니다.' };
  const problem = mailOAuthProblem(provider, settings);
  if (problem) return { status: 400, error: problem };
  const state = randomToken();
  const nonce = randomToken();
  const verifier = randomToken(48);
  pending.set(state, { userId, provider, accountId, nonce, verifier, createdAt: Date.now(), outcome: null });
  const authUrl = buildMailAuthorizeUrl({ provider, settings, redirectUri, state, nonce, codeChallenge: pkceChallenge(verifier), loginHint });
  return { state, authUrl, expiresInSeconds: Math.round(STATE_TTL_MS / 1000) };
}

/** 이 state가 메일 연결 것인지(sso.js 콜백이 나눠 보낼 때). */
export const isMailOAuthState = (state) => typeof state === 'string' && pending.has(state);

/**
 * 돌아온 곳(sso.js /auth/sso/callback이 넘김) — 코드를 토큰으로 바꾸고 계정을 저장한다. 브라우저에 보일 쪽지 `{ ok, title, message }`.
 */
export async function mailOAuthCallback(query, settings) {
  const entry = pending.get(query.state);
  if (!entry || Date.now() - entry.createdAt > STATE_TTL_MS || entry.outcome) {
    return { ok: false, title: '메일 계정 연결을 이어 갈 수 없습니다', message: '시간이 지났습니다. 앱에서 처음부터 다시 하세요.' };
  }
  const fail = (error, title = '메일 계정을 연결하지 못했습니다') => {
    entry.outcome = { status: 'error', error };
    return { ok: false, title, message: error };
  };
  if (typeof query.error === 'string') return fail('로그인을 취소했거나 메일 권한을 허용하지 않았습니다.', '연결하지 않았습니다');
  const code = typeof query.code === 'string' ? query.code : '';
  if (!code) return fail('로그인한 곳이 코드를 보내지 않았습니다.');
  const exchanged = await exchangeMailCode({
    provider: entry.provider,
    settings,
    code,
    verifier: entry.verifier,
    redirectUri: mailOAuthRedirectUri(),
  });
  if (exchanged.error) return fail(exchanged.error);
  const who = checkMailIdToken({ provider: entry.provider, settings, claims: exchanged.claims, nonce: entry.nonce });
  if (who.error) return fail(who.error);
  let done;
  try {
    done = await completer({ userId: entry.userId, provider: entry.provider, accountId: entry.accountId, email: who.email, name: who.name, tokens: exchanged.tokens });
  } catch (err) {
    console.error('[webmail] OAuth 연결 저장 실패:', err?.message ?? err);
    done = { error: '메일 계정을 저장하지 못했습니다.' };
  }
  if (done.error) return fail(done.error);
  entry.outcome = { status: 'done', account: done.account };
  return { ok: true, title: '메일 계정을 연결했습니다', message: `${who.email} — TangoTalk 앱으로 돌아가세요. 이 창은 닫아도 됩니다.` };
}

/** 결과 묻기 — 시작한 사람만. `{ status: 'pending' }` | `{ status: 'done', account }` | `{ status: 'error', error }`(끝난 결과는 한 번만). */
export function pollMailOAuth(state, userId) {
  const entry = typeof state === 'string' ? pending.get(state) : null;
  if (!entry || entry.userId !== userId || Date.now() - entry.createdAt > STATE_TTL_MS) {
    return { status: 'error', error: '시간이 지났습니다. 처음부터 다시 하세요.' };
  }
  if (!entry.outcome) return { status: 'pending' };
  pending.delete(state);
  return entry.outcome;
}

/** OAuth 계정의 연결 값(미리 정한 서비스 그대로). */
export function oauthEndpointsOf(provider) {
  const preset = MAIL_PRESETS[MAIL_OAUTH_PRESET[provider]];
  return {
    provider: MAIL_OAUTH_PRESET[provider],
    imapHost: preset.imap.host,
    imapPort: preset.imap.port,
    imapSecurity: preset.imap.security,
    smtpHost: preset.smtp.host,
    smtpPort: preset.smtp.port,
    smtpSecurity: preset.smtp.security,
  };
}
