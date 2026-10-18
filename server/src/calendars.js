import { Router } from 'express';
import { teamAccess } from './access.js';
import { RateLimiter, tooMany } from './authGuard.js';
import {
  DAY_MS,
  KST_OFFSET_MS,
  MAX_EXDATES,
  OCCURRENCE_MAX_MS,
  QUERY_MAX_MS,
  QUERY_MIN_MS,
  alignStartToRecurrence,
  dateStringOf,
  expandOccurrences,
  fillOccurrenceBudget,
  normalizeExdates,
  occurrenceIndex,
  parseDateString,
  parseRecurrence,
  splitRecurrenceAt,
  weekdayOf,
} from './calendarRecurrence.js';
import {
  addMemberRow,
  deleteCalendar,
  deleteEvent,
  deleteMemberRow,
  ensurePersonalCalendar,
  ensureTeamCalendar,
  filterInvitableUserIds,
  findCalendarById,
  findCalendarMember,
  findCalendarsByIds,
  findEventById,
  findEventWithCreatorName,
  insertEvent,
  insertSharedCalendar,
  insertSubscriber,
  listAttendeeIdsOfCalendar,
  listAttendeesForEvents,
  listCalendarCandidates,
  listCalendarPeopleIds,
  listEventColorsForUser,
  listEventsForWindow,
  listMemberRowsForUser,
  listMembersWithUsers,
  listTeamBirthdays,
  listTeamMemberIdSet,
  listTeamNonGuestMemberIds,
  listUserNames,
  searchEventsByTitle,
  searchSubscribableCalendars,
  setEventColor,
  setMemberRole,
  splitEvent,
  updateCalendar,
  updateEvent,
  upsertMemberPreferences,
} from './db/queries/calendars.js';
import { canSearchEventTitle, parseCalendarSearchQuery, searchCursorOf, toSearchItem } from './calendarSearchRules.js';
import { listTeamIdsForUser, listTeamMemberIds } from './db/queries/teams.js';
import { leaveTypeOf } from './annualLeave.js';
import { listApprovedLeaves, listApprovedTrips } from './db/queries/groupware.js';
import { getServerSettings } from './db/queries/serverSettings.js';
import { effectiveGroupwareScope, groupwareScopeKey } from './groupwareScope.js';
import { findUserById } from './db/queries/users.js';
import { listExternalCalendars } from './db/queries/externalCalendars.js';
import { toExternalCalendarDto } from './externalCalendarRules.js';
import { externalOccurrencesFor } from './externalCalendars.js';
import { holidaysInRange } from './holidays.js';
import { listBookingsForEvents, listStandaloneBookingsForCalendar } from './db/queries/resources.js';
import { broadcastResources, eventResourcesDto, resourceScopeKeyForTeam, syncEventResources } from './groupwareResources.js';
import { eventBookingRange, eventResourceDto } from './resourceRules.js';
import { calendarPermissions, canModifyCalendarEvent, graphemeLength } from './permissions.js';

/**
 * 캘린더(팀 단위) — 기본/팀/공유 캘린더, 멤버·구독, 일정(반복 포함), 공휴일·생일 내장 캘린더.
 * 규약은 서버·클라이언트 공용 문서(투표·캘린더 API 규약)를 따른다. 핵심 규칙:
 *  - 권한은 전부 calendarAccess(아래) 한 곳에서 계산한다(계산 자체는 permissions.js의 calendarPermissions).
 *  - 종일 일정의 start/end는 "날짜를 UTC 자정으로 본 ms"(end는 마지막 날 다음 날, 배타), 시간 일정은 순간(ms)이고
 *    반복은 Asia/Seoul 벽시계 기준이다(calendarRecurrence.js).
 *  - 일정/캘린더가 바뀌면 관련자의 user:<id> 룸에 calendar:changed { teamId, calendarId }를 보낸다.
 */

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const COLOR_RE = /^#[0-9a-fA-F]{6}$/;

const CALENDAR_NAME_MAX = 30;
const TITLE_MAX = 50;
const DESCRIPTION_MAX = 500;
const LOCATION_MAX = 50;
const ATTENDEE_MAX = 200;
const QUERY_SPAN_MAX_MS = 62 * DAY_MS;
// 조회 구간이 놓일 수 있는 범위(QUERY_MIN_MS·QUERY_MAX_MS)와 회차가 놓일 수 있는 끝(OCCURRENCE_MAX_MS)은
// calendarRecurrence.js에 있다 — 반복 종료일 상한(MAX_UNTIL)·앱의 달 단위 조회와 맞물린 값이라 그 곁에서 함께 검증한다.
// 한 번의 일정 조회가 돌려주는 회차 수 상한 — 일정을 대량으로 만들어도 펼치는 계산과 응답 크기가 이 안에서 끝나게 한다
// (한 화면에 현실적으로 보이는 회차는 수백 개 수준이다). 한 시리즈의 상한은 expandOccurrences가 따로 건다.
// 상한을 일정들에 어떻게 나눌지(어느 일정이 빠질지)는 fillOccurrenceBudget이 정하고, 상한에 닿으면 응답에
// X-Calendar-Truncated: 1을 붙인다.
const QUERY_OCCURRENCE_MAX = 5000;
// 일정 행을 새로 만드는 요청(새 일정, 반복 일정의 "이 일정만"·"이 일정 및 이후 일정" 수정)은 한 사람이 10분에 60개까지.
// 조회는 볼 수 있는 반복 일정을 구간과 상관없이 전부 읽어 구간에 회차가 있는지 하나씩 보므로, 스크립트로 일정을 끝없이
// 찍어내면 그 팀의 캘린더 조회가 점점 무거워진다. 편집 창으로 하나씩 만드는 속도(평균 10초에 하나 미만)로는 닿지 않게
// 잡았다. 일정 개수 자체에는 아직 상한이 없어서, 이 제한은 늘어나는 속도를 늦출 뿐이다.
const EVENT_CREATE_MAX = 60;
const EVENT_CREATE_WINDOW_MS = 10 * 60 * 1000;
// 일정 길이·날짜 범위 — 터무니없는 값이 반복 계산이나 DB를 흔들지 않게 하는 안전 상한.
const EVENT_MAX_DURATION_MS = 366 * DAY_MS;
const EVENT_MIN_START_MS = Date.UTC(2000, 0, 1);
const EVENT_MAX_START_MS = Date.UTC(2100, 0, 1);

export const HOLIDAY_COLOR = '#E53935';
export const BIRTHDAY_COLOR = '#F06292';
// 내장 캘린더 "팀 휴가" — 그룹웨어에서 승인된 휴가(groupware.js).
export const LEAVE_COLOR = '#12B886';
// 내장 캘린더 "출장" — 그룹웨어에서 승인된 출장 신청(양식 'trip' — 휴가와 같은 사람들에게).
export const TRIP_COLOR = '#F08C00';
// 내장 캘린더 "회의실 예약" — 그룹웨어에서 바로 잡은 내 예약(일정에 붙인 예약은 그 일정으로 보인다 — groupwareResources.js).
export const BOOKING_COLOR = '#7950F2';
const TEAM_CALENDAR_COLOR = '#5B8DEF';
// 기본 캘린더 색 팔레트 — 사람 id로 골라서 사람마다 다르게 보이게 한다.
const PALETTE = ['#5B8DEF', '#F4A261', '#2A9D8F', '#E76F51', '#9B5DE5', '#00B4D8', '#8AB17D', '#EF476F', '#FFB703', '#6C757D'];

function paletteColor(seed) {
  let h = 0;
  for (const ch of seed) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return PALETTE[h % PALETTE.length];
}

// ── 권한 ────────────────────────────────────────────────────────────────

/**
 * 이 사람이 이 캘린더에서 무엇을 할 수 있는지 — 규약의 권한 표를 한 곳에 모은 함수.
 * 계정 등급·팀 소유자·팀 멤버십(teamAccess)과 내 멤버 행(calendar_members)을 읽어 permissions.js의
 * calendarPermissions에 넘긴다. 팀에서 나간 사람의 행이 남아 있어도 여기서 팀 멤버십을 보므로 접근이 막히고, 준회원으로
 * 내려간 사람의 공유 캘린더 행(관리자·쓰기·소유자)도 계정 등급과 함께 계산되어 읽기로만 동작한다.
 * 목록처럼 여러 캘린더를 판정할 때는 [prefetched]에 `team`(teamAccess 결과)·`member`(내 행 또는 null)를 미리 넘겨
 * 조회를 줄인다.
 */
export async function calendarAccess(calendar, userId, prefetched = {}) {
  const team = prefetched.team ?? (await teamAccess(calendar.teamId, userId));
  const member = 'member' in prefetched ? prefetched.member : await findCalendarMember(calendar.id, userId);
  const perms = calendarPermissions({
    calendar,
    userId,
    isTeamMember: team.isMember,
    role: team.role,
    isOwner: team.isOwner,
    memberRole: member?.role ?? null,
  });
  return { ...perms, team, member };
}

// 준회원으로 내려가 행에 남은 권한(관리자·쓰기·소유자)보다 낮게 계산된 사람(calendarPermissions의 limitedAsGuest)에게 주는
// 거절 문구 — 등급이 바뀐 뒤 캘린더 목록을 다시 받기 전에는 예전 권한의 버튼이 화면에 남아 있을 수 있어서, "관리자만" 같은
// 문구 대신 왜 안 되는지를 알려 준다.
const GUEST_READ_ONLY = '준회원은 공유 캘린더에서 읽기만 할 수 있습니다.';

/** 권한이 없어 거절할 때의 문구 — 준회원이라 권한이 낮춰진 사람이면 [fallback] 대신 그 이유를 알려 준다. */
function deniedText(access, fallback) {
  return access?.limitedAsGuest ? GUEST_READ_ONLY : fallback;
}

// ── DTO ─────────────────────────────────────────────────────────────────

function toCalendarDto(calendar, access, ownerName) {
  const member = access.member;
  return {
    id: calendar.id,
    teamId: calendar.teamId,
    kind: calendar.kind,
    // 기본 캘린더는 이름을 바꿀 수 없으니 소유자의 "지금" 이름을 보여준다(가입 후 이름을 바꿔도 따라간다).
    name: calendar.kind === 'personal' ? (ownerName ?? calendar.name) : calendar.name,
    color: member?.color ?? calendar.color,
    defaultColor: calendar.color,
    isPublic: calendar.isPublic,
    ownerId: calendar.ownerId ?? null,
    ownerName: ownerName ?? null,
    role: access.role,
    hidden: member?.hidden === true,
    canCreateEvents: access.canCreateEvents,
    canDelete: access.canDelete,
    canEditSettings: access.canEditSettings,
  };
}

async function singleCalendarDto(calendar, userId, access = null) {
  const acc = access ?? (await calendarAccess(calendar, userId));
  const names = await listUserNames(calendar.ownerId ? [calendar.ownerId] : []);
  return toCalendarDto(calendar, acc, names.get(calendar.ownerId) ?? null);
}

function toMemberDto(row, calendar) {
  return {
    userId: row.userId,
    name: row.name ?? row.username,
    role: row.role,
    isOwner: calendar.ownerId != null && row.userId === calendar.ownerId,
  };
}

/**
 * 한 일정의 한 회차를 EventOccurrence로. [info]={calendar, access}, [attendees]=[{userId,name}], [bookings]=붙은 자원 예약들(회의실 + 장비 —
 * 없으면 빈 목록 — DTO에는 `resource`(첫 자원, 예전 앱)와 `resources`).
 */
function toOccurrenceDto({ event, start, end, info, viewerId, attendees, isAttendee, myColor, bookings = [] }) {
  const access = info.access;
  const detailVisible =
    event.visibility !== 'private' ||
    event.creatorId === viewerId ||
    isAttendee ||
    access.isOwner === true ||
    access.isManager === true;
  const editable = canModifyCalendarEvent({ access, event, userId: viewerId });
  return {
    key: `${event.id}:${start}`,
    eventId: event.id,
    calendarId: event.calendarId,
    source: 'event',
    title: detailVisible ? event.title : '비공개 일정',
    description: detailVisible ? (event.description ?? null) : null,
    location: detailVisible ? (event.location ?? null) : null,
    start,
    end,
    allDay: event.allDay,
    visibility: event.visibility,
    restricted: !detailVisible,
    recurring: !!event.recurrence,
    recurrence: detailVisible ? (event.recurrence ?? null) : null,
    creatorId: event.creatorId ?? null,
    creatorName: event.creatorName ?? null,
    attendees: detailVisible ? attendees : [],
    ...(detailVisible ? eventResourcesDto(bookings) : { resource: null, resources: [] }),
    color: myColor ?? info.access.member?.color ?? info.calendar.color,
    canEdit: editable,
    canDelete: editable,
  };
}

// ── 입력 검사 ───────────────────────────────────────────────────────────

function isUuid(s) {
  return typeof s === 'string' && UUID_RE.test(s);
}

function parseColor(raw) {
  return typeof raw === 'string' && COLOR_RE.test(raw) ? raw.toUpperCase() : null;
}

/** 글자 수는 앱 입력창과 같은 글자(grapheme) 단위로 센다. 앞뒤 공백은 뺀다. */
function parseText(raw, { label, min, max }) {
  if (typeof raw !== 'string') return { error: `${label}을(를) 입력하세요.` };
  const value = raw.trim();
  if (graphemeLength(value) < min) return { error: `${label}을(를) 입력하세요.` };
  if (graphemeLength(value) > max) return { error: `${label}은(는) ${max}자 이내로 입력하세요.` };
  return { value };
}

function parseOptionalText(raw, { label, max }) {
  if (raw === null || raw === undefined) return { value: null };
  const r = parseText(raw, { label, min: 0, max });
  if (r.error) return r;
  return { value: r.value === '' ? null : r.value };
}

/** 정수 ms인지. */
function parseMs(raw) {
  return Number.isSafeInteger(raw) ? raw : null;
}

/** 일정 시작으로 받을 수 있는 시각인지(EVENT_MIN_START_MS 이상, EVENT_MAX_START_MS 미만). */
function isEventStartInRange(ms) {
  return ms >= EVENT_MIN_START_MS && ms < EVENT_MAX_START_MS;
}

/**
 * 일정 본문 필드를 검사한다. 생성이면 [existing]=null(title·start·end 필수), 수정이면 [existing]에 지금 값
 * ({title, description, location, startMs, endMs, allDay, visibility})을 주고, 안 보낸 필드는 그 값을 쓴다.
 * end만 안 보내고 start만 옮기면 길이를 유지한다.
 */
function parseEventFields(body, existing) {
  const b = body ?? {};
  const f = {};

  if (b.title !== undefined || !existing) {
    const r = parseText(b.title, { label: '제목', min: 1, max: TITLE_MAX });
    if (r.error) return { error: r.error };
    f.title = r.value;
  } else {
    f.title = existing.title;
  }
  for (const [key, label, max] of [
    ['description', '설명', DESCRIPTION_MAX],
    ['location', '장소', LOCATION_MAX],
  ]) {
    if (b[key] !== undefined || !existing) {
      const r = parseOptionalText(b[key], { label, max });
      if (r.error) return { error: r.error };
      f[key] = r.value;
    } else {
      f[key] = existing[key] ?? null;
    }
  }

  if (b.allDay !== undefined && typeof b.allDay !== 'boolean') return { error: '종일 여부가 올바르지 않습니다.' };
  f.allDay = b.allDay ?? existing?.allDay ?? false;

  if (b.visibility !== undefined && b.visibility !== 'public' && b.visibility !== 'private') {
    return { error: '공개 범위가 올바르지 않습니다.' };
  }
  f.visibility = b.visibility ?? existing?.visibility ?? 'public';

  if (!existing && (b.start === undefined || b.end === undefined)) return { error: '시작과 종료 시각을 입력하세요.' };
  let startMs = existing?.startMs;
  let endMs = existing?.endMs;
  if (b.start !== undefined) {
    startMs = parseMs(b.start);
    if (startMs === null) return { error: '시작 시각이 올바르지 않습니다.' };
    // start만 옮겼으면 길이를 그대로 유지한다.
    if (b.end === undefined && existing) endMs = startMs + (existing.endMs - existing.startMs);
  }
  if (b.end !== undefined) {
    endMs = parseMs(b.end);
    if (endMs === null) return { error: '종료 시각이 올바르지 않습니다.' };
  }
  if (!(endMs > startMs)) return { error: '종료 시각은 시작 시각보다 뒤여야 합니다.' };
  if (!isEventStartInRange(startMs)) return { error: '시작 시각이 허용 범위를 벗어났습니다.' };
  if (endMs - startMs > EVENT_MAX_DURATION_MS) return { error: '일정 길이는 최대 366일입니다.' };
  if (f.allDay && (startMs % DAY_MS !== 0 || endMs % DAY_MS !== 0)) {
    return { error: '종일 일정의 시작·종료는 날짜(UTC 자정) 단위여야 합니다.' };
  }
  f.startMs = startMs;
  f.endMs = endMs;

  if (b.color !== undefined && b.color !== null) {
    f.color = parseColor(b.color);
    if (!f.color) return { error: '색은 #RRGGBB 형식이어야 합니다.' };
  }
  if (b.attendeeIds !== undefined) {
    if (!Array.isArray(b.attendeeIds) || b.attendeeIds.length > ATTENDEE_MAX || !b.attendeeIds.every(isUuid)) {
      return { error: '참석자 목록이 올바르지 않습니다.' };
    }
    f.attendeeIds = [...new Set(b.attendeeIds.map((id) => id.toLowerCase()))];
  }
  return { fields: f };
}

/**
 * recurrence를 검사·정규화하고 시작이 첫 회차가 되도록 맞춘다(매주 반복에서 시작 요일이 목록에 없으면 옮김).
 * 통과하면 { recurrence, startMs, endMs }. 저장 직전의 시작 시각도 여기서 범위를 다시 본다 — "모든 일정" 수정은
 * 시작을 "회차가 옮겨진 만큼"으로 다시 계산하므로 parseEventFields의 검사만으로는 1900년 같은 시작이 들어올 수 있다.
 */
function finalizeRecurrence(rawRecurrence, startMs, endMs, allDay) {
  if (!isEventStartInRange(startMs)) return { error: '시작 시각이 허용 범위를 벗어났습니다.' };
  const parsed = parseRecurrence(rawRecurrence, { startMs, allDay });
  if (parsed.error) return { error: parsed.error };
  const rec = parsed.value;
  if (!rec) return { recurrence: null, startMs, endMs };
  const aligned = alignStartToRecurrence(startMs, endMs, allDay, rec);
  if (!isEventStartInRange(aligned.startMs)) return { error: '시작 시각이 허용 범위를 벗어났습니다.' };
  if (rec.until && parseDateString(rec.until) < parseDateString(dateStringOf(aligned.startMs, allDay))) {
    return { error: '반복 종료일은 시작일보다 빠를 수 없습니다.' };
  }
  return { recurrence: rec, startMs: aligned.startMs, endMs: aligned.endMs };
}

/** 시작 요일 하나로 만든 매주 반복은 시작을 다른 요일로 옮길 때 요일도 따라간다(요일을 따로 고른 것은 그대로). */
function followStartWeekday(rec, oldStartMs, newStartMs, allDay) {
  if (!rec || rec.freq !== 'weekly' || rec.byWeekday?.length !== 1) return rec;
  if (rec.byWeekday[0] !== weekdayOf(oldStartMs, allDay)) return rec;
  return { ...rec, byWeekday: [weekdayOf(newStartMs, allDay)] };
}

async function resolveAttendees(teamId, rawIds, { requesterRole, keep = new Set() }) {
  const ids = rawIds;
  if (ids.length === 0) return { ids };
  if (requesterRole === 'guest') return { error: '준회원은 참석자를 초대할 수 없습니다.' };
  // 이미 초대돼 있던 사람은 그 뒤 팀을 나가도 목록을 다시 보낼 때 막지 않는다(새로 초대하는 사람만 검사).
  const toCheck = ids.filter((id) => !keep.has(id));
  const valid = new Set(await filterInvitableUserIds(teamId, toCheck));
  if (toCheck.some((id) => !valid.has(id))) {
    return { error: '초대할 수 없는 사용자가 포함되어 있습니다. (팀 멤버가 아니거나 탈퇴·정지한 사용자)' };
  }
  return { ids };
}

/**
 * 일정 행 → 반복 계산(calendarRecurrence.js)이 받는 모양. 라우터 밖의 collectOccurrences(조회·ICS 내보내기)도 쓰므로 모듈 맨 위에 둔다
 * (라우터 안에 있으면 collectOccurrences에서 ReferenceError — 일정이 하나라도 있는 구간의 조회가 500이 됐다).
 */
function recurringView(event) {
  return {
    startMs: event.startAt.getTime(),
    endMs: event.endAt.getTime(),
    allDay: event.allDay,
    recurrence: event.recurrence,
    exdates: event.exdates,
  };
}

// ── 일정 추가 횟수 제한 ─────────────────────────────────────────────────

const eventCreateLimiter = new RateLimiter({ max: EVENT_CREATE_MAX, windowMs: EVENT_CREATE_WINDOW_MS });
setInterval(() => eventCreateLimiter.prune(), EVENT_CREATE_WINDOW_MS).unref();

/**
 * 일정 행을 새로 만들기 직전에 부른다 — 검사를 다 통과해 정말 행이 생기는 요청만 센다(입력 오류로 다시 보내는 것은
 * 세지 않는다). 사람 단위라 남이 대신 막을 수 없다. 너무 많으면 429로 응답하고 false.
 */
function allowEventCreate(req, res) {
  const wait = eventCreateLimiter.hit(req.user.sub);
  if (wait === 0) return true;
  tooMany(res, wait, '일정 추가');
  return false;
}

// ── 라우터 ──────────────────────────────────────────────────────────────

export function createCalendarsRouter(io) {
  const router = Router();

  // ── 알림 ──
  /** 캘린더가 바뀌면 알릴 사람들: 멤버·구독자·소유자·(팀 캘린더면 정회원 이상 팀원 전원) + 참석자 등 [extra]. */
  async function notifyChanged(calendar, extraUserIds = []) {
    const ids = new Set(extraUserIds.filter(Boolean));
    for (const id of await listCalendarPeopleIds(calendar.id)) ids.add(id);
    if (calendar.ownerId) ids.add(calendar.ownerId);
    if (calendar.kind === 'team') {
      for (const id of await listTeamNonGuestMemberIds(calendar.teamId)) ids.add(id);
    }
    for (const id of ids) {
      io.to(`user:${id}`).emit('calendar:changed', { teamId: calendar.teamId, calendarId: calendar.id });
    }
  }

  /** 나만 바뀌는 개인 설정(색·숨김·구독 취소)은 내 다른 기기에만 알린다. */
  function notifyMe(calendar, userId) {
    io.to(`user:${userId}`).emit('calendar:changed', { teamId: calendar.teamId, calendarId: calendar.id });
  }

  // ── 공통 로더 ──
  /** 캘린더를 읽고 내 권한을 계산한다. 없으면 404로 응답하고 null. */
  async function loadCalendar(req, res) {
    if (!isUuid(req.params.id)) {
      res.status(404).json({ error: '캘린더를 찾을 수 없습니다.' });
      return null;
    }
    const calendar = await findCalendarById(req.params.id);
    if (!calendar) {
      res.status(404).json({ error: '캘린더를 찾을 수 없습니다.' });
      return null;
    }
    const access = await calendarAccess(calendar, req.user.sub);
    return { calendar, access };
  }

  /** loadCalendar + 볼 수 있어야 한다. 팀 멤버가 아니거나 준회원의 팀 캘린더는 403, 그 밖에 못 보면 404. */
  async function loadViewableCalendar(req, res) {
    const ctx = await loadCalendar(req, res);
    if (!ctx) return null;
    if (ctx.access.canView) return ctx;
    if (!ctx.access.team.isMember) {
      res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    } else if (ctx.calendar.kind === 'team') {
      res.status(403).json({ error: '준회원은 팀 캘린더를 볼 수 없습니다.' });
    } else {
      res.status(404).json({ error: '캘린더를 찾을 수 없습니다.' });
    }
    return null;
  }

  /** :teamId의 멤버여야 한다. 아니면 403(또는 잘못된 id면 404)으로 응답하고 null. */
  async function requireTeam(req, res) {
    if (!isUuid(req.params.teamId)) {
      res.status(404).json({ error: '팀을 찾을 수 없습니다.' });
      return null;
    }
    const team = await teamAccess(req.params.teamId, req.user.sub);
    if (!team.isMember) {
      res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
      return null;
    }
    return team;
  }

  // ── 1. 내 캘린더 목록 ──
  router.get('/teams/:teamId/calendars', async (req, res) => {
    const team = await requireTeam(req, res);
    if (!team) return;
    const teamId = req.params.teamId;
    const userId = req.user.sub;

    // 처음 열 때 기본 캘린더·팀 캘린더를 만든다(동시에 열어도 unique index로 하나만 생긴다).
    await Promise.all([
      ensurePersonalCalendar(teamId, userId, {
        name: team.user.name ?? team.user.username,
        color: paletteColor(userId),
      }),
      ensureTeamCalendar(teamId, { name: '팀 캘린더', color: TEAM_CALENDAR_COLOR }),
    ]);

    const [candidates, memberIds] = await Promise.all([listCalendarCandidates(teamId, userId), listTeamMemberIdSet(teamId)]);
    const ownerNames = await listUserNames([...new Set(candidates.map((c) => c.calendar.ownerId).filter(Boolean))]);

    let personal = null;
    let teamCalendar = null;
    const shared = [];
    const subscribed = [];
    for (const { calendar, member } of candidates) {
      const access = await calendarAccess(calendar, userId, { team, member });
      if (!access.canView) continue;
      const dto = toCalendarDto(calendar, access, ownerNames.get(calendar.ownerId) ?? null);
      if (access.role === 'subscriber') {
        // 소유자가 팀을 나간 기본 캘린더는 구독 목록에서 뺀다.
        if (calendar.kind === 'personal' && !memberIds.has(calendar.ownerId)) continue;
        subscribed.push(dto);
      } else if (calendar.kind === 'personal') personal = dto;
      else if (calendar.kind === 'team') teamCalendar = dto;
      else shared.push(dto);
    }
    subscribed.sort((a, b) => a.name.localeCompare(b.name, 'ko'));
    // 내가 구독한 외부 캘린더(ICS 주소 — 나에게만 보인다). 앱은 "구독 캘린더" 묶음 끝에 붙인다.
    const external = (await listExternalCalendars(userId, teamId)).map(toExternalCalendarDto);
    res.json({ mine: [personal, teamCalendar, ...shared].filter(Boolean), subscribed, external });
  });

  // ── 2. 새 캘린더 ──
  router.post('/teams/:teamId/calendars', async (req, res) => {
    const team = await requireTeam(req, res);
    if (!team) return;
    if (team.role === 'guest') return res.status(403).json({ error: '준회원은 새 캘린더를 만들 수 없습니다.' });
    const name = parseText(req.body?.name, { label: '캘린더 이름', min: 1, max: CALENDAR_NAME_MAX });
    if (name.error) return res.status(400).json({ error: name.error });
    const color = parseColor(req.body?.color);
    if (!color) return res.status(400).json({ error: '색은 #RRGGBB 형식이어야 합니다.' });
    const isPublic = req.body?.isPublic ?? true;
    if (typeof isPublic !== 'boolean') return res.status(400).json({ error: '공개 여부가 올바르지 않습니다.' });

    const { calendar, member } = await insertSharedCalendar({
      teamId: req.params.teamId,
      name: name.value,
      color,
      isPublic,
      ownerId: req.user.sub,
    });
    notifyMe(calendar, req.user.sub);
    const access = await calendarAccess(calendar, req.user.sub, { team, member });
    res.status(201).json(await singleCalendarDto(calendar, req.user.sub, access));
  });

  // ── 3. 캘린더 설정(이름·공개) ──
  router.patch('/calendars/:id', async (req, res) => {
    const ctx = await loadViewableCalendar(req, res);
    if (!ctx) return;
    const { calendar, access } = ctx;
    const { name, isPublic } = req.body ?? {};
    if (calendar.kind === 'team') return res.status(403).json({ error: '팀 캘린더는 설정을 바꿀 수 없습니다.' });
    if (!access.canEditSettings) {
      return res.status(403).json({ error: deniedText(access, '캘린더 관리자만 설정을 바꿀 수 있습니다.') });
    }

    const patch = {};
    if (name !== undefined) {
      if (calendar.kind === 'personal') return res.status(400).json({ error: '기본 캘린더의 이름은 바꿀 수 없습니다.' });
      const r = parseText(name, { label: '캘린더 이름', min: 1, max: CALENDAR_NAME_MAX });
      if (r.error) return res.status(400).json({ error: r.error });
      patch.name = r.value;
    }
    if (isPublic !== undefined) {
      if (typeof isPublic !== 'boolean') return res.status(400).json({ error: '공개 여부가 올바르지 않습니다.' });
      patch.isPublic = isPublic;
    }
    if (Object.keys(patch).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });

    const updated = await updateCalendar(calendar.id, patch);
    await notifyChanged(updated);
    res.json(await singleCalendarDto(updated, req.user.sub));
  });

  // ── 4. 내 개인 설정(색·숨김) ──
  router.patch('/calendars/:id/me', async (req, res) => {
    const ctx = await loadViewableCalendar(req, res);
    if (!ctx) return;
    const { calendar, access } = ctx;
    const { color, hidden } = req.body ?? {};
    const patch = {};
    if (color !== undefined) {
      const c = parseColor(color);
      if (!c) return res.status(400).json({ error: '색은 #RRGGBB 형식이어야 합니다.' });
      patch.color = c;
    }
    if (hidden !== undefined) {
      if (typeof hidden !== 'boolean') return res.status(400).json({ error: '숨김 여부가 올바르지 않습니다.' });
      patch.hidden = hidden;
    }
    if (Object.keys(patch).length === 0) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });

    // 팀 캘린더·내 기본 캘린더는 권한이 계산값이라 행이 없을 수 있다 — 개인 설정을 담을 행을 만든다.
    const row = await upsertMemberPreferences(calendar.id, req.user.sub, patch, access.role === 'admin' ? 'admin' : 'read');
    notifyMe(calendar, req.user.sub);
    res.json(await singleCalendarDto(calendar, req.user.sub, { ...access, member: row }));
  });

  // ── 5. 캘린더 삭제 ──
  router.delete('/calendars/:id', async (req, res) => {
    const ctx = await loadViewableCalendar(req, res);
    if (!ctx) return;
    const { calendar, access } = ctx;
    if (calendar.kind !== 'shared') {
      return res.status(400).json({ error: '기본 캘린더와 팀 캘린더는 삭제할 수 없습니다.' });
    }
    // 준회원이 된 소유자도 여기서 막힌다(calendarPermissions) — 캘린더를 지우면 다른 멤버의 일정까지 모두 사라지기 때문이다.
    if (!access.canDelete) return res.status(403).json({ error: deniedText(access, '캘린더 소유자만 삭제할 수 있습니다.') });
    // 지운 뒤에는 누가 관련자였는지 알 수 없으니 미리 모은다.
    const attendeeIds = await listAttendeeIdsOfCalendar(calendar.id);
    const peopleIds = await listCalendarPeopleIds(calendar.id);
    await deleteCalendar(calendar.id);
    for (const id of new Set([...attendeeIds, ...peopleIds, req.user.sub])) {
      io.to(`user:${id}`).emit('calendar:changed', { teamId: calendar.teamId, calendarId: calendar.id });
    }
    res.json({ ok: true });
  });

  // ── 6. 나에게만 삭제 / 구독 취소 ──
  router.delete('/calendars/:id/me', async (req, res) => {
    const ctx = await loadCalendar(req, res);
    if (!ctx) return;
    const { calendar, access } = ctx;
    const userId = req.user.sub;
    if (calendar.kind === 'team') {
      return res.status(400).json({ error: '팀 캘린더는 삭제할 수 없습니다. 숨김을 사용하세요.' });
    }
    if (calendar.ownerId === userId) {
      // 소유자는 멤버 행을 지우지 않는다(소유자 행이 없으면 아무도 그 캘린더를 지울 수 없게 된다). 준회원이 된 소유자는
      // 캘린더 삭제도 못 하므로(calendarPermissions) 막힌 길을 권하지 않고 숨김을 알려 준다 — 앱은 삭제 권한이 없는
      // 공유 캘린더 멤버에게 "나에게만 삭제"를 보여 주므로 이 문구가 그대로 뜬다.
      if (calendar.kind === 'shared' && access.limitedAsGuest) {
        return res.status(400).json({ error: '준회원인 소유자는 캘린더 삭제와 나에게만 삭제를 할 수 없습니다. 숨김을 사용하세요.' });
      }
      return res.status(400).json({
        error: calendar.kind === 'shared' ? '소유자는 캘린더 삭제를 사용하세요.' : '기본 캘린더는 삭제할 수 없습니다.',
      });
    }
    if (!access.member) return res.status(404).json({ error: '구독 중이거나 멤버인 캘린더가 아닙니다.' });
    await deleteMemberRow(calendar.id, userId);
    notifyMe(calendar, userId);
    res.json({ ok: true });
  });

  // ── 7. 멤버 관리(공유 캘린더, 캘린더 관리자) ──
  async function loadManagedSharedCalendar(req, res) {
    const ctx = await loadViewableCalendar(req, res);
    if (!ctx) return null;
    if (ctx.calendar.kind !== 'shared') {
      res.status(400).json({ error: '멤버는 새로 만든 공유 캘린더에서만 관리할 수 있습니다.' });
      return null;
    }
    if (!ctx.access.canEditSettings) {
      res.status(403).json({ error: deniedText(ctx.access, '캘린더 관리자만 멤버를 관리할 수 있습니다.') });
      return null;
    }
    return ctx;
  }

  router.get('/calendars/:id/members', async (req, res) => {
    const ctx = await loadManagedSharedCalendar(req, res);
    if (!ctx) return;
    const rows = await listMembersWithUsers(ctx.calendar.id);
    // 권한은 행에 저장된 값 그대로 보여 준다. 준회원으로 내려간 멤버의 행에는 예전 권한(관리자·쓰기)이 남아 있을 수
    // 있지만 실제로는 calendarPermissions가 읽기로만 계산하므로 노출돼도 힘이 없다. 반대로 여기서 읽기로 바꿔 보여 주면
    // 캘린더 관리자가 남은 권한을 알아보고 읽기로 낮출 길이 없어진다 — 앱은 지금 권한과 같은 값을 고르면 요청을
    // 보내지 않고, 준회원에게는 읽기만 고를 수 있게 한다. 그러면 정회원으로 다시 올라갔을 때 예전 권한이 모르는 새 돌아온다.
    res.json(rows.map((r) => toMemberDto(r, ctx.calendar)));
  });

  router.post('/calendars/:id/members', async (req, res) => {
    const ctx = await loadManagedSharedCalendar(req, res);
    if (!ctx) return;
    const { calendar } = ctx;
    const { userId, role } = req.body ?? {};
    if (!isUuid(userId)) return res.status(400).json({ error: '멤버를 선택하세요.' });
    if (!['admin', 'write', 'read'].includes(role)) return res.status(400).json({ error: '권한이 올바르지 않습니다.' });
    const [validId] = await filterInvitableUserIds(calendar.teamId, [userId]);
    if (!validId) return res.status(400).json({ error: '팀 멤버가 아니거나 탈퇴·정지한 사용자입니다.' });
    const target = await findUserById(userId);
    if (target?.role === 'guest' && role !== 'read') {
      return res.status(400).json({ error: '준회원은 읽기 권한만 줄 수 있습니다.' });
    }
    const row = await addMemberRow(calendar.id, userId, role);
    if (!row) return res.status(409).json({ error: '이미 이 캘린더의 멤버입니다.' });
    await notifyChanged(calendar, [userId]);
    res.status(201).json(toMemberDto({ ...row, name: target.name, username: target.username }, calendar));
  });

  router.patch('/calendars/:id/members/:userId', async (req, res) => {
    const ctx = await loadManagedSharedCalendar(req, res);
    if (!ctx) return;
    const { calendar } = ctx;
    const targetId = req.params.userId;
    const role = req.body?.role;
    if (!isUuid(targetId)) return res.status(404).json({ error: '멤버를 찾을 수 없습니다.' });
    if (!['admin', 'write', 'read'].includes(role)) return res.status(400).json({ error: '권한이 올바르지 않습니다.' });
    if (targetId === calendar.ownerId) return res.status(400).json({ error: '소유자의 권한은 바꿀 수 없습니다.' });
    const current = await findCalendarMember(calendar.id, targetId);
    if (!current || current.role === 'subscriber') return res.status(404).json({ error: '멤버를 찾을 수 없습니다.' });
    const target = await findUserById(targetId);
    if (target?.role === 'guest' && role !== 'read') {
      return res.status(400).json({ error: '준회원은 읽기 권한만 줄 수 있습니다.' });
    }
    const row = await setMemberRole(calendar.id, targetId, role);
    await notifyChanged(calendar, [targetId]);
    res.json(toMemberDto({ ...row, name: target?.name, username: target?.username }, calendar));
  });

  router.delete('/calendars/:id/members/:userId', async (req, res) => {
    const ctx = await loadManagedSharedCalendar(req, res);
    if (!ctx) return;
    const { calendar } = ctx;
    const targetId = req.params.userId;
    if (!isUuid(targetId)) return res.status(404).json({ error: '멤버를 찾을 수 없습니다.' });
    if (targetId === calendar.ownerId) return res.status(400).json({ error: '소유자는 내보낼 수 없습니다.' });
    const current = await findCalendarMember(calendar.id, targetId);
    if (!current || current.role === 'subscriber') return res.status(404).json({ error: '멤버를 찾을 수 없습니다.' });
    await deleteMemberRow(calendar.id, targetId);
    await notifyChanged(calendar, [targetId]);
    res.json({ ok: true });
  });

  // ── 8. 구독 ──
  router.get('/teams/:teamId/calendars/search', async (req, res) => {
    const team = await requireTeam(req, res);
    if (!team) return;
    if (team.role === 'guest') return res.status(403).json({ error: '준회원은 캘린더를 구독할 수 없습니다.' });
    const q = typeof req.query.q === 'string' ? req.query.q.trim().slice(0, 50) : '';
    const rows = await searchSubscribableCalendars(req.params.teamId, req.user.sub, q);
    res.json(
      rows.map(({ calendar, ownerName, ownerUsername, memberRole }) => {
        const owner = ownerName ?? ownerUsername ?? null;
        return {
          id: calendar.id,
          kind: calendar.kind,
          name: calendar.kind === 'personal' ? (owner ?? calendar.name) : calendar.name,
          color: calendar.color,
          ownerName: owner,
          subscribed: memberRole === 'subscriber',
        };
      }),
    );
  });

  router.post('/calendars/:id/subscribe', async (req, res) => {
    const ctx = await loadCalendar(req, res);
    if (!ctx) return;
    const { calendar, access } = ctx;
    if (!access.team.isMember) return res.status(403).json({ error: '이 팀의 멤버가 아닙니다.' });
    if (access.team.role === 'guest') return res.status(403).json({ error: '준회원은 캘린더를 구독할 수 없습니다.' });
    if (calendar.kind === 'team') return res.status(400).json({ error: '팀 캘린더는 구독하지 않아도 보입니다.' });
    // 이미 멤버·소유자·구독자면 그대로 돌려준다.
    if (access.canView) return res.json(await singleCalendarDto(calendar, req.user.sub, access));
    if (!calendar.isPublic) return res.status(403).json({ error: '공개되지 않은 캘린더입니다.' });
    if (calendar.kind === 'personal' && !(await listTeamMemberIdSet(calendar.teamId)).has(calendar.ownerId)) {
      return res.status(404).json({ error: '캘린더를 찾을 수 없습니다.' });
    }
    await insertSubscriber(calendar.id, req.user.sub);
    notifyMe(calendar, req.user.sub);
    res.json(await singleCalendarDto(calendar, req.user.sub));
  });

  // ── 9. 일정 조회 ──
  router.get('/teams/:teamId/calendar/events', async (req, res) => {
    const team = await requireTeam(req, res);
    if (!team) return;
    const teamId = req.params.teamId;
    const userId = req.user.sub;
    const fromMs = Number(req.query.from);
    const toMs = Number(req.query.to);
    if (!Number.isSafeInteger(fromMs) || !Number.isSafeInteger(toMs) || toMs <= fromMs) {
      return res.status(400).json({ error: 'from, to(ms)를 올바르게 보내세요.' });
    }
    if (toMs - fromMs > QUERY_SPAN_MAX_MS) return res.status(400).json({ error: '조회 구간은 최대 62일입니다.' });
    if (fromMs < QUERY_MIN_MS || toMs > QUERY_MAX_MS) return res.status(400).json({ error: '조회 구간이 허용 범위를 벗어났습니다.' });

    const { result, truncated } = await collectOccurrences({ team, teamId, userId, fromMs, toMs });
    // 내가 구독한 외부 캘린더(ICS — 나에게만 보인다, 읽기 전용). 받아 둔 회차를 그대로 붙인다(externalCalendars.js).
    for (const occ of await externalOccurrencesFor({ teamId, userId, fromMs, toMs })) result.push(occ);

    sortOccurrences(result);
    // 상한에 닿았으면(빠진 회차가 있을 수 있다) 헤더로 알린다. 본문은 배열 그대로라 지금 앱은 그냥 무시하고,
    // 나중에 앱이 "일부 일정만 표시" 같은 안내를 띄울 수 있다(웹 앱도 같은 주소라 CORS 노출 설정이 필요 없다).
    if (truncated) res.set('X-Calendar-Truncated', '1');
    res.json(result);
  });

  // ── 9-2. 일정 제목 검색 ──
  // 내가 볼 수 있는 캘린더(숨김 여부는 서버가 모른다 — 클라이언트가 거른다)와 내가 참석자인 일정 중 제목에 q가 들어간 것.
  // 공휴일·생일은 대상이 아니다. 결과는 일정(마스터) 단위, 시작 시각 최신순(start 내림차순). 반복 일정의 start는 첫 회차다.
  router.get('/teams/:teamId/calendar/search', async (req, res) => {
    const team = await requireTeam(req, res);
    if (!team) return;
    const parsed = parseCalendarSearchQuery(req.query);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const teamId = req.params.teamId;
    const userId = req.user.sub;

    const candidates = await listCalendarCandidates(teamId, userId);
    const infoById = new Map();
    for (const { calendar, member } of candidates) {
      infoById.set(calendar.id, { calendar, access: await calendarAccess(calendar, userId, { team, member }) });
    }
    const infos = [...infoById.values()];
    const rows = await searchEventsByTitle({
      teamId,
      calendarIds: infos.filter((i) => i.access.canView).map((i) => i.calendar.id),
      managedCalendarIds: infos.filter((i) => i.access.isOwner === true || i.access.isManager === true).map((i) => i.calendar.id),
      userId,
      like: parsed.like,
      before: parsed.before,
      limit: parsed.limit + 1,
    });
    const hasMore = rows.length > parsed.limit;
    const events = rows.slice(0, parsed.limit);

    // 참석자로만 초대받은 일정의 캘린더(내가 못 보는 캘린더) 정보도 채운다.
    const missing = [...new Set(events.map((e) => e.calendarId))].filter((id) => !infoById.has(id));
    if (missing.length > 0) {
      const rowsOfMine = await listMemberRowsForUser(userId, missing);
      for (const calendar of await findCalendarsByIds(missing)) {
        infoById.set(calendar.id, {
          calendar,
          access: await calendarAccess(calendar, userId, { team, member: rowsOfMine.get(calendar.id) ?? null }),
        });
      }
    }

    const eventIds = events.map((e) => e.id);
    const [attendeesByEvent, colors, ownerNames] = await Promise.all([
      listAttendeesForEvents(eventIds),
      listEventColorsForUser(eventIds, userId),
      listUserNames([...new Set(events.map((e) => infoById.get(e.calendarId)?.calendar.ownerId).filter(Boolean))]),
    ]);

    const items = [];
    for (const event of events) {
      const info = infoById.get(event.calendarId);
      if (!info) continue;
      const attendees = attendeesByEvent.get(event.id) ?? [];
      const isAttendee = attendees.some((a) => a.userId === userId);
      if (!info.access.canView && !isAttendee) continue;
      // 쿼리가 이미 거르지만, 가려진("비공개 일정") 제목이 걸리는 일은 절대 없도록 한 번 더 확인한다.
      if (!canSearchEventTitle({ event, viewerId: userId, isAttendee, access: info.access })) continue;
      const { calendar, access } = info;
      items.push(
        toSearchItem({
          event,
          calendarName: calendar.kind === 'personal' ? (ownerNames.get(calendar.ownerId) ?? calendar.name) : calendar.name,
          color: colors.get(event.id) ?? access.member?.color ?? calendar.color,
          attendees,
          creatorName: event.creatorName,
          canEdit: canModifyCalendarEvent({ access, event, userId }),
        }),
      );
    }
    res.json({ items, nextBefore: hasMore && items.length > 0 ? searchCursorOf(items[items.length - 1]) : null });
  });

  // ── 10. 일정 만들기 ──
  router.post('/calendars/:id/events', async (req, res) => {
    const ctx = await loadViewableCalendar(req, res);
    if (!ctx) return;
    const { calendar, access } = ctx;
    if (!access.canCreateEvents) {
      return res.status(403).json({ error: deniedText(access, '이 캘린더에 일정을 만들 권한이 없습니다.') });
    }

    const parsed = parseEventFields(req.body, null);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const f = parsed.fields;
    const rec = finalizeRecurrence(req.body?.recurrence ?? null, f.startMs, f.endMs, f.allDay);
    if (rec.error) return res.status(400).json({ error: rec.error });
    const attendees = await resolveAttendees(calendar.teamId, f.attendeeIds ?? [], { requesterRole: access.team.role });
    if (attendees.error) return res.status(400).json({ error: attendees.error });
    // 회의실·자원(그룹웨어 — 여러 개: 회의실 + 장비) — 반복 없는 일정에만. 겹침·예약 규칙은 일정을 넣은 뒤 한 트랜잭션에서 본다(안 되면 일정을 지운다).
    const resourceIds = requestedResourceIds(req.body);
    if (resourceIds === 'invalid') return res.status(400).json({ error: '회의실·자원을 확인하세요.' });
    const bookingRange = eventBookingRange({ startMs: rec.startMs, endMs: rec.endMs, allDay: f.allDay });
    if (resourceIds?.length && rec.recurrence) {
      return res.status(400).json({ error: '반복 일정에는 회의실·자원을 잡을 수 없습니다. 회차마다 따로 잡으세요.' });
    }
    if (!allowEventCreate(req, res)) return;

    const row = await insertEvent(
      {
        calendarId: calendar.id,
        creatorId: req.user.sub,
        title: f.title,
        description: f.description,
        location: f.location,
        startAt: new Date(rec.startMs),
        endAt: new Date(rec.endMs),
        allDay: f.allDay,
        visibility: f.visibility,
        recurrence: rec.recurrence,
        exdates: [],
      },
      { attendeeIds: attendees.ids, colors: f.color ? [{ userId: req.user.sub, color: f.color }] : [] },
    );
    if (resourceIds?.length) {
      const booked = await syncEventResources({
        io,
        eventId: row.id,
        title: f.title,
        resourceIds,
        range: bookingRange,
        user: access.team.user,
        teamId: calendar.teamId,
        role: access.team.role,
      });
      if (booked.error) {
        await deleteEvent(row.id);
        return res.status(booked.status).json({ error: booked.error });
      }
      for (const scopeKey of booked.scopes) await broadcastResources(io, scopeKey);
    }
    await notifyChanged(calendar, attendees.ids);
    const dto = await describeEvent(row.id, req.user.sub);
    res.status(201).json(dto);
  });

  // ── 11. 일정 상세 ──
  router.get('/events/:id', async (req, res) => {
    if (!isUuid(req.params.id)) return res.status(404).json({ error: '일정을 찾을 수 없습니다.' });
    const dto = await describeEvent(req.params.id, req.user.sub);
    if (!dto) return res.status(404).json({ error: '일정을 찾을 수 없습니다.' });
    res.json(dto);
  });

  /**
   * 일정 하나를 요청자 기준 EventOccurrence로(기본은 첫 회차, [occurrenceStart]를 주면 그 회차). 볼 수 없으면 null.
   * 볼 수 있는 조건: 그 캘린더를 볼 수 있거나 참석자로 초대받은 팀 멤버.
   */
  async function describeEvent(eventId, viewerId, occurrenceStart = null) {
    const event = await findEventWithCreatorName(eventId);
    if (!event) return null;
    const calendar = await findCalendarById(event.calendarId);
    if (!calendar) return null;
    const access = await calendarAccess(calendar, viewerId);
    if (!access.team.isMember) return null;
    const attendeesByEvent = await listAttendeesForEvents([event.id]);
    const attendees = attendeesByEvent.get(event.id) ?? [];
    const isAttendee = attendees.some((a) => a.userId === viewerId);
    if (!access.canView && !isAttendee) return null;
    const [colors, bookings] = await Promise.all([listEventColorsForUser([event.id], viewerId), listBookingsForEvents([event.id])]);
    const startMs = occurrenceStart ?? event.startAt.getTime();
    return toOccurrenceDto({
      event,
      start: startMs,
      end: startMs + (event.endAt.getTime() - event.startAt.getTime()),
      info: { calendar, access },
      viewerId,
      attendees,
      isAttendee,
      myColor: colors.get(event.id),
      bookings: bookings.get(event.id) ?? [],
    });
  }

  /** 수정·삭제가 다룰 일정과 내 권한을 읽는다. 볼 수 없으면 404로 응답하고 null. */
  async function loadEvent(req, res) {
    if (!isUuid(req.params.id)) {
      res.status(404).json({ error: '일정을 찾을 수 없습니다.' });
      return null;
    }
    const event = await findEventById(req.params.id);
    const calendar = event ? await findCalendarById(event.calendarId) : null;
    if (!event || !calendar) {
      res.status(404).json({ error: '일정을 찾을 수 없습니다.' });
      return null;
    }
    const access = await calendarAccess(calendar, req.user.sub);
    const attendeeRows = (await listAttendeesForEvents([event.id])).get(event.id) ?? [];
    const isAttendee = attendeeRows.some((a) => a.userId === req.user.sub);
    if (!access.team.isMember || (!access.canView && !isAttendee)) {
      res.status(404).json({ error: '일정을 찾을 수 없습니다.' });
      return null;
    }
    return { event, calendar, access, attendeeIds: attendeeRows.map((a) => a.userId) };
  }

  /** 반복 일정의 scope/occurrenceStart를 읽고 검사한다. 통과하면 { scope, occurrenceStart, index }. */
  function parseScope(rawScope, rawOccurrence, event, { required }) {
    const scope = rawScope ?? 'all';
    if (!['this', 'following', 'all'].includes(scope)) return { error: 'scope가 올바르지 않습니다.' };
    if (!event.recurrence) return { scope: 'all', occurrenceStart: null, index: 0 };
    const needsOccurrence = required || scope !== 'all';
    if (rawOccurrence === undefined || rawOccurrence === null || rawOccurrence === '') {
      if (needsOccurrence) return { error: '반복 일정은 occurrenceStart가 필요합니다.' };
      return { scope, occurrenceStart: event.startAt.getTime(), index: 0 };
    }
    const occurrenceStart = Number(rawOccurrence);
    // 조회가 내놓을 수 있는 회차만 받는다(일정 시작은 2000년 뒤이고, 조회는 OCCURRENCE_MAX_MS 앞의 회차만 펼친다) —
    // 그래서 이 회차에서 반복을 나눠도 원래 시리즈의 종료일(그 회차 전날)이 반복 종료일 상한(MAX_UNTIL) 안에 머문다.
    if (!Number.isSafeInteger(occurrenceStart) || occurrenceStart < QUERY_MIN_MS || occurrenceStart >= OCCURRENCE_MAX_MS) {
      return { error: 'occurrenceStart가 올바르지 않습니다.' };
    }
    const index = occurrenceIndex(recurringView(event), occurrenceStart);
    if (index < 0) return { error: '이 일정의 회차가 아닙니다.' };
    if (scope === 'this') {
      const exdates = normalizeExdates(event.exdates);
      if (exdates.includes(occurrenceStart)) return { error: '이미 제외된 회차입니다.' };
      // "이 일정만"은 회차 하나를 exdates에 더한다 — 조회마다 훑는 목록이라 끝없이 늘지 않게 막는다.
      if (exdates.length >= MAX_EXDATES) {
        return { error: '따로 고치거나 지운 회차가 너무 많은 반복 일정입니다. "이 일정 및 이후 일정"으로 나눠서 바꾸세요.' };
      }
    }
    return { scope, occurrenceStart, index };
  }

  // ── 12. 일정 수정 ──
  router.patch('/events/:id', async (req, res) => {
    const ctx = await loadEvent(req, res);
    if (!ctx) return;
    const { event, calendar, access, attendeeIds: oldAttendeeIds } = ctx;
    const userId = req.user.sub;
    const b = req.body ?? {};
    const isRecurring = !!event.recurrence;

    // 색만 바꾸는 요청은 편집 권한 없이도 된다(내 개인 색이라 일정 자체는 안 바뀐다). 색은 시리즈 전체에 걸리므로
    // scope·occurrenceStart도 필요 없다(occurrenceStart를 주면 그 회차를 돌려준다).
    const contentKeys = Object.keys(b).filter((k) => !['scope', 'occurrenceStart', 'color'].includes(k));
    if (contentKeys.length === 0) {
      if (b.color === undefined) return res.status(400).json({ error: '바꿀 내용이 없습니다.' });
      const color = parseColor(b.color);
      if (!color) return res.status(400).json({ error: '색은 #RRGGBB 형식이어야 합니다.' });
      await setEventColor(event.id, userId, color);
      notifyMe(calendar, userId);
      const shown = Number(b.occurrenceStart);
      return res.json(await describeEvent(event.id, userId, isRecurring && Number.isSafeInteger(shown) ? shown : null));
    }

    const sp = parseScope(b.scope, b.occurrenceStart, event, { required: true });
    if (sp.error) return res.status(400).json({ error: sp.error });
    let { scope, occurrenceStart, index } = sp;
    // 회의실·자원 — resourceIds(목록 — 그대로 맞춤) 또는 예전 resourceId(undefined면 그대로, null이면 빼기, id면 그 하나로). 반복 없는 일정만.
    const wantedResourceIds = requestedResourceIds(b);
    if (wantedResourceIds === 'invalid') return res.status(400).json({ error: '회의실·자원을 확인하세요.' });
    if (wantedResourceIds?.length && isRecurring && scope !== 'all') {
      return res.status(400).json({ error: '반복 일정에는 회의실·자원을 잡을 수 없습니다. 회차마다 따로 잡으세요.' });
    }
    // 첫 회차부터 이후 모두 = 전체.
    if (scope === 'following' && index === 0) scope = 'all';

    if (!canModifyCalendarEvent({ access, event, userId })) {
      return res.status(403).json({ error: deniedText(access, '이 일정을 수정할 권한이 없습니다.') });
    }

    // 캘린더 이동 검사.
    let targetCalendar = calendar;
    if (b.calendarId !== undefined && b.calendarId !== calendar.id) {
      if (!isUuid(b.calendarId)) return res.status(400).json({ error: '캘린더가 올바르지 않습니다.' });
      if (isRecurring && scope !== 'all') {
        return res.status(400).json({ error: '반복 일정은 전체 수정일 때만 캘린더를 옮길 수 있습니다.' });
      }
      const target = await findCalendarById(b.calendarId);
      if (!target || target.teamId !== calendar.teamId) return res.status(400).json({ error: '옮길 캘린더를 찾을 수 없습니다.' });
      const targetAccess = await calendarAccess(target, userId);
      if (!targetAccess.canCreateEvents) {
        return res.status(403).json({ error: deniedText(targetAccess, '그 캘린더에 일정을 만들 권한이 없습니다.') });
      }
      targetCalendar = target;
    }

    const masterStart = event.startAt.getTime();
    const masterEnd = event.endAt.getTime();
    const duration = masterEnd - masterStart;
    // 반복 일정의 start/end 기본값은 "편집한 회차"의 값이다 — 클라이언트가 그 회차 기준으로 폼을 채워 보내기 때문.
    const occStart = isRecurring ? occurrenceStart : masterStart;
    const parsed = parseEventFields(b, {
      title: event.title,
      description: event.description,
      location: event.location,
      startMs: occStart,
      endMs: occStart + duration,
      allDay: event.allDay,
      visibility: event.visibility,
    });
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const f = parsed.fields;
    const hasRecurrence = b.recurrence !== undefined;
    const attendeeIdsInput = f.attendeeIds;
    let attendeeResult = null;
    if (attendeeIdsInput) {
      attendeeResult = await resolveAttendees(calendar.teamId, attendeeIdsInput, {
        requesterRole: access.team.role,
        keep: new Set(oldAttendeeIds),
      });
      if (attendeeResult.error) return res.status(400).json({ error: attendeeResult.error });
    }
    const shared = {
      title: f.title,
      description: f.description,
      location: f.location,
      allDay: f.allDay,
      visibility: f.visibility,
    };
    const notifyTargets = [...oldAttendeeIds, ...(attendeeResult?.ids ?? [])];
    const changedCalendars = [calendar];

    let resultId;

    if (scope === 'this') {
      // 이 회차만: 원본에서 이 회차를 빼고, 바뀐 내용으로 반복 없는 새 일정을 만든다.
      if (!allowEventCreate(req, res)) return;
      const created = await splitEvent(
        event.id,
        { exdates: normalizeExdates([...(event.exdates ?? []), occurrenceStart]) },
        {
          calendarId: calendar.id,
          creatorId: event.creatorId,
          ...shared,
          startAt: new Date(f.startMs),
          endAt: new Date(f.endMs),
          recurrence: null,
          exdates: [],
        },
        { attendeeIds: attendeeResult?.ids },
      );
      resultId = created.id;
      if (f.color) await setEventColor(created.id, userId, f.color);
    } else if (scope === 'following') {
      // 이 회차와 이후: 원본은 이 회차 전날까지로 줄이고, 같은 규칙의 새 시리즈를 만든다.
      const view = recurringView(event);
      const split = splitRecurrenceAt(view, occurrenceStart, index);
      let rawNewRec = split.after;
      if (hasRecurrence) rawNewRec = b.recurrence;
      else rawNewRec = followStartWeekday(rawNewRec, occurrenceStart, f.startMs, f.allDay);
      const fin = finalizeRecurrence(rawNewRec, f.startMs, f.endMs, f.allDay);
      if (fin.error) return res.status(400).json({ error: fin.error });
      if (!allowEventCreate(req, res)) return;
      const sameStart = fin.startMs === occurrenceStart && f.allDay === event.allDay;
      const oldExdates = normalizeExdates(event.exdates);
      const created = await splitEvent(
        event.id,
        { recurrence: split.before, exdates: oldExdates.filter((x) => x < occurrenceStart) },
        {
          calendarId: calendar.id,
          creatorId: event.creatorId,
          ...shared,
          startAt: new Date(fin.startMs),
          endAt: new Date(fin.endMs),
          recurrence: fin.recurrence,
          exdates: sameStart && fin.recurrence ? oldExdates.filter((x) => x >= occurrenceStart) : [],
        },
        { attendeeIds: attendeeResult?.ids },
      );
      resultId = created.id;
      if (f.color) await setEventColor(created.id, userId, f.color);
    } else {
      // 전체: 시리즈(또는 단일 일정) 자체를 바꾼다.
      let newStart = f.startMs;
      let newEnd = f.endMs;
      if (isRecurring) {
        // start/end는 편집한 회차의 값이므로, 회차가 옮겨진 만큼(=회차와 원본 사이 간격은 그대로) 원본을 옮긴다.
        // 클라이언트가 회차가 아닌 원본의 start를 그대로 보낸 경우(값이 원본 시작과 같음)는 시작을 안 바꾼 것으로 본다.
        const shift = b.start !== undefined && f.startMs !== masterStart ? f.startMs - occStart : 0;
        newStart = masterStart + shift;
        newEnd = newStart + (f.endMs - f.startMs);
      }
      let rawRec = hasRecurrence ? b.recurrence : event.recurrence;
      if (!hasRecurrence) rawRec = followStartWeekday(rawRec, masterStart, newStart, f.allDay);
      const fin = finalizeRecurrence(rawRec, newStart, newEnd, f.allDay);
      if (fin.error) return res.status(400).json({ error: fin.error });

      // exdates는 원래 회차 시작 ms 목록이라 시리즈가 옮겨지면 뜻이 달라진다 — 시각만 바뀐 경우는 같이 옮기고,
      // 날짜가 바뀌었거나 종일 여부가 바뀌었거나 반복이 없어졌으면 비운다.
      // 회의실·자원 — 일정을 고치기 전에 잡거나 옮겨 둔다(겹치면 일정도 안 바뀐다).
      const existingBookings = (await listBookingsForEvents([event.id])).get(event.id) ?? [];
      const nextIds = wantedResourceIds === undefined ? existingBookings.map((x) => x.resourceId) : wantedResourceIds;
      if (nextIds.length && fin.recurrence) {
        return res.status(400).json({
          error: existingBookings.length
            ? '회의실·자원을 잡은 일정은 반복할 수 없습니다. 먼저 회의실·자원을 빼세요.'
            : '반복 일정에는 회의실·자원을 잡을 수 없습니다. 회차마다 따로 잡으세요.',
        });
      }
      const range = eventBookingRange({ startMs: fin.startMs, endMs: fin.endMs, allDay: f.allDay });
      // 붙은 자원들 맞추기 — 빠진 것 지우고, 새것 잡고, 시간이 바뀌면 옮긴다(한 트랜잭션 — 안 되면 일정도 안 바뀐다).
      const synced = await syncEventResources({
        io,
        eventId: event.id,
        title: f.title,
        resourceIds: wantedResourceIds,
        existing: existingBookings,
        range,
        user: access.team.user,
        teamId: calendar.teamId,
        role: access.team.role,
      });
      if (synced.error) return res.status(synced.status).json({ error: synced.error });
      for (const scopeKey of synced.scopes) await broadcastResources(io, scopeKey);

      let exdates = normalizeExdates(event.exdates);
      const delta = fin.startMs - masterStart;
      const dateChanged = dateStringOf(fin.startMs, f.allDay) !== dateStringOf(masterStart, event.allDay);
      if (!fin.recurrence || f.allDay !== event.allDay || (delta !== 0 && dateChanged)) exdates = [];
      else if (delta !== 0) exdates = exdates.map((x) => x + delta);

      const updated = await updateEvent(
        event.id,
        {
          ...shared,
          calendarId: targetCalendar.id,
          startAt: new Date(fin.startMs),
          endAt: new Date(fin.endMs),
          recurrence: fin.recurrence,
          exdates,
        },
        { attendeeIds: attendeeResult?.ids },
      );
      resultId = updated.id;
      if (f.color) await setEventColor(updated.id, userId, f.color);
      if (targetCalendar.id !== calendar.id) changedCalendars.push(targetCalendar);
    }

    for (const c of changedCalendars) await notifyChanged(c, notifyTargets);
    res.json(await describeEvent(resultId, userId));
  });

  // ── 13. 일정 삭제 ──
  router.delete('/events/:id', async (req, res) => {
    const ctx = await loadEvent(req, res);
    if (!ctx) return;
    const { event, calendar, access, attendeeIds } = ctx;
    if (!canModifyCalendarEvent({ access, event, userId: req.user.sub })) {
      return res.status(403).json({ error: deniedText(access, '이 일정을 삭제할 권한이 없습니다.') });
    }
    const sp = parseScope(req.query.scope, req.query.occurrenceStart, event, { required: false });
    if (sp.error) return res.status(400).json({ error: sp.error });
    const { scope, occurrenceStart, index } = sp;

    if (!event.recurrence || scope === 'all' || (scope === 'following' && index === 0)) {
      // 붙은 회의실·자원 예약은 일정과 같이 지워진다(FK cascade) — 예약 현황을 새로 받게 알린다.
      const eventBookings = (await listBookingsForEvents([event.id])).get(event.id) ?? [];
      await deleteEvent(event.id);
      for (const scopeKey of new Set(eventBookings.map((x) => x.scopeKey))) await broadcastResources(io, scopeKey);
    } else if (scope === 'this') {
      await updateEvent(event.id, { exdates: normalizeExdates([...(event.exdates ?? []), occurrenceStart]) });
    } else {
      const split = splitRecurrenceAt(recurringView(event), occurrenceStart, index);
      await updateEvent(event.id, {
        recurrence: split.before,
        exdates: normalizeExdates(event.exdates).filter((x) => x < occurrenceStart),
      });
    }
    await notifyChanged(calendar, [...attendeeIds, req.user.sub]);
    res.json({ ok: true });
  });

  return router;
}

// ── 일정 회차 모으기 ──────────────────────────────────────────────────────

/**
 * [teamId]에서 [userId]가 볼 수 있는 일정(볼 수 있는 캘린더 + 참석자로 초대받은 일정)의 [fromMs, toMs) 회차 — 일정 조회(GET
 * /teams/:teamId/calendar/events)와 내 일정 내보내기(ICS 피드 — calendarFeeds.js)가 같이 쓴다. [builtIns]면 공휴일·생일도 넣고,
 * [skipHidden]이면 내가 숨긴 캘린더의 일정을 뺀다. 정렬은 하지 않는다(sortOccurrences). { result, truncated }.
 */
export async function collectOccurrences({ team, teamId, userId, fromMs, toMs, builtIns = true, skipHidden = false }) {
  // 종일 회차(공휴일·생일 포함)는 날짜를 "한국 날짜"로 보고 구간과 겹치는지 잰다. 표현은 UTC 자정 ms라
  // 구간을 9시간 밀어서 비교하면 한국 시간 자정 기준 구간(한 달 격자 등)과 정확히 맞는다.
  const dayFrom = fromMs + KST_OFFSET_MS;
  const dayTo = toMs + KST_OFFSET_MS;

  const candidates = await listCalendarCandidates(teamId, userId);
  const infoById = new Map();
  for (const { calendar, member } of candidates) {
    const access = await calendarAccess(calendar, userId, { team, member });
    infoById.set(calendar.id, { calendar, access });
  }
  const viewableIds = [...infoById.values()].filter((i) => i.access.canView).map((i) => i.calendar.id);

  const events = await listEventsForWindow({
    teamId,
    calendarIds: viewableIds,
    attendeeUserId: userId,
    fromMs,
    toMs,
    slackMs: KST_OFFSET_MS,
  });

  // 참석자로만 초대받은 일정의 캘린더(내가 못 보는 캘린더) 정보도 채운다.
  const missing = [...new Set(events.map((e) => e.calendarId))].filter((id) => !infoById.has(id));
  if (missing.length > 0) {
    const cals = await findCalendarsByIds(missing);
    const rows = await listMemberRowsForUser(userId, missing);
    for (const calendar of cals) {
      const access = await calendarAccess(calendar, userId, { team, member: rows.get(calendar.id) ?? null });
      infoById.set(calendar.id, { calendar, access });
    }
  }

  const eventIds = events.map((e) => e.id);
  const [attendeesByEvent, colors, bookings] = await Promise.all([
    listAttendeesForEvents(eventIds),
    listEventColorsForUser(eventIds, userId),
    listBookingsForEvents(eventIds),
  ]);

  // 볼 수 있는 일정만 추린다(내가 못 보는 캘린더의 일정이라도 참석자로 초대받았으면 보인다).
  const visible = [];
  for (const event of events) {
    const info = infoById.get(event.calendarId);
    if (!info) continue;
    const attendees = attendeesByEvent.get(event.id) ?? [];
    const isAttendee = attendees.some((a) => a.userId === userId);
    if (!(info.access.canView || isAttendee)) continue;
    // 내보내기는 앱에서 숨긴 캘린더의 일정을 빼고 보낸다(참석자로 초대받은 일정은 숨김과 상관없이 나간다).
    if (skipHidden && !isAttendee && info.access.member?.hidden === true) continue;
    visible.push({ event, info, attendees, isAttendee });
  }

  // 응답 전체의 회차 상한 — fillOccurrenceBudget이 구간에 회차가 있는 일정에만 차례를 주고(내 일정이 먼저, 나머지는 만든
  // 사람마다 돌아가며 — 일정을 대량으로 만들어도 남의 일정을 밀어내지 못한다) 그 순서대로 상한까지 펼친다.
  // 회차는 OCCURRENCE_MAX_MS 앞의 것만 펼친다 — 조회로 받은 회차는 모두 수정·삭제에서 그대로 다시 지정할 수 있어야
  // 하기 때문이다(parseScope). 종일 회차는 dayTo 쪽을 같은 끝에서 자르므로 날짜가 MAX_UNTIL까지인 것만 나온다.
  const occurrenceTo = Math.min(toMs, OCCURRENCE_MAX_MS);
  const occurrenceDayTo = Math.min(dayTo, OCCURRENCE_MAX_MS);
  const filled = fillOccurrenceBudget(visible, {
    viewerId: userId,
    budget: QUERY_OCCURRENCE_MAX,
    expand: ({ event }, limit) =>
      expandOccurrences(
        recurringView(event),
        event.allDay ? dayFrom : fromMs,
        event.allDay ? occurrenceDayTo : occurrenceTo,
        { limit },
      ),
  });
  const result = [];
  for (const { item, occurrences } of filled) {
    const { event, info, attendees, isAttendee } = item;
    for (const occ of occurrences) {
      result.push(
        toOccurrenceDto({
          event,
          start: occ.start,
          end: occ.end,
          info,
          viewerId: userId,
          attendees,
          isAttendee,
          myColor: colors.get(event.id),
          bookings: bookings.get(event.id) ?? [],
        }),
      );
    }
  }
  const truncated = result.length >= QUERY_OCCURRENCE_MAX;
  if (truncated) {
    // 정상적인 캘린더로는 닿기 어려운 양이라, 일정 대량 생성 같은 남용을 알아챌 수 있게 남긴다.
    console.warn(`[calendar] 일정 조회 회차를 상한(${QUERY_OCCURRENCE_MAX}개)까지만 보냈습니다 — 팀 ${teamId}, 사용자 ${userId}`);
  }

  if (!builtIns) return { result, truncated };
  // 공휴일 — 모두에게.
  for (const h of holidaysInRange(dayFrom, dayTo)) {
    result.push(builtInOccurrence({ key: `holiday:${h.date}`, calendarId: 'holidays', source: 'holiday', title: h.name, start: h.startMs, end: h.endMs, color: HOLIDAY_COLOR }));
  }
  // 생일 — 정회원 이상만.
  if (team.role !== 'guest') {
    const birthdays = await listTeamBirthdays(teamId);
    const firstYear = new Date(dayFrom).getUTCFullYear();
    const lastYear = new Date(dayTo).getUTCFullYear();
    for (const person of birthdays) {
      const match = /^(\d{2})-(\d{2})$/.exec(person.birthday ?? '');
      if (!match) continue;
      for (let year = firstYear; year <= lastYear; year++) {
        const startMs = birthdayStart(year, Number(match[1]), Number(match[2]));
        if (startMs === null) continue;
        if (startMs < dayTo && startMs + DAY_MS > dayFrom) {
          result.push(
            builtInOccurrence({
              key: `birthday:${person.id}:${new Date(startMs).toISOString().slice(0, 10)}`,
              calendarId: 'birthdays',
              source: 'birthday',
              title: `${person.name ?? person.username} 님의 생일`,
              start: startMs,
              end: startMs + DAY_MS,
              color: BIRTHDAY_COLOR,
            }),
          );
        }
      }
    }
    // 팀 휴가 — 그룹웨어에서 승인된 휴가. 팀 범위면 이 팀의 결재, 회사 전체 범위면 이 팀 사람들의 휴가(정회원 이상만 — 생일과 같다).
    const settings = await getServerSettings();
    const scope = effectiveGroupwareScope(settings);
    const leaves = await listApprovedLeaves({
      scopeKey: groupwareScopeKey(scope, teamId),
      from: new Date(dayFrom).toISOString().slice(0, 10),
      to: new Date(dayTo - 1).toISOString().slice(0, 10),
      userIds: scope === 'server' ? await listTeamMemberIds(teamId) : null,
    });
    for (const leave of leaves) {
      const { leaveType, startDate, endDate } = leave.payload ?? {};
      const startMs = Date.parse(`${startDate}T00:00:00Z`);
      const endMs = Date.parse(`${endDate}T00:00:00Z`) + DAY_MS;
      if (Number.isNaN(startMs) || Number.isNaN(endMs)) continue;
      result.push(
        builtInOccurrence({
          key: `leave:${leave.id}`,
          calendarId: 'leaves',
          source: 'leave',
          title: `${leave.authorName} ${leave.payload?.leaveLabel ?? leaveTypeOf(leaveType)?.label ?? '휴가'}`,
          start: startMs,
          end: endMs,
          color: LEAVE_COLOR,
        }),
      );
    }
    // 출장 — 그룹웨어에서 승인된 출장 신청(휴가와 같은 범위·같은 사람들).
    const trips = await listApprovedTrips({
      scopeKey: groupwareScopeKey(scope, teamId),
      from: new Date(dayFrom).toISOString().slice(0, 10),
      to: new Date(dayTo - 1).toISOString().slice(0, 10),
      userIds: scope === 'server' ? await listTeamMemberIds(teamId) : null,
    });
    for (const trip of trips) {
      const { startDate, endDate, destination } = trip.payload ?? {};
      const startMs = Date.parse(`${startDate}T00:00:00Z`);
      const endMs = Date.parse(`${endDate}T00:00:00Z`) + DAY_MS;
      if (Number.isNaN(startMs) || Number.isNaN(endMs)) continue;
      result.push(
        builtInOccurrence({
          key: `trip:${trip.id}`,
          calendarId: 'trips',
          source: 'trip',
          title: destination ? `${trip.authorName} 출장 · ${destination}` : `${trip.authorName} 출장`,
          start: startMs,
          end: endMs,
          color: TRIP_COLOR,
          location: destination ?? null,
        }),
      );
    }
    // 회의실 예약 — 그룹웨어에서 바로 잡은 내 예약(일정에 붙인 것은 그 일정으로 이미 보인다).
    const scopeKey = await resourceScopeKeyForTeam(teamId);
    for (const b of await listStandaloneBookingsForCalendar({ scopeKey, userId, fromMs, toMs })) {
      result.push(
        builtInOccurrence({
          key: `booking:${b.id}`,
          calendarId: 'bookings',
          source: 'booking',
          title: b.title,
          start: b.startAt.getTime(),
          end: b.endAt.getTime(),
          color: BOOKING_COLOR,
          allDay: false,
          location: b.resourceName,
          resource: eventResourceDto(b),
        }),
      );
    }
  }

  return { result, truncated };
}

/** 종일 회차는 "날짜"라서 같은 날의 시간 일정보다 앞에 오도록 시작 시각을 한국 벽시계로 바꿔 비교한다. */
export function sortOccurrences(list) {
  const sortKey = (o) => (o.allDay ? o.start : o.start + KST_OFFSET_MS);
  return list.sort((a, b) => sortKey(a) - sortKey(b) || Number(b.allDay) - Number(a.allDay) || a.title.localeCompare(b.title, 'ko'));
}

// ── 내장 캘린더 회차 ────────────────────────────────────────────────────

/** 공휴일·생일·휴가·회의실 예약 회차 — 일정이 아니라서 eventId·작성자·참석자가 없고 고칠 수 없다(예약만 시간 회차). */
function builtInOccurrence({ key, calendarId, source, title, start, end, color, allDay = true, location = null, resource = null }) {
  return {
    key,
    eventId: null,
    calendarId,
    source,
    title,
    description: null,
    location,
    resource,
    start,
    end,
    allDay,
    visibility: 'public',
    restricted: false,
    recurring: false,
    recurrence: null,
    creatorId: null,
    creatorName: null,
    attendees: [],
    color,
    canEdit: false,
    canDelete: false,
  };
}

/**
 * [year]년 생일 회차의 날짜(UTC 자정 ms). 평년의 2월 29일은 3월 1일로 보여 준다.
 * 월-일이 아예 없는 날짜(13월 등)면 null.
 */
export function birthdayStart(year, month, day) {
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  const ms = Date.UTC(year, month - 1, day);
  const d = new Date(ms);
  if (d.getUTCMonth() === month - 1) return ms;
  // 넘쳐서 다음 달로 간 경우: 2월 29일(평년)만 3월 1일로 받아 주고 나머지는 잘못된 값이다.
  return month === 2 && day === 29 ? Date.UTC(year, 2, 1) : null;
}

/** 생일이 바뀌면 그 사람이 속한 팀의 정회원 이상 팀원들에게 캘린더 새로고침을 알린다(users.js). */
export async function notifyBirthdayChanged(io, userId) {
  const teamIds = await listTeamIdsForUser(userId);
  for (const teamId of teamIds) {
    for (const id of await listTeamNonGuestMemberIds(teamId)) {
      io.to(`user:${id}`).emit('calendar:changed', { teamId, calendarId: 'birthdays' });
    }
  }
}

/**
 * 일정 입력의 회의실·자원 — `resourceIds`(목록)가 있으면 그것, 없으면 예전 `resourceId`(null이면 빈 목록 — 빼기), 둘 다 없으면 undefined
 * (그대로). 모양이 틀리면 'invalid'.
 */
function requestedResourceIds(body) {
  if (body?.resourceIds !== undefined) {
    if (body.resourceIds === null) return [];
    if (!Array.isArray(body.resourceIds) || !body.resourceIds.every(isUuid)) return 'invalid';
    return [...new Set(body.resourceIds)];
  }
  if (body?.resourceId === undefined) return undefined;
  if (body.resourceId === null) return [];
  return isUuid(body.resourceId) ? [body.resourceId] : 'invalid';
}
