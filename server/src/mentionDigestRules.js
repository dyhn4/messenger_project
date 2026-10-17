/**
 * 오래 접속하지 않은 사람에게 보내는 멘션 요약 메일의 규칙 — 누구에게, 언제, 어떤 멘션을 넣을지. DB·메일 없이 시험할 수 있게
 * 계산만 모았다(실제로 모으고 보내는 쪽은 mentionDigest.js).
 */

const DAY = 24 * 60 * 60 * 1000;

/** 하루 중 요약 메일을 보내는 시각(서버 PC 시각) — 출근 무렵에 받아 보게. */
export const DIGEST_HOUR = 9;
/** 메일 한 통에 하나씩 적는 멘션 수 — 나머지는 "외 N개"로. */
export const DIGEST_ITEMS_MAX = 10;
/** 이보다 오래된 안 읽은 멘션은 넣지 않는다(알림 기록도 90일이면 지워진다 — retention.js). */
export const DIGEST_LOOKBACK_MS = 30 * DAY;

/** 지금이 요약을 보낼 시간인지. 서버는 30분마다 들여다보고, 이 시간대에 든 첫 번째에만 보낸다(같은 날 두 번은 간격이 막는다). */
export function isDigestHour(now = new Date()) {
  return new Date(now).getHours() === DIGEST_HOUR;
}

/**
 * 마지막으로 앱이 붙어 있던 시각 — 계정에 적힌 값(socket.js가 적는다)과 기기들의 마지막 접속 중 늦은 쪽. 둘 다 없으면(이 기능
 * 전에 가입해 한 번도 다시 안 붙은 사람) 가입 시각.
 */
export function lastSeenOf({ lastSeenAt = null, deviceLastSeenAt = null, createdAt = null }) {
  const times = [lastSeenAt, deviceLastSeenAt].filter(Boolean).map((t) => new Date(t).getTime());
  if (times.length > 0) return new Date(Math.max(...times));
  return createdAt ? new Date(createdAt) : null;
}

/**
 * 이 사람에게 지금 요약을 보낼 차례인지 — [days]일 넘게 접속하지 않았고, 지난 요약에서 [days]일이 지났을 때(계속 안 들어와도
 * [days]일에 한 번보다 자주 보내지 않는다). 지금 접속해 있는 사람은 부르는 쪽이 먼저 뺀다.
 */
export function digestDue({ now = new Date(), lastSeen, sentAt = null, days }) {
  const nowMs = new Date(now).getTime();
  const gap = days * DAY;
  if (!lastSeen || nowMs - new Date(lastSeen).getTime() < gap) return false;
  return !sentAt || nowMs - new Date(sentAt).getTime() >= gap;
}

/** 이번 요약에 넣을 멘션의 시작 시각 — 지난 요약 뒤에 온 것만(같은 멘션을 두 번 알리지 않게), 그리고 [DIGEST_LOOKBACK_MS] 안. */
export function digestWindowStart({ now = new Date(), sentAt = null }) {
  const floor = new Date(now).getTime() - DIGEST_LOOKBACK_MS;
  return new Date(sentAt ? Math.max(floor, new Date(sentAt).getTime()) : floor);
}

/**
 * 요약에 넣을 멘션 — [rows]는 안 읽은 멘션 알림(어느 순서든). @all을 꺼 둔 사람([mentionAll] 거짓)에게는 @all을 빼고, 최신순으로
 * [DIGEST_ITEMS_MAX]개만 남긴다. `{ items, total }`.
 */
export function pickDigestItems(rows, { mentionAll = true } = {}) {
  const kept = rows
    .filter((r) => r.kind === 'mention' || (mentionAll && r.kind === 'mention_all'))
    .sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime());
  return { items: kept.slice(0, DIGEST_ITEMS_MAX), total: kept.length };
}
