/**
 * 화상회의 영상 화질 단계 — 참가자가 늘어 LiveKit(SFU)의 부담이 커지면 보내는 쪽(각 클라이언트)이 카메라·화면 공유의
 * 최대 해상도와 비트레이트를 스스로 낮춘다. 서버는 단계만 정해 call:state에 실어 보내고(calls.js), 실제 인코딩 값은
 * 클라이언트(client/lib/services/call_quality.dart)가 단계마다 정한다.
 *
 * 두 가지를 보고 더 낮은 쪽을 쓴다:
 *  - 그 통화의 참가자 수 — 한 사람이 받는 영상 수(내려받기)와 그 방이 SFU에 올리는 양이 함께 는다.
 *  - 이 서버 전체의 통화 참가자 수 — 여러 방이 동시에 회의하면 서버 한 대의 대역폭·CPU를 나눠 쓴다.
 *
 * 단계: fhd(1080p) → hd(720p) → sd(540p) → ld(360p).
 */
export const VIDEO_TIERS = ['fhd', 'hd', 'sd', 'ld'];

/** 한 통화의 참가자 수 기준 — 4명까지 1080p, 8명까지 720p, 16명까지 540p, 그 이상 360p. */
export const ROOM_TIER_LIMITS = [4, 8, 16];

/** 서버 전체 통화 참가자 수 기준 — 16명까지 1080p, 32명까지 720p, 64명까지 540p, 그 이상 360p. */
export const SERVER_TIER_LIMITS = [16, 32, 64];

function tierIndex(count, limits) {
  const i = limits.findIndex((limit) => count <= limit);
  return i === -1 ? limits.length : i;
}

/** [roomParticipants]명이 있는 통화의 화질 단계(서버 전체 참가자 [serverParticipants]명 기준과 둘 중 낮은 쪽). */
export function videoTierFor(roomParticipants, serverParticipants) {
  const index = Math.max(tierIndex(roomParticipants, ROOM_TIER_LIMITS), tierIndex(serverParticipants, SERVER_TIER_LIMITS));
  return VIDEO_TIERS[index];
}
