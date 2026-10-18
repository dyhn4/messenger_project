import { DAY_MS, KST_OFFSET_MS } from './calendarRecurrence.js';

/**
 * 회의실·자원 예약 규칙 — 자원 입력 검사, 예약 시간 검사, 겹침, 캘린더 일정의 예약 구간(groupwareResources.js·calendars.js가 쓴다).
 * 시각은 모두 ms 순간이다. 종일 일정은 한국 날짜의 자정~다음 날 자정을 잡는다.
 */

export const RESOURCE_KINDS = Object.freeze(['room', 'equipment', 'vehicle']);
export const RESOURCE_KIND_LABEL = Object.freeze({ room: '회의실', equipment: '장비', vehicle: '차량' });

export const RESOURCE_NAME_MAX = 30;
export const RESOURCE_LOCATION_MAX = 50;
export const RESOURCE_DESCRIPTION_MAX = 200;
export const RESOURCE_CAPACITY_MAX = 1000;
/** 범위마다 자원 수 상한. */
export const RESOURCES_MAX = 100;
export const BOOKING_TITLE_MAX = 50;
/** 예약 한 건의 길이 상한(차량·장비의 며칠 대여까지). */
export const BOOKING_MAX_MS = 7 * DAY_MS;
/** 얼마나 앞까지 예약할 수 있는지. */
export const BOOKING_AHEAD_MS = 180 * DAY_MS;
/** 한 사람이 한 범위에 잡아 둘 수 있는 앞으로의 예약 수. */
export const BOOKINGS_PER_USER_MAX = 100;
/** 예약 현황 조회 구간 상한. */
export const BOOKING_QUERY_MAX_MS = 31 * DAY_MS;

const ms = (v) => (v ? new Date(v).getTime() : null);
const clean = (v) => (typeof v === 'string' ? v.trim() : '');
const length = (s) => [...s].length;

/**
 * 자원 입력 `{ kind, name, location?, capacity?, description?, enabled?, sortOrder? }` → `{ values }` | `{ error }`. [partial]이면(고치기)
 * 보낸 칸만 검사해서 돌려준다.
 */
export function parseResourceInput(body, { partial = false } = {}) {
  const b = body ?? {};
  const values = {};
  if (!partial || b.kind !== undefined) {
    const kind = b.kind ?? 'room';
    if (!RESOURCE_KINDS.includes(kind)) return { error: '자원 종류를 확인하세요.' };
    values.kind = kind;
  }
  if (!partial || b.name !== undefined) {
    const name = clean(b.name);
    if (!name) return { error: '자원 이름을 넣으세요.' };
    if (length(name) > RESOURCE_NAME_MAX) return { error: `자원 이름은 ${RESOURCE_NAME_MAX}자 이내로 넣으세요.` };
    values.name = name;
  }
  for (const [key, label, max] of [
    ['location', '위치', RESOURCE_LOCATION_MAX],
    ['description', '설명', RESOURCE_DESCRIPTION_MAX],
  ]) {
    if (partial && b[key] === undefined) continue;
    if (b[key] !== null && b[key] !== undefined && typeof b[key] !== 'string') return { error: `${label}을(를) 확인하세요.` };
    const v = clean(b[key]);
    if (length(v) > max) return { error: `${label}은(는) ${max}자 이내로 넣으세요.` };
    values[key] = v || null;
  }
  if (!partial || b.capacity !== undefined) {
    const c = b.capacity;
    if (c === null || c === undefined || c === '') values.capacity = null;
    else if (!Number.isInteger(c) || c < 1 || c > RESOURCE_CAPACITY_MAX) return { error: `수용 인원은 1~${RESOURCE_CAPACITY_MAX}명으로 넣으세요.` };
    else values.capacity = c;
  }
  if (b.enabled !== undefined) {
    if (typeof b.enabled !== 'boolean') return { error: '켜고 끄기를 확인하세요.' };
    values.enabled = b.enabled;
  }
  if (b.sortOrder !== undefined) {
    if (!Number.isInteger(b.sortOrder) || b.sortOrder < 0 || b.sortOrder > 10000) return { error: '순서를 확인하세요.' };
    values.sortOrder = b.sortOrder;
  }
  if (partial && Object.keys(values).length === 0) return { error: '바꿀 내용이 없습니다.' };
  return { values };
}

/**
 * 예약 시간 검사 — [startMs, endMs)가 순서대로이고 7일 이하, 끝이 [now]보다 뒤(지난 시간은 잡지 않음), 시작이 180일 안. `{ startMs, endMs }` | `{ error }`.
 */
export function parseBookingTimes(start, end, now = Date.now()) {
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end)) return { error: '예약 시간을 확인하세요.' };
  if (end <= start) return { error: '끝 시각은 시작 시각보다 뒤여야 합니다.' };
  if (end - start > BOOKING_MAX_MS) return { error: '예약은 한 번에 7일까지입니다.' };
  if (end <= now) return { error: '지난 시간은 예약할 수 없습니다.' };
  if (start > now + BOOKING_AHEAD_MS) return { error: '예약은 180일 앞까지만 잡을 수 있습니다.' };
  return { startMs: start, endMs: end };
}

/** 예약 제목(그룹웨어에서 바로 잡을 때) — 비우면 "<자원 이름> 예약". */
export function parseBookingTitle(raw, resourceName) {
  if (raw !== undefined && raw !== null && typeof raw !== 'string') return { error: '제목을 확인하세요.' };
  const title = clean(raw);
  if (length(title) > BOOKING_TITLE_MAX) return { error: `제목은 ${BOOKING_TITLE_MAX}자 이내로 넣으세요.` };
  return { title: title || `${resourceName} 예약` };
}

/** 두 구간 [a.startMs, a.endMs)·[b.startMs, b.endMs)가 겹치는지(끝과 시작이 맞닿으면 겹치지 않음). */
export const overlaps = (a, b) => a.startMs < b.endMs && b.startMs < a.endMs;

/** 캘린더 일정이 잡을 구간 — 시간 일정은 그대로, 종일 일정(날짜를 UTC 자정으로 본 ms)은 한국 날짜의 자정부터. */
export function eventBookingRange({ startMs, endMs, allDay }) {
  return allDay ? { startMs: startMs - KST_OFFSET_MS, endMs: endMs - KST_OFFSET_MS } : { startMs, endMs };
}

/** 한국 시각 "M/D HH:MM" — 겹침 안내 글. */
export function kstText(ms) {
  const d = new Date(ms + KST_OFFSET_MS);
  const hh = String(d.getUTCHours()).padStart(2, '0');
  const mm = String(d.getUTCMinutes()).padStart(2, '0');
  return `${d.getUTCMonth() + 1}/${d.getUTCDate()} ${hh}:${mm}`;
}

/** 겹친 예약을 알리는 글 — "이미 예약된 시간입니다 (10/20 10:00~11:00 홍길동)". */
export function conflictText(booking) {
  const start = booking.startAt.getTime();
  const end = booking.endAt.getTime();
  const endText = kstText(end);
  const sameDay = kstText(start).split(' ')[0] === endText.split(' ')[0];
  return `이미 예약된 시간입니다 (${kstText(start)}~${sameDay ? endText.split(' ')[1] : endText} ${booking.userName})`;
}

/**
 * 예약 줄(listBookingsInRange 등) → 화면에 줄 모양. 일정에 붙은 예약은 일정 제목을 쓰고, 비공개 일정이면 잡은 사람·일정 만든 사람이 아닌
 * 사람에게는 "비공개 일정"으로 보인다.
 */
export function bookingDto(b, { viewerId, isManager = false }) {
  const mine = b.userId === viewerId;
  const hidden = b.eventId && b.eventVisibility === 'private' && !mine && b.eventCreatorId !== viewerId;
  return {
    id: b.id,
    resourceId: b.resourceId,
    resourceName: b.resourceName,
    resourceKind: b.resourceKind,
    title: hidden ? '비공개 일정' : (b.eventId ? (b.eventTitle ?? b.title) : b.title),
    userId: b.userId ?? null,
    userName: b.userName,
    teamId: b.teamId ?? null,
    start: ms(b.startAt),
    end: ms(b.endAt),
    eventId: b.eventId ?? null,
    // 'confirmed' | 'pending'(승인을 기다림 — resourcePolicy.js), 반복 예약 묶음.
    status: b.status ?? 'confirmed',
    seriesId: b.seriesId ?? null,
    mine,
    canCancel: mine || isManager,
  };
}

/** 일정 DTO의 `resource` 칸(calendars.js toOccurrenceDto). */
export const eventResourceDto = (b) =>
  b ? { bookingId: b.id, resourceId: b.resourceId, name: b.resourceName, kind: b.resourceKind, status: b.status ?? 'confirmed' } : null;
