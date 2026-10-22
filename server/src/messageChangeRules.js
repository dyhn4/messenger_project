/**
 * "이후 바뀐 것" 동기화 규칙(messageChanges.js) — 커서 모양, 페이지 크기, 바뀐 메시지와 지운 흔적을 한 줄로 합치기. DB 없이 시험한다.
 *
 * 커서는 `<ms>` 또는 `<ms>:<메시지 id>` — (바뀐 시각, id) 순서의 마지막 자리다. 같은 시각에 여럿이 바뀌어도(탈퇴한 사람의 이름을
 * 한 번에 고침 등) 페이지 사이에서 건너뛰지 않게 id까지 둔다. 시각만 있으면 그 시각까지는 다 받았다는 뜻이다.
 */

/** 이보다 최근에 바뀐 것은 아직 주지 않는다 — 트랜잭션 시작 시각으로 찍혀 늦게 커밋된 변화를 커서가 앞질러 놓치지 않게(그동안의
 * 변화는 실시간 연결로 받고, 다음 동기화가 이 자리부터 다시 본다). */
export const CHANGES_HORIZON_MS = 30_000;
export const CHANGES_PAGE_DEFAULT = 200;
export const CHANGES_PAGE_MAX = 500;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** 커서 → `{ since: Date, afterId }`, 없으면 null(처음 — 지금 자리만 알려 준다), 모양이 틀리면 `{ error }`. */
export function parseChangesCursor(raw) {
  if (raw === undefined || raw === null || raw === '') return null;
  if (typeof raw !== 'string') return { error: '동기화 자리가 올바르지 않습니다.' };
  const [msText, id, ...rest] = raw.split(':');
  const ms = Number(msText);
  if (rest.length > 0 || !/^\d+$/.test(msText) || !Number.isSafeInteger(ms)) {
    return { error: '동기화 자리가 올바르지 않습니다.' };
  }
  if (id !== undefined && !UUID_RE.test(id)) return { error: '동기화 자리가 올바르지 않습니다.' };
  return { since: new Date(ms), afterId: id ?? null };
}

export function formatChangesCursor(at, id = null) {
  const ms = at instanceof Date ? at.getTime() : Number(at);
  return id ? `${ms}:${id}` : String(ms);
}

/** 이번에 볼 끝 — 지금보다 [CHANGES_HORIZON_MS] 앞(밀리초 단위). */
export const changesHorizon = (nowMs) => new Date(Math.floor(nowMs) - CHANGES_HORIZON_MS);

export function changesPageSize(raw) {
  const n = Math.floor(Number(raw));
  if (!Number.isFinite(n) || n <= 0) return CHANGES_PAGE_DEFAULT;
  return Math.min(n, CHANGES_PAGE_MAX);
}

/**
 * 바뀐 메시지([changed] — changedAt 순)와 지운 흔적([removed] — removedAt 순, 각각 [limit]+1개까지 받아 온 것)을 (시각, id) 순으로
 * 합쳐 [limit]개만. `{ changed, removed, more, cursor(더 있으면 마지막 자리, 없으면 null) }`.
 */
export function mergeChangePage(changed, removed, limit) {
  const items = [
    ...changed.map((m) => ({ at: new Date(m.changedAt).getTime(), id: m.id, message: m })),
    ...removed.map((r) => ({ at: new Date(r.removedAt).getTime(), id: r.id, removal: r })),
  ].sort((a, b) => a.at - b.at || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const page = items.slice(0, limit);
  const more = items.length > limit;
  const last = page[page.length - 1];
  return {
    changed: page.filter((i) => i.message).map((i) => i.message),
    removed: page.filter((i) => i.removal).map((i) => i.removal),
    more,
    cursor: more && last ? formatChangesCursor(last.at, last.id) : null,
  };
}
