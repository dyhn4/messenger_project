import crypto from 'node:crypto';

/**
 * OAuth 앱(연동 앱이 사람의 승인을 받아 그 사람 이름으로 공개 API를 부르기)의 **순수 규칙** — 돌아갈 주소 검사·맞춰 보기, 권한 글, PKCE,
 * 승인 코드(사람이 앱에 넣는 짧은 코드) 모양, 토큰 수명. 흐름은 oauth.js(승인 코드 방식 + PKCE — RFC 6749·7636·8252). DB 없이 시험한다
 * (test/oauthRules.test.js).
 *
 * 흐름: 앱이 브라우저를 /oauth/authorize?client_id&redirect_uri&scope&state&code_challenge 로 보낸다 → 그 페이지가 짧은 코드(ABCD-2345)를
 * 보여 준다 → 사람이 TangoTalk 앱의 내 프로필 → 연결된 앱 → "코드로 승인"에 넣고 앱 이름·권한을 보고 승인한다 → 페이지가 돌아갈 주소로
 * ?code&state를 붙여 보낸다 → 앱이 POST /oauth/token으로 코드를 토큰(tto_ 1시간 + 다시 받기 ttr_ 90일)으로 바꾼다.
 * 브라우저에서 비밀번호를 받지 않아 회사 계정(SSO)·사내 디렉터리·2단계 인증 사람도 그대로 쓴다.
 */

export const CLIENT_ID_PREFIX = 'ttc_';
export const CLIENT_SECRET_PREFIX = 'tts_';
export const OAUTH_ACCESS_PREFIX = 'tto_';
export const OAUTH_REFRESH_PREFIX = 'ttr_';
export const ACCESS_TOKEN_TTL_SEC = 3600;
export const REFRESH_TOKEN_TTL_DAYS = 90;
export const OAUTH_REQUEST_TTL_MS = 10 * 60 * 1000;
export const REDIRECT_URIS_MAX = 10;
const REDIRECT_URI_MAX = 500;
/** 승인 코드 글자 — 헷갈리는 글자(0·O·1·I·L·U·A·E 등 모음)를 뺐다(모음을 빼면 우연한 낱말이 덜 생긴다). */
const USER_CODE_CHARS = 'BCDFGHJKMNPQRSTVWXZ23456789';

const isLoopbackHost = (host) => host === '127.0.0.1' || host === '[::1]' || host === 'localhost';

/**
 * 돌아갈 주소 하나 — https, 이 PC 안의 http(127.0.0.1·[::1]·localhost — 명령줄 도구가 잠깐 여는 주소), 휴대폰·PC 앱의 자기 스킴
 * (com.example.app:/callback처럼 점이 든 이름). #은 안 된다. `{ uri }` | `{ error }`.
 */
export function parseRedirectUri(value) {
  const raw = typeof value === 'string' ? value.trim() : '';
  if (!raw || raw.length > REDIRECT_URI_MAX) return { error: '돌아갈 주소를 500자 안으로 넣으세요.' };
  let u;
  try {
    u = new URL(raw);
  } catch {
    return { error: `돌아갈 주소 모양이 올바르지 않습니다: ${raw}` };
  }
  if (u.hash) return { error: '돌아갈 주소에는 #을 넣을 수 없습니다.' };
  if (u.username || u.password) return { error: '돌아갈 주소에 계정 정보를 넣지 마세요.' };
  const scheme = u.protocol.slice(0, -1);
  if (scheme === 'https') return { uri: u.href };
  if (scheme === 'http') {
    return isLoopbackHost(u.hostname === '::1' ? '[::1]' : u.hostname)
      ? { uri: u.href }
      : { error: 'http 주소는 이 PC 안(127.0.0.1·localhost)만 됩니다. 그 밖에는 https를 쓰세요.' };
  }
  if (/^[a-z][a-z0-9+-]*(\.[a-z0-9+-]+)+$/.test(scheme)) return { uri: raw };
  return { error: `쓸 수 없는 돌아갈 주소입니다: ${raw}` };
}

/** 돌아갈 주소 목록 — 줄바꿈·쉼표로 나눈 글이나 배열, 0~10개(비우면 OAuth를 쓰지 않는 앱). `{ uris }` | `{ error }`. */
export function parseRedirectUris(value) {
  const list = (Array.isArray(value) ? value : typeof value === 'string' ? value.split(/[\n,]/) : [])
    .map((v) => (typeof v === 'string' ? v.trim() : ''))
    .filter(Boolean);
  if (list.length > REDIRECT_URIS_MAX) return { error: `돌아갈 주소는 ${REDIRECT_URIS_MAX}개까지입니다.` };
  const uris = [];
  for (const v of list) {
    const r = parseRedirectUri(v);
    if (r.error) return r;
    if (!uris.includes(r.uri)) uris.push(r.uri);
  }
  return { uris };
}

/**
 * 요청한 돌아갈 주소가 등록한 것과 맞는지 — 그대로 같아야 하고, 이 PC 안 http 주소만 포트가 달라도 된다(RFC 8252 7.3 — 명령줄 도구는
 * 빈 포트를 그때그때 연다).
 */
export function redirectUriMatches(registered, requested) {
  if (typeof requested !== 'string' || !Array.isArray(registered)) return false;
  if (registered.includes(requested)) return true;
  let req;
  try {
    req = new URL(requested);
  } catch {
    return false;
  }
  if (req.protocol !== 'http:' || !isLoopbackHost(req.hostname === '::1' ? '[::1]' : req.hostname)) return false;
  return registered.some((r) => {
    try {
      const u = new URL(r);
      return u.protocol === 'http:' && u.hostname === req.hostname && u.pathname === req.pathname && u.search === req.search;
    } catch {
      return false;
    }
  });
}

/** 권한 글(scope — 띄어 쓴 'read write') → ['read'] | ['read','write']. 비우면 읽기만. `{ scopes }` | `{ error }`. */
export function parseOAuthScope(value) {
  const parts = String(value ?? '')
    .split(/[\s,+]+/)
    .filter(Boolean);
  if (parts.some((p) => p !== 'read' && p !== 'write')) return { error: 'invalid_scope' };
  return { scopes: parts.includes('write') ? ['read', 'write'] : ['read'] };
}

/** PKCE — code_challenge 모양(S256 — base64url 43자). */
export const isCodeChallenge = (v) => typeof v === 'string' && /^[A-Za-z0-9_-]{43}$/.test(v);

/** PKCE 확인 — base64url(SHA-256(verifier)) === challenge. verifier는 43~128자(RFC 7636). */
export function verifyPkce(verifier, challenge) {
  if (typeof verifier !== 'string' || !/^[A-Za-z0-9._~-]{43,128}$/.test(verifier) || !isCodeChallenge(challenge)) return false;
  const digest = crypto.createHash('sha256').update(verifier).digest('base64url');
  return crypto.timingSafeEqual(Buffer.from(digest), Buffer.from(challenge));
}

/** 사람이 앱에 넣을 승인 코드 — 'XXXX-XXXX'(약 38비트, 10분·한 번만, 넣는 횟수 제한). */
export function generateUserCode(randomInt = crypto.randomInt) {
  let s = '';
  for (let i = 0; i < 8; i += 1) s += USER_CODE_CHARS[randomInt(USER_CODE_CHARS.length)];
  return `${s.slice(0, 4)}-${s.slice(4)}`;
}

/** 넣은 코드를 저장 모양으로 — 대문자로, 글자·숫자만 남겨 4-4로. 모양이 아니면 null. */
export function normalizeUserCode(input) {
  const s = String(input ?? '')
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, '');
  if (s.length !== 8 || [...s].some((c) => !USER_CODE_CHARS.includes(c))) return null;
  return `${s.slice(0, 4)}-${s.slice(4)}`;
}

/** 돌아갈 주소에 값(code·state·error)을 붙인 주소 — 원래 있던 물음표 값은 그대로 둔다. 값이 null이면 뺀다. */
export function redirectWith(uri, params) {
  const extra = Object.entries(params).filter(([, v]) => v !== null && v !== undefined && v !== '');
  const qs = extra.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`).join('&');
  if (!qs) return uri;
  return `${uri}${uri.includes('?') ? '&' : '?'}${qs}`;
}

/** POST /oauth/token의 앱 확인 — Authorization: Basic base64(id:secret) 또는 본문의 client_id·client_secret. `{ clientId, clientSecret }`. */
export function clientCredentialsOf(authorization, body) {
  const header = typeof authorization === 'string' ? authorization : '';
  if (header.startsWith('Basic ')) {
    try {
      const decoded = Buffer.from(header.slice(6).trim(), 'base64').toString('utf8');
      const i = decoded.indexOf(':');
      if (i > 0) {
        return { clientId: decodeURIComponent(decoded.slice(0, i)), clientSecret: decodeURIComponent(decoded.slice(i + 1)) || null };
      }
    } catch {
      // 모양이 틀린 헤더는 본문 값으로 본다.
    }
  }
  const str = (v) => (typeof v === 'string' && v ? v : null);
  return { clientId: str(body?.client_id), clientSecret: str(body?.client_secret) };
}

/** 승인 기다리기가 끝났는지(10분). */
export const oauthRequestExpired = (row, now = Date.now()) => !row || new Date(row.expiresAt).getTime() <= now;

/** 화면에 보일 돌아갈 곳 — 주소의 호스트(자기 스킴이면 스킴). 승인 창이 "어디로 가는지" 보여 준다. */
export function redirectLabel(uri) {
  try {
    const u = new URL(uri);
    return u.host || u.protocol.slice(0, -1);
  } catch {
    return uri;
  }
}
