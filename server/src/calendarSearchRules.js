// 캘린더 일정 제목 검색의 순수 규칙(쿼리 검사·LIKE 이스케이프·보이는지 판정·DTO) — DB 없이 단위 테스트할 수 있게
// calendars.js에서 떼어 냈다. 라우트는 calendars.js의 `GET /teams/:teamId/calendar/search`.

export const CALENDAR_SEARCH_DEFAULT_LIMIT = 50;
export const CALENDAR_SEARCH_MAX_LIMIT = 100;
export const CALENDAR_SEARCH_QUERY_MAX = 50;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** LIKE 패턴의 특수 문자(\ % _)를 이스케이프해 사용자가 친 글자 그대로 부분 일치시킨다. */
export function escapeLike(text) {
  return text.replace(/[\\%_]/g, (c) => `\\${c}`);
}

/**
 * `GET /teams/:teamId/calendar/search` 쿼리 검사 — 통과하면 `{ q, like, limit, before }`, 아니면 `{ error }`.
 *  - q: 앞뒤 공백을 뺀 검색어(1~50자). 비면 오류.
 *  - limit: 1..100으로 눌러 담는다(기본 50).
 *  - before: 이어받기 커서 `"<startMs>"` 또는 `"<startMs>:<eventId>"`(이전 응답의 nextBefore). 없으면 null,
 *    있으면 `{ ms, id|null }`.
 */
export function parseCalendarSearchQuery(query) {
  const q = typeof query?.q === 'string' ? query.q.trim() : '';
  if (!q) return { error: '검색어를 입력하세요.' };
  if ([...q].length > CALENDAR_SEARCH_QUERY_MAX) {
    return { error: `검색어는 ${CALENDAR_SEARCH_QUERY_MAX}자 이내로 입력하세요.` };
  }
  let limit = CALENDAR_SEARCH_DEFAULT_LIMIT;
  if (query?.limit !== undefined && query.limit !== '') {
    const n = Math.floor(Number(query.limit));
    if (!Number.isFinite(n) || n < 1) return { error: 'limit은 1 이상의 숫자여야 합니다.' };
    limit = Math.min(n, CALENDAR_SEARCH_MAX_LIMIT);
  }
  let before = null;
  if (query?.before !== undefined && query.before !== '') {
    const m = /^(-?\d{1,16})(?::([0-9a-f-]{36}))?$/i.exec(String(query.before));
    if (!m || (m[2] !== undefined && !UUID_RE.test(m[2]))) return { error: 'before가 올바르지 않습니다.' };
    before = { ms: Number(m[1]), id: m[2]?.toLowerCase() ?? null };
  }
  return { q, like: `%${escapeLike(q)}%`, limit, before };
}

/** 응답의 이어받기 커서 — 마지막 항목의 `"<startMs>:<eventId>"`. */
export function searchCursorOf(item) {
  return `${item.start}:${item.eventId}`;
}

/**
 * 이 일정의 제목을 검색 결과에 보여도 되는지(= 상세가 보이는 일정인지). 공개 일정이거나, 비공개여도
 * 만든 사람·참석자·캘린더 소유자·관리자면 true — 목록의 "비공개 일정"(restricted)은 제목이 가려져 있으니 걸리면 안 된다.
 */
export function canSearchEventTitle({ event, viewerId, isAttendee, access }) {
  return (
    event.visibility !== 'private' ||
    event.creatorId === viewerId ||
    isAttendee === true ||
    access?.isOwner === true ||
    access?.isManager === true
  );
}

/** 검색 결과 한 줄(일정 마스터 단위). 종일 일정의 start/end는 기존 규약(UTC 자정 ms) 그대로다. */
export function toSearchItem({ event, calendarName, color, attendees, creatorName, canEdit }) {
  return {
    eventId: event.id,
    calendarId: event.calendarId,
    calendarName,
    color,
    title: event.title,
    start: event.startAt.getTime(),
    end: event.endAt.getTime(),
    allDay: event.allDay,
    recurring: !!event.recurrence,
    recurrence: event.recurrence ?? null,
    attendees,
    creatorName: creatorName ?? null,
    canEdit: canEdit === true,
  };
}
