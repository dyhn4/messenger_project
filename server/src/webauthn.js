import crypto from 'node:crypto';
import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from '@simplewebauthn/server';
import { Router } from 'express';
import { accessPayload, issueTokenPair } from './auth.js';
import { clientIpKey, limits, rateLimit, retryLater, waitText } from './authGuard.js';
import {
  countPasskeys,
  deletePasskey,
  findPasskeyByCredentialId,
  insertPasskey,
  listPasskeys,
  renamePasskey,
  touchPasskey,
} from './db/queries/loginSecurityExtras.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { findUserById } from './db/queries/users.js';
import { isUuid } from './favoritesRules.js';
import { userFromOtpTicket } from './loginSecurity.js';
import { otpRequiredFor } from './loginSecurityRules.js';
import { isPkceValue, pkceChallenge, randomToken } from './ssoRules.js';
import { getWebPublicUrl } from './webAddress.js';
import {
  defaultPasskeyName,
  fromB64url,
  parsePasskeyName,
  PASSKEYS_PER_USER,
  toB64url,
  WEBAUTHN_TTL_MS,
  webauthnRp,
} from './webauthnRules.js';

/**
 * 하드웨어 보안 키·패스키(WebAuthn) — 등록(내 프로필), 비밀번호 없이 로그인, 로그인 둘째 단계(2단계 인증 대신). 규칙은 webauthnRules.js,
 * 서명 확인은 @simplewebauthn/server.
 *
 * 모든 앱(PC·안드로이드·아이폰·웹)이 같은 길을 쓴다 — 앱이 무작위 검증값의 해시(challenge)와 함께 시작을 청하면 서버가 웹 앱 주소
 * (WEB_DOMAIN — 정식 인증서)의 작은 페이지 주소를 주고, 앱은 그 주소를 브라우저로 연 채 2초마다 결과를 묻는다(검증값 원문을 같이 보내야
 * 해서 주소를 엿본 다른 사람은 결과를 못 가져간다 — 회사 계정 로그인과 같다). 그 페이지가 브라우저의 WebAuthn(navigator.credentials)으로
 * 보안 키(USB·NFC)·패스키(Windows Hello·휴대폰·iCloud/Google 비밀번호 관리자)를 쓰고 결과를 서버에 보낸다. 키는 그 도메인으로만 서명하므로
 * 가짜 사이트에서는 쓸 수 없다. 진행 중인 것은 서버 메모리에 5분까지만 둔다.
 *
 * 비밀번호 없이 로그인은 사용자 확인(PIN·지문·얼굴)을 꼭 거친 패스키만 받고(그 자체로 2단계), 둘째 단계는 사용자 확인 없는 USB 키도 받는다.
 */

const pending = new Map(); // state → { kind, userId, userName, appChallenge, challenge, options, name, viaTicket, createdAt, outcome }
setInterval(() => {
  const now = Date.now();
  for (const [state, entry] of pending) if (now - entry.createdAt > WEBAUTHN_TTL_MS) pending.delete(state);
}, 60 * 1000).unref();

const EXPIRED = '보안 키 확인 시간이 지났습니다. 처음부터 다시 하세요.';
const NO_WEB = '서버의 웹 앱 주소(정식 인증서 — WEB_DOMAIN)가 없어 보안 키·패스키를 쓸 수 없습니다.';
const RP_NAME = 'TangoTalk';

const escapeHtml = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

/** 진행 중인 것 + 앱의 검증값 확인 → entry | null(sso.js entryFor와 같다). */
function entryFor(state, verifier) {
  if (typeof state !== 'string' || !isPkceValue(verifier)) return null;
  const entry = pending.get(state);
  if (!entry || Date.now() - entry.createdAt > WEBAUTHN_TTL_MS) return null;
  const a = Buffer.from(pkceChallenge(verifier));
  const b = Buffer.from(entry.appChallenge);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  return entry;
}

/** 브라우저 페이지의 주소. */
const ceremonyUrl = (state) => `${getWebPublicUrl().replace(/\/+$/, '')}/auth/passkeys/ceremony?state=${encodeURIComponent(state)}`;

const unusableText = (user) =>
  !user ? '계정을 찾을 수 없습니다.' : user.deletedAt ? '탈퇴한 계정입니다.' : user.suspendedAt ? '정지된 계정입니다. 서버 운영자에게 문의하세요.' : null;

/** 진행 시작 → 앱에 줄 `{ state, url, expiresInSeconds }`. */
function begin(entry) {
  const state = randomToken();
  pending.set(state, { ...entry, createdAt: Date.now(), outcome: null });
  return { state, url: ceremonyUrl(state), expiresInSeconds: Math.round(WEBAUTHN_TTL_MS / 1000) };
}

/** 이 사람의 키를 지우거나(마지막 둘째 단계) 2단계 인증을 끄면 안 되는지 — 정책상 꼭 써야 하는데 남는 방법이 없을 때. */
export async function lastSecondFactorLocked(user, { removingPasskey = false, removingTotp = false } = {}) {
  const settings = await getServerSettings();
  if (!otpRequiredFor(settings.otpPolicy, user)) return false;
  const passkeys = (await countPasskeys(user.id)) - (removingPasskey ? 1 : 0);
  const totp = !!user.totpEnabledAt && !removingTotp;
  return passkeys <= 0 && !totp;
}

// ── 브라우저 페이지(웹 앱 주소에서 열린다) ────────────────────────────────

export const CEREMONY_PAGE_JS = `(function(){
var state=new URLSearchParams(location.search).get('state');var el=document.getElementById('status');var btn=document.getElementById('go');
function show(t,bad){el.textContent=t;el.className=bad?'status err':'status';}
function b2a(b){var s='';var u=new Uint8Array(b);for(var i=0;i<u.length;i++)s+=String.fromCharCode(u[i]);return btoa(s).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'');}
function a2b(s){s=s.replace(/-/g,'+').replace(/_/g,'/');while(s.length%4)s+='=';var r=atob(s);var u=new Uint8Array(r.length);for(var i=0;i<r.length;i++)u[i]=r.charCodeAt(i);return u.buffer;}
function creation(o){o=Object.assign({},o);o.challenge=a2b(o.challenge);o.user=Object.assign({},o.user,{id:a2b(o.user.id)});o.excludeCredentials=(o.excludeCredentials||[]).map(function(c){return Object.assign({},c,{id:a2b(c.id)});});return o;}
function request(o){o=Object.assign({},o);o.challenge=a2b(o.challenge);o.allowCredentials=(o.allowCredentials||[]).map(function(c){return Object.assign({},c,{id:a2b(c.id)});});return o;}
function toJSON(c){var r=c.response;var out={id:c.id,rawId:b2a(c.rawId),type:c.type,clientExtensionResults:c.getClientExtensionResults?c.getClientExtensionResults():{},authenticatorAttachment:c.authenticatorAttachment||undefined,response:{clientDataJSON:b2a(r.clientDataJSON)}};
if(r.attestationObject){out.response.attestationObject=b2a(r.attestationObject);out.response.transports=r.getTransports?r.getTransports():[];}
else{out.response.authenticatorData=b2a(r.authenticatorData);out.response.signature=b2a(r.signature);out.response.userHandle=r.userHandle?b2a(r.userHandle):undefined;}return out;}
var opts=null;
fetch('/auth/passkeys/ceremony/options?state='+encodeURIComponent(state),{cache:'no-store'}).then(function(r){return r.json();}).then(function(j){
if(j.error){show(j.error,true);return;}opts=j;document.getElementById('title').textContent=j.title;document.getElementById('detail').textContent=j.detail;btn.disabled=false;
if(!window.PublicKeyCredential){show('이 브라우저는 보안 키·패스키를 쓸 수 없습니다. 최신 Chrome·Edge·Safari로 여세요. / This browser does not support passkeys.',true);btn.disabled=true;}
}).catch(function(){show('서버에 연결하지 못했습니다. / Could not reach the server.',true);});
btn.addEventListener('click',function(){if(!opts)return;btn.disabled=true;show('보안 키를 대거나 화면의 안내를 따르세요… / Follow your browser prompt…');
var p=opts.kind==='register'?navigator.credentials.create({publicKey:creation(opts.publicKey)}):navigator.credentials.get({publicKey:request(opts.publicKey)});
p.then(function(c){return fetch('/auth/passkeys/ceremony/finish',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({state:state,credential:toJSON(c)})});})
.then(function(r){return r.json();}).then(function(j){if(j.ok){show(j.message||'확인했습니다. 앱으로 돌아가세요. / Done. Go back to the app.');}else{show(j.error||'확인하지 못했습니다.',true);btn.disabled=false;}})
.catch(function(e){show((e&&e.name==='NotAllowedError')?'취소했거나 시간이 지났습니다. 다시 누르세요. / Cancelled or timed out.':(e&&e.name==='InvalidStateError')?'이 키는 이미 등록되어 있습니다. / This key is already registered.':'보안 키를 쓰지 못했습니다: '+(e&&e.message||e),true);btn.disabled=false;});});
})();`;

function ceremonyPage(res) {
  res
    .status(200)
    .set({
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      'content-security-policy':
        "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      'referrer-policy': 'no-referrer',
    })
    .send(`<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>TangoTalk 보안 키</title>
<style>body{font-family:system-ui,-apple-system,"Segoe UI","Malgun Gothic",sans-serif;background:#f2f2f4;color:#1d1d1f;margin:0;padding:24px 16px}
main{max-width:440px;margin:40px auto;background:#fff;border-radius:14px;padding:28px 24px;box-shadow:0 2px 12px rgba(0,0,0,.06);text-align:center}
h1{font-size:20px;margin:8px 0} .key{font-size:40px} p{line-height:1.6;color:#444}
button{font-size:16px;padding:12px 22px;border-radius:10px;border:0;background:#3366ff;color:#fff;cursor:pointer;margin-top:12px}
button:disabled{background:#aab;cursor:default} .status{margin-top:16px;font-size:14px;color:#555} .err{color:#c62828}
@media (prefers-color-scheme:dark){body{background:#1c1c1e;color:#eee} main{background:#2c2c2e;box-shadow:none} p,.status{color:#bbb}}</style></head>
<body><main><div class="key">🔑</div><h1 id="title">보안 키·패스키</h1><p id="detail"></p>
<button id="go" disabled>계속 / Continue</button><p class="status" id="status"></p></main><script src="/auth/passkeys/ceremony.js"></script></body></html>`);
}

export function createWebauthnRouter() {
  const router = Router();

  /** 시작할 수 있는지 — 웹 앱 주소가 있어야 한다. `{ rp }` | 응답을 보내고 null. */
  function rpOr503(res) {
    const rp = webauthnRp(getWebPublicUrl());
    if (!rp) res.status(503).json({ error: NO_WEB });
    return rp;
  }

  /**
   * 등록 시작 — Bearer(내 프로필에서) 또는 확인 표(로그인 중 "2단계 인증을 꼭 써야 함"에서 그 자리에서 등록 — ticket, purpose 'setup')
   * `{ challenge, name?, ticket? }` → `{ state, url, expiresInSeconds }`. 표로 등록하면 끝난 뒤 결과 묻기에서 토큰도 준다.
   */
  router.post('/passkeys/register/start', async (req, res) => {
    const rp = rpOr503(res);
    if (!rp) return;
    if (!isPkceValue(req.body?.challenge)) return res.status(400).json({ error: '앱을 최신 버전으로 업데이트하세요.' });
    let user = null;
    const viaTicket = !!req.body?.ticket;
    if (viaTicket) {
      user = await userFromOtpTicket(req.body.ticket, 'setup');
      if (!user) return res.status(401).json({ error: '확인 시간이 지났습니다. 처음부터 다시 로그인하세요.' });
    } else {
      const payload = await accessPayload(req);
      user = payload ? await findUserById(payload.sub) : null;
      if (!user) return res.status(401).json({ error: '토큰이 유효하지 않습니다.' });
    }
    const name = parsePasskeyName(req.body?.name, '');
    if (name.error) return res.status(400).json({ error: name.error });
    const existing = await listPasskeys(user.id);
    if (existing.length >= PASSKEYS_PER_USER) return res.status(400).json({ error: `보안 키·패스키는 ${PASSKEYS_PER_USER}개까지 등록할 수 있습니다.` });
    const options = await generateRegistrationOptions({
      rpName: RP_NAME,
      rpID: rp.rpID,
      userName: user.username,
      userDisplayName: user.name ?? user.username,
      userID: new TextEncoder().encode(user.id),
      attestationType: 'none',
      excludeCredentials: existing.map((c) => ({ id: c.credentialId, transports: c.transports ?? undefined })),
      // 패스키(기기에 남는 키)를 되도록 — 그래야 아이디 없이도 로그인한다. 사용자 확인은 되면 한다(PIN 없는 USB 키도 둘째 단계로는 쓴다).
      authenticatorSelection: { residentKey: 'preferred', userVerification: 'preferred' },
      timeout: WEBAUTHN_TTL_MS - 30_000,
    });
    res.json(
      begin({
        kind: 'register',
        userId: user.id,
        userName: user.name ?? user.username,
        appChallenge: req.body.challenge,
        challenge: options.challenge,
        options,
        name: name.name || null,
        viaTicket,
      }),
    );
  });

  /** 비밀번호 없이 로그인 시작 `{ challenge }` — 아이디를 묻지 않는다(키에 남은 패스키를 고른다). */
  router.post('/passkeys/login/start', rateLimit(limits.ssoStartIp, '보안 키 로그인 시도'), async (req, res) => {
    const rp = rpOr503(res);
    if (!rp) return;
    if (!(await getServerSettings()).passkeyLoginEnabled) {
      return res.status(403).json({ error: '이 서버는 보안 키·패스키로 바로 로그인하는 것을 막아 두었습니다. 아이디로 로그인하세요.' });
    }
    if (!isPkceValue(req.body?.challenge)) return res.status(400).json({ error: '앱을 최신 버전으로 업데이트하세요.' });
    const options = await generateAuthenticationOptions({ rpID: rp.rpID, userVerification: 'required', timeout: WEBAUTHN_TTL_MS - 30_000 });
    res.json(begin({ kind: 'login', userId: null, appChallenge: req.body.challenge, challenge: options.challenge, options }));
  });

  /** 로그인 둘째 단계 시작 `{ ticket, challenge }` — 비밀번호(또는 디렉터리)를 통과하고 받은 확인 표(purpose 'login')로. */
  router.post('/passkeys/second/start', async (req, res) => {
    const rp = rpOr503(res);
    if (!rp) return;
    const user = await userFromOtpTicket(req.body?.ticket, 'login');
    if (!user) return res.status(401).json({ error: '확인 시간이 지났습니다. 처음부터 다시 로그인하세요.' });
    if (!isPkceValue(req.body?.challenge)) return res.status(400).json({ error: '앱을 최신 버전으로 업데이트하세요.' });
    const keys = await listPasskeys(user.id);
    if (keys.length === 0) return res.status(400).json({ error: '등록한 보안 키가 없습니다. 인증 앱의 코드를 넣으세요.' });
    const options = await generateAuthenticationOptions({
      rpID: rp.rpID,
      allowCredentials: keys.map((c) => ({ id: c.credentialId, transports: c.transports ?? undefined })),
      userVerification: 'preferred',
      timeout: WEBAUTHN_TTL_MS - 30_000,
    });
    res.json(
      begin({ kind: 'second', userId: user.id, userName: user.name ?? user.username, appChallenge: req.body.challenge, challenge: options.challenge, options }),
    );
  });

  /**
   * 결과 묻기 `{ state, verifier }` → `{ status: 'pending' }` | `{ status: 'registered', passkey }` | `{ status: 'done', accessToken, … }` |
   * `{ status: 'error', error }`. 토큰은 한 번만 준다.
   */
  router.post('/passkeys/poll', rateLimit(limits.ssoPollIp, '보안 키 확인'), async (req, res) => {
    const entry = entryFor(req.body?.state, req.body?.verifier);
    if (!entry) return res.status(400).json({ status: 'error', error: EXPIRED });
    const outcome = entry.outcome;
    if (!outcome) return res.json({ status: 'pending' });
    pending.delete(req.body.state);
    if (outcome.type === 'error') return res.json({ status: 'error', error: outcome.error });
    if (outcome.type === 'registered' && !entry.viaTicket) return res.json({ status: 'registered', passkey: outcome.passkey });
    const user = await findUserById(outcome.userId);
    const why = unusableText(user);
    if (why) return res.json({ status: 'error', error: why });
    res.json({
      status: 'done',
      ...issueTokenPair(user),
      userId: user.id,
      username: user.username,
      ...(outcome.passkey ? { passkey: outcome.passkey } : {}),
    });
  });

  // ── 브라우저 페이지 ──

  router.get('/passkeys/ceremony', (req, res) => ceremonyPage(res));
  router.get('/passkeys/ceremony.js', (req, res) =>
    res.set({ 'content-type': 'text/javascript; charset=utf-8', 'cache-control': 'no-cache' }).send(CEREMONY_PAGE_JS),
  );

  /** 페이지가 받는 값 — WebAuthn 옵션과 화면 글(누구의 무엇을 하는지 — 남이 보낸 주소면 알아보게). */
  router.get('/passkeys/ceremony/options', (req, res) => {
    res.set('cache-control', 'no-store');
    const entry = typeof req.query.state === 'string' ? pending.get(req.query.state) : null;
    if (!entry || Date.now() - entry.createdAt > WEBAUTHN_TTL_MS || entry.outcome) return res.json({ error: EXPIRED });
    const text = {
      register: ['보안 키·패스키 등록', `${entry.userName} 계정에 보안 키·패스키를 등록합니다. 직접 시작한 것이 아니면 이 창을 닫으세요.`],
      login: ['보안 키·패스키로 로그인', 'TangoTalk에 등록한 보안 키·패스키로 로그인합니다.'],
      second: ['보안 키로 로그인 확인', `${entry.userName} 계정의 로그인을 보안 키로 확인합니다.`],
    }[entry.kind];
    res.json({ kind: entry.kind === 'register' ? 'register' : 'get', publicKey: entry.options, title: text[0], detail: text[1] });
  });

  /** 페이지가 보낸 결과 확인 `{ state, credential }` → `{ ok, message }` | `{ ok: false, error }`. */
  router.post('/passkeys/ceremony/finish', async (req, res) => {
    const wait = limits.ssoPollIp.hit(clientIpKey(req));
    if (wait > 0) return retryLater(res, wait, `요청이 너무 많습니다. ${waitText(wait)} 뒤에 다시 하세요.`);
    const state = typeof req.body?.state === 'string' ? req.body.state : '';
    const entry = pending.get(state);
    if (!entry || Date.now() - entry.createdAt > WEBAUTHN_TTL_MS || entry.outcome) return res.json({ ok: false, error: EXPIRED });
    const rp = webauthnRp(getWebPublicUrl());
    const credential = req.body?.credential;
    if (!rp || !credential || typeof credential !== 'object') return res.json({ ok: false, error: '보안 키 응답이 없습니다.' });
    const fail = (error) => res.json({ ok: false, error });
    try {
      if (entry.kind === 'register') {
        const v = await verifyRegistrationResponse({
          response: credential,
          expectedChallenge: entry.challenge,
          expectedOrigin: rp.origin,
          expectedRPID: rp.rpID,
          requireUserVerification: false,
        });
        if (!v.verified) return fail('보안 키를 확인하지 못했습니다.');
        const info = v.registrationInfo;
        const transports = info.credential.transports ?? [];
        const row = await insertPasskey({
          userId: entry.userId,
          credentialId: info.credential.id,
          publicKey: toB64url(info.credential.publicKey),
          counter: info.credential.counter ?? 0,
          transports,
          deviceType: info.credentialDeviceType,
          backedUp: !!info.credentialBackedUp,
          aaguid: info.aaguid ?? null,
          name: entry.name ?? defaultPasskeyName({ backedUp: info.credentialBackedUp, transports }),
        });
        if (!row) return fail('이 보안 키는 이미 등록되어 있습니다.');
        entry.outcome = { type: entry.viaTicket ? 'login' : 'registered', userId: entry.userId, passkey: passkeyDto(row) };
        return res.json({ ok: true, message: '보안 키를 등록했습니다. TangoTalk 앱으로 돌아가세요. 이 창은 닫아도 됩니다.' });
      }
      // 로그인·둘째 단계 — 누른 키를 찾고(둘째 단계는 그 사람의 키여야 한다) 서명을 확인한다.
      const key = typeof credential.id === 'string' ? await findPasskeyByCredentialId(credential.id) : null;
      if (!key || (entry.kind === 'second' && key.userId !== entry.userId)) {
        return fail(entry.kind === 'second' ? '이 계정에 등록한 보안 키가 아닙니다.' : '등록되지 않은 보안 키·패스키입니다. 아이디로 로그인한 뒤 내 프로필에서 등록하세요.');
      }
      const v = await verifyAuthenticationResponse({
        response: credential,
        expectedChallenge: entry.challenge,
        expectedOrigin: rp.origin,
        expectedRPID: rp.rpID,
        credential: { id: key.credentialId, publicKey: fromB64url(key.publicKey), counter: Number(key.counter ?? 0), transports: key.transports ?? undefined },
        requireUserVerification: entry.kind === 'login',
      });
      if (!v.verified) return fail('보안 키를 확인하지 못했습니다.');
      await touchPasskey(key.id, v.authenticationInfo.newCounter);
      entry.outcome = { type: 'login', userId: key.userId };
      return res.json({ ok: true, message: '확인했습니다. TangoTalk 앱으로 돌아가세요. 이 창은 닫아도 됩니다.' });
    } catch (err) {
      console.warn('[webauthn] 확인 실패:', err?.message ?? err);
      return fail('보안 키를 확인하지 못했습니다. 처음부터 다시 하세요.');
    }
  });

  // ── 내 보안 키 관리(Bearer) ──

  async function bearerUser(req, res) {
    const payload = await accessPayload(req);
    const user = payload ? await findUserById(payload.sub) : null;
    if (!user) res.status(401).json({ error: '토큰이 유효하지 않습니다.' });
    return user;
  }

  router.get('/passkeys', async (req, res) => {
    const user = await bearerUser(req, res);
    if (!user) return;
    res.json({ passkeys: (await listPasskeys(user.id)).map(passkeyDto), available: !!webauthnRp(getWebPublicUrl()) });
  });

  router.patch('/passkeys/:id', async (req, res) => {
    const user = await bearerUser(req, res);
    if (!user) return;
    const name = parsePasskeyName(req.body?.name);
    if (name.error) return res.status(400).json({ error: name.error });
    const row = isUuid(req.params.id) ? await renamePasskey(req.params.id, user.id, name.name) : null;
    if (!row) return res.status(404).json({ error: '보안 키를 찾을 수 없습니다.' });
    res.json(passkeyDto(row));
  });

  /** 지우기 — 2단계 인증을 꼭 써야 하는데 이것이 마지막 방법이면(인증 앱도 없음) 지울 수 없다. */
  router.delete('/passkeys/:id', async (req, res) => {
    const user = await bearerUser(req, res);
    if (!user) return;
    if (!isUuid(req.params.id)) return res.status(404).json({ error: '보안 키를 찾을 수 없습니다.' });
    if (await lastSecondFactorLocked(user, { removingPasskey: true })) {
      return res.status(403).json({ error: '관리자가 2단계 인증을 꼭 쓰게 정해서 마지막 보안 키는 지울 수 없습니다. 인증 앱을 먼저 켜세요.' });
    }
    if (!(await deletePasskey(req.params.id, user.id))) return res.status(404).json({ error: '보안 키를 찾을 수 없습니다.' });
    res.json({ ok: true });
  });

  return router;
}

const ms = (v) => (v ? new Date(v).getTime() : null);

export const passkeyDto = (r) => ({
  id: r.id,
  name: r.name,
  backedUp: !!r.backedUp,
  deviceType: r.deviceType ?? null,
  transports: Array.isArray(r.transports) ? r.transports : [],
  createdAt: ms(r.createdAt),
  lastUsedAt: ms(r.lastUsedAt),
});
