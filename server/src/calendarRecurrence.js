/**
 * 캘린더 반복 일정 계산과, 일정 조회가 받는 구간·회차의 범위, 조회 한 번의 회차 상한을 일정들에 나눠 펼치는 규칙을
 * 모아둔 순수 모듈(DB·시계 의존 없음 — test/calendarRecurrence.test.js, test/calendarRecurrenceBounds.test.js로 검증한다).
 *
 * 시간 규칙(규약의 "종일 일정 표현" 참고):
 *  - 종일 일정의 start/end는 "그 날짜를 UTC 자정으로 본 epoch ms", end는 마지막 날 다음 날 자정(배타)이다.
 *    반복은 날짜 단위로 펼친다.
 *  - 시간 일정은 보통의 순간(epoch ms)이고, 반복은 Asia/Seoul 벽시계 기준으로 펼친다. 한국은 DST가 없어
 *    UTC+9 고정으로 계산해도 되고, 서버 TZ와 무관해야 하므로 Date의 로컬 getter는 절대 쓰지 않는다.
 *  - 그래서 안쪽 계산은 전부 "로컬 ms"(시간 일정은 ms+9h, 종일은 ms 그대로)로 하고 UTC getter만 쓴다.
 *
 * recurrence 모양: { freq: 'daily'|'weekly'|'monthly'|'yearly', interval: 1..99,
 *   byWeekday?: [0..6](일=0, weekly만), until?: 'YYYY-MM-DD'(그 날 포함, MAX_UNTIL까지), count?: 1..500 }.
 * until과 count는 동시에 못 쓴다. count는 "처음 회차를 포함한 총 회차 수"이고, exdates로 빠진 회차도 센다
 * (일부를 지웠다고 시리즈가 더 길어지면 안 되기 때문이다).
 *
 * 비용: 회차는 시리즈 첫 회차부터 하나씩 세지 않고, 보려는 구간이 든 주기(일·주·달·해)로 산술로 건너뛰어 만든다.
 * 누구나 반복 일정을 만들 수 있으므로, 오래되었거나 끝이 없는 시리즈를 잔뜩 만들어도 조회 한 번의 비용이
 * 시리즈 나이가 아니라 구간 길이에만 비례해야 한다(그렇지 않으면 조회 하나가 이벤트 루프를 오래 붙잡는다).
 * 한 시리즈가 내는 회차 수와 조회 한 번의 회차 수에도 상한이 있고, 조회 상한을 일정들에 어떻게 나눌지(상한에 닿으면
 * 어느 일정이 빠질지)는 fillOccurrenceBudget이 정한다.
 */

export const DAY_MS = 86400000;
export const KST_OFFSET_MS = 9 * 3600 * 1000;

export const FREQS = ['daily', 'weekly', 'monthly', 'yearly'];
export const MAX_INTERVAL = 99;
export const MAX_COUNT = 500;
/**
 * 반복 종료일(until)로 받을 수 있는 가장 늦은 날. 이보다 먼 날짜는 "종료 없음"과 다를 바 없는 터무니없는 값으로 본다.
 * 회차가 놓일 수 있는 끝(OCCURRENCE_MAX_MS)을 이 다음 날 0시로 맞춰 두어, 조회로 받은 회차에서 "이 일정 및 이후
 * 일정"으로 나눠도 원래 시리즈에 붙는 종료일(그 회차 전날)이 이 범위를 넘지 않는다.
 */
export const MAX_UNTIL = '2299-12-31';
/**
 * 회차 시작이 놓일 수 있는 끝(배타) = MAX_UNTIL 다음 날 0시(UTC). 일정 조회는 이보다 앞의 회차만 펼치고(calendars.js),
 * 회차를 지정하는 수정·삭제(occurrenceStart)도 이보다 앞의 회차만 받는다. 종일 회차는 날짜가 MAX_UNTIL까지, 시간 회차는
 * 한국 날짜로 그다음 날 오전 9시 전까지라, 어느 회차에서 나눠도 종료일(그 회차 전날)이 MAX_UNTIL을 넘지 않는다.
 * 종료일이 MAX_UNTIL 안인 시리즈는 회차가 모두 이 앞이므로, 여기서 잘리는 것은 끝이 없거나 횟수로 그보다 멀리 가는
 * 시리즈의 그 뒤 회차뿐이다.
 */
export const OCCURRENCE_MAX_MS = Date.parse(`${MAX_UNTIL}T00:00:00Z`) + DAY_MS;
/**
 * 일정 조회 구간(from·to)이 놓일 수 있는 범위 — 이 밖의 값(수십만 년 뒤 등)은 Date·DB 시각 범위를 넘어 500이 나기 전에
 * 400으로 막는다. 앱(calendar_controller.dart)은 화면에 걸친 달마다 [그 달 1일 - 1일, 다음 달 1일 + 1일)(기기 시간대 자정)을
 * 따로 받고, 달력 격자는 앞뒤 달의 며칠까지 그린다. 그래서 2299년 12월(MAX_UNTIL이 든 달)을 보면 2300년 1월 덩어리(현지
 * 2300-02-02 자정까지)도 받는다. 1900년 1월 ~ 2299년 12월의 어느 달을 어느 시간대(UTC-12 ~ +14)에서 봐도 요청이 이 안에
 * 들도록(필요한 범위는 대략 1899-11-29 ~ 2300-02-02) 앞뒤로 한 달쯤 더 둔다. 구간 끝이 OCCURRENCE_MAX_MS보다 뒤여도
 * 회차는 그 앞의 것만 나온다.
 */
export const QUERY_MIN_MS = Date.UTC(1899, 10, 1);
export const QUERY_MAX_MS = Date.UTC(2300, 2, 1);
/** 한 시리즈에서 따로 고치거나 지운 회차(exdates)의 최대 수 — 조회마다 훑는 목록이라 끝없이 자라지 않게 한다. */
export const MAX_EXDATES = 1000;
/** 한 번의 펼침이 다룰 수 있는 최대 구간(규약의 "반복 최대 펼침 3년"). */
export const MAX_EXPAND_SPAN_MS = 3 * 366 * DAY_MS;
/** 한 번의 펼침이 한 시리즈에서 내놓는 회차 수 상한(호출부가 limit으로 더 낮출 수 있다). */
export const MAX_OCCURRENCES_PER_EXPAND = 1000;
/** 회차를 차례로 내놓는 작업의 안전 상한 — 호출부가 끊지 않아도 무한 루프는 막는다. */
const MAX_ITERATIONS = 200000;
/** JS Date가 나타낼 수 있는 가장 먼 날(일 번호, ±8.64e15ms) — 이보다 먼 회차는 만들지 않는다. */
const MAX_DAY = 1e8;

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

const MAX_UNTIL_DAY = parseDateString(MAX_UNTIL);

function ymd(dayNumber) {
  const d = new Date(dayNumber * DAY_MS);
  return { y: d.getUTCFullYear(), m: d.getUTCMonth(), d: d.getUTCDate() };
}

const MONTH_DAYS = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

function isLeapYear(y) {
  return (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
}

/** Date 없이 계산한다 — 회차 번호를 셀 때 수백 번 부르므로 가볍고, Date 범위 밖의 해에서도 NaN이 안 된다. */
function daysInMonth(y, m) {
  return m === 1 && isLeapYear(y) ? 29 : MONTH_DAYS[m];
}

function weekdayOfDay(dayNumber) {
  return new Date(dayNumber * DAY_MS).getUTCDay();
}

/** 일정 시작의 요일(0=일). 시간 일정은 한국 날짜 기준. */
export function weekdayOf(ms, allDay) {
  return weekdayOfDay(dayNumberOf(toLocalMs(ms, allDay)));
}

function mod(a, n) {
  return ((a % n) + n) % n;
}

function gcd(a, b) {
  while (b) [a, b] = [b, a % b];
  return a;
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
    if (untilDay > MAX_UNTIL_DAY) return { error: `반복 종료일은 ${MAX_UNTIL}까지 정할 수 있습니다.` };
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

// ── 회차 번호 세기(산술) ───────────────────────────────────────────────────

/**
 * [0, n) 가운데 pred(i)가 참인 i의 수. pred는 주기 period로 되풀이되어야 한다 — 한 주기만 훑고 곱하므로
 * n이 아무리 커도 비용은 period다.
 */
function countPeriodic(n, period, pred) {
  const rest = n % period;
  let perPeriod = 0;
  let inRest = 0;
  for (let i = 0; i < period; i++) {
    if (pred(i)) {
      perPeriod++;
      if (i < rest) inRest++;
    }
  }
  return Math.floor(n / period) * perPeriod + inRest;
}

/** first, first+step, first+2·step, … 해 가운데 앞의 n개에 든 윤년 수. 윤년 규칙은 400년마다 되풀이된다. */
function countLeapYears(first, step, n) {
  return countPeriodic(n, 400 / gcd(400, step), (j) => isLeapYear(first + j * step));
}

/**
 * 매월 반복의 앞쪽 n개 주기(달) 가운데 회차가 있는 달의 수 = n번째 주기 회차의 번호.
 * 그 달에 없는 날짜(29~31일)는 건너뛰므로 n보다 작을 수 있다.
 */
function monthlyOccurrencesBefore(start, interval, n) {
  if (start.d <= 28) return n;
  const base = start.y * 12 + start.m;
  // 주기별 "몇 월"은 12/g 주기마다 되풀이된다(g = gcd(interval, 12)).
  const period = 12 / gcd(interval, 12);
  if (start.d >= 30) {
    // 30·31일은 2월(윤년이어도 29일)에 늘 없으니 몇 월인지만 보면 된다.
    return countPeriodic(n, period, (i) => start.d <= MONTH_DAYS[mod(base + i * interval, 12)]);
  }
  // 29일은 평년 2월만 빠진다. 2월은 period마다 같은 자리에서 한 번 걸리고, 그 해들은 interval/g년 간격이다.
  let firstFeb = -1;
  for (let i = 0; i < period && firstFeb < 0; i++) {
    if (mod(base + i * interval, 12) === 1) firstFeb = i;
  }
  if (firstFeb < 0 || n <= firstFeb) return n;
  const febs = Math.floor((n - 1 - firstFeb) / period) + 1;
  const firstFebYear = Math.floor((base + firstFeb * interval) / 12);
  const leapFebs = countLeapYears(firstFebYear, interval / gcd(interval, 12), febs);
  return n - (febs - leapFebs);
}

/** 매년 반복의 앞쪽 n개 주기(해) 가운데 회차가 있는 해의 수 — 2월 29일만 평년에 빠진다. */
function yearlyOccurrencesBefore(start, interval, n) {
  if (start.m !== 1 || start.d !== 29) return n;
  return countLeapYears(start.y, interval, n);
}

// ── 회차 만들기 ────────────────────────────────────────────────────────────

/** 저장된 간격. parseRecurrence가 1..99만 저장하지만, 이상한 값이어도 0으로 나누거나 제자리를 돌지 않게 1로 본다. */
function intervalOf(rec) {
  return Number.isInteger(rec.interval) && rec.interval >= 1 ? rec.interval : 1;
}

/** 매주 반복의 요일 목록(오름차순·중복 없음). 비었거나 이상한 값뿐이면 시작 요일 하나. */
function weekdaysOf(rec, startDay) {
  const days = Array.isArray(rec.byWeekday)
    ? [...new Set(rec.byWeekday.filter((d) => Number.isInteger(d) && d >= 0 && d <= 6))].sort((a, b) => a - b)
    : [];
  return days.length > 0 ? days : [weekdayOfDay(startDay)];
}

/**
 * 로컬 "일 번호"를 freq 규칙대로 오름차순으로 `{ day, index }`로 내놓는다(until/count 적용 전). index는 시리즈 첫
 * 회차부터 센 회차 번호다. fromDay(≥ startDay)가 든 주기 바로 앞까지는 하나씩 세지 않고 산술로 건너뛰므로,
 * 맨 앞에 fromDay보다 이른 회차가 몇 개 섞일 수 있다(거르는 것은 호출부 몫).
 */
function* iterateDayNumbers(rec, startDay, fromDay) {
  const interval = intervalOf(rec);
  // 조건에 맞는 날이 한참 안 나오는 경우(2월 29일 매년)의 무한 루프를 막는다.
  let misses = 0;
  const MAX_MISSES = 2000;

  // 아래 각 분기의 for(;;)는 소비하는 쪽(occurrencesFrom)이 until/count/구간으로 끊는 무한 제너레이터다.
  if (rec.freq === 'daily') {
    const first = Math.max(0, Math.ceil((fromDay - startDay) / interval));
    for (let i = first; ; i++) yield { day: startDay + i * interval, index: i };
  }
  if (rec.freq === 'weekly') {
    const days = weekdaysOf(rec, startDay);
    // 주는 일요일에 시작한다(byWeekday의 일=0과 같은 기준). 시작일이 속한 주가 0번째 주.
    const weekStart = startDay - weekdayOfDay(startDay);
    const span = interval * 7;
    // 0번째 주에는 시작일 이후 요일만 회차이고, 그 뒤의 반복 주는 모두 days.length개씩이다.
    const firstWeekCount = days.filter((wd) => weekStart + wd >= startDay).length;
    const firstWeek = Math.max(0, Math.floor((fromDay - weekStart) / span));
    let index = firstWeek === 0 ? 0 : firstWeekCount + (firstWeek - 1) * days.length;
    for (let w = firstWeek; ; w++) {
      for (const wd of days) {
        const day = weekStart + w * span + wd;
        if (day >= startDay) yield { day, index: index++ };
      }
    }
  }
  if (rec.freq === 'monthly') {
    const start = ymd(startDay);
    const base = start.y * 12 + start.m;
    const from = ymd(fromDay);
    const first = Math.max(0, Math.floor((from.y * 12 + from.m - base) / interval));
    let index = monthlyOccurrencesBefore(start, interval, first);
    for (let i = first; ; i++) {
      const total = base + i * interval;
      const y = Math.floor(total / 12);
      const m = total - y * 12;
      // 그 달에 없는 날짜(31일 등)는 건너뛴다 — 다음 달로 밀지 않는다.
      if (start.d <= daysInMonth(y, m)) {
        misses = 0;
        yield { day: Math.floor(Date.UTC(y, m, start.d) / DAY_MS), index: index++ };
      } else if (++misses > MAX_MISSES) return;
    }
  }
  if (rec.freq === 'yearly') {
    const start = ymd(startDay);
    const first = Math.max(0, Math.floor((ymd(fromDay).y - start.y) / interval));
    let index = yearlyOccurrencesBefore(start, interval, first);
    for (let i = first; ; i++) {
      const y = start.y + i * interval;
      if (start.d <= daysInMonth(y, start.m)) {
        misses = 0;
        yield { day: Math.floor(Date.UTC(y, start.m, start.d) / DAY_MS), index: index++ };
      } else if (++misses > MAX_MISSES) return;
    }
  }
}

/**
 * 일정의 회차를 시간순으로 `{ start(실제 ms), index }`로 내놓는다 — start ≥ fromMs인 것만. index는 시리즈 첫
 * 회차부터 센 번호다. until/count는 적용하고 exdates는 적용하지 않는다(그래야 인덱스가 "n번째 회차"로 안정적이다).
 * fromMs 앞의 회차는 세지 않고 산술로 건너뛰므로 비용이 시리즈 나이와 무관하다.
 * event = { startMs, allDay, recurrence }
 */
function* occurrencesFrom(event, fromMs) {
  const { startMs, allDay, recurrence: rec } = event;
  if (Number.isNaN(fromMs)) return;
  if (!rec) {
    if (startMs >= fromMs) yield { start: startMs, index: 0 };
    return;
  }
  const startLocal = toLocalMs(startMs, allDay);
  const startDay = dayNumberOf(startLocal);
  // 시작이 숫자가 아니거나 Date로 나타낼 수 없는 날이면 회차가 없다(검사를 거친 값이면 생기지 않는다).
  if (!(Math.abs(startDay) <= MAX_DAY)) return;
  const msOfDay = startLocal - startDay * DAY_MS;
  // 형식이 깨진 until은 예전처럼 회차 없음으로 본다.
  const untilDay = rec.until ? (parseDateString(rec.until) ?? -Infinity) : Infinity;
  const count = rec.count ?? Infinity;
  const fromDay = Math.max(startDay, dayNumberOf(toLocalMs(fromMs, allDay)));
  if (fromDay > MAX_DAY) return;
  let steps = 0;
  for (const { day, index } of iterateDayNumbers(rec, startDay, fromDay)) {
    if (!(day <= untilDay && day <= MAX_DAY) || index >= count) return;
    const start = fromLocalMs(day * DAY_MS + msOfDay, allDay);
    if (start >= fromMs) yield { start, index };
    if (++steps >= MAX_ITERATIONS) return;
  }
}

/**
 * 일정의 회차 시작(실제 ms)을 시간순으로 내놓는다 — until/count까지 적용, exdates는 적용하지 않는다.
 * [fromMs]를 주면 그보다 이른 회차는 세지 않고 건너뛴다. 반복이 없으면 시작 하나뿐.
 * event = { startMs, allDay, recurrence }
 */
export function* iterateOccurrenceStarts(event, fromMs = -Infinity) {
  for (const { start } of occurrencesFrom(event, fromMs)) yield start;
}

/**
 * [fromMs, toMs) 구간에 걸치는 회차들 `[{ start, end }]`(시간순). 회차가 구간과 겹치려면
 * start < toMs && end > fromMs. exdates(원래 회차 시작 ms 목록)에 있는 회차는 뺀다.
 * 한 시리즈에서 limit개(최대 MAX_OCCURRENCES_PER_EXPAND)까지만 내놓는다 — 시간순 앞의 것부터.
 * event = { startMs, endMs, allDay, recurrence, exdates }
 */
export function expandOccurrences(event, fromMs, toMs, { limit = MAX_OCCURRENCES_PER_EXPAND } = {}) {
  if (!Number.isFinite(fromMs) || !Number.isFinite(toMs) || !(toMs > fromMs) || !(limit > 0)) return [];
  const cap = Math.min(limit, MAX_OCCURRENCES_PER_EXPAND);
  const duration = event.endMs - event.startMs;
  // 3년보다 긴 구간을 한 번에 펼치지 않는다(호출부가 62일로 제한하지만 순수 함수도 스스로 막는다).
  const to = Math.min(toMs, fromMs + MAX_EXPAND_SPAN_MS);
  const result = [];
  let excluded = null;
  // 구간에 걸치려면 start > fromMs - duration이어야 한다 — 그보다 이른 회차는 세지 않고 건너뛴다.
  for (const start of iterateOccurrenceStarts(event, fromMs - duration)) {
    if (start >= to || result.length >= cap) break;
    if (start + duration <= fromMs) continue;
    excluded ??= new Set((event.exdates ?? []).map(Number));
    if (excluded.has(start)) continue;
    result.push({ start, end: start + duration });
  }
  return result;
}

/**
 * occurrenceStartMs가 이 일정의 몇 번째 회차인지(0부터, exdates 무시). 회차가 아니면 -1.
 * this/following 편집·삭제가 "정말 있는 회차인지" 검사하고 count를 나눌 때 쓴다.
 * 그 시각 이후의 첫 회차가 바로 그 시각이어야 회차다 — 앞의 회차는 세지 않고 산술로 건너뛴다.
 */
export function occurrenceIndex(event, occurrenceStartMs) {
  const { value, done } = occurrencesFrom(event, occurrenceStartMs).next();
  return !done && value.start === occurrenceStartMs ? value.index : -1;
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

// ── 조회 한 번의 회차 상한 ─────────────────────────────────────────────────

/**
 * 조회 한 번의 회차 상한([budget]개, calendars.js의 QUERY_OCCURRENCE_MAX)을 일정들에 나눠 펼친다. 누가 일정을 대량으로
 * 만들어도 남의 일정을 화면에서 밀어내지 못하게 하고, 펼치는 회차 수도 일정 수와 상관없이 상한 근처에서 멈추게 한다.
 *  1. 구간에 보일 회차가 없는 일정은 뺀다. 조회는 반복 일정을 구간과 상관없이 모두 후보로 읽어서 이미 끝난 반복, 이번
 *     구간에 날짜가 없는 매년 반복 같은 것이 섞인다. 이런 일정까지 차례를 받으면 그런 일정이 많은 사람은 앞 차례를 헛되이
 *     쓰고, 정작 구간에 보이는 일정이 대량 생성분에 밀려난다. 회차를 하나만 펼쳐 보는 검사라(구간 앞은 산술로 건너뛴다)
 *     일정마다 드는 비용이 작다.
 *  2. 남은 일정을 orderForOccurrenceBudget 순서대로 펼쳐 상한까지 채운다. 다 차면 나머지는 펼치지 않고, 마지막 일정은
 *     남은 자리만큼만 담는다.
 * expand(item, limit)는 그 항목의 구간 회차를 시간순으로 limit개까지 돌려준다(구간·종일 처리는 호출부 몫).
 * 돌려주는 값: [{ item, occurrences }] — 펼친 순서대로, 회차가 있는 항목만. 상한에 닿았는지는 회차 수의 합으로 안다.
 */
export function fillOccurrenceBudget(items, { viewerId, budget, expand }) {
  const inWindow = items.filter((item) => expand(item, 1).length > 0);
  const filled = [];
  let used = 0;
  for (const item of orderForOccurrenceBudget(inWindow, viewerId)) {
    const room = budget - used;
    if (!(room > 0)) break;
    const occurrences = expand(item, room);
    used += occurrences.length;
    filled.push({ item, occurrences });
  }
  return filled;
}

/**
 * fillOccurrenceBudget이 상한을 채울 일정 순서 — DB가 주는 순서와 상관없이 늘 같은 일정이 빠지도록 정한다. items에는 구간에
 * 회차가 있는 일정만 넘겨야 한다(fillOccurrenceBudget이 거른다). 회차가 없는 일정도 차례를 받으면 아래 2의 보장이 깨진다.
 *  1. 내가 만든 일정이 먼저 — 남이 무엇을 얼마나 만들어도 내 일정은 빠지지 않는다.
 *  2. 나머지는 만든 사람마다 한 개씩 돌아가며 넣는다. 한 사람이 수천 개를 만들어도 다른 사람들 일정은 차례마다 한 개씩
 *     함께 들어가므로, 상한에 닿으면 그 구간에 일정이 가장 많은 사람의 일정부터 빠진다. 참석자 초대는 팀원 누구나 할 수
 *     있어서(나를 초대한 일정을 대량으로 만들 수 있다) 초대받은 일정도 이 차례를 앞지르지 않는다.
 *     만든 사람의 계정 행이 지워진 일정(creatorId가 null — FK가 ON DELETE SET NULL)은 캘린더마다 한 사람으로 친다. 일정마다
 *     따로 치면 그런 일정이 아무리 많아도 모두 첫 차례에 들어가 다른 사람들 일정을 밀어내고, 전부 한 사람으로 치면 떠난
 *     사람들 일정이 다 합쳐 한 차례에 하나씩만 들어간다. 기본 캘린더는 주인만 일정을 만들 수 있어서 대개 "떠난 사람마다"가 된다.
 *  3. 한 사람의 일정끼리, 그리고 같은 차례끼리는 나를 초대한 일정 → 먼저 만든 일정(createdAt) → id 순.
 * items: [{ event: { id, creatorId, calendarId, createdAt }, isAttendee }] — 항목은 그대로 두고 새 배열에 순서대로 담아 준다.
 */
export function orderForOccurrenceBudget(items, viewerId) {
  const rows = items.map((item) => {
    const { id, creatorId, calendarId, createdAt } = item.event;
    return {
      item,
      mine: viewerId != null && creatorId === viewerId,
      invited: item.isAttendee === true,
      // 차례를 나눠 받는 단위(위 2) — 앞머리를 달리 붙여, 사람 id와 캘린더 id가 우연히 같아도 섞이지 않게 한다.
      owner: creatorId != null ? `user:${creatorId}` : `calendar:${calendarId ?? ''}`,
      created: createdMsOf(createdAt),
      id: String(id ?? ''),
    };
  });
  const within = (a, b) =>
    Number(b.invited) - Number(a.invited) || a.created - b.created || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  // 만든 사람마다 자기 일정에 차례(0, 1, 2, …)를 매긴다.
  rows.sort(within);
  const turns = new Map(); // 만든 사람(또는 떠난 사람들의 캘린더) → 지금까지 매긴 차례 수
  for (const row of rows) {
    row.turn = turns.get(row.owner) ?? 0;
    turns.set(row.owner, row.turn + 1);
  }
  rows.sort((a, b) => Number(b.mine) - Number(a.mine) || a.turn - b.turn || within(a, b));
  return rows.map((row) => row.item);
}

/** 일정을 만든 시각(ms) — Date·ms·ISO 문자열을 받는다. 알 수 없으면 가장 나중에 만든 것으로 본다(앞자리를 차지하지 않게). */
function createdMsOf(createdAt) {
  const ms = createdAt == null ? Number.NaN : new Date(createdAt).getTime();
  return Number.isFinite(ms) ? ms : Number.MAX_SAFE_INTEGER;
}
