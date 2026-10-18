import { findActiveDeviceForUser } from './db/queries/devices.js';
import { findUserById } from './db/queries/users.js';

/**
 * REST 요청마다 "이 토큰이 아직 살아 있는 계정의 것인지"를 확인할 때 쓰는 계정 상태 캐시(auth.js requireAuth).
 *
 * 예전엔 REST는 토큰 서명·만료만 봐서, 정지·강제 로그아웃·비밀번호 변경 뒤에도 이미 받은 AccessToken(최대 1시간)으로
 * 계속 API를 쓸 수 있었다(소켓만 바로 끊겼다). 요청마다 DB를 읽으면 부담이라 30초 동안 기억해 두고, 상태를 바꾸는
 * 쪽(updateUser)이 바로 지워서 바뀐 즉시 막히게 한다.
 */
const TTL_MS = 30_000;
const cache = new Map(); // userId → { at, tokenVersion, blocked }

export async function accountState(userId) {
  const hit = cache.get(userId);
  if (hit && Date.now() - hit.at < TTL_MS) return hit;
  const user = await findUserById(userId);
  const state = {
    at: Date.now(),
    tokenVersion: user?.tokenVersion ?? 0,
    blocked: !user || !!user.suspendedAt || !!user.deletedAt,
  };
  cache.set(userId, state);
  if (cache.size > 10_000) cache.delete(cache.keys().next().value);
  return state;
}

/** 계정 상태(토큰 버전·정지·탈퇴)가 바뀌었을 때 — 다음 요청부터 바로 다시 읽게 한다. */
export function invalidateAccountState(userId) {
  cache.delete(userId);
}

const deviceCache = new Map(); // `${userId}|${deviceId}` → { at, active }

/**
 * 기기에 묶인 토큰(`did` — auth.js issueTokenPair)의 그 기기가 아직 로그인돼 있는지 — 이 사람의 기기이고 "내 기기"에서
 * 로그아웃(revoked)되지 않았으면 true. 계정 상태와 같은 30초 캐시이고, 로그아웃시키면 그 자리에서 지운다
 * ([invalidateDeviceState]).
 */
export async function deviceActive(deviceId, userId) {
  const key = `${userId}|${deviceId}`;
  const hit = deviceCache.get(key);
  if (hit && Date.now() - hit.at < TTL_MS) return hit.active;
  const active = !!(await findActiveDeviceForUser(deviceId, userId));
  deviceCache.set(key, { at: Date.now(), active });
  if (deviceCache.size > 10_000) deviceCache.delete(deviceCache.keys().next().value);
  return active;
}

/** 기기를 로그아웃시켰거나 다시 등록했을 때 — 다음 요청부터 바로 다시 읽게 한다. */
export function invalidateDeviceState(deviceId, userId) {
  deviceCache.delete(`${userId}|${deviceId}`);
}

const ssoCache = new Map(); // ssoSessionId → { at, active }

/**
 * 회사 계정 로그인 세션(`ssid` — auth.js issueTokenPair)이 아직 살아 있는지 — 회사 계정 쪽에서 로그아웃했거나(SAML SLO·Microsoft
 * 프런트 채널 로그아웃) 이 앱에서 로그아웃하면 끝난다(sso_sessions.ended_at). 계정 상태와 같은 30초 캐시이고, 끝낼 때 그 자리에서
 * 지운다([invalidateSsoSessionState]).
 */
export async function ssoSessionActive(ssid, userId) {
  const hit = ssoCache.get(ssid);
  if (hit && Date.now() - hit.at < TTL_MS) return hit.active && hit.userId === userId;
  const { findSsoSessionById } = await import('./db/queries/loginSecurityExtras.js');
  const row = await findSsoSessionById(ssid);
  const entry = { at: Date.now(), active: !!row && !row.endedAt, userId: row?.userId ?? null };
  ssoCache.set(ssid, entry);
  if (ssoCache.size > 10_000) ssoCache.delete(ssoCache.keys().next().value);
  return entry.active && entry.userId === userId;
}

/** 회사 계정 세션을 끝냈을 때 — 다음 요청부터 바로 막히게. */
export function invalidateSsoSessionState(ssid) {
  ssoCache.delete(ssid);
}
