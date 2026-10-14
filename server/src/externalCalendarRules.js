import net from 'node:net';

/**
 * 외부 캘린더 연동의 순수 규칙(DB·네트워크 없음 — test/externalCalendars.test.js).
 *  - 가져오기: 외부 ICS 주소 구독(읽기 전용, 나에게만 보인다) — externalCalendars.js가 받아 icsImport.js로 펼친다.
 *  - 내보내기: 내가 볼 수 있는 일정을 ICS 구독 주소로 — Google·Outlook 캘린더에 "URL로 추가"하면 따라온다(icsFeed.js).
 */

/** 앱이 외부 캘린더를 우리 캘린더와 구분하는 id 머리(일정 회차의 calendarId도 `ext:<id>`). */
export const EXTERNAL_ID_PREFIX = 'ext:';
/** 사람마다·팀마다 구독할 수 있는 외부 캘린더 수. */
export const EXTERNAL_CALENDAR_MAX = 10;
export const EXTERNAL_NAME_MAX = 30;
export const EXTERNAL_URL_MAX = 2048;
/** 받는 ICS 본문 상한(풀어서) — 몇 년 치 회사 일정도 보통 1MB 안팎이다. */
export const EXTERNAL_FETCH_MAX_BYTES = 5 * 1024 * 1024;
export const EXTERNAL_FETCH_DEADLINE_MS = 20000;
/** 자동으로 다시 받는 간격(Google도 구독 캘린더를 몇 시간마다 받는다 — 이 정도면 충분히 빠르다). */
export const EXTERNAL_REFRESH_INTERVAL_MS = 30 * 60 * 1000;
/** "지금 새로고침"을 다시 누를 수 있는 간격. */
export const EXTERNAL_MANUAL_REFRESH_MIN_MS = 60 * 1000;
/** 받을 때 펼쳐 저장하는 구간 — 지금부터 과거 1년·미래 2년. 그 밖의 달에는 외부 일정이 보이지 않는다. */
export const EXTERNAL_WINDOW_PAST_MS = 366 * 86400000;
export const EXTERNAL_WINDOW_FUTURE_MS = 2 * 366 * 86400000;

/** 내보내기 피드의 구간 — 지금부터 과거 60일·미래 1년(구독하는 쪽이 받는 양을 적당히). */
export const FEED_WINDOW_PAST_MS = 60 * 86400000;
export const FEED_WINDOW_FUTURE_MS = 366 * 86400000;

/**
 * 사용자가 붙여 넣은 구독 주소를 받을 주소로 — webcal(s)://는 https://로 바꾸고, http(s)만, 아이디·비밀번호가 든 주소와
 * 사설 IP를 직접 적은 주소는 받지 않는다(이름을 푼 IP는 받을 때 safeFetch가 다시 막는다). { url, host } 또는 { error }.
 */
export function normalizeIcsUrl(raw) {
  if (typeof raw !== 'string') return { error: '구독 주소(ICS)를 입력하세요.' };
  let s = raw.trim();
  if (!s) return { error: '구독 주소(ICS)를 입력하세요.' };
  if (s.length > EXTERNAL_URL_MAX) return { error: '주소가 너무 깁니다.' };
  s = s.replace(/^webcals?:\/\//i, 'https://');
  let parsed;
  try {
    parsed = new URL(s);
  } catch {
    return { error: '올바른 주소가 아닙니다. https:// 또는 webcal://로 시작하는 ICS 주소를 넣으세요.' };
  }
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
    return { error: 'https:// 또는 webcal://로 시작하는 ICS 주소를 넣으세요.' };
  }
  if (parsed.username || parsed.password) return { error: '아이디·비밀번호가 들어간 주소는 쓸 수 없습니다.' };
  const host = parsed.hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (!host || host === 'localhost' || host.endsWith('.localhost') || net.isIP(host)) {
    return { error: '인터넷에 공개된 캘린더 주소만 구독할 수 있습니다(IP 주소·사내 주소는 안 됩니다).' };
  }
  if (parsed.port && parsed.port !== '80' && parsed.port !== '443') return { error: '80·443 포트의 주소만 구독할 수 있습니다.' };
  return { url: parsed.toString(), host };
}

/** 받아 오기에 실패했을 때 앱에 보여 줄 짧은 이유. */
export function fetchErrorText(err, status) {
  if (status === 401 || status === 403) return '주소에 접근할 권한이 없습니다. 비공개 주소(ICS)를 다시 복사해 넣으세요.';
  if (status === 404 || status === 410) return '주소에서 캘린더를 찾을 수 없습니다.';
  if (status) return `캘린더 서버가 오류를 돌려줬습니다(${status}).`;
  const msg = String(err?.message ?? err ?? '');
  if (/너무 큽니다/.test(msg)) return '캘린더가 너무 큽니다(5MB 이하만).';
  if (/ICS 형식/.test(msg)) return 'ICS 캘린더가 아닙니다. 캘린더의 "비공개 주소(iCal 형식)"를 넣으세요.';
  if (/시간 초과/.test(msg)) return '캘린더 서버가 응답하지 않습니다.';
  if (/차단|포트/.test(msg)) return '이 주소로는 접속할 수 없습니다.';
  if (err?.code === 'ENOTFOUND' || err?.code === 'EAI_AGAIN') return '주소의 서버를 찾을 수 없습니다.';
  return '캘린더를 받지 못했습니다.';
}

/** 외부 캘린더 행 → 앱의 캘린더 목록 항목(GET /teams/:teamId/calendars의 external). 주소는 호스트만 보낸다. */
export function toExternalCalendarDto(row) {
  return {
    id: `${EXTERNAL_ID_PREFIX}${row.id}`,
    teamId: row.teamId,
    kind: 'external',
    name: row.name,
    color: row.color,
    defaultColor: row.color,
    isPublic: false,
    ownerId: row.userId,
    ownerName: null,
    role: 'subscriber',
    hidden: row.hidden === true,
    canCreateEvents: false,
    canDelete: true,
    canEditSettings: true,
    host: row.host,
    lastSuccessAt: row.lastSuccessAt ? row.lastSuccessAt.getTime() : null,
    lastError: row.lastError ?? null,
  };
}

/** 저장해 둔 외부 회차 → 앱의 EventOccurrence(source 'external' — 읽기 전용). */
export function toExternalOccurrenceDto(row, calendar) {
  const start = row.startAt.getTime();
  return {
    key: `${EXTERNAL_ID_PREFIX}${calendar.id}:${row.uid}:${start}`,
    eventId: null,
    calendarId: `${EXTERNAL_ID_PREFIX}${calendar.id}`,
    source: 'external',
    title: row.title,
    description: row.description ?? null,
    location: row.location ?? null,
    start,
    end: row.endAt.getTime(),
    allDay: row.allDay,
    visibility: 'public',
    restricted: false,
    recurring: false,
    recurrence: null,
    creatorId: null,
    creatorName: calendar.name,
    attendees: [],
    color: calendar.color,
    canEdit: false,
    canDelete: false,
  };
}
