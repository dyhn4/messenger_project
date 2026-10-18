import { invalidateSsoSessionState } from './authState.js';
import { endSsoSession, endSsoSessionsBy, insertSsoSession } from './db/queries/loginSecurityExtras.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { microsoftLogoutUrl } from './ssoRules.js';
import { getWebPublicUrl } from './webAddress.js';

/**
 * 회사 계정 로그인 세션 — 로그아웃 연동. 회사 계정(Google·Microsoft·SAML)으로 들어오면 세션 하나를 만들어 그 id를 토큰(`ssid`)에
 * 싣고(sso.js), 끝나면 그 토큰은 갱신·요청·소켓에서 바로 막힌다(auth.js — authState.js ssoSessionActive).
 *  - 이 앱에서 로그아웃(POST /auth/logout): 그 세션을 끝내고, 관리자가 "회사 계정에서도 로그아웃"을 켰으면 그쪽 로그아웃 주소를 돌려준다
 *    (Microsoft는 Entra 로그아웃 주소, SAML은 서명한 LogoutRequest — Google은 회사 계정 쪽 로그아웃을 따로 열 수 없다).
 *  - 회사 계정 쪽에서 로그아웃: SAML IdP가 보낸 LogoutRequest(saml.js /auth/sso/saml/slo)·Microsoft 프런트 채널 로그아웃
 *    (/auth/sso/frontchannel-logout)이 그쪽 세션 값(SessionIndex·sid)으로 이 앱의 세션을 끝낸다. 그 세션의 기기 소켓도 끊는다.
 */

/** 로그인 세션 만들기 → id. */
export async function startSsoSession({ userId, provider, idpSessionId = null, nameId = null, nameIdFormat = null }) {
  const row = await insertSsoSession({
    userId,
    provider,
    idpSessionId: idpSessionId ? String(idpSessionId).slice(0, 500) : null,
    nameId: nameId ? String(nameId).slice(0, 1000) : null,
    nameIdFormat,
  });
  return row.id;
}

/** "로그아웃했습니다" 쪽지 주소(회사 계정 로그아웃이 끝나면 돌아올 곳). */
export const loggedOutPageUrl = () => {
  const base = getWebPublicUrl();
  return base ? `${base.replace(/\/+$/, '')}/auth/sso/logged-out` : null;
};

/**
 * 이 앱에서 로그아웃 — [ssid] 세션(그 사람의 것이어야 한다)을 끝내고, 회사 계정 쪽 로그아웃 주소(설정이 켜졌을 때) | null.
 */
export async function endSsoLogin(ssid, userId, reason) {
  const ended = await endSsoSession(ssid, reason);
  invalidateSsoSessionState(ssid);
  if (!ended || ended.userId !== userId) return null;
  const settings = await getServerSettings();
  if (!settings.ssoIdpLogout) return null;
  if (ended.provider === 'microsoft') return microsoftLogoutUrl(settings, loggedOutPageUrl());
  if (ended.provider === 'saml' && ended.nameId) {
    const { samlLogoutUrl } = await import('./saml.js');
    return samlLogoutUrl(settings, ended).catch((err) => {
      console.warn('[saml] 로그아웃 주소를 만들지 못했습니다:', err?.message ?? err);
      return null;
    });
  }
  return null;
}

/**
 * 회사 계정 쪽에서 로그아웃 — [provider]의 그쪽 세션 값([idpSessionId]) 또는 NameID([nameId])가 같은 세션을 끝내고, 그 사람들의 소켓을
 * 끊는다(다른 세션의 기기는 새 토큰으로 바로 다시 붙는다). 끝낸 세션 수.
 */
export async function endIdpSessions(io, { provider, idpSessionId = null, nameId = null }, reason) {
  if (!idpSessionId && !nameId) return 0;
  const ended = await endSsoSessionsBy({ provider, idpSessionId, nameId }, reason);
  const users = new Set();
  for (const row of ended) {
    invalidateSsoSessionState(row.id);
    users.add(row.userId);
  }
  for (const userId of users) io?.in(`user:${userId}`).disconnectSockets(true);
  return ended.length;
}
