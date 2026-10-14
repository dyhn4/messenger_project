/**
 * 내 일정 내보내기 — 일정 회차(EventOccurrence 모양, calendars.js의 조회와 같은 것)를 ICS(iCalendar) 본문으로 만드는 순수 모듈
 * (test/externalCalendars.test.js). Google·Outlook 캘린더에 "URL로 구독"하면 이 본문을 주기적으로 받아 간다.
 *
 * 반복 일정은 RRULE로 보내지 않고 회차마다 VEVENT 하나로 보낸다 — 우리 반복 규칙(Asia/Seoul 벽시계·따로 고친 회차)을 그대로
 * 옮기다 생길 어긋남이 없고, 받는 쪽은 그냥 그린다. UID는 회차 키라 같은 회차는 매번 같은 UID다.
 * 시간 일정은 UTC(…Z)로, 종일 일정은 날짜(VALUE=DATE)로 쓴다(종일의 start/end는 UTC 자정 ms — 끝은 배타라 DTEND와 같은 뜻).
 */

const CRLF = '\r\n';

/** TEXT 값 이스케이프(RFC 5545 3.3.11). */
export function escapeIcsText(value) {
  return String(value)
    .replace(/\\/g, '\\\\')
    .replace(/;/g, '\\;')
    .replace(/,/g, '\\,')
    .replace(/\r\n|\r|\n/g, '\\n');
}

/** 한 줄을 75바이트(UTF-8)마다 접는다 — 다음 줄은 공백 하나로 시작. 한글이 중간에서 잘리지 않게 글자 단위로 센다. */
export function foldIcsLine(line) {
  const out = [];
  let current = '';
  let bytes = 0;
  for (const ch of line) {
    const size = Buffer.byteLength(ch, 'utf8');
    const limit = out.length === 0 ? 75 : 74; // 이어지는 줄은 앞의 공백 1바이트를 뺀다.
    if (bytes + size > limit) {
      out.push(current);
      current = '';
      bytes = 0;
    }
    current += ch;
    bytes += size;
  }
  out.push(current);
  return out.join(`${CRLF} `);
}

function pad(n, width = 2) {
  return String(n).padStart(width, '0');
}

/** ms → 20261015T000000Z */
export function icsUtc(ms) {
  const d = new Date(ms);
  return `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}T${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}Z`;
}

/** 종일 ms(UTC 자정) → 20261015 */
export function icsDate(ms) {
  const d = new Date(ms);
  return `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}`;
}

/** UID에 못 쓰는 글자를 걸러 낸다(회차 키는 uuid:ms 꼴이라 보통 그대로다). */
function safeUid(key) {
  return String(key).replace(/[^A-Za-z0-9:._-]/g, '_');
}

/**
 * [name] 캘린더 이름(구독하는 쪽 목록에 보인다), [occurrences] 회차들, [nowMs] DTSTAMP, [uidDomain] UID 뒤에 붙일 이름.
 * 비공개라 내용을 볼 수 없는 회차(restricted)는 "비공개 일정"으로 시간만 나간다(조회와 같다).
 */
export function buildIcsFeed({ name, occurrences, nowMs, uidDomain = 'tangotalk' }) {
  const stamp = icsUtc(nowMs);
  const lines = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//TangoTalk//Calendar Feed//KO',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    `X-WR-CALNAME:${escapeIcsText(name)}`,
    'X-WR-TIMEZONE:Asia/Seoul',
    'REFRESH-INTERVAL;VALUE=DURATION:PT30M',
    'X-PUBLISHED-TTL:PT30M',
  ];
  for (const o of occurrences) {
    lines.push('BEGIN:VEVENT');
    lines.push(`UID:${safeUid(o.key)}@${uidDomain}`);
    lines.push(`DTSTAMP:${stamp}`);
    if (o.allDay) {
      lines.push(`DTSTART;VALUE=DATE:${icsDate(o.start)}`);
      lines.push(`DTEND;VALUE=DATE:${icsDate(Math.max(o.end, o.start + 86400000))}`);
    } else {
      lines.push(`DTSTART:${icsUtc(o.start)}`);
      lines.push(`DTEND:${icsUtc(Math.max(o.end, o.start))}`);
    }
    lines.push(`SUMMARY:${escapeIcsText(o.title ?? '')}`);
    if (o.location) lines.push(`LOCATION:${escapeIcsText(o.location)}`);
    if (o.description) lines.push(`DESCRIPTION:${escapeIcsText(o.description)}`);
    if (o.restricted) lines.push('CLASS:PRIVATE');
    lines.push('TRANSP:OPAQUE');
    lines.push('END:VEVENT');
  }
  lines.push('END:VCALENDAR');
  return lines.map(foldIcsLine).join(CRLF) + CRLF;
}
