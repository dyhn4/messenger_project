// 회의실·자원 예약 후속 — 자원마다의 예약 규칙(사람·요일·시간대·한 번에 쓸 시간·승인), 반복 예약, 회의실 추천, 사용 통계, 시작 전 알림,
// 태블릿 화면의 지금·다음 예약. `node --test test/*.test.js`(DB 없이 돈다).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  checkBookingPolicy,
  displayState,
  durationText,
  initialBookingStatus,
  isApproverOf,
  parseResourcePolicy,
  quickBookRange,
  remindersDue,
  resourceStats,
  seriesOccurrences,
  splitSeriesConflicts,
  suggestResources,
} from '../src/resourcePolicy.js';

// 한국 시각 'YYYY-MM-DD HH:MM' → ms.
const k = (s) => Date.parse(`${s.replace(' ', 'T')}:00+09:00`);
const U1 = '11111111-1111-1111-1111-111111111111';
const U2 = '22222222-2222-2222-2222-222222222222';
const room = (extra = {}) => ({ id: 'R1', name: '대회의실', kind: 'room', enabled: true, capacity: 10, ...extra });

test('예약 규칙 입력 — 승인할 사람·예약할 수 있는 사람·시간대(함께)·요일·한 번에 쓸 시간', () => {
  const isCandidate = (id) => id === U1 || id === U2;
  const ok = parseResourcePolicy(
    { requiresApproval: true, approverIds: [U1, U1], allowedUserIds: [U2], availableFrom: 480, availableTo: 1200, availableDays: [5, 1, 2, 3, 4], maxMinutes: 240 },
    { isCandidate },
  );
  assert.deepEqual(ok.values, {
    requiresApproval: true,
    approverIds: [U1],
    allowedUserIds: [U2],
    availableFrom: 480,
    availableTo: 1200,
    availableDays: [1, 2, 3, 4, 5],
    maxMinutes: 240,
  });
  // 모든 요일이면 null(제한 없음), 빈 목록은 안 됨.
  assert.equal(parseResourcePolicy({ availableDays: [0, 1, 2, 3, 4, 5, 6] }).values.availableDays, null);
  assert.match(parseResourcePolicy({ availableDays: [] }).error, /요일/);
  assert.match(parseResourcePolicy({ availableFrom: 600 }).error, /함께/);
  // 한쪽만 보내도 지금 값과 맞추어 본다.
  assert.deepEqual(parseResourcePolicy({ availableTo: 1080 }, { current: { availableFrom: 540, availableTo: 1200 } }).values, { availableFrom: 540, availableTo: 1080 });
  assert.match(parseResourcePolicy({ availableFrom: 900, availableTo: 600 }).error, /시간대/);
  assert.match(parseResourcePolicy({ approverIds: ['nope'] }).error, /승인할 사람/);
  assert.match(parseResourcePolicy({ allowedUserIds: [U1] }, { isCandidate: () => false }).error, /고를 수 없는/);
  assert.match(parseResourcePolicy({ maxMinutes: 5 }).error, /15분~7일/);
  assert.deepEqual(parseResourcePolicy({}).values, {});
});

test('예약 규칙 검사 — 정해진 사람만(관리자는 됨), 요일·시간대, 한 번에 쓸 시간', () => {
  const r = room({ allowedUserIds: [U1], availableDays: [1, 2, 3, 4, 5], availableFrom: 540, availableTo: 1080, maxMinutes: 120 });
  // 2026-10-19(월) 10:00~11:00.
  const base = { startMs: k('2026-10-19 10:00'), endMs: k('2026-10-19 11:00') };
  assert.equal(checkBookingPolicy(r, { userId: U1, ...base }), null);
  assert.match(checkBookingPolicy(r, { userId: U2, ...base }).error, /정해진 사람만/);
  assert.equal(checkBookingPolicy(r, { userId: U2, ...base, privileged: true }), null);
  assert.match(checkBookingPolicy(r, { userId: U1, startMs: k('2026-10-19 10:00'), endMs: k('2026-10-19 13:00') }).error, /2시간까지/);
  assert.match(checkBookingPolicy(r, { userId: U1, startMs: k('2026-10-18 10:00'), endMs: k('2026-10-18 11:00') }).error, /월·화·수·목·금요일에만/);
  assert.match(checkBookingPolicy(r, { userId: U1, startMs: k('2026-10-19 08:00'), endMs: k('2026-10-19 09:30') }).error, /09:00~18:00/);
  assert.match(checkBookingPolicy(r, { userId: U1, startMs: k('2026-10-19 17:30'), endMs: k('2026-10-19 18:30') }).error, /09:00~18:00/);
  // 끝이 자정이면 24:00으로 본다.
  const late = room({ availableFrom: 1200, availableTo: 1440 });
  assert.equal(checkBookingPolicy(late, { userId: U1, startMs: k('2026-10-19 22:00'), endMs: k('2026-10-20 00:00') }), null);
  assert.equal(checkBookingPolicy(room(), { userId: U2, ...base }), null);
  assert.equal(durationText(90), '1시간 30분');
  assert.equal(durationText(2880), '2일');
});

test('승인 — 승인이 필요한 자원은 승인할 사람·관리자가 아니면 기다림으로', () => {
  const r = room({ requiresApproval: true, approverIds: [U1] });
  assert.equal(initialBookingStatus(r, { userId: U2 }), 'pending');
  assert.equal(initialBookingStatus(r, { userId: U1 }), 'confirmed');
  assert.equal(initialBookingStatus(r, { userId: U2, isManager: true }), 'confirmed');
  assert.equal(initialBookingStatus(room(), { userId: U2 }), 'confirmed');
  assert.equal(isApproverOf(r, { userId: U1 }), true);
  assert.equal(isApproverOf(r, { userId: U2 }), false);
  assert.equal(isApproverOf(room(), { userId: U2, isManager: true }), true);
});

test('반복 예약 — 매주·2주마다 같은 시간, 회차 수·간격·180일, 겹치는 회차 나누기', () => {
  const now = k('2026-10-18 09:00');
  const s = k('2026-10-20 10:00');
  const e = k('2026-10-20 11:00');
  const weekly = seriesOccurrences({ startMs: s, endMs: e, repeatWeeks: 4, now });
  assert.deepEqual(
    weekly.occurrences.map((o) => new Date(o.startMs + 9 * 3600_000).toISOString().slice(0, 16)),
    ['2026-10-20T10:00', '2026-10-27T10:00', '2026-11-03T10:00', '2026-11-10T10:00'],
  );
  assert.equal(seriesOccurrences({ startMs: s, endMs: e, repeatWeeks: 3, everyWeeks: 2, now }).occurrences[2].startMs, s + 28 * 86_400_000);
  assert.equal(seriesOccurrences({ startMs: s, endMs: e, now }).occurrences.length, 1);
  assert.match(seriesOccurrences({ startMs: s, endMs: e, repeatWeeks: 27, now }).error, /1~26회/);
  assert.match(seriesOccurrences({ startMs: s, endMs: e, repeatWeeks: 2, everyWeeks: 3, now }).error, /매주 또는 2주/);
  assert.match(seriesOccurrences({ startMs: s, endMs: s + 8 * 86_400_000, repeatWeeks: 2, now }).error, /반복 간격보다 짧아야/);
  assert.match(seriesOccurrences({ startMs: s, endMs: e, repeatWeeks: 26, now: k('2026-06-01 09:00') }).error, /180일/);

  const existing = [{ startAt: new Date(k('2026-10-27 10:30')), endAt: new Date(k('2026-10-27 12:00')), userName: '김' }];
  const split = splitSeriesConflicts(weekly.occurrences, existing);
  assert.equal(split.free.length, 3);
  assert.equal(split.conflicts.length, 1);
  assert.equal(split.conflicts[0].with.userName, '김');
});

test('회의실 추천 — 비어 있고·예약할 수 있고·수용 인원이 맞는 것, 남는 자리가 적은 것부터', () => {
  const startMs = k('2026-10-19 10:00');
  const endMs = k('2026-10-19 11:00');
  const resources = [
    room({ id: 'A', name: '대회의실', capacity: 20 }),
    room({ id: 'B', name: '소회의실', capacity: 6 }),
    room({ id: 'C', name: '중회의실', capacity: 10 }),
    room({ id: 'D', name: '세미나실', capacity: null }),
    room({ id: 'E', name: '임원실', capacity: 8, allowedUserIds: [U2] }),
    room({ id: 'F', name: '꺼진 방', capacity: 8, enabled: false }),
    room({ id: 'G', name: '빔 프로젝터', kind: 'equipment', capacity: null }),
    room({ id: 'H', name: '승인 방', capacity: 12, requiresApproval: true, approverIds: [U2] }),
  ];
  const busy = [{ resourceId: 'C', startAt: new Date(k('2026-10-19 10:30')), endAt: new Date(k('2026-10-19 12:00')) }];
  const list = suggestResources({ resources, busy, startMs, endMs, attendees: 7, userId: U1 });
  assert.deepEqual(
    list.map((x) => [x.resource.id, x.spare, x.needsApproval]),
    [
      ['H', 5, true],
      ['A', 13, false],
      ['D', null, false],
    ],
  );
  // 장비 추천.
  assert.deepEqual(
    suggestResources({ resources, busy, startMs, endMs, kind: 'equipment', userId: U1 }).map((x) => x.resource.id),
    ['G'],
  );
});

test('사용 통계 — 건수·쓴 시간(구간 안)·이용률·쓴 사람·요일별, 승인 기다리는 것은 뺌', () => {
  // 2026-10-19(월)~2026-10-26(월) 한 주 — 평일 09:00~18:00 = 5 × 540분.
  const fromMs = k('2026-10-19 00:00');
  const toMs = k('2026-10-26 00:00');
  const bookings = [
    { resourceId: 'R1', startAt: new Date(k('2026-10-19 10:00')), endAt: new Date(k('2026-10-19 12:00')), userName: '김', status: 'confirmed' },
    { resourceId: 'R1', startAt: new Date(k('2026-10-21 14:00')), endAt: new Date(k('2026-10-21 15:00')), userName: '이', status: 'confirmed' },
    { resourceId: 'R1', startAt: new Date(k('2026-10-22 14:00')), endAt: new Date(k('2026-10-22 15:00')), userName: '김', status: 'confirmed' },
    { resourceId: 'R1', startAt: new Date(k('2026-10-23 14:00')), endAt: new Date(k('2026-10-23 15:00')), userName: '박', status: 'pending' },
    // 구간 앞에서 시작한 예약은 구간 안만.
    { resourceId: 'R1', startAt: new Date(k('2026-10-18 23:00')), endAt: new Date(k('2026-10-19 01:00')), userName: '이', status: 'confirmed' },
  ];
  const [r] = resourceStats({ resources: [room()], bookings, fromMs, toMs });
  assert.equal(r.count, 4);
  assert.equal(r.minutes, 120 + 60 + 60 + 60);
  assert.equal(r.availableMinutes, 5 * 540);
  assert.equal(r.utilization, Math.round((300 / 2700) * 1000) / 10);
  assert.equal(r.userCount, 2);
  assert.deepEqual(r.topUsers, [
    { name: '김', count: 2 },
    { name: '이', count: 2 },
  ]);
  assert.equal(r.byWeekday[1], 2);
  assert.equal(r.byWeekday[3], 1);
  // 시간대·요일을 정한 자원은 그만큼.
  const [weekend] = resourceStats({ resources: [room({ availableDays: [6], availableFrom: 600, availableTo: 720 })], bookings: [], fromMs, toMs });
  assert.equal(weekend.availableMinutes, 120);
  assert.equal(weekend.utilization, 0);
});

test('시작 전 알림 — 잡힌 예약만, 안 알린 것, 범위의 알림 분 안에 드는 것(0이면 끔)', () => {
  const now = k('2026-10-19 09:50');
  const b = (id, start, extra = {}) => ({ id, scopeKey: 'server', userId: U1, status: 'confirmed', remindedAt: null, startAt: new Date(k(start)), ...extra });
  const list = [
    b('a', '2026-10-19 10:00'),
    b('b', '2026-10-19 10:30'),
    b('c', '2026-10-19 09:55', { status: 'pending' }),
    b('d', '2026-10-19 09:58', { remindedAt: new Date() }),
    b('e', '2026-10-19 09:59', { userId: null }),
    b('f', '2026-10-19 09:45'),
    b('g', '2026-10-19 09:55', { scopeKey: 'team-a' }),
  ];
  const due = remindersDue(list, { now, leadOf: (key) => (key === 'server' ? 10 : 0) });
  assert.deepEqual(
    due.map((x) => x.id),
    ['a'],
  );
});

test('태블릿 화면 — 지금 쓰는 예약·이어진 예약의 끝·오늘 남은 예약·언제까지 비는지, 바로 예약', () => {
  const now = k('2026-10-19 10:15');
  const b = (start, end, title) => ({ startAt: new Date(k(start)), endAt: new Date(k(end)), title });
  const busy = displayState([b('2026-10-19 11:00', '2026-10-19 12:00', '다음'), b('2026-10-19 10:00', '2026-10-19 10:30', '지금'), b('2026-10-19 10:30', '2026-10-19 11:00', '이어서'), b('2026-10-20 09:00', '2026-10-20 10:00', '내일')], now);
  assert.equal(busy.current.title, '지금');
  assert.equal(busy.busyUntil, k('2026-10-19 12:00'));
  assert.deepEqual(
    busy.upcoming.map((x) => x.title),
    ['이어서', '다음'],
  );
  assert.equal(busy.freeUntil, null);
  const free = displayState([b('2026-10-19 11:00', '2026-10-19 12:00', '다음')], now);
  assert.equal(free.current, null);
  assert.equal(free.freeUntil, k('2026-10-19 11:00'));
  assert.deepEqual(quickBookRange({ minutes: 30, now, freeUntil: free.freeUntil, current: null }), { startMs: k('2026-10-19 10:15'), endMs: k('2026-10-19 10:45') });
  assert.match(quickBookRange({ minutes: 60, now, freeUntil: free.freeUntil, current: null }).error, /다음 예약/);
  assert.match(quickBookRange({ minutes: 20, now, freeUntil: null, current: null }).error, /15·30·60/);
  assert.match(quickBookRange({ minutes: 15, now, freeUntil: null, current: busy.current }).error, /쓰는 중/);
});
