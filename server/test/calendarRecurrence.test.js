// 캘린더 순수 로직 단위 테스트 — `node --test test/` (DB·서버 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  DAY_MS,
  alignStartToRecurrence,
  expandOccurrences,
  occurrenceIndex,
  parseRecurrence,
  splitRecurrenceAt,
} from '../src/calendarRecurrence.js';
import { HOLIDAYS, holidaysInRange } from '../src/holidays.js';
import { calendarPermissions, canModifyCalendarEvent } from '../src/permissions.js';

const HOUR = 3600 * 1000;
/** KST 벽시계 'YYYY-MM-DD HH:mm' → 실제 epoch ms. */
const kst = (s) => Date.parse(s.replace(' ', 'T') + ':00+09:00');
/** 종일 표현: 'YYYY-MM-DD' → UTC 자정 ms. */
const day = (s) => Date.parse(`${s}T00:00:00Z`);
const kstStr = (ms) => new Date(ms + 9 * HOUR).toISOString().slice(0, 16).replace('T', ' ');
const dayStr = (ms) => new Date(ms).toISOString().slice(0, 10);
const FAR = day('2040-01-01');

function timed(startStr, endStr, recurrence, exdates = []) {
  return { startMs: kst(startStr), endMs: kst(endStr), allDay: false, recurrence, exdates };
}
function allDay(startStr, endStr, recurrence, exdates = []) {
  return { startMs: day(startStr), endMs: day(endStr), allDay: true, recurrence, exdates };
}
// FAR가 3년보다 멀어서 expandOccurrences가 자르므로, 끝이 있는 반복 검사에는 넉넉한 3년 구간을 준다.
const starts = (ev, from = ev.startMs, span = 3 * 365 * DAY_MS) => expandOccurrences(ev, from, from + span).map((o) => o.start);

// ── 펼치기 ──────────────────────────────────────────────────────────────

test('반복 없음: 구간에 걸칠 때만 나온다', () => {
  const ev = timed('2026-05-05 10:00', '2026-05-05 11:00', null);
  assert.equal(expandOccurrences(ev, kst('2026-05-05 00:00'), kst('2026-05-06 00:00')).length, 1);
  assert.equal(expandOccurrences(ev, kst('2026-05-05 11:00'), kst('2026-05-06 00:00')).length, 0); // 끝과 맞닿음은 제외
  assert.equal(expandOccurrences(ev, kst('2026-05-05 00:00'), kst('2026-05-05 10:00')).length, 0); // 시작과 맞닿음은 제외
});

test('daily interval + count', () => {
  const ev = timed('2026-05-01 09:00', '2026-05-01 10:00', { freq: 'daily', interval: 2, count: 4 });
  assert.deepEqual(starts(ev).map(kstStr), [
    '2026-05-01 09:00',
    '2026-05-03 09:00',
    '2026-05-05 09:00',
    '2026-05-07 09:00',
  ]);
});

test('daily until은 그날을 포함하고, 한국 날짜 기준이다', () => {
  // 한국 시간 23:30 시작 = UTC로는 같은 날 14:30. until '2026-03-03'이면 3/3 23:30 회차까지 나온다.
  const ev = timed('2026-03-01 23:30', '2026-03-02 00:30', { freq: 'daily', interval: 1, until: '2026-03-03' });
  assert.deepEqual(starts(ev).map(kstStr), ['2026-03-01 23:30', '2026-03-02 23:30', '2026-03-03 23:30']);
});

test('한국 새벽 시간대 일정도 한국 요일로 반복한다(UTC로는 전날)', () => {
  // 2026-05-05(화) 01:00 KST = 05-04T16:00Z. 매주 화 → 다음은 2026-05-12(화) 01:00 KST.
  const ev = timed('2026-05-05 01:00', '2026-05-05 02:00', { freq: 'weekly', interval: 1, byWeekday: [2], count: 3 });
  assert.deepEqual(starts(ev).map(kstStr), ['2026-05-05 01:00', '2026-05-12 01:00', '2026-05-19 01:00']);
});

test('weekly byWeekday [1,3], 첫 주는 시작일 이후만', () => {
  // 2026-05-06은 수요일.
  const ev = timed('2026-05-06 10:00', '2026-05-06 11:00', { freq: 'weekly', interval: 1, byWeekday: [1, 3], count: 5 });
  assert.deepEqual(starts(ev).map(kstStr), [
    '2026-05-06 10:00',
    '2026-05-11 10:00',
    '2026-05-13 10:00',
    '2026-05-18 10:00',
    '2026-05-20 10:00',
  ]);
});

test('weekly interval 2는 시작일이 속한 주(일요일 시작)부터 격주', () => {
  const ev = allDay('2026-05-04', '2026-05-05', { freq: 'weekly', interval: 2, byWeekday: [1, 5], count: 4 });
  assert.deepEqual(starts(ev).map(dayStr), ['2026-05-04', '2026-05-08', '2026-05-18', '2026-05-22']);
});

test('monthly: 31일은 없는 달을 건너뛴다', () => {
  const ev = allDay('2026-01-31', '2026-02-01', { freq: 'monthly', interval: 1, count: 5 });
  assert.deepEqual(starts(ev).map(dayStr), ['2026-01-31', '2026-03-31', '2026-05-31', '2026-07-31', '2026-08-31']);
});

test('monthly interval 3', () => {
  const ev = timed('2026-01-15 09:00', '2026-01-15 10:00', { freq: 'monthly', interval: 3, count: 3 });
  assert.deepEqual(starts(ev).map(kstStr), ['2026-01-15 09:00', '2026-04-15 09:00', '2026-07-15 09:00']);
});

test('yearly: 2월 29일은 윤년에만', () => {
  const ev = allDay('2024-02-29', '2024-03-01', { freq: 'yearly', interval: 1, count: 3 });
  assert.deepEqual(starts(ev).map(dayStr), ['2024-02-29']); // 3년 구간엔 첫 회차뿐
  // 3년 상한을 넘는 회차는 구간을 나눠 본다.
  const later = [
    ...expandOccurrences(ev, day('2027-01-01'), day('2030-01-01')),
    ...expandOccurrences(ev, day('2030-01-01'), day('2033-01-01')),
  ].map((o) => dayStr(o.start));
  assert.deepEqual(later, ['2028-02-29', '2032-02-29']);
});

test('yearly interval 2 + until', () => {
  const ev = allDay('2026-03-01', '2026-03-02', { freq: 'yearly', interval: 2, until: '2030-03-01' });
  const all = [
    ...expandOccurrences(ev, day('2026-01-01'), day('2029-01-01')),
    ...expandOccurrences(ev, day('2029-01-01'), day('2032-01-01')),
  ];
  assert.deepEqual(all.map((o) => dayStr(o.start)), ['2026-03-01', '2028-03-01', '2030-03-01']);
});

test('exdates는 빠지지만 count에는 센다', () => {
  const ev = timed('2026-05-01 09:00', '2026-05-01 10:00', { freq: 'daily', interval: 1, count: 4 }, [kst('2026-05-02 09:00')]);
  assert.deepEqual(starts(ev).map(kstStr), ['2026-05-01 09:00', '2026-05-03 09:00', '2026-05-04 09:00']);
});

test('구간 자르기: 여러 날 종일 일정의 두 번째 날도 걸친다', () => {
  const ev = allDay('2026-05-01', '2026-05-04', { freq: 'weekly', interval: 1, byWeekday: [5], count: 3 }); // 금, 3일짜리
  const occ = expandOccurrences(ev, day('2026-05-03'), day('2026-05-04'));
  assert.equal(occ.length, 1);
  assert.equal(dayStr(occ[0].start), '2026-05-01');
  assert.equal(dayStr(occ[0].end), '2026-05-04');
});

test('오래된 매일 반복도 구간만 뽑는다', () => {
  const ev = timed('2020-01-01 09:00', '2020-01-01 10:00', { freq: 'daily', interval: 1 });
  const got = expandOccurrences(ev, kst('2026-05-01 00:00'), kst('2026-05-08 00:00')).map((o) => o.start);
  assert.equal(got.length, 7);
  assert.equal(kstStr(got[0]), '2026-05-01 09:00');
});

test('한 번에 3년보다 길게는 펼치지 않는다', () => {
  const ev = allDay('2026-01-01', '2026-01-02', { freq: 'daily', interval: 1 });
  const got = expandOccurrences(ev, day('2026-01-01'), day('2040-01-01'));
  assert.ok(got.length <= 3 * 366);
});

// ── 인덱스·나누기 ───────────────────────────────────────────────────────

test('occurrenceIndex', () => {
  const ev = timed('2026-05-01 09:00', '2026-05-01 10:00', { freq: 'daily', interval: 2, count: 4 });
  assert.equal(occurrenceIndex(ev, kst('2026-05-01 09:00')), 0);
  assert.equal(occurrenceIndex(ev, kst('2026-05-05 09:00')), 2);
  assert.equal(occurrenceIndex(ev, kst('2026-05-04 09:00')), -1); // 회차 아님
  assert.equal(occurrenceIndex(ev, kst('2026-05-09 09:00')), -1); // count 밖
});

test('splitRecurrenceAt: count는 until로 환산하고 남은 횟수를 새 시리즈에 준다', () => {
  const ev = timed('2026-05-01 09:00', '2026-05-01 10:00', { freq: 'daily', interval: 1, count: 10 });
  const occ = kst('2026-05-04 09:00'); // 4번째 회차 = 인덱스 3
  const { before, after } = splitRecurrenceAt(ev, occ, occurrenceIndex(ev, occ));
  assert.deepEqual(before, { freq: 'daily', interval: 1, until: '2026-05-03' });
  assert.deepEqual(after, { freq: 'daily', interval: 1, count: 7 });
  // 나뉜 두 시리즈를 합치면 원래 10회.
  const a = starts({ ...ev, recurrence: before }).length;
  const b = starts({ ...ev, startMs: occ, endMs: occ + HOUR, recurrence: after }).length;
  assert.equal(a + b, 10);
});

test('splitRecurrenceAt: until은 새 시리즈가 그대로 물려받는다', () => {
  const ev = allDay('2026-05-01', '2026-05-02', { freq: 'weekly', interval: 1, byWeekday: [5], until: '2026-06-30' });
  const occ = day('2026-05-15');
  const { before, after } = splitRecurrenceAt(ev, occ, occurrenceIndex(ev, occ));
  assert.equal(before.until, '2026-05-14');
  assert.equal(after.until, '2026-06-30');
  assert.deepEqual(after.byWeekday, [5]);
});

// ── 검사 ────────────────────────────────────────────────────────────────

test('parseRecurrence: 정상·기본값', () => {
  const start = { startMs: kst('2026-05-06 10:00'), allDay: false }; // 수요일
  assert.deepEqual(parseRecurrence(null, start), { value: null });
  assert.deepEqual(parseRecurrence({ freq: 'weekly' }, start).value, { freq: 'weekly', interval: 1, byWeekday: [3] });
  assert.deepEqual(parseRecurrence({ freq: 'weekly', byWeekday: [3, 1, 1] }, start).value.byWeekday, [1, 3]);
  assert.deepEqual(parseRecurrence({ freq: 'daily', interval: 3, count: 5 }, start).value, { freq: 'daily', interval: 3, count: 5 });
  assert.equal(parseRecurrence({ freq: 'daily', until: '2026-12-31', count: null }, start).value.until, '2026-12-31');
});

test('parseRecurrence: 거절', () => {
  const start = { startMs: kst('2026-05-06 10:00'), allDay: false };
  const bad = (r) => assert.ok(parseRecurrence(r, start).error, JSON.stringify(r));
  bad({ freq: 'hourly' });
  bad({ freq: 'daily', interval: 0 });
  bad({ freq: 'daily', interval: 100 });
  bad({ freq: 'daily', interval: 1.5 });
  bad({ freq: 'daily', byWeekday: [1] });
  bad({ freq: 'weekly', byWeekday: [7] });
  bad({ freq: 'daily', until: '2026-12-31', count: 3 });
  bad({ freq: 'daily', count: 501 });
  bad({ freq: 'daily', count: 0 });
  bad({ freq: 'daily', until: '2026-02-30' });
  bad({ freq: 'daily', until: '2026-05-05' }); // 시작일보다 앞
  bad('daily');
});

test('alignStartToRecurrence: 시작 요일이 목록에 없으면 다음 해당 요일로', () => {
  const s = kst('2026-05-06 10:00'); // 수
  const e = s + HOUR;
  const r = alignStartToRecurrence(s, e, false, { freq: 'weekly', interval: 1, byWeekday: [1, 5] });
  assert.equal(kstStr(r.startMs), '2026-05-08 10:00'); // 금
  assert.equal(r.endMs - r.startMs, HOUR);
  assert.equal(alignStartToRecurrence(s, e, false, { freq: 'weekly', interval: 1, byWeekday: [3] }).startMs, s);
  assert.equal(alignStartToRecurrence(s, e, false, { freq: 'daily', interval: 1 }).startMs, s);
});

// ── 공휴일 표 ───────────────────────────────────────────────────────────

/** Intl 음력('chinese') → 그레고리력 날짜. 한국 음력과 이 기간엔 같다. */
function lunarToGregorian(year, month, dayOfMonth) {
  const fmt = new Intl.DateTimeFormat('en-u-ca-chinese', { timeZone: 'UTC', month: 'numeric', day: 'numeric' });
  for (let ms = Date.UTC(year, 0, 1); ms < Date.UTC(year + 1, 0, 1); ms += DAY_MS) {
    const parts = Object.fromEntries(fmt.formatToParts(ms + 12 * HOUR).map((p) => [p.type, p.value]));
    if (parts.month === String(month) && parts.day === String(dayOfMonth)) return new Date(ms).toISOString().slice(0, 10);
  }
  return null;
}

test('공휴일 표 = 규칙으로 다시 계산한 값(임시공휴일·선거일 제외)', () => {
  const isSat = (d) => new Date(`${d}T00:00:00Z`).getUTCDay() === 6;
  const isSun = (d) => new Date(`${d}T00:00:00Z`).getUTCDay() === 0;
  const plus = (d, n) => new Date(Date.parse(`${d}T00:00:00Z`) + n * DAY_MS).toISOString().slice(0, 10);

  const specials = new Set(['2025-01-27', '2025-06-03', '2026-06-03']);
  const base = new Set();
  const derived = []; // { d, mode }  mode: 'weekend' = 토/일이면 대체, 'holidaySun' = 명절(일요일이면 대체), 'none'
  for (const y of [2025, 2026, 2027]) {
    const seollal = lunarToGregorian(y, 1, 1);
    const chuseok = lunarToGregorian(y, 8, 15);
    const buddha = lunarToGregorian(y, 4, 8);
    assert.ok(seollal && chuseok && buddha, `${y} 음력 변환`);
    const fixed = [
      [`${y}-01-01`, 'none'],
      [`${y}-03-01`, 'weekend'],
      [`${y}-05-05`, 'weekend'],
      [buddha, 'weekend'],
      [`${y}-06-06`, 'none'],
      [`${y}-08-15`, 'weekend'],
      [`${y}-10-03`, 'weekend'],
      [`${y}-10-09`, 'weekend'],
      [`${y}-12-25`, 'weekend'],
    ];
    for (const [d, mode] of fixed) {
      base.add(d);
      derived.push({ d, mode });
    }
    for (const c of [seollal, chuseok]) {
      for (const d of [plus(c, -1), c, plus(c, 1)]) {
        base.add(d);
        derived.push({ d, mode: 'holidaySun' });
      }
    }
  }
  // 날짜당 대체 하루: 토/일(명절은 일요일)과 겹치거나, 다른 공휴일과 같은 날인 경우(2025-05-05).
  const nameCount = new Map();
  for (const { d } of derived) nameCount.set(d, (nameCount.get(d) ?? 0) + 1);
  const needs = new Set();
  for (const { d, mode } of derived) {
    if (mode === 'weekend' && (isSat(d) || isSun(d))) needs.add(d);
    if (mode === 'holidaySun' && isSun(d)) needs.add(d);
    if (nameCount.get(d) > 1) needs.add(d);
  }
  const occupied = new Set(base);
  const substitutes = new Set();
  for (const d of [...needs].sort()) {
    let cand = plus(d, 1);
    while (isSat(cand) || isSun(cand) || occupied.has(cand)) cand = plus(cand, 1);
    occupied.add(cand);
    substitutes.add(cand);
  }
  const expected = new Set([...base, ...substitutes]);
  const actual = new Set(HOLIDAYS.map((h) => h.date).filter((d) => !specials.has(d)));
  assert.deepEqual([...actual].sort(), [...expected].sort());
  // 이름이 "대체공휴일"인 것도 정확히 대체 날짜들이어야 한다.
  for (const h of HOLIDAYS) {
    if (specials.has(h.date)) continue;
    assert.equal(h.name.startsWith('대체공휴일'), substitutes.has(h.date), `${h.date} ${h.name}`);
  }
});

test('공휴일 표: 날짜 중복 없음·형식·정렬', () => {
  const dates = HOLIDAYS.map((h) => h.date);
  assert.equal(new Set(dates).size, dates.length);
  assert.deepEqual([...dates].sort(), dates);
  for (const h of HOLIDAYS) {
    assert.match(h.date, /^\d{4}-\d{2}-\d{2}$/);
    assert.ok(h.name);
    assert.ok(h.date >= '2025-01-01' && h.date <= '2027-12-31');
  }
});

test('holidaysInRange: 범위 밖은 비고, 안은 UTC 자정 표현', () => {
  assert.equal(holidaysInRange(day('2024-01-01'), day('2024-12-31')).length, 0);
  assert.equal(holidaysInRange(day('2028-01-01'), day('2028-12-31')).length, 0);
  const got = holidaysInRange(day('2026-05-04'), day('2026-05-07'));
  assert.deepEqual(got.map((h) => h.date), ['2026-05-05']);
  assert.equal(got[0].startMs, day('2026-05-05'));
  assert.equal(got[0].endMs, day('2026-05-06'));
});

// ── 권한 표 ─────────────────────────────────────────────────────────────

const ME = 'me';
const OTHER = 'other';
const perm = (calendar, ctx) => calendarPermissions({ calendar, userId: ME, isTeamMember: true, ...ctx });

test('calendarPermissions: 팀 멤버가 아니면 아무것도 못 한다', () => {
  const p = perm({ kind: 'personal', ownerId: ME, isPublic: true }, { role: 'member', isTeamMember: false });
  assert.equal(p.canView, false);
  assert.equal(p.canCreateEvents, false);
});

test('calendarPermissions: personal', () => {
  const cal = { kind: 'personal', ownerId: ME, isPublic: true };
  let p = perm(cal, { role: 'member' });
  assert.deepEqual([p.role, p.canView, p.canCreateEvents, p.canEditSettings, p.canDelete], ['admin', true, true, true, false]);
  // 준회원도 자기 기본 캘린더에는 일정을 만든다.
  p = perm(cal, { role: 'guest' });
  assert.deepEqual([p.canView, p.canCreateEvents], [true, true]);
  // 남의 공개 기본 캘린더 구독
  const theirs = { kind: 'personal', ownerId: OTHER, isPublic: true };
  p = perm(theirs, { role: 'member', memberRole: 'subscriber' });
  assert.deepEqual([p.role, p.canView, p.canCreateEvents, p.canEditSettings], ['subscriber', true, false, false]);
  // 비공개로 바뀌면 구독으로는 못 본다, 구독 행이 없어도 못 본다, 준회원 구독자도 못 본다.
  assert.equal(perm({ ...theirs, isPublic: false }, { role: 'member', memberRole: 'subscriber' }).canView, false);
  assert.equal(perm(theirs, { role: 'member' }).canView, false);
  assert.equal(perm(theirs, { role: 'guest', memberRole: 'subscriber' }).canView, false);
});

test('calendarPermissions: team', () => {
  const cal = { kind: 'team', ownerId: null, isPublic: true };
  let p = perm(cal, { role: 'member', isOwner: false });
  assert.deepEqual([p.role, p.canView, p.canCreateEvents, p.canEditSettings, p.canDelete], ['read', true, false, false, false]);
  p = perm(cal, { role: 'member', isOwner: true });
  assert.deepEqual([p.role, p.canCreateEvents], ['admin', true]);
  p = perm(cal, { role: 'admin', isOwner: false });
  assert.deepEqual([p.role, p.canCreateEvents], ['admin', true]);
  p = perm(cal, { role: 'guest', isOwner: false });
  assert.equal(p.canView, false); // 준회원은 팀 캘린더를 볼 수 없다
});

test('calendarPermissions: shared', () => {
  const cal = { kind: 'shared', ownerId: OTHER, isPublic: false };
  const of = (memberRole, role = 'member') => perm(cal, { role, memberRole });
  assert.deepEqual([of('admin').canView, of('admin').canCreateEvents, of('admin').canEditSettings], [true, true, true]);
  assert.deepEqual([of('write').canView, of('write').canCreateEvents, of('write').canEditSettings], [true, true, false]);
  assert.deepEqual([of('read').canView, of('read').canCreateEvents, of('read').canEditSettings], [true, false, false]);
  assert.equal(of(null).canView, false);
  assert.equal(of('subscriber').canView, false); // 비공개
  const pub = { ...cal, isPublic: true };
  assert.equal(perm(pub, { role: 'member', memberRole: 'subscriber' }).canView, true);
  assert.equal(perm(pub, { role: 'guest', memberRole: 'subscriber' }).canView, false);
  // 소유자만 캘린더를 지운다.
  assert.equal(perm({ ...cal, ownerId: ME }, { role: 'member', memberRole: 'admin' }).canDelete, true);
  assert.equal(of('admin').canDelete, false);
  // 준회원 read 멤버는 볼 수 있다.
  assert.equal(of('read', 'guest').canView, true);
});

test('canModifyCalendarEvent: 만든 사람·소유자·관리자만, write 멤버는 남의 일정을 못 고친다', () => {
  const cal = { kind: 'shared', ownerId: OTHER, isPublic: false };
  const event = { creatorId: OTHER };
  const can = (memberRole, e = event) =>
    canModifyCalendarEvent({ access: perm(cal, { role: 'member', memberRole }), event: e, userId: ME });
  assert.equal(can('admin'), true);
  assert.equal(can('write'), false);
  assert.equal(can('write', { creatorId: ME }), true);
  assert.equal(can('read', { creatorId: ME }), false); // 권한이 내려간 옛 작성자
  // 팀 캘린더: 팀 관리자만.
  const team = { kind: 'team', ownerId: null, isPublic: true };
  assert.equal(canModifyCalendarEvent({ access: perm(team, { role: 'member', isOwner: false }), event: { creatorId: ME }, userId: ME }), false);
  assert.equal(canModifyCalendarEvent({ access: perm(team, { role: 'admin', isOwner: false }), event, userId: ME }), true);
});
