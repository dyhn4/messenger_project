/**
 * 캘린더 반복 일정 계산만 모아둔 순수 모듈(DB·시계 의존 없음 — test/calendarRecurrence.test.js로 검증한다).
 *
 * 시간 규칙(규약의 "종일 일정 표현" 참고):
 *  - 종일 일정의 start/end는 "그 날짜를 UTC 자정으로 본 epoch ms", end는 마지막 날 다음 날 자정(배타)이다.
 *    반복은 날짜 단위로 펼친다.
 *  - 시간 일정은 보통의 순간(epoch ms)이고, 반복은 Asia/Seoul 벽시계 기준으로 펼친다. 한국은 DST가 없어
 *    UTC+9 고정으로 계산해도 되고, 서버 TZ와 무관해야 하므로 Date의 로컬 getter는 절대 쓰지 않는다.
 *  - 그래서 안쪽 계산은 전부 "로컬 ms"(시간 일정은 ms+9h, 종일은 ms 그대로)로 하고 UTC getter만 쓴다.
 *
 * recurrence 모양: { freq: 'daily'|'weekly'|'monthly'|'yearly', interval: 1..99,
 *   byWeekday?: [0..6](일=0, weekly만), until?: 'YYYY-MM-DD'(그 날 포함), count?: 1..500 }.
 * until과 count는 동시에 못 쓴다. count는 "처음 회차를 포함한 총 회차 수"이고, exdates로 빠진 회차도 센다
 * (일부를 지웠다고 시리즈가 더 길어지면 안 되기 때문이다).
 */

export const DAY_MS = 86400000;
export const KST_OFFSET_MS = 9 * 3600 * 1000;

export const FREQS = ['daily', 'weekly', 'monthly', 'yearly'];
export const MAX_INTERVAL = 99;
export const MAX_COUNT = 500;
/** 한 번의 펼침이 다룰 수 있는 최대 구간(규약의 "반복 최대 펼침 3년"). */
export const MAX_EXPAND_SPAN_MS = 3 * 366 * DAY_MS;
/** 회차를 하나하나 세는 작업의 안전 상한 — 오래된 매일 반복도 수십 년어치는 세지만 무한 루프는 막는다. */
const MAX_ITERATIONS = 200000;

// ── 시간·날짜 변환 ─────────────────────────────────────────────────────────

/** 실제 순간(ms) → 펼침용 로컬 ms. 종일은 이미 "날짜 UTC 자정"이라 그대로. */
export function toLocalMs(ms, allDay) {
  return allDay ? ms : ms + KST_OFFSET_MS;
}

export function fromLocalMs(localMs, allDay) {
  return allDay ? localMs : localMs - KST_OFFSET_MS;
}

function dayNumberOf(localMs) {
  return Math.floor(localMs / DAY_MS);
}

/** 로컬 ms → 'YYYY-MM-DD'. */
export function localDateString(localMs) {
  return new Date(localMs).toISOString().slice(0, 10);
}

/** 그 순간이 속한 한국 날짜(시간 일정) 또는 그 날짜(종일) 'YYYY-MM-DD'. */
export function dateStringOf(ms, allDay) {
  return localDateString(toLocalMs(ms, allDay));
}

/** 'YYYY-MM-DD' → 일 번호(1970-01-01 = 0). 형식이 틀리거나 없는 날짜(2월 30일)면 null. */
export function parseDateString(s) {
  if (typeof s !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(s)) return null;
  const ms = Date.parse(`${s}T00:00:00Z`);
  if (Number.isNaN(ms)) return null;
  // Date.parse는 2월 30일을 3월 2일로 넘기지 않고 NaN으로 주지만, 안전하게 다시 문자열로 비교한다.
  if (new Date(ms).toISOString().slice(0, 10) !== s) return null;
  return Math.floor(ms / DAY_MS);
}

function ymd(dayNumber) {
  const d = new Date(dayNumber * DAY_MS);
  return { y: d.getUTCFullYear(), m: d.getUTCMonth(), d: d.getUTCDate() };
}

function daysInMonth(y, m) {
  return new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
}

function weekdayOfDay(dayNumber) {
  return new Date(dayNumber * DAY_MS).getUTCDay();
}

/** 일정 시작의 요일(0=일). 시간 일정은 한국 날짜 기준. */
export function weekdayOf(ms, allDay) {
  return weekdayOfDay(dayNumberOf(toLocalMs(ms, allDay)));
}

// ── 검사·정규화 ────────────────────────────────────────────────────────────

/**
 * 클라이언트가 보낸 recurrence를 검사해 저장할 모양으로 정리한다. 통과하면 `{ value }`(반복 없음이면 value=null),
 * 아니면 `{ error }`. weekly에서 byWeekday가 비면 시작 요일 하나로 채운다.
 */
export function parseRecurrence(raw, { startMs, allDay }) {
  if (raw === null || raw === undefined) return { value: null };
  if (typeof raw !== 'object' || Array.isArray(raw)) return { error: '반복 설정이 올바르지 않습니다.' };
  if (!FREQS.includes(raw.freq)) return { error: '반복 단위가 올바르지 않습니다.' };

  let interval = 1;
  if (raw.interval !== undefined && raw.interval !== null) {
    if (!Number.isInteger(raw.interval) || raw.interval < 1 || raw.interval > MAX_INTERVAL) {
      return { error: `반복 간격은 1~${MAX_INTERVAL} 사이여야 합니다.` };
    }
    interval = raw.interval;
  }

  const rec = { freq: raw.freq, interval };

  const hasWeekdays = Array.isArray(raw.byWeekday) ? raw.byWeekday.length > 0 : raw.byWeekday != null;
  if (raw.freq === 'weekly') {
    let days;
    if (raw.byWeekday == null || (Array.isArray(raw.byWeekday) && raw.byWeekday.length === 0)) {
      days = [weekdayOf(startMs, allDay)];
    } else {
      if (!Array.isArray(raw.byWeekday) || !raw.byWeekday.every((d) => Number.isInteger(d) && d >= 0 && d <= 6)) {
        return { error: '반복 요일이 올바르지 않습니다.' };
      }
      days = [...new Set(raw.byWeekday)].sort((a, b) => a - b);
    }
    rec.byWeekday = days;
  } else if (hasWeekdays) {
    return { error: '반복 요일은 매주 반복에서만 지정할 수 있습니다.' };
  }

  const hasUntil = raw.until !== undefined && raw.until !== null && raw.until !== '';
  const hasCount = raw.count !== undefined && raw.count !== null;
  if (hasUntil && hasCount) return { error: '반복 종료일과 반복 횟수는 함께 쓸 수 없습니다.' };
  if (hasUntil) {
    const untilDay = parseDateString(raw.until);
    if (untilDay === null) return { error: '반복 종료일 형식이 올바르지 않습니다.' };
    if (untilDay < dayNumberOf(toLocalMs(startMs, allDay))) {
      return { error: '반복 종료일은 시작일보다 빠를 수 없습니다.' };
    }
    rec.until = raw.until;
  }
  if (hasCount) {
    if (!Number.isInteger(raw.count) || raw.count < 1 || raw.count > MAX_COUNT) {
      return { error: `반복 횟수는 1~${MAX_COUNT} 사이여야 합니다.` };
    }
    rec.count = raw.count;
  }
  return { value: rec };
}

/**
 * 매주 반복인데 시작일의 요일이 byWeekday에 없으면 시작을 그다음 해당 요일로 옮긴다 — "일정의 시작 = 첫 회차"라는
 * 약속을 지키기 위해서다(이 약속 덕에 첫 회차·following 편집의 '첫 회차면 all'이 단순해진다).
 * 시각(시:분)과 길이는 그대로. 옮길 필요가 없으면 입력 그대로 돌려준다.
 */
export function alignStartToRecurrence(startMs, endMs, allDay, rec) {
  if (!rec || rec.freq !== 'weekly') return { startMs, endMs };
  const start = weekdayOf(startMs, allDay);
  if (rec.byWeekday.includes(start)) return { startMs, endMs };
  let add = 1;
  while (!rec.byWeekday.includes((start + add) % 7)) add++;
  return { startMs: startMs + add * DAY_MS, endMs: endMs + add * DAY_MS };
}

// ── 회차 만들기 ────────────────────────────────────────────────────────────

/** 로컬 "일 번호"를 freq 규칙대로 오름차순으로 하나씩 내놓는다(until/count 적용 전). */
function* iterateDayNumbers(rec, startDay) {
  const interval = rec.interval ?? 1;
  const start = ymd(startDay);
  // 조건에 맞는 날이 한참 안 나오는 경우(2월 29일 매년)의 무한 루프를 막는다.
  let misses = 0;
  const MAX_MISSES = 2000;

  // 아래 각 분기의 for(;;)는 소비하는 쪽(iterateOccurrenceStarts)이 until/count로 끊는 무한 제너레이터다.
  if (rec.freq === 'daily') {
    for (let i = 0; ; i++) yield startDay + i * interval;
  }
  if (rec.freq === 'weekly') {
    const days = rec.byWeekday?.length ? [...rec.byWeekday].sort((a, b) => a - b) : [weekdayOfDay(startDay)];
    // 주는 일요일에 시작한다(byWeekday의 일=0과 같은 기준). 시작일이 속한 주가 0번째 주.
    const weekStart = startDay - weekdayOfDay(startDay);
    for (let w = 0; ; w++) {
      for (const wd of days) {
        const day = weekStart + w * interval * 7 + wd;
        if (day >= startDay) yield day;
      }
    }
  }
  if (rec.freq === 'monthly') {
    for (let i = 0; ; i++) {
      const total = start.y * 12 + start.m + i * interval;
      const y = Math.floor(total / 12);
      const m = total % 12;
      // 그 달에 없는 날짜(31일 등)는 건너뛴다 — 다음 달로 밀지 않는다.
      if (start.d <= daysInMonth(y, m)) {
        misses = 0;
        yield Math.floor(Date.UTC(y, m, start.d) / DAY_MS);
      } else if (++misses > MAX_MISSES) return;
    }
  }
  if (rec.freq === 'yearly') {
    for (let i = 0; ; i++) {
      const y = start.y + i * interval;
      if (start.d <= daysInMonth(y, start.m)) {
        misses = 0;
        yield Math.floor(Date.UTC(y, start.m, start.d) / DAY_MS);
      } else if (++misses > MAX_MISSES) return;
    }
  }
}

/**
 * 일정의 모든 회차 시작(실제 ms)을 시간순으로 내놓는다 — until/count까지 적용, exdates는 적용하지 않는다
 * (그래야 인덱스가 "n번째 회차"로 안정적이다). 반복이 없으면 시작 하나뿐.
 * event = { startMs, allDay, recurrence }
 */
export function* iterateOccurrenceStarts(event) {
  const { startMs, allDay, recurrence: rec } = event;
  const startLocal = toLocalMs(startMs, allDay);
  if (!rec) {
    yield startMs;
    return;
  }
  const startDay = dayNumberOf(startLocal);
  const msOfDay = startLocal - startDay * DAY_MS;
  const untilDay = rec.until ? parseDateString(rec.until) : Infinity;
  const limit = rec.count ?? Infinity;
  let produced = 0;
  let steps = 0;
  for (const day of iterateDayNumbers(rec, startDay)) {
    if (day > untilDay) return;
    yield fromLocalMs(day * DAY_MS + msOfDay, allDay);
    if (++produced >= limit) return;
    if (++steps >= MAX_ITERATIONS) return;
  }
}

/**
 * [fromMs, toMs) 구간에 걸치는 회차들 `[{ start, end }]`(시간순). 회차가 구간과 겹치려면
 * start < toMs && end > fromMs. exdates(원래 회차 시작 ms 목록)에 있는 회차는 뺀다.
 * event = { startMs, endMs, allDay, recurrence, exdates }
 */
export function expandOccurrences(event, fromMs, toMs) {
  const duration = event.endMs - event.startMs;
  const excluded = new Set((event.exdates ?? []).map(Number));
  // 3년보다 긴 구간을 한 번에 펼치지 않는다(호출부가 62일로 제한하지만 순수 함수도 스스로 막는다).
  const to = Math.min(toMs, fromMs + MAX_EXPAND_SPAN_MS);
  const result = [];
  for (const start of iterateOccurrenceStarts(event)) {
    if (start >= to) break;
    if (start + duration <= fromMs) continue;
    if (excluded.has(start)) continue;
    result.push({ start, end: start + duration });
  }
  return result;
}

/**
 * occurrenceStartMs가 이 일정의 몇 번째 회차인지(0부터, exdates 무시). 회차가 아니면 -1.
 * this/following 편집·삭제가 "정말 있는 회차인지" 검사하고 count를 나눌 때 쓴다.
 */
export function occurrenceIndex(event, occurrenceStartMs) {
  let i = 0;
  for (const start of iterateOccurrenceStarts(event)) {
    if (start === occurrenceStartMs) return i;
    if (start > occurrenceStartMs) return -1;
    i++;
  }
  return -1;
}

/**
 * "이 회차와 이후" 편집·삭제를 위해 시리즈를 둘로 가른다(회차 인덱스 index ≥ 1 이어야 한다).
 *  - before: 원래 시리즈의 새 recurrence — occurrenceStart 전날까지(until). count였다면 until로 환산한다.
 *  - after: 새 시리즈가 물려받을 recurrence — 같은 규칙. count였다면 남은 횟수(count - index)로 줄여
 *    전체 횟수가 달라지지 않게 한다.
 */
export function splitRecurrenceAt(event, occurrenceStartMs, index) {
  const rec = event.recurrence;
  const localStart = toLocalMs(occurrenceStartMs, event.allDay);
  const dayBefore = localDateString(Math.floor(localStart / DAY_MS) * DAY_MS - DAY_MS);
  const { count, until, ...rest } = rec;
  const before = { ...rest, until: dayBefore };
  const after = { ...rest };
  if (count != null) after.count = Math.max(1, count - index);
  else if (until != null) after.until = until;
  return { before, after };
}

/** exdates 정리 — 숫자만, 중복 없이 오름차순. */
export function normalizeExdates(list) {
  return [...new Set((Array.isArray(list) ? list : []).map(Number).filter(Number.isFinite))].sort((a, b) => a - b);
}
