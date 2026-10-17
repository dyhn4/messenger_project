import crypto from 'node:crypto';

/**
 * 회사 계정 로그인(SSO — Google·Microsoft, OAuth 2.0 / OpenID Connect)의 **순수 규칙** — 주소 만들기와 받은 ID 토큰 확인.
 * 네트워크·DB는 sso.js가 한다. `node --test`로 시험한다(test/loginSecurity.test.js).
 *
 * 흐름(sso.js): 앱이 서버에 시작을 청하면 서버가 그쪽 로그인 주소를 만들어 주고(앱은 브라우저로 연다), 로그인이 끝나면 그쪽이
 * 서버의 돌아올 주소(WEB_DOMAIN의 /auth/sso/callback)로 코드를 보낸다. 서버는 그 코드를 그쪽 토큰 주소에서 직접(TLS) ID 토큰으로
 * 바꾸고, 여기 규칙으로 발급자·대상(클라이언트 ID)·만료·nonce·회사(도메인/테넌트)를 확인한다. ID 토큰을 토큰 주소에서 TLS로 바로
 * 받았으므로 서명 대신 TLS 서버 확인으로 출처를 믿는다(OpenID Connect Core 3.1.3.7 6번).
 */

export const SSO_PROVIDERS = Object.freeze(['google', 'microsoft']);
export const SSO_PROVIDER_LABEL = Object.freeze({ google: 'Google', microsoft: 'Microsoft' });

/** Microsoft 테넌트 ID — 디렉터리(테넌트) ID GUID만 받는다('common' 등 아무 회사나 들어오는 값은 안 됨). */
const GUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DOMAIN_RE = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/i;

export const isTenantId = (v) => typeof v === 'string' && GUID_RE.test(v.trim());
export const isDomainName = (v) => typeof v === 'string' && DOMAIN_RE.test(v.trim());

/** "a.com, b.co.kr" → ['a.com', 'b.co.kr'](소문자, 빈 것 빼고). */
export function parseDomainList(text) {
  return String(text ?? '')
    .split(/[\s,;]+/)
    .map((d) => d.trim().toLowerCase())
    .filter(Boolean);
}

/** 그쪽 주소들 — 시험에서는 [override]로 가짜 서버를 가리키게 한다. */
export function providerEndpoints(provider, settings, override = null) {
  if (override?.[provider]) return override[provider];
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

/** 이 제공자를 켤 수 있을 만큼 값이 다 있는지 — 없으면 무엇이 빠졌는지 글, 다 있으면 null. */
export function ssoConfigProblem(provider, settings) {
  if (provider === 'google') {
    if (!settings.ssoGoogleClientId) return '클라이언트 ID를 넣으세요.';
    if (!settings.ssoGoogleClientSecretEnc) return '클라이언트 보안 비밀을 넣으세요.';
    if (parseDomainList(settings.ssoGoogleDomains).length === 0) {
      return '받아들일 회사 도메인(Google Workspace)을 넣으세요 — 없으면 아무 Gmail 계정으로나 들어올 수 있습니다.';
    }
    return null;
  }
  if (provider === 'microsoft') {
    if (!isTenantId(settings.ssoMicrosoftTenantId)) return '디렉터리(테넌트) ID(GUID)를 넣으세요.';
    if (!settings.ssoMicrosoftClientId) return '애플리케이션(클라이언트) ID를 넣으세요.';
    if (!settings.ssoMicrosoftClientSecretEnc) return '클라이언트 암호를 넣으세요.';
    return null;
  }
  return '알 수 없는 로그인 방법입니다.';
}

/** 지금 쓸 수 있는(켜져 있고 값이 다 있는) 제공자들. */
export function enabledSsoProviders(settings) {
  return SSO_PROVIDERS.filter(
    (p) => (p === 'google' ? settings.ssoGoogleEnabled : settings.ssoMicrosoftEnabled) && !ssoConfigProblem(p, settings),
  );
}

export const clientIdOf = (provider, settings) =>
  provider === 'google' ? settings.ssoGoogleClientId : settings.ssoMicrosoftClientId;

/** 무작위 글자(base64url) — state·nonce·PKCE 검증값. */
export function randomToken(bytes = 32, randomBytes = crypto.randomBytes) {
  return randomBytes(bytes).toString('base64url');
}

/** PKCE S256 — base64url(sha256(verifier)). */
export function pkceChallenge(verifier) {
  return crypto.createHash('sha256').update(String(verifier)).digest('base64url');
}

/** 앱이 보낸 PKCE 값 모양(43~128자 base64url — RFC 7636). */
export const isPkceValue = (v) => typeof v === 'string' && /^[A-Za-z0-9_-]{43,128}$/.test(v);

/** 그쪽 로그인 주소 — 사용자가 브라우저에서 여는 곳. */
export function buildAuthorizeUrl({ provider, settings, redirectUri, state, nonce, codeChallenge, endpoints }) {
  const ep = endpoints ?? providerEndpoints(provider, settings);
  const params = new URLSearchParams({
    client_id: clientIdOf(provider, settings),
    redirect_uri: redirectUri,
    response_type: 'code',
    scope: 'openid email profile',
    state,
    nonce,
    code_challenge: codeChallenge,
    code_challenge_method: 'S256',
    prompt: 'select_account',
  });
  if (provider === 'google') {
    const domains = parseDomainList(settings.ssoGoogleDomains);
    // 도메인이 하나면 그 회사 계정만 고르게 힌트를 준다(확인은 아래 claims의 hd로 다시 한다).
    if (domains.length === 1) params.set('hd', domains[0]);
  }
  return `${ep.authorizeUrl}?${params.toString()}`;
}

/** JWT 가운데(payload)를 읽는다 — 서명은 보지 않는다(위 설명). 모양이 틀리면 null. */
export function decodeJwtPayload(token) {
  if (typeof token !== 'string') return null;
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  try {
    const json = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
    return json && typeof json === 'object' ? json : null;
  } catch {
    return null;
  }
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * 받은 ID 토큰의 내용(claims) 확인 → `{ identity: { subject, email, name } }` | `{ error }`. 발급자·대상·만료(5분 여유)·nonce,
 * Google은 회사 도메인(hd)과 이메일 확인 여부, Microsoft는 테넌트(tid)를 본다. [subject]는 그쪽이 바꾸지 않는 값 — Google sub,
 * Microsoft는 테넌트+oid(앱마다 달라지는 sub 대신 사람마다 같은 oid).
 */
export function validateIdTokenClaims({ provider, settings, claims, nonce, nowMs = Date.now(), endpoints }) {
  const bad = (why) => ({ error: `회사 계정 확인에 실패했습니다(${why}).` });
  if (!claims) return bad('토큰 모양');
  const ep = endpoints ?? providerEndpoints(provider, settings);
  if (!ep.issuers.includes(claims.iss)) return bad('발급자');
  const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!aud.includes(clientIdOf(provider, settings))) return bad('대상');
  const now = Math.floor(nowMs / 1000);
  if (typeof claims.exp !== 'number' || claims.exp < now - 300) return bad('만료');
  if (typeof claims.iat === 'number' && claims.iat > now + 300) return bad('발급 시각');
  if (!nonce || claims.nonce !== nonce) return bad('nonce');

  if (provider === 'google') {
    const domains = parseDomainList(settings.ssoGoogleDomains);
    const hd = String(claims.hd ?? '').toLowerCase();
    if (!hd || !domains.includes(hd)) {
      return { error: '이 서버에서 허용한 회사(Google Workspace) 계정이 아닙니다. 회사 계정으로 다시 로그인하세요.' };
    }
    if (claims.email_verified !== true && claims.email_verified !== 'true') return bad('이메일 미확인');
    if (typeof claims.sub !== 'string' || !claims.sub) return bad('계정 ID');
    return {
      identity: {
        subject: claims.sub,
        email: EMAIL_RE.test(claims.email ?? '') ? claims.email.toLowerCase() : null,
        name: typeof claims.name === 'string' ? claims.name : null,
      },
    };
  }

  const tenant = String(settings.ssoMicrosoftTenantId ?? '').trim().toLowerCase();
  if (String(claims.tid ?? '').toLowerCase() !== tenant) {
    return { error: '이 서버에서 허용한 회사(Microsoft Entra) 계정이 아닙니다. 회사 계정으로 다시 로그인하세요.' };
  }
  if (typeof claims.oid !== 'string' || !claims.oid) return bad('계정 ID');
  const mail = [claims.email, claims.preferred_username].find((v) => typeof v === 'string' && EMAIL_RE.test(v));
  return {
    identity: {
      subject: `${tenant}:${claims.oid.toLowerCase()}`,
      email: mail ? mail.toLowerCase() : null,
      name: typeof claims.name === 'string' ? claims.name : null,
    },
  };
}

/**
 * 회사 계정 이메일로 새 아이디를 만든다 — 앞부분(@ 앞)을 영문·숫자·. _ -만 남겨 4~20자로 맞추고, [isTaken]이면 뒤에 숫자를 붙인다.
 * 새 아이디 규칙(authGuard.js USERNAME_PATTERN — 영문·숫자·. _ -, 4~20자, 영문·숫자로 시작)에 맞는 글자를 돌려준다.
 */
export async function usernameFromEmail(email, isTaken) {
  let base = String(email ?? '')
    .split('@')[0]
    .toLowerCase()
    .replace(/[^a-z0-9._-]/g, '')
    .replace(/^[^a-z0-9]+/, '')
    .slice(0, 16);
  if (base.length < 4) base = `user${base}`.slice(0, 16);
  if (!(await isTaken(base))) return base;
  for (let i = 2; i < 1000; i += 1) {
    const candidate = `${base.slice(0, 20 - String(i).length)}${i}`;
    if (!(await isTaken(candidate))) return candidate;
  }
  return `${base.slice(0, 12)}${crypto.randomInt(10_000_000, 99_999_999)}`;
}
