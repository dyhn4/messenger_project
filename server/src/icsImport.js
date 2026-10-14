import ICAL from 'ical.js';

/**
 * 외부 캘린더(ICS — Google·Outlook·iCloud 등의 구독 주소)를 읽어 [fromMs, toMs) 구간의 회차로 펼치는 순수 모듈(DB·네트워크 없음 —
 * test/externalCalendars.test.js). 받아 오기와 저장은 externalCalendars.js가 한다.
 *
 * 시간 규칙은 우리 캘린더와 같다(calendarRecurrence.js 머리말): 종일 일정은 "그 날짜를 UTC 자정으로 본 ms"(끝은 다음 날 자정,
 * 배타), 시간 일정은 보통의 순간(ms). 파일 안의 VTIMEZONE(서머타임 포함)은 ical.js가 풀고, VTIMEZONE 없이 TZID만 붙은 시각은
 * 그 이름이 IANA 시간대(America/New_York 등)면 그 시간대로, 아니면(시간대 없는 "떠 있는" 시각 포함) 한국 시간으로 읽는다.
 *
 * 비용 상한: 누구의 주소든 넣을 수 있으므로 반복 규칙 하나가 서버를 오래 붙잡지 못하게 시리즈마다 훑는 회차 수를, 캘린더 하나가
 * 내는 회차 수를 제한한다. 초·분 단위 반복(FREQ=SECONDLY/MINUTELY)은 달력에 쓸 일이 없어 첫 회차만 쓴다.
 */

export const ICS_TITLE_MAX = 200;
export const ICS_DESCRIPTION_MAX = 2000;
export const ICS_LOCATION_MAX = 200;
/** 캘린더 하나에서 저장하는 회차 상한. */
export const ICS_MAX_OCCURRENCES = 5000;
/** 반복 시리즈 하나를 펼칠 때 훑는 회차 상한(첫 회차부터 센다 — 매일 반복을 50년 치 훑어도 닿지 않는 값). */
export const ICS_MAX_ITERATIONS_PER_SERIES = 20000;
/** 한 회차의 최대 길이 — 이보다 긴 일정은 여기서 자른다(우리 일정과 같은 상한). */
const MAX_DURATION_MS = 366 * 86400000;
const DAY_MS = 86400000;
const DEFAULT_ZONE = 'Asia/Seoul';
const UNSAFE_FREQS = new Set(['SECONDLY', 'MINUTELY']);

/** 받은 본문이 ICS처럼 보이는지 — 로그인 화면(HTML) 같은 엉뚱한 응답을 파싱 전에 가려낸다. */
export function looksLikeIcs(text) {
  return /^\s*BEGIN:VCALENDAR/i.test(text.replace(/^﻿/, ''));
}

const zoneFormatters = new Map();

/** IANA 시간대 이름이면 그 Intl 포맷터, 아니면 null(Windows 이름 "Korea Standard Time" 등). */
function zoneFormatter(tz) {
  if (zoneFormatters.has(tz)) return zoneFormatters.get(tz);
  let fmt = null;
  try {
    fmt = new Intl.DateTimeFormat('en-US', {
      timeZone: tz,
      hourCycle: 'h23',
      year: 'numeric',
      month: 'numeric',
      day: 'numeric',
      hour: 'numeric',
      minute: 'numeric',
      second: 'numeric',
    });
  } catch {
    fmt = null;
  }
  if (zoneFormatters.size < 100) zoneFormatters.set(tz, fmt);
  return fmt;
}

/** [utcMs] 순간에 [fmt] 시간대의 UTC 오프셋(ms). */
function offsetAt(fmt, utcMs) {
  const parts = {};
  for (const p of fmt.formatToParts(new Date(utcMs))) parts[p.type] = Number(p.value);
  const asUtc = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second);
  return asUtc - Math.floor(utcMs / 1000) * 1000;
}

/** 벽시계 시각(연·월·일·시·분·초)을 [tz] 시간대(못 알아보면 한국 시간)로 읽은 순간(ms). */
export function wallTimeToMs({ year, month, day, hour, minute, second }, tz) {
  const fmt = (tz && zoneFormatter(tz)) || zoneFormatter(DEFAULT_ZONE);
  const wall = Date.UTC(year, month - 1, day, hour, minute, second);
  const guess = wall - offsetAt(fmt, wall);
  return wall - offsetAt(fmt, guess);
}

/** ical.js 시각 하나를 ms로 — 종일은 UTC 자정, 시간대가 풀린 시각은 그대로, 떠 있는 시각은 [tzHint](없으면 한국)로. */
function timeToMs(time, tzHint) {
  if (time.isDate) return Date.UTC(time.year, time.month - 1, time.day);
  const tzid = time.zone?.tzid;
  if (!tzid || tzid === 'floating') return wallTimeToMs(time, time.timezone || tzHint);
  return time.toUnixTime() * 1000;
}

function cut(value, max) {
  if (value == null) return null;
  const s = String(value).replace(/\r\n?/g, '\n').trim();
  if (!s) return null;
  return [...s].length > max ? [...s].slice(0, max).join('') : s;
}

function isCancelled(component) {
  return String(component.getFirstPropertyValue('status') ?? '').toUpperCase() === 'CANCELLED';
}

/** 한 회차를 결과 모양으로. 시각이 이상하면 null. */
function occurrenceOf({ uid, item, startTime, endTime, tzHint }) {
  const allDay = startTime.isDate;
  const start = timeToMs(startTime, tzHint);
  let end = endTime ? timeToMs(endTime, tzHint) : start;
  if (!Number.isFinite(start) || !Number.isFinite(end)) return null;
  if (allDay && end <= start) end = start + DAY_MS;
  if (end < start) end = start;
  if (end - start > MAX_DURATION_MS) end = start + MAX_DURATION_MS;
  return {
    uid,
    title: cut(item.summary, ICS_TITLE_MAX) ?? '(제목 없음)',
    description: cut(item.description, ICS_DESCRIPTION_MAX),
    location: cut(item.location, ICS_LOCATION_MAX),
    start,
    end,
    allDay,
  };
}

/**
 * ICS 본문을 읽어 [fromMs, toMs)와 겹치는 회차를 돌려준다 — { name(X-WR-CALNAME 또는 null), occurrences, truncated }.
 * occurrences는 시작 순. ICS가 아니거나 읽을 수 없으면 throw.
 */
export function parseIcs(text, { fromMs, toMs, maxOccurrences = ICS_MAX_OCCURRENCES, maxIterationsPerSeries = ICS_MAX_ITERATIONS_PER_SERIES }) {
  if (!looksLikeIcs(text)) throw new Error('ICS 형식이 아닙니다.');
  const jcal = ICAL.parse(text.replace(/^﻿/, ''));
  const roots = Array.isArray(jcal[0]) ? jcal : [jcal];
  const occurrences = [];
  let truncated = false;
  let name = null;

  const push = (occ) => {
    if (!occ || occ.end <= fromMs || occ.start >= toMs) return true;
    if (occurrences.length >= maxOccurrences) {
      truncated = true;
      return false;
    }
    occurrences.push(occ);
    return true;
  };

  for (const data of roots) {
    const root = new ICAL.Component(data);
    name ??= cut(root.getFirstPropertyValue('x-wr-calname'), 100);
    // UID별로 원본(RECURRENCE-ID 없음)과 따로 고친 회차(있음)를 모은다.
    const masters = new Map();
    const exceptions = new Map();
    let anonymous = 0;
    for (const vevent of root.getAllSubcomponents('vevent')) {
      if (!vevent.getFirstPropertyValue('dtstart')) continue;
      const uid = String(vevent.getFirstPropertyValue('uid') ?? `no-uid-${anonymous++}`);
      if (vevent.hasProperty('recurrence-id')) {
        if (!exceptions.has(uid)) exceptions.set(uid, []);
        exceptions.get(uid).push(vevent);
      } else if (!masters.has(uid)) {
        masters.set(uid, vevent);
      }
    }

    for (const [uid, vevent] of masters) {
      if (isCancelled(vevent)) continue;
      const event = new ICAL.Event(vevent);
      const tzHint = event.startDate.timezone || null;
      const rrule = vevent.getFirstPropertyValue('rrule');
      const recurring = event.isRecurring() && !UNSAFE_FREQS.has(String(rrule?.freq ?? '').toUpperCase());
      if (!recurring) {
        if (!push(occurrenceOf({ uid, item: event, startTime: event.startDate, endTime: event.endDate, tzHint }))) return done();
        continue;
      }
      for (const ex of exceptions.get(uid) ?? []) event.relateException(ex);
      const it = event.iterator();
      let next;
      let iterations = 0;
      while ((next = it.next())) {
        if (++iterations > maxIterationsPerSeries) break;
        // 원래 회차가 구간 끝을 지나면 멈춘다(따로 옮긴 회차도 원래 자리 순서로 나온다).
        if (timeToMs(next, tzHint) >= toMs + DAY_MS) break;
        const details = event.getOccurrenceDetails(next);
        if (details.item !== event && isCancelled(details.item.component)) continue;
        if (!push(occurrenceOf({ uid, item: details.item, startTime: details.startDate, endTime: details.endDate, tzHint }))) {
          return done();
        }
      }
    }
    // 원본 없이 고친 회차만 있는 경우(구독 범위 밖의 원본 등) — 그 회차만 일정으로 쓴다.
    for (const [uid, list] of exceptions) {
      if (masters.has(uid)) continue;
      for (const vevent of list) {
        if (isCancelled(vevent)) continue;
        const event = new ICAL.Event(vevent);
        const tzHint = event.startDate.timezone || null;
        if (!push(occurrenceOf({ uid, item: event, startTime: event.startDate, endTime: event.endDate, tzHint }))) return done();
      }
    }
  }
  return done();

  function done() {
    occurrences.sort((a, b) => a.start - b.start || a.end - b.end);
    return { name, occurrences, truncated };
  }
}
