import crypto from 'node:crypto';
import express, { Router } from 'express';
import { userAccess } from './access.js';
import { accountState } from './authState.js';
import { clientIpKey, limits, retryLater, waitText } from './authGuard.js';
import { lookupHash } from './crypto.js';
import {
  deleteGrant,
  deleteOAuthRequestsBefore,
  findAppByClientId,
  findGrantById,
  findIntegrationById,
  findOAuthRequestByCodeHash,
  findOAuthRequestById,
  findOAuthRequestByUserCode,
  findUsableApiToken,
  insertApiToken,
  insertOAuthRequest,
  listUserGrants,
  revokeTokenById,
  transitionOAuthRequest,
  upsertGrant,
} from './db/queries/integrations.js';
import { findTeamById, isTeamMember } from './db/queries/teams.js';
import { isUuid } from './favoritesRules.js';
import { generateSecretToken, isSecretToken, tokenPrefixOf } from './integrationRules.js';
import {
  ACCESS_TOKEN_TTL_SEC,
  clientCredentialsOf,
  generateUserCode,
  isCodeChallenge,
  normalizeUserCode,
  OAUTH_ACCESS_PREFIX,
  OAUTH_REFRESH_PREFIX,
  OAUTH_REQUEST_TTL_MS,
  oauthRequestExpired,
  parseOAuthScope,
  redirectLabel,
  redirectUriMatches,
  redirectWith,
  REFRESH_TOKEN_TTL_DAYS,
  verifyPkce,
} from './oauthRules.js';

/**
 * OAuth 앱 — 연동 앱(integrations kind 'app')이 사람의 승인을 받아 **그 사람 이름으로** 공개 API(/api/v1)를 부르게 한다(개인 API 토큰을
 * 복사해 붙이는 대신). 승인 코드 방식 + PKCE(RFC 6749·7636·8252), 규칙은 oauthRules.js.
 *
 *  1. 앱이 브라우저를 GET /oauth/authorize?response_type=code&client_id&redirect_uri&scope&state&code_challenge&code_challenge_method=S256
 *     로 보낸다 → 이 서버가 앱 이름·권한과 짧은 승인 코드(ABCD-2345)를 보여 주는 페이지를 낸다.
 *  2. 사람이 TangoTalk 앱의 내 프로필 → 연결된 앱 → "코드로 승인"에 코드를 넣고 앱 이름·권한을 확인해 승인한다(/api/oauth/requests/…).
 *     브라우저에서 비밀번호를 받지 않으므로 회사 계정(SSO)·사내 디렉터리(LDAP)·2단계 인증을 쓰는 사람도 그대로 된다.
 *  3. 페이지가 2초마다 물어 보다가(GET /oauth/requests/:id/status) 승인되면 돌아갈 주소로 ?code&state를 붙여 간다(코드는 그때 처음 만들고
 *     5분·한 번만).
 *  4. 앱이 POST /oauth/token(grant_type=authorization_code — 앱 비밀이나 PKCE)으로 코드를 tto_ 토큰(1시간)과 ttr_ 다시 받기 토큰(90일,
 *     쓸 때마다 새것으로)으로 바꾼다. 토큰은 앱의 팀 안에서만 쓰이고(publicApi.js), 내 프로필 → 연결된 앱에서 끊으면 바로 못 쓴다.
 */

const ms = (v) => (v ? new Date(v).getTime() : null);
const escapeHtml = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

const SCOPE_TEXT = { read: '읽기(내 팀·대화방·메시지·할 일·일정)', write: '쓰기(내 이름으로 메시지·댓글·할 일·일정)' };
const SCOPE_TEXT_EN = { read: 'Read (my team, rooms, messages, to-dos, events)', write: 'Write (messages, comments, to-dos, events as me)' };

/** 승인 페이지·오류 페이지 — 바깥 스크립트·글꼴 없이, 이 서버의 /oauth/authorize.js만. */
function page(res, status, { title, body, requestId = null }) {
  res
    .status(status)
    .set({
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      'content-security-policy':
        "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      'x-frame-options': 'DENY',
      'referrer-policy': 'no-referrer',
    })
    .send(`<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>
body{font-family:system-ui,-apple-system,"Segoe UI","Malgun Gothic",sans-serif;background:#f2f2f4;color:#1d1d1f;margin:0;padding:24px 16px}
main{max-width:460px;margin:40px auto;background:#fff;border-radius:14px;padding:28px 24px;box-shadow:0 2px 12px rgba(0,0,0,.06)}
h1{font-size:20px;margin:0 0 6px} .en{color:#888;font-size:13px} .app{font-size:34px}
.code{font-size:34px;letter-spacing:4px;font-weight:700;text-align:center;background:#f5f5f7;border-radius:10px;padding:14px;margin:18px 0;font-family:ui-monospace,Consolas,monospace}
ul{padding-left:20px;margin:8px 0} li{margin:4px 0} .status{margin-top:16px;color:#555;font-size:14px} .err{color:#c62828}
@media (prefers-color-scheme:dark){body{background:#1c1c1e;color:#eee} main{background:#2c2c2e;box-shadow:none} .code{background:#3a3a3c} .status{color:#bbb}}
</style></head>
<body${requestId ? ` data-request-id="${escapeHtml(requestId)}"` : ''}><main>${body}</main>${requestId ? '<script src="/oauth/authorize.js"></script>' : ''}</body></html>`);
}

const errorPage = (res, status, ko, en) =>
  page(res, status, {
    title: 'TangoTalk',
    body: `<h1>연결할 수 없습니다</h1><p class="en">Cannot connect</p><p class="err">${escapeHtml(ko)}</p><p class="en">${escapeHtml(en)}</p>`,
  });

/** 승인 페이지의 스크립트 — 2초마다 승인 결과를 묻고, 끝나면 돌아갈 주소로 간다. */
const AUTHORIZE_JS = `(function(){
var id=document.body.getAttribute('data-request-id');var el=document.getElementById('status');
function show(t){if(el)el.textContent=t;}
function poll(){fetch('/oauth/requests/'+encodeURIComponent(id)+'/status',{cache:'no-store'}).then(function(r){return r.json();}).then(function(j){
if(j.redirect){show(j.status==='approved'?'승인되었습니다. 돌아가는 중… / Approved. Redirecting…':'거절되었습니다. / Denied.');location.replace(j.redirect);return;}
if(j.status==='expired'){show('시간이 지났습니다. 처음부터 다시 하세요. / Expired. Please start again.');return;}
setTimeout(poll,2000);}).catch(function(){setTimeout(poll,4000);});}
setTimeout(poll,2000);})();`;

/** OAuth 오류 응답(RFC 6749 5.2) — error 코드와 한국어 설명. */
function oauthError(res, status, error, description) {
  return res.status(status).set('cache-control', 'no-store').json({ error, error_description: description });
}

/** 앱 비밀이 맞는지(열쇠 해시를 시간 일정하게 비교). */
function clientSecretMatches(app, secret) {
  if (!secret || !app.clientSecretHash) return false;
  const a = Buffer.from(lookupHash(secret));
  const b = Buffer.from(app.clientSecretHash);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

/** 토큰 한 쌍을 만든다 — 공개 API 토큰(1시간)과 다시 받기 토큰(90일). OAuth 토큰 응답 모양으로. */
async function issueTokens(app, grant) {
  const access = generateSecretToken(OAUTH_ACCESS_PREFIX);
  const refresh = generateSecretToken(OAUTH_REFRESH_PREFIX);
  const base = { userId: grant.userId, name: app.name, scopes: grant.scopes, grantId: grant.id };
  await insertApiToken({
    ...base,
    kind: 'oauth',
    tokenHash: lookupHash(access),
    tokenPrefix: tokenPrefixOf(access),
    expiresAt: new Date(Date.now() + ACCESS_TOKEN_TTL_SEC * 1000),
  });
  await insertApiToken({
    ...base,
    kind: 'refresh',
    tokenHash: lookupHash(refresh),
    tokenPrefix: tokenPrefixOf(refresh),
    expiresAt: new Date(Date.now() + REFRESH_TOKEN_TTL_DAYS * 86_400_000),
  });
  return { access_token: access, token_type: 'Bearer', expires_in: ACCESS_TOKEN_TTL_SEC, refresh_token: refresh, scope: grant.scopes.join(' ') };
}

/** 이 사람이 지금 이 앱을 승인할 수 있는지 — 쓸 수 있는 계정, 정회원 이상, 앱의 팀 멤버. 안 되면 거절 문구. */
async function approvalDenial(app, userId) {
  if ((await accountState(userId)).blocked) return '쓸 수 없는 계정입니다.';
  if ((await userAccess(userId)).role === 'guest') return '준회원은 앱을 연결할 수 없습니다.';
  if (!(await isTeamMember(app.teamId, userId))) return '이 앱의 팀 멤버만 승인할 수 있습니다.';
  return null;
}

/** 로그인 없이 여는 경로 — 승인 페이지·결과 묻기·토큰·토큰 끊기. index.js가 앱 맨 위에 건다. */
export function createOAuthPublicRouter() {
  const router = Router();
  const form = express.urlencoded({ extended: false, limit: '16kb' });

  router.get('/oauth/authorize.js', (req, res) => {
    res.set({ 'content-type': 'text/javascript; charset=utf-8', 'cache-control': 'no-cache' }).send(AUTHORIZE_JS);
  });

  router.get('/oauth/authorize', async (req, res) => {
    const wait = limits.oauthAuthorizeIp.hit(clientIpKey(req));
    if (wait > 0) return errorPage(res, 429, `요청이 너무 많습니다. ${waitText(wait)} 뒤에 다시 하세요.`, 'Too many requests.');
    const q = req.query;
    const clientId = typeof q.client_id === 'string' ? q.client_id : '';
    const app = clientId ? await findAppByClientId(clientId) : null;
    if (!app || !app.enabled) return errorPage(res, 400, '등록되지 않았거나 꺼진 앱입니다(client_id).', 'Unknown or disabled app (client_id).');
    const redirectUri = typeof q.redirect_uri === 'string' ? q.redirect_uri : '';
    if (!redirectUriMatches(app.redirectUris ?? [], redirectUri)) {
      return errorPage(res, 400, '이 앱에 등록되지 않은 돌아갈 주소입니다(redirect_uri).', 'redirect_uri is not registered for this app.');
    }
    const state = typeof q.state === 'string' ? q.state.slice(0, 500) : null;
    const back = (error, description) => res.redirect(302, redirectWith(redirectUri, { error, error_description: description, state }));
    if (q.response_type !== 'code') return back('unsupported_response_type', 'response_type=code만 됩니다.');
    const scope = parseOAuthScope(q.scope);
    if (scope.error) return back('invalid_scope', 'scope는 read·write 중에서 고르세요.');
    let codeChallenge = null;
    if (q.code_challenge !== undefined) {
      if (q.code_challenge_method !== 'S256' || !isCodeChallenge(q.code_challenge)) {
        return back('invalid_request', 'code_challenge는 S256(43자)만 됩니다.');
      }
      codeChallenge = q.code_challenge;
    }
    let row = null;
    for (let i = 0; i < 3 && !row; i += 1) {
      try {
        row = await insertOAuthRequest({
          integrationId: app.id,
          userCode: generateUserCode(),
          redirectUri,
          scopes: scope.scopes,
          state,
          codeChallenge,
          expiresAt: new Date(Date.now() + OAUTH_REQUEST_TTL_MS),
        });
      } catch (err) {
        if (err?.code !== '23505') throw err; // 같은 코드가 이미 있음 — 다시 만든다.
      }
    }
    if (!row) return errorPage(res, 503, '잠시 뒤에 다시 하세요.', 'Please try again later.');
    // 오래된 요청은 가끔 치운다.
    if (Math.random() < 0.05) deleteOAuthRequestsBefore(new Date(Date.now() - 24 * 3600 * 1000)).catch(() => {});
    const team = await findTeamById(app.teamId);
    page(res, 200, {
      title: `${app.name} — TangoTalk`,
      requestId: row.id,
      body: `<div class="app">${escapeHtml(app.emoji ?? '🤖')}</div>
<h1>${escapeHtml(app.name)}</h1>
<p>${escapeHtml(team?.name ?? '')} 팀의 연동 앱이 TangoTalk의 내 계정으로 다음을 하려고 합니다.</p>
<p class="en">This app wants to use your TangoTalk account to:</p>
<ul>${scope.scopes.map((s) => `<li>${escapeHtml(SCOPE_TEXT[s])}<br><span class="en">${escapeHtml(SCOPE_TEXT_EN[s])}</span></li>`).join('')}</ul>
<p>TangoTalk 앱에서 <b>내 프로필 → 연결된 앱 → 코드로 승인</b>을 열고 이 코드를 넣으세요(10분 안에).</p>
<p class="en">In the TangoTalk app, open <b>My profile → Connected apps → Approve with code</b> and enter this code (within 10 minutes).</p>
<div class="code">${escapeHtml(row.userCode)}</div>
<p class="en">승인하면 ${escapeHtml(redirectLabel(redirectUri))}(으)로 돌아갑니다. / You will return to ${escapeHtml(redirectLabel(redirectUri))}.</p>
<p class="status" id="status">승인을 기다리는 중… / Waiting for approval…</p>`,
    });
  });

  /** 승인 페이지가 묻는 결과 — 승인되면 처음 한 번만 승인 코드를 만들어 돌아갈 주소를 준다. */
  router.get('/oauth/requests/:id/status', async (req, res) => {
    const wait = limits.oauthTokenIp.hit(clientIpKey(req));
    if (wait > 0) return retryLater(res, wait, '요청이 너무 많습니다.');
    res.set('cache-control', 'no-store');
    const row = isUuid(req.params.id) ? await findOAuthRequestById(req.params.id) : null;
    if (!row || oauthRequestExpired(row)) return res.json({ status: 'expired' });
    if (row.status === 'pending') return res.json({ status: 'pending' });
    if (row.status === 'denied') {
      return res.json({ status: 'denied', redirect: redirectWith(row.redirectUri, { error: 'access_denied', state: row.state }) });
    }
    if (row.status !== 'approved') return res.json({ status: 'expired' }); // 이미 코드를 받아 갔다.
    const code = crypto.randomBytes(32).toString('base64url');
    const issued = await transitionOAuthRequest(row.id, 'approved', {
      status: 'issued',
      codeHash: lookupHash(code),
      expiresAt: new Date(Date.now() + 5 * 60 * 1000),
    });
    if (!issued) return res.json({ status: 'expired' });
    res.json({ status: 'approved', redirect: redirectWith(row.redirectUri, { code, state: row.state }) });
  });

  /** 토큰 받기 — grant_type=authorization_code | refresh_token(form 또는 JSON). */
  router.post('/oauth/token', form, async (req, res) => {
    const wait = limits.oauthTokenIp.hit(clientIpKey(req));
    if (wait > 0) return retryLater(res, wait, '요청이 너무 많습니다.');
    const b = req.body ?? {};
    const { clientId, clientSecret } = clientCredentialsOf(req.get('authorization'), b);
    const app = clientId ? await findAppByClientId(clientId) : null;
    if (!app || !app.enabled) return oauthError(res, 401, 'invalid_client', '등록되지 않았거나 꺼진 앱입니다.');
    if (clientSecret && !clientSecretMatches(app, clientSecret)) return oauthError(res, 401, 'invalid_client', '앱 비밀이 맞지 않습니다.');

    if (b.grant_type === 'authorization_code') {
      const code = typeof b.code === 'string' ? b.code : '';
      const row = code ? await findOAuthRequestByCodeHash(lookupHash(code)) : null;
      if (!row || row.integrationId !== app.id || row.status !== 'issued' || oauthRequestExpired(row)) {
        return oauthError(res, 400, 'invalid_grant', '승인 코드가 없거나 이미 썼거나 만료됐습니다.');
      }
      if (b.redirect_uri !== row.redirectUri) return oauthError(res, 400, 'invalid_grant', 'redirect_uri가 승인 때와 다릅니다.');
      // PKCE를 걸었으면 늘 확인하고, 앱 비밀 없이 오면(휴대폰·명령줄 앱) PKCE가 있어야 한다.
      if (row.codeChallenge ? !verifyPkce(b.code_verifier, row.codeChallenge) : !clientSecret) {
        return oauthError(res, 400, 'invalid_grant', row.codeChallenge ? 'code_verifier가 맞지 않습니다.' : '앱 비밀이나 PKCE가 필요합니다.');
      }
      const used = await transitionOAuthRequest(row.id, 'issued', { status: 'used' });
      if (!used) return oauthError(res, 400, 'invalid_grant', '승인 코드를 이미 썼습니다.');
      const denial = await approvalDenial(app, row.userId);
      if (denial) return oauthError(res, 400, 'invalid_grant', denial);
      const grant = await upsertGrant({ integrationId: app.id, userId: row.userId, scopes: row.scopes });
      return res.set('cache-control', 'no-store').json(await issueTokens(app, grant));
    }

    if (b.grant_type === 'refresh_token') {
      const token = typeof b.refresh_token === 'string' ? b.refresh_token : '';
      const row = isSecretToken(token, OAUTH_REFRESH_PREFIX) ? await findUsableApiToken(lookupHash(token)) : null;
      const grant = row?.kind === 'refresh' && row.grantId ? await findGrantById(row.grantId) : null;
      if (!grant || grant.integrationId !== app.id) return oauthError(res, 400, 'invalid_grant', '다시 받기 토큰이 없거나 만료됐습니다.');
      // 쓴 다시 받기 토큰은 바로 못 쓰게 하고 새 한 쌍을 준다(새어 나간 토큰을 둘이 같이 쓰면 한쪽이 곧 막힌다).
      if (!(await revokeTokenById(row.id))) return oauthError(res, 400, 'invalid_grant', '다시 받기 토큰을 이미 썼습니다.');
      const denial = await approvalDenial(app, grant.userId);
      if (denial) return oauthError(res, 400, 'invalid_grant', denial);
      return res.set('cache-control', 'no-store').json(await issueTokens(app, grant));
    }
    return oauthError(res, 400, 'unsupported_grant_type', 'grant_type은 authorization_code·refresh_token만 됩니다.');
  });

  /** 토큰 끊기(RFC 7009) — 이 앱의 토큰이면 못 쓰게 하고, 모르는 토큰이어도 200. */
  router.post('/oauth/revoke', form, async (req, res) => {
    const b = req.body ?? {};
    const { clientId } = clientCredentialsOf(req.get('authorization'), b);
    const app = clientId ? await findAppByClientId(clientId) : null;
    const token = typeof b.token === 'string' ? b.token : '';
    if (app && (isSecretToken(token, OAUTH_ACCESS_PREFIX) || isSecretToken(token, OAUTH_REFRESH_PREFIX))) {
      const row = await findUsableApiToken(lookupHash(token));
      const grant = row?.grantId ? await findGrantById(row.grantId) : null;
      if (grant?.integrationId === app.id) await revokeTokenById(row.id);
    }
    res.status(200).end();
  });

  return router;
}

/** 로그인한 앱이 부르는 경로 — 코드로 승인·거절, 연결된 앱 목록·끊기(/api 아래, requireAuth). */
export function createOAuthRouter() {
  const router = Router();

  /** 넣은 코드의 승인 요청 — 아니면 응답을 보내고 null. */
  async function pendingRequest(req, res, code) {
    const wait = limits.oauthCodeUser.hit(req.user.sub);
    if (wait > 0) {
      retryLater(res, wait, `코드를 너무 많이 넣었습니다. ${waitText(wait)} 뒤에 다시 하세요.`);
      return null;
    }
    const userCode = normalizeUserCode(code);
    const row = userCode ? await findOAuthRequestByUserCode(userCode) : null;
    if (!row || row.status !== 'pending' || oauthRequestExpired(row)) {
      res.status(404).json({ error: '코드가 맞지 않거나 시간이 지났습니다. 브라우저의 코드를 다시 확인하세요.' });
      return null;
    }
    const app = await findIntegrationById(row.integrationId);
    if (!app || app.kind !== 'app' || !app.enabled) {
      res.status(404).json({ error: '앱을 찾을 수 없습니다.' });
      return null;
    }
    const denial = await approvalDenial(app, req.user.sub);
    if (denial) {
      res.status(403).json({ error: denial });
      return null;
    }
    return { row, app };
  }

  /** 코드 확인 `{ code }` → 앱·권한·돌아갈 곳(승인 창에 보인다). */
  router.post('/oauth/requests/lookup', async (req, res) => {
    const found = await pendingRequest(req, res, req.body?.code);
    if (!found) return;
    const { row, app } = found;
    const team = await findTeamById(app.teamId);
    res.json({
      id: row.id,
      app: { id: app.id, name: app.name, emoji: app.emoji ?? null, description: app.description ?? null },
      teamName: team?.name ?? null,
      scopes: row.scopes,
      redirectHost: redirectLabel(row.redirectUri),
      expiresAt: ms(row.expiresAt),
    });
  });

  /** 승인 `{ code }`·거절 — 코드를 다시 받아 같은 요청인지 본다(요청 id만으로는 승인하지 못하게). */
  for (const [action, status] of [
    ['approve', 'approved'],
    ['deny', 'denied'],
  ]) {
    router.post(`/oauth/requests/:id/${action}`, async (req, res) => {
      const found = await pendingRequest(req, res, req.body?.code);
      if (!found) return;
      if (found.row.id !== req.params.id) return res.status(404).json({ error: '코드가 맞지 않습니다.' });
      const updated = await transitionOAuthRequest(found.row.id, 'pending', { status, userId: req.user.sub });
      if (!updated) return res.status(409).json({ error: '이미 처리된 요청입니다.' });
      res.json({ ok: true });
    });
  }

  /** 내 연결된 앱 — 승인한 앱마다 이름·팀·권한·승인 시각·마지막 사용. */
  router.get('/users/me/connected-apps', async (req, res) => {
    const rows = await listUserGrants(req.user.sub);
    res.json(
      rows.map(({ grant, app, teamName }) => ({
        id: grant.id,
        app: { id: app.id, name: app.name, emoji: app.emoji ?? null, description: app.description ?? null },
        teamName: teamName ?? null,
        scopes: grant.scopes ?? [],
        createdAt: ms(grant.createdAt),
        lastUsedAt: ms(grant.lastUsedAt),
      })),
    );
  });

  /** 연결 끊기 — 승인을 지우면 그 앱의 토큰도 같이 지워져 바로 못 쓴다. */
  router.delete('/users/me/connected-apps/:id', async (req, res) => {
    if (!isUuid(req.params.id) || !(await deleteGrant(req.params.id, req.user.sub))) {
      return res.status(404).json({ error: '연결된 앱을 찾을 수 없습니다.' });
    }
    res.json({ ok: true });
  });

  return router;
}
