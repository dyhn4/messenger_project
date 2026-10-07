// 반복 일정 펼침의 비용·상한 테스트 — `node --test test/calendarRecurrenceBounds.test.js` (DB·서버 없이 돈다).
// 펼침은 시리즈 첫 회차부터 세지 않고 구간 근처로 산술로 건너뛴다. 그 결과가 "날마다 규칙을 직접 대 보는" 느린 기준
// 구현과 같은지, 그리고 시리즈가 아무리 오래돼도 비용·회차 수가 묶이는지를 본다. 조회 한 번의 회차 상한에 닿았을 때
// 어느 일정이 빠지는지(fillOccurrenceBudget·orderForOccurrenceBudget)와, 조회 구간·회차가 놓일 수 있는 범위가 반복
// 종료일 상한(MAX_UNTIL)·앱의 달 단위 조회와 맞는지도 본다.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  DAY_MS,
  MAX_EXDATES,
  MAX_EXPAND_SPAN_MS,
  MAX_OCCURRENCES_PER_EXPAND,
  MAX_UNTIL,
  OCCURRENCE_MAX_MS,
  QUERY_MAX_MS,
  QUERY_MIN_MS,
  expandOccurrences,
  fillOccurrenceBudget,
  iterateOccurrenceStarts,
  occurrenceIndex,
  orderForOccurrenceBudget,
  parseRecurrence,
  splitRecurrenceAt,
} from '../src/calendarRecurrence.js';

const HOUR = 3600 * 1000;
const KST = 9 * HOUR;
/** KST 벽시계 'YYYY-MM-DD HH:mm' → 실제 epoch ms. */
const kst = (s) => Date.parse(s.replace(' ', 'T') + ':00+09:00');
/** 종일 표현: 'YYYY-MM-DD' → UTC 자정 ms. */
const day = (s) => Date.parse(`${s}T00:00:00Z`);
const kstStr = (ms) => new Date(ms + KST).toISOString().slice(0, 16).replace('T', ' ');
const dayStr = (ms) => new Date(ms).toISOString().slice(0, 10);
const daysBetween = (a, b) => Math.round((day(b) - day(a)) / DAY_MS);

function timed(startStr, endStr, recurrence, exdates = []) {
  return { startMs: kst(startStr), endMs: kst(endStr), allDay: false, recurrence, exdates };
}
function allDay(startStr, endStr, recurrence, exdates = []) {
  return { startMs: day(startStr), endMs: day(endStr), allDay: true, recurrence, exdates };
}

// ── 느린 기준 구현 ──────────────────────────────────────────────────────

/**
 * 시리즈 첫날부터 lastDay(로컬 일 번호)까지 날마다 "그날이 회차인가"만 보고 센 회차 [{ start, index }].
 * 계산 모듈의 건너뛰기와 독립적인 정의다: daily는 간격, weekly는 일요일 시작 주 번호와 요일, monthly는 같은 날짜가
 * 있는 달(없으면 건너뜀), yearly는 같은 월·일. index는 exdates와 무관하게 센 회차 번호, until·count를 적용한다.
 */
function bruteOccurrences(ev, lastDay) {
  const rec = ev.recurrence;
  if (!rec) return [{ start: ev.startMs, index: 0 }];
  const local = ev.allDay ? ev.startMs : ev.startMs + KST;
  const startDay = Math.floor(local / DAY_MS);
  const toStart = (d) => d * DAY_MS + (local - startDay * DAY_MS) - (ev.allDay ? 0 : KST);
  const s = new Date(startDay * DAY_MS);
  const weekStart = startDay - s.getUTCDay();
  const weekdays = rec.byWeekday ?? [s.getUTCDay()];
  const untilDay = rec.until ? day(rec.until) / DAY_MS : Infinity;
  const k = rec.interval;
  const out = [];
  for (let d = startDay; d <= Math.min(lastDay, untilDay); d++) {
    if (rec.count != null && out.length >= rec.count) break;
    const t = new Date(d * DAY_MS);
    const months = (t.getUTCFullYear() - s.getUTCFullYear()) * 12 + t.getUTCMonth() - s.getUTCMonth();
    let hit;
    switch (rec.freq) {
      case 'daily':
        hit = (d - startDay) % k === 0;
        break;
      case 'weekly':
        hit = weekdays.includes(t.getUTCDay()) && Math.floor((d - weekStart) / 7) % k === 0;
        break;
      case 'monthly':
        hit = t.getUTCDate() === s.getUTCDate() && months % k === 0;
        break;
      case 'yearly':
        hit = t.getUTCMonth() === s.getUTCMonth() && t.getUTCDate() === s.getUTCDate() && months % (12 * k) === 0;
        break;
    }
    if (hit) out.push({ start: toStart(d), index: out.length });
  }
  return out;
}

/**
 * 매월·매년 종일 반복의 회차 시작(UTC 자정 ms) — 달을 하나씩 넘기며 "간격에 맞는 달이고 그 날짜가 있는가"만 본다.
 * 날마다 세기엔 너무 먼(수백 년) 구간의 기준값으로 쓴다.
 */
function monthStepOccurrences(startStr, freq, interval, lastYear) {
  const s = new Date(day(startStr));
  const step = freq === 'yearly' ? 12 * interval : interval;
  const out = [];
  for (let t = 0; ; t += step) {
    const y = s.getUTCFullYear() + Math.floor((s.getUTCMonth() + t) / 12);
    const m = (s.getUTCMonth() + t) % 12;
    if (y > lastYear) return out;
    const ms = Date.UTC(y, m, s.getUTCDate());
    if (new Date(ms).getUTCDate() === s.getUTCDate()) out.push(ms);
  }
}

/** bruteOccurrences로 expandOccurrences와 같은 규칙(겹침·exdates·3년·회차 수 상한)의 답을 만든다. */
function bruteExpand(ev, all, fromMs, toMs) {
  const duration = ev.endMs - ev.startMs;
  const to = Math.min(toMs, fromMs + MAX_EXPAND_SPAN_MS);
  const excluded = new Set(ev.exdates);
  return all
    .filter((o) => o.start < to && o.start + duration > fromMs && !excluded.has(o.start))
    .slice(0, MAX_OCCURRENCES_PER_EXPAND)
    .map((o) => ({ start: o.start, end: o.start + duration }));
}

/** 재현 가능한 의사 난수(mulberry32). */
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** 무작위 시리즈 — 달 끝(28~31일)·2월 29일·한국 새벽/밤 시각·여러 간격·종료 조건을 골고루 섞는다. */
function randomSeries(rand) {
  const int = (lo, hi) => lo + Math.floor(rand() * (hi - lo + 1));
  const pick = (list) => list[Math.floor(rand() * list.length)];
  const isAllDay = rand() < 0.4;
  const y = int(2000, 2030);
  const m = int(0, 11);
  const dim = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
  const d = rand() < 0.5 ? int(dim - 3, dim) : int(1, dim);
  const startMs = isAllDay ? Date.UTC(y, m, d) : Date.UTC(y, m, d, pick([0, 1, 9, 14, 23]), pick([0, 30])) - KST;
  const longDays = rand() < 0.15 ? int(1, 10) : 0; // 여러 날에 걸치는 회차(앞 회차가 구간에 걸쳐 들어오는 경우)
  const endMs = isAllDay ? startMs + (longDays + 1) * DAY_MS : startMs + int(1, 3) * HOUR + longDays * DAY_MS;
  const freq = pick(['daily', 'weekly', 'monthly', 'yearly']);
  const recurrence = { freq, interval: pick([1, 1, 1, 2, 3, 4, 6, 7, 12, 13, 25, 99]) };
  if (freq === 'weekly') {
    recurrence.byWeekday = [...new Set(Array.from({ length: int(1, 4) }, () => int(0, 6)))].sort((a, b) => a - b);
  }
  const end = rand();
  if (end < 0.3) recurrence.count = int(1, 500);
  else if (end < 0.6) recurrence.until = dayStr(startMs + (isAllDay ? 0 : KST) + int(0, 365 * 30) * DAY_MS);
  return { startMs, endMs, allDay: isAllDay, recurrence, exdates: [] };
}

// ── 기준 구현과 같은 답 ─────────────────────────────────────────────────

test('건너뛰는 펼침 = 날마다 세는 기준 구현(무작위 시리즈·구간, exdates·count·until 포함)', () => {
  const rand = rng(20261007);
  let compared = 0;
  let nonEmpty = 0;
  for (let c = 0; c < 160; c++) {
    const ev = randomSeries(rand);
    const windows = [];
    for (let w = 0; w < 5; w++) {
      const offsetDays = [-400, -1, 0, 1, 30, 365, 1500, 6000, 12000][Math.floor(rand() * 9)] + Math.floor(rand() * 60) - 30;
      const from = ev.startMs + offsetDays * DAY_MS + Math.floor(rand() * 24) * HOUR;
      const span = [HOUR, DAY_MS, 7 * DAY_MS, 31 * DAY_MS, 62 * DAY_MS, 400 * DAY_MS][Math.floor(rand() * 6)];
      windows.push([from, from + span]);
    }
    const lastLocal = Math.max(...windows.map(([, to]) => to)) + KST;
    const all = bruteOccurrences(ev, Math.floor(lastLocal / DAY_MS) + 1);
    // 실제 회차 일부를 "이 일정만"으로 뺀 것처럼 exdates에 넣는다(count에는 계속 센다).
    ev.exdates = all.filter(() => rand() < 0.1).map((o) => o.start);

    for (const [from, to] of windows) {
      const want = bruteExpand(ev, all, from, to);
      assert.deepEqual(expandOccurrences(ev, from, to), want, `expand ${JSON.stringify(ev.recurrence)} @${dayStr(from)}`);
      compared++;
      if (want.length > 0) nonEmpty++;
    }
    if (all.length === 0) continue; // 첫 회차가 모든 구간보다 뒤인 시리즈(격주 요일 등)
    // 회차 번호: 실제 회차는 그 번호, 회차가 아닌 시각은 -1.
    const byStart = new Map(all.map((o) => [o.start, o.index]));
    const probes = [all[0], all[all.length - 1], ...Array.from({ length: 6 }, () => all[Math.floor(rand() * all.length)])];
    for (const o of probes) {
      assert.equal(occurrenceIndex(ev, o.start), o.index, `index ${JSON.stringify(ev.recurrence)} @${dayStr(o.start)}`);
      for (const p of [o.start + 60000, o.start - DAY_MS]) {
        if (p > all[all.length - 1].start) continue; // 기준 목록 밖은 모른다
        assert.equal(occurrenceIndex(ev, p), byStart.get(p) ?? -1);
      }
    }
  }
  // 대부분의 구간이 비어서 통과하는 일이 없도록, 회차가 실제로 나온 비교가 충분히 있었는지 본다.
  assert.ok(nonEmpty > compared / 4, `회차가 나온 비교 ${nonEmpty}/${compared}`);
});

test('달 끝(29~31일)·2월 29일 반복의 회차 번호도 하나씩 센 값과 같다(모든 간격, 400년 윤년 주기 포함)', () => {
  for (const start of ['2000-01-29', '2000-01-30', '2000-01-31', '2000-02-29', '2023-03-31', '2024-08-31', '2024-02-29']) {
    for (const freq of ['monthly', 'yearly']) {
      for (let interval = 1; interval <= 99; interval++) {
        const ev = allDay(start, dayStr(day(start) + DAY_MS), { freq, interval });
        // 2100·2200·2300년(평년)과 2400년(윤년)을 지나도록 2400년까지 본다.
        const all = monthStepOccurrences(start, freq, interval, 2400);
        for (let i = 0; i < all.length; i += freq === 'monthly' ? 13 : 1) {
          assert.equal(occurrenceIndex(ev, all[i]), i, `${freq} ${start} 간격 ${interval} #${i}`);
        }
        const last = all[all.length - 1];
        assert.deepEqual(expandOccurrences(ev, last - 40 * DAY_MS, last + DAY_MS).map((o) => o.start).slice(-1), [last]);
      }
    }
  }
});

// ── 오래된 시리즈·먼 구간 ───────────────────────────────────────────────

test('오래된 매일 반복도 먼 미래 구간의 회차와 번호가 정확하다(시리즈 처음부터 세지 않는다)', () => {
  const ev = timed('2000-01-01 09:00', '2000-01-01 10:00', { freq: 'daily', interval: 1 });
  // 예전 구현은 회차를 처음부터 20만 개까지만 세서 550년쯤 뒤부터는 빈 목록을 냈다.
  const got = expandOccurrences(ev, kst('2600-03-01 00:00'), kst('2600-03-08 00:00'));
  assert.deepEqual(got.map((o) => kstStr(o.start)), [
    '2600-03-01 09:00',
    '2600-03-02 09:00',
    '2600-03-03 09:00',
    '2600-03-04 09:00',
    '2600-03-05 09:00',
    '2600-03-06 09:00',
    '2600-03-07 09:00',
  ]);
  assert.equal(occurrenceIndex(ev, got[0].start), daysBetween('2000-01-01', '2600-03-01'));
  assert.equal(occurrenceIndex(ev, got[0].start + 60000), -1);
});

test('먼 구간에서도 count·until·exdates 규칙을 지킨다', () => {
  // count 500: 마지막 회차(번호 499)까지만, 그 뒤 구간은 비어 있다.
  const counted = allDay('2000-01-01', '2000-01-02', { freq: 'daily', interval: 2, count: 500 });
  const last = day('2000-01-01') + 499 * 2 * DAY_MS;
  assert.deepEqual(expandOccurrences(counted, last - 3 * DAY_MS, last + 30 * DAY_MS).map((o) => dayStr(o.start)), [
    dayStr(last - 2 * DAY_MS),
    dayStr(last),
  ]);
  assert.equal(occurrenceIndex(counted, last), 499);
  assert.equal(occurrenceIndex(counted, last + 2 * DAY_MS), -1);
  assert.deepEqual(expandOccurrences(counted, day('2090-01-01'), day('2090-03-01')), []);

  // 매주 월·수·금 격주, until 2090-01-31: 그날까지만.
  const weekly = timed('2000-01-03 08:30', '2000-01-03 09:00', { freq: 'weekly', interval: 2, byWeekday: [1, 3, 5], until: '2090-01-31' });
  const tail = expandOccurrences(weekly, kst('2090-01-15 00:00'), kst('2090-03-01 00:00')).map((o) => kstStr(o.start));
  assert.ok(tail.length > 0 && tail.every((s) => s.slice(0, 10) <= '2090-01-31'), tail.join(','));

  // 매월 31일, 먼 회차를 exdates로 빼면 그 회차만 빠지고 번호는 그대로다.
  const monthly = allDay('2000-01-31', '2000-02-01', { freq: 'monthly', interval: 1 }, [day('2099-12-31')]);
  const dec = expandOccurrences(monthly, day('2099-10-01'), day('2100-02-01')).map((o) => dayStr(o.start));
  assert.deepEqual(dec, ['2099-10-31', '2100-01-31']);
  // 2000-01 ~ 2099-11의 31일 있는 달은 100년 × 7 = 700개에서 2099-12 하나를 뺀 699개 → 2099-12-31은 699번.
  assert.equal(occurrenceIndex(monthly, day('2099-12-31')), 699);
});

test('비용이 시리즈 나이와 무관하다: 2000년부터의 반복 수천 개를 2299년 구간으로 펼쳐도 금방 끝난다', () => {
  const series = [
    timed('2000-01-01 09:00', '2000-01-01 10:00', { freq: 'daily', interval: 1 }),
    timed('2000-01-02 09:00', '2000-01-02 10:00', { freq: 'weekly', interval: 1, byWeekday: [0, 1, 2, 3, 4, 5, 6] }),
    allDay('2000-01-31', '2000-02-01', { freq: 'monthly', interval: 1 }),
    allDay('2000-01-29', '2000-01-30', { freq: 'monthly', interval: 7 }),
    allDay('2000-02-29', '2000-03-01', { freq: 'yearly', interval: 1 }),
  ];
  const from = kst('2299-11-01 00:00');
  const to = from + 62 * DAY_MS;
  // 답은 날마다 세는 기준 구현으로 한 번만 만든다(300년치라 시리즈당 한 번이면 충분하다).
  const want = series.map((ev) => bruteExpand(ev, bruteOccurrences(ev, Math.floor((to + KST) / DAY_MS) + 1), from, to));
  assert.deepEqual(want.map((w) => w.length), [62, 62, 2, 1, 0]); // 31일은 10-31(구간 시작에 걸침)·12-31, 29일은 7개월 간격
  const started = performance.now();
  for (let i = 0; i < 4000; i++) {
    series.forEach((ev, k) => {
      const got = expandOccurrences(ev, from, to);
      if (i === 0) assert.deepEqual(got, want[k]);
    });
  }
  const elapsed = performance.now() - started;
  // 예전 구현은 시리즈마다 300년치 회차를 처음부터 세느라 이 양이면 수십 초가 걸렸다. 넉넉하게 잡은 상한이다.
  assert.ok(elapsed < 3000, `2만 번 펼치는 데 ${elapsed.toFixed(0)}ms`);
});

// ── 상한·이상한 입력 ────────────────────────────────────────────────────

test('한 시리즈가 한 번에 내는 회차 수에는 상한이 있다(앞의 것부터, limit으로 더 낮출 수 있다)', () => {
  const ev = allDay('2026-01-01', '2026-01-02', { freq: 'daily', interval: 1 });
  const capped = expandOccurrences(ev, day('2026-01-01'), day('2029-01-01')); // 3년 = 1096회
  assert.equal(capped.length, MAX_OCCURRENCES_PER_EXPAND);
  assert.equal(dayStr(capped[0].start), '2026-01-01');
  assert.equal(capped[capped.length - 1].start, day('2026-01-01') + (MAX_OCCURRENCES_PER_EXPAND - 1) * DAY_MS);
  assert.deepEqual(
    expandOccurrences(ev, day('2026-03-01'), day('2026-04-01'), { limit: 3 }).map((o) => dayStr(o.start)),
    ['2026-03-01', '2026-03-02', '2026-03-03'],
  );
  assert.equal(expandOccurrences(ev, day('2026-01-01'), day('2029-01-01'), { limit: 1e9 }).length, MAX_OCCURRENCES_PER_EXPAND);
  assert.deepEqual(expandOccurrences(ev, day('2026-03-01'), day('2026-04-01'), { limit: 0 }), []);
  assert.deepEqual(expandOccurrences(ev, day('2026-03-01'), day('2026-04-01'), { limit: Number.NaN }), []);
  // 여러 날짜에 걸치는 매일 반복(길이 366일)도 62일 구간에 걸치는 회차(2026-06-01 ~ 2027-08-01 시작)만큼만 — 상한 안이다.
  const long = allDay('2026-01-01', '2027-01-02', { freq: 'daily', interval: 1 });
  const overlapping = expandOccurrences(long, day('2027-06-01'), day('2027-08-02'));
  assert.equal(overlapping.length, daysBetween('2026-06-01', '2027-08-01') + 1);
  assert.ok(overlapping.length < MAX_OCCURRENCES_PER_EXPAND);
});

test('이상한 구간·저장값이어도 멈추지 않고 빈 목록이나 안전한 값을 낸다', () => {
  const ev = timed('2026-05-01 09:00', '2026-05-01 10:00', { freq: 'daily', interval: 1 });
  const from = kst('2026-05-01 00:00');
  assert.deepEqual(expandOccurrences(ev, Number.NaN, from), []);
  assert.deepEqual(expandOccurrences(ev, from, Number.NaN), []);
  assert.deepEqual(expandOccurrences(ev, from, Infinity), []);
  assert.deepEqual(expandOccurrences(ev, -Infinity, from), []);
  assert.deepEqual(expandOccurrences(ev, from, from), []);
  assert.deepEqual(expandOccurrences(ev, from + DAY_MS, from), []);
  // Date가 나타낼 수 있는 끝(±8.64e15ms) 근처나 그 너머여도 던지지 않는다.
  assert.doesNotThrow(() => expandOccurrences(ev, 8.6e15, 8.6e15 + 62 * DAY_MS));
  assert.deepEqual(expandOccurrences(ev, 9e15, 9e15 + DAY_MS), []);
  assert.equal(occurrenceIndex(ev, Number.NaN), -1);
  assert.equal(occurrenceIndex(ev, Infinity), -1);
  assert.equal(occurrenceIndex(ev, -Infinity), -1);

  // DB에 검사 전 값이 남아 있어도 0으로 나누거나 끝없이 돌지 않는다.
  const week = (recurrence) => expandOccurrences({ ...ev, recurrence }, from, from + 7 * DAY_MS).length;
  assert.equal(week({ freq: 'daily', interval: 0 }), 7); // 간격 1로 본다
  assert.equal(week({ freq: 'daily', interval: -3 }), 7);
  assert.equal(week({ freq: 'daily', interval: 1.5 }), 7);
  assert.equal(week({ freq: 'monthly', interval: 0 }), 1);
  assert.equal(week({ freq: 'weekly', interval: 1, byWeekday: ['x', 9, null] }), 1); // 시작 요일(금) 하나
  assert.equal(week({ freq: 'weekly', interval: 1, byWeekday: [5, 5, 1, 1] }), 2); // 중복은 한 번만
  assert.equal(week({ freq: 'daily', interval: 1, until: 'garbage' }), 0); // 깨진 종료일은 예전처럼 회차 없음
  assert.equal(week({ freq: 'hourly', interval: 1 }), 0);
  assert.deepEqual(expandOccurrences({ ...ev, startMs: Number.NaN }, from, from + DAY_MS), []);

  // 끝없는 시리즈를 처음부터 끝까지 돌려도 안전 상한에서 멈춘다.
  let n = 0;
  for (const _ of iterateOccurrenceStarts(ev)) n++;
  assert.ok(n > 0 && n <= 200000);
});

test('parseRecurrence: 반복 종료일은 MAX_UNTIL까지, 간격·횟수는 정해진 범위만', () => {
  const start = { startMs: kst('2026-05-06 10:00'), allDay: false };
  assert.equal(MAX_UNTIL, '2299-12-31');
  assert.equal(parseRecurrence({ freq: 'daily', until: MAX_UNTIL }, start).value.until, MAX_UNTIL);
  for (const until of ['2300-01-01', '9999-12-31']) {
    assert.ok(parseRecurrence({ freq: 'daily', until }, start).error, until);
  }
  for (const bad of [{ interval: 0 }, { interval: -1 }, { interval: 100 }, { interval: '2' }, { count: 0 }, { count: 501 }, { count: 2.5 }]) {
    assert.ok(parseRecurrence({ freq: 'daily', ...bad }, start).error, JSON.stringify(bad));
  }
  assert.ok(Number.isInteger(MAX_EXDATES) && MAX_EXDATES >= 500); // count 상한(500)짜리 시리즈는 회차를 다 지울 수 있어야 한다
});

// ── 조회 한 번의 회차 상한을 채우는 순서 ────────────────────────────────

/**
 * 조회 항목 { event, isAttendee } — event는 펼침에 쓰는 값과 순서를 정하는 값(id·만든 사람·만든 시각, 만든 사람이 없으면
 * [ev]에 담아 준 캘린더 id)을 함께 담는다.
 */
function item(id, creatorId, createdAt, ev, isAttendee = false) {
  return { event: { ...ev, id, creatorId, createdAt }, isAttendee };
}

/** calendars.js의 일정 조회처럼 fillOccurrenceBudget으로 [budget]개까지 펼친다 — 회차가 들어간 일정 id와 쓴 회차 수. */
function fillBudget(items, viewerId, budget, from, to) {
  const filled = fillOccurrenceBudget(items, {
    viewerId,
    budget,
    expand: ({ event }, limit) => expandOccurrences(event, from, to, { limit }),
  });
  return {
    kept: filled.map(({ item }) => item.event.id),
    used: filled.reduce((sum, { occurrences }) => sum + occurrences.length, 0),
  };
}

/**
 * 예전 조회 방식 — 볼 수 있는 일정 전부(구간에 회차가 없는 것까지)에 차례를 매겨 그 순서대로 펼쳤다. 회귀 테스트가 고친
 * 문제를 실제로 재현하는 상황인지 확인하는 데만 쓴다.
 */
function fillBudgetWithoutFilter(items, viewerId, budget, from, to) {
  const kept = [];
  let used = 0;
  for (const { event } of orderForOccurrenceBudget(items, viewerId)) {
    if (used >= budget) break;
    const occs = expandOccurrences(event, from, to, { limit: budget - used });
    used += occs.length;
    if (occs.length > 0) kept.push(event.id);
  }
  return { kept, used };
}

const pad3 = (i) => String(i).padStart(3, '0');
/** 2026-01-01부터 끝없이 매일 반복하는 시간 일정 — 대량 생성분. */
const dailySpam = () => timed('2026-01-01 09:00', '2026-01-01 10:00', { freq: 'daily', interval: 1 });

/** 재현 가능한 섞기(Fisher–Yates). */
function shuffled(list, rand) {
  const out = [...list];
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

test('회차 상한에 닿아도 내 일정과 다른 사람들 일정은 대량으로 만든 일정에 밀려나지 않는다', () => {
  const from = kst('2026-03-01 00:00');
  const to = kst('2026-04-01 00:00');
  const early = Date.parse('2026-01-01T00:00:00Z');
  const later = Date.parse('2026-02-15T00:00:00Z');
  // 한 사람이 먼저(가장 이른 createdAt) 매일 반복 300개를 만들고, 그 절반에는 나를 참석자로 넣었다 — 초대는 팀원 누구나 할 수 있다.
  const spam = Array.from({ length: 300 }, (_, i) =>
    item(`spam-${String(i).padStart(3, '0')}`, 'spammer', new Date(early + i), timed('2026-01-01 09:00', '2026-01-01 10:00', { freq: 'daily', interval: 1 }), i % 2 === 0),
  );
  const real = [
    item('me-once', 'me', new Date(later), timed('2026-03-10 10:00', '2026-03-10 11:00', null)),
    item('me-weekly', 'me', new Date(later + 1), timed('2026-02-02 09:00', '2026-02-02 09:30', { freq: 'weekly', interval: 1, byWeekday: [1] })),
    item('me-daily', 'me', new Date(later + 2), timed('2026-01-05 08:00', '2026-01-05 08:15', { freq: 'daily', interval: 1 })),
    item('kim-weekly', 'kim', new Date(later + 3), timed('2026-01-02 16:00', '2026-01-02 17:00', { freq: 'weekly', interval: 1, byWeekday: [5] })),
    item('kim-once', 'kim', new Date(later + 4), timed('2026-03-20 14:00', '2026-03-20 15:00', null)),
    item('lee-invite', 'lee', new Date(later + 5), timed('2026-03-05 10:00', '2026-03-05 11:00', null), true),
  ];
  const budget = 600; // QUERY_OCCURRENCE_MAX(5000) 대신 작은 상한으로 같은 규칙을 본다
  const rand = rng(7);
  let first = null;
  // DB가 어떤 순서로 주든(대량 생성분이 앞이든 뒤든 섞였든) 빠지는 일정이 같다.
  for (const input of [[...spam, ...real], [...real, ...spam], shuffled([...spam, ...real], rand), shuffled([...real, ...spam], rand)]) {
    const { kept, used } = fillBudget(input, 'me', budget, from, to);
    assert.equal(used, budget);
    for (const { event } of real) assert.ok(kept.includes(event.id), `${event.id}가 빠졌다`);
    const spamKept = kept.filter((id) => id.startsWith('spam-'));
    assert.ok(spamKept.length > 0 && spamKept.length < 20, `대량 생성분 ${spamKept.length}개`);
    first ??= kept;
    assert.deepEqual(kept, first);
  }
});

test('회차 상한을 채우는 순서: 내 일정 → 만든 사람마다 한 개씩 돌아가며, 같은 차례는 초대받은 것 → 먼저 만든 것 → id', () => {
  const ev = timed('2026-03-02 10:00', '2026-03-02 11:00', null);
  const items = [
    item('a', 'me', new Date(5), ev),
    item('b', 'me', 1, ev),
    item('c', 'x', new Date(2).toISOString(), ev, true),
    item('d', 'x', 1, ev),
    item('e', 'y', 3, ev),
    item('f', 'y', 3, ev),
    item('g', 'x', 0, ev),
    item('h', null, 1, ev),
    item('i', 'z', undefined, ev), // 만든 시각을 모르면 가장 나중에 만든 것으로 본다
    item('j', 'z', 0, ev),
  ];
  const before = items.map((it) => it.event.id);
  const order = (list, viewer) => orderForOccurrenceBudget(list, viewer).map((it) => it.event.id);
  // 사람마다 차례: x = c(초대) g d, y = e f, z = j i, 만든 사람 없음 = h.
  // 내 것(b, a) → 0번째 차례(초대받은 c → 먼저 만든 j, h, e) → 1번째(g, f, i) → 2번째(d).
  assert.deepEqual(order(items, 'me'), ['b', 'a', 'c', 'j', 'h', 'e', 'g', 'f', 'i', 'd']);
  assert.deepEqual(items.map((it) => it.event.id), before); // 받은 배열은 그대로 둔다
  assert.equal(orderForOccurrenceBudget(items, 'me')[0], items[1]); // 항목 자체를 돌려준다(복사하지 않는다)
  const rand = rng(11);
  for (let k = 0; k < 20; k++) assert.deepEqual(order(shuffled(items, rand), 'me'), order(items, 'me'));
  // 보는 사람이 없으면(null) "내 일정" 묶음도 없다 — me도 다른 사람처럼 차례를 돈다.
  assert.deepEqual(order(items, null), ['c', 'j', 'b', 'h', 'e', 'g', 'f', 'a', 'i', 'd']);
  assert.deepEqual(orderForOccurrenceBudget([], 'me'), []);
});

test('구간에 회차가 없는 일정(끝난 반복)은 차례를 받지 않는다 — 끝난 반복이 많은 사람의 이번 달 일정도 대량 생성분에 밀려나지 않는다', () => {
  const from = kst('2026-03-01 00:00');
  const to = kst('2026-04-01 00:00');
  const t0 = Date.parse('2025-01-01T00:00:00Z');
  // kim: 2025년에 끝난 매주 반복 200개를 먼저 만들었고, 이번 달(3월)에는 일정이 하나 있다.
  const ended = Array.from({ length: 200 }, (_, i) =>
    item(
      `kim-ended-${pad3(i)}`,
      'kim',
      new Date(t0 + i),
      timed('2025-01-06 10:00', '2025-01-06 11:00', { freq: 'weekly', interval: 1, byWeekday: [1], until: '2025-12-31' }),
    ),
  );
  const kimOnce = item('kim-once', 'kim', new Date(t0 + 1000), timed('2026-03-20 14:00', '2026-03-20 15:00', null));
  // spammer: 끝없는 매일 반복 300개 — 3월에만 9300회라 상한을 넘는다.
  const spam = Array.from({ length: 300 }, (_, i) => item(`spam-${pad3(i)}`, 'spammer', new Date(t0 + 2000 + i), dailySpam()));
  const budget = 5000; // calendars.js의 QUERY_OCCURRENCE_MAX와 같은 값
  const input = [...ended, kimOnce, ...spam];

  // 예전 방식에서는 끝난 반복 200개가 kim의 0~199번째 차례를 쓰고 kim-once는 200번째 차례였는데, 그 전에 대량 생성분
  // (차례마다 31회)이 상한을 다 채워 kim-once가 빠졌다 — 이 상황이 그 문제를 실제로 재현하는지 먼저 확인한다.
  assert.ok(!fillBudgetWithoutFilter(input, 'me', budget, from, to).kept.includes('kim-once'));

  const rand = rng(3);
  for (const list of [input, [...input].reverse(), shuffled(input, rand)]) {
    const { kept, used } = fillBudget(list, 'me', budget, from, to);
    assert.equal(used, budget);
    // kim-once는 kim의 첫 차례라 0번째 차례(kim-once, spam-000)에 바로 들어간다.
    assert.ok(kept.indexOf('kim-once') >= 0 && kept.indexOf('kim-once') < 2, `kim-once 자리 ${kept.indexOf('kim-once')}`);
    // 끝난 반복은 회차가 없어 결과에도 없다.
    assert.ok(!kept.some((id) => id.startsWith('kim-ended-')));
  }
});

test('끝난 반복 말고도 구간에 회차가 없는 일정(다른 달의 매년 반복, 구간의 회차를 모두 지운 반복, 구간 뒤의 일정)은 차례를 받지 않는다', () => {
  const from = kst('2026-03-01 00:00');
  const to = kst('2026-04-01 00:00');
  const weekly = timed('2026-03-02 10:00', '2026-03-02 11:00', { freq: 'weekly', interval: 1, byWeekday: [1], count: 5 });
  const cleared = { ...weekly, exdates: expandOccurrences(weekly, from, to).map((o) => o.start) };
  assert.equal(cleared.exdates.length, 5);
  const lee = [
    ...Array.from({ length: 50 }, (_, i) => item(`lee-yearly-${pad3(i)}`, 'lee', i, allDay('2020-07-01', '2020-07-02', { freq: 'yearly', interval: 1 }))),
    item('lee-cleared', 'lee', 100, cleared),
    item('lee-later', 'lee', 101, timed('2026-04-10 10:00', '2026-04-10 11:00', null)),
    item('lee-once', 'lee', 200, timed('2026-03-05 10:00', '2026-03-05 11:00', null)),
  ];
  const spam = Array.from({ length: 300 }, (_, i) => item(`spam-${pad3(i)}`, 'spammer', i, dailySpam()));
  const { kept, used } = fillBudget([...lee, ...spam], 'me', 600, from, to);
  assert.equal(used, 600);
  assert.deepEqual(kept.filter((id) => id.startsWith('lee-')), ['lee-once']);
  assert.ok(kept.indexOf('lee-once') < 2, `lee-once 자리 ${kept.indexOf('lee-once')}`);
  // 상한이 넉넉하면 회차가 있는 일정은 모두 들어간다(회차를 덜 담지 않는다).
  const roomy = fillOccurrenceBudget([...lee, ...spam], {
    viewerId: 'me',
    budget: 1e6,
    expand: ({ event }, limit) => expandOccurrences(event, from, to, { limit }),
  });
  assert.equal(roomy.length, 301);
  assert.equal(roomy.reduce((sum, { occurrences }) => sum + occurrences.length, 0), 300 * 31 + 1);
  // 상한이 0이거나 숫자가 아니면 아무것도 펼치지 않는다.
  for (const budget of [0, -1, Number.NaN]) {
    assert.deepEqual(fillOccurrenceBudget(lee, { viewerId: 'me', budget, expand: ({ event }, limit) => expandOccurrences(event, from, to, { limit }) }), []);
  }
});

test('만든 사람의 계정이 지워진 일정(creatorId null)은 캘린더마다 한 사람처럼 차례를 받는다', () => {
  const ev = timed('2026-03-02 10:00', '2026-03-02 11:00', null);
  const order = (list) => orderForOccurrenceBudget(list, 'me').map((it) => it.event.id);
  const items = [
    item('t1', null, 1, { ...ev, calendarId: 'team-cal' }),
    item('t2', null, 2, { ...ev, calendarId: 'team-cal' }),
    item('t3', null, 3, { ...ev, calendarId: 'team-cal' }),
    item('p1', null, 4, { ...ev, calendarId: 'left-personal' }),
    item('p2', null, 5, { ...ev, calendarId: 'left-personal' }),
    item('k1', 'kim', 6, { ...ev, calendarId: 'team-cal' }),
    item('k2', 'kim', 7, { ...ev, calendarId: 'team-cal' }),
    item('x1', 'team-cal', 8, ev), // 사람 id가 캘린더 id와 우연히 같아도 다른 몫이다
  ];
  // 차례: 캘린더 team-cal의 떠난 사람들 = t1 t2 t3, left-personal = p1 p2, kim = k1 k2, 사람 'team-cal' = x1.
  assert.deepEqual(order(items), ['t1', 'p1', 'k1', 'x1', 't2', 'p2', 'k2', 't3']);

  // 떠난 사람이 한 캘린더에 남긴 대량 일정도 한 사람 몫의 차례만 받는다. 일정마다 따로 차례를 주면 모두 0번째 차례라,
  // 먼저 만든 그 일정들이 상한을 다 채워 다른 사람의 일정을 밀어냈을 것이다.
  const from = kst('2026-03-01 00:00');
  const to = kst('2026-04-01 00:00');
  const leftovers = Array.from({ length: 300 }, (_, i) => item(`left-${pad3(i)}`, null, i, { ...dailySpam(), calendarId: 'team-cal' }));
  const kimOnce = item('kim-once', 'kim', 1000, { ...timed('2026-03-20 14:00', '2026-03-20 15:00', null), calendarId: 'team-cal' });
  const { kept, used } = fillBudget([...leftovers, kimOnce], 'me', 600, from, to);
  assert.equal(used, 600);
  assert.ok(kept.includes('kim-once'));
});

// ── 조회 구간·회차가 놓일 수 있는 범위 ──────────────────────────────────

/**
 * 앱이 [year]년 [month](0부터)월을 달력 격자로 볼 때 보내는 일정 조회 구간들 — 기기 시간대가 UTC+[offsetMs]일 때의 ms.
 * calendar_layout.dart(monthGridRange: 일요일 시작 주로, 그 달 첫날이 든 주 ~ 마지막 날이 든 주)와
 * calendar_controller.dart(_neededChunks·_startChunk: 격자에 걸친 달마다 [1일 - 1일, 다음 달 1일 + 1일), 기기 시간대 자정)를
 * 그대로 옮겼다. 날짜는 Date.UTC로 "현지 날짜"를 나타내고 마지막에 시간대만큼 뺀다. 주·일·목록 보기의 구간은 모두
 * 격자 안이라 따로 보지 않는다.
 */
function appMonthQueries(year, month, offsetMs) {
  const first = Date.UTC(year, month, 1);
  const last = Date.UTC(year, month + 1, 0);
  const gridFrom = first - new Date(first).getUTCDay() * DAY_MS;
  const gridTo = last + (7 - new Date(last).getUTCDay()) * DAY_MS; // 마지막 주 토요일 다음 날(배타)
  const queries = [];
  const g = new Date(gridFrom);
  for (let key = Date.UTC(g.getUTCFullYear(), g.getUTCMonth(), 1); key < gridTo; ) {
    const k = new Date(key);
    const [y, m] = [k.getUTCFullYear(), k.getUTCMonth()];
    queries.push({ from: Date.UTC(y, m, 0) - offsetMs, to: Date.UTC(y, m + 1, 2) - offsetMs });
    key = Date.UTC(y, m + 1, 1);
  }
  return queries;
}

test('조회 구간 범위는 앱의 달 단위 조회와 맞는다: 1900년 1월 ~ 2299년 12월의 어느 달을 어느 시간대에서 봐도 범위 안이다', () => {
  // 리뷰에서 400이 났던 경우: 2299년 12월 격자는 11월·12월과 2300년 1월 덩어리(현지 2300-02-02까지)를 받는다.
  const seoul = appMonthQueries(2299, 11, KST).map(({ from, to }) => [dayStr(from + KST), dayStr(to + KST)]);
  assert.deepEqual(seoul, [
    ['2299-10-31', '2299-12-02'],
    ['2299-11-30', '2300-01-02'],
    ['2299-12-31', '2300-02-02'],
  ]);
  let checked = 0;
  for (const offsetHours of [-12, -9.5, -3, 0, 5.75, 9, 12.75, 14]) {
    for (let year = 1900; year <= 2299; year++) {
      for (let month = 0; month < 12; month++) {
        for (const { from, to } of appMonthQueries(year, month, offsetHours * HOUR)) {
          const what = `${year}-${month + 1} UTC${offsetHours >= 0 ? '+' : ''}${offsetHours}: ${new Date(from).toISOString()} ~ ${new Date(to).toISOString()}`;
          assert.ok(from >= QUERY_MIN_MS && to <= QUERY_MAX_MS, what);
          assert.ok(to - from <= 62 * DAY_MS, what); // calendars.js의 조회 구간 길이 상한(QUERY_SPAN_MAX_MS)
          checked++;
        }
      }
    }
  }
  assert.ok(checked >= 8 * 4800, `확인한 조회 ${checked}개`); // 시간대 8곳 × 400년 × 12달, 달마다 한 개 이상
});

test('회차의 끝(OCCURRENCE_MAX_MS) 앞의 어느 회차에서 반복을 나눠도 종료일이 MAX_UNTIL을 넘지 않는다', () => {
  assert.equal(OCCURRENCE_MAX_MS, day('2300-01-01'));
  assert.ok(QUERY_MIN_MS < day('2000-01-01') && OCCURRENCE_MAX_MS < QUERY_MAX_MS);
  // 끝이 없는 매일 반복에서 끝 바로 앞의 회차 — 시간 일정은 한국 날짜로 2300-01-01 오전(9시 전), 종일 일정은 2299-12-31.
  const timedDaily = timed('2026-01-01 08:30', '2026-01-01 09:00', { freq: 'daily', interval: 1 });
  const allDayDaily = allDay('2026-01-01', '2026-01-02', { freq: 'daily', interval: 1 });
  const lastTimed = expandOccurrences(timedDaily, kst('2299-12-30 00:00'), OCCURRENCE_MAX_MS).at(-1);
  const lastAllDay = expandOccurrences(allDayDaily, day('2299-12-30'), OCCURRENCE_MAX_MS).at(-1);
  assert.equal(kstStr(lastTimed.start), '2300-01-01 08:30');
  assert.equal(dayStr(lastAllDay.start), MAX_UNTIL);
  for (const [ev, occurrenceStart] of [
    [timedDaily, lastTimed.start],
    [allDayDaily, lastAllDay.start],
  ]) {
    const { before } = splitRecurrenceAt(ev, occurrenceStart, occurrenceIndex(ev, occurrenceStart));
    assert.ok(before.until <= MAX_UNTIL, before.until);
    // 나뉜 원래 시리즈를 그대로 다시 저장해도("모든 일정" 수정) 반복 종료일 검사를 통과한다.
    assert.equal(parseRecurrence(before, { startMs: ev.startMs, allDay: ev.allDay }).value.until, before.until);
  }
  // 종료일이 MAX_UNTIL인 시리즈는 마지막 회차(한국 날짜 2299-12-31 밤)까지 그 앞이다 — 끝에서 잘리는 회차가 없다.
  const untilMax = timed('2026-01-01 23:30', '2026-01-02 00:30', { freq: 'daily', interval: 1, until: MAX_UNTIL });
  const tail = expandOccurrences(untilMax, kst('2299-12-30 00:00'), kst('2300-01-03 00:00'));
  assert.equal(kstStr(tail.at(-1).start), '2299-12-31 23:30');
  assert.ok(tail.at(-1).start < OCCURRENCE_MAX_MS);
});
