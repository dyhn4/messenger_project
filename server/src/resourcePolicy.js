import { DAY_MS, KST_OFFSET_MS } from './calendarRecurrence.js';
import { BOOKING_AHEAD_MS, overlaps } from './resourceRules.js';

/**
 * 회의실·자원 예약 후속(순수 규칙) — 자원마다의 예약 규칙(예약할 수 있는 사람·요일·시간대·한 번에 쓸 수 있는 시간, 관리자 승인), 매주 같은
 * 시간의 반복 예약, 참석자 수에 맞는 회의실 추천, 사용 통계, 시작 전 알림, 회의실 앞 태블릿 화면의 지금·다음 예약. 시각은 ms 순간이고
 * 요일·시간대는 한국 시각으로 본다(resourceRules.js와 같다). DB는 groupwareResources.js·roomDisplay.js. `node --test`로 시험한다
 * (test/resourceFollowup.test.js).
 */

/** 예약 상태 — 'confirmed'(잡힘) | 'pending'(관리자 승인을 기다림 — 그 시간은 이미 막는다). 거절하면 지운다. */
export const BOOKING_STATUSES = Object.freeze(['confirmed', 'pending']);
/** 자원마다 승인할 사람·예약할 수 있는 사람 수. */
export const RESOURCE_PEOPLE_MAX = 50;
/** 반복 예약 — 매주(또는 2주마다) 같은 시간, 최대 회차. */
export const SERIES_MAX = 26;
export const SERIES_EVERY_WEEKS = Object.freeze([1, 2]);
/** 일정 하나에 붙일 수 있는 자원 수(회의실 + 장비). */
export const EVENT_RESOURCES_MAX = 5;
/** 시작 전 알림(분) — 0이면 끔. */
export const BOOKING_REMINDER_MAX = 120;
export const BOOKING_REMINDER_DEFAULT = 10;
/** 태블릿에서 바로 잡는 시간(분). */
export const QUICK_BOOK_MINUTES = Object.freeze([15, 30, 60]);

const isIdList = (v) => Array.isArray(v) && v.every((id) => typeof id === 'string' && /^[0-9a-f-]{36}$/i.test(id));
const kst = (ms) => new Date(ms + KST_OFFSET_MS);
/** 한국 시각의 요일(0 = 일)·하루 중 분. */
const weekdayOf = (ms) => kst(ms).getUTCDay();
const minuteOf = (ms) => kst(ms).getUTCHours() * 60 + kst(ms).getUTCMinutes();
const kstDayStart = (ms) => {
  const d = kst(ms);
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()) - KST_OFFSET_MS;
};

/**
 * 자원의 예약 규칙 입력 `{ requiresApproval?, approverIds?, allowedUserIds?, availableFrom?, availableTo?, availableDays?, maxMinutes?,
 * displayQuickBook? }`(시간대는 하루 중 분, 요일은 0=일 ~ 6=토) → `{ values }`(보낸 것만) | `{ error }`. [isCandidate]는 이 범위에서 고를 수
 * 있는 사람인지. 승인이 필요한 자원은 승인할 사람이 한 명은 있어야 한다(없으면 그룹웨어 관리자가 승인 — 그래도 된다).
 */
export function parseResourcePolicy(body, { isCandidate = () => true, current = {} } = {}) {
  const b = body ?? {};
  const values = {};
  if (b.requiresApproval !== undefined) {
    if (typeof b.requiresApproval !== 'boolean') return { error: '승인 필요 여부를 확인하세요.' };
    values.requiresApproval = b.requiresApproval;
  }
  // 오류 문구는 칸마다 문장 전체로(앱이 통째로 번역한다).
  const MESSAGES = {
    approverIds: ['승인할 사람을 확인하세요.', `승인할 사람은 ${RESOURCE_PEOPLE_MAX}명까지입니다.`, '승인할 사람에 고를 수 없는 사람이 있습니다.'],
    allowedUserIds: ['예약할 수 있는 사람을 확인하세요.', `예약할 수 있는 사람은 ${RESOURCE_PEOPLE_MAX}명까지입니다.`, '예약할 수 있는 사람에 고를 수 없는 사람이 있습니다.'],
  };
  for (const key of ['approverIds', 'allowedUserIds']) {
    const [badShape, tooMany, notCandidate] = MESSAGES[key];
    if (b[key] === undefined) continue;
    const list = b[key] === null ? [] : b[key];
    if (!isIdList(list)) return { error: badShape };
    const unique = [...new Set(list)];
    if (unique.length > RESOURCE_PEOPLE_MAX) return { error: tooMany };
    if (!unique.every(isCandidate)) return { error: notCandidate };
    values[key] = unique;
  }
  const hasFrom = b.availableFrom !== undefined;
  const hasTo = b.availableTo !== undefined;
  if (hasFrom || hasTo) {
    const from = hasFrom ? b.availableFrom : (current.availableFrom ?? null);
    const to = hasTo ? b.availableTo : (current.availableTo ?? null);
    if ((from === null) !== (to === null)) return { error: '예약할 수 있는 시간대는 시작과 끝을 함께 정하세요.' };
    if (from !== null) {
      if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to > 24 * 60 || from >= to) {
        return { error: '예약할 수 있는 시간대를 확인하세요(시작이 끝보다 앞).' };
      }
    }
    values.availableFrom = from;
    values.availableTo = to;
  }
  if (b.availableDays !== undefined) {
    if (b.availableDays === null) values.availableDays = null;
    else {
      const days = Array.isArray(b.availableDays) ? [...new Set(b.availableDays)].sort() : null;
      if (!days || days.length === 0 || !days.every((d) => Number.isInteger(d) && d >= 0 && d <= 6)) {
        return { error: '예약할 수 있는 요일을 하나 이상 고르세요.' };
      }
      values.availableDays = days.length === 7 ? null : days;
    }
  }
  if (b.maxMinutes !== undefined) {
    const n = b.maxMinutes;
    if (n === null) values.maxMinutes = null;
    else if (!Number.isInteger(n) || n < 15 || n > 7 * 24 * 60) return { error: '한 번에 쓸 수 있는 시간은 15분~7일로 정하세요.' };
    else values.maxMinutes = n;
  }
  if (b.displayQuickBook !== undefined) {
    if (typeof b.displayQuickBook !== 'boolean') return { error: '태블릿에서 바로 예약 여부를 확인하세요.' };
    values.displayQuickBook = b.displayQuickBook;
  }
  return { values };
}

/** 이 사람이 이 자원의 승인자인지(자원에 정한 승인할 사람, 또는 그룹웨어 관리자). */
export const isApproverOf = (resource, { userId, isManager = false }) =>
  isManager || (Array.isArray(resource.approverIds) && resource.approverIds.includes(userId));

const hm = (m) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
const DAY_NAMES = ['일', '월', '화', '수', '목', '금', '토'];

/**
 * 자원의 예약 규칙 검사 — 예약할 수 있는 사람(비면 모두 — [privileged](그룹웨어 관리자)는 늘 됨), 요일·시간대(시작과 끝이 그 안 — 여러 날
 * 예약은 시작·끝 날만 본다), 한 번에 쓸 수 있는 시간. 막히면 `{ error }`, 아니면 null.
 */
export function checkBookingPolicy(resource, { userId, startMs, endMs, privileged = false }) {
  const allowed = Array.isArray(resource.allowedUserIds) ? resource.allowedUserIds : [];
  if (!privileged && allowed.length > 0 && !allowed.includes(userId)) {
    return { error: `${resource.name}은(는) 정해진 사람만 예약할 수 있습니다.` };
  }
  if (resource.maxMinutes && endMs - startMs > resource.maxMinutes * 60_000) {
    return { error: `${resource.name}은(는) 한 번에 ${durationText(resource.maxMinutes)}까지 예약할 수 있습니다.` };
  }
  const days = Array.isArray(resource.availableDays) ? resource.availableDays : null;
  if (days && (!days.includes(weekdayOf(startMs)) || !days.includes(weekdayOf(endMs - 1)))) {
    return { error: `${resource.name}은(는) ${days.map((d) => DAY_NAMES[d]).join('·')}요일에만 예약할 수 있습니다.` };
  }
  if (resource.availableFrom != null && resource.availableTo != null) {
    const s = minuteOf(startMs);
    // 끝이 자정이면(다음 날 00:00) 24:00으로 본다.
    const eRaw = minuteOf(endMs);
    const e = eRaw === 0 && endMs > startMs ? 24 * 60 : eRaw;
    if (s < resource.availableFrom || e > resource.availableTo || (endMs - startMs < DAY_MS && e < s)) {
      return { error: `${resource.name}은(는) ${hm(resource.availableFrom)}~${hm(resource.availableTo)}에만 예약할 수 있습니다.` };
    }
  }
  return null;
}

/** 분 → "2시간" · "1시간 30분" · "45분" · "3일". */
export function durationText(minutes) {
  if (minutes % (24 * 60) === 0) return `${minutes / (24 * 60)}일`;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return h && m ? `${h}시간 ${m}분` : h ? `${h}시간` : `${m}분`;
}

/** 새 예약의 상태 — 승인이 필요한 자원이면 'pending'(승인할 사람·관리자가 잡으면 바로 'confirmed'). */
export const initialBookingStatus = (resource, { userId, isManager = false }) =>
  resource.requiresApproval && !isApproverOf(resource, { userId, isManager }) ? 'pending' : 'confirmed';

/**
 * 반복 예약 입력 `{ repeatWeeks?(회차 수, 1이면 반복 없음), everyWeeks?(1 | 2) }` → 회차들 `[{ startMs, endMs }]`(첫 회차 포함, 같은 한국
 * 시각 — 7일 × everyWeeks 간격, 180일 앞까지) | `{ error }`.
 */
export function seriesOccurrences({ startMs, endMs, repeatWeeks = 1, everyWeeks = 1, now = Date.now() }) {
  const count = Number(repeatWeeks);
  const every = Number(everyWeeks);
  if (!Number.isInteger(count) || count < 1 || count > SERIES_MAX) return { error: `반복은 1~${SERIES_MAX}회로 정하세요.` };
  if (!SERIES_EVERY_WEEKS.includes(every)) return { error: '반복 간격은 매주 또는 2주마다입니다.' };
  if (count > 1 && endMs - startMs > 7 * every * DAY_MS) return { error: '반복 예약은 한 회차가 반복 간격보다 짧아야 합니다.' };
  const out = [];
  for (let i = 0; i < count; i += 1) {
    // 한국에는 서머타임이 없어 7일 = 7 × 24시간이다.
    const s = startMs + i * every * 7 * DAY_MS;
    out.push({ startMs: s, endMs: s + (endMs - startMs) });
  }
  if (out[out.length - 1].startMs > now + BOOKING_AHEAD_MS) return { error: '반복 예약의 마지막 회차가 180일 앞을 넘습니다. 회차를 줄이세요.' };
  return { occurrences: out };
}

/**
 * 반복 예약 회차들 가운데 [existing](그 자원의 예약들 `{ startAt, endAt }`)과 겹치는 것을 나눈다 → `{ free, conflicts }`(회차 순).
 */
export function splitSeriesConflicts(occurrences, existing) {
  const busy = existing.map((b) => ({ startMs: new Date(b.startAt).getTime(), endMs: new Date(b.endAt).getTime(), booking: b }));
  const free = [];
  const conflicts = [];
  for (const o of occurrences) {
    const hit = busy.find((b) => overlaps(o, b));
    if (hit) conflicts.push({ ...o, with: hit.booking });
    else free.push(o);
  }
  return { free, conflicts };
}

/**
 * 참석자 수에 맞는 회의실 추천 — 켜진 자원 중 [kind](기본 회의실)이고, [startMs, endMs)에 비어 있고([busy] — 그 시간의 예약들), 이 사람이
 * 예약할 수 있고(checkBookingPolicy), 수용 인원이 [attendees] 이상인 것. 남는 자리가 적은 것부터(딱 맞는 방), 수용 인원을 모르는 방은 뒤에.
 * `[{ resource, spare(남는 자리 — 모르면 null), needsApproval }]`.
 */
export function suggestResources({ resources, busy, startMs, endMs, attendees = 0, kind = 'room', userId, privileged = false }) {
  const taken = new Set(busy.filter((b) => overlaps({ startMs, endMs }, { startMs: new Date(b.startAt).getTime(), endMs: new Date(b.endAt).getTime() })).map((b) => b.resourceId));
  const out = [];
  for (const r of resources) {
    if (!r.enabled || (kind && r.kind !== kind) || taken.has(r.id)) continue;
    if (checkBookingPolicy(r, { userId, startMs, endMs, privileged })) continue;
    if (r.capacity != null && r.capacity < attendees) continue;
    out.push({ resource: r, spare: r.capacity == null ? null : r.capacity - attendees, needsApproval: !!r.requiresApproval && !privileged && !isApproverOf(r, { userId }) });
  }
  return out.sort((a, b) => (a.spare ?? Infinity) - (b.spare ?? Infinity) || a.resource.name.localeCompare(b.resource.name, 'ko'));
}

/**
 * 사용 통계 — [fromMs, toMs) 동안 자원마다 예약 건수·쓴 시간(분 — 구간 안만)·쓴 사람 수·많이 쓴 사람(3명)·요일별 건수(0=일)·이용률(쓴 시간 /
 * 쓸 수 있던 시간 — 자원의 요일·시간대, 없으면 평일 09:00~18:00 — 100%까지). 승인 기다리는 예약은 뺀다.
 */
export function resourceStats({ resources, bookings, fromMs, toMs }) {
  const rows = resources.map((r) => ({
    resourceId: r.id,
    name: r.name,
    kind: r.kind,
    count: 0,
    minutes: 0,
    users: new Map(),
    byWeekday: [0, 0, 0, 0, 0, 0, 0],
    availableMinutes: availableMinutesOf(r, fromMs, toMs),
  }));
  const byId = new Map(rows.map((x) => [x.resourceId, x]));
  for (const b of bookings) {
    const row = byId.get(b.resourceId);
    if (!row || b.status === 'pending') continue;
    const s = Math.max(new Date(b.startAt).getTime(), fromMs);
    const e = Math.min(new Date(b.endAt).getTime(), toMs);
    if (e <= s) continue;
    row.count += 1;
    row.minutes += Math.round((e - s) / 60_000);
    row.byWeekday[weekdayOf(s)] += 1;
    const key = b.userName ?? '(알 수 없음)';
    row.users.set(key, (row.users.get(key) ?? 0) + 1);
  }
  return rows.map(({ users, ...x }) => ({
    ...x,
    userCount: users.size,
    topUsers: [...users.entries()]
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0], 'ko'))
      .slice(0, 3)
      .map(([name, count]) => ({ name, count })),
    utilization: x.availableMinutes > 0 ? Math.min(100, Math.round((x.minutes / x.availableMinutes) * 1000) / 10) : null,
  }));
}

/** 자원을 쓸 수 있던 시간(분) — 구간의 날마다 그 요일이면 시간대만큼. */
function availableMinutesOf(r, fromMs, toMs) {
  const days = Array.isArray(r.availableDays) ? r.availableDays : [1, 2, 3, 4, 5];
  const from = r.availableFrom ?? 9 * 60;
  const to = r.availableTo ?? 18 * 60;
  let total = 0;
  for (let day = kstDayStart(fromMs); day < toMs; day += DAY_MS) {
    if (!days.includes(weekdayOf(day))) continue;
    const s = Math.max(day + from * 60_000, fromMs);
    const e = Math.min(day + to * 60_000, toMs);
    if (e > s) total += Math.round((e - s) / 60_000);
  }
  return total;
}

/**
 * 지금 시작 전 알림을 보낼 예약들 — 잡힌(승인된) 예약 중 아직 안 알렸고, 시작이 지금부터 그 범위의 알림 분([leadOf](scopeKey) — 0이면 끔)
 * 안에 드는 것. 이미 시작한 예약은 알리지 않는다.
 */
export function remindersDue(bookings, { now, leadOf }) {
  return bookings.filter((b) => {
    if (b.status === 'pending' || b.remindedAt || !b.userId) return false;
    const lead = leadOf(b.scopeKey);
    if (!lead) return false;
    const start = new Date(b.startAt).getTime();
    return start > now && start - now <= lead * 60_000;
  });
}

/**
 * 회의실 앞 태블릿 화면 — [bookings](그 자원의 오늘·내일 예약, 시작 순)로 지금 쓰는 예약·오늘 남은 예약·언제까지 비는지.
 * `{ current, upcoming(오늘 남은 것 — 5개까지), freeUntil(지금 비어 있으면 다음 예약 시작 — 없으면 null), busyUntil }`. 승인 기다리는 예약은
 * 쓰는 것으로 보되 표시만 한다.
 */
export function displayState(bookings, now) {
  const sorted = [...bookings].sort((a, b) => new Date(a.startAt) - new Date(b.startAt));
  const current = sorted.find((b) => new Date(b.startAt).getTime() <= now && new Date(b.endAt).getTime() > now) ?? null;
  const dayEnd = kstDayStart(now) + DAY_MS;
  const upcoming = sorted.filter((b) => new Date(b.startAt).getTime() > now && new Date(b.startAt).getTime() < dayEnd).slice(0, 5);
  const next = sorted.find((b) => new Date(b.startAt).getTime() > now) ?? null;
  // 이어진 예약들은 하나로 — 지금 예약이 끝나는 때에 다음 예약이 바로 붙어 있으면 그 끝까지 쓰는 중.
  let busyUntil = current ? new Date(current.endAt).getTime() : null;
  if (busyUntil) {
    for (const b of sorted) {
      const s = new Date(b.startAt).getTime();
      if (s <= busyUntil && new Date(b.endAt).getTime() > busyUntil) busyUntil = new Date(b.endAt).getTime();
    }
  }
  return { current, upcoming, freeUntil: current ? null : next ? new Date(next.startAt).getTime() : null, busyUntil };
}

/** 태블릿에서 바로 잡기 — [minutes](15·30·60)분을 지금부터, 다음 예약과 겹치지 않게. `{ startMs, endMs }` | `{ error }`. */
export function quickBookRange({ minutes, now, freeUntil, current }) {
  if (!QUICK_BOOK_MINUTES.includes(minutes)) return { error: '15·30·60분 중에서 고르세요.' };
  if (current) return { error: '지금 쓰는 중인 회의실입니다.' };
  // 분 단위로 내려 맞춘다(시계와 맞게).
  const startMs = Math.floor(now / 60_000) * 60_000;
  const endMs = startMs + minutes * 60_000;
  if (freeUntil && endMs > freeUntil) return { error: '다음 예약과 겹칩니다. 더 짧게 고르세요.' };
  return { startMs, endMs };
}
