// 외부 캘린더 연동 — ICS 읽기(icsImport.js), 구독 주소 규칙(externalCalendarRules.js), 내 일정 내보내기(icsFeed.js)와 연결
// (externalCalendars.js·calendarFeeds.js·calendars.js·index.js) — `node --test test/*.test.js`. DB·네트워크 없이 돈다.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import {
  EXTERNAL_ID_PREFIX,
  fetchErrorText,
  normalizeIcsUrl,
  toExternalCalendarDto,
  toExternalOccurrenceDto,
} from '../src/externalCalendarRules.js';
import { buildIcsFeed, escapeIcsText, foldIcsLine } from '../src/icsFeed.js';
import { looksLikeIcs, parseIcs, wallTimeToMs } from '../src/icsImport.js';

const WINDOW = { fromMs: Date.UTC(2026, 0, 1), toMs: Date.UTC(2027, 11, 31) };
const iso = (ms) => new Date(ms).toISOString();

function ics(...events) {
  return ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:test', 'X-WR-CALNAME:회사 일정', ...events, 'END:VCALENDAR'].join('\r\n');
}

const NY_TZ = [
  'BEGIN:VTIMEZONE',
  'TZID:America/New_York',
  'BEGIN:DAYLIGHT',
  'TZOFFSETFROM:-0500',
  'TZOFFSETTO:-0400',
  'DTSTART:19700308T020000',
  'RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU',
  'END:DAYLIGHT',
  'BEGIN:STANDARD',
  'TZOFFSETFROM:-0400',
  'TZOFFSETTO:-0500',
  'DTSTART:19701101T020000',
  'RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU',
  'END:STANDARD',
  'END:VTIMEZONE',
].join('\r\n');

test('반복 일정: 파일 안 시간대(서머타임)·빠진 회차(EXDATE)·옮긴 회차(RECURRENCE-ID)·취소한 회차', () => {
  const text = ics(
    NY_TZ,
    'BEGIN:VEVENT\r\nUID:weekly\r\nDTSTART;TZID=America/New_York:20261012T090000\r\nDTEND;TZID=America/New_York:20261012T100000\r\n' +
      'RRULE:FREQ=WEEKLY;COUNT=6\r\nEXDATE;TZID=America/New_York:20261019T090000\r\nSUMMARY:주간 회의\r\nEND:VEVENT',
    'BEGIN:VEVENT\r\nUID:weekly\r\nRECURRENCE-ID;TZID=America/New_York:20261026T090000\r\n' +
      'DTSTART;TZID=America/New_York:20261026T110000\r\nDTEND;TZID=America/New_York:20261026T120000\r\nSUMMARY:주간 회의(옮김)\r\nEND:VEVENT',
    'BEGIN:VEVENT\r\nUID:weekly\r\nRECURRENCE-ID;TZID=America/New_York:20261109T090000\r\n' +
      'DTSTART;TZID=America/New_York:20261109T090000\r\nSTATUS:CANCELLED\r\nSUMMARY:주간 회의\r\nEND:VEVENT',
  );
  const { name, occurrences } = parseIcs(text, WINDOW);
  assert.equal(name, '회사 일정');
  assert.deepEqual(
    occurrences.map((o) => [o.title, iso(o.start)]),
    [
      ['주간 회의', '2026-10-12T13:00:00.000Z'], // 서머타임(UTC-4)
      ['주간 회의(옮김)', '2026-10-26T15:00:00.000Z'],
      ['주간 회의', '2026-11-02T14:00:00.000Z'], // 표준시(UTC-5)
      ['주간 회의', '2026-11-16T14:00:00.000Z'],
    ],
  );
  assert.equal(occurrences[0].end - occurrences[0].start, 3600000);
  assert.ok(occurrences.every((o) => o.uid === 'weekly' && o.allDay === false));
});

test('종일 일정은 UTC 자정 ms(끝은 배타), VTIMEZONE 없는 TZID는 IANA 이름이면 그 시간대, 아니면·떠 있는 시각은 한국 시간', () => {
  const text = ics(
    'BEGIN:VEVENT\r\nUID:a\r\nDTSTART;VALUE=DATE:20261015\r\nDTEND;VALUE=DATE:20261017\r\nSUMMARY:워크숍\r\nEND:VEVENT',
    'BEGIN:VEVENT\r\nUID:b\r\nDTSTART;VALUE=DATE:20261020\r\nSUMMARY:끝 없는 종일\r\nEND:VEVENT',
    'BEGIN:VEVENT\r\nUID:c\r\nDTSTART;TZID=Europe/London:20261015T090000\r\nDURATION:PT30M\r\nSUMMARY:런던\r\nEND:VEVENT',
    'BEGIN:VEVENT\r\nUID:d\r\nDTSTART;TZID=Korea Standard Time:20261015T090000\r\nSUMMARY:윈도우 이름\r\nEND:VEVENT',
    'BEGIN:VEVENT\r\nUID:e\r\nDTSTART:20261015T090000\r\nSUMMARY:떠 있는 시각\r\nEND:VEVENT',
    'BEGIN:VEVENT\r\nUID:f\r\nDTSTART:20261015T000000Z\r\nDTEND:20261015T010000Z\r\nSUMMARY:UTC\r\n' +
      'DESCRIPTION:첫 줄\\n둘째 줄\\, 쉼표\r\nLOCATION:3층 회의실\r\nEND:VEVENT',
  );
  const byUid = Object.fromEntries(parseIcs(text, WINDOW).occurrences.map((o) => [o.uid, o]));
  assert.equal(byUid.a.allDay, true);
  assert.equal(byUid.a.start, Date.UTC(2026, 9, 15));
  assert.equal(byUid.a.end, Date.UTC(2026, 9, 17));
  assert.equal(byUid.b.end - byUid.b.start, 86400000, '끝이 없는 종일 일정은 하루');
  assert.equal(iso(byUid.c.start), '2026-10-15T08:00:00.000Z'); // 런던 서머타임(UTC+1)
  assert.equal(byUid.c.end - byUid.c.start, 30 * 60000);
  assert.equal(iso(byUid.d.start), '2026-10-15T00:00:00.000Z'); // 한국 09:00
  assert.equal(iso(byUid.e.start), '2026-10-15T00:00:00.000Z');
  assert.equal(byUid.f.description, '첫 줄\n둘째 줄, 쉼표');
  assert.equal(byUid.f.location, '3층 회의실');
});

test('구간 밖·취소된 일정은 빼고, 초·분 단위 반복은 첫 회차만, 회차 상한에 닿으면 truncated', () => {
  const text = ics(
    'BEGIN:VEVENT\r\nUID:old\r\nDTSTART:20200101T000000Z\r\nSUMMARY:옛날\r\nEND:VEVENT',
    'BEGIN:VEVENT\r\nUID:cancel\r\nDTSTART:20261001T000000Z\r\nSTATUS:CANCELLED\r\nSUMMARY:취소\r\nEND:VEVENT',
    'BEGIN:VEVENT\r\nUID:sec\r\nDTSTART:20261001T000000Z\r\nRRULE:FREQ=SECONDLY\r\nSUMMARY:초마다\r\nEND:VEVENT',
    'BEGIN:VEVENT\r\nUID:daily\r\nDTSTART;VALUE=DATE:20261001\r\nRRULE:FREQ=DAILY\r\nSUMMARY:매일\r\nEND:VEVENT',
  );
  const all = parseIcs(text, WINDOW);
  assert.equal(all.occurrences.filter((o) => o.uid === 'old' || o.uid === 'cancel').length, 0);
  assert.equal(all.occurrences.filter((o) => o.uid === 'sec').length, 1);
  assert.ok(all.occurrences.filter((o) => o.uid === 'daily').length > 400);
  const capped = parseIcs(text, { ...WINDOW, maxOccurrences: 10 });
  assert.equal(capped.occurrences.length, 10);
  assert.equal(capped.truncated, true);
  // 시리즈 하나가 훑는 회차 상한 — 끝없는 반복도 거기서 멈춘다.
  const iter = parseIcs(text, { ...WINDOW, maxIterationsPerSeries: 5 });
  assert.equal(iter.occurrences.filter((o) => o.uid === 'daily').length, 5);
});

test('ICS가 아니면(로그인 화면 HTML 등) 거절', () => {
  assert.equal(looksLikeIcs('﻿BEGIN:VCALENDAR\r\n'), true);
  assert.equal(looksLikeIcs('<!doctype html><html>'), false);
  assert.throws(() => parseIcs('<html></html>', WINDOW), /ICS 형식/);
});

test('벽시계 → 순간: 서머타임 전환 앞뒤', () => {
  const t = { year: 2026, month: 3, day: 9, hour: 9, minute: 0, second: 0 };
  assert.equal(iso(wallTimeToMs(t, 'America/New_York')), '2026-03-09T13:00:00.000Z');
  assert.equal(iso(wallTimeToMs({ ...t, day: 7 }, 'America/New_York')), '2026-03-07T14:00:00.000Z');
  assert.equal(iso(wallTimeToMs(t, '없는 시간대')), '2026-03-09T00:00:00.000Z');
});

test('구독 주소: webcal → https, http(s)만, 계정·IP·사내 이름·다른 포트는 거절', () => {
  assert.deepEqual(normalizeIcsUrl(' webcal://calendar.google.com/calendar/ical/x/private-abc/basic.ics '), {
    url: 'https://calendar.google.com/calendar/ical/x/private-abc/basic.ics',
    host: 'calendar.google.com',
  });
  assert.equal(normalizeIcsUrl('https://outlook.office365.com/owa/calendar/a/b/calendar.ics').host, 'outlook.office365.com');
  assert.match(normalizeIcsUrl('').error, /입력/);
  assert.match(normalizeIcsUrl('ftp://example.com/a.ics').error, /https/);
  assert.match(normalizeIcsUrl('https://user:pw@example.com/a.ics').error, /아이디/);
  assert.match(normalizeIcsUrl('https://192.168.0.10/a.ics').error, /공개된/);
  assert.match(normalizeIcsUrl('https://[::1]/a.ics').error, /공개된/);
  assert.match(normalizeIcsUrl('http://localhost/a.ics').error, /공개된/);
  assert.match(normalizeIcsUrl('https://example.com:8443/a.ics').error, /포트/);
  assert.match(normalizeIcsUrl('아무 글자').error, /올바른 주소/);
});

test('받기 실패 이유', () => {
  assert.match(fetchErrorText(null, 403), /권한/);
  assert.match(fetchErrorText(null, 404), /찾을 수 없/);
  assert.match(fetchErrorText(new Error('응답이 너무 큽니다.')), /5MB/);
  assert.match(fetchErrorText(new Error('차단된 주소입니다: x')), /접속할 수 없/);
  assert.match(fetchErrorText(Object.assign(new Error('x'), { code: 'ENOTFOUND' })), /찾을 수 없/);
});

test('목록·회차 DTO: id는 ext: 머리, 주소는 호스트만, 회차는 읽기 전용', () => {
  const row = {
    id: 'c1',
    teamId: 't1',
    userId: 'u1',
    name: '회사',
    color: '#039BE5',
    hidden: false,
    host: 'calendar.google.com',
    urlEnc: 'secret',
    lastSuccessAt: new Date(1000),
    lastError: null,
  };
  const dto = toExternalCalendarDto(row);
  assert.equal(dto.id, `${EXTERNAL_ID_PREFIX}c1`);
  assert.equal(dto.kind, 'external');
  assert.equal(dto.urlEnc, undefined);
  assert.equal(JSON.stringify(dto).includes('secret'), false);
  const occ = toExternalOccurrenceDto(
    { uid: 'x', title: '회의', description: null, location: null, startAt: new Date(5000), endAt: new Date(6000), allDay: false },
    row,
  );
  assert.equal(occ.calendarId, 'ext:c1');
  assert.equal(occ.source, 'external');
  assert.equal(occ.canEdit, false);
  assert.equal(occ.color, '#039BE5');
});

test('내보내기: 이스케이프·75바이트 접기·종일은 날짜, 다시 읽으면 같은 일정', () => {
  assert.equal(escapeIcsText('a;b,c\\d\ne'), 'a\\;b\\,c\\\\d\\ne');
  const long = `SUMMARY:${'가'.repeat(60)}`;
  const folded = foldIcsLine(long).split('\r\n');
  assert.ok(folded.length > 1);
  assert.ok(folded.every((l) => Buffer.byteLength(l, 'utf8') <= 75));
  assert.equal(folded.map((l, i) => (i === 0 ? l : l.slice(1))).join(''), long);

  const nowMs = Date.UTC(2026, 9, 14);
  const body = buildIcsFeed({
    name: '탱고톡 · 마케팅',
    nowMs,
    occurrences: [
      { key: 'e1:100', title: '주간 회의; 3층', description: '안건\n- 배너', location: '회의실, A', start: Date.UTC(2026, 9, 15, 1), end: Date.UTC(2026, 9, 15, 2), allDay: false },
      { key: 'e2:200', title: '워크숍', start: Date.UTC(2026, 9, 20), end: Date.UTC(2026, 9, 22), allDay: true },
      { key: 'e3:300', title: '비공개 일정', start: Date.UTC(2026, 9, 16, 5), end: Date.UTC(2026, 9, 16, 6), allDay: false, restricted: true },
    ],
  });
  assert.ok(body.startsWith('BEGIN:VCALENDAR\r\n'));
  assert.ok(body.endsWith('END:VCALENDAR\r\n'));
  assert.match(body, /DTSTART;VALUE=DATE:20261020\r\nDTEND;VALUE=DATE:20261022/);
  assert.match(body, /CLASS:PRIVATE/);
  const back = parseIcs(body, WINDOW);
  assert.equal(back.name, '탱고톡 · 마케팅');
  assert.deepEqual(
    back.occurrences.map((o) => [o.title, o.start, o.end, o.allDay]),
    [
      ['주간 회의; 3층', Date.UTC(2026, 9, 15, 1), Date.UTC(2026, 9, 15, 2), false],
      ['비공개 일정', Date.UTC(2026, 9, 16, 5), Date.UTC(2026, 9, 16, 6), false],
      ['워크숍', Date.UTC(2026, 9, 20), Date.UTC(2026, 9, 22), true],
    ],
  );
  assert.equal(back.occurrences[0].description, '안건\n- 배너');
  assert.equal(back.occurrences[0].location, '회의실, A');
});

test('연결: 라우트·작업·일정 조회 합치기·공개 피드의 확인', () => {
  const index = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');
  assert.match(index, /app\.use\('\/api', requireAuth, createExternalCalendarsRouter\(io\)\)/);
  assert.match(index, /app\.use\('\/api', requireAuth, createCalendarFeedsRouter\(\)\)/);
  assert.match(index, /app\.get\('\/calendar-feed\/:token', rateLimit\(limits\.calendarFeedIp/);
  assert.match(index, /startExternalCalendarJob\(io\)/);

  const calendars = fs.readFileSync(new URL('../src/calendars.js', import.meta.url), 'utf8');
  assert.match(calendars, /externalOccurrencesFor\(\{ teamId, userId, fromMs, toMs \}\)/);
  assert.match(calendars, /listExternalCalendars\(userId, teamId\)\)\.map\(toExternalCalendarDto\)/);

  const ext = fs.readFileSync(new URL('../src/externalCalendars.js', import.meta.url), 'utf8');
  // 바깥 주소는 safeFetch로만, 남의 구독은 404.
  assert.match(ext, /safeFetch\(url,/);
  assert.doesNotMatch(ext, /\bfetch\(/);
  assert.match(ext, /row\.userId !== req\.user\.sub/);

  const feeds = fs.readFileSync(new URL('../src/calendarFeeds.js', import.meta.url), 'utf8');
  // 피드는 매번 계정 상태와 팀 멤버인지 다시 보고, 숨긴 캘린더·공휴일·생일은 뺀다.
  assert.match(feeds, /accountState\(feed\.userId\)/);
  assert.match(feeds, /teamAccess\(feed\.teamId, feed\.userId\)/);
  assert.match(feeds, /builtIns: false,\s+skipHidden: true/);
  assert.match(feeds, /lookupHash\(token\)/);
});
