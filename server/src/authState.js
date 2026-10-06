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
